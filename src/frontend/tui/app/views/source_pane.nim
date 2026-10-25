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

import isonim_tui

import ../layout/profile
import ../syntax/highlighter
import ./gutter
import ./heatmap
import ./inline_annotations
import ./styled_row
import ./scrubber_track
from codetracer_embed import HorizontalView, setViewport, overflows, barModel,
  ScrubberModel, scrubberModel

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
    entryContext*: string
      ## The highlighter's state at the start of `heldLines[0]`
      ## (`SourceVM.heldLineContexts[0]`), "" when none was derived. A few
      ## bytes, not the text above the window (PLAT-47 B4).
    totalLineCount*: int
    viewportTop*: int
      ## First line the pane shows.
    executionLine*: int
      ## The line the BACKEND reports for the current stop — `SourceVM`'s
      ## `executionLine`, never `EditorVM.cursorLine`. CTUI-4 measured the
      ## difference: a pane that followed the caret sat on line 1 for a whole
      ## session while the pointer walked off the bottom.
    inspectionLine*: int
      ## CTUI-6. The line the CALL STACK pane's inspection cursor selected, or 0
      ## for none.
      ##
      ## ZERO BY DEFAULT, which is what keeps every CTUI-5 screen unchanged: a
      ## model built without it renders precisely the pane CTUI-5 measured.
      ##
      ## It is a SEPARATE FIELD FROM `executionLine` because the two are
      ## different questions and CTUI-6's contract is that they must not be
      ## conflated. When an outer frame in ANOTHER FILE is inspected the binding
      ## sets `executionLine` to 0 — the debugger is not stopped in the file on
      ## screen, and drawing `-->` on a line of it would be the strongest form
      ## of that conflation: a pane claiming the program is somewhere it has
      ## never been.
    marks*: seq[(int, GutterMark)]
      ## Breakpoints and tracepoints on this file, by line.
    caretLine*: int
    caretColumn*: int
      ## PLAT-51 (CodeTracer-TUI.md §3.3.2, Editor-Pane.md "The caret in a
      ## read-only editor"): the read-only editor's CARET — the cell drawn in
      ## reverse video, distinct from the execution line's band and from the
      ## inspection cursor's ` ▹ `. Line 0: no caret.
    selected*: seq[tuple[line, fromColumn, toColumn: int]]
      ## PLAT-68: the read-only editor's SELECTION (Shift+arrows, Ctrl+A, a
      ## drag, a find match — its document's selection, Monaco's read-only
      ## mode): per line, the 1-based cell columns `[fromColumn, toColumn)`
      ## painted on the selection ground. `toColumn` past the line's end
      ## covers the line break, as a selection that continues does.
    findMarks*: seq[tuple[line, fromColumn, toColumn: int; current: bool]]
      ## PLAT-70 Part C (Find-And-Incremental-Search.md §3.3 step 4): the find
      ## session's matches on the drawn lines (`find_vm.marksInWindow`), the
      ## current one flagged — drawn in the editor itself, over the selection,
      ## every match on the find ground and the current one on its own.
    columnMarks*: seq[(int, int)]
      ## PLAT-50 (K14): the column breakpoints on this file, `(line,
      ## column)` — the cell they are anchored at is marked in the code, as
      ## the desktop's `ct-column-breakpoint-marker` decoration marks it.
    values*: seq[Annotation]
      ## What the ViewModel reports at THIS tick. Rebuilt every frame; see
      ## `inline_annotations.nim` on why nothing here is cached.
    lineValues*: seq[(int, seq[Annotation])]
      ## The FLOW's values, by line (`editor_surface.flowValuesByLine` — the
      ## rule GPUI's editor draws): every line of the current function the run
      ## reached, drawn as they are, beside the code. A line listed here shows
      ## these instead of `values`; the execution line falls back to `values`
      ## (filtered by the names its text mentions) when the flow has nothing
      ## for it. Empty when the flow overlay is hidden.
    heat*: LineHeat
    notTakenLines*: seq[int]
      ## The flow overlay: lines inside a branch arm the recorded run DECLINED,
      ## from `editor_surface.notTakenLinesOf`. They are painted de-emphasised,
      ## which is the desktop editor's `.line-flow-skip` (half opacity) in the
      ## terminal's vocabulary. Empty when the overlay is hidden or the flow
      ## window claims nothing — and then the pane is exactly CTUI-5's.
    gutterMode*: GutterMode
    degradedMessage*: string
      ## Page-Descriptions.md §14's row, when there is one. Rendered in the
      ## body rather than invented here: the string comes from the binding,
      ## which reads `EditorVM.degradedState`.
    hview*: HorizontalView
      ## PLAT-70 (Horizontal-Overflow.md §4): the read-only editor's
      ## horizontal view — its document's, after the runtime's caret-follow.
      ## The code is drawn from `hview.leftCol`; the bar while it overflows.
    caretViewColumn*: int
      ## The caret's 0-based view column (`editing_core.caretViewColumn`):
      ## the bar's mark (§4.2).
    overflowMarkers*: bool
      ## `view.overflow-markers` (§4.6).

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
    barRow*: int
      ## PLAT-70: the horizontal bar's row, -1 when the content fits.
    trackCol*: int
      ## M73 (#840): the vertical bar's column, -1 when the file fits.
    trackTop*: int
    trackRows*: int
      ## Its first row and its height: the body rows, never the corner cell
      ## the horizontal bar's row would give it (Scrollbar-Scrubbers.md §6).

  SourceTrack* = object
    ## M73 (#840): where the pane's VERTICAL bar is painted, and the model it
    ## is drawn over — what `paintSourcePane` draws and what a press on it is
    ## hit-tested against, from one computation.
    shown*: bool
    col*: int
    top*: int
    rows*: int
    model*: ScrubberModel
      ## Scrollbar-Scrubbers.md §3 over the FILE: every line of it is the
      ## population, the window the first visible one, the mark the
      ## execution line (§3.5's "now", in the pointer's colour).

  SourcePaneLayout* = object
    ## The cells the pane divides `area` into. ONE function computes all of
    ## it (`sourcePaneLayout`) because the two bars depend on each other: the
    ## vertical one takes a column from the code, which can make a line
    ## overflow and bring the horizontal one, which takes a row from the body.
    gutterWidth*: int
    codeWidth*: int
    bodyRows*: int
    bar*: tuple[shown: bool; row, left, cols: int; view: HorizontalView]
    track*: SourceTrack

