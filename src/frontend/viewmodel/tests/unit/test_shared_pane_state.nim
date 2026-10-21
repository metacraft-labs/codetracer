## EACH WINDOW TAB SHOWS ITS OWN FILES, TEST RESULTS AND CONSTRAINTS.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_shared_pane_state.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_shared_pane_state.nim
##
## ## The defect (issue #835)
##
## These three panes have ONE ViewModel per window, shared by every tab.
## Opening a replay, then "+" and New File, made the edit tab write "No
## project folder is open." into Test Results and Constraints and its empty
## project into Files; switching back, the replay tab showed all of that
## (rule 6 of `GUI/Multi-Window-Tab-Management.md` §Tab Behavior: a tab's
## state is preserved across switches). And a tab shown for the first time
## inherited whatever the previous tab had there (rule 1: each tab is an
## independent session); a replay opened in it never overwrites these panes,
## so it would have kept another tab's project for good.
##
## ## What is asserted
##
## The switch itself lives in `ui/session_switch.nim`, a renderer module no
## headless lane can load; it only calls the three procs exercised here, in
## the order `tabSwitch` below calls them. So these checks drive the REAL
## ViewModels through a replay tab, an edit tab and a third tab, and read the
## signals the panes render:
##
## * a tab shown for the first time gets EXACTLY what a freshly created VM
##   holds — compared against a fresh VM, not against constants copied here,
##   so a new initial value in a VM constructor cannot drift from the reset;
## * a tab left and entered again gets back exactly what it showed;
## * what the host installed for the whole window (the test runner, a run in
##   flight) survives every switch.
##
## The production VM constructors and the production module. The one stand-in
## is `MockBackendService`, and only because `createFilesystemVM` needs a
## `ReplayDataStore` and a store needs a backend: nothing here sends a request
## or reads a reply, so no behaviour under test passes through it.

