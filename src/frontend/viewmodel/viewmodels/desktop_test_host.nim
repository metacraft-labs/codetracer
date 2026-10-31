## The DESKTOP test-runner host — what settles a run started from the editor.
##
## Spec: `GUI/Core-Panes/Test-Results-Pane.md` §4 ("The desktop host") and §5
## ("A run settles, however it ended"). Read that first; this module is its
## implementation and nothing here is a product decision of its own.
##
## ## The obligation this closes
##
## `test_results_vm.nim`'s header says `runTests` is "installed by the host,
## exactly as `BuildVM.runBuild` is (`ui_js` points it at
## `web_noir_build.startNoirTests` on the web arm **and the Electron arm may
## point it elsewhere**)". Nobody ever did. Every call that settles a run —
## `beginRun`, `endRun`, and the one `editor.settleEditorTestRun` outside
## `editor.nim` itself — was installed inside `ui_js.startWebRenderer`, which
## the desktop never enters, so the desktop Run-test control armed a spinner
## that only its own two-minute deadline could stop and the pane never moved
## (issue #748). (`editor.runTestFromGutter` calls `settleEditorTestRun` too,
## but only to unwind the spinner it armed one line earlier over a dispatch the
## hook refused — it ends no run that was actually started.)
##
## ## What a desktop run can honestly report, and what it cannot
##
## The desktop run is `ct record-test`, and **it is a RECORDING, not a
## verdict**. `src/ct/trace/record.nim`'s `recordTest` exits 0 when a recording
## was produced and 1 when one was not; a test that ran and FAILED still
## records and still exits 0. Nothing on this path parses a pass/fail result.
##
## So this host emits the run-level half of the event stream and no per-test
## verdict at all:
##
##   * dispatch — `run-started`, carrying the command line. `openScopes`
##     becomes 1, `TestRunSummary.inProgress` becomes true, and the pane's
##     headline reads "running…".
##   * settled, recording produced — `run-finished`, plus
##     `TestResultsVM.rememberRecording` so the row carries the recording. The
##     same shape the web arm uses: a recording reaches the pane through
##     `rememberRecordingForSelector` there too, not through an event.
##   * settled, no recording — a run-level `diagnostic` carrying the host's own
##     sentence, then `run-finished`. `runFailureLines` reads it back out and
##     `headlineFor` answers `RunFailedHeadline`.
##
## **A `test-finished` with a status is specifically NOT emitted**, and that is
## the one thing not to "improve" here. `tsPassed` for an exit code that only
## means "a recording exists" would paint a green tick over a test that failed;
## `noir_test_run.nim`'s header makes the same point about `should_fail` and
## the inversion it must not re-apply. The pane says what it knows.
##
## ## The whole-suite run: `ct test run`, and here the verdicts ARE genuine
##
## The pane's header ▶ runs the project's suite through `ct test run
## --workspace <project> --events <file>` (§4.3 of the spec). `ct` hands that
## to the ORC-built `ct-test` installed beside it
## (`src/ct_test/ct_test_delegate.nim`), and `ct-test` writes every
## `TestEvent` its providers produced to `<file>` as JSON Lines, by the
## contracts serialiser. Those events are the RUNNER's: a `test-finished`
## carries the status the test framework itself reported. So, unlike the
## record path above, this path passes per-test verdicts straight to the pane —
## withholding them would be the opposite lie.
##
## What the host adds to the runner's stream, and why each is not optional:
##
##   * **Run-level framing.** `run-started` at dispatch (the headline says
##     "running…" during the seconds before the runner answers) and, at
##     settle, as many `run-finished` as are needed to close every scope the
##     stream left open. A stream cut short by a crash would otherwise leave
##     `TestRunSummary.inProgress` true for ever.
##   * **No row left `running`.** `inProgress` is also true while any ROW is
##     `troRunning`, so a `test-started` that never got its `test-finished`
##     is closed as `errored` with the host's sentence — the runner ended and
##     never said; it is not a pass and not a failure of the user's test.
##   * **A run-level diagnostic whenever the run produced no answer**: the
##     runner could not be started, it exited 2 ("no test executed"), or what
##     it wrote cannot be read. The pane must reach `RunFailedHeadline`, never
##     the "not run yet" sentence it showed before the click.
##   * **The join.** The runner keys a unit's framing by the catalog's
##     `TestItem.id` but a provider's per-test events by the framework's OWN
##     name for the test (nargo's `tests::test_main`), which is the catalog's
##     `selector`. Both are mapped onto the catalog id here, through
##     `TestResultsVM.testIdForSelector`, so one test is one row.
##
## ## The per-row controls, mirroring the web arm
##
##   * `⟳` refresh — record the test again (`ct record-test`) and STAY in the
##     pane: the record dispatch that keeps the window.
##   * `⏵` open-existing — enter the recording the row already carries, by id,
##     and EXECUTE NOTHING. A separate entry point rather than a flag on the
##     recorder, for the web arm's reason: a proc with no dispatch in it cannot
##     re-run a test by accident.
##   * `⏵` record-and-open (no recording yet, or Shift held) — the editor's own
##     Run-test dispatch: record, then load the recording.
##
## The two that record are runs, so they go through the same single-pending
## rule and the same settle as the editor's click; `⏵` open-existing is not a
## run and touches neither.
##
## ## Why the dispatch and the editor settle are injected
##
## The dispatch is `renderer.runTests`, which sends an Electron IPC message;
## the settle is `ui/editor.settleEditorTestRun`, which reaches Monaco and the
## DOM. Neither compiles in a headless lane, and this module's whole subject —
## *does a run that started reach `endRun`, and does the editor get told* — is
## exactly what has to be asserted without them. `ui_js` supplies the real two
## in its `if inElectron:` block, the suite supplies spies, and there is one
## body either way. The suite dispatch (`CODETRACER::run-test-suite`), the
## record dispatch that keeps the window, and the open-a-recording entry point
## (`CODETRACER::load-recent-trace`) are injected for the same reason.

