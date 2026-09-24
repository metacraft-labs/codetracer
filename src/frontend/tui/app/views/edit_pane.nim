## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/edit_pane.nim — PLAT-16. The Source pane **in Edit mode**.
##
## ## THIS IS A SECOND PANE, AND THAT IS §2.1 CONSEQUENCE 1 RATHER THAN A
## ## DUPLICATION
##
## CodeTracer-TUI-Edit-Mode.md §2.1: *"**Edit mode does not use `SourceVM`.**
## It is a read-only window over a possibly-remote, revision-identified
## artifact. An editor needs a whole mutable buffer with undo. Reusing
## `SourceVM` would mean adding mutation to the type whose entire purpose is to
## serve a revision faithfully."*
##
## So `SourcePaneModel` is not reused either: its `heldLines` IS the window
## contract, its `firstHeldLine` exists because a line outside the window is a
## REQUEST, and neither is true of a file the user has open in an editor. A
## model with `heldLines` covering the whole file would be a window-shaped type
## carrying something that is not a window, and the next reader would have to
## work out which of its invariants still hold.
##
## ## WHAT *IS* REUSED, AND IT IS THE PART THE SPECIFICATION NAMES
##
## §3: *"that widget bound to a working-tree buffer, with the gutter reused
## from Debug mode minus the execution pointer (there is no execution).
## Breakpoint markers stay."*
##
##   * **The gutter** is `views/gutter.gutterRow`, the same function, with
##     `isExecutionLine` and `isInspectionLine` false on every line. The
##     pointer FIELD is still three cells wide (`NoPointerGlyph`), so the code
##     column sits at the same screen x in both modes and a mode switch does
##     not slide the text sideways. `test_edit_mode_source.nim` asserts that
##     equality across the switch.
##   * **The syntax highlighter** is `app/syntax/highlighter`, the same
##     tree-sitter path the Debug pane uses.
##   * **The marks** are the same `GutterMark` values from the same point list.
##
## ## THE NUMBER COLUMN'S STYLE IS SUPPLIED, NOT DERIVED FROM A PROVENANCE
##
## `gutterRow` tints the number field from `GutterProvenance` when no style is
## given. Edit mode gives one. §2's table: *"working tree is the subject;
## provenance is not a concept"* — so answering `gpUnverified` here would print
## a yellow "this might not be what ran" tint over a file the user is editing
## on purpose, which is a true statement about a recording and a false one
## about an editor. A fourth `GutterProvenance` value was the alternative and
## was declined: it would have put a value meaning "not applicable" into an
## enum every other consumer reads as a three-way answer.
##
## ## A PURE FUNCTION OF A VALUE, exactly as `source_pane.nim` is
##
## `app/edit_binding.nim` owns the editing document and produces one of these
## per frame. Nothing here mutates a buffer, and nothing here knows a widget
## exists — which is what lets the whole pane be asserted with no editor and no
## terminal.
##
## *This sentence read "owns the `TextAreaWidget`" until the editing core
## landed, and by then that module held no widget at all — a claim in a comment
## is a claim nothing re-takes. The second half was true the whole time and is
## more true now: there is no widget on this front-end's editing path.*

import ../layout/profile
import ../syntax/highlighter
import ./gutter
# `source_pane` is imported for ONE symbol — `tokenStyle`, the nine-colour
# token palette §3.3.2 specifies. Edit mode and Debug mode must colour Nim's
# `proc` keyword identically or a mode switch would repaint the file; one
# palette is how that is guaranteed rather than checked.
import ./source_pane
import ./styled_row

export gutter, styled_row, highlighter, profile

