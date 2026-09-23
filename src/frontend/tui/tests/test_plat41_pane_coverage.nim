## PLAT-41 — every `PaneKind` is accounted for, in exactly one way.
##
## Run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/tui/tests/test_plat41_pane_coverage.nim
##
## **THE CLAIM THIS FILE EXISTS TO MAKE ASSERTABLE.** PLAT-41 says every pane
## is either expressed in the vocabulary, declared a native escape, or a named
## accepted exception. That sentence is only worth something if it is an
## IDENTITY over the enum rather than a count somebody maintains — and PLAT-23
## warns specifically that an accepted exception *"must not become a way to
## close the gate without drawing anything"*.
##
## So the three properties below are the milestone, and the rest of the file is
## about making each of them hard to satisfy dishonestly:
##
##   1. the three sets COVER `PaneKind` — no pane is silently omitted;
##   2. the three sets are PAIRWISE DISJOINT — no pane has two answers;
##   3. each set's members behave as their category promises — a vocabulary
##      pane is portable, a native pane is REFUSED by the portability check,
##      and an accepted exception says which exception it is.
##
## Property 3 is what stops 1 and 2 from being satisfiable by moving names
## between sets: a pane parked in `PaneAcceptedExceptions` to make the counts
## work has to also produce a report that names itself an accepted exception,
## and a pane parked in `PaneNativePanes` has to be genuinely refused by
## `checkPortable`.

import std/[os, sets, strutils, unittest]

import ../../view_vocabulary/pane_views
import ../../headless_app/layout_model
import ../../../common/view_vocabulary
import ../../../common/value_presentation

# PLAT-41's data-path cases construct real ViewModels over a mock backend.
import isonim/core/[signals, owner]
import store/replay_data_store
import store/types as store_types
import viewmodels/debug_controls_vm
import viewmodels/flow_vm
import viewmodels/search_vm
import viewmodels/scratchpad_vm
import viewmodels/shell_vm
import viewmodels/filesystem_vm
import ../host/native_host   # `recordingFileTree`, the replay file tree's producer
import ./fixtures/fixture_provider
import isonim/viewmodel as isonim_viewmodel
import backend/mock_backend

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

proc allPanes(): set[PaneKind] =
  for p in PaneKind: result.incl p

suite "PLAT-41 LAW-P1 — the three sets COVER PaneKind":

  test "every pane is accounted for, and the identity is over the enum":
    let every = allPanes()
    var missing: seq[string] = @[]
    for p in PaneKind:
      if p notin PaneAccountedFor: missing.add $p
    if missing.len > 0:
      checkpoint("panes in no category: " & missing.join(", "))
    ck missing.len == 0
    ck PaneAccountedFor == every

  test "and nothing is accounted for that is not a pane":
    # The other direction. A set holding a value outside the enum cannot be
    # built in Nim, so what this really asserts is that the union has not been
    # narrowed — that `PaneAccountedFor` is the union it claims to be rather
    # than a hand-maintained third list that happens to match today.
    ck PaneAccountedFor ==
       PaneVocabularyPanes + PaneNativePanes + PaneAcceptedExceptions

  test "the cardinalities add up, and they are the measured ones":
    # 13 = 10 + 2 + 1. Written out because the sum is the claim: when a pane
    # moves category, TWO of these move and the test names which. It did
    # once already — 9 + 2 + 2 until the replay file tree was expressed
    # (PLAT-41's measured correction: the desktop draws the recording's own
    # sources in replay, which refuted `fileTree`'s exception).
    ck card(allPanes()) == 13
    ck card(PaneVocabularyPanes) == 10
    ck card(PaneNativePanes) == 2
    ck card(PaneAcceptedExceptions) == 1
    ck paneFileTree in PaneVocabularyPanes
    ck PaneAcceptedExceptions == {paneBuildOutput}
    ck card(PaneVocabularyPanes) + card(PaneNativePanes) +
       card(PaneAcceptedExceptions) == card(allPanes())

suite "PLAT-41 LAW-P2 — the three sets are PAIRWISE DISJOINT":
  ## A pane in two categories is two answers to one question. This is the
  ## property that stops LAW-P1 being satisfiable by putting everything
  ## everywhere.

  test "vocabulary and native do not overlap":
    ck card(PaneVocabularyPanes * PaneNativePanes) == 0

  test "vocabulary and accepted exceptions do not overlap":
    ck card(PaneVocabularyPanes * PaneAcceptedExceptions) == 0

  test "native and accepted exceptions do not overlap":
    ck card(PaneNativePanes * PaneAcceptedExceptions) == 0

