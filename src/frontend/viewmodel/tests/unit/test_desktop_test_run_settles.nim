## A DESKTOP TEST RUN MUST END, AND THE PANE MUST SAY HOW.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_desktop_test_run_settles.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_desktop_test_run_settles.nim
##
## Spec: `GUI/Core-Panes/Test-Results-Pane.md` §4 and §5.
##
## ## The defect, as it was on the tree (issue #748)
##
## On the desktop the editor's Run-test click reached `renderer.runTests` →
## `CODETRACER::run-test` → `index/traces.onRunTest`, which runs `ct
## record-test` and then either loads the resulting trace or, on its error arm,
## sends `CODETRACER::failed-record`. **Not one of its exits reached anything
## the Test Results pane subscribes to, and none of them reached
## `editor.settleEditorTestRun`.** `settleEditorTestRun` had exactly one caller
## outside `editor.nim` — `ui_js.nim:6475`, inside `startWebRenderer`, which the
## desktop never enters — and `setRunTests` exactly one non-test caller, in the
## same block. (`editor.nim`'s own `runTestFromGutter` also calls it, but only
## to unwind a spinner it armed one line earlier over a dispatch that was
## refused; it settles no run that a host started, which is the point.)
##
## So the button spun until its own two-minute deadline, and the pane read "no
## tests found" throughout. Both halves of the report.
##
## ## Why these checks are shaped the way they are
##
## **THEY ASSERT PAINTED TEXT.** The pane is mounted with `MockRenderer` and
## the headline and failure block are read back out of the rendered tree.
## "`endRun` was called" and "the user can see the run ended" are different
## claims and only the second is the product.
##
## **THE FAILURE PATH IS THE CENTRAL CASE, NOT AN EXTRA ONE.** It is the path a
## user actually meets: a successful run replaces the window with the
## recording, so the stuck spinner is mostly seen after a recorder that could
## not build the project.
##
## **AND THE FAILURE ARM'S ASSERTION HAD TO BE CHOSEN, not merely written**
## (`Testing/Verification-Harness-Traps.md` §7). The obvious assertion — "the
## pane lists no verdicts" — is satisfied by the broken state and by the fixed
## one alike: a failed run produces no rows either way. What discriminates is
## the HEADLINE, which moves from "5 tests, not run yet" (byte-identical before
## the click and after a failed run, which is what a user reads as a button
## that did nothing) to `RunFailedHeadline`, with the recorder's own sentence
## beneath it. Both are asserted, and the before-value is asserted too so the
## two cannot be the same string by accident.
##
## **THERE IS AN OVER-SETTLING GUARD.** A host that called `settleEditor` on
## every touch would satisfy every positive arm here, so the in-flight arm
## asserts the settle count is still zero while the run is going, and the
## second-click arm asserts a refused second run does not settle the first.
##
## ## The one mock, and why it is a spy rather than a fake
##
## `DesktopTestHost`'s two effects are injected, and this suite passes closures
## that COUNT and RECORD. That is not a mock of the subject: the subject is the
## host's own state machine and the real `TestResultsVM`, both of which are
## exercised for real. What is replaced is `renderer.runTests` (an Electron IPC
## send) and `ui/editor.settleEditorTestRun` (Monaco + the DOM) — two process
## boundaries that cannot exist in a headless lane and whose only contribution
## to this question is "was I called, and how often".

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

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const
  RecorderFailed =
    "ct record-test error: \"Exit with code 1\""
    ## `index/traces.onRunTest`'s error arm, verbatim in shape: it composes
    ## `"ct record-test error: " & JSON.stringify(processResult.error)`, and
    ## `electron_lib.readProcessOutput` rejects a non-zero exit with the
    ## string `Exit with code <n>`. Compared by VALUE below rather than merely
    ## asserting the block is non-empty, because what is under test is that
    ## whatever the host process said reaches the screen intact.

  NotRunYet = "5 tests, not run yet"
    ## What the pane says before the click — AND what it said after a failed
    ## run before this fix. The suite's whole discrimination rests on this
    ## string, so it is named.

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

