## test_plat61_shell.nim — the Shell pane's shared model, which the desktop,
## the terminal and the GPUI window all draw from.
##
## LANE: `vm-unit`, `vm-unit-js` and `vm-unit-wasm`, by the directory glob.
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7.
##
## Asserted:
##
##   * THE LIVE EMULATOR (§7.3): a line feed only a line feed (the pty applied
##     ONLCR), lines that scroll off the top KEPT and COUNTED, `ED 3` dropping
##     the kept lines, a resize keeping the cursor on screen, DECCKM tracked —
##     and the recorded program's screen (PLAT-52) unchanged by all of it;
##   * THE ACTIONS (§7.4): a working event opens an action at the cursor's
##     line, its range follows the cursor while it runs, the settled event
##     ends it at the last line written; a settled event with no working one
##     before it; the words, glyphs and tones every front-end prints;
##   * THE ROWS: the lines a view shows, following the tail, scrolled back,
##     the marks on an action's first and later lines, the cursor;
##   * THE PRESS (§7.6): a settled recording opens through the front-end's
##     hook and is remembered; a running one, a failed one, a compile say why
##     not; a front-end without the hook says so;
##   * THE KEYS (§7.5): the bytes xterm sends for named keys, modifiers and
##     control characters, DECCKM's cursor keys, the prefix's three routes;
##   * THE SESSION: start, input, resize and exit through the host, a host
##     that cannot run a shell, and the session wire both ways.
##
## THE ONE STAND-IN, and why it is not a mock: the `ShellHost` here is four
## closures that record what the model asked of its process side. The unit
## under test is the MODEL — what it asks and when; whether a real shell on a
## real pty answers is the `tui`, `tui-real-terminal` and `gpui-shell` lanes'
## (`test_plat61_shell*.nim`), which run bash and a real `ct record` through
## `common/shell_session.nim`. The output bytes and the events fed in here are
## the model's INPUT — what a pty and `ct record`'s report line carry — not a
## stand-in for anything.

import std/[json, strutils, unittest]

import isonim/core/[owner, signals]

import ../../store/types
import ../../viewmodels/shell_vm
import ../../viewmodels/terminal_output_model

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

proc recordEvent(action: int; status: string; command = "python3 prog.py";
                 recordingId = ""; folder = ""; error = ""): JsonNode =
  ## A `RecordingCommand` line as `trace_index.sessionEventJson` writes it.
  result = %*{"kind": "RecordingCommand", "status": status,
              "actionId": action, "command": command,
              "errorMessage": error, "sessionId": 7, "firstLine": -1,
              "lastLine": -1}
  if recordingId.len > 0 or folder.len > 0:
    result["trace"] = %*{"recordingId": recordingId, "outputFolder": folder,
                         "program": "prog.py"}

type HostLog = ref object
  started: seq[(int, int)]
  input: string
  resized: seq[(int, int)]
  stopped: int
  opened: seq[string]

proc hostFor(log: HostLog; refuse = ""): ShellHost =
  result.start = proc(cols, rows: int): string =
    log.started.add((cols, rows))
    refuse
  result.input = proc(data: string) = log.input.add data
  result.resize = proc(cols, rows: int) = log.resized.add((cols, rows))
  result.stop = proc() = inc log.stopped

proc startedVM(log: HostLog; cols = 40; rows = 5): ShellVM =
  result = createShellVM()
  result.host = hostFor(log)
  result.openRecording = proc(a: ShellAction): string =
    log.opened.add a.traceFolder
    ""
  result.startShell(cols, rows)

