## PLAT-42 — LAW-E1 (the surface partition) and LAW-E2 (inline values reflow),
## over PLAT-24's EIGHTEEN corpus documents, on both native media.
##
## Run (tui lane flags — it links both renderers, as PLAT-34's observed suite
## does):
##   nim c -r <tui flags> src/frontend/tui/tests/test_plat42_laws.nim
##
## **LAW-E1 — THE SURFACE PARTITION.** For every row of a rendered editor,
## each of the four concerns is PRESENT on the row, ABSENT from it, or
## DEGRADED with a named reason — and the three are exhaustive. A degraded
## concern must name its filed gap; an absent one must not pretend to be
## degraded, and a degraded one must never render as absent (the silent
## repair `srEmpty`-for-`srUnreadable` was). The twin: with a breakpoint on one
## line, per-line status is PRESENT there and ABSENT on every other row.
##
## **LAW-E2 — INLINE VALUES REFLOW.** The inline value occupies a position the
## CODE's width determines, on both media:
##   * the terminal paints it at `gutter + display width of the code + gap`,
##     in CELLS — so a line of double-width CJK pushes it twice as far as the
##     same number of ASCII characters would;
##   * GPUI draws it as the desktop's flow draws it (since 2026-10-17): chips
##     ABSOLUTELY placed in the code column at `left = (line length + 1)` of
##     the flow container's `ch` (10.18 px, `ui/flow.nim`'s
##     `calc(<len>ch + 1ch)`, measured) less the horizontal scroll, `top`
##     2 px — so its x is still the CODE's length, per line (the window
##     frames show it: `test_plat42_window.nim` measures each chip's x there).
## The killer is an OVERLAY — the value drawn at a fixed position rather than
## after the code — which is exactly what an editor that cannot reflow
## (candidate B in the decision above) would have to do. Placing by the code's
## length is asserted per document, and that the eighteen documents' values do
## NOT all land at one x is asserted over the corpus.
##
## THE CORPUS IS PLAT-24's EIGHTEEN DOCUMENTS, cardinality asserted, and the
## realised DOCUMENT set is asserted (§34b: class coverage is weaker by the
## multiplicity).
##
## No mocks: the shipped painter, the shipped surface builder, the real shim.

import std/[json, math, sets, strutils, unittest]
from std/unicode import runeLen

import codetracer_embed
import isonim_gpui/renderer
import isonim_gpui/bindings
import gpui/app/leaves
import ../app/views/source_pane
import ../app/source_binding
import ../../view_vocabulary/editor_surface
import ../../view_vocabulary/pane_views
import ../../viewmodel/tests/generators/vocabulary_generator

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  CorpusSize = 18
  Cols = 200
  FlowCh = 10.18
    ## The desktop flow container's `ch`, in px — the unit its inline values
    ## are placed in (`ui/flow.nim`'s `flowLeftStyle`), measured on its six
    ## reference states. Spelled here, not imported, so the law is the
    ## desktop's rule and not the renderer's own constant read back.

var chipLefts: seq[string] = @[]
  ## Every document's chip `left` AS THE PLAN HAS IT, for the corpus-wide
  ## overlay twin.

type
  Presence = enum
    prPresent, prAbsent, prDegraded

proc carries(row: EditorRow; c: EditorConcern): bool =
  case c
  of ecExecutionPointer: row.pointer != eptNone
  of ecLineStatus: row.mark != emNone
  of ecInlineValues: row.values.len > 0
  of ecFlowOverlay: row.flow != efsUnknown

proc presence(s: EditorSurface; row: EditorRow; c: EditorConcern): Presence =
  ## LAW-E1's classification, from the SURFACE the medium was handed.
  case s.support[c]
  of esDegraded: prDegraded
  of esAbsent: prAbsent
  of esRendered: (if row.carries(c): prPresent else: prAbsent)

proc reasonFor(c: EditorConcern): string =
  ## The filed gap a degraded concern names, or "".
  for g in FiledEditorGaps:
    if g.concern == c: return $g.id
  ""

proc firstLine(d: ScenarioDoc): string =
  for l in d.text.splitLines():
    if l.strip.len > 0: return l
  d.text

let docs = scenarioDocs()

suite "PLAT-42: the corpus":
  test "it is PLAT-24's eighteen documents, and every one is realised":
    ck docs.len == CorpusSize
    var ids = initHashSet[string]()
    for d in docs: ids.incl d.id
    ck ids.len == CorpusSize

