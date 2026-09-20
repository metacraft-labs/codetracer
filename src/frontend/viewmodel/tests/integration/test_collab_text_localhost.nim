## PLAT-33's real-stack integration test: **three peers, over the real
## local-network transport, editing one real file, with delivery order and
## duplication fuzzed.**
##
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/integration/test_collab_text_localhost.nim
##
## Spec: `Architecture/Editor-ViewModel.md` §12.2 and §12.2a;
## `Planned-Work/CodeTracer-Platform.milestones.org` PLAT-33, *"Real-stack
## integration tests (no mocks)"*.
##
## =========================================================================
## WHAT IS REAL HERE THAT IS NOT REAL IN THE UNIT SUITE
## =========================================================================
##
## `test_editor_collab_laws.nim` drives real envelopes through the real
## reducer, and that is most of the stack — but it hands the envelope from
## one peer to another as a Nim value. Four things only this file exercises:
##
## 1. **A real listening socket and three real TCP connections** on
##    127.0.0.1, through `collab/transport/local_socket.nim` — the transport
##    that already existed and that PLAT-33 was told to use rather than
##    invent.
## 2. **The envelope survives a THIRD encoding.** The unit suite round-trips
##    through `codec.toJson`; here every envelope is additionally wrapped in
##    a `LocalSocketRoomMessage`, newline-framed, written to a socket, read
##    back and re-parsed. A change set that survives `"CS1|"` and the
##    envelope's JSON has to survive the frame as well — and the document is
##    a ZWJ corpus window, so the bytes being framed are multi-byte clusters
##    rather than ASCII.
## 3. **Delivery order and duplication are fuzzed by the TRANSPORT**, not by
##    a list the test shuffled: `deliverReverse` drains the room's pending
##    queue from the back and `duplicatePending` puts a second copy of a real
##    frame on the wire. The peer's dedup is then the product's `hasApplied`
##    reached over a socket.
## 4. **A peer is really disconnected and really reconnected**, so the
##    offline half of §12.3 runs against a transport that drops frames rather
##    than against a flag.
##
## =========================================================================
## NO MOCKS, AND THE ONE THING THAT IS NOT REAL IS NAMED
## =========================================================================
##
## Every peer holds a real `SharedSessionDocument`, a real `PeerSession` and
## a real `EditorState`, and every state change goes through
## `reducer.applyViewOp`. What is NOT real is the process boundary: the three
## peers are three values in one process talking over three real sockets,
## rather than three processes. `test_collab_localhost.nim` beside this file
## does spawn processes, and this file deliberately does not follow it —
## adding process spawning here would test the harness, not the rebase, and
## the thing under test is what happens to a change set between a socket and
## a document.

import std/[json, net, options, os, strutils, unittest]

import ../../editor/change_set
import ../../editor/collab_text
import ../../editor/operations
import ../../collab/types
import ../../collab/codec
import ../../collab/reducer
import ../../collab/text_ops
import ../../collab/transport/local_socket
import ../corpus/unicode_corpus
import ../generators/change_generator

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 101

const
  SessionId = "plat33-localhost"
  DocumentId = "plat33-doc"
  Authority: PrincipalId = "peer0"
  PeerCount = 3

func peerId(i: int): string = "peer" & $i

func marker(peer, round: int): char =
  ## One distinct, unsplittable byte per `(peer, round)`. ASCII control bytes
  ## 0x01 upward: absent from the ZWJ corpus documents, and a single byte
  ## cannot be broken in half by an insertion.
  char(1 + peer * 8 + round)

type
  WirePeer = object
    id: string
    socket: Socket
    doc: SharedSessionDocument
    session: PeerSession
    editor: EditorState

