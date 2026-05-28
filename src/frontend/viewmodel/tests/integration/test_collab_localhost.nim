## M5 localhost collaboration integration tests.
##
##   nim c -r src/frontend/viewmodel/tests/integration/test_collab_localhost.nim

import std/[
  json,
  net,
  options,
  os,
  osproc,
  sequtils,
  unittest,
]

import ../../collab/[backend_snapshots, codec, reducer, types]
import ../../collab/transport/[in_memory, local_socket]

type
  LocalhostPeer = ref object
    id: string
    principalId: PrincipalId
    actorId: ActorId
    replicaId: SessionReplicaId
    process: Process

  LocalhostHarness = ref object
    sessionId: string
    traceIdentity: string
    authorityPrincipalId: PrincipalId
    backendOwnerId: PrincipalId
    authorityActorId: ActorId
    authorityReplicaId: SessionReplicaId
    authoritySeq: uint64
    authorityLamport: uint64
    authorityDocument: SharedSessionDocument
    transport: LocalSocketRoomTransport
    peerBinary: string
    peers: seq[LocalhostPeer]
    acceptedLog: seq[ViewOpEnvelope]
    protocolLog: seq[string]

  ConformanceMessageKind = enum
    cmkNone,
    cmkViewOp,
    cmkJoinSnapshot,
    cmkBackendSnapshot

  ConformanceReceived = object
    kind: ConformanceMessageKind
    opId: ViewOpId
    joinTailLen: int
    backendEpoch: uint64

  TransportConformanceHarness = ref object
    enqueueViewOp: proc(seq: uint64; entryId: int) {.closure.}
    enqueueJoinSnapshot: proc(seq: uint64; entryId: int) {.closure.}
    enqueueBackendSnapshot: proc() {.closure.}
    duplicateAllPending: proc() {.closure.}
    deliverAll: proc() {.closure.}
    deliverReverse: proc() {.closure.}
    deliverOne: proc(): string {.closure.}
    disconnectB: proc() {.closure.}
    reconnectB: proc() {.closure.}
    receiveB: proc(): ConformanceReceived {.closure.}
    cleanup: proc() {.closure.}

const
  PeerSource = "src/frontend/viewmodel/tests/integration/collab_peer_process.nim"
  PeerBinary = "src/frontend/viewmodel/tests/integration/collab_peer_process"

proc containsOp(ops: openArray[ViewOpEnvelope]; opId: ViewOpId): bool =
  for op in ops:
    if op.opId == opId:
      return true

proc compilePeerProcess(): string =
  doAssert fileExists(PeerSource), "missing " & PeerSource
  if fileExists(PeerBinary) and not fileNewer(PeerSource, PeerBinary):
    return PeerBinary
  let cmd = "nim c --out:" & quoteShell(PeerBinary) & " " & quoteShell(PeerSource)
  let exitCode = execShellCmd(cmd)
  doAssert exitCode == 0, "failed to compile collab_peer_process"
  PeerBinary

proc canonicalState(state: SharedSessionViewState): string =
  $(state.toJson)

proc canonicalAuthorityState(harness: LocalhostHarness): string =
  canonicalState(harness.authorityDocument.state)

proc currentAuthoritySnapshot(harness: LocalhostHarness): SharedSessionSnapshot =
  harness.authorityDocument.snapshot

proc acceptedTailAfter(harness: LocalhostHarness;
                       snapshot: SharedSessionSnapshot): seq[ViewOpEnvelope] =
  for op in harness.acceptedLog:
    if op.opId notin snapshot.appliedOpIds:
      result.add op

proc findPeer(harness: LocalhostHarness; peerId: string): LocalhostPeer =
  for peer in harness.peers:
    if peer.id == peerId:
      return peer
  nil

proc protocolDump(harness: LocalhostHarness): string =
  result.add "protocol log:\n"
  for line in harness.protocolLog:
    result.add "  " & line & "\n"
  result.add "accepted log:\n"
  for op in harness.acceptedLog:
    result.add "  " & op.opId & " " & $op.kind & " " & op.targetPath &
      " principal=" & op.principalId & "\n"
  result.add "authority state:\n  " &
    $harness.authorityDocument.state.toJson & "\n"

