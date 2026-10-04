## test_plat48_top_bar.nim — PLAT-48, Tier 2. **The desktop's top bar and
## footer on a real terminal**: the shipped `codetracer-tui` on the `calc`
## recording in a real PTY (TermAssert + libvterm), a real `replay-server`
## behind it, driven by the bytes a terminal sends — keys, and SGR-1006 mouse
## reports.
##
##   * MENU — `F12` opens it and so does a click on a folder title; the keys
##     walk into the Debug folder; every stepping item's shortcut, read back
##     from the dropdown's cells, is the ACTIVE keymap's first binding for it;
##     `:keys <file>` rebinds Step Over and the dropdown shows the new chord;
##     choosing Step Over moves the debugger (the header's tick changes).
##   * OMNIBAR — `Ctrl+p`, `#42`, `Enter`: the debugger is at tick 42; a
##     `:sym` query lists the recording's functions.
##   * DEBUGGER CONTROLS — for `unicode`, `nerd` and `text` (at three
##     widths) the row's cells are the mode's glyphs (text: exactly a priority
##     prefix); a click on each control performs it on the recording (the
##     tick moves the way the control says); with the terminal answering the
##     kitty graphics query `OK` the controls are the DESKTOP'S MARKS — the
##     transcript carries each mark's pixels, byte-equal to the desktop's SVG
##     path data rasterised, placed on the control's cells.
##   * AUTO-HIDE — the footer strip's four labels; a click reveals the pane's
##     OWN rows over the body and changes nothing outside it; `Esc` restores
##     every cell; a left-docked pane's label reads down one character per
##     row; `:pin` / `:unpin` survive a restart through the saved layout.
##
## No mocks: the real binary, a real recording, a real engine, a real pty.