import std/[options, strutils]

import isonim/core/signals

import ../../../ct_test/contracts
import ./test_results_vm

export contracts

type
  DesktopTestDispatch* = proc(selector, file: string; line: int): string
    ## Hand the run to the host process. Returns "" when it was taken, or a
    ## sentence saying why it could not be — the same contract
    ## `editor.editorTestRunHook` has, for the same reason: a control that
    ## starts spinning over a request nothing took is the defect being fixed.

  DesktopTestSettleEditor* = proc(note: string)
    ## Stop every spinning editor Run-test button, however the run ended.
    ## `ui/editor.settleEditorTestRun`'s signature, as a value.

  DesktopSuiteDispatch* = proc(workspaceRoot: string): string
    ## Hand a whole-suite run of `workspaceRoot` to the host process — in the
    ## product, `CODETRACER::run-test-suite`, answered by `index/traces
    ## .onRunTestSuite` with `CODETRACER::test-suite-settled`. Returns "" when
    ## it was taken, or why it was not: `DesktopTestDispatch`'s contract.

  DesktopWorkspaceRoot* = proc(): string
    ## The project folder a suite run covers, read AT CLICK TIME, or "" when
    ## no project is open. A provider and not a value, because the desktop
    ## learns its folder after the pane has mounted and can change it with
    ## "Open folder" without remounting anything.

  DesktopOpenRecording* = proc(testId, recordingId: string;
                               policy: TraceOpenPolicy): string
    ## Open test `testId`'s recording `recordingId`, by id, without running
    ## anything, where `Test-Results-Pane.md` §9 places it for the destination
    ## `policy` (the setting, inverted by the modifier) — in the desktop
    ## product a new session tab by default (`createNewSession` +
    ## `CODETRACER::load-recent-trace`). "" when it was handed over, else why
    ## not.

  DesktopRunKind* = enum
    ## Which of the two desktop runners a pending run belongs to.
    ##
    ## Kept on the run because the two settle messages are different
    ## (`test-run-settled` / `test-suite-settled`) and a settle of one kind
    ## must not end a run of the other: the editor's context-menu "Run test"
    ## dispatches `ct record-test` AROUND this host, and its settle arriving
    ## during a suite run would otherwise end the suite run in the pane while
    ## `ct-test` was still running. `drkRecordTest` is first so a
    ## default-constructed run is the kind this host always had.
    drkRecordTest = "ct-record-test"
    drkSuite = "ct-test-run"

  DesktopTestRun* = object
    ## The run this window is waiting on.
    kind*: DesktopRunKind
    workspaceRoot*: string
      ## The project a suite run covers; "" for a record run.
    testId*: string
      ## What the pane joins on — `TestResultsVM.testIdForSelector`, so the
      ## run and the recording it produces land on the same row.
    selector*: string
    file*: string
    line*: int
    runId*: string
    commandLine*: string
    openAfter*: bool
      ## A record run that OPENS its recording once it settles — the editor's
      ## Run-test and the row's record-and-open (§9.5); false for `⟳`.
    openPolicy*: TraceOpenPolicy
      ## Where it opens: the destination captured at the press, because the
      ## modifier is no longer held when the recorder answers.

  DesktopTestHost* = ref object
    vm*: TestResultsVM
    dispatch*: DesktopTestDispatch
      ## Record a test whose recording is then OPENED: the editor's Run-test,
      ## and the row's record-and-open. The host opens it on the settle, by
      ## `openRecording` (`Test-Results-Pane.md` §9.5); the dispatch itself
      ## loads nothing into the asking window.
    settleEditor*: DesktopTestSettleEditor
    pending*: Option[DesktopTestRun]
    runCounter*: int
    keepWindowDispatch*: DesktopTestDispatch
      ## Record a test and STAY in the pane: the row's `⟳`. Nil until
      ## `installDesktopRowActions`.
    suiteDispatch*: DesktopSuiteDispatch
      ## Nil until `installDesktopSuiteRun`.
    workspaceRoot*: DesktopWorkspaceRoot
      ## Nil until `installDesktopSuiteRun`; also resolves a catalog row's
      ## project-relative file for the row controls.
    openRecording*: DesktopOpenRecording
      ## Nil until `installDesktopRowActions`.

  DesktopSuiteEvents* = object
    ## What `parseDesktopSuiteEvents` read out of `ct-test --events`'s file.
    events*: seq[TestEvent]
    unreadableLines*: int
      ## Non-blank lines that were not a `TestEvent`. Counted, not dropped:
      ## a stream with none readable is "the runner said something this build
      ## does not understand", which the pane has to say rather than absorb.

