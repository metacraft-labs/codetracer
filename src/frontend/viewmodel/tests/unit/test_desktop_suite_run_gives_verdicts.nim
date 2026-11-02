## THE DESKTOP ▶ RUNS THE SUITE, AND THE PANE SHOWS WHAT THE RUNNER SAID.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_desktop_suite_run_gives_verdicts.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_desktop_suite_run_gives_verdicts.nim
##
## Spec: `GUI/Core-Panes/Test-Results-Pane.md` §3 (what a host installs), §4.3
## (the controls the desktop host left nil) and §5 (a run settles, however it
## ended). Issue: codetracer-pm
## `issues/2026-10-20-desktop-test-runs-give-no-verdict-the-ct-test-runner-is-not-wired.md`
## (GitHub #748, pxor's comment of 2026-10-01).
##
## ## The defect, as it was on the tree
##
## The desktop host (`desktop_test_host.nim`) installed the editor's Run-test
## control and nothing else. `TestResultsVM.runTests` and the three per-row
## actions stayed nil on the Electron arm, so the pane's header ▶ and every
## row's `⟳` / `⏵` rendered disabled ("No host in this build can run the
## tests"), and the only desktop run was `ct record-test` — a RECORDING, which
## by design carries no verdict. A desktop user therefore never saw a test
## pass or fail, while the same project in a browser did: "the desktop version
## can't run tests from the Monaco editor, while the online version running the
## same trace can".
##
## The runner that adjudicates now ships (`ct test run` hands the run to the
## ORC-built `ct-test` beside `ct`), and `ct-test test run --events <path>`
## writes the run's per-test `TestEvent`s as JSON Lines. This suite asserts the
## host's half: it installs the ▶ and the row controls, dispatches a suite run,
## and folds what the runner wrote onto the catalog's rows.
##
## ## Why these checks are shaped the way they are
##
## **THEY ASSERT PAINTED TEXT AND PAINTED CLASSES.** The pane is mounted with
## `MockRenderer`, and the headline, the failure block and each row's state
## class are read back out of the rendered tree. "`ingestEvent` was called" and
## "a user can see the test failed" are different claims; only the second is
## the product.
##
## **THE CLICK IS THE VIEW-MODEL'S OWN.** The ▶ is driven through
## `TestResultsVM.startRun` and the row controls through `triggerRefresh` /
## `triggerOpen` — the exact procs the view's click handlers call — so a host
## that installed its procs somewhere the pane does not read would fail here.
##
## **THE VERDICT STREAM IS THE RUNNER'S WIRE FORMAT, NOT A HAND-BUILT SUMMARY.**
## The fixture is written with `contracts.eventToJsonLine`, the serialiser
## `ct-test --events` uses, and in the shape the Noir provider emits: a
## per-unit `run-started` / `run-finished` keyed by the CATALOG id, and
## `test-started` / `failure` / `test-finished` keyed by nargo's own test name
## (the catalog's `selector`). Both must land on ONE row per test, which is
## why `rows.len` is asserted as well as the states — a join that missed would
## append a second, orphan row per test and still paint a green tick somewhere.
##
## **THE FAILURE ARMS ASSERT THE HEADLINE BY VALUE** (Verification-Harness-
## Traps.md §7): "the pane lists no verdicts" is true of the broken state too.
## What discriminates is `RunFailedHeadline` replacing "5 tests, not run yet".
##
## ## The mocks, and why they are spies rather than fakes
##
## Four effects are injected into the host, and this suite passes closures
## that COUNT and RECORD:
##
##   * the suite dispatch — in the product, an IPC send to the Electron main
##     process, which spawns `ct test run`;
##   * the two record dispatches (opening and not opening the recording) — in
##     the product, `renderer.runTests` → `CODETRACER::run-test` → `ct
##     record-test`;
##   * the open-a-recording entry point — `CODETRACER::load-recent-trace`;
##   * the editor settle — Monaco and the DOM.
##
## Every one of them is a process boundary that cannot exist in a headless
## lane, and each contributes to this question only "was I called, with what,
## and how often". The subject — the host's state machine, the real
## `TestResultsVM`, the real event fold and the real view — runs for real. The
## runner's output is not mocked either: it is the runner's wire format,
## produced by the runner's own serialiser.

