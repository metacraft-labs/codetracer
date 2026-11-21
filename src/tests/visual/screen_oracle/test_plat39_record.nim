## PLAT-39 — the PORTABLE half: assert the recorded readings, with no pixels.
##
## Run:
##   nim c -r src/tests/visual/screen_oracle/test_plat39_record.nim
##
## **THIS SUITE DELIBERATELY IMPORTS NOTHING THAT READS AN IMAGE.** No
## GuiAssert, no `vision_producer`, no ffmpeg, no tesseract. It reads two
## committed JSON files and compares them. That is what lets it run in CI, where
## the capture step is wired into no workflow at all and the frames therefore
## never exist.
##
## **WHAT IT ASSERTS, AND WHY THAT IS NOT CIRCULAR.** The left-hand side is
## `plat39-readings.json` — values a PIXEL reader derived from a screenshot. The
## right-hand side is `answers/*.electron.capture.json` — values the Electron
## front-end recorded out of its OWN state while driving the scenario. Those two
## came from paths that share no code: one went through the DOM and Playwright,
## the other through OCR of a photograph. Both are committed, so this is a
## RECORDED result rather than a live one, but it is still a comparison between
## two independent derivations, and a record that disagreed with the DOM would
## redden here.
##
## **WHAT IT CANNOT DO, SAID PLAINLY.** It cannot notice that the reader has
## stopped working. Nothing here executes the reader. Only `test_screen_oracle`
## does that, and it needs the frames. So this suite is strictly weaker, it is
## not a substitute, and the two exist for different reasons: this one keeps a
## real PLAT-39 assertion running everywhere, and that one keeps the oracle
## honest where the corpus exists.

import std/[json, os, sequtils, sets, strutils, tables, unittest]
import ./pane_grammar   # `namesAgree`, the comparison rule the live suite uses

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

let repoRoot = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let recordPath = repoRoot / "src/tests/visual/plat39-readings.json"
let answerDir = repoRoot / "src/tests/visual/answers"

const Scenarios = ["entry-shell", "stepped-editor", "advanced-state",
                   "returned-calltrace", "continued-event-log",
                   "breakpoint-editor"]
const GpuiScenarios = Scenarios

suite "PLAT-39 record — the record exists, and it is not a record of nothing":

  test "the record is present, and its absence would be named not inferred":
    ## A record that is on NEITHER path is a named failure rather than a skip —
    ## PLAT-38's rule for its own committed capture, applied here.
    if not fileExists(recordPath):
      checkpoint("PLAT-39's readings record is absent: " & recordPath)
      checkpoint("Remedy: just plat39-record (needs the captured corpus)")
    ck fileExists(recordPath)

  test "its provenance is present and PRINTED — a record with no date cannot be aged":
    let r = parseJson(readFile(recordPath))
    ck r.hasKey("takenAt")
    ck r["takenAt"].getStr.len > 0
    ck r.hasKey("host")
    echo "  record takenAt=", r["takenAt"].getStr, " host=", r["host"].getStr

  test "every frame digest is non-empty — a record built from an absent corpus is visible":
    ## The emitter refuses to write from an absent corpus, but a record could
    ## also arrive by other means. An empty digest means the frame was not
    ## there when the reading was taken, which would make every value below a
    ## record of `urFrameMissing` wearing the shape of an answer.
    let r = parseJson(readFile(recordPath))
    ck r.hasKey("frameDigests")
    var empties: seq[string] = @[]
    for k, v in r["frameDigests"]:
      if v.getStr.len == 0: empties.add k
    if empties.len > 0:
      checkpoint("frames with no digest: " & empties.join(", "))
    ck empties.len == 0

  test "the recorded cardinality matches the declared scenario set, both ways":
    let r = parseJson(readFile(recordPath))
    let sj = parseJson(readFile(repoRoot / "src/tests/visual/scenarios.json"))
    ck r["expectedScenarios"].getInt == sj["expectedScenarios"].getInt
    var recorded = initHashSet[string]()
    for k, _ in r["electron"]: recorded.incl k
    ck recorded == Scenarios.toHashSet
    ck recorded.len == r["expectedScenarios"].getInt

