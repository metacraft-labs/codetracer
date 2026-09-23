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
##   * GPUI draws it as the code span's NEXT SIBLING in a flex row with no
##     absolute positioning, so its x is wherever the code ends (the window
##     frames show it: `test_plat42_window.nim`).
## The killer is an OVERLAY — the value drawn at a fixed position rather than
## after the code — which is exactly what an editor that cannot reflow
## (candidate B in the decision above) would have to do.
##
## THE CORPUS IS PLAT-24's EIGHTEEN DOCUMENTS, cardinality asserted, and the
## realised DOCUMENT set is asserted (§34b: class coverage is weaker by the
## multiplicity).
##
## No mocks: the shipped painter, the shipped surface builder, the real shim.

import std/[json, sets, strutils, unittest]

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
      # --- GPUI: the annotation FOLLOWS the code in a flex row. ------------
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
      ck childCount(rowEl) == 3            # gutter, code, annotation
      let code = nthChild(rowEl, 1)
      let ann = nthChild(rowEl, 2)
      ck getAttribute(code, TextRoleAttribute) == "editor-code"
      ck textContent(ann).startsWith("/*")
      # No absolute placement anywhere on the annotation: its position is the
      # flex layout's, i.e. the code's width.
      # Read from the RUST side's plan, not from what this case set.
      let plan = parseJson(renderPlanJson(r, rowEl))
      let annStyles = plan["children"][2]["styles"]
      ck annStyles{"position"}.getStr notin ["absolute", "fixed"]
      ck annStyles{"left"}.isNil

suite "PLAT-42 laws — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
