## PLAT-42 — the GPUI editor's four debugger surfaces, asserted from a record of
## the SHIPPED binary's render plan.
##
## Run:
##   nim c -r src/frontend/gpui/tests/test_plat42_surfaces.nim
##
## **WHERE THE EVIDENCE COMES FROM.** `ci/test/plat42_surfaces_record.py` runs
## `codetracer-gpui --report-plan` against the real `calc` recording, once per
## pinned scenario — and against `noir_space_ship` for the flow overlay, which
## needs a declined branch — and records what each editor row carried. The plan is the
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
import ./plat42_gutter

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
  gutterLineOf(row["text"].getStr)

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

  for s in Scenarios:
    test "the execution band is on that row and on no other — " & s:
      # The band PLAT-39's reader locates the pointer by. Twin: a band on
      # every row, or on none, fails.
      var banded = 0
      for r in rowsOf(s):
        if r["rowBackground"].getStr.len > 0:
          inc banded
          ck r["pointer"].getStr == "eptExecution"
      ck banded == 1

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

const FlowScenario = "noir-declined-arm"
  ## `noir_space_ship`'s `shield.nr`, stopped (`stepIn=33`) on line 29 in the
  ## first call of `calculate_damage`: the shield is full, so `shield_pct ==
  ## 100` took its arm and declined the `else` (lines 32-33), and `damage >
  ## remaining_shield` declined its arm (lines 35-36). `calc` cannot carry this
  ## case: it has no `if` at all, by design.
  ##
  ## Until 2026-09-24 this was `stepIn=15` and lines 11-13 — the arm of the
  ## in-loop `if` on line 10, which the run ENTERS on later passes. The backend
  ## called it declined only because of the defect f0e3f8f0f fixed (#758), and
  ## with that fix the old stop has no declined line; the record was re-taken.
const DeclinedArm = [32, 33, 35, 36]
const DeclinedHeader = 34
  ## The `if` whose arm (35-36) was declined: its test ran, so it is taken.

proc flowRowsOf(s: string): seq[JsonNode] =
  rec()["flowScenarios"][s]["rows"].getElems

suite "PLAT-42 surface 4 — the flow overlay, DRAWN":
  ## Retired `PLAT22-PG2`. The per-line fact is `FlowVM.styledLines` — the
  ## desktop editor's own dimming rule (`ui/flow_line_styles`) applied to the
  ## `ct/updated-flow` window — and GPUI paints a declined line at the desktop
  ## editor's `.line-flow-skip` opacity. Until 2026-09-23 every row here was
  ## `efsUnknown`: the native stdio transport never delivered the event the
  ## window arrives on. The terminal's half is `tui/tests/
  ## test_plat42_flow_overlay_terminal.nim`, which compares against THIS record.

  test "the flow scenarios are exactly the pinned set, on the named recording":
    var got = initHashSet[string]()
    for k, _ in rec()["flowScenarios"]: got.incl k
    ck got == [FlowScenario].toHashSet
    ck rec()["flowTrace"].getStr.startsWith("noir_space_ship-")

  for s in Scenarios:
    test "a program with no branch dims nothing — " & s:
      # `calc` has no `if`, so no line can be in a declined arm. A rule that
      # dimmed "lines with no step" — the defect `flowStyledLines` was
      # rewritten to remove — would dim most of this file.
      for r in rowsOf(s):
        ck r["flow"].getStr in ["efsUnknown", "efsTaken"]
        ck r["codeOpacity"].getStr == ""

  test "the flow reaches the shipped rows at all":
    # The non-vacuity floor for the case above: at least one calc stop carries
    # a positive fact, so "nothing dimmed" is not "nothing loaded".
    var taken = 0
    for s in Scenarios:
      for r in rowsOf(s):
        if r["flow"].getStr == "efsTaken": inc taken
    ck taken > 0

  test "exactly the declined arm is not-taken, and exactly it is painted dimmed":
    var notTaken: seq[int] = @[]
    var dimmed: seq[int] = @[]
    for r in flowRowsOf(FlowScenario):
      if r["flow"].getStr == "efsNotTaken": notTaken.add lineOf(r)
      if r["codeOpacity"].getStr.len > 0:
        ck r["codeOpacity"].getStr == "0.5"
        dimmed.add lineOf(r)
    ck notTaken == @DeclinedArm
    ck dimmed == @DeclinedArm

  test "the header of the declined arm ran, and is not dimmed":
    # Omniscience-Flow.md requires this by name: the condition line is the line
    # whose test was evaluated.
    var found = 0
    for r in flowRowsOf(FlowScenario):
      if lineOf(r) == DeclinedHeader:
        inc found
        ck r["flow"].getStr == "efsTaken"
        ck r["codeOpacity"].getStr == ""
    ck found == 1

  test "the stop itself is a line that ran":
    var pointing = 0
    for r in flowRowsOf(FlowScenario):
      if r["pointer"].getStr == "eptExecution":
        inc pointing
        ck r["flow"].getStr == "efsTaken"
        ck lineOf(r) notin DeclinedArm
    ck pointing == 1

suite "PLAT-42 — a presentation defect found on the way, FIXED":
  test "a Python list of ints renders as a list, not as a hex byte string":
    ## `results` is [5, 7, 42, 17, 2] at the continued-event-log stop. Filed
    ## here as measured — the GPUI inline value read `05 07 2a 11 02
    ## (5 bytes)`, the right numbers in the wrong shape — and fixed in PLAT-2's
    ## pipeline (`value_model.byteBufferOf`: a type that says otherwise vetoes
    ## the byte-buffer claim; this value is a `list` of `int`). `@[…]` is every
    ## front-end's sequence spelling for a non-Rust recording
    ## (`presentationLangOf`), not a PLAT-42 choice.
    let rows = execRows("continued-event-log")
    ck rows.len == 1
    if rows.len == 1:
      let values = rows[0]["values"].getStr
      checkpoint(values)
      ck "bytes)" notin values
      ck "results=@[5, 7, 42, 17, 2]" in values

suite "PLAT-42 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
