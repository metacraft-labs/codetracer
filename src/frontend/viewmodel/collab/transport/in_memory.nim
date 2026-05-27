## Deterministic same-process collaboration transport.
##
## This module intentionally has no sockets, timers, DOM, or renderer coupling.
## Tests enqueue protocol messages, then explicitly choose delivery order,
## duplication, disconnect, and reconnect behavior.

import std/[options, sequtils]

import ../types

type
  InMemoryPeerId* = string

  InMemoryMessageKind* = enum
    imkViewOp,
    imkJoinSnapshot

  InMemoryRoomMessage* = object
    kind*: InMemoryMessageKind
    fromPeerId*: InMemoryPeerId
    toPeerId*: InMemoryPeerId
    op*: ViewOpEnvelope
    snapshot*: SharedSessionSnapshot
    tail*: seq[ViewOpEnvelope]

  InMemoryDelivery* = object
    message*: InMemoryRoomMessage
    delivered*: bool
    reason*: string

  InMemoryPeer* = ref object
    id*: InMemoryPeerId
    connected*: bool
    onMessage*: proc(message: InMemoryRoomMessage)

  InMemoryRoomTransport* = ref object
    peers*: seq[InMemoryPeer]
    pending*: seq[InMemoryRoomMessage]
    delivered*: seq[InMemoryDelivery]

proc newInMemoryRoomTransport*(): InMemoryRoomTransport =
  InMemoryRoomTransport(peers: @[], pending: @[], delivered: @[])

proc findPeerIndex(room: InMemoryRoomTransport; peerId: InMemoryPeerId): int =
  if room.isNil:
    return -1
  for i, peer in room.peers:
    if peer.id == peerId:
      return i
  -1

proc registerPeer*(room: InMemoryRoomTransport;
                   peerId: InMemoryPeerId;
                   onMessage: proc(message: InMemoryRoomMessage)) =
  if room.isNil:
    return
  let existing = room.findPeerIndex(peerId)
  if existing >= 0:
    room.peers[existing].connected = true
    room.peers[existing].onMessage = onMessage
  else:
    room.peers.add InMemoryPeer(
      id: peerId,
      connected: true,
      onMessage: onMessage,
    )

proc disconnectPeer*(room: InMemoryRoomTransport; peerId: InMemoryPeerId) =
  let index = room.findPeerIndex(peerId)
  if index >= 0:
    room.peers[index].connected = false

proc reconnectPeer*(room: InMemoryRoomTransport; peerId: InMemoryPeerId) =
  let index = room.findPeerIndex(peerId)
  if index >= 0:
    room.peers[index].connected = true

proc isConnected*(room: InMemoryRoomTransport; peerId: InMemoryPeerId): bool =
  let index = room.findPeerIndex(peerId)
  index >= 0 and room.peers[index].connected

proc enqueue*(room: InMemoryRoomTransport; message: InMemoryRoomMessage) =
  if room.isNil:
    return
  room.pending.add message

proc enqueueViewOp*(room: InMemoryRoomTransport;
                    fromPeerId, toPeerId: InMemoryPeerId;
                    op: ViewOpEnvelope) =
  room.enqueue InMemoryRoomMessage(
    kind: imkViewOp,
    fromPeerId: fromPeerId,
    toPeerId: toPeerId,
    op: op,
  )

proc enqueueJoinSnapshot*(room: InMemoryRoomTransport;
                          fromPeerId, toPeerId: InMemoryPeerId;
                          snapshot: SharedSessionSnapshot;
                          tail: seq[ViewOpEnvelope]) =
  room.enqueue InMemoryRoomMessage(
    kind: imkJoinSnapshot,
    fromPeerId: fromPeerId,
    toPeerId: toPeerId,
    snapshot: snapshot,
    tail: tail,
  )

proc duplicatePending*(room: InMemoryRoomTransport; index: int) =
  if room.isNil or index < 0 or index >= room.pending.len:
    return
  room.pending.add room.pending[index]

proc duplicateAllPending*(room: InMemoryRoomTransport) =
  if room.isNil:
    return
  let original = room.pending
  for message in original:
    room.pending.add message

proc pendingCount*(room: InMemoryRoomTransport): int =
  if room.isNil: 0 else: room.pending.len

proc pendingKinds*(room: InMemoryRoomTransport): seq[InMemoryMessageKind] =
  if room.isNil:
    return @[]
  room.pending.mapIt(it.kind)

proc deliverPending*(room: InMemoryRoomTransport; index = 0): Option[InMemoryDelivery] =
  if room.isNil or index < 0 or index >= room.pending.len:
    return none(InMemoryDelivery)

  let message = room.pending[index]
  room.pending.delete(index)
  let peerIndex = room.findPeerIndex(message.toPeerId)
  var delivery = InMemoryDelivery(message: message)
  if peerIndex < 0:
    delivery.reason = "unknown peer"
  elif not room.peers[peerIndex].connected:
    delivery.reason = "peer disconnected"
  else:
    delivery.delivered = true
    if not room.peers[peerIndex].onMessage.isNil:
      room.peers[peerIndex].onMessage(message)
  room.delivered.add delivery
  some(delivery)

proc deliverAll*(room: InMemoryRoomTransport) =
  if room.isNil:
    return
  while room.pending.len > 0:
    discard room.deliverPending(0)

proc deliverReverse*(room: InMemoryRoomTransport) =
  if room.isNil:
    return
  while room.pending.len > 0:
    discard room.deliverPending(room.pending.high)
