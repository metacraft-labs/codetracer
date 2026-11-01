## test_plat63_verification_vm.nim — PLAT-63, the shared half: **the
## Verification pane every front-end draws**, as the data the desktop's view,
## the terminal's pane and the GPUI leaf read (`viewmodels/verification_vm`).
##
## Spec: codetracer-pm `spec/Planned-Features/Verification-Payload-
## Contract-v1.md` (§5 findings and the absence of a location, §9 the
## steppable counterexample) and `milestones/Verno-CodeTracer-Integration.
## milestones.org` (VN-M3 the text tier, VN-M5 the counterexample).
##
##   * FINDINGS BY KIND: the groups in `FindingGroupOrder`, each its heading
##     (the kind in words and the count) over its rows in report order;
##   * THE LINES every front-end lists, in order: the notes, the
##     counterexample offers, the groups, and an open counterexample's
##     heading, provenance, positions and steps;
##   * THE CURSOR (`moveSelection`): down from none is the first line, up the
##     last, clamped, Home / End; the cursor skips the lines that are not
##     selectable;
##   * A PRESS (`activateLine`): a located finding leads to its file, line and
##     column as the verifier spelled them; an offer opens its counterexample;
##     a step moves the counterexample and leads to its source only when the
##     step recorded one — `position not recorded` otherwise, never line 1;
##   * THE ROW MENU (`rowMenu` / `runRowMenu`): the entries per line kind, in
##     order, disabled with their reasons; a disabled entry runs nothing;
##   * WHERE A FILE IS (`sourceCandidates`): the run's project root, then its
##     parent (Noir's reporter), and nothing else;
##   * THE DESKTOP'S VIEW over the same VM: its groups and rows, keyed as the
##     lines are, the same words; a Run control only where a host offers one;
##   * THE PERSISTED VOCABULARY: `PaneKind.paneVerification`, layout schema 8
##     and its migration, the desktop's `Content.Verification` row.
##
## Every run here is a REAL recorded Verno run (the VN-M4 corpus and the VN-M5
## end-to-end document): the printed output through the text classifier, the
## payload through the decoder and `attachPayload`'s rules. No mocks: the
## desktop's tree is drawn by IsoNim's headless renderer (`mock_dom`, the
## renderer the desktop view's own suites draw it with), not a stand-in for
## anything the product does. Pure — vm-unit and vm-unit-js.

