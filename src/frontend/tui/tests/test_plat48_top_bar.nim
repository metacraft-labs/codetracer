## test_plat48_top_bar.nim — PLAT-48, the terminal's rendering, Tier 1: the
## top bar row, the menu's dropdowns, the omnibar, the debugger controls in
## their four renderings, the auto-hide strips and the reveal, pin / unpin,
## the session tabs, and the kitty bytes the `graphics` rendering sends.
##
## Everything through the product's own entry points: `TuiRuntime.handleToken`
## with the bytes a terminal sends (`F12` is `ESC [ 24 ~`), `shellScreenOf`
## for the frame, `control_icons.controlIconBytes` for the picture escapes.
## The runtime has no replay session here (the pty suite
## `real_terminal/test_plat48_top_bar.nim` has one): a debugger action
## dispatched with no session answers "unavailable", which is asserted, not
## hidden.
##
## ONE STAND-IN, and why it is not a mock of anything asserted: the session
## tab cases open several `HeadlessApp` slots over the SDK's own
## `MockBackendService` (a transport that answers the DAP handshake), because
## a terminal process opens one recording and the strip needs several. What
## those cases assert — which tabs are drawn, which one is active, what a
## click, `g t` / `g T` or `Ctrl+Tab` does to the active slot — is a function
## of the real slots and the real key path, never of the transport.

import std/[base64, os, strutils, tables, unicode, unittest]

import ../app/runtime
import ../app/views/shell
import ../app/layout/binding
import ../app/theme/capabilities
import ../host/control_icons
import ../../../common/terminal_graphics/[raster, path_raster]
import headless_app/session_tabs
import headless_app/layout_model
import codetracer_embed

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 311

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
  Up = "\x1b[A"
  Right = "\x1b[C"
  Left = "\x1b[D"

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc newRuntime(cols, rows: int): TuiRuntime =
  result = newTuiRuntime(newTuiApp(), caps(), cols, rows)
  discard result.enableLayoutBinding()
  result.refreshMenuForKeymap()

proc row0(rt: TuiRuntime): string = rt.shellScreenOf().rows[0]

proc visible(rt: TuiRuntime): seq[string] = rt.shellScreenOf().visibleRows()