const
  DesktopRunAlreadyGoingText* =
    "a test run is already going in this window; wait for it to finish and " &
    "press Run test again"
    ## Spelled as a constant because the host returns it, the suite compares
    ## against it, and the pane paints it. A literal in three places is three
    ## chances to drift.

  DesktopRecordedNote* = ""
    ## What the editor's button is restored to, on EVERY outcome.
    ##
    ## Empty means `restoreTestButton` puts back the literal "Run test" node
    ## the button was built with. The failure sentence deliberately does not go
    ## here: `note` becomes the button's whole label, and a recorder's error
    ## paragraph rendered as a gutter button is unreadable. The sentence goes
    ## to the pane's `.test-results-failure` block instead, which is the
    ## surface that already exists for "an attempt was made and it did not
    ## work".

  DesktopDispatchRaisedText* =
    "the test run could not be handed to CodeTracer"
    ## The stem of the sentence a dispatch that THREW produces. Spelled as a
    ## constant for `DesktopRunAlreadyGoingText`'s reason — the host builds it,
    ## the suite compares against it, the pane paints it. The thrown message is
    ## appended when there is one, because the host process's own words are
    ## what make such a failure diagnosable at all.

  DesktopTestProviderId* = "ct-record-test"
    ## `TestEvent.providerId` for this host's RECORD run. Names the command
    ## that produced the run, the way `noir_test_run` names
    ## `NoirNargoProviderId`.

  DesktopSuiteProviderId* = "ct-test-run"
    ## `TestEvent.providerId` for the host's own framing of a SUITE run. The
    ## per-test events keep the provider id the runner gave them
    ## (`noir-nargo`, …) — this one names only what the host itself says.

  DesktopNoProjectText* =
    "No project folder is open, so there is no test suite to run. Open the " &
    "project's folder and press ▶ again."
    ## The ▶'s answer when the desktop has no project. Said instead of
    ## spawning `ct test run` with an empty `--workspace`, which would fail
    ## with an argument error a user did not cause.

  DesktopSuiteNothingRanText* = "ct test run executed no test"
    ## The stem of the sentence for exit code 2. `ct-test` exits 2 when NO
    ## test ran at all — a run that proves nothing, which is neither a pass nor
    ## "not run yet". The runner's own stderr verdict, which names the cause,
    ## is appended.

  DesktopSuiteUnreadableText* =
    "ct test run finished, but no per-test result it wrote could be read"
    ## The stem for a stream with no readable event in it.

  DesktopSuiteNoResultText* =
    "ct test run finished without any per-test result reaching CodeTracer"
    ## The stem for an EMPTY stream from a runner that did not say it ran
    ## nothing (exit 0 or 1): the events file was not written or not read.

  DesktopSuiteUnreportedTestText* =
    "the run ended without this test reporting a result"
    ## Filed on a row the stream opened and never closed. `errored`, not
    ## `failed`: the runner ended without saying, which establishes nothing
    ## about the user's test.

  DesktopRowNotInCatalogText* =
    "this test is not in the project's test list, so CodeTracer does not " &
    "know which file to record it from"
    ## A row the RUN reported that the catalog does not have (`joinRows`
    ## appends those). `ct record-test` needs the file, and guessing one would
    ## record the wrong program.

  DesktopOpenRaisedText* = "the recording could not be handed to CodeTracer"
    ## The stem for an open-existing entry point that THREW;
    ## `DesktopDispatchRaisedText`'s counterpart for the control that runs
    ## nothing.

proc newDesktopTestHost*(vm: TestResultsVM;
                         dispatch: DesktopTestDispatch;
                         settleEditor: DesktopTestSettleEditor):
                         DesktopTestHost =
  DesktopTestHost(vm: vm, dispatch: dispatch, settleEditor: settleEditor,
                  pending: none(DesktopTestRun), runCounter: 0)

proc providerIdFor(kind: DesktopRunKind): string =
  case kind
  of drkRecordTest: DesktopTestProviderId
  of drkSuite: DesktopSuiteProviderId