# ---------------------------------------------------------------------------
suite "PLAT-39 record — the pixel-derived value against the DOM-derived value":
# ---------------------------------------------------------------------------
  ## The milestone's central claim, as a recorded result. One case per scenario
  ## so a failure names the scenario rather than the set.

  for scenario in Scenarios:
    test "recorded highlighted line == the capture's stoppedLine — " & scenario:
      let r = parseJson(readFile(recordPath))
      let cap = parseJson(readFile(answerDir /
                                   (scenario & ".electron.capture.json")))
      let ed = r["electron"][scenario]["editor"]
      ck ed["kind"].getStr == "read"
      var last = -1
      for q in parseJson(readFile(answerDir / (scenario & ".electron.json")))["answers"]:
        if q{"question"}.getStr == "editor-row-count":
          for part in q{"value"}.getStr.split(";"):
            if part.startsWith("last="): last = parseInt(part[5 .. ^1])
      if ed["highlightedLine"].getInt != cap["stoppedLine"].getInt and
         cap["stoppedLine"].getInt == last:
        # FILED: `PLAT35-PD4` — the execution line is the editor's last DOM
        # row and under the pane's bottom edge; see test_screen_oracle.nim.
        checkpoint(scenario & ": PLAT35-PD4")
        ck ed["highlightedLine"].getInt == -1
      else:
        ck ed["highlightedLine"].getInt == cap["stoppedLine"].getInt

  for scenario in Scenarios:
    test "recorded frame size == the size the capture declared — " & scenario:
      let r = parseJson(readFile(recordPath))
      let cap = parseJson(readFile(answerDir /
                                   (scenario & ".electron.capture.json")))
      let declared = cap["capturePixels"].getStr.split("x")
      ck r["electron"][scenario]["width"].getInt == parseInt(declared[0])
      ck r["electron"][scenario]["height"].getInt == parseInt(declared[1])

  for scenario in Scenarios:
    test "the event log's two recorded counts agree — " & scenario:
      let r = parseJson(readFile(recordPath))
      let el = r["electron"][scenario]["eventLog"]
      ck el["kind"].getStr == "read"
      ck el["events"].getInt == el["ofRows"].getInt

  test "entry-shell is the population control and its record DIFFERS":
    ## A corpus of six structurally identical screens makes every comparison
    ## over it vacuous. `entry-shell` is the unstepped scenario and its record
    ## must not look like a stepped one.
    let r = parseJson(readFile(recordPath))
    ck r["electron"]["entry-shell"]["programState"]["kind"].getStr == "empty"
    ck r["electron"]["stepped-editor"]["programState"]["kind"].getStr == "read"
    ck r["electron"]["entry-shell"]["editor"]["highlightedLine"].getInt !=
       r["electron"]["stepped-editor"]["editor"]["highlightedLine"].getInt

# ---------------------------------------------------------------------------
suite "PLAT-39 record — DIFF-8's filed gaps, as recorded":
# ---------------------------------------------------------------------------
  ## Each asserted as the state MEASURED on the day it was filed, so that the
  ## day the product changes this goes red and the gap is revisited rather than
  ## quietly staying true.

  for scenario in GpuiScenarios:
    test "GAP 1, CLOSED BY PLAT-40 — both renderers' state rows name the same variables — " & scenario:
      # Filed 2026-09-22 (`name = value`, and wrapping values); closed
      # 2026-09-23 — see `test_screen_oracle.nim`'s case of the same name.
      let r = parseJson(readFile(recordPath))
      let gk = r["gpui"][scenario]["programState"]["kind"].getStr
      ck gk == r["electron"][scenario]["programState"]["kind"].getStr
      if gk == "read":
        var gn, en: seq[string]
        for n in r["gpui"][scenario]["programState"]["variableNames"]: gn.add n.getStr
        for n in r["electron"][scenario]["programState"]["variableNames"]: en.add n.getStr
        ck min(gn.len, en.len) > 0
        ck namesAgree(gn, en)

  for scenario in GpuiScenarios:
    test "GAP 2, CLOSED BY PLAT-40 — both renderers' event log reads as the same rows — " & scenario:
      let r = parseJson(readFile(recordPath))
      ck r["gpui"][scenario]["eventLog"]["kind"].getStr == "read"
      ck r["gpui"][scenario]["eventLog"]["events"].getInt > 0
      ck r["gpui"][scenario]["eventLog"]["events"].getInt ==
         r["electron"][scenario]["eventLog"]["events"].getInt

  for scenario in GpuiScenarios:
    test "GAP 3, CLOSED BY PLAT-42 — GPUI's execution line reads as Electron's — " & scenario:
      # Filed 2026-09-22 as `-1` (no band drawn); closed 2026-09-23 — see
      # `test_screen_oracle.nim`'s case of the same name.
      let r = parseJson(readFile(recordPath))
      ck r["gpui"][scenario]["editor"]["kind"].getStr == "read"
      ck r["gpui"][scenario]["editor"]["highlightedLine"].getInt > 0
      let eLine = r["electron"][scenario]["editor"]["highlightedLine"].getInt
      if eLine == -1:
        # `PLAT35-PD4` on the Electron frame (see the case above): GPUI's
        # reading is held to the capture's stoppedLine instead.
        let cap = parseJson(readFile(answerDir /
                                     (scenario & ".electron.capture.json")))
        ck r["gpui"][scenario]["editor"]["highlightedLine"].getInt ==
           cap["stoppedLine"].getInt
      else:
        ck r["gpui"][scenario]["editor"]["highlightedLine"].getInt == eLine

  test "GAP 4, CLOSED — every GPUI frame is a window at its declared size":
    let r = parseJson(readFile(recordPath))
    let sj = parseJson(readFile(repoRoot / "src/tests/visual/scenarios.json"))
    let vp = sj["viewports"]
    for s in sj["scenarios"].getElems:
      let id = s["id"].getStr
      let want = vp[s["viewport"].getStr]
      ck r["gpui"][id]["width"].getInt == want["width"].getInt
      ck r["gpui"][id]["height"].getInt == want["height"].getInt
      ck r["gpui"][id]["width"].getInt == r["electron"][id]["width"].getInt

suite "PLAT-39 record — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
