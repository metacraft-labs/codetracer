## test_plat64_operation_tables.nim — the terminal's operation tables
## (Input-Routing-And-Keymaps.md §3) through the same dispatch a key runs: each
## entry reaches its procedure, an overlay's table holds only while it is open, a
## disabled operation is inert and says why (IR-6), and one this front-end does
## not perform says so.
##
## The top bar's elements and a docked pane's label are pressed with real SGR
## reports: a plain press does what it always did, a user's row takes it over.
##
## No mocks: the shipped runtime over its real ViewModels, with no terminal. The
## Video Player's suite records the acts its host is asked for; its header says
## why that one stand-in is not a mock. The top bar's suite gives the runtime a
## welcome host that starts nothing: the strip offers its "+" only to a host
## that can open a tab, and what is asserted is the tab the press adds and
## which operation a press reaches, both before the host would be asked.

import std/[strutils, tempfiles, unittest]

import codetracer_embed

import ../app/runtime
import ../app/theme/capabilities
import ../app/tui_app
import ../app/views/frame_viewer
import ../app/views/visual_replay_panes
import ../app/views/[shell, top_bar]
import ../app/layout/binding
import ../../headless_app/layout_model
import ../../viewmodel/keymap/[keymap_router, user_keymap]
import ../../viewmodel/viewmodels/video_player_vm
from ../../viewmodel/viewmodels/native_welcome import NativeWelcomeIntent

const
  Cols = 140
  Rows = 40

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc runtime(): TuiRuntime =
  let app = newTuiApp()
  app.projectRoot = createTempDir("ct-plat64-tables-", "")
  app.modes = initModeRegister(pmEdit)
  result = newTuiRuntime(app, caps(), Cols, Rows)
  discard result.enableLayoutBinding()

suite "IR-6: an operation that cannot run says why":
  test "Stop with no session is inert, and gives the reason":
    let rt = runtime()
    discard rt.runNamedOperation("debugger.stop", "", 0)
    check "Stop" in rt.app.notification
    check not rt.hasDebugSession

  test "Toggle Read-Only with no document gives the reason":
    let rt = runtime()
    discard rt.runNamedOperation("editor.toggle-read-only", "", 0)
    check "no document" in rt.app.notification

  test "an operation this front-end does not perform says so":
    let rt = runtime()
    discard rt.runNamedOperation("video-player.rewind", "", 0)
    check "not available in the terminal" in rt.app.notification

  test "an element's operation from a key has no element, and says so":
    let rt = runtime()
    discard rt.runNamedOperation("calltrace.go-to-call", "", 0)
    check "not available in the terminal" in rt.app.notification

suite "§3: an entry reaches its procedure":
  test "the program menu's own operations move it":
    let rt = runtime()
    discard rt.runNamedOperation("menu.open", "", 0)
    check rt.app.menu.isOpen
    discard rt.runNamedOperation("menu.enter-folder", "", 0)
    let first = rt.app.menu.highlightedItem().label
    discard rt.runNamedOperation("menu.focus-next", "", 0)
    check rt.app.menu.highlightedItem().label != first
    discard rt.runNamedOperation("menu.focus-previous", "", 0)
    check rt.app.menu.highlightedItem().label == first
    discard rt.runNamedOperation("menu.close", "", 0)
    discard rt.runNamedOperation("menu.close", "", 0)
    check not rt.app.menu.isOpen

  test "the menu's table holds only while it is open":
    let rt = runtime()
    discard rt.runNamedOperation("menu.focus-next", "", 0)
    check "not available in the terminal" in rt.app.notification
    check not rt.app.menu.isOpen

  test "the palette's table holds its whole namespace while it is open":
    let rt = runtime()
    discard rt.runNamedOperation("palette.open-commands", "", 0)
    check rt.app.omnibar.isOpen
    let query = rt.app.omnibar.query
    discard rt.runNamedOperation("palette.quick-open-file", "", 0)
    check rt.app.omnibar.isOpen
    check rt.app.omnibar.query == query
    discard rt.runNamedOperation("palette.close", "", 0)
    check not rt.app.omnibar.isOpen

  test "a toggle is its own inverse through the table":
    let rt = runtime()
    let before = rt.tabMovesFocus
    discard rt.runNamedOperation("editor.toggle-tab-moves-focus", "", 0)
    check rt.tabMovesFocus != before
    discard rt.runNamedOperation("editor.toggle-tab-moves-focus", "", 0)
    check rt.tabMovesFocus == before

