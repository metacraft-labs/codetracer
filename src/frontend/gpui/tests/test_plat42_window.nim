## PLAT-42 — the four surfaces ON SCREEN, with negative twins, from the
## committed window record.
##
## Run:
##   nim c -r src/frontend/gpui/tests/test_plat42_window.nim
##
## `src/tests/visual/plat42-window.json` is measured by
## `ci/test/plat42-surfaces-window.sh` (each pinned stop in a real
## `codetracer-gpui` window on a headless sway, framed with `grim`) and read by
## `plat42_window_record.nim` through PLAT-39's pixel reader. This suite reads
## no binary and no image. Against lines the MODEL names — the shipped binary's
## render-plan record (`plat42-surfaces.json`) and the Electron capture's
## stopped line — it asserts, for each surface, the line it is on and a
## negative twin at the lines it is not:
##
##   * POINTER: the highlighted line PLAT-39 recovers from pixels is the
##     line Electron stopped on, in every pinned scenario;
##   * INLINE VALUES: the text of the execution row, read off the screen,
##     carries the first value name the model put there — and at the quiet
##     stop no row carries a value comment at all;
##   * PER-LINE STATUS: breakpoint vs no breakpoint at the same stop, the
##     GUTTER differs on exactly the breakpoint's line;
##   * FLOW: overlay shown vs hidden at the same stop, the CODE differs on
##     exactly the declined arm's lines.
##
## The windows end on their deadline BY DESIGN (no key is typed); the frames
## are taken after the window settles.

import std/[json, os, strutils, unittest]
import ./plat42_gutter

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let recordPath = repo / "src/tests/visual/plat42-window.json"

const
  CalcScenarios = ["entry-shell", "stepped-editor", "advanced-state",
                   "returned-calltrace", "continued-event-log",
                   "breakpoint-editor"]
  ValueScenarios = ["advanced-state", "returned-calltrace",
                    "continued-event-log"]
  QuietScenario = "stepped-editor"
  DeclinedArm = @[11, 12, 13]
  TwinFloor = 0.01
    ## A row "differs" when more than 1% of its band's pixels moved by more
    ## than the record's `pixelDelta`. Not a timing and not a tuned budget:
    ## the untouched rows of both twins measure the noise floor in the record
    ## itself, and the case below asserts they sit under it.

proc rec(): JsonNode = parseJson(readFile(recordPath))
proc surfaces(): JsonNode =
  parseJson(readFile(repo / "src/tests/visual/plat42-surfaces.json"))

proc lineOfText(t: string): int = gutterLineOf(t)

proc modelExecRow(sid: string): JsonNode =
  for r in surfaces()["scenarios"][sid]["rows"]:
    if r["pointer"].getStr == "eptExecution": return r
  nil

proc changedLines(twin: JsonNode): seq[int] =
  for r in twin:
    if r["changed"].getFloat > TwinFloor: result.add r["line"].getInt

suite "PLAT-42: the four surfaces in a real window":

  test "the record is present and provenanced":
    ck fileExists(recordPath)
    ck rec()["takenAt"].getStr.len > 0
    ck rec()["host"].getStr.len > 0

  test "every frame's line labels rest on a MAJORITY of its rows' own gutters":
    # The record labels rows by vote (`plat42_window_record.rowBands`): row i
    # is line firstLine + i, firstLine being the majority of each row's OCR'd
    # gutter minus its index. A label that a minority of rows supports is a
    # guess, and every assertion below would inherit it.
    for id, f in rec()["frames"]:
      if id == "blank": continue
      let v = f["lineVote"]
      checkpoint(id & ": " & $v)
      ck v["rows"].getInt > 10
      ck v["support"].getInt * 2 > v["rows"].getInt

  for sid in CalcScenarios:
    test "POINTER on screen is the line Electron stopped on — " & sid:
      let f = rec()["frames"][sid]
      ck f["present"].getBool
      ck f["editorLocated"].getBool
      let cap = parseJson(readFile(repo / "src/tests/visual/answers" /
                                   (sid & ".electron.capture.json")))
      ck f["executionLine"].getInt == cap["stoppedLine"].getInt

  for sid in ValueScenarios:
    test "INLINE VALUES legible at the execution row — " & sid:
      let model = modelExecRow(sid)
      let first = model["values"].getStr.split('|')[0].split('=')[0]
      ck first.len > 0
      let line = lineOfText(model["text"].getStr)
      var screenRow = ""
      for r in rec()["frames"][sid]["rows"]:
        if r["line"].getInt == line: screenRow = r["text"].getStr
      # From the value COMMENT, not the row: the variable is named in the
      # code on this line, so `first in screenRow` held with or without a
      # value drawn. The pane may clip the comment (`/* re…`).
      let shown = valueCommentName(screenRow)
      checkpoint(sid & " line " & $line & ": " & screenRow &
                 " | comment names '" & shown & "', model '" & first & "'")
      ck legiblyNames(shown, first)

  test "and at the quiet stop no row carries a value comment":
    # A value comment is `/* name…`, not any `/*`: measured, OCR reads the
    # docstring's ``//`` on line 45 as `*//*`.
    for r in rec()["frames"][QuietScenario]["rows"]:
      ck valueCommentName(r["text"].getStr) == ""

  test "PER-LINE STATUS twin: the gutter differs on exactly the breakpoint's line":
    var bpLine = -1
    for r in surfaces()["scenarios"]["breakpoint-editor"]["rows"]:
      if r["mark"].getStr != "emNone": bpLine = lineOfText(r["text"].getStr)
    ck bpLine > 0
    let changed = changedLines(rec()["markTwin"])
    checkpoint("gutter rows that differ: " & $changed)
    ck changed == @[bpLine]

  test "FLOW twin: the code differs on exactly the declined arm's lines":
    let changed = changedLines(rec()["flowTwin"])
    checkpoint("code rows that differ: " & $changed)
    ck changed == DeclinedArm

  test "the BLANK control: the reader finds none of the four surfaces":
    # A frame of the compositor before any window existed. No editor pane,
    # so no pointer, no row, no value and no mark — the control every
    # surface reading above is measured against.
    let b = rec()["frames"]["blank"]
    ck b["present"].getBool
    ck not b["editorLocated"].getBool
    ck b["executionLine"].getInt == -1
    ck b["rows"].len == 0

  test "the twins' untouched rows sit at the noise floor":
    # The floor is justified by the record, not asserted into it: every row a
    # twin does NOT change must measure below it.
    for twinName in ["markTwin", "flowTwin"]:
      var quiet = 0
      for r in rec()[twinName]:
        if r["changed"].getFloat <= TwinFloor: inc quiet
      ck quiet > 5

suite "PLAT-42 window — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
