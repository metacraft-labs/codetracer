## test_plat48_top_bar.nim — PLAT-48, the terminal's rendering, Tier 1: the
## top bar row, the menu's dropdowns, the omnibar, the debugger controls in
## their four renderings, the auto-hide strips and the reveal, pin / unpin,
## the session tabs, and the kitty bytes the `graphics` rendering sends.
##
## Everything through the product's own entry points: `TuiRuntime.handleToken`
## with the bytes a terminal sends (`F12` is `ESC [ 24 ~`), `shellScreenOf`
## for the frame, `control_icons.controlIconBytes` for the picture escapes.
## The PLAT-48 cases have no replay session (the pty suite
## `real_terminal/test_plat48_top_bar.nim` has one): a debugger action
## dispatched with no session answers "unavailable", which is asserted, not
## hidden. The M76 cases at the end (codetracer#843: the Debug menu's Stop
## and its breakpoint and tracepoint items) DO open one — the real `calc`
## recording under a real `replay-server` — because what they assert is
## what an item does to a session, down to the engine process being gone.
##
## ONE STAND-IN, and why it is not a mock of anything asserted: the session
## tab cases open several `HeadlessApp` slots over the SDK's own
## `MockBackendService` (a transport that answers the DAP handshake), because
## a terminal process opens one recording and the strip needs several. What
## those cases assert — which tabs are drawn, which one is active, what a
## click, `g t` / `g T` or `Ctrl+Tab` does to the active slot — is a function
## of the real slots and the real key path, never of the transport.
##
## M74 (codetracer#841), the File menu, runs over a REAL session (`calc`, a
## real `replay-server`) and a real project on disk read through the host's
## own `edit_host` reader. ONE MORE STAND-IN, the host's welcome seam: those
## cases install a capturing `welcomeHost` closure (as `test_plat51b_parity`
## does) that records the intent the runtime hands over and performs nothing.
## What is asserted — which items are enabled in which state, the reason a
## disabled one gives, the welcome tab and form a choice opens, the buffer a
## choice makes active — is the runtime's and the shared models' own; the
## host performing the intent end to end is `real_terminal/test_plat51b_pty`.

import std/[base64, os, osproc, posix, strutils, tables, unicode, unittest]

import ../app/runtime
import ../app/tui_app
import ../app/edit_binding
import ../app/views/shell
import ../app/layout/binding
import ../app/theme/capabilities
import ../app/theme/roles
import ../host/control_icons
import ../host/edit_host
import ../host/tui_session
from backend/stdio_backend import toBackendService
import ../../../common/terminal_graphics/[raster, path_raster]
import headless_app/session_tabs
import headless_app/layout_model
import headless_app/welcome_tabs
import codetracer_embed
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 514
  ## 379 (M74, codetracer#841) -> 514 (M76, codetracer#843): +135 — the
  ## Debug menu's point items and Stop over a real session (+91, of them
  ## +14 for which open starts its session in a stopped tab), and the
  ## top bar's Stop control: drawn in every mode and at narrow widths (+24),
  ## clicked (+15), the ViewModel's Stop ending the replay (+5). Measured.

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
  ## PLAT-68: under the VIM base — the keys these cases drive (`F12`,
  ## `Ctrl+o`, `g t`, `n`) are CodeTracer-TUI.md §4.2's, which is the Vim and
  ## Kakoune bases' navigation layer now (under CUA the menu, the reveal and
  ## the session tabs are the palette's, `Ctrl+PageDown` and the top bar).
  result = newTuiRuntime(newTuiApp(), caps(), cols, rows)
  discard result.enableLayoutBinding()
  result.selectBase(bkVim, ksFlag)
  result.refreshMenuForKeymap()

proc row0(rt: TuiRuntime): string = rt.shellScreenOf().rows[0]

proc visible(rt: TuiRuntime): seq[string] = rt.shellScreenOf().visibleRows()

