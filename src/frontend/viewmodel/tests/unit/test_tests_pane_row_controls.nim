## THE TESTS PANE MUST OFFER, PER ROW, TWO DIFFERENT ACTIONS.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_tests_pane_row_controls.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_tests_pane_row_controls.nim
##
## ## What was asked for, and why one button could not have answered it
##
## The user's words: *"The tests results panel should offer a way to re-run a
## specific test and to enter an existing recording (this is not necessarily a
## re-run)."* The parenthesis is the requirement. Two actions:
##
##   * `⟳` **refresh the recording** — execute this test again, keep the new
##     recording, and DO NOT NAVIGATE;
##   * `⏵` **open the recording** — enter the one that already exists,
##     EXECUTING NOTHING.
##
## Plus the two the design adds on top: **Shift + `⏵`** refreshes *and* opens,
## and with no recording `⏵` means record-and-open — with a label that says so,
## because "open" over a button about to spend a compile is a lie.
##
## A single control that ran the test and ended in the debugger would satisfy
## none of them.
##
## ## Why these checks are shaped the way they are
##
## **THE DISCRIMINATOR IS `data-ct-recording-id`, AND IT IS NAMED IN THE
## ASSERTION.** A check that could not tell "the existing recording was opened"
## from "a new one was quietly made" would make this whole feature
## untrustworthy — it would pass just as green over an implementation that
## re-ran the test every time, which is precisely the thing the user said this
## is *not*. So every arm about `⏵` reads the id off the DOM before the click
## and again after it, and asserts the direction of the comparison by name:
## UNCHANGED for open, CHANGED for the shift arm.
##
## **PER CONTROL AND PER STATE, BY NAME.** "The TESTS pane has buttons" cannot
## fail for its own reason. Each case below names one control and one row state,
## so a failure says which of the ten combinations broke.
##
## **THE TWO BUTTONS ARE ASSERTED TO DISAGREE.** Several arms check that one is
## disabled while the other is not — a run in flight blocks `⟳` and not `⏵`,
## because entering an existing recording executes nothing. A test that only
## ever asserted them together would pass over an implementation that collapsed
## them into one availability rule, which would be a control dead for a reason
## that does not apply to it.
##
## **THE TOOLTIP IS ASSERTED TO MOVE ON `setShiftHeld` ALONE.** No pointer
## event, no rebuild, no second render — because the defect being guarded
## against is a title that is correct at mouseover and stale for the rest of the
## hover, which is exactly when the modifier is reached for.
##
## **A DISABLED CONTROL IS ASSERTED TO EXPLAIN ITSELF.** Every disabled arm
## checks the `title` is non-empty AND names the reason, not merely that the
## class contains `disabled`. A greyed control that says nothing is the same
## dead affordance with better manners.

import std/[options, strutils, tables, unittest]

import isonim/core/[owner, signals, computation]
import isonim/testing/mock_dom

import ../../../../ct_test/contracts
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

proc attr(node: MockNode; name: string): string =
  node.attributes.getOrDefault(name, "")

proc collectText(node: MockNode; acc: var string) =
  if node.kind == mnkText:
    acc.add node.text
  for child in node.children:
    collectText(child, acc)

proc textOf(node: MockNode): string =
  collectText(node, result)

proc rowNodes(panel: MockNode): seq[MockNode] =
  ## The rows, and ONLY the rows.
  ##
  ## `allByClass` matches by substring, which is why the actions wrapper in the
  ## view is called `test-results-actions` and not `test-results-row-actions`.
  ## This proc is where that would have broken first: a wrapper carrying the
  ## other name would double every count below, and the arms asserting "five
  ## rows" would have gone on passing at ten.
  allByClass(panel, "test-results-row")

proc rowNamed(panel: MockNode; testId: string): MockNode =
  for node in rowNodes(panel):
    if node.attr("data-ct-test-id") == testId:
      return node
  MockNode(nil)

proc refreshButtonOf(row: MockNode): MockNode =
  let found = allByClass(row, "test-results-refresh-btn")
  if found.len == 0: MockNode(nil) else: found[0]

proc openButtonOf(row: MockNode): MockNode =
  let found = allByClass(row, "test-results-open-btn")
  if found.len == 0: MockNode(nil) else: found[0]

proc isDisabled(node: MockNode): bool =
  not node.isNil and "disabled" in node.attr("class")

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

