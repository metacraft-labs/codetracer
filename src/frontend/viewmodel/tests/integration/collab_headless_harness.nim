## Same-process headless collaboration harness for M3.
##
## The harness creates real SessionViewModels and drives the migrated action
## procs. A deterministic in-memory room carries accepted ViewOps between
## peers; a same-process authority document records accepted operations and
## rejection diagnostics so failed convergence tests can dump the full protocol
## trace.

import std/[algorithm, asyncdispatch, json, options, sequtils, sets]

import isonim/core/signals

import ../../backend/mock_backend
import ../../collab/[
  authority,
  backend_snapshots,
  codec,
  reducer,
  runtime_role,
  session_core,
  types,
]
import ../../collab/transport/in_memory
import ../../session_vm
import ../../viewmodels/[calltrace_vm, state_vm]

type
  HeadlessAuthorityEvent* = object
    fromPeerId*: string
    op*: ViewOpEnvelope
    result*: ApplyResult

  HeadlessPeerApplyEvent* = object
    peerId*: string
    opId*: ViewOpId
    result*: ApplyResult

  HeadlessPeerSnapshotEvent* = object
    peerId*: string
    family*: string
    backendEpoch*: uint64
    result*: ApplyResult

  HeadlessPeer* = ref object
    id*: string
    principalId*: PrincipalId
    actorId*: ActorId
    replicaId*: SessionReplicaId
    session*: SessionViewModel
    mockBackend*: MockBackendService
    lastPublishedLocalOp*: int
    receivedOps*: seq[HeadlessPeerApplyEvent]
    receivedBackendSnapshots*: seq[HeadlessPeerSnapshotEvent]

  ProjectedSignalsSnapshot* = object
    calltraceSelection*: Option[int64]
    calltraceExpanded*: seq[int64]
    stateTab*: StateTab
    stateSelectedPath*: string
    stateExpanded*: seq[string]
    watches*: seq[string]

  CollabHeadlessHarness* = ref object
    sessionId*: string
    traceIdentity*: string
    authorityPrincipalId*: PrincipalId
    backendOwnerId*: PrincipalId
    authorityActorId*: ActorId
    authorityReplicaId*: SessionReplicaId
    authoritySeq*: uint64
    authorityLamport*: uint64
    authorityDocument*: SharedSessionDocument
    backendCommandAuthority*: BackendCommandAuthority
    backendEpoch*: uint64
    transport*: InMemoryRoomTransport
    peers*: seq[HeadlessPeer]
    acceptedLog*: seq[ViewOpEnvelope]
    authorityEvents*: seq[HeadlessAuthorityEvent]
    rejectionDiagnostics*: seq[HeadlessAuthorityEvent]
    protocolLog*: seq[string]

proc drain*() =
  try:
    poll(0)
  except ValueError:
    discard

proc containsOp*(ops: openArray[ViewOpEnvelope]; opId: ViewOpId): bool =
  for op in ops:
    if op.opId == opId:
      return true

proc sortedSeq[T](items: HashSet[T]): seq[T] =
  for item in items:
    result.add item
  result.sort(cmp[T])

proc projectedSignals*(peer: HeadlessPeer): ProjectedSignalsSnapshot =
  ProjectedSignalsSnapshot(
    calltraceSelection: peer.session.calltraceVM.selectedEntry.val,
    calltraceExpanded: peer.session.calltraceVM.expandedNodes.val.sortedSeq,
    stateTab: peer.session.stateVM.activeTab.val,
    stateSelectedPath: peer.session.stateVM.selectedPath.val,
    stateExpanded: peer.session.stateVM.expandedPaths.val.sortedSeq,
    watches: peer.session.stateVM.watchExpressions.val,
  )

proc canonicalState*(state: SharedSessionViewState): string =
  $(state.toJson)

proc canonicalState*(peer: HeadlessPeer): string =
  canonicalState(peer.session.collabCore.document.state)

proc canonicalAuthorityState*(harness: CollabHeadlessHarness): string =
  canonicalState(harness.authorityDocument.state)

proc findPeer*(harness: CollabHeadlessHarness; peerId: string): HeadlessPeer =
  for peer in harness.peers:
    if peer.id == peerId:
      return peer
  nil