import std/[base64, monotimes, options, os, sets, strutils, times, unicode,
            unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../host/control_icons
import ../../../../common/terminal_graphics/[raster, path_raster]
import ../../../viewmodel/viewmodels/transport_icons

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count. (PLAT-49 part B: +9 — the footer
# case checks every row the docked-open pane changed, and a docked band is
# taller than the overlay the click used to open. PLAT-50: -1 — with no
# divider row between stacked panes the docked band changes one row fewer.)
const ExpectedAssertions = 109

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  F12 = "\x1b[24~"
  CtrlP = "\x10"
  CtrlO = "\x0f"
  Enter = "\r"
  Esc = "\x1b"
  Down = "\x1b[B"
  Right = "\x1b[C"
  KittyOk = "\x1b_Gi=31;OK\x1b\\"

type Snapshot = seq[seq[Cell]]

proc colorKey(c: Color): string =
  case c.kind
  of ckDefault: "default"
  of ckIndexed: "idx" & $c.idx
  of ckRgb: $c.r & "," & $c.g & "," & $c.b

proc stateDir(name: string): string =
  result = getTempDir() / ("plat48-pty-" & $getCurrentProcessId() & "-" & name)
  createDir(result)

proc open(cols, rows: int; state: string; extra: seq[(string, string)] = @[]):
    TuiTestSession =
  let resolved = resolveFixture("calc")
  doAssert resolved.outcome == foRecorded
  var b = newTuiTest(tuiBinary(), @[resolved.tracePath])
    .width(cols).height(rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
  for (k, v) in extra:
    b = b.envSet(k, v)
  result = b.spawn()
  settleOnDebugger(result, cols, rows)

proc rowOf(sess: var TuiTestSession; cols, row: int): string =
  discard sess.drainOutput(40)
  sess.regionText(row, 0, cols, 1).split('\n')[0]

proc waitRow(sess: var TuiTestSession; cols, row: int; needle: string;
             timeoutMs = 30000): string =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.rowOf(cols, row)
    if result.contains(needle):
      return
  raise newException(AssertionFailedError,
    "row " & $row & " never showed '" & needle & "': " & result)

proc tickOf(line: string): int =
  let at = line.find("tick: ")
  if at < 0: return -1
  var digits = ""
  for ch in line[at + 6 .. ^1]:
    if ch in {'0' .. '9'}: digits.add ch
    elif ch == ',': discard
    else: break
  if digits.len == 0: -1 else: parseInt(digits)

proc waitTick(sess: var TuiTestSession; cols: int; want: proc(t: int): bool;
              timeoutMs = 240000): int =
  ## Generous: a step is a round trip through `replay-server`, and on a host
  ## at load 150 one step was measured taking tens of seconds.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = tickOf(sess.rowOf(cols, 0))
    if want(result):
      return
  raise newException(AssertionFailedError,
    "the header's tick never satisfied the wait: " & sess.rowOf(cols, 0) &
    " | status: " & sess.statusRowText(cols, 50))

proc snap(sess: var TuiTestSession; cols, rows: int): Snapshot =
  discard sess.drainOutput(60)
  for r in 0 ..< rows:
    var row: seq[Cell] = @[]
    for c in 0 ..< cols:
      row.add sess.cellAt(r, c)
    result.add row

proc text(s: Snapshot; r: int): string =
  for c in s[r]:
    result.add(if int(c.rune) == 0: " " else: $c.rune)

proc cellFind(line, needle: string; start = 0): int =
  let at = line.find(needle, start)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc esc(sess: var TuiTestSession) =
  ## One `Esc` KEY: a lone `ESC` byte, then quiet for longer than the
  ## binary's escape delay (`EscDelayMs`, 50 ms) — two `ESC`s sent back to
  ## back are framed as ONE key, exactly as a terminal's would be.
  sess.send(Esc)
  sleep(200)
  discard sess.drainOutput(40)

proc click(sess: var TuiTestSession; row, col: int) =
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "M")
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "m")

proc typeLine(sess: var TuiTestSession; line: string) =
  sess.send(":")
  sess.send(line)
  sess.send(Enter)

proc quit(sess: var TuiTestSession) =
  sess.send("q")
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

suite "PLAT-48 on a real terminal: the menu":

  test "open by key and by click, walk into Debug, shortcuts are the keymap's, rebind, choose":
    const Cols = 200
    const Rows = 50
    var sess = open(Cols, Rows, stateDir("menu"))
    let top = sess.rowOf(Cols, 0)
    # PLAT-49: one root button; the first level drops below it. PLAT-50: the
    # button is bounded by edge lines, as the desktop's `#menu-root` border.
    ck top.startsWith("▕≡▏")
    # BY KEY: F12, then Down through the first level to Debug, Right into it.
    sess.send(F12)
    # Row 1 already says "Files" (the Files stack's strip, PLAT-49): wait for
    # the dropdown's second item, which nothing else on that row spells.
    # PLAT-50: the dropdown is framed, its items one row down (row 1 is its
    # top edge).
    discard sess.waitRow(Cols, 3, " Edit ")
    var debugRow = -1
    for r in 1 ..< 12:
      if sess.rowOf(Cols, r).cellFind(" Debug ") in 0 .. 3: debugRow = r
    ck debugRow > 0
    for _ in 0 ..< 5:
      sess.send(Down)
    sess.send(Right)
    discard sess.waitRow(Cols, debugRow, "Continue")
    let expected = [("Continue", "c"), ("Step Over", "n"), ("Step In", "s"),
                    ("Step Out", "f"), ("Reverse Continue", "rc"),
                    ("Reverse Step Over", "p"), ("Reverse Step In", "b"),
                    ("Reverse Step Out", "rf")]
    var s = sess.snap(Cols, Rows)
    for (label, chord) in expected:
      var found = false
      for r in 1 ..< 24:
        let line = s.text(r)
        let at = line.cellFind(" " & label & " ")
        if at >= 0 and line.runeSubStr(at + 1).strip.startsWith(label):
          let rest = line.runeSubStr(at + 1 + label.runeLen).strip
          if rest.split(' ')[0] == chord:
            found = true
      ck found
    sess.esc()
    sess.esc()
    # BY CLICK: the root button, then the Debug folder.
    sess.click(0, 1)
    discard sess.waitRow(Cols, debugRow, "Debug")
    sess.click(debugRow, 2)
    discard sess.waitRow(Cols, debugRow + 1, "Step Over")
    sess.esc()
    sess.esc()
    # REBIND: Step Over becomes Ctrl+n; the dropdown says so.
    let keys = stateDir("menu") / "keys"
    writeFile(keys, "NORMAL n = -\nNORMAL F10 = -\nNORMAL Ctrl+n = step-over\n")
    sess.typeLine("keys " & keys)
    discard sess.waitRow(Cols, Rows - 1, "keys " & keys)
    sess.click(0, 1)
    discard sess.waitRow(Cols, debugRow, "Debug")
    sess.click(debugRow, 2)
    let row2 = sess.waitRow(Cols, debugRow + 1, "Step Over")
    ck row2.contains("Ctrl+n")
    # CHOOSE Step Over: the debugger moves.
    let before = tickOf(sess.rowOf(Cols, 0))
    sess.send(Down)
    sess.send(Enter)
    let after = sess.waitTick(Cols, proc(t: int): bool = t > before)
    ck after > before
    sess.quit()

suite "PLAT-48 on a real terminal: the omnibar":

  test "Ctrl+p, a tick, Enter: the debugger is there; a :sym query lists functions":
    const Cols = 200
    const Rows = 50
    var sess = open(Cols, Rows, stateDir("omnibar"))
    sess.send(CtrlP)
    sess.send("#42")
    # PLAT-50: the results are framed; the first is on row 2.
    discard sess.waitRow(Cols, 2, "Go to tick 42")
    sess.send(Enter)
    let t = sess.waitTick(Cols, proc(t: int): bool = t == 42)
    ck t == 42
    sess.send(CtrlP)
    sess.send(":sym apply")
    let r1 = sess.waitRow(Cols, 2, "apply_op")
    ck r1.contains("apply_op")
    sess.send(Enter)
    let moved = sess.waitTick(Cols, proc(t: int): bool = t != 42)
    ck moved != 42
    sess.quit()

suite "PLAT-48 on a real terminal: the debugger controls":

  test "unicode and nerd: the row's cells are the mode's glyphs":
    const Cols = 200
    const Rows = 50
    for mode in [imUnicode, imNerd]:
      var sess = open(Cols, Rows, stateDir("glyphs-" & $mode))
      sess.typeLine("icons " & $mode)
      discard sess.waitRow(Cols, Rows - 1, "icons " & $mode)
      let top = sess.rowOf(Cols, 0)
      for c in TransportControls:
        ck top.contains(" " & c.glyphFor(mode) & " ")
      sess.quit()

  test "text: exactly a priority prefix at 80, 120 and 200 columns":
    for cols in [80, 120, 200]:
      var sess = open(cols, 40, stateDir("text-" & $cols))
      sess.typeLine("icons text")
      # Synchronised on the TOP ROW taking the first priority control's
      # text: since PLAT-49 part B the footer's labels share the status row,
      # and at 80 columns they leave the command's note too little room to
      # be read back whole.
      let first = TransportControls[controlIndex(TextPriority[0])].text
      discard sess.waitRow(cols, 0, " " & first & " ")
      let top = sess.rowOf(cols, 0)
      var shown: HashSet[string]
      shown.init()
      for c in TransportControls:
        if top.contains(" " & c.text & " "):
          shown.incl c.id
      var k = 0
      while k < TextPriority.len and TextPriority[k] in shown:
        inc k
      ck k == shown.len          # a PREFIX of the priority order
      if cols == 200: ck shown.len == TransportControls.len
      if cols == 80: ck shown.len < TransportControls.len
      sess.quit()

  test "a click on each control performs it on the recording":
    const Cols = 200
    const Rows = 50
    var sess = open(Cols, Rows, stateDir("click"))
    proc col(sess: var TuiTestSession; glyph: string): int =
      sess.rowOf(Cols, 0).cellFind(" " & glyph & " ") + 1
    var t = tickOf(sess.rowOf(Cols, 0))
    # An order in which every control has somewhere to go: forward and back
    # inside the program first, then to the entry, the end, and back. Two
    # `next`s first, so the reverse steps start inside a call and not on the
    # entry line (from which reverse-next has only the start to go to).
    let order = [("next", 1), ("next", 1), ("step-in", 1), ("next", 1),
                 ("reverse-next", -1),
                 ("reverse-step-in", -1), ("step-out", 1),
                 ("reverse-step-out", -1), ("run-to-entry", 0),
                 ("continue", 1), ("reverse-continue", -1)]
    for (id, dir) in order:
      let before = t
      sess.click(0, sess.col(TransportControls[controlIndex(id)].unicode))
      t = sess.waitTick(Cols, proc(x: int): bool =
        (dir > 0 and x > before) or (dir < 0 and x < before) or
        (dir == 0 and x <= 1))
      checkpoint(id & ": " & $before & " -> " & $t)
      if dir > 0: ck t > before
      elif dir < 0: ck t < before
      else: ck t <= 1
    sess.quit()

  test "graphics: on a terminal that answers the kitty query, the controls are the desktop's marks":
    const Cols = 200
    const Rows = 50
    var sess = open(Cols, Rows, stateDir("graphics"))
    # THE TERMINAL'S ANSWER to the graphics query the binary sent after its
    # first frame (libvterm draws no pictures; the reply is what a kitty
    # graphics terminal writes back).
    sess.send(KittyOk)
    let deadline = getMonoTime() + initDuration(seconds = 20)
    var bytes = ""
    while getMonoTime() < deadline:
      discard sess.drainOutput(60)
      bytes = sess.transcriptBytes()
      if bytes.contains("\x1b_Ga=p,i=48"):
        break
    ck sess.transcriptDroppedBytes() == 0
    ck bytes.contains("\x1b_Gi=31,s=1,v=1,a=q")       # the query was asked
    var placed = 0
    for i in 0 ..< TransportControls.len:
      for ink in IconInk:
        let id = iconImageId(ink, i)
        let head = "\x1b_Ga=t,f=32,s=32,v=32,i=" & $id & ",q=2,m="
        let at = bytes.find(head)
        if at < 0:
          continue
        var b64 = ""
        var p = at
        while true:
          let semi = bytes.find(';', p)
          let stop = bytes.find("\x1b\\", semi)
          b64.add bytes[semi + 1 ..< stop]
          let more = bytes[p ..< semi].contains("m=1")
          p = stop + 2
          if not more: break
        let decoded = decode(b64)
        # The ink is the one the binary drew in; the SHAPE is the desktop's
        # mark: every pixel's coverage (alpha) equals the rasterised mark's.
        let expected = markImage(TransportControls[i].id, rgb(0, 0, 0))
        var sameAlpha = decoded.len == expected.pixels.len
        if sameAlpha:
          for k in countup(3, decoded.len - 1, 4):
            if byte(decoded[k]) != expected.pixels[k]:
              sameAlpha = false
        ck sameAlpha
        let place = "\x1b_Ga=p,i=" & $id & ",p=1,c=2,r=1,C=1,q=2"
        if bytes.contains(place):
          inc placed
    ck placed == TransportControls.len
    # The control cells themselves are blank: the picture is over them.
    let top = sess.rowOf(Cols, 0)
    for c in TransportControls:
      ck not top.contains(" " & c.unicode & " ")
    sess.quit()

suite "PLAT-48 on a real terminal: auto-hide panels":

  test "the footer labels on the status row; a click docks the pane's own rows; a second restores every cell":
    # PLAT-49 part B (the user's direction): the labels are IN the status
    # row, and a click DOCKS the pane into the arrangement — no overlay, no
    # message — where a second click on its label closes it again.
    const Cols = 200
    const Rows = 50
    var sess = open(Cols, Rows, stateDir("reveal"))
    let s0 = sess.snap(Cols, Rows)
    let strip = s0.text(Rows - 1)
    for t in ["BUILD", "PROBLEMS", "FIND IN FILES", "REQUESTS"]:
      ck strip.contains(" " & t & " ")
    sess.click(Rows - 1, strip.cellFind(" BUILD ") + 1)
    let deadline = getMonoTime() + initDuration(seconds = 10)
    var s1 = sess.snap(Cols, Rows)
    while getMonoTime() < deadline and s1.text(Rows - 2) == s0.text(Rows - 2):
      sleep(100)
      s1 = sess.snap(Cols, Rows)
    # The docked band: the rows that changed at the bottom of the body.
    var changed: seq[int] = @[]
    for r in 1 ..< Rows - 1:
      if s1.text(r) != s0.text(r):
        changed.add r
    ck changed.len > 0
    # ITS OWN ROWS: the build pane's tab and verdict, no fill glyph.
    var band = -1
    for r in changed:
      if s1.text(r).startsWith(" BUILD "): band = r
    ck band > 0
    ck s1.text(band + 1).contains("[idle]")
    for r in changed:
      ck not s1.text(r).contains("▒")
    # Contiguous to the status row: docked against the bottom edge.
    ck changed[^1] == Rows - 2
    ck not sess.rowOf(Cols, Rows - 1).contains("revealing")
    sess.click(Rows - 1, strip.cellFind(" BUILD ") + 1)
    let deadline2 = getMonoTime() + initDuration(seconds = 10)
    var s2 = sess.snap(Cols, Rows)
    while getMonoTime() < deadline2 and s2.text(Rows - 2) != s0.text(Rows - 2):
      sleep(100)
      s2 = sess.snap(Cols, Rows)
    var same = true
    for r in 0 ..< Rows - 1:
      for c in 0 ..< Cols:
        if s2[r][c].rune != s0[r][c].rune or
           colorKey(s2[r][c].fg) != colorKey(s0[r][c].fg) or
           colorKey(s2[r][c].bg) != colorKey(s0[r][c].bg):
          same = false
    ck same
    sess.quit()

  test "a left-docked pane's label reads down, one character per row":
    const Cols = 200
    const Rows = 50
    var sess = open(Cols, Rows, stateDir("left"))
    sess.typeLine("focus left")
    sess.typeLine("dock left")
    discard sess.waitRow(Cols, Rows - 1, "applied")
    let s = sess.snap(Cols, Rows)
    var column = ""
    for r in 1 ..< Rows - 2:
      column.add s[r][0].rune
    # `:focus left` from the editor is the Files stack.
    ck column.startsWith("Files")
    sess.quit()

  test "pin and unpin survive a restart through the saved layout":
    const Cols = 200
    const Rows = 50
    let state = stateDir("pin")
    var sess = open(Cols, Rows, state)
    sess.typeLine("focus left")
    sess.typeLine("pin")
    discard sess.waitRow(Cols, Rows - 1, "applied")
    let strip = sess.rowOf(Cols, Rows - 1)
    ck strip.contains(" Files ") or strip.contains(" FILES ")
    sess.quit()
    var again = open(Cols, Rows, state)
    let strip2 = again.rowOf(Cols, Rows - 1)
    ck strip2.contains(" Files ") or strip2.contains(" FILES ")
    again.typeLine("unpin fileTree")
    discard again.waitRow(Cols, Rows - 1, "applied")
    ck not again.rowOf(Cols, Rows - 1).contains(" Files ")
    again.quit()
    var third = open(Cols, Rows, state)
    ck not third.rowOf(Cols, Rows - 1).contains(" Files ")
    # Placed again: its title row (a bare pane's title is upper-cased) or
    # its tab.
    let body = third.rowOf(Cols, 1) & third.rowOf(Cols, 2)
    ck body.contains("FILES") or body.contains("Files")
    third.quit()

suite "PLAT-48 pty: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
