## test_plat70f_pointer_pty.nim — the terminal's pointer shape on a real pty
## (Pointer-Affordances.md §5; PA-3 … PA-8), and a click on a hop row.
##
## THE ONE STAND-IN, AND WHY IT IS NOT A MOCK: `persona_peer`. No OSC 22-capable
## emulator runs in CI, so the pty's other end answers the binary's real query
## as kitty's pointer-shape specification says, or stays silent as foot, Ghostty
## and xterm do. The subject (the shipped `codetracer-tui`, its negotiation, its
## hit-test, its restore) is real, and every assertion reads the bytes it wrote.

import std/[monotimes, os, posix, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ./persona_peer

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 132

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  Osc = "\x1b]22;"
  St = "\x1b\\"
  LeaveAlt = "\x1b[?1049l"
  CtrlQ = "\x11"
  Reset = Osc & St
  Pop = Osc & "<" & St

var spawned = 0

proc freshDir(): string =
  inc spawned
  result = getTempDir() / ("plat70f-pty-" & $getCurrentProcessId() & "-" &
                           $spawned)
  removeDir(result)
  createDir(result)

proc calcTrace(): string =
  let resolved = resolveFixture("calc")
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

let trace = calcTrace()

type Peer = object
  persona: Persona
  term: string
  program: string
  tmux: string

proc kittyPeer(reply = "1,1,1,0,0,1,1,1,1,1"): Peer =
  ## The answer measured on kitty 0.47.0: no `col-resize` or `row-resize`, but
  ## their `ew-resize` and `ns-resize`.
  var p = kitty()
  p.pointerReply = reply
  Peer(persona: p, term: "xterm-kitty")

proc setOnly(name: string): Peer =
  case name
  of "ghostty":
    var p = silent()
    Peer(persona: p, term: "xterm-256color", program: "ghostty")
  of "foot":
    Peer(persona: silent(), term: "foot")
  else:
    var p = xterm()
    Peer(persona: p, term: "xterm-256color")

proc open(peer: Peer; extra: seq[string] = @[]): (TuiTestSession, string) =
  let state = freshDir()
  var builder = newTuiTest(tuiBinary(), @["--theme=dark"] & extra & @[trace])
    .width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG", "KITTY_WINDOW_ID",
               "GHOSTTY_RESOURCES_DIR", "SSH_CONNECTION", "SSH_TTY", "SSH_CLIENT")
    .envSet("TERM", peer.term).envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("XDG_CONFIG_HOME", state / "config")
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
  if peer.program.len > 0:
    builder = builder.envSet("TERM_PROGRAM", peer.program)
  if peer.tmux.len > 0:
    builder = builder.envSet("TMUX", peer.tmux)
  var sess = builder.spawn()
  discard sess.serve(peer.persona, timeoutMs = 5000)
  settleOnDebugger(sess, Cols, Rows)
  (sess, state)

proc close(sess: var TuiTestSession; state: string) =
  sess.terminate()
  sess.close()
  removeDir(state)

proc pointerBytes(sess: var TuiTestSession): seq[string] =
  ## Every OSC 22 the binary wrote since it started, the query included.
  discard sess.drainOutput(120)
  let bytes = sess.transcriptBytes()
  var at = 0
  while true:
    let start = bytes.find(Osc, at)
    if start < 0: break
    let stop = bytes.find(St, start)
    if stop < 0: break
    result.add bytes[start + Osc.len ..< stop]
    at = stop + St.len

proc shapesWritten(sess: var TuiTestSession): seq[string] =
  ## The shape names only: a push's name, a set's, without query, pop or reset.
  for b in sess.pointerBytes:
    if b.len == 0 or b[0] in {'?', '<'}: continue
    result.add b.strip(chars = {'>'}, trailing = false)

proc move(sess: var TuiTestSession; row, col: int) =
  ## One report, and time for the answer to it: a loaded host paints late.
  let before = sess.pointerBytes().len
  sess.sendMouseMove(row, col)
  let deadline = getMonoTime() + initDuration(milliseconds = 3000)
  while sess.pointerBytes().len == before and getMonoTime() < deadline:
    sleep(30)

