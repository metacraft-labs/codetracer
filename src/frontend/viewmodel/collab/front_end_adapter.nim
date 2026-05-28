## Front-end adapter boundary for collaborative ViewModel sessions.
##
## The collaboration document owns logical ViewState only.  Front ends project
## that state into their own shells and leaves through this adapter, while
## renderer-local structures such as GoldenLayout configs, Monaco view state,
## terminal buffers, and GPUI native handles stay private to the adapter.

import std/[algorithm, json, strutils, tables]

import ./[codec, reducer, session_core, types]

type
  CollabFrontEndKind* = enum
    cfkWebUI,
    cfkIsoNimTUI,
    cfkGPUI

  AdapterLogicalPanel* = object
    id*: string
    kind*: LogicalPanelKind
    parentId*: string
    orderKey*: string
    isVisible*: bool
    isFocused*: bool

  AdapterDriverControls* = object
    activePrincipalId*: PrincipalId
    leaseId*: DriverLeaseId
    hasActiveDriver*: bool
    localPrincipalCanRequestDriver*: bool
    localPrincipalCanIssueDebugCommand*: bool

  AdapterFollowMode* = object
    localActorId*: ActorId
    followedPrincipalId*: PrincipalId
    isFollowing*: bool

  AdapterProjection* = object
    frontEndKind*: CollabFrontEndKind
    panels*: seq[AdapterLogicalPanel]
    focusedPanelId*: string
    calltraceSelectionId*: string
    stateSelectedPath*: string
    stateActiveTab*: string
    activeDocumentId*: string
    driverControls*: AdapterDriverControls
    followMode*: AdapterFollowMode

  WebUiPanelMapping* = object
    logicalPanelId*: string
    goldenLayoutComponentId*: string
    goldenLayoutStackId*: string
    monacoEditorKey*: string

  WebUiShellPanel* = object
    logicalPanelId*: string
    kind*: LogicalPanelKind
    goldenLayoutComponentId*: string
    goldenLayoutStackId*: string
    monacoEditorKey*: string
    isVisible*: bool
    isFocused*: bool

  FrontEndAdapter* = ref object
    kind*: CollabFrontEndKind
    localPrincipalId*: PrincipalId
    localActorId*: ActorId
    projection*: AdapterProjection
    rejectedLocalLeakCount*: int
    publishedOps: seq[ViewOpEnvelope]
    localShellState: JsonNode
    localLeafState: Table[string, JsonNode]
    webUiMappings: Table[string, WebUiPanelMapping]

const LocalOnlyTokens = [
  "goldenlayout", "resolvedconfig", "monaco", "editorviewstate",
  "cursorstate", "terminalstate", "terminalscrollback", "xterm", "scrollback",
  "gpuinativehandle", "gpuiwidgettree", "nativehandle"
]

proc initFrontEndAdapter*(
    kind: CollabFrontEndKind;
    localPrincipalId = "";
    localActorId = ""): FrontEndAdapter =
  FrontEndAdapter(
    kind: kind,
    localPrincipalId: localPrincipalId,
    localActorId: localActorId,
    projection: AdapterProjection(frontEndKind: kind),
    publishedOps: @[],
    rejectedLocalLeakCount: 0,
    localShellState: newJObject(),
    localLeafState: initTable[string, JsonNode](),
    webUiMappings: initTable[string, WebUiPanelMapping](),
  )

proc initWebUiCollabAdapter*(
    localPrincipalId = "";
    localActorId = ""): FrontEndAdapter =
  initFrontEndAdapter(cfkWebUI, localPrincipalId, localActorId)

proc initIsoNimTuiCollabAdapter*(
    localPrincipalId = "";
    localActorId = ""): FrontEndAdapter =
  initFrontEndAdapter(cfkIsoNimTUI, localPrincipalId, localActorId)

proc initGpuiCollabAdapter*(
    localPrincipalId = "";
    localActorId = ""): FrontEndAdapter =
  initFrontEndAdapter(cfkGPUI, localPrincipalId, localActorId)

proc initCompatibilityAdapters*(
    localPrincipalId = "";
    webActorId = "actor-webui";
    tuiActorId = "actor-isonim-tui";
    gpuiActorId = "actor-gpui"): seq[FrontEndAdapter] =
  @[
    initWebUiCollabAdapter(localPrincipalId, webActorId),
    initIsoNimTuiCollabAdapter(localPrincipalId, tuiActorId),
    initGpuiCollabAdapter(localPrincipalId, gpuiActorId),
  ]

