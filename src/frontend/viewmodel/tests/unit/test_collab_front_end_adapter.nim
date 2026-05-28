## Unit tests for M7 collaborative front-end adapter contracts.
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_collab_front_end_adapter.nim

import std/[json, sequtils, strutils, unittest]

import ../../collab/[front_end_adapter, types]

const
  TestSession = "session-m7"
  AdminPrincipal = "principal-admin"
  DriverPrincipal = "principal-driver"
  BackendOwner = "principal-backend"

proc op(
    kind: ViewOpKind;
    opId: string;
    lamport: uint64;
    actorId = "actor-admin";
    principalId = AdminPrincipal;
    targetPath = "";
    payload = newJObject()): ViewOpEnvelope =
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: TestSession,
    principalId: principalId,
    actorId: actorId,
    replicaId: actorId & "-replica",
    actorSeq: lamport,
    opId: opId,
    lamport: lamport,
    capabilityIds: @["grant-root"],
    targetPath: targetPath,
    kind: kind,
    payload: payload,
    unknownFields: newJObject(),
  )

proc newDoc(): SharedSessionDocument =
  initSharedSessionDocument(
    sessionId = TestSession,
    traceIdentity = "trace-m7",
    authorityPrincipalId = AdminPrincipal,
    backendOwnerId = BackendOwner,
  )

proc createPanelOp(id: string; kind: LogicalPanelKind; orderKey: string;
                   opId: string; lamport: uint64): ViewOpEnvelope =
  op(vokCreatePanel, opId, lamport,
    targetPath = "layout.panels",
    payload = %*{
      "panelId": id,
      "kind": $kind,
      "parentId": "root",
      "orderKey": orderKey,
      "isVisible": true,
    })

proc sharedLog(): seq[ViewOpEnvelope] =
  @[
    createPanelOp("panel-editor", lpkEditor, "a", "panel-editor-create", 1),
    createPanelOp("panel-calltrace", lpkCalltrace, "b", "panel-calltrace-create", 2),
    createPanelOp("panel-state", lpkState, "c", "panel-state-create", 3),
    op(vokSetFocusedPanel, "focus-calltrace", 4,
      targetPath = "focusedPanelId",
      payload = %*{"panelId": "panel-calltrace"}),
    op(vokSetCalltraceSelection, "select-calltrace", 5,
      targetPath = "calltrace.selectedEntry",
      payload = %*{"entryId": "call-42"}),
    op(vokSetRegister, "select-state-path", 6,
      targetPath = "statePane.selectedPath",
      payload = %*{"value": "frame.locals.counter"}),
    op(vokSetStateTab, "state-tab-watches", 7,
      targetPath = "statePane.activeTab",
      payload = %*{"tab": "stWatches"}),
    op(vokSetRegister, "editor-active-document", 8,
      targetPath = "editor.activeDocumentId",
      payload = %*{"value": "file://src/main.nim"}),
    op(vokGrantDriver, "driver-grant", 9,
      targetPath = "activeDriver",
      payload = %*{
        "principalId": DriverPrincipal,
        "leaseId": "lease-driver",
      }),
    op(vokFollowParticipant, "follow-webui", 10,
      actorId = "actor-webui",
      targetPath = "followState",
      payload = %*{"principalId": DriverPrincipal}),
    op(vokFollowParticipant, "follow-tui", 11,
      actorId = "actor-isonim-tui",
      targetPath = "followState",
      payload = %*{"principalId": DriverPrincipal}),
    op(vokFollowParticipant, "follow-gpui", 12,
      actorId = "actor-gpui",
      targetPath = "followState",
      payload = %*{"principalId": DriverPrincipal}),
  ]

proc containsAny(haystack: string; needles: openArray[string]): bool =
  let lower = haystack.toLowerAscii
  for needle in needles:
    if lower.contains(needle.toLowerAscii):
      return true