proc protocolDump*(harness: CollabHeadlessHarness): string =
  result.add "protocol log:\n"
  for line in harness.protocolLog:
    result.add "  " & line & "\n"
  result.add "accepted log:\n"
  for op in harness.acceptedLog:
    result.add "  " & op.opId & " " & $op.kind & " " & op.targetPath &
      " principal=" & op.principalId & "\n"
  result.add "authority events:\n"
  for event in harness.authorityEvents:
    result.add "  " & event.fromPeerId & " " & event.op.opId & " " &
      $event.result.status & " " & event.result.reason & "\n"
  result.add "peer states:\n"
  for peer in harness.peers:
    result.add "  " & peer.id & " " &
      $peer.session.collabCore.document.state.toJson & "\n"
  result.add "authority state:\n  " &
    $harness.authorityDocument.state.toJson & "\n"

proc allPeerStatesMatchAuthority*(harness: CollabHeadlessHarness): bool =
  let expected = harness.canonicalAuthorityState
  for peer in harness.peers:
    if peer.canonicalState != expected:
      return false
  true

proc allProjectedSignalsMatch*(harness: CollabHeadlessHarness): bool =
  if harness.peers.len <= 1:
    return true
  let expected = harness.peers[0].projectedSignals
  for peer in harness.peers[1 .. ^1]:
    if peer.projectedSignals != expected:
      return false
  true

proc receiveMessage(harness: CollabHeadlessHarness;
                    peerId: string;
                    message: InMemoryRoomMessage) =
  let peer = harness.findPeer(peerId)
  if peer.isNil:
    harness.protocolLog.add "drop message for unknown peer " & peerId
    return

  case message.kind
  of imkViewOp:
    let result = peer.session.collabCore.applyRemoteViewOp(message.op)
    peer.receivedOps.add HeadlessPeerApplyEvent(
      peerId: peerId,
      opId: message.op.opId,
      result: result,
    )
    harness.protocolLog.add "deliver op " & message.op.opId & " to " &
      peerId & " => " & $result.status
  of imkJoinSnapshot:
    peer.session.collabCore.loadJoinSnapshot(message.snapshot)
    harness.protocolLog.add "deliver snapshot rev " &
      $message.snapshot.documentRevision & " to " & peerId &
      " tail=" & $message.tail.len
    for op in message.tail:
      let result = peer.session.collabCore.applyRemoteViewOp(op)
      peer.receivedOps.add HeadlessPeerApplyEvent(
        peerId: peerId,
        opId: op.opId,
        result: result,
      )
      harness.protocolLog.add "deliver tail op " & op.opId & " to " &
        peerId & " => " & $result.status
  of imkBackendSnapshot:
    let result = peer.session.collabCore.document.applyAndProjectBackendSnapshot(
      peer.session.store,
      message.backendSnapshot)
    peer.receivedBackendSnapshots.add HeadlessPeerSnapshotEvent(
      peerId: peerId,
      family: message.backendSnapshot.family,
      backendEpoch: message.backendSnapshot.backendEpoch,
      result: result,
    )
    harness.protocolLog.add "deliver backend snapshot " &
      message.backendSnapshot.family & "@" &
      $message.backendSnapshot.backendEpoch & " to " & peerId &
      " => " & $result.status

proc newCollabHeadlessHarness*(
    sessionId = "headless-m3-session";
    traceIdentity = "headless-trace";
    authorityPrincipalId = "principal-owner";
    backendOwnerId = "principal-owner"): CollabHeadlessHarness =
  result = CollabHeadlessHarness(
    sessionId: sessionId,
    traceIdentity: traceIdentity,
    authorityPrincipalId: authorityPrincipalId,
    backendOwnerId: backendOwnerId,
    authorityActorId: "actor-authority",
    authorityReplicaId: "replica-authority",
    authorityDocument: initSharedSessionDocument(
      sessionId = sessionId,
      traceIdentity = traceIdentity,
      authorityPrincipalId = authorityPrincipalId,
      backendOwnerId = backendOwnerId,
    ),
    backendCommandAuthority: newBackendCommandAuthority(backendOwnerId, nil),
    backendEpoch: 0'u64,
    transport: newInMemoryRoomTransport(),
    peers: @[],
    acceptedLog: @[],
    authorityEvents: @[],
    rejectionDiagnostics: @[],
    protocolLog: @[],
  )

