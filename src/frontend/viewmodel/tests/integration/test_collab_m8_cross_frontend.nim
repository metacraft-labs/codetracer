## M8 real-backend cross-front-end collaboration tests.
##
## These tests use a recorded replay fixture through replay-server, a
## WebUI-facing ViewModel adapter, and the real IsoNim TUI headless renderer.
## The protocol dump is printed before every failed assertion so CI artifacts
## include the accepted ViewOps and backend snapshot traffic.
##
##   nim c -r src/frontend/viewmodel/tests/integration/test_collab_m8_cross_frontend.nim

import std/[json, os, options, sequtils, strutils, tables, unittest]

import isonim/core/[async_compat, signals]
import isonim_tui/renderer
import isonim_tui/testing/harness

import ../../backend/mock_backend
import ../../collab/[
  authority,
  backend_snapshots,
  codec,
  front_end_adapter,
  reducer,
  runtime_role,
  session_core,
  types,
]
import ../../headless_session
import ../../session_vm
import ../../store/types as store_types
import ../../sync/signal_serializer except SessionViewModel

type
  M8Peer = ref object
    id: string
    principalId: PrincipalId
    actorId: ActorId
    replicaId: SessionReplicaId
    seq: uint64
    session: SessionViewModel
    adapter: FrontEndAdapter

  M8TuiSurface = ref object
    harness: TerminalTestHarness
    peer: M8Peer

  DebuggerObservation = object
    ticks: uint64
    file: string
    fileName: string
    line: int
    selected: string
    localsEpoch: uint64

  M8Harness = ref object
    sessionId: string
    traceIdentity: string
    authorityPrincipalId: PrincipalId
    backendOwnerId: PrincipalId
    authorityActorId: ActorId
    authorityReplicaId: SessionReplicaId
    authoritySeq: uint64
    lamport: uint64
    backendEpoch: uint64
    authorityDocument: SharedSessionDocument
    backendAuthority: BackendCommandAuthority
    webDebug: HeadlessDebugSession
    web: M8Peer
    tui: M8Peer
    tuiSurface: M8TuiSurface
    acceptedLog: seq[ViewOpEnvelope]
    protocolLog: seq[string]

const DriverLease = "m8-web-driver-lease"
const TuiWatchFilterInputId = "tui-watch-filter-input"
const TuiLocalFocusLeafKey = "isonim-tui:terminal:panel-state"

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / "nim.cfg") and dirExists(dir / "src" / "db-backend"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate codetracer repo root from " & currentSourcePath())

proc findReplayServer(): string =
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let candidate = repoRoot() / "src" / "build-debug" / "bin" / "replay-server"
  doAssert fileExists(candidate),
    "missing replay-server; set REPLAY_SERVER_BIN or build src/build-debug/bin/replay-server"
  candidate

proc findM8TraceFixture(): string =
  let envTrace = getEnv("M8_COLLAB_TRACE_PATH", "")
  if envTrace.len > 0 and dirExists(envTrace):
    return envTrace
  let candidate = repoRoot() / "src" / "db-backend" / "trace"
  if not dirExists(candidate):
    raise newException(IOError,
      "missing M8 trace fixture; set M8_COLLAB_TRACE_PATH or restore " &
      "src/db-backend/trace. Tried: " & candidate)
  candidate

proc drain() =
  drainPlatformCallbacks()

proc protocolDump(h: M8Harness): string =
  result.add "M8 protocol log:\n"
  for line in h.protocolLog:
    result.add "  " & line & "\n"
  result.add "accepted ViewOps:\n"
  for op in h.acceptedLog:
    result.add "  " & op.opId & " " & $op.kind & " " & op.targetPath &
      " principal=" & op.principalId & "\n"
  result.add "authority state:\n  " & $h.authorityDocument.state.toJson & "\n"
  if not h.web.isNil:
    result.add "web projection:\n  " & $h.web.adapter.projectionJson & "\n"
  if not h.tui.isNil:
    result.add "tui projection:\n  " & $h.tui.adapter.projectionJson & "\n"
    result.add "tui local state:\n  " &
      $h.tui.adapter.localLeafStateJson(TuiLocalFocusLeafKey) & "\n"
    if not h.tuiSurface.isNil and not h.tuiSurface.harness.root.isNil:
      result.add "tui visible text:\n  " &
        h.tuiSurface.harness.root.textContent.replace("\n", "\\n") & "\n"

proc require(h: M8Harness; condition: bool; label: string) =
  if not condition:
    echo h.protocolDump()
  checkpoint label
  check condition

proc newAuthorityOp(h: M8Harness; kind: ViewOpKind; targetPath: string;
                    payload: JsonNode): ViewOpEnvelope =
  h.authoritySeq.inc
  h.lamport.inc
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: h.sessionId,
    principalId: h.authorityPrincipalId,
    actorId: h.authorityActorId,
    replicaId: h.authorityReplicaId,
    actorSeq: h.authoritySeq,
    opId: h.authorityActorId & ":" & $h.authoritySeq,
    lamport: h.lamport,
    targetPath: targetPath,
    kind: kind,
    payload: if payload.isNil: newJObject() else: payload,
    unknownFields: newJObject(),
  )