proc item(id, selector, file: string; line: int): TestItem =
  TestItem(id: id, providerId: "noir-nargo", language: "noir",
           framework: "nargo test", name: selector, kind: tikCase,
           file: file, range: SourceRange(startLine: line, startColumn: 1,
                                          endLine: line, endColumn: 1),
           selector: selector, parentId: "", tags: @[],
           location: LocationProvenance(source: lskParser, detail: "",
                                        confidence: lcHigh),
           stale: false, staleReason: "")

proc threeTests(): seq[TestItem] =
  @[item("a", "tests::test_main", "src/main.nr", 13),
    item("b", "tests::test_bounds", "src/main.nr", 20),
    item("c", "tests::test_fails", "src/main.nr", 27)]

proc finished(testId: string; status: TestResultStatus): TestEvent =
  ## A verdict for one test, as `ingestTestEvent` folds it.
  TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
            providerId: "noir-nargo", runId: "r1", testId: testId,
            status: some(status), durationMs: 2,
            trace: none(TraceMetadata), diagnostic: none(TestDiagnostic))

proc recordingCreated(testId, recordingId: string): TestEvent =
  ## The event a recorder emits when a trace exists. Used rather than calling
  ## `rememberRecording` directly wherever the point is that the PIPELINE
  ## carries the recording — a test that only ever poked the register would
  ## pass over a `ingestEvent` that dropped `event.trace` on the floor.
  TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekRecordingCreated,
            providerId: "noir-nargo", runId: "r1", testId: testId,
            status: none(TestResultStatus),
            trace: some(TraceMetadata(traceId: recordingId,
                                      recordingId: recordingId,
                                      path: "/traces/" & recordingId,
                                      backend: "noir-wasm",
                                      metadata: {"recordedAt": "10:04:31"}
                                        .toTable)),
            diagnostic: none(TestDiagnostic))

type
  Calls = ref object
    ## What the host was asked to do, and for which test. A ref so the closures
    ## installed into the VM write into the same object the assertions read.
    refreshed: seq[string]
    openedExisting: seq[string]
    recordedAndOpened: seq[string]

proc installHosts(vm: TestResultsVM; calls: Calls;
                  withRefresh = true; withOpenExisting = true;
                  withRecordAndOpen = true) =
  var refresh, openExisting, recordAndOpen: TestRowActionProc
  if withRefresh:
    refresh = proc(testId, selector: string) = calls.refreshed.add selector
  if withOpenExisting:
    openExisting = proc(testId, selector: string) =
      calls.openedExisting.add selector
  if withRecordAndOpen:
    recordAndOpen = proc(testId, selector: string) =
      calls.recordedAndOpened.add selector
  vm.setRowActions(refresh, openExisting, recordAndOpen)

proc paneWithThreeTests(calls: Calls): (TestResultsVM, MockRenderer, MockNode) =
  let vm = createTestResultsVM()
  vm.setCatalog(TestCatalog(items: threeTests()))
  vm.installHosts(calls)
  let r = MockRenderer()
  (vm, r, renderTestResultsPanel(r, vm))

# ---------------------------------------------------------------------------

