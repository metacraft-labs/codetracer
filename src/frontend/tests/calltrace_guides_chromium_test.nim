## calltrace_guides_chromium_test.nim — the call trace's guide lines meet the
## rows they connect, at the rows' real pitch and after a zoom (issue #849).
##
## The Call Trace pane's spec (`Call-Trace-Pane.md` § Visual Design) asks for
## "Vertical guides | Lines connecting parent to children". The guides are an
## absolutely positioned SVG layer (`#svg-content-0`) laid over the rows by
## `isonim_calltrace_view.renderTraceSvg`; the rows themselves are laid out by
## the browser from em-based CSS. A guide connects two rows only when its
## coordinates are the rows' coordinates, so this suite reads both off a real
## layout and compares them:
##
##   * every horizontal connector sits on the boundary between the two rows
##     it joins (the next row's top edge), within `TolerancePx`;
##   * its two ends sit on the centres of the two rows' toggles;
##   * the same still holds after the root font size changes — which is what
##     the desktop's Ctrl+= / Ctrl+- zoom does (`ui_js.nim` `updateLayout`
##     writes `documentElement.style.fontSize`) — with no other prompt to the
##     view than the layout change itself.
##
## The defect this pins: the SVG was laid out at a hard-coded 25 px per row
## with x offsets in fixed pixels, and its render effect depended only on the
## lines, so a row advance other than 25 px drifted by a little more every row
## (about 28 px by row 100 at the 25.28 px advance the desktop measured
## while rows with a return value were taller than the rest) and a zoom never
## moved it.
##
## ## WHY A BROWSER
##
## The property is geometric: it holds or fails in a LAYOUT, and only a
## browser lays out. jsdom answers 0 for every `getBoundingClientRect`, and
## `MockRenderer` has no pixels at all. This runs in headless Chromium through
## the `renderer-chromium` lane (`src/frontend/tests/chromium-run.mjs`).
##
## ## THE STYLESHEET
##
## `RowCss` restates the `calltrace.styl` rules that place a row and its
## toggle (`.calltrace-lines`, `.calltrace-row`, `.calltrace-child`,
## `.call-child-box`, `.toggle-call`, `.calltrace-svg-line`), in the same em
## units, so the rows scale with the root font size exactly as the app's do.
## One declaration is added on purpose: `margin-bottom: 0.0175em` on each row.
## It is ADVERSARIAL, not a model of the shipped stylesheet: it makes the row
## advance (25.28 px at 16 px) differ from the row box (25 px) and not be a
## whole number of pixels, so a drawer that assumes the advance is either one
## is caught. The shipped rows have advance == box (every row is 1.5625em,
## `ci/test/calltrace-row-box-in-browser.sh`), but a box that is not a whole
## number of pixels is ordinary — 20.3125 px at a 13 px root — and the
## guides must take the advance from the layout whatever it turns out to be.
## The desktop really did have an advance above its box once — rows showing a
## return value were ~0.8 px taller (codetracer-pm issue
## 2026-10-18-electron-calltrace-row-advance-exceeds-its-own-row-box) — which
## is the value this margin reproduces.
##
## ## NO MOCKS OF THE SUBJECT
##
## The view, its effects, its DOM and the browser are real. The store is fed
## by `updateCalltraceSection` and the backend behind it is
## `MockBackendService`, because nothing here talks to a debugger: the subject
## is how rows already in the store are drawn, and the backend is never asked
## anything after the store is created.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## `std/unittest` cannot `await`, so — as `view_vocabulary_chromium_test.nim`
## does — `ck` tallies, each case prints `[OK]` / `[FAILED]`, and the tally is
## compared with a number written from a run.

import std/[asyncjs, math, strutils]

import isonim/core/owner
import isonim/web/dom_api
import isonim/web/web_renderer