proc newPeerOp(h: M8Harness; peer: M8Peer; kind: ViewOpKind; targetPath: string;
               payload: JsonNode): ViewOpEnvelope =
  peer.seq.inc
  h.lamport.inc
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: h.sessionId,
    principalId: peer.principalId,
    actorId: peer.actorId,
    replicaId: peer.replicaId,
    actorSeq: peer.seq,
    opId: peer.actorId & ":" & $peer.seq,
    lamport: h.lamport,
    targetPath: targetPath,
    kind: kind,
    payload: if payload.isNil: newJObject() else: payload,
    unknownFields: newJObject(),
  )

proc applyAcceptedOp(peer: M8Peer; op: ViewOpEnvelope): ApplyResult =
  result = peer.session.collabCore.applyRemoteViewOp(op)
  peer.session.collabCore.projectCurrentState()
  drain()

proc submitToAuthority(h: M8Harness; fromPeerId: string;
                       op: ViewOpEnvelope): ApplyResult =
  if op.kind == vokDebugCommand:
    result = h.backendAuthority.submitDebugCommand(h.authorityDocument, op)
  else:
    result = h.authorityDocument.applyViewOp(op)
    h.backendAuthority.auditViewOp(op, result)

  h.protocolLog.add "authority " & $result.status & " " & op.opId &
    " from " & fromPeerId & " " & result.reason
  if result.status notin {asRejected, asDuplicate}:
    h.acceptedLog.add op
    let webResult = h.web.applyAcceptedOp(op)
    let tuiResult = h.tui.applyAcceptedOp(op)
    h.protocolLog.add "deliver op " & op.opId & " to web => " & $webResult.status
    h.protocolLog.add "deliver op " & op.opId & " to tui => " & $tuiResult.status

proc submitAndRequireApplied(h: M8Harness; fromPeerId: string;
                             op: ViewOpEnvelope) =
  let result = h.submitToAuthority(fromPeerId, op)
  h.require(result.status != asRejected,
    "operation " & op.opId & " should not be rejected: " & result.reason)

proc configurePeer(peer: M8Peer; h: M8Harness) =
  let core = peer.session.collabCore
  core.localPrincipalId = peer.principalId
  core.localActorId = peer.actorId
  core.localReplicaId = peer.replicaId
  core.actorSeq = 0
  core.lamport = h.authorityDocument.state.revision
  core.collaborationEnabled = true
  core.peerTransportStarted = true
  core.remoteAwarenessStarted = true
  core.remoteGossipStarted = true
  core.loadJoinSnapshot(h.authorityDocument.snapshot)
  core.installFrontEndAdapterProjection(peer.adapter)

proc addLine(r: TerminalRenderer; root: TerminalNode; id, text: string) =
  let row = r.createElement("div")
  r.setAttribute(row, "id", id)
  r.appendChild(row, r.createTextNode(text))
  r.appendChild(root, row)

proc addFocusableLine(r: TerminalRenderer; root: TerminalNode; id, text: string) =
  let row = r.createElement("div")
  r.setAttribute(row, "id", id)
  r.setAttribute(row, "data-focusable", "true")
  r.appendChild(row, r.createTextNode(text))
  r.appendChild(root, row)

