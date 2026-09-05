## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/source_pane.nim — CTUI-5. The centre pane of
## CodeTracer-TUI.md §3.3.2, painted into whatever rectangle CTUI-3's
## projection gives the `editor` pane.
##
## ## This module is a PURE FUNCTION OF A VALUE, and that is load-bearing three
## ## times over
##
## `SourcePaneModel` is a plain object: a window of text, a line to point at, a
## set of gutter marks, the values the ViewModel reported at this tick, and a
## provenance. `app/source_binding.nim` is the only thing that knows a
## `SourceVM` exists, and it builds one of these per frame.
##
## Three properties follow, and each is something a test in this milestone
## actually needs:
##
##   1. **The pane can be asserted without a debugger.** `test_syntax_
##      highlighting_ansi.nim` builds a model out of text it wrote and reads the
##      cells back, in the Tier-1 lane, at no process cost.
##   2. **Two frames are comparable.** CTUI-5's fine-grained-subscription
##      contract is measured by composing frame N and frame N+1 and counting
##      the compositor's dirty regions and emitted bytes. That measurement is
##      only meaningful if a row whose inputs did not change produces
##      byte-identical spans, which a pure function guarantees and a closure
##      over a signal does not.
##   3. **The virtualization is checkable.** `materializedLines` counts the
##      source lines this frame actually read out of the model, and the model
##      itself carries only `SourceVM`'s held window. A pane that had reached
##      for a whole file would have to do it through a field that is not there.
##
## ## THE WINDOW, AND WHAT A LINE OUTSIDE IT LOOKS LIKE
##
## `SourceVM`'s second contract is that "a line outside the window is a
## REQUEST, not an empty string", because "an empty default is how a source
## pane silently renders blank, and a blank pane over a working debugger is
## indistinguishable from a file of blank lines". This pane honours that on
## screen: a visible line the model does not hold renders `SourceLoadingText`,
## in its own style, at its own line number. It never renders as blank, and
## `SourcePaneScreen.loadingLines` counts them so a test can assert the count
## rather than scan for a glyph.
##
## ## PROVENANCE IS VISIBLE, IN TWO PLACES, ON PURPOSE
##
## CTUI-5: "A file served `savUnverified` (working-tree) must not look
## identical to one served `savVerified` (the recording's own copy). CTUI-4
## fought hard for this distinction; do not render it away."
##
## Two independent signals, because either alone has a hole:
##
##   * the **title row** carries a marker — `[verified]`, `[UNVERIFIED]` or
##     `[NO SOURCE]` — with its own colour. That is the one a reader sees when
##     they open the pane, and it says WHAT the condition is in words;
##   * the **line-number column** is tinted (`gutter.lineNumberStyle`):
##     `bright_black` for verified, `yellow` for unverified, `red` for absent.
##     That is the one a reader sees at line 400 with the title row scrolled
##     out of their attention, and it is on every row.
##
## A marker in the title alone would be invisible in a `regionText` read of the
## body; a tint alone would say "something is off" without saying what. Both
## are asserted, at Tier 1 by cell style and at Tier 2 by `cellAt`.
##
## ## No mocks
##
## Nothing in this file constructs a backend, a session or a ViewModel. The
## text it renders came from `SourceVM` through the binding, which got it from
## a real `SourceProvider`.

import std/unicode

import isonim_tui

import ../layout/profile
import ../syntax/highlighter
import ./gutter
import ./heatmap
import ./inline_annotations
import ./styled_row

export gutter, heatmap, inline_annotations, styled_row, highlighter, profile

