## test_plat64_operation_tables.nim — the terminal's operation tables
## (Input-Routing-And-Keymaps.md §3) through the same dispatch a key runs: each
## entry reaches its procedure, an overlay's table holds only while it is open, a
## disabled operation is inert and says why (IR-6), and one this front-end does
## not perform says so.
##
## No mocks: the shipped runtime over its real ViewModels, with no terminal. The
## Video Player's suite records the acts its host is asked for; its header says
## why that one stand-in is not a mock.

import std/[strutils, tempfiles, unittest]

import codetracer_embed

import ../app/runtime
import ../app/theme/capabilities
import ../app/tui_app
import ../app/views/frame_viewer
import ../app/views/visual_replay_panes
import ../../headless_app/layout_model
import ../../viewmodel/keymap/[keymap_router, user_keymap]
import ../../viewmodel/viewmodels/video_player_vm

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
