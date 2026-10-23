## test_plat70h_scrollbars_pty.nim — PLAT-70 Part H (Scrollbar-Scrubbers.md
## §7), the shipped `codetracer-tui` on a REAL pseudo-terminal (TermAssert: a
## real pty, the screen read back through libvterm, the child's byte stream
## kept as a transcript), over a real recording of `test-programs/calc`
## against the real `replay-server`. The editor's vertical bar, with the
## default options (a hairline thumb, no track, fading on):
##
##   * at rest the thumb is `▕` in `ui/text/primary/caption-subtle` on the
##     editor's own ground; the pointer on the thumb widens it to `▐` in the
##     caption tone; on the track it reveals `▕` in `ui/border/primary`
##     (SB-5, SB-2);
##   * grabbed by its last cell and moved four rows, its first cell moved four
##     rows (SB-3);
##   * a MIDDLE press on the track pages toward the pointer, and held it keeps
##     paging until the thumb reaches the pointer (SB-4);
##   * EXACT BYTES (SB-6): left alone the bar fades out and a wheel brings it
##     back, and between "absent" and "drawn" the transcript paints the thumb
##     cell in at least one INTERMEDIATE colour in each direction; under
##     `--scrollbar-fade=off` it never does;
##   * `:set scrollbar-thickness thick` re-draws the thumb as `▐` at rest and
##     is remembered in `tui-preferences` (SB-7).
##
## No mocks: the binary, the engine and the recording are real. State in a
## scratch directory.

