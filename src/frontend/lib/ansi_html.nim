## The one AnsiUp constructor CodeTracer uses, with its escaping stated.
##
## `ansi_up` turns a recorded program's ANSI-coloured output into `<span>`
## runs, and both consumers — `ui/terminal_output.nim` (program stdout/stderr)
## and `ui/build.nim` (compiler output) — put the result into `innerHTML`.
## That is deliberate: the `<span>`s are the point.
##
## What is NOT deliberate is that the *escaping* of everything around those
## spans was a library default nobody had written down.  `ansi_up` 6.0.6
## initialises `_escape_html = true` in its constructor, so
## `<img src=x onerror=...>` in a program's output arrives at `innerHTML` as
## `&lt;img ...&gt;` and renders as text.  Turn that setter off — one line, and
## the library offers it — and every recorded program gets script execution in
## the Electron renderer.
##
## So the default is written down here instead:
##
##   * `newEscapingAnsiUp` sets `escape_html = true` explicitly.  It is the
##     only `new AnsiUp` in the product.
##   * `src/frontend/tests/htmlSinks.test.mjs` asserts the library's own
##     default is still `true` (a canary on the pin), asserts this file sets
##     it, and asserts no source anywhere sets it to `false`.
##   * The same test runs hostile program output through this converter into
##     a real DOM and asserts nothing renders.

import std/jsffi

var newAnsiUpInstance {.importcpp: "new AnsiUp".}: proc: js

proc newEscapingAnsiUp*(): js =
  ## An `AnsiUp` that escapes `& < > " '` in everything that is not an ANSI
  ## escape sequence.  This is the library's default; the assignment makes it
  ## a property of CodeTracer rather than a property of the pinned version.
  result = newAnsiUpInstance()
  result.escape_html = true

# Spelled as an `importjs` and not as `instance.ansi_to_html(raw)`, because Nim
# compares identifiers ignoring underscores and case: inside `ansiToHtml`,
# `instance.ansi_to_html(raw)` resolves to `ansiToHtml` ITSELF and recurses
# until the stack dies.  Measured, not guessed.
proc callAnsiToHtml(instance: js; raw: cstring): cstring
  {.importjs: "#.ansi_to_html(#)".}

proc ansiToHtml*(instance: js; raw: cstring): cstring =
  ## `raw` -> HTML with `<span style=...>` colour runs and everything else
  ## HTML-escaped.  Safe for `innerHTML` exactly because of the line above.
  callAnsiToHtml(instance, raw)
