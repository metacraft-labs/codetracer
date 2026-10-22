## Text that is about to be handed to an HTML parser.
##
## Some sinks in the front ends take a STRING OF MARKUP and nothing else:
## a DataTables column `render` callback's return value is inserted as HTML
## (https://datatables.net/reference/option/columns.render), and a few views
## build `innerHTML` deliberately because the markup around the text is the
## point. When such a string carries text the program under replay wrote —
## its output, a file name it opened, a line of its source — that text is not
## markup and must reach the parser escaped.
##
## Pure Nim with no imports, so the JS front end, the native view-model tests
## and any other consumer can share the one implementation.

proc escapeHtmlText*(text: string): string =
  ## The five characters that must not reach `innerHTML` as markup.
  ##
  ## `&` first, or every entity this proc writes gets its own `&` escaped a
  ## second time and the pane renders `&amp;lt;` where a user wrote `<`.
  ## `"` and `'` are escaped as well as `<`, `>` and `&` so the result is
  ## also safe inside a quoted attribute value
  ## (https://html.spec.whatwg.org/multipage/syntax.html#attributes-2).
  result = newStringOfCap(text.len + 16)
  for ch in text:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#39;"
    else: result.add ch