const
  SourcePaneTitle* = "SOURCE"
  PaneRule* = canonical(grDividerH)
  SourceLoadingText* = canonical(grLoading) & " loading"
    ## What a visible-but-unheld line shows. See this module's header: never a
    ## blank, because a blank is how a source pane lies about a working
    ## debugger.
  SourceLoadingStyle* = CellStyle(role: srChromeMuted, italic: true)

  VerifiedMarker* = "[verified]"
  UnverifiedMarker* = "[UNVERIFIED]"
  AbsentMarker* = "[NO SOURCE]"
  VerifiedMarkerStyle* = CellStyle(role: srSourceVerified)
  UnverifiedMarkerStyle* = CellStyle(role: srSourceUnverified)
  AbsentMarkerStyle* = CellStyle(role: srSourceAbsent)

  TitleStyle* = CellStyle(role: srChromeTitle)
  PathStyle* = CellStyle(role: srChromeMuted)
  RuleStyle* = CellStyle(role: srBorderPane)
  DegradedStyle* = CellStyle(role: srChromeError)
  FlowNotTakenStyle* = CellStyle(role: srLineNotTaken)
    ## A line the run did not reach, de-emphasised. `bright_black` is the
    ## colour this pane already uses for text that is present but not the
    ## subject (the path, the rule, the loading placeholder); the syntax
    ## colours are dropped on such a line because a highlighted keyword on a
    ## dimmed line reads as live code.

  TokenStyles*: array[TokenClass, CellStyle] = [
    tcPlain: DefaultCellStyle,
    tcKeyword: CellStyle(role: srSyntaxKeyword),
    tcType: CellStyle(role: srSyntaxType),
    tcString: CellStyle(role: srSyntaxString),
    tcNumber: CellStyle(role: srSyntaxNumber),
    tcComment: CellStyle(role: srSyntaxComment),
    tcIdentifier: CellStyle(role: srSyntaxIdentifier),
    tcOperator: CellStyle(role: srSyntaxOperator),
    tcPunctuation: CellStyle(role: srSyntaxPunctuation),
    tcStringEscape: CellStyle(role: srSyntaxStringEscape),
    tcBracket: CellStyle(role: srSyntaxBracket),
    tcTag: CellStyle(role: srSyntaxTag),
    tcTypeIdentifier: CellStyle(role: srSyntaxTypeIdentifier),
    tcKeywordType: CellStyle(role: srSyntaxKeywordType),
    tcCommentDoc: CellStyle(role: srSyntaxCommentDoc),
    tcRegexp: CellStyle(role: srSyntaxRegexp),
    tcVariable: CellStyle(role: srSyntaxVariable),
    tcNamespace: CellStyle(role: srSyntaxNamespace),
    tcAttributeName: CellStyle(role: srSyntaxAttributeName),
    tcMetatag: CellStyle(role: srSyntaxMetatag)]
    ## §3.3.2's "per-language token highlighting mapped ... to terminal ANSI
    ## colors (keywords, types, strings, comments, identifiers)".
    ##
    ## TWELVE DISTINCT STYLES (the last three since PLAT-47, the scopes the
    ## desktop's Monaco Python tokenizer colours on their own), and `test_syntax_highlighting_ansi.nim` asserts
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
                          degradedMessage = "";
                          inspectionLine = 0;
                          notTakenLines: seq[int] = @[];
                          entryContext = "";
                          columnMarks: seq[(int, int)] = @[];
                          lineValues: seq[(int, seq[Annotation])] = @[]):
                         SourcePaneModel =
  ## `inspectionLine` is LAST and defaults to 0, so every CTUI-5 call site
  ## builds exactly the model it built before CTUI-6 existed.
  SourcePaneModel(
    path: path, revisionLabel: revisionLabel, provenance: provenance,
    firstHeldLine: firstHeldLine, heldLines: heldLines,
    entryContext: entryContext,
    totalLineCount: totalLineCount, viewportTop: viewportTop,
    executionLine: executionLine, inspectionLine: inspectionLine,
    marks: marks, columnMarks: columnMarks, values: values, heat: heat,
    notTakenLines: notTakenLines, gutterMode: gutterMode,
    degradedMessage: degradedMessage, lineValues: lineValues)