suite "PLAT-61 the live emulator":
  test "a line feed is only a line feed; the recorded screen keeps ONLCR":
    var live = newShellScreen(20, 4)
    live.feed("ab\ncd")
    ck live.screenRowText(1).strip == "cd"
    ck live.cellAt(1, 2).ch == int32('c')      # column kept: no ONLCR
    var recorded = newTermScreen(20, 4)
    recorded.feed("ab\ncd")
    ck recorded.cellAt(1, 0).ch == int32('c')  # PLAT-52: LF as CR LF
    ck recorded.scrollbackLimit == 0 and recorded.onlcr

  test "lines that leave the top are kept and counted":
    var s = newShellScreen(10, 3)
    for i in 1 .. 7:
      s.feed("line" & $i & "\r\n")
    # 7 lines and the cursor's fresh one: 8 rows of output on a 3-row screen.
    ck s.scrolledOff == 5
    ck s.keptLines == 5
    ck cellsText(s.keptLine(0)).strip == "line1"
    ck s.screenRowText(0).strip == "line6"
    var recorded = newTermScreen(10, 3)
    for i in 1 .. 7:
      recorded.feed("line" & $i & "\n")
    ck recorded.keptLines == 0                 # PLAT-52 keeps none
    ck recorded.scrolledOff == 5               # but counts

  test "the scrollback is bounded and ED 3 drops it":
    var s = newShellScreen(10, 2)
    s.scrollbackLimit = 3
    for i in 1 .. 10:
      s.feed($i & "\r\n")
    ck s.keptLines == 3
    ck cellsText(s.keptLine(0)).strip == "7"
    ck s.scrolledOff == 9
    s.feed("\e[H\e[2J\e[3J")
    ck s.keptLines == 0
    ck s.scrolledOff == 9                      # absolute lines do not move

  test "a resize keeps the cursor on screen; DECCKM is tracked":
    var s = newShellScreen(10, 6)
    for i in 1 .. 5:
      s.feed("r" & $i & "\r\n")
    ck s.row == 5
    s.resize(6, 3)
    ck s.rows == 3 and s.cols == 6
    ck s.row == 2
    ck s.screenRowText(0).strip == "r4"
    ck s.scrolledOff == 3
    ck cellsText(s.keptLine(s.keptLines - 1)).strip == "r3"
    s.resize(12, 5)
    ck s.row == 2 and s.screenRowText(1).strip == "r5"
    ck not s.appCursor
    s.feed("\e[?1h")
    ck s.appCursor
    s.feed("\e[?1l")
    ck not s.appCursor

suite "PLAT-61 the actions":
  test "a working event opens an action at the cursor; it follows the cursor; the settled one ends it":
    createRoot proc(dispose: proc()) =
      let log = HostLog()
      let vm = startedVM(log, 40, 4)
      vm.receiveOutput("$ ./build.sh\r\n")
      ck vm.cursorLine == 1
      vm.receiveEvent(recordEvent(4242, "WorkingStatus"))
      ck vm.actions.len == 1
      ck vm.actions[0].firstLine == 1
      ck vm.actions[0].status == sasWorking
      vm.receiveOutput("hello\r\nworld\r\n")
      ck vm.actionRange(vm.actions[0]) == (1, 3)   # follows the cursor
      ck vm.actionAtLine(3) == 0
      vm.receiveEvent(recordEvent(4242, "OkStatus",
                                  recordingId = "0191abcd-1234-7000-8000-000000000001",
                                  folder = "/tmp/rec-1"))
      ck vm.actions.len == 1
      ck vm.actions[0].status == sasOk
      ck vm.actions[0].lastLine == 2                # cursor at a fresh line
      ck vm.actions[0].traceFolder == "/tmp/rec-1"
      ck vm.actionAtLine(3) == -1
      ck vm.actionAtLine(0) == -1
      ck vm.actions[0].actionSummary ==
        "recorded command: python3 prog.py — recording 0191abcd"
      ck vm.actions[0].actionGlyph == "●"
      ck vm.actions[0].actionGlyph(ascii = true) == "*"
      ck vm.actions[0].toneOf == stOk
      ck vm.statusWords == "running — 1 recording"
      dispose()

  test "a settled event with no working one; a failure; the other kinds' words":
    createRoot proc(dispose: proc()) =
      let vm = startedVM(HostLog(), 40, 4)
      vm.receiveOutput("$ ct record nope.py\r\nerror: no such file\r\n")
      vm.receiveEvent(recordEvent(9, "ErrorStatus", command = "nope.py",
                                  error = "no such file"))
      let a = vm.actions[0]
      ck a.firstLine == 1 and a.lastLine == 1
      ck a.status == sasError
      ck a.actionSummary == "error recording command: nope.py error: no such file"
      ck a.actionGlyph == "✕" and a.actionGlyph(true) == "x"
      ck a.toneOf == stError
      var c = actionFromEvent(%*{"kind": "CustomCompilerFlagCommand",
                                  "status": "OkStatus", "actionId": 1,
                                  "program": "gcc"})
      ck c.kind == sakCompile
      ck c.actionSummary == "custom compiling flags: gcc"
      var l = actionFromEvent(%*{"kind": 1, "status": 0, "actionId": 2,
                                  "binary": "a.out"})
      ck l.kind == sakLink and l.status == sasWorking
      ck l.actionSummary == "linking binary: a.out"
      ck l.actionGlyph == "◌" and l.toneOf == stWorking
      ck actionBar() == "│" and actionBar(true) == "|"
      dispose()