proc newLocalhostHarness(name: string): LocalhostHarness =
  let transport = newLocalSocketRoomTransportForNamespace(name)
  result = LocalhostHarness(
    sessionId: "localhost-" & name,
    traceIdentity: "localhost-trace",
    authorityPrincipalId: "principal-owner",
    backendOwnerId: "principal-owner",
    authorityActorId: "actor-authority",
    authorityReplicaId: "replica-authority",
    authorityDocument: initSharedSessionDocument(
      sessionId = "localhost-" & name,
      traceIdentity = "localhost-trace",
      authorityPrincipalId = "principal-owner",
      backendOwnerId = "principal-owner",
    ),
    transport: transport,
    peerBinary: compilePeerProcess(),
    peers: @[],
    acceptedLog: @[],
    protocolLog: @["listen 127.0.0.1:" & $transport.port.int],
  )

proc authorityOp(harness: LocalhostHarness;
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

proc broadcastAccepted(harness: LocalhostHarness;
                       fromPeerId: string;
                       op: ViewOpEnvelope) =
  for peer in harness.peers:
    harness.transport.enqueueViewOp(fromPeerId, peer.id, op)

proc submitToAuthority(harness: LocalhostHarness;
                       fromPeerId: string;
                       op: ViewOpEnvelope): ApplyResult =
  result = harness.authorityDocument.applyViewOp(op)
  harness.protocolLog.add "authority " & $result.status & " " & op.opId &
    " from " & fromPeerId & " " & result.reason
  if result.status != asRejected and not harness.acceptedLog.containsOp(op.opId):
    harness.acceptedLog.add op
    harness.broadcastAccepted(fromPeerId, op)

proc grantPeerCapabilities(harness: LocalhostHarness; peerId: string) =
  let peer = harness.findPeer(peerId)
  if peer.isNil or peer.principalId == harness.authorityPrincipalId:
    return
  let op = harness.authorityOp(
    vokGrantCapabilities,
    "capabilityGrants",
    %*{
      "grantId": "grant-" & peer.id,
      "subject": peer.principalId,
      "capabilities": @[$capMutateSharedViewState, $capManageWatches],
      "targetPaths": @["calltrace", "statePane"],
    },
  )
  discard harness.submitToAuthority("authority", op)

proc enqueueJoin(harness: LocalhostHarness;
                 peerId: string;
                 snapshot: SharedSessionSnapshot;
                 fromPeerId = "authority") =
  harness.transport.enqueueJoinSnapshot(
    fromPeerId,
    peerId,
    snapshot,
    harness.acceptedTailAfter(snapshot),
  )

proc deliverAll(harness: LocalhostHarness) =
  harness.transport.deliverAll()

proc addPeer(harness: LocalhostHarness;
             peerId: string;
             role: string;
             principalId = "";
             joinSnapshot: Option[SharedSessionSnapshot] =
               none(SharedSessionSnapshot)): LocalhostPeer =
  let principal =
    if principalId.len > 0: principalId else: "principal-" & peerId
  result = LocalhostPeer(
    id: peerId,
    principalId: principal,
    actorId: "actor-" & peerId,
    replicaId: "replica-" & peerId,
  )
  let args = @[
    harness.transport.host,
    $harness.transport.port.int,
    peerId,
    role,
    principal,
    result.actorId,
    result.replicaId,
    harness.sessionId,
    harness.traceIdentity,
    harness.authorityPrincipalId,
    harness.backendOwnerId,
  ]
  result.process = startProcess(harness.peerBinary, args = args)
  let acceptedId = harness.transport.acceptPeer(peerId)
  doAssert acceptedId == peerId
  harness.peers.add result
  harness.protocolLog.add "peer process joined " & peerId
  harness.enqueueJoin(peerId,
    if joinSnapshot.isSome: joinSnapshot.get else: harness.currentAuthoritySnapshot)
  harness.deliverAll()

proc readUntilResponse(harness: LocalhostHarness;
                       peerId, requestId: string;
                       wanted: set[LocalSocketMessageKind]): LocalSocketRoomMessage =
  for _ in 0 ..< 50:
    let frame = harness.transport.readPeerFrame(peerId)
    if frame.isNone:
      continue
    let message = frame.get
    case message.kind
    of lsmViewOp:
      discard harness.submitToAuthority(peerId, message.op)
    of lsmAck, lsmState, lsmError:
      if message.requestId == requestId and message.kind in wanted:
        return message
    else:
      discard
  LocalSocketRoomMessage(
    kind: lsmError,
    fromPeerId: peerId,
    requestId: requestId,
    reason: "timed out waiting for peer response",
    payload: newJObject(),
  )

proc peerCommand(harness: LocalhostHarness;
                 peerId, command: string;
                 payload: JsonNode = newJObject()): LocalSocketRoomMessage =
  let requestId = peerId & "-" & command & "-" & $harness.protocolLog.len
  harness.transport.enqueueCommand(peerId, command, payload, requestId)
  harness.deliverAll()
  result = harness.readUntilResponse(
    peerId,
    requestId,
    {lsmAck, lsmState, lsmError})
  check result.kind != lsmError

proc requestState(harness: LocalhostHarness; peerId: string): JsonNode =
  let response = harness.peerCommand(peerId, "state")
  check response.kind == lsmState
  response.payload

proc selectCalltrace(harness: LocalhostHarness;
                     peerId: string;
                     entry: Option[int64]) =
  let payload =
    if entry.isSome: %*{"entryId": entry.get}
    else: %*{"entryId": newJNull()}
  discard harness.peerCommand(peerId, "selectCalltrace", payload)
  harness.deliverAll()

proc toggleStatePath(harness: LocalhostHarness; peerId, path: string) =
  discard harness.peerCommand(peerId, "toggleStatePath", %*{"path": path})
  harness.deliverAll()

proc addWatch(harness: LocalhostHarness; peerId, expression: string) =
  discard harness.peerCommand(peerId, "addWatch", %*{"expression": expression})
  harness.deliverAll()

proc allPeerStatesMatchAuthority(harness: LocalhostHarness): bool =
  let expected = harness.canonicalAuthorityState
  for peer in harness.peers:
    let state = harness.requestState(peer.id)
    if state{"canonicalState"}.getStr("") != expected:
      harness.protocolLog.add "state mismatch for " & peer.id & ": " &
        state{"canonicalState"}.getStr("")
      return false
  true

proc checkConverged(harness: LocalhostHarness) =
  if not harness.allPeerStatesMatchAuthority:
    echo harness.protocolDump()
  check harness.allPeerStatesMatchAuthority

proc shutdown(harness: LocalhostHarness) =
  if harness.isNil:
    return
  for peer in harness.peers:
    if not peer.process.isNil:
      try:
        discard harness.peerCommand(peer.id, "shutdown")
      except CatchableError:
        discard
      discard waitForExit(peer.process, 1000)
      if running(peer.process):
        terminate(peer.process)
        discard waitForExit(peer.process, 1000)
      close(peer.process)
  harness.transport.close()

proc makeTwoPeerHarness(name: string): LocalhostHarness =
  result = newLocalhostHarness(name)
  discard result.addPeer("owner", "owner",
    principalId = result.authorityPrincipalId)
  discard result.addPeer("peer-b", "collaborator")
  result.grantPeerCapabilities("peer-b")
  result.deliverAll()

proc sampleOp(actorId: string; seq: uint64; entryId: int): ViewOpEnvelope =
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: "transport-conformance",
    principalId: "principal-" & actorId,
    actorId: actorId,
    replicaId: "replica-" & actorId,
    actorSeq: seq,
    opId: actorId & ":" & $seq,
    lamport: seq,
    targetPath: "calltrace.selectedEntry",
    kind: vokSetCalltraceSelection,
    payload: %*{"entryId": $entryId},
    unknownFields: newJObject(),
  )