proc annotationsAt*(model: SourcePaneModel; line: int;
                    lineText: string): seq[Annotation] =
  ## The values drawn beside `line`: the flow's for it when it has any
  ## (`lineValues`), else — on the execution line only — the names in scope
  ## its text mentions. ONE answer for every front-end: GPUI's rows carry the
  ## same (`editor_surface.editorSurfaceFor`).
  for (l, vs) in model.lineValues:
    if l == line:
      return vs
  if line == model.executionLine and line > 0 and model.values.len > 0:
    return annotationsForLine(lineText, model.values)

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

# `cellWidthOf`, `cellSlice` and `truncateToCells` MOVED TO
# `app/views/styled_row.nim` by CTUI-6, which needs the same cell arithmetic in
# `frame_item.nim` and must not import a pane to get it. This module re-exports
# `styled_row`, so every CTUI-5 call site — inside this file and in the suites —
# resolves to exactly the same procedures.

# ---------------------------------------------------------------------------
# Painting
# ---------------------------------------------------------------------------

proc titleRowSpans*(model: SourcePaneModel; width: int;
                    glyphs = DefaultGlyphs): StyledRow =
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
    result.add StyledSpan(text: repeatGlyph(glyphs.glyph(grDividerH), width - used),
                          style: RuleStyle)

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
  for span in titleRowSpans(model, width, g.glyphs):
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