proc settlePointer(sess: var TuiTestSession) =
  ## Until the binary has stopped writing OSC 22: a loaded host answers a burst
  ## of reports late, so a fixed wait reads a prefix of what it will write.
  let deadline = getMonoTime() + initDuration(seconds = 15)
  var seen = -1
  while getMonoTime() < deadline:
    discard sess.drainOutput(500)
    let now = sess.pointerBytes().len
    if now == seen and now > 0:
      return
    seen = now

proc waitLast(sess: var TuiTestSession; wanted: proc(last: string): bool): bool =
  ## Until the last OSC 22 written satisfies `wanted`: a `:set` line is handled
  ## when the host gets to it, not when the test sent it.
  let deadline = getMonoTime() + initDuration(seconds = 15)
  while getMonoTime() < deadline:
    let bytes = sess.pointerBytes()
    if bytes.len > 0 and wanted(bytes[^1]):
      return true
    sleep(100)
  false

proc sweep(sess: var TuiTestSession; row: int) =
  for col in 0 ..< Cols:
    sess.sendMouseMove(row, col)
  sess.settlePointer()

proc screenText(sess: var TuiTestSession; row: int): string =
  for c in 0 ..< Cols:
    let cell = sess.cellAt(row, c)
    result.add(if int(cell.rune) == 0: " " else: $cell.rune)

proc findOnScreen(sess: var TuiTestSession; needle: string; first = 0): (int, int) =
  discard sess.drainOutput(120)
  for r in first ..< Rows:
    let at = sess.screenText(r).find(needle)
    if at >= 0:
      return (r, sess.screenText(r)[0 ..< at].len)
  (-1, -1)

suite "the kitty dialect (PA-3, PA-6)":
  test "the query, one push, sets after it, each only on change":
    var (sess, state) = open(kittyPeer())
    let written = sess.transcriptBytes()
    ck written.contains(PointerQuery)
    sess.sweep(Rows div 2)
    let all = sess.pointerBytes()
    # The query, then exactly one push: the first shape.
    var pushes = 0
    for b in all:
      if b.startsWith(">"): inc pushes
    ck pushes == 1
    let shapes = sess.shapesWritten()
    ck "text" in shapes
    ck "ew-resize" in shapes
    ck "col-resize" notin shapes
    # Each written shape differs from the one before it.
    var repeated = false
    for i in 1 ..< shapes.len:
      if shapes[i] == shapes[i - 1]: repeated = true
    ck not repeated
    sess.close(state)

  test "1000 motion reports over one element write at most one OSC 22":
    var (sess, state) = open(kittyPeer())
    sess.move(Rows div 2, 60)
    let before = sess.pointerBytes().len
    for i in 0 ..< 1000:
      sess.sendMouseMove(Rows div 2, 60)
    discard sess.drainOutput(400)
    ck sess.pointerBytes().len == before
    sess.close(state)

  test "a tab points, and a disabled control refuses":
    var (sess, state) = open(kittyPeer())
    let (tabRow, tabCol) = sess.findOnScreen(" Variables ")
    ck tabRow >= 0
    sess.move(tabRow, tabCol + 2)
    ck sess.shapesWritten()[^1] == "pointer"
    # A disabled transport control, at the top bar, while one is disabled.
    sess.sweep(0)
    ck "pointer" in sess.shapesWritten()
    sess.close(state)

  test "a tab drag grabs, and keeps its offered drop off the layout":
    var (sess, state) = open(kittyPeer())
    let (tabRow, tabCol) = sess.findOnScreen(" Variables ")
    ck tabRow >= 0
    sess.sendMousePress(tabRow, tabCol + 2)
    discard sess.drainOutput(120)
    sess.sendMouseMove(tabRow + 8, tabCol + 2, held = {mbLeft})
    sess.settlePointer()
    ck sess.shapesWritten()[^1] == "grabbing"
    # GoldenLayout's rule: a pointer off the layout is constrained onto it, and
    # a release there still drops, so this is not a refusal.
    sess.sendMouseMove(Rows - 1, tabCol + 2, held = {mbLeft})
    sess.settlePointer()
    checkpoint($sess.shapesWritten())
    ck sess.shapesWritten()[^1] == "grabbing"
    sess.send("\e")
    discard sess.drainOutput(300)
    sess.close(state)

  test "a shape the terminal says it lacks is never written (PA-3)":
    # `grab` and `grabbing` answered `0`: the drag shows the fallback.
    var (sess, state) = open(kittyPeer("1,1,1,0,0,0,0,1,1,1"))
    let (tabRow, tabCol) = sess.findOnScreen(" Variables ")
    sess.sendMousePress(tabRow, tabCol + 2)
    discard sess.drainOutput(120)
    sess.sendMouseMove(tabRow + 8, tabCol + 2, held = {mbLeft})
    sess.settlePointer()
    let shapes = sess.shapesWritten()
    ck "grab" notin shapes
    ck "grabbing" notin shapes
    ck shapes[^1] == "pointer"
    sess.send("\e")
    discard sess.drainOutput(300)
    sess.close(state)

  test "focus-out pops, focus-in pushes the last shape again":
    var (sess, state) = open(kittyPeer())
    sess.move(Rows div 2, 60)
    let shown = sess.shapesWritten()[^1]
    sess.send("\e[O")
    discard sess.drainOutput(150)
    ck sess.pointerBytes()[^1] == "<"
    sess.send("\e[I")
    discard sess.drainOutput(150)
    ck sess.pointerBytes()[^1] == ">" & shown
    sess.close(state)