suite "the Video Player's keys and presses reach its operations":
  # The pane is placed and focused as the session places it; the player is
  # the host's (`TuiApp.visualAct`), which here records the acts it is asked
  # for — the one stand-in, and why it is not a mock: what is asserted is the
  # operation a key or a press reaches, which happens before the host is
  # called, and the host's own half is `test_plat59_visual_replay`'s.
  proc playerRuntime(acts: ref seq[VisualAct]): TuiRuntime =
    let app = newTuiApp()
    app.projectRoot = createTempDir("ct-plat64-player-", "")
    app.modes = initModeRegister(pmDebug)
    result = newTuiRuntime(app, caps(), Cols, Rows)
    discard result.enableLayoutBinding()
    result.app.visualAct = proc(act: VisualAct): VisualActResult =
      acts[].add act
      VisualActResult(changed: true)
    discard result.setVisualReplayPanes(true)
    result.app.frameViewer.pane = true
    result.showVisualPane(paneVideoPlayer)
    # The focus tree is re-hung over the new arrangement, as a frame of the
    # running terminal does (`resize` re-derives the panes).
    result.resize(Cols, Rows)
    result.app.layoutBinding.focus = paneVideoPlayer
    check result.focus.focusPaneKind(paneVideoPlayer)

  proc lastAction(acts: ref seq[VisualAct]): string =
    if acts[].len == 0 or acts[^1].kind != vaPlayer: "" else: $acts[^1].action

  proc pressPlay(rt: TuiRuntime) =
    let (_, screen) = rt.videoPlayerScreen()
    for b in screen.transportButtons:
      if b.action == VpaTogglePlay:
        discard rt.handleToken("\x1b[<0;" & $(b.col + 1) & ";" &
                               $(screen.transportRow + 1) & "M", 0)
        return
    checkpoint("no Play button was drawn")
    check false

  test "a key, a user's row for it, and a button's press":
    let acts = new seq[VisualAct]
    let rt = playerRuntime(acts)
    discard rt.handleToken("j", 0)
    check acts.lastAction == $VpaRewind
    rt.pressPlay()
    check acts.lastAction == $VpaTogglePlay
    rt.router.applyUserKeymap(parseUserKeymap("""[
      { "key": "j", "command": "video-player.jump-end",
        "when": "paneKind == videoPlayer" },
      { "key": "click", "command": "video-player.jump-start",
        "when": "paneKind == videoPlayer && elementKind == button" }
    ]"""))
    discard rt.handleToken("j", 0)
    check acts.lastAction == $VpaJumpEnd
    rt.pressPlay()
    check acts.lastAction == $VpaJumpStart

  test "the picker's and the magnifier's layers follow the player's state":
    let acts = new seq[VisualAct]
    let rt = playerRuntime(acts)
    check rt.probeKey("Esc").operation != "video-player.cancel-picker"
    check rt.probeKey("Left").operation == "video-player.step-frame-back"
    rt.app.frameViewer.transport.picker = true
    check rt.probeKey("Esc").operation == "video-player.cancel-picker"
    rt.app.frameViewer.magnified = true
    check rt.probeKey("Left").operation == "video-player.move-magnifier-left"
    check rt.probeKey("Enter").operation == "video-player.commit-pick"
    rt.app.frameViewer.magnified = false
    rt.app.frameViewer.transport.picker = false
    check rt.probeKey("Left").operation == "video-player.step-frame-back"

