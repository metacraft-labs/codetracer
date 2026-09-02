## A wasm `nargo test` run, as `TestEvent`s.
##
## ## It invents no model, and it invents no runner
##
## `test_results_vm.nim`'s header already says the pane is the JOIN of two
## models that existed before it: a `TestCatalog` (what tests exist) and a
## `TestRunSummary` folded from `TestEvent`s (what a run said). Its second
## half had no producer on the web, and this module is that producer — the
## adapter between `platform/noir_build.NoirTestResponse`, which is the wasm
## module's wire shape, and `ct_test/contracts.TestEvent`, which is the shape
## `ingestTestEvent` already folds and the Agent Activity pane already renders.
##
## So there are still exactly two models and exactly one fold. What arrives here
## is a list of verdicts `nargo::ops::run_test` reached; what leaves is the same
## list in the vocabulary the pane speaks.
##
## ## THE ONE THING THAT MUST NOT BE RE-DECIDED HERE
##
## `#[test(should_fail)]`. An assertion failure under that attribute is a PASS
## and a clean execution is a FAILURE, and the inversion is applied inside
## `nargo` — `test_status_program_compile_pass` and
## `check_expected_failure_message` — before the status ever reaches this
## module. `NoirTestOutcome.status` is therefore already the final verdict, and
## the mapping below is a rename of four tags and nothing more. There is no
## `if outcome.shouldFail` in the status arm and there must never be one: a
## second application of the inversion would report the whole suite backwards
## while every field still looked plausible.
##
## `shouldFail` IS read, in one place and for one purpose: the message the pane
## shows says "expected to fail" beside such a row, so a reader can tell a green
## row that means "the assertions held" from one that means "the assertions
## fired, as demanded". Saying it is the opposite of applying it.
##
## ## Why the ids are resolved against the catalog rather than recomputed
##
## `TestItem.id` is `makeTestItemId(providerId, language, framework, file,
## selector)` and the pane joins a run onto a catalog BY THAT ID. The runner
## answers a `selector` — `tests::test_main`, `fully_qualified_function_name`'s
## own string, which `noir_test_syntax.selectorFor` derives identically. So the
## id is looked up from the catalog by selector, and only DERIVED when the
## catalog has no such test.
##
## Both halves matter. Recomputing always would make the join depend on this
## module and the parser agreeing about a path spelling — the runner reports VFS
## paths (`hello_noir/src/main.nr`) and the catalog holds project-relative ones
## (`src/main.nr`) — and a mismatch there would produce a pane where every test
## appears twice, once not-run and once with a verdict. Looking up only would
## silently drop a test the runner found and the parser did not, which is a real
## disagreement worth seeing rather than hiding (`joinRows` appends such rows
## deliberately, for the same reason).

import std/[options, strutils]

import ../../../ct_test/contracts
import ../platform/noir_build

from ../../../ct_test/frameworks/noir_test_syntax import
  NoirNargoProviderId, NoirNargoFramework

export contracts

const
  noirTestLanguage* = "noir"
    ## `noir_test_syntax.providerInfo().language`, spelled here because this
    ## module derives an id when the catalog cannot supply one and the id has
    ## to be byte-for-byte the one the parser would have produced.

proc noirRunProjectRelative*(vfsPath, packageDir: string): string =
  ## The runner's VFS path as the catalog's project-relative one.
  ##
  ## `test_vfs.rs` reports `file_manager.path()` verbatim, which is the key the
  ## request registered — `hello_noir/src/main.nr`, package directory
  ## included, because `noirVfsPath` puts it there. `TestItem.file` is
  ## `src/main.nr`. This is `noirVfsPath` run backwards, and it is the only
  ## place that knows the two spellings differ.
  if packageDir.len == 0:
    return vfsPath
  let prefix = packageDir & "/"
  if vfsPath.startsWith(prefix):
    vfsPath[prefix.len .. ^1]
  else:
    vfsPath

proc noirRunTestId*(outcome: NoirTestOutcome; items: seq[TestItem];
                    packageDir: string): string =
  ## The id the pane joins on. Catalog first, derivation second — see the
  ## header for why it is both and not either.
  for item in items:
    if item.selector == outcome.name:
      return item.id
  makeTestItemId(NoirNargoProviderId, noirTestLanguage, NoirNargoFramework,
                 noirRunProjectRelative(outcome.file, packageDir),
                 outcome.name)

proc noirRunStatus*(status: NoirTestStatus): TestResultStatus =
  ## Four runner tags to four wire statuses, and NOTHING else happens here.
  ##
  ## `ntsCompileError` is `tsErrored` and not `tsFailed`, matching what the two
  ## mean: a test that did not build has established nothing about itself,
  ## while a test that failed has. `TestRunOutcome` keeps them apart too
  ## (`troErrored` / `troFailed`) and the pane gives them different glyphs, so
  ## collapsing them here would erase a distinction three layers already carry.
  ##
  ## `ntsUnknown` is `tsErrored` for the same reason it is not a failure in
  ## `noirTestFailed`: a tag this build does not recognise is a fault in the
  ## tooling, and reporting the user's test as failed for it would send them to
  ## fix a program that is fine.
  case status
  of ntsPass: tsPassed
  of ntsFail: tsFailed
  of ntsSkipped: tsSkipped
  of ntsCompileError: tsErrored
  of ntsUnknown: tsErrored

proc noirRunMessage*(outcome: NoirTestOutcome): string =
  ## The one line the pane shows under a row.
  ##
  ## For a PASS it is the expectation note or nothing — "expected to fail" is
  ## the only thing worth saying about a test that passed, and it is worth
  ## saying loudly (see the header).
  let expectation = noirTestExpectationNote(outcome)
  case outcome.status
  of ntsPass:
    if expectation.len > 0: "passed (" & expectation & ")" else: ""
  of ntsSkipped:
    let reason = outcome.output.strip()
    if reason.len > 0: reason else: "skipped"
  of ntsFail, ntsCompileError, ntsUnknown:
    let text = noirTestFailureText(outcome)
    if expectation.len > 0:
      (if text.len > 0: text & " [" & expectation & "]" else: expectation)
    else:
      text