import std/[json, options, strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom

import ../../viewmodels/project_actions
import ../../viewmodels/verification_report
import ../../viewmodels/verification_payload
import ../../viewmodels/verification_vm
import ../../viewmodels/counterexample_session_vm
import ../../views/isonim_verification_view
import headless_app/layout_model
import headless_app/desktop_panes
import ../../../../common/types

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 96

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  TypeErrOutput = staticRead("../fixtures/verno/pipeline_error_type_mismatch.txt")
  TypeErrPayload =
    staticRead("../fixtures/verno/payload/pipeline_error_type_mismatch.json")
  AssertionOutput = staticRead("../fixtures/verno/failed_obligation_assertion.txt")
  EndToEndPayload =
    staticRead("../fixtures/verno/counterexample/verno_end_to_end_macos.json")
  UnsupportedOutput = staticRead("../fixtures/verno/unsupported_lambda.txt")

proc vernoAction(): ProjectAction =
  ProjectAction(id: "tasks:Verify with Verno", label: "Verify with Verno",
                command: "verno",
                args: @["--program-dir", ".", "formal-verify", "--",
                        "--rlimit", "60"])

proc finished(output: string; payload = ""; root = "/work/typeerr";
              exitCode = 1): VerificationVM =
  ## A run of the project's Verno action that ended with `output` (and its
  ## report `payload`, believed or refused by the real rules).
  result = createVerificationVM()
  result.start(vernoAction(), projectRoot = root)
  var started = 0'i64
  if payload.len > 0:
    started = decodeVerificationPayload(payload).payload.startedAtUnixMs
  result.finish(output, some(exitCode), payloadText = payload,
                runStartedAtUnixMs = started)

proc keysOf(lines: openArray[VerificationLine]): seq[string] =
  for line in lines:
    result.add line.key

proc kindsOf(lines: openArray[VerificationLine]): seq[VerificationLineKind] =
  for line in lines:
    result.add line.kind

proc walk(node: MockNode; visit: proc(n: MockNode)) =
  if node.isNil:
    return
  visit(node)
  for child in node.children:
    walk(child, visit)

proc withAttribute(node: MockNode; name: string): seq[MockNode] =
  var acc: seq[MockNode] = @[]
  walk(node, proc(n: MockNode) =
    if name in n.attributes:
      acc.add n)
  acc

proc childText(node: MockNode; class: string): string =
  var acc = ""
  walk(node, proc(n: MockNode) =
    if acc.len == 0 and n.attributes.getOrDefault("class") == class:
      acc = textContent(n))
  acc

proc desktopTree(vm: VerificationVM;
                 session: CounterexampleSessionVM): MockNode =
  var renderer: MockRenderer
  renderVerificationPanelLive[MockRenderer, MockNode](renderer, vm, session)

suite "PLAT-63: findings by kind, as every front-end lists them":

  test "a real pipeline-error run: one group, its rows in report order":
    let vm = finished(TypeErrOutput, TypeErrPayload)
    let model = vm.panelModel()
    ck model.groups.len == 1
    ck model.groups[0].kind == vfkPipelineError
    ck model.groups[0].heading == "pipeline error (2)"
    ck model.groups[0].rows == @[0, 1]
    ck kindsOf(model.lines) == @[vlNote, vlGroup, vlFinding, vlFinding]
    ck model.lines[0].text == "Nothing was proved or disproved about this program."
    ck keysOf(model.lines) == @["", "", "finding:0", "finding:1"]
    ck model.lines[2].title == "typeerr/src/main.nr:2"
    ck model.lines[2].message == "Expected type Field, found type u32"
    ck model.lines[2].location == "typeerr/src/main.nr:2:20"
    ck model.lines[2].hasSource and model.lines[2].file == "typeerr/src/main.nr"
    ck model.lines[2].line == 2 and model.lines[2].column == 20
    ck model.lines[3].location == "typeerr/src/main.nr:1:24"

  test "the groups' order is the kinds', whatever the report's order":
    let vm = finished(TypeErrOutput)
    var report = vm.report.val.get
    var limitation = report.findings[0]
    limitation.kind = vfkLimitation
    limitation.hasLocation = false
    var failed = report.findings[1]
    failed.kind = vfkFailedObligation
    report.findings = @[limitation, report.findings[0], failed]
    vm.report.val = some(report)
    let model = vm.panelModel()
    var order: seq[VerificationFindingKind] = @[]
    for g in model.groups:
      order.add g.kind
    ck order == @[vfkFailedObligation, vfkPipelineError, vfkLimitation]
    ck model.groups[0].rows == @[2] and model.groups[2].rows == @[0]
    # The unlocated limitation leads nowhere, and says so.
    let at = lineOfKey(model.lines, findingKey(0))
    ck not model.lines[at].hasSource
    ck model.lines[at].noSourceReason == NoSourceLocationReason

  test "a limitation is grouped as one, with the run's note":
    let vm = finished(UnsupportedOutput, exitCode = 101)
    let model = vm.panelModel()
    ck model.groups.len == 1 and model.groups[0].kind == vfkLimitation
    ck model.groups[0].heading == "verifier limitation (1)"
    ck model.lines[0].kind == vlNote

suite "PLAT-63: the counterexample's lines, the cursor and a press":

  test "offers first, then the findings; opening adds the steps":
    let vm = finished(AssertionOutput, EndToEndPayload,
                      root = "/work/verus_post_failure")
    let session = createCounterexampleSessionVM()
    var model = vm.panelModel(session)
    ck vm.payloadStatus.val == psAttached
    ck kindsOf(model.lines) == @[vlOffer, vlOffer, vlGroup, vlFinding]
    ck model.lines[0].key == "offer:f0" and model.lines[1].key == "offer:f1"
    ck model.lines[0].title == OpenCounterexampleLabel
    ck model.lines[1].hasSource and model.lines[1].file == "src/main.nr" and
       model.lines[1].line == 7 and model.lines[1].column == 12
    ck model.lines[2].text == "failed obligation (1)"
    # A press on the offer: the counterexample, open on its first step.
    let opened = vm.activateLine(session, "offer:f1")
    ck opened.kind == vakCounterexample
    ck session.isOpen.val and session.findingId.val == "f1"
    ck vm.selectedKey.val == "offer:f1"
    model = vm.panelModel(session)
    ck kindsOf(model.lines) == @[vlOffer, vlOffer, vlGroup, vlFinding,
                                 vlCounterexample, vlNote, vlNote, vlStep,
                                 vlStep]
    ck model.lines[5].text == SolverDerivedProvenance
    ck model.lines[6].text == "1 of 2 steps have no source position"
    ck model.lines[7].key == "step:0" and model.lines[7].isCurrent
    ck model.lines[7].location == UnknownPositionText
    ck model.lines[7].message.contains("state = 0")
    ck not model.lines[7].hasSource
    ck model.lines[8].hasSource and model.lines[8].line == 7
    # A step with no position moves the walk and leads to no line.
    let unknown = vm.activateLine(session, "step:0")
    ck unknown.kind == vakStep and unknown.note.contains(UnknownPositionText)
    # The violation's step leads to its line, and is the current step.
    let known = vm.activateLine(session, "step:1")
    ck known.kind == vakSource and known.file == "src/main.nr" and
       known.line == 7 and known.column == 12
    ck session.currentStep.val == 1
    ck vm.panelModel(session).lines[8].isCurrent

  test "the cursor moves over the selectable lines only":
    let vm = finished(TypeErrOutput, TypeErrPayload)
    let session = createCounterexampleSessionVM()
    ck vm.moveSelection(session, 1) == "finding:0"      # from none, down
    ck vm.moveSelection(session, 1) == "finding:1"
    ck vm.moveSelection(session, 1) == "finding:1"      # clamped
    ck vm.moveSelection(session, -1) == "finding:0"
    ck vm.moveSelection(session, -5) == "finding:0"
    ck vm.moveSelection(session, 1, toEnd = true) == "finding:1"
    ck vm.moveSelection(session, -1, toEnd = true) == "finding:0"
    vm.selectLine("")
    ck vm.moveSelection(session, -1) == "finding:1"     # from none, up
    ck vm.panelModel(session).selectedKey == "finding:1"
    # A new run clears the cursor: last run's line does not stay selected.
    vm.start(vernoAction(), projectRoot = "/work/typeerr")
    ck vm.selectedKey.val == ""

  test "a press on a finding: its file, line and column, or why none":
    let vm = finished(TypeErrOutput, TypeErrPayload)
    let session = createCounterexampleSessionVM()
    let a = vm.activateLine(session, "finding:1")
    ck a.kind == vakSource
    ck a.file == "typeerr/src/main.nr" and a.line == 1 and a.column == 24
    ck vm.selectedKey.val == "finding:1"
    let gone = vm.activateLine(session, "finding:9")
    ck gone.kind == vakNone and gone.note == "that line is no longer listed"

  test "where the verifier's file is: the root, then its parent":
    let vm = finished(TypeErrOutput, TypeErrPayload, root = "/work/typeerr/")
    ck vm.sourceCandidates("typeerr/src/main.nr") ==
       @["/work/typeerr/typeerr/src/main.nr", "/work/typeerr/src/main.nr"]
    ck vm.sourceCandidates("src/main.nr") ==
       @["/work/typeerr/src/main.nr", "/work/src/main.nr"]
    ck vm.sourceCandidates("/abs/x.nr") == @["/abs/x.nr"]
    ck vm.sourceCandidates("") == newSeq[string]()

suite "PLAT-63: the row menu":

  test "entries by line kind, in order, disabled with their reasons":
    let vm = finished(AssertionOutput, EndToEndPayload,
                      root = "/work/verus_post_failure")
    let session = createCounterexampleSessionVM()
    proc labels(key: string): seq[string] =
      for e in vm.rowMenu(session, key):
        result.add e.label & (if e.enabled: "" else: " (" & e.reason & ")")
    ck labels("offer:f1") == @["Step Through the Counterexample",
                               "Go to Source", "Copy Message",
                               "Copy Location"]
    ck labels("finding:0") == @["Go to Source", "Copy Message",
                                "Copy Location"]
    ck labels("") == newSeq[string]()
    discard vm.activateLine(session, "offer:f1")
    ck labels("step:0") == @["Go to Source (" & UnknownPositionText & ": " &
                               NoSnapPosReason & ")",
                             "Copy Message", "Close the Counterexample"]
    ck labels("step:1") == @["Go to Source", "Copy Message",
                             "Close the Counterexample"]

  test "a chosen entry, as the model decides it now":
    let vm = finished(TypeErrOutput, TypeErrPayload)
    let session = createCounterexampleSessionVM()
    let copied = vm.runRowMenu(session, "finding:0", vmaCopyLocation)
    ck copied.copied == "typeerr/src/main.nr:2:20"
    ck vm.runRowMenu(session, "finding:0", vmaCopyMessage).copied ==
       "Expected type Field, found type u32"
    let go = vm.runRowMenu(session, "finding:1", vmaGoToSource)
    ck go.activation.kind == vakSource and go.activation.line == 1
    # An entry this line's menu does not have runs nothing.
    let absent = vm.runRowMenu(session, "finding:0", vmaOpenCounterexample)
    ck absent.activation.kind == vakNone and absent.copied == ""
    # A disabled one runs nothing either, and says why.
    let cx = finished(AssertionOutput, EndToEndPayload,
                      root = "/work/verus_post_failure")
    let s2 = createCounterexampleSessionVM()
    discard cx.activateLine(s2, "offer:f1")
    let refused = cx.runRowMenu(s2, "step:0", vmaGoToSource)
    ck refused.activation.kind == vakNone
    ck refused.note.startsWith(UnknownPositionText)
    let closed = cx.runRowMenu(s2, "step:1", vmaCloseCounterexample)
    ck closed.note == "closed the counterexample" and not s2.isOpen.val
    ck cx.selectedKey.val == ""

suite "PLAT-63: the desktop's view draws the same lines":

  test "groups, rows, keys and words, over a real run":
    let vm = finished(TypeErrOutput, TypeErrPayload)
    let session = createCounterexampleSessionVM()
    vm.selectLine("finding:1")
    let model = vm.panelModel(session)
    let tree = desktopTree(vm, session)
    let groups = tree.withAttribute("data-ct-verification-group")
    ck groups.len == model.groups.len
    ck groups[0].attributes["data-ct-verification-group"] == $vfkPipelineError
    ck childText(groups[0], "ct-verification-group-heading") ==
       model.groups[0].heading
    var rows: seq[string] = @[]
    for row in tree.withAttribute("data-ct-verification-row"):
      rows.add row.attributes["data-ct-verification-key"] & "|" &
               childText(row, "ct-verification-row-kind") & "|" &
               childText(row, "ct-verification-row-title") & "|" &
               childText(row, "ct-verification-row-message") & "|" &
               row.attributes["data-ct-verification-location"]
    var want: seq[string] = @[]
    for line in model.lines:
      if line.kind == vlFinding:
        want.add line.key & "|" & line.kindLabel & "|" & line.title & "|" &
                 line.message & "|" & line.location
    ck rows == want
    ck rows.len == 2
    let selected = tree.withAttribute("data-ct-verification-selected")
    ck selected[1].attributes["data-ct-verification-selected"] == "true"
    ck selected[0].attributes["data-ct-verification-selected"] == "false"
    # The note, in the view's words.
    ck tree.withAttribute("data-ct-verification-note").len == 1
    # No host offered a run: no Run control (the desktop today).
    ck tree.withAttribute("data-ct-verification-action").len == 0

  test "the offers and the Run control a host offers":
    let vm = finished(AssertionOutput, EndToEndPayload,
                      root = "/work/verus_post_failure")
    let session = createCounterexampleSessionVM()
    vm.offerRun("Verify with Verno")
    let tree = desktopTree(vm, session)
    var actions: seq[string] = @[]
    for n in tree.withAttribute("data-ct-verification-action"):
      actions.add n.attributes["data-ct-verification-action"] & ":" &
                  n.attributes.getOrDefault("data-ct-verification-key")
    ck actions == @["run:", "open-counterexample:offer:f0",
                    "open-counterexample:offer:f1"]
    ck vm.panelModel(session).canRun
    # While a run is in flight there is no Run, and there is Stop.
    vm.start(vernoAction(), projectRoot = "/work/verus_post_failure")
    let running = vm.panelModel(session)
    ck not running.canRun and running.cancellable
    ck running.runLabel == "Verify with Verno"
    # A host with no Verno action says why, and offers nothing.
    let none = createVerificationVM()
    none.offerRun("", "this project declares no Verno action")
    ck not none.panelModel().canRun
    ck none.panelModel().runUnavailableReason.len > 0

suite "PLAT-63: the pane in the persisted vocabulary":

  test "PaneKind.verification, schema 8, the desktop's row":
    ck $paneVerification == "verification"
    ck paneVerification == high(PaneKind)
    ck LayoutSchemaVersion == 8
    # A layout naming the pane round-trips.
    let tree = row([pane(paneEditor, weight = 60.0),
                    pane(paneVerification, weight = 40.0)])
    let doc = saveLayout(initLayout(tree))
    ck doc["version"].getInt == 8
    ck restoreLayoutDocument(doc).tree.contains(paneVerification)
    # A version-7 document (no pane of its can be `verification`) reads
    # unchanged, re-stamped.
    var v7 = saveLayout(initLayout(row([pane(paneEditor, weight = 60.0),
                                        pane(paneState, weight = 40.0)])))
    v7["version"] = %7
    var migrated = false
    try:
      migrated = restoreLayoutDocument(v7).tree.contains(paneState)
    except LayoutDecodeError:
      migrated = false
    ck migrated
    ck PaneContent[paneVerification].content == Content.Verification
    ck PaneContent[paneVerification].label == "verificationComponent-0"
    # In no default: View › Verification opens it.
    ck not sharedDefaultLayout().tree.contains(paneVerification)

suite "PLAT-63 verification: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
