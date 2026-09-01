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
## than one that says why. On the web there is no `nargo`, no subprocess and
## no test operation in the wasm worker — it dispatches exactly `compile` and
## `trace` — so running is not "not wired yet", it is unavailable for a reason
## that can be stated. `runAbsence` carries that sentence and the view shows
## it. §1b.3 step 6's rule, applied to a pane: "a plain statement of what was
## asked for and could not be found."

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

    let rows = createMemo[seq[TestResultsRow]] proc(): seq[TestResultsRow] =
      joinRows(catalog.val, summary.val)

    let isEmpty = createMemo[bool] proc(): bool =
      catalog.val.len == 0 and summary.val.rows.len == 0

    let headline = createMemo[string] proc(): string =
      headlineFor(catalog.val, summary.val, runAbsence.val)

    TestResultsVM(
      catalog: catalog,
      summary: summary,
      runAbsence: runAbsence,
      projectName: projectName,
      rows: rows,
      isEmpty: isEmpty,
      headline: headline,
      disposeProc: dispose,
    )
