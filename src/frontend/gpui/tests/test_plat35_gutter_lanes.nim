## test_plat35_gutter_lanes.nim — **TIER 3 OVER THE GUTTER'S LANES:
## `PLAT35-F13` and `PLAT35-F14`.**
##
## Run (needs the real `isonim-gpui` shim at the baked path, like every suite
## that imports `app/leaves`):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_plat35_gutter_lanes.nim
##
## ## The two findings, and why they are asserted here rather than read
##
## `codetracer-specs/spec/Methodologies/visual-design-iteration.md` tier 3:
## *"these are assertions, not comparisons, so they need no baseline and
## cannot drift. That makes them the most durable checks in the stack, and
## they should carry as much of the load as possible."* Both findings were
## FOUND in tier 4 — an agent reading a frame — and both are expressible
## structurally, which is where they are put:
##
##   * **`PLAT35-F14` — the mark had no reserved lane.** `gutterText` put the
##     number field's padding IN FRONT of the lanes, so each lane's cell index
##     moved with the line number's digit count. Measured on the front-end's
##     own window plan, 1440x900, unstepped, `--replay-ops=setBreakpoint@1`:
##
##         line  1 (pointer)  [' ', '▶', ' ', '1']
##         line  2 (mark)     [' ', ' ', '●', '2']
##         line 10            [' ', ' ', '1', '0']
##
##     The dot and the TENS DIGIT both at cell index 2, in one frame.
##
##   * **`PLAT35-F13` — the breakpoint glyph did not read as a breakpoint.**
##     Two halves, both structural. The mark sat inside the ONE gutter span so
##     it took the line-number colour: the same window plan reported the
##     marked row's gutter run as `#575757`, byte-identical to its unmarked
##     neighbours, while that node's own `data-ct-token` already said
##     `gutter.breakpoint.enabled`. And `●` abutted its digit with ZERO cells
##     where `▶` had one, the one being an accident of the lanes' order rather
##     than a padding anybody chose.
##
## ## What each case would be satisfied by if it stood alone
##
## Stated because an assertion that cannot fail is the defect this campaign is
## about, and three of these need a partner:
##
##   1. *the lanes are one cell each at a fixed index* — satisfied by a gutter
##      with no number field at all, so the width case pins the total.
##   2. *digits never reach the lanes* — satisfied by a gutter that drew no
##      mark, so the case before it asserts the glyph IS in the mark's cell.
##   3. *the mark's colour is not the line numbers'* — satisfied by painting
##      every mark one arbitrary colour, so the Electron case reads the colour
##      out of the REFERENCE front-end's own stylesheet (§6) instead of out of
##      a literal here, and the `emNone` arm asserts the function is not
##      simply constant.
##
## ## The one thing this suite does NOT assert
##
## Pixels. Nothing here opens a window or reads a frame; the geometry and the
## colour are read from the functions that produce them. The frame-level
## reading is the tier-4 ledger's (`src/tests/visual/tier4-gpui-readings.json`)
## and the capture lane's (`ci/test/plat35-gpui-capture.sh`).
##
## ## Trap 13 / §29
##
## Every helper that calls `check` is a `template`. The `proc`s return values.

import std/[json, os, sequtils, sets, strutils, unicode, unittest]

import ../app/leaves
import ../../styles/generated/design_tokens
import ./plat42_gutter

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# ---------------------------------------------------------------------------
# THE POPULATIONS. Every count in the last case is a function of these, so a
# fifth mark or a fifth width moves the expected total without an edit.
# ---------------------------------------------------------------------------
const
  Marks = [emNone, emBreakpoint, emBreakpointDisabled, emTracepoint]
    ## Every `EditorMark`. Written out rather than iterated as `EditorMark` so
    ## the arity is a number the formula can use; the first case asserts the
    ## list IS the enum, so a fifth mark cannot be quietly left out of it.
  Pointers = [eptNone, eptInspection, eptExecution]
  Widths = [1, 2, 3, 4]
    ## Number-field widths. `renderEditor` derives it as the widest DRAWN line
    ## number, so 1..4 covers every file up to 9999 lines; the corpus's `calc`
    ## is 116 lines and draws 2 or 3.
  Lines = [1, 10, 100]
    ## One, two and three digits — the three cases whose DISAGREEMENT about a
    ## lane's cell index was `PLAT35-F14`.

  PointerLaneCell = 0
  MarkLaneCell = 1
  NumberFieldFirstCell = 3
    ## `<pointer><mark><lane gap><number field>`. Written here as the three
    ## numbers a reader of a FRAME would count, and asserted against
    ## `gutterRuns`' own output rather than derived from it, so this file is
    ## the half that is right if the two ever disagree.

  LaneGlyphs = [ExecutionPointerGlyph, InspectionPointerGlyph,
                BreakpointGlyph, BreakpointDisabledGlyph, TracepointGlyph]
    ## Every glyph that can occupy a lane. `EmptyLaneGlyph` is deliberately
    ## not here: it is the ABSENCE of a glyph and carries no ink.

  ElectronGutterStyles = "src/frontend/styles/components/text_editor.styl"
    ## The REFERENCE's own stylesheet, read at run time. Never transcribed: a
    ## copy here would be written from the same reading that produced
    ## `leaves.markColour`, and the two would agree about a misreading (§30).

  ScenariosRel = "src/tests/visual/scenarios.json"

  MaxGutterClusters = 3
    ## `screen_oracle/vision_producer`'s own constant, quoted rather than
    ## imported: it is declared without a `*` and importing that module would
    ## pull the OCR stack into a suite that needs no pixels. See the case that
    ## uses it for what the two numbers mean to each other.