type
  SourcePaneModel* = object
    ## Everything the source pane shows, as a value.
    path*: string
      ## The recorded path of the file at the current stop. The pane shows its
      ## basename in the title and uses its EXTENSION to pick a grammar.
    revisionLabel*: string
      ## `@<generation>` (and `#<digest>` when a recorder emits one), for the
      ## title row. Shown because two revisions of one path are the case
      ## CTUI-4's identity triple exists for, and a pane that showed only the
      ## name would render them identically.
    provenance*: GutterProvenance
    firstHeldLine*: int
      ## 1-based line number of `heldLines[0]`.
    heldLines*: seq[string]
      ## `SourceVM`'s window and nothing else. THE PANE HOLDS NO MORE THAN
      ## THIS, which is the memory contract, and it is why the field is the
      ## window rather than the file.
    totalLineCount*: int
    viewportTop*: int
      ## First line the pane shows.
    executionLine*: int
      ## The line the BACKEND reports for the current stop — `SourceVM`'s
      ## `executionLine`, never `EditorVM.cursorLine`. CTUI-4 measured the
      ## difference: a pane that followed the caret sat on line 1 for a whole
      ## session while the pointer walked off the bottom.
    marks*: seq[(int, GutterMark)]
      ## Breakpoints and tracepoints on this file, by line.
    values*: seq[Annotation]
      ## What the ViewModel reports at THIS tick. Rebuilt every frame; see
      ## `inline_annotations.nim` on why nothing here is cached.
    heat*: LineHeat
    gutterMode*: GutterMode
    degradedMessage*: string
      ## Page-Descriptions.md §14's row, when there is one. Rendered in the
      ## body rather than invented here: the string comes from the binding,
      ## which reads `EditorVM.degradedState`.

  SourcePaneScreen* = object
    ## One painted pane, plus the counts a test asserts on.
    rows*: seq[StyledRow]
      ## `area.height` rows of exactly `area.width` cells.
    area*: CellArea
    gutterWidth*: int
    codeWidth*: int
    materializedLines*: int
      ## Source lines this frame read out of `heldLines`.
    loadingLines*: int
      ## Visible lines the model did not hold. Never rendered blank.
    annotatedLines*: int
      ## Lines that carried an inline annotation.

const
  SourcePaneTitle* = "SOURCE"
  PaneRule* = "─"
  SourceLoadingText* = "⋯ loading"
    ## What a visible-but-unheld line shows. See this module's header: never a
    ## blank, because a blank is how a source pane lies about a working
    ## debugger.
  SourceLoadingStyle* = CellStyle(fg: "bright_black", italic: true)

  VerifiedMarker* = "[verified]"
  UnverifiedMarker* = "[UNVERIFIED]"
  AbsentMarker* = "[NO SOURCE]"
  VerifiedMarkerStyle* = CellStyle(fg: "green")
  UnverifiedMarkerStyle* = CellStyle(fg: "yellow", bold: true)
  AbsentMarkerStyle* = CellStyle(fg: "red", bold: true)

  TitleStyle* = CellStyle(fg: "white", bold: true)
  PathStyle* = CellStyle(fg: "bright_black")
  RuleStyle* = CellStyle(fg: "bright_black")
  DegradedStyle* = CellStyle(fg: "red", bold: true)

  TokenStyles*: array[TokenClass, CellStyle] = [
    tcPlain: DefaultCellStyle,
    tcKeyword: CellStyle(fg: "magenta", bold: true),
    tcType: CellStyle(fg: "cyan"),
    tcString: CellStyle(fg: "green"),
    tcNumber: CellStyle(fg: "yellow"),
    tcComment: CellStyle(fg: "bright_black", italic: true),
    tcIdentifier: CellStyle(fg: "white"),
    tcOperator: CellStyle(fg: "bright_blue"),
    tcPunctuation: CellStyle(fg: "blue")]
    ## §3.3.2's "per-language token highlighting mapped ... to terminal ANSI
    ## colors (keywords, types, strings, comments, identifiers)".
    ##
    ## NINE DISTINCT STYLES, and `test_syntax_highlighting_ansi.nim` asserts
    ## the number rather than spot-checking two of them: a palette with a
    ## repeat renders two token classes identically while every span-level
    ## assertion stays green.

proc tokenStyle*(class: TokenClass): CellStyle =
  TokenStyles[class]

proc provenanceMarker*(p: GutterProvenance): string =
  case p
  of gpVerified: VerifiedMarker
  of gpUnverified: UnverifiedMarker
  of gpAbsent: AbsentMarker

