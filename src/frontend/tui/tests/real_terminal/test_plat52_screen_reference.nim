## test_plat52_screen_reference.nim — PLAT-52, the Terminal Output pane's
## SCREEN, checked against a reference terminal emulator.
##
## The recording of a real full-screen program (`test-programs/terminal_screen`:
## the alternate screen, absolute cursor addressing, erase in display and in
## line, insert / delete line, a scroll region, colours, a clear mid-run),
## through a real `replay-server` (`ct/load-terminal`, the producer both native
## front-ends call). Its writes are fed to the shared model
## (`viewmodels/terminal_output_model`, the emulator every front-end draws)
## AND to libvterm (`nim-libvterm`, the emulator TermAssert reads real
## terminals with), and the two screens are compared cell for cell — the
## character, its colours, bold, italic, underline, reverse — at several
## writes: the first frame, a frame after the scroll region filled, the frame
## after the mid-run clear, the last frame, and after the program left the
## alternate screen.
##
## libvterm is fed the bytes as the terminal device delivers them: a line
## feed the program wrote reaches a terminal as CR LF (ONLCR), which the
## shared model applies itself (`TermScreen.control`).
##
## And the COST (§3): the screen after every write, scrubbed through in order
## and then in a scattered order, each reconstruction within a frame (16 ms),
## replaying at most one snapshot interval.
##
## No mocks: the recording, the engine and the reference emulator are real.

import std/[monotimes, os, strutils, times, unicode, unittest]

import isonim/core/[signals, computation]
import nim_libvterm

import headless_session
import store/types
import viewmodels/terminal_output_vm
import ../../../viewmodel/host/terminal_output_source
import ../fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 21

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const FrameBudgetMs = 16.0

proc sameColour(model: TermColor; other: Color): bool =
  case model.kind
  of tckDefault: other.kind == ckDefault
  of tckIndexed: other.kind == ckIndexed and int(other.idx) == model.index
  of tckRgb:
    other.kind == ckRgb and int(other.r) == model.r and
      int(other.g) == model.g and int(other.b) == model.b

proc differences(m: TermScreen; v: Screen; limit = 6): seq[string] =
  ## Every cell where the shared model and libvterm disagree.
  for r in 0 ..< m.rows:
    for c in 0 ..< m.cols:
      let mc = m.cellAt(r, c)
      let vc = v.cellAt(r, c)
      if mc.wide == -1 or vc.width == 0:
        continue
      let mt = if mc.ch == 0: Rune(' ') else: Rune(mc.ch)
      let vt = if int(vc.rune) == 0: Rune(' ') else: vc.rune
      var why = ""
      if mt != vt:
        why = "char '" & $mt & "' vs '" & $vt & "'"
      else:
        let a = m.attrsOf(mc)
        let blank = mt == Rune(' ')
        if not sameColour(a.bg, vc.bg):
          why = "bg " & $a.bg & " vs " & $vc.bg
        elif not blank and not sameColour(a.fg, vc.fg):
          why = "fg " & $a.fg & " vs " & $vc.fg
        elif not blank and a.bold != (caBold in vc.attrs):
          why = "bold"
        elif not blank and a.italic != (caItalic in vc.attrs):
          why = "italic"
        elif not blank and a.underline != (vc.underline != usNone):
          why = "underline"
        elif a.reverse != (caReverse in vc.attrs):
          why = "reverse"
      if why.len > 0:
        result.add "(" & $r & "," & $c & ") " & why
        if result.len >= limit: return

let screenRec = resolveFixture(FixtureSpec(
  name: "terminal_screen", program: "test-programs/terminal_screen/main.py",
  recorder: "codetracer-python-recorder",
  probe: FixtureProbe(kind: pkPythonRecorder),
  buildHint: "Install codetracer_python_recorder into the interpreter `ct` " &
             "will use.",
  blockedOn: ""))

suite "PLAT-52: the screen is libvterm's screen, at every write checked":

  test "the shared model and libvterm agree cell for cell":
    require screenRec.outcome == foRecorded
    let s = newHeadlessDebugSession(screenRec.tracePath, findReplayServer())
    defer: s.close()
    let n = s.loadTerminalOutput()
    let vm = s.session.terminalOutputVM
    let writes = vm.events.val
    checkpoint($n & " writes")
    ck n == writes.len
    ck n >= 30
    ck vm.screen.offered
    # The writes to check: the first frame, one after the scroll region
    # filled, the one after the mid-run clear, the last frame, the end.
    var clearAt = -1
    for m in vm.screen.marks:
      if m.kind == smClear: clearAt = m.write
    ck clearAt > 0
    let checkpoints = @[2, 12, clearAt, clearAt + 1, n - 2, n - 1]
    var reference = newScreen(DefaultScreenRows, DefaultScreenCols)
    var fed = -1
    var checked = 0
    for w in checkpoints:
      while fed < w:
        inc fed
        reference.feed(writes[fed].content.replace("\n", "\r\n"))
      let model = vm.screen.screenAfter(w)
      let diffs = differences(model, reference)
      if diffs.len > 0:
        checkpoint("write " & $w & ": " & diffs.join("; "))
      ck diffs.len == 0
      ck model.altActive == reference.altScreenActive
      inc checked
    ck checked == 6
    # A screen worth checking: the dashboard is on it mid-run.
    let mid = vm.screen.screenAfter(clearAt + 1)
    var text = ""
    for r in 0 ..< mid.rows:
      text.add mid.screenRowText(r) & "\n"
    ck text.contains("dashboard (second half)")
    ck text.contains("TASK")

  test "a scrub across the whole session stays within the frame budget":
    require screenRec.outcome == foRecorded
    let s = newHeadlessDebugSession(screenRec.tracePath, findReplayServer())
    defer: s.close()
    discard s.loadTerminalOutput()
    let m = s.session.terminalOutputVM.screen
    let n = m.writeCount
    var worstMs = 0.0
    var worstReplay = 0
    var order: seq[int] = @[]
    for w in 0 ..< n: order.add w            # a drag, start to end
    for w in countdown(n - 1, 0): order.add w   # and back
    var k = 7
    for _ in 0 ..< n:                         # then scattered jumps
      k = (k * 31 + 11) mod n
      order.add k
    for w in order:
      let t0 = getMonoTime()
      discard m.screenAfter(w)
      let ms = float((getMonoTime() - t0).inNanoseconds) / 1e6
      worstMs = max(worstMs, ms)
      worstReplay = max(worstReplay, m.replayed)
    checkpoint("worst " & formatFloat(worstMs, ffDecimal, 3) & " ms, worst " &
               "replay " & $worstReplay & " writes of " & $n &
               ", snapshot every " & $m.snapshotEvery)
    echo "PLAT-52 scrub: ", order.len, " reconstructions, worst ",
         formatFloat(worstMs, ffDecimal, 3), " ms, worst replay ",
         worstReplay, " writes"
    ck worstReplay <= m.snapshotEvery
    ck worstMs < FrameBudgetMs

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