type
  EditPaneModel* = object
    ## Everything the edit pane shows, as a value.
    path*: string
      ## The WORKING-TREE path of the open file. Absolute or project-relative
      ## as the host resolved it; the pane shows the basename.
    sourceStatement*: string
      ## §2's Requirement: *"The Source pane states which mode's source it is
      ## showing, **always**."* Filled from
      ## `product_mode.sourceStatementFor(pmEdit)` by the binding, never
      ## spelled here — a second copy of that sentence in a view is a second
      ## thing that can disagree with the core's answer.
    lines*: seq[string]
      ## The file's lines from `linesFrom` on — the WHOLE FILE when
      ## `totalLines` is 0 (a model built from a string, as the suites do),
      ## and only the rows the pane can draw when the binding fills it.
      ##
      ## A WINDOW SINCE 2026-09-23, and measured: splitting a 24,000-line
      ## buffer into a `seq[string]` for every frame cost ~65 ms on its own,
      ## and `runtime.sourcePaneRows` builds this model too, so a keystroke
      ## paid it twice before a byte was painted. The pane draws a screen; the
      ## model now holds one.
    linesFrom*: int
      ## 1-based line number of `lines[0]`; `0` means `1`.
    totalLines*: int
      ## How many lines the file has; `0` means `lines.len` (the whole file
      ## is in `lines`).
    viewportTop*: int
      ## 1-based first line shown.
    caretLine*: int
      ## 1-based line the caret is on, or 0 for none.
    caretColumn*: int
      ## 0-based grapheme-cluster column of the caret within its line.
    selectionActive*: bool
    dirty*: bool
      ## Whether the buffer differs from what was loaded. Shown in the title as
      ## a marker, because Mode-Transitions.md §5 requires an unsaved buffer to
      ## SURVIVE a mode switch and a user cannot be expected to remember which
      ## of two files they have not written.
    marks*: seq[(int, GutterMark)]
    language*: string
      ## The grammar id for the highlighter, derived by the binding from the
      ## file extension.
    spans*: seq[seq[SyntaxSpan]]
      ## PLAT-29. The syntax spans to draw, for the lines from `spansFrom` on,
      ## as the ASYNCHRONOUS producer left them
      ## (`syntax/highlight_producer.spansForWindow`): the current parse, or
      ## the lines reconciliation let through, or none. When `spansProvided`
      ## this pane draws exactly these and PARSES NOTHING — §11: the render
      ## path does not wait on a parse.
    spansFrom*: int
    spansProvided*: bool

  EditPaneScreen* = object
    ## One painted pane, plus the counts a test asserts on. Same shape as
    ## `SourcePaneScreen` so a cross-mode assertion compares like with like.
    rows*: seq[StyledRow]
    area*: CellArea
    gutterWidth*: int
    codeWidth*: int
    renderedLines*: int
      ## Source lines this frame actually drew.
    caretRow*: int
      ## Screen row the caret landed on, or -1 when it is off screen. Reported
      ## rather than recomputed by a caller, because the host has to park the
      ## real terminal cursor there and two derivations of one coordinate is
      ## how a cursor ends up one row from the character it is editing.
    caretCol*: int

const
  EditPaneTitle* = "EDIT"
    ## The title's first word, and DELIBERATELY NOT `SOURCE`.
    ##
    ## Mode-Transitions.md §7: *"The mode is legible from the window without
    ## invoking anything. Which panes are present is the primary signal."* The
    ## status line's `[EDIT]` indicator is one signal and the pane's own title
    ## is the second, and a reader looking at the middle of the screen sees
    ## only the second.

  DirtyMarker* = "[+]"
    ## Vim's own spelling of a modified buffer, for a front-end whose input
    ## model is Vim's.
  CleanMarker* = ""

  EditLineNumberStyle* = CellStyle(fg: "bright_black")
    ## Deliberately the SAME cells as `gutter.VerifiedLineNumberStyle`.
    ##
    ## Not an oversight and not a reuse of the constant: the two say different
    ## things that happen to look the same. "This is the recording's own copy"
    ## and "this is the file you are editing" are both states in which the text
    ## on screen is exactly what it claims to be, and neither warrants the
    ## warning tint. Naming it separately is what lets one change without the
    ## other.

  EditCaretLineBackground* = "black"
    ## The caret's row, tinted as a whole. Debug mode tints the execution
    ## line; Edit mode has no execution, so the row worth tinting is the one
    ## the user is typing on.

  EditTitleStyle* = CellStyle(fg: "bright_yellow", bold: true)
  EditPathStyle* = CellStyle(fg: "white")
  EditDirtyStyle* = CellStyle(fg: "yellow", bold: true)
  EditStatementStyle* = CellStyle(fg: "bright_black", italic: true)
  EditRuleStyle* = CellStyle(fg: "bright_black")
  EditPaneRule* = "─"

proc initEditPaneModel*(path = ""; sourceStatement = "";
                        lines: seq[string] = @[]; viewportTop = 1;
                        caretLine = 0; caretColumn = 0;
                        selectionActive = false; dirty = false;
                        marks: seq[(int, GutterMark)] = @[];
                        language = ""): EditPaneModel =
  EditPaneModel(path: path, sourceStatement: sourceStatement, lines: lines,
                viewportTop: viewportTop, caretLine: caretLine,
                caretColumn: caretColumn, selectionActive: selectionActive,
                dirty: dirty, marks: marks, language: language)