proc provenanceMarkerStyle*(p: GutterProvenance): CellStyle =
  case p
  of gpVerified: VerifiedMarkerStyle
  of gpUnverified: UnverifiedMarkerStyle
  of gpAbsent: AbsentMarkerStyle

proc initSourcePaneModel*(path = ""; revisionLabel = "";
                          provenance = gpVerified;
                          firstHeldLine = 1; heldLines: seq[string] = @[];
                          totalLineCount = 0; viewportTop = 1;
                          executionLine = 0;
                          marks: seq[(int, GutterMark)] = @[];
                          values: seq[Annotation] = @[];
                          heat = LineHeat();
                          gutterMode = gutLineNumbers;
                          degradedMessage = ""): SourcePaneModel =
  SourcePaneModel(
    path: path, revisionLabel: revisionLabel, provenance: provenance,
    firstHeldLine: firstHeldLine, heldLines: heldLines,
    totalLineCount: totalLineCount, viewportTop: viewportTop,
    executionLine: executionLine, marks: marks, values: values, heat: heat,
    gutterMode: gutterMode, degradedMessage: degradedMessage)

# ---------------------------------------------------------------------------
# Reading the model
# ---------------------------------------------------------------------------

proc isEmpty*(model: SourcePaneModel): bool =
  ## Whether the pane has anything to show at all. A model with no path is a
  ## session that has not stopped anywhere yet — distinct from one with a path
  ## and no text, which is §14's row.
  model.path.len == 0

proc holdsLine*(model: SourcePaneModel; line: int): bool =
  line >= model.firstHeldLine and
    line < model.firstHeldLine + model.heldLines.len

proc heldTextAt*(model: SourcePaneModel; line: int): string =
  ## The held text of `line`, or "" when it is outside the window.
  ##
  ## The "" here is safe and is not the empty-string default `SourceVM` refuses:
  ## every caller checks `holdsLine` first and renders `SourceLoadingText` when
  ## it is false. `heldTextAt` is never the thing that decides.
  if model.holdsLine(line): model.heldLines[line - model.firstHeldLine]
  else: ""

proc markFor*(model: SourcePaneModel; line: int): GutterMark =
  ## The gutter mark on `line`.
  ##
  ## Last declaration wins, because a line may legitimately carry both a
  ## breakpoint and a tracepoint and the gutter has one cell. The ORDER is the
  ## binding's — it adds breakpoints after tracepoints — so a line with both
  ## shows `●`, which is the one that stops.
  result = gmNone
  for (line2, mark) in model.marks:
    if line2 == line:
      result = mark

proc largestGutterNumber*(model: SourcePaneModel): int =
  ## The largest value the number field will have to show.
  case model.gutterMode
  of gutLineNumbers: model.totalLineCount
  of gutExecutionCounts: model.heat.largestCount()

proc paneGutterWidth*(model: SourcePaneModel): int =
  gutterWidth(gutterNumberWidth(largestGutterNumber(model)))

# ---------------------------------------------------------------------------
# Cell arithmetic over a line of text
# ---------------------------------------------------------------------------

proc pathBaseName*(path: string): string =
  ## The last component of a recorded path, splitting on BOTH separators.
  ##
  ## `std/os.extractFilename` is not used, for the reason
  ## `ct/trace/ctfs_sources.safePayloadPath` was fixed for in CTUI-4: a
  ## recorded path is whatever a recorder interned, a Windows recording carries
  ## backslashes, and a splitter that knows only its own host's separator shows
  ## the whole path as the "file name" on the other host. Also keeps `std/os`
  ## out of a view.
  result = path
  for i in countdown(path.high, 0):
    if path[i] == '/' or path[i] == '\\':
      return path[i + 1 .. ^1]

proc cellWidthOf*(s: string): int =
  for r in runes(s):
    result += max(1, displayWidth($r))

