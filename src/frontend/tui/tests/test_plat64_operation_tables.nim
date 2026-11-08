## test_plat64_operation_tables.nim — the terminal's operation tables
## (Input-Routing-And-Keymaps.md §3) through the same dispatch a key runs: each
## entry reaches its procedure, an overlay's table holds only while it is open, a
## disabled operation is inert and says why (IR-6), and one this front-end does
## not perform says so.
##
## No mocks: the shipped runtime over its real ViewModels, with no terminal.

import std/[strutils, tempfiles, unittest]

import codetracer_embed

import ../app/runtime
import ../app/theme/capabilities
import ../app/tui_app

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
