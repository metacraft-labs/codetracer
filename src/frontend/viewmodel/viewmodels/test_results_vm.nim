## NOT-A-TEST-LANE-FILE: this is the Test Results pane's VIEWMODEL —
## production frontend code named after the test results it models, which is
## why its basename matches the guard's `test_*` name arm. It imports no
## `unittest` and declares no `suite`/`test` block. Its behaviour IS asserted,
## by the five `ns9_test_results_*` cases in
## `src/frontend/viewmodel/tests/unit/test_ns9_panes_vm.nim`, which the
## `vm-unit` and `vm-unit-js` lanes run.

## TestResultsVM — reactive state for the Test Results pane (`Content.TestResults`).
##
## ## It invents no model
##
## Two already existed and neither had a pane:
##
##   * WHAT TESTS EXIST — `TestCatalog` / `TestItem` from
##     `src/ct_test/contracts.nim`, the `ct test` discovery contract. Produced
##     on the desktop by `ct test discover`, and in a browser by
##     `ct_test/frameworks/noir_test_syntax.noirCatalogFromSources` over the
##     bundled template's sources. Both produce the SAME selectors, and
##     `ci/test/noir-template-toolchain.sh` compares them against `nargo test`'s
##     own names rather than taking it on trust.
##   * WHAT A RUN SAID — `TestRunSummary` / `TestRunRow` from
##     `test_run_summary_vm.nim`, already folded from `TestEvent`s by
##     `ingestTestEvent`, already rendered by the Agent Activity pane, and
##     already fed by a second producer (`verification_report.toTestEvents`).
##
## This VM is the JOIN of the two, and the join is the pane's whole idea:
## a catalog item with no run row is a test that EXISTS AND HAS NOT RUN, which
## is the state the first screen is in and which neither model can express
## alone. `TestRunOutcome` deliberately has no "not run" member — it is a
## projection of a run, and a run cannot contain a test it never started — so
## adding one would have corrupted the model for the Agent Activity pane that
## shares it. The absence lives here instead, as an `Option`.
##
## ## Why `runAbsence` is a first-class field
##
## A pane that lists five tests and a Run button that does nothing is worse
## than one that says why. So `runAbsence` carries the sentence and the view
## shows it. §1b.3 step 6's rule, applied to a pane: "a plain statement of what
## was asked for and could not be found."
##
## WHAT IT NO LONGER SAYS. Until the `test` operation landed in the Noir wasm
## module this field carried a permanent paragraph — a browser has no `nargo`,
## the worker dispatches exactly `compile` and `trace`, running is unavailable.
## Every clause of that is now false: `nv_test_vfs` is an export of
## `noir_wasm.wasm`, the worker routes `test` to it, and `nargo::ops::run_test`
## reaches the verdicts. The field stays because a deployment that delivered no
## compiler module still cannot run tests and still owes a sentence saying so —
## but it is now a statement about a PARTICULAR deployment, computed by
## `ui/web_noir_build.noirTestRunAbsence`, rather than a claim about the
## product. Prose asserting an absence that has been filled teaches a user the
## product is less capable than it is, which is the mirror image of a dead
## affordance.
##
## ## A RUN THAT FAULTED IS A THIRD STATE, and it used to be invisible
##
## Three things can be true after the ▶ is pressed: the run is going, the run
## reported verdicts, or the run FAULTED before it reported any. Only the first
## two had a rendering, so the third fell through to the fourth arm of
## `headlineFor` and painted "5 tests, not run yet" — byte-identical to the
## pane before the click, which is what a user reads as a button that did
## nothing. It is the same felt symptom as the spinner that never settled,
## surviving in a quieter form after the control itself was proven live.
##
## The information was never missing; only its rendering was. A refused or
## faulted run reaches this pane as `noir_test_run.noirTestRunEvents`'
## `run-started` / `diagnostic` / `run-finished` stream, and `ingestTestEvent`
## files a diagnostic carrying no `testId` under `TestRunSummary.diagnostics` —
## the RUN-LEVEL diagnostics, as distinct from a row's. The BUILD pane was
## already showing those same lines while this pane showed none of them.
##
## So `runFailureLines` reads them back out and `headlineFor` gains an arm
## before the not-run one. The precedence matters and is not arbitrary: a run
## that produced rows AND a run-level diagnostic keeps the counts as its
## headline, because "2 passed, 1 failed" is the more specific true statement
## and the diagnostic is still rendered beneath. The new arm fires only when
## there are NO rows — precisely the case where the pane would otherwise claim
## nothing ran when something did and failed.
##
## ## `runTests` is the affordance the absence used to stand in for
##
## Installed by the host, exactly as `BuildVM.runBuild` is
## (`ui_js` points it at `web_noir_build.startNoirTests` on the web arm and the
## Electron arm may point it elsewhere). Nil means no host installed one, and
## the view renders the button disabled rather than absent — a Run control that
## vanishes is indistinguishable from a pane that has no such feature.
##
## ## THE TWO PER-ROW CONTROLS, and why they are two and not one
##
## A row is not a status line; it is an entry point into its own recorded
## execution (Noir-Studio.md §9.1). Two DIFFERENT things a reader wants from
## one, and they are not the same action under two names:
##
##   * **REFRESH THE RECORDING** (`⟳`) — execute this test again and keep the
##     new recording. Does NOT navigate. The reader stays in the pane, which is
##     what makes it usable on a row you are not finished reading.
##   * **OPEN THE RECORDING** (`⏵`) — enter the recording that ALREADY EXISTS.
##     Executes nothing. This is the whole point: the recording is already
##     there, so entering it must cost a click and not a compile.
##
## Holding **Shift** turns the second into *refresh the recording and open it*
## — the combined gesture, for the common case where you changed the test and
## want to step through the new run.
##
## And when there is NO recording, the second button means *record and open*.
## That is not a special case bolted on: `openButtonMode` orders its arms so it
## falls out — with nothing to reuse, `obmOpenExisting` is simply unreachable,
## and Shift changes nothing because there is nothing for it to change. What
## does NOT fall out, and is written by hand, is the LABEL: "Open the
## recording" over a button about to spend ten seconds compiling is a lie, so
## the title says "Record this test and open the recording" instead.
##
## ## `shiftHeld` is a Signal, and that is the discoverability fix
##
## A modifier nobody can see is a capability that is present, correct and never
## reached — this campaign's signature defect. Three things follow from making
## the modifier a piece of reactive VM state rather than a field read off the
## click event:
##
##   1. **The tooltip changes while Shift is held**, not when the pointer next
##      moves. A title computed at mouseover would be STALE EXACTLY WHEN IT
##      MATTERS: the user is already hovering the button when they reach for
##      Shift, so a mouseover-time read never fires and the tooltip goes on
##      describing the unshifted action right up until the shifted one happens.
##   2. **The button's affordance changes too** — `shift-armed` in the class and
##      a different glyph — so the modifier is visible and not merely readable.
##   3. **The title and the click cannot disagree.** `openButtonMode` is ONE
##      pure function and the tooltip, the class, the glyph and the click
##      handler are all consumers of it. A view that read `ev.shiftKey` at click
##      time would have two sources of truth for one decision, and a tooltip
##      that promised one action while the handler performed the other is worse
##      than either action alone.
##
## The unshifted tooltip also NAMES the modifier, so a user who never presses
## Shift can still find out the combined action exists.
##
## ## The two buttons have DIFFERENT absences, and collapsing them would be a lie
##
## Refreshing needs the runner: it is blocked while a run is in flight, blocked
## by whatever `runAbsence` says about this deployment, and blocked when no host
## installed a recorder.
##
## Opening an EXISTING recording needs none of that. It executes nothing, so a
## run in flight is not an obstacle; and a deployment with no compiler module
## cannot make a recording but can certainly replay one it already has. Greying
## `⏵` out for `runAbsence` would be a control that is dead for a reason which
## does not apply to it — the same defect shape as one that is dead for no
## stated reason at all.

