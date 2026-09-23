## PLAT-42 — the frame budget, from the committed window record.
##
## Run:
##   nim c -r src/frontend/gpui/tests/test_plat42_frame_budget.nim
##
## `src/tests/visual/plat42-frame-budget.json` is measured by
## `ci/test/plat42-frame-budget.sh` (a 40,000-line file in a real
## `codetracer-gpui --edit` window, scrolled 80 lines and edited with real keys,
## at two viewports) and summarised by `ci/test/plat42_frames_record.py`.
##
## **NOTHING HERE IS A THRESHOLD** (Verification-Harness-Traps §28a): the host
## is shared and a timing taken on it is a measurement of it, so the figures
## are PRINTED with the load they were taken under and never compared with a
## constant. What IS asserted is that the measurement happened and is
## interpretable: both viewports present, frames and key latencies recorded,
## the whole document loaded, the keys applied, the pane scrolled, the run
## ended on its sentinel, and the load recorded beside the figures.
##
## No mocks: it reads a committed measurement of the shipped binary.

import std/[json, os, strutils, unittest]

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let recordPath = repo / "src/tests/visual/plat42-frame-budget.json"
const Viewports = ["1440x900", "2560x1440"]

proc rec(): JsonNode = parseJson(readFile(recordPath))

suite "PLAT-42: the frame budget, measured and reported":

  test "the record is present, provenanced, and says what it did not measure":
    ck fileExists(recordPath)
    ck rec()["takenAt"].getStr.len > 0
    ck rec()["host"].getStr.len > 0
    ck rec()["notMeasured"].getStr.contains("stepping")

  for vp in Viewports:
    test "the measurement happened at " & vp:
      let v = rec()["viewports"][vp]
      # 40,000 lines and the trailing newline's empty last line.
      ck v["documentLines"].getInt >= 40000
      ck v["keysApplied"].getInt >= 85
      ck v["finalViewportTop"].getInt > 1
      ck not v["endedOnDeadline"].getBool
      ck v["renderPath"]["count"].getInt > 0
      ck v["keyToFrame"]["count"].getInt > 0
      # Every key applied has a handler time: the series is the keys, not a
      # sample of them.
      ck v["keyHandler"]["count"].getInt == v["keysApplied"].getInt
      ck v["loadAverageStart"].getStr.len > 0
      ck v["cpus"].getInt > 0
      echo "  ", vp, ": render-path p50 ", v["renderPath"]["p50Ms"].getFloat,
        " ms, p95 ", v["renderPath"]["p95Ms"].getFloat, " ms, max ",
        v["renderPath"]["maxMs"].getFloat, " ms over ",
        v["renderPath"]["count"].getInt, " frames; key->frame p50 ",
        v["keyToFrame"]["p50Ms"].getFloat, " ms, p95 ",
        v["keyToFrame"]["p95Ms"].getFloat, " ms; key handler p50 ",
        v["keyHandler"]["p50Ms"].getFloat, " ms, p95 ",
        v["keyHandler"]["p95Ms"].getFloat, " ms; load ",
        v["loadAverageStart"].getStr, " on ", v["cpus"].getInt, " cpus"

suite "PLAT-42 frame budget — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
