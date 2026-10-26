## test_plat53_test_results.nim — PLAT-53: the Test Results pane's shared
## pieces, which the desktop, the terminal and the GPUI window all draw from.
##
## LANE: `vm-unit`, `vm-unit-js` and `vm-unit-wasm`, by the directory glob.
##
## Spec: `GUI/Core-Panes/Test-Results-Pane.md` §8.2 (the catalog rule) and
## §8.4 (what every front-end draws).
##
## Asserted:
##
##   * THE WORDS AND MARKS moved out of the desktop's view are the ViewModel's,
##     and the view still answers with them (the same symbols, re-exported):
##     every state's mark, the location, the duration only once run, every
##     arm of the ▶'s title;
##   * THE CATALOG RULE (`test_catalog_answer`), every arm in the desktop's
##     order — no folder, no `Nargo.toml`, a discovery that raised, a catalog
##     — over real Noir source text (the parser is the `ct test` provider's);
##   * THE NATIVE LIST (`displayRows`): each test, its message's lines under
##     it, the failure block, the absence, the empty state, in the desktop's
##     order;
##   * THE COLUMNS (`testResultsFit`): the name and the location share the
##     room 18 : 10 whatever they hold, the duration is never cut, the fixed
##     parts keep their widths, and a pane narrower than the fixed parts
##     scrolls;
##   * the open title's last clause where Shift cannot arm `⏵`.
##
## NO MOCKS: the ViewModel and the catalog parser run for real. The one
## stand-in is the `sources` reader handed to `testCatalogAnswer` — a closure
## returning source text this suite wrote, which is exactly the argument the
## desktop's and the native hosts' filesystem walks pass, so it is the input
## the rule is defined over rather than a mock of a collaborator. The walks
## themselves are asserted over a real directory by the `tui` lane's
## `test_plat53_test_results_host.nim`.

import std/[strutils, unittest]

import isonim/core/[owner, signals]

import ../../viewmodels/test_results_vm
import ../../viewmodels/test_catalog_answer
from ../../viewmodels/no_project_folder import NoProjectFolderText
import ../../views/isonim_test_results_view

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

const ExpectedAssertions = 59

const MainNr = """
fn main(x: Field, y: pub Field) {
    assert(x != y);
}

#[test]
fn test_passes() {
    main(1, 2);
}

#[test]
fn test_fails() {
    main(1, 1);
}
"""

proc rowOf(name: string; state: TestResultsRowState; message = "";
           file = "src/main.nr"; line = 6): TestResultsRow =
  TestResultsRow(testId: "noir/" & name, selector: name, name: name,
                 file: file, line: line, state: state, durationMs: 12,
                 message: message)

suite "PLAT-53: the words every front-end draws":
  test "the marks, locations and durations are the ViewModel's":
    ck stateMark(trsNotRun) == "·"
    ck stateMark(trsRunning) == "…"
    ck stateMark(trsPassed) == "✓"
    ck stateMark(trsFailed) == "✗"
    ck stateMark(trsSkipped) == "–"
    ck stateMark(trsErrored) == "!"
    ck stateMark(trsCancelled) == "×"
    ck rowWhere(rowOf("t", trsPassed)) == "src/main.nr:6"
    ck rowWhere(rowOf("t", trsPassed, line = 0)) == "src/main.nr"
    ck rowWhere(rowOf("t", trsPassed, file = "")) == ""
    ck rowDuration(rowOf("t", trsNotRun)) == ""
    ck rowDuration(rowOf("t", trsFailed)) == "12ms"
    # The desktop's view answers with the SAME procs (re-exported).
    ck isonim_test_results_view.stateMark(trsFailed) == "✗"
    ck isonim_test_results_view.EmptyStateText == EmptyStateText

  test "the ▶'s title says why it is disabled, or what it does":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      ck vm.runButtonTitle() == NoRunHostText
      vm.setRunTests(proc(): string = "")
      ck vm.runButtonTitle() == RunTestsTitle
      vm.setRunAbsence("this deployment cannot")
      ck vm.runButtonTitle() == "this deployment cannot"
      vm.setRunAbsence("")
      vm.beginRun()
      ck vm.runButtonTitle() == RunInProgressText
      vm.endRun()
      ck vm.runButtonTitle() == RunTestsTitle
      dispose()

  test "where Shift cannot arm ⏵, the open title names ⟳":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setRowActions(proc(a, b: string) = discard,
                       proc(a, b: string) = discard,
                       proc(a, b: string) = discard)
      var row = rowOf("test_passes", trsPassed)
      row.recordingId = "rec-1"
      # The clause, then where it opens (Test-Results-Pane.md §9.4).
      ck vm.openButtonTitle(row).endsWith("Hold Shift to record it again " &
                                          "first. " & OpensInNewTabText)
      ck vm.openButtonTitle(row, shiftReachable = false).endsWith(
        NoShiftRecordAgainText & " " & OpensInNewTabText)
      ck "nothing is re-run" in vm.openButtonTitle(row, shiftReachable = false)
      dispose()

