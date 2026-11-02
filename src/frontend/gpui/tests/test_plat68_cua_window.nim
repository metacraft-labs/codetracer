## PLAT-68 Phase A — the CUA editing sequence typed into a REAL GPUI WINDOW
## gives the document the terminal gives: asserted from the committed record.
##
## Run:
##   nim c -r src/frontend/gpui/tests/test_plat68_cua_window.nim
##
## `src/tests/visual/plat68-cua-window.json` is written by
## `ci/test/plat68-cua-window.sh` (a real `codetracer-gpui --edit` window on a
## headless sway; `wtype` types `x y`, `Shift+Right` x3, `Ctrl+C`, `End`,
## `Ctrl+V`, `Ctrl+Z`, `Ctrl+Y`, `Down`, `Ctrl+Shift+K`, `Ctrl+S` and the `F12`
## sentinel through the compositor's seat) followed by
## `ci/test/plat68-cua-window.sh --record`. This suite reads no binary and no
## compositor — PLAT-37/38/44's measure-locally-commit-the-measurement
## arrangement — so it is portable and the floor counts it.
##
## No mocks: the record is a measurement of the shipped binary, and the
## expected document is the one `test_plat68_keymaps_pty.nim` reaches through a
## real pty with the same keys.
##
## Four facts:
##
##   * the FILE ON DISK after the run is the expected document — the CUA base
##     drove copy, paste, undo, redo, delete-line and save through GPUI's key
##     delivery;
##   * the loop ended on the SENTINEL, not on the backstop;
##   * every key reached the edit arm under its CANONICAL name (one modifier
##     order, lowercase letters, Shift written explicitly) — the decoder half
##     of PLAT-68, on the GPUI front end;
##   * the editing keys were CLAIMED by the editor (none `ignored`), and only
##     the sentinel fell through.

import std/[json, os, sequtils, unittest]

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let recordPath = repo / "src/tests/visual/plat68-cua-window.json"

proc rec(): JsonNode = parseJson(readFile(recordPath))

const ExpectedNames = [
  "x", "y", "Shift+Right", "Shift+Right", "Shift+Right", "Ctrl+c", "End",
  "Ctrl+v", "Ctrl+z", "Ctrl+y", "Down", "Ctrl+Shift+k", "Ctrl+s", "F12"]

suite "PLAT-68: the CUA sequence in a real GPUI window":

  test "the record is present and provenanced":
    ck fileExists(recordPath)
    ck rec()["takenAt"].getStr.len > 0
    ck rec()["host"].getStr.len > 0
    echo "  record takenAt=", rec()["takenAt"].getStr, " host=",
      rec()["host"].getStr, " binary=", rec()["binary"].getStr

  test "the document on disk is the CUA sequence's document":
    let r = rec()
    ck r["rc"].getInt == 0
    ck r["onDisk"].getStr == r["expected"].getStr
    ck r["onDisk"].getStr != r["original"].getStr
    # The same document the terminal suite reaches with the same keys.
    ck r["expected"].getStr == "xyalphaalp\ngamma\n"

  test "the run finished on its sentinel, not on the backstop":
    ck not rec()["endedOnDeadline"].getBool

  test "every key arrived under its canonical name, in order":
    let names = rec()["keys"].getElems.mapIt(it["name"].getStr)
    ck names == @ExpectedNames

  test "the editor claimed every editing key; only the sentinel fell through":
    let keys = rec()["keys"].getElems
    ck keys.len == ExpectedNames.len
    for k in keys[0 ..< keys.len - 1]:
      ck k["outcome"].getStr != "ignored"
    ck keys[^1]["outcome"].getStr == "ignored"
    # The writes are writes: paste, undo, redo and delete-line changed the
    # buffer.
    for i in [7, 8, 9, 11]:
      ck keys[i]["outcome"].getStr == "changed"

suite "PLAT-68 window — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
