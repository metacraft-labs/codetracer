## test_plat60_native_low_level_code.nim — **the Low Level Code pane on the
## terminal over a NATIVE recording: steps by one instruction from the
## listing, and — once the replay server answers a native listing — the
## function's machine code under its source lines, with the execution pointer
## on the stop's own instruction** — on a real session.
##
## A real `replay-server` replaying an rr recording of the shared native
## fixture (`codetracer-native-test-programs/c/sudoku_solver/main.c`, recorded
## by `fixtures/native_recording`) through `ct-native-replay`, opened by the
## terminal's own `openTuiSession`, driven through its own token handler and
## painted by its own `shellScreen`:
##
##   * the listing is the ENGINE's answer for the stop's function (asked
##     again over the raw channel): every instruction at its load address,
##     its mnemonic and operands, its `main.c` line; the function's load
##     address in the header; the execution pointer (`▸`) on the instruction
##     at the stop's pc (`StopLocation.frameOffset`);
##   * the header says a step goes BY INSTRUCTION (the engine's
##     `supportsSteppingGranularity`); F10 pressed in the listing moves the
##     stop by one instruction — the pointer goes to the next instruction of
##     the listing, several presses stay on one source line — and Shift+F10
##     returns to the pc and tick it left; F11 from a call's line enters
##     `is_valid`. The move reaches the store
##     (`HeadlessDebugSession.stepByInstruction`), so the pane follows it.
##
## No mocks: a real rr recording, a real `replay-server` and
## `ct-native-replay`, the terminal's real runtime, host and painters. Without
## `ct-native-replay` or `rr` the cases skip, each printing
## `MISSING-PREREQ SKIP:` with what is missing; a recorder that is present and
## fails fails them.

import std/[json, os, strutils, unicode, unittest]

import isonim/core/[signals]

import headless_session
import view_vocabulary/pane_views
import ../../../common/view_vocabulary

import ../app/runtime
import codetracer_embed
import ../app/tui_app
import ../app/theme/capabilities
import ../app/views/shell
import ../app/views/low_level_code_pane
import ../host/tui_session
import ./fixtures/native_recording

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as the suite's RUNTIME assertion count.
const ExpectedAssertions = 59

var countedAssertions = 0
var skipped = false

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 56
  AltOne = "\x1b1"
  F10 = "\x1b[21~"
  ShiftF10 = "\x1b[21;2~"
  F11 = "\x1b[23~"
  IsValidRowCheck = 21
    ## `if (board[row][c] == num) return false;` in `is_valid`.
  SolveCallsIsValid = 58
    ## `if (is_valid(board, row, col, num)) {` in `solve_sudoku`.

proc newRuntime(): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
  discard result.enableLayoutBinding()
  result.refreshMenuForKeymap()

proc send(s: TuiSession; rt: TuiRuntime; token: string) =
  let outcome = rt.handleToken(token, 0)
  s.applyOutcome(rt, outcome)

proc open(path: string): (TuiRuntime, TuiSession) =
  let rt = newRuntime()
  let s = openTuiSession(path, viewportHeight = Rows - 8)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
  rt.app.lowLevelAct = proc(act: LowLevelAct): LowLevelActResult =
    s.lowLevelAct(rt, act)
  (rt, s)

proc stopAt(s: TuiSession; rt: TuiRuntime; source: string; line: int) =
  ## Continue to a breakpoint on `line` (cleared after), the panes following.
  s.session.setBreakpoint(source, line)
  s.session.continueForward()
  discard s.session.clearBreakpoints(source)
  s.refresh(rt)

proc pc(s: TuiSession): int64 =
  s.session.session.store.stop.val.frameOffset

proc engineListing(s: TuiSession): JsonNode =
  ## The engine's answer for the stop's function, asked over the raw channel.
  let fn = s.session.session.store.asmFunction
  let answer = s.session.sendRawDapRequest("ct/load-asm-function", %*{
    "path": fn.path, "name": fn.name, "key": fn.key, "forceReload": false})
  discard s.session.drainEvents()
  checkpoint("ct/load-asm-function: " & ($answer)[0 ..< min(400, ($answer).len)])
  answer

proc ticks(s: TuiSession): uint64 =
  s.session.getCurrentRRTicks()

proc executing(rt: TuiRuntime): LowLevelPaneRow =
  let at = rt.app.lowLevel.executionRow
  if at >= 0: rt.app.lowLevel.rows[at] else: LowLevelPaneRow(index: -1)

proc instructions(rt: TuiRuntime): seq[LowLevelPaneRow] =
  for r in rt.app.lowLevel.rows:
    if r.kind == lpInstruction: result.add r