import std/[options, strutils, tables]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../../../ct_test/contracts
import test_run_summary_vm

export test_run_summary_vm

type
  RunTestsProc* = proc()
    ## The host's runner, named so a `Signal` of it can be created carrying
    ## `nil` — an untyped `nil` gives `createSignal` nothing to infer from.

  TestRowActionProc* = proc(testId: string; selector: string)
    ## One row's action, as the host implements it. Named for `RunTestsProc`'s
    ## reason: a `Signal` of it must be constructible carrying nil.
    ##
    ## BOTH IDENTITIES ARE PASSED. The pane joins on `testId` and the runner
    ## takes `selector` (`nargo test --exact`'s string); a host that had only
    ## one of them would have to re-derive the other, and the derivation is
    ## exactly what `noirRunTestId` exists to keep in one place.

  TestRecordingRef* = object
    ## THAT a recording exists for a test, and WHICH ONE — never the recording
    ## itself.
    ##
    ## The trace document is megabytes and lives with the host that produced it
    ## (`ui/web_noir_build`'s retention table on the web arm). What the pane
    ## needs is only enough to say "there is one", to label it, and to let a
    ## check tell one recording from another. `recordingId` is that last part
    ## and it is the load-bearing field: it is the DISCRIMINATOR a gate reads to
    ## prove that pressing `⏵` opened the recording that was already there
    ## rather than quietly making a new one.
    testId*: string
    recordingId*: string
    recordedAtText*: string
      ## Local wall-clock text, for the tooltip. Human-facing only — nothing
      ## compares two of these, because a clock is not an identity.

  OpenButtonMode* = enum
    ## What `⏵` will do if it is pressed RIGHT NOW.
    ##
    ## ONE PURE FUNCTION, FOUR CONSUMERS: the title, the class, the glyph and
    ## the click handler all read `openButtonMode`, so a tooltip that promises
    ## one action while the handler performs another is not expressible.
    obmOpenExisting = "open-existing"
      ## A recording exists and Shift is not held. Enters it. EXECUTES NOTHING,
      ## which is the property the whole control exists for.
    obmRefreshAndOpen = "refresh-and-open"
      ## A recording exists and Shift IS held. Records again, then enters the
      ## NEW recording. The recording id afterwards must differ.
    obmRecordAndOpen = "record-and-open"
      ## No recording exists, so there is nothing to reuse and Shift is
      ## irrelevant. Records, then enters. The label says so rather than saying
      ## "open".

  TestResultsRowState* = enum
    ## What the pane knows about one test. `trsNotRun` is the state the join
    ## exists to produce and is not expressible in `TestRunOutcome`.
    trsNotRun = "not-run"
    trsRunning = "running"
    trsPassed = "passed"
    trsFailed = "failed"
    trsSkipped = "skipped"
    trsErrored = "errored"
    trsCancelled = "cancelled"

  TestResultsRow* = object
    testId*: string
    ## `selector` is the runner's fully-qualified name (`utils::test_x`), the
    ## string `nargo test --exact` takes. Kept beside the display name because
    ## the row's action needs it and the label must stay short.
    selector*: string
    name*: string
    file*: string
    line*: int
    state*: TestResultsRowState
    durationMs*: int
    message*: string
    recordingId*: string
      ## The recording this row can be entered into, or "" for none.
      ##
      ## CARRIED ON THE ROW rather than looked up by the view, so that the
      ## thing the buttons decide on and the thing a check reads off the DOM
      ## are the same value. The view paints it into `data-ct-recording-id`,
      ## which is what makes "did pressing ⏵ re-execute?" answerable by
      ## comparing two strings instead of by watching for a spinner.
    recordedAtText*: string
      ## When that recording was made, in local wall-clock text, or "".

  TestResultsVM* = ref object of ViewModel
    # -- Mutable state --
    catalog*: Signal[seq[TestItem]]
    summary*: Signal[TestRunSummary]
    runAbsence*: Signal[string]
      ## Why a run cannot be started here, or "" when it can.
    projectName*: Signal[string]
    inFlight*: Signal[bool]
      ## A run this pane started is still going.
      ##
      ## SEPARATE FROM `summary.inProgress`, which is derived from the event
      ## stream's open scopes. The two answer different questions and the gap
      ## between them is the whole first second of a run: a click dispatches a
      ## `start` to a worker that has 16 MB to fetch and instantiate before it
      ## emits `run-started`, and in that window `summary.inProgress` is false
      ## while a run is very much happening. A button that re-enabled there
      ## would let a user queue a second suite over the first.

    runTests*: Signal[RunTestsProc]
      ## Start a run. Nil when no host installed one; see the header.
      ##
      ## A SIGNAL, and not the plain `proc()` field it was, because the host
      ## installs it LATE. `ui_js` points it at `web_noir_build.startNoirTests`
      ## when the Noir surface comes up, which is after the pane has mounted
      ## and after `runButtonClass`/`runButtonTitle` have already been read
      ## against a nil runner. A plain field is invisible to the reactive
      ## graph, so that install re-rendered nothing and the pane kept painting
      ## the disabled button and "No host in this build can run the tests"
      ## over a runner that was by then installed and working — a dead
      ## affordance whose deadness is a lie about the product.
      ##
      ## Every other input to `canRun` (`runAbsence`, `inFlight`) is already a
      ## Signal; this was the one that was not, so it was also the one that
      ## could not re-render.

    recordings*: Signal[seq[TestRecordingRef]]
      ## Which tests have a recording that can be entered.
      ##
      ## SURVIVES `beginRun` AND `clearRun`, deliberately, and that is the
      ## difference between this and `summary`. A `TestRunSummary` describes ONE
      ## run and is blanked when the next starts; a recording is an artefact
      ## that outlives the run that made it, and blanking it would mean every
      ## row lost its `⏵` the instant anyone pressed ▶ — the recording still on
      ## disk, the only way back to it gone.

    shiftHeld*: Signal[bool]
      ## Whether Shift is down RIGHT NOW.
      ##
      ## Driven by document-level keydown/keyup, not by a click event's
      ## `shiftKey`. See the header: this is what lets the tooltip and the
      ## button's own appearance change while the pointer is already resting on
      ## it, and what keeps the promise and the action a single decision.

    refreshRecording*: Signal[TestRowActionProc]
      ## Record this test again and KEEP THE RESULT WITHOUT NAVIGATING.
    openExistingRecording*: Signal[TestRowActionProc]
      ## Enter the recording that already exists. Must execute nothing.
    recordAndOpenRecording*: Signal[TestRowActionProc]
      ## Record this test and then enter the recording that produces.

    # -- Derived state --
    rows*: Memo[seq[TestResultsRow]]
    isEmpty*: Memo[bool]
    headline*: Memo[string]
    runFailure*: Memo[seq[string]]
      ## The run-level diagnostics of the last settled run, or empty.
      ##
      ## RENDERED WHETHER OR NOT THERE ARE ROWS, unlike the headline's failed
      ## arm. A run that reported two verdicts and then faulted has both a
      ## count worth showing and a fault worth showing, and the headline can
      ## only carry one of them.