type
  Spies = ref object
    ## What the two injected effects were asked to do.
    dispatched: int
    settled: int
    lastSelector: string
    lastFile: string
    lastLine: int
    refuseWith: string

proc hostOverPane(spies: Spies): (TestResultsVM, MockNode, DesktopTestHost) =
  let vm = createTestResultsVM()
  vm.setCatalog(TestCatalog(items: fiveTests()))
  let r = MockRenderer()
  let panel = renderTestResultsPanel(r, vm)
  let host = newDesktopTestHost(
    vm,
    dispatch = proc(selector, file: string; line: int): string =
      inc spies.dispatched
      spies.lastSelector = selector
      spies.lastFile = file
      spies.lastLine = line
      spies.refuseWith,
    settleEditor = proc(note: string) =
      inc spies.settled)
  (vm, panel, host)

# ---------------------------------------------------------------------------

suite "a test run dispatched through the desktop host ends, and says how":

  test "the dispatch reaches beginRun, and the pane says the run is going":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = Spies()
      let (vm, panel, host) = hostOverPane(spies)

      # BEFORE, spelled out — the string the defect leaves on screen after a
      # failed run as well, which is why it is compared by value in the third
      # case below.
      ck paneText(panel, "test-results-headline") == NotRunYet
      ck not vm.inFlight.val

      ck host.startDesktopTestRun("tests::test_main", "src/main.nr", 13) == ""

      # The dispatch went to the host process, with the test the click named.
      ck spies.dispatched == 1
      ck spies.lastSelector == "tests::test_main"
      ck spies.lastFile == "src/main.nr"
      ck spies.lastLine == 13

      # `beginRun`, and it is VISIBLE. The headline is what a user reads.
      ck vm.inFlight.val
      ck paneText(panel, "test-results-headline") == "running…"

      # THE OVER-SETTLING GUARD. Nothing has ended, so nothing may have been
      # told that something ended.
      ck spies.settled == 0

      dispose()
    expectCount(10)

  test "a run that produced a recording settles, and the recording is kept":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = Spies()
      let (vm, panel, host) = hostOverPane(spies)
      ck host.startDesktopTestRun("tests::test_main", "src/main.nr", 13) == ""

      host.settleDesktopTestRun(recordingId = "rec-1",
                                recordedAtText = "14:05:02")

      # `endRun` — the half that was never reached on this arm.
      ck not vm.inFlight.val
      # AND THE EDITOR'S BUTTON WAS TOLD. `settleEditorTestRun` is what stops
      # the animation; it had exactly one caller in the frontend and it was
      # inside the web-only bootstrap.
      ck spies.settled == 1

      # The run reported no VERDICT and the pane does not invent one: `ct
      # record-test` exits 0 for a test that ran and failed, so a row painted
      # green here would be a lie. What it does carry is the recording.
      ck paneText(panel, "test-results-headline") == NotRunYet
      let rows = vm.rows.val
      var recorded = 0
      for row in rows:
        if row.testId == "a":
          if row.recordingId == "rec-1" and row.recordedAtText == "14:05:02":
            inc recorded
      ck recorded == 1
      ck rows.len == 5

      dispose()
    expectCount(6)

  test "a run the recorder FAILED settles too, and the pane says why":
    ## THE PATH THE DEFECT IS MOST OFTEN MET ON, and the one the milestone
    ## calls out: a successful run replaces the window with the recording, so
    ## the spinner that never stops is mostly seen after a failure.
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = Spies()
      let (vm, panel, host) = hostOverPane(spies)
      ck host.startDesktopTestRun("tests::test_main", "src/main.nr", 13) == ""
      ck paneText(panel, "test-results-failure") == ""
      ck "hidden" in firstByClass(panel, "test-results-failure")
        .attributes.getOrDefault("class", "")

      host.settleDesktopTestRun(errorMessage = RecorderFailed)

      ck not vm.inFlight.val
      ck spies.settled == 1

      # THE DEFECT, AS ONE ASSERTION. Before this, a failed run left the
      # headline on the string it had before the click — which is why the
      # assertion is `!=` against that named value as well as `==` against the
      # new one. "The pane lists no verdicts" would have been true either way.
      let headline = paneText(panel, "test-results-headline")
      ck headline != NotRunYet
      ck headline == RunFailedHeadline

      # AND THE REASON IS PAINTED, in the host process's own words, in a block
      # that is no longer hidden.
      ck "hidden" notin firstByClass(panel, "test-results-failure")
        .attributes.getOrDefault("class", "")
      ck paneText(panel, "test-results-failure") == RecorderFailed

      # NOT A STANDING CLAIM ABOUT THE BUILD. One recorder failure must not
      # grey the pane out for the rest of the session.
      ck vm.runAbsence.val == ""

      dispose()
    expectCount(10)

  test "a second click while a run is going is refused, and settles nothing":
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = Spies()
      let (vm, panel, host) = hostOverPane(spies)
      ck host.startDesktopTestRun("tests::test_main", "src/main.nr", 13) == ""

      ck host.startDesktopTestRun("tests::test_bounds", "src/main.nr", 20) ==
        DesktopRunAlreadyGoingText
      ck spies.dispatched == 1

      # THE RUNNING SPINNER BELONGS TO THE FIRST RUN. A blanket settle here
      # would make the second click visibly "finish" the first.
      ck spies.settled == 0
      ck vm.inFlight.val
      ck paneText(panel, "test-results-headline") == "running…"

      # And the first run still settles normally afterwards.
      host.settleDesktopTestRun(recordingId = "rec-1")
      ck not vm.inFlight.val
      ck spies.settled == 1

      dispose()
    expectCount(8)

  test "a dispatch the host process declines settles immediately":
    ## The synchronous-refusal path. `runTestFromGutter`'s header records the
    ## measured version of this on the web arm: a dispatch refused inside the
    ## hook left the slot spinning for the full two minutes, because the settle
    ## ran before anything had been armed. Here the run is begun first, so the
    ## refusal has something to unwind.
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = Spies()
      spies.refuseWith = "the recorder is already running"
      let (vm, panel, host) = hostOverPane(spies)

      ck host.startDesktopTestRun("tests::test_main", "src/main.nr", 13) ==
        "the recorder is already running"
      ck spies.dispatched == 1
      ck spies.settled == 1
      ck not vm.inFlight.val
      ck paneText(panel, "test-results-failure") ==
        "the recorder is already running"

      # And the host is free again: the refused run did not leave a pending
      # one behind that would refuse every later click.
      spies.refuseWith = ""
      ck host.startDesktopTestRun("tests::test_main", "src/main.nr", 13) == ""
      ck vm.inFlight.val

      dispose()
    expectCount(7)

  test "a dispatch that RAISES settles too, and says what was thrown":
    ## THE LAST PATH OUT OF A DISPATCHED RUN. `beginRun` happens before the
    ## dispatch so a synchronous refusal has something to unwind — which leaves
    ## an exception escaping the same call as the one way the run could still
    ## be begun and never ended. The real dispatch is `renderer.runTests`: it
    ## resets the component tree and then hands a payload to Electron's
    ## structured clone, and neither is guaranteed not to throw. §5 admits no
    ## such path, so it is asserted rather than assumed.
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = Spies()
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: fiveTests()))
      let r = MockRenderer()
      let panel = renderTestResultsPanel(r, vm)
      let host = newDesktopTestHost(
        vm,
        dispatch = proc(selector, file: string; line: int): string =
          inc spies.dispatched
          raise newException(IOError, "the payload could not be cloned"),
        settleEditor = proc(note: string) = inc spies.settled)

      let answer = host.startDesktopTestRun("tests::test_main", "src/main.nr", 13)

      # THE CLICK IS TOLD, so the caller shows a sentence instead of arming a
      # spinner, and the sentence carries what the host process actually said.
      ck answer.startsWith(DesktopDispatchRaisedText)
      ck "the payload could not be cloned" in answer
      ck spies.dispatched == 1

      # AND THE RUN ENDED. Both halves: the pane and the editor.
      ck not vm.inFlight.val
      ck spies.settled == 1
      ck paneText(panel, "test-results-headline") == RunFailedHeadline
      ck paneText(panel, "test-results-failure") == answer

      # The host is free again rather than wedged behind a run it still thinks
      # is pending — the second-click refusal must not become permanent.
      ck host.pending.isNone

      dispose()
    expectCount(8)

  test "a host with no dispatch says so rather than pretending to run":
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: fiveTests()))
      var noDispatch: DesktopTestDispatch
      var noSettle: DesktopTestSettleEditor
      let host = newDesktopTestHost(vm, noDispatch, noSettle)

      # `NoRunHostText` is the VIEW-MODEL's constant, the same one
      # `runButtonTitle` paints into the disabled ▶'s tooltip. Asserting
      # against it rather than against a literal is what makes "the host said
      # it cannot run" and "the pane said it cannot run" one fact.
      ck host.startDesktopTestRun("tests::test_main", "src/main.nr", 13) ==
        NoRunHostText
      # NOTHING WAS BEGUN. A host that cannot dispatch must not leave the pane
      # claiming a run is in flight — that is the spinner defect with the
      # spinner in a different place.
      ck not vm.inFlight.val

      dispose()
    expectCount(2)