suite "§5.1: the top bar's and a docked label's presses go through the router":
  # A press on the top bar's elements and on a docked pane's label: the plain
  # press does what it always did, and a user's row for the element's press
  # (`paneKind == topBar`, or the label's pane) runs the user's operation
  # instead. `help.check-key-delivery` is the user's operation because its
  # answer is on the status line.
  const UserTakesIt = "keys check"

  proc barColumn(rt: TuiRuntime; kind: TopBarHitKind): int =
    let screen = rt.shellScreenOf()
    let tabs = rt.app.shellModel(rt.width, rt.height).topBar.tabs
    for col in 0 ..< rt.width:
      if screen.topBarLayout.topBarHitAt(col, tabs).kind == kind:
        return col
    -1

  proc click(rt: TuiRuntime; row, col: int) =
    discard rt.handleToken("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "M", 0)
    discard rt.handleToken("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "m", 0)

  proc userRow(rt: TuiRuntime; whenText: string) =
    rt.router.applyUserKeymap(parseUserKeymap("""[
      { "key": "click", "command": "help.check-key-delivery",
        "when": """" & whenText & """" }
    ]"""))

  test "the menu button opens and closes the menu; a user's row takes it":
    let rt = runtime()
    let col = rt.barColumn(thMenuButton)
    check col >= 0
    rt.click(0, col)
    check rt.app.menu.isOpen
    rt.click(0, col)
    check not rt.app.menu.isOpen
    rt.userRow("paneKind == topBar && elementKind == button")
    rt.click(0, col)
    check not rt.app.menu.isOpen
    check UserTakesIt in rt.app.notification

  test "the strip's + adds a tab, and a press on a tab is the user's when bound":
    let rt = runtime()
    # The host's welcome flow: the strip offers its "+" only to a host that
    # can open a tab. What it would start is not asked for here.
    rt.app.welcomeHost = proc(tab: int; intent: NativeWelcomeIntent): string = ""
    let tabsBefore = rt.app.welcomeTabs.tabs.len
    let add = rt.barColumn(thTabAdd)
    check add >= 0
    rt.click(0, add)
    rt.click(0, rt.barColumn(thTabAdd))
    check rt.app.welcomeTabs.tabs.len == tabsBefore + 2
    let tab = rt.barColumn(thTab)
    check tab >= 0
    rt.userRow("paneKind == topBar && elementKind == tab")
    rt.click(0, tab)
    check UserTakesIt in rt.app.notification

  test "the omnibox opens on a press":
    let rt = runtime()
    let col = rt.barColumn(thOmnibar)
    check col >= 0
    rt.click(0, col)
    check rt.app.omnibar.isOpen

  test "a docked pane's label docks it open; a user's row takes the press":
    proc labelCell(rt: TuiRuntime; pane: PaneKind): tuple[row, col: int] =
      let geom = rt.layoutGeometry()
      for s in geom.strips:
        for sl in s.slots:
          if sl.pane == pane:
            return (sl.area.row, sl.area.col)
      (-1, -1)
    proc dockedOpen(rt: TuiRuntime; pane: PaneKind): bool =
      let layout = rt.app.layoutBinding.layout
      let at = layout.dockedIndex(pane)
      at >= 0 and layout.docked[at].open
    let rt = runtime()
    let panes = rt.app.layoutBinding.layout.visiblePanes
    check panes.len > 1
    let pane = panes[^1]
    check rt.app.layoutBinding.dispatch(cmdDock(pane, leLeft)).status == lasApplied
    rt.resize(Cols, Rows)
    let (row, col) = rt.labelCell(pane)
    check row >= 0
    rt.click(row, col)
    check rt.dockedOpen(pane)
    rt.click(row, col)
    check not rt.dockedOpen(pane)
    rt.userRow("paneKind == " & $pane & " && elementKind == button")
    rt.click(row, col)
    check not rt.dockedOpen(pane)
    check UserTakesIt in rt.app.notification