proc stateFromOutcome*(outcome: TestRunOutcome): TestResultsRowState =
  case outcome
  of troRunning: trsRunning
  of troPassed: trsPassed
  of troFailed: trsFailed
  of troSkipped: trsSkipped
  of troErrored: trsErrored
  of troCancelled: trsCancelled

proc shortName*(selector: string): string =
  ## The last `::` segment — what §1a's mock-up shows in the pane
  ## (`test_main`, not `hello_noir::tests::test_main`). The module path is
  ## still in `selector`, so nothing is lost.
  let idx = selector.rfind("::")
  if idx < 0: selector else: selector[idx + 2 .. ^1]

proc recordingFor*(recordings: seq[TestRecordingRef];
                   testId: string): TestRecordingRef =
  ## The recording held for `testId`, or a zeroed one.
  ##
  ## A LINEAR SCAN over a project's test list, and a `Table` here would buy
  ## nothing: the catalog this searches is the same one `joinRows` is already
  ## walking, and both are the length of a Noir project's `#[test]` count.
  for recording in recordings:
    if recording.testId == testId:
      return recording
  TestRecordingRef()

proc joinRows*(items: seq[TestItem]; summary: TestRunSummary;
               recordings: seq[TestRecordingRef] = @[]):
    seq[TestResultsRow] =
  ## Catalog ∪ run ∪ recordings, keyed by the runner's own test id.
  ##
  ## The catalog is the ORDER, because it is the stable one: a run reports
  ## tests as they finish, which on a parallel runner is arrival order and
  ## changes between runs. A pane whose rows reshuffle on every run is one a
  ## reader cannot keep their place in.
  ##
  ## Rows the run reported that the catalog does not have are appended rather
  ## than dropped. That is not defensive padding — it is the honest rendering
  ## of a real disagreement (a stale catalog, or a runner that generates tests)
  ## and hiding it would make the pane quietly wrong.
  var byId = initTable[string, TestRunRow]()
  for row in summary.rows:
    byId[row.testId] = row

  var seen = initTable[string, bool]()
  for item in items:
    seen[item.id] = true
    let recording = recordings.recordingFor(item.id)
    if byId.hasKey(item.id):
      let row = byId[item.id]
      result.add TestResultsRow(
        testId: item.id, selector: item.selector,
        name: shortName(item.selector),
        file: item.file, line: item.range.startLine,
        state: stateFromOutcome(row.outcome),
        durationMs: row.durationMs, message: row.output.strip(),
        recordingId: recording.recordingId,
        recordedAtText: recording.recordedAtText)
    else:
      result.add TestResultsRow(
        testId: item.id, selector: item.selector,
        name: shortName(item.selector),
        file: item.file, line: item.range.startLine,
        state: trsNotRun, durationMs: 0, message: "",
        recordingId: recording.recordingId,
        recordedAtText: recording.recordedAtText)

  for row in summary.rows:
    if seen.hasKey(row.testId): continue
    let recording = recordings.recordingFor(row.testId)
    result.add TestResultsRow(
      testId: row.testId, selector: row.testId,
      name: displayName(row.testId), file: "", line: 0,
      state: stateFromOutcome(row.outcome),
      durationMs: row.durationMs, message: row.output.strip(),
      recordingId: recording.recordingId,
      recordedAtText: recording.recordedAtText)