const
  MinSourceTrackWidth* = 8
    ## M73 (#840): the narrowest pane that gives a column to the vertical bar
    ## — the call trace's `MinTrackedWidth`, for the same reason: below it the
    ## column is worth more as text.

proc sourcePaneLayout*(model: SourcePaneModel; area: CellArea): SourcePaneLayout =
  ## Where `paintSourcePane` puts the gutter, the code, PLAT-70's horizontal
  ## bar and M73's vertical bar in `area` — the one computation the painter,
  ## the click read-back and the runtime's hit-tests all use.
  ##
  ## THE VERTICAL BAR IS OVERFLOW-ONLY, as the horizontal one is
  ## (Horizontal-Overflow.md §4.7) and as Monaco's `vertical: 'auto'`
  ## scrollbar is: it takes the pane's rightmost column (Scrollbar-Scrubbers.md
  ## §4, "inside the pane's own rectangle") only while the file has more lines
  ## than the body has rows. A file that fits paints exactly the pane it did
  ## before M73. The order matters: the column is decided first, against the
  ## rows the horizontal bar leaves at the full code width; the horizontal bar
  ## is then decided at the narrower width, and where both are shown their
  ## corner cell is left to neither (§6).
  let gutW = min(area.width, model.paneGutterWidth())
  let fullW = max(0, area.width - gutW)
  var view = model.hview
  view.setViewport(fullW)
  let barAtFull = view.overflows and area.height >= 3
  let rowsAtFull = area.height - 1 - (if barAtFull: 1 else: 0)
  # §14's absent file draws no row of text, so it has nothing to scroll.
  let absent = model.provenance == gpAbsent and model.heldLines.len == 0
  let tracked = not absent and area.width >= MinSourceTrackWidth and
                fullW >= 2 and rowsAtFull >= 1 and
                model.totalLineCount > rowsAtFull
  let codeW = if tracked: fullW - 1 else: fullW
  view = model.hview
  view.setViewport(codeW)
  let barShown = view.overflows and area.height >= 3
  let bodyRows =
    if absent: 0
    else: max(0, area.height - 1 - (if barShown: 1 else: 0))
  result.gutterWidth = gutW
  result.codeWidth = codeW
  result.bodyRows = bodyRows
  result.bar = (shown: barShown, row: area.row + area.height - 1,
                left: area.col + gutW, cols: codeW, view: view)
  if tracked and bodyRows > 0:
    result.track = SourceTrack(
      shown: true, col: area.col + area.width - 1, top: area.row + 1,
      rows: bodyRows,
      model: scrubberModel(model.totalLineCount, max(0, model.viewportTop - 1),
                           bodyRows,
                           (if model.executionLine > 0: model.executionLine - 1
                            else: -1)))

proc sourceBarOf*(model: SourcePaneModel; area: CellArea):
    tuple[shown: bool; row, left, cols: int; view: HorizontalView] =
  ## PLAT-70: where `paintSourcePane` draws the horizontal bar in `area`, and
  ## the view it is drawn over — what a press on it is hit-tested against.
  ## M73: one column narrower while the vertical bar is shown
  ## (`sourcePaneLayout`).
  model.sourcePaneLayout(area).bar

proc sourceTrackOf*(model: SourcePaneModel; area: CellArea): SourceTrack =
  ## M73 (#840): where `paintSourcePane` draws the vertical bar in `area`.
  model.sourcePaneLayout(area).track

proc sourceCodeWidth*(model: SourcePaneModel; area: CellArea): int =
  ## The code columns of the pane painted into `area` — the width the
  ## horizontal view is measured against (PLAT-70), less the vertical bar's
  ## column while it is shown (M73).
  model.sourcePaneLayout(area).codeWidth