proc cellSlice*(s: string; startCell, endCell: int): string =
  ## The `[startCell, endCell)` CELLS of `s`.
  ##
  ## By cell rather than by byte or by rune, because a syntax span is expressed
  ## in cells (see `app/syntax/highlighter.SyntaxSpan`) and a line may hold a
  ## wide glyph. A wide glyph straddling the boundary is included when its
  ## FIRST cell is inside, which keeps the slice's cell count right — dropping
  ## it would shift everything after it left by two columns.
  result = ""
  var at = 0
  for r in runes(s):
    let w = max(1, displayWidth($r))
    if at >= endCell:
      break
    if at >= startCell:
      result.add $r
    at += w

proc truncateToCells*(s: string; cells: int): string =
  ## `s` clipped to `cells` columns.
  if cells <= 0: "" else: cellSlice(s, 0, cells)

# ---------------------------------------------------------------------------
# Painting
# ---------------------------------------------------------------------------

proc titleRowSpans*(model: SourcePaneModel; width: int): StyledRow =
  ## The title row as styled spans, exactly `width` cells wide.
  ##
  ## Built as a list of (text, style) pairs and then fitted, rather than
  ## painted through a nested helper: `g` is a `var` parameter and Nim will not
  ## let a closure capture one, so a `put`-style inner proc cannot exist here.
  result = @[]
  if width <= 0:
    return
  var parts: seq[StyledSpan] = @[]
  parts.add StyledSpan(text: SourcePaneTitle, style: TitleStyle)
  let base = pathBaseName(model.path)
  if base.len > 0:
    parts.add StyledSpan(text: " " & base, style: PathStyle)
  if model.revisionLabel.len > 0:
    parts.add StyledSpan(text: model.revisionLabel, style: PathStyle)
  parts.add StyledSpan(text: " " & provenanceMarker(model.provenance),
                       style: provenanceMarkerStyle(model.provenance))
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
    var rule = ""
    while cellWidthOf(rule) < width - used:
      rule.add PaneRule
    result.add StyledSpan(text: rule, style: RuleStyle)

proc titleRowText*(model: SourcePaneModel; width: int): string =
  ## The pane's first row, as text. Derived from `titleRowSpans` rather than
  ## rebuilt, so the text a Tier-2 `regionText` read is compared against and
  ## the styled row a Tier-1 cell read walks cannot disagree.
  rowText(titleRowSpans(model, width))

proc paintTitleRow(g: var StyledGrid; row, col, width: int;
                   model: SourcePaneModel) =
  if width <= 0:
    return
  var at = col
  for span in titleRowSpans(model, width):
    g.paint(row, at, span.text, span.style)
    at += cellWidthOf(span.text)

proc restyleClamped(g: var StyledGrid; row, col, width, lo, hi: int;
                    transform: proc(s: CellStyle): CellStyle) =
  ## `restyle`, clamped to `[lo, hi)` as well as to the grid.
  ##
  ## The pane owns a RECTANGLE of a shared screen, and a syntax span computed
  ## from a line's own columns can run past the pane's right edge. Without this
  ## clamp a long line would repaint the neighbouring pane's cells — which the
  ## projection's disjointness check cannot see, because it checks the
  ## rectangles and not what was drawn in them.
  let start = max(col, lo)
  let stop = min(col + width, hi)
  if stop > start:
    g.restyle(row, start, stop - start, transform)