import std/[sets, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel

import ../../../../ct_test/contracts
import ../../viewmodels/test_results_vm
import ../../viewmodels/constraints_vm
import ../../viewmodels/filesystem_vm
import ../../viewmodels/shared_pane_state
import ../../store/[types, replay_data_store]
import ../../backend/mock_backend

const NoProject = "No project folder is open."

type
  Window = object
    ## The window's one instance of each shared VM, as the renderer has.
    tests: TestResultsVM
    constraints: ConstraintsVM
    files: FilesystemVM

  Tab = ref object
    snapshot: SharedPaneSnapshot ## nil until the tab has been left once

let store = createReplayDataStore(
  newMockBackendService(autoRespond = true).toBackendService())

proc newWindow(): Window =
  Window(tests: createTestResultsVM(), constraints: createConstraintsVM(),
         files: createFilesystemVM(store))

proc tabSwitch(w: Window; leaving, entering: Tab) =
  ## `session_switch.switchSession`'s order: keep the tab being left, then
  ## restore the target, or reset it on its first entry.
  leaving.snapshot = captureSharedPanes(w.tests, w.constraints, w.files)
  if entering.snapshot.isNil:
    resetSharedPanes(w.tests, w.constraints, w.files)
  else:
    restoreSharedPanes(entering.snapshot, w.tests, w.constraints, w.files)

proc item(id: string): TestItem =
  TestItem(id: id, name: id, file: "src/main.nr")

proc folder(path: string; children: seq[FilesystemEntryNode] = @[]): FilesystemEntryNode =
  FilesystemEntryNode(id: path, text: path, path: path, isFolder: true,
                      children: children)

proc writeEditProject(w: Window) =
  ## What an edit tab with no project folder writes: `onNoTrace` plus the
  ## `CODETRACER::ns9-panes` answer.
  w.tests.setRunAbsence(NoProject)
  w.constraints.setAbsence(NoProject)
  w.files.clearRoot()

proc writeNoirProject(w: Window) =
  ## A tab whose project has tests, a circuit report and an open tree.
  w.tests.setCatalog(TestCatalog(items: @[item("t1"), item("t2")]))
  w.tests.projectName.val = "hello_noir"
  w.tests.recordings.val = @[TestRecordingRef(testId: "t1", recordingId: "r1")]
  w.constraints.setReport(ConstraintReport(
    package: "hello_noir", functions: @[], provenance: "nargo info"))
  w.constraints.projectName.val = "hello_noir"
  w.files.setRoot(folder("/p", @[folder("/p/src")]))
  w.files.expandPath("/p/src")

proc checkFresh(w: Window) =
  ## Every tab-state signal equals a freshly created VM's.
  let freshTests = createTestResultsVM()
  let freshConstraints = createConstraintsVM()
  let freshFiles = createFilesystemVM(store)
  check w.tests.catalog.val == freshTests.catalog.val
  check w.tests.summary.val == freshTests.summary.val
  check w.tests.runAbsence.val == freshTests.runAbsence.val
  check w.tests.projectName.val == freshTests.projectName.val
  check w.tests.recordings.val == freshTests.recordings.val
  check w.tests.headline.val == freshTests.headline.val
  check w.constraints.report.val == freshConstraints.report.val
  check w.constraints.projectName.val == freshConstraints.projectName.val
  check w.constraints.headline.val == freshConstraints.headline.val
  check w.files.rootEntry.val == freshFiles.rootEntry.val
  check w.files.loadingState.val == freshFiles.loadingState.val
  check w.files.loadError.val == freshFiles.loadError.val
  check w.files.expandedPaths.val == freshFiles.expandedPaths.val
  check w.files.diffEntries.val == freshFiles.diffEntries.val
  freshTests.dispose()
  freshConstraints.dispose()
  freshFiles.dispose()

suite "shared panes across the tabs of one window (#835)":

  test "a tab shown for the first time does not show the previous tab's project":
    let w = newWindow()
    let replay = Tab()
    let edit = Tab()
    let third = Tab()
    # Replay tab first, as the window starts: it never writes these panes.
    tabSwitch(w, replay, edit)
    writeEditProject(w)
    check w.constraints.report.val.absence == NoProject
    # "+" again, and a recording opened there writes nothing to them either.
    tabSwitch(w, edit, third)
    check w.constraints.report.val.absence != NoProject
    check w.tests.runAbsence.val != NoProject
    checkFresh(w)

  test "a first entry after a project with tests forgets all of it":
    let w = newWindow()
    let noir = Tab()
    let fresh = Tab()
    writeNoirProject(w)
    check w.tests.catalog.val.len == 2
    tabSwitch(w, noir, fresh)
    check w.tests.catalog.val.len == 0
    check w.files.expandedPaths.val.len == 0
    checkFresh(w)

  test "a tab left and entered again shows what it showed":
    let w = newWindow()
    let noir = Tab()
    let edit = Tab()
    writeNoirProject(w)
    let catalog = w.tests.catalog.val
    let recordings = w.tests.recordings.val
    let report = w.constraints.report.val
    let expanded = w.files.expandedPaths.val
    check "/p/src" in expanded
    tabSwitch(w, noir, edit)
    writeEditProject(w)
    tabSwitch(w, edit, noir)
    check w.tests.catalog.val == catalog
    check w.tests.recordings.val == recordings
    check w.tests.projectName.val == "hello_noir"
    check w.tests.runAbsence.val == ""
    check w.constraints.report.val == report
    check w.constraints.projectName.val == "hello_noir"
    check w.files.expandedPaths.val == expanded
    # And the edit tab gets its own back, too.
    tabSwitch(w, noir, edit)
    check w.tests.runAbsence.val == NoProject
    check w.constraints.report.val.absence == NoProject
    check w.tests.catalog.val.len == 0

  test "what the host installed for the window survives a first entry":
    let w = newWindow()
    var calls = 0
    w.tests.setRunTests(proc(): string =
      inc calls
      "")
    w.tests.beginRun()
    tabSwitch(w, Tab(), Tab())
    check w.tests.inFlight.val
    check not w.tests.runTests.val.isNil
    let runner = w.tests.runTests.val
    discard runner()
    check calls == 1

  test "panes whose ViewModel does not exist yet are skipped":
    let snapshot = captureSharedPanes(nil, nil, nil)
    check not snapshot.hasTestResults
    check not snapshot.hasConstraints
    check not snapshot.hasFilesystem
    resetSharedPanes(nil, nil, nil)
    restoreSharedPanes(snapshot, nil, nil, nil)
    restoreSharedPanes(nil, nil, nil, nil)
