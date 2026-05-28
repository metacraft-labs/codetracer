## Headless collaboration peer process for M5 localhost integration tests.
##
## The parent test process owns deterministic authority policy. This executable
## owns one real SessionViewModel, receives serialized room messages over TCP,
## drives migrated ViewModel actions, and sends locally produced ViewOps back to
## the authority over the same loopback socket.

import std/[asyncdispatch, json, net, options, os, sets, strutils]

import isonim/core/signals

import ../../backend/mock_backend
import ../../collab/[backend_snapshots, codec, runtime_role, session_core, types]
import ../../collab/transport/local_socket
import ../../session_vm
import ../../viewmodels/[calltrace_vm, state_vm]

type
  PeerRuntime = ref object
    id: string
    principalId: PrincipalId
    actorId: ActorId
    replicaId: SessionReplicaId
    socket: Socket
    session: SessionViewModel
    mockBackend: MockBackendService
    lastPublishedLocalOp: int

proc drain() =
  try:
    poll(0)
  except ValueError:
    discard

proc parseRole(raw: string): ViewModelRuntimeRole =
  case raw
  of "owner", "backend-owner", "vrrBackendOwner":
    vrrBackendOwner
  of "collaborator", "vrrCollaborator":
    vrrCollaborator
  else:
    vrrCollaborator

proc canonicalState(peer: PeerRuntime): string =
  $(peer.session.collabCore.document.state.toJson)

proc projectedSignalsJson(peer: PeerRuntime): JsonNode =
  var calltraceExpanded = newJArray()
  for entry in peer.session.calltraceVM.expandedNodes.val:
    calltraceExpanded.add %entry
  var stateExpanded = newJArray()
  for path in peer.session.stateVM.expandedPaths.val:
    stateExpanded.add %path
  %*{
    "calltraceSelected": (
      if peer.session.calltraceVM.selectedEntry.val.isSome:
        %peer.session.calltraceVM.selectedEntry.val.get
      else:
        newJNull()
    ),
    "calltraceExpanded": calltraceExpanded,
    "stateTab": $peer.session.stateVM.activeTab.val,
    "stateSelectedPath": peer.session.stateVM.selectedPath.val,
    "stateExpanded": stateExpanded,
    "watches": peer.session.stateVM.watchExpressions.val,
  }

proc sendAck(peer: PeerRuntime; requestId, command: string;
             payload: JsonNode = newJObject()) =
  peer.socket.sendFrame(LocalSocketRoomMessage(
    kind: lsmAck,
    fromPeerId: peer.id,
    requestId: requestId,
    command: command,
    payload: if payload.isNil: newJObject() else: payload,
  ))

proc sendError(peer: PeerRuntime; requestId, command, reason: string) =
  peer.socket.sendFrame(LocalSocketRoomMessage(
    kind: lsmError,
    fromPeerId: peer.id,
    requestId: requestId,
    command: command,
    reason: reason,
    payload: newJObject(),
  ))

proc publishLocalOps(peer: PeerRuntime) =
  let log = peer.session.collabCore.localOperationLog
  while peer.lastPublishedLocalOp < log.len:
    let op = log[peer.lastPublishedLocalOp]
    peer.lastPublishedLocalOp.inc
    peer.socket.sendFrame(LocalSocketRoomMessage(
      kind: lsmViewOp,
      fromPeerId: peer.id,
      toPeerId: "authority",
      op: op,
    ))

proc handleRoomMessage(peer: PeerRuntime; message: LocalSocketRoomMessage) =
  case message.kind
  of lsmJoinSnapshot:
    peer.session.collabCore.loadJoinSnapshot(message.snapshot)
    for op in message.tail:
      discard peer.session.collabCore.applyRemoteViewOp(op)
    drain()
  of lsmViewOp:
    discard peer.session.collabCore.applyRemoteViewOp(message.op)
    drain()
  of lsmBackendSnapshot:
    discard peer.session.collabCore.document.applyAndProjectBackendSnapshot(
      peer.session.store,
      message.backendSnapshot)
    drain()
  else:
    discard