proc desktopRunStartedEvents*(run: DesktopTestRun): seq[TestEvent] =
  ## `run-started`, and nothing per-test.
  ##
  ## A `record-started` carrying the `testId` would ALSO be true, and it is
  ## deliberately not sent: `ingestTestEvent` calls `ensureRow` for it, and a
  ## row opened here stays `troRunning` for ever because no later event on this
  ## path carries a status to close it with. The pane would then read "1
  ## running" after a run that had settled — the spinner defect, moved one
  ## surface over. The run's progress is carried by `openScopes` instead, which
  ## `run-finished` closes.
  @[TestEvent(
    schemaVersion: TestEventSchemaVersion,
    kind: tekRunStarted,
    providerId: providerIdFor(run.kind),
    runId: run.runId,
    message: run.commandLine,
    status: none(TestResultStatus),
    trace: none(TraceMetadata),
    diagnostic: none(TestDiagnostic))]

proc desktopRunSettledEvents*(run: DesktopTestRun;
                              errorMessage: string): seq[TestEvent] =
  ## What the pane is told when the recorder answered.
  ##
  ## The diagnostic comes FIRST and is run-level (no `testId`), so
  ## `runFailureLines` finds it and `headlineFor` reaches `RunFailedHeadline`
  ## instead of the not-run sentence the pane was already showing. That
  ## distinction is the whole of the error path: "5 tests, not run yet" is
  ## byte-identical before the click and after a failed run, and a user reads
  ## the second one as a button that did nothing.
  proc base(kind: TestEventKind): TestEvent =
    TestEvent(
      schemaVersion: TestEventSchemaVersion,
      kind: kind,
      providerId: providerIdFor(run.kind),
      runId: run.runId,
      status: none(TestResultStatus),
      trace: none(TraceMetadata),
      diagnostic: none(TestDiagnostic))

  if errorMessage.len > 0:
    var failed = base(tekDiagnostic)
    failed.message = errorMessage
    result.add failed
  result.add base(tekRunFinished)

proc settleDesktopTestRun*(host: DesktopTestHost;
                           recordingId = ""; recordedAtText = "";
                           errorMessage = "") =
  ## The recorder answered, however it answered.
  ##
  ## CALLED ON SETTLE AND NOT ON SUCCESS. A refused dispatch, a dispatch that
  ## RAISED, a recorder that could not build the project, a recorder that
  ## answered in a shape this build does not understand, and a recording that
  ## was made are five answers and all five end the run; the one state this
  ## must never leave behind is "still running" over a run that is not.
  ## `ui/editor.settleEditorTestRun` says the same thing about the animation it
  ## stops, and this is the caller the desktop never had.
  ##
  ## THE EDITOR IS TOLD EVEN WHEN NOTHING IS PENDING. The editor's context-menu
  ## "Run test" dispatches through `renderer.runTests` without going through
  ## this host, and a reload can leave a spinner behind a host that has
  ## forgotten the run; `settleEditorTestRun` over an empty list is a no-op, so
  ## telling it unconditionally costs nothing and closes both.
  if not host.settleEditor.isNil:
    host.settleEditor(DesktopRecordedNote)
  if host.pending.isNone or host.pending.get.kind != drkRecordTest:
    # A RECORD settle ends a RECORD run and nothing else. The context-menu
    # "Run test" above dispatches around this host, so its settle can arrive
    # while a SUITE run is pending — and ending that one here would paint the
    # pane idle while `ct-test` was still running. See `DesktopRunKind`.
    return
  let run = host.pending.get
  host.pending = none(DesktopTestRun)
  if host.vm.isNil:
    return
  for event in desktopRunSettledEvents(run, errorMessage):
    host.vm.ingestEvent(event)
  if recordingId.len > 0:
    # THE ARTEFACT OUTLIVES THE RUN. `rememberRecording` and not a
    # `recording-created` event: `TestRunSummary` is blanked by the next
    # `beginRun`, and a recording learned only from there would vanish the
    # moment anyone started a second test. Same reasoning, same call, as the
    # web arm's `noirTestRecordingSink`.
    host.vm.rememberRecording(run.testId, recordingId, recordedAtText)
  host.vm.endRun()
  if run.openAfter and recordingId.len > 0:
    # §9.5: RECORD, THEN OPEN WHERE §9 PLACES IT. The host process loaded
    # nothing into the asking window (the run recorded with `keepWindow`),
    # so opening is this host's, after the run is over — a failure to open
    # is said on the pane and does not reopen the run.
    if host.openRecording.isNil:
      host.vm.noteRowActionRefusal(NoReplayHostText)
    else:
      var refusal = ""
      try:
        refusal = host.openRecording(run.testId, recordingId, run.openPolicy)
      except:
        let detail = getCurrentExceptionMsg()
        refusal = DesktopOpenRaisedText &
          (if detail.len > 0: ": " & detail else: ".")
      host.vm.noteRowActionRefusal(refusal)


# ---------------------------------------------------------------------------
# The whole-suite run: reading what `ct-test --events` wrote
# ---------------------------------------------------------------------------