proc paintCellBand*(g: var StyledGrid; row, codeCol, codeW, left,
                    fromColumn, toColumn: int; role: SemanticRole) =
  ## One band of a code row's ground — a selection or a find match — over the
  ## 1-based cell columns `[fromColumn, toColumn)` of the LINE, drawn from
  ## the view's left column and cut to the code area. One painter for both
  ## editor panes (Debug's source, Edit's), so a band lands on the cells its
  ## text is drawn on in either.
  if toColumn <= fromColumn: return
  let first = max(1, fromColumn - left)
  let last = min(codeW + 1, toColumn - left)
  if last > first:
    g.restyle(row, codeCol + first - 1, last - first,
              proc(s: CellStyle): CellStyle = s.withBackground(role))

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
                            loadingLines: 0, annotatedLines: 0, barRow: -1,
                            trackCol: -1, trackTop: -1, trackRows: 0)
  if area.width <= 0 or area.height <= 0:
    return

  # M73: the gutter, the code and both bars from ONE computation, so the
  # painter, the click read-back and the runtime's hit-tests cannot disagree.
  let layout = model.sourcePaneLayout(area)
  let gutW = layout.gutterWidth
  let codeW = layout.codeWidth
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
      highlightWindow(model.path, model.firstHeldLine, model.heldLines,
                      model.entryContext)
    else:
      cache.highlight(model.path, 0, "", model.firstHeldLine, model.heldLines,
                      model.entryContext)

  # PLAT-70: THE HORIZONTAL VIEW, at this pane's code width; the bar takes
  # the last row only while the content overflows (Horizontal-Overflow §4.7).
  let bar = layout.bar
  let view = bar.view
  let left = view.leftCol
  # Absent (§14's `savAbsent`): no line of this file will arrive, so no row is
  # drawn as `⋯ loading` — the degraded message below names the missing file.
  let bodyRows = layout.bodyRows
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
      provenance = model.provenance,
      isInspectionLine = line == model.inspectionLine and line > 0)
    if model.gutterMode == gutExecutionCounts:
      spec.numberText = model.heat.heatCountText(line, g.glyphs)
      spec.numberStyle = model.heat.heatStyle(line)

    var at = area.col
    for span in gutterRow(spec, g.glyphs):
      if at >= area.col + gutW:
        break
      let room = area.col + gutW - at
      let fitted = truncateToCells(span.text, room)
      g.paint(row, at, fitted, span.style)
      at += cellWidthOf(fitted)

    if codeW <= 0:
      continue

    let codeCol = area.col + gutW
    if not model.holdsLine(line):
      inc result.loadingLines
      let loading = truncateToCells(g.glyphText(grLoading) & " loading", codeW)
      g.paint(row, codeCol, loading, SourceLoadingStyle)
    else:
      inc result.materializedLines
      let raw = model.heldTextAt(line)
      let text = cellSlice(raw, left, left + codeW)
      g.paint(row, codeCol, text, DefaultCellStyle)
      let shown = cellWidthOf(text)
      for span in file.spansForLine(line):
        if span.class == tcPlain:
          continue
        let lo = codeCol + max(0, span.startCell - left)
        let hi = codeCol + min(shown, span.endCell - left)
        if hi <= lo:
          continue
        let style = tokenStyle(span.class)
        restyleClamped(g, row, lo, hi - lo, codeCol, codeCol + codeW,
                       proc(s: CellStyle): CellStyle =
                         var out2 = style
                         out2.surface = s.surface
                         out2)
      # THE FLOW OVERLAY. Applied after the syntax colours so it replaces
      # them, and before the execution-line background so a stop inside a
      # declined arm (which the flow never reports, but a stale window could)
      # still shows where the debugger is.
      if line in model.notTakenLines and shown > 0:
        g.restyle(row, codeCol, shown, proc(s: CellStyle): CellStyle =
          var out2 = FlowNotTakenStyle
          out2.surface = s.surface
          out2)
      # PLAT-50 (K14): A COLUMN BREAKPOINT'S CELL, underlined in the
      # breakpoint's colour — the desktop's inline `ct-column-breakpoint-
      # marker` on the one character the breakpoint is anchored at.
      for (ml, mc) in model.columnMarks:
        if ml == line and mc - left >= 1 and mc - left <= shown:
          g.restyle(row, codeCol + mc - left - 1, 1, proc(s: CellStyle): CellStyle =
            var out2 = s
            out2.role = srGutterBreakpoint
            out2.underline = true
            out2)
      # The inline annotation: the flow's values on every line the run
      # reached in this function (the step's own values, recorded at that
      # step, so not a value from another moment), and the names in scope on
      # the execution line where the flow has none (`annotationsAt`).
      let annotations = model.annotationsAt(line, raw)
      if annotations.len > 0:
        let span = shownAnnotationSpan(annotations, codeW, shown, g.glyphs)
        if span.text.len > 0:
          inc result.annotatedLines
          g.paint(row, codeCol + shown + AnnotationGap, span.text, span.style)
      if model.overflowMarkers:
        paintOverflowMarkers(g, row, codeCol, cellWidthOf(raw), view)

    if line == model.executionLine and line > 0:
      # §3.3.2's "background highlight on current active execution line",
      # DRAWN AS THE DESKTOP DRAWS IT (PLAT-47): Monaco's stop decoration is a
      # whole-line band across the editor's content area, from the first code
      # column to the editor's right edge, whatever the line's length — and
      # not under the line numbers (measured off the Electron app on `calc`:
      # `plat47-desktop-parity.electron.json` reads the band 30px inside the
      # editor's right edge, past the end of the line). So the band covers
      # the code column, text, annotation and trailing blanks alike, to the
      # pane's right edge, and the gutter keeps its own colours (the active
      # line number and the `-->` pointer mark the line there).
      #
      # APPLIED LAST, so it keeps every foreground the highlighter decided —
      # see `styled_row.restyle`'s docstring on why this is not painted first.
      #
      # THE EMISSION COST. CTUI-5 (2026-09) ended the band at the end of the
      # line's text to keep a one-line step under its 250-byte gate: a band
      # that ends with the text makes a step's cost depend on the line rather
      # than on the pane. Parity with the desktop is the stronger requirement
      # now, and the cost is measured, not assumed:
      # `test_source_stepping_forward_backward.nim` still asserts the gate at
      # its 56-column pane with the full-width band, and
      # `test_plat47_desktop_parity.nim` reads the band back off a real PTY
      # to the pane's last column.
      #
      # M73: TO THE CODE'S LAST COLUMN, which is the pane's last column
      # unless the vertical bar holds it — the band never paints over the
      # track (Scrollbar-Scrubbers.md §4: the track is the pane's rightmost
      # column, and the desktop's band ends at Monaco's scrollbar too).
      g.restyle(row, codeCol, codeW,
                proc(s: CellStyle): CellStyle =
                  s.withBackground(ExecutionLineBackground))
    # PLAT-68: THE SELECTION, on the design system's selection ground, under
    # the caret.
    for sel in model.selected:
      if sel.line == line:
        paintCellBand(g, row, codeCol, codeW, left, sel.fromColumn,
                      sel.toColumn, srSurfaceSelection)
    # PLAT-70 Part C: THE FIND HIGHLIGHTS, over the selection (the current
    # match is the selection, and its own style is what marks it).
    for m in model.findMarks:
      if m.line == line:
        paintCellBand(g, row, codeCol, codeW, left, m.fromColumn, m.toColumn,
                      (if m.current: srSurfaceFindMatchCurrent
                       else: srSurfaceFindMatch))
    # PLAT-51: THE CARET, over everything — its cell reversed (a caret past
    # the line's end sits on the blank cell after it).
    if line == model.caretLine and line > 0 and
       model.caretColumn - left >= 1 and model.caretColumn - left <= codeW:
      g.restyle(row, codeCol + model.caretColumn - left - 1, 1,
                proc(s: CellStyle): CellStyle =
                  var out2 = s
                  out2.reverse = true
                  out2)

  if layout.track.shown:
    # M73 (#840): THE VERTICAL BAR — Scrollbar-Scrubbers.md §4's terminal
    # track down the pane's rightmost column over the body rows, the thumb in
    # eighths for the window over the WHOLE file, the execution line marked in
    # the pointer's colour. Painted after the rows so nothing a row draws (the
    # band, an inline value) can cover it; its corner with the horizontal bar
    # is left to neither (§6).
    let t = layout.track
    paintVerticalScrubber(g, t.col, t.top, t.rows, t.model)
    result.trackCol = t.col
    result.trackTop = t.top
    result.trackRows = t.rows

  if bar.shown and bodyRows > 0:
    # §4.7: the last row, one cell high, over the code columns.
    result.barRow = bar.row
    paintHorizontalBar(g, bar.row, bar.left, bar.cols,
                       view.barModel(model.caretViewColumn))

  if model.degradedMessage.len > 0 and area.height >= 2:
    if bodyRows == 0:
      # Absent: the rows are free, so the message is WRAPPED over them rather
      # than cut — its tail is the missing file's name.
      var rest = model.degradedMessage
      var row = area.row + 1
      while rest.len > 0 and row < area.row + area.height:
        let piece = truncateToCells(rest, area.width)
        g.paint(row, area.col, piece, DegradedStyle)
        if piece.len == 0 or piece.len >= rest.len: break
        rest = rest[piece.len .. ^1]
        inc row
    else:
      # Left of the vertical bar while it is shown (M73).
      let room = area.width - (if layout.track.shown: 1 else: 0)
      g.paint(area.row + 1, area.col,
              truncateToCells(model.degradedMessage, room), DegradedStyle)

  for r in area.row ..< area.row + area.height:
    result.rows.add g.rowSpansIn(r, area.col, area.width)

