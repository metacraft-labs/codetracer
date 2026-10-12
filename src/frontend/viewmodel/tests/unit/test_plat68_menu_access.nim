## test_plat68_menu_access.nim — PLAT-68 Phase B: THE PROGRAM MENU IS
## REACHABLE FROM THE KEYBOARD (CUA-Keymap.md §3.8).
##
## VS Code on Linux and Windows opens its menu with `Alt` pressed alone and
## with `Alt+<mnemonic>`, and `F10` focuses the menu bar where nothing else
## holds it. This product's CUA base does the same, with `` Alt+` `` for the
## terminal (which never sees `Alt` alone) and every front-end:
##
##   * the menu's DATA and the keymap's DATA name the same letters: every
##     shown top-level folder has a mnemonic, they are distinct, each appears
##     in its label (the renderers underline it), and `Alt+<letter>` resolves
##     to `menu.open-folder(<that folder>)` in every scope a user types in —
##     the window, a list, the read-only and the writable editor;
##   * the letters do not take CodeTracer's own Alt chords (`Alt+E`, `Alt+V`,
##     `Alt+C` still focus panes), and the find widget's own `Alt+R` / `Alt+W`
##     still win inside it;
##   * `Alt` alone toggles the menu, `` Alt+` `` opens it under CUA and Emacs,
##     `F10` opens it in Edit mode and steps over in Debug mode;
##   * a user's `-menu.toggle` row turns the Alt gesture off (KL-11);
##   * `menu.open-folder`'s argument opens that folder in the Menu ViewModel;
##   * `alt_tap`: `Alt` down and up with nothing between is a tap; a key, a
##     second modifier or a pointer press in between is not.
##
## No mocks: the shipped bases, the shipped router, the shared menu tree.

import std/[strutils, unittest]

import ../../editing_core
import ../../keymap/keymap_router
import ../../keymap/scope_path
import ../../keymap/operation_catalogue
import ../../keymap/user_keymap
import ../../keymap/layer_stack
import ../../keymap/alt_tap
import ../../../../common/key_names
import ../../viewmodels/[menu_vm, product_menu]

const ExpectedAssertions = 147

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Terminal = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                         keyProtocol: kpKitty)
  Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                        keyProtocol: kpNative)

let
  Window = element(ekWindow, "window")
  Tab = element(ekTab, "tab:1")
  WindowPath = @[Window]
  ListPath = @[Window, Tab, pane("calltrace"), element(ekRow, "call-7")]
  EditorPath = @[Window, Tab, pane("editor"), element(ekEditor, "editor:a.nr")]
  FindPath = EditorPath & @[element(ekOverlay, "find"),
                            element(ekInput, "find-query")]

proc debugFacts(readOnly = true): SessionFacts =
  SessionFacts(product: pmDebug, replayLoaded: true,
               editor: EditorFacts(readOnly: readOnly, mode: emInsert))

proc editFacts(): SessionFacts =
  SessionFacts(product: pmEdit, editor: EditorFacts(mode: emInsert))

proc answer(r: var KeymapRouter; facts: SessionFacts; path: ScopePath;
            key: string): string =
  describeResolution(r.route(facts, path, nmNormal, key, 1_000))

proc shownFolders(): seq[MenuItem] =
  for it in nativeFrontEndMenu("calc").children:
    if it.kind == mikFolder and not it.hidden:
      result.add it

suite "PLAT-68 menu access: the menu's letters are the keymap's":

  test "every shown top-level folder has a distinct mnemonic in its label":
    let folders = shownFolders()
    # The subject count first: "every folder has one" is true of none.
    ck folders.len == MenuFolderArguments.len
    var seen: seq[char] = @[]
    for f in folders:
      checkpoint(f.label)
      ck f.mnemonic in 'a'..'z'
      ck f.mnemonicAt >= 0
      ck f.mnemonic notin seen
      ck f.label.toLowerAscii in MenuFolderArguments
      seen.add f.mnemonic

  test "Alt+<mnemonic> opens that folder, wherever the user is typing":
    var r = initKeymapRouter(bkCua, Desktop)
    for f in shownFolders():
      let want = "operation menu.open-folder(" & f.label.toLowerAscii & ")"
      let key = "Alt+" & $f.mnemonic
      checkpoint(key)
      ck r.answer(debugFacts(), WindowPath, key) == want
      ck r.answer(debugFacts(), ListPath, key) == want
      ck r.answer(debugFacts(), EditorPath, key) == want
      ck r.answer(editFacts(), EditorPath, key) == want

  test "the mnemonics leave CodeTracer's own Alt chords alone":
    var r = initKeymapRouter(bkCua, Desktop)
    ck r.answer(debugFacts(), EditorPath, "Alt+e") ==
       "operation layout.focus-pane(event-log)"
    ck r.answer(debugFacts(), EditorPath, "Alt+v") ==
       "operation layout.focus-pane(editor)"
    ck r.answer(debugFacts(), ListPath, "Alt+c") ==
       "operation layout.focus-pane(call-trace)"
    # Inside the find widget — a pushed layer, as every front-end pushes it
    # (§5.3) — its own toggles come first.
    var facts = editFacts()
    facts.findWidgetVisible = true
    let token = r.pushLayer(FindTable, "editor:a.nr", "FIND")
    ck r.answer(facts, FindPath, "Alt+r") == "operation find.toggle-regex"
    ck r.answer(facts, FindPath, "Alt+w") == "operation find.toggle-whole-word"
    ck r.popLayer(token).outcome == poPopped
    # …and outside it the same letters open Reset and View.
    ck r.answer(editFacts(), EditorPath, "Alt+r") ==
       "operation menu.open-folder(reset)"
    ck r.answer(editFacts(), EditorPath, "Alt+w") ==
       "operation menu.open-folder(view)"

