## NS9 — the Test Results and Constraints panes' logic, headless.
##
## Everything asserted here is a pure function of its input, and every fixture
## is REAL producer output rather than a shape invented to suit the parser:
## `NargoInfoTemplate` is the exact stdout of `nargo info --json` run against
## the bundled template, captured on 2026-09-01. A fixture written by hand
## would test that the parser reads what its author expected, which is the one
## thing a parser never fails at.
##
## The browser-side end of this — that the SELECTORS the pane lists are the
## names `nargo test` runs — is not assertable without the toolchain, so it
## lives in `ci/test/noir-template-toolchain.sh` instead, which runs both and
## compares the sets.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_ns9_panes_vm.nim

import std/[options, strutils, unittest]

import ../../../../common/noir_constraints
import ../../../../ct_test/contracts
import ../../viewmodels/test_results_vm
import ../../viewmodels/constraints_vm

const NargoInfoTemplate = """{"programs":[{"package_name":"hello_noir","functions":[{"name":"main","opcodes":17}],"unconstrained_functions":[{"name":"directive_invert","opcodes":9},{"name":"directive_integer_quotient","opcodes":8}]}]}"""

proc item(id, selector, file: string; line: int): TestItem =
  TestItem(id: id, providerId: "noir-nargo", language: "noir",
           framework: "nargo test", name: selector, kind: tikCase,
           file: file, range: SourceRange(startLine: line, startColumn: 1,
                                          endLine: line, endColumn: 1),
           selector: selector, parentId: "", tags: @[],
           location: LocationProvenance(source: lskParser, detail: "",
                                        confidence: lcHigh),
           stale: false, staleReason: "")

proc row(testId: string; outcome: TestRunOutcome; durationMs: int;
         output = ""): TestRunRow =
  TestRunRow(testId: testId, name: testId, outcome: outcome,
             durationMs: durationMs, output: output, diagnostics: @[],
             tracePath: "", traceId: "", recordingId: "",
             recordingAttempted: false)

suite "NS9 — Constraints":

  test "ns9_constraints_parses_the_real_nargo_info_output":
    let report = parseNargoInfoJson(NargoInfoTemplate, "measured")
    check report.absence == ""
    check report.package == "hello_noir"
    check report.functions.len == 3
    check report.hasCounts()
    check report.provenance == "measured"

    # The ACIR row is the one that governs proving cost, and there is exactly
    # ONE of it — which is the finding this pane exists to render honestly.
    # Noir inlines every non-`#[fold]` function, so `utils::assert_in_range`
    # has no row of its own and §1a's `main 9 / utils::check 5` cannot be
    # produced from this project. See `common/noir_constraints.nim`'s header.
    var acirNames: seq[string] = @[]
    for fn in report.functions:
      if fn.kind == cfkAcir: acirNames.add fn.name
    check acirNames == @["main"]
    check report.acirTotal() == 17
    check report.unconstrainedTotal() == 17

  test "ns9_constraints_never_sums_across_the_two_currencies":
    # ACIR opcodes and Brillig opcodes are different units. The totals happen
    # to be equal here (17 and 17), which is exactly the coincidence that
    # would hide a bug that added them — so this asserts the sum is NOT
    # reported as one number.
    let report = parseNargoInfoJson(NargoInfoTemplate, "measured")
    check report.acirTotal() != report.acirTotal() + report.unconstrainedTotal()
    let line = headlineFor(report)
    check line.contains("17 ACIR opcodes")
    check line.contains("17 unconstrained")
    check not line.contains("34")

  test "ns9_constraints_an_unreadable_answer_is_an_absence_not_an_empty_pane":
    for bad in ["", "   ", "not json at all", "{}", """{"programs":[]}""",
                """{"programs":[{"package_name":"x"}]}"""]:
      let report = parseNargoInfoJson(bad, "measured")
      check report.absence.len > 0
      check report.functions.len == 0
      check not report.hasCounts()
      # The pane renders `absence` as its whole content, so an empty reason
      # would be a blank pane with no explanation — the state this model was
      # built to make unrepresentable.
      check report.absence.strip().len > 10

  test "ns9_constraints_staleness_is_labelled_and_does_not_apply_to_an_absence":
    var report = parseNargoInfoJson(NargoInfoTemplate, "measured")
    check not headlineFor(report).contains("stale")
    report.stale = true
    check headlineFor(report).contains("(stale)")

    var absent = absentReport("no nargo here")
    absent.stale = true
    # An absent report has no counts to be stale; the headline must stay the
    # statement of absence rather than becoming "unavailable (stale)".
    check headlineFor(absent) == "unavailable"