const RunFailedHeadline* = "run failed, no tests ran"
  ## The headline for a run that faulted before any test reported.
  ##
  ## Spelled as a constant because two renderers and the checks both name it,
  ## and because the WHOLE POINT is that this string is not either of the two
  ## it used to be confused with: it is not "5 tests, not run yet" (which
  ## asserts the tests never started) and it is not `summaryText`'s "N passed"
  ## (which asserts they finished).

proc runFailureLines*(summary: TestRunSummary): seq[string] =
  ## What a settled run said when it could not run any tests.
  ##
  ## These are `TestRunSummary.diagnostics` — the diagnostics the runner
  ## emitted with NO `testId`, which `ingestTestEvent` files at run level
  ## precisely because they belong to the run rather than to any one test. A
  ## wasm module that is absent, a crate that would not elaborate, a worker
  ## that faulted: all three arrive here and none of them has a test to hang
  ## off.
  ##
  ## EMPTY WHILE IN FLIGHT, deliberately. A run that has emitted its first
  ## diagnostic and not yet finished is still a run in progress, and reporting
  ## it as a failure would make the pane flip to a verdict it has not reached.
  ## `inProgress` is the same gate `headlineFor`'s first arm uses, so the two
  ## cannot disagree about whether the run is over.
  if summary.inProgress:
    return @[]
  for diagnostic in summary.diagnostics:
    if diagnostic.message.len > 0:
      result.add diagnostic.message

