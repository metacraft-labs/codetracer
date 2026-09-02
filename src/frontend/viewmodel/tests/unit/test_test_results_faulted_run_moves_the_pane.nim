## A FAULTED `nargo test` RUN MUST MOVE THE TEST RESULTS PANE.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_test_results_faulted_run_moves_the_pane.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_test_results_faulted_run_moves_the_pane.nim
##
## ## The defect, as it was measured
##
## With the Noir compiler module absent from the bundle, a click on Run
## DISPATCHED and then faulted. The worker's log said so twice —
## `nbpTest-exit verdict=npvFaulted code=1` and
## `test-results ok=false tests=0` — and the BUILD pane painted two diagnostic
## rows for it. Test Results painted nothing, and went on reading
## "5 tests, not run yet": BYTE-IDENTICAL to the pane before the click.
##
## That is worse than an ugly error. It is a pane positively asserting that
## the tests have not run, one gesture after a run of them failed, and it is
## indistinguishable from a click that was dropped on the floor. It is the same
## felt symptom the user first reported by hand — "it just hanged in the
## browser" — surviving in a quieter form after the control itself had been
## proved live.
##
## ## Why these checks are shaped the way they are
##
## **They assert RENDERED TEXT, before and after, and they assert the two
## differ.** A check that only asserted the after-text would pass over a pane
## that had shown the failure sentence all along; a check that only asserted
## "something changed" would pass over a pane that changed to something equally
## useless. Both halves are here, and the before-text is spelled out in full
## because it is the exact string the defect leaves on screen.
##
## **They drive the real producer.** The stream is
## `noir_test_run.noirTestRunEvents` over a `NoirTestResponse` that
## `noir_build.parseNoirTestResponse` produced from the wire, folded by
## `TestResultsVM.ingestEvent`, which is the fold `ui_js`'s `noirTestRunSink`
## calls. Nothing here hand-builds a `TestRunSummary`: a summary written by the
## test would assert that the renderer paints what the test author expected,
## which is the one thing a renderer never fails at, and it would not have
## caught this defect — the summary was always right, and only its RENDERING
## was missing.
##
## **The fault fixture is the one that was observed.** `parseNoirTestResponse`
## over stdout it cannot decode is exactly what `paintTestResult` answers
## `npvFaulted` to, and it leaves `ok = false`, `tests = 0` and NO diagnostics
## — so the sentence the pane ends up showing has to be one this code path
## synthesises. A fixture that carried a diagnostic would have exercised the
## easy half only.

import std/[strutils, tables, unittest]

import isonim/core/[owner, signals, computation]
import isonim/testing/mock_dom

import ../../../../ct_test/contracts
import ../../platform/noir_build
import ../../viewmodels/noir_test_run
import ../../viewmodels/test_results_vm
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

proc textOf(node: MockNode): string =
  ## Every character a reader would see under `node`, in document order.
  ##
  ## TEXT AND NOT A CLASS. `class` tells you which branch the view took;
  ## painted text tells you what the user is looking at, and the two are only
  ## the same until someone changes one of them. This campaign has already
  ## found gates that passed by comparing a class to a string it could never
  ## equal.
  collectText(node, result)

proc paneText(panel: MockNode; className: string): string =
  let nodes = allByClass(panel, className)
  if nodes.len == 0: "" else: textOf(nodes[0]).strip()

# ---------------------------------------------------------------------------
# Fixtures — the wire, verbatim
# ---------------------------------------------------------------------------

const UndecodableStdout = """
error: failed to instantiate the Noir compiler module
"""
  ## WHAT THE OBSERVED FAULT PUT ON STDOUT. A bundle with no compiler module
  ## leaves the worker answering something that is not a `TestVfsResponse`, so
  ## `parseNoirTestResponse` reports `decoded = false` and `paintTestResult`
  ## answers `npvFaulted` — the exact verdict the log recorded.

const CheckRefused = """
{"ok":false,"stage":"check","kind":"check-error",
 "message":"the project did not compile: 1 diagnostic(s)",
 "diagnostics":[{"message":"cannot find `no_such_function` in this scope",
                 "file":"app/src/main.nr","line":5,"column":5,
                 "end_line":5,"end_column":21,"start":40,"end":56,
                 "severity":"error"}],
 "passed":0,"failed":0,"skipped":0}
"""
  ## The other way a run fails to run: the module is there and the project
  ## does not compile. Carries a REAL diagnostic, so it proves the pane shows
  ## the toolchain's own sentence rather than a generic one.

const OnePassed = """
{"ok":true,"stage":"test","passed":1,"failed":0,"skipped":0,
 "tests":[{"name":"tests::test_main","file":"app/src/main.nr","line":13,
           "status":"pass","output":"","should_fail":false}]}
"""

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
  ## The bundled template's catalog size, because "5 tests, not run yet" is
  ## the literal string the defect leaves on screen.
  @[item("a", "tests::test_main", "src/main.nr", 13),
    item("b", "tests::test_bounds", "src/main.nr", 20),
    item("c", "tests::test_fails", "src/main.nr", 27),
    item("d", "tests::test_expected", "src/main.nr", 34),
    item("e", "tests::test_skipped", "src/main.nr", 41)]

proc drive(vm: TestResultsVM; stdout: string) =
  ## One run, along the path production takes.
  ##
  ## `beginRun` is what `web_noir_build.noirTestRunStarted` calls at dispatch,
  ## the fold is what `noirTestRunSink` does on the phase's exit, and `endRun`
  ## is `noirTestRunSettled`. Skipping any of the three would test a pipeline
  ## the product does not have.
  vm.beginRun()
  let response = parseNoirTestResponse(stdout)
  for event in noirTestRunEvents(response, vm.catalog.val,
                                 runId = "wasm-test-1",
                                 commandLine = "nargo test",
                                 packageDir = "app"):
    vm.ingestEvent(event)
  vm.endRun()

