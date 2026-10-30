## test_test_tab_placement.nim — WHICH TAB A TEST'S RECORDING OPENS IN, on
## every front-end: the one rule the desktop, the terminal and the GPUI window
## share.
##
## LANE: `vm-unit`, `vm-unit-js` and `vm-unit-wasm`, by the directory glob.
##
## Spec: `GUI/Core-Panes/Test-Results-Pane.md` §9 (and Multi-Window-Tab-
## Management's "Which tab a replay opens in"). Issue: codetracer-pm
## `issues/2026-10-24-desktop-test-results-opens-a-recording-in-place-not-in-a-new-tab.md`.
##
## Asserted:
##
##   * §9.1's FOUR ARMS, in order — the test's own tab shown when it holds
##     this recording, replaced in place when it holds an older one (rule 4),
##     the current tab replaced when it is the destination and a replay, a
##     new tab otherwise — and rule 3: an editing session (a current tab that
##     cannot be replaced) is never the answer;
##   * §9.2's BOOKKEEPING: one test per tab, a closed tab forgotten, a
##     replacement's new id followed;
##   * §9.3's MODIFIER inverts the setting, either way, for one press;
##   * §9.4's SENTENCES, and that the `⏵` title ends with the one the press
##     would act on (a disabled title has none);
##   * the `replay-open-in` DOCUMENT: round trip, the last line for a
##     workspace wins, unknown values and malformed lines fall back to the
##     default, separators trimmed, the palette's targets;
##   * THE DESKTOP HOST OPENS AFTER IT RECORDS (§9.5), and only then: record-
##     and-open and the editor's Run-test hand the recording to the host's
##     `openRecording` on the settle, with the destination captured AT THE
##     PRESS (the modifier released before the recorder answers); `⟳` opens
##     nothing; a failed record opens nothing; an open the front-end refuses
##     is said on the pane; with no opener installed the pane says so;
##   * §9.3's PALETTE PAIR: **Tests: Run** / **Tests: Run in Current Tab** —
##     their labels and omnibox targets, one per destination; `runTestIn`
##     RECORDS the test (also when a recording exists) and the host captures
##     THE COMMAND's destination, neither the setting's nor a held
##     modifier's, the hold released after the dispatch; §9.1 still places
##     it (an editing session is not replaced); the started note says where;
##     no selection, a test the catalog dropped, a run in flight and a host
##     that refuses at once each answer their own sentence and record
##     nothing;
##   * THE PROJECT'S RUN (Edit-Mode-Toolbar.md §9.4, EMT-D32/D33): the
##     palette pair **Project: Run** / **Project: Run in Current Tab** — labels
##     and targets, distinct from both test pairs, listed in the omnibox;
##     `runProgramIn` dispatches the project's folder with THE COMMAND's
##     destination (the setting and a held Ctrl ignored), begins no run in the
##     pane, holds the host's one pending run (a second run of either kind is
##     refused, a test's settle does not end it); its settle opens the
##     recording under the project's key, where §9.1 places it — a re-run
##     reuses the run's own tab (rule 4), an editing session is never the
##     destination (rule 3); no project, a project with no Run (the toolbar
##     model's own reason), no route, a refused dispatch, a recorder failure
##     and an exit with no recording each say their sentence and open nothing.
##
## THE ONE STAND-IN, and why it is not a mock: the host's two effects — the
## dispatch (an IPC send, in the product) and `openRecording` (a new session
## tab, in the product) — are closures that record what they were handed.
## They are the process and window boundaries `desktop_test_host` takes as
## injected values precisely so this half can be asserted without either
## (`test_desktop_test_run_settles.nim`'s reasoning); the ViewModel, the
## host's state machine and the settle run for real. The terminal and the GPUI
## window perform the placements against their real tabs in the `tui`,
## `tui-real-terminal` and `gpui-shell` suites.

import std/[strutils, unittest]

import isonim/core/[owner, signals, computation]

import ../../../../ct_test/contracts
import ../../viewmodels/test_results_vm
import ../../viewmodels/desktop_test_host
import ../../viewmodels/replay_open_setting
import ../../viewmodels/omnibar_sources
import ../../viewmodels/edit_mode_toolbar
import ../../platform/capabilities

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

const ExpectedAssertions = 159

