## WebRTC DataChannel transport for collaborative ViewModel sessions.
##
## CI rendezvous endpoints are a signaling/control plane only. ViewOps are
## framed here and sent over RTCDataChannel in browser builds; native tests use
## the same frame codec and a headless Chromium harness to exercise real
## RTCPeerConnection/DataChannel behavior.

import std/json

import ../[backend_snapshots, codec, reducer, session_core, types]
import ./local_socket

type
  WebRtcFrameKind* = enum
    wrfkViewOp,
    wrfkJoinSnapshot,
    wrfkBackendSnapshot

  WebRtcFrame* = object
    kind*: WebRtcFrameKind
    fromPeerId*: string
    toPeerId*: string
    op*: ViewOpEnvelope
    snapshot*: SharedSessionSnapshot
    backendSnapshot*: BackendDataSnapshotEnvelope
    tail*: seq[ViewOpEnvelope]

  WebRtcFallbackDecision* = object
    directPeerFailed*: bool
    shouldRetryRendezvous*: bool
    mayRelayViewOpsThroughCi*: bool
    reason*: string

  WebRtcControlPlaneAudit* = ref object
    rendezvousMessages*: int
    dataChannelMessages*: int
    ciViewOpRelayAttempts*: int

  WebRtcRendezvousConfig* = object
    roomId*: string
    rendezvousUrl*: string
    inviteToken*: string
    peerId*: string
    principalId*: string
    actorId*: string
    replicaId*: string
    host*: bool

const WebRtcTransportHint* = "webrtc-datachannel"
const P2PViewOpsHint* = "p2p-viewops"
const CiViewOpRelayDisabledHint* = "viewops-not-accepted"

proc parseFrameKind(name: string): WebRtcFrameKind =
  for value in WebRtcFrameKind:
    if $value == name:
      return value
  raise newException(ValueError, "unknown WebRTC frame kind: " & name)

proc viewOpArray(ops: openArray[ViewOpEnvelope]): JsonNode =
  result = newJArray()
  for op in ops:
    result.add op.toJson

proc toJson*(frame: WebRtcFrame): JsonNode =
  result = %*{
    "protocol": "codetracer.collab.webrtc",
    "kind": $frame.kind,
    "fromPeerId": frame.fromPeerId,
    "toPeerId": frame.toPeerId,
  }
  case frame.kind
  of wrfkViewOp:
    result["op"] = frame.op.toJson
  of wrfkJoinSnapshot:
    result["snapshot"] = frame.snapshot.toJson
    result["tail"] = viewOpArray(frame.tail)
  of wrfkBackendSnapshot:
    result["backendSnapshot"] = frame.backendSnapshot.backendSnapshotToJson

proc parseWebRtcFrame*(node: JsonNode): WebRtcFrame =
  if node{"protocol"}.getStr("") != "codetracer.collab.webrtc":
    raise newException(ValueError, "not a CodeTracer WebRTC frame")
  result.kind = parseFrameKind(node{"kind"}.getStr(""))
  result.fromPeerId = node{"fromPeerId"}.getStr("")
  result.toPeerId = node{"toPeerId"}.getStr("")
  case result.kind
  of wrfkViewOp:
    result.op = parseViewOpEnvelope(node{"op"})
  of wrfkJoinSnapshot:
    result.snapshot = parseSharedSessionSnapshot(node{"snapshot"})
    for opNode in node{"tail"}.getElems(@[]):
      result.tail.add parseViewOpEnvelope(opNode)
  of wrfkBackendSnapshot:
    result.backendSnapshot = parseBackendDataSnapshotEnvelope(node{"backendSnapshot"})

proc parseWebRtcFrame*(raw: string): WebRtcFrame =
  parseWebRtcFrame(parseJson(raw))

proc encodeViewOpFrame*(fromPeerId, toPeerId: string;
                        op: ViewOpEnvelope): string =
  $WebRtcFrame(
    kind: wrfkViewOp,
    fromPeerId: fromPeerId,
    toPeerId: toPeerId,
    op: op).toJson

proc encodeJoinSnapshotFrame*(fromPeerId, toPeerId: string;
                              snapshot: SharedSessionSnapshot;
                              tail: openArray[ViewOpEnvelope]): string =
  $WebRtcFrame(
    kind: wrfkJoinSnapshot,
    fromPeerId: fromPeerId,
    toPeerId: toPeerId,
    snapshot: snapshot,
    tail: @tail).toJson

