## test_plat35_text_faces.nim — **TIER 3 for the one thing PLAT-35 aligned on
## 2026-10-02: the declared text face is the face that is drawn.**
##
## Run (needs the real `isonim-gpui` shim at the baked path):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_plat35_text_faces.nim
##
## ## What this suite is for
##
## `codetracer-specs/spec/Methodologies/visual-design-iteration.md` tier 3:
## *"measure the DOM, because pixels are bad at this … these are assertions,
## not comparisons, so they need no baseline and cannot drift. That makes them
## the most durable checks in the stack, and they should carry as much of the
## load as possible."*
##
## The finding they carry here was found by the tier-4 loop and could not have
## been found by any instrument this repository had. `leaves.gpuiMetricFor`
## DECLARED `mono/md/regular` for the editor's code, its gutter and its inline
## values — the Electron front-end's own measured buckets, moved there on
## 2026-09-20 *because* the cross-renderer gate said so — and the window drew
## all three in the proportional default, because nothing set `font-family` at
## all. The tier-3 comparison was green throughout: both arms answered `mono`,
## and one of them was answering about a declaration.
##
## The first macOS capture of the front-end's own scene is what caught it
## (*"code is set in a proportional sans, not monospace; `total = add(total,
## i)` glyph widths vary"*, three of six readings, 2026-10-02). These
## assertions are what stop it coming back without a human looking at a
## picture.
##
## ## The four claims, and why each needs the others
##
##   1. **The mapping is TOTAL over `TextRole`.** A role that resolved to ""
##      would keep the window's inherited proportional face and nothing would
##      say so.
##   2. **The two faces DIFFER.** Without this the whole mapping is vacuous:
##      one family for both classes satisfies claims 1 and 3 and draws every
##      role in one face, which is the state before this pass.
##   3. **The applied face is DERIVED from the declared metric**, role by role,
##      over the whole enum. Asserted against `gpuiMetricFor`'s own output
##      rather than against a list written here, so a role whose declaration
##      moves takes its face with it.
##   4. **The walk REACHES the editor's spans**, counted against an
##      independent count taken by this suite. `applyTextFaces` returning
##      without styling anything is the failure mode a `discard`ed call cannot
##      see.
##
## And one NEGATIVE claim, which is `PLAT35-VG8` measured rather than quoted:
##
##   5. **It does NOT reach a pane drawn through PLAT-3's medium-independent
##      tree**, because that tree carries no text role and therefore no
##      metric. The 2026-10-02 reviews reported exactly this from the pixels —
##      *"every value in the State pane still renders proportional"*, *"the
##      event-log table is still proportional"* — and the assertion here is
##      what makes the SCOPE of the gap exact instead of a surprise.

import std/[strutils, unittest]

import isonim_gpui/renderer

import ../app/leaves
import ../chrome
import ../main
import ../../view_vocabulary/editor_surface
import ../../view_vocabulary/pane_views
import ../../view_vocabulary/gpui_binding
import ../../../common/view_vocabulary

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

proc metricsIn(node: GpuiElement): int =
  ## How many elements of this subtree carry a text metric, counted
  ## INDEPENDENTLY of `applyTextFaces` — a second walk, so the production
  ## walk's own answer is compared against something and not against itself
  ## (`Verification-Harness-Traps` §30's two-copies rule turned the right way
  ## round: here two readings of one tree are the point).
  if node.isNil: return 0
  if getAttribute(node, TextMetricAttribute).len > 0:
    result = 1
  for i in 0 ..< childCount(node):
    result += metricsIn(nthChild(node, i))

proc rolesIn(node: GpuiElement; role: TextRole): int =
  if node.isNil: return 0
  if getAttribute(node, TextRoleAttribute) == $role:
    result = 1
  for i in 0 ..< childCount(node):
    result += rolesIn(nthChild(node, i), role)

proc sampleSurface(): EditorSurface =
  ## A three-row editor surface with one execution row, one marked row and one
  ## row carrying an inline value — enough that every mono role appears, and
  ## no debugger, no recording and no window are needed to assert over it.
  ## `EditorSurface` is a plain object precisely so this is possible.
  EditorSurface(
    medium: GpuiMedium,
    path: "calc/main.py",
    provenance: epVerified,
    viewportTop: 1,
    totalLineCount: 3,
    executionLine: 2,
    gutterVisible: true,
    productMode: pmDebug,
    rows: @[
      EditorRow(line: 1, text: "def add(a, b):", held: true),
      EditorRow(line: 2, text: "    return a + b", held: true,
                pointer: eptExecution,
                values: @[EditorValue(name: "a", value: "1")]),
      EditorRow(line: 3, text: "total = add(1, 2)", held: true,
                mark: emBreakpoint)])