import std/[options, strutils, tables, unittest]

import isonim/core/[owner, signals, computation]
import isonim/testing/mock_dom

import ../../../../ct_test/contracts
import ../../viewmodels/test_results_vm
import ../../viewmodels/desktop_test_host
import ../../views/isonim_test_results_view

# ---------------------------------------------------------------------------
# A counted `check` — Verification-Harness-Traps.md §4c.
# ---------------------------------------------------------------------------

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

template startCount() =
  asserted = 0

template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

# ---------------------------------------------------------------------------
# Reading the painted pane
# ---------------------------------------------------------------------------

proc findAllByClass(node: MockNode; className: string;
                    acc: var seq[MockNode]) =
  if node.kind == mnkElement and
      className in node.attributes.getOrDefault("class", ""):
    acc.add(node)
  for child in node.children:
    findAllByClass(child, className, acc)

proc allByClass(node: MockNode; className: string): seq[MockNode] =
  result = @[]
  findAllByClass(node, className, result)

proc collectText(node: MockNode; acc: var string) =
  if node.kind == mnkText:
    acc.add node.text
  for child in node.children:
    collectText(child, acc)

proc firstByClass(panel: MockNode; className: string): MockNode =
  let nodes = allByClass(panel, className)
  if nodes.len == 0: MockNode(nil) else: nodes[0]

proc paneText(panel: MockNode; className: string): string =
  let node = firstByClass(panel, className)
  if node.isNil:
    ""
  else:
    var text = ""
    collectText(node, text)
    text.strip()

proc paintedRowClass(panel: MockNode; testId: string): string =
  ## The class the view painted on the row for `testId` — "" when no such row
  ## was painted at all, which is itself a failure the callers assert against.
  for row in allByClass(panel, "test-results-row"):
    if row.attributes.getOrDefault("data-ct-test-id", "") == testId:
      return row.attributes.getOrDefault("class", "")
  ""

proc runButtonIsDisabled(panel: MockNode): bool =
  "disabled" in firstByClass(panel, "test-results-run-btn")
    .attributes.getOrDefault("class", "")

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const
  Root = "/work/hello_noir"
    ## The project folder the desktop knows (`data.startOptions.folder`).

  NotRunYet = "5 tests, not run yet"
    ## What the pane says before a click — and what a failed run left behind
    ## before arm 3 of `headlineFor`. Named because the failure arms
    ## discriminate against it.

  SpawnFailed = "ct test run could not be started: spawn ct ENOENT"
    ## The main process's sentence for a runner that never started.

  NothingRanStderr =
    "ct test: run verdict: nothing-executed (exit 2) — no test executed: " &
    "1 unit(s) were dispatched and none reported a finished test\n" &
    "ct test: install the toolchain the provider names"
    ## `ct_test.runRun`'s two stderr lines for exit 2, in their real shape.

proc item(id, selector, file: string; line: int): TestItem =
  TestItem(id: id, providerId: "noir-nargo", language: "noir",
           framework: "nargo test", name: selector, kind: tikCase,
           file: file, range: SourceRange(startLine: line, startColumn: 1,
                                          endLine: line, endColumn: 1),
           selector: selector, parentId: "", tags: @[],
           location: LocationProvenance(source: lskParser, detail: "",
                                        confidence: lcHigh),
           stale: false, staleReason: "")

proc fiveTests(): seq[TestItem] =
  @[item("a", "tests::test_main", "src/main.nr", 13),
    item("b", "tests::test_bounds", "src/main.nr", 20),
    item("c", "tests::test_fails", "src/main.nr", 27),
    item("d", "tests::test_expected", "src/main.nr", 34),
    item("e", "tests::test_skipped", "src/main.nr", 41)]

proc ev(kind: TestEventKind; runId, testId: string;
        status = none(TestResultStatus); message = ""): TestEvent =
  TestEvent(schemaVersion: TestEventSchemaVersion, kind: kind,
            providerId: "noir-nargo", runId: runId, testId: testId,
            status: status, message: message,
            trace: none(TraceMetadata), diagnostic: none(TestDiagnostic))

