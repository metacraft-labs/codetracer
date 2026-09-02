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
## ## `runTests` is the affordance the absence used to stand in for
##
## Installed by the host, exactly as `BuildVM.runBuild` is
## (`ui_js` points it at `web_noir_build.startNoirTests` on the web arm and the
## Electron arm may point it elsewhere). Nil means no host installed one, and
## the view renders the button disabled rather than absent — a Run control that
## vanishes is indistinguishable from a pane that has no such feature.

import std/[options, strutils, tables]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../../../ct_test/contracts
import test_run_summary_vm

export test_run_summary_vm

type
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

    runTests*: proc()
      ## Start a run. Nil when no host installed one; see the header.

    # -- Derived state --
    rows*: Memo[seq[TestResultsRow]]
    isEmpty*: Memo[bool]
    headline*: Memo[string]

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

proc joinRows*(items: seq[TestItem]; summary: TestRunSummary):
    seq[TestResultsRow] =
  ## Catalog ∪ run, keyed by the runner's own test id.
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
    if byId.hasKey(item.id):
      let row = byId[item.id]
      result.add TestResultsRow(
        testId: item.id, selector: item.selector,
        name: shortName(item.selector),
        file: item.file, line: item.range.startLine,
        state: stateFromOutcome(row.outcome),
        durationMs: row.durationMs, message: row.output.strip())
    else:
      result.add TestResultsRow(
        testId: item.id, selector: item.selector,
        name: shortName(item.selector),
        file: item.file, line: item.range.startLine,
        state: trsNotRun, durationMs: 0, message: "")

  for row in summary.rows:
    if seen.hasKey(row.testId): continue
    result.add TestResultsRow(
      testId: row.testId, selector: row.testId,
      name: displayName(row.testId), file: "", line: 0,
      state: stateFromOutcome(row.outcome),
      durationMs: row.durationMs, message: row.output.strip())

proc headlineFor*(items: seq[TestItem]; summary: TestRunSummary;
                  absence: string): string =
  ## The one line above the rows. It says what is true, in this order of
  ## precedence: a run is happening; a run happened; tests exist but have not
  ## run; there are no tests.
  if summary.inProgress:
    return "running…"
  if summary.rows.len > 0:
    return summaryText(summary)
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

proc canRun*(vm: TestResultsVM): bool =
  ## Whether the ▶ does anything: a host installed a runner, this deployment
  ## stated no reason it cannot, and nothing is already in flight.
  not vm.runTests.isNil and vm.runAbsence.val.len == 0 and not vm.inFlight.val

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
  vm.runTests()

proc clearRun*(vm: TestResultsVM) =
  vm.summary.val = TestRunSummary()

proc ingestEvent*(vm: TestResultsVM; event: TestEvent) =
  ## Fold one runner event into the run. The fold is
  ## `test_run_summary_vm.ingestTestEvent` — the same one the Agent Activity
  ## pane uses — so a stream that renders in one pane renders in the other.
  var current = vm.summary.val
  ingestTestEvent(current, event)
  vm.summary.val = current

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

    let rows = createMemo[seq[TestResultsRow]] proc(): seq[TestResultsRow] =
      joinRows(catalog.val, summary.val)

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

    TestResultsVM(
      catalog: catalog,
      summary: summary,
      runAbsence: runAbsence,
      projectName: projectName,
      inFlight: inFlight,
      rows: rows,
      isEmpty: isEmpty,
      headline: headline,
      disposeProc: dispose,
    )