# ---------------------------------------------------------------------------

suite "a run that faulted must not leave the pane saying the tests never ran":

  test "a faulted run replaces 'not run yet' with a failure and its reason":
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: fiveTests()))

      let r = MockRenderer()
      let panel = renderTestResultsPanel(r, vm)

      # BEFORE THE CLICK, spelled out. This is the string the defect leaves on
      # screen after the click too, which is why it is asserted by value here
      # and compared against by value below.
      let headlineBefore = paneText(panel, "test-results-headline")
      ck headlineBefore == "5 tests, not run yet"

      # And nothing is claiming a failure yet, so the assertion below cannot
      # be green over a pane that always shows one.
      ck paneText(panel, "test-results-failure") == ""

      drive(vm, UndecodableStdout)

      let headlineAfter = paneText(panel, "test-results-headline")

      # THE DEFECT, AS ONE ASSERTION: these two were byte-identical.
      ck headlineAfter != headlineBefore
      ck headlineAfter == "run failed, no tests ran"

      # And the pane says WHY, in the words this code path produces. The BUILD
      # pane received this fault; before the fix, Test Results received the
      # same events and painted none of them.
      let failureText = paneText(panel, "test-results-failure")
      ck failureText.len > 0
      ck failureText == "the Noir toolchain could not run the tests"

      # The five tests are still listed and still honestly marked not-run —
      # they did not run. The change is that the pane no longer claims that is
      # the WHOLE truth.
      ck allByClass(panel, "test-results-row").len == 5

      dispose()
    expectCount(7)

  test "a refused run shows the toolchain's own diagnostic, not a generic one":
    ## The half that would still pass if the failure block rendered a fixed
    ## string. `cannot find \`no_such_function\` in this scope` is the
    ## compiler's sentence and the only one worth reading.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: fiveTests()))

      let r = MockRenderer()
      let panel = renderTestResultsPanel(r, vm)
      ck paneText(panel, "test-results-headline") == "5 tests, not run yet"

      drive(vm, CheckRefused)

      ck paneText(panel, "test-results-headline") == "run failed, no tests ran"

      let failureText = paneText(panel, "test-results-failure")
      ck failureText.contains("cannot find `no_such_function` in this scope")
      # POSITIONED, because the file is what makes it actionable, and
      # `diagnosticsFrom` prefixes it for exactly that reason.
      ck failureText.contains("src/main.nr")
      # `app/` is the package directory; `noirRunProjectRelative` strips it so
      # the path matches the one the editor's tabs are keyed by.
      ck not failureText.contains("app/src/main.nr")

      dispose()
    expectCount(5)

  test "a run that reported verdicts is not reported as a failure":
    ## The over-firing guard. Without it the new arm could be satisfied by a
    ## `headlineFor` that returned the failure string unconditionally, and
    ## every check above would still be green.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: fiveTests()))

      let r = MockRenderer()
      let panel = renderTestResultsPanel(r, vm)

      drive(vm, OnePassed)

      let headline = paneText(panel, "test-results-headline")
      ck headline != "run failed, no tests ran"
      ck headline.contains("1 passed")
      ck paneText(panel, "test-results-failure") == ""

      dispose()
    expectCount(3)

  test "starting a second run clears the previous failure from the pane":
    ## `beginRun` blanks the summary, so the fault of the run before last must
    ## not sit under a run that is happening now. A stale failure line is the
    ## same class of lie as a stale verdict.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: fiveTests()))

      let r = MockRenderer()
      let panel = renderTestResultsPanel(r, vm)

      drive(vm, CheckRefused)
      ck paneText(panel, "test-results-failure").len > 0

      vm.beginRun()
      ck paneText(panel, "test-results-failure") == ""
      ck paneText(panel, "test-results-headline") == "running…"

      # And a clean run after a faulted one leaves no trace of the fault.
      let response = parseNoirTestResponse(OnePassed)
      for event in noirTestRunEvents(response, vm.catalog.val,
                                     runId = "wasm-test-2",
                                     commandLine = "nargo test",
                                     packageDir = "app"):
        vm.ingestEvent(event)
      vm.endRun()
      ck paneText(panel, "test-results-failure") == ""
      ck paneText(panel, "test-results-headline").contains("1 passed")

      dispose()
    expectCount(5)

  test "a run still in flight is not yet a failed one":
    ## `runFailureLines` refuses while `inProgress`, so a diagnostic that
    ## arrives mid-run does not flip the pane to a verdict the run has not
    ## reached. Without this the headline would race the stream.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: fiveTests()))

      let r = MockRenderer()
      let panel = renderTestResultsPanel(r, vm)

      vm.beginRun()
      let response = parseNoirTestResponse(CheckRefused)
      let events = noirTestRunEvents(response, vm.catalog.val,
                                     runId = "wasm-test-3",
                                     commandLine = "nargo test",
                                     packageDir = "app")
      # Everything except the closing `run-finished`, which is the state a
      # stream is in for the whole time it is arriving.
      ck events.len >= 2
      for event in events[0 ..< events.high]:
        vm.ingestEvent(event)

      ck paneText(panel, "test-results-headline") == "running…"
      ck paneText(panel, "test-results-failure") == ""

      # The last event lands and the verdict appears.
      vm.ingestEvent(events[events.high])
      vm.endRun()
      ck paneText(panel, "test-results-headline") == "run failed, no tests ran"
      ck paneText(panel, "test-results-failure").len > 0

      dispose()
    expectCount(5)
