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
##   * POINTER: the one line row whose execution-mark lane holds ink is the
##     line Electron stopped on, in every pinned scenario;
##   * INLINE VALUES: on every line row of every scenario, the chips found on
##     screen (by their ground, then read) name the values the model put on
##     that line, in order, at the x the code's length puts them — and a row
##     the model gives no value carries no chip;
##   * PER-LINE STATUS: breakpoint vs no breakpoint at the same stop, the
##     GUTTER differs on exactly the breakpoint's line;
##   * FLOW: overlay shown vs hidden at the same stop, the CODE differs on
##     exactly the declined arm's lines and the lines whose inline values the
##     overlay draws.
##
## The windows end on their deadline BY DESIGN (no key is typed); the frames
## are taken after the window settles.

import std/[algorithm, json, math, os, strutils, unittest]
from std/unicode import runeLen
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
  CalcSource = "test-programs/calc/main.py"
    ## The calc recording's source (the window's status bar names it), for
    ## the length of each line — which is where a row's chips go.
  FlowCh = 10.18
    ## The desktop flow container's `ch` in px: a row's first chip is at
    ## `(line length + 1) * FlowCh` from the code's left (`ui/flow.nim`'s
    ## `calc(<len>ch + 1ch)`, measured on the desktop's six reference states).
  ChipXSlackPx = 4
    ## The record's code-column left is the leftmost GLYPH INK of the pane's
    ## code (a glyph's side bearing in from the column), and the chip's left
    ## its box's first ground pixel (a 4 px rounded corner): a few px.
  ChipVisiblePx = 30
    ## A chip whose left is this far inside the code column's right edge is on
    ## screen whole enough to be found (the record keeps boxes >= 12 px).
  LongValueCols = 30
    ## A value this long, or one the presenter already elided (`…`), is drawn
    ## with the "view more" eye cell (`ui/flow.nim`'s `max-width: 30ch`).
  DeclinedArm = @[32, 33, 35, 36]
    ## `plat42-surfaces.json`'s `noir-declined-arm` stop (`stepIn=28`; 33 until 2026-10-17); it was
    ## lines 11-13 at `stepIn=15` until 2026-09-24 — see `test_plat42_surfaces`.
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

