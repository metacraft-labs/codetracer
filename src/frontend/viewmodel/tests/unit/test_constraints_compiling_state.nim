## THE CONSTRAINTS PANE HAS A THIRD STATE, AND IT READS AS PROGRESS.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run::
##
##   nim c  -r src/frontend/viewmodel/tests/unit/test_constraints_compiling_state.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_constraints_compiling_state.nim
##
## ## The defect this pane keeps having, in its third form
##
## The pane's first defect was that it COUNTED a listing it had already read
## and thrown away. Its second was that the listing only appeared after a
## gesture: measured on the deployed site at revision b6e28026 with no key
## pressed and a twenty-second wait, `opcodeRows: 0`, the function row `main`,
## and a caption reading "Build the project to see the compiler's own listing
## here". `ui_js.startWebRenderer` now dispatches a compile one macrotask after
## the project mounts, which fixes that — and creates this one.
##
## Between the mount and the first listing landing (measured at 456 ms for
## `hello_noir` and 537 ms for `/noir/demo` against a local server, 910 ms and
## 980 ms against the deployed CDN) the pane holds the bundled `nargo info`
## totals it is about to replace. The caption it showed for that state told the
## reader to "Build the project" — advice for a build that is ALREADY RUNNING,
## and one `startNoirBuild` would refuse with `reason=already-running` if they
## took it.
##
## So the pane's states must not be "a number" and "no number" with an
## unlabelled window in between. That window is now stated.
##
## ## Why the checks are shaped the way they are
##
## **They end at PAINTED TEXT, not at a flag.** `report.compiling` is a bool,
## and asserting that a bool this suite just set is set is the shape
## `test_constraints_stale_on_edit.nim`'s header names as the reason the
## staleness label shipped unreachable: a check that assigns the state it
## measures covers the renderer and cannot cover the caller. Every case below
## reads the string the view put in the DOM.
##
## **They assert what the caption is NOT.** The failure mode is not an empty
## pane — it is a caption that gives the wrong instruction while looking
## perfectly reasonable. So the compiling caption is checked to have replaced
## the `nargo info` sentence, by asserting the words "Build the project" are
## gone; a pane that appended rather than replaced would look fine to an
## existential and would still be telling the reader to do the thing.
##
## **Every settle is exercised, including the ones that are not successes.** A
## flag cleared only on success would leave a pane claiming progress that
## stopped, forever, on any project that does not compile — worse than the
## silence it replaced, because it is a claim rather than an absence.

import std/[strutils, tables, unittest]

import isonim/core/[owner, signals, computation]
import isonim/testing/mock_dom

import ../../../../common/noir_constraints
import ../../viewmodels/constraints_vm
import ../../views/isonim_constraints_view

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
  collectText(node, result)

proc paneText(panel: MockNode; className: string): string =
  let nodes = allByClass(panel, className)
  if nodes.len == 0: "" else: textOf(nodes[0]).strip()

proc paneClass(panel: MockNode): string =
  panel.attributes.getOrDefault("class", "")

proc opcodeRowCount(panel: MockNode): int =
  ## How many OPCODE ROWS the pane painted.
  ##
  ## NOT `allByClass(panel, "constraints-opcode")`, and the difference cost two
  ## red cases before it was noticed. That helper matches on SUBSTRING, and the
  ## rows live inside a container whose class is `constraints-opcodes
  ## low-level-code-instructions` — so `constraints-opcode` matches the
  ## container as well as every row in it, and a two-row listing counts as
  ## three. An off-by-one that scales with nesting is exactly the kind a `>= 1`
  ## assertion would never have surfaced.
  ##
  ## `opcodeRowClass()` is compared whole, so this counts rows and nothing
  ## else, and it reads the view's own constant rather than a copy of it.
  for node in allByClass(panel, "constraints-opcode"):
    if node.attributes.getOrDefault("class", "") == opcodeRowClass():
      inc result

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const NargoInfoTemplate = """{"programs":[{"package_name":"hello_noir","functions":[{"name":"main","opcodes":17}],"unconstrained_functions":[{"name":"directive_invert","opcodes":9},{"name":"directive_integer_quotient","opcodes":8}]}]}"""
  ## The exact stdout of `nargo info --json` over the bundled template. This is
  ## what `onNs9PanesConstraints` puts in the pane during the mount, so it is
  ## precisely what a visitor is looking at when the automatic compile is
  ## dispatched.

const AcirListing = """func 0
private parameters: [w0]
public parameters: []
return values: []
BRILLIG CALL func: 0, predicate: 1, inputs: [w0 - w1], outputs: [w2]
ASSERT 0 = w0*w2 - w1*w2 - 1
"""
  ## Two rows of the compiler's own `--print-acir` text. Enough to make
  ## `hasListing` true, which is the only property the cases below need of it.