suite "the desktop host files its run under the id the pane joins on":

  test "a selector the catalog knows resolves to that test's id":
    ## `testIdForSelector` is ONE function with two callers
    ## (`rememberRecordingForSelector` and this host) for
    ## `Verification-Harness-Traps.md` §30's reason: a second copy is a second
    ## thing that can be wrong while its twin agrees with itself. Here the
    ## consequence is concrete — the run and the recording it produces have to
    ## land on the same row.
    startCount()
    createRoot proc(dispose: proc()) =
      let spies = Spies()
      let (vm, _, host) = hostOverPane(spies)

      ck vm.testIdForSelector("tests::test_bounds") == "b"
      discard host.startDesktopTestRun("tests::test_bounds", "src/main.nr", 20)
      host.settleDesktopTestRun(recordingId = "rec-b")

      var onRowB = 0
      for row in vm.rows.val:
        if row.testId == "b" and row.recordingId == "rec-b":
          inc onRowB
      ck onRowB == 1

      dispose()
    expectCount(2)

  test "a selector the catalog does not know still reaches a row":
    ## The degradation `noir_test_run.noirRunTestId` documents: with no catalog
    ## entry the selector IS the key, so a desktop run of a Python or Rust test
    ## — neither of which this build discovers into a catalog — is still
    ## reachable rather than silently dropped.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createTestResultsVM()
      let spies = Spies()
      let host = newDesktopTestHost(
        vm,
        dispatch = proc(selector, file: string; line: int): string =
          inc spies.dispatched
          "",
        settleEditor = proc(note: string) = inc spies.settled)

      ck vm.testIdForSelector("test_unknown") == "test_unknown"
      discard host.startDesktopTestRun("test_unknown", "tests/t.py", 4)
      host.settleDesktopTestRun(recordingId = "rec-py",
                                recordedAtText = "09:00:00")

      var found = 0
      for recording in vm.recordings.val:
        if recording.testId == "test_unknown" and
           recording.recordingId == "rec-py":
          inc found
      ck found == 1
      ck spies.settled == 1

      dispose()
    expectCount(3)