proc currentAuthoritySnapshot*(harness: CollabHeadlessHarness): SharedSessionSnapshot =
  harness.authorityDocument.snapshot

proc configurePeerCore(harness: CollabHeadlessHarness; peer: HeadlessPeer;
                       snapshot: SharedSessionSnapshot) =
  let core = peer.session.collabCore
  core.localPrincipalId = peer.principalId
  core.localActorId = peer.actorId
  core.localReplicaId = peer.replicaId
  core.actorSeq = 0
  core.lamport = snapshot.state.revision
  core.collaborationEnabled = true
  core.peerTransportStarted = true
  core.remoteGossipStarted = true
  core.loadJoinSnapshot(snapshot)

proc addPeer*(harness: CollabHeadlessHarness;
              peerId: string;
              runtimeRole: ViewModelRuntimeRole;
              principalId = "";
              joinNow = true): HeadlessPeer =
  let principal =
    if principalId.len > 0: principalId else: "principal-" & peerId
  let mock = newMockBackendService(autoRespond = true)
  let session = createSessionVM(mock.toBackendService(), runtimeRole)
  session.initializePanelViewModels()
  drain()
  mock.clearReceivedCommands()

  result = HeadlessPeer(
    id: peerId,
    principalId: principal,
    actorId: "actor-" & peerId,
    replicaId: "replica-" & peerId,
    session: session,
    mockBackend: mock,
  )
  if joinNow:
    harness.configurePeerCore(result, harness.currentAuthoritySnapshot)
  else:
    harness.configurePeerCore(result, initSharedSessionDocument(
      sessionId = harness.sessionId,
      traceIdentity = harness.traceIdentity,
      authorityPrincipalId = harness.authorityPrincipalId,
      backendOwnerId = harness.backendOwnerId,
    ).snapshot)

  harness.peers.add result
  if principal == harness.backendOwnerId:
    harness.backendCommandAuthority.backend = mock.toBackendService()
  harness.transport.registerPeer(peerId, proc(message: InMemoryRoomMessage) =
    harness.receiveMessage(peerId, message))
  harness.protocolLog.add "peer joined transport " & peerId

proc authorityOp(harness: CollabHeadlessHarness;
                 kind: ViewOpKind;
                 targetPath: string;
                 payload: JsonNode): ViewOpEnvelope =
  harness.authoritySeq.inc
  harness.authorityLamport.inc
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: harness.sessionId,
    principalId: harness.authorityPrincipalId,
    actorId: harness.authorityActorId,
    replicaId: harness.authorityReplicaId,
    actorSeq: harness.authoritySeq,
    opId: harness.authorityActorId & ":" & $harness.authoritySeq,
    lamport: harness.authorityLamport,
    capabilityIds: @[],
    targetPath: targetPath,
    kind: kind,
    payload: if payload.isNil: newJObject() else: payload,
    unknownFields: newJObject(),
  )

proc broadcastAccepted(harness: CollabHeadlessHarness;
                       fromPeerId: string;
                       op: ViewOpEnvelope) =
  for peer in harness.peers:
    harness.transport.enqueueViewOp(fromPeerId, peer.id, op)

proc emitDebuggerSnapshot*(harness: CollabHeadlessHarness;
                           rrTicks: uint64;
                           status = "dsIdle";
                           file = "main.nim";
                           line = 1): ApplyResult

proc submitToAuthority*(harness: CollabHeadlessHarness;
                        fromPeerId: string;
                        op: ViewOpEnvelope): ApplyResult =
  if op.kind == vokDebugCommand:
    result = harness.backendCommandAuthority.submitDebugCommand(
      harness.authorityDocument,
      op)
  else:
    result = harness.authorityDocument.applyViewOp(op)
    harness.backendCommandAuthority.auditViewOp(op, result)
  let event = HeadlessAuthorityEvent(
    fromPeerId: fromPeerId,
    op: op,
    result: result,
  )
  harness.authorityEvents.add event
  harness.protocolLog.add "authority " & $result.status & " " & op.opId &
    " from " & fromPeerId & " " & result.reason

  if result.status == asRejected:
    harness.rejectionDiagnostics.add event
    return
  if result.status != asDuplicate and not harness.acceptedLog.containsOp(op.opId):
    harness.acceptedLog.add op
    harness.broadcastAccepted(fromPeerId, op)
    if op.kind == vokDebugCommand:
      let current = harness.authorityDocument.state.backendSnapshots
      var nextTicks = 1'u64
      for snapshot in current:
        if snapshot.family == "debugger":
          nextTicks = snapshot.payload{"rrTicks"}.getBiggestInt.uint64 + 1'u64
      discard harness.emitDebuggerSnapshot(nextTicks)