suite "the Low Level Code pane over a native (rr) recording":

  let rec = nativeRecording()

  test "the stop's function as machine code, the pointer on its instruction":
    if not rec.ok:
      echo "  ", missingNativePrereq(rec)
      skipped = true
      skip()
    else:
      let (rt, s) = open(rec.tracePath)
      defer: s.close()
      s.stopAt(rt, rec.sourcePath, IsValidRowCheck)
      ck s.session.getCurrentLine() == IsValidRowCheck
      s.send(rt, AltOne)
      ck s.session.session.lowLevelCodeVM.shown.val
      ck s.session.session.store.asmFunction.name == "is_valid"
      # The stop names its instruction: a load address, kept whole.
      ck s.pc > BiggestInt(high(int32))
      let answer = s.engineListing()
      ck answer{"success"}.getBool(false)
      let body = answer{"body"}
      block:
        let engine = body{"instructions"}.getElems
        let address = body{"address"}.getBiggestInt(0)
        ck engine.len > 10
        ck address > 0
        let held = rt.instructions
        ck held.len == engine.len
        for i in 0 ..< min(held.len, engine.len):
          let e = engine[i]
          let want = e{"name"}.getStr & (if e{"args"}.getStr.len > 0:
                                           " " & e{"args"}.getStr else: "")
          if held[i].offset != $e{"offset"}.getBiggestInt or
             not held[i].instruction.startsWith(want):
            checkpoint("row " & $i & ": " & held[i].offset & " " &
                       held[i].instruction & " vs " & $e)
            ck false
            break
        var lines: seq[int] = @[]
        for r in rt.app.lowLevel.rows:
          if r.kind == lpSource: lines.add r.line
        ck IsValidRowCheck in lines
        for l in lines: ck l in 18 .. 36
        ck rt.app.lowLevel.address.startsWith("Originating address: 0x")
        # THE EXECUTION POINTER: the stop's own instruction, with its glyph.
        let at = rt.executing
        ck at.offset == $s.pc
        ck at.crossRef.endsWith(":" & $IsValidRowCheck)
        var drawn = false
        for row in rt.shellScreenOf().rows:
          if row.contains("▸") and row.contains(at.offset): drawn = true
        ck drawn
        # GPUI's view of the same ViewModel lists the same offsets.
        let view = lowLevelCodePaneView(s.session.session.lowLevelCodeVM)
        var offsets: seq[string] = @[]
        for n in walk(view.root):
          if n.kind == pkTable:
            for row in n.rows:
              # A source line's row is `["", line, text, path:line]`; an
              # instruction's second cell is its offset.
              if row.len > 3 and not row[3].endsWith(":" & row[1]):
                offsets.add row[1]
        var mine: seq[string] = @[]
        for r in held: mine.add r.offset
        ck offsets == mine
        # An instruction step moves the pointer to the next instruction.
        let from0 = rt.executing
        let mnemonic = from0.instruction.split(' ')[0]
        s.send(rt, F10)
        if mnemonic.len > 0 and mnemonic[0] != 'j' and
           not mnemonic.startsWith("call") and not mnemonic.startsWith("ret"):
          var nextOffset = ""
          for i, r in held:
            if r.offset == from0.offset and i + 1 < held.len:
              nextOffset = held[i + 1].offset
          ck rt.executing.offset == nextOffset

  test "a step in the listing goes by one instruction, both ways":
    if not rec.ok:
      echo "  ", missingNativePrereq(rec)
      skipped = true
      skip()
    else:
      let (rt, s) = open(rec.tracePath)
      defer: s.close()
      s.stopAt(rt, rec.sourcePath, IsValidRowCheck)
      s.send(rt, AltOne)
      let (focused, pane) = rt.focus.focusedPane()
      ck focused and pane == paneLowLevelCode
      ck rt.app.lowLevel.stepping == SteppingByInstructionText
      # Forward by one instruction: the pc moves, and the line stays while it
      # has instructions left (a line step would leave it).
      var stayedOnLine = false
      for _ in 0 ..< 4:
        let fromPc = s.pc
        let fromTicks = s.ticks
        let fromLine = s.session.getCurrentLine()
        s.send(rt, F10)
        ck s.pc > 0 and s.pc != fromPc
        if s.session.getCurrentLine() == fromLine: stayedOnLine = true
        let toPc = s.pc
        # Back by one instruction: the pc and the tick it left.
        s.send(rt, ShiftF10)
        ck s.pc == fromPc
        ck s.ticks == fromTicks
        s.send(rt, F10)
        ck s.pc == toPc
      ck stayedOnLine

  test "step into by instruction at a call enters the callee":
    if not rec.ok:
      echo "  ", missingNativePrereq(rec)
      skipped = true
      skip()
    else:
      let (rt, s) = open(rec.tracePath)
      defer: s.close()
      s.stopAt(rt, rec.sourcePath, SolveCallsIsValid)
      s.send(rt, AltOne)
      ck s.session.session.store.stop.val.functionName == "solve_sudoku"
      # F11 one instruction at a time: the line's instructions, then the
      # call, then the callee's first instruction.
      var entered = false
      for _ in 0 ..< 40:
        s.send(rt, F11)
        if s.session.session.store.stop.val.functionName == "is_valid":
          entered = true
          break
        ck s.session.session.store.stop.val.functionName == "solve_sudoku"
      ck entered
      ck s.session.getCurrentLine() == 18
      ck s.session.session.lowLevelCodeVM.shown.val

suite "native Low Level Code suite self-check":
  test "native_low_level_code_assertion_count_is_measured":
    if skipped:
      skip()
    else:
      checkpoint("assertions: " & $countedAssertions)
      check countedAssertions == ExpectedAssertions