proc item(id, selector: string; line: int): TestItem =
  TestItem(id: id, providerId: "noir-nargo", language: "noir",
           framework: "nargo test", name: selector, kind: tikCase,
           file: "src/main.nr",
           range: SourceRange(startLine: line, startColumn: 1,
                              endLine: line, endColumn: 1),
           selector: selector, parentId: "", tags: @[],
           location: LocationProvenance(source: lskParser, detail: "",
                                        confidence: lcHigh),
           stale: false, staleReason: "")

proc rowFor(vm: TestResultsVM; testId: string): TestResultsRow =
  for row in vm.rows.val:
    if row.testId == testId:
      return row
  TestResultsRow()

type
  Opened = object
    testId, recordingId: string
    policy: TraceOpenPolicy

  Spies = ref object
    recordOpening, recordKeeping: int
    opened: seq[Opened]
    openRefuseWith: string
    programRuns: seq[string]
      ## The project folders the project's Run was dispatched for.
    programRefuseWith: string
    notes: seq[string]
      ## What the host said about a Run that opened nothing.

proc hostOver(vm: TestResultsVM; spies: Spies; withOpener = true):
    DesktopTestHost =
  ## The desktop host over `vm`, installed as the `if inElectron:` block
  ## installs it: the opening dispatch, `⟳`'s keep-window dispatch and the
  ## opener.
  result = newDesktopTestHost(vm,
    dispatch = proc(selector, file: string; line: int): string =
      inc spies.recordOpening
      "",
    settleEditor = nil)
  var opener: DesktopOpenRecording = nil
  if withOpener:
    opener = proc(testId, recordingId: string;
                  policy: TraceOpenPolicy): string =
      spies.opened.add Opened(testId: testId, recordingId: recordingId,
                              policy: policy)
      spies.openRefuseWith
  result.installDesktopSuiteRun(
    workspaceRoot = proc(): string = "/proj",
    suiteDispatch = proc(workspaceRoot: string): string = "")
  result.installDesktopRowActions(
    keepWindowDispatch = proc(selector, file: string; line: int): string =
      inc spies.recordKeeping
      "",
    openRecording = opener)
  result.installDesktopProgramRun(
    dispatch = proc(workspaceRoot: string): string =
      spies.programRuns.add workspaceRoot
      spies.programRefuseWith,
    note = proc(text: string) = spies.notes.add text)

proc noirRun(): ToolbarButton =
  ## The toolbar's Run for a Noir package, as the desktop composes it.
  editModeToolbar(desktopProfile, EditMode,
                  listing = @["Nargo.toml", "src/main.nr"]).run

suite "§9.1: one placement rule":

  test "the four arms, in order, and rule 3":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      # The default: nothing known, a new tab.
      ck vm.placeTestRecording("a", "rec-1", topNewTab).kind == ttpNewTab
      # The current tab is the destination, but it is an EDITING session (or
      # no tab at all): rule 3 — a new tab.
      vm.setCurrentTab(4, replaceable = false)
      ck vm.placeTestRecording("a", "rec-1", topCurrentTab).kind == ttpNewTab
      vm.setCurrentTab(-1, replaceable = true)
      ck not vm.currentTabReplaceable.val
      ck vm.placeTestRecording("a", "rec-1", topCurrentTab).kind == ttpNewTab
      # A replay is current and is the destination: arm 3, replaced.
      vm.setCurrentTab(7, replaceable = true)
      let current = vm.placeTestRecording("a", "rec-1", topCurrentTab)
      ck current.kind == ttpReplaceTab and current.tab == 7
      ck vm.placeTestRecording("a", "rec-1", topNewTab).kind == ttpNewTab
      # The test has a tab: arm 1 when it holds this recording …
      vm.noteTestTab("a", 3, "rec-1")
      let shown = vm.placeTestRecording("a", "rec-1", topNewTab)
      ck shown.kind == ttpShowTab and shown.tab == 3
      # … arm 2 when it holds an older one — whatever the destination.
      let again = vm.placeTestRecording("a", "rec-2", topNewTab)
      ck again.kind == ttpReplaceTab and again.tab == 3
      let againHere = vm.placeTestRecording("a", "rec-2", topCurrentTab)
      ck againHere.kind == ttpReplaceTab and againHere.tab == 3
      # Another test has no tab: the destination decides.
      ck vm.placeTestRecording("b", "rec-9", topNewTab).kind == ttpNewTab
      dispose()