proc broadcastBackendSnapshot*(harness: CollabHeadlessHarness;
                               fromPeerId: string;
                               snapshot: BackendDataSnapshotEnvelope) =
  for peer in harness.peers:
    harness.transport.enqueueBackendSnapshot(fromPeerId, peer.id, snapshot)

proc emitDebuggerSnapshot*(harness: CollabHeadlessHarness;
                           rrTicks: uint64;
                           status = "dsIdle";
                           file = "main.nim";
                           line = 1): ApplyResult =
  harness.backendEpoch.inc
  let snapshot = backendSnapshot(
    sessionId = harness.sessionId,
    backendOwnerId = harness.backendOwnerId,
    emittedByPrincipalId = harness.backendOwnerId,
    family = "debugger",
    backendEpoch = harness.backendEpoch,
    payload = %*{
      "rrTicks": rrTicks,
      "status": status,
      "file": file,
      "line": line,
      "threadId": 1,
    },
  )
  result = harness.authorityDocument.applyAuthoritativeBackendSnapshot(snapshot)
  harness.protocolLog.add "authority backend snapshot debugger@" &
    $snapshot.backendEpoch & " => " & $result.status & " " & result.reason
  if result.status == asApplied:
    harness.broadcastBackendSnapshot("backend", snapshot)

proc publishLocalOps*(harness: CollabHeadlessHarness; peer: HeadlessPeer) =
  if peer.isNil:
    return
  let log = peer.session.collabCore.localOperationLog
  while peer.lastPublishedLocalOp < log.len:
    let op = log[peer.lastPublishedLocalOp]
    peer.lastPublishedLocalOp.inc
    discard harness.submitToAuthority(peer.id, op)

proc publishLocalOps*(harness: CollabHeadlessHarness; peerId: string) =
  harness.publishLocalOps(harness.findPeer(peerId))

proc grantPeerCapabilities*(harness: CollabHeadlessHarness;
                            peer: HeadlessPeer;
                            capabilities: seq[CapabilityKind] = @[
                              capMutateSharedViewState,
                              capManageWatches,
                            ];
                            targetPaths: seq[string] = @[
                              "calltrace",
                              "statePane",
                            ]) =
  if peer.isNil or peer.principalId == harness.authorityPrincipalId:
    return
  let op = harness.authorityOp(
    vokGrantCapabilities,
    "capabilityGrants",
    %*{
      "grantId": "grant-" & peer.id,
      "subject": peer.principalId,
      "capabilities": capabilities.mapIt($it),
      "targetPaths": targetPaths,
    },
  )
  discard harness.submitToAuthority("authority", op)

proc grantPeerCapabilities*(harness: CollabHeadlessHarness; peerId: string) =
  harness.grantPeerCapabilities(harness.findPeer(peerId))

proc grantAllCollaborators*(harness: CollabHeadlessHarness) =
  for peer in harness.peers:
    harness.grantPeerCapabilities(peer)

proc deliverAll*(harness: CollabHeadlessHarness) =
  harness.transport.deliverAll()
  drain()

proc deliverReverse*(harness: CollabHeadlessHarness) =
  harness.transport.deliverReverse()
  drain()

proc duplicateAllPending*(harness: CollabHeadlessHarness) =
  harness.transport.duplicateAllPending()

proc pendingCount*(harness: CollabHeadlessHarness): int =
  harness.transport.pendingCount

proc disconnectPeer*(harness: CollabHeadlessHarness; peerId: string) =
  harness.transport.disconnectPeer(peerId)
  harness.protocolLog.add "disconnect " & peerId

