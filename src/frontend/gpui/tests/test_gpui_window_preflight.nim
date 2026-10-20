## test_gpui_window_preflight.nim — **the refusal a window launch makes when no
## window can open, decided as a pure function.**
##
## Run:
##   nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_gpui_window_preflight.nim
##
## `window_preflight.windowPreflight` decides from three inputs — whether the
## loaded shim has a window backend, an environment lookup, the target OS — so
## every combination is asserted here, in-process, without a display, without
## a shim of each kind and without touching this process's environment
## (`codetracer-pm/issues/2026-10-01-gpui-launch-is-silent-when-no-window-can-open.md`,
## `codetracer-pm/spec/CLI/ct/ui-selection.md` §8a):
##
##   * a featureless shim is refused as `wpNoWindowBackend` on every OS, with
##     the issue's wording;
##   * a windowed shim with no graphical session on Linux/FreeBSD is refused as
##     `wpNoGraphicalSession`; empty `DISPLAY` / `WAYLAND_DISPLAY` count as
##     unset (GPUI's own rule); `ZED_HEADLESS` is named when it is the cause;
##   * BOTH problems report the featureless kind, and the message names the
##     missing session too (the module header says why);
##   * macOS and Windows never consult the environment;
##   * a windowed shim with either display opens.
##
## The real binary's refusal — exit code, stderr, promptness — is
## `test_gpui_window_refusal.nim`'s.
##
## MOCKS: the environment is a table-backed `EnvLookup` instead of this
## process's environment. That is the function's declared input, not a stand-in
## for a collaborator: the point of the pure decision is that the cases above
## (an empty `ZED_HEADLESS`, a display on a host that has none) can be stated
## exactly, which mutating the test's own environment could not do safely.

import std/[options, strutils, tables, unittest]

import ../window_preflight
import isonim_gpui/display_session

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

proc envOf(pairs: openArray[(string, string)]): EnvLookup =
  ## An `EnvLookup` over exactly `pairs`; a name not listed is unset.
  let t = pairs.toTable
  result = proc(name: string): Option[string] =
    if name in t: some(t[name]) else: none(string)

let noDisplay = envOf([])
let x11 = envOf({"DISPLAY": ":0"})
let wayland = envOf({"WAYLAND_DISPLAY": "wayland-1"})

suite "window_preflight: the featureless shim":

  test "is refused by kind, with the issue's wording, on every OS":
    for os in ["linux", "freebsd", "macosx", "windows"]:
      let p = windowPreflight(false, x11, os)
      checkpoint(os & ": " & p.message)
      ck p.refusal == wpNoWindowBackend
      ck p.message.startsWith(NoWindowBackendMessage)
      ck "--features gpui-backend" in p.message
      ck "--report-plan" in p.message

  test "with a display, the message names the backend only":
    let p = windowPreflight(false, wayland, "linux")
    ck p.refusal == wpNoWindowBackend
    ck "graphical session" notin p.message

  test "with NO display too, the featureless kind wins and both are named":
    let p = windowPreflight(false, noDisplay, "linux")
    checkpoint(p.message)
    ck p.refusal == wpNoWindowBackend
    ck p.message.startsWith(NoWindowBackendMessage)
    ck NoGraphicalSessionMessage in p.message

  test "on macOS a missing display is not a second problem":
    let p = windowPreflight(false, noDisplay, "macosx")
    ck p.refusal == wpNoWindowBackend
    ck "graphical session" notin p.message

suite "window_preflight: the windowed shim":

  test "with no graphical session on Linux and FreeBSD, refused by kind":
    for os in ["linux", "freebsd"]:
      let p = windowPreflight(true, noDisplay, os)
      checkpoint(os & ": " & p.message)
      ck p.refusal == wpNoGraphicalSession
      ck p.message.startsWith(NoGraphicalSessionMessage)
      ck "--report-plan" in p.message

  test "empty DISPLAY and WAYLAND_DISPLAY count as unset":
    let p = windowPreflight(true, envOf({"DISPLAY": "",
                                         "WAYLAND_DISPLAY": ""}), "linux")
    ck p.refusal == wpNoGraphicalSession

  test "ZED_HEADLESS is named when it is the cause, even beside a display":
    let p = windowPreflight(true, envOf({"ZED_HEADLESS": "",
                                         "DISPLAY": ":0"}), "linux")
    checkpoint(p.message)
    ck p.refusal == wpNoGraphicalSession
    ck p.message.startsWith(ZedHeadlessMessage)
    ck "DISPLAY / WAYLAND_DISPLAY unset" notin p.message

  test "either display lets the window open":
    for env in [x11, wayland, envOf({"WAYLAND_DISPLAY": "",
                                     "DISPLAY": ":1"})]:
      let p = windowPreflight(true, env, "linux")
      ck p.refusal == wpWindowCanOpen
      ck p.message.len == 0

  test "macOS and Windows open with no display variables at all":
    for os in ["macosx", "windows"]:
      ck windowPreflight(true, noDisplay, os).refusal == wpWindowCanOpen

  test "the refusal code is the terminal front-end's":
    # `ExitNoTerminal` (src/frontend/tui/app/cli.nim) is 3; the GPUI front-end
    # refuses an impossible request with the same number. Stated as a literal
    # rather than imported: this lane links no terminal front-end
    # (`test_gpui_shell_split.nim`).
    ck ExitNoWindow == 3

suite "window_preflight: the tally":
  test "every assertion above ran":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