proc nodeDomId(node: TerminalNode): string =
  if node.isNil:
    return "(none)"
  if node.attributes.hasKey("id"):
    return node.attributes["id"]
  "node-" & $node.id

proc localFocusId(surface: M8TuiSurface): string =
  if surface.isNil or surface.harness.isNil:
    return "(none)"
  surface.harness.focusedNode.nodeDomId

proc rememberLocalFocus(surface: M8TuiSurface) =
  if surface.isNil or surface.peer.isNil or surface.peer.adapter.isNil:
    return
  surface.peer.adapter.rememberIsoNimTuiLeafState("panel-state", %*{
    "focusedNodeId": surface.localFocusId,
  })

proc render(surface: M8TuiSurface) =
  let peer = surface.peer
  let store = peer.session.store
  let dbg = store.debugger.val
  let projection = peer.adapter.projection
  let localFocus = surface.localFocusId
  let watches = peer.session.collabCore.document.state.statePane.visibleWatches.
    mapIt(it.expression).join(",")
  let breakpoints = peer.session.collabCore.document.state.visibleBreakpoints.
    mapIt(it.file.extractFilename & ":" & $it.line).join(",")
  let calltraceLabel =
    if store.calltrace.lines.val.len == 0: "(none)"
    else: store.calltrace.lines.val[0].name
  let localsLabel =
    if store.locals.locals.val.len == 0: "(none)"
    else: store.locals.locals.val.mapIt(it.name).join(",")

  surface.harness.mount(proc(r: TerminalRenderer): TerminalNode =
    let root = r.createElement("div")
    r.setAttribute(root, "id", "m8-tui-root")
    r.addLine(root, "debugger",
      "Debugger " & dbg.location.file.extractFilename & ":" & $dbg.location.line &
      " ticks=" & $dbg.rrTicks)
    r.addLine(root, "calltrace",
      "Calltrace selected=" & projection.calltraceSelectionId &
      " rows=" & $store.calltrace.lines.val.len & " first=" & calltraceLabel)
    r.addLine(root, "locals",
      "Locals epoch=" & $store.locals.loadedForRRTicks.val &
      " vars=" & localsLabel)
    r.addFocusableLine(root, TuiWatchFilterInputId, "Watch filter")
    r.addLine(root, "follow",
      "Follow following=" & $projection.followMode.isFollowing &
      " principal=" & projection.followMode.followedPrincipalId &
      " local-focus=" & localFocus)
    r.addLine(root, "watches", "Watches " & watches)
    r.addLine(root, "breakpoints", "Breakpoints " & breakpoints)
    root)
  surface.rememberLocalFocus()

proc tuiText(surface: M8TuiSurface): string =
  surface.render()
  surface.harness.root.textContent

proc emitBackendSnapshot(h: M8Harness; family: string; payload: JsonNode) =
  h.backendEpoch.inc
  let snapshot = backendSnapshot(
    sessionId = h.sessionId,
    backendOwnerId = h.backendOwnerId,
    emittedByPrincipalId = h.backendOwnerId,
    family = family,
    backendEpoch = h.backendEpoch,
    payload = payload)
  let authorityResult = h.authorityDocument.applyAuthoritativeBackendSnapshot(snapshot)
  h.protocolLog.add "authority backend snapshot " & family & "@" &
    $h.backendEpoch & " => " & $authorityResult.status & " " & authorityResult.reason
  h.require(authorityResult.status == asApplied,
    "backend snapshot should apply: " & family)
  for peer in [h.web, h.tui]:
    let result = peer.session.collabCore.document.applyAndProjectBackendSnapshot(
      peer.session.store,
      snapshot)
    peer.session.collabCore.projectCurrentState()
    h.protocolLog.add "deliver backend snapshot " & family & "@" &
      $h.backendEpoch & " to " & peer.id & " => " & $result.status
    h.require(result.status == asApplied,
      "backend snapshot should project to " & peer.id & ": " & family)
  drain()

