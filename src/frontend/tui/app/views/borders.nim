## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/borders.nim — CTUI-11. The Unicode and ASCII glyph sets, and the
## one table that maps between them.
##
## ## What §6.3 asks for, and what a terminal front-end actually draws
##
## §6.3 names two sets: `┌`, `─`, `│`, `└`, `▼`, `●` when UTF-8 is available,
## and `+`, `-`, `|`, `*`, `>` when it is not. Both are published below in
## full. Two facts about how they are used are recorded here rather than
## discovered later:
##
## 1. **This shell draws RULES AND SEPARATORS, not boxes.** `app/views/shell.nim`
##    paints a pane's title row as `SOURCE ─────` and its right-hand edge as a
##    column of `│`; no view in this tree draws a corner. So `┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼`
##    and their ASCII counterpart `+` are published, are covered by
##    `asciiFor`, and DO NOT APPEAR on a CodeTracer TUI screen today. That is
##    stated because the alternative — quietly publishing a corner nobody
##    paints — is how a table stops describing the product.
## 2. **The ASCII set is larger than the five characters §6.3 lists.** The
##    §6.3 list covers a border and one marker; this front-end distinguishes a
##    verified breakpoint from a disabled one from a tracepoint, an expanded
##    tree node from a collapsed one, and a timeline needle from a span. Folding
##    those onto one `*` would break CTUI-11's own contract — degradation never
##    removes information — so the set adds `o`, `v`, `^`, `#`, `.` and `:`.
##    Every one of the five §6.3 characters is still what it says it is.
##
## ## Why the mapping is a TABLE and not a transliteration
##
## `asciiFor` translates a fixed list of CHROME glyphs and nothing else. It is
## deliberately not "replace every non-ASCII rune", because a screen carries
## program text as well as furniture: a Python identifier, a string literal or
## a recorded path may hold any codepoint, and a blanket transliteration would
## corrupt the one thing on the screen the user cannot re-derive. A non-UTF-8
## terminal will mis-render such a rune, and that is the terminal's limit rather
## than something this table may paper over by changing the data.
##
## ## Widths
##
## EVERY GLYPH IN BOTH SETS IS EXACTLY ONE CELL WIDE, and the pairs in `asciiFor`
## are one-cell-to-one-cell. That is not incidental: the degradation pass in
## `app/theme/degradation.nim` rewrites runes inside an already-composited grid,
## where a substitution of a different width would shift every column after it.
## `app/tests/test_degraded_style_tables.nim` asserts the width equality over
## the whole table rather than trusting this paragraph.

import std/tables

import ../theme/capabilities

export capabilities

type
  BorderSet* = object
    ## One complete glyph set. A value rather than a module of constants so a
    ## view takes the set it was handed instead of asking which mode is
    ## current — the same reason `TerminalCapabilities` is one value.
    topLeft*: string
    topRight*: string
    bottomLeft*: string
    bottomRight*: string
    horizontal*: string
      ## The rule a pane title trails, and the timeline's track.
    vertical*: string
      ## The column a pane draws on its right-hand edge.
    teeLeft*: string
    teeRight*: string
    teeTop*: string
    teeBottom*: string
    cross*: string
    breakpoint*: string
      ## §3.3.2's verified breakpoint dot.
    breakpointDisabled*: string
    tracepoint*: string
    collapsed*: string
      ## §3.3.3's collapsed tree node.
    expanded*: string
    needle*: string
      ## §3.3.5's execution marker on the timeline scrubber.
    span*: string
      ## The timeline's call-span fill.
    ellipsis*: string
      ## What a truncated field ends with. ONE CELL in both sets — `...` would
      ## be three and would not fit where the Unicode glyph did.
    dotFill*: string
    dashFill*: string