proc paneWithBundledCounts(vm: ConstraintsVM) =
  vm.setReport(parseNargoInfoJson(
    NargoInfoTemplate,
    "measured at build time by the Noir compiler this page runs"))

# ---------------------------------------------------------------------------

suite "the Constraints pane says a compile is running":

  test "the caption stops telling the reader to do what is already happening":
    ## THE CASE THE WHOLE FILE IS FOR. Before the compile the pane carries the
    ## bundled totals and the `nargo info` sentence; at dispatch that sentence
    ## must go, because it is an instruction to perform the action in flight.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      paneWithBundledCounts(vm)

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)

      # BEFORE, by value. The sentence is asserted rather than assumed so the
      # comparison below is between two known strings.
      let before = paneText(panel, "constraints-listing-notice")
      ck before.contains("Build the project")
      ck before.contains("nargo info")

      vm.noteCompileStarted()

      let during = paneText(panel, "constraints-listing-notice")
      ck during != before
      ck during.contains("Compiling this project")
      # THE NEGATIVE, and it is the one that fails for the right reason. A
      # caption that APPENDED the progress sentence rather than replacing the
      # instruction would satisfy every positive above and would still be
      # telling the reader to press a key that is refused.
      ck not during.contains("Build the project")

      # The counts are KEPT. Blanking the pane to announce that a better answer
      # is coming trades information for a spinner; the bundled totals are
      # still the best available answer until the listing lands.
      ck paneText(panel, "constraints-headline") ==
        "17 ACIR opcodes, 17 unconstrained"
      ck allByClass(panel, "constraints-row").len == 3

      # And the class, so the caption and its styling cannot disagree about
      # which state the pane is in.
      ck paneClass(panel).contains("compiling")

      dispose()
    expectCount(8)

  test "a landing listing ends the compiling state and replaces the caption":
    ## The success path. `noirConstraintsSink` builds a whole new report, whose
    ## `compiling` is false by construction — so this asserts that the pane
    ## leaves the state through the ordinary door and not only through
    ## `noteCompileSettled`.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      paneWithBundledCounts(vm)

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)

      vm.noteCompileStarted()
      ck paneClass(panel).contains("compiling")

      vm.setReport(reportFromAcirListing(
        AcirListing, "hello_noir", "compiled in this tab at 3:23:55 AM"))

      ck not paneClass(panel).contains("compiling")
      # A pane holding a listing has nothing to caption: the rows ARE the
      # answer, and `listingNoticeFor` returns "" for exactly that reason.
      ck paneText(panel, "constraints-listing-notice") == ""
      ck opcodeRowCount(panel) == 2
      ck paneText(panel, "constraints-provenance") ==
        "compiled in this tab at 3:23:55 AM"

      dispose()
    expectCount(5)

  test "a refused compile clears the state and says why, rather than claiming progress forever":
    ## THE CASE A SUCCESS-ONLY CLEAR WOULD GET WRONG, and the reason
    ## `noteCompileSettled` fires on every exit path in `onPhaseExit` rather
    ## than beside the sink.
    ##
    ## A deployment that ships no wasm modules refuses at `capProcessSpawn`
    ## synchronously — `dispatch` never reaches the worker — so this is not an
    ## exotic path: it is what every page that fails to load the compiler does.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      paneWithBundledCounts(vm)

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)

      vm.noteCompileStarted()
      ck paneClass(panel).contains("compiling")

      vm.noteCompileSettled(
        "This page loaded no Noir compiler, so nothing can be compiled here.")

      ck not paneClass(panel).contains("compiling")
      let caption = paneText(panel, "constraints-listing-notice")
      ck caption == "This page loaded no Noir compiler, so nothing can be " &
        "compiled here."
      ck not caption.contains("Compiling this project")
      # The counts survive a refusal: nothing about them became wrong because
      # a compile could not be started.
      ck paneText(panel, "constraints-headline") ==
        "17 ACIR opcodes, 17 unconstrained"

      dispose()
    expectCount(5)

  test "a settle with no reason falls back to the ordinary caption":
    ## `noteCompileSettled("")` is the success call — the sink has already
    ## replaced the report by the time it runs in the live wiring, but it must
    ## not invent a failure sentence when it has not been given one.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      paneWithBundledCounts(vm)

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)

      vm.noteCompileStarted()
      vm.noteCompileSettled("")

      ck not paneClass(panel).contains("compiling")
      # Back to the `nargo info` sentence, because that IS the pane's state
      # again: counts, no rows, and no stated reason for the absence.
      ck paneText(panel, "constraints-listing-notice").contains(
        "Build the project")

      dispose()
    expectCount(2)

  test "a recompile over an existing listing announces itself without dimming the rows":
    ## The second and later compiles. The rows on screen came from a real
    ## compile and stay; `stale` is the flag that says they may no longer
    ## describe the source, and `compiling` is the one that says something is
    ## being done about it. Both can be true at once, which is exactly what a
    ## visitor who edits and presses Build is looking at.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      vm.setReport(reportFromAcirListing(
        AcirListing, "hello_noir", "compiled in this tab at 3:23:55 AM"))

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)
      ck paneText(panel, "constraints-listing-notice") == ""

      vm.noteSourceEdited("src/main.nr")
      vm.noteCompileStarted()

      let cls = paneClass(panel)
      ck cls.contains("stale")
      ck cls.contains("compiling")
      # THE CAPTION APPEARS OVER A PANE THAT HAS ROWS, which is why
      # `listingNoticeFor` checks `compiling` BEFORE it returns "" for a
      # report that has a listing. Without that ordering a recompile would run
      # in silence over rows that look current.
      ck paneText(panel, "constraints-listing-notice").contains(
        "Compiling this project")
      ck opcodeRowCount(panel) == 2
      # The headline still carries `(stale)`: an in-flight recompile does not
      # clear the mark, and `constraints_vm`'s decision 3 says why.
      ck paneText(panel, "constraints-headline").endsWith("(stale)")

      dispose()
    expectCount(6)

  test "the bundled counts arriving late do not end a compile that is running":
    ## THE ORDERING DEFECT, and the only case here that was found in a browser
    ## rather than written from the design.
    ##
    ## A `MutationObserver` watching every class change on the pane from before
    ## any page script ran NEVER SAW the `compiling` class, over a window the
    ## same trace showed lasting three and a half seconds. The flag was set and
    ## then overwritten: `onNs9PanesConstraints` delivers the bundled
    ## `nargo info` counts over `newWebIpc`, whose `deferHostReply` is a
    ## `setTimeout`, into a panel that mounts on a retry loop — so the report a
    ## reader thinks of as "what the pane starts with" can land seconds after
    ## the automatic compile was dispatched, carrying `compiling: false`.
    ##
    ## The order below is therefore the LIVE one and not a contrived one:
    ## dispatch first, bundled counts second.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)

      vm.noteCompileStarted()
      ck paneClass(panel).contains("compiling")

      # The late arrival. Same call `onNs9PanesConstraints` makes.
      paneWithBundledCounts(vm)

      ck paneClass(panel).contains("compiling")
      ck paneText(panel, "constraints-listing-notice").contains(
        "Compiling this project")
      # And it did land: the counts it carried are on screen.
      ck paneText(panel, "constraints-headline") ==
        "17 ACIR opcodes, 17 unconstrained"

      # THE COMPILE'S OWN ANSWER STILL ENDS THE WAIT. A rule that preserved the
      # flag against every report would leave the pane painting a listing under
      # a caption saying it was still compiling.
      vm.setReport(reportFromAcirListing(
        AcirListing, "hello_noir", "compiled in this tab at 3:23:55 AM"))
      ck not paneClass(panel).contains("compiling")
      ck opcodeRowCount(panel) == 2

      dispose()
    expectCount(6)

  test "the opening state of a visit says a compile is running, not that none ever was":
    ## THE PANE'S FIRST SECOND, and it is a state with no counts in it at all.
    ##
    ## `createConstraintsVM` opens at `absentReport("No circuit has been
    ## compiled for this project yet.")`. The automatic compile is dispatched
    ## about a macrotask after the mount and the bundled `nargo info` counts
    ## arrive later still, so every visit begins with an absence and a compile
    ## in flight — not as an edge case, as the opening frame.
    ##
    ## Both sentences would otherwise be painted, one under the other, and they
    ## disagree: one says nothing has happened and the other says something is
    ## happening. The second is true and it is also the one that answers the
    ## reader. `absenceTextFor` withholds the first for exactly this window.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)

      # The pane before anything is dispatched: the absence, in full.
      ck paneText(panel, "constraints-absence") ==
        "No circuit has been compiled for this project yet."

      vm.noteCompileStarted()

      ck paneText(panel, "constraints-listing-notice").contains(
        "Compiling this project")
      ck paneText(panel, "constraints-absence") == ""
      ck paneClass(panel).contains("compiling")
      # `stale` is still excluded: counts that do not exist cannot have stopped
      # describing anything.
      ck not paneClass(panel).contains("stale")

      # AND THE SENTENCE COMES BACK when the compile fails, because at that
      # point nothing HAS been compiled and the pane should say so again.
      vm.noteCompileSettled("")
      ck paneText(panel, "constraints-absence") ==
        "No circuit has been compiled for this project yet."
      ck paneText(panel, "constraints-listing-notice") == ""

      dispose()
    expectCount(7)