proc parseDesktopSuiteEvents*(text: string): DesktopSuiteEvents =
  ## The runner's JSON Lines, as `TestEvent`s, in the order they were written.
  ##
  ## ONE RECOGNISER, NOT A SECOND ONE. `test_run_summary_vm.parseTestEventLine`
  ## already decides "is this line a ct-test event", strictly (a JSON object
  ## carrying a known `kind` AND a `schemaVersion`), and decodes it with
  ## `contracts.testEventFromJson` — the inverse of the serialiser `ct-test`
  ## writes with. A local parser would be a second definition of the wire
  ## format that could accept what the other refuses.
  ##
  ## Pure, so it runs on both backends and is asserted directly.
  for line in text.splitLines():
    if line.strip().len == 0:
      continue
    let parsed = parseTestEventLine(line)
    if parsed.isSome:
      result.events.add parsed.get
    else:
      inc result.unreadableLines

proc runnerSaid*(stderrText: string): string =
  ## What `ct-test` said about the run on stderr, as one line for the pane.
  ##
  ## Its own sentences are prefixed `ct test:` (the run verdict, the remedy,
  ## an invocation error), and those are what name the CAUSE of a run that
  ## produced nothing, so they are preferred. Anything else on stderr — a
  ## crash, a loader error — is represented by its last three lines rather
  ## than dropped: a failure with no words is the thing this pane exists not
  ## to show.
  const MaxChars = 2000
  var own, other: seq[string]
  for raw in stderrText.splitLines():
    let line = raw.strip()
    if line.len == 0:
      continue
    if line.startsWith("ct test:"):
      own.add line
    else:
      other.add line
  let chosen =
    if own.len > 0: own
    elif other.len > 3: other[^3 .. ^1]
    else: other
  result = chosen.join(" ")
  if result.len > MaxChars:
    result = result[0 ..< MaxChars] & "…"

proc desktopSuiteFailureSentence*(exitCode: int;
                                  stderrText, errorMessage: string;
                                  verdicts, unreadableLines: int): string =
  ## The run-level sentence a settled suite run owes the pane, or "" when the
  ## runner's verdicts say everything.
  ##
  ## In precedence order, most specific first:
  ##
  ##   1. the host process's own sentence (`errorMessage`): the runner could
  ##      not be started, or its answer could not be collected. Verbatim —
  ##      `index/traces.onRunTestSuite` composed it and it names the cause;
  ##   2. exit 2: NO TEST RAN (`run_orchestration.ExitNothingExecuted`). Not a
  ##      pass, not "not run yet"; the runner's verdict names the cause;
  ##   3. no verdict at all: unreadable output, or no output, or a non-zero
  ##      exit with nothing to show for it (an invocation error is exit 1);
  ##   4. verdicts, but an exit code `ct-test` never answers with (a crash
  ##      after reporting, a signal): the counts may be incomplete, and the
  ##      pane says so beneath them.
  ##
  ## Exit 0 and exit 1 WITH verdicts need no sentence: a red suite is an
  ## answer, and its failures are on the rows.
  let said = runnerSaid(stderrText)
  proc withSaid(stem: string): string =
    stem & (if said.len > 0: ": " & said else: ".")
  if errorMessage.len > 0:
    return errorMessage
  if exitCode == 2:
    return withSaid(DesktopSuiteNothingRanText)
  if verdicts == 0:
    if unreadableLines > 0:
      return withSaid(DesktopSuiteUnreadableText & " (" & $unreadableLines &
                      " unreadable line(s), exit code " & $exitCode & ")")
    if exitCode == 0 or exitCode == 1:
      return withSaid(DesktopSuiteNoResultText & " (exit code " &
                      $exitCode & ")")
    return withSaid("ct test run ended with exit code " & $exitCode &
                    " before any test reported a result")
  if exitCode != 0 and exitCode != 1:
    return withSaid("ct test run ended with exit code " & $exitCode &
                    " after reporting results, so they may be incomplete")
  ""

proc desktopSuiteRowId*(vm: TestResultsVM; testId: string): string =
  ## The catalog row a runner event belongs on.
  ##
  ## TWO IDENTITIES ARRIVE IN ONE STREAM. `run_orchestration` frames each unit
  ## with the catalog's `TestItem.id` (`RunUnitOutcome.testId`, and the
  ## provider's `run-started` / `run-finished` for a `tskSingle` scope), while
  ## a provider's per-test events carry the FRAMEWORK's name for the test —
  ## nargo's `tests::test_main` — which is what the catalog stores as
  ## `selector`. Mapped through `testIdForSelector`, the one place the two
  ## identities meet, so they cannot land on two rows; an id the catalog does
  ## not know is kept as it is, and `joinRows` appends it rather than hiding a
  ## real disagreement.
  if vm.isNil or testId.len == 0:
    return testId
  for item in vm.catalog.val:
    if item.id == testId:
      return testId
  vm.testIdForSelector(testId)

proc suiteEvent(run: DesktopTestRun; kind: TestEventKind;
                testId = ""; message = "";
                status = none(TestResultStatus)): TestEvent =
  TestEvent(
    schemaVersion: TestEventSchemaVersion,
    kind: kind,
    providerId: providerIdFor(run.kind),
    runId: run.runId,
    testId: testId,
    message: message,
    status: status,
    trace: none(TraceMetadata),
    diagnostic: none(TestDiagnostic))