suite "§9.2: a test's tab":

  test "one test per tab, a closed tab forgotten, a moved id followed":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.noteTestTab("a", 1, "rec-a")
      vm.noteTestTab("b", 2, "rec-b")
      ck vm.testTabOf("a") == 1 and vm.testTabOf("b") == 2
      # The same test again: its entry moves, it is not duplicated.
      vm.noteTestTab("a", 5, "rec-a2")
      ck vm.testTabOf("a") == 5
      ck vm.testTabs.val.len == 2
      # Another test's recording replaced tab 2: b no longer has a tab.
      vm.noteTestTab("c", 2, "rec-c")
      ck vm.testTabOf("b") == -1 and vm.testTabOf("c") == 2
      # Tab 5 closed.
      vm.forgetTestTab(5)
      ck vm.testTabOf("a") == -1
      # A replacement gave tab 2 a new id.
      vm.movedTestTab(2, 8)
      ck vm.testTabOf("c") == 8
      # Nonsense is refused rather than filed.
      vm.noteTestTab("", 3, "x")
      vm.noteTestTab("d", -1, "x")
      ck vm.testTabs.val.len == 1
      dispose()

suite "§9.3: the setting and the modifier":

  test "the modifier inverts the setting for one press, either way":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      ck vm.openSetting.val == topNewTab
      ck vm.effectiveOpenPolicy() == topNewTab
      vm.setRedirectHeld(true)
      ck vm.effectiveOpenPolicy() == topCurrentTab
      vm.setOpenSetting(topCurrentTab)
      ck vm.effectiveOpenPolicy() == topNewTab
      vm.setRedirectHeld(false)
      ck vm.effectiveOpenPolicy() == topCurrentTab
      ck vm.effectiveOpenPolicy(redirect = true) == topNewTab
      ck topNewTab.invert() == topCurrentTab and
         topCurrentTab.invert() == topNewTab
      dispose()

suite "§9.4: what the ⏵ title says":

  test "every sentence, from the facts the press reads":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: @[item("a", "test_a", 5), item("b", "test_b", 9)]))
      let a = vm.rowFor("a")
      # An editing session is current (the desktop's pane): a new tab.
      vm.setCurrentTab(1, replaceable = false)
      ck vm.openDestinationText(a) == OpensInNewTabText
      # A replay is current: the destination and the other gesture.
      vm.setCurrentTab(2, replaceable = true)
      ck vm.openDestinationText(a) ==
        "Opens in a new tab; Ctrl+click opens it in this tab."
      vm.setRedirectHeld(true)
      ck vm.openDestinationText(a) ==
        "Opens in this tab, ending its session; release Ctrl opens a new tab."
      vm.setRedirectHeld(false)
      vm.setOpenSetting(topCurrentTab)
      ck vm.openDestinationText(a) ==
        "Opens in this tab, ending its session; Ctrl+click opens a new tab."
      vm.redirectKeyName = "Cmd"
      vm.setRedirectHeld(true)
      ck vm.openDestinationText(a) ==
        "Opens in a new tab; release Cmd opens it in this tab."
      vm.setRedirectHeld(false)
      vm.redirectKeyName = RedirectKeyName
      # The test has a tab: rule 4 is what the press will do.
      vm.noteTestTab("a", 6, "rec-a")
      ck vm.openDestinationText(a) == OpensInOwnTabText
      ck vm.openDestinationText(vm.rowFor("b")) ==
        "Opens in this tab, ending its session; Ctrl+click opens a new tab."
      # A front-end with no session tabs says what it does instead.
      vm.setSessionTabsShown(false)
      ck vm.openDestinationText(vm.rowFor("b")) == NoSessionTabsOpenText
      dispose()

  test "the title ends with it; a disabled title does not":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: @[item("a", "test_a", 5)]))
      vm.setCurrentTab(1, replaceable = false)
      # No host installed: the control is disabled, with its reason only.
      let disabled = vm.openButtonTitle(vm.rowFor("a"))
      ck not disabled.endsWith(OpensInNewTabText)
      let spies = Spies()
      discard hostOver(vm, spies)
      let title = vm.openButtonTitle(vm.rowFor("a"))
      ck title.startsWith("Record test_a and open the recording (")
      ck title.endsWith(" " & OpensInNewTabText)
      vm.rememberRecording("a", "rec-a", "10:00:00 AM")
      ck vm.openButtonTitle(vm.rowFor("a")) ==
        "Open the recording of test_a from 10:00:00 AM — nothing is re-run. " &
        "Hold Shift to record it again first. " & OpensInNewTabText
      dispose()