proc noirTestDiagnostic*(outcome: NoirTestOutcome;
                         packageDir: string): Option[TestDiagnostic] =
  ## The assertion's own position, when the runner gave one.
  ##
  ## Carried so the pane's row can point at the line that FIRED rather than at
  ## the `fn` line, which is usually not the same place and is the one a reader
  ## wants. `severity` is always `dsError`: this only exists for a failure.
  if not outcome.hasDiagnostic:
    return none(TestDiagnostic)
  some TestDiagnostic(
    severity: dsError,
    message: outcome.diagnostic.message,
    file: noirRunProjectRelative(outcome.diagnostic.file, packageDir),
    range: some SourceRange(
      startLine: outcome.diagnostic.line,
      startColumn: outcome.diagnostic.column,
      endLine: (if outcome.diagnostic.endLine > 0: outcome.diagnostic.endLine
                else: outcome.diagnostic.line),
      endColumn: (if outcome.diagnostic.endColumn > 0:
                    outcome.diagnostic.endColumn
                  else: outcome.diagnostic.column)))

proc noirTestRunEvents*(response: NoirTestResponse; items: seq[TestItem];
                        runId, commandLine, packageDir: string): seq[TestEvent] =
  ## One wasm test run as the event stream `ingestTestEvent` folds.
  ##
  ## `run-started` … per test `test-started` then `test-finished` … then
  ## `run-finished`, which is the shape `test_run_summary_vm`'s `openScopes`
  ## counter requires: a stream without the closing `run-finished` leaves
  ## `inProgress` true forever, and the pane's headline says "running…" over a
  ## run that ended.
  ##
  ## A REFUSED RUN STILL PRODUCES A STREAM — `run-started`, one `diagnostic`
  ## per elaboration error, `run-finished`. Emitting nothing would leave the
  ## pane showing the previous run's verdicts under a Run button that had
  ## visibly been pressed, which is the state a user reads as "it passed".
  proc base(kind: TestEventKind): TestEvent =
    TestEvent(
      schemaVersion: TestEventSchemaVersion,
      kind: kind,
      providerId: NoirNargoProviderId,
      runId: runId,
      status: none(TestResultStatus),
      trace: none(TraceMetadata),
      diagnostic: none(TestDiagnostic))

  var started = base(tekRunStarted)
  started.message = commandLine
  result.add started

  if not response.ok:
    for diagnostic in response.diagnostics:
      var event = base(tekDiagnostic)
      event.message = diagnostic.message
      event.diagnostic = some TestDiagnostic(
        severity: dsError,
        message: diagnostic.message,
        file: noirRunProjectRelative(diagnostic.file, packageDir),
        range: some SourceRange(
          startLine: diagnostic.line, startColumn: diagnostic.column,
          endLine: (if diagnostic.endLine > 0: diagnostic.endLine
                    else: diagnostic.line),
          endColumn: (if diagnostic.endColumn > 0: diagnostic.endColumn
                      else: diagnostic.column)))
      result.add event
    if response.diagnostics.len == 0:
      var event = base(tekDiagnostic)
      event.message =
        if response.message.len > 0: response.message
        else: "the Noir toolchain could not run the tests"
      result.add event
    result.add base(tekRunFinished)
    return

  for outcome in response.tests:
    let testId = noirRunTestId(outcome, items, packageDir)

    var startedTest = base(tekTestStarted)
    startedTest.testId = testId
    result.add startedTest

    if outcome.output.strip().len > 0 and outcome.status != ntsSkipped:
      var output = base(tekOutput)
      output.testId = testId
      output.output = outcome.output
      result.add output

    # WHAT THE ROW ENDS UP SAYING GOES THROUGH `output`, and that is the
    # model's shape rather than a workaround. `test_results_vm.joinRows` builds
    # `TestResultsRow.message` from `TestRunRow.output`, and `TestRunRow` has
    # no `message` field at all — `ingestTestEvent` appends `event.output` on
    # `tekOutput` and `tekFailure` and reads `event.message` only for the run's
    # command line. So a `test-finished` carrying prose in `message` would fold
    # to a row with a verdict and nothing under it, which is exactly what the
    # first version of this module produced: green and red rows, correct in
    # every state, and not one of them saying why.
    let summaryLine = noirRunMessage(outcome)
    if noirTestFailed(outcome.status) or outcome.status == ntsUnknown:
      # `tekFailure` and not a bare `tekOutput`: it is the event that carries a
      # DIAGNOSTIC, which is how the assertion's own line reaches the row.
      var failure = base(tekFailure)
      failure.testId = testId
      failure.status = some noirRunStatus(outcome.status)
      failure.message = summaryLine
      failure.output = summaryLine
      failure.diagnostic = noirTestDiagnostic(outcome, packageDir)
      result.add failure
    elif summaryLine.len > 0:
      # A PASS THAT IS WORTH A SENTENCE — a `should_fail` test that failed as
      # demanded, or a skipped fuzzing harness. Both are green-ish rows whose
      # plain reading is wrong without the note.
      var note = base(tekOutput)
      note.testId = testId
      note.output = summaryLine
      result.add note

    var finished = base(tekTestFinished)
    finished.testId = testId
    finished.status = some noirRunStatus(outcome.status)
    finished.message = summaryLine
    finished.diagnostic = noirTestDiagnostic(outcome, packageDir)
    result.add finished

  result.add base(tekRunFinished)