proc encodeBackendSnapshotFrame*(fromPeerId, toPeerId: string;
                                 snapshot: BackendDataSnapshotEnvelope): string =
  $WebRtcFrame(
    kind: wrfkBackendSnapshot,
    fromPeerId: fromPeerId,
    toPeerId: toPeerId,
    backendSnapshot: snapshot).toJson

proc recordRendezvous*(audit: WebRtcControlPlaneAudit) =
  if not audit.isNil:
    inc audit.rendezvousMessages

proc recordDataChannel*(audit: WebRtcControlPlaneAudit) =
  if not audit.isNil:
    inc audit.dataChannelMessages

proc rejectCiViewOpRelay*(audit: WebRtcControlPlaneAudit): bool =
  ## Returns false by design: M9 fallback may retry/rejoin signaling but must not
  ## turn CI into a normal ViewOp relay.
  if not audit.isNil:
    inc audit.ciViewOpRelayAttempts
  false

proc fallbackDecision*(directPeerFailed: bool; reason: string): WebRtcFallbackDecision =
  WebRtcFallbackDecision(
    directPeerFailed: directPeerFailed,
    shouldRetryRendezvous: directPeerFailed,
    mayRelayViewOpsThroughCi: false,
    reason: reason)

proc acceptsWebRtcP2P*(transportHints: openArray[string]): bool =
  var hasWebRtc = false
  var hasP2P = false
  var ciRelayDisabled = false
  for hint in transportHints:
    case hint
    of WebRtcTransportHint:
      hasWebRtc = true
    of P2PViewOpsHint:
      hasP2P = true
    of CiViewOpRelayDisabledHint:
      ciRelayDisabled = true
    else:
      discard
  hasWebRtc and hasP2P and ciRelayDisabled

proc applyWebRtcFrame*(core: CollaborativeSessionCore;
                       frame: WebRtcFrame): ApplyResult =
  if core.isNil:
    return rejected("missing collaborative session core")
  case frame.kind
  of wrfkViewOp:
    result = core.applyRemoteViewOp(frame.op)
  of wrfkJoinSnapshot:
    core.loadJoinSnapshot(frame.snapshot)
    result = applied("snapshot loaded")
    for op in frame.tail:
      result = core.applyRemoteViewOp(op)
  of wrfkBackendSnapshot:
    result = core.document.applyAuthoritativeBackendSnapshot(frame.backendSnapshot)
    core.projectCurrentState()