suite "PLAT-35 tier 3 — the declared text face is the face that is drawn":

  test "the mapping is total over TextRole: no role resolves to no face":
    for role in TextRole:
      let metric = gpuiMetricFor(role)
      ck metric.len > 0
      ck fontFamilyForMetric(metric).len > 0

  test "the two faces differ, so the mapping is not vacuous":
    # WITHOUT THIS EVERY OTHER CLAIM HERE IS SATISFIED BY ONE FACE. The state
    # this suite was written against is exactly "one face for everything", and
    # a mono family equal to the proportional one reproduces it while leaving
    # the totality and the per-role derivation green.
    ck MonoFontFamily != WindowFontFamily
    ck fontFamilyFor(fcMono) != fontFamilyFor(fcProportional)

  test "each role's applied face is the face its DECLARED metric names":
    # Derived from `gpuiMetricFor`, which is the Electron front-end's own
    # measured bucket table (`mono/md/regular` for code and gutter,
    # `proportional/md/regular` for titles and variable names), so a
    # declaration that moves takes its face with it rather than leaving a
    # hardcoded list here to disagree with it.
    for role in TextRole:
      let declared = gpuiMetricFor(role).split('/')[0]
      let applied = fontFamilyForMetric(gpuiMetricFor(role))
      if declared == $fcMono:
        ck applied == MonoFontFamily
      else:
        ck declared == $fcProportional
        ck applied == WindowFontFamily

  test "the brief's third design goal, as an assertion":
    # "Monospace for code, gutter and inline values; proportional for pane
    # titles and variable names" — `tools/visual-review-brief.md` § Design
    # Goals. Written out by ROLE rather than derived, because this is the
    # requirement and the table above is the implementation: if the two ever
    # disagree, this case is the half that is right.
    ck fontFamilyForMetric(gpuiMetricFor(trEditorCode)) == MonoFontFamily
    ck fontFamilyForMetric(gpuiMetricFor(trGutterLineNumber)) == MonoFontFamily
    ck fontFamilyForMetric(gpuiMetricFor(trValueText)) == MonoFontFamily
    ck fontFamilyForMetric(gpuiMetricFor(trPaneTitle)) == WindowFontFamily
    ck fontFamilyForMetric(gpuiMetricFor(trValueName)) == WindowFontFamily

  test "an element with no metric, and an unreadable metric, are left alone":
    # NOT defaulted. An element the window did not declare a face for keeps
    # the family it inherits, and a metric this build cannot parse must not be
    # silently restyled into one of the two — that would be a face nobody
    # chose, drawn with the authority of one somebody did.
    ck fontFamilyForMetric("") == ""
    ck fontFamilyForMetric("serif/md/regular") == ""
    ck fontFamilyForMetric("mono") == MonoFontFamily  # face alone is enough

  test "the walk reaches every declared metric in a real editor tree":
    var r: GpuiRenderer
    let pane = r.createElement("div")
    let surface = sampleSurface()
    ck renderEditor(r, pane, sourcePaneView(GpuiMedium).root, surface)
    let declared = metricsIn(pane)
    # THE DENOMINATOR IS ASSERTED. A tree with no declared metrics would make
    # "the walk styled every one of them" true of nothing (§4's empty
    # numerator): three rows carry a gutter span and a code span each, so six
    # at the very least, plus the inline value on row 2.
    ck declared >= 2 * surface.rows.len
    ck rolesIn(pane, trGutterLineNumber) == surface.rows.len
    ck rolesIn(pane, trEditorCode) == surface.rows.len
    ck rolesIn(pane, trValueText) == 1
    ck applyTextFaces(r, pane) == declared

  test "PLAT35-VG8, measured: the medium-independent tree carries no metric":
    # **THE SCOPE OF THE GAP, ASSERTED RATHER THAN DISCOVERED FROM A PICTURE.**
    # The state, call-trace and event-log panes are drawn through PLAT-3's
    # medium-independent vocabulary tree, which publishes no text role — that
    # is `PLAT35-VG8`, filed — so `applyTextFaces` has nothing to act on there
    # and those panes keep the window's proportional face however many roles
    # the editor declares. The 2026-10-02 tier-4 readings saw it in the pixels
    # ("every value in the State pane still renders proportional"); this is
    # the same fact where it cannot drift.
    #
    # A pane view with no ViewModel reports rather than drawing data, and the
    # claim holds either way: the point is that NOTHING in that subtree
    # carries a metric, which a report satisfies as surely as a populated
    # pane. The editor case above is what stops this from being a claim about
    # an empty tree.
    var r: GpuiRenderer
    let pane = r.createElement("div")
    let pv = paneView(paneState, nil, GpuiPanelBudget, GpuiMedium)
    let binding = renderGpui(r, pv.root)
    r.appendChild(pane, binding.root)
    ck childCount(pane) > 0
    ck metricsIn(pane) == 0
    ck applyTextFaces(r, pane) == 0

  test "the case count":
    echo "PLAT-35 text-face checks: ", CHECKS
    ck CHECKS > 0
