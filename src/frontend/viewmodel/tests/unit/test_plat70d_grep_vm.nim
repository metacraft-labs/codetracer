## test_plat70d_grep_vm.nim — PLAT-70 Part D (Find-And-Incremental-Search.md
## §5.2): what `search.find-in-files` with no pattern opens on, in the shared
## ViewModels every front-end draws — on the C and the JS backend (vm-unit and
## vm-unit-js).
##
## * **The seed** (`search_results_vm.findInFilesSeed`): the editor's
##   selection when it is non-empty and on one line, else the pane's query —
##   VS Code's Find in Files, which seeds from the selection only.
## * **The request** (`SearchResultsVM.openField`): the seed returned and
##   recorded once per call for the view that draws the field; nothing is
##   searched until `Enter` (no run starts, the query is unchanged).
## * **The selected seed** (`OmnibarVM.openSelected`): the terminal's and
##   GPUI's field is the omnibar's `:grep` line, the seed selected — typing,
##   `Backspace` and `Delete` replace or remove it and keep `:grep `, a caret
##   move ends it at the selection's start or end, and an empty seed selects
##   nothing.
## * **The selection's text** (`find_vm.selectionText`) on a real document.
##
## ## No mocks
## The shipped ViewModels and editing core, over values written here. The
## SearchResultsVM has no host: its `onSearch` is a capturing closure — the
## one stand-in, and not a mock: it records whether a run was asked for, which
## is the claim, and answers nothing.

import std/unittest

import ../../editing_core
import ../../viewmodels/find_vm
import ../../viewmodels/omnibar_vm
import ../../viewmodels/search_results_vm
import isonim/core/signals

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 46

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

suite "PLAT-70 Part D: Find in Files' field opens seeded":

  test "the seed: a one-line selection, else the pane's query":
    ck findInFilesSeed("scale", "old") == "scale"
    ck findInFilesSeed("", "old") == "old"
    ck findInFilesSeed("two\nlines", "old") == "old"
    ck findInFilesSeed("crlf\r", "old") == "old"
    ck findInFilesSeed("", "") == ""
    ck findInFilesSeed("café x", "") == "café x"

  test "openField: the seed, requested once per call; nothing is searched":
    let vm = createSearchResultsVM(nil)
    var runs = 0
    vm.onSearch = proc(runId: int; query: string; options: TextMatchOptions) =
      inc runs
    vm.search("old")
    ck runs == 1
    let id = vm.runId
    ck vm.openField("factor") == "factor"
    ck vm.fieldRequest.val.seed == "factor"
    ck vm.fieldRequest.val.revision == 1
    ck vm.openField("") == "old"
    ck vm.fieldRequest.val.seed == "old"
    ck vm.fieldRequest.val.revision == 2
    ck vm.openField("a\nb") == "old"
    ck vm.fieldRequest.val.revision == 3
    ck runs == 1
    ck vm.runId == id
    ck vm.query.val == "old"
    discard vm

  test "openSelected: the seed selected after the prefix; typing replaces it":
    let ob = newOmnibarVM()
    ob.openSelected(":grep ", "scale")
    ck ob.isOpen
    ck ob.query == ":grep scale"
    ck ob.selectedSpan == (6, 11)
    ck ob.selectedText == "scale"
    ck ob.selectedChars == (6, 11)
    ck ob.cursor == 11
    ck ob.mode == omProgram
    ob.typeText("f")
    ck ob.query == ":grep f"
    ck ob.selectedSpan == (-1, -1)
    ob.typeText("o")
    ck ob.query == ":grep fo"

  test "Backspace and Delete remove the selection, keeping the prefix":
    let ob = newOmnibarVM()
    ob.openSelected(":grep ", "scale")
    ob.backspace()
    ck ob.query == ":grep "
    ck ob.cursor == 6
    ob.openSelected(":grep ", "scale")
    ob.deleteForward()
    ck ob.query == ":grep "
    ck ob.selectedText == ""

  test "a caret move ends the selection at its start or its end":
    let ob = newOmnibarVM()
    ob.openSelected(":grep ", "scale")
    ob.moveCursor(-1)
    ck ob.cursor == 6 and ob.selectedSpan == (-1, -1)
    ob.typeText("x")
    ck ob.query == ":grep xscale"
    ob.openSelected(":grep ", "scale")
    ob.moveCursor(1)
    ck ob.cursor == 11 and ob.selectedText == ""
    ob.openSelected(":grep ", "scale")
    ob.cursorHome()
    ck ob.cursor == 0 and ob.selectedText == ""
    ob.openSelected(":grep ", "scale")
    ob.cursorEnd()
    ck ob.selectedText == ""

  test "an empty seed selects nothing; open and setQuery clear a selection":
    let ob = newOmnibarVM()
    ob.openSelected(":grep ", "")
    ck ob.query == ":grep " and ob.selectedSpan == (-1, -1)
    ob.openSelected(":grep ", "a")
    ob.open(":sym ")
    ck ob.selectedSpan == (-1, -1)
    ob.openSelected(":grep ", "a")
    ob.setQuery(":grep b")
    ck ob.selectedSpan == (-1, -1)
    ob.openSelected(":grep ", "a")
    ob.close()
    ck ob.selectedSpan == (-1, -1)

  test "a multibyte seed: characters, not bytes, for the painters":
    let ob = newOmnibarVM()
    ob.openSelected(":grep ", "café")
    ck ob.selectedText == "café"
    ck ob.selectedChars == (6, 10)
    ck ob.cursorChars == 10

  test "selectionText: the main selection of a real document":
    var d = initEditingDocument("main.py", "def scale(v):\n    return v\n",
                                bkCua)
    d.moveCaretTo(0, 4)
    ck selectionText(d) == ""
    d.extendSelectionTo(0, 9)
    ck selectionText(d) == "scale"

  test "assertion count":
    check countedAssertions == ExpectedAssertions
