## test_plat49_chrome_models.nim — PLAT-49 part A, the shared half: what the
## user's 2026-10-01 findings put into the ViewModels, so every front-end
## renders the same logical content its own way.
##
##   * finding 5 — a debugger control's TOOLTIP (label and key) is
##     `debug_controls_vm`'s: one shape (`tooltipText`), one label table
##     (`TransportActions`), the same labels the controls' renderings carry;
##   * finding 6 — the OMNIBAR's placeholder is the ViewModel's
##     (`OmnibarPlaceholder`), and its query is edited at a CARET in insert
##     or overwrite mode (`cursor`, `overwrite`), UTF-8 safe;
##   * finding 12 — a variable row's CATEGORY is the ViewModel's
##     (`state_vm.VariableCategory`), with one distinct one-letter tag each;
##   * finding 1 — the Menu ViewModel walks the desktop's cascade: Up / Down
##     at the open level (the first level included), Right into a folder,
##     Left back out.
##
## Every subject is pure (values in, values out), on both backends (vm-unit
## and vm-unit-js). No mocks.

import std/[sets, strutils, unittest]

import ../../viewmodels/[menu_vm, product_menu, omnibar_vm, transport_icons]
from ../../viewmodels/debug_controls_vm import tooltipText, transportLabel,
  transportTooltip, TransportActions
from ../../viewmodels/state_vm import VariableCategory, vcLocal, categoryTag

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 99

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

suite "PLAT-49: the debugger controls' tooltip is the ViewModel's":

  test "label and key, or the bare label; one table of labels":
    ck tooltipText("Next", "n") == "Next (n)"
    ck tooltipText("Next", "") == "Next"
    ck tooltipText("Reverse continue", "F8 F2") == "Reverse continue (F8 F2)"
    for (id, label) in TransportActions:
      ck transportLabel(id) == label
      ck transportTooltip(id, "x") == label & " (x)"
      ck transportTooltip(id, "") == label
    # The controls' renderings carry the SAME labels: every control the
    # terminal and GPUI draw has the ViewModel's label.
    for c in TransportControls:
      ck transportLabel(c.id) == c.label
    # An unknown id is named rather than dropped.
    ck transportLabel("no-such-control") == "no-such-control"

suite "PLAT-49: the omnibar's placeholder and caret":

  test "one placeholder, the desktop palette's words":
    ck OmnibarPlaceholder == "Navigate to file or run a :command"
    let vm = newOmnibarVM()
    ck vm.query.len == 0 and vm.cursor == 0 and not vm.overwrite

  test "insert at the caret; Left / Right / Home / End; Backspace and Delete":
    let vm = newOmnibarVM()
    vm.open()
    vm.typeText("abc")
    ck vm.query == "abc" and vm.cursor == 3
    vm.moveCursor(-1)
    ck vm.cursor == 2
    vm.typeText("X")
    ck vm.query == "abXc" and vm.cursor == 3
    vm.cursorHome()
    ck vm.cursor == 0
    vm.typeText(":")
    ck vm.query == ":abXc" and vm.cursor == 1
    ck vm.mode == omCommand
    vm.cursorEnd()
    ck vm.cursor == 5
    vm.backspace()
    ck vm.query == ":abX" and vm.cursor == 4
    vm.cursorHome()
    vm.deleteForward()
    ck vm.query == "abX" and vm.cursor == 0
    ck vm.mode == omFile
    # Clamped at both ends.
    vm.moveCursor(-5)
    ck vm.cursor == 0
    vm.moveCursor(50)
    ck vm.cursor == 3
    vm.backspace()
    vm.backspace()
    vm.backspace()
    vm.backspace()
    ck vm.query == "" and vm.cursor == 0

  test "overwrite replaces the character under the caret; at the end it appends":
    let vm = newOmnibarVM()
    vm.open("main.py")
    ck vm.cursor == 7
    vm.toggleOverwrite()
    ck vm.overwrite
    vm.cursorHome()
    vm.typeText("x")
    ck vm.query == "xain.py" and vm.cursor == 1
    vm.cursorEnd()
    vm.typeText("c")
    ck vm.query == "xain.pyc" and vm.cursor == 8
    vm.toggleOverwrite()
    ck not vm.overwrite
    vm.cursorHome()
    vm.typeText("m")
    ck vm.query == "mxain.pyc"
    # Closing resets the caret and the mode; opening starts in insert mode.
    vm.toggleOverwrite()
    vm.close()
    ck vm.cursor == 0 and not vm.overwrite
    vm.open("#4")
    ck vm.cursor == 2 and not vm.overwrite

  test "the caret moves by CHARACTERS, never inside one":
    let vm = newOmnibarVM()
    vm.open()
    vm.typeText("é")
    vm.typeText("ü")
    ck vm.query == "éü"
    ck vm.cursor == 4
    ck vm.cursorChars == 2
    vm.moveCursor(-1)
    ck vm.cursor == 2 and vm.cursorChars == 1
    vm.typeText("a")
    ck vm.query == "éaü"
    vm.toggleOverwrite()
    vm.typeText("o")
    ck vm.query == "éao"
    vm.cursorHome()
    vm.deleteForward()
    ck vm.query == "ao"
    vm.cursorEnd()
    vm.backspace()
    ck vm.query == "a"

suite "PLAT-49: a variable row's category is the ViewModel's":

  test "six categories, six distinct one-letter tags":
    var tags = initHashSet[string]()
    for c in VariableCategory:
      ck categoryTag(c).len == 1
      ck categoryTag(c)[0].isUpperAscii
      tags.incl categoryTag(c)
    ck tags.len == 6
    ck categoryTag(vcLocal) == "L"

suite "PLAT-49: the menu walks the desktop's cascade":

  test "Up / Down at the first level, Right into a folder, Left back out":
    let vm = newMenuVM(nativeFrontEndMenu("calc"))
    vm.open()
    ck vm.path.len == 0
    ck vm.highlightedItem().label == "File"
    for _ in 0 ..< 5:
      vm.moveHighlight(1)
    ck vm.highlightedItem().label == "Debug"
    ck vm.enterFolder()
    ck vm.path.len == 1
    ck vm.highlightedItem().label == "Continue"
    # Two levels shown: the first level and the submenu beside it.
    let levels = vm.openLevels()
    ck levels.len == 2
    ck levels[0].folderPath.len == 0
    ck levels[1].folderPath == vm.path
    ck vm.leaveFolder()
    ck vm.path.len == 0
    ck vm.highlightedItem().label == "Debug"
    vm.moveHighlight(-1)
    ck vm.highlightedItem().label == "Reset"
    vm.escape()
    ck not vm.isOpen

suite "PLAT-49 models: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
