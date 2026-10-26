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
##     is said on the pane; with no opener installed the pane says so.
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

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

const ExpectedAssertions = 81

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