suite "the replay-open-in document":

  test "round trip, last line wins, unknown values default, separators trimmed":
    let doc = withReplayOpen("", "/home/me/proj/", topCurrentTab)
    ck doc == "/home/me/proj\tcurrent-tab\n"
    ck replayOpenFor(doc, "/home/me/proj") == topCurrentTab
    ck replayOpenFor(doc, "/home/me/proj///") == topCurrentTab
    ck replayOpenFor(doc, "/home/me/other") == topNewTab
    ck replayOpenFor(doc, "") == topNewTab
    # Another workspace is kept, in its order; setting one again replaces its
    # line rather than adding a second.
    let two = withReplayOpen(withReplayOpen(doc, "/w2", topNewTab),
                             "/home/me/proj", topNewTab)
    ck decodeReplayOpen(two).len == 2
    ck decodeReplayOpen(two)[0].workspace == "/w2"
    ck replayOpenFor(two, "/home/me/proj") == topNewTab
    # A hand-edited file: the last line for a workspace wins; comments, junk
    # and an unknown value are skipped.
    let edited = "# mine\n/p\tcurrent-tab\nnot a line\n/p\tsideways\n" &
                 "/q\tCURRENT-TAB\r\n"
    ck replayOpenFor(edited, "/p") == topCurrentTab
    ck replayOpenFor(edited, "/q") == topCurrentTab
    ck decodeReplayOpen(edited).len == 2
    ck replayOpenFor("garbage", "/p") == topNewTab

  test "the palette's commands, by their labels and targets":
    for policy in [topNewTab, topCurrentTab]:
      let (ok, back) = parseReplayOpenCommandTarget(
        replayOpenCommandTarget(policy))
      ck ok and back == policy
    ck replayOpenCommandLabel(topNewTab) == OpenRecordingsInNewTabLabel
    ck replayOpenCommandLabel(topCurrentTab) == OpenRecordingsInCurrentTabLabel
    ck not parseReplayOpenCommandTarget("layoutSetting:x:y").ok
    ck not parseReplayOpenCommandTarget(ReplayOpenCommandPrefix & "nope").ok
    ck replayOpenSetNote("/p/", topCurrentTab) ==
      "test recordings open in the current tab in /p"