proc toAdapterPanel(panel: LogicalPanel; focusedPanelId: string): AdapterLogicalPanel =
  AdapterLogicalPanel(
    id: panel.id,
    kind: panel.kind,
    parentId: panel.parentId,
    orderKey: panel.orderKey,
    isVisible: panel.isVisible,
    isFocused: panel.id == focusedPanelId,
  )

proc projectSharedState*(adapter: FrontEndAdapter; state: SharedSessionViewState) =
  if adapter.isNil:
    return

  var panels: seq[AdapterLogicalPanel] = @[]
  for panel in state.visiblePanels:
    panels.add panel.toAdapterPanel(state.focusedPanelId.value)

  var follow = AdapterFollowMode(localActorId: adapter.localActorId)
  for item in state.followState:
    if item.actorId == adapter.localActorId:
      follow.followedPrincipalId = item.followedPrincipalId
      follow.isFollowing = item.followedPrincipalId.len > 0
      break

  let activeDriver = state.activeDriver.principalId.len > 0
  adapter.projection = AdapterProjection(
    frontEndKind: adapter.kind,
    panels: panels,
    focusedPanelId: state.focusedPanelId.value,
    calltraceSelectionId: state.calltrace.selectedEntry.value,
    stateSelectedPath: state.statePane.selectedPath.value,
    stateActiveTab: state.statePane.activeTab.value,
    activeDocumentId: state.editor.activeDocumentId.value,
    driverControls: AdapterDriverControls(
      activePrincipalId: state.activeDriver.principalId,
      leaseId: state.activeDriver.leaseId,
      hasActiveDriver: activeDriver,
      localPrincipalCanRequestDriver:
        not activeDriver or state.activeDriver.principalId == adapter.localPrincipalId,
      localPrincipalCanIssueDebugCommand:
        activeDriver and state.activeDriver.principalId == adapter.localPrincipalId,
    ),
    followMode: follow,
  )

proc installFrontEndAdapterProjection*(core: CollaborativeSessionCore;
                                       adapter: FrontEndAdapter) =
  if core.isNil or adapter.isNil:
    return
  core.addProjectionCallback(proc(state: SharedSessionViewState) =
    adapter.projectSharedState(state))

proc replayOperationLog*(
    adapter: FrontEndAdapter;
    initialDocument: SharedSessionDocument;
    ops: openArray[ViewOpEnvelope]): SharedSessionDocument =
  result = initialDocument
  if adapter.isNil:
    return
  adapter.projectSharedState(result.state)
  for op in ops:
    discard result.applyViewOp(op)
    adapter.projectSharedState(result.state)

proc rememberWebUiGoldenLayoutState*(adapter: FrontEndAdapter; resolvedConfig: JsonNode) =
  if adapter.isNil:
    return
  adapter.localShellState["goldenLayoutResolvedConfig"] =
    if resolvedConfig.isNil: newJObject() else: resolvedConfig

proc rememberWebUiPanelMapping*(
    adapter: FrontEndAdapter;
    logicalPanelId, goldenLayoutComponentId, goldenLayoutStackId: string;
    monacoEditorKey = "") =
  if adapter.isNil:
    return
  adapter.webUiMappings[logicalPanelId] = WebUiPanelMapping(
    logicalPanelId: logicalPanelId,
    goldenLayoutComponentId: goldenLayoutComponentId,
    goldenLayoutStackId: goldenLayoutStackId,
    monacoEditorKey: monacoEditorKey,
  )

proc rememberWebUiMonacoLeafState*(
    adapter: FrontEndAdapter;
    panelId: string;
    viewState: JsonNode) =
  if adapter.isNil:
    return
  adapter.localLeafState["webui:monaco:" & panelId] =
    if viewState.isNil: newJObject() else: viewState

proc rememberIsoNimTuiLeafState*(
    adapter: FrontEndAdapter;
    panelId: string;
    terminalState: JsonNode) =
  if adapter.isNil:
    return
  adapter.localLeafState["isonim-tui:terminal:" & panelId] =
    if terminalState.isNil: newJObject() else: terminalState

proc rememberGpuiLeafState*(
    adapter: FrontEndAdapter;
    panelId: string;
    gpuiState: JsonNode) =
  if adapter.isNil:
    return
  adapter.localLeafState["gpui:leaf:" & panelId] =
    if gpuiState.isNil: newJObject() else: gpuiState