const
  UnicodeBorders* = BorderSet(
    topLeft: "┌", topRight: "┐", bottomLeft: "└", bottomRight: "┘",
    horizontal: "─", vertical: "│",
    teeLeft: "├", teeRight: "┤", teeTop: "┬", teeBottom: "┴", cross: "┼",
    breakpoint: "●", breakpointDisabled: "○", tracepoint: "◆",
    collapsed: "▶", expanded: "▼",
    needle: "▲", span: "█",
    ellipsis: "…", dotFill: "·", dashFill: "┊")
    ## The set every pane in this tree already paints — `shell.PaneRuleGlyph`,
    ## `shell.PaneSeparatorGlyph`, `gutter.BreakpointGlyph`,
    ## `tree_node.CollapsedGlyph`, `timeline_bar.NeedleGlyph` and the rest are
    ## exactly these runes. Collected here rather than re-spelled, so the
    ## degradation table below and the views cannot disagree about what a
    ## Unicode screen shows; `app/tests/test_degraded_style_tables.nim` asserts
    ## the equality against those published constants.

  AsciiBorders* = BorderSet(
    topLeft: "+", topRight: "+", bottomLeft: "+", bottomRight: "+",
    horizontal: "-", vertical: "|",
    teeLeft: "+", teeRight: "+", teeTop: "+", teeBottom: "+", cross: "+",
    breakpoint: "*", breakpointDisabled: "o", tracepoint: "+",
    collapsed: ">", expanded: "v",
    needle: "^", span: "#",
    ellipsis: ".", dotFill: ".", dashFill: ":")
    ## §6.3's fallback. `+`, `-`, `|`, `*` and `>` are the five the section
    ## names, at the five meanings it gives them; the rest exist because this
    ## front-end has more states than one marker can carry. See the module
    ## header.

proc borderSet*(mode: BorderMode): BorderSet =
  ## The set for a resolved border mode. The one place a `BorderMode` becomes
  ## glyphs.
  case mode
  of bmUnicode: UnicodeBorders
  of bmAscii: AsciiBorders

proc borderSet*(caps: TerminalCapabilities): BorderSet =
  ## The set for a whole resolved capability value, for a caller that has one.
  borderSet(caps.borders)

const AsciiFallbacks: array[21, (string, string)] = [
  # THE ORDER IS THE ORDER OF `BorderSet`'S FIELDS, plus the box-drawing
  # weights no field names. Written as a pair list rather than derived by
  # walking the two objects because a field-by-field walk would map
  # `tracepoint` and `cross` onto the same key and silently drop one.
  ("┌", "+"), ("┐", "+"), ("└", "+"), ("┘", "+"),
  ("├", "+"), ("┤", "+"), ("┬", "+"), ("┴", "+"), ("┼", "+"),
  ("─", "-"), ("│", "|"),
  # The heavy and double weights. Nothing in this tree paints them today; they
  # are here because a Unicode screen that acquired one would otherwise pass
  # straight through the ASCII pass and land on a terminal that cannot show it,
  # which is the failure mode this table exists to prevent.
  ("━", "-"), ("═", "-"), ("┃", "|"), ("║", "|"),
  ("●", "*"), ("○", "o"), ("◆", "+"),
  ("▶", ">"), ("▼", "v"), ("▲", "^")]

const ExtraAsciiFallbacks: array[3, (string, string)] = [
  ("█", "#"), ("…", "."), ("·", ".")]

var asciiTable {.compileTime.}: Table[string, string]

const AsciiFallbackTable* = block:
  ## Every Unicode chrome glyph this tree can paint, and its one-cell ASCII
  ## stand-in. Built at compile time so the lookup below is a hash rather than
  ## a scan, and exported so a test can assert its SIZE — a mapping that lost
  ## an entry would otherwise present as one un-degraded glyph on a screen
  ## nobody was reading.
  var t = initTable[string, string]()
  for pair in AsciiFallbacks:
    t[pair[0]] = pair[1]
  for pair in ExtraAsciiFallbacks:
    t[pair[0]] = pair[1]
  t["┊"] = ":"
  t

proc asciiFor*(rune: string): string =
  ## The ASCII stand-in for one chrome glyph, or the rune unchanged.
  ##
  ## UNCHANGED IS THE COMMON CASE and is the point: this is applied to every
  ## cell of a composited screen, and the cells that are not chrome are program
  ## text. See the module header on why this is a table and not a rule.
  AsciiFallbackTable.getOrDefault(rune, rune)

proc glyphFor*(rune: string; mode: BorderMode): string =
  ## `rune` as this border mode spells it.
  case mode
  of bmUnicode: rune
  of bmAscii: asciiFor(rune)