proc headlineFor*(items: seq[TestItem]; summary: TestRunSummary;
                  absence: string): string =
  ## The one line above the rows. It says what is true, in this order of
  ## precedence: a run is happening; a run happened and reported tests; a run
  ## happened and FAULTED; tests exist but have not run; there are no tests.
  if summary.inProgress:
    return "running…"
  if summary.rows.len > 0:
    return summaryText(summary)
  if runFailureLines(summary).len > 0:
    # A RUN HAPPENED AND FAILED, and this arm is the whole of the fix for a
    # pane that answered a faulted run with the sentence it had shown before
    # the click. It sits above the not-run arms because "these tests have not
    # run yet" is FALSE here — an attempt was made and it failed — and below
    # the rows arm because a run that got as far as verdicts has something
    # more specific to say.
    return RunFailedHeadline
  if items.len == 0:
    return "no tests found"
  let plural = if items.len == 1: " test" else: " tests"
  if absence.len > 0:
    return $items.len & plural & ", not run"
  $items.len & plural & ", not run yet"

proc setCatalog*(vm: TestResultsVM; catalog: TestCatalog) =
  vm.catalog.val = catalog.items

proc setRunAbsence*(vm: TestResultsVM; reason: string) =
  vm.runAbsence.val = reason

proc setRunTests*(vm: TestResultsVM; runner: RunTestsProc) =
  ## Install the host's runner. A WRITE TO THE GRAPH, which is the point: the
  ## install happens after the pane has mounted, and the button's class and
  ## title must be recomputed against it rather than left at the verdict they
  ## reached while it was nil.
  vm.runTests.val = runner

proc canRun*(vm: TestResultsVM): bool =
  ## Whether the ▶ does anything: a host installed a runner, this deployment
  ## stated no reason it cannot, and nothing is already in flight.
  not vm.runTests.val.isNil and vm.runAbsence.val.len == 0 and not vm.inFlight.val

proc beginRun*(vm: TestResultsVM) =
  ## Called by the host at the moment it dispatches, before any event arrives.
  ## Clears the previous run — a pane that kept the last verdicts under a
  ## button that had visibly been pressed is one a user reads as "it passed".
  vm.summary.val = TestRunSummary()
  vm.inFlight.val = true

proc endRun*(vm: TestResultsVM) =
  ## Called by the host when the run settles, however it settled.
  vm.inFlight.val = false

proc startRun*(vm: TestResultsVM) =
  ## The view's click handler. Guarded here rather than in the view so the mock
  ## and web renderers cannot disagree about when the button is live.
  if not vm.canRun():
    return
  # Bound first: `vm.runTests.val()` parses as `val(vm.runTests)` and calls
  # nothing.
  let runner = vm.runTests.val
  runner()

proc clearRun*(vm: TestResultsVM) =
  ## Blank the RUN. Recordings are untouched — see `TestResultsVM.recordings`
  ## for why an artefact must outlive the run that produced it.
  vm.summary.val = TestRunSummary()

# ---------------------------------------------------------------------------
# The two per-row controls
# ---------------------------------------------------------------------------

const
  NoRecorderHostText* = "No host in this build can record a test"
  NoReplayHostText* = "No host in this build can open a recording"
  RunInProgressText* = "A test run is already in progress"
  NeverRecordedText* = "this test has no recording yet"
  RecordingDiscardedText* = "this test ran, but no recording was kept"
    ## THE STATE THAT IS NOT "NEVER RUN", and the reason it has its own
    ## sentence. A row that ran and whose recording is gone looks identical to
    ## one that never ran if you only ask `recordingId == ""`, and telling a
    ## user their passing test "has no recording yet" invites them to press the
    ## button that just failed to leave one.

proc hasRecording*(row: TestResultsRow): bool =
  ## Whether `⏵` can enter something without executing anything.
  ##
  ## ONE GATE, so "the button says open" and "the button opens" cannot drift.
  ## `recordingId` and not `recordedAtText`: a clock is not an identity, and a
  ## host that failed to format a time still produced a recording.
  row.recordingId.len > 0

proc recordingAbsenceText*(row: TestResultsRow): string =
  ## Why this row has nothing to enter. "" when it has.
  if row.hasRecording(): ""
  elif row.state == trsNotRun: NeverRecordedText
  else: RecordingDiscardedText

proc setShiftHeld*(vm: TestResultsVM; held: bool) =
  ## Driven by document keydown/keyup. A WRITE TO THE GRAPH: every open
  ## button's title, class and glyph is recomputed, including the one the
  ## pointer is already resting on.
  if vm.shiftHeld.val != held:
    vm.shiftHeld.val = held

