## The auto-hide overlay's hide completes when its slide-out ends, whatever
## the renderer's timers do (codetracer-pm
## issues/2026-11-14-escape-sometimes-leaves-a-minimal-sidebars-overlay-on-screen.md).
##
## `ui/auto_hide.hideOverlay` adds `closing` (the slide-out animation in the
## shipped stylesheet) and used to finish the hide only from a 100 ms
## `setTimeout`. A renderer whose timers were held back past that left the
## overlay half-way off screen: in realistic scenario runs the teardown came
## 12 s after Escape in a passing run and not within 15 s in failing ones,
## while input kept being handled.
##
## THE SCRIPTED CLOCK. This suite replaces `window.setTimeout` with one that
## records each callback and never runs it -- timers held back indefinitely --
## and keeps the browser's own timer for its waits. Against the unfixed module
## the overlay stays `visible closing` for the whole wait (red); with the fix
## the slide-out's `animationend` completes the hide while the recorded timer
## is still unrun.
##
## The second case is the race the hide has to survive: a reopen during the
## slide-out takes the overlay over (`cancelOverlayClose`), and the cancelled
## hide must not tear the reopened panel down when a later slide-out ends.
##
## What is real: Chromium, its CSS animation engine, the shipped dark theme
## (compiled from `auto_hide.styl`), and the production `ui/auto_hide` procs.
## The one stand-in is the held-back timer, and it is not a mock of anything
## the product calls: it is the condition under test.
## Lane: renderer-chromium; `CODETRACER_BUILD_DIR` names the theme's build.

import std/[asyncjs, jsffi, os]
import kdom
import ../types
import ../ui/auto_hide

const ThemeCss = staticRead(getEnv("CODETRACER_BUILD_DIR",
  currentSourcePath().parentDir / "../../build-debug") /
  "frontend/styles/default_dark_theme_electron.css")

proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}
proc prepare(css: cstring) {.importjs: """
  (function(css) {
    var style = document.createElement('style'); style.textContent = css;
    document.head.appendChild(style);
    document.body.innerHTML =
      '<div id="auto-hide-overlay" class="auto-hide-overlay">' +
      '<div id="auto-hide-overlay-title"></div>' +
      '<div id="auto-hide-overlay-content"></div></div>';
    // The held-back timers: recorded, never run. The suite's own waits use
    // the browser's timer, kept aside first.
    window.__ctRealSetTimeout = window.setTimeout.bind(window);
    window.__ctHeldTimers = [];
    window.setTimeout = function (fn, ms) {
      window.__ctHeldTimers.push(ms); return 100000 + window.__ctHeldTimers.length;
    };
    window.clearTimeout = function () {};
  })(#)
""".}
proc realSleep(ms: int): Future[void] {.importjs:
  "new Promise(function (r) { window.__ctRealSetTimeout(r, #); })".}
proc heldTimers(): int {.importjs: "(window.__ctHeldTimers.length)".}
proc overlayClass(): cstring {.importjs:
  "(document.getElementById('auto-hide-overlay').className)".}
proc hasClass(name: cstring): bool {.importjs:
  "document.getElementById('auto-hide-overlay').classList.contains(#)".}
proc title(): cstring {.importjs:
  "(document.getElementById('auto-hide-overlay-title').textContent)".}
proc newPanelElement(text: cstring): kdom.Element {.importjs: """
  (function (t) { var d = document.createElement('div'); d.textContent = t; return d; })(#)""".}

var failures = 0

proc check(ok: bool; label: string; detail = "") =
  ## In the lane runner's format (ci/lib/run-nim-test-lane.sh counts the
  ## `[OK]` and `[FAILED]` lines): a check printed any other way is not
  ## counted, and a passing file reads as one that ran nothing.
  if ok:
    echo "  [OK] " & label
  else:
    inc failures
    echo "  [FAILED] " & label & (if detail.len > 0: ": " & detail else: "")

proc panel(title: string; edge: AutoHideEdge): AutoHidePanel =
  AutoHidePanel(edge: edge, title: cstring(title),
                liveElement: newPanelElement(cstring(title)))

proc waitWhile(cond: proc(): bool; ms: int) {.async.} =
  var waited = 0
  while cond() and waited < ms:
    await realSleep(20)
    waited += 20

proc main() {.async.} =
  prepare(cstring(ThemeCss))
  initAutoHideState()

  # 1. A hide with every timer held back completes when its slide-out ends.
  let events = panel("EVENTS", Bottom)
  autoHideState.panels.add events
  showOverlayPreview(events)
  await realSleep(300)   # the slide-in
  check(hasClass(cstring"visible"), "the overlay is open", $overlayClass())
  let timersBefore = heldTimers()
  hideOverlay()
  check(hasClass(cstring"closing"), "the hide starts the slide-out",
        $overlayClass())
  await waitWhile(proc(): bool = hasClass(cstring"visible"), 2000)
  check(not hasClass(cstring"visible") and not hasClass(cstring"closing"),
        "the hide completed with its timer held back", $overlayClass())
  check(heldTimers() > timersBefore,
        "the hide's fallback timer was scheduled and never ran")
  check(not autoHideState.overlayVisible, "the state reads closed")

  # 2. A reopen during the slide-out takes the overlay over, and the cancelled
  #    hide does not tear the reopened panel down when a later slide ends.
  let files = panel("FILES", Bottom)
  autoHideState.panels.add files
  showOverlayPreview(events)
  await realSleep(300)
  hideOverlay()
  showOverlayPreview(files)          # within the 100 ms slide-out
  await realSleep(400)
  check(hasClass(cstring"visible") and not hasClass(cstring"closing"),
        "the reopened overlay is open, not closing", $overlayClass())
  check($title() == "FILES", "the reopened overlay shows the new panel",
        $title())
  check(autoHideState.overlayVisible and autoHideState.activeOverlay == files,
        "the state reads the reopened panel")
  hideOverlay()
  await waitWhile(proc(): bool = hasClass(cstring"visible"), 2000)
  check(not hasClass(cstring"visible"), "the second hide completes",
        $overlayClass())

  if failures > 0:
    echo "FAIL: auto_hide_slide_out_chromium_test: " & $failures & " check(s)"
    ctFinish(1)
  else:
    echo "PASS: auto_hide_slide_out_chromium_test"
    ctFinish(0)

discard main()