suite "PLAT-41 LAW-P3 — each category BEHAVES as it promises":
  ## Without this, LAW-P1 and LAW-P2 are satisfiable by moving names between
  ## sets until the arithmetic works.

  test "every native pane is REFUSED by the portability check":
    # Refusal is the point: `checkPortable` rejects a native escape on purpose,
    # so a pane listed native that turned out to be portable would mean the set
    # is wrong, not that the pane is fine.
    for pane in PaneNativePanes:
      let pv =
        if pane == paneEditor: sourcePaneView("gpui")
        else: timelinePaneView("gpui")
      let report = checkPortable(pv.root)
      if report.violations.len != 1:
        checkpoint($pane & " is listed native and was not refused")
      ck report.violations.len == 1
      ck pv.native == "gpui"

  test "both native panes are refused BY NAME in PLAT-3's admission table":
    # The set is that table's consequence rather than a preference, and this is
    # what says so. A third member added here without a rejection to point at
    # would be a pane somebody decided not to express.
    ck card(PaneNativePanes) == 2
    ck paneEditor in PaneNativePanes
    ck paneTimeline in PaneNativePanes

  test "every accepted exception NAMES itself as one":
    # PLAT-23's warning, enforced: an exception that reported nothing, or
    # reported something generic, would be the silent omission this category
    # exists to prevent.
    for pane in PaneAcceptedExceptions:
      let pv = paneView(pane, nil, GpuiPanelBudget, "gpui")
      ck pv.report.len > 0
      ck pv.report.contains("accepted exception")
      ck pv.entries == {pkText}

  test "every vocabulary pane with a nil ViewModel REPORTS rather than blanks":
    # PLAT-9's degradation rule over the whole set, including the five PLAT-41
    # added. A pane that returned an empty tree here would render as a blank
    # region a reader would read as "this pane is broken".
    for pane in PaneVocabularyPanes:
      let pv = paneView(pane, nil, GpuiPanelBudget, "gpui")
      if pv.report.len == 0:
        checkpoint($pane & " has a nil VM and reported nothing")
      ck pv.report.len > 0
      ck pv.entries == {pkText}

  test "every vocabulary pane's REPORT tree is portable":
    for pane in PaneVocabularyPanes:
      let pv = paneView(pane, nil, GpuiPanelBudget, "gpui")
      ck checkPortable(pv.root).violations.len == 0
      ck pv.native.len == 0

suite "PLAT-41 — the five panes this milestone added":
  ## Named individually rather than looped, so that a pane dropped from
  ## `PaneVocabularyPanes` fails HERE by name as well as failing the identity
  ## above by arithmetic.

  test "debugControls is expressed — the pane PLAT-37's frame showed as an apology":
    ck paneDebugControls in PaneVocabularyPanes
    ck paneDebugControls notin PaneAcceptedExceptions

  test "flow is expressed":
    ck paneFlow in PaneVocabularyPanes

  test "search is expressed":
    ck paneSearch in PaneVocabularyPanes

  test "scratchpad is expressed":
    ck paneScratchpad in PaneVocabularyPanes

  test "shell is expressed":
    ck paneShell in PaneVocabularyPanes

  test "and the report no longer claims they are unexpressed":
    # The exact sentence PLAT-37's captured window displayed. If any of the
    # five still produces it, this milestone has renamed a set without writing
    # a view.
    for pane in [paneDebugControls, paneFlow, paneSearch, paneScratchpad,
                 paneShell]:
      let pv = paneView(pane, nil, GpuiPanelBudget, "gpui")
      ck not pv.report.contains("not yet expressed")

