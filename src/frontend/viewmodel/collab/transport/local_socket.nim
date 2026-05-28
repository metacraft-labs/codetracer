## Local TCP transport for headless collaboration integration tests.
##
## M5 uses a deliberately small, line-delimited JSON protocol over loopback TCP.
## The transport keeps deterministic test controls from the in-memory room:
## explicit delivery, duplicate, drop, delay, and reverse-order delivery.

import std/[json, net, options, os, strutils]

import ../[codec, types]

type
  LocalSocketMessageKind* = enum
    lsmHello,
    lsmViewOp,
    lsmJoinSnapshot,
    lsmBackendSnapshot,
    lsmCommand,
    lsmState,
    lsmAck,
    lsmError

  LocalSocketRoomMessage* = object
    kind*: LocalSocketMessageKind
    fromPeerId*: string
    toPeerId*: string
    requestId*: string
    command*: string
    reason*: string
    op*: ViewOpEnvelope
    snapshot*: SharedSessionSnapshot
    backendSnapshot*: BackendDataSnapshotEnvelope
    tail*: seq[ViewOpEnvelope]
    payload*: JsonNode

  LocalSocketDelivery* = object
    message*: LocalSocketRoomMessage
    delivered*: bool
    reason*: string

  LocalSocketPeer* = ref object
    id*: string
    socket*: Socket
    connected*: bool

  LocalSocketRoomTransport* = ref object
    server*: Socket
    host*: string
    port*: Port
    peers*: seq[LocalSocketPeer]
    pending*: seq[LocalSocketRoomMessage]
    delivered*: seq[LocalSocketDelivery]
    faultDelayMs*: int

const DefaultFrameTimeoutMs* = 5000

proc parseEnumValue[T: enum](name: string; fallback: T): T =
  for value in T:
    if $value == name:
      return value
  fallback