type GutterCase = tuple[row: EditorRow, w: int]

proc requireFile(rel, why: string): string =
  ## Absent, this suite FAILS BY NAME rather than skipping.
  if not fileExists(rel):
    raise newException(IOError, rel & " is not here. " & why &
      " Run this suite from the repository root.")
  rel

proc gutterCases(): seq[GutterCase] =
  ## The whole cross product, as rows paired with the width they are drawn at.
  ##
  ## **A LINE LONGER THAN THE FIELD IS NOT IN THE POPULATION**, and that is
  ## not a convenience: `renderEditor` computes `widest` from the rows it is
  ## about to draw, so a surface never holds a line number wider than its own
  ## number field. Putting `line = 100` at `numberWidth = 1` in here would
  ## assert over a surface this front-end cannot build and would make the
  ## constant-width case fail for a reason no frame can show.
  for w in Widths:
    for m in Marks:
      for p in Pointers:
        for line in Lines:
          if len($line) <= w:
            result.add (row: EditorRow(line: line, mark: m, pointer: p,
                                       held: true), w: w)

proc cellsOf(row: EditorRow; numberWidth: int): seq[string] =
  ## One row's gutter as CELLS. The gutter face is monospaced
  ## (`gpuiMetricFor(trGutterLineNumber)`, applied by `main.applyTextFaces`
  ## out of `chrome.MonoFontFamily`), so one rune is one column and a cell
  ## index is an x.
  for r in gutterText(row, numberWidth).toRunes:
    result.add $r

proc isBlank(cell: string): bool =
  ## A cell with no ink: an ASCII space, or the no-break space `GutterGap` and
  ## `EmptyLaneGlyph` are written with.
  cell == " " or cell == EmptyLaneGlyph or cell == GutterLaneGap

proc isDigitCell(cell: string): bool =
  cell.len == 1 and cell[0] in {'0' .. '9'}

proc markCellOf(row: EditorRow; numberWidth: int): int =
  ## Which cell the row's mark glyph occupies, or -1 when it draws none.
  result = -1
  let glyph = markGlyph(row.mark)
  if glyph == EmptyLaneGlyph: return
  for i, c in cellsOf(row, numberWidth):
    if c == glyph: return i

proc inkGroups(row: EditorRow; numberWidth: int): int =
  ## How many runs of inked cells the gutter holds, separated by at least one
  ## blank. The CELL-level analogue of `vision_producer.inkClusters`.
  var inRun = false
  for c in cellsOf(row, numberWidth):
    if isBlank(c):
      inRun = false
    elif not inRun:
      inRun = true
      inc result

proc inkedLanes(row: EditorRow): int =
  ## How many of the row's two lanes carry a glyph.
  (if markGlyph(row.mark) != EmptyLaneGlyph: 1 else: 0) +
  (if pointerGlyph(row.pointer) != EmptyLaneGlyph: 1 else: 0)

proc backgroundTokenOf(styles, cls: string): string =
  ## The design-system token named by `background:` inside a `.<cls>` rule of a
  ## Stylus sheet — `colors-ui-text-error-primary` for
  ## `.gutter-breakpoint-enabled`. "" when the class or the declaration is not
  ## there, which the case below asserts against rather than tolerating.
  var seen = false
  for raw in styles.splitLines():
    let line = raw.strip()
    if not seen:
      if line == "." & cls:
        seen = true
      continue
    if line.startsWith("background:"):
      return line["background:".len .. ^1].strip()
    # A new selector before the declaration means that rule carried none.
    if line.startsWith("."):
      return ""
  ""

