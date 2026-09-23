## PLAT-42 — DIFF-11: the four surfaces, two media, one model — compared
## through what each medium PUT ON THE SCREEN.
##
## Run (tui-real-terminal lane flags; needs `just build-tui`):
##   nim c -r <flags> src/frontend/tui/tests/real_terminal/test_plat42_diff11.nim
##
## **THE §30a TRAP, IN ITS EXACT SHAPE, IS WHAT THIS FILE IS BUILT AROUND.**
## Both native editors derive their rows from `editor_rows`, so comparing
## their `EditorRow` values is two reads of one value and cannot fail. So
## nothing here reads a ViewModel. The two sides are:
##
##   * THE TERMINAL: the SHIPPED `codetracer-tui` binary in a real pty, driven
##     by keys (`s`, `n`, `f`, `c`, `:break N`), its screen parsed by libvterm
##     — the cells a user sees, colours included;
##   * THE GPUI WINDOW: `src/tests/visual/plat42-window.json`, which is
##     PLAT-39's reader run over frames of the shipped `codetracer-gpui` in a
##     real window (`ci/test/plat42-surfaces-window.sh`) — the pointer
##     recovered from the execution band's pixels, the rows' text by OCR, and
##     two pixel twins.
##
## Per concern, at the stops `scenarios.json` pins:
##
##   * POINTER: the line the terminal paints `-->` on == the line PLAT-39
##     read off the GPUI frame, at every calc stop the reader could read;
##   * INLINE VALUES: at each stop the terminal draws a value on, the first
##     name it draws is legible on the same line of the GPUI frame; at the
##     quiet stop neither medium draws one;
##   * PER-LINE STATUS: the one gutter line the GPUI mark twin changed is the
##     one line the terminal marks after `:break` on it — and no other;
##   * FLOW: the lines whose code the terminal recolours when the overlay is
##     hidden (`--no-flow-overlay`, both binaries' flag) == the lines the GPUI
##     flow twin's pixels changed on.
##
## NO MOCKS. Two shipped binaries, two real recordings, a real pty, real
## window frames; nothing constructed by this file is compared with anything.

import std/[json, monotimes, os, sets, strutils, times, unicode, unittest]

import term_assert

import ../../../gpui/tests/plat42_gutter
import ../../testing/dual_snap
import ../fixtures/fixture_provider
import ./lifecycle_support

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 220
  Rows = 64
  PointerGlyph = "-->"
  MarkGlyph = "●"
  SettleQuietMs = 1500
  StepTimeoutS = 180
  CalcScenarios = ["entry-shell", "stepped-editor", "advanced-state",
                   "returned-calltrace", "continued-event-log",
                   "breakpoint-editor"]
  ValueScenarios = ["advanced-state", "returned-calltrace",
                    "continued-event-log"]
  QuietScenario = "stepped-editor"
  FlowStepIns = 15
  TwinFloor = 0.2
    ## A GPUI twin row "changed" above this INK fraction. The record's
    ## changed rows measure ~0.93 and its untouched rows 0.0 (see
    ## `test_plat42_window.nim`, which asserts that separation).

let repo = lifecycle_support.repoRoot()
let windowRecord = parseJson(readFile(repo / "src/tests/visual/plat42-window.json"))

type
  TermRow = object
    screenRow: int
    line: int
    marked: bool
    codeCol: int      ## first column of the code
    code: string      ## the code and anything after it, to the pane's edge

# ---------------------------------------------------------------------------
# Driving the shipped binary
# ---------------------------------------------------------------------------

proc settleAfter(sess: var TuiTestSession; before: string) =
  ## Wait for the screen to CHANGE from `before`, then to stop changing for
  ## `SettleQuietMs`, then for the frame's cursor barrier. A step that takes
  ## a while on a loaded host is waited for rather than read half-painted.
  let deadline = getMonoTime() + initDuration(seconds = StepTimeoutS)
  while getMonoTime() < deadline:
    discard sess.drainOutput(100)
    if sess.screenContents() != before: break
  var last = sess.screenContents()
  var since = getMonoTime()
  while getMonoTime() < deadline:
    discard sess.drainOutput(100)
    let now = sess.screenContents()
    if now != last:
      last = now
      since = getMonoTime()
    elif getMonoTime() - since > initDuration(milliseconds = SettleQuietMs):
      break
  waitForCompleteFrame(sess, Cols, Rows, timeoutMs = 30000)

proc press(sess: var TuiTestSession; bytes: string) =
  let before = sess.screenContents()
  sess.send(bytes)
  settleAfter(sess, before)