import ../viewmodel/backend/backend_service
import ../viewmodel/backend/mock_backend
import ../viewmodel/store/types
import ../viewmodel/store/replay_data_store
import ../viewmodel/viewmodels/calltrace_vm
import ../viewmodel/views/isonim_calltrace_view

# ---------------------------------------------------------------------------
# The page's side of the runner
# ---------------------------------------------------------------------------

proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}

proc body(): Element {.importjs: "(document.body)".}
proc newDiv(): Element {.importjs: "(document.createElement('div'))".}
proc appendEl(p, c: Element) {.importjs: "#.appendChild(#)".}
proc removeEl(e: Element) {.importjs: "#.remove()".}
proc qsaIn(e: Element; sel: cstring): seq[Element] {.importjs:
  "Array.from(#.querySelectorAll(#))".}
proc qsIn(e: Element; sel: cstring): Element {.importjs:
  "(#.querySelector(#) || null)".}
proc rectTop(e: Element): float {.importjs: "#.getBoundingClientRect().top".}
proc rectLeft(e: Element): float {.importjs: "#.getBoundingClientRect().left".}
proc rectHeight(e: Element): float {.importjs:
  "#.getBoundingClientRect().height".}
proc rectWidth(e: Element): float {.importjs: "#.getBoundingClientRect().width".}
proc numAttr(e: Element; name: cstring): float {.importjs:
  "Number(#.getAttribute(#))".}
proc setRootFontSize(px: cstring) {.importjs:
  "(document.documentElement.style.fontSize = #)".}
proc addStyle(css: cstring) {.importjs:
  "((c) => { const s = document.createElement('style'); s.textContent = c; document.head.appendChild(s); })(#)".}
proc sleepMs(ms: int): Future[void] {.importjs:
  "(new Promise((res) => setTimeout(res, #)))".}
proc nextFrame(): Future[void] {.importjs:
  "(new Promise((res) => requestAnimationFrame(() => requestAnimationFrame(res))))".}

# ---------------------------------------------------------------------------
# Counting
# ---------------------------------------------------------------------------

var checks = 0
var caseFailed = false
var failedCases = 0
var passedCases = 0

template ck(cond: untyped; detail: string = "") =
  inc checks
  if not (cond):
    caseFailed = true
    echo "    Check failed: " & astToStr(cond) &
      (if detail.len > 0: "  -- " & detail else: "")

proc beginCase() = caseFailed = false

proc endCase(name: string) =
  if caseFailed:
    inc failedCases
    echo "  [FAILED] " & name
  else:
    inc passedCases
    echo "  [OK] " & name

const ExpectedChecks = 22
  ## Written from a run. See the end of `main`.

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

const
  RowCount = 120
    ## Long enough that a per-row error of 0.28 px has grown past a whole
    ## row (25 px) by the last row, which is the reporter's symptom (#849).
  TolerancePx = 1.0
    ## Sub-pixel layout snaps row edges to 1/64 px; one CSS pixel is far
    ## above that and far below the 28 px the defect reaches.

  RowCss = """
.calltrace-view { width: 100%; display: flex; flex-direction: column; }
.calltrace-view .calltrace-lines { display: flex; flex-direction: column; position: relative; }
.calltrace-view .calltrace-child { white-space: nowrap; width: 100%; float: left; display: inline; }
.calltrace-view .calltrace-call-line { position: relative; margin-bottom: 0.0175em; }
.calltrace-view .calltrace-svg-line { position: absolute; overflow: visible; z-index: 1; pointer-events: none; }
.calltrace-view .calltrace-row { padding-left: 0.3125em; min-height: 1.55em; line-height: 1.55em; display: inline-flex; float: left; }
.calltrace-view .call-child-box { display: flex; align-items: center; z-index: 2; min-width: max-content; }
.calltrace-view .toggle-call { width: 0.875em; height: 1.5625em; display: block; margin-right: 0.25em; z-index: 2; }
.calltrace-view .call-text { padding-left: 0.125em; display: inline; }
"""

