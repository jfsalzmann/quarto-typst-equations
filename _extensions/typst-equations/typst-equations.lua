-- Renders math written in native Typst math syntax inside $...$/$$...$$.
-- No LaTeX anywhere: Pandoc's markdown reader captures whatever is between
-- the dollar signs as a Math node's raw text without interpreting it, so
-- that text can just as well be Typst syntax as LaTeX -- this filter is
-- what actually does something with it.
--
-- On typst output: passed straight through as a raw Typst math span/block
-- (untouched -- it's already valid Typst, and Quarto's typst format needs
-- typst installed to render the document at all regardless of this filter).
-- On html output: compiled via `quarto typst compile` (the same typst
-- binary Quarto's own typst format already uses, resolved portably -- no
-- hardcoded path) into a small SVG, cached per formula under the
-- document's own _files directory, and referenced as a plain <img>.
-- On any other output (latex/pdf, docx, ...): this filter has no way to
-- turn Typst syntax into that format's own math, so it shows the same
-- short placeholder as an unavailable-Typst html render would.
--
-- Caching note: this is a hand-rolled, filter-level cache (a file-exists
-- check keyed by a hash of the formula text) -- Quarto's own execute-cache
-- / _freeze machinery only covers *code chunk execution*, not the Pandoc
-- AST pass this filter runs in, so it never sees or skips this step.

local WARNING = "[Typst math unavailable -- install Typst, or use LaTeX]"

local typst_available = nil

local function check_typst_available()
  if typst_available ~= nil then return typst_available end
  typst_available = pcall(function()
    pandoc.pipe("quarto", { "typst", "--version" }, "")
  end)
  if not typst_available then
    quarto.log.warning(
      "typst-equations.lua: `quarto typst` is not available -- math formulas will show a placeholder "
      .. "instead of rendering. Install Typst (bundled with Quarto >= 1.4), or rewrite formulas in LaTeX."
    )
  end
  return typst_available
end

local abs_cache_dir = nil
local rel_cache_dir = nil

-- quarto.doc.output_file's own directory may be absolute or relative
-- depending on how Quarto was invoked; filesystem operations (mkdir/read/
-- write) need a path resolvable from the current working directory, while
-- an <img src=...> must stay relative to the HTML file itself (same
-- convention as Quarto's own <doc>_files/figure-html/*.png references) so
-- the output stays portable if the folder is copied or moved.
local function ensure_cache_dir()
  if abs_cache_dir then return abs_cache_dir, rel_cache_dir end
  local out = quarto.doc.output_file
  local dir = out:match("(.*)[/\\][^/\\]+$") or "."
  local stem = out:match("([^/\\]+)%.[^.]+$") or out
  abs_cache_dir = dir .. "/" .. stem .. "_files/typst-equations"
  rel_cache_dir = stem .. "_files/typst-equations"
  os.execute('mkdir -p "' .. abs_cache_dir .. '"')
  return abs_cache_dir, rel_cache_dir
end

-- Wraps a formula body in a minimal, tightly-cropped, transparent-background
-- Typst document -- text size/color chosen to sit reasonably against
-- surrounding prose; both are the only things ever likely to need tuning.
local function typst_source(content, display)
  local pad = display and " " or ""
  return table.concat({
    '#set page(width: auto, height: auto, margin: 2pt, fill: none)',
    '#set text(size: 14pt)',
    '$' .. pad .. content .. pad .. '$',
  }, "\n")
end

-- Compiles `content` to an SVG file under the cache dir, keyed by a hash of
-- the formula text itself, so unchanged formulas across renders (or
-- repeated identical formulas within one document) are never recompiled.
-- Returns the path relative to the output HTML file, suitable for <img src>,
-- or nil if Typst is unavailable or this specific formula failed to compile.
local function compile_to_svg(content, display)
  if not check_typst_available() then return nil end

  local dir, rel_dir = ensure_cache_dir()
  local key = pandoc.utils.sha1(content .. (display and ":d" or ":i"))
  local svg_path = dir .. "/" .. key .. ".svg"
  local rel_path = rel_dir .. "/" .. key .. ".svg"

  local f = io.open(svg_path, "r")
  if f then
    f:close()
    return rel_path
  end

  local tmp_out = os.tmpname()
  local ok = pcall(function()
    pandoc.pipe("quarto", { "typst", "compile", "-", tmp_out, "--format", "svg" }, typst_source(content, display))
  end)

  if not ok then
    quarto.log.warning("typst-equations.lua: failed to compile formula, showing placeholder: " .. content)
    os.remove(tmp_out)
    return nil
  end

  local src = io.open(tmp_out, "r")
  if not src then
    quarto.log.warning("typst-equations.lua: no output produced for formula, showing placeholder: " .. content)
    return nil
  end
  local svg_content = src:read("*a")
  src:close()
  os.remove(tmp_out)

  local dest = io.open(svg_path, "w")
  dest:write(svg_content)
  dest:close()

  return rel_path
end

local function img_tag(content, display, path)
  local class = display and "typst-equations-display" or "typst-equations-inline"
  return '<img class="' .. class .. '" src="' .. path .. '" alt="' .. content:gsub('"', "&quot;") .. '">'
end

-- Inline context (used from Math()): must always return an Inline element.
local function html_inline(content, display)
  local path = compile_to_svg(content, display)
  if not path then
    return pandoc.RawInline("html", "<code>" .. WARNING .. "</code>")
  end
  return pandoc.RawInline("html", img_tag(content, display, path))
end

-- Block context (used from Para(), for a standalone $$...$$ line): must
-- always return a Block element.
local function html_block(content)
  local path = compile_to_svg(content, true)
  if not path then
    return pandoc.RawBlock("html", "<p><code>" .. WARNING .. "</code></p>")
  end
  return pandoc.RawBlock("html", '<p style="text-align:center">' .. img_tag(content, true, path) .. "</p>")
end

function Math(el)
  local display = el.mathtype == "DisplayMath"
  if quarto.doc.is_format("typst") then
    local pad = display and " " or ""
    return pandoc.RawInline("typst", "$" .. pad .. el.text .. pad .. "$")
  elseif quarto.doc.is_format("html") then
    return html_inline(el.text, display)
  else
    quarto.log.warning("typst-equations.lua: this output format has no Typst math support, showing placeholder")
    return pandoc.Str(WARNING)
  end
end

-- Quarto/Pandoc always wraps a standalone $$...$$ display-math line in its
-- own paragraph, so intercepting Para lets the html path replace the whole
-- paragraph with a centered image instead of leaving it as inline text.
function Para(p)
  if #p.content == 1 and p.content[1].t == "Math" and p.content[1].mathtype == "DisplayMath" then
    local m = p.content[1]
    if quarto.doc.is_format("typst") then
      return pandoc.RawBlock("typst", "$ " .. m.text .. " $")
    elseif quarto.doc.is_format("html") then
      return html_block(m.text)
    else
      quarto.log.warning("typst-equations.lua: this output format has no Typst math support, showing placeholder")
      return pandoc.Para({ pandoc.Str(WARNING) })
    end
  end
end