proc keyFor(kind: string): string =
  case kind
  of "stepIn": "s"
  of "next": "n"
  of "stepOut": "f"
  of "continueForward": "c"
  else: ""

proc open(trace: string; extra: seq[string] = @[]): TuiTestSession =
  result = tuiSession(extra & @[trace], cols = Cols, rows = Rows)
  settleOnDebugger(result, Cols, Rows)

# ---------------------------------------------------------------------------
# Reading the terminal's screen
# ---------------------------------------------------------------------------

proc sourceRows(sess: var TuiTestSession): seq[TermRow] =
  ## The source pane's rows, located by the one row that carries the
  ## execution pointer: the gutter number ends one gap before its column on
  ## EVERY row of the pane (`views/gutter.gutterRow`: mark, number, gap,
  ## pointer, gap), so the pointer's column locates the gutter everywhere.
  let lines = sess.screenContents().splitLines()
  var pcol = -1
  for l in lines:
    let rs = l.toRunes
    for c in 1 .. rs.len - 3:
      if $rs[c ..< c + 3] == PointerGlyph and rs[c - 1] == Rune(' ') and
         c >= 2 and ($rs[c - 2]).len == 1 and ($rs[c - 2])[0].isDigit:
        pcol = c
        break
    if pcol >= 0: break
  if pcol < 0: return
  var candidates: seq[TermRow] = @[]
  var pointerAt = -1
  for i, l in lines:
    let rs = l.toRunes
    if rs.len <= pcol + 4: continue
    let gutter = $rs[max(0, pcol - 12) ..< pcol]
    let trimmed = gutter.strip(leading = false)
    var j = trimmed.len
    while j > 0 and trimmed[j - 1].isDigit: dec j
    if j == trimmed.len: continue
    var code = $rs[pcol + 4 .. ^1]
    let edge = code.find("│")
    if edge >= 0: code = code[0 ..< edge]
    if $rs[pcol ..< pcol + 3] == PointerGlyph: pointerAt = candidates.len
    candidates.add TermRow(screenRow: i, line: parseInt(trimmed[j .. ^1]),
                           marked: MarkGlyph in gutter, codeCol: pcol + 4,
                           code: code)
  # ONLY THE SOURCE PANE: the run of adjacent screen rows around the
  # pointer's whose line numbers are consecutive. Another pane below or
  # beside it can hold digits at the same columns (measured: the event log's
  # rows parsed as lines 100 and 10).
  if pointerAt < 0: return
  var lo = pointerAt
  while lo > 0 and candidates[lo - 1].screenRow == candidates[lo].screenRow - 1 and
        candidates[lo - 1].line == candidates[lo].line - 1:
    dec lo
  var hi = pointerAt
  while hi < candidates.high and
        candidates[hi + 1].screenRow == candidates[hi].screenRow + 1 and
        candidates[hi + 1].line == candidates[hi].line + 1:
    inc hi
  result = candidates[lo .. hi]

proc pointerLine(sess: var TuiTestSession): int =
  let lines = sess.screenContents().splitLines()
  for r in sourceRows(sess):
    if PointerGlyph in ($lines[r.screenRow].toRunes[max(0, r.codeCol - 5) ..<
                                                    r.codeCol]):
      return r.line
  -1

proc firstValueName(code: string): string =
  ## The first name in the row's `/* name: value, … */` annotation, or "".
  let at = code.find("/*")
  if at < 0: return ""
  var i = at + 2
  while i < code.len and code[i] == ' ': inc i
  var name = ""
  while i < code.len and (code[i].isAlphaNumeric or code[i] == '_'):
    name.add code[i]
    inc i
  if i < code.len and code[i] == ':': name else: ""

proc codeColours(sess: var TuiTestSession; r: TermRow): seq[string] =
  ## The foreground of every non-blank code cell on `r`, as text.
  let rs = r.code.toRunes
  for k in 0 ..< rs.len:
    if rs[k] != Rune(' '):
      let cell = sess.cellAt(r.screenRow, r.codeCol + k)
      result.add $cell.fg

# ---------------------------------------------------------------------------
# Reading the GPUI record
# ---------------------------------------------------------------------------

proc gpuiFrame(sid: string): JsonNode = windowRecord["frames"][sid]

proc gpuiRowText(sid: string; line: int): string =
  for r in gpuiFrame(sid)["rows"]:
    if r["line"].getInt == line: return r["text"].getStr
  ""

proc gpuiChanged(twin: string): seq[int] =
  for r in windowRecord[twin]:
    if r["changed"].getFloat > TwinFloor: result.add r["line"].getInt