proc depthOf(i: int): int =
  ## A tree that goes down and back up, so connectors join rows of equal,
  ## deeper and shallower depth: 0 1 2 3 2 1 2 3 4 3 2 1 ...
  let k = i mod 8
  if k <= 4: k else: 8 - k

proc fixtureLines(): seq[CallLine] =
  for i in 0 ..< RowCount:
    result.add CallLine(
      index: int64(i),
      name: "f" & $i,
      depth: depthOf(i),
      rrTicks: uint64(100 + i),
      location: Location(file: "test.nim", line: i + 1),
      callKey: $i)

# ---------------------------------------------------------------------------
# Reading the layout and the guides
# ---------------------------------------------------------------------------

type
  Seg = tuple[x1, y1, x2, y2: float]

proc segments(svg: Element): seq[Seg] =
  for l in svg.qsaIn(cstring"line"):
    result.add (l.numAttr("x1"), l.numAttr("y1"), l.numAttr("x2"), l.numAttr("y2"))

proc connectors(segs: seq[Seg]): seq[Seg] =
  ## The horizontal connectors, in drawing order: one per adjacent row pair.
  for s in segs:
    if abs(s.y1 - s.y2) < 1e-6 and abs(s.x1 - s.x2) > 1e-6:
      result.add s
    elif abs(s.y1 - s.y2) < 1e-6 and abs(s.x1 - s.x2) <= 1e-6:
      # A zero-length "connector" between two rows of the same depth.
      result.add s

proc checkGuidesMeetRows(panel: Element; label: string) =
  ## Every connector k joins row k to row k+1: it lies on row k+1's top edge
  ## and runs from row k's toggle centre to row k+1's toggle centre. All
  ## coordinates are relative to the SVG's own box, which is where the
  ## guides' user units are drawn (`viewBox` = its CSS size, origin 0 0).
  let svg = panel.qsIn(cstring"#svg-content-0")
  ck not svg.isNil, label & ": the guide layer exists"
  if svg.isNil: return
  let rows = panel.qsaIn(cstring".calltrace-call-line")
  ck rows.len == RowCount, label & ": rows rendered " & $rows.len
  if rows.len != RowCount: return
  let originTop = svg.rectTop()
  let originLeft = svg.rectLeft()
  let segs = svg.segments()
  let cons = connectors(segs)
  ck cons.len == RowCount - 1,
    label & ": one connector per adjacent row pair, got " & $cons.len
  if cons.len != RowCount - 1: return

  var worstY, worstX = 0.0
  var worstYRow, worstXRow = -1
  for k in 0 ..< RowCount - 1:
    let boundary = rows[k + 1].rectTop() - originTop
    let dy = abs(cons[k].y1 - boundary)
    if dy > worstY:
      worstY = dy
      worstYRow = k
    let t0 = rows[k].qsIn(cstring".toggle-call")
    let t1 = rows[k + 1].qsIn(cstring".toggle-call")
    let c0 = t0.rectLeft() + t0.rectWidth() / 2.0 - originLeft
    let c1 = t1.rectLeft() + t1.rectWidth() / 2.0 - originLeft
    let dx = max(abs(cons[k].x1 - c0), abs(cons[k].x2 - c1))
    if dx > worstX:
      worstX = dx
      worstXRow = k
  let pitch = (rows[^1].rectTop() - rows[0].rectTop()) / float(RowCount - 1)
  echo "    " & label & ": row advance " & formatFloat(pitch, ffDecimal, 4) &
    " px, row box " & formatFloat(rows[0].rectHeight(), ffDecimal, 4) &
    " px; worst |dy| " & formatFloat(worstY, ffDecimal, 3) & " at row " &
    $worstYRow & ", worst |dx| " & formatFloat(worstX, ffDecimal, 3) &
    " at row " & $worstXRow
  ck worstY <= TolerancePx,
    label & ": connector " & $worstYRow & " is " &
    formatFloat(worstY, ffDecimal, 2) & " px off the row boundary"
  ck worstX <= TolerancePx,
    label & ": connector " & $worstXRow & " is " &
    formatFloat(worstX, ffDecimal, 2) & " px off a toggle centre"

  # The vertical guide of every row spans that row: from its top (its toggle
  # centre for the first row) to its bottom (its toggle centre for the last).
  var verticalSpanOk = true
  var firstBad = -1
  var vi = 0
  for s in segs:
    if abs(s.x1 - s.x2) < 1e-6 and s.y2 > s.y1:
      if vi < RowCount:
        let top = rows[vi].rectTop() - originTop
        let bottom = if vi + 1 < RowCount: rows[vi + 1].rectTop() - originTop
                     else: top + rows[vi].rectHeight()
        if s.y1 < top - TolerancePx or s.y2 > bottom + TolerancePx:
          if firstBad < 0: firstBad = vi
          verticalSpanOk = false
      inc vi
  ck vi == RowCount, label & ": one vertical guide per row, got " & $vi
  ck verticalSpanOk, label & ": vertical guide of row " & $firstBad &
    " leaves its row"

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