# ---------------------------------------------------------------------------
suite "PLAT-41 — the five panes DRAW DATA, not only reports":
# ---------------------------------------------------------------------------
  ## **THE HALF THE CASES ABOVE DO NOT COVER, AND THE HALF THAT MATTERS.**
  ##
  ## Every case before this one drives a NIL ViewModel and asserts the pane
  ## reports rather than blanking. That is PLAT-9's rule and it is worth
  ## asserting — but on its own it would let this milestone pass while the five
  ## new views were nothing but their own `vm.isNil` arms. "The apology is
  ## gone" and "a view exists" are different claims, and only the second is
  ## what PLAT-41 promised.
  ##
  ## So each pane is given a ViewModel WITH DATA IN IT and asserted to render
  ## the vocabulary entries its design calls for, with the report EMPTY. The
  ## report being empty is the discriminator: a view that fell back to its
  ## report arm would still produce a tree, and only the report tells them
  ## apart.
  ##
  ## The data is constructed here rather than replayed, and that is stated
  ## rather than hidden: this is a unit test of the VIEW, not of the producer.
  ## The producer path is PLAT-40's and the on-screen path is PLAT-39's.

  proc freshStore(): ReplayDataStore =
    let mock = newMockBackendService(autoRespond = true)
    createReplayDataStore(mock.toBackendService())

  test "flow renders a Table of steps when the ViewModel has steps":
    createRoot proc(dispose: proc()) =
      let vm = createFlowVM(freshStore())
      vm.setSteps(@[
        FlowStepEntry(step: 1, location: "calc.py:12", expression: "x",
                      beforeValue: "0", afterValue: "1"),
        FlowStepEntry(step: 2, location: "calc.py:13", expression: "y",
                      beforeValue: "1", afterValue: "2")])
      let pv = paneView(paneFlow, ViewModel(vm), GpuiPanelBudget, "gpui")
      ck pv.report.len == 0
      ck pkTable in pv.entries
      ck pv.root.rows.len == 2
      dispose()

  test "search renders an Input and a List when the ViewModel has results":
    createRoot proc(dispose: proc()) =
      let vm = createSearchVM(freshStore())
      vm.setQuery("checksum")
      vm.setResults(@[
        SearchPanelResultEntry(label: "calc.py:112", detail: "checksum = 73",
                               shortcut: ""),
        SearchPanelResultEntry(label: "calc.py:44", detail: "div", shortcut: "")])
      let pv = paneView(paneSearch, ViewModel(vm), GpuiPanelBudget, "gpui")
      ck pv.report.len == 0
      ck pkInput in pv.entries
      ck pkList in pv.entries
      dispose()

  test "scratchpad renders a Table of pinned values":
    createRoot proc(dispose: proc()) =
      let vm = createScratchpadVM(freshStore())
      vm.addValue(ScratchpadValueEntry(expression: "checksum",
                                       valueText: "73", isError: false))
      let pv = paneView(paneScratchpad, ViewModel(vm), GpuiPanelBudget, "gpui")
      ck pv.report.len == 0
      ck pkTable in pv.entries
      ck pv.root.rows.len == 1
      dispose()

  test "shell renders an Input carrying what was typed":
    createRoot proc(dispose: proc()) =
      let vm = createShellVM(freshStore())
      vm.setInput("print(checksum)")
      let pv = paneView(paneShell, ViewModel(vm), GpuiPanelBudget, "gpui")
      ck pkInput in pv.entries
      # The shell's report is NON-empty by design and says why: its ViewModel
      # carries input and history and no output. That is the one pane here
      # whose report survives having data, and it is recorded rather than
      # asserted away.
      ck pv.report.contains("no output")
      dispose()

  test "fileTree renders the RECORDING'S OWN source tree, from its paths.json":
    # Not constructed rows: `native_host.recordingFileTree` reads the `calc`
    # recording's `paths.json` and its `files/` store — the tree the desktop's
    # Files pane shows in replay — and the view draws it with an empty report.
    let calc = resolveFixture("calc")
    doAssert calc.outcome != foMissingPrereq,
      missingPrereqMessage(calc.spec, calc.detail)
    createRoot proc(dispose: proc()) =
      let vm = createFilesystemVM(freshStore())
      vm.setRoot(recordingFileTree(calc.tracePath))
      let pv = paneView(paneFileTree, ViewModel(vm), GpuiPanelBudget, "gpui")
      ck pv.report.len == 0
      ck pkTree in pv.entries
      var labels: seq[string] = @[]
      proc walk(n: ViewNode) =
        labels.add n.label
        for c in n.children: walk(c)
      walk(pv.root)
      checkpoint($labels)
      ck labels == @["source folders", "calc", "main.py"]
      dispose()
    # AND AN EMPTY TREE REPORTS: a trace folder with no `paths.json`.
    createRoot proc(dispose: proc()) =
      let vm = createFilesystemVM(freshStore())
      vm.setRoot(recordingFileTree(getTempDir() / "plat41-no-such-trace"))
      ck paneView(paneFileTree, ViewModel(vm), GpuiPanelBudget, "gpui").report.len > 0
      dispose()

  test "debugControls renders Buttons whose availability comes from the VM":
    createRoot proc(dispose: proc()) =
      let vm = createDebugControlsVM(freshStore())
      let pv = paneView(paneDebugControls, ViewModel(vm), GpuiPanelBudget,
                        "gpui")
      ck pv.report.len == 0
      ck pkButton in pv.entries
      ck pkText in pv.entries
      # The desktop's nine transport controls and a status line. Counted,
      # because a view that emitted one button would satisfy `pkButton in
      # entries` and draw a broken pane. (Four until PLAT-41 aligned the pane
      # with the desktop toolbar's `TransportActions`.)
      ck pv.root.children.len == TransportActions.len + 1
      ck pv.root.children.len == 10
      dispose()

  test "a populated pane and a nil pane do NOT produce the same tree":
    # The discriminator, stated once as its own case. If these agreed, every
    # assertion in this suite would be satisfied by the report arm alone —
    # which is the two-empties collapse PLAT-23 measured, one level up.
    createRoot proc(dispose: proc()) =
      let vm = createScratchpadVM(freshStore())
      vm.addValue(ScratchpadValueEntry(expression: "x", valueText: "1",
                                       isError: false))
      let withData = paneView(paneScratchpad, ViewModel(vm), GpuiPanelBudget,
                              "gpui")
      let withNil = paneView(paneScratchpad, nil, GpuiPanelBudget, "gpui")
      ck withData.entries != withNil.entries
      ck withData.report.len == 0
      ck withNil.report.len > 0
      dispose()

suite "PLAT-41 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