suite "collaborative ViewModel M7 front-end adapters":

  test "test_collab_webui_adapter_does_not_publish_goldenlayout_state":
    let adapter = initWebUiCollabAdapter(DriverPrincipal, "actor-webui")
    adapter.rememberWebUiGoldenLayoutState(%*{
      "root": {"type": "goldenLayoutResolvedConfig", "width": 900},
      "content": [{"type": "component", "componentName": "CalltraceComponent"}],
    })
    adapter.rememberWebUiPanelMapping(
      "panel-calltrace", "calltraceComponent-0", "gl-stack-right")
    adapter.rememberWebUiMonacoLeafState("panel-editor", %*{
      "monacoEditorViewState": {"cursorState": [{"lineNumber": 20}]},
      "scrollTop": 1234,
    })

    let doc = adapter.replayOperationLog(newDoc(), sharedLog())
    check doc.state.focusedPanelId.value == "panel-calltrace"
    check adapter.projection.focusedPanelId == "panel-calltrace"
    check adapter.webUiShellPanels.anyIt(
      it.logicalPanelId == "panel-calltrace" and
      it.goldenLayoutComponentId == "calltraceComponent-0" and
      it.goldenLayoutStackId == "gl-stack-right" and
      it.isFocused)

    for item in sharedLog():
      check adapter.publishSharedOperation(item)

    let published = $adapter.publishedOperationsJson
    check not published.containsAny(["goldenLayout", "resolvedConfig", "monaco"])
    check not ($adapter.projectionJson).containsAny(
      ["goldenLayout", "resolvedConfig", "monaco"])
    check ($adapter.localShellStateJson).contains("goldenLayoutResolvedConfig")

  test "test_collab_adapter_replays_shared_operation_log":
    let adapters = initCompatibilityAdapters(DriverPrincipal)
    for adapter in adapters:
      let doc = adapter.replayOperationLog(newDoc(), sharedLog())
      check doc.state.revision == sharedLog().len.uint64
      check adapter.projection.panels.len == 3
      check adapter.projection.focusedPanelId == "panel-calltrace"
      check adapter.projection.panels.anyIt(
        it.id == "panel-calltrace" and it.kind == lpkCalltrace and it.isFocused)
      check adapter.projection.calltraceSelectionId == "call-42"
      check adapter.projection.stateSelectedPath == "frame.locals.counter"
      check adapter.projection.stateActiveTab == "stWatches"
      check adapter.projection.activeDocumentId == "file://src/main.nim"
      check adapter.projection.driverControls.activePrincipalId == DriverPrincipal
      check adapter.projection.driverControls.leaseId == "lease-driver"
      check adapter.projection.driverControls.localPrincipalCanIssueDebugCommand
      check adapter.projection.followMode.followedPrincipalId == DriverPrincipal
      check adapter.projection.followMode.isFollowing

  test "test_collab_leaf_specific_state_stays_local":
    let adapters = initCompatibilityAdapters(DriverPrincipal)
    adapters[0].rememberWebUiMonacoLeafState("panel-editor", %*{
      "monacoEditorViewState": {"cursorState": [{"lineNumber": 2, "column": 4}]},
    })
    adapters[1].rememberIsoNimTuiLeafState("panel-shell", %*{
      "terminalScrollback": ["local prompt"],
      "cursorState": {"row": 3, "column": 1},
    })
    adapters[2].rememberGpuiLeafState("panel-editor", %*{
      "gpuiNativeHandle": "0xabc",
      "gpuiWidgetTree": {"selectedLeaf": "editor"},
    })

    for adapter in adapters:
      discard adapter.replayOperationLog(newDoc(), sharedLog())
      for item in sharedLog():
        check adapter.publishSharedOperation(item)

      check not ($adapter.publishedOperationsJson).containsAny(
        ["monaco", "terminalScrollback", "scrollback", "gpuiNativeHandle",
         "gpuiWidgetTree", "nativeHandle", "cursorState"])
      check not ($adapter.projectionJson).containsAny(
        ["monaco", "terminalScrollback", "scrollback", "gpuiNativeHandle",
         "gpuiWidgetTree", "nativeHandle", "cursorState"])

    let leakingOp = op(vokSetFocusedPanel, "leaking-focus", 20,
      targetPath = "focusedPanelId",
      payload = %*{
        "panelId": "panel-editor",
        "monacoEditorViewState": {"cursorState": [{"lineNumber": 1}]},
      })
    check not adapters[0].publishSharedOperation(leakingOp)
    check adapters[0].rejectedLocalLeakCount == 1

    let leakingTerminalOp = op(vokSetRegister, "leaking-terminal", 21,
      targetPath = "statePane.selectedPath",
      payload = %*{
        "value": "frame.locals.counter",
        "terminalState": {"scrollback": ["local prompt"]},
      })
    check not adapters[1].publishSharedOperation(leakingTerminalOp)
    check adapters[1].rejectedLocalLeakCount == 1