import std/[monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import codetracer_embed

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 18

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 160
  Rows = 48
  Ground = "#282828"       ## the editor's ground, Dark
  RestInk = "#727272"      ## ui/text/primary/caption-subtle
  HoverInk = "#b4b4b4"     ## ui/text/primary/caption
  RevealedInk = "#565656"  ## ui/border/primary
  MiddleButton = 1

var spawned = 0
var lastState = ""

proc trace(): string =
  let resolved = resolveFixture(FixtureSpec(
    name: "calc", program: "test-programs/calc/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

proc open(extra: seq[string] = @[]): TuiTestSession =
  inc spawned
  lastState = getTempDir() / ("plat70h-pty-" & $getCurrentProcessId() & "-" &
                              $spawned)
  removeDir(lastState)
  createDir(lastState)
  result = newTuiTest(tuiBinary(), @["--theme=dark"] & extra & @[trace()])
    .width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", lastState)
    .envSet("CODETRACER_HOME", lastState / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", lastState / "layout")
    .spawn()
  settleOnDebugger(result, Cols, Rows)

proc quit(sess: var TuiTestSession) =
  sess.send("\x11")  # Ctrl+Q, the CUA base's quit
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

proc glyph(c: Cell): string =
  if int(c.rune) == 0: " " else: $c.rune

proc hexOf(c: Color): string =
  if c.kind != ckRgb: return "(" & $c.kind & ")"
  "#" & toHex(int(c.r), 2).toLowerAscii & toHex(int(c.g), 2).toLowerAscii &
    toHex(int(c.b), 2).toLowerAscii

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  ## One SGR-1006 report — the exact bytes a terminal writes.
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc settle(sess: var TuiTestSession) =
  sleep(60)
  discard sess.drainOutput(30)

proc eventually(sess: var TuiTestSession; what: string;
                cond: proc(sess: var TuiTestSession): bool;
                timeoutMs = 20000): bool =
  ## Polled, not slept for: a loaded host is slower, not red.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    discard sess.drainOutput(10)
    if cond(sess): return true
    sleep(15)
  checkpoint("never: " & what)
  false

type EditorBar = object
  col, top, rows: int

proc editorBar(sess: var TuiTestSession): EditorBar =
  ## The editor's bar: the column just left of the divider (`▏`) that closes
  ## the pane whose tab names the recorded file, from its first body row to
  ## the last row above the status line where that divider runs.
  discard sess.drainOutput(40)
  var strip = ""
  for c in 0 ..< Cols: strip.add sess.cellAt(1, c).glyph
  let at = strip.find("main.py")
  doAssert at >= 0, "no editor tab: " & strip
  var col = strip[0 ..< at].runeLen
  while col < Cols - 1 and sess.cellAt(3, col).glyph != "▏": inc col
  var bottom = 2
  while bottom + 1 < Rows - 1 and sess.cellAt(bottom + 1, col).glyph == "▏":
    inc bottom
  EditorBar(col: col - 1, top: 2, rows: bottom - 1)

proc column(sess: var TuiTestSession; bar: EditorBar): seq[(string, string)] =
  for r in bar.top ..< bar.top + bar.rows:
    let c = sess.cellAt(r, bar.col)
    result.add (c.glyph, c.fg.hexOf)

proc thumbRows(sess: var TuiTestSession; bar: EditorBar;
               glyphs: openArray[string]): seq[int] =
  for i, (g, _) in sess.column(bar):
    if g in glyphs: result.add bar.top + i

proc wake(sess: var TuiTestSession; bar: EditorBar) =
  ## The pointer onto the editor's code, near its bar: the bar is wanted.
  sess.mouse(35, bar.top + 3, bar.col - 2)
  sess.settle()

# ---------------------------------------------------------------------------
# The transcript, read as a terminal reads it: which colour each write of a
# cell of the bar's column was painted in.
# ---------------------------------------------------------------------------

proc barWrites(bytes: string; col: int; glyph: string): seq[string] =
  ## Every `#rrggbb` the stream painted `glyph` in at column `col` (0-based),
  ## following cursor addresses (`CSI r ; c H`), SGR foregrounds and the
  ## column each printed rune advances.
  var fg = ""
  var c = 0
  var i = 0
  while i < bytes.len:
    if bytes[i] == '\x1b' and i + 1 < bytes.len and bytes[i + 1] == '[':
      var j = i + 2
      while j < bytes.len and bytes[j] notin {'@' .. '~'}: inc j
      if j >= bytes.len: break
      let params = bytes[i + 2 ..< j]
      case bytes[j]
      of 'H':
        let p = params.split(';')
        c = (if p.len >= 2 and p[1].len > 0: parseInt(p[1]) - 1 else: 0)
      of 'm':
        let p = params.split(';')
        var k = 0
        while k < p.len:
          case p[k]
          of "", "0", "39": fg = ""
          of "38":
            if k + 4 < p.len and p[k + 1] == "2":
              fg = "#" & toHex(parseInt(p[k + 2]), 2).toLowerAscii &
                   toHex(parseInt(p[k + 3]), 2).toLowerAscii &
                   toHex(parseInt(p[k + 4]), 2).toLowerAscii
              k += 4
            elif k + 2 < p.len and p[k + 1] == "5":
              k += 2
          of "48":
            if k + 1 < p.len and p[k + 1] == "2": k += 4
            elif k + 1 < p.len and p[k + 1] == "5": k += 2
          else: discard
          inc k
      else: discard
      i = j + 1
      continue
    if bytes[i] == '\x1b':
      inc i
      continue
    if bytes[i] in {'\r', '\n'}:
      inc i
      continue
    let r = bytes.runeAt(i)
    let s = $r
    if s == glyph and c == col:
      result.add fg
    inc c
    i += s.len

proc grey(hex: string): int =
  if hex.len != 7: -1 else: parseHexInt(hex[1 .. 2])

proc between(hex: string; lo, hi: string): bool =
  ## A grey strictly between two greys.
  let v = hex.grey
  v > min(lo.grey, hi.grey) and v < max(lo.grey, hi.grey)

suite "PLAT-70 Part H: the editor's scrollbar on a real terminal":

  test "hover widens the thumb and reveals the track; a grab keeps its offset; a held middle press pages to the pointer":
    var sess = open()
    defer: sess.quit()
    let bar = sess.editorBar()
    checkpoint("bar: col " & $bar.col & " rows " & $bar.top & "+" & $bar.rows)
    ck bar.rows > 20
    sess.wake(bar)
    let rest = sess.thumbRows(bar, ["▕"])
    checkpoint("thumb at rest: " & $rest)
    ck rest.len >= 2 and rest[0] == bar.top
    ck sess.cellAt(rest[1], bar.col).fg.hexOf == RestInk
    ck sess.cellAt(rest[1], bar.col).bg.hexOf == Ground
    # On the thumb: widened, the hover colour.
    sess.mouse(35, rest[1], bar.col)
    ck sess.eventually("the thumb widened", proc(s: var TuiTestSession): bool =
      s.cellAt(rest[1], bar.col).glyph == "▐" and
        s.cellAt(rest[1], bar.col).fg.hexOf == HoverInk)
    ck sess.cellAt(rest[1], bar.col).bg.hexOf == Ground
    # On the track: revealed, the thumb back at rest.
    let away = rest[^1] + 4
    sess.mouse(35, away, bar.col)
    ck sess.eventually("the track revealed", proc(s: var TuiTestSession): bool =
      s.cellAt(away, bar.col).glyph == "▕" and
        s.cellAt(away, bar.col).fg.hexOf == RevealedInk)
    ck sess.cellAt(rest[1], bar.col).glyph == "▕"
    # SB-3: grabbed by its last cell, moved four rows.
    sess.mouse(0, rest[^1], bar.col)
    sess.mouse(32, rest[^1] + 2, bar.col)
    sess.mouse(32, rest[^1] + 4, bar.col)
    sess.mouse(0, rest[^1] + 4, bar.col, release = true)
    var held: seq[int] = @[]
    ck sess.eventually("the thumb moved by four", proc(s: var TuiTestSession): bool =
      held = s.thumbRows(bar, ["▐"])
      held.len > 0 and held[0] == rest[0] + 4)
    checkpoint("after the drag: " & $held)
    # SB-4: a held MIDDLE press near the bottom of the track pages toward
    # it until the thumb reaches it.
    let target = bar.top + bar.rows - 3
    sess.mouse(MiddleButton, target, bar.col)
    ck sess.eventually("paged to the pointer", proc(s: var TuiTestSession): bool =
      let t = s.thumbRows(bar, ["▕", "▐"])
      t.len > 0 and t[^1] >= target - 1)
    sess.mouse(MiddleButton, target, bar.col, release = true)

  test "exact bytes: the fade goes out and back in through intermediate frames; never with fade off":
    var sess = open()
    defer: sess.quit()
    let bar = sess.editorBar()
    sess.wake(bar)
    let rest = sess.thumbRows(bar, ["▕"])
    require rest.len >= 2
    let probe = rest[1]
    # The pointer away (the top bar), and the bar left alone: it fades out.
    let before = sess.transcriptBytes().len
    sess.mouse(35, 0, Cols div 2)
    ck sess.eventually("the bar faded out", proc(s: var TuiTestSession): bool =
      s.cellAt(probe, bar.col).glyph == " ", timeoutMs = 10000)
    let outBytes = sess.transcriptBytes()[before .. ^1]
    let outInks = outBytes.barWrites(bar.col, "▕")
    checkpoint("fading out: " & outInks.join(" "))
    var outSteps = 0
    for ink in outInks:
      if ink.between(Ground, RestInk): inc outSteps
    ck outSteps >= 1
    # A wheel over the code: the pane scrolls, the bar fades back in.
    let mark = sess.transcriptBytes().len
    sess.mouse(65, bar.top + 5, bar.col - 10)
    ck sess.eventually("the bar came back", proc(s: var TuiTestSession): bool =
      for i, (g, ink) in s.column(bar):
        if g == "▕" and ink == RestInk: return true
      false, timeoutMs = 10000)
    let inInks = sess.transcriptBytes()[mark .. ^1].barWrites(bar.col, "▕")
    checkpoint("fading in: " & inInks.join(" "))
    var inSteps = 0
    for ink in inInks:
      if ink.between(Ground, RestInk): inc inSteps
    ck inSteps >= 1

    var off = open(@["--scrollbar-fade=off"])
    defer: off.quit()
    let offBar = off.editorBar()
    let start = off.transcriptBytes().len
    off.mouse(35, 0, Cols div 2)
    sleep(FadeAfterMs + FadeOutMs + 600)
    discard off.drainOutput(50)
    var drawn = 0
    for (g, ink) in off.column(offBar):
      if g == "▕" and ink == RestInk: inc drawn
    ck drawn >= 2
    var steps = 0
    for ink in off.transcriptBytes()[start .. ^1].barWrites(offBar.col, "▕"):
      if ink.between(Ground, RestInk): inc steps
    ck steps == 0

  test "`:set scrollbar-thickness thick` draws `▐` at rest and is remembered":
    var sess = open(@["--scrollbar-fade=off"])
    defer: sess.quit()
    let bar = sess.editorBar()
    sess.send(":")
    sleep(100)
    sess.send("set scrollbar-thickness thick\r")
    ck sess.eventually("thick", proc(s: var TuiTestSession): bool =
      s.thumbRows(bar, ["▐"]).len >= 2)
    var prefs = ""
    for f in walkDirRec(lastState):
      if f.endsWith("tui-preferences"): prefs = readFile(f)
    checkpoint("tui-preferences: " & prefs.replace("\n", " | "))
    ck prefs.contains("scrollbar-thickness=thick")

suite "PLAT-70 Part H: assertion count":
  test "every assertion ran":
    check countedAssertions == ExpectedAssertions