suite "PLAT-61 the marks":
  test "an action's lines are where `ct record` marked the output":
    createRoot proc(dispose: proc()) =
      let vm = startedVM(HostLog(), 40, 8)
      # The events arrive LATE — after everything the command and the shell
      # wrote, the next prompt included; the marks in the output say where.
      vm.receiveOutput("$ ./build.sh\r\nbuilding\r\n" &
                       "\e]6973;action=7;status=working\a" &
                       "out1\r\nout2\r\n" &
                       "\e]6973;action=7;status=ok\x1b\\" &
                       "recordingId:r7\r\n$ ")
      ck vm.marks.len == 2
      vm.receiveEvent(recordEvent(7, "WorkingStatus"))
      vm.receiveEvent(recordEvent(7, "OkStatus", recordingId = "r7",
                                  folder = "/tmp/r7"))
      ck vm.marks.len == 0
      let a = vm.actions[0]
      ck a.firstLine == 2 and vm.lineText(a.firstLine) == "out1"
      ck a.lastLine == 3 and vm.lineText(a.lastLine) == "out2"
      ck vm.actionAtLine(4) == -1              # the id ct printed after
      ck vm.lineText(4) == "recordingId:r7"     # the OSC drew nothing
      var m: ShellActionMark
      ck not parseActionMark("0;title", 0, 0, m)
      ck not parseActionMark("6973;action=x;status=ok", 0, 0, m)
      ck parseActionMark("6973;status=error;action=3", 5, 1, m)
      ck m.actionId == 3 and m.status == sasError and m.line == 5
      dispose()

suite "PLAT-61 the rows":
  test "a view follows the tail, scrolls back, marks the actions":
    createRoot proc(dispose: proc()) =
      let log = HostLog()
      let vm = startedVM(log, 30, 3)
      vm.receiveOutput("$ ./build.sh\r\n")
      vm.receiveEvent(recordEvent(1, "WorkingStatus"))
      vm.receiveOutput("\e[32mok\e[0m one\r\ntwo\r\n")
      vm.receiveEvent(recordEvent(1, "OkStatus", recordingId = "r1",
                                  folder = "/tmp/r1"))
      vm.receiveOutput("$ ")
      ck vm.lineCount == 4
      let rows = vm.shellRows(3)
      ck rows.len == 3
      ck rows[0].text == "ok one" and rows[0].line == 1
      ck rows[0].mark == srmStart and rows[0].tone == stOk
      ck rows[1].mark == srmRange
      ck rows[2].text == "$" and rows[2].mark == srmNone
      ck rows[2].cursorCol == 2
      ck rows[0].runs[0].text == "ok"
      ck rows[0].runs[0].attrs.fg.kind != tckDefault
      vm.scrollShell(-1, 3)
      ck vm.visibleTop(3) == 0
      ck vm.shellRows(3)[0].text == "$ ./build.sh"
      vm.sendInput("x")
      ck log.input == "x"
      ck vm.scrollTop.val == -1                  # typing returns to the tail
      ck vm.visibleTop(3) == 1
      vm.scrollShellTo(0, 3)
      ck vm.visibleTop(3) == 0
      vm.scrollShell(5, 3)
      ck vm.scrollTop.val == -1
      dispose()

suite "PLAT-61 the press":
  test "a settled recording opens; the others say why not":
    createRoot proc(dispose: proc()) =
      let log = HostLog()
      let vm = startedVM(log, 30, 6)
      vm.receiveOutput("$ a\r\n")
      vm.receiveEvent(recordEvent(1, "WorkingStatus"))
      ck vm.activateLine(1) == "still recording"
      vm.receiveOutput("out\r\n")
      vm.receiveEvent(recordEvent(1, "OkStatus",
                                  recordingId = "0191abcd-0000-7000-8000-00000000000a",
                                  folder = "/tmp/ra"))
      vm.receiveOutput("$ b\r\nboom\r\n")
      vm.receiveEvent(recordEvent(2, "ErrorStatus", error = "boom"))
      ck vm.activateLine(1) == "opened recording 0191abcd"
      ck log.opened == @["/tmp/ra"]
      ck vm.opened == @["/tmp/ra"]
      ck vm.note.val == "opened recording 0191abcd"
      ck vm.activateLine(3) == "the recording failed: boom"
      ck vm.activateLine(0) == ""                 # no action on the line
      ck log.opened.len == 1
      vm.openRecording = nil
      ck vm.activateLine(1) == "this front-end cannot open a recording"
      vm.openRecording = proc(a: ShellAction): string = "the folder is gone"
      ck vm.activateLine(1) == "the folder is gone"
      ck vm.opened.len == 1
      dispose()