suite "PLAT-53: the catalog rule, shared by every host":
  test "no folder, no Nargo.toml, a failed discovery, a catalog":
    var read = 0
    let reader = proc(): seq[NoirSourceFile] =
      inc read
      @[NoirSourceFile(path: "src/main.nr", content: MainNr)]
    let none = testCatalogAnswer("", true, reader)
    ck not none.hasCatalog
    ck none.absence == NoProjectFolderText
    let notCrate = testCatalogAnswer("/p", false, reader)
    ck not notCrate.hasCatalog
    ck notCrate.absence == NoTestProviderText
    ck read == 0   # neither arm reads a source
    let failed = testCatalogAnswer("/p", true,
      proc(): seq[NoirSourceFile] = raise newException(IOError, "disk gone"))
    ck not failed.hasCatalog
    ck failed.absence == DiscoveryFailedStem & "disk gone"
    let crate = testCatalogAnswer("/p", true, reader)
    ck crate.hasCatalog
    ck crate.absence == ""
    ck read == 1
    var selectors: seq[string] = @[]
    for item in crate.catalog.items:
      selectors.add item.selector
    ck selectors == @["test_passes", "test_fails"]
    ck crate.catalog.items[0].file == "src/main.nr"
    ck crate.catalog.items[0].range.startLine == 5   # the `#[test]` line

suite "PLAT-53: the native list":
  test "each test, its message lines, the failure block, the absence":
    let rows = @[rowOf("test_passes", trsPassed),
                 rowOf("test_fails", trsFailed,
                       message = "Failed assertion\n  at src/main.nr:2")]
    let d = displayRowsOf(rows, @["run-level one", "two\nlines"], "why not")
    var kinds: seq[TestResultsDisplayKind] = @[]
    for x in d:
      kinds.add x.kind
    ck kinds == @[tdRow, tdRow, tdMessage, tdMessage, tdFailure, tdFailure,
                  tdFailure, tdAbsence]
    ck d[1].row == 1 and d[2].row == 1 and d[3].row == 1
    ck d[2].text == "Failed assertion"
    ck d[3].text == "  at src/main.nr:2"
    ck d[5].text == "two" and d[6].text == "lines"
    ck d[7].text == "why not"
    ck displayRowOf(d, 1) == 1
    ck displayRowOf(d, 5) == -1

  test "no tests: the empty state, after the absence":
    let d = displayRowsOf(@[], @[], NoTestProviderText)
    ck d.len == 2
    ck d[0].kind == tdAbsence and d[0].text == NoTestProviderText
    ck d[1].kind == tdEmpty and d[1].text == EmptyStateText

  test "the ViewModel's own list follows its rows":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(testCatalogAnswer("/p", true,
        proc(): seq[NoirSourceFile] =
          @[NoirSourceFile(path: "src/main.nr", content: MainNr)]).catalog)
      let d = vm.displayRows()
      ck d.len == 2
      ck d[0].kind == tdRow and d[1].kind == tdRow
      ck vm.rowOfTest(vm.rows.val[1].testId) == 1
      ck vm.rowOfTest("nope") == -1
      dispose()

suite "PLAT-53: the columns":
  test "the name and the location share the room 18 : 10":
    # mark 1, duration 4, actions 5, gaps 4 → 86 left of 100.
    let f = testResultsFit(1, 4, 5, 100)
    ck f.mode == fmFit
    ck f.widths[0] == 1 and f.widths[3] == 4 and f.widths[4] == 5
    let shared = f.widths[1] + f.widths[2]
    ck shared == 100 - 1 - 4 - 5 - 4
    # 86 * 18 / 28 = 55.3; Jefferson's rule gives the name 55 or 56.
    ck f.widths[1] in 55 .. 56
    ck f.widths[1] > f.widths[2]
    ck f.contentUnits == 100

  test "the duration is never cut, and a narrow pane scrolls":
    let f = testResultsFit(1, 6, 5, 10)
    ck f.mode == fmScroll
    ck f.widths[3] == 6
    ck f.widths[1] == 0 and f.widths[2] == 0

  test "the assertion count":
    check asserted == ExpectedAssertions