proc handleCommand(peer: PeerRuntime; message: LocalSocketRoomMessage): bool =
  try:
    case message.command
    of "selectCalltrace":
      let entry = message.payload{"entryId"}
      if entry.isNil or entry.kind == JNull:
        peer.session.calltraceVM.selectEntry(none(int64))
      else:
        peer.session.calltraceVM.selectEntry(some(entry.getBiggestInt.int64))
      peer.publishLocalOps()
      peer.sendAck(message.requestId, message.command)
    of "toggleCalltrace":
      peer.session.calltraceVM.toggleExpand(
        message.payload{"lineIndex"}.getBiggestInt.int64)
      peer.publishLocalOps()
      peer.sendAck(message.requestId, message.command)
    of "toggleStatePath":
      peer.session.stateVM.toggleExpand(message.payload{"path"}.getStr(""))
      peer.publishLocalOps()
      peer.sendAck(message.requestId, message.command)
    of "addWatch":
      peer.session.stateVM.addWatch(message.payload{"expression"}.getStr(""))
      peer.publishLocalOps()
      peer.sendAck(message.requestId, message.command)
    of "removeWatch":
      peer.session.stateVM.removeWatch(message.payload{"expression"}.getStr(""))
      peer.publishLocalOps()
      peer.sendAck(message.requestId, message.command)
    of "state":
      peer.socket.sendFrame(LocalSocketRoomMessage(
        kind: lsmState,
        fromPeerId: peer.id,
        requestId: message.requestId,
        command: message.command,
        payload: %*{
          "canonicalState": peer.canonicalState,
          "state": peer.session.collabCore.document.state.toJson,
          "appliedOpIds": peer.session.collabCore.document.appliedOpIds,
          "projected": peer.projectedSignalsJson,
          "localLogLen": peer.session.collabCore.localOperationLog.len,
        },
      ))
    of "shutdown":
      peer.sendAck(message.requestId, message.command)
      return false
    else:
      peer.sendError(message.requestId, message.command,
        "unknown peer command: " & message.command)
  except CatchableError:
    peer.sendError(message.requestId, message.command, getCurrentExceptionMsg())
  true

proc configureCore(peer: PeerRuntime;
                   sessionId, traceIdentity, authorityPrincipalId,
                   backendOwnerId: string) =
  let snapshot = initSharedSessionDocument(
    sessionId = sessionId,
    traceIdentity = traceIdentity,
    authorityPrincipalId = authorityPrincipalId,
    backendOwnerId = backendOwnerId,
  ).snapshot
  let core = peer.session.collabCore
  core.localPrincipalId = peer.principalId
  core.localActorId = peer.actorId
  core.localReplicaId = peer.replicaId
  core.actorSeq = 0
  core.lamport = 0
  core.collaborationEnabled = true
  core.peerTransportStarted = true
  core.remoteGossipStarted = true
  core.loadJoinSnapshot(snapshot)

proc main() =
  if paramCount() < 9:
    quit "usage: collab_peer_process <host> <port> <peerId> <role> " &
      "<principalId> <actorId> <replicaId> <sessionId> <traceIdentity> " &
      "<authorityPrincipalId> <backendOwnerId>", 2

  let host = paramStr(1)
  let port = Port(parseInt(paramStr(2)))
  let peerId = paramStr(3)
  let role = parseRole(paramStr(4))
  let principalId = paramStr(5)
  let actorId = paramStr(6)
  let replicaId = paramStr(7)
  let sessionId = paramStr(8)
  let traceIdentity = paramStr(9)
  let authorityPrincipalId =
    if paramCount() >= 10: paramStr(10) else: "principal-owner"
  let backendOwnerId =
    if paramCount() >= 11: paramStr(11) else: authorityPrincipalId

  let mock = newMockBackendService(autoRespond = true)
  let session = createSessionVM(mock.toBackendService(), role)
  session.initializePanelViewModels()
  drain()
  mock.clearReceivedCommands()

  var peer = PeerRuntime(
    id: peerId,
    principalId: principalId,
    actorId: actorId,
    replicaId: replicaId,
    socket: connectPeerSocket(host, port, peerId),
    session: session,
    mockBackend: mock,
  )
  peer.configureCore(
    sessionId,
    traceIdentity,
    authorityPrincipalId,
    backendOwnerId)

  var running = true
  while running:
    let frame = peer.socket.recvFrame(DefaultFrameTimeoutMs)
    if frame.isNone:
      continue
    let message = frame.get
    case message.kind
    of lsmCommand:
      running = peer.handleCommand(message)
    of lsmJoinSnapshot, lsmViewOp, lsmBackendSnapshot:
      peer.handleRoomMessage(message)
    else:
      discard

  session.dispose()
  peer.socket.close()

when isMainModule:
  main()