proc localShellStateJson*(adapter: FrontEndAdapter): JsonNode =
  if adapter.isNil or adapter.localShellState.isNil:
    return newJObject()
  adapter.localShellState

proc localLeafStateJson*(adapter: FrontEndAdapter; key: string): JsonNode =
  if adapter.isNil or not adapter.localLeafState.hasKey(key):
    return newJObject()
  adapter.localLeafState[key]

proc webUiShellPanels*(adapter: FrontEndAdapter): seq[WebUiShellPanel] =
  if adapter.isNil or adapter.kind != cfkWebUI:
    return
  for panel in adapter.projection.panels:
    let mapping =
      if adapter.webUiMappings.hasKey(panel.id):
        adapter.webUiMappings[panel.id]
      else:
        WebUiPanelMapping(logicalPanelId: panel.id)
    result.add WebUiShellPanel(
      logicalPanelId: panel.id,
      kind: panel.kind,
      goldenLayoutComponentId: mapping.goldenLayoutComponentId,
      goldenLayoutStackId: mapping.goldenLayoutStackId,
      monacoEditorKey: mapping.monacoEditorKey,
      isVisible: panel.isVisible,
      isFocused: panel.isFocused,
    )
  result.sort(proc(a, b: WebUiShellPanel): int = cmp(a.logicalPanelId, b.logicalPanelId))

proc jsonPanel(panel: AdapterLogicalPanel): JsonNode =
  %*{
    "id": panel.id,
    "kind": $panel.kind,
    "parentId": panel.parentId,
    "orderKey": panel.orderKey,
    "isVisible": panel.isVisible,
    "isFocused": panel.isFocused,
  }

proc projectionJson*(adapter: FrontEndAdapter): JsonNode =
  if adapter.isNil:
    return newJObject()
  var panels = newJArray()
  for panel in adapter.projection.panels:
    panels.add panel.jsonPanel
  %*{
    "frontEndKind": $adapter.projection.frontEndKind,
    "panels": panels,
    "focusedPanelId": adapter.projection.focusedPanelId,
    "calltraceSelectionId": adapter.projection.calltraceSelectionId,
    "stateSelectedPath": adapter.projection.stateSelectedPath,
    "stateActiveTab": adapter.projection.stateActiveTab,
    "activeDocumentId": adapter.projection.activeDocumentId,
    "driverControls": {
      "activePrincipalId": adapter.projection.driverControls.activePrincipalId,
      "leaseId": adapter.projection.driverControls.leaseId,
      "hasActiveDriver": adapter.projection.driverControls.hasActiveDriver,
      "localPrincipalCanRequestDriver":
        adapter.projection.driverControls.localPrincipalCanRequestDriver,
      "localPrincipalCanIssueDebugCommand":
        adapter.projection.driverControls.localPrincipalCanIssueDebugCommand,
    },
    "followMode": {
      "localActorId": adapter.projection.followMode.localActorId,
      "followedPrincipalId": adapter.projection.followMode.followedPrincipalId,
      "isFollowing": adapter.projection.followMode.isFollowing,
    },
  }

proc jsonMentionsLocalOnlyToken(node: JsonNode): bool =
  if node.isNil:
    return false
  case node.kind
  of JObject:
    for key, value in node:
      let lowerKey = key.toLowerAscii
      for token in LocalOnlyTokens:
        if lowerKey.contains(token):
          return true
      if value.jsonMentionsLocalOnlyToken:
        return true
  of JArray:
    for item in node:
      if item.jsonMentionsLocalOnlyToken:
        return true
  of JString:
    let value = node.getStr("").toLowerAscii
    for token in LocalOnlyTokens:
      if value.contains(token):
        return true
  else:
    discard
  false

proc operationMentionsLocalLeafInternals*(op: ViewOpEnvelope): bool =
  op.toJson.jsonMentionsLocalOnlyToken

proc publishSharedOperation*(adapter: FrontEndAdapter; op: ViewOpEnvelope): bool =
  if adapter.isNil:
    return false
  if op.operationMentionsLocalLeafInternals:
    adapter.rejectedLocalLeakCount.inc
    return false
  adapter.publishedOps.add op
  true

proc publishedOperationsJson*(adapter: FrontEndAdapter): JsonNode =
  result = newJArray()
  if adapter.isNil:
    return
  for op in adapter.publishedOps:
    result.add op.toJson