suite "PLAT-42: LAW-E1 — the surface partition":

  for d in docs:
    test "every row x concern is present, absent or degraded-with-a-reason — " & d.id:
      let path = "doc.txt"
      for medium in [GpuiMedium, "terminal"]:
        # WITHOUT points: per-line status has no producer, so it is DEGRADED
        # and names PLAT22-PG1 — on every row, never "absent".
        let bare = editorSurfaceForProject(path, d.text, medium, false)
        ck bare.rows.len > 0
        var counts: array[Presence, int]
        for row in bare.rows:
          for c in EditorConcern:
            let p = bare.presence(row, c)
            inc counts[p]
            if p == prDegraded:
              ck reasonFor(c).len > 0
        ck counts[prPresent] + counts[prAbsent] + counts[prDegraded] ==
           bare.rows.len * EditorConcerns.card
        for row in bare.rows:
          ck bare.presence(row, ecLineStatus) == prDegraded
        ck reasonFor(ecLineStatus) == "PLAT22-PG1"
        # WITH a breakpoint on line 1: per-line status is PRESENT there and
        # ABSENT on every other row — the twin a renderer that marks every
        # row fails.
        let marked = editorSurfaceForProject(path, d.text, medium, false,
          points = [EditorPoint(path: path, line: 1, kind: epkBreakpoint,
                                enabled: true)])
        var present: seq[int] = @[]
        for row in marked.rows:
          case marked.presence(row, ecLineStatus)
          of prPresent: present.add row.line
          of prAbsent: discard
          of prDegraded: ck false
        ck present == @[1]

suite "PLAT-42: LAW-E2 — inline values reflow, on both media":

  for d in docs:
    test "the value is placed by the code's width — " & d.id:
      # The doc's first line, with ` x` appended so a whole-word name is on
      # it whatever script the line is in.
      let line = firstLine(d) & " x"
      let values = @[EditorValue(name: "x", value: "1")]
      # --- THE TERMINAL: in cells. ----------------------------------------
      let model = initSourcePaneModel(
        path = "doc.txt", firstHeldLine = 1, heldLines = @[line],
        totalLineCount = 1, viewportTop = 1, executionLine = 1,
        values = annotationsOf(values))
      var g = newStyledGrid(Cols, 3)
      let screen = paintSourcePane(g, CellArea(col: 0, row: 0, width: Cols,
                                               height: 3), model)
      let painted = rowText(screen.rows[1])
      let codeCells = cellWidthOf(line)
      let wantCol = screen.gutterWidth + codeCells + AnnotationGap
      # The column the annotation STARTS at, in cells.
      var col = 0
      var at = -1
      for span in screen.rows[1]:
        if span.text.startsWith("/*") and at < 0: at = col
        col += cellWidthOf(span.text)
      checkpoint(d.id & ": code " & $codeCells & " cells, annotation at " &
                 $at & ", want " & $wantCol & " | " & painted)
      ck at == wantCol
      # --- GPUI: the chips are placed BY THE CODE'S LENGTH. ----------------
      gpui_reset_tree()
      var r: GpuiRenderer
      let parent = r.createElement("div")
      var surface = editorSurfaceForProject("doc.txt", line, GpuiMedium, false)
      ck surface.rows.len == 1
      surface.rows[0].values = values
      surface.rows[0].pointer = eptExecution
      discard renderEditor(r, parent, sourcePaneView(GpuiMedium).root, surface)
      var rowEl: GpuiElement = nil
      var stack = @[parent]
      while stack.len > 0:
        let n = stack.pop()
        if getAttribute(n, EditorRowAttribute).len > 0: rowEl = n
        for i in 0 ..< childCount(n): stack.add nthChild(n, i)
      ck not rowEl.isNil
      # gutter, then the code column (PLAT-47 B1: the band's extent), which
      # holds the code and the inline values — found by role, since the
      # column also carries the indent guides of an indented line.
      ck childCount(rowEl) == 2
      let column = nthChild(rowEl, 1)
      var codeAt, annAt = -1
      var codes, anns = 0
      for i in 0 ..< childCount(column):
        let c = nthChild(column, i)
        if getAttribute(c, TextRoleAttribute) == "editor-code":
          codeAt = i
          inc codes
        if getAttribute(c, InlineValuesAttribute).len > 0:
          annAt = i
          inc anns
      ck codes == 1
      ck anns == 1
      ck annAt > codeAt
      if codes == 1 and anns == 1:
        let ann = nthChild(column, annAt)
        # The row's values, as `inlineValueText` spells them for a plan reader,
        # and drawn as ONE chip naming `x` and showing `1`.
        ck getAttribute(ann, InlineValuesAttribute) == inlineValueText(values)
        ck childCount(ann) == 1
        ck textContent(ann) == "x1"
        # THE PLACEMENT, read from the RUST side's plan, not from what this case
        # set: absolute in the code column, at the code's length + 1 in the
        # flow's `ch` (nothing here scrolls, so no columns are skipped).
        let plan = parseJson(renderPlanJson(r, rowEl))
        let colPlan = plan["children"][1]
        let annStyles = colPlan["children"][annAt]["styles"]
        let wantLeft = int(round(float(line.runeLen + 1) * FlowCh))
        checkpoint(d.id & ": " & $line.runeLen & " runes, chip styles " &
                   $annStyles & ", want left " & $wantLeft & "px")
        ck colPlan["styles"]{"position"}.getStr == "relative"
        ck annStyles{"position"}.getStr == "absolute"
        ck annStyles{"left"}.getStr == $wantLeft & "px"
        ck annStyles{"top"}.getStr == "2px"
        chipLefts.add annStyles{"left"}.getStr

  test "the corpus's values are not all at one x (the OVERLAY twin)":
    # A renderer that drew every value at a fixed x passes no per-document
    # case above; over eighteen first lines of different lengths it would
    # also leave one distinct `left` here.
    checkpoint("chip lefts: " & $chipLefts)
    ck chipLefts.len == CorpusSize
    ck chipLefts.toHashSet.len > 1