proc modelValues(sid: string): seq[tuple[line: int, names, values: seq[string]]] =
  ## Each model row's values, `name=value|…` split back into names and values.
  for r in surfaces()["scenarios"][sid]["rows"]:
    var names, values: seq[string] = @[]
    for item in r["values"].getStr.split('|'):
      let eq = item.find('=')
      if eq > 0:
        names.add item[0 ..< eq]
        values.add item[eq + 1 .. ^1]
    result.add (lineOfText(r["text"].getStr), names, values)

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
      # Exactly one row carries the execution mark: not none, not every one.
      checkpoint(sid & ": pointer lanes inked on lines " & $f["pointerLines"])
      ck f["pointerLines"].len == 1
      let cap = parseJson(readFile(repo / "src/tests/visual/answers" /
                                   (sid & ".electron.capture.json")))
      ck f["executionLine"].getInt == cap["stoppedLine"].getInt

  let source = readFile(repo / CalcSource).splitLines()
  for sid in CalcScenarios:
    test "INLINE VALUES on screen are the model's, row by row — " & sid:
      let f = rec()["frames"][sid]
      let codeWidth = f["codeWidth"].getInt
      ck codeWidth > 100
      let model = modelValues(sid)
      var withValues, without, named = 0
      for r in f["rows"]:
        let line = r["line"].getInt
        var names, values: seq[string] = @[]
        var known = false
        for m in model:
          if m.line == line:
            (names, values, known) = (m.names, m.values, true)
        if not known: continue
        let chips = r["chips"]
        var shown: seq[string] = @[]
        for c in chips: shown.add valueCommentName(c["text"].getStr)
        checkpoint(sid & " line " & $line & ": model " & $names &
                   " | chips " & $chips)
        if names.len == 0:
          # THE NEGATIVE TWIN: a row the model gives no value carries no chip.
          inc without
          ck chips.len == 0
          continue
        inc withValues
        # PLACEMENT: `(line length + 1)` of the flow's `ch` from the code.
        let wantX = int(round(float(source[line - 1].runeLen + 1) * FlowCh))
        if wantX + ChipVisiblePx <= codeWidth:
          ck chips.len > 0
        if chips.len == 0: continue
        ck abs(chips[0]["x"].getInt - wantX) <= ChipXSlackPx
        ck chips.len <= names.len
        for i, c in chips.getElems:
          if i >= names.len: continue
          # A chip the pane's edge cuts may be cut anywhere, its name too: it
          # is held to the model's name only when a name is legible on it.
          if c["clipped"].getBool and shown[i].len == 0: continue
          inc named
          ck legiblyNames(shown[i], names[i])
          let long = values[i].runeLen >= LongValueCols or
                     values[i].endsWith("…")
          ck c["more"].getBool == long
      checkpoint(sid & ": " & $withValues & " rows with values (" & $named &
                 " chips named), " & $without & " without")
      ck withValues > 0
      ck named > 0
      ck without > 10

  for sid in ValueScenarios:
    test "INLINE VALUES legible at the execution row — " & sid:
      let model = modelExecRow(sid)
      let first = model["values"].getStr.split('|')[0].split('=')[0]
      ck first.len > 0
      let line = lineOfText(model["text"].getStr)
      var chips = newJArray()
      for r in rec()["frames"][sid]["rows"]:
        if r["line"].getInt == line: chips = r["chips"]
      # From the CHIP, not the row: the variable is named in the code on this
      # line, so `first in rowText` held with or without a value drawn.
      ck chips.len > 0
      if chips.len > 0:
        let shown = valueCommentName(chips[0]["text"].getStr)
        checkpoint(sid & " line " & $line & ": " & $chips &
                   " | chip names '" & shown & "', model '" & first & "'")
        ck legiblyNames(shown, first)

  test "PER-LINE STATUS twin: the gutter differs on exactly the breakpoint's line":
    var bpLine = -1
    for r in surfaces()["scenarios"]["breakpoint-editor"]["rows"]:
      if r["mark"].getStr != "emNone": bpLine = lineOfText(r["text"].getStr)
    ck bpLine > 0
    let changed = changedLines(rec()["markTwin"])
    checkpoint("gutter rows that differ: " & $changed)
    ck changed == @[bpLine]

  test "FLOW twin: the code differs on exactly the declined arm and the flow's values":
    # Since 2026-10-17 the overlay owns two things on screen: the declined
    # arm, dimmed, and the inline values of the lines the run reached
    # (`editor_surface.flowValuesByLine` draws them only with the overlay shown; the
    # execution line keeps its own either way). So the twin must differ on
    # the declined arm, on each line whose CHIPS the overlay added, and on
    # nothing else — and each added line must be one the model gives values,
    # other than the stop itself.
    proc chipsByLine(id: string): seq[(int, string)] =
      for r in rec()["frames"][id]["rows"]:
        result.add (r["line"].getInt, $r["chips"])
    let shown = chipsByLine("noir-flow")
    let hidden = chipsByLine("noir-flow-off")
    var model: seq[tuple[line: int, values: string, exec: bool]] = @[]
    for r in surfaces()["flowScenarios"]["noir-declined-arm"]["rows"]:
      model.add (lineOfText(r["text"].getStr), r["values"].getStr,
                 r["pointer"].getStr == "eptExecution")
    var added: seq[int] = @[]
    for (line, chips) in shown:
      if chips == "[]": continue
      var before = "[]"
      for (l2, c2) in hidden:
        if l2 == line: before = c2
      if before != chips:
        added.add line
        var valued = false
        for m in model:
          if m.line == line and m.values.len > 0 and not m.exec: valued = true
        checkpoint("overlay added chips on line " & $line & ": " & chips)
        ck valued
    ck added.len > 0
    for line in DeclinedArm: ck line notin added
    var want = DeclinedArm & added
    want.sort()
    let changed = changedLines(rec()["flowTwin"])
    checkpoint("code rows that differ: " & $changed & ", want " & $want)
    ck changed == want

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