suite "§9.3: the palette pair, Tests: Run and Tests: Run in Current Tab":

  test "their labels and targets, one per destination":
    ck runTestCommandLabel(topNewTab) == "Tests: Run"
    ck runTestCommandLabel(topCurrentTab) == "Tests: Run in Current Tab"
    for policy in [topNewTab, topCurrentTab]:
      let (ok, back) = parseRunTestCommandTarget(runTestCommandTarget(policy))
      ck ok and back == policy
      # Not the setting's command: the two pairs never read as each other.
      ck not parseReplayOpenCommandTarget(runTestCommandTarget(policy)).ok
      ck not parseRunTestCommandTarget(replayOpenCommandTarget(policy)).ok
    ck runTestCommandDetail(topCurrentTab).endsWith("in the current tab")
    ck not parseRunTestCommandTarget(RunTestCommandPrefix & "nope").ok

  test "the command's destination is captured, the setting and Ctrl ignored":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: @[item("a", "test_a", 5), item("b", "test_b", 9)]))
      let spies = Spies()
      let host = hostOver(vm, spies)
      # A replay tab is current; the setting is the current tab and Ctrl is
      # held — **Tests: Run** still opens a NEW tab.
      vm.setCurrentTab(4, replaceable = true)
      vm.setOpenSetting(topCurrentTab)
      vm.setRedirectHeld(true)
      vm.selectTest("a")
      ck vm.runTestStartedText("a", topNewTab) ==
        "recording test_a; it opens in a new tab"
      ck vm.runSelectedTestIn(topNewTab) == ""
      ck spies.recordOpening == 1
      ck not vm.hasCommandPolicy   # held for that one dispatch only
      ck vm.effectiveOpenPolicy() == topNewTab   # Ctrl inverting the setting
      vm.setRedirectHeld(false)
      host.settleDesktopTestRun(recordingId = "rec-a", recordedAtText = "t")
      ck spies.opened.len == 1 and spies.opened[0].policy == topNewTab
      # **Run in Current Tab** RECORDS AGAIN although a recording exists, and
      # opens at the current tab whatever the setting says.
      vm.setOpenSetting(topNewTab)
      ck vm.rowFor("a").hasRecording()
      ck vm.runTestStartedText("b", topCurrentTab) ==
        "recording test_b; it opens in this tab"
      ck vm.runTestIn("b", topCurrentTab) == ""
      ck spies.recordOpening == 2
      host.settleDesktopTestRun(recordingId = "rec-b", recordedAtText = "t")
      ck spies.opened.len == 2 and spies.opened[1].policy == topCurrentTab
      ck spies.opened.len == 2 and spies.opened[1].testId == "b"
      # §9.1 still places it: from an EDITING session the current tab is no
      # destination (rule 3), and the note says so.
      vm.setCurrentTab(0, replaceable = false)
      ck vm.runTestStartedText("a", topCurrentTab) ==
        "recording test_a; it opens in a new tab"
      dispose()

  test "no selection, a dropped test, a run in flight, a refusal: said":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: @[item("a", "test_a", 5)]))
      let spies = Spies()
      discard hostOver(vm, spies)
      ck vm.runSelectedTestIn(topNewTab) == NoTestSelectedText
      vm.selectTest("gone")
      ck vm.runSelectedTestIn(topNewTab) == TestNotListedText
      vm.selectTest("a")
      ck vm.runSelectedTestIn(topNewTab) == ""
      ck vm.runSelectedTestIn(topCurrentTab) == RunInProgressText
      ck spies.recordOpening == 1
      dispose()
    createRoot proc(dispose: proc()) =
      # A host that refuses AT ONCE: its sentence, not "recording …".
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: @[item("a", "test_a", 5)]))
      let host = newDesktopTestHost(vm,
        dispatch = proc(selector, file: string; line: int): string =
          "the recorder is busy",
        settleEditor = nil)
      host.installDesktopRowActions(
        keepWindowDispatch = proc(selector, file: string; line: int): string =
          "",
        openRecording = proc(testId, recordingId: string;
                             policy: TraceOpenPolicy): string = "")
      ck vm.runTestIn("a", topNewTab) == "the recorder is busy"
      ck not vm.inFlight.val
      dispose()
    createRoot proc(dispose: proc()) =
      # No host: nothing can record.
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: @[item("a", "test_a", 5)]))
      ck vm.runTestIn("a", topNewTab) == NoRecorderHostText
      dispose()