suite "PLAT-61 the keys":
  test "what each key sends":
    ck keyBytes(ShellKey(key: "Enter")) == "\r"
    ck keyBytes(ShellKey(key: "Backspace")) == "\x7f"
    ck keyBytes(ShellKey(key: "Tab")) == "\t"
    ck keyBytes(ShellKey(key: "Tab", shift: true)) == "\e[Z"
    ck keyBytes(ShellKey(key: "Up")) == "\e[A"
    ck keyBytes(ShellKey(key: "Up"), appCursor = true) == "\eOA"
    ck keyBytes(ShellKey(key: "Left", ctrl: true)) == "\e[1;5D"
    ck keyBytes(ShellKey(key: "Delete")) == "\e[3~"
    ck keyBytes(ShellKey(key: "PageUp", shift: true)) == "\e[5;2~"
    ck keyBytes(ShellKey(key: "F1")) == "\eOP"
    ck keyBytes(ShellKey(key: "F5")) == "\e[15~"
    ck keyBytes(ShellKey(key: "c", text: "c", ctrl: true)) == "\x03"
    ck keyBytes(ShellKey(key: "D", text: "D", ctrl: true)) == "\x04"
    ck keyBytes(ShellKey(key: "b", text: "b", alt: true)) == "\eb"
    ck keyBytes(ShellKey(key: "é", text: "é")) == "é"
    ck keyBytes(ShellKey(key: "Space", ctrl: true)) == "\x00"
    # The canonical names the terminal's and GPUI's decoders produce.
    ck shellKeyOfChord("Ctrl+c") == ShellKey(key: "c", text: "c", ctrl: true)
    ck keyBytes(shellKeyOfChord("Ctrl+c")) == "\x03"
    ck keyBytes(shellKeyOfChord("Shift+Tab")) == "\e[Z"
    ck keyBytes(shellKeyOfChord("Ctrl+Shift+Up")) == "\e[1;6A"
    ck keyBytes(shellKeyOfChord("Alt+f")) == "\ef"
    ck keyBytes(shellKeyOfChord("A")) == "A"
    ck keyBytes(shellKeyOfChord("+")) == "+"
    ck keyBytes(shellKeyOfChord("Ctrl++")) == "+"
    ck shellKeyOfChord("Ctrl+]").isPrefix

  test "the prefix: armed, then the next key is CodeTracer's; twice sends it":
    createRoot proc(dispose: proc()) =
      let log = HostLog()
      let vm = startedVM(log)
      let prefix = ShellKey(key: "]", text: "]", ctrl: true)
      ck vm.pressKey(ShellKey(key: "l", text: "l")).kind == skrShell
      ck log.input == "l"
      ck vm.pressKey(prefix).kind == skrConsumed
      ck vm.prefixArmed
      ck ShellPrefixChord in vm.note.val
      ck vm.pressKey(ShellKey(key: "Tab")).kind == skrApp
      ck log.input == "l"                          # nothing reached the shell
      ck not vm.prefixArmed
      discard vm.pressKey(prefix)
      let twice = vm.pressKey(prefix)
      ck twice.kind == skrShell and twice.bytes == ShellPrefixByte
      ck log.input == "l" & ShellPrefixByte
      vm.receiveOutput("\e[?1h")
      ck vm.pressKey(ShellKey(key: "Up")).bytes == "\eOA"
      dispose()

suite "PLAT-61 the session":
  test "start, resize, stop and exit through the host; the wire":
    createRoot proc(dispose: proc()) =
      let log = HostLog()
      let vm = startedVM(log, 33, 7)
      ck log.started == @[(33, 7)]
      ck vm.state.val == sssRunning
      ck vm.screen.cols == 33 and vm.screen.rows == 7
      vm.startShell(33, 7)                         # once
      ck log.started.len == 1
      vm.resizeShell(50, 9)
      ck log.resized == @[(50, 9)]
      vm.resizeShell(50, 9)
      ck log.resized.len == 1
      vm.receiveUpdate(outputMessage("hi\r\n"))
      ck vm.lineText(0) == "hi"
      vm.receiveUpdate(eventMessage(recordEvent(3, "WorkingStatus")))
      ck vm.actions.len == 1 and vm.actions[0].firstLine == 1
      vm.stopShell()
      ck log.stopped == 1
      vm.receiveUpdate(exitMessage(0))
      ck vm.state.val == sssExited
      ck vm.statusWords == "exited (0)"
      ck vm.shellRows(7)[^1].cursorCol == -1      # no cursor once exited
      vm.sendInput("ignored")
      ck "ignored" notin log.input
      dispose()

  test "a host that cannot run a shell; a refused start; a failure on the wire":
    createRoot proc(dispose: proc()) =
      let none = createShellVM()
      none.startShell(10, 3)
      ck none.state.val == sssFailed
      ck none.statusWords == "could not start: this front-end cannot run a shell"
      let refused = createShellVM()
      refused.host = hostFor(HostLog(), refuse = "no pty here")
      refused.startShell(10, 3)
      ck refused.state.val == sssFailed and refused.failure == "no pty here"
      let wire = createShellVM()
      wire.receiveUpdate(failedMessage("could not start the shell: x"))
      ck wire.state.val == sssFailed
      ck wire.note.val == "could not start the shell: x"
      dispose()

  test "every assertion ran":
    check asserted >= 100