proc sampleSnapshot(): SharedSessionSnapshot =
  initSharedSessionDocument(
    sessionId = "transport-conformance",
    traceIdentity = "trace",
    authorityPrincipalId = "principal-a",
    backendOwnerId = "principal-a",
  ).snapshot

proc sampleBackendSnapshot(): BackendDataSnapshotEnvelope =
  backendSnapshot(
    sessionId = "transport-conformance",
    backendOwnerId = "principal-a",
    emittedByPrincipalId = "principal-a",
    family = "debugger",
    backendEpoch = 1'u64,
    payload = %*{"rrTicks": 1, "status": "dsIdle"},
  )

proc toConformanceMessage(message: InMemoryRoomMessage): ConformanceReceived =
  case message.kind
  of imkViewOp:
    ConformanceReceived(kind: cmkViewOp, opId: message.op.opId)
  of imkJoinSnapshot:
    ConformanceReceived(
      kind: cmkJoinSnapshot,
      joinTailLen: message.tail.len,
    )
  of imkBackendSnapshot:
    ConformanceReceived(
      kind: cmkBackendSnapshot,
      backendEpoch: message.backendSnapshot.backendEpoch,
    )

proc toConformanceMessage(message: LocalSocketRoomMessage): ConformanceReceived =
  case message.kind
  of lsmViewOp:
    ConformanceReceived(kind: cmkViewOp, opId: message.op.opId)
  of lsmJoinSnapshot:
    ConformanceReceived(
      kind: cmkJoinSnapshot,
      joinTailLen: message.tail.len,
    )
  of lsmBackendSnapshot:
    ConformanceReceived(
      kind: cmkBackendSnapshot,
      backendEpoch: message.backendSnapshot.backendEpoch,
    )
  else:
    ConformanceReceived(kind: cmkNone)

