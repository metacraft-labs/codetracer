## pane_measure_resize_loop_chromium_test.nim — measuring a pane stays out of
## the browser's ResizeObserver delivery, so a resize raises no error.
##
## `views/pane_measure_dom` reports a pane's size to its ViewModel whenever the
## pane is resized. When the State pane grows past what the stop was asked for,
## that report raises the value budget, the stop loader asks for the locals
## again, and `.loading-indicator` appears above the values, which makes the
## observed `.value-components-container` shorter. When all of that ran inside
## the observer's callback, the observed element had changed size at a depth
## the browser may not deliver in the same frame, so Chromium raised
## `ResizeObserver loop completed with undelivered notifications.` on `window`
## (https://drafts.csswg.org/resize-observer/#deliver-resize-loop-error). That
## event has a null `error`, which is the `Non-object error: null` line
## `verify_clean_console_on_trace_open` found in a clean trace open.
##
## The Playwright test saw it in about a third of the opens, because it needs a
## resize to land at the right moment of a trace open. This suite settles the
## pane first and then resizes it, so the same chain runs on every pass.
##
## The indicator has a second consequence, pinned here too: it is taller than a
## row, so showing and hiding it changes the pane's row count. While the budget
## followed that, each load caused the next, and a pane nobody touched kept
## asking for as long as the answers came (`stop_loader.localsBudgetToAsk`).
##
## ## WHY A BROWSER
##
## The error comes from the browser's own delivery loop. jsdom has no layout
## and no `ResizeObserver`, and its stand-in in `jsdom-run.mjs` observes
## nothing. This runs in headless Chromium through the `renderer-chromium`
## lane (`src/frontend/tests/chromium-run.mjs`).
##
## ## THE STYLESHEET
##
## `PaneCss` restates only what makes the indicator take height from the
## values: a fixed-height panel whose values fill what the rows above them
## leave (`components/state.styl`'s grid). The indicator's 24 px is the height
## measured in the app, where the values went from 399 px to 375 px.
##
## ## WHAT IS MOCKED, AND WHY
##
## `MockBackendService` stands in for the replay engine's transport, the one
## boundary this suite cannot run for real without a recording. It is deferred,
## so a locals request stays in flight across a frame as it does over the real
## transport. The session, `StateVM`, `StopLoader`, the rendered panel,
## `startMeasuringPane`, the observer and the layout are all real.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## `std/unittest` cannot `await`, so — as `calltrace_guides_chromium_test.nim`
## does — `ck` tallies, each case prints `[OK]` / `[FAILED]`, and the tally is
## compared with a number written from a run.

import std/[asyncjs, json]

import isonim/core/[computation, owner, signals]
import isonim/web/dom_api
import isonim/web/web_renderer

import ../viewmodel/backend/backend_service
import ../viewmodel/backend/mock_backend
import ../viewmodel/pane_viewport
import ../viewmodel/session_vm
import ../viewmodel/store/replay_data_store
import ../viewmodel/sdk/stop_loader
import ../viewmodel/viewmodels/state_vm
import ../viewmodel/views/isonim_state_view
import ../viewmodel/views/pane_measure_dom

# ---------------------------------------------------------------------------
# The page's side of the runner
# ---------------------------------------------------------------------------

proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}

proc body(): Element {.importjs: "(document.body)".}
proc newDiv(): Element {.importjs: "(document.createElement('div'))".}
proc appendEl(p, c: Element) {.importjs: "#.appendChild(#)".}
proc removeEl(e: Element) {.importjs: "#.remove()".}
proc qsIn(e: Element; sel: cstring): Element {.importjs:
  "(#.querySelector(#) || null)".}
proc setHostHeight(e: Element; px: int) {.importjs:
  "#.style.height = (# + 'px')".}
proc setClass(e: Element; cls: cstring) {.importjs: "#.className = #".}
proc clientHeightOf(e: Element): int {.importjs: "#.clientHeight".}
proc addStyle(css: cstring) {.importjs:
  "((c) => { const s = document.createElement('style'); s.textContent = c; document.head.appendChild(s); })(#)".}
proc nextFrame(): Future[void] {.importjs:
  "(new Promise((res) => requestAnimationFrame(() => requestAnimationFrame(res))))".}

proc installLoopErrorCounter() {.importjs: """
  (() => {
    window.ctLoopErrors = 0;
    // Consumed here: the suite asserts on the count, and the control below
    // raises this event on purpose.
    window.addEventListener('error', (event) => {
      if (String(event.message).includes('ResizeObserver loop')) {
        window.ctLoopErrors += 1;
        event.preventDefault();
      }
    });
  })()
""".}
proc loopErrors(): int {.importjs: "(window.ctLoopErrors)".}