proc tokenSpelling(t: DesignToken): string =
  ## The token's published name in the stylesheet's spelling:
  ## `colors/ui/text/error/primary` -> `colors-ui-text-error-primary`.
  ## DERIVED from the generated enum, so a token the design system renames
  ## takes this comparison with it.
  ($t).replace("/", "-")

let Cases = gutterCases()
let scenarios = parseJson(readFile(requireFile(ScenariosRel,
  "It is the corpus declaration, and the UNSTEPPED breakpoint case these " &
  "findings need is declared in it.")))

suite "PLAT-35 tier 3 — the gutter's lanes":

  test "the populations are the enums, and the glyphs are distinct":
    # **§4 FIRST.** Every case below loops over `Marks`, `Pointers` and
    # `Cases`; a list that had lost a member would make all of them true of
    # less than the product while the formula still added up.
    var marks = initHashSet[EditorMark]()
    for m in Marks: marks.incl m
    var pointers = initHashSet[EditorPointer]()
    for p in Pointers: pointers.incl p
    for m in EditorMark: ck m in marks
    for p in EditorPointer: ck p in pointers
    ck Cases.len > 0
    # And the glyph table is not one glyph wearing five names: a gutter whose
    # marks were all `●` would satisfy every lane claim here.
    var glyphs = initHashSet[string]()
    for g in LaneGlyphs: glyphs.incl g
    ck glyphs.len == LaneGlyphs.len
    ck EmptyLaneGlyph notin glyphs
    echo "  population: ", Cases.len, " (row, numberWidth) case(s)"

  test "PLAT35-F14: each lane is ONE reserved cell at a FIXED index":
    # The three runs, in order, one cell each — so the pointer is always cell
    # 0 and the mark always cell 1, whatever the line number's digit count.
    for c in Cases:
      let runs = gutterRuns(c.row, c.w)
      ck runs[0].kind == grkPointer
      ck runs[1].kind == grkMark
      ck runs[2].kind == grkNumber
      ck runs[0].text.toRunes.len == 1
      ck runs[1].text.toRunes.len == 1
      let cells = cellsOf(c.row, c.w)
      ck cells[PointerLaneCell] == pointerGlyph(c.row.pointer)
      ck cells[MarkLaneCell] == markGlyph(c.row.mark)

  test "PLAT35-F14: a drawn mark is in the mark's cell and in no other":
    # **THE FINDING, AS THE ONE EQUALITY IT IS.** Before 2026-10-03 this index
    # was `max(0, numberWidth - len($line)) + 1`, so it was 1 on a row whose
    # number filled the field and 2 or 3 on a row whose number did not — the
    # same surface, the same lane, three different columns.
    for c in Cases:
      if markGlyph(c.row.mark) == EmptyLaneGlyph: continue
      ck markCellOf(c.row, c.w) == MarkLaneCell

  test "PLAT35-F14: no digit ever reaches the lanes or the gap between them":
    # The other side of the same equality, and the clause the frame showed:
    # the dot at cell 2 and line 10's TENS DIGIT at cell 2. Asserted over
    # every row of every surface, because the defect is that the mark formed
    # no column a reader could scan DOWN.
    for c in Cases:
      for i, cell in cellsOf(c.row, c.w):
        if isDigitCell(cell):
          ck i >= NumberFieldFirstCell

  test "PLAT35-F13: no lane glyph abuts a digit, in either lane":
    # The padding half. `●` had ZERO cells to its digit and `▶` had one; the
    # separation is now `GutterLaneGap`, declared once and the same for both
    # lanes however the number field is padded.
    #
    # A DIGIT and not "any ink": the two lanes ARE adjacent to each other by
    # design (`GutterLaneGap` is one cell and it sits between the lane block
    # and the number, not between the lanes — see its own comment for the
    # measured reason), so a row carrying both a pointer and a mark draws
    # `▶●` in cells 0 and 1. That is two glyphs of different shape and now of
    # different colour, and it is not what the finding is about: the finding
    # is a marker glyph crowded against a NUMBER.
    for c in Cases:
      let cells = cellsOf(c.row, c.w)
      for i, cell in cells:
        if cell in LaneGlyphs:
          ck i + 1 < cells.len
          ck not isDigitCell(cells[i + 1])
      # The gap cell itself, on EVERY row — the clause that was false exactly
      # when a mark was drawn on a row whose number filled the field.
      ck isBlank(cells[NumberFieldFirstCell - 1])

  test "PLAT35-F13: markColour is the mark's, and emNone is not repainted":
    # FOUR ARMS, and the `emNone` one is the two-sided half: a function that
    # returned one red for everything would satisfy every other claim here and
    # would paint the blank lane of every unmarked row.
    let resting = EditorLineNumberColour
    let active = EditorActiveLineNumberColour
    ck markColour(emNone, resting) == resting
    ck markColour(emNone, active) == active
    for m in Marks:
      if m == emNone: continue
      ck markColour(m, resting) != resting
      ck markColour(m, active) != active
      # Independent of what it would have inherited: a mark whose colour moved
      # with the cursor would be a mark whose meaning does.
      ck markColour(m, resting) == markColour(m, active)
    # The three drawn marks are three colours and not one.
    var hexes = initHashSet[string]()
    for m in Marks:
      if m == emNone: continue
      hexes.incl markColour(m, resting)
    ck hexes.len == Marks.len - 1

  test "PLAT35-F13: the mark's colour is the ELECTRON gutter's own token":
    # **THE REFERENCE, READ FROM THE REFERENCE** (§6: *"the Electron front-end
    # is the reference; where the reference is wrong, that is a change to the
    # Electron front-end and to the design system, never a licence for the
    # GPUI front-end to differ"*). The three classes are parsed out of the
    # shipped stylesheet and mapped through the GENERATED token table, so a
    # change to either side of the comparison reddens this case.
    let styles = readFile(requireFile(ElectronGutterStyles,
      "It is the Electron front-end's own gutter stylesheet, which is the " &
      "reference for what colour a gutter mark is."))
    let classes = [("gutter-breakpoint-enabled", emBreakpoint,
                    dtColorsUiTextErrorPrimary),
                   ("gutter-breakpoint-disabled", emBreakpointDisabled,
                    dtColorsUiSurfacePrimaryTertiary),
                   ("gutter-trace", emTracepoint, dtColorsUiBorderAction)]
    for entry in classes:
      let (cls, mark, token) = entry
      let named = backgroundTokenOf(styles, cls)
      checkpoint("." & cls & " background: " & named)
      # The class EXISTS and names a token — not a skip, and not "" compared
      # against "".
      ck named.len > 0
      ck named == tokenSpelling(token)
      ck markColour(mark, EditorLineNumberColour) ==
         DesignTokenHex[token][dmDark]

  test "PLAT35-F16 stays closed: one surface, one gutter width":
    # The lanes are one glyph each and the number field is padded, so every
    # row of one surface is the same number of cells wide and every row's code
    # starts in one column. That is what `PLAT35-F16` closed in iteration 2,
    # and moving the padding must not undo it.
    for w in Widths:
      var widths = initHashSet[int]()
      for c in Cases:
        if c.w == w:
          widths.incl cellsOf(c.row, c.w).len
      ck widths.len == 1
      # pointer + mark + lane gap + number field + `GutterGap`, as cells.
      ck 2 + 1 + w + GutterGap.toRunes.len in widths

  test "PLAT-39's reader still gets at most MaxGutterClusters from a gutter":
    # **THE INVARIANT ANOTHER MILESTONE DEPENDS ON, QUOTED AND ASSERTED.**
    # `screen_oracle/vision_producer.readGutterDigits` reads *"the shortest
    # prefix of the band's clusters (up to `MaxGutterClusters`) that parses as
    # `EditorGrammar`"*, and that constant is 3 with its own comment:
    # *"Electron's gutter is two clusters (the arrow, ~30 px left of the
    # number, then the number); GPUI's is one (`▶ 44`). A third covers a mark
    # drawn in its own lane."* So three lanes' worth of ink is what the reader
    # was built for.
    #
    # THIS IS A CELL COUNT AND THE READER'S IS A PIXEL COUNT, and the cell
    # count is the CONSERVATIVE direction: a pixel cluster boundary needs
    # `MinGutterGapPx = 14` of background, while one blank cell of this gutter
    # measured ~10 px in the iteration-3 reading of `editorWithMark` (*"the
    # pointer has 10px"* to its digit, which is exactly one empty lane). A
    # single blank cell therefore does not split a pixel cluster at all, so
    # every group counted here is at worst an over-count of the clusters the
    # reader sees.
    for c in Cases:
      ck inkGroups(c.row, c.w) <= MaxGutterClusters

  test "PLAT-42's own gutter reader still recovers the line, unchanged":
    # **THE OTHER MILESTONE'S READER, RUN RATHER THAN REASONED ABOUT.**
    # `tests/plat42_gutter.gutterLineOf` is the ONE reading of a row's line
    # number that PLAT-42's and PLAT-44's suites and committed records share,
    # and it skips leading non-digits up to `MaxLaneBytes = 12`. Moving the
    # padding from in front of the lanes to behind them adds ONE byte before
    # the first digit (the ASCII lane gap), so the question is whether that
    # reader still reads this gutter — and it is asked here by RUNNING it over
    # the whole population rather than by arguing about the budget.
    #
    # Nothing in `plat42_gutter.nim` changed but its comments
    # (`git diff` on it is comment-only): the reader did NOT have to move with
    # the geometry, and this case is what establishes that rather than
    # assuming it. The row text is the gutter followed by real code, because
    # that is what a reader is handed.
    for c in Cases:
      ck gutterLineOf(gutterText(c.row, c.w) & "def f():") == c.row.line

  test "the CORPUS declares an unstepped breakpoint case":
    # **THE HALF THAT IS ABOUT THE CORPUS AND NOT ABOUT THE WINDOW.**
    # `breakpoint-editor` is `stepIn=6, setBreakpoint@1`, and `setBreakpoint@n`
    # is an offset into the editor's FIRST DRAWN ROW, which after six stepIns
    # is 31 — so its mark lands on a two-digit row and that scenario CANNOT
    # fail the cases above. Reproducing `PLAT35-F14` took an ad-hoc probe, and
    # an assertion that cannot fail is the defect this campaign is about.
    #
    # `gpuiProbes` in `scenarios.json` is where the unstepped case is declared.
    # Why it is declared there rather than as a seventh member of `scenarios`
    # is in that file's own comment, measured: four other milestones pin the
    # six, two of them against records only a Wayland or Xvfb lane regenerates.
    # This case is what stops the probe being dropped again.
    let probes = scenarios{"gpuiProbes"}
    ck probes.kind == JArray
    ck probes.len == scenarios{"expectedGpuiProbes"}.getInt(-1)
    ck probes.len > 0
    let kinds = scenarios{"operationKinds"}.getElems.mapIt(it.getStr).toHashSet
    var unstepped = 0
    for p in probes:
      var setsABreakpoint = false
      var steps = 0
      for op in p{"operations"}:
        let kind = op{"kind"}.getStr
        # THE CLOSED VOCABULARY IS THE SAME ONE, so a probe cannot reach for
        # an operation no driver performs.
        ck kind in kinds
        if kind == "setBreakpoint": setsABreakpoint = true
        else: inc steps
      if setsABreakpoint and steps == 0: inc unstepped
      # A probe names a view of its own, so the capture lane's per-view file
      # name cannot collide with one of the six.
      ck p{"view"}.getStr.len > 0
      ck p{"viewport"}.getStr in scenarios{"viewports"}
    ck unstepped > 0

  test "every case ran":
    # **AN EXACT EQUALITY AGAINST A FORMULA, NOT AGAINST A CONSTANT**, so a
    # fifth mark or a fifth number width keeps this green while a CASE THAT
    # STOPS RUNNING still reddens it. Every term is a population counted from
    # the same declarations the cases loop over — never from `CHECKS`, which
    # would make this satisfied by its own subject.
    let nMarks = Marks.len
    let nPointers = Pointers.len
    let drawn = nMarks - 1            # the marks that draw a glyph
    var marked = 0                    # cases whose row draws a mark
    var digitCells = 0                # digit cells over the whole population
    var inked = 0                     # inked lanes over the whole population
    for c in Cases:
      if markGlyph(c.row.mark) != EmptyLaneGlyph: inc marked
      digitCells += len($c.row.line)
      inked += inkedLanes(c.row)
    var probeOps = 0
    let nProbes = scenarios{"gpuiProbes"}.len
    for p in scenarios{"gpuiProbes"}:
      probeOps += p{"operations"}.len
    let derived =
      (nMarks + nPointers + 3) +          # the populations case
      7 * Cases.len +                     # the reserved-lane case
      marked +                            # a drawn mark is in the mark's cell
      digitCells +                        # no digit reaches the lanes
      (2 * inked + Cases.len) +           # no lane glyph abuts a digit
      (2 + 3 * drawn + 1) +               # markColour's four arms
      3 * drawn +                         # the Electron classes
      2 * Widths.len +                    # one surface, one width
      Cases.len +                         # PLAT-39's cluster bound
      Cases.len +                         # PLAT-42's reader, re-run
      (4 + probeOps + 2 * nProbes) +      # the corpus case
      1                                   # this equality itself
    checkpoint("CHECKS " & $CHECKS & " derived " & $derived)
    ck CHECKS == derived
    echo "PLAT-35 gutter-lane checks: ", CHECKS, " (derived ", derived,
         " from ", Cases.len, " case(s), ", nProbes, " probe(s))"