proc paintSourcePane*(g: var StyledGrid; area: CellArea;
                      model: SourcePaneModel;
                      cache: HighlighterCache = nil): SourcePaneScreen =
  ## Paint the pane into `area` of `g`, and report what it painted.
  ##
  ## `cache` is CTUI-5's risk mitigation: parse once per `(path, generation,
  ## digest, window)` and reuse the spans. Passing `nil` parses every call,
  ## which is what the cold-parse benchmark measures.
  result = SourcePaneScreen(rows: @[], area: area, gutterWidth: 0,
                            codeWidth: 0, materializedLines: 0,
                            loadingLines: 0, annotatedLines: 0)
  if area.width <= 0 or area.height <= 0:
    return

  let gutW = min(area.width, model.paneGutterWidth())
  let codeW = max(0, area.width - gutW)
  let numberWidth = gutterNumberWidth(largestGutterNumber(model))
  result.gutterWidth = gutW
  result.codeWidth = codeW

  paintTitleRow(g, area.row, area.col, area.width, model)

  if area.height <= 1:
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  # The syntax spans for the whole held window, once. `highlight` is the cached
  # entry point; `highlightWindow` behind it is the parse.
  let file =
    if cache.isNil:
      highlightWindow(model.path, model.firstHeldLine, model.heldLines)
    else:
      cache.highlight(model.path, 0, "", model.firstHeldLine, model.heldLines)

  let bodyRows = area.height - 1
  for i in 0 ..< bodyRows:
    let row = area.row + 1 + i
    let line = model.viewportTop + i
    if line < 1:
      continue
    if model.totalLineCount > 0 and line > model.totalLineCount:
      # Past the end of the file. Left blank ON PURPOSE and it is the ONE blank
      # this pane draws: there is no line here, as against a line whose text
      # has not arrived, which is `SourceLoadingText` below.
      continue

    var spec = initGutterLineSpec(
      line = line,
      numberWidth = numberWidth,
      mark = model.markFor(line),
      isExecutionLine = line == model.executionLine and line > 0,
      provenance = model.provenance)
    if model.gutterMode == gutExecutionCounts:
      spec.numberText = model.heat.heatCountText(line)
      spec.numberStyle = model.heat.heatStyle(line)

    var at = area.col
    for span in gutterRow(spec):
      if at >= area.col + gutW:
        break
      let room = area.col + gutW - at
      let fitted = truncateToCells(span.text, room)
      g.paint(row, at, fitted, span.style)
      at += cellWidthOf(fitted)

    # How far the execution-line highlight reaches on this row. Grown as the
    # code and the annotation are painted; see the `restyle` call below for the
    # measurement that decided it is not the whole row.
    var highlightCells = gutW

    if codeW <= 0:
      if line == model.executionLine and line > 0:
        g.restyle(row, area.col, highlightCells, proc(s: CellStyle): CellStyle =
          s.withBackground(ExecutionLineBackground))
      continue

    let codeCol = area.col + gutW
    if not model.holdsLine(line):
      inc result.loadingLines
      let loading = truncateToCells(SourceLoadingText, codeW)
      g.paint(row, codeCol, loading, SourceLoadingStyle)
      highlightCells += cellWidthOf(loading)
    else:
      inc result.materializedLines
      let raw = model.heldTextAt(line)
      let text = truncateToCells(raw, codeW)
      g.paint(row, codeCol, text, DefaultCellStyle)
      let shown = cellWidthOf(text)
      highlightCells += shown
      for span in file.spansForLine(line):
        if span.class == tcPlain:
          continue
        let lo = codeCol + max(0, span.startCell)
        let hi = codeCol + min(shown, span.endCell)
        if hi <= lo:
          continue
        let style = tokenStyle(span.class)
        restyleClamped(g, row, lo, hi - lo, codeCol, codeCol + codeW,
                       proc(s: CellStyle): CellStyle =
                         var out2 = style
                         out2.bg = s.bg
                         out2)
      # The inline annotation, for the EXECUTION line only. §3.3.2 renders the
      # evaluated values "at the current step", and a value printed beside a
      # line the debugger is not on is a value from another moment.
      if line == model.executionLine and model.values.len > 0:
        let span = annotationSpan(raw, model.values, codeW, shown)
        if span.text.len > 0:
          inc result.annotatedLines
          g.paint(row, codeCol + shown + AnnotationGap, span.text, span.style)
          highlightCells += AnnotationGap + cellWidthOf(span.text)

    if line == model.executionLine and line > 0:
      # §3.3.2's "background highlight on current active execution line".
      #
      # APPLIED LAST, so it keeps every foreground the gutter and the
      # highlighter decided — see `styled_row.restyle`'s docstring on why this
      # is not painted first.
      #
      # AND APPLIED TO THE LINE'S EXTENT RATHER THAN TO THE WHOLE ROW, which is
      # a MEASURED decision against CTUI-5's < 250-byte single-step emission
      # gate rather than a taste one. A step changes two rows: the one the
      # pointer left and the one it reached. With the highlight spanning the
      # full pane the compositor's diff is 2 x paneWidth cells, and the
      # emission was measured at 224 bytes on a 56-column pane and 292 on a
      # 90-column one, over 40 short lines — over the gate at the width the
      # Ultra-wide profile gives this pane. Ending the highlight at the end of
      # the line's own text (plus the gutter, plus the inline annotation) keeps
      # the syntax colours and brings the same step to 149 bytes at BOTH
      # widths, because the cost stops depending on the pane and starts
      # depending on the line.
      #
      # THIS IS A TRADE, NOT A CONVENTION MATCH, and saying so is the honest
      # form. The mainstream GUI editors — VS Code, IntelliJ, Vim's
      # `cursorline`, Emacs's `hl-line` — all highlight the FULL row, so the
      # ragged right edge here is a visible departure from what a reader
      # arriving from one of them expects. What buys it is that a terminal pane
      # pays per emitted cell over a link this front-end is specified to run
      # across (SSH, container shells), and §3.3.2's own sentence asks for "a
      # background highlight on the current active execution line" without
      # saying how far right it reaches. The line stays unambiguous either way:
      # the `-->` pointer, the gutter tint and the highlight all agree on it.
      #
      # WHAT THAT DOES NOT BUY, stated because the gate is a number and this
      # is the condition under which it is still missed: a line long enough to
      # FILL the code column and dense in tokens costs 344 bytes at 56 columns
      # and 348 at 90 — the runes are 112 of that and the rest is one SGR
      # transition per token, on both the row the pointer left and the row it
      # reached. The measurement on the real `calc` fixture is in CTUI-5's
      # Implementation section; this comment records the worst case rather
      # than leaving it to be found.
      g.restyle(row, area.col, min(highlightCells, area.width),
                proc(s: CellStyle): CellStyle =
                  s.withBackground(ExecutionLineBackground))

  if model.degradedMessage.len > 0 and area.height >= 2:
    g.paint(area.row + 1, area.col,
            truncateToCells(model.degradedMessage, area.width), DegradedStyle)

  for r in area.row ..< area.row + area.height:
    result.rows.add g.rowSpansIn(r, area.col, area.width)