proc isEmpty*(model: EditPaneModel): bool =
  ## Whether the pane has a file at all. An Edit-mode session with no file open
  ## is an ordinary state — the user has just opened a project — and it is
  ## distinct from a file that is empty.
  model.path.len == 0

proc lineCount*(model: EditPaneModel): int =
  if model.totalLines > 0: model.totalLines else: model.lines.len

proc lineAt*(model: EditPaneModel; line: int): string =
  ## The text of a 1-based line, or "" for one outside what the model holds.
  let idx = line - max(1, model.linesFrom)
  if idx < 0 or idx >= model.lines.len: "" else: model.lines[idx]

proc markFor*(model: EditPaneModel; line: int): GutterMark =
  ## The gutter mark on `line`. LAST DECLARATION WINS, the same rule
  ## `source_pane.markFor` states and for the same reason: a line carrying both
  ## a breakpoint and a tracepoint has one cell, and `●` is the one that stops.
  result = gmNone
  for (line2, mark) in model.marks:
    if line2 == line:
      result = mark

proc paneGutterWidth*(model: EditPaneModel): int =
  gutterWidth(gutterNumberWidth(max(1, model.lineCount)))

# `pathBaseName` IS `styled_row`'s, NOT A SECOND ONE. The first draft of this
# module declared its own and `test_call_stack_navigation.nim` went red with
# `ambiguous call` — which is the import graph saying, correctly, that two
# procedures answering one question is one too many. Both modules are
# re-exported by `shell.nim`, so a consumer would have had to qualify a call
# that has exactly one right answer.

proc titleRowSpans*(model: EditPaneModel; width: int): StyledRow =
  ## The title row as styled spans, exactly `width` cells wide.
  ##
  ## FOUR FIELDS AND THE THIRD IS THE REQUIREMENT: `EDIT`, the basename, the
  ## dirty marker, and `model.sourceStatement`. §2's Requirement asks the pane
  ## to state which mode's source it is showing ALWAYS, and this is where it
  ## says it. When the terminal is too narrow the statement is what goes first,
  ## which is `truncateToCells` doing the deciding rather than a branch here —
  ## the path and the dirty marker are what a user needs to not lose work.
  result = @[]
  if width <= 0:
    return
  var parts: seq[StyledSpan] = @[]
  parts.add StyledSpan(text: EditPaneTitle, style: EditTitleStyle)
  let base = pathBaseName(model.path)
  if base.len > 0:
    parts.add StyledSpan(text: " " & base, style: EditPathStyle)
  if model.dirty:
    parts.add StyledSpan(text: " " & DirtyMarker, style: EditDirtyStyle)
  if model.sourceStatement.len > 0:
    parts.add StyledSpan(text: " — " & model.sourceStatement,
                         style: EditStatementStyle)
  var used = 0
  for part in parts:
    if used >= width:
      break
    let fitted = truncateToCells(part.text, width - used)
    if fitted.len == 0:
      continue
    result.add StyledSpan(text: fitted, style: part.style)
    used += cellWidthOf(fitted)
  if used < width:
    result.add StyledSpan(text: " ", style: DefaultCellStyle)
    inc used
  if used < width:
    result.add StyledSpan(text: repeatGlyph(EditPaneRule, width - used),
                          style: EditRuleStyle)

proc titleRowText*(model: EditPaneModel; width: int): string =
  rowText(titleRowSpans(model, width))