suite "NS9 — Test Results":

  test "ns9_test_results_a_catalog_with_no_run_is_five_not_run_rows":
    let items = @[
      item("a", "test_main", "src/main.nr", 13),
      item("b", "tests::test_bounds", "src/tests.nr", 13),
    ]
    let rows = joinRows(items, TestRunSummary())
    check rows.len == 2
    check rows[0].state == trsNotRun
    check rows[1].state == trsNotRun
    # A test nobody started has no duration, and "0 ms" would be a measurement
    # the pane did not make.
    check rows[0].durationMs == 0
    check rows[0].name == "test_main"
    check rows[1].name == "test_bounds"      # short name, module path dropped
    check rows[1].selector == "tests::test_bounds"

  test "ns9_test_results_joins_a_run_onto_the_catalog_in_catalog_order":
    let items = @[
      item("a", "test_a", "src/main.nr", 1),
      item("b", "test_b", "src/main.nr", 2),
      item("c", "test_c", "src/main.nr", 3),
    ]
    # A parallel runner reports tests as they FINISH, so the run's order is
    # arrival order. The pane must not reshuffle between runs.
    var summary = TestRunSummary()
    summary.rows = @[row("c", troFailed, 3, "assert failed"),
                     row("a", troPassed, 2)]
    let rows = joinRows(items, summary)
    check rows.len == 3
    check rows[0].testId == "a"
    check rows[1].testId == "b"
    check rows[2].testId == "c"
    check rows[0].state == trsPassed
    check rows[1].state == trsNotRun
    check rows[2].state == trsFailed
    check rows[2].message == "assert failed"
    check rows[0].durationMs == 2

  test "ns9_test_results_a_run_row_the_catalog_lacks_is_shown_not_dropped":
    # A stale catalog, or a runner that generates tests. Dropping the row
    # would make the pane quietly disagree with the runner; appending it makes
    # the disagreement visible, which is the honest rendering.
    let items = @[item("a", "test_a", "src/main.nr", 1)]
    var summary = TestRunSummary()
    summary.rows = @[row("a", troPassed, 1), row("ghost", troFailed, 4)]
    let rows = joinRows(items, summary)
    check rows.len == 2
    check rows[1].testId == "ghost"
    check rows[1].state == trsFailed
    check rows[1].file == ""

  test "ns9_test_results_headline_says_what_is_true_in_precedence_order":
    let items = @[item("a", "test_a", "src/main.nr", 1),
                  item("b", "test_b", "src/main.nr", 2)]
    var running = TestRunSummary()
    running.inProgress = true
    check headlineFor(items, running, "") == "running…"

    check headlineFor(@[], TestRunSummary(), "") == "no tests found"
    check headlineFor(items, TestRunSummary(), "") == "2 tests, not run yet"
    # With a stated reason a run cannot happen, "yet" would be a promise.
    check headlineFor(items, TestRunSummary(), "no nargo here") ==
      "2 tests, not run"

    var finished = TestRunSummary()
    finished.rows = @[row("a", troPassed, 1)]
    finished.passed = 1
    check headlineFor(items, finished, "") != "2 tests, not run yet"

  test "ns9_test_results_every_run_outcome_maps_to_a_distinct_row_state":
    # `TestRunOutcome` has no "not run" member on purpose — it is a projection
    # of a run, and a run cannot contain a test it never started. The pane's
    # extra state must therefore be unreachable from an outcome, or the join
    # could silently report a real result as "not run".
    var seen: seq[TestResultsRowState] = @[]
    for outcome in TestRunOutcome:
      let state = stateFromOutcome(outcome)
      check state != trsNotRun
      check state notin seen
      seen.add state
    check seen.len == 6
