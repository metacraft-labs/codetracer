## A RUN CONTROL THAT TAKES A CLICK MUST START, OR SAY WHY NOT.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_run_control_refusal_is_shown.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_run_control_refusal_is_shown.nim
##
## ## The defect, as it was on the tree
##
## `RunTestsProc` was `proc()`. `ui_js` installed
## `web_noir_build.startNoirTests` into it, and that proc opens with three
## refusals:
##
##     if activeInFlight:
##       report("test-ignored", "reason=already-running"); return
##     if not tmpl.hasFiles:
##       report("test-refused", "reason=no-project"); return
##     if producerFor(tmpl).isNil:
##       report("test-refused", "reason=no-build-vm"); return
##
## `report` writes one line to the browser console. Nothing else happened.
##
## **And `canRun` is TRUE in all three states.** None of them is `runAbsence`
## (which is a statement about the deployment, set from
## `noirTestRunAbsence()`), and none is the pane's own `inFlight` (which only
## `beginRun` sets, and `beginRun` is never reached on these paths). So the ▶
## was painted live, correctly titled "Run the tests (nargo test)", took a real
## pointer click — and the pane did not move by one character.
##
## The commonest way in is the ordinary one: press Build, then press ▶ while it
## is still going. `activeInFlight` is `web_noir_build`'s global and is set by
## ANY dispatch — a build, a row's `⟳`, the gutter's run control — while the
## pane's `inFlight` is set only by a run this pane started. The two were never
## the same flag and the ▶ was gated on the weaker one.
##
## ## Why these checks are shaped the way they are
##
## **THEY ASSERT PAINTED TEXT.** "The runner returned a sentence" and "the user
## can read it" are different claims and only the second is the product. The
## failure block is `hidden` until something is in it, so its class is asserted
## too — a sentence rendered into a hidden node is the defect with extra steps.
##
## **THEY ASSERT THE CONTROL WAS LIVE.** `ck vm.canRun()` before every click.
## Without it these arms would pass over a build that fixed the symptom by
## disabling the button, which is a different product and a worse one: a
## control that vanishes cannot be told apart from a feature that does not
## exist, and `isonim_test_results_view`'s header argues that at length.
##
## **THERE IS AN OVER-FIRING GUARD.** A pane that showed a failure line after
## every click would satisfy every positive arm here. So a runner that accepts
## is asserted to leave the block empty and the headline alone.
##
## **THE REFUSAL IS ASSERTED NOT TO BECOME A STANDING CLAIM.** `runAbsence` is
## still empty and `canRun` is still true after the refusal, so the user can
## press again once the build finishes. Filing a transient refusal into
## `runAbsence` was the first thing tried when `noteRowActionRefusal` was
## written, and it greys out the ▶ and every row's `⟳` on the strength of one
## declined click.

import std/[strutils, tables, unittest]

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

proc firstByClass(panel: MockNode; className: string): MockNode =
  let nodes = allByClass(panel, className)
  if nodes.len == 0: MockNode(nil) else: nodes[0]

proc paneText(panel: MockNode; className: string): string =
  let node = firstByClass(panel, className)
  if node.isNil: "" else: textOf(node).strip()

proc failureLineCount(panel: MockNode): int =
  ## The `.test-results-failure-line` children, counted by EXACT class token.
  ##
  ## `allByClass` matches by substring and `test-results-failure` is a prefix
  ## of `test-results-failure-line`, so a substring count here would report the
  ## container as one of its own children. The same trap the view's header
  ## names about `test-results-row`, one class over.
  for node in allByClass(panel, "test-results-failure-line"):
    if "test-results-failure-line" in node.attr("class").split(' '):
      inc result

proc runButtonOf(panel: MockNode): MockNode =
  firstByClass(panel, "test-results-run-btn")

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const AlreadyRunning =
  "a build or test run is already going in this tab; wait for it to " &
  "finish, or stop it, and press ▶ again"
  ## `web_noir_build.startNoirTests`' `activeInFlight` sentence, spelled here
  ## rather than imported: `ui/web_noir_build` is a `when defined(js)` renderer
  ## module that reaches `data`, `ctPlatform` and the DOM, and importing it
  ## would make this suite uncompilable on the native lane. What is under test
  ## is that WHATEVER the host answers is carried to the screen intact, which
  ## is why the arms compare against this value rather than merely asserting
  ## the block is non-empty.

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

proc mountedPane(): (TestResultsVM, MockNode) =
  let vm = createTestResultsVM()
  vm.setCatalog(TestCatalog(items: fiveTests()))
  let r = MockRenderer()
  (vm, renderTestResultsPanel(r, vm))

# ---------------------------------------------------------------------------

