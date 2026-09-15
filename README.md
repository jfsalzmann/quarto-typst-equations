# typst-equations

A [Quarto](https://quarto.org) filter extension that lets you write math
formulas in native [Typst](https://typst.app) math syntax inside
`$...$` / `$$...$$` delimiters instead of LaTeX, and have them
render correctly in both HTML and Typst-PDF output from the same source.

## Why?

Quarto's `typst` format converts LaTeX math to Typst math
automatically, but this means we may have to mix Latex and Typst code
in the same doc. Here, we sidestep the built-in handling and conversion
to get a full Typst experience, in both HTML and Typst/PDF output.

## What it does, by output format:

- **`typst`**: the formula text is passed straight through as raw Typst
  math (inline `$...$` or a padded display `$ ... $`) — no compilation
  needed, Typst is assumed to be available.
- **`html`**: each formula is compiled via `quarto typst compile` into a
  small SVG, cached under the document's `<doc>_files/typst-equations/`
  directory (keyed by a hash of the formula text, with unchanged formulas
  across renders never being recompiled), and embedded as a vector `<img>`.
- **Any other format or Typst unavailable** (e.g. some mistaken
  `format: pdf` using LaTeX, `docx`, or an older Quarto version): a short
  placeholder is shown along with a render-time warning (`quarto.log.warning`)
  suggesting to remove the filter for that format.

## Install

```bash
quarto add jfsalzmann/quarto-typst-equations
```

This installs the extension under `_extensions/typst-equations/` in your
current project.

## Use

Add the filter either to a single document's YAML header:

```yaml
filters:
  - typst-equations
```

or, to enable it project-wide, at the **top level** of `_quarto.yml`:

```yaml
filters:
  - typst-equations
```

(Do not nest it under a specific `format:` key — this would only
cover that one format, and a stray future format switch would
silently bypass the filter, producing render issues with Latex
formulas expected where you have used Typst Math.)

Then write formulas in Typst math syntax. A few of the more common
LaTeX → Typst swaps:

| LaTeX | Typst |
|---|---|
| `\sim` | `tilde.op` |
| `\mathcal{N}` | `cal(N)` |
| `\text{Binomial}` | `"Binomial"` |
| `\frac{a}{b}` | `a/b` or `frac(a, b)` |
| `\le`, `\ge` | `<=`, `>=` |
| `\Phi^{-1}` | `Phi^(-1)` |
| `\bar{X}` | `macron(X)` |
| `\quad` | `quad` |
| `f^{\text{Bin}}` | `f^upright("Bin")` |

See `example.qmd` in this repo (render it with `quarto render
example.qmd` after installing/vendoring the extension) for a worked
example of both inline and display math in both output formats.

## Notes

- No LaTeX involvement in either output path — the `html` path never
  touches MathJax/KaTeX for filtered formulas, and the `typst` path never
  goes through Pandoc's LaTeX math parser.
- No external dependencies beyond Quarto itself (>= 1.4, for the bundled
  Typst toolchain) — the filter uses only `pandoc.pipe`, `pandoc.utils`,
  and `quarto.log`/`quarto.doc`, all part of Quarto's own Lua filter
  environment.
- The per-formula SVG cache is a simple file-existence check, not
  integrated with Quarto's own `execute`/`freeze` caching — that only
  covers code-chunk execution, not the Pandoc filter pass this runs in.
- Independent of any other extension or template — it only defines
  `Math`/`Para` Lua filter functions, nothing format- or
  project-specific.

## License

MIT — see [LICENSE](LICENSE).
