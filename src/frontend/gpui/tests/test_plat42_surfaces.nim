## PLAT-42 — the GPUI editor's four debugger surfaces, asserted from a record of
## the SHIPPED binary's render plan.
##
## Run:
##   nim c -r src/frontend/gpui/tests/test_plat42_surfaces.nim
##
## **WHERE THE EVIDENCE COMES FROM.** `ci/test/plat42_surfaces_record.py` runs
## `codetracer-gpui --report-plan` against the real `calc` recording, once per
## pinned scenario, and records what each editor row carried. The plan is the
## Rust-side shadow tree, which is the reading PLAT-42 requires — *"read back out
## of the RUST-SIDE shadow tree, never out of the surface the case built"*.
##
## That reading became possible only when the render plan began serialising
## element attributes. Before, the editor wrote `data-ct-pointer`/`-mark`/
## `-values`/`-flow` on every row and the plan dropped all of them.
##
## **NO MOCKS.** Nothing here constructs a surface. It reads two committed JSON
## files: the recorded plan readings, and the answers the ELECTRON front-end
## recorded from its own state. Where the two agree, two front-ends sharing no
## rendering code reported the same stop.
##
## **WHAT IT CANNOT DO.** It does not run the binary, so it cannot notice the
## editor breaking after the record was taken; re-recording does that.

import std/[json, os, sets, strutils, tables, unittest]

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

let repoRoot = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let recordPath = repoRoot / "src/tests/visual/plat42-surfaces.json"
let answerDir = repoRoot / "src/tests/visual/answers"

const Scenarios = ["entry-shell", "stepped-editor", "advanced-state",
                   "returned-calltrace", "continued-event-log",
                   "breakpoint-editor"]

# Stops whose execution line NAMES something in scope, so the execution-line-
# only rule must produce values there — and the stops whose line names nothing
# in scope, where it must not. Measured on the shipped binary 2026-09-23.
const ValuesExpected = ["advanced-state", "returned-calltrace",
                        "continued-event-log"]

proc rec(): JsonNode = parseJson(readFile(recordPath))
proc rowsOf(s: string): seq[JsonNode] = rec()["scenarios"][s]["rows"].getElems

proc lineOf(row: JsonNode): int =
  ## The gutter's line number, read off the row's own text. `data-ct-row` is a
  ## VIEWPORT INDEX, not a line: a stop at line 110 still draws rows 1..54.
  var digits = ""
  for ch in row["text"].getStr:
    if ch.isDigit: digits.add ch
    else: break
  if digits.len == 0: -1 else: parseInt(digits)

proc execRows(s: string): seq[JsonNode] =
  for r in rowsOf(s):
    if r["pointer"].getStr == "eptExecution": result.add r

suite "PLAT-42 record — present, provenanced, and about the pinned set":
  test "the record is present, and its absence is named":
    if not fileExists(recordPath):
      checkpoint("absent: " & recordPath & " — remedy: just plat42-surfaces-record")
    ck fileExists(recordPath)

  test "provenance is present and printed":
    let r = rec()
    ck r["takenAt"].getStr.len > 0
    ck r["host"].getStr.len > 0
    echo "  record takenAt=", r["takenAt"].getStr, " host=", r["host"].getStr

  test "the recorded scenarios are exactly the pinned set":
    var got = initHashSet[string]()
    for k, _ in rec()["scenarios"]: got.incl k
    ck got == Scenarios.toHashSet

suite "PLAT-42 surface 1 — the execution pointer":
  for s in Scenarios:
    test "exactly one row carries the execution pointer — " & s:
      ck execRows(s).len == 1

  for s in Scenarios:
    test "that row is the line Electron recorded stopping on — " & s:
      # Two front-ends, no shared rendering code, one stop.
      let cap = parseJson(readFile(answerDir / (s & ".electron.capture.json")))
      let rows = execRows(s)
      ck rows.len == 1
      if rows.len == 1:
        ck lineOf(rows[0]) == cap["stoppedLine"].getInt

suite "PLAT-42 surface 3 — inline values, on the EXECUTION LINE ONLY":
  ## The rule is deliberate and documented at `editor_surface.nim`: a value at
  ## the stop drawn beside a line thirty rows above it that has not run would be
  ## stale. It DIVERGES from Electron, which annotates every mentioning line —
  ## recorded by PLAT-34 as PLAT22-PG3.

  for s in Scenarios:
    test "no row other than the execution row carries values — " & s:
      for r in rowsOf(s):
        if r["pointer"].getStr != "eptExecution":
          ck r["values"].getStr.len == 0

  for s in Scenarios:
    test "values appear exactly where the stop line names something in scope — " & s:
      let rows = execRows(s)
      ck rows.len == 1
      if rows.len == 1:
        if s in ValuesExpected: ck rows[0]["values"].getStr.len > 0
        else: ck rows[0]["values"].getStr.len == 0

suite "PLAT-42 surface 2 — per-line status":
  for s in Scenarios:
    test "breakpoint marks appear only where a breakpoint was set — " & s:
      var marks = 0
      for r in rowsOf(s):
        if r["mark"].getStr != "emNone": inc marks
      if s == "breakpoint-editor": ck marks == 1
      else: ck marks == 0

suite "PLAT-42 surface 4 — the flow overlay, FILED AS UNBUILT":
  ## Asserted as the state MEASURED, so building it turns this red and the
  ## record has to be retaken rather than quietly going stale. The overlay is
  ## unbuilt on the terminal as well — `ecFlowOverlay` has no reference under
  ## src/frontend/tui/ — so this is new work on both media, not a port.
  for s in Scenarios:
    test "every row's flow state is efsUnknown — " & s:
      for r in rowsOf(s):
        ck r["flow"].getStr == "efsUnknown"

suite "PLAT-42 — a presentation defect found on the way, FILED":
  test "a Python list of ints is rendered as a hex byte string":
    ## `results` is [5, 7, 42, 17, 2] at the continued-event-log stop. The GPUI
    ## inline value reads `05 07 2a 11 02 (5 bytes)` — the right numbers in the
    ## wrong shape. This is PLAT-2's value-presentation pipeline rather than a
    ## PLAT-42 surface; asserted as measured so a fix turns this red.
    let rows = execRows("continued-event-log")
    ck rows.len == 1
    if rows.len == 1:
      ck rows[0]["values"].getStr.contains("(5 bytes)")

suite "PLAT-42 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