proc settleDesktopSuiteRun*(host: DesktopTestHost; eventsText: string;
                            exitCode: int; stderrText = "";
                            errorMessage = "") =
  ## `ct test run` answered — or could not be run — however that went.
  ##
  ## `eventsText` is what `ct-test --events` wrote (JSON Lines), `exitCode`
  ## its exit status (-1 when it never ran to an exit), `stderrText` its
  ## stderr, and `errorMessage` the host process's sentence when the run could
  ## not be started or its answer could not be collected.
  ##
  ## CALLED ON SETTLE AND NOT ON SUCCESS, exactly as `settleDesktopTestRun`
  ## is, and for §5's reason: every exit ends the run. The editor is told
  ## unconditionally for the same reason that proc gives.
  if host.isNil:
    return
  if not host.settleEditor.isNil:
    host.settleEditor(DesktopRecordedNote)
  if host.pending.isNone or host.pending.get.kind != drkSuite:
    return
  let run = host.pending.get
  host.pending = none(DesktopTestRun)
  let vm = host.vm
  if vm.isNil:
    return

  # THE RUNNER'S VERDICTS, verbatim apart from the join. Counted as they go
  # in, because "the stream reported no verdict" is what decides whether the
  # run produced an answer at all.
  let parsed = parseDesktopSuiteEvents(eventsText)
  var verdicts = 0
  for event in parsed.events:
    var joined = event
    joined.testId = vm.desktopSuiteRowId(event.testId)
    vm.ingestEvent(joined)
    if joined.kind == tekTestFinished and joined.status.isSome:
      inc verdicts

  # NO ROW MAY BE LEFT RUNNING. See the header: a row in `troRunning` keeps
  # `inProgress` true after `endRun`, which would hold the headline on
  # "running…" over a run that is over.
  for row in vm.summary.val.rows:
    if row.outcome == troRunning:
      vm.ingestEvent(run.suiteEvent(tekFailure, testId = row.testId,
                                    message = DesktopSuiteUnreportedTestText,
                                    status = some(tsErrored)))

  # A RUN THAT GAVE NO ANSWER SAYS SO, at run level, so `runFailureLines`
  # finds it and `headlineFor` reaches `RunFailedHeadline` when there are no
  # rows — and paints it beneath the counts when there are.
  let sentence = desktopSuiteFailureSentence(
    exitCode, stderrText, errorMessage, verdicts, parsed.unreadableLines)
  if sentence.len > 0:
    vm.ingestEvent(run.suiteEvent(tekDiagnostic, message = sentence))

  # AND EVERY SCOPE IS CLOSED: the host's own `run-started`, plus any a stream
  # cut short left open. Bounded by the count, so a stream cannot make this
  # loop run longer than the scopes it opened.
  var guard = vm.summary.val.openScopes
  while vm.summary.val.openScopes > 0 and guard > 0:
    vm.ingestEvent(run.suiteEvent(tekRunFinished))
    dec guard
  vm.endRun()

# ---------------------------------------------------------------------------
# Dispatching a run: the one body behind every control that starts one
# ---------------------------------------------------------------------------

type
  DesktopDispatchAnswer = object
    ## What a dispatch attempt came to.
    refusal: string
      ## "" when the run was dispatched and is now pending.
    filed: bool
      ## The refusal is ALREADY in the pane, because the run had been begun
      ## and was then settled with it. A caller that files refusals itself
      ## (`TestResultsVM.startRun`, the row controls) must not file it again,
      ## or the failure block reads the sentence twice.

proc settleRefused(host: DesktopTestHost; run: DesktopTestRun;
                   refusal: string) =
  case run.kind
  of drkRecordTest: host.settleDesktopTestRun(errorMessage = refusal)
  of drkSuite: host.settleDesktopSuiteRun("", -1, errorMessage = refusal)

proc runDispatch(host: DesktopTestHost; run: DesktopTestRun;
                 send: proc(): string): DesktopDispatchAnswer =
  ## Make `run` pending, begin it in the pane, and hand it over.
  host.pending = some(run)

  # BEFORE THE DISPATCH, so a dispatch that is refused synchronously inside
  # the call finds a run to settle. `runTestFromGutter`'s header records the
  # measured failure from doing this in the other order: the settle swept
  # nothing, and then the caller armed a spinner no second settle would clear.
  host.vm.beginRun()
  for event in desktopRunStartedEvents(run):
    host.vm.ingestEvent(event)

  # AND A DISPATCH THAT RAISES IS AN END OF THE RUN TOO, not a third
  # behaviour. `beginRun` has already happened, so an exception escaping this
  # call would leave the pane's headline on "running…" with nothing left that
  # could settle it — the very defect this module exists to close, moved from
  # the IPC round trip to the send that starts it. The real dispatches hand a
  # payload to Electron's structured clone (and `renderer.runTests` resets the
  # component tree first); none is guaranteed not to throw. §5 of the spec
  # admits no path out of a dispatched run that does not settle it.
  var refusal = ""
  try:
    refusal = send()
  except:
    # Bare, because on the JS backend a raw `throw` from the host process's
    # own code is not a `CatchableError` and a typed arm would not see it.
    let detail = getCurrentExceptionMsg()
    refusal = DesktopDispatchRaisedText &
      (if detail.len > 0: ": " & detail else: ".")
  if refusal.len > 0:
    host.settleRefused(run, refusal)
    return DesktopDispatchAnswer(refusal: refusal, filed: true)
  DesktopDispatchAnswer()

