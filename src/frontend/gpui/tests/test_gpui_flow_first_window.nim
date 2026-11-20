## test_gpui_flow_first_window.nim — THE GPUI WINDOW IS ON SCREEN BEFORE THE
## FIRST STOP'S FLOW ANSWERS, and draws the flow once it does: asserted from
## the committed record.
##
## Run:
##   nim c -r src/frontend/gpui/tests/test_gpui_flow_first_window.nim
##
## `src/tests/visual/gpui-flow-first.json` is written by
## `ci/test/gpui-flow-first-window.sh` (a real `codetracer-gpui` window on a
## headless sway over the `calc` recording, its `replay-server` behind a proxy
## that holds the answer to `ct/load-flow` until a release file exists, sway
## asked for its windows while the answer is held) followed by `--record`; the
## `gpui-window-captures` CI job re-takes it (`flowfirst`). This suite reads no
## binary and no compositor, so it is portable.
##
## No mocks: the record is a measurement of the shipped binary and the real
## replay-server behind the hold. The facts:
##
##   * the flow's answer WAS HELD and then released;
##   * the window WAS MAPPED while it was held (a window titled CodeTracer in
##     sway's tree) — the window did not wait for the flow to open;
##   * the window's own trace, in the order it wrote it: the flow deferred at
##     the open, asked for after the first frame with no flow rows drawn yet,
##     and applied afterwards with flow rows drawn (the editor's flow overlay
##     filled in);
##   * the loop ended on the sentinel, not on the backstop.

import std/[json, os, unittest]

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const ExpectedAssertions = 11

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let recordPath = repo / "src/tests/visual/gpui-flow-first.json"

suite "GPUI: the window opens before the first stop's flow":
  let r = parseJson(readFile(recordPath))
  var kinds: seq[string]
  var rowsAt: seq[int]
  for e in r["order"]:
    kinds.add e["event"].getStr
    rowsAt.add(if e.hasKey("flowRows"): e["flowRows"].getInt else: -1)
  var proxy: seq[string]
  for p in r["proxy"]: proxy.add p["what"].getStr

  test "the loop ended on the sentinel":
    ck r["rc"].getInt == 0
    ck not r["endedOnDeadline"].getBool

  test "the flow's answer was held, then released":
    ck proxy.len >= 2
    ck proxy.len >= 2 and proxy[0] == "held" and proxy[1] == "released"

  test "the window was mapped while the flow was held":
    ck r["windowMappedWhileHeld"].getBool

  test "the flow was asked for after the first frame, then drawn":
    ck kinds.len >= 3
    ck kinds.len >= 3 and kinds[0 .. 2] == @["deferred", "requested", "applied"]
    # No flow rows in the frame the window drew before it asked; the call's
    # lines carry a flow state once the answer was applied.
    ck rowsAt.len >= 3 and rowsAt[1] == 0
    ck rowsAt.len >= 3 and rowsAt[2] > 0
    ck rowsAt.len >= 3 and rowsAt[2] > rowsAt[1]

  test "assertion count":
    ck CHECKS == ExpectedAssertions