suite "a click on a live run control ends in something the user can see":

  test "a host that declines the run says so ON THE PANE, not only on the console":
    startCount()
    createRoot proc(dispose: proc()) =
      let (vm, panel) = mountedPane()

      var asked = 0
      vm.setRunTests(proc(): string =
        inc asked
        AlreadyRunning)

      # THE CONTROL IS LIVE. This is the whole premise: the pane cannot see
      # `web_noir_build.activeInFlight`, so it correctly believes a run can
      # start, and the click therefore reaches the host.
      ck vm.canRun()
      ck runButtonOf(panel).attr("class") == "test-results-run-btn"

      # BEFORE, spelled out — the string the defect leaves on screen after the
      # click as well, which is why it is compared by value below.
      let headlineBefore = paneText(panel, "test-results-headline")
      ck headlineBefore == "5 tests, not run yet"
      ck paneText(panel, "test-results-failure") == ""
      ck "hidden" in firstByClass(panel, "test-results-failure").attr("class")

      fireEvent(runButtonOf(panel), "click")
      ck asked == 1

      # THE DEFECT, AS ONE ASSERTION: these two were byte-identical.
      let headlineAfter = paneText(panel, "test-results-headline")
      ck headlineAfter != headlineBefore
      ck headlineAfter == "run failed, no tests ran"

      # AND THE REASON IS PAINTED, in the host's own words, in a block that is
      # no longer hidden.
      ck "hidden" notin firstByClass(panel, "test-results-failure").attr("class")
      ck paneText(panel, "test-results-failure") == AlreadyRunning
      ck failureLineCount(panel) == 1

      # The five tests are still listed. The pane gained a sentence; it did not
      # lose the project.
      ck allByClass(panel, "test-results-row").len == 5

      dispose()
    expectCount(12)

  test "the refusal is transient: the control stays live and can be pressed again":
    ## `noteRunRefusal` and NOT `setRunAbsence`. A build finishes in seconds and
    ## the user is entitled to press again; writing the refusal into
    ## `runAbsence` would grey out the ▶ and every row's `⟳` on the strength of
    ## one declined click, and would state it as a fact about the deployment.
    startCount()
    createRoot proc(dispose: proc()) =
      let (vm, panel) = mountedPane()

      var answers = @[AlreadyRunning, ""]
      var asked = 0
      vm.setRunTests(proc(): string =
        let reply = answers[asked]
        inc asked
        reply)

      fireEvent(runButtonOf(panel), "click")
      ck paneText(panel, "test-results-failure") == AlreadyRunning

      # NOT A STANDING CLAIM ABOUT THE BUNDLE.
      ck vm.runAbsence.val == ""
      ck vm.canRun()
      ck runButtonOf(panel).attr("class") == "test-results-run-btn"

      # The build finished; the second press is accepted, and the stale
      # sentence does not outlive it.
      fireEvent(runButtonOf(panel), "click")
      ck asked == 2
      vm.beginRun()
      ck paneText(panel, "test-results-failure") == ""
      ck paneText(panel, "test-results-headline") == "running…"

      dispose()
    expectCount(7)

  test "a run the host ACCEPTS leaves no failure line and does not move the headline":
    ## The over-firing guard. Without it every arm above would be green over a
    ## `startRun` that filed a diagnostic on every click, and the pane would
    ## report a failure for each run it successfully started.
    startCount()
    createRoot proc(dispose: proc()) =
      let (vm, panel) = mountedPane()

      var asked = 0
      vm.setRunTests(proc(): string =
        inc asked
        "")

      fireEvent(runButtonOf(panel), "click")
      ck asked == 1
      ck paneText(panel, "test-results-failure") == ""
      ck "hidden" in firstByClass(panel, "test-results-failure").attr("class")
      ck failureLineCount(panel) == 0
      ck paneText(panel, "test-results-headline") == "5 tests, not run yet"

      dispose()
    expectCount(5)

  test "a control the pane itself knows is dead is not pressed, and states its own reason":
    ## The seam between the two kinds of "no". `runAbsence` is knowable before
    ## the click and belongs on the pane as ordinary content; a host refusal is
    ## only knowable by asking. This arm asserts the first still short-circuits
    ## — the runner is never called — so the fix did not turn a stated absence
    ## into a click that has to fail to explain itself.
    startCount()
    createRoot proc(dispose: proc()) =
      let (vm, panel) = mountedPane()

      var asked = 0
      vm.setRunTests(proc(): string =
        inc asked
        AlreadyRunning)
      vm.setRunAbsence(
        "this page was published without the Noir compiler, so nothing " &
        "here can be compiled, run or tested")

      ck not vm.canRun()
      ck "disabled" in runButtonOf(panel).attr("class")
      fireEvent(runButtonOf(panel), "click")
      ck asked == 0

      # The reason is on the pane, in the ABSENCE block and not the failure
      # block: nothing was attempted, so nothing failed.
      ck paneText(panel, "test-results-absence").startsWith(
        "this page was published without the Noir compiler")
      ck paneText(panel, "test-results-failure") == ""
      ck paneText(panel, "test-results-headline") == "5 tests, not run"

      dispose()
    expectCount(6)

  test "a per-row control that is declined uses the same block, in the same words":
    ## `noteRowActionRefusal` now shares `noteRunRefusal`'s body. The header's ▶
    ## and a row's `⟳` are different controls with the same obligation, and two
    ## copies of "file it as a diagnostic" is how one of them would later stop
    ## doing it.
    startCount()
    createRoot proc(dispose: proc()) =
      let (vm, panel) = mountedPane()

      ck paneText(panel, "test-results-failure") == ""
      vm.noteRowActionRefusal(AlreadyRunning)
      ck paneText(panel, "test-results-failure") == AlreadyRunning
      ck failureLineCount(panel) == 1
      ck vm.runAbsence.val == ""

      # An empty message files nothing, so a host that answered "" cannot make
      # the block appear.
      vm.clearRun()
      vm.noteRowActionRefusal("")
      ck paneText(panel, "test-results-failure") == ""

      dispose()
    expectCount(5)