proc raiseLoopErrorOnPurpose(el: Element) {.importjs: """
  ((el) => {
    // The shape the browser refuses to deliver: a callback that resizes the
    // element it observes.
    let grown = false;
    const ro = new ResizeObserver(() => {
      if (grown) return;
      grown = true;
      el.style.height = (el.clientHeight + 10) + 'px';
    });
    ro.observe(el);
    window.ctControlObserver = ro;
  })(#)
""".}
proc stopControl() {.importjs: "window.ctControlObserver.disconnect()".}

proc stopInSameDelivery(el: Element; stop: proc()) {.importjs: """
  ((el, stop) => {
    // Observers are delivered in creation order, so this one runs after the
    // pane's: between the pane scheduling its report and the frame running it.
    let first = true;
    const ro = new ResizeObserver(() => {
      if (first) { first = false; return; }
      ro.disconnect();
      stop();
    });
    ro.observe(el);
  })(#, #)
""".}

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

const ExpectedChecks = 16
  ## Written from a run. See the end of `main`.

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

const
  RowPx = 22
    ## `pane_measure_dom`'s `StateRowFallbackPx`: the pane has no rows to
    ## measure, so this is the pitch its report divides by.
  ShortPx = 300
    ## Mounted at this height, whose budget is below the 3000 asked for before
    ## the pane is measured.
  TallPx = 800
    ## Tall enough that its budget is above that 3000, so growing to it has to
    ## ask for more.
  SettleRounds = 30
    ## Frames given to the pane to come to rest. Far above the handful a
    ## settled pane needs, so that a pane that never rests is seen as one.

  PaneCss = """
.pane-host { position: absolute; top: 0; left: 0; width: 400px; }
.pane-host .isonim-state { display: flex; flex-direction: column; height: 100%; }
.pane-host .variables-toolbar,
.pane-host #code-state-line-0,
.pane-host #gdb-evaluate { flex: none; height: 0; overflow: hidden; }
.pane-host .loading-indicator { flex: none; height: 24px; overflow: hidden; }
.pane-host .value-components-container { flex: 1; min-height: 0; overflow: auto; }
"""

type
  Pane = ref object
    mock: MockBackendService
    session: SessionViewModel
    loader: StopLoader
    host: Element
    scroller: Element
    stop: StopMeasuring
    dispose: proc()

proc localsAnswer(): JsonNode =
  %*{"success": true, "body": {"locals": []}}

proc sentLocals(p: Pane): int =
  for c in p.mock.receivedCommands:
    if c.command == "ct/load-locals":
      inc result

proc comeToRest(p: Pane): Future[void] {.async.} =
  ## Answer what the pane asks, a frame late as the real transport does, so
  ## that the indicator is laid out while a load is in flight.
  for _ in 0 ..< SettleRounds:
    await nextFrame()
    p.mock.settleAllDeferred(localsAnswer())
    await nextFrame()

proc mountPane(): Future[Pane] {.async.} =
  ## A State pane at a stop, measured, with its first answers in.
  let p = Pane(mock: newMockBackendService(autoRespond = true))
  p.mock.deferResponses = true
  p.session = createSessionVM(p.mock.toBackendService())
  p.session.store.claimLocalsLoading()
  p.session.initializePanelViewModels()
  p.loader = createStopLoader(p.session, {spLocals})
  p.loader.follow()
  p.session.store.updateDebuggerPosition(100, "/src/main.py", 3)

  p.host = newDiv()
  p.host.setClass(cstring"pane-host")
  p.host.setHostHeight(ShortPx)
  body().appendEl(p.host)
  let pane = p
  createRoot proc(dispose: proc()) =
    pane.dispose = dispose
    let panel = renderStatePanel[WebRenderer, Element](WebRenderer(),
                                                       pane.session.stateVM)
    pane.host.appendEl(panel)
    pane.stop = startMeasuringPane(pane.host, mpState, pane.session)
  p.scroller = p.host.qsIn(cstring".value-components-container")
  await p.comeToRest()
  result = p

proc unmount(p: Pane) =
  if not p.stop.isNil:
    p.stop()
  p.dispose()
  p.host.removeEl()

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