proc mountPanel(): (Element, Element, CalltraceVM) =
  let host = newDiv()
  body().appendEl(host)
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  var vm: CalltraceVM
  createRoot proc(dispose: proc()) =
    vm = createCalltraceVM(store)
    store.updateCalltraceSection(fixtureLines(), startIndex = 0'i64,
                                 totalCount = uint64(RowCount))
    discard appendChild(Node(host), Node(
      renderCalltracePanel[WebRenderer, Element](WebRenderer(), vm)))
  let panel = host.qsIn(cstring".isonim-calltrace")
  (host, panel, vm)

proc settle() {.async.} =
  ## Let the view's deferred measurement (a `setTimeout(0)` after the rows
  ## render) and any resize notification run, then let layout settle.
  await nextFrame()
  await sleepMs(50)
  await nextFrame()

proc caseGuidesMeetRowsAtTheMeasuredAdvance() {.async.} =
  beginCase()
  setRootFontSize(cstring"16px")
  let (host, panel, _) = mountPanel()
  await settle()
  checkGuidesMeetRows(panel, "16px")
  host.removeEl()
  endCase("the guides meet the rows at the rows' measured advance, " &
          "down to row " & $(RowCount - 1))

proc caseGuidesFollowAZoom() {.async.} =
  beginCase()
  setRootFontSize(cstring"16px")
  let (host, panel, _) = mountPanel()
  await settle()
  # Zoom in, as `zoomInEditors` does: the root font size changes and nothing
  # else is said to the view.
  setRootFontSize(cstring"20px")
  await settle()
  checkGuidesMeetRows(panel, "zoomed in to 20px")
  setRootFontSize(cstring"12px")
  await settle()
  checkGuidesMeetRows(panel, "zoomed out to 12px")
  host.removeEl()
  setRootFontSize(cstring"16px")
  endCase("the guides follow the rows through a zoom in and a zoom out")

proc main() {.async.} =
  addStyle(cstring RowCss)
  echo ""
  echo "[Suite] Call trace guide lines meet their rows (#849), in Chromium"
  await caseGuidesMeetRowsAtTheMeasuredAdvance()
  await caseGuidesFollowAZoom()
  beginCase()
  # THE TALLY. Compared with a number written from a run, so a case that
  # returned early is a count mismatch rather than a silent pass. `CHECKS:`
  # is the line the lane runner reads.
  inc checks
  echo "CHECKS: " & $checks
  if checks != ExpectedChecks:
    caseFailed = true
    echo "    assertion count is " & $checks & ", expected " & $ExpectedChecks
  endCase("every assertion above ran")
  ctFinish(if failedCases > 0: 1 else: 0)

discard main()
