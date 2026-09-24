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
## ## Why the dispatch and the editor settle are injected
##
## The dispatch is `renderer.runTests`, which sends an Electron IPC message;
## the settle is `ui/editor.settleEditorTestRun`, which reaches Monaco and the
## DOM. Neither compiles in a headless lane, and this module's whole subject —
## *does a run that started reach `endRun`, and does the editor get told* — is
## exactly what has to be asserted without them. `ui_js` supplies the real two
## in its `if inElectron:` block, the suite supplies spies, and there is one
## body either way.

import std/options

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

  DesktopTestRun* = object
    ## The run this window is waiting on.
    testId*: string
      ## What the pane joins on — `TestResultsVM.testIdForSelector`, so the
      ## run and the recording it produces land on the same row.
    selector*: string
    file*: string
    line*: int
    runId*: string
    commandLine*: string

  DesktopTestHost* = ref object
    vm*: TestResultsVM
    dispatch*: DesktopTestDispatch
    settleEditor*: DesktopTestSettleEditor
    pending*: Option[DesktopTestRun]
    runCounter*: int

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
    ## `TestEvent.providerId` for this host. Names the command that produced
    ## the run, the way `noir_test_run` names `NoirNargoProviderId`.

proc newDesktopTestHost*(vm: TestResultsVM;
                         dispatch: DesktopTestDispatch;
                         settleEditor: DesktopTestSettleEditor):
                         DesktopTestHost =
  DesktopTestHost(vm: vm, dispatch: dispatch, settleEditor: settleEditor,
                  pending: none(DesktopTestRun), runCounter: 0)

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
    providerId: DesktopTestProviderId,
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
      providerId: DesktopTestProviderId,
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
  if host.pending.isNone:
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

proc startDesktopTestRun*(host: DesktopTestHost;
                          selector, file: string; line: int): string =
  ## Take a Run-test click. "" when the run was dispatched, otherwise the
  ## sentence the caller shows instead of starting a spinner.
  if host.isNil or host.vm.isNil or host.dispatch.isNil:
    # `NoRunHostText`, the view-model's own constant, and not a second copy of
    # its sentence: a host constructed without a dispatch is exactly the fact
    # the pane already has words for, and one string in one place is what stops
    # the two answers drifting (`Verification-Harness-Traps.md` §30).
    return NoRunHostText
  if host.pending.isSome:
    # NOT `settleEditorTestRun()` on this path, and the omission is the point:
    # there IS a run going, and its spinner belongs to it. `runTestFromGutter`
    # makes the same distinction where it restores the slot it displaced.
    return DesktopRunAlreadyGoingText

  inc host.runCounter
  let run = DesktopTestRun(
    testId: host.vm.testIdForSelector(selector),
    selector: selector,
    file: file,
    line: line,
    runId: "ct-record-test-" & $host.runCounter,
    commandLine: "ct record-test " & selector)
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
  # the IPC round trip to the send that starts it. The real dispatch is
  # `renderer.runTests`, which resets the component tree and then hands a
  # payload to Electron's structured clone; neither is guaranteed not to
  # throw. §5 of the spec admits no path out of a dispatched run that does not
  # settle it, and this is the last one.
  var refusal = ""
  try:
    refusal = host.dispatch(selector, file, line)
  except:
    # Bare, because on the JS backend a raw `throw` from the host process's
    # own code is not a `CatchableError` and a typed arm would not see it.
    let detail = getCurrentExceptionMsg()
    refusal = DesktopDispatchRaisedText &
      (if detail.len > 0: ": " & detail else: ".")
  if refusal.len > 0:
    host.settleDesktopTestRun(errorMessage = refusal)
    return refusal
  ""