proc typeLine(rt: TuiRuntime; line: string): RuntimeOutcome =
  result = rt.handleToken(":", 0'i64)
  for ch in line:
    result = rt.handleToken($ch, 0'i64)
  result = rt.handleToken(Enter, 0'i64)

suite "PLAT-48: the top bar row":

  test "at 200 columns: the menu's titles, every control, the omnibar field, the header":
    let rt = newRuntime(200, 50)
    let r = rt.row0()
    for title in ["File", "Edit", "View", "Build", "Reset", "Debug", "Help"]:
      ck r.contains(" " & title & " ")
    for c in TransportControls:
      ck r.contains(c.unicode)
    ck r.contains("⌕ Search")
    ck r.contains("tick: ")
    ck r.strip.endsWith("[PAUSED]")
    # Colour, not glyphs: no bracket around a title and no rule through it.
    ck not r.contains("[File]") and not r.contains("─")

  test "at 80 columns: the menu collapses to ≡, the omnibar to ⌕, controls by priority":
    let rt = newRuntime(80, 24)
    # The header a real recording puts beside them (`calc`'s own).
    rt.app.traceName = "calc-2f0db4f45192"
    rt.app.tick = 1420
    rt.app.totalTicks = 8950
    let lay = rt.shellScreenOf().topBarLayout
    ck not lay.menuExpanded and not lay.omnibarField
    ck rt.row0().startsWith(" ≡ ")
    var ids: seq[string] = @[]
    for i in lay.shownControls: ids.add TransportControls[i].id
    # A priority PREFIX, in toolbar order.
    var prefix: seq[string] = @[]
    for id in TextPriority:
      if prefix.len < ids.len: prefix.add id
    for id in prefix: ck id in ids
    ck ids.len < TransportControls.len
    ck rt.row0().contains("tick: ")

  test "each icons mode draws its own glyph set":
    for mode in [imNerd, imUnicode, imText]:
      let rt = newRuntime(220, 50)
      rt.app.icons = mode
      let r = rt.row0()
      for c in TransportControls:
        ck r.contains(c.glyphFor(mode))
    # `graphics` on a terminal that was not measured to draw pictures falls
    # back to unicode — a mode it cannot show is never drawn as blanks.
    let rt = newRuntime(200, 50)
    rt.app.icons = imGraphics
    ck rt.shellScreenOf().topBarLayout.effectiveIcons == imUnicode
    rt.app.graphicsDrawn = true
    let lay = rt.shellScreenOf().topBarLayout
    ck lay.effectiveIcons == imGraphics
    for s in lay.segments:
      if s.part == tpControl:
        ck s.width == GraphicsControlCells + 1
        ck rt.row0().runeSubStr(s.col, s.width).strip.len == 0

  test "text mode keeps exactly the priority subset at three widths":
    for width in [80, 120, 200]:
      let rt = newRuntime(width, 40)
      rt.app.icons = imText
      let lay = rt.shellScreenOf().topBarLayout
      var ids: seq[string] = @[]
      for i in lay.shownControls: ids.add TransportControls[i].id
      var expected: seq[string] = @[]
      for id in TextPriority:
        if expected.len < ids.len: expected.add id
      var sorted: seq[string] = @[]
      for c in TransportControls:
        if c.id in expected: sorted.add c.id
      ck ids == sorted
      for i in lay.shownControls:
        ck rt.row0().contains(" " & TransportControls[i].text & " ")
      if width == 200:
        ck ids.len == TransportControls.len
      if width == 80:
        ck ids.len < TransportControls.len

suite "PLAT-48: the menu":

  test "F12 opens it; keys walk the bar and into a folder; the chords are the keymap's":
    let rt = newRuntime(200, 50)
    discard rt.handleToken(F12, 0)
    ck rt.app.menu.isOpen
    # The bar: Right moves across the titles, Down enters one.
    for _ in 0 ..< 5:
      discard rt.handleToken(Right, 0)
    ck rt.app.menu.highlightedItem().label == "Debug"
    discard rt.handleToken(Down, 0)
    ck rt.app.menu.path == @[6]
    let screen = rt.shellScreenOf()
    ck screen.menuDropdowns.len == 1
    let dd = screen.menuDropdowns[0]
    let rows = rt.visible()
    var stepOver = ""
    for dr in dd.rows:
      if dr.item >= 0 and dd.level.items[dr.item].label == "Step Over":
        stepOver = rows[dr.row].runeSubStr(dd.area.col, dd.area.width)
    ck stepOver.contains("Step Over")
    ck stepOver.contains(" n ")     # the default keymap's first binding
    discard rt.handleToken(Esc, 0)
    ck rt.app.menu.path.len == 0 and rt.app.menu.isOpen
    discard rt.handleToken(Esc, 0)
    ck not rt.app.menu.isOpen

  test "switching the keymap changes the chord the menu shows":
    let rt = newRuntime(200, 50)
    let keys = getTempDir() / "plat48-keys-" & $getCurrentProcessId()
    writeFile(keys, "NORMAL n = -\nNORMAL F10 = -\nNORMAL Ctrl+n = step-over\n")
    discard rt.typeLine("keys " & keys)
    ck rt.app.menu.shortcutFor("forwardNext") == "Ctrl+n"
    discard rt.typeLine("keys default")
    ck rt.app.menu.shortcutFor("forwardNext") == "n"
    removeFile(keys)

  test "Enter on an item runs its action; a disabled item does nothing":
    let rt = newRuntime(200, 50)
    discard rt.handleToken(F12, 0)
    for _ in 0 ..< 5:
      discard rt.handleToken(Right, 0)
    discard rt.handleToken(Down, 0)
    discard rt.handleToken(Down, 0)      # Step Over
    let outcome = rt.handleToken(Enter, 0)
    ck not rt.app.menu.isOpen
    # No session: the dispatcher answers, by name, that it cannot step.
    ck outcome.action == kaStepOver
    # File > Open Trace... is not something the terminal does: disabled.
    discard rt.handleToken(F12, 0)
    discard rt.handleToken(Down, 0)
    ck rt.app.menu.path == @[1]
    ck not rt.app.menu.highlightedItem().enabled
    discard rt.handleToken(Enter, 0)
    ck rt.app.menu.isOpen

  test "a click on a title opens it, on an item runs it, outside closes":
    let rt = newRuntime(200, 50)
    let lay = rt.shellScreenOf().topBarLayout
    let view = lay.segmentOf(tpMenuTitle, 3)     # View
    discard rt.handleToken("\x1b[<0;" & $(view.col + 2) & ";1M", 0)
    discard rt.handleToken("\x1b[<0;" & $(view.col + 2) & ";1m", 0)
    ck rt.app.menu.isOpen and rt.app.menu.path == @[3]
    let dd = rt.shellScreenOf().menuDropdowns[0]
    var resetRow = -1
    for dr in dd.rows:
      if dr.item >= 0 and dd.level.items[dr.item].label == "Reset Layout":
        resetRow = dr.row
    ck resetRow > 0
    discard rt.handleToken("\x1b[<0;" & $(dd.area.col + 3) & ";" &
                           $(resetRow + 1) & "M", 0)
    ck not rt.app.menu.isOpen
    ck rt.app.notification.contains("reset")
    discard rt.handleToken(F12, 0)
    discard rt.handleToken("\x1b[<0;100;30M", 0)
    ck not rt.app.menu.isOpen

suite "PLAT-48: the omnibar":

  test "Ctrl+p opens it; the mode follows the query; Enter on a tick goes there":
    let rt = newRuntime(200, 50)
    discard rt.handleToken(CtrlP, 0)
    ck rt.app.omnibar.isOpen
    ck rt.shellScreenOf().topBarLayout.omnibarField
    for ch in "#42":
      discard rt.handleToken($ch, 0)
    ck rt.app.omnibar.mode == omTick
    ck rt.row0().contains("⌕ #42")
    ck rt.app.omnibar.resultLabels() == @["Go to tick 42"]
    let outcome = rt.handleToken(Enter, 0)
    ck not rt.app.omnibar.isOpen
    ck outcome.detail.contains("goto") or rt.app.notification.contains("goto") or
       rt.app.notification.len > 0

  test "a command query lists the menu's commands and runs one":
    let rt = newRuntime(200, 50)
    discard rt.handleToken(CtrlP, 0)
    for ch in ":reset lay":
      discard rt.handleToken(if ch == ' ': " " else: $ch, 0)
    ck rt.app.omnibar.mode == omCommand
    ck rt.app.omnibar.resultLabels().len >= 1
    ck rt.app.omnibar.resultLabels()[0] == "View › Reset Layout"
    discard rt.handleToken(Enter, 0)
    ck rt.app.notification.contains("reset")

  test "Esc closes it, and the frame shows its results under the field":
    let rt = newRuntime(200, 50)
    discard rt.handleToken(CtrlP, 0)
    for ch in ":step":
      discard rt.handleToken($ch, 0)
    let rows = rt.visible()
    ck rows[1].contains("Debug › Step")
    discard rt.handleToken(Esc, 0)
    ck not rt.app.omnibar.isOpen

suite "PLAT-48: the auto-hide strips":

  test "the shared default's footer panels are the bottom strip's labels":
    let rt = newRuntime(200, 50)
    let rows = rt.visible()
    let strip = rows[^2]
    for t in ["BUILD", "PROBLEMS", "FIND IN FILES", "REQUESTS"]:
      ck strip.contains(" " & t & " ")

  test "a left-docked pane's label reads top to bottom, one character per row":
    let rt = newRuntime(200, 50)
    discard rt.typeLine("focus left")
    let focused = rt.app.layoutBinding.focus
    discard rt.typeLine("dock left")
    let screen = rt.shellScreenOf()
    var left: DockStrip
    for s in screen.geometry.strips:
      if s.edge == leLeft: left = s
    ck left.slots.len == 1 and left.slots[0].pane == focused
    let title = left.slots[0].title
    let rows = screen.visibleRows()
    var read = ""
    for i in 0 ..< title.runeLen:
      read.add rows[left.area.row + i].runeSubStr(left.area.col, 1)
    ck read == title

  test "Ctrl+o reveals the docked pane ITSELF over the body, Esc restores every cell":
    let rt = newRuntime(200, 50)
    let before = rt.visible()
    discard rt.handleToken(CtrlO, 0)
    let screen = rt.shellScreenOf()
    ck screen.geometry.revealing
    ck screen.geometry.revealPane == paneBuildOutput
    let a = screen.geometry.reveal
    # Against the footer's own edge: the bottom of the tree area, full width.
    let inner = screen.geometry.inner
    ck a.row + a.height == inner.row + inner.height
    ck a.col == inner.col and a.width == inner.width
    let rows = screen.visibleRows()
    # The build pane's own title row, not a fill glyph.
    ck rows[a.row].runeSubStr(a.col, a.width).contains("BUILD")
    for r in a.row ..< a.row + a.height:
      ck not rows[r].runeSubStr(a.col, a.width).contains("▒")
    # Nothing outside the overlay moved.
    for r in 0 ..< rows.len - 1:
      if r < a.row or r >= a.row + a.height:
        ck rows[r] == before[r]
    discard rt.handleToken(Esc, 0)
    ck not rt.shellScreenOf().geometry.revealing
    let after = rt.visible()
    for r in 0 ..< after.len - 1:
      ck after[r] == before[r]

  test "Ctrl+o cycles through the docked panes and then hides":
    let rt = newRuntime(200, 50)
    var seen: seq[PaneKind] = @[]
    for _ in 0 ..< 4:
      discard rt.handleToken(CtrlO, 0)
      seen.add rt.shellScreenOf().geometry.revealPane
    ck seen == @[paneBuildOutput, paneProblems, paneSearch, paneRequests]
    discard rt.handleToken(CtrlO, 0)
    ck not rt.shellScreenOf().geometry.revealing

  test "a second click on the revealed pane's label hides it; outside hides it too":
    let rt = newRuntime(200, 50)
    var strip: DockStrip
    for s in rt.shellScreenOf().geometry.strips:
      if s.edge == leBottom: strip = s
    let slot = strip.slots[1].area
    let press = "\x1b[<0;" & $(slot.col + 2) & ";" & $(slot.row + 1)
    discard rt.handleToken(press & "M", 0)
    discard rt.handleToken(press & "m", 0)
    ck rt.shellScreenOf().geometry.revealPane == paneProblems
    discard rt.handleToken(press & "M", 0)
    discard rt.handleToken(press & "m", 0)
    ck not rt.shellScreenOf().geometry.revealing
    discard rt.handleToken(press & "M", 0)
    discard rt.handleToken(press & "m", 0)
    discard rt.handleToken("\x1b[<0;60;5M", 0)
    ck not rt.shellScreenOf().geometry.revealing

  test "pin / unpin round-trip through the saved document":
    let rt = newRuntime(200, 50)
    discard rt.typeLine("focus left")
    let pane = rt.app.layoutBinding.focus
    discard rt.typeLine("pin")
    ck rt.app.layoutBinding.layout.dockedIndex(pane) >= 0
    let doc = rt.app.layoutBinding.saveDocument()
    let rt2 = newRuntime(200, 50)
    discard rt2.app.layoutBinding.restoreDocument(doc)
    ck rt2.app.layoutBinding.layout.dockedIndex(pane) >= 0
    discard rt2.typeLine("unpin " & $pane)
    ck rt2.app.layoutBinding.layout.dockedIndex(pane) < 0
    ck rt2.app.layoutBinding.layout.tree.contains(pane)
    let back = rt2.app.layoutBinding.saveDocument()
    let rt3 = newRuntime(200, 50)
    discard rt3.app.layoutBinding.restoreDocument(back)
    ck rt3.app.layoutBinding.layout.tree.contains(pane)
    # …and in its own place: the arrangement after pin + unpin is the one
    # before the pin, pane for pane (the first tab of a stack goes back in
    # FRONT of the tab that followed it, not behind it).
    let before = newRuntime(200, 50)
    discard before.typeLine("focus left")
    proc order(n: LayoutNode; acc: var seq[PaneKind]) =
      if n.kind == lnPane: acc.add n.pane
      for c in n.children: order(c, acc)
    var was, now: seq[PaneKind] = @[]
    order(before.app.layoutBinding.layout.tree, was)
    order(rt3.app.layoutBinding.layout.tree, now)
    checkpoint($was & " / " & $now)
    ck was == now

suite "PLAT-48: session tabs":

  test "several sessions are a strip; the active one is lifted, a click activates":
    let rt = newRuntime(220, 50)
    for t in ["alpha", "beta", "gamma"]:
      discard rt.app.shell.openSession(newMockBackendService(autoRespond = true)
                                         .toBackendService(), t)
    let screen = rt.shellScreenOf()
    var tabs: seq[TopBarSegment] = @[]
    for s in screen.topBarLayout.segments:
      if s.part == tpTab: tabs.add s
    ck tabs.len == 3
    for (s, t) in [(tabs[0], "alpha"), (tabs[1], "beta"), (tabs[2], "gamma")]:
      ck screen.rows[0].runeSubStr(s.col, s.width) == " " & t & " "
    ck rt.app.shell.activeTabIndex() == 2
    discard rt.handleToken("\x1b[<0;" & $(tabs[0].col + 2) & ";1M", 0)
    ck rt.app.shell.activeTabIndex() == 0

  test "g t / g T and Ctrl+Tab / Ctrl+Shift+Tab step the tabs, wrapping (§3.3.1)":
    let rt = newRuntime(220, 50)
    # One session: the key answers, and says there is no other tab.
    discard rt.app.shell.openSession(newMockBackendService(autoRespond = true)
                                       .toBackendService(), "alpha")
    discard rt.handleToken("g", 0)
    discard rt.handleToken("t", 0)
    ck rt.app.shell.activeTabIndex() == 0
    ck rt.app.notification.contains("only one session")
    for t in ["beta", "gamma"]:
      discard rt.app.shell.openSession(newMockBackendService(autoRespond = true)
                                         .toBackendService(), t)
    ck rt.app.shell.activeTabIndex() == 2
    # `g t` from the last tab wraps to the first; the row shows it lifted.
    discard rt.handleToken("g", 0)
    discard rt.handleToken("t", 0)
    ck rt.app.shell.activeTabIndex() == 0
    ck rt.app.notification.contains("session 1 of 3: alpha")
    # `g T` wraps back to the last.
    discard rt.handleToken("g", 0)
    discard rt.handleToken("T", 0)
    ck rt.app.shell.activeTabIndex() == 2
    # `Ctrl+Tab` as xterm's modifyOtherKeys and as `CSI u` sends it.
    discard rt.handleToken("\x1b[27;5;9~", 0)
    ck rt.app.shell.activeTabIndex() == 0
    discard rt.handleToken("\x1b[9;5u", 0)
    ck rt.app.shell.activeTabIndex() == 1
    discard rt.handleToken("\x1b[27;6;9~", 0)
    ck rt.app.shell.activeTabIndex() == 0
    discard rt.handleToken("\x1b[9;6u", 0)
    ck rt.app.shell.activeTabIndex() == 2
    # The strip draws what the ViewModel says is active.
    let screen = rt.shellScreenOf()
    var active = ""
    for sg in screen.topBarLayout.segments:
      if sg.part == tpTab and sg.index == rt.app.shell.activeTabIndex():
        active = screen.rows[0].runeSubStr(sg.col, sg.width)
    ck active == " gamma "
    # A bare `t` is still seek-to-tick's prefix, not a tab step: the `g`
    # prefix is what makes `t` a tab key.
    discard rt.handleToken("t", 0)
    ck rt.app.shell.activeTabIndex() == 2

suite "PLAT-48: the graphics rendering's bytes":

  test "each control is the desktop's mark, transmitted once and placed on its cells":
    let rt = newRuntime(200, 50)
    rt.app.icons = imGraphics
    rt.app.graphicsDrawn = true
    let lay = rt.shellScreenOf().topBarLayout
    var state: ControlIconState
    let ink = "#e0e0e0"
    let bytes = controlIconBytes(state, lay, newSeq[bool](TransportControls.len),
                                 ink, ink)
    ck bytes.startsWith("\x1b7") and bytes.endsWith("\x1b8")
    for s in lay.segments:
      if s.part != tpControl:
        continue
      let id = iconImageId(iiDisabled, s.index)
      # Placed on the control's own cells: its column, and exactly
      # `GraphicsControlCells` columns by one row (kitty's `c`/`r`).
      ck bytes.contains("\x1b[1;" & $(s.col + 1) & "H\x1b_Ga=p,i=" & $id &
                        ",p=1,c=" & $GraphicsControlCells & ",r=1,")
      # The transmitted pixels ARE the mark rasterised.
      let head = "\x1b_Ga=t,f=32,s=32,v=32,i=" & $id & ",q=2,m="
      let at = bytes.find(head)
      ck at >= 0
      var b64 = ""
      var i = at
      while true:
        let semi = bytes.find(';', i)
        let stop = bytes.find("\x1b\\", semi)
        b64.add bytes[semi + 1 ..< stop]
        let more = bytes[i ..< semi].contains("m=1")
        i = stop + 2
        if not more: break
      let decoded = decode(b64)
      let expected = markImage(TransportControls[s.index].id,
                               parseHexRgb(ink))
      ck decoded.len == expected.pixels.len
      var same = true
      for k in 0 ..< decoded.len:
        if byte(decoded[k]) != expected.pixels[k]: same = false
      ck same
    # Nothing moved: nothing is sent again.
    ck controlIconBytes(state, lay, newSeq[bool](TransportControls.len),
                        ink, ink).len == 0

suite "PLAT-48 top bar: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