proc dispatchRecordRun(host: DesktopTestHost; dispatch: DesktopTestDispatch;
                       selector, file: string; line: int;
                       openAfter: bool): DesktopDispatchAnswer =
  ## Every `ct record-test` dispatch — the editor's Run-test, the row's `⟳`
  ## and its record-and-open — which differ only in the dispatch they hand the
  ## run to (open the recording, or keep the window).
  if host.isNil or host.vm.isNil or dispatch.isNil:
    # `NoRunHostText`, the view-model's own constant, and not a second copy of
    # its sentence: a host constructed without a dispatch is exactly the fact
    # the pane already has words for, and one string in one place is what stops
    # the two answers drifting (`Verification-Harness-Traps.md` §30).
    return DesktopDispatchAnswer(refusal: NoRunHostText)
  if host.pending.isSome:
    # NOT `settleEditorTestRun()` on this path, and the omission is the point:
    # there IS a run going, and its spinner belongs to it. `runTestFromGutter`
    # makes the same distinction where it restores the slot it displaced.
    return DesktopDispatchAnswer(refusal: DesktopRunAlreadyGoingText)
  inc host.runCounter
  let run = DesktopTestRun(
    kind: drkRecordTest,
    testId: host.vm.testIdForSelector(selector),
    selector: selector,
    file: file,
    line: line,
    runId: "ct-record-test-" & $host.runCounter,
    commandLine: "ct record-test " & selector,
    openAfter: openAfter,
    openPolicy: host.vm.effectiveOpenPolicy())
  host.runDispatch(run, proc(): string = dispatch(selector, file, line))

proc startDesktopTestRun*(host: DesktopTestHost;
                          selector, file: string; line: int): string =
  ## Take a Run-test click. "" when the run was dispatched, otherwise the
  ## sentence the caller shows instead of starting a spinner.
  if host.isNil:
    return NoRunHostText
  host.dispatchRecordRun(host.dispatch, selector, file, line,
                         openAfter = true).refusal

proc desktopSuiteCommandLine*(workspaceRoot: string): string =
  ## What the host process runs, as the pane's `run-started` quotes it. The
  ## `--events <file>` argument is the host process's own temporary file and
  ## is deliberately not part of what the user is shown.
  "ct test run --workspace " & workspaceRoot

proc dispatchSuiteRun(host: DesktopTestHost;
                      workspaceRoot: string): DesktopDispatchAnswer =
  if host.isNil or host.vm.isNil or host.suiteDispatch.isNil:
    return DesktopDispatchAnswer(refusal: NoRunHostText)
  # THE SINGLE-PENDING RULE IS SHARED with the record runs: one settle message
  # per kind, one pending run per window, and a second run of either kind is
  # refused while either is going rather than queued behind it.
  if host.pending.isSome:
    return DesktopDispatchAnswer(refusal: DesktopRunAlreadyGoingText)
  let root = workspaceRoot.strip()
  if root.len == 0:
    return DesktopDispatchAnswer(refusal: DesktopNoProjectText)
  inc host.runCounter
  let run = DesktopTestRun(
    kind: drkSuite,
    workspaceRoot: root,
    runId: "ct-test-run-" & $host.runCounter,
    commandLine: desktopSuiteCommandLine(root))
  let dispatch = host.suiteDispatch
  host.runDispatch(run, proc(): string = dispatch(root))

proc startDesktopSuiteRun*(host: DesktopTestHost;
                           workspaceRoot: string): string =
  ## Run `workspaceRoot`'s whole suite through `ct test run`. "" when the run
  ## was dispatched, otherwise why it was not.
  host.dispatchSuiteRun(workspaceRoot).refusal

proc currentWorkspaceRoot(host: DesktopTestHost): string =
  if host.isNil or host.workspaceRoot.isNil: ""
  else: host.workspaceRoot()

proc installDesktopSuiteRun*(host: DesktopTestHost;
                             workspaceRoot: DesktopWorkspaceRoot;
                             suiteDispatch: DesktopSuiteDispatch) =
  ## Install the pane's header ▶ on the desktop.
  ##
  ## THE HOST INSTALLS IT, and not `ui_js` beside it, so the claim "the
  ## desktop host installs the ▶" is one a headless suite can assert. The
  ## runner answers `RunTestsProc`'s sentence contract, with one refinement:
  ## a refusal the host has ALREADY filed in the pane (a run that was begun
  ## and then declined or raised) is answered with "", because `startRun`
  ## files whatever it is handed and the sentence would otherwise read twice.
  if host.isNil or host.vm.isNil:
    return
  host.workspaceRoot = workspaceRoot
  host.suiteDispatch = suiteDispatch
  if suiteDispatch.isNil:
    return
  host.vm.setRunTests(proc(): string =
    let answer = host.dispatchSuiteRun(host.currentWorkspaceRoot())
    if answer.filed: "" else: answer.refusal)

