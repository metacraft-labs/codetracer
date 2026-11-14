## flow_loop_slider_chromium_test.nim — a review's loop slider is built when
## its control is laid out, however late that is.
##
## A review's loop control lives in a Monaco view zone (`ui/unified_diff.nim`),
## and noUiSlider must never be built over an element with no box (#562,
## `ui/flow_loop_slider.nim` lesson 1). The review used to come back on a timer,
## twenty tries over ~3 s. A control revealed by a context expansion on a
## loaded machine was laid out after the last try, and kept its stepper
## without the slider for good: a desktop scenario
## (`src/tests/scenarios/deepreview/loop-slider-drag-picks-the-pass.yaml`)
## found it in two of two realistic runs. `ensureFlowLoopSliderWhenLaidOut`
## waits for the layout itself instead.
##
## The cases:
##
##   * an element laid out only after 3.5 s (later than the timer's last try)
##     gets its slider once it is laid out, and nothing is left observing it;
##   * an element already laid out gets its slider at once;
##   * an element removed before it was ever laid out leaves no observer
##     behind and is never built over;
##   * a loop with a single pass gets neither a slider nor an observer.
##
## ## WHY A BROWSER
##
## Being laid out is a layout fact, and the wait is a `ResizeObserver`: jsdom
## has neither (every `clientWidth` is 0, and its observer stand-in observes
## nothing). This runs in headless Chromium through the `renderer-chromium`
## lane (`src/frontend/tests/chromium-run.mjs`).
##
## ## NO MOCKS
##
## noUiSlider is the real library, the copy the desktop ships
## (`node_modules/nouislider`), loaded into the page with the suite. The
## element, its layout and the observer are the browser's.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## `std/unittest` cannot `await`, so — as `calltrace_guides_chromium_test.nim`
## does — `ck` tallies, each case prints `[OK]` / `[FAILED]`, and the tally is
## compared with a number written from a run.

import std/[asyncjs, dom, jsffi]

import ../ui/flow_loop_slider

const NoUiSliderSource = staticRead("../../../node_modules/nouislider/dist/nouislider.min.js")
{.emit: NoUiSliderSource.}

proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}
proc wait(ms: int): Future[void] {.importjs:
  "(new Promise((resolve) => setTimeout(resolve, #)))".}
proc frames(): Future[void] {.importjs:
  "(new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 50)))))".}
proc setHtml(html: cstring) {.importjs: "document.body.innerHTML = #".}
proc qs(sel: cstring): Node {.importjs: "document.querySelector(#)".}
proc show(node: Node) {.importjs:
  "((n) => { n.style.display = 'block'; })(#)".}
proc built(node: Node): bool {.importjs:
  "((n) => !!n.querySelector('.noUi-base') && !!n.noUiSlider)(#)".}
proc observing(node: Node): bool {.importjs: "(!!#.__ctSliderLayoutObserver)".}
proc widthOf(node: Node): int {.importjs: "(#.clientWidth)".}

var checks = 0
var caseFailed = false
var failedCases = 0

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
    echo "  [OK] " & name

const
  # The control as `unified_diff.loopZoneDom` draws it: a row whose slider is
  # the flex child that takes the space left over. `display: none` stands in
  # for a view zone Monaco has not laid out yet: the element has no box.
  Page = """
    <style>
      .review-loop-selector { display: flex; width: 400px; }
      .flow-loop-slider-container { flex: 1; }
      .flow-loop-slider { height: 6px; }
    </style>
    <div class="review-loop-selector" id="zone" style="display: none">
      <span>iteration 1 / 3</span>
      <div class="flow-loop-slider-container">
        <div class="flow-loop-slider" id="slider"></div>
      </div>
    </div>
  """
  ExpectedChecks = 16

proc caseLaidOutLate() {.async.} =
  beginCase()
  setHtml(Page)
  let slider = qs("#slider")
  var passes: seq[int]
  let now = ensureFlowLoopSliderWhenLaidOut(slider, 2, 0,
    proc(iteration: int) = passes.add iteration)
  ck not now, "an element with no box must not be built over"
  ck not slider.built
  # Later than the twenty tries the review used to make.
  await wait(3500)
  ck not slider.built, "built while it still had no box"
  show(qs("#zone"))
  await frames()
  ck slider.widthOf > 0
  ck slider.built, "the slider was not built once its control was laid out"
  ck not slider.observing, "the layout observer is still running"
  endCase("a control laid out after 3.5 s gets its slider when it is laid out")

proc caseLaidOutAlready() {.async.} =
  beginCase()
  setHtml(Page)
  show(qs("#zone"))
  let slider = qs("#slider")
  let now = ensureFlowLoopSliderWhenLaidOut(slider, 2, 1,
    proc(iteration: int) = discard)
  ck now
  ck slider.built
  ck not slider.observing
  endCase("a control already laid out gets its slider at once")

proc caseRemovedFirst() {.async.} =
  beginCase()
  setHtml(Page)
  let zone = qs("#zone")
  let slider = qs("#slider")
  discard ensureFlowLoopSliderWhenLaidOut(slider, 2, 0,
    proc(iteration: int) = discard)
  ck slider.observing
  # The zone is replaced (the controls are rebuilt wholesale) before it was
  # ever laid out; the old element is shown, detached, to give the observer
  # something to report.
  zone.parentNode.removeChild(zone)
  show(zone)
  await frames()
  ck not slider.observing, "a removed control is still observed"
  ck not slider.built
  endCase("a control removed before its layout leaves nothing running")

proc caseSingleLoopPass() {.async.} =
  beginCase()
  setHtml(Page)
  let slider = qs("#slider")
  let now = ensureFlowLoopSliderWhenLaidOut(slider, 0, 0,
    proc(iteration: int) = discard)
  ck not now
  ck not slider.observing, "a loop with one pass has nothing to wait for"
  show(qs("#zone"))
  await frames()
  ck not slider.built
  endCase("a loop with a single pass gets no slider and no observer")

proc main() {.async.} =
  echo ""
  echo "[Suite] a review's loop slider and its control's layout"
  await caseLaidOutLate()
  await caseLaidOutAlready()
  await caseRemovedFirst()
  await caseSingleLoopPass()
  beginCase()
  # THE TALLY: a case that returned early is a count mismatch, not a pass.
  inc checks
  echo "CHECKS: " & $checks
  if checks != ExpectedChecks:
    caseFailed = true
    echo "    assertion count is " & $checks & ", expected " & $ExpectedChecks
  endCase("every assertion above ran")
  ctFinish(if failedCases > 0: 1 else: 0)

discard main()
