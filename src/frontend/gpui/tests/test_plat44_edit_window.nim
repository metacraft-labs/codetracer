## PLAT-44 — a keystroke in a REAL WINDOW changes the file on disk, and the
## user can SEE that it did: asserted from the committed window record.
##
## Run:
##   nim c -r src/frontend/gpui/tests/test_plat44_edit_window.nim
##
## `src/tests/visual/plat44-edit-window.json` is written by
## `just plat44-edit-window` (a real `codetracer-gpui --edit` window on a
## headless sway; `wtype` types Shift+q, Ctrl+s and the F12 sentinel through
## the compositor's seat; `grim` grabs a blank, a before and an after frame)
## followed by `just plat44-window-record` (the frames read through PLAT-39's
## pixel reader: `locateGrid`, `identifyPane`, `ocrRegion`). This suite reads
## no binary and no image — PLAT-37/38/39's measure-locally-commit-the-
## measurement arrangement — so it is portable and the floor counts it.
##
## Three facts, and the last is the one only the vision tier can state:
##
##   * PLAT-23's G4 verbatim — *"the GPUI editor accepts a keystroke and
##     changes a buffer"* — as a FILE ON DISK after a real keystroke;
##   * the loop ended on the SENTINEL, not on the backstop, so the run
##     finished rather than being killed;
##   * the typed `Q` is LEGIBLE in the after frame and absent from the before
##     frame, and the blank frame is not readable as an editor at all — the
##     model changing and the screen changing are two assertions (PLAT-44's
##     gate), and a write that reaches the buffer and never a pixel would fail
##     the second.
##
## THE LANE'S OWN NEGATIVE TWIN (`CODETRACER_PLAT44_NEGATIVE=1`, the same run
## with the key left out) ended in `VERDICT: FAIL` with the file unchanged
## when this record was taken; it is recorded in the milestone rather than
## here, because this record is the positive run.

import std/[json, os, strutils, unittest]

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let recordPath = repo / "src/tests/visual/plat44-edit-window.json"

proc rec(): JsonNode = parseJson(readFile(recordPath))

suite "PLAT-44: a keystroke in a real window":

  test "the record is present and provenanced":
    ck fileExists(recordPath)
    ck rec()["takenAt"].getStr.len > 0
    ck rec()["host"].getStr.len > 0
    echo "  record takenAt=", rec()["takenAt"].getStr, " host=",
      rec()["host"].getStr, " binary=", rec()["run"]["binary"].getStr

  test "G4: the keystroke changed the FILE ON DISK":
    let run = rec()["run"]
    ck run["rc"].getInt == 0
    ck run["onDisk"].getStr == run["expected"].getStr
    ck run["onDisk"].getStr != run["original"].getStr
    ck run["onDisk"].getStr.startsWith("Q")

  test "the run finished on its sentinel, not on the backstop":
    ck not rec()["run"]["endedOnDeadline"].getBool

  test "three frames were taken":
    for n in ["blank", "before", "after"]:
      ck rec()["run"]["frames"][n].getInt > 0

  test "the typed byte is ON SCREEN after the key and not before it":
    let before = rec()["frames"]["before"]
    let after = rec()["frames"]["after"]
    ck before["located"].getBool
    ck after["located"].getBool
    # The line the key edited, as the pixel reader recovered it.
    ck "Qalpha" in after["text"].getStr
    ck "Qalpha" notin before["text"].getStr
    # …and the before frame DID read that line, so its absence above is an
    # absence of the `Q`, not of the text.
    ck "alpha" in before["text"].getStr

  test "the blank control is not readable as an editor":
    let blank = rec()["frames"]["blank"]
    ck not blank["located"].getBool
    ck blank["reason"].getStr.len > 0

suite "PLAT-44 window — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