suite "PLAT-68 menu access: Alt alone, Alt+`, F10":

  test "Alt alone toggles the menu in every mode and scope":
    var r = initKeymapRouter(bkCua, Desktop)
    for facts in [debugFacts(), debugFacts(readOnly = false), editFacts()]:
      for path in [WindowPath, ListPath, EditorPath]:
        ck r.answer(facts, path, "Alt") == "operation menu.toggle"

  test "Alt+` opens the menu under CUA and Emacs, on the terminal too":
    for base in [bkCua, bkEmacs]:
      var r = initKeymapRouter(base, Terminal)
      for facts in [debugFacts(), editFacts()]:
        for path in [WindowPath, ListPath, EditorPath]:
          checkpoint($base)
          ck r.answer(facts, path, "Alt+`") == "operation menu.open"

  test "F10 is the menu in Edit mode and step over in Debug mode":
    var r = initKeymapRouter(bkCua, Desktop)
    ck r.answer(editFacts(), WindowPath, "F10") == "operation menu.open"
    ck r.answer(editFacts(), EditorPath, "F10") == "operation menu.open"
    ck r.answer(debugFacts(), WindowPath, "F10") ==
       "operation debugger.step-over"
    ck r.answer(debugFacts(), EditorPath, "F10") ==
       "operation debugger.step-over"

  test "on macOS there is neither Alt alone nor a mnemonic (Option types)":
    const Mac = KeyDelivery(frontEnd: feDesktop, platform: pkMac,
                            keyProtocol: kpNative)
    var r = initKeymapRouter(bkCua, Mac)
    ck not r.answer(editFacts(), EditorPath, "Alt").contains("menu.")
    ck not r.answer(editFacts(), EditorPath, "Alt+d").contains("menu.")
    ck r.answer(editFacts(), EditorPath, "Alt+`") == "operation menu.open"

  test "a user's -menu.toggle turns the Alt gesture off, and only it":
    let user = parseUserKeymap("""[
      { "key": "alt", "command": "-menu.toggle" }
    ]""")
    var r = initKeymapRouter(bkCua, Desktop, user = user)
    ck r.answer(editFacts(), EditorPath, "Alt").startsWith("nothing")
    ck r.answer(editFacts(), EditorPath, "Alt+`") == "operation menu.open"
    ck r.answer(editFacts(), EditorPath, "Alt+d") ==
       "operation menu.open-folder(debug)"

  test "the chord a surface shows for the menu is the router's":
    var r = initKeymapRouter(bkCua, Desktop)
    let facts = editFacts()
    ck r.chordFor("menu.toggle", facts, WindowPath, nmNormal) == "Alt"
    ck r.chordFor("menu.open-folder", facts, WindowPath, nmNormal,
                  "debug") == "Alt+D"

suite "PLAT-68 menu access: the argument opens the folder":

  test "menu.open-folder(<name>) opens the shown folder of that name":
    let vm = newMenuVM(nativeFrontEndMenu("calc"))
    for name in MenuFolderArguments:
      checkpoint(name)
      ck argumentProblem("menu.open-folder", name) == ""
      let i = vm.folderIndexOf(name)
      ck i >= 0
      ck not vm.root.children[i].hidden
      vm.openFolder(i)
      ck vm.isOpen
      ck vm.path == @[i]
      vm.close()
    ck argumentProblem("menu.open-folder", "window") != ""
    ck vm.folderIndexOf("no-such-folder") == -1

  test "Help is the SHOWN twin, not the macOS one":
    let vm = newMenuVM(nativeFrontEndMenu("calc"))
    let i = vm.folderIndexOf("help")
    var hiddenHelp = -1
    for k, it in vm.root.children:
      if it.label == "Help" and it.hidden: hiddenHelp = k
    ck hiddenHelp >= 0
    ck i != hiddenHelp
    ck vm.root.children[i].mnemonic == 'h'

suite "PLAT-68 menu access: Alt pressed and released alone":

  test "Alt down then up, nothing between, is one tap":
    var t: AltTap
    ck not t.modifiersChanged({kmodAlt})
    ck t.modifiersChanged({})
    # A second, separate tap is a tap too; a bare release is not.
    ck not t.modifiersChanged({kmodAlt})
    ck t.modifiersChanged({})
    ck not t.modifiersChanged({})

  test "a key, a second modifier or a pointer press in between is not a tap":
    var t: AltTap
    discard t.modifiersChanged({kmodAlt})
    t.interrupted()                         # Alt+F: a chord
    ck not t.modifiersChanged({})
    discard t.modifiersChanged({kmodAlt})
    discard t.modifiersChanged({kmodAlt, kmodShift})   # Alt+Shift
    discard t.modifiersChanged({kmodAlt})
    ck not t.modifiersChanged({})
    discard t.modifiersChanged({kmodCtrl})  # Ctrl first, then Alt, released
    discard t.modifiersChanged({kmodCtrl, kmodAlt})
    discard t.modifiersChanged({kmodAlt})
    ck not t.modifiersChanged({})
    discard t.modifiersChanged({kmodAlt})
    t.reset()                               # the window lost the focus
    ck not t.modifiersChanged({})

suite "PLAT-68 menu access: assertion count":
  test "the declared count was reached":
    checkpoint("counted: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
