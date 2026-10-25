## NOT-A-TEST-LANE-FILE: this is the terminal's Test Results HOST — production
## frontend code named after the test results it fills, which is why its
## basename matches the guard's `test_*` name arm. It imports no `unittest`
## and declares no `suite`/`test` block. It is asserted by
## `src/frontend/tui/tests/test_plat53_test_results_host.nim` (the `tui`
## lane) and the shipped binary's pty suite.

## tui/host/test_results_source.nim — PLAT-53. **The terminal's Test Results
## pane is filled from the desktop's ViewModel, by the desktop's host.**
##
## The host half of the pane, as `vcs_source.nim` is the VCS pane's: it owns
## the window's `TestResultsVM` and the `NativeTestHost` that runs its suite
## and records its tests (`viewmodel/host/native_test_host.nim`, the desktop's
## `desktop_test_host` over native producers), and hands the app layer the
## value `views/test_results_pane.nim` paints.
##
## ONE PER WINDOW, NOT PER TAB (`Test-Results-Pane.md` §8.2): every tab of the
## terminal shares its project (`app.projectRoot`), so a test's recording
## opened in a new tab leaves the run's verdicts on screen in the tab it was
## opened from and in the new one.
##
## Polled from the loop that reads the keyboard (`tick`), so the screen keeps
## answering while a suite runs; `close` ends a run still going (its whole
## process group) when the loop ends.

import ../../viewmodel/host/native_test_host
import ../app/runtime
import ../app/tui_app
import ../app/views/test_results_pane

import isonim/core/[owner, computation]

const
  NoSessionTabsText* =
    "this window has no session tabs (it was started with `ct edit`), so " &
    "the recording is not opened here; it is at "
    ## The `⏵` refusal of a terminal with no session tabs, followed by the
    ## recording's folder (`Test-Results-Pane.md` §8.3): stated on the pane,
    ## never a silent no-op.

type
  TestsSource* = ref object
    vm*: TestResultsVM
    host*: NativeTestHost
    dispose: proc()

proc controlOf(label, title: string; enabled: bool;
               mode = ""): TestsPaneControl =
  TestsPaneControl(label: label, title: title, enabled: enabled, mode: mode)

proc toneOf(state: TestResultsRowState): TestsTone =
  case state
  of trsPassed: ttoPassed
  of trsFailed, trsErrored: ttoFailed
  of trsNotRun: ttoNotRun
  of trsRunning, trsSkipped, trsCancelled: ttoOther

proc lineKindOf(kind: TestResultsDisplayKind): TestsPaneLineKind =
  case kind
  of tdRow: tlRow
  of tdMessage: tlMessage
  of tdFailure: tlFailure
  of tdAbsence: tlAbsence
  of tdEmpty: tlEmpty

proc paneModelOf*(vm: TestResultsVM): TestResultsPaneModel =
  ## The shared ViewModel as the pane's value — every word the ViewModel's
  ## (the desktop's view reads the same procs), nothing derived here. The
  ## terminal cannot hold Shift (§8.4), so `⏵`'s title names `⟳` instead.
  result = TestResultsPaneModel(loaded: true, headline: vm.headline.val,
                                selected: -1)
  result.run = controlOf(RunButtonLabel, vm.runButtonTitle(), vm.canRun())
  for row in vm.rows.val:
    result.rows.add TestsPaneRow(
      testId: row.testId, selector: row.selector, state: $row.state,
      tone: toneOf(row.state), mark: stateMark(row.state), name: row.name,
      where: rowWhere(row), duration: rowDuration(row),
      recordingId: row.recordingId,
      refresh: controlOf("⟳", vm.refreshButtonTitle(row),
                         vm.refreshAbsence().len == 0),
      open: controlOf(vm.openButtonMark(row),
                      vm.openButtonTitle(row, shiftReachable = false),
                      vm.openAbsence(row).len == 0,
                      $vm.openButtonMode(row)))
  for d in vm.displayRows():
    result.lines.add TestsPaneLine(kind: lineKindOf(d.kind), row: d.row,
                                   text: d.text)

proc newTestsSource*(projectRoot: NativeProjectRoot;
                     ctBinary: NativeCtBinary;
                     resolveFolder: NativeResolveFolder;
                     openFolder: NativeOpenFolder): TestsSource =
  ## A source for the window's project, its host installed on a fresh
  ## `TestResultsVM`.
  result = TestsSource()
  let src = result
  createRoot proc(dispose: proc()) =
    src.vm = createTestResultsVM()
    src.dispose = dispose
  src.host = newNativeTestHost(src.vm, projectRoot, ctBinary, resolveFolder,
                               openFolder)

proc publish*(s: TestsSource; rt: TuiRuntime) =
  ## Hand the app layer the pane's value. The selection and the reading
  ## position are the reader's, so a re-read keeps them (the painter clamps
  ## the scroll; a selection past the rows is dropped).
  if s.isNil:
    return
  let selected = rt.app.tests.selected
  let top = rt.app.tests.scrollTop
  rt.app.tests = paneModelOf(s.vm)
  rt.app.tests.selected = if selected < rt.app.tests.rows.len: selected
                          else: -1
  rt.app.tests.scrollTop = top

proc refresh*(s: TestsSource; rt: TuiRuntime; force = false) =
  ## Read the project's catalog (when the project changed, or `force`) and
  ## publish.
  if s.isNil:
    return
  discard s.host.refreshCatalog(force)
  s.publish(rt)

proc tick*(s: TestsSource; rt: TuiRuntime): bool =
  ## Settle a run that ended, follow a re-rooted project, and say what the
  ## host has to say. Whether the pane (or the status line) changed.
  if s.isNil:
    return false
  let settled = s.host.poll()
  let rerooted = s.host.refreshCatalog()
  let note = s.host.takeNote()
  if note.len > 0:
    rt.app.notification = note
  if settled or rerooted:
    s.publish(rt)
  settled or rerooted or note.len > 0

proc rowOf(s: TestsSource; testId: string): int =
  s.vm.rowOfTest(testId)

proc applyClick*(s: TestsSource; rt: TuiRuntime; c: PaneClickRequest): bool =
  ## A press on the ▶, a `⟳` or a `⏵` (`runtime.routePaneClick`), through
  ## the ViewModel's own guards — the procs the desktop's click handlers
  ## call. Answers whether the click was the pane's.
  if s.isNil:
    return false
  case c.kind
  of pcTestsRun:
    s.vm.startRun()
  of pcTestsRefresh, pcTestsOpen:
    let i = s.rowOf(c.text)
    if i < 0:
      rt.app.notification = "that test is no longer listed"
      return true
    let row = s.vm.rows.val[i]
    if c.kind == pcTestsRefresh: s.vm.triggerRefresh(row)
    else: s.vm.triggerOpen(row)
  else:
    return false
  let note = s.host.takeNote()
  if note.len > 0:
    rt.app.notification = note
  s.publish(rt)
  true

proc close*(s: TestsSource) =
  ## End a run still going and release the ViewModel.
  if s.isNil:
    return
  s.host.stop()
  if not s.dispose.isNil:
    s.dispose()