proc setRowActions*(vm: TestResultsVM;
                    refresh, openExisting, recordAndOpen: TestRowActionProc) =
  ## Install the host's three per-row actions.
  ##
  ## `setRunTests`' rule, for the same reason: these are Signals, so a plain
  ## field write would reach no observer and every row would keep painting the
  ## disabled buttons and "No host in this build can record a test" over hosts
  ## that were by then installed and working.
  vm.refreshRecording.val = refresh
  vm.openExistingRecording.val = openExisting
  vm.recordAndOpenRecording.val = recordAndOpen

proc rememberRecording*(vm: TestResultsVM;
                        testId, recordingId, recordedAtText: string) =
  ## A recording now exists for `testId`. Replaces any previous one.
  ##
  ## REPLACES RATHER THAN APPENDS, because "the recording of this test" is
  ## singular from the pane's point of view: `⏵` enters one, and a list would
  ## be a chooser this design does not have. Refreshing therefore CHANGES the
  ## id in place, which is exactly what makes the shift arm checkable.
  if testId.len == 0 or recordingId.len == 0:
    return
  var updated = vm.recordings.val
  for i in 0 ..< updated.len:
    if updated[i].testId == testId:
      updated[i] = TestRecordingRef(testId: testId, recordingId: recordingId,
                                    recordedAtText: recordedAtText)
      vm.recordings.val = updated
      return
  updated.add TestRecordingRef(testId: testId, recordingId: recordingId,
                               recordedAtText: recordedAtText)
  vm.recordings.val = updated

proc rememberRecordingForSelector*(vm: TestResultsVM;
                                   selector, recordingId,
                                   recordedAtText: string) =
  ## The same, from the identity a RUNNER knows.
  ##
  ## The host that produces a recording holds a selector — `nargo test
  ## --exact`'s string — and the pane joins on a catalog id. Resolving here and
  ## not at the call site keeps the catalog the single place the two identities
  ## meet, and degrades the way `noirRunTestId` does: with no catalog entry the
  ## selector IS the key, so a recording is still reachable from a row the
  ## catalog did not predict rather than being silently dropped.
  for item in vm.catalog.val:
    if item.selector == selector:
      vm.rememberRecording(item.id, recordingId, recordedAtText)
      return
  vm.rememberRecording(selector, recordingId, recordedAtText)

proc forgetRecordings*(vm: TestResultsVM) =
  ## Every recording this pane knew about is gone.
  ##
  ## Called when the host discards them — a new project, or a reload that left
  ## the retention table empty. It is what produces the "ran, but no recording
  ## was kept" state honestly, instead of leaving `⏵` pointing at a blob
  ## nothing holds any more.
  vm.recordings.val = @[]

proc refreshAbsence*(vm: TestResultsVM): string =
  ## Why `⟳` cannot run. "" when it can.
  ##
  ## Ordered most-specific first: a run in flight is a transient state with an
  ## obvious remedy (wait), a deployment absence is a standing fact about this
  ## bundle, and a nil host is a build that never wired the control.
  if vm.inFlight.val: RunInProgressText
  elif vm.runAbsence.val.len > 0: vm.runAbsence.val
  elif vm.refreshRecording.val.isNil: NoRecorderHostText
  else: ""

proc openButtonMode*(vm: TestResultsVM; row: TestResultsRow): OpenButtonMode =
  ## What `⏵` would do if pressed now. THE one decision; four consumers.
  ##
  ## The no-recording arm is FIRST, and that ordering is the whole of the
  ## "pleasing collapse": with nothing to reuse, Shift is not consulted, so
  ## plain and shifted presses do the same thing without a special case saying
  ## so.
  if not row.hasRecording(): obmRecordAndOpen
  elif vm.shiftHeld.val: obmRefreshAndOpen
  else: obmOpenExisting

proc openAbsence*(vm: TestResultsVM; row: TestResultsRow): string =
  ## Why `⏵` cannot run, IN THE MODE IT IS IN. "" when it can.
  ##
  ## The two modes have genuinely different requirements and this is where that
  ## is stated. Entering an existing recording executes nothing, so it is not
  ## blocked by a run in flight and not blocked by a deployment that cannot
  ## compile — a bundle with no Noir module can still replay a recording it
  ## already holds. Greying the control out for either would be a control dead
  ## for a reason that does not apply to it.
  case vm.openButtonMode(row)
  of obmOpenExisting:
    if vm.openExistingRecording.val.isNil: NoReplayHostText else: ""
  of obmRefreshAndOpen, obmRecordAndOpen:
    let absence = vm.refreshAbsence()
    if absence.len > 0: absence
    elif vm.recordAndOpenRecording.val.isNil: NoReplayHostText
    else: ""

proc refreshButtonClass*(vm: TestResultsVM): string =
  if vm.refreshAbsence().len > 0: "test-results-refresh-btn disabled"
  else: "test-results-refresh-btn"

