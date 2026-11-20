## test_gpui_vcs_off_loop_window.nim — THE GPUI WINDOW ANSWERS INPUT WHILE
## THE VCS PANE'S GIT HAS NOT RETURNED: asserted from the committed record.
##
## Run:
##   nim c -r src/frontend/gpui/tests/test_gpui_vcs_off_loop_window.nim
##
## `src/tests/visual/gpui-vcs-off-loop.json` is written by
## `ci/test/gpui-vcs-off-loop-window.sh` (a real `codetracer-gpui --edit`
## window on a headless sway over a git repository, a fake `git` first on
## PATH holding `status` and `log` until a release file exists, `wtype` typing
## `x` while it is held) followed by `--record`; the `gpui-window-captures`
## CI job re-takes it (`vcsoffloop`). This suite reads no binary and no
## compositor, so it is portable.
##
## No mocks: the record is a measurement of the shipped binary and the real
## git behind the gate. The facts:
##
##   * git WAS HELD: a `status` or `log` began before the key was typed and
##     was released only after it — so the key came while git had not
##     returned;
##   * the KEY REACHED THE EDIT ARM before the pane's first read was applied
##     (the window's own trace, in the order it wrote it) — the loop was not
##     waiting on git;
##   * the read WAS APPLIED once git returned (`vcs refreshed` after the
##     key), without another refresh interval having to pass first;
##   * the loop ended on the sentinel, not on the backstop.

import std/[json, os, unittest]

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const ExpectedAssertions = 9

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let recordPath = repo / "src/tests/visual/gpui-vcs-off-loop.json"

suite "GPUI: the window answers input while the VCS pane's git is held":
  let r = parseJson(readFile(recordPath))
  var kinds: seq[string]
  for e in r["order"]: kinds.add e["event"].getStr

  test "the loop ended on the sentinel":
    ck r["rc"].getInt == 0
    ck not r["endedOnDeadline"].getBool

  test "git was held across the key":
    var heldBefore, releasedAfter = false
    for g in r["git"]:
      if g["what"].getStr == "held" and g["atMs"].getInt < r["typedAtMs"].getInt:
        heldBefore = true
      if g["what"].getStr == "released" and g["atMs"].getInt > r["typedAtMs"].getInt:
        releasedAfter = true
    ck heldBefore
    ck releasedAfter
    ck r["releasedAtMs"].getInt > r["typedAtMs"].getInt

  test "the key reached the edit arm before the first read was applied":
    ck "key" in kinds
    ck "vcs-applied" in kinds
    ck kinds.find("key") < kinds.find("vcs-applied")

  test "assertion count":
    ck CHECKS == ExpectedAssertions