proc newInMemoryConformanceHarness(): TransportConformanceHarness =
  let room = newInMemoryRoomTransport()
  var received: seq[InMemoryRoomMessage] = @[]
  var readIndex = 0
  room.registerPeer("a", proc(message: InMemoryRoomMessage) = discard)
  room.registerPeer("b", proc(message: InMemoryRoomMessage) =
    received.add message)

  proc enqueueViewOp(seq: uint64; entryId: int) =
    room.enqueueViewOp("a", "b", sampleOp("actor-a", seq, entryId))

  proc enqueueJoinSnapshot(seq: uint64; entryId: int) =
    room.enqueueJoinSnapshot(
      "a",
      "b",
      sampleSnapshot(),
      @[sampleOp("actor-a", seq, entryId)])

  proc enqueueBackendSnapshot() =
    room.enqueueBackendSnapshot("a", "b", sampleBackendSnapshot())

  proc deliverOne(): string =
    let delivery = room.deliverPending()
    if delivery.isSome: delivery.get.reason else: "no pending message"

  proc receiveB(): ConformanceReceived =
    if readIndex >= received.len:
      return ConformanceReceived(kind: cmkNone)
    result = received[readIndex].toConformanceMessage
    inc readIndex

  TransportConformanceHarness(
    enqueueViewOp: enqueueViewOp,
    enqueueJoinSnapshot: enqueueJoinSnapshot,
    enqueueBackendSnapshot: enqueueBackendSnapshot,
    duplicateAllPending: proc() = room.duplicateAllPending(),
    deliverAll: proc() = room.deliverAll(),
    deliverReverse: proc() = room.deliverReverse(),
    deliverOne: deliverOne,
    disconnectB: proc() = room.disconnectPeer("b"),
    reconnectB: proc() = room.reconnectPeer("b"),
    receiveB: receiveB,
    cleanup: proc() = discard,
  )

proc newLocalSocketConformanceHarness(): TransportConformanceHarness =
  let room = newLocalSocketRoomTransportForNamespace("transport-conformance")
  let clientA = connectPeerSocket("127.0.0.1", room.port, "a")
  discard room.acceptPeer("a")
  let clientB = connectPeerSocket("127.0.0.1", room.port, "b")
  discard room.acceptPeer("b")
  room.setFaultDelay(1)

  proc enqueueViewOp(seq: uint64; entryId: int) =
    room.enqueueViewOp("a", "b", sampleOp("actor-a", seq, entryId))

  proc enqueueJoinSnapshot(seq: uint64; entryId: int) =
    room.enqueueJoinSnapshot(
      "a",
      "b",
      sampleSnapshot(),
      @[sampleOp("actor-a", seq, entryId)])

  proc enqueueBackendSnapshot() =
    room.enqueueBackendSnapshot("a", "b", sampleBackendSnapshot())

  proc deliverOne(): string =
    let delivery = room.deliverPending()
    if delivery.isSome: delivery.get.reason else: "no pending message"

  proc receiveB(): ConformanceReceived =
    let frame = clientB.recvFrame()
    if frame.isSome: frame.get.toConformanceMessage
    else: ConformanceReceived(kind: cmkNone)

  proc cleanup() =
    clientA.close()
    clientB.close()
    room.close()

  TransportConformanceHarness(
    enqueueViewOp: enqueueViewOp,
    enqueueJoinSnapshot: enqueueJoinSnapshot,
    enqueueBackendSnapshot: enqueueBackendSnapshot,
    duplicateAllPending: proc() = room.duplicateAllPending(),
    deliverAll: proc() = room.deliverAll(),
    deliverReverse: proc() = room.deliverReverse(),
    deliverOne: deliverOne,
    disconnectB: proc() = room.disconnectPeer("b"),
    reconnectB: proc() = room.reconnectPeer("b"),
    receiveB: receiveB,
    cleanup: cleanup,
  )