proc sourcePaneScreen*(model: SourcePaneModel; width, height: int;
                       cache: HighlighterCache = nil): SourcePaneScreen =
  ## The pane on a screen of its own — the shape a Tier-1 test and the
  ## `app_source_pane` snapshot app both use.
  ##
  ## `rows` here are `width` cells wide, because the grid IS the pane. Inside
  ## the shell the same painter writes into a screen-wide grid at the pane's
  ## rectangle, and `test_real_source_pane.nim` compares the two so the pane
  ## cannot look one way alone and another way in the shell.
  var g = newStyledGrid(width, height)
  let area = CellArea(col: 0, row: 0, width: width, height: height)
  result = paintSourcePane(g, area, model, cache)

proc sourcePaneRows*(model: SourcePaneModel; width, height: int;
                     cache: HighlighterCache = nil): seq[StyledRow] =
  sourcePaneScreen(model, width, height, cache).rows

proc sourcePaneText*(model: SourcePaneModel; width, height: int;
                     cache: HighlighterCache = nil): seq[string] =
  ## The pane as plain text, one string per row. What a Tier-2 `regionText`
  ## read is compared against.
  result = @[]
  for row in sourcePaneRows(model, width, height, cache):
    result.add rowText(row)

proc renderSourcePaneTree*(model: SourcePaneModel; r: TerminalRenderer;
                           width, height: int;
                           cache: HighlighterCache = nil): TerminalNode =
  ## The pane as a component tree: one `div` per row, styled spans inside.
  styledRowsTree(r, sourcePaneRows(model, width, height, cache))