proc emitRealBackendState(h: M8Harness) =
  h.webDebug.requestAndLoadCalltrace(startIndex = 0, height = 40, depth = 20)
  h.webDebug.requestAndLoadLocals()

  let dbg = h.webDebug.session.store.debugger.val
  h.emitBackendSnapshot("debugger", %*{
    "rrTicks": dbg.rrTicks,
    "status": $dbg.status,
    "file": dbg.location.file,
    "line": dbg.location.line,
    "threadId": dbg.threadId,
  })
  h.emitBackendSnapshot("calltrace", %*{
    "lines": signal_serializer.toJson(h.webDebug.session.store.calltrace.lines.val),
    "startLineIndex": h.webDebug.session.store.calltrace.startLineIndex.val,
    "totalCallsCount": h.webDebug.session.store.calltrace.totalCallsCount.val,
  })
  h.emitBackendSnapshot("locals", %*{
    "rrTicks": h.webDebug.session.store.locals.loadedForRRTicks.val,
    "locals": signal_serializer.toJson(h.webDebug.session.store.locals.locals.val),
  })

proc selectFirstLoadedCalltraceLine(h: M8Harness) =
  let lines = h.webDebug.session.store.calltrace.lines.val
  h.require(lines.len > 0, "real backend should provide calltrace rows")
  let selected = lines[0].index
  h.submitAndRequireApplied(h.web.id, h.newPeerOp(
    h.web,
    vokSetCalltraceSelection,
    "calltrace.selectedEntry",
    %*{"entryId": $selected}))

proc grantTuiCapabilities(h: M8Harness) =
  h.submitAndRequireApplied("authority", h.newAuthorityOp(
    vokGrantCapabilities,
    "capabilityGrants",
    %*{
      "grantId": "grant-tui-m8",
      "subject": h.tui.principalId,
      "capabilities": @[
        $capObserve,
        $capPublishAwareness,
        $capMutateSharedViewState,
        $capManageBreakpoints,
        $capManageWatches,
        $capControlDebugger,
      ],
      "targetPaths": @["*"],
    }))

proc createMandatoryPanels(h: M8Harness) =
  for (panelId, kind, orderKey) in [
    ("panel-editor", lpkEditor, "a"),
    ("panel-calltrace", lpkCalltrace, "b"),
    ("panel-state", lpkState, "c"),
  ]:
    h.submitAndRequireApplied("authority", h.newAuthorityOp(
      vokCreatePanel,
      "layout",
      %*{
        "panelId": panelId,
        "kind": $kind,
        "parentId": "root",
        "orderKey": orderKey,
        "isVisible": true,
      }))
  h.submitAndRequireApplied("authority", h.newAuthorityOp(
    vokSetFocusedPanel,
    "focusedPanelId",
    %*{"panelId": "panel-editor"}))

proc grantWebDriver(h: M8Harness) =
  h.submitAndRequireApplied("authority", h.newAuthorityOp(
    vokGrantDriver,
    "activeDriver",
    %*{
      "principalId": h.web.principalId,
      "leaseId": DriverLease,
    }))

proc newM8Harness(): M8Harness =
  let tracePath = findM8TraceFixture()
  let replayServer = findReplayServer()
  let webDebug = newHeadlessDebugSession(tracePath, replayServer)
  let tuiMock = newMockBackendService(autoRespond = true)
  let tuiSession = createSessionVM(tuiMock.toBackendService(), vrrCollaborator)
  tuiSession.initializePanelViewModels()

  result = M8Harness(
    sessionId: "m8-real-backend-webui-tui",
    traceIdentity: tracePath,
    authorityPrincipalId: "principal-webui",
    backendOwnerId: "principal-webui",
    authorityActorId: "actor-authority",
    authorityReplicaId: "replica-authority",
    authorityDocument: initSharedSessionDocument(
      sessionId = "m8-real-backend-webui-tui",
      traceIdentity = tracePath,
      authorityPrincipalId = "principal-webui",
      backendOwnerId = "principal-webui"),
    backendAuthority: newBackendCommandAuthority(
      "principal-webui",
      webDebug.session.backend),
    webDebug: webDebug,
    acceptedLog: @[],
    protocolLog: @["trace fixture " & tracePath],
  )
  result.web = M8Peer(
    id: "webui",
    principalId: result.authorityPrincipalId,
    actorId: "actor-webui",
    replicaId: "replica-webui",
    session: webDebug.session,
    adapter: initWebUiCollabAdapter(result.authorityPrincipalId, "actor-webui"))
  result.tui = M8Peer(
    id: "isonim-tui",
    principalId: "principal-tui",
    actorId: "actor-isonim-tui",
    replicaId: "replica-isonim-tui",
    session: tuiSession,
    adapter: initIsoNimTuiCollabAdapter("principal-tui", "actor-isonim-tui"))
  result.web.configurePeer(result)
  result.tui.configurePeer(result)
  result.tuiSurface = M8TuiSurface(
    harness: newTerminalTestHarness(96, 12),
    peer: result.tui)
  result.grantTuiCapabilities()
  result.createMandatoryPanels()
  result.grantWebDriver()
  result.emitRealBackendState()
  discard result.tuiSurface.tuiText()
  let focusNode = result.tuiSurface.harness.findById(TuiWatchFilterInputId)
  result.require(not focusNode.isNil,
    "TUI harness should render a focusable watch filter")
  discard result.tuiSurface.harness.setFocus(focusNode)
  result.tuiSurface.rememberLocalFocus()

