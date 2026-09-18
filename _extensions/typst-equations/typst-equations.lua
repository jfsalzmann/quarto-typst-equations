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
  -- pandoc.system.make_directory instead of `os.execute('mkdir -p ...')`: the latter shells out to `mkdir -p`, a Unix-only flag Windows' cmd.exe mkdir doesn't understand.
  pcall(pandoc.system.make_directory, abs_cache_dir, true)
  return abs_cache_dir, rel_cache_dir
end

-- Workaround for upstream typst auto-sized document for inline formulas issue typst/typst#1028: inline math under-reports its own ascent/descent, so `page(height: auto)` clips tall formulas -- give inline math a generous margin here and crop it to its real ink with crop_to_ink() below.
local function typst_source(content, display)
  local pad = display and " " or ""
  local margin = display and "2pt" or "40pt"
  return table.concat({
    '#set page(width: auto, height: auto, margin: ' .. margin .. ', fill: none)',
    '#set text(size: 14pt)',
    '$' .. pad .. content .. pad .. '$',
  }, "\n")
end

-- Tokenizes an SVG path `d` attribute into a stream of single-letter
-- commands and numbers, handling commands and numbers butted up against
-- each other with no separating space/comma (valid, and common in Typst's
-- compact path output, e.g. "9.562h" or "-0.322c").
local function tokenize_path(d)
  local tokens = {}
  local i, n = 1, #d
  while i <= n do
    local c = d:sub(i, i)
    if c:match("[MmLlHhVvCcSsQqTtAaZz]") then
      tokens[#tokens + 1] = c
      i = i + 1
    elseif c:match("[%-%.%d]") then
      local j = i
      if d:sub(j, j) == "-" then j = j + 1 end
      while d:sub(j, j):match("%d") do j = j + 1 end
      if d:sub(j, j) == "." then
        j = j + 1
        while d:sub(j, j):match("%d") do j = j + 1 end
      end
      tokens[#tokens + 1] = tonumber(d:sub(i, j - 1))
      i = j
    else
      i = i + 1 -- whitespace/commas/anything else between tokens
    end
  end
  return tokens
end

-- Walks a path's tokens and returns every point the pen visits, including
-- Bezier control points (not just on-curve points). A cubic/quadratic curve
-- always lies within the convex hull of its control polygon, so the bbox of
-- these points is a safe over-estimate of the true inked area -- it can
-- over-crop-pad slightly but can never clip a curve that bulges past its
-- endpoints, which is exactly the failure mode being fixed here.
local function path_points(d)
  local tokens = tokenize_path(d)
  local i, n = 1, #tokens
  local cx, cy, sx, sy = 0, 0, 0, 0
  local pts = {}
  local function pt(x, y)
    pts[#pts + 1] = { x, y }
  end
  local cmd = nil
  while i <= n do
    if type(tokens[i]) == "string" then
      cmd = tokens[i]
      i = i + 1
    end
    if cmd == "M" or cmd == "m" then
      local first = true
      while i <= n and type(tokens[i]) ~= "string" do
        local x, y = tokens[i], tokens[i + 1]
        i = i + 2
        if cmd == "m" then cx, cy = cx + x, cy + y else cx, cy = x, y end
        pt(cx, cy)
        if first then sx, sy = cx, cy; first = false end
        cmd = (cmd == "M") and "L" or "l" -- extra pairs after M/m are implicit lineto
      end
    elseif cmd == "L" or cmd == "l" then
      while i <= n and type(tokens[i]) ~= "string" do
        local x, y = tokens[i], tokens[i + 1]
        i = i + 2
        if cmd == "l" then cx, cy = cx + x, cy + y else cx, cy = x, y end
        pt(cx, cy)
      end
    elseif cmd == "H" or cmd == "h" then
      while i <= n and type(tokens[i]) ~= "string" do
        local x = tokens[i]
        i = i + 1
        if cmd == "h" then cx = cx + x else cx = x end
        pt(cx, cy)
      end
    elseif cmd == "V" or cmd == "v" then
      while i <= n and type(tokens[i]) ~= "string" do
        local y = tokens[i]
        i = i + 1
        if cmd == "v" then cy = cy + y else cy = y end
        pt(cx, cy)
      end
    elseif cmd == "C" or cmd == "c" then
      while i <= n and type(tokens[i]) ~= "string" do
        local x1, y1, x2, y2, x, y = tokens[i], tokens[i + 1], tokens[i + 2], tokens[i + 3], tokens[i + 4], tokens[i + 5]
        i = i + 6
        local p1, p2
        if cmd == "c" then
          p1, p2 = { cx + x1, cy + y1 }, { cx + x2, cy + y2 }
          cx, cy = cx + x, cy + y
        else
          p1, p2 = { x1, y1 }, { x2, y2 }
          cx, cy = x, y
        end
        pt(p1[1], p1[2]); pt(p2[1], p2[2]); pt(cx, cy)
      end
    elseif cmd == "S" or cmd == "s" or cmd == "Q" or cmd == "q" then
      while i <= n and type(tokens[i]) ~= "string" do
        local x1, y1, x, y = tokens[i], tokens[i + 1], tokens[i + 2], tokens[i + 3]
        i = i + 4
        local p1
        if cmd == "s" or cmd == "q" then
          p1 = { cx + x1, cy + y1 }
          cx, cy = cx + x, cy + y
        else
          p1 = { x1, y1 }
          cx, cy = x, y
        end
        pt(p1[1], p1[2]); pt(cx, cy)
      end
    elseif cmd == "T" or cmd == "t" then
      while i <= n and type(tokens[i]) ~= "string" do
        local x, y = tokens[i], tokens[i + 1]
        i = i + 2
        if cmd == "t" then cx, cy = cx + x, cy + y else cx, cy = x, y end
        pt(cx, cy)
      end
    elseif cmd == "A" or cmd == "a" then
      -- Arcs never appear in Typst's glyph/rule output, but handle them
      -- defensively: bound by a square of the larger radius around both
      -- endpoints, which safely over-estimates any arc's extent.
      while i <= n and type(tokens[i]) ~= "string" do
        local rx, ry, x, y = tokens[i], tokens[i + 1], tokens[i + 5], tokens[i + 6]
        i = i + 7
        local ex, ey
        if cmd == "a" then ex, ey = cx + x, cy + y else ex, ey = x, y end
        local r = math.max(rx, ry)
        pt(cx - r, cy - r); pt(cx + r, cy + r)
        pt(ex - r, ey - r); pt(ex + r, ey + r)
        cx, cy = ex, ey
      end
    elseif cmd == "Z" or cmd == "z" then
      -- Zero-argument command: the top-of-loop command check already
      -- consumed the "Z"/"z" token itself, so no further advance here --
      -- an extra `i = i + 1` would skip the very next token, which for any
      -- glyph with an enclosed counter (0, 8, p, e, a, g, q, b, d, o, ...)
      -- is the moveto that starts the inner subpath, silently corrupting
      -- every point after it.
      cx, cy = sx, sy
    else
      i = i + 1
    end
  end
  return pts
end

-- Computes the true ink bounding box (in the SVG's own coordinate space) of
-- every glyph/rule Typst drew, by reading its <symbol><path> defs and the
-- <g transform=matrix(...)><use> instances that place them, and mapping
-- each symbol's point bbox through its placement matrix. Returns nil if the
-- SVG doesn't match the structure Typst's SVG export always produces (so
-- the caller can fall back to the uncropped, generously-margined render
-- instead of risking a bad crop).
local function ink_bbox(svg)
  local sym_bbox = {}
  for id, d in svg:gmatch('<symbol id="([^"]+)"[^>]*><path d="([^"]*)"') do
    local pts = path_points(d)
    if #pts > 0 then
      local minx, miny, maxx, maxy = pts[1][1], pts[1][2], pts[1][1], pts[1][2]
      for _, p in ipairs(pts) do
        if p[1] < minx then minx = p[1] end
        if p[1] > maxx then maxx = p[1] end
        if p[2] < miny then miny = p[2] end
        if p[2] > maxy then maxy = p[2] end
      end
      sym_bbox[id] = { minx, miny, maxx, maxy }
    end
  end

  local gminx, gminy, gmaxx, gmaxy = math.huge, math.huge, -math.huge, -math.huge
  local found = false
  for mat, id in svg:gmatch('<g transform="matrix%(([^)]+)%)"><use xlink:href="#([^"]+)"') do
    local a, b, c, dd, e, f = mat:match("(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
    local bb = sym_bbox[id]
    if a and bb then
      a, b, c, dd, e, f = tonumber(a), tonumber(b), tonumber(c), tonumber(dd), tonumber(e), tonumber(f)
      local minx, miny, maxx, maxy = bb[1], bb[2], bb[3], bb[4]
      local corners = { { minx, miny }, { minx, maxy }, { maxx, miny }, { maxx, maxy } }
      for _, p in ipairs(corners) do
        local nx = a * p[1] + c * p[2] + e
        local ny = b * p[1] + dd * p[2] + f
        if nx < gminx then gminx = nx end
        if nx > gmaxx then gmaxx = nx end
        if ny < gminy then gminy = ny end
        if ny > gmaxy then gmaxy = ny end
      end
      found = true
    end
  end
  if not found then return nil end
  return gminx, gminy, gmaxx, gmaxy
end

-- 1pt of slack beyond the measured ink bbox -- since that bbox is already a
-- safe over-estimate (control points, not the tighter true curve), this is
-- just a little visual breathing room, not a clipping safety margin.
local CROP_PAD = 1.0

-- Rewrites the SVG's viewBox/width/height to crop tightly to its own ink,
-- computed from the actual rendered geometry rather than assumed from page
-- metrics -- works for any formula complexity (matrices, big operators,
-- deep nesting) without per-case tuning. Leaves the svg untouched (falls
-- back to the generously-margined compile) if the bbox can't be determined.
local function crop_to_ink(svg)
  local minx, miny, maxx, maxy = ink_bbox(svg)
  if not minx then return svg end

  minx = minx - CROP_PAD
  miny = miny - CROP_PAD
  local w = (maxx + CROP_PAD) - minx
  local h = (maxy + CROP_PAD) - miny

  local head_start, head_end = svg:find('^<svg viewBox="[^"]*" width="[^"]*" height="[^"]*"')
  if not head_start then return svg end

  local new_header = string.format('<svg viewBox="%g %g %g %g" width="%gpt" height="%gpt"', minx, miny, w, h, w, h)
  return new_header .. svg:sub(head_end + 1)
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

  -- Workaround for upstream pandoc tmp dir issue jgm/pandoc#10946: os.tmpname() crashes pandoc.exe on Windows, so use pandoc.system.with_temporary_directory instead.
  local svg_content = pandoc.system.with_temporary_directory("typst-equations", function(tmpdir)
    local tmp_out = tmpdir .. "/out.svg"
    local ok = pcall(function()
      pandoc.pipe("quarto", { "typst", "compile", "-", tmp_out, "--format", "svg" }, typst_source(content, display))
    end)
    if not ok then
      quarto.log.warning("typst-equations.lua: failed to compile formula, showing placeholder: " .. content)
      return nil
    end
    local src = io.open(tmp_out, "r")
    if not src then
      quarto.log.warning("typst-equations.lua: no output produced for formula, showing placeholder: " .. content)
      return nil
    end
    local data = src:read("*a")
    src:close()
    return data
  end)

  if not svg_content then return nil end

  -- Only inline math needs the ink crop (see typst_source's comment) --
  -- display math is already correctly sized by Typst itself.
  local dest = io.open(svg_path, "w")
  dest:write(display and svg_content or crop_to_ink(svg_content))
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