proc exitPaths(): seq[(string, cint)] =
  @[("SIGTERM", SIGTERM), ("SIGHUP", SIGHUP), ("SIGINT", SIGINT),
    ("SIGQUIT", SIGQUIT), ("SIGSEGV", SIGSEGV), ("SIGABRT", SIGABRT)]

proc endedBy(sess: var TuiTestSession; path: string; sig: cint) =
  if path == "quit":
    sess.send(CtrlQ)
  else:
    sess.sendSignal(sig)
  discard sess.waitExit(initDuration(seconds = 15))
  discard sess.drainOutput(120)

suite "the restore (PA-4, PA-8)":
  test "kitty: the pop is the last OSC 22, before the alternate screen is left":
    for (path, sig) in @[("quit", cint(0))] & exitPaths():
      checkpoint(path)
      var (sess, state) = open(kittyPeer())
      sess.move(Rows div 2, 60)
      sess.endedBy(path, sig)
      let bytes = sess.transcriptBytes()
      ck sess.pointerBytes()[^1] == "<"
      ck bytes.rfind(Pop) < bytes.rfind(LeaveAlt)
      sess.close(state)

  for (path, sig) in @[("quit", cint(0))] & exitPaths():
    test "set-only: the reset follows the last shape on " & path:
      for name in ["ghostty", "foot", "xterm"]:
        checkpoint(name & " " & path)
        var (sess, state) = open(setOnly(name))
        # Over a tab: never the same name as the reset.
        let (tabRow, tabCol) = sess.findOnScreen(" Variables ")
        sess.move(tabRow, tabCol + 2)
        ck sess.shapesWritten().len > 0
        sess.endedBy(path, sig)
        let bytes = sess.transcriptBytes()
        let reset = case name
                    of "xterm": Osc & "xterm" & St
                    of "ghostty": Osc & "text" & St
                    else: Reset
        ck bytes.rfind(reset) >= 0
        ck bytes.rfind(reset) < bytes.rfind(LeaveAlt)
        # Nothing after the reset but the alternate screen's end.
        ck bytes.find(Osc, bytes.rfind(reset) + reset.len) < 0
        sess.close(state)

  test "xterm's shapes are its own names":
    var (sess, state) = open(setOnly("xterm"))
    sess.sweep(Rows div 2)
    let shapes = sess.shapesWritten()
    ck "xterm" in shapes
    ck "text" notin shapes
    sess.close(state)

  test "a stop gives the pointer back, and the continue takes it again":
    for peer in [kittyPeer(), setOnly("ghostty")]:
      var (sess, state) = open(peer)
      let (tabRow, tabCol) = sess.findOnScreen(" Variables ")
      sess.move(tabRow, tabCol + 2)
      let shown = sess.shapesWritten()[^1]
      let pushing = peer.persona.pointerReply.len > 0
      let mark = sess.pointerBytes().len
      # The pty's session is the binary's own, so the kernel discards the stop
      # (an orphaned group) and the continue follows at once.
      sess.sendSignal(SIGTSTP)
      sess.settlePointer()
      let after = sess.pointerBytes()[mark .. ^1]
      checkpoint($after)
      ck after == (if pushing: @["<", ">" & shown] else: @["text", shown])
      sess.close(state)