type
  SourceClickTarget* = object
    ## PLAT-50: what a press on the source pane is on.
    line*: int
      ## The source line pressed, 0 for none.
    onGutter*: bool
    column*: int
      ## The code column pressed (1-based cell of the line's text); 0 on the
      ## gutter or past the code column.
    lineText*: string
      ## The held text of `line` ("" while it is loading).
    value*: int
      ## The inline value pressed (an index into `values`), -1 for none.
    values*: seq[Annotation]
      ## Every value the line's annotation shows.

proc sourceClickTargetAt*(model: SourcePaneModel; area: CellArea;
                          row, col: int): SourceClickTarget =
  ## A press at `(row, col)` on the pane `paintSourcePane` painted into
  ## `area`, read back by the same arithmetic: the line, the gutter or the
  ## code column, and on a line with inline values which one it is on.
  result = SourceClickTarget(value: -1)
  if area.width <= 0 or area.height <= 1 or row <= area.row or
     row >= area.row + area.height or col < area.col or
     col >= area.col + area.width:
    return
  let layout = model.sourcePaneLayout(area)
  let gutW = layout.gutterWidth
  let codeW = layout.codeWidth
  let bar = layout.bar
  let view = bar.view
  # PLAT-70: the horizontal bar's row is the bar's, never a line.
  if bar.shown and row == bar.row:
    return
  # M73: and the vertical bar's column is the bar's, never a column of text.
  if layout.track.shown and col == layout.track.col:
    return
  let line = model.viewportTop + (row - area.row - 1)
  if line < 1 or (model.totalLineCount > 0 and line > model.totalLineCount):
    return
  result.line = line
  if col < area.col + gutW:
    result.onGutter = true
    return
  let codeCol = area.col + gutW
  result.column = col - codeCol + 1 + view.leftCol
  if not model.holdsLine(line):
    return
  let raw = model.heldTextAt(line)
  result.lineText = raw
  let annotations = model.annotationsAt(line, raw)
  if annotations.len > 0:
    let shown = cellWidthOf(cellSlice(raw, view.leftCol, view.leftCol + codeW))
    let start = codeCol + shown + AnnotationGap
    let targets = shownAnnotationTargets(annotations, codeW, shown)
    for t in targets:
      result.values.add t.value
    for i, t in targets:
      if col >= start + t.startCell and col < start + t.endCell:
        result.value = i
        result.column = 0
        break

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
