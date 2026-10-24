## test_plat68_menu_accelerators.nim — the macOS native menu's accelerators
## are the ROUTER's chords (Base-Keymaps-And-Layer-Stack.md KL-8), in
## Electron's syntax.
##
## On macOS the Electron main process builds the native application menu
## (`index/menu.nim`, compiled with `-d:ctmacos`). Its accelerators came from
## the legacy YAML `bindings:` table, which no key is delivered through any
## more; a user who rebound an operation in `keybindings.json` saw the old
## chord beside the menu item. They now come from `menu_accelerators`
## (`menuAccelerator`): the base the desktop runs, the user's file laid over
## it, at the window's scope.
##
## Held here, on Linux, because no Linux lane compiles the `ctmacos` arm:
##   * the translation into Electron's accelerator syntax, row by row, and
##     what is never given one (a sequence, a bare or Shift-only printable
##     key — a registered accelerator would take it from every text field);
##   * for every `ClientAction` the menu can name, the accelerator is the
##     router's chord, and TYPING that chord at the window's scope runs the
##     item's operation (the property KL-8 states, through `route`);
##   * a user row that rebinds Step Over and removes F10 changes the
##     accelerator; the base's chord is gone;
##   * the macOS arm of `index/menu.nim` reads `menuAccelerator` and not the
##     YAML table (a source check: the arm is not compiled on Linux; its
##     planted control is the pre-change spelling, refused by the same
##     predicate).
##
## No mocks: the shipped base and the real user-file parser; the router is
## the product's.

import std/[os, strutils, unittest]

import ../../keymap/[keymap_router, user_keymap, client_actions,
                     operation_catalogue, menu_accelerators, editing_keymap]
import ../../keymap/context_keys
import ../../../../common/key_names

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 28
  ## 25 on the JS backend, which cannot read a source file (the last suite).

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Mac = KeyDelivery(frontEnd: feDesktop, platform: pkMac,
                    keyProtocol: kpNative)

proc macRouter(text = ""): KeymapRouter =
  initKeymapRouter(bkCua, Mac, user = parseUserKeymap(text))

suite "the chord in Electron's accelerator syntax":

  test "modifiers and named keys":
    ck electronAccelerator("Ctrl+Shift+K", pkMac) == "Ctrl+Shift+K"
    ck electronAccelerator("F10", pkMac) == "F10"
    ck electronAccelerator("Shift+F11", pkMac) == "Shift+F11"
    ck electronAccelerator("Meta+P", pkMac) == "Cmd+P"
    ck electronAccelerator("Meta+P", pkLinux) == "Super+P"
    ck electronAccelerator("Ctrl+Alt+N", pkMac) == "Ctrl+Alt+N"
    ck electronAccelerator("Esc", pkMac) == "Escape"
    ck electronAccelerator("Ctrl+Enter", pkMac) == "Ctrl+Return"
    ck electronAccelerator("Ctrl++", pkMac) == "Ctrl+Plus"
    ck electronAccelerator("Alt+`", pkMac) == "Alt+`"
    ck electronAccelerator("Ctrl+PageDown", pkMac) == "Ctrl+PageDown"

  test "what has no accelerator":
    ck electronAccelerator("", pkMac) == ""
    ck electronAccelerator("Ctrl+K Ctrl+W", pkMac) == ""   # a sequence
    ck electronAccelerator("n", pkMac) == ""               # a letter: typing
    ck electronAccelerator("Shift+G", pkMac) == ""         # a shifted letter
    ck electronAccelerator("G", pkMac) == ""
    ck electronAccelerator("Alt", pkMac) == ""             # Alt alone

suite "the menu's accelerator is the router's chord (KL-8)":

  test "Step Over is F10 under CUA, with no user file":
    let r = macRouter()
    ck r.menuChord("forwardNext") == "F10"
    ck r.menuAccelerator("forwardNext") == "F10"

  test "every action the menu names: the chord shown, typed here, runs it":
    var r = macRouter()
    var shown, checked = 0
    for (operation, action) in ClientActionOperations:
      let chord = r.menuChord(action)
      let acc = r.menuAccelerator(action)
      if acc.len == 0:
        continue
      inc shown
      # The accelerator is the chord, respelt — never another chord.
      if acc != electronAccelerator(chord, pkMac):
        checkpoint(action & ": " & acc & " vs " & chord)
        ck false
      # Typing the chord at the window's scope runs the item's operation.
      var probe = r
      var res: EditingResolution
      for key in normalizeChordSequence(chord).splitWhitespace:
        res = probe.route(menuFacts(), menuScopePath(), nmNormal, key, 1_000)
      let ran = if res.kind == erOperation:
                  (if res.argument.len > 0: res.operation & "(" &
                     res.argument & ")" else: res.operation)
                else: ""
      if ran != operationOfClientAction(action):
        checkpoint(action & " shows " & chord & " which runs '" & ran & "'")
        ck false
      inc checked
    checkpoint("accelerators shown: " & $shown)
    ck shown >= 10
    ck checked == shown

suite "the user's keybindings.json changes the accelerator":

  test "a row rebinding Step Over, and F10 removed":
    let r = macRouter("""[
      { "key": "ctrl+alt+n", "command": "debugger.step-over" },
      { "key": "f10", "command": "-debugger.step-over" }
    ]""")
    ck r.menuAccelerator("forwardNext") == "Ctrl+Alt+N"
    ck r.menuAccelerator("forwardNext") != "F10"

  test "a removal alone leaves the item with no accelerator":
    let r = macRouter("""[ { "key": "f10", "command": "-debugger.step-over" } ]""")
    ck r.menuAccelerator("forwardNext") == ""
    # …and the item's neighbours keep theirs.
    ck r.menuAccelerator("forwardStep") == "F11"

when not defined(js):
 suite "the macOS menu reads the router, not the YAML table":

   func readsRouter(src: string): bool =
     ## The `ctmacos` arm sets each item's accelerator from `menuAccelerator`
     ## and never indexes the YAML `shortcutMap`.
     let arm = src[src.find("when defined(ctmacos):") .. ^1]
     "menuAccelerator(" in arm and "shortcutMap" notin arm

   test "index/menu.nim's macOS arm":
     let frontend = currentSourcePath.parentDir / ".." / ".." / ".."
     let src = readFile(frontend / "index" / "menu.nim")
     ck "when defined(ctmacos):" in src
     ck readsRouter(src)

   test "the planted control: the old arm is refused":
     const Old = """when defined(ctmacos):
       let binding = data.config.shortcutMap.actionShortcuts[node.action]
       let resultBinding = if binding.len == 0: "" else: toAccelerator($binding[0].renderer)
 """
     ck not readsRouter(Old)

suite "PLAT-68 menu accelerators: assertion count":
  test "the declared count was reached":
    const Expected = when defined(js): ExpectedAssertions - 3
                     else: ExpectedAssertions
    check countedAssertions == Expected
