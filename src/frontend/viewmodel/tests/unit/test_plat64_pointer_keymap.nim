## test_plat64_pointer_keymap.nim — Input-Routing-And-Keymaps.md §5.1 and §4: a
## pointer gesture on an element resolves through the one resolver, a user's row
## overrides the base's, the overlays' rows live in their pushed layers, and a
## pointer row is reported as any other row of a user's file.
##
## No mocks: the shipped four bases, the shipped router, a user file parsed by the
## shipped loader.

import std/[strutils, unittest]

import ../../keymap/[base_keymaps, context_keys, editing_keymap, keymap_router,
                     operation_catalogue, overlay_rows, pointer_rows, user_keymap]
import ../../viewmodels/product_mode
import ../../../../common/key_names

const
  Terminal = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                         keyProtocol: kpLegacy)
  Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                        keyProtocol: kpNative)

proc pathOf(paneKind: string; kind: ElementKind): ScopePath =
  @[element(ekWindow, "window"), pane(paneKind), element(kind, "")]

proc facts(): SessionFacts =
  SessionFacts(product: pmDebug, replayLoaded: true,
               editor: sourceViewFacts())

proc opOf(router: KeymapRouter; paneKind: string; kind: ElementKind;
          gesture: string): string =
  let res = router.routePointer(facts(), pathOf(paneKind, kind), nmNormal, gesture)
  if res.kind == erOperation: res.operation else: ""

suite "§5.1: a gesture on an element":
  test "isPointerChord knows a gesture, with its modifiers or not":
    check isPointerChord("Click")
    check isPointerChord("Ctrl+Click")
    check pointerGesture(prPrimary, true, false, false) == "Ctrl+Click"
    check pointerGesture(prSecondary, true, true, true) == "Ctrl+Shift+Alt+RightClick"
    check pointerGesture(prMiddle, false, false, false) == "MiddleClick"
    check isPointerChord("Ctrl+Alt+MiddleClick")
    check not isPointerChord("Enter")
    check not isPointerChord("Ctrl+c")
    check normalizeChord("ctrl+click") == "Ctrl+Click"
    check normalizeChord("alt+rightclick") == "Alt+RightClick"

  test "every base declares each element's gesture":
    for base in BaseKeymap:
      let r = initKeymapRouter(base, Desktop)
      check opOf(r, "calltrace", ekRow, "Click") == "calltrace.go-to-call"
      check opOf(r, "calltrace", ekToggle, "Click") == "calltrace.toggle-call"
      check opOf(r, "calltrace", ekRow, "DoubleClick") == "calltrace.go-to-call"
      check opOf(r, "calltrace", ekRow, "RightClick") == "context-menu.open"
      check opOf(r, "eventLog", ekRow, "Click") == "event-log.jump"
      check opOf(r, "eventLog", ekRow, "RightClick") == "event-log.show-content"
      check opOf(r, "eventLog", ekHeader, "Click") == "event-log.sort"
      check opOf(r, "state", ekRow, "Click") == "variables.toggle-expand"
      check opOf(r, "fileTree", ekRow, "Click") == "file-tree.activate"
      check opOf(r, "fileTree", ekRow, "RightClick") == "context-menu.open"

  test "the element's kind and pane scope a row":
    let r = initKeymapRouter(bkCua, Desktop)
    check opOf(r, "eventLog", ekToggle, "Click") == ""
    check opOf(r, "calltrace", ekHeader, "Click") == ""
    check opOf(r, "calltrace", ekRow, "Ctrl+Click") == ""

  test "a gesture is no key: a keyboard route never reaches a pointer row":
    var r = initKeymapRouter(bkCua, Desktop)
    let res = r.route(facts(), pathOf("calltrace", ekRow), nmNormal, "Click", 0)
    check res.kind != erOperation

suite "§4.3: configuration populates the pointer keymap":
  const File = """[
    { "key": "ctrl+click", "command": "debugger.step-over",
      "when": "paneKind == calltrace && elementKind == row" },
    { "key": "click", "command": "debugger.step-into",
      "when": "paneKind == eventLog && elementKind == row" }
  ]"""

  test "a user's row beats the base's, in its scope only":
    let r = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap(File))
    check r.errors.len == 0
    check opOf(r, "calltrace", ekRow, "Ctrl+Click") == "debugger.step-over"
    check opOf(r, "calltrace", ekRow, "Click") == "calltrace.go-to-call"
    check opOf(r, "eventLog", ekRow, "Click") == "debugger.step-into"
    check opOf(r, "eventLog", ekHeader, "Click") == "event-log.sort"

  test "the answer says the row is the user's":
    let r = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap(File))
    let res = r.routePointer(facts(), pathOf("calltrace", ekRow), nmNormal,
                             "Ctrl+Click")
    check res.layer.startsWith("user:")
    check r.routePointer(facts(), pathOf("calltrace", ekRow), nmNormal,
                         "Click").layer.startsWith("base:")

  test "a terminal with no extended keys can still deliver a gesture":
    let r = initKeymapRouter(bkCua, Terminal, user = parseUserKeymap(File))
    check r.errors.len == 0
    check opOf(r, "calltrace", ekRow, "Ctrl+Click") == "debugger.step-over"

  test "a removal takes a gesture's row out":
    let r = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap("""[
      { "key": "click", "command": "-event-log.jump" }
    ]"""))
    check opOf(r, "eventLog", ekRow, "Click") == ""

  test "a user's pointer row over a base row is listed as a shadow (IR-4)":
    let r = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap(File))
    var seen = false
    for s in r.shadows:
      if s.shadowedOperation == "event-log.jump": seen = true
    check seen

suite "§4.1: the overlays' rows":
  test "an overlay's rows hold only while its layer is pushed":
    var r = initKeymapRouter(bkCua, Desktop)
    let path = @[element(ekWindow, "window")]
    check r.route(facts(), path, nmNormal, "Up", 0).operation !=
      "menu.focus-previous"
    discard r.pushLayer(MenuTable, "window", "")
    check r.route(facts(), path, nmNormal, "Up", 0).operation ==
      "menu.focus-previous"
    check r.route(facts(), path, nmNormal, "Down", 0).operation == "menu.focus-next"
    check r.route(facts(), path, nmNormal, "Right", 0).operation == "menu.enter-folder"
    check r.route(facts(), path, nmNormal, "Left", 0).operation == "menu.leave-folder"
    check r.route(facts(), path, nmNormal, "Enter", 0).operation == "menu.accept"
    check r.route(facts(), path, nmNormal, "Esc", 0).operation == "menu.close"

  test "every base carries them":
    for base in BaseKeymap:
      var r = initKeymapRouter(base, Desktop)
      discard r.pushLayer(ContentViewTable, "window", "")
      let path = @[element(ekWindow, "window")]
      check r.route(facts(), path, nmNormal, "q", 0).operation == "content-view.close"
      check r.route(facts(), path, nmNormal, "PageUp", 0).operation == "content-view.page-up"

  test "a user can rebind a menu's key":
    var r = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap("""[
      { "key": "ctrl+n", "command": "menu.focus-next" }
    ]"""))
    discard r.pushLayer(MenuTable, "window", "")
    check r.route(facts(), @[element(ekWindow, "window")], nmNormal, "Ctrl+n", 0).operation ==
      "menu.focus-next"

  test "the row tables hold what they claim":
    check OverlayRows.len > 0
    check PointerRows.len > 0
    for row in PointerRows: check row.table == PointerTable