when defined(js):
  proc jsStartWebRtc(roomId, rendezvousUrl, inviteToken, peerId, principalId,
                     actorId, replicaId: cstring; host: bool;
                     onData: proc(raw: cstring) {.closure.}): bool {.importjs: """
    (function(roomId, rendezvousUrl, inviteToken, peerId, principalId, actorId,
              replicaId, host, onData) {
      if (typeof RTCPeerConnection === "undefined") return false;
      window.CODETRACER_COLLAB_WEBRTC_LOG =
        window.CODETRACER_COLLAB_WEBRTC_LOG || [];
      window.__ctCollabWebRtc = window.__ctCollabWebRtc || {};

      const key = String(roomId || "");
      const id = String(peerId || "");
      const invite = String(inviteToken || "");
      const rendezvous = String(rendezvousUrl || "");

      function log(event) {
        window.CODETRACER_COLLAB_WEBRTC_LOG.push(Object.assign({
          roomId: key,
          peerId: id
        }, event));
      }

      function roomUrl() {
        if (rendezvous.length > 0) {
          const marker = "/rooms/" + encodeURIComponent(key) + "/rendezvous";
          const index = rendezvous.indexOf(marker);
          if (index >= 0) return rendezvous.substring(0, index + marker.length - "/rendezvous".length);
          if (rendezvous.endsWith("/rendezvous")) {
            return rendezvous.substring(0, rendezvous.length - "/rendezvous".length);
          }
        }
        return "/api/v1/collab/rooms/" + encodeURIComponent(key);
      }

      function roomsUrl() {
        const current = roomUrl();
        const suffix = "/" + encodeURIComponent(key);
        return current.endsWith(suffix) ? current.substring(0, current.length - suffix.length) : "/api/v1/collab/rooms";
      }

      async function postJson(url, payload) {
        const response = await fetch(url, {
          method: "POST",
          headers: {"content-type": "application/json"},
          body: JSON.stringify(payload)
        });
        if (!response.ok) throw new Error(await response.text());
        if (response.status === 204) return {};
        return await response.json();
      }

      const record = {
        roomId: key,
        peerId: id,
        host: !!host,
        rendezvousUrl: rendezvous,
        roomToken: "",
        remotePeerId: "",
        lastSignalSequence: 0,
        pc: new RTCPeerConnection({
          iceServers: window.CODETRACER_COLLAB_WEBRTC_ICE_SERVERS || []
        }),
        channel: null,
        pending: [],
        pendingCandidates: [],
        sent: [],
        received: [],
        ready: false,
        failed: false
      };

      function attach(channel) {
        record.channel = channel;
        channel.onopen = function() {
          record.ready = true;
          log({event: "datachannel-open"});
          while (record.pending.length && channel.readyState === "open") {
            channel.send(record.pending.shift());
          }
        };
        channel.onmessage = function(event) {
          const raw = String(event.data || "");
          record.received.push(raw);
          log({
            event: "datachannel-message",
            direction: "receive"
          });
          onData(raw);
        };
      }

      async function postSignal(kind, payload, toPeerId) {
        if (!record.roomToken) {
          record.pendingCandidates.push({kind, payload, toPeerId: toPeerId || null});
          return;
        }
        const signal = await postJson(roomUrl() + "/signals", {
          roomToken: record.roomToken,
          fromPeerId: id,
          toPeerId: toPeerId || record.remotePeerId || null,
          kind,
          payload
        });
        record.lastSignalSequence = Math.max(record.lastSignalSequence, signal.sequence || 0);
        log({event: "rendezvous-signal-posted", kind});
      }

      async function flushPendingCandidates() {
        while (record.pendingCandidates.length) {
          const item = record.pendingCandidates.shift();
          await postSignal(item.kind, item.payload, item.toPeerId);
        }
      }

      record.pc.onicecandidate = function(event) {
        if (event.candidate) {
          postSignal("candidate", event.candidate.toJSON ? event.candidate.toJSON() : event.candidate)
            .catch(error => {
              record.failed = true;
              log({event: "rendezvous-signal-error", message: String(error && error.message || error)});
            });
        }
      };

      if (record.host) {
        attach(record.pc.createDataChannel("codetracer-viewops", {ordered: true}));
      } else {
        record.pc.ondatachannel = function(event) { attach(event.channel); };
      }

      async function pollSignals(onSignal) {
        const deadline = Date.now() + 15000;
        while (!record.failed && Date.now() < deadline) {
          const url = roomUrl() + "/signals?peerId=" + encodeURIComponent(id) +
            "&roomToken=" + encodeURIComponent(record.roomToken) +
            "&afterSequence=" + encodeURIComponent(String(record.lastSignalSequence));
          const response = await fetch(url);
          if (!response.ok) throw new Error(await response.text());
          const payload = await response.json();
          if (payload.acceptsViewOps === true) throw new Error("rendezvous accepted ViewOps");
          for (const signal of payload.signals || []) {
            record.lastSignalSequence = Math.max(record.lastSignalSequence, signal.sequence || 0);
            await onSignal(signal);
          }
          if (record.ready) return;
          await new Promise(resolve => setTimeout(resolve, 25));
        }
        if (!record.ready) throw new Error("timed out waiting for WebRTC rendezvous");
      }

      async function startHost() {
        const room = await postJson(roomsUrl(), {
          inviteToken: invite,
          roomId: key,
          peer: {peerId: id, principalId: String(principalId || ""), actorId: String(actorId || ""), replicaId: String(replicaId || "")},
          payload: {client: "webui", intent: "create-webrtc-room"}
        });
        if (room.acceptsViewOps === true) throw new Error("rendezvous accepted ViewOps");
        record.roomToken = room.roomToken || "";
        record.lastSignalSequence = 0;
        log({event: "rendezvous-room-created"});
        await flushPendingCandidates();
        await record.pc.setLocalDescription(await record.pc.createOffer());
        await postSignal("offer", record.pc.localDescription ? record.pc.localDescription.toJSON() : record.pc.localDescription, null);
        await pollSignals(async signal => {
          if (signal.kind === "answer") {
            record.remotePeerId = signal.fromPeerId || record.remotePeerId;
            await record.pc.setRemoteDescription(signal.payload);
          } else if (signal.kind === "candidate") {
            record.remotePeerId = signal.fromPeerId || record.remotePeerId;
            await record.pc.addIceCandidate(signal.payload);
          }
        });
      }

      async function startJoiner() {
        const room = await postJson(roomUrl() + "/join", {
          inviteToken: invite,
          peer: {peerId: id, principalId: String(principalId || ""), actorId: String(actorId || ""), replicaId: String(replicaId || "")},
          payload: {client: "isonim-tui", intent: "join-webrtc-room"}
        });
        if (room.acceptsViewOps === true) throw new Error("rendezvous accepted ViewOps");
        record.roomToken = room.roomToken || "";
        record.lastSignalSequence = 0;
        for (const peer of room.peers || []) {
          if (peer.peerId !== id) {
            record.remotePeerId = peer.peerId;
            break;
          }
        }
        log({event: "rendezvous-room-joined"});
        await flushPendingCandidates();
        await pollSignals(async signal => {
          if (signal.kind === "offer") {
            record.remotePeerId = signal.fromPeerId || record.remotePeerId;
            await record.pc.setRemoteDescription(signal.payload);
            await record.pc.setLocalDescription(await record.pc.createAnswer());
            await postSignal("answer", record.pc.localDescription ? record.pc.localDescription.toJSON() : record.pc.localDescription, record.remotePeerId);
          } else if (signal.kind === "candidate") {
            record.remotePeerId = signal.fromPeerId || record.remotePeerId;
            await record.pc.addIceCandidate(signal.payload);
          }
        });
      }

      window.__ctCollabWebRtc[key + ":" + id] = record;
      (record.host ? startHost() : startJoiner()).catch(error => {
        record.failed = true;
        log({event: "rendezvous-start-error", message: String(error && error.message || error)});
      });
      return true;
    })(#, #, #, #, #, #, #, #, #)
  """.}

  proc jsSendWebRtc(roomId, peerId, raw: cstring): bool {.importjs: """
    (function(roomId, peerId, raw) {
      const records = window.__ctCollabWebRtc || {};
      const record = records[String(roomId || "") + ":" + String(peerId || "")];
      if (!record) return false;
      const text = String(raw || "");
      record.sent.push(text);
      window.CODETRACER_COLLAB_WEBRTC_LOG =
        window.CODETRACER_COLLAB_WEBRTC_LOG || [];
      window.CODETRACER_COLLAB_WEBRTC_LOG.push({
        event: "datachannel-message",
        direction: "send",
        roomId: String(roomId || ""),
        peerId: String(peerId || "")
      });
      if (record.channel && record.channel.readyState === "open") {
        record.channel.send(text);
      } else {
        record.pending.push(text);
      }
      return true;
    })(#, #, #)
  """.}