suite "Edit-Mode-Toolbar §9.4: the project's Run":

  test "the palette pair's labels and targets, in the omnibox":
    ck runProgramCommandLabel(topNewTab) == "Project: Run"
    ck runProgramCommandLabel(topCurrentTab) == "Project: Run in Current Tab"
    for policy in [topNewTab, topCurrentTab]:
      let (ok, back) = parseRunProgramCommandTarget(
        runProgramCommandTarget(policy))
      ck ok and back == policy
      # Neither test pair's command reads as the project's, nor the other way.
      ck not parseRunTestCommandTarget(runProgramCommandTarget(policy)).ok
      ck not parseReplayOpenCommandTarget(runProgramCommandTarget(policy)).ok
      ck not parseRunProgramCommandTarget(runTestCommandTarget(policy)).ok
    var targets: seq[string] = @[]
    for entry in replayOpenCommands():
      targets.add entry.target
    ck runProgramCommandTarget(topNewTab) in targets
    ck runProgramCommandTarget(topCurrentTab) in targets
    ck noirRun().enabled

  test "the command's destination, the pane untouched, one pending run":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: @[item("a", "test_a", 5)]))
      let spies = Spies()
      let host = hostOver(vm, spies)
      # A replay is current; the setting says the current tab and Ctrl is
      # held — **Project: Run** still opens a NEW tab.
      vm.setCurrentTab(4, replaceable = true)
      vm.setOpenSetting(topCurrentTab)
      vm.setRedirectHeld(true)
      ck host.programRunStartedText(topNewTab) ==
        "recording /proj; it opens in a new tab"
      ck host.runProgramIn(topNewTab, noirRun()) == ""
      ck spies.programRuns == @["/proj"]
      ck host.programRunning
      # A program is not a test: the pane begins no run.
      ck not vm.inFlight.val
      # One run per window, of either kind.
      ck host.runProgramIn(topCurrentTab, noirRun()) ==
        ProgramRunAlreadyGoingText
      ck host.startDesktopTestRun("test_a", "/proj/src/main.nr", 5) ==
        DesktopRunAlreadyGoingText
      # A test's settle does not end it.
      host.settleDesktopTestRun(recordingId = "rec-t", recordedAtText = "t")
      ck host.programRunning and spies.opened.len == 0
      host.settleDesktopProgramRun(recordingId = "rec-1")
      ck not host.programRunning
      ck spies.opened.len == 1 and
        spies.opened[0].testId == programRunKey("/proj/")
      ck spies.opened.len == 1 and spies.opened[0].recordingId == "rec-1"
      ck spies.opened.len == 1 and spies.opened[0].policy == topNewTab
      ck spies.notes.len == 0
      dispose()

  test "rule 4: a re-run reuses the run's tab; rule 3: an editing session":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      let spies = Spies()
      let host = hostOver(vm, spies)
      let key = programRunKey("/proj")
      vm.setCurrentTab(4, replaceable = true)
      # **Run in Current Tab** from a replay replaces it …
      ck host.programRunStartedText(topCurrentTab) ==
        "recording /proj; it opens in this tab"
      ck vm.placeTestRecording(key, "rec-1", topCurrentTab) ==
        TestTabPlacement(kind: ttpReplaceTab, tab: 4)
      # … and once the run has a tab, a re-run goes there, whatever the
      # destination: the same program again compares nothing.
      vm.noteTestTab(key, 7, "rec-1")
      ck host.programRunStartedText(topNewTab) ==
        "recording /proj; it opens in the tab it already has"
      ck vm.placeTestRecording(key, "rec-2", topNewTab) ==
        TestTabPlacement(kind: ttpReplaceTab, tab: 7)
      ck vm.placeTestRecording(key, "rec-1", topNewTab) ==
        TestTabPlacement(kind: ttpShowTab, tab: 7)
      # A tab holds one thing: a test placed in the run's tab takes it.
      vm.noteTestTab("a", 7, "rec-a")
      ck vm.testTabOf(key) == -1
      # An editing session is never the destination.
      vm.setCurrentTab(0, replaceable = false)
      ck host.programRunStartedText(topCurrentTab) ==
        "recording /proj; it opens in a new tab"
      dispose()

  test "no project, no Run, no route, a refusal, a failure: said":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      let spies = Spies()
      let host = hostOver(vm, spies)
      # A folder CodeTracer does not recognise: the toolbar's own reason.
      let notes = editModeToolbar(desktopProfile, EditMode,
                                  listing = @["notes.txt"]).run
      ck not notes.enabled
      ck host.runProgramIn(topNewTab, notes) == notes.reason
      ck notes.reason.len > 0
      ck spies.programRuns.len == 0
      # The dispatch refuses at once: its sentence, and nothing pending.
      spies.programRefuseWith = "the recorder is busy"
      ck host.runProgramIn(topNewTab, noirRun()) == "the recorder is busy"
      ck not host.programRunning
      spies.programRefuseWith = ""
      # The recorder failed: its words, nothing opened.
      ck host.runProgramIn(topNewTab, noirRun()) == ""
      host.settleDesktopProgramRun(errorMessage = "ct record error: no main")
      ck spies.notes == @["ct record error: no main"]
      # Exit 0 with no recording is its own verdict (EMT-D16).
      ck host.runProgramIn(topNewTab, noirRun()) == ""
      host.settleDesktopProgramRun()
      ck spies.notes.len == 2 and spies.notes[1] == ProgramNoRecordingText
      ck spies.opened.len == 0
      # A settle with no program run pending changes nothing.
      host.settleDesktopProgramRun(recordingId = "stray")
      ck spies.opened.len == 0
      dispose()
    createRoot proc(dispose: proc()) =
      # No project folder open.
      let vm = createTestResultsVM()
      let host = newDesktopTestHost(vm, dispatch = nil, settleEditor = nil)
      host.installDesktopProgramRun(
        dispatch = proc(workspaceRoot: string): string = "",
        note = nil)
      ck host.runProgramIn(topNewTab, noirRun()) == NoProgramProjectText
      # No route at all.
      let bare = newDesktopTestHost(vm, dispatch = nil, settleEditor = nil)
      ck bare.runProgramIn(topNewTab, noirRun()) == NoProgramRouteText
      dispose()