proc paintEditPane*(g: var StyledGrid; area: CellArea; model: EditPaneModel;
                    cache: HighlighterCache = nil): EditPaneScreen =
  ## Paint the pane into `area` of `g`, and report what it painted.
  result = EditPaneScreen(rows: @[], area: area, gutterWidth: 0, codeWidth: 0,
                          renderedLines: 0, caretRow: -1, caretCol: -1)
  if area.width <= 0 or area.height <= 0:
    return

  let gw = paneGutterWidth(model)
  let numberWidth = gutterNumberWidth(max(1, model.lineCount))
  result.gutterWidth = gw
  result.codeWidth = max(0, area.width - gw)

  # Row 0 is the title; the body starts at row 1. Same split as the Debug pane,
  # so the two modes' first code row is the same screen row.
  var at = area.row
  var titleSpans = titleRowSpans(model, area.width)
  var x = area.col
  for span in titleSpans:
    g.paint(at, x, span.text, span.style)
    x += cellWidthOf(span.text)
  result.rows.add titleSpans
  inc at

  let bodyRows = area.height - 1
  if bodyRows <= 0:
    return
  let codeW = result.codeWidth

  # WITH SPANS PROVIDED (the product path, since PLAT-29) NOTHING IS PARSED
  # HERE: the producer ran off the render path and the model carries what it
  # left. Without them — a pane drawn from a model somebody built by hand —
  # the window is parsed the way it always was, below.
  #
  # THE VISIBLE WINDOW ONLY IS PARSED, even though the model holds the whole
  # file. `highlightWindow` is the same entry point the Debug pane uses and it
  # takes a window; handing it a ten-thousand-line buffer on every frame would
  # make an editor's scroll cost grow with the file rather than with the
  # screen. The whole file is in the MODEL because an editor needs it; it is
  # not in the PARSE because a frame does not.
  var window: seq[string] = @[]
  let firstVisible = max(1, model.viewportTop)
  if not model.spansProvided:
    for i in 0 ..< bodyRows:
      let line = firstVisible + i
      if line >= 1 and line <= model.lineCount:
        window.add model.lineAt(line)
  let file =
    if model.spansProvided:
      FileHighlight(mode: hmNone, firstLine: model.spansFrom,
                    lines: model.spans)
    elif cache.isNil:
      highlightWindow(model.path, firstVisible, window)
    else:
      cache.highlight(model.path, 0, "", firstVisible, window)

  for i in 0 ..< bodyRows:
    let line = model.viewportTop + i
    let row = at + i
    if line < 1 or line > model.lineCount:
      # PAST THE END OF THE FILE. Blank, and blank is CORRECT here in a way it
      # never is in the Debug pane: `source_pane.nim` refuses to render a blank
      # for a line it does not hold because a blank is indistinguishable from a
      # file of blank lines, but this model HOLDS THE WHOLE FILE, so "there is
      # no line 412" is a fact rather than a gap.
      result.rows.add @[]
      continue

    var spec = initGutterLineSpec(
      line = line, numberWidth = numberWidth, mark = markFor(model, line),
      isExecutionLine = false, numberStyle = EditLineNumberStyle)
    # THE EXECUTION POINTER IS NOT DRAWN, and the flags above are how: both
    # cursors are false on every line, so `gutterRow` emits `NoPointerGlyph`
    # and the three cells stay reserved. §3: "the gutter reused from Debug mode
    # minus the execution pointer (there is no execution)."
    spec.isInspectionLine = false
    let gutterSpans = gutterRow(spec)
    var gx = area.col
    for span in gutterSpans:
      if gx >= area.col + gw:
        break
      let room = area.col + gw - gx
      let fitted = truncateToCells(span.text, room)
      g.paint(row, gx, fitted, span.style)
      gx += cellWidthOf(fitted)
    result.rows.add gutterSpans

    let limit = area.col + area.width
    if codeW > 0:
      let codeCol = area.col + gw
      let raw = model.lineAt(line)
      let text = truncateToCells(raw, codeW)
      g.paint(row, codeCol, text, DefaultCellStyle)
      let shown = cellWidthOf(text)
      for span in file.spansForLine(line):
        if span.class == tcPlain:
          continue
        let lo = codeCol + max(0, span.startCell)
        let hi = min(codeCol + min(shown, span.endCell), limit)
        if hi <= lo:
          continue
        let style = tokenStyle(span.class)
        g.restyle(row, lo, hi - lo,
                  proc(s: CellStyle): CellStyle =
                    var out2 = style
                    out2.bg = s.bg
                    out2)
    inc result.renderedLines

    if line == model.caretLine:
      # THE CARET'S ROW IS TINTED AS A WHOLE, gutter included, on exactly the
      # rule `source_pane.nim` applies to the execution line: the highlight is
      # a property of the row rather than of the text, so it is applied after
      # both the gutter and the highlighter have chosen their foregrounds.
      g.restyle(row, area.col, area.width,
                proc(s: CellStyle): CellStyle =
                  var out2 = s
                  out2.bg = EditCaretLineBackground
                  out2)
      result.caretRow = row
      # The caret's cell is the gutter plus its cluster column, clamped into
      # the pane. Clamped rather than allowed to run out: a caret past the
      # right edge would park the terminal's real cursor in the NEXT pane.
      result.caretCol = min(area.col + gw + model.caretColumn, limit - 1)