proc reconnectPeer*(harness: CollabHeadlessHarness; peerId: string) =
  harness.transport.reconnectPeer(peerId)
  harness.protocolLog.add "reconnect " & peerId

proc acceptedTailAfter*(harness: CollabHeadlessHarness;
                        snapshot: SharedSessionSnapshot): seq[ViewOpEnvelope] =
  for op in harness.acceptedLog:
    if op.opId notin snapshot.appliedOpIds:
      result.add op

proc enqueueJoin*(harness: CollabHeadlessHarness;
                  peerId: string;
                  snapshot: SharedSessionSnapshot;
                  fromPeerId = "authority") =
  harness.transport.enqueueJoinSnapshot(
    fromPeerId,
    peerId,
    snapshot,
    harness.acceptedTailAfter(snapshot),
  )

proc enqueueCurrentJoin*(harness: CollabHeadlessHarness;
                         peerId: string;
                         fromPeerId = "authority") =
  harness.enqueueJoin(peerId, harness.currentAuthoritySnapshot, fromPeerId)

proc selectCalltrace*(harness: CollabHeadlessHarness;
                      peerId: string;
                      entry: Option[int64]) =
  let peer = harness.findPeer(peerId)
  peer.session.calltraceVM.selectEntry(entry)
  harness.publishLocalOps(peer)

proc toggleCalltrace*(harness: CollabHeadlessHarness;
                      peerId: string;
                      lineIndex: int64) =
  let peer = harness.findPeer(peerId)
  peer.session.calltraceVM.toggleExpand(lineIndex)
  harness.publishLocalOps(peer)

proc selectStateTab*(harness: CollabHeadlessHarness;
                     peerId: string;
                     tab: StateTab) =
  let peer = harness.findPeer(peerId)
  peer.session.stateVM.selectTab(tab)
  harness.publishLocalOps(peer)

proc toggleStatePath*(harness: CollabHeadlessHarness;
                      peerId: string;
                      path: string) =
  let peer = harness.findPeer(peerId)
  peer.session.stateVM.toggleExpand(path)
  harness.publishLocalOps(peer)

proc addWatch*(harness: CollabHeadlessHarness;
               peerId: string;
               expression: string) =
  let peer = harness.findPeer(peerId)
  peer.session.stateVM.addWatch(expression)
  harness.publishLocalOps(peer)

proc removeWatch*(harness: CollabHeadlessHarness;
                  peerId: string;
                  expression: string) =
  let peer = harness.findPeer(peerId)
  peer.session.stateVM.removeWatch(expression)
  harness.publishLocalOps(peer)

proc forgedOp*(harness: CollabHeadlessHarness;
               principalId: PrincipalId;
               actorId: ActorId;
               opId: ViewOpId;
               kind: ViewOpKind;
               targetPath: string;
               payload: JsonNode): ViewOpEnvelope =
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: harness.sessionId,
    principalId: principalId,
    actorId: actorId,
    replicaId: actorId & "-replica",
    actorSeq: 1,
    opId: opId,
    lamport: harness.authorityLamport + 100,
    capabilityIds: @[],
    targetPath: targetPath,
    kind: kind,
    payload: payload,
    unknownFields: newJObject(),
  )

proc replayAcceptedLog*(harness: CollabHeadlessHarness): SharedSessionDocument =
  result = initSharedSessionDocument(
    sessionId = harness.sessionId,
    traceIdentity = harness.traceIdentity,
    authorityPrincipalId = harness.authorityPrincipalId,
    backendOwnerId = harness.backendOwnerId,
  )
  for op in harness.acceptedLog:
    discard result.applyViewOp(op)

proc replaySnapshotPlusTail*(harness: CollabHeadlessHarness;
                             snapshot: SharedSessionSnapshot): SharedSessionDocument =
  result = SharedSessionDocument(
    state: snapshot.state,
    appliedOpIds: snapshot.appliedOpIds,
  )
  for op in harness.acceptedTailAfter(snapshot):
    discard result.applyViewOp(op)

proc dispose*(harness: CollabHeadlessHarness) =
  for peer in harness.peers:
    if not peer.session.isNil:
      peer.session.dispose()