proc unitStream(catalogId, selector: string;
                status: TestResultStatus): seq[TestEvent] =
  ## ONE run unit, as `noir_nargo.noirRunResult` emits it for a `tskSingle`
  ## scope: the unit's framing carries the CATALOG id, the per-test events
  ## carry nargo's NAME for the test.
  let runId = "noir-nargo:single:" & selector
  result.add ev(tekRunStarted, runId, catalogId,
                message = "nargo test --exact " & selector & " --format json")
  result.add ev(tekTestStarted, runId, selector, message = selector)
  if status == tsFailed:
    result.add ev(tekFailure, runId, selector, some(tsFailed),
                  "assertion failed: x == 2")
  result.add ev(tekTestFinished, runId, selector, some(status), $status)
  result.add ev(tekRunFinished, runId, catalogId, some(status), $status)

proc jsonLines(events: seq[TestEvent]): string =
  ## What `ct-test test run --events <path>` writes: one event per line, by
  ## the contracts serialiser.
  for event in events:
    result.add eventToJsonLine(event)
    result.add "\n"

proc onePassOneFail(): string =
  jsonLines(unitStream("a", "tests::test_main", tsPassed) &
            unitStream("c", "tests::test_fails", tsFailed))

type
  Spies = ref object
    ## What the injected effects were asked to do.
    suiteDispatched: int
    lastRoot: string
    suiteRefuseWith: string
    suiteRaises: bool
    recordOpening: int       ## record, then open the recording
    recordKeeping: int       ## record, stay in the pane
    lastSelector: string
    lastFile: string
    lastLine: int
    opened: seq[string]      ## recording ids handed to the open entry point
    openRefuseWith: string
    settled: int
    root: string             ## what the workspace-root provider answers

proc newSpies(): Spies = Spies(root: Root)

proc desktopHostOverPane(spies: Spies; installControls = true):
    (TestResultsVM, MockNode, DesktopTestHost) =
  ## The pane, mounted, with the desktop host over it — and, unless the case
  ## is about the moment before, the host's controls installed the way the
  ## `if inElectron:` block installs them.
  let vm = createTestResultsVM()
  vm.setCatalog(TestCatalog(items: fiveTests()))
  let r = MockRenderer()
  let panel = renderTestResultsPanel[MockRenderer, MockNode](r, vm)
  let host = newDesktopTestHost(
    vm,
    dispatch = proc(selector, file: string; line: int): string =
      inc spies.recordOpening
      spies.lastSelector = selector
      spies.lastFile = file
      spies.lastLine = line
      "",
    settleEditor = proc(note: string) =
      inc spies.settled)
  if installControls:
    host.installDesktopSuiteRun(
      workspaceRoot = proc(): string = spies.root,
      suiteDispatch = proc(workspaceRoot: string): string =
        inc spies.suiteDispatched
        spies.lastRoot = workspaceRoot
        if spies.suiteRaises:
          raise newException(IOError, "the IPC channel is closed")
        spies.suiteRefuseWith)
    host.installDesktopRowActions(
      keepWindowDispatch = proc(selector, file: string; line: int): string =
        inc spies.recordKeeping
        spies.lastSelector = selector
        spies.lastFile = file
        spies.lastLine = line
        "",
      openRecording = proc(testId, recordingId: string;
                           policy: TraceOpenPolicy): string =
        spies.opened.add recordingId
        spies.openRefuseWith)
  (vm, panel, host)

proc rowFor(vm: TestResultsVM; testId: string): TestResultsRow =
  for row in vm.rows.val:
    if row.testId == testId:
      return row
  TestResultsRow()

# ---------------------------------------------------------------------------