proc refreshButtonTitle*(vm: TestResultsVM; row: TestResultsRow): string =
  ## What `⟳` will do, or why it will not.
  ##
  ## The enabled sentence says BOTH halves — that it records, and that it does
  ## not navigate — because "refresh" alone does not tell a reader whether they
  ## are about to lose the pane they are looking at.
  let absence = vm.refreshAbsence()
  if absence.len > 0:
    return absence
  if row.hasRecording():
    "Record " & row.name & " again, replacing the recording from " &
      (if row.recordedAtText.len > 0: row.recordedAtText else: "the last run") &
      ". Stays in this pane."
  else:
    "Record " & row.name & " (" & row.recordingAbsenceText() &
      "). Stays in this pane."

proc openButtonClass*(vm: TestResultsVM; row: TestResultsRow): string =
  ## `shift-armed` is the VISIBLE half of the modifier.
  ##
  ## Only in `obmRefreshAndOpen` — the mode Shift actually changed. Painting it
  ## in `obmRecordAndOpen` would tell a user Shift had done something on a row
  ## where it did nothing, which is a worse lie than not showing it at all.
  result = "test-results-open-btn"
  if vm.openButtonMode(row) == obmRefreshAndOpen:
    result.add " shift-armed"
  if vm.openAbsence(row).len > 0:
    result.add " disabled"

proc openButtonMark*(vm: TestResultsVM; row: TestResultsRow): string =
  ## The glyph, which changes with the mode for `shift-armed`'s reason: a
  ## modifier that alters what a button does should alter what it looks like.
  case vm.openButtonMode(row)
  of obmOpenExisting: "⏵"
  of obmRefreshAndOpen: "⟳⏵"
  of obmRecordAndOpen: "⏺⏵"

proc openButtonTitle*(vm: TestResultsVM; row: TestResultsRow): string =
  ## What `⏵` will do, or why it will not.
  ##
  ## THE UNSHIFTED SENTENCE NAMES THE MODIFIER. That clause is the only thing
  ## standing between the combined action and a user who never thinks to press
  ## Shift, and this campaign has found about twenty capabilities that were
  ## present, correct and never reached for want of exactly it.
  ##
  ## It also names the recording, by time. "Open the recording" is a promise
  ## that something already exists; naming WHICH one is what lets a reader
  ## notice when it is older than the edit they just made.
  let absence = vm.openAbsence(row)
  if absence.len > 0:
    # A disabled control that explains itself. In `obmRecordAndOpen` the row's
    # own absence is appended, so a user is told both that nothing can run and
    # that there was nothing to open either.
    if vm.openButtonMode(row) == obmOpenExisting:
      return absence
    return absence & " — and " & row.recordingAbsenceText()
  case vm.openButtonMode(row)
  of obmOpenExisting:
    "Open the recording of " & row.name &
      (if row.recordedAtText.len > 0: " from " & row.recordedAtText else: "") &
      " — nothing is re-run. Hold Shift to record it again first."
  of obmRefreshAndOpen:
    "Record " & row.name & " again and open the NEW recording, replacing " &
      (if row.recordedAtText.len > 0: "the one from " & row.recordedAtText
       else: "the existing one") & "."
  of obmRecordAndOpen:
    # NOT "OPEN". There is nothing to open and the button is about to spend a
    # compile; a label promising otherwise is the lie the header names.
    "Record " & row.name & " and open the recording (" &
      row.recordingAbsenceText() & ")."

proc noteRowActionRefusal*(vm: TestResultsVM; message: string) =
  ## A per-row control was pressed and the host could not honour it.
  ##
  ## FILED AS A RUN-LEVEL DIAGNOSTIC, so it renders in the pane's existing
  ## `.test-results-failure` block — the surface that already exists for "an
  ## attempt was made and it did not work".
  ##
  ## SPECIFICALLY NOT `setRunAbsence`, which was the first thing tried and is
  ## a category error with real consequences. `runAbsence` means "this
  ## DEPLOYMENT cannot run tests"; writing a failed replay into it would grey
  ## out the header's ▶ and every row's `⟳` because a `⏵` did not work — a
  ## refusal in one control disabling three others, and a standing claim about
  ## the bundle made out of a transient event.
  if message.len == 0:
    return
  var current = vm.summary.val
  current.diagnostics.add TestRunDiagnostic(
    severity: "error", message: message)
  vm.summary.val = current

proc triggerRefresh*(vm: TestResultsVM; row: TestResultsRow) =
  ## The `⟳` click. Guarded HERE and not in the view, so the mock and web
  ## renderers cannot disagree about when the control is live — the rule
  ## `startRun` already follows for the header's ▶.
  if vm.refreshAbsence().len > 0:
    return
  let action = vm.refreshRecording.val
  if action.isNil:
    return
  action(row.testId, row.selector)

proc triggerOpen*(vm: TestResultsVM; row: TestResultsRow) =
  ## The `⏵` click, dispatched on the SAME `openButtonMode` the tooltip was
  ## rendered from. Reading `shiftHeld` again here rather than taking a
  ## modifier off the event is what makes that identity structural.
  if vm.openAbsence(row).len > 0:
    return
  case vm.openButtonMode(row)
  of obmOpenExisting:
    let action = vm.openExistingRecording.val
    if not action.isNil:
      action(row.testId, row.selector)
  of obmRefreshAndOpen, obmRecordAndOpen:
    let action = vm.recordAndOpenRecording.val
    if not action.isNil:
      action(row.testId, row.selector)