suite "the TESTS pane offers two different per-row actions":

  test "row-controls: every row carries both controls, and rows are still counted correctly":
    ## THE AFFORDANCE EXISTS AT ALL. This is the arm that goes red on a tree
    ## without the feature, and it names both controls separately so a build
    ## that added one of them cannot pass.
    ##
    ## It also re-asserts the row count, which is the substring trap: an
    ## actions wrapper named `test-results-row-actions` would make this read 6.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)
      discard vm

      ck rowNodes(panel).len == 3
      ck allByClass(panel, "test-results-refresh-btn").len == 3
      ck allByClass(panel, "test-results-open-btn").len == 3

      # AND THE TWO ARE DISTINCT NODES. A view that rendered one element
      # matching both class names would satisfy the two counts above.
      let row = rowNamed(panel, "a")
      ck not row.isNil
      ck not refreshButtonOf(row).isNil
      ck not openButtonOf(row).isNil
      ck refreshButtonOf(row).id != openButtonOf(row).id

      dispose()
    expectCount(7)

  test "row-state never-run: refresh records, and open is labelled record-and-open":
    ## A row that has never run has nothing to enter, so `⏵` must not say
    ## "open". The label is checked by value because the lie is the defect.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)
      let row = rowNamed(panel, "a")

      ck row.attr("data-ct-recording-id") == ""
      ck "not-run" in row.attr("class")

      let refreshBtn = refreshButtonOf(row)
      ck not refreshBtn.isDisabled()
      ck refreshBtn.attr("title").contains("Record")
      ck refreshBtn.attr("title").contains("Stays in this pane")

      let openBtn = openButtonOf(row)
      ck not openBtn.isDisabled()
      ck openBtn.attr("data-ct-open-mode") == "record-and-open"
      ck openBtn.attr("title").contains("Record")
      ck openBtn.attr("title").contains("open the recording")
      # NOT A PROMISE TO OPEN SOMETHING THAT IS NOT THERE.
      ck not openBtn.attr("title").startsWith("Open the recording")
      ck openBtn.attr("title").contains(NeverRecordedText)

      discard vm
      dispose()
    expectCount(11)

  test "row-state passed-with-recording: open enters it and re-runs nothing":
    ## THE ARM THE WHOLE FEATURE IS FOR. The recording id is read before and
    ## after the click and asserted UNCHANGED — the discriminator that
    ## separates "entered the existing recording" from "quietly made a new one".
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.ingestEvent(finished("a", tsPassed))
      vm.ingestEvent(recordingCreated("a", "rec-1"))

      let row = rowNamed(panel, "a")
      ck "passed" in row.attr("class")
      let idBefore = row.attr("data-ct-recording-id")
      ck idBefore == "rec-1"

      let openBtn = openButtonOf(row)
      ck openBtn.attr("data-ct-open-mode") == "open-existing"
      ck not openBtn.isDisabled()
      ck openBtn.attr("title").startsWith("Open the recording of test_main")
      # THE TIMESTAMP IS NAMED, so a reader can see the recording is older
      # than the edit they just made.
      ck openBtn.attr("title").contains("10:04:31")
      ck openBtn.attr("title").contains("nothing is re-run")

      fireEvent(openBtn, "click")

      # THE HOST WAS ASKED TO OPEN, AND NOT TO RECORD.
      ck calls.openedExisting == @["tests::test_main"]
      ck calls.recordedAndOpened.len == 0
      ck calls.refreshed.len == 0

      # AND THE RECORDING IS THE SAME ONE. An implementation that re-ran the
      # test would have minted a new id here; this equality is the only thing
      # standing between the feature and a silent re-run.
      let idAfter = rowNamed(panel, "a").attr("data-ct-recording-id")
      ck idAfter == idBefore
      ck idAfter == "rec-1"

      dispose()
    expectCount(12)

  test "row-state failed-with-recording: both controls are live on a red row":
    ## §9.1's "a red test is one click from a time-travel session". A failing
    ## row is the one a reader most wants to enter, so it gets its own arm.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.ingestEvent(finished("c", tsFailed))
      vm.ingestEvent(recordingCreated("c", "rec-red"))

      let row = rowNamed(panel, "c")
      ck "failed" in row.attr("class")
      ck row.attr("data-ct-recording-id") == "rec-red"
      ck not refreshButtonOf(row).isDisabled()
      ck not openButtonOf(row).isDisabled()
      ck openButtonOf(row).attr("data-ct-open-mode") == "open-existing"

      fireEvent(openButtonOf(row), "click")
      ck calls.openedExisting == @["tests::test_fails"]

      dispose()
    expectCount(6)

  test "row-state ran-but-recording-discarded: open says so, and does not claim it never ran":
    ## THE FIFTH STATE, and the one that is easy to get wrong by asking only
    ## `recordingId == ""`. A passing row whose recording is gone must not be
    ## told it "has no recording yet" — that sentence invites a user to press
    ## the button that has just failed to leave one.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.ingestEvent(finished("a", tsPassed))
      vm.ingestEvent(recordingCreated("a", "rec-1"))
      ck rowNamed(panel, "a").attr("data-ct-recording-id") == "rec-1"

      # The host discarded them — a reload, or a project change.
      vm.forgetRecordings()

      let row = rowNamed(panel, "a")
      # STILL PASSED. Losing the recording does not un-run the test.
      ck "passed" in row.attr("class")
      ck row.attr("data-ct-recording-id") == ""

      let openBtn = openButtonOf(row)
      ck openBtn.attr("data-ct-open-mode") == "record-and-open"
      ck openBtn.attr("title").contains(RecordingDiscardedText)
      ck not openBtn.attr("title").contains(NeverRecordedText)

      ck refreshButtonOf(row).attr("title").contains(RecordingDiscardedText)

      dispose()
    expectCount(7)

  test "row-state running: refresh is disabled and says why, and open is NOT":
    ## THE TWO BUTTONS DISAGREE, and that is the assertion. A run in flight
    ## blocks recording; it does not block entering a recording that already
    ## exists, because entering one executes nothing. An implementation with a
    ## single availability rule fails here and nowhere else.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.ingestEvent(finished("a", tsPassed))
      vm.ingestEvent(recordingCreated("a", "rec-1"))
      vm.beginRun()

      let row = rowNamed(panel, "a")
      let refreshBtn = refreshButtonOf(row)
      ck refreshBtn.isDisabled()
      # IT EXPLAINS ITSELF. A greyed control with an empty title is the dead
      # affordance with better manners.
      ck refreshBtn.attr("title") == RunInProgressText

      let openBtn = openButtonOf(row)
      ck not openBtn.isDisabled()
      ck openBtn.attr("data-ct-open-mode") == "open-existing"

      # AND THE CLICKS AGREE WITH THE PAINT. `triggerRefresh` guards in the VM
      # so the two renderers cannot disagree about when a control is live.
      fireEvent(refreshBtn, "click")
      ck calls.refreshed.len == 0
      fireEvent(openBtn, "click")
      ck calls.openedExisting == @["tests::test_main"]

      dispose()
    expectCount(6)

  test "row-controls: a deployment that cannot run tests can still enter a recording":
    ## `runAbsence` is a statement about a bundle with no compiler module. It
    ## stops a recording being MADE; it cannot stop one that already exists
    ## being replayed. Greying `⏵` for it would be a control dead for a reason
    ## that does not apply to it.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.ingestEvent(finished("a", tsPassed))
      vm.ingestEvent(recordingCreated("a", "rec-1"))
      vm.setRunAbsence("This deployment ships no Noir compiler module.")

      let row = rowNamed(panel, "a")
      ck refreshButtonOf(row).isDisabled()
      ck refreshButtonOf(row).attr("title") ==
        "This deployment ships no Noir compiler module."
      ck not openButtonOf(row).isDisabled()

      fireEvent(openButtonOf(row), "click")
      ck calls.openedExisting == @["tests::test_main"]

      # BUT THE COMBINED GESTURE IS REFUSED, because it would have to record.
      vm.setShiftHeld(true)
      let armed = openButtonOf(rowNamed(panel, "a"))
      ck armed.isDisabled()
      ck armed.attr("title").startsWith(
        "This deployment ships no Noir compiler module.")

      dispose()
    expectCount(6)

  test "row-controls: a build with no recorder host disables refresh by name":
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: threeTests()))
      vm.installHosts(calls, withRefresh = false)
      let r = MockRenderer()
      let panel = renderTestResultsPanel(r, vm)

      let row = rowNamed(panel, "a")
      ck refreshButtonOf(row).isDisabled()
      ck refreshButtonOf(row).attr("title") == NoRecorderHostText
      # AND IT IS STILL RENDERED. A control that vanishes cannot be told apart
      # from a feature that does not exist.
      ck not refreshButtonOf(row).isNil

      dispose()
    expectCount(3)

  test "row-controls: a build with no replay host disables open by name":
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let vm = createTestResultsVM()
      vm.setCatalog(TestCatalog(items: threeTests()))
      vm.installHosts(calls, withOpenExisting = false)
      let r = MockRenderer()
      let panel = renderTestResultsPanel(r, vm)

      vm.ingestEvent(finished("a", tsPassed))
      vm.ingestEvent(recordingCreated("a", "rec-1"))

      let row = rowNamed(panel, "a")
      ck openButtonOf(row).isDisabled()
      ck openButtonOf(row).attr("title") == NoReplayHostText
      # AND REFRESH IS UNAFFECTED — the two absences are genuinely different.
      ck not refreshButtonOf(row).isDisabled()

      dispose()
    expectCount(3)

  test "refresh-control: records the one test and does NOT navigate":
    ## `⟳` calls the refresh host and neither of the two that end in the
    ## debugger. The negative half is the point: a "refresh" that opened a
    ## session would be the single-button design the user ruled out.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.ingestEvent(finished("b", tsPassed))
      vm.ingestEvent(recordingCreated("b", "rec-b1"))

      let row = rowNamed(panel, "b")
      ck refreshButtonOf(row).attr("title").contains("again")
      ck refreshButtonOf(row).attr("title").contains("10:04:31")

      fireEvent(refreshButtonOf(row), "click")
      ck calls.refreshed == @["tests::test_bounds"]
      ck calls.openedExisting.len == 0
      ck calls.recordedAndOpened.len == 0

      dispose()
    expectCount(5)

  test "shift-arm: Shift turns open into refresh-and-open, and a NEW recording lands":
    ## THE SHIFT ARM'S OWN DISCRIMINATOR, and it is the mirror image of the
    ## open arm's. There the id had to be unchanged; here it must CHANGE, and
    ## the row must end up carrying the new one — "recorded a new one" and
    ## "landed in it" are two claims and both are made.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.ingestEvent(finished("a", tsPassed))
      vm.ingestEvent(recordingCreated("a", "rec-old"))
      let idBefore = rowNamed(panel, "a").attr("data-ct-recording-id")
      ck idBefore == "rec-old"

      vm.setShiftHeld(true)

      let armed = openButtonOf(rowNamed(panel, "a"))
      ck armed.attr("data-ct-open-mode") == "refresh-and-open"
      ck "shift-armed" in armed.attr("class")
      ck armed.attr("title").startsWith("Record test_main again and open")
      ck armed.attr("title").contains("rec")  # names what it replaces, by time
      ck textOf(armed) == "⟳⏵"

      fireEvent(armed, "click")

      # A DIFFERENT HOST WAS CALLED. Not `openExisting`.
      ck calls.recordedAndOpened == @["tests::test_main"]
      ck calls.openedExisting.len == 0

      # …and the recording the host then produces replaces the old one, so the
      # row now points at a DIFFERENT recording.
      vm.ingestEvent(recordingCreated("a", "rec-new"))
      let idAfter = rowNamed(panel, "a").attr("data-ct-recording-id")
      ck idAfter != idBefore
      ck idAfter == "rec-new"

      dispose()
    expectCount(10)

  test "shift-arm: with no recording Shift changes nothing, because there is nothing to reuse":
    ## THE PLEASING COLLAPSE, asserted rather than assumed. Plain and shifted
    ## presses agree on a never-recorded row — and the button does NOT paint
    ## itself `shift-armed`, because Shift did not change what it does and
    ## saying otherwise would be a second lie on top of the first.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      let plain = openButtonOf(rowNamed(panel, "a"))
      let plainMode = plain.attr("data-ct-open-mode")
      let plainTitle = plain.attr("title")
      ck plainMode == "record-and-open"

      vm.setShiftHeld(true)
      let shifted = openButtonOf(rowNamed(panel, "a"))
      ck shifted.attr("data-ct-open-mode") == plainMode
      ck shifted.attr("title") == plainTitle
      ck "shift-armed" notin shifted.attr("class")

      fireEvent(shifted, "click")
      ck calls.recordedAndOpened == @["tests::test_main"]
      ck calls.openedExisting.len == 0

      dispose()
    expectCount(6)

  test "shift-discoverability: the unshifted tooltip names the modifier":
    ## THE WHOLE ANSWER TO "A MODIFIER NOBODY CAN SEE". A user who never
    ## presses Shift must still be able to find out the combined action exists,
    ## and the only place that can happen is the tooltip they already read.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.ingestEvent(finished("a", tsPassed))
      vm.ingestEvent(recordingCreated("a", "rec-1"))

      let openBtn = openButtonOf(rowNamed(panel, "a"))
      ck vm.shiftHeld.val == false
      ck openBtn.attr("title").contains("Hold Shift")
      ck openBtn.attr("title").contains("record it again first")

      dispose()
    expectCount(3)

  test "shift-liveness: the tooltip and the glyph move on keydown alone, with no pointer event":
    ## THE STALENESS DEFECT, NAMED. Nothing here fires a mouseover, a mouseout
    ## or a re-render: the only thing that happens between the two reads is
    ## `setShiftHeld`. A view that computed its title at pointer-entry would
    ## pass every other arm in this file and fail this one — which is the
    ## situation a real user is in, because they are already hovering the
    ## button when they reach for the key.
    ##
    ## It also asserts the return trip. A flag that armed and never disarmed
    ## would leave the pane promising a re-record to every later click.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.ingestEvent(finished("a", tsPassed))
      vm.ingestEvent(recordingCreated("a", "rec-1"))

      # ONE node, held across the whole case. Re-querying would let a view that
      # rebuilt the row pass for the wrong reason; the requirement is that THIS
      # element's own attributes change.
      let openBtn = openButtonOf(rowNamed(panel, "a"))
      let nodeIdBefore = openBtn.id
      let titleBefore = openBtn.attr("title")
      let markBefore = textOf(openBtn)
      ck titleBefore.startsWith("Open the recording")
      ck markBefore == "⏵"

      vm.setShiftHeld(true)

      # THE SAME ELEMENT, and this is the assertion that keeps the two render
      # effects genuinely separate. Without it a view whose structural effect
      # also subscribes to `shiftHeld` passes — it rebuilds the row, the new
      # button carries the right title, and the one the user is hovering is
      # thrown away mid-hover. Measured: on release only the shift effect ran,
      # over the new nodes, and the element actually under the pointer stayed
      # frozen in its armed state.
      ck openButtonOf(rowNamed(panel, "a")).id == nodeIdBefore

      ck openBtn.attr("title") != titleBefore
      ck openBtn.attr("title").startsWith("Record test_main again")
      ck textOf(openBtn) != markBefore
      ck textOf(openBtn) == "⟳⏵"
      ck "shift-armed" in openBtn.attr("class")
      # THE ACCESSIBLE NAME MOVES TOO. A tooltip a screen reader cannot reach
      # is a modifier that is discoverable only by sighted hover.
      ck openBtn.attr("aria-label") == openBtn.attr("title")

      vm.setShiftHeld(false)

      ck openBtn.attr("title") == titleBefore
      ck textOf(openBtn) == markBefore
      ck "shift-armed" notin openBtn.attr("class")
      ck openButtonOf(rowNamed(panel, "a")).id == nodeIdBefore

      dispose()
    expectCount(13)

  test "recordings survive the next run, so a row does not lose its ⏵ when ▶ is pressed":
    ## `beginRun` blanks the SUMMARY. A recording is an artefact that outlives
    ## the run that made it, and blanking it with the run would take every
    ## row's `⏵` away the instant anyone pressed the pane's ▶ — the recording
    ## still held, the only way back to it gone.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.ingestEvent(finished("a", tsPassed))
      vm.ingestEvent(recordingCreated("a", "rec-1"))
      ck rowNamed(panel, "a").attr("data-ct-recording-id") == "rec-1"

      vm.beginRun()

      let row = rowNamed(panel, "a")
      # The verdict is gone, honestly — this run has not reported one.
      ck "not-run" in row.attr("class")
      # The recording is NOT.
      ck row.attr("data-ct-recording-id") == "rec-1"
      ck openButtonOf(row).attr("data-ct-open-mode") == "open-existing"

      dispose()
    expectCount(4)

  test "recordings are addressable per test, not per run":
    ## Two tests, two recordings, and each row points at its own. A register
    ## keyed by anything coarser than the test would give both rows the same
    ## id, and `⏵` would enter the wrong execution — a defect no screenshot
    ## would show.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.ingestEvent(recordingCreated("a", "rec-a"))
      vm.ingestEvent(recordingCreated("c", "rec-c"))

      ck rowNamed(panel, "a").attr("data-ct-recording-id") == "rec-a"
      ck rowNamed(panel, "c").attr("data-ct-recording-id") == "rec-c"
      # And the third row, which was never recorded, has none.
      ck rowNamed(panel, "b").attr("data-ct-recording-id") == ""
      ck rowNamed(panel, "b").openButtonOf().attr("data-ct-open-mode") ==
        "record-and-open"

      fireEvent(openButtonOf(rowNamed(panel, "c")), "click")
      ck calls.openedExisting == @["tests::test_fails"]

      dispose()
    expectCount(5)

  test "a recording is reachable by the selector a runner knows, not only by catalog id":
    ## The host that produces a recording holds `nargo test --exact`'s string;
    ## the pane joins on a catalog id. `rememberRecordingForSelector` is the
    ## one place the two identities meet, and it degrades the way
    ## `noirRunTestId` does rather than dropping a recording it cannot map.
    startCount()
    createRoot proc(dispose: proc()) =
      let calls = Calls()
      let (vm, _, panel) = paneWithThreeTests(calls)

      vm.rememberRecordingForSelector("tests::test_bounds", "rec-sel", "09:00")
      ck rowNamed(panel, "b").attr("data-ct-recording-id") == "rec-sel"
      ck rowNamed(panel, "b").openButtonOf().attr("data-ct-open-mode") ==
        "open-existing"

      # A selector the catalog does not have is still remembered, under itself.
      vm.rememberRecordingForSelector("tests::ghost", "rec-ghost", "09:01")
      ck vm.recordings.val.len == 2
      ck vm.recordings.val[1].testId == "tests::ghost"

      dispose()
    expectCount(4)