suite "the desktop host installs the pane's run controls":

  test "with the desktop host installed, the ▶ and the row controls are live":
    ## THE DEFECT, AS IT WAS SEEN: every control disabled with "No host in
    ## this build …" on the desktop. The before-state is asserted on a host
    ## built WITHOUT the controls installed, so the two halves of this case are
    ## the same pane, one call apart.
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      let (vm, panel, host) = desktopHostOverPane(spies, installControls = false)
      ck vm.runTests.val.isNil
      ck runButtonIsDisabled(panel)

      host.installDesktopSuiteRun(
        workspaceRoot = proc(): string = spies.root,
        suiteDispatch = proc(workspaceRoot: string): string =
          inc spies.suiteDispatched
          "")
      host.installDesktopRowActions(
        keepWindowDispatch = proc(selector, file: string; line: int): string =
          inc spies.recordKeeping
          "",
        openRecording = proc(testId, recordingId: string;
                             policy: TraceOpenPolicy): string =
          spies.opened.add recordingId
          "")

      ck not vm.runTests.val.isNil
      ck vm.canRun()
      # PAINTED, not merely set: `runTests` is a Signal precisely so an install
      # after mount re-renders the button.
      ck not runButtonIsDisabled(panel)
      ck not vm.refreshRecording.val.isNil
      ck not vm.openExistingRecording.val.isNil
      ck not vm.recordAndOpenRecording.val.isNil
      ck vm.refreshAbsence() == ""
      ck vm.openAbsence(vm.rowFor("a")) == ""

      dispose()
    expectCount(10)

suite "a suite run through ct test run puts the runner's verdicts on the pane":

  test "the ▶ dispatches ct test run for the open project, and the pane says it is going":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      let (vm, panel, _) = desktopHostOverPane(spies)
      ck paneText(panel, "test-results-headline") == NotRunYet

      vm.startRun()

      ck spies.suiteDispatched == 1
      ck spies.lastRoot == Root
      ck vm.inFlight.val
      ck paneText(panel, "test-results-headline") == "running…"
      ck runButtonIsDisabled(panel)
      # Nothing has ended, so nothing may have been told that something ended.
      ck spies.settled == 0
      # And no record dispatch was used for a suite run.
      ck spies.recordOpening == 0 and spies.recordKeeping == 0

      dispose()
    expectCount(8)

  test "one passing and one failing test land on their catalog rows, with the counts":
    ## THE PRODUCT THE ISSUE ASKS FOR. Verdicts here are genuine — they come
    ## from the runner's own `test-finished` events, not from `ct record-test`'s
    ## exit code — so they are exactly what must reach the pane.
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      let (vm, panel, host) = desktopHostOverPane(spies)
      vm.startRun()

      host.settleDesktopSuiteRun(eventsText = onePassOneFail(), exitCode = 1)

      ck not vm.inFlight.val
      ck spies.settled == 1

      # THE JOIN: one row per catalog test, none appended for nargo's names.
      ck vm.rows.val.len == 5
      ck vm.rowFor("a").state == trsPassed
      ck vm.rowFor("c").state == trsFailed
      ck vm.rowFor("b").state == trsNotRun
      ck vm.rowFor("d").state == trsNotRun

      # PAINTED — the class a user's eye and a gate both read.
      ck "passed" in paintedRowClass(panel, "a")
      ck "failed" in paintedRowClass(panel, "c")
      ck "not-run" in paintedRowClass(panel, "b")

      # The headline carries the counts and nothing claims to be running.
      let headline = paneText(panel, "test-results-headline")
      ck headline.startsWith("1 passed, 1 failed")
      ck "running" notin headline
      ck vm.summary.val.running == 0
      ck not vm.summary.val.inProgress

      # A red suite is an answer, not a host failure: no failure block.
      ck paneText(panel, "test-results-failure") == ""
      # And the ▶ is live again for the next run.
      ck not runButtonIsDisabled(panel)

      dispose()
    expectCount(16)

  test "a runner that could not be started reaches RunFailedHeadline, with the sentence":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      let (vm, panel, host) = desktopHostOverPane(spies)
      vm.startRun()

      host.settleDesktopSuiteRun(eventsText = "", exitCode = -1,
                                 errorMessage = SpawnFailed)

      ck not vm.inFlight.val
      ck spies.settled == 1
      let headline = paneText(panel, "test-results-headline")
      ck headline != NotRunYet
      ck headline == RunFailedHeadline
      ck paneText(panel, "test-results-failure") == SpawnFailed
      ck not vm.summary.val.inProgress

      dispose()
    expectCount(6)

  test "a run that executed nothing (exit 2) is a failed run, and says why":
    ## `ct test run` exits 2 when NO test ran — which is not a pass, and which
    ## the pane must not render as "not run yet" either.
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      let (vm, panel, host) = desktopHostOverPane(spies)
      vm.startRun()

      # An EMPTY stream: the shape of a run whose every unit was refused
      # (a provider that declares it cannot run), so no event was produced.
      host.settleDesktopSuiteRun(eventsText = "", exitCode = 2,
                                 stderrText = NothingRanStderr)

      ck not vm.inFlight.val
      ck paneText(panel, "test-results-headline") == RunFailedHeadline
      let failure = paneText(panel, "test-results-failure")
      ck failure.startsWith(DesktopSuiteNothingRanText)
      # The runner's own verdict sentence reaches the screen, because it is
      # the only place the CAUSE is named.
      ck "nothing-executed (exit 2)" in failure

      dispose()
    expectCount(4)

  test "output this build cannot read is a failed run, not a silent one":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      let (vm, panel, host) = desktopHostOverPane(spies)
      vm.startRun()

      host.settleDesktopSuiteRun(eventsText = "Segmentation fault\n{not json",
                                 exitCode = 0)

      ck not vm.inFlight.val
      ck paneText(panel, "test-results-headline") == RunFailedHeadline
      ck paneText(panel, "test-results-failure").startsWith(
        DesktopSuiteUnreadableText)

      dispose()
    expectCount(3)

  test "a test the runner started and never finished does not leave the pane running":
    ## `inProgress` is `openScopes > 0 or running > 0`. A crashed runner can
    ## leave a `test-started` with no `test-finished`, and a row left
    ## `running` would keep the headline on "running…" after `endRun` — the
    ## spinner defect, moved into the pane.
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      let (vm, panel, host) = desktopHostOverPane(spies)
      vm.startRun()

      let truncated = jsonLines(@[
        ev(tekRunStarted, "r", "a", message = "nargo test"),
        ev(tekTestStarted, "r", "tests::test_main")])
      host.settleDesktopSuiteRun(eventsText = truncated, exitCode = 139)

      ck not vm.inFlight.val
      ck not vm.summary.val.inProgress
      ck vm.rowFor("a").state == trsErrored
      ck "running" notin paneText(panel, "test-results-headline")
      ck paneText(panel, "test-results-failure").len > 0

      dispose()
    expectCount(5)

