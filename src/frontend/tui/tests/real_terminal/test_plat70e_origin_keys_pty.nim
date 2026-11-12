## Ported in part to the scenario
## src/tests/scenarios/terminal/origin-menu-and-a-hop-press.yaml; kept as the
## subject of its mutation harness (run-plat70e-origin-mutations.py,
## run-plat70f-pointer-mutations.py); and for its cases no scenario ports yet.
##
## test_plat70e_origin_keys_pty.nim — PLAT-70 Part E (Variable-State-Pane.md
## § Value origin from the keyboard; Value-Origin-Tracking.md §13.0): **the
## value origin from the keyboard, on a real terminal.**
##
## The shipped `codetracer-tui` on the `calc` recording, at tick 118
## (where the local `value` has a recorded origin at tick 90, the call
## that returned it), driven with the keyboard only
## and read back off the screen through libvterm, in Debug mode:
##
##   * under CUA: `F6` until the Variables pane has the focus, `Down` until
##     `value` is the selected row (the selection ground read off the
##     cells); `Ctrl+Shift+O` (xterm's `modifyOtherKeys` bytes, which the
##     terminal negotiates on `xterm-256color`) opens its origin chain under
##     the row; `Down` moves onto the first hop (the hop's row on the
##     selection ground, the variable's not); `Escape` closes the chain and
##     the variable is selected again; reopened, `Enter` on the first hop
##     seeks to the tick the hop names (the header's tick read off the
##     screen); `Menu` (`CSI 29 ~`) opens the
##     row's menu and choosing "Show value origin" toggles the chain;
##   * with `keyProtocol` legacy (`TERM=screen-256color`): `Ctrl+K
##     Shift+F10` opens the same menu, where `Shift+F10` alone stays reverse
##     step over;
##   * under Vim: `3` focuses the pane, `j` selects, `g o` opens the chain,
##     `j` moves onto its hop and `Esc` closes it, `o` still walks to the
##     origin and `Shift+O` walks back.
##
## No mocks: the real binary, a real recording of the `calc` program, a real
## `replay-server`, a real pty (TermAssert + libvterm).