suite "PLAT-42: the flow overlay as GPUI draws it, read from the Rust plan":

  test "a not-taken row's code is at half opacity; a taken or unknown row's is not":
    gpui_reset_tree()
    var r: GpuiRenderer
    let parent = r.createElement("div")
    var surface = editorSurfaceForProject("doc.txt", "a\nb\nc\n", GpuiMedium,
                                          false)
    ck surface.rows.len >= 3
    surface.rows[0].flow = efsTaken
    surface.rows[1].flow = efsNotTaken
    surface.rows[2].flow = efsUnknown
    discard renderEditor(r, parent, sourcePaneView(GpuiMedium).root, surface)
    let plan = parseJson(renderPlanJson(r, parent))
    var opacityByFlow: seq[(string, string)] = @[]
    proc walk(n: JsonNode) =
      let a = n{"attributes"}
      if not a.isNil and a{"data-ct-flow"}.getStr.len > 0:
        let code = n["children"][1]["children"][0]
        opacityByFlow.add (a["data-ct-flow"].getStr,
                           code["styles"]{"opacity"}.getStr)
      for c in n{"children"}.getElems: walk(c)
    walk(plan)
    checkpoint($opacityByFlow)
    ck ("efsNotTaken", FlowNotTakenOpacity) in opacityByFlow
    ck ("efsTaken", "") in opacityByFlow
    ck ("efsUnknown", "") in opacityByFlow

suite "PLAT-42: the execution row's band and the one-line rows, read from the Rust plan":

  test "the band is on the execution row and on no other; every row is one line":
    # PLAT-39's reader finds the execution line by this band (its GAP 3 was
    # that GPUI drew none). The twin: a renderer that banded every row, or
    # none, fails. And every row keeps its line on one row — a wrapped row
    # takes the rows of the lines below it (the noir inline value did).
    gpui_reset_tree()
    var r: GpuiRenderer
    let parent = r.createElement("div")
    var surface = editorSurfaceForProject("doc.txt", "a\nb\nc\nd\n", GpuiMedium,
                                          false)
    ck surface.rows.len >= 4
    surface.rows[2].pointer = eptExecution
    discard renderEditor(r, parent, sourcePaneView(GpuiMedium).root, surface)
    let plan = parseJson(renderPlanJson(r, parent))
    var banded: seq[(string, string)] = @[]
    var wraps: seq[(string, string)] = @[]
    proc walk(n: JsonNode) =
      let a = n{"attributes"}
      if not a.isNil and a{EditorRowAttribute}.getStr.len > 0:
        let st = n["styles"]
        wraps.add (st{"white_space"}.getStr, st{"overflow"}.getStr)
        # PLAT-47 B1: the band is Monaco's — on the CODE COLUMN (the row's
        # second child), not under the gutter. The row itself carries none.
        if st{"bg"}.getStr.len > 0:
          banded.add (a[EditorRowAttribute].getStr & ":row", st{"bg"}.getStr)
        let gutterBg = n["children"][0]["styles"]{"bg"}.getStr
        if gutterBg.len > 0:
          banded.add (a[EditorRowAttribute].getStr & ":gutter", gutterBg)
        let column = n["children"][1]["styles"]
        if column{"bg"}.getStr.len > 0:
          banded.add (a[EditorRowAttribute].getStr, column{"bg"}.getStr)
      for c in n{"children"}.getElems: walk(c)
    walk(plan)
    checkpoint("banded rows: " & $banded)
    ck wraps.len == surface.rows.len
    for w in wraps:
      ck w == ("nowrap", "hidden")
    ck banded == @[($surface.rows[2].line, ExecutionRowBand)]

suite "PLAT-42 laws — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