suite "a desktop suite run settles, however it ended":

  test "no project open: refused with a sentence, nothing spawned, nothing left running":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      spies.root = ""
      let (vm, panel, _) = desktopHostOverPane(spies)

      vm.startRun()

      ck spies.suiteDispatched == 0
      ck not vm.inFlight.val
      ck paneText(panel, "test-results-failure") == DesktopNoProjectText

      dispose()
    expectCount(3)

  test "a second run while one is pending is refused, and the first still settles":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      let (vm, panel, host) = desktopHostOverPane(spies)
      vm.startRun()

      # A second SUITE run, and a Run-test click from the editor: both refused.
      ck host.startDesktopSuiteRun(Root) == DesktopRunAlreadyGoingText
      ck host.startDesktopTestRun("tests::test_main", "src/main.nr", 13) ==
        DesktopRunAlreadyGoingText
      ck spies.suiteDispatched == 1
      ck spies.recordOpening == 0
      ck spies.settled == 0

      # A `test-run-settled` from a run this host did not start (the editor's
      # context-menu "Run test" dispatches around the host) does not end the
      # SUITE run.
      host.settleDesktopTestRun(recordingId = "rec-ctx")
      ck vm.inFlight.val
      ck paneText(panel, "test-results-headline") == "running…"

      host.settleDesktopSuiteRun(eventsText = onePassOneFail(), exitCode = 1)
      ck not vm.inFlight.val
      ck vm.rowFor("a").state == trsPassed

      dispose()
    expectCount(9)

  test "a suite dispatch that RAISES settles, and the sentence is painted once":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      spies.suiteRaises = true
      let (vm, panel, host) = desktopHostOverPane(spies)

      vm.startRun()

      ck spies.suiteDispatched == 1
      ck not vm.inFlight.val
      ck spies.settled == 1
      ck paneText(panel, "test-results-headline") == RunFailedHeadline
      # ONCE. The host files the sentence when it settles; the ▶'s own refusal
      # path (`startRun` → `noteRunRefusal`) must not file it a second time.
      let failure = paneText(panel, "test-results-failure")
      ck failure.startsWith(DesktopDispatchRaisedText)
      ck failure.count("the IPC channel is closed") == 1
      ck host.pending.isNone

      dispose()
    expectCount(7)

  test "a suite dispatch the main process declines settles immediately":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      spies.suiteRefuseWith = "the main process is shutting down"
      let (vm, panel, host) = desktopHostOverPane(spies)

      vm.startRun()

      ck not vm.inFlight.val
      ck spies.settled == 1
      ck paneText(panel, "test-results-failure") ==
        "the main process is shutting down"
      ck host.pending.isNone

      dispose()
    expectCount(4)