suite "§9.5: the desktop host opens after it records":

  test "record-and-open opens on the settle, where the press chose":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: @[item("a", "test_a", 5), item("b", "test_b", 9)]))
      let spies = Spies()
      let host = hostOver(vm, spies)
      # ⏵ with no recording, Ctrl held at the press …
      ck vm.openButtonMode(vm.rowFor("a")) == obmRecordAndOpen
      vm.setRedirectHeld(true)
      vm.triggerOpen(vm.rowFor("a"))
      vm.setRedirectHeld(false)
      ck spies.recordOpening == 1
      # … nothing is opened while it records …
      ck spies.opened.len == 0
      ck vm.inFlight.val
      # … and the settle opens it, for the destination of THE PRESS.
      host.settleDesktopTestRun(recordingId = "rec-a",
                                recordedAtText = "10:00:00 AM")
      ck not vm.inFlight.val
      ck spies.opened.len == 1
      ck spies.opened.len == 1 and spies.opened[0].testId == "a"
      ck spies.opened.len == 1 and spies.opened[0].recordingId == "rec-a"
      ck spies.opened.len == 1 and spies.opened[0].policy == topCurrentTab
      ck vm.rowFor("a").recordingId == "rec-a"
      # ⏵ again opens the recording it has, by id, for the destination now.
      vm.triggerOpen(vm.rowFor("a"))
      ck spies.recordOpening == 1
      ck spies.opened.len == 2 and spies.opened[1].recordingId == "rec-a"
      ck spies.opened.len == 2 and spies.opened[1].policy == topNewTab
      dispose()

  test "the editor's Run-test opens too; ⟳ and a failed record open nothing":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: @[item("a", "test_a", 5), item("b", "test_b", 9)]))
      let spies = Spies()
      let host = hostOver(vm, spies)
      # The editor's control — the same opening dispatch.
      ck host.startDesktopTestRun("test_b", "/proj/src/main.nr", 9) == ""
      host.settleDesktopTestRun(recordingId = "rec-b", recordedAtText = "t")
      ck spies.opened.len == 1 and spies.opened[0].testId == "b"
      # ⟳ records and stays: its settle opens nothing.
      vm.triggerRefresh(vm.rowFor("a"))
      ck spies.recordKeeping == 1
      host.settleDesktopTestRun(recordingId = "rec-a2", recordedAtText = "t")
      ck spies.opened.len == 1
      ck vm.rowFor("a").recordingId == "rec-a2"
      # A record that made nothing opens nothing, and says why.
      vm.setShiftHeld(true)
      vm.triggerOpen(vm.rowFor("a"))
      vm.setShiftHeld(false)
      ck spies.recordOpening == 2
      host.settleDesktopTestRun(errorMessage = "ct record-test error: no")
      ck spies.opened.len == 1
      ck vm.headline.val == RunFailedHeadline
      dispose()

  test "a refused open is said on the pane; no opener is said too":
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: @[item("a", "test_a", 5)]))
      let spies = Spies(openRefuseWith: "this window has no session tabs")
      let host = hostOver(vm, spies)
      vm.triggerOpen(vm.rowFor("a"))
      host.settleDesktopTestRun(recordingId = "rec-a", recordedAtText = "t")
      ck spies.opened.len == 1
      ck vm.runFailure.val.join(" ").contains("this window has no session tabs")
      dispose()
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: @[item("a", "test_a", 5)]))
      let spies = Spies()
      let host = hostOver(vm, spies, withOpener = false)
      vm.triggerOpen(vm.rowFor("a"))
      ck spies.recordOpening == 1
      host.settleDesktopTestRun(recordingId = "rec-a", recordedAtText = "t")
      ck spies.opened.len == 0
      ck vm.runFailure.val.join(" ").contains(NoReplayHostText)
      dispose()

  test "the assertion count":
    check asserted == ExpectedAssertions