proc scenarioOps(sid: string): JsonNode =
  let sj = parseJson(readFile(repo / "src/tests/visual/scenarios.json"))
  for s in sj["scenarios"]:
    if s["id"].getStr == sid:
      return s{"operations"}
  newJArray()

# ---------------------------------------------------------------------------

suite "PLAT-42 DIFF-11: the four surfaces on both native media, as painted":

  let calc = resolveFixture("calc")
  let noir = resolveFixture("noir_space_ship")

  test "the binary, the recordings and the window record this lane needs exist":
    if not fileExists(tuiBinary()):
      checkpoint("missing " & tuiBinary() & " — run `just build-tui`")
    ck fileExists(tuiBinary())
    ck calc.outcome == foRecorded
    ck noir.outcome == foRecorded
    # The window record must be about THESE recordings.
    for m in windowRecord["manifest"]:
      if m["id"].getStr == "blank":
        continue
      if m["id"].getStr.startsWith("noir"):
        ck m["trace"].getStr == noir.tracePath.lastPathPart
      else:
        ck m["trace"].getStr == calc.tracePath.lastPathPart
      ck m{"settled"}.getBool(false)

  for sid in CalcScenarios:
    test "POINTER, VALUES and STATUS agree with the GPUI frame — " & sid:
      if calc.outcome != foRecorded:
        ck false
      else:
        var sess = open(calc.tracePath)
        defer:
          sess.send("q")
          discard sess.waitExit(initDuration(seconds = 10))
          sess.close()
        var bpLine = -1
        for op in scenarioOps(sid):
          let kind = op["kind"].getStr
          if kind == "setBreakpoint":
            # The line GPUI's frame shows marked: the ONE gutter row its mark
            # twin changed. The terminal is asked for that line by `:break`.
            let changed = gpuiChanged("markTwin")
            ck changed.len == 1
            if changed.len == 1:
              bpLine = changed[0]
              sess.press(":break " & $bpLine & "\r")
          else:
            for _ in 0 ..< op{"times"}.getInt(1):
              sess.press(keyFor(kind))

        # --- POINTER ------------------------------------------------------
        let termLine = sess.pointerLine()
        let gpuiLine = gpuiFrame(sid)["executionLine"].getInt
        checkpoint(sid & ": terminal pointer " & $termLine &
                   ", GPUI frame (PLAT-39) " & $gpuiLine)
        ck termLine > 0
        ck gpuiLine > 0
        ck termLine == gpuiLine

        # --- INLINE VALUES ------------------------------------------------
        var execCode = ""
        for r in sess.sourceRows():
          if r.line == termLine: execCode = r.code
        let name = firstValueName(execCode)
        let gpuiText = gpuiRowText(sid, gpuiLine)
        checkpoint("terminal: " & execCode.strip & " | GPUI: " & gpuiText)
        # The GPUI side is read from its value COMMENT (`plat42_gutter`),
        # never from the row: the variable is named in the code on that line.
        let gpuiName = valueCommentName(gpuiText)
        if sid in ValueScenarios:
          ck name.len > 0
          ck legiblyNames(gpuiName, name)
        if sid == QuietScenario:
          ck name.len == 0
          ck gpuiName.len == 0

        # --- PER-LINE STATUS ------------------------------------------------
        var marked: seq[int] = @[]
        for r in sess.sourceRows():
          if r.marked: marked.add r.line
        checkpoint("terminal marks: " & $marked)
        if bpLine > 0:
          ck marked == @[bpLine]
        else:
          ck marked.len == 0

  test "FLOW: the terminal recolours exactly the lines GPUI's pixels changed":
    if noir.outcome != foRecorded:
      ck false
    else:
      var colours: array[2, seq[(int, seq[string])]]
      for i, extra in [newSeq[string](), @["--no-flow-overlay"]]:
        var sess = open(noir.tracePath, extra)
        for _ in 0 ..< FlowStepIns:
          sess.press("s")
        for r in sess.sourceRows():
          colours[i].add (r.line, sess.codeColours(r))
        sess.send("q")
        discard sess.waitExit(initDuration(seconds = 10))
        sess.close()
      var changed: seq[int] = @[]
      for (line, shown) in colours[0]:
        for (line2, hidden) in colours[1]:
          if line2 == line and shown != hidden:
            changed.add line
            checkpoint("line " & $line & " shown=" & $shown & " hidden=" &
                       $hidden)
      let gpui = gpuiChanged("flowTwin")
      checkpoint("terminal recoloured " & $changed & "; GPUI pixels " & $gpui)
      ck gpui.len > 0
      ck changed == gpui

  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