# ---------------------------------------------------------------------------
# The per-row controls
# ---------------------------------------------------------------------------

proc catalogItemFor(vm: TestResultsVM; testId: string): Option[TestItem] =
  for item in vm.catalog.val:
    if item.id == testId:
      return some(item)
  none(TestItem)

proc inProject*(workspaceRoot, file: string): string =
  ## A catalog file, as a path the recorder can open.
  ##
  ## The catalog keeps files PROJECT-RELATIVE (`src/main.nr`), while `ct
  ## record-test` resolves its path against its own working directory — the
  ## Electron main process's, which is not the project. So a relative file is
  ## joined onto the project folder; an absolute one (POSIX or a Windows drive
  ## path) is left alone. Written out rather than `std/os.joinPath` so the
  ## same answer comes back on both backends and for both path styles.
  if file.len == 0 or workspaceRoot.len == 0:
    return file
  if file[0] in {'/', '\\'} or (file.len > 2 and file[1] == ':'):
    return file
  var root = workspaceRoot
  while root.len > 1 and root[^1] in {'/', '\\'}:
    root.setLen(root.len - 1)
  root & "/" & file

proc noteRowRefusal(host: DesktopTestHost; answer: DesktopDispatchAnswer) =
  if answer.refusal.len > 0 and not answer.filed:
    host.vm.noteRowActionRefusal(answer.refusal)

proc recordRow(host: DesktopTestHost; testId, selector: string;
               keepWindow: bool) =
  ## `⟳` (keep the window) and record-and-open (open the recording): a `ct
  ## record-test` run of the row's test, through the same single-pending rule
  ## and the same settle as the editor's Run-test click.
  if host.isNil or host.vm.isNil:
    return
  let item = host.vm.catalogItemFor(testId)
  if item.isNone:
    host.vm.noteRowActionRefusal(DesktopRowNotInCatalogText)
    return
  let dispatch = if keepWindow: host.keepWindowDispatch else: host.dispatch
  host.noteRowRefusal(host.dispatchRecordRun(
    dispatch, selector,
    inProject(host.currentWorkspaceRoot(), item.get.file),
    item.get.range.startLine, openAfter = not keepWindow))

proc openExistingRow(host: DesktopTestHost; testId: string) =
  ## `⏵` over a recording that already exists: enter it, by id. NOT A RUN —
  ## nothing is begun, nothing is pending, nothing settles — which is the
  ## property the control exists for.
  if host.isNil or host.vm.isNil:
    return
  let recording = host.vm.recordings.val.recordingFor(testId)
  if recording.recordingId.len == 0:
    host.vm.noteRowActionRefusal(NeverRecordedText)
    return
  if host.openRecording.isNil:
    host.vm.noteRowActionRefusal(NoReplayHostText)
    return
  var refusal = ""
  try:
    refusal = host.openRecording(testId, recording.recordingId,
                                 host.vm.effectiveOpenPolicy())
  except:
    let detail = getCurrentExceptionMsg()
    refusal = DesktopOpenRaisedText &
      (if detail.len > 0: ": " & detail else: ".")
  # SAID, NOT SWALLOWED — the web arm's rule: the pane offered this control
  # believing a recording was there, so a host that disagrees owes the user
  # the sentence rather than a click that did nothing.
  host.vm.noteRowActionRefusal(refusal)

proc installDesktopRowActions*(host: DesktopTestHost;
                               keepWindowDispatch: DesktopTestDispatch;
                               openRecording: DesktopOpenRecording) =
  ## Install the three per-row actions on the desktop, mirroring the web
  ## arm's (`ui_js.startWebRenderer`): `refresh` records without navigating,
  ## `openExisting` enters the existing recording and executes nothing,
  ## `recordAndOpen` records and then enters the new recording.
  ##
  ## A nil effect leaves ITS control nil, so the pane renders it disabled with
  ## its stated reason rather than enabled over nothing.
  if host.isNil or host.vm.isNil:
    return
  host.keepWindowDispatch = keepWindowDispatch
  host.openRecording = openRecording
  # TYPED VARS, for `createTestResultsVM`'s reason: `TestRowActionProc(nil)`
  # compiles on both backends and throws on one.
  var refresh, openExisting, recordAndOpen: TestRowActionProc
  if not keepWindowDispatch.isNil:
    refresh = proc(testId, selector: string) =
      host.recordRow(testId, selector, keepWindow = true)
  if not openRecording.isNil:
    openExisting = proc(testId, selector: string) =
      host.openExistingRow(testId)
  if not host.dispatch.isNil:
    recordAndOpen = proc(testId, selector: string) =
      host.recordRow(testId, selector, keepWindow = false)
  host.vm.setRowActions(refresh, openExisting, recordAndOpen)