proc parseUint64(node: JsonNode; fallback = 0'u64): uint64 =
  if node.isNil:
    return fallback
  case node.kind
  of JInt:
    let raw = node.getBiggestInt
    if raw < 0: 0'u64 else: raw.uint64
  of JString:
    try:
      parseUInt(node.getStr).uint64
    except ValueError:
      fallback
  else:
    fallback

proc backendSnapshotToJson*(snapshot: BackendDataSnapshotEnvelope): JsonNode =
  %*{
    "sessionId": snapshot.sessionId,
    "backendOwnerId": snapshot.backendOwnerId,
    "emittedByPrincipalId": snapshot.emittedByPrincipalId,
    "family": snapshot.family,
    "backendEpoch": %snapshot.backendEpoch,
    "payload": if snapshot.payload.isNil: newJObject() else: snapshot.payload,
  }

proc parseBackendDataSnapshotEnvelope*(node: JsonNode): BackendDataSnapshotEnvelope =
  BackendDataSnapshotEnvelope(
    sessionId: node{"sessionId"}.getStr(""),
    backendOwnerId: node{"backendOwnerId"}.getStr(""),
    emittedByPrincipalId: node{"emittedByPrincipalId"}.getStr(""),
    family: node{"family"}.getStr(""),
    backendEpoch: parseUint64(node{"backendEpoch"}),
    payload: if node{"payload"}.isNil: newJObject() else: node{"payload"},
  )

proc toJson*(message: LocalSocketRoomMessage): JsonNode =
  result = %*{
    "kind": $message.kind,
    "fromPeerId": message.fromPeerId,
    "toPeerId": message.toPeerId,
    "requestId": message.requestId,
    "command": message.command,
    "reason": message.reason,
  }
  case message.kind
  of lsmViewOp:
    result["op"] = message.op.toJson
  of lsmJoinSnapshot:
    result["snapshot"] = message.snapshot.toJson
    var tail = newJArray()
    for op in message.tail:
      tail.add op.toJson
    result["tail"] = tail
  of lsmBackendSnapshot:
    result["backendSnapshot"] = message.backendSnapshot.backendSnapshotToJson
  of lsmCommand, lsmState, lsmAck, lsmError, lsmHello:
    result["payload"] =
      if message.payload.isNil: newJObject() else: message.payload

proc parseLocalSocketRoomMessage*(node: JsonNode): LocalSocketRoomMessage =
  result.kind = parseEnumValue(node{"kind"}.getStr(""), lsmError)
  result.fromPeerId = node{"fromPeerId"}.getStr("")
  result.toPeerId = node{"toPeerId"}.getStr("")
  result.requestId = node{"requestId"}.getStr("")
  result.command = node{"command"}.getStr("")
  result.reason = node{"reason"}.getStr("")
  result.payload = if node{"payload"}.isNil: newJObject() else: node{"payload"}
  case result.kind
  of lsmViewOp:
    result.op = parseViewOpEnvelope(node{"op"})
  of lsmJoinSnapshot:
    result.snapshot = parseSharedSessionSnapshot(node{"snapshot"})
    for opNode in node{"tail"}.getElems(@[]):
      result.tail.add parseViewOpEnvelope(opNode)
  of lsmBackendSnapshot:
    result.backendSnapshot =
      parseBackendDataSnapshotEnvelope(node{"backendSnapshot"})
  else:
    discard

proc sendFrame*(socket: Socket; message: LocalSocketRoomMessage) =
  socket.send($message.toJson & "\n")

proc recvFrame*(socket: Socket;
                timeoutMs = DefaultFrameTimeoutMs): Option[LocalSocketRoomMessage] =
  let line = socket.recvLine(timeout = timeoutMs)
  if line.len == 0:
    return none(LocalSocketRoomMessage)
  try:
    some(parseLocalSocketRoomMessage(parseJson(line)))
  except CatchableError:
    some(LocalSocketRoomMessage(
      kind: lsmError,
      reason: getCurrentExceptionMsg(),
      payload: %*{"raw": line},
    ))

proc deterministicPort*(namespace: string; spread = 2000; attempt = 0): Port =
  ## Pick a stable loopback test port while spreading parallel test processes.
  ## CODETRACER_COLLAB_TEST_PORT_BASE can be set by CI to reserve a range.
  let base = parseInt(getEnv("CODETRACER_COLLAB_TEST_PORT_BASE", "21000"))
  var hash = 0
  for ch in namespace:
    hash = (hash * 131 + ord(ch)) mod spread
  let pidOffset = (getCurrentProcessId() mod 20) * spread
  Port(base + pidOffset + ((hash + attempt) mod spread))

proc newLocalSocketRoomTransport*(port: Port;
                                  host = "127.0.0.1"): LocalSocketRoomTransport =
  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(port, host)
  server.listen()
  LocalSocketRoomTransport(
    server: server,
    host: host,
    port: port,
    peers: @[],
    pending: @[],
    delivered: @[],
  )

proc newLocalSocketRoomTransportForNamespace*(
    namespace: string;
    host = "127.0.0.1";
    attempts = 200): LocalSocketRoomTransport =
  ## Bind a deterministic port for a test namespace, probing nearby ports when
  ## the stable first choice is already occupied by another local process.
  var lastError = ""
  for attempt in 0 ..< attempts:
    let port = deterministicPort(namespace, attempt = attempt)
    try:
      return newLocalSocketRoomTransport(port, host)
    except OSError:
      lastError = getCurrentExceptionMsg()
  raise newException(IOError,
    "could not bind local socket room for namespace " & namespace &
    " after " & $attempts & " attempts: " & lastError)

proc close*(room: LocalSocketRoomTransport) =
  if room.isNil:
    return
  for peer in room.peers:
    if not peer.socket.isNil:
      peer.socket.close()
  if not room.server.isNil:
    room.server.close()

proc findPeerIndex(room: LocalSocketRoomTransport; peerId: string): int =
  if room.isNil:
    return -1
  for i, peer in room.peers:
    if peer.id == peerId:
      return i
  -1

proc acceptPeer*(room: LocalSocketRoomTransport;
                 expectedPeerId = "";
                 timeoutMs = DefaultFrameTimeoutMs): string =
  var client = newSocket()
  room.server.accept(client)
  let hello = client.recvFrame(timeoutMs)
  if hello.isNone or hello.get.kind != lsmHello:
    client.close()
    raise newException(IOError, "local socket peer did not send hello")
  result = hello.get.fromPeerId
  if expectedPeerId.len > 0 and result != expectedPeerId:
    client.close()
    raise newException(IOError,
      "expected peer " & expectedPeerId & " but got " & result)
  let existing = room.findPeerIndex(result)
  if existing >= 0:
    if not room.peers[existing].socket.isNil:
      room.peers[existing].socket.close()
    room.peers[existing].socket = client
    room.peers[existing].connected = true
  else:
    room.peers.add LocalSocketPeer(id: result, socket: client, connected: true)

proc connectPeerSocket*(host: string;
                        port: Port;
                        peerId: string;
                        timeoutMs = DefaultFrameTimeoutMs): Socket =
  result = newSocket()
  result.connect(host, port, timeout = timeoutMs)
  result.sendFrame(LocalSocketRoomMessage(
    kind: lsmHello,
    fromPeerId: peerId,
    payload: newJObject(),
  ))

proc disconnectPeer*(room: LocalSocketRoomTransport; peerId: string) =
  let index = room.findPeerIndex(peerId)
  if index >= 0:
    room.peers[index].connected = false

proc reconnectPeer*(room: LocalSocketRoomTransport; peerId: string) =
  let index = room.findPeerIndex(peerId)
  if index >= 0:
    room.peers[index].connected = true

proc isConnected*(room: LocalSocketRoomTransport; peerId: string): bool =
  let index = room.findPeerIndex(peerId)
  index >= 0 and room.peers[index].connected

proc setFaultDelay*(room: LocalSocketRoomTransport; delayMs: int) =
  if not room.isNil:
    room.faultDelayMs = max(0, delayMs)

proc enqueue*(room: LocalSocketRoomTransport; message: LocalSocketRoomMessage) =
  if not room.isNil:
    room.pending.add message

proc enqueueViewOp*(room: LocalSocketRoomTransport;
                    fromPeerId, toPeerId: string;
                    op: ViewOpEnvelope) =
  room.enqueue LocalSocketRoomMessage(
    kind: lsmViewOp,
    fromPeerId: fromPeerId,
    toPeerId: toPeerId,
    op: op,
  )

proc enqueueJoinSnapshot*(room: LocalSocketRoomTransport;
                          fromPeerId, toPeerId: string;
                          snapshot: SharedSessionSnapshot;
                          tail: seq[ViewOpEnvelope]) =
  room.enqueue LocalSocketRoomMessage(
    kind: lsmJoinSnapshot,
    fromPeerId: fromPeerId,
    toPeerId: toPeerId,
    snapshot: snapshot,
    tail: tail,
  )

proc enqueueBackendSnapshot*(room: LocalSocketRoomTransport;
                             fromPeerId, toPeerId: string;
                             snapshot: BackendDataSnapshotEnvelope) =
  room.enqueue LocalSocketRoomMessage(
    kind: lsmBackendSnapshot,
    fromPeerId: fromPeerId,
    toPeerId: toPeerId,
    backendSnapshot: snapshot,
  )

proc enqueueCommand*(room: LocalSocketRoomTransport;
                     toPeerId: string;
                     command: string;
                     payload: JsonNode = newJObject();
                     requestId = "") =
  room.enqueue LocalSocketRoomMessage(
    kind: lsmCommand,
    fromPeerId: "controller",
    toPeerId: toPeerId,
    requestId: requestId,
    command: command,
    payload: if payload.isNil: newJObject() else: payload,
  )

proc duplicatePending*(room: LocalSocketRoomTransport; index: int) =
  if room.isNil or index < 0 or index >= room.pending.len:
    return
  room.pending.add room.pending[index]

proc duplicateAllPending*(room: LocalSocketRoomTransport) =
  if room.isNil:
    return
  let original = room.pending
  for message in original:
    room.pending.add message

proc dropPendingForPeer*(room: LocalSocketRoomTransport; peerId: string): int =
  if room.isNil:
    return 0
  var kept: seq[LocalSocketRoomMessage] = @[]
  for message in room.pending:
    if message.toPeerId == peerId:
      inc result
      room.delivered.add LocalSocketDelivery(
        message: message,
        delivered: false,
        reason: "dropped by fault control",
      )
    else:
      kept.add message
  room.pending = kept

proc pendingCount*(room: LocalSocketRoomTransport): int =
  if room.isNil: 0 else: room.pending.len

proc deliverPending*(room: LocalSocketRoomTransport;
                     index = 0): Option[LocalSocketDelivery] =
  if room.isNil or index < 0 or index >= room.pending.len:
    return none(LocalSocketDelivery)

  let message = room.pending[index]
  room.pending.delete(index)
  var delivery = LocalSocketDelivery(message: message)
  let peerIndex = room.findPeerIndex(message.toPeerId)
  if peerIndex < 0:
    delivery.reason = "unknown peer"
  elif not room.peers[peerIndex].connected:
    delivery.reason = "peer disconnected"
  elif room.peers[peerIndex].socket.isNil:
    delivery.reason = "missing socket"
  else:
    if room.faultDelayMs > 0:
      sleep(room.faultDelayMs)
    room.peers[peerIndex].socket.sendFrame(message)
    delivery.delivered = true
  room.delivered.add delivery
  some(delivery)

proc deliverAll*(room: LocalSocketRoomTransport) =
  if room.isNil:
    return
  while room.pending.len > 0:
    discard room.deliverPending(0)

proc deliverReverse*(room: LocalSocketRoomTransport) =
  if room.isNil:
    return
  while room.pending.len > 0:
    discard room.deliverPending(room.pending.high)

proc readPeerFrame*(room: LocalSocketRoomTransport;
                    peerId: string;
                    timeoutMs = DefaultFrameTimeoutMs): Option[LocalSocketRoomMessage] =
  let index = room.findPeerIndex(peerId)
  if index < 0 or room.peers[index].socket.isNil:
    return none(LocalSocketRoomMessage)
  room.peers[index].socket.recvFrame(timeoutMs)
