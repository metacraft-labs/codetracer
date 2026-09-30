## test_plat48_desktop_menu.nim — PLAT-48, the desktop's column beside the
## terminal's and GPUI's: THE ONE MENU, DRAWN THREE WAYS.
##
## Reads `src/tests/visual/answers/plat48-menu.electron.json`, written by the
## REAL Electron app (`just plat48-capture-electron`,
## `src/tests/gui/tests/visual/plat48-menu-capture.spec.ts`), and asserts:
##
##   * THE VERIFICATION GATE: a highlight given to the Menu ViewModel alone
##     was the highlight the desktop's DOM drew — the open folder and Step
##     Over, then Step Out and no longer Step Over;
##   * the desktop's top-level folders are the shared tree's
##     (`product_menu.nativeFrontEndMenu`) — the tree the terminal and GPUI
##     menus draw;
##   * the Debug folder's shortcuts are the desktop keymap's chords, the same
##     table the GPUI window binds and shows (`window_top_bar.desktopBindings`
##     reads `default_config.yaml`);
##   * choosing Step Over from the menu moved the debugger;
##   * the footer's labels are the shared default's docked panes, the strip
##     the terminal and GPUI draw.
##
## FAILS BY NAME when the answers file is absent. No mocks.

import std/[json, os, strutils, unittest]

import codetracer_embed
import headless_app/layout_model

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 14

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while not fileExists(dir / "justfile"):
    dir = dir.parentDir
  dir

let answers = repoRoot() / "src" / "tests" / "visual" / "answers" /
              "plat48-menu.electron.json"

suite "PLAT-48: the desktop's menu is the shared Menu ViewModel's":

  test "the answers exist":
    if not fileExists(answers):
      checkpoint("missing " & answers & " — run `just plat48-capture-electron`")
    ck fileExists(answers)

  if fileExists(answers):
    let a = parseJson(readFile(answers))

    test "THE GATE: the ViewModel's highlight, and only it, moved the desktop's":
      var first, second: seq[string]
      for s in a["gate"]["vmHighlightStepOver"]: first.add s.getStr
      for s in a["gate"]["vmHighlightStepOut"]: second.add s.getStr
      ck "Debug" in first and "Step Over" in first
      ck "Step Out" in second and "Step Over" notin second

    test "the desktop's folders are the shared tree's":
      var desk: seq[string]
      for s in a["rootLabels"]: desk.add s.getStr
      let tree = nativeFrontEndMenu("calc")
      var shared: seq[string]
      for i in tree.visibleChildren():
        shared.add tree.children[i].label
      ck desk == shared

    test "the Debug folder's chords are the desktop keymap's":
      let sc = a["debugShortcuts"]
      ck sc["Step Over"].getStr == "F10"
      ck sc["Step In"].getStr == "F11"
      ck sc["Step Out"].getStr == "F12"
      ck sc["Reverse Step Over"].getStr == "SHIFT+F10"
      ck sc["Continue"].getStr == "F8 F2"

    test "Step Over from the menu moved the debugger, and closed the menu":
      ck a["openedByClick"].getBool
      # …and the desktop's own `aMenu` chord (CTRL+M) opens the same menu.
      ck a["openedByKey"].getBool
      ck a["stepOver"]["after"].getInt != a["stepOver"]["before"].getInt
      ck a["stepOver"]["closed"].getBool

    test "the footer's labels are the shared default's docked panes":
      var labels: seq[string]
      for s in a["footerLabels"]: labels.add s.getStr
      var shared: seq[string]
      for d in sharedDefaultDocked(): shared.add d.title
      ck labels == shared

suite "PLAT-48 desktop menu: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