proc runTransportConformance(label: string;
                             harness: TransportConformanceHarness) =
  try:
    checkpoint label
    harness.enqueueViewOp(1, 1)
    harness.enqueueViewOp(2, 2)
    harness.deliverReverse()
    let first = harness.receiveB()
    let second = harness.receiveB()
    check first.kind == cmkViewOp
    check first.opId == "actor-a:2"
    check second.kind == cmkViewOp
    check second.opId == "actor-a:1"

    harness.enqueueJoinSnapshot(3, 3)
    harness.enqueueBackendSnapshot()
    harness.duplicateAllPending()
    harness.deliverAll()
    var joinCount = 0
    var backendCount = 0
    for _ in 0 ..< 4:
      let message = harness.receiveB()
      if message.kind == cmkJoinSnapshot:
        inc joinCount
        check message.joinTailLen == 1
      if message.kind == cmkBackendSnapshot:
        inc backendCount
        check message.backendEpoch == 1'u64
    check joinCount == 2
    check backendCount == 2

    harness.disconnectB()
    harness.enqueueViewOp(4, 4)
    check harness.deliverOne() == "peer disconnected"

    harness.reconnectB()
    harness.enqueueViewOp(5, 5)
    harness.deliverAll()
    let afterReconnect = harness.receiveB()
    check afterReconnect.kind == cmkViewOp
    check afterReconnect.opId == "actor-a:5"
  finally:
    if not harness.cleanup.isNil:
      harness.cleanup()

suite "collaborative ViewModel M5 localhost transport":

  test "integration_collab_localhost_two_processes_converge_viewstate":
    let harness = makeTwoPeerHarness("two-processes")
    try:
      harness.selectCalltrace("owner", some(42'i64))
      harness.toggleStatePath("peer-b", "frame.locals.counter")
      harness.addWatch("peer-b", "counter + 1")

      let peerB = harness.requestState("peer-b")
      check peerB{"projected"}{"calltraceSelected"}.getBiggestInt == 42
      check "counter + 1" in peerB{"projected"}{"watches"}.getElems.mapIt(it.getStr)
      harness.checkConverged()
    finally:
      harness.shutdown()

  test "integration_collab_localhost_join_mid_session_replays_snapshot_tail":
    let harness = makeTwoPeerHarness("join-mid-session")
    try:
      harness.selectCalltrace("owner", some(7'i64))
      let joinBase = harness.currentAuthoritySnapshot()
      harness.addWatch("owner", "tailWatch")
      discard harness.addPeer("peer-c", "collaborator", joinSnapshot = some(joinBase))
      harness.grantPeerCapabilities("peer-c")
      harness.deliverAll()

      let peerC = harness.requestState("peer-c")
      check peerC{"projected"}{"calltraceSelected"}.getBiggestInt == 7
      check "tailWatch" in peerC{"projected"}{"watches"}.getElems.mapIt(it.getStr)
      harness.checkConverged()
    finally:
      harness.shutdown()

  test "integration_collab_localhost_reconnect_resyncs_missing_ops":
    let harness = makeTwoPeerHarness("reconnect-resync")
    try:
      harness.selectCalltrace("owner", some(1'i64))
      harness.transport.disconnectPeer("peer-b")
      harness.addWatch("owner", "missed.while.disconnected")
      check harness.transport.delivered.anyIt(
        it.message.toPeerId == "peer-b" and it.reason == "peer disconnected")

      harness.transport.reconnectPeer("peer-b")
      harness.enqueueJoin("peer-b", harness.currentAuthoritySnapshot())
      harness.deliverAll()

      let peerB = harness.requestState("peer-b")
      check "missed.while.disconnected" in
        peerB{"projected"}{"watches"}.getElems.mapIt(it.getStr)
      harness.checkConverged()
    finally:
      harness.shutdown()

  test "integration_collab_transport_conformance_in_memory_and_localhost":
    runTransportConformance("in-memory", newInMemoryConformanceHarness())
    runTransportConformance("localhost", newLocalSocketConformanceHarness())