proc ingestEvent*(vm: TestResultsVM; event: TestEvent) =
  ## Fold one runner event into the run. The fold is
  ## `test_run_summary_vm.ingestTestEvent` — the same one the Agent Activity
  ## pane uses — so a stream that renders in one pane renders in the other.
  var current = vm.summary.val
  ingestTestEvent(current, event)
  vm.summary.val = current

  # AND THE RECORDING IS HARVESTED OFF THE SAME STREAM.
  #
  # `ingestTestEvent` already flattens `event.trace` onto `TestRunRow`, but a
  # `TestRunSummary` is blanked by the next `beginRun` — so a recording learned
  # only from there would vanish the moment anyone pressed ▶ again. Copying it
  # into `recordings` here is what makes it durable, and doing it in this proc
  # rather than at a call site means every producer that emits a
  # `recording-created` gets it, not just the one that was in mind.
  if event.testId.len > 0 and event.trace.isSome:
    let trace = event.trace.get
    if trace.recordingId.len > 0:
      vm.rememberRecording(event.testId, trace.recordingId,
                           trace.metadata.getOrDefault("recordedAt", ""))

proc applyRunText*(vm: TestResultsVM; text: string): bool =
  ## Fold a whole NDJSON stream. Returns whether it contained any events, so a
  ## caller can tell "the runner said nothing we understood" from "the runner
  ## reported no tests" — the distinction `parseTestRun` exists to preserve.
  let parsed = parseTestRun(text)
  if parsed.isNone:
    return false
  vm.summary.val = parsed.get
  true

proc createTestResultsVM*(): TestResultsVM =
  withViewModel proc(dispose: proc()): TestResultsVM =
    let catalog = createSignal(newSeq[TestItem]())
    let summary = createSignal(TestRunSummary())
    let runAbsence = createSignal("")
    let projectName = createSignal("")
    let inFlight = createSignal(false)
    # A TYPED VAR, and `createSignal(RunTestsProc(nil))` is specifically wrong.
    # That conversion compiles on both backends and runs on one: `nim js`
    # emits it as `null.bind(null)`, which throws at module scope and took
    # every test that merely CONSTRUCTS this VM down with it — including six
    # that never touch `runTests`. The native lane stayed green throughout.
    var noRunner: RunTestsProc
    let runTests = createSignal(noRunner)

    let recordings = createSignal(newSeq[TestRecordingRef]())
    let shiftHeld = createSignal(false)
    # THREE TYPED VARS, for `noRunner`'s reason and not for tidiness.
    # `createSignal(TestRowActionProc(nil))` compiles on both backends and runs
    # on one: `nim js` emits the conversion as `null.bind(null)`, which throws
    # at module scope and takes down every test that merely CONSTRUCTS this VM.
    var noRefresh, noOpenExisting, noRecordAndOpen: TestRowActionProc
    let refreshRecording = createSignal(noRefresh)
    let openExistingRecording = createSignal(noOpenExisting)
    let recordAndOpenRecording = createSignal(noRecordAndOpen)

    let rows = createMemo[seq[TestResultsRow]] proc(): seq[TestResultsRow] =
      joinRows(catalog.val, summary.val, recordings.val)

    let isEmpty = createMemo[bool] proc(): bool =
      catalog.val.len == 0 and summary.val.rows.len == 0

    let headline = createMemo[string] proc(): string =
      if inFlight.val and not summary.val.inProgress and
         summary.val.rows.len == 0:
        # The dispatched-but-silent window. See `inFlight`: the worker has the
        # request and has not answered, and "5 tests, not run yet" over a run
        # the user just started reads as a button that did nothing.
        "running…"
      else:
        headlineFor(catalog.val, summary.val, runAbsence.val)

    let runFailure = createMemo[seq[string]] proc(): seq[string] =
      # NOT gated on `inFlight`. `runFailureLines` already refuses to answer
      # while `summary.inProgress`, and adding the second gate here would
      # blank the fault for the window between the last event and the host's
      # `endRun` — a flicker back to silence at the exact moment the user
      # looks for the reason.
      runFailureLines(summary.val)

    TestResultsVM(
      catalog: catalog,
      summary: summary,
      runAbsence: runAbsence,
      projectName: projectName,
      inFlight: inFlight,
      runTests: runTests,
      recordings: recordings,
      shiftHeld: shiftHeld,
      refreshRecording: refreshRecording,
      openExistingRecording: openExistingRecording,
      recordAndOpenRecording: recordAndOpenRecording,
      rows: rows,
      isEmpty: isEmpty,
      headline: headline,
      runFailure: runFailure,
      disposeProc: dispose,
    )