import std/[monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../app/theme/colour_math
import ../../app/theme/roles

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 19

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  StatusRow = Rows - 1
  CtrlK = "\x0b"
  CtrlQ = "\x11"
  CtrlShiftO = "\e[27;6;111~"
    ## `Ctrl+Shift+O` under xterm's `modifyOtherKeys` (CSI 27 ; mods ; cp ~).
  Menu = "\e[29~"
    ## The application (context-menu) key, as xterm sends it.
  ShiftF10 = "\e[21;2~"
  F6 = "\e[17~"
  Down = "\e[B"
  Home = "\e[H"
  Esc = "\e"
  Enter = "\r"

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc freshDir(): string =
  inc spawned
  result = getTempDir() / ("plat70e-pty-" & $getCurrentProcessId() & "-" &
                           $spawned)
  removeDir(result)
  createDir(result)

proc calcTrace(): string =
  let resolved = resolveFixture("calc")
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

let trace = calcTrace()

proc open(extra: seq[string] = @[]; term = "xterm-256color"):
    (TuiTestSession, string) =
  let state = freshDir()
  var sess = newTuiTest(tuiBinary(), @["--theme=dark"] & extra & @[trace])
    .width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", term).envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("XDG_CONFIG_HOME", state / "config")
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
    .spawn()
  settleOnDebugger(sess, Cols, Rows)
  (sess, state)

proc snap(sess: var TuiTestSession): Snapshot =
  discard sess.drainOutput(80)
  for r in 0 ..< Rows:
    var row: seq[Cell] = @[]
    for c in 0 ..< Cols:
      row.add sess.cellAt(r, c)
    result.add row

proc text(s: Snapshot; r: int): string =
  for c in s[r]:
    result.add(if int(c.rune) == 0: " " else: $c.rune)

proc cellFind(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc findRow(s: Snapshot; needle: string; first = 0): (int, int) =
  for r in first ..< Rows:
    let c = s.text(r).cellFind(needle)
    if c >= 0: return (r, c)
  (-1, -1)

proc varsFind(s: Snapshot; needle: string): (int, int) =
  ## `needle` inside the Variables pane only (between its strip title and
  ## the next pane's): the editor shows the same names in the source.
  let (tr, left) = s.findRow(" Variables ")
  if tr < 0: return (-1, -1)
  let (_, right0) = s.findRow(" Call Trace ")
  let right = if right0 > left: right0 else: Cols
  for r in tr + 1 ..< Rows - 1:
    var slice = ""
    for c in left ..< right:
      slice.add(if int(s[r][c].rune) == 0: " " else: $s[r][c].rune)
    let at = slice.cellFind(needle)
    if at >= 0: return (r, left + at)
  (-1, -1)

proc dump(s: Snapshot): string =
  for r in 0 ..< Rows: result.add s.text(r) & "\n"

proc waitUntil(sess: var TuiTestSession; what: string;
               cond: proc(s: Snapshot): bool; timeoutMs = 60000): Snapshot =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.snap()
    if cond(result): return
    sleep(50)
  raise newException(AssertionFailedError, "never: " & what & "\n" &
                     result.dump)

proc waitText(sess: var TuiTestSession; needle: string): Snapshot =
  sess.waitUntil("`" & needle & "` on the screen", proc(s: Snapshot): bool =
    s.findRow(needle)[0] >= 0)

proc key(sess: var TuiTestSession; bytes: string) =
  sess.send(bytes)
  discard sess.drainOutput(if bytes == Esc: 300 else: 120)

proc quit(sess: var TuiTestSession; state: string) =
  sess.send(CtrlQ)
  discard sess.waitExit(initDuration(seconds = 15))
  sess.terminate()
  sess.close()
  removeDir(state)

proc bgHex(c: Cell): string =
  if c.bg.kind == ckRgb: hexOf((c.bg.r.int, c.bg.g.int, c.bg.b.int)) else: ""

let selectionHex = tokenHex(RoleSpecs[srSurfaceSelection].bg, dmDark)

proc selected(s: Snapshot; row, col: int): bool =
  ## Whether the cell at (`row`, `col`) is on the selected row's ground.
  row >= 0 and col >= 0 and s[row][col].bgHex == selectionHex

proc tick(s: Snapshot): int =
  let line = s.text(0)
  let at = line.find("tick: ")
  if at < 0: return -1
  var digits = ""
  for c in line[at + "tick: ".len .. ^1]:
    if c in {'0' .. '9'}: digits.add c
    elif c == ',': discard
    else: break
  if digits.len == 0: -1 else: parseInt(digits)

proc hopTick(line: string): int =
  ## The tick a hop row names: `⇠ tick N  kind  …`.
  let at = line.find("⇠ tick ")
  if at < 0: return -1
  var digits = ""
  for c in line[at + "⇠ tick ".len .. ^1]:
    if c in {'0' .. '9'}: digits.add c
    else: break
  if digits.len == 0: -1 else: parseInt(digits)

proc focusVariables(sess: var TuiTestSession; next = F6) =
  ## `F6` (CUA's `layout.focus-next-pane`) until the status line says the
  ## Variables pane has the focus.
  for i in 0 ..< 12:
    let before = sess.snap().text(StatusRow)
    sess.key(next)
    # The status names the pane the key focused; wait for it to change (a
    # loaded host paints it late), then read it.
    let deadline = getMonoTime() + initDuration(milliseconds = 3000)
    var now = before
    while getMonoTime() < deadline:
      now = sess.snap().text(StatusRow)
      if now != before and now.contains("focus "): break
      sleep(50)
    if now.contains("focus state"):
      return
  raise newException(AssertionFailedError,
                     "F6 never focused the Variables pane:\n" & sess.snap().dump)

proc selectVariable(sess: var TuiTestSession; name: string; down = Down;
                    first = Home): (int, int) =
  ## `Home` (the first row), then `Down` until `name`'s row is the selected
  ## one; its (row, column).
  if first.len > 0: sess.key(first)
  for i in 0 ..< 40:
    # A loaded host paints the moved cursor late: give each key up to a
    # second to show before reading where the cursor is.
    let deadline = getMonoTime() + initDuration(milliseconds = 1000)
    var s = sess.snap()
    while true:
      let (r, c) = s.varsFind(name & " ")
      if r >= 0 and s.selected(r, c):
        return (r, c)
      if getMonoTime() >= deadline: break
      sleep(50)
      s = sess.snap()
    sess.key(down)
  raise newException(AssertionFailedError,
                     "never selected " & name & ":\n" & sess.snap().dump)

proc atResults(sess: var TuiTestSession) =
  sess.send(":goto 118\r")
  discard sess.waitUntil("`value` in the Variables pane",
    proc(s: Snapshot): bool = s.varsFind("value ")[0] >= 0)

suite "PLAT-70 Part E on a real terminal: value origin from the keyboard":

  test "a press on a hop seeks to its tick, with the cursor on it":
    var (sess, state) = open()
    defer: sess.quit(state)
    sess.atResults()
    sess.focusVariables()
    let (rx, _) = sess.selectVariable("value")
    ck rx > 0
    sess.key(CtrlShiftO)
    var s = sess.waitUntil("the chain under value",
      proc(s: Snapshot): bool = s.findRow("⇠ tick ", rx + 1)[0] > rx)
    let (h0, hc) = s.findRow("⇠ tick ", rx + 1)
    let wanted = hopTick(s.text(h0))
    ck wanted > 0
    sess.sendMouseClick(h0, hc + 4)
    s = sess.waitUntil("the recording at the hop's tick",
      proc(s: Snapshot): bool = s.tick == wanted)
    let (h1, hc1) = s.findRow("⇠ tick ", 1)
    ck h1 > 0 and s.selected(h1, hc1)

  test "CUA: Ctrl+Shift+O, Down onto a hop, Escape, Enter seeks, Menu":
    var (sess, state) = open()
    defer: sess.quit(state)
    sess.atResults()
    sess.focusVariables()
    let (rx, cx) = sess.selectVariable("value")
    ck rx > 0
    # ---- Ctrl+Shift+O: the chain under the row ----------------------------
    sess.key(CtrlShiftO)
    var s = sess.waitUntil("the chain under value",
      proc(s: Snapshot): bool = s.findRow("⇠ tick ", rx + 1)[0] > rx)
    let (h0, hc) = s.findRow("⇠ tick ", rx + 1)
    checkpoint("first hop: " & s.text(h0))
    ck s.selected(rx, cx)                      # the variable keeps the cursor
    ck not s.selected(h0, hc)
    # ---- Down: onto the first hop -----------------------------------------
    sess.key(Down)
    s = sess.waitUntil("the first hop selected",
      proc(s: Snapshot): bool = s.selected(h0, hc))
    ck not s.selected(rx, cx)
    # ---- Escape: the chain closes; the variable is selected again ----------
    sess.key(Esc)
    s = sess.waitUntil("the chain closed",
      proc(s: Snapshot): bool = s.findRow("⇠ tick ")[0] < 0)
    ck s.selected(rx, cx)
    # ---- Enter on the first hop: the recording moves to its tick -----------
    sess.key(CtrlShiftO)
    s = sess.waitUntil("the chain again",
      proc(s: Snapshot): bool = s.findRow("⇠ tick ", rx + 1)[0] > rx)
    let hopLine = s.text(s.findRow("⇠ tick ", rx + 1)[0])
    let target = hopTick(hopLine)
    checkpoint("seek to " & $target)
    ck target > 0 and target != 118
    sess.key(Down)
    sess.key(Enter)
    s = sess.waitUntil("the tick the hop names",
      proc(s: Snapshot): bool = s.tick == target)
    ck s.tick == target
    # The cursor stays where it was across the stop the seek made: on the
    # first hop of `value`'s chain, read again at the new tick.
    s = sess.waitUntil("the hop still selected after the seek",
      proc(s: Snapshot): bool =
        let (h, c) = s.findRow("⇠ tick ")
        h >= 0 and s.selected(h, c))
    let (hs, hcs) = s.findRow("⇠ tick ")
    ck s.selected(hs, hcs)
    # ---- Menu: the row's menu; "Show value origin" toggles the chain -------
    sess.atResults()
    sess.focusVariables()
    let (rm, cm) = sess.selectVariable("value")
    let hadChain = sess.snap().findRow("⇠ tick ", rm + 1)[0] > rm
    sess.key(Menu)
    s = sess.waitText("Show value origin")
    let (ro, co) = s.findRow("Show value origin")
    ck ro >= rm
    sess.key(Down)
    sess.key(Enter)
    s = sess.waitUntil("the chain toggled",
      proc(s: Snapshot): bool =
        (s.findRow("⇠ tick ", rm + 1)[0] > rm) != hadChain and
        s.findRow("Show value origin")[0] < 0)
    discard co
    ck (s.findRow("⇠ tick ", rm + 1)[0] > rm) != hadChain
    discard cm

  test "legacy keys: Ctrl+K Shift+F10 opens the row menu; Shift+F10 still steps back":
    var (sess, state) = open(term = "screen-256color")
    defer: sess.quit(state)
    sess.atResults()
    sess.focusVariables()
    discard sess.selectVariable("value")
    sess.key(CtrlK)
    sess.key(ShiftF10)
    var s = sess.waitText("Show value origin")
    ck s.findRow("Toggle value history")[0] >= 0
    sess.key(Esc)
    s = sess.waitUntil("the menu closed",
      proc(s: Snapshot): bool = s.findRow("Show value origin")[0] < 0)
    let t0 = s.tick
    sess.key(ShiftF10)
    s = sess.waitUntil("reverse step over",
      proc(s: Snapshot): bool = s.tick >= 0 and s.tick < t0)
    ck s.tick < t0

  test "Vim: g o in the pane; Esc on a hop closes it; o walks and Shift+O walks back":
    var (sess, state) = open(@["--keymap=vim"])
    defer: sess.quit(state)
    sess.atResults()
    sess.key("3")
    discard sess.waitUntil("the Variables pane focused",
      proc(s: Snapshot): bool = s.text(StatusRow).contains("focus state"))
    let (rx, cx) = sess.selectVariable("value", down = "j", first = "")
    sess.key("g")
    sess.key("o")
    var s = sess.waitUntil("the chain under value",
      proc(s: Snapshot): bool = s.findRow("⇠ tick ", rx + 1)[0] > rx)
    let (h0, hc) = s.findRow("⇠ tick ", rx + 1)
    ck h0 > rx
    # `j` onto the hop; Vim's `Esc` there closes the chain, back on `value`.
    sess.key("j")
    s = sess.waitUntil("the hop selected",
      proc(s: Snapshot): bool = s.selected(h0, hc))
    sess.key(Esc)
    s = sess.waitUntil("the chain closed",
      proc(s: Snapshot): bool = s.findRow("⇠ tick ")[0] < 0)
    ck s.selected(rx, cx)
    sess.key("o")
    # The query is asynchronous (the status says so); the walk lands on the
    # hop's tick when it answers.
    s = sess.waitUntil("the walk's first hop",
      proc(s: Snapshot): bool = s.tick >= 0 and s.tick != 118)
    checkpoint("walked: " & s.text(StatusRow))
    let walked = s.tick
    ck walked != 118
    sess.key("O")
    s = sess.waitUntil("back at the question",
      proc(s: Snapshot): bool = s.tick == 118)
    ck s.tick == 118

  test "assertion count":
    check countedAssertions == ExpectedAssertions