proc close(h: M8Harness) =
  if h.isNil:
    return
  if not h.tuiSurface.isNil and not h.tuiSurface.harness.isNil:
    h.tuiSurface.harness.dispose()
  if not h.tui.isNil and not h.tui.session.isNil:
    h.tui.session.dispose()
  if not h.webDebug.isNil:
    h.webDebug.close()

proc webDebuggerSnapshot(h: M8Harness): DebuggerObservation =
  let dbg = h.web.session.store.debugger.val
  DebuggerObservation(
    ticks: dbg.rrTicks,
    file: dbg.location.file,
    fileName: dbg.location.file.extractFilename,
    line: dbg.location.line,
    selected: h.web.adapter.projection.calltraceSelectionId,
    localsEpoch: h.web.session.store.locals.loadedForRRTicks.val,
  )

proc describe(obs: DebuggerObservation): string =
  obs.fileName & ":" & $obs.line & " ticks=" & $obs.ticks &
    " localsEpoch=" & $obs.localsEpoch

proc changedAfterStep(after, before: DebuggerObservation): bool =
  after.ticks != before.ticks or after.file != before.file or
    after.line != before.line or after.localsEpoch != before.localsEpoch

suite "M8 collaborative real backend WebUI plus IsoNim TUI":

  test "e2e_collab_webui_tui_driver_step_updates_both_frontends":
    let h = newM8Harness()
    try:
      let before = h.webDebuggerSnapshot()
      h.submitAndRequireApplied(h.web.id, h.newPeerOp(
        h.web,
        vokDebugCommand,
        "debugger.commands",
        %*{
          "command": "next",
          "leaseId": DriverLease,
          "args": {"threadId": 1},
        }))
      h.webDebug.consumeNextCompleteMove()
      h.emitRealBackendState()
      h.selectFirstLoadedCalltraceLine()

      let web = h.webDebuggerSnapshot()
      let tuiDbg = h.tui.session.store.debugger.val
      let tuiText = h.tuiSurface.tuiText()

      h.require(web.file.len > 0 and web.line > 0,
        "real backend step should report a concrete source position")
      h.require(web.changedAfterStep(before),
        "real backend step should change observable debugger position/epoch; " &
        "before=" & before.describe & " after=" & web.describe)
      h.require(tuiDbg.rrTicks == web.ticks,
        "TUI debugger rrTicks should track WebUI driver")
      h.require(tuiDbg.location.file == web.file,
        "TUI debugger file should track WebUI driver")
      h.require(tuiDbg.location.line == web.line,
        "TUI debugger line should track WebUI driver")
      h.require(h.tui.adapter.projection.calltraceSelectionId == web.selected,
        "TUI calltrace selection should match WebUI selection")
      h.require(h.tui.session.store.locals.loadedForRRTicks.val == web.localsEpoch,
        "TUI locals epoch should match WebUI locals epoch")
      h.require("Debugger " & web.fileName in tuiText and
          "selected=" & web.selected in tuiText and
          "epoch=" & $web.localsEpoch in tuiText,
        "TUI visible text should include debugger, calltrace, and locals epoch")
      h.require(h.protocolLog.anyIt("backend snapshot debugger" in it) and
          h.acceptedLog.anyIt(it.kind == vokDebugCommand),
        "protocol log should include debug command and backend snapshots")
    finally:
      h.close()

  test "e2e_collab_tui_webui_follow_mode_tracks_driver_without_stealing_focus":
    let h = newM8Harness()
    try:
      h.submitAndRequireApplied(h.tui.id, h.newPeerOp(
        h.tui,
        vokFollowParticipant,
        "followState",
        %*{"followedPrincipalId": h.web.principalId}))
      h.submitAndRequireApplied(h.web.id, h.newPeerOp(
        h.web,
        vokSetFocusedPanel,
        "focusedPanelId",
        %*{"panelId": "panel-calltrace"}))
      h.submitAndRequireApplied(h.web.id, h.newPeerOp(
        h.web,
        vokSetCalltraceSelection,
        "calltrace.selectedEntry",
        %*{"entryId": "follow-row-7"}))

      let tuiText = h.tuiSurface.tuiText()
      let focusedNode = h.tuiSurface.harness.focusedNode
      let localLeaf = h.tui.adapter.localLeafStateJson(TuiLocalFocusLeafKey)
      h.require(h.tui.adapter.projection.followMode.isFollowing,
        "TUI adapter should expose follow mode")
      h.require(h.tui.adapter.projection.followMode.followedPrincipalId ==
          h.web.principalId,
        "TUI should follow WebUI principal")
      h.require(h.tui.adapter.projection.focusedPanelId == "panel-calltrace",
        "TUI shared focused panel should track WebUI driver")
      h.require(h.tui.adapter.projection.calltraceSelectionId == "follow-row-7",
        "TUI calltrace selection should track WebUI driver")
      h.require(not focusedNode.isNil and focusedNode.nodeDomId == TuiWatchFilterInputId,
        "TUI harness focus manager should keep renderer-local focus")
      h.require(localLeaf.getOrDefault("focusedNodeId").getStr("") ==
          TuiWatchFilterInputId,
        "TUI adapter leaf state should keep renderer-local focus")
      h.require("local-focus=" & TuiWatchFilterInputId in tuiText,
        "TUI renderer-local focus should not be overwritten by shared follow state")
      h.require(h.protocolLog.anyIt("vokFollowParticipant" in it) or
          h.acceptedLog.anyIt(it.kind == vokFollowParticipant),
        "protocol log should include follow-mode operation")
    finally:
      h.close()

  test "e2e_collab_webui_tui_shared_breakpoint_and_watch":
    let h = newM8Harness()
    try:
      let dbg = h.web.session.store.debugger.val
      h.webDebug.setBreakpoint(dbg.location.file, max(dbg.location.line, 1))
      h.submitAndRequireApplied(h.tui.id, h.newPeerOp(
        h.tui,
        vokSetBreakpoint,
        "breakpoints",
        %*{
          "breakpointId": "bp-m8-tui",
          "file": dbg.location.file,
          "line": max(dbg.location.line, 1),
          "condition": "",
          "enabled": true,
        }))
      h.submitAndRequireApplied(h.web.id, h.newPeerOp(
        h.web,
        vokAddWatch,
        "statePane.watchExpressions",
        %*{
          "watchId": "watch-m8-web",
          "expression": "dummy",
          "orderKey": "a",
        }))

      let tuiText = h.tuiSurface.tuiText()
      let webBreakpoints = h.web.session.collabCore.document.state.visibleBreakpoints
      let tuiBreakpoints = h.tui.session.collabCore.document.state.visibleBreakpoints
      h.require(webBreakpoints.len == 1 and tuiBreakpoints.len == 1,
        "shared breakpoint should appear in both front ends")
      h.require(h.web.session.stateVM.watchExpressions.val == @["dummy"] and
          h.tui.session.stateVM.watchExpressions.val == @["dummy"],
        "shared watch should appear in both front ends")
      h.require("Breakpoints " & dbg.location.file.extractFilename in tuiText and
          "Watches dummy" in tuiText,
        "TUI visible text should show shared breakpoint and watch")
      h.require(h.acceptedLog.anyIt(it.kind == vokSetBreakpoint) and
          h.acceptedLog.anyIt(it.kind == vokAddWatch),
        "protocol accepted log should include breakpoint and watch ViewOps")
    finally:
      h.close()