proc caseControlTheCounterSeesTheError() {.async.} =
  ## Without this, "no error was counted" could mean the counter is deaf.
  beginCase()
  let el = newDiv()
  el.setHostHeight(50)
  body().appendEl(el)
  let before = loopErrors()
  raiseLoopErrorOnPurpose(el)
  await nextFrame()
  ck loopErrors() > before, "the counter never saw the browser's error"
  stopControl()
  el.removeEl()
  endCase("control: a callback resizing what it observes is counted")

proc caseAResizeRaisesNoLoopError() {.async.} =
  beginCase()
  let p = await mountPane()
  let before = loopErrors()
  let loadsBefore = p.sentLocals()
  p.host.setHostHeight(TallPx)
  await nextFrame()
  ck loopErrors() == before,
    "the resize raised " & $(loopErrors() - before) & " loop error(s)"
  ck p.sentLocals() > loadsBefore,
    "the resize must reach the loader, or this tested nothing"
  ck p.mock.pendingDeferredCount() > 0, "the reload must be in flight"
  ck p.scroller.clientHeightOf == TallPx - 24,
    "the indicator must have taken its height from the values: " &
    $p.scroller.clientHeightOf
  p.unmount()
  endCase("a resize that shows the loading indicator raises no loop error")

proc caseTheReportReachesTheViewModel() {.async.} =
  beginCase()
  let p = await mountPane()
  ck p.session.stateVM.viewport.val.measured, "the pane was never measured"
  p.host.setHostHeight(TallPx)
  await p.comeToRest()
  ck p.scroller.clientHeightOf == TallPx,
    "the indicator must be gone at rest: " & $p.scroller.clientHeightOf
  let shown = p.session.stateVM.viewport.val
  ck shown == pixelPaneViewport(float(TallPx), 400.0, float(RowPx), 0.0,
                                0.0, countPartialRow = true),
    "the resting size was not reported: rows=" & $shown.rows
  p.unmount()
  endCase("the pane's final size reaches the ViewModel")

proc caseTheLoadsComeToRest() {.async.} =
  ## The indicator is taller than a row, so its appearing and going changes
  ## the row count the budget is worked out from.
  beginCase()
  let p = await mountPane()
  let settledLoads = p.sentLocals()
  await p.comeToRest()
  ck p.sentLocals() == settledLoads,
    "a pane nobody touched kept asking: " & $settledLoads & " -> " &
    $p.sentLocals()
  p.host.setHostHeight(TallPx)
  await p.comeToRest()
  let afterResize = p.sentLocals()
  ck afterResize - settledLoads == 1,
    "one resize cost " & $(afterResize - settledLoads) & " locals loads"
  await p.comeToRest()
  ck p.sentLocals() == afterResize, "the loads did not come to rest: " &
    $afterResize & " -> " & $p.sentLocals()
  ck p.mock.pendingDeferredCount() == 0, "a load is still in flight"
  p.unmount()
  endCase("a resize costs a bounded number of loads and then stops")

proc caseAResizeBurstCoalesces() {.async.} =
  beginCase()
  let p = await mountPane()
  let loadsBefore = p.sentLocals()
  for px in [400, 500, 600, 700, TallPx]:
    p.host.setHostHeight(px)
  await nextFrame()
  ck p.sentLocals() - loadsBefore == 1,
    "five resizes in one task sent " & $(p.sentLocals() - loadsBefore) &
    " locals loads"
  p.unmount()
  endCase("a burst of resizes in one task costs one report")

proc caseStoppingCancelsAPendingReport() {.async.} =
  beginCase()
  let p = await mountPane()
  let shownBefore = p.session.stateVM.viewport.val
  let loadsBefore = p.sentLocals()
  stopInSameDelivery(p.scroller, p.stop)
  await nextFrame()
  p.host.setHostHeight(TallPx)
  await nextFrame()
  await nextFrame()
  ck p.session.stateVM.viewport.val == shownBefore,
    "a stopped pane still reported rows=" &
    $p.session.stateVM.viewport.val.rows
  ck p.sentLocals() == loadsBefore, "a stopped pane still caused a load"
  p.stop = nil
  p.unmount()
  endCase("stopping the measurement cancels a report already scheduled")

proc main() {.async.} =
  addStyle(cstring PaneCss)
  installLoopErrorCounter()
  echo ""
  echo "[Suite] Measuring a pane raises no ResizeObserver loop, in Chromium"
  await caseControlTheCounterSeesTheError()
  await caseAResizeRaisesNoLoopError()
  await caseTheReportReachesTheViewModel()
  await caseTheLoadsComeToRest()
  await caseAResizeBurstCoalesces()
  await caseStoppingCancelsAPendingReport()
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