proc startWebRtcRoomTransport*(core: CollaborativeSessionCore;
                               roomId: string;
                               host: bool;
                               rendezvousUrl = "";
                               inviteToken = "";
                               peerId = ""): bool =
  if core.isNil or roomId.len == 0:
    return false

  let effectivePeerId = if peerId.len > 0: peerId else: core.localReplicaId
  core.transportSnapshotBase = core.joinSnapshot
  core.hasTransportSnapshotBase = true
  core.publishLocalViewOp = proc(op: ViewOpEnvelope): bool =
    when defined(js):
      jsSendWebRtc(cstring(roomId), cstring(effectivePeerId),
        cstring(encodeViewOpFrame(effectivePeerId, "", op)))
    else:
      false

  when defined(js):
    result = jsStartWebRtc(
      cstring(roomId),
      cstring(rendezvousUrl),
      cstring(inviteToken),
      cstring(effectivePeerId),
      cstring(core.localPrincipalId),
      cstring(core.localActorId),
      cstring(core.localReplicaId),
      host,
      proc(raw: cstring) {.closure.} =
        try:
          discard core.applyWebRtcFrame(parseWebRtcFrame($raw))
        except CatchableError:
          discard)
  else:
    discard effectivePeerId
    discard rendezvousUrl
    discard inviteToken
    result = false

  if result:
    core.peerTransportStarted = true
    core.remoteAwarenessStarted = true
    core.remoteGossipStarted = false