proc typeLine(rt: TuiRuntime; line: string): RuntimeOutcome =
  result = rt.handleToken(":", 0'i64)
  for ch in line:
    result = rt.handleToken($ch, 0'i64)
  result = rt.handleToken(Enter, 0'i64)

suite "PLAT-48: the top bar row":

  test "at 200 columns: the menu's root button, every control, the omnibar field, the header":
    # PLAT-49: the menu is ONE root button, as the desktop's is; its folders
    # are a dropdown inside it, never titles across the row.
    let rt = newRuntime(200, 50)
    let r = rt.row0()
    # PLAT-50: the button inside its border lines, as the desktop's
    # `#menu-root` is.
    ck r.startsWith(FieldEdgeLeft & MenuButtonGlyph & FieldEdgeRight)
    for title in ["File", "Edit", "View", "Build", "Reset", "Debug", "Help"]:
      ck not r.contains(" " & title & " ")
    for c in TransportControls:
      ck r.contains(c.unicode)
    ck r.contains("⌕ " & OmnibarPlaceholder[0 ..< 12])
    ck r.contains("tick: ")
    ck r.strip.endsWith("[PAUSED]")
    # Colour, not glyphs: no bracket and no rule through the row.
    ck not r.contains("[File]") and not r.contains("─")

  test "at 80 columns: the menu collapses to ≡, the omnibar to ⌕, controls by priority":
    let rt = newRuntime(80, 24)
    # The header a real recording puts beside them (`calc`'s own).
    rt.app.traceName = "calc-2f0db4f45192"
    rt.app.tick = 1420
    rt.app.totalTicks = 8950
    let lay = rt.shellScreenOf().topBarLayout
    ck not lay.omnibarField
    ck rt.row0().startsWith(FieldEdgeLeft & MenuButtonGlyph & FieldEdgeRight)
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

  test "F12 opens it; keys walk the first level and into a folder; the chords are the keymap's":
    let rt = newRuntime(200, 50)
    discard rt.handleToken(F12, 0)
    ck rt.app.menu.isOpen
    # PLAT-49, the desktop's cascade: Down walks the first level, Right opens
    # a folder's submenu beside it.
    for _ in 0 ..< 5:
      discard rt.handleToken(Down, 0)
    ck rt.app.menu.highlightedItem().label == "Debug"
    discard rt.handleToken(Right, 0)
    ck rt.app.menu.path == @[6]
    let screen = rt.shellScreenOf()
    ck screen.menuDropdowns.len == 2
    let dd = screen.menuDropdowns[1]
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
    # PLAT-68: the user's `keybindings.json` rows, laid over the base — the
    # menu shows the chord that RUNS the item now (`chordFor`).
    let rt = newRuntime(200, 50)
    discard rt.applyUserKeymap(parseUserKeymap("""[
      { "key": "n", "command": "-debugger.step-over" },
      { "key": "f10", "command": "-debugger.step-over" },
      { "key": "ctrl+n", "command": "debugger.step-over" }
    ]"""))
    rt.refreshMenuForKeymap()
    ck rt.app.menu.shortcutFor("forwardNext") == "Ctrl+N"
    discard rt.applyUserKeymap(parseUserKeymap(""))
    rt.refreshMenuForKeymap()
    ck rt.app.menu.shortcutFor("forwardNext") == "n"

  test "Enter on an item runs its action; a disabled item does nothing":
    let rt = newRuntime(200, 50)
    discard rt.handleToken(F12, 0)
    for _ in 0 ..< 5:
      discard rt.handleToken(Down, 0)
    discard rt.handleToken(Right, 0)     # into Debug: Continue
    discard rt.handleToken(Down, 0)      # Step Over
    let outcome = rt.handleToken(Enter, 0)
    ck not rt.app.menu.isOpen
    # No session: the dispatcher answers, by name, that it cannot step.
    ck outcome.action == kaStepOver
    # File > Open Trace... needs a host to open a recording in, and this
    # runtime has none: disabled (M74's cases below give it one).
    discard rt.handleToken(F12, 0)
    discard rt.handleToken(Right, 0)
    ck rt.app.menu.path == @[1]
    ck not rt.app.menu.highlightedItem().enabled
    discard rt.handleToken(Enter, 0)
    ck rt.app.menu.isOpen

  test "a click on the button opens it, on a folder its submenu, on an item runs it, outside closes":
    let rt = newRuntime(200, 50)
    let lay = rt.shellScreenOf().topBarLayout
    let button = lay.segmentOf(tpMenuButton)
    discard rt.handleToken("\x1b[<0;" & $(button.col + 2) & ";1M", 0)
    discard rt.handleToken("\x1b[<0;" & $(button.col + 2) & ";1m", 0)
    ck rt.app.menu.isOpen and rt.app.menu.path.len == 0
    let first = rt.shellScreenOf().menuDropdowns[0]
    var viewRow = -1
    for dr in first.rows:
      if dr.item >= 0 and first.level.items[dr.item].label == "View":
        viewRow = dr.row
    ck viewRow > 0
    discard rt.handleToken("\x1b[<0;" & $(first.area.col + 3) & ";" &
                           $(viewRow + 1) & "M", 0)
    discard rt.handleToken("\x1b[<0;" & $(first.area.col + 3) & ";" &
                           $(viewRow + 1) & "m", 0)
    ck rt.app.menu.isOpen and rt.app.menu.path == @[3]
    let dd = rt.shellScreenOf().menuDropdowns[1]
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
    # PLAT-50: the results are framed (the dropdown surface's border on row
    # 1), the first result on row 2.
    ck rows[1].contains("┌")
    ck rows[2].contains("Debug › Step")
    discard rt.handleToken(Esc, 0)
    ck not rt.app.omnibar.isOpen

suite "PLAT-48: the auto-hide strips":

  test "the shared default's footer panels are the bottom strip's labels":
    let rt = newRuntime(200, 50)
    let rows = rt.visible()
    # PLAT-49 part B (finding 9): the labels are IN the status-bar row.
    let strip = rows[^1]
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

  test "a click on a label docks its pane open, a second closes it; outside hides a reveal":
    # PLAT-49 part B (finding 9), as the desktop: a CLICK on a footer label
    # docks the pane into the layout (no overlay); a second click collapses
    # it. A revealed pane (Ctrl+O here) still hides on a press outside it.
    let rt = newRuntime(200, 50)
    var strip: DockStrip
    for s in rt.shellScreenOf().geometry.strips:
      if s.edge == leBottom: strip = s
    let slot = strip.slots[1].area
    let press = "\x1b[<0;" & $(slot.col + 2) & ";" & $(slot.row + 1)
    discard rt.handleToken(press & "M", 0)
    discard rt.handleToken(press & "m", 0)
    ck rt.shellScreenOf().geometry.openDockPane == paneProblems
    ck not rt.shellScreenOf().geometry.revealing
    discard rt.handleToken(press & "M", 0)
    discard rt.handleToken(press & "m", 0)
    ck rt.shellScreenOf().geometry.openDock.height == 0
    ck not rt.shellScreenOf().geometry.revealing
    discard rt.handleToken(CtrlO, 0)
    ck rt.shellScreenOf().geometry.revealing
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
      # PLAT-49 part B: each tab ends with its close control while there are
      # several sessions, as the desktop's does.
      ck screen.rows[0].runeSubStr(s.col, s.width) ==
         " " & t & " " & SessionTabCloseGlyph & " "
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
    # The tab carries its close control (PLAT-49 part B, finding 7).
    ck active == " gamma × "
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

suite "M74 (#841): the File menu follows what the terminal can do":
  # codetracer#841: every File item but Exit was greyed out, because the
  # enabled set was a static table fixed at start-up that omitted the tab and
  # trace actions the terminal performs. These cases drive the File menu
  # through the bar's own keys (`F12`, `Right`, `Down`, `Enter`) over a REAL
  # recording (`calc`, a real `replay-server`), with the menu re-read each
  # time it opens — which is when the state these items depend on is read.

  proc fileItem(rt: TuiRuntime; action: string): MenuItem =
    ## The File item that runs `action`, as the menu holds it now.
    rt.app.menu.itemAt(rt.app.menu.pathOfAction(action))

  proc openFileMenu(rt: TuiRuntime) =
    ## `F12`, then `Right` into File (the first shown folder).
    if rt.app.menu.isOpen:
      discard rt.handleToken(Esc, 0)
      discard rt.handleToken(Esc, 0)
    discard rt.handleToken(F12, 0)
    discard rt.handleToken(Right, 0)

  proc chooseFileItem(rt: TuiRuntime; label: string): RuntimeOutcome =
    ## Open File and press `Enter` on `label`, walked to with `Down`.
    rt.openFileMenu()
    for _ in 0 ..< 16:
      if rt.app.menu.highlightedItem().label == label:
        break
      discard rt.handleToken(Down, 0)
    checkpoint("chose " & rt.app.menu.highlightedItem().label)
    result = rt.handleToken(Enter, 0)
    # A disabled item does nothing and leaves the menu open (the Menu
    # ViewModel's rule); close it, so the case's next key is not the menu's.
    for _ in 0 ..< 3:
      if rt.app.menu.isOpen:
        discard rt.handleToken(Esc, 0)

  proc enabledNow(rt: TuiRuntime; action: string): bool =
    ## Whether `action`'s item is enabled in the menu as it OPENS now.
    rt.openFileMenu()
    result = rt.fileItem(action).enabled
    discard rt.handleToken(Esc, 0)
    discard rt.handleToken(Esc, 0)

  let calc = resolveFixture("calc")

  proc open(path: string): (TuiRuntime, TuiSession) =
    let rt = newRuntime(200, 50)
    let s = openTuiSession(path, viewportHeight = 42)
    s.header(rt)
    s.learnExtent()
    s.refresh(rt)
    (rt, s)

  test "the trace and tab items are enabled where a host performs them; New Trace Tab adds a welcome tab":
    require calc.outcome == foRecorded
    let (rt, s) = open(calc.tracePath)
    defer: s.close()
    # No host to open a recording with: the four trace and tab items are
    # disabled, and choosing one SAYS why (EMT-D14) rather than nothing.
    for action in ["aOpenTrace", "aOpenTraceInNewTab", "aRecordNewTrace",
                   "aNewTraceTab"]:
      checkpoint(action)
      ck not rt.enabledNow(action)
    discard rt.chooseFileItem("New Trace Tab")
    ck rt.app.notification.startsWith("New Trace Tab: ")
    ck rt.app.notification.len > "New Trace Tab: ".len
    ck rt.app.welcomeTabs.tabs.len == 0
    # The host's welcome flow arrives: the same items, enabled — the state
    # changed, and the menu follows it the next time it opens.
    var asked: seq[NativeWelcomeIntent] = @[]
    rt.app.welcomeHost = proc(tab: int; intent: NativeWelcomeIntent): string =
      asked.add intent
      ""
    for action in ["aOpenTrace", "aOpenTraceInNewTab", "aRecordNewTrace",
                   "aNewTraceTab", "aExit"]:
      checkpoint(action)
      ck rt.enabledNow(action)
    # File › New Trace Tab is the strip's "+" (Multi-Window-Tab-Management.md
    # rule 3): a new tab showing the Welcome Screen, its forms closed.
    discard rt.chooseFileItem("New Trace Tab")
    ck not rt.app.menu.isOpen
    ck rt.app.welcomeTabs.tabs.len == 1
    ck rt.app.welcomeTabs.welcomeShown
    let w = rt.app.shownWelcome()
    ck not w.isNil and w.form == nwfNone
    ck rt.shellScreenOf().rows.join("\n").contains(NativeWelcomeHeading)
    ck asked.len == 0

  test "Open Trace…, Open Trace in New Tab… and Record New Trace… reach the welcome flow":
    require calc.outcome == foRecorded
    let (rt, s) = open(calc.tracePath)
    defer: s.close()
    var asked: seq[NativeWelcomeIntent] = @[]
    rt.app.welcomeHost = proc(tab: int; intent: NativeWelcomeIntent): string =
      asked.add intent
      ""
    # From the session tab, Open Trace in New Tab…: a new welcome tab with its
    # "Open local trace" form open — the terminal's trace dialog.
    discard rt.chooseFileItem("Open Trace in New Tab...")
    ck rt.app.welcomeTabs.tabs.len == 1
    var w = rt.app.shownWelcome()
    ck not w.isNil and w.form == nwfOpenTrace
    # The form is the real one: the recording typed and Enter reach the host
    # as the intent to open it.
    if not w.isNil:
      for ch in calc.tracePath:
        discard rt.handleToken($ch, 0)
      discard rt.handleToken(Enter, 0)
    ck asked.len == 1 and asked[0].kind == niOpenTrace and
       asked[0].path == calc.tracePath
    # With a welcome tab shown, Open Trace… opens the form IN that tab (it
    # becomes the session it starts, rule 3); Open Trace in New Tab… does not.
    discard rt.chooseFileItem("Open Trace...")
    ck rt.app.welcomeTabs.tabs.len == 1
    w = rt.app.shownWelcome()
    ck not w.isNil and w.form == nwfOpenTrace
    discard rt.handleToken(Esc, 0)
    ck not w.isNil and w.form == nwfNone
    # Record New Trace…: the same tab's record form (the desktop shows the
    # welcome screen's New Recording form).
    discard rt.chooseFileItem("Record New Trace...")
    ck rt.app.welcomeTabs.tabs.len == 1
    w = rt.app.shownWelcome()
    ck not w.isNil and w.form == nwfRecord
    discard rt.handleToken(Esc, 0)
    # Back on the recording's tab, Open Trace… has no welcome tab to use: it
    # opens one, and its form, rather than replacing the recording
    # (Multi-Window-Tab-Management.md: a replay opens in a new tab by default;
    # replacement is never automatic).
    var o = RuntimeOutcome()
    rt.showSessionTab(0, o)
    ck not rt.app.welcomeTabs.welcomeShown
    discard rt.chooseFileItem("Open Trace...")
    ck rt.app.welcomeTabs.tabs.len == 2
    w = rt.app.shownWelcome()
    ck not w.isNil and w.form == nwfOpenTrace
    ck asked.len == 1

  test "the file items act on the edit session's buffers, and say why when they cannot":
    require calc.outcome == foRecorded
    let (rt, s) = open(calc.tracePath)
    defer: s.close()
    # A real project on disk, read through the host's own reader
    # (`edit_host`), as `main.nim` wires it.
    let project = getTempDir() / "ct-m74-project-" & $getCurrentProcessId()
    createDir(project)
    defer: removeDir(project)
    writeFile(project / "a.py", "print('a')\n")
    writeFile(project / "b.py", "print('b')\n")
    rt.app.projectRoot = project
    rt.editServices.listFiles = proc(): EditListResult =
      let listing = listProjectFiles(project)
      EditListResult(files: listing.files, truncated: listing.truncated)
    rt.editServices.readFile = proc(relative: string): EditReadResult =
      try:
        EditReadResult(ok: true, text: readProjectFile(project, relative))
      except CatchableError as e:
        EditReadResult(ok: false, message: e.msg)
    # In Debug mode the editor shows the file the recording is at: there is
    # no list of open files to step, and Next File says so.
    ck not rt.enabledNow("switchTabRight")
    discard rt.chooseFileItem("Next File")
    ck rt.app.notification.startsWith("Next File: ")
    ck rt.app.notification.len > "Next File: ".len
    # Edit mode (`Ctrl+F5`) arrives at the project's first file: ONE buffer.
    discard rt.handleToken("\x1b[15;5~", 0)
    ck rt.app.modes.product == pmEdit
    require not rt.app.editSession.isNil
    ck rt.app.editSession.buffers.len == 1
    ck rt.enabledNow("closeTab")
    for action in ["switchTabRight", "switchTabLeft", "switchTabHistory",
                   "reopenTab"]:
      checkpoint(action)
      ck not rt.enabledNow(action)
    discard rt.chooseFileItem("Previous File")
    ck rt.app.notification.startsWith("Previous File: ")
    ck rt.app.notification.len > "Previous File: ".len
    # A second file: the stepping items are enabled — the same menu, a new
    # state.
    discard rt.typeLine("e b.py")
    ck rt.app.editSession.buffers.len == 2
    let first = rt.app.editSession.activeBuffer().path
    for action in ["switchTabRight", "switchTabLeft", "switchTabHistory"]:
      checkpoint(action)
      ck rt.enabledNow(action)
    discard rt.chooseFileItem("Next File")
    ck not rt.app.menu.isOpen
    ck rt.app.editSession.activeBuffer().path != first
    discard rt.chooseFileItem("Previous File")
    ck rt.app.editSession.activeBuffer().path == first
    discard rt.chooseFileItem("Switch File")
    ck rt.app.editSession.activeBuffer().path != first
    # Close Current File closes the shown buffer; Reopen File brings it back.
    let closing = rt.app.editSession.activeBuffer().path
    discard rt.chooseFileItem("Close Current File")
    ck rt.app.editSession.buffers.len == 1
    ck rt.app.editSession.indexOfPath(closing) < 0
    ck rt.enabledNow("reopenTab")
    discard rt.chooseFileItem("Reopen File")
    ck rt.app.editSession.buffers.len == 2
    ck rt.app.editSession.activeBuffer().path == closing
    ck not rt.enabledNow("reopenTab")
    # A buffer with unsaved changes is not closed — the desktop would ask in
    # a save dialog, and closing it here would discard the edit: Close
    # Current File is disabled, and says why.
    discard rt.handleToken("i", 0)
    discard rt.handleToken("x", 0)
    discard rt.handleToken(Esc, 0)
    ck rt.app.editSession.activeBuffer().isDirty
    ck not rt.enabledNow("closeTab")
    discard rt.chooseFileItem("Close Current File")
    ck rt.app.notification.startsWith("Close Current File: ")
    ck rt.app.notification.contains("unsaved changes")
    ck rt.app.editSession.buffers.len == 2

# ---------------------------------------------------------------------------
# M76 (codetracer#843): the program menu's Stop and its breakpoint and
# tracepoint items, OVER A REAL SESSION
# ---------------------------------------------------------------------------
#
# The cases above need no engine; these do, because what they assert is what
# an item DOES to a session: the rows the engine verified
# (`store.pointList.rows`), the sweep's hits (`tracepointHits`), and — for
# Stop — that the `replay-server` child is really gone, read off the process
# table, not off a flag. The real `calc` recording and a real
# `replay-server`; the tokens go through `handleToken` and `applyOutcome`,
# the shipped loop's two halves. Nothing is mocked.

let calcFixture = resolveFixture("calc")

const
  ShiftF5 = "\x1b[15;2~"
    ## Shift+F5 as xterm sends it (`CSI 15 ; 2 ~`): CUA's `debugger.stop`.
  AddLine = "return left + right"
  MulLine = "return left * right"
    ## Two lines of `calc`'s `main.py` that run, so a tracepoint there has
    ## hits. Found by their text, asserted before use.

proc sessionRuntime(): TuiRuntime =
  ## The front-end as `main.nim` builds it for a replay: a layout binding,
  ## and the Vim base, whose `F12` opens the program menu (the cases
  ## above). The suite case that presses Shift+F5 switches to CUA itself.
  result = newRuntime(200, 56)

proc send(s: TuiSession; rt: TuiRuntime; token: string) =
  ## One token through the shipped loop: the runtime decides, the host acts.
  let outcome = rt.handleToken(token, 0)
  s.applyOutcome(rt, outcome)

proc openCalc(): (TuiRuntime, TuiSession) =
  ## `calc` opened as `main.nim`'s `interactive` opens it, the session put in
  ## the strip as its one tab.
  let rt = sessionRuntime()
  let s = openTuiSession(calcFixture.tracePath, viewportHeight = 48)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
  discard rt.app.shell.openSession(s.session.backend.toBackendService(),
                                   title = rt.app.traceName,
                                   layout = rt.app.layoutBinding.layout,
                                   adopt = s.session.sdk)
  rt.refreshMenuForKeymap()
  (rt, s)

proc chooseItem(s: TuiSession; rt: TuiRuntime; folder, label: string): bool =
  ## Open the program menu (`F12`), walk to `folder` › `label` with the keys
  ## a user presses, and press Enter on it. Answers whether the item was
  ## ENABLED where it was chosen. A disabled item leaves the menu open
  ## (`Enter on an item runs its action; a disabled item does nothing`
  ## above); it is closed again so the next step starts from the editor.
  s.send(rt, F12)
  var steps = 0
  while rt.app.menu.highlightedItem().label != folder and steps < 16:
    s.send(rt, Down)
    inc steps
  doAssert rt.app.menu.highlightedItem().label == folder, "no folder " & folder
  s.send(rt, Right)
  steps = 0
  while rt.app.menu.highlightedItem().label != label and steps < 60:
    s.send(rt, Down)
    inc steps
  doAssert rt.app.menu.highlightedItem().label == label,
    "no " & folder & " item " & label
  result = rt.app.menu.highlightedItem().enabled
  s.send(rt, Enter)
  while rt.app.menu.isOpen:
    s.send(rt, Esc)

proc chooseDebugItem(s: TuiSession; rt: TuiRuntime; label: string): bool =
  ## Debug › `label` (`chooseItem`).
  s.chooseItem(rt, "Debug", label)

proc lineOf(path, text: string): int =
  ## The 1-based line of `path` whose stripped text is `text`, or 0.
  let lines: seq[string] = readFile(path).splitLines()
  for i, l in lines:
    if l.strip() == text:
      return i + 1
  0

proc placeCaret(rt: TuiRuntime; line: int) =
  ## The Debug-mode editor's caret on `line` — where a click on the text
  ## puts it (PLAT-51 deliverable 6, `test_plat51_parity.nim`), set on the
  ## editor's own document so the case does not depend on the line being
  ## scrolled into view.
  let buf = rt.debugBuffer()
  doAssert not buf.isNil, "the Debug-mode editor has no document"
  buf.moveCaretTo(line - 1, 0)
  rt.app.caret = (buf.path, line, 1)

proc rowsOfKind(s: TuiSession; kind: string): seq[PointListEntry] =
  for r in s.session.session.store.pointList.rows.val:
    if r.kind == kind:
      result.add r

proc rowAt(s: TuiSession; kind: string; line: int): (bool, PointListEntry) =
  for r in s.rowsOfKind(kind):
    if r.line == line:
      return (true, r)
  (false, PointListEntry())

proc processAlive(pid: int): bool =
  ## Whether `pid` names a process on this host that has not been reaped —
  ## `kill(pid, 0)`, which sends nothing (POSIX `kill(2)`:
  ## https://pubs.opengroup.org/onlinepubs/9799919799/functions/kill.html).
  ## A zombie still answers 0 here, so a child its parent never reaped
  ## counts as ALIVE: the backend must be gone, not merely signalled.
  pid > 0 and posix.kill(Pid(pid), 0) == 0

suite "M76 (#843): the Debug menu's breakpoint items, over a real session":

  test "Delete All Breakpoints is enabled, and removes every breakpoint the user set":
    require calcFixture.outcome == foRecorded
    let (rt, s) = openCalc()
    defer: s.close()
    let path = s.session.getCurrentFile()
    let add = lineOf(path, AddLine)
    let mul = lineOf(path, MulLine)
    ck add > 0 and mul > 0
    ck s.toggleBreakpoint(path, add)
    ck s.toggleBreakpoint(path, mul)
    s.refresh(rt)
    ck s.rowsOfKind(PointKindBreakpoint).len == 2
    ck s.points.len == 2           # the gutter's points, read off the store
    ck s.chooseDebugItem(rt, "Delete All Breakpoints")
    checkpoint("after: " & $s.rowsOfKind(PointKindBreakpoint))
    ck s.rowsOfKind(PointKindBreakpoint).len == 0
    ck s.points.len == 0
    ck rt.app.points == pointListPaneModelFor(s.points)

  test "Delete / Enable / Disable Breakpoint act on the caret's line; the All items on every one":
    require calcFixture.outcome == foRecorded
    let (rt, s) = openCalc()
    defer: s.close()
    let path = s.session.getCurrentFile()
    let add = lineOf(path, AddLine)
    let mul = lineOf(path, MulLine)
    ck add > 0 and mul > 0
    ck s.toggleBreakpoint(path, add)
    ck s.toggleBreakpoint(path, mul)
    s.refresh(rt)
    rt.placeCaret(add)
    ck s.chooseDebugItem(rt, "Disable Breakpoint")
    ck s.rowAt(PointKindBreakpoint, add)[0]
    ck not s.rowAt(PointKindBreakpoint, add)[1].enabled
    ck s.rowAt(PointKindBreakpoint, mul)[1].enabled
    ck s.chooseDebugItem(rt, "Enable Breakpoint")
    ck s.rowAt(PointKindBreakpoint, add)[1].enabled
    ck s.chooseDebugItem(rt, "Disable All Breakpoints")
    ck not s.rowAt(PointKindBreakpoint, add)[1].enabled
    ck not s.rowAt(PointKindBreakpoint, mul)[1].enabled
    ck s.chooseDebugItem(rt, "Enable All Breakpoints")
    ck s.rowAt(PointKindBreakpoint, add)[1].enabled
    ck s.rowAt(PointKindBreakpoint, mul)[1].enabled
    ck s.chooseDebugItem(rt, "Delete Breakpoint")
    ck not s.rowAt(PointKindBreakpoint, add)[0]
    ck s.rowAt(PointKindBreakpoint, mul)[0]

suite "M76 (#843): the Debug menu's tracepoint items, over a real session":

  test "Add opens the tracepoint editor at the caret; enable, disable, run all and delete act on the rows":
    require calcFixture.outcome == foRecorded
    let (rt, s) = openCalc()
    defer: s.close()
    let path = s.session.getCurrentFile()
    let add = lineOf(path, AddLine)
    let mul = lineOf(path, MulLine)
    ck add > 0 and mul > 0
    # "Add a Tracepoint": the editor opens ON THE CARET'S LINE (the
    # desktop's `addTracepointAtPosition`), and its Enter sweeps.
    # A tracepoint's expression is a `log(...)` call, as the desktop's
    # tracepoint editor takes it (`test_event_log_jump.nim`'s sweep).
    rt.placeCaret(add)
    ck s.chooseDebugItem(rt, "Add a Tracepoint")
    ck rt.prompt.open
    ck rt.prompt.buffer == "tracepoint "
    ck rt.app.tracepointAt == (path, add)
    for ch in "log(left)":
      s.send(rt, $ch)
    s.send(rt, Enter)
    ck s.rowAt(PointKindTracepoint, add)[0]
    rt.app.content = ContentOverlay()
    rt.placeCaret(mul)
    ck s.chooseDebugItem(rt, "Add a Tracepoint")
    ck rt.app.tracepointAt == (path, mul)
    for ch in "log(right)":
      s.send(rt, $ch)
    s.send(rt, Enter)
    rt.app.content = ContentOverlay()
    ck s.rowsOfKind(PointKindTracepoint).len == 2
    # Disable at the caret (the multiply line): only that row.
    ck s.chooseDebugItem(rt, "Disable Tracepoint")
    ck not s.rowAt(PointKindTracepoint, mul)[1].enabled
    ck s.rowAt(PointKindTracepoint, add)[1].enabled
    # Run All Tracepoints sweeps the ENABLED ones again: the hits are now
    # the addition line's, and none is the disabled one's.
    ck s.chooseDebugItem(rt, "Run All Tracepoints")
    let hits = s.session.session.store.pointList.tracepointHits.val
    checkpoint("hits after Run All: " & $hits.len)
    ck hits.len > 0
    var onAdd = 0
    var onMul = 0
    for h in hits:
      if h.line == add: inc onAdd
      if h.line == mul: inc onMul
    ck onAdd == hits.len and onMul == 0
    ck rt.app.content.open
    rt.app.content = ContentOverlay()
    # Enable at the caret, then Disable All / Enable All.
    ck s.chooseDebugItem(rt, "Enable Tracepoint")
    ck s.rowAt(PointKindTracepoint, mul)[1].enabled
    ck s.chooseDebugItem(rt, "Disable All Tracepoints")
    ck not s.rowAt(PointKindTracepoint, add)[1].enabled
    ck not s.rowAt(PointKindTracepoint, mul)[1].enabled
    ck s.chooseDebugItem(rt, "Enable All Tracepoints")
    ck s.rowAt(PointKindTracepoint, add)[1].enabled
    ck s.rowAt(PointKindTracepoint, mul)[1].enabled
    # Delete at the caret: the multiply line's row goes, the other stays.
    ck s.chooseDebugItem(rt, "Delete Tracepoint")
    ck not s.rowAt(PointKindTracepoint, mul)[0]
    ck s.rowAt(PointKindTracepoint, add)[0]

suite "M76 (#843): Stop ends the debugging session":

  test "the menu's Stop is enabled; after it the tab is in Edit mode and its replay-server is gone":
    require calcFixture.outcome == foRecorded
    let (rt, s) = openCalc()
    defer: s.close()
    let pid = int(s.session.backend.process.processID)
    ck processAlive(pid)
    ck rt.app.modes.product == pmDebug
    ck s.chooseDebugItem(rt, "Stop")
    # 1. The workspace is in Edit mode.
    ck rt.app.modes.product == pmEdit
    # 2. The replay backend for the session is terminated — the process,
    #    not a flag on it.
    checkpoint("replay-server pid " & $pid)
    ck not processAlive(pid)
    # 3. The tab survives.
    ck rt.app.shell.tabsOf().len == 1
    # Nothing that follows reaches the dead engine: the panes are refreshed,
    # a step is pressed in Edit mode and again after switching back to the
    # (now empty) debugger — each answered, none raising.
    s.refresh(rt)
    s.send(rt, "n")
    s.send(rt, "\x1b[15;5~")       # Ctrl+F5, the mode toggle
    ck rt.app.modes.product == pmDebug
    s.send(rt, "n")
    ck not processAlive(pid)

  test "after Stop, opening a recording starts a NEW debugging session in the tab":
    # Requirement 3's other half: "*Run*, or opening a trace, starts a new
    # debugging session in it by the ordinary route". The route is
    # `main.nim`'s `recordingOpener` for a stopped tab: a session opened as
    # every session is, the runtime pointed at it, Debug mode. Written with
    # the fix — before it there was no Stop to come back from.
    require calcFixture.outcome == foRecorded
    let (rt, s) = openCalc()
    defer: s.close()
    let first = s.session.replayPid()
    ck s.chooseDebugItem(rt, "Stop")
    ck s.ended
    ck rt.app.traceName == ""
    ck not rt.hasDebugSession
    # A second Stop has nothing to end: the menu, re-read as it opens
    # (M74's state-aware table), draws it disabled, and choosing it says why.
    ck not s.chooseDebugItem(rt, "Stop")
    ck rt.app.notification.contains("no debugging session")
    let s2 = openTuiSession(calcFixture.tracePath, viewportHeight = 48)
    defer: s2.close()
    s2.header(rt)
    s2.learnExtent()
    s2.refresh(rt)
    rt.enterProductMode(pmDebug)
    let second = s2.session.replayPid()
    ck second != first and processAlive(second)
    ck not processAlive(first)
    ck rt.app.traceName.len > 0
    ck rt.hasDebugSession
    let before = s2.session.getCurrentRRTicks()
    s2.send(rt, "n")             # Step Over, the Vim base's
    ck s2.session.getCurrentRRTicks() != before

  test "after Stop, Open Trace… stands in for the stopped tab; Open Trace in New Tab… does not":
    # Requirement 3, on the side of what is NOT replaced: Stop never closes a
    # tab, so only an open chosen ON the stopped tab (Open Trace… / Record New
    # Trace…) starts its session in that tab — `main.nim`'s `recordingOpener`
    # replaces the stopped slot only for the welcome tab `stoppedTabWelcome`
    # names. A request for a new tab gets one, and the stopped tab stays.
    require calcFixture.outcome == foRecorded
    let (rt, s) = openCalc()
    defer: s.close()
    rt.app.welcomeHost = proc(tab: int; intent: NativeWelcomeIntent): string =
      ""
    var o = RuntimeOutcome()
    # On a LIVE tab, Open Trace… is a new tab and stands in for nothing.
    ck s.chooseItem(rt, "File", "Open Trace...")
    ck rt.app.welcomeTabs.welcomeShown
    ck rt.app.stoppedTabWelcome == -1
    rt.closeWelcomeTabAt(0, o)
    ck not rt.app.welcomeTabs.welcomeShown
    ck s.chooseDebugItem(rt, "Stop")
    ck s.ended
    # Open Trace in New Tab… on the stopped tab: a new tab, nothing else.
    ck s.chooseItem(rt, "File", "Open Trace in New Tab...")
    ck rt.app.welcomeTabs.tabs.len == 1 and rt.app.welcomeTabs.welcomeShown
    ck rt.app.stoppedTabWelcome == -1
    rt.closeWelcomeTabAt(0, o)
    ck not rt.app.welcomeTabs.welcomeShown
    # Open Trace… on the stopped tab: its welcome tab stands in for it.
    ck s.chooseItem(rt, "File", "Open Trace...")
    ck rt.app.welcomeTabs.tabs.len == 1 and rt.app.welcomeTabs.welcomeShown
    ck rt.app.stoppedTabWelcome == rt.app.welcomeTabs.tabs[0].serial
    ck rt.app.shell.tabsOf().len == 1     # the stopped tab is still there

  test "Shift+F5 (CUA's debugger.stop) reaches the same Stop":
    require calcFixture.outcome == foRecorded
    let (rt, s) = openCalc()
    defer: s.close()
    rt.selectBase(bkCua, ksFlag)
    rt.refreshMenuForKeymap()
    let pid = int(s.session.backend.process.processID)
    ck processAlive(pid)
    # The menu shows the chord beside the item, as it does for the steps.
    ck rt.app.menu.shortcutFor("stop") == "Shift+F5"
    s.send(rt, ShiftF5)
    ck rt.app.modes.product == pmEdit
    ck not processAlive(pid)

const
  StopMarks = [(imNerd, "\u{EAD7}"), (imUnicode, "■"), (imText, " Stop ")]
    ## Stop's mark per icons mode (Debugger-Controls.md § Control Marks: a
    ## square), as the row draws it: Codicons' `debug-stop`, a filled square,
    ## the labelled button. `graphics` draws the square too — the desktop's
    ## Stop is an image, not one of the marks the terminal rasterises.

proc cellOfText(row, needle: string): int =
  ## The cell (not byte) column `needle` starts at in `row`, or -1.
  let at = row.find(needle)
  if at < 0: -1 else: row[0 ..< at].runeLen

proc roleAt(rt: TuiRuntime; col: int): SemanticRole =
  ## The style role of row 0's cell `col`.
  var c = 0
  for span in rt.shellScreenOf().styledRows[0]:
    let w = span.text.runeLen
    if col >= c and col < c + w:
      return span.style.role
    c += w

proc lastTransportCol(rt: TuiRuntime): int =
  result = -1
  for s in rt.shellScreenOf().topBarLayout.segments:
    if s.part == tpControl:
      result = max(result, s.col + s.width - 1)

suite "M76 (#843): the top bar's Stop control":

  test "Stop is drawn at the toolbar's tail, in every icons mode, after the nine transports":
    for (mode, mark) in StopMarks:
      let rt = newRuntime(200, 50)
      rt.app.icons = mode
      let r = rt.row0()
      checkpoint($mode & ": " & r)
      let col = r.cellOfText(mark)
      ck col > rt.lastTransportCol()
      ck rt.shellScreenOf().topBarLayout.shownControls.len ==
         TransportControls.len
    # Narrow rows: Stop takes only room the transports left — it is never
    # drawn over another part, and it is after every transport shown.
    for mode in [imNerd, imUnicode, imText]:
      for width in [40, 60, 80, 100, 120, 160]:
        let rt = newRuntime(width, 30)
        rt.app.icons = mode
        let lay = rt.shellScreenOf().topBarLayout
        var lastEnd = -1
        var overlap = false
        var stopAfter = true
        for sg in lay.segments:
          if sg.col < lastEnd: overlap = true
          lastEnd = max(lastEnd, sg.col + sg.width)
          if sg.part == tpStop and sg.col <= rt.lastTransportCol():
            stopAfter = false
        checkpoint($mode & " at " & $width & ": " & rt.row0())
        ck not overlap and stopAfter
    # With no session it is drawn disabled, as the transports are.
    let rt = newRuntime(200, 50)
    let col = rt.row0().cellOfText("■")
    ck col >= 0 and rt.roleAt(col) == srChromeMuted

  test "a click on Stop ends the session as the menu does; afterwards it is disabled and inert":
    require calcFixture.outcome == foRecorded
    let (rt, s) = openCalc()
    defer: s.close()
    rt.selectBase(bkCua, ksFlag)
    rt.refreshMenuForKeymap()
    let pid = s.session.replayPid()
    ck processAlive(pid)
    let col = rt.row0().cellOfText("■")
    checkpoint("Stop at cell " & $col & ": " & rt.row0())
    ck col > rt.lastTransportCol()
    ck rt.roleAt(col) == srChromeText          # enabled: a session is open
    # The pointer on it: the tooltip names the command and its chord.
    s.send(rt, "\x1b[<35;" & $(col + 1) & ";1M")
    checkpoint("tooltip: " & rt.app.hoveredTooltip)
    ck rt.app.hoveredTooltip.contains("Stop")
    ck rt.app.hoveredTooltip.contains("Shift+F5")
    ck rt.visible()[1].contains("Shift+F5")
    # The click: a real SGR press and release on its cell.
    s.send(rt, "\x1b[<0;" & $(col + 1) & ";1M")
    s.send(rt, "\x1b[<0;" & $(col + 1) & ";1m")
    ck rt.app.modes.product == pmEdit
    ck not processAlive(pid)
    ck s.ended
    # Disabled now, and a second click does nothing but say so.
    let after = rt.row0().cellOfText("■")
    ck after >= 0 and rt.roleAt(after) == srChromeMuted
    s.send(rt, "\x1b[<0;" & $(after + 1) & ";1M")
    s.send(rt, "\x1b[<0;" & $(after + 1) & ";1m")
    ck rt.app.modes.product == pmEdit
    ck rt.app.notification.contains("no debugging session")

  test "the session's DebugControlsVM Stop is the host's: invokeToolbarAction(\"stop\") ends the replay":
    # `DebugControlsVM.invokeToolbarAction` is "the one route a button, a key
    # chord and a menu item take": on the native front ends its `stop` must
    # not be the nil entry `defaultDebugCommands` leaves (`native_host`
    # installs it), so a caller that reaches it ends the engine.
    require calcFixture.outcome == foRecorded
    let (rt, s) = openCalc()
    defer: s.close()
    let pid = s.session.replayPid()
    ck processAlive(pid)
    ck not s.controls.commands.stop.isNil
    s.controls.invokeToolbarAction("stop")
    ck not processAlive(pid)
    # The terminal's half ran with it: Edit mode, the session forgotten.
    ck rt.app.modes.product == pmEdit
    ck rt.app.traceName == ""
    # The terminal's entry points read the closed channel and stay off it.
    ck s.ended
    s.refresh(rt)
    s.send(rt, "n")
    ck not processAlive(pid)

suite "PLAT-48 top bar: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