let baseDoc = block:
  ## A real ZWJ corpus window: the class PLAT-33 names as the input that
  ## distinguishes a rebase that maps positions from one that maps byte
  ## offsets, and the one whose bytes a naive framing layer would mangle.
  var d = ""
  for doc in genDocs(0x33c0de11'u32):
    if doc.id.startsWith("c1-zwj"):
      d = doc.text
      break
  if d.len == 0: d = genDocs(0x33c0de11'u32)[0].text
  d

proc grantText(doc: var SharedSessionDocument; subject: PrincipalId;
               lamport: uint64) =
  discard doc.applyViewOp(ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: SessionId, principalId: Authority, actorId: Authority,
    opId: "grant-" & subject, lamport: lamport,
    kind: vokGrantCapabilities, targetPath: "capabilityGrants",
    payload: %*{
      "grantId": "grant-" & subject, "subject": subject, "issuer": Authority,
      "capabilities": [$capEditSharedText, $capPublishAwareness],
      "targetPaths": [TextDocumentsPath, TextSelectionsPath]},
    unknownFields: newJObject()))

proc drain(p: var WirePeer): int =
  ## Feed the peer's editor everything the reducer has newly COMMITTED.
  if not p.doc.state.hasTextDocument(DocumentId):
    return 0
  let committed = p.doc.state.textDocument(DocumentId).committedLog
  if committed.len <= p.session.version:
    return 0
  var batch: seq[TextUpdate] = @[]
  for i in p.session.version ..< committed.len:
    batch.add committed[i].toTextUpdate
  p.editor = p.session.receiveInto(p.editor, batch)
  batch.len

suite "PLAT-33 — three peers over the real local-network transport":

  test "three peers converge over real sockets, with order and duplication fuzzed":
    let room = newLocalSocketRoomTransportForNamespace("plat33-collab-text")
    defer: room.close()

    var peers: seq[WirePeer] = @[]
    for i in 0 ..< PeerCount:
      var p = WirePeer(
        id: peerId(i),
        socket: connectPeerSocket(room.host, room.port, peerId(i)),
        doc: initSharedSessionDocument(
          sessionId = SessionId, authorityPrincipalId = Authority,
          backendOwnerId = Authority),
        session: initPeerSession(peerId(i)),
        editor: initEditorState(baseDoc))
      counted room.acceptPeer(peerId(i)) == peerId(i)
      peers.add p
    counted peers.len == PeerCount

    for i in 0 ..< PeerCount:
      for j in 1 ..< PeerCount:
        peers[i].doc.grantText(peerId(j), uint64(90 + j))

    var lamport = 1000'u64
    var accepted: seq[ViewOpEnvelope] = @[]
    var framesRead = 0
    var duplicatesSeen = 0
    var reversedRounds = 0
    var partitionedRounds = 0

    let boundaries = clusterBoundaries(baseDoc)
    counted boundaries.len > 4

    for round in 0 ..< 4:
      # ---------------------------------------------------------------
      # EVERY PEER EDITS BEFORE ANY PEER SUBMITS.
      # ---------------------------------------------------------------
      # Which is what makes the submissions concurrent at the authority: by
      # the time peer 1's submission is read off the wire, peer 0's has
      # already been accepted, so `rebaseUpdates` walks a non-empty `over`.
      for i in 0 ..< PeerCount:
        # A real cluster boundary, and the three peers deliberately pick
        # boundaries CLOSE TOGETHER so the rebase is not the identity.
        let at = boundaries[(round * 2 + i) mod (boundaries.len - 1)]
        # **A ONE-BYTE MARKER, AND THE REASON IS NOT BREVITY.** A multi-byte
        # marker is splittable: a later insert at a cluster boundary can land
        # INSIDE `<1:2>` and the substring search then reports the edit
        # missing when it is present and correctly placed. Four of twelve did
        # exactly that on the first run. A single byte has no interior, so
        # `contains` answers the question the case is actually asking.
        let cs = changeSet(peers[i].editor.doc.len, at, at,
                           $marker(i, round))
        peers[i].editor = commitChange(peers[i].editor, cs)
        peers[i].session.recordLocal(cs, "e" & $i & "-" & $round)

      # ---------------------------------------------------------------
      # EACH PEER SENDS ITS SUBMISSION OVER ITS OWN SOCKET.
      # ---------------------------------------------------------------
      for i in 0 ..< PeerCount:
        let sendable = peers[i].session.sendable
        if sendable.updates.len == 0: continue
        var idTail = ""
        for u in sendable.updates: idTail.add u.updateId
        let submission = submitTextUpdateOp(
          sessionId = SessionId, principalId = peerId(i), actorId = peerId(i),
          replicaId = peerId(i), opId = "sub-" & $i & "-" & idTail,
          lamport = lamport, documentId = DocumentId,
          updates = sendable.updates, atVersion = sendable.atVersion,
          baseLength = baseDoc.len)
        lamport += 1
        peers[i].socket.sendFrame(LocalSocketRoomMessage(
          kind: lsmViewOp, fromPeerId: peerId(i), toPeerId: Authority,
          op: submission))

      # ---------------------------------------------------------------
      # THE AUTHORITY READS EACH SUBMISSION OFF THE WIRE AND ACCEPTS IT.
      # ---------------------------------------------------------------
      for i in 0 ..< PeerCount:
        let frame = room.readPeerFrame(peerId(i))
        counted frame.isSome
        inc framesRead
        let message = frame.get
        counted message.kind == lsmViewOp
        counted message.op.kind == vokSubmitTextUpdate
        # **THE CHANGE SET SURVIVED THE FRAME.** Asserted here rather than
        # inferred from convergence: a framing layer that mangled a
        # continuation byte would produce a change set that still decodes and
        # still applies, and the divergence would surface three rounds later
        # somewhere else.
        counted message.op.payload{"updates"}.getElems(@[]).len ==
                peers[i].session.unconfirmed.len

        let accept = peers[0].doc.state.acceptSubmission(
          message.op, Authority, Authority, Authority, lamport)
        lamport += uint64(max(1, accept.ops.len))
        counted accept.refused.len == 0
        for op in accept.ops:
          counted peers[0].doc.applyViewOp(op).status == asApplied
          accepted.add op
          for j in 0 ..< PeerCount:
            if j == 0: continue
            room.enqueueViewOp(Authority, peerId(j), op)
        discard peers[0].drain()

      # ---------------------------------------------------------------
      # FUZZ THE WIRE: duplicate a real frame, and drain from the back.
      # ---------------------------------------------------------------
      if room.pending.len > 0 and round mod 2 == 0:
        room.duplicatePending(0)
      if round mod 2 == 1:
        room.deliverReverse()
        inc reversedRounds
      else:
        room.deliverAll()

      # ---------------------------------------------------------------
      # A REAL DISCONNECT, AND A REAL RECONNECT.
      # ---------------------------------------------------------------
      if round == 2:
        room.disconnectPeer(peerId(2))
        inc partitionedRounds

      # **DRAINING A REAL SOCKET IS A `try`, NOT AN `isNone`.**
      # `recvFrame` delegates to `net.recvLine`, which RAISES `TimeoutError`
      # when nothing arrives inside the budget rather than returning `none` —
      # and `none` is what it returns for a CLOSED peer. Reading "no more
      # frames right now" out of the return value alone therefore conflates
      # an idle socket with a dead one, and the first version of this loop
      # crashed on the first quiet moment.
      for j in 1 ..< PeerCount:
        while true:
          var frame = none(LocalSocketRoomMessage)
          try:
            frame = peers[j].socket.recvFrame(50)
          except TimeoutError:
            break
          if frame.isNone: break
          inc framesRead
          let outcome = peers[j].doc.applyViewOp(frame.get.op)
          if outcome.status == asDuplicate: inc duplicatesSeen
          discard peers[j].drain()

      if round == 2:
        room.reconnectPeer(peerId(2))

    counted framesRead > 0
    counted accepted.len > 0
    counted reversedRounds > 0
    counted partitionedRounds > 0
    # **DUPLICATION REALLY HAPPENED**, as a count rather than a claim about
    # the transport: a duplicate the wire never carried is a fuzz that
    # tested nothing.
    checkpoint("duplicate frames the reducer refused: " & $duplicatesSeen)
    counted duplicatesSeen > 0

    # ---------------------------------------------------------------
    # QUIESCE — every accept to every peer, then everything still
    # unconfirmed submitted, until nobody is holding anything.
    # ---------------------------------------------------------------
    for j in 0 ..< PeerCount:
      for op in accepted:
        discard peers[j].doc.applyViewOp(op)
        discard peers[j].drain()

    for round in 0 ..< 6:
      var pending = false
      for i in 0 ..< PeerCount:
        let sendable = peers[i].session.sendable
        if sendable.updates.len == 0: continue
        pending = true
        var idTail = ""
        for u in sendable.updates: idTail.add u.updateId
        let submission = submitTextUpdateOp(
          sessionId = SessionId, principalId = peerId(i), actorId = peerId(i),
          replicaId = peerId(i), opId = "q" & $round & "-" & $i & "-" & idTail,
          lamport = lamport, documentId = DocumentId,
          updates = sendable.updates, atVersion = sendable.atVersion,
          baseLength = baseDoc.len)
        lamport += 1
        let accept = peers[0].doc.state.acceptSubmission(
          submission, Authority, Authority, Authority, lamport)
        lamport += uint64(max(1, accept.ops.len))
        counted accept.refused.len == 0
        for op in accept.ops:
          accepted.add op
          for j in 0 ..< PeerCount:
            discard peers[j].doc.applyViewOp(op)
            discard peers[j].drain()
      if not pending: break

    for i in 0 ..< PeerCount:
      counted peers[i].session.unconfirmed.len == 0

    # ---------------------------------------------------------------
    # CONVERGENCE, AGAINST THE AUTHORITY'S OWN FOLD.
    # ---------------------------------------------------------------
    # §30a: two peers running one `receiveUpdates` agree under any mutation
    # to it. The right-hand side is a different walk over different data.
    let fold = peers[0].doc.state.foldDocument(DocumentId, baseDoc)
    counted fold != baseDoc
    for i in 0 ..< PeerCount:
      checkpoint("peer " & $i & " has " & $peers[i].editor.doc.len &
                 " bytes, the fold has " & $fold.len)
      counted peers[i].editor.doc == fold
    # Every peer's edit is in the result: a fold that dropped somebody's work
    # would still be equal on all three.
    for i in 0 ..< PeerCount:
      for round in 0 ..< 4:
        checkpoint("peer " & $i & " round " & $round)
        counted fold.contains($marker(i, round))

    for i in 0 ..< PeerCount:
      peers[i].socket.close()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