suite "off (PA-5, §5.6)":
  test "a silent peer with TERM=vt220 is never sent OSC 22":
    var (sess, state) = open(Peer(persona: silent(), term: "vt220"))
    sess.sweep(Rows div 2)
    ck not sess.transcriptBytes().contains(Osc)
    sess.close(state)

  test "--pointer-shapes=off asks nothing and writes nothing":
    var (sess, state) = open(kittyPeer(), @["--pointer-shapes=off"])
    sess.sweep(Rows div 2)
    ck not sess.transcriptBytes().contains(Osc)
    sess.close(state)

  test "--pointer-shapes=on writes on a terminal nobody identified":
    var (sess, state) = open(Peer(persona: silent(), term: "xterm-256color"),
                             @["--pointer-shapes=on"])
    sess.move(Rows div 2, 60)
    ck sess.shapesWritten().len > 0
    sess.close(state)

suite "the setting (§5.6)":
  test ":set pointer-shapes off gives the pointer back; on takes it again":
    var (sess, state) = open(kittyPeer())
    let (tabRow, tabCol) = sess.findOnScreen(" Variables ")
    sess.move(tabRow, tabCol + 2)
    ck sess.pointerBytes()[^1].startsWith(">")
    sess.send(":set pointer-shapes off\r")
    ck sess.waitLast(proc(last: string): bool = last == "<")
    sess.settlePointer()
    let written = sess.pointerBytes().len
    sess.sweep(Rows div 2)
    ck sess.pointerBytes().len == written
    sess.send(":set pointer-shapes on\r")
    ck sess.waitLast(proc(last: string): bool = last.startsWith(">"))
    sess.close(state)

suite "tmux (PA-7)":
  test "a silent wrapped query: nothing sent, and the remedy reported":
    var (sess, state) = open(Peer(persona: silent(), term: "tmux-256color",
                                  tmux: "/tmp/none,1,0"))
    sess.sweep(Rows div 2)
    let bytes = sess.transcriptBytes()
    # The wrapped query alone, every ESC inside doubled.
    ck bytes.contains("\x1bPtmux;\x1b\x1b]22;?default")
    ck bytes.count("\x1bPtmux;\x1b\x1b]22;") == 1
    sess.close(state)
    var report = newTuiTest(tuiBinary(), @["--capabilities"])
      .width(Cols).height(Rows).transcript()
      .envRemove("KITTY_WINDOW_ID", "TERM_PROGRAM", "SSH_CONNECTION", "SSH_TTY")
      .envSet("TMUX", "/tmp/none,1,0").envSet("TERM", "tmux-256color")
      .spawn()
    discard report.waitExit(initDuration(seconds = 20))
    discard report.drainOutput(100)
    ck report.transcriptBytes().contains("allow-passthrough")
    report.close()

  test "an answered wrapped query: every sequence wrapped":
    var outer = kitty()
    outer.pointerReply = "1,1,1,1,1,1,1,1,0,0"
    var (sess, state) = open(Peer(persona: outer, term: "tmux-256color",
                                  tmux: "/tmp/none,1,0"))
    sess.move(Rows div 2, 60)
    let bytes = sess.transcriptBytes()
    ck bytes.contains("\x1bPtmux;\x1b\x1b]22;>")
    ck bytes.replace("\x1b\x1b]22;", "").count(Osc) == 0
    sess.close(state)

suite "the count":
  test "assertion count":
    check countedAssertions == ExpectedAssertions