suite "the desktop row controls mirror the web arm's":

  test "⟳ re-records without opening, ⏵ opens the existing recording and runs nothing":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      let (vm, panel, host) = desktopHostOverPane(spies)

      # ⟳ on row b: the RECORD path that keeps the window, with the catalog's
      # file and line for that test. The catalog's file is PROJECT-relative
      # and the recorder resolves paths against the main process's cwd, so
      # it arrives joined onto the project folder.
      vm.triggerRefresh(vm.rowFor("b"))
      ck spies.recordKeeping == 1
      ck spies.recordOpening == 0
      ck spies.lastSelector == "tests::test_bounds"
      ck spies.lastFile == Root & "/src/main.nr"
      ck spies.lastLine == 20
      ck vm.inFlight.val

      # It is a run, so it settles like one — and the recording lands on b.
      host.settleDesktopTestRun(recordingId = "rec-b", recordedAtText = "10:00")
      ck not vm.inFlight.val
      ck spies.settled == 1
      ck vm.rowFor("b").recordingId == "rec-b"

      # ⏵ on b now OPENS that recording, by id, and dispatches no run.
      ck vm.openButtonMode(vm.rowFor("b")) == obmOpenExisting
      vm.triggerOpen(vm.rowFor("b"))
      ck spies.opened == @["rec-b"]
      ck spies.recordKeeping == 1
      ck spies.recordOpening == 0
      ck not vm.inFlight.val

      dispose()
    expectCount(14)

  test "⏵ with no recording records and opens, through the opening dispatch":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      let (vm, panel, host) = desktopHostOverPane(spies)

      ck vm.openButtonMode(vm.rowFor("c")) == obmRecordAndOpen
      vm.triggerOpen(vm.rowFor("c"))
      ck spies.recordOpening == 1
      ck spies.recordKeeping == 0
      ck spies.lastSelector == "tests::test_fails"
      ck spies.lastLine == 27
      ck spies.opened.len == 0
      ck vm.inFlight.val

      host.settleDesktopTestRun(errorMessage = "ct record-test error: \"Exit with code 1\"")
      ck not vm.inFlight.val
      ck paneText(panel, "test-results-headline") == RunFailedHeadline

      dispose()
    expectCount(9)

  test "an open the main process refuses is shown, and starts no run":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = newSpies()
      spies.openRefuseWith = "the recording rec-a is no longer in the trace index"
      let (vm, panel, _) = desktopHostOverPane(spies)
      vm.rememberRecording("a", "rec-a", "09:00")

      vm.triggerOpen(vm.rowFor("a"))

      ck spies.opened == @["rec-a"]
      ck not vm.inFlight.val
      ck paneText(panel, "test-results-failure") ==
        "the recording rec-a is no longer in the trace index"

      dispose()
    expectCount(3)

suite "the suite stream parser":

  test "reads the runner's JSON Lines, and counts what it could not read":
    startCount()
    let parsed = parseDesktopSuiteEvents(
      onePassOneFail() & "\nnot an event\n\n" & "{\"kind\":\"x\"}\n")
    ck parsed.events.len == 9
    ck parsed.events[2].kind == tekTestFinished
    ck parsed.events[2].status == some(tsPassed)
    ck parsed.unreadableLines == 2
    expectCount(4)
