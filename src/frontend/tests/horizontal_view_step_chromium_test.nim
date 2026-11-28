## horizontal_view_step_chromium_test.nim — an output pane's Right and Left
## (`view.scroll-right` / `view.scroll-left`, `list_scrubber_dom.viewOperation`)
## move its view six columns of the text it shows, in the font that text is
## drawn in.
##
## Terminal Output's lines set their own face (`.terminal-line` is
## SpaceMono, `components/terminal.styl`), and the scroll container they sit
## in does not. The step was measured on a span appended to the container,
## in the container's face. Where the two faces differ in width, Right moved
## another number of the lines' columns: five on a CI runner
## (layout/plat70a-output-hscroll, run 45822112077), six where the faces
## happened to agree. This suite gives the container and the lines two faces
## of different widths on purpose, so it fails wherever the step is measured
## in the wrong one.
##
## ## WHY A BROWSER
##
## The claim is about text measured by a layout engine: jsdom has none. This
## runs in headless Chromium through the `renderer-chromium` lane
## (`src/frontend/tests/chromium-run.mjs`).
##
## ## WHAT IS MOCKED, AND WHY
##
## Nothing. The DOM is the pane's shape (a scroll container, its lines), the
## operation is the shipped one, and the widths are the browser's.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## `ck` tallies, each case prints `[OK]` / `[FAILED]`, and the tally is
## compared with a number written from a run.

import std/[asyncjs, jsffi, math, strutils]

import ../viewmodel/views/list_scrubber_dom

proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}
proc settle(): Future[void] {.importjs:
  "new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)))".}
proc setHtml(html: cstring) {.importjs: "document.body.innerHTML = #".}
proc qs(sel: cstring): JsObject {.importjs: "document.querySelector(#)".}
proc scrollLeftOf(e: JsObject): float {.importjs: "#.scrollLeft".}
proc setScrollLeft(e: JsObject; v: float) {.importjs: "#.scrollLeft = #".}
proc charWidthIn(e: JsObject): float {.importjs: """
  (function(e){
    const s = document.createElement('span');
    s.textContent = 'MMMMMMMMMM';
    s.style.whiteSpace = 'pre';
    e.appendChild(s);
    const w = s.getBoundingClientRect().width / 10;
    e.removeChild(s);
    return w;
  })(#)""".}

const ExpectedChecks = 5
  ## Written from a run. See the end of `main`.

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

proc caseStepIsSixColumnsOfTheLines() {.async.} =
  beginCase()
  # The container in a narrow monospace face at 10 px, the lines in another
  # at 18 px: a column of the lines is far wider than one of the container.
  let line = "<<LEFT-EDGE>> " & repeat("the quick brown fox jumps over the lazy dog, 0123456789 ", 6) &
             "<<RIGHT-EDGE>>"
  setHtml(cstring("""<div class="terminal" style="width: 400px; height: 200px">
    <pre id="out" style="font: 10px monospace; overflow-x: auto; width: 400px; height: 200px; margin: 0">""" &
    """<div class="terminal-line" style="font: 18px monospace; white-space: pre; display: flex">""" &
    line & """</div></pre></div>"""))
  await settle()
  let pre = qs("#out")
  let lineEl = qs(".terminal-line")
  let lineCol = charWidthIn(lineEl)
  let preCol = charWidthIn(pre)
  ck abs(lineCol - preCol) > 1.0,
    "the fixture's two faces differ (" & $lineCol & " vs " & $preCol & ")"
  setScrollLeft(pre, 0)
  ck viewOperation(pre, "view.scroll-right"), "Right moves the view"
  let step = float(int(round(6.0 * lineCol)))
  ck abs(scrollLeftOf(pre) - step) <= 1.0,
    "six of the lines' columns (" & $scrollLeftOf(pre) & " px, expected " & $step & ")"
  ck viewOperation(pre, "view.scroll-right") and abs(scrollLeftOf(pre) - 2.0 * step) <= 1.0,
    "twelve after a second Right (" & $scrollLeftOf(pre) & " px)"
  discard viewOperation(pre, "view.scroll-left")
  ck abs(scrollLeftOf(pre) - step) <= 1.0,
    "and back to six after Left (" & $scrollLeftOf(pre) & " px)"
  endCase("Right and Left move six columns of the text, in the text's own face")

proc main() {.async.} =
  echo ""
  echo "[Suite] an output pane's horizontal view step"
  try:
    await caseStepIsSixColumnsOfTheLines()
  except CatchableError as e:
    inc failedCases
    echo "  [FAILED] the case raised: " & e.msg
  beginCase()
  echo "CHECKS: " & $checks
  if checks != ExpectedChecks:
    caseFailed = true
    echo "    assertion count is " & $checks & ", expected " & $ExpectedChecks
  endCase("every assertion above ran")
  ctFinish(if failedCases > 0: 1 else: 0)

discard main()
