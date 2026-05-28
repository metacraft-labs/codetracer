## M9 WebRTC/DataChannel collaboration integration tests.
##
##   nim c -r src/frontend/viewmodel/tests/integration/test_collab_webrtc.nim

import std/[json, os, osproc, sequtils, strutils, unittest]

import isonim_tui/renderer
import isonim_tui/testing/harness

import ../../backend/mock_backend
import ../../collab/[authority, backend_snapshots, front_end_adapter, reducer, session_core, types]
import ../../collab/transport/webrtc

type
  Peer = object
    peerId: string
    principalId: PrincipalId
    actorId: ActorId
    replicaId: SessionReplicaId
    seq: uint64
    core: CollaborativeSessionCore

  M9Harness = ref object
    sessionId: string
    traceIdentity: string
    authorityPrincipalId: PrincipalId
    backendOwnerId: PrincipalId
    authoritySeq: uint64
    lamport: uint64
    authorityDocument: SharedSessionDocument
    backendAuthority: BackendCommandAuthority
    web: Peer
    tui: Peer
    audit: WebRtcControlPlaneAudit

proc sampleOp(actorId: string; seq: uint64; entryId: int): ViewOpEnvelope =
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: "webrtc-conformance",
    principalId: "principal-a",
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

proc newPeer(h: M9Harness; peerId, principalId: string): Peer =
  let core = createCollaborativeSessionCore(
    sessionId = h.sessionId,
    traceIdentity = h.traceIdentity,
    localPrincipalId = principalId,
    localActorId = "actor-" & peerId,
    localReplicaId = "replica-" & peerId,
    backendOwnerId = h.backendOwnerId)
  core.collaborationEnabled = true
  core.peerTransportStarted = true
  core.remoteAwarenessStarted = true
  core.remoteGossipStarted = false
  core.loadJoinSnapshot(h.authorityDocument.snapshot)
  Peer(
    peerId: peerId,
    principalId: principalId,
    actorId: "actor-" & peerId,
    replicaId: "replica-" & peerId,
    core: core)

proc authorityOp(h: M9Harness; kind: ViewOpKind; targetPath: string;
                 payload: JsonNode): ViewOpEnvelope =
  h.authoritySeq.inc
  h.lamport.inc
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: h.sessionId,
    principalId: h.authorityPrincipalId,
    actorId: "actor-authority",
    replicaId: "replica-authority",
    actorSeq: h.authoritySeq,
    opId: "actor-authority:" & $h.authoritySeq,
    lamport: h.lamport,
    targetPath: targetPath,
    kind: kind,
    payload: if payload.isNil: newJObject() else: payload,
    unknownFields: newJObject(),
  )

proc peerOp(h: M9Harness; peer: var Peer; kind: ViewOpKind; targetPath: string;
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

proc applyAuthority(h: M9Harness; op: ViewOpEnvelope): ApplyResult =
  if op.kind == vokDebugCommand:
    result = h.backendAuthority.submitDebugCommand(h.authorityDocument, op)
  else:
    result = h.authorityDocument.applyViewOp(op)
    h.backendAuthority.auditViewOp(op, result)
  if result.status notin {asRejected, asDuplicate}:
    discard h.web.core.applyRemoteViewOp(op)
    discard h.tui.core.applyRemoteViewOp(op)

proc grantAll(h: M9Harness; principalId, grantId: string) =
  let op = h.authorityOp(
    vokGrantCapabilities,
    "capabilityGrants",
    %*{
      "grantId": grantId,
      "subject": principalId,
      "capabilities": @[
        $capObserve,
        $capPublishAwareness,
        $capMutateSharedViewState,
        $capManageWatches,
        $capControlDebugger,
      ],
      "targetPaths": @["*"],
    })
  check h.applyAuthority(op).status != asRejected

proc grantDriver(h: M9Harness; principalId, leaseId: string) =
  let op = h.authorityOp(
    vokGrantDriver,
    "activeDriver",
    %*{"principalId": principalId, "leaseId": leaseId})
  check h.applyAuthority(op).status != asRejected

proc newM9Harness(): M9Harness =
  result = M9Harness(
    sessionId: "m9-webrtc-webui-tui",
    traceIdentity: "m9-trace",
    authorityPrincipalId: "principal-webui",
    backendOwnerId: "principal-webui",
    authorityDocument: initSharedSessionDocument(
      sessionId = "m9-webrtc-webui-tui",
      traceIdentity = "m9-trace",
      authorityPrincipalId = "principal-webui",
      backendOwnerId = "principal-webui"),
    backendAuthority: newBackendCommandAuthority(
      "principal-webui",
      newMockBackendService(autoRespond = true).toBackendService()),
    audit: WebRtcControlPlaneAudit())
  result.web = result.newPeer("webui", "principal-webui")
  result.tui = result.newPeer("isonim-tui", "principal-tui")
  result.grantAll(result.tui.principalId, "grant-tui-m9")
  result.grantDriver(result.web.principalId, "lease-web")

proc findChromium(): string =
  for candidate in [
    getEnv("CHROMIUM_BIN", ""),
    "chromium",
    "chromium-browser",
    "google-chrome",
    "google-chrome-stable",
  ]:
    if candidate.len == 0:
      continue
    let found = findExe(candidate)
    if found.len > 0:
      return found
  raise newException(IOError, "Chromium is required for real WebRTC DataChannel tests")

proc runRendezvousBackedWebRtc(frames: openArray[string];
                               reconnectFrames: openArray[string] = []): JsonNode =
  let chromium = findChromium()
  let tempDir = getTempDir() / ("codetracer-webrtc-" & $getCurrentProcessId())
  createDir(tempDir)
  let framesPath = tempDir / "frames.json"
  let reconnectPath = tempDir / "reconnect_frames.json"
  let runnerPath = tempDir / "webrtc_cdp.py"
  let runner = r"""
import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

chromium = sys.argv[1]
frames = json.loads(open(sys.argv[2], "r", encoding="utf-8").read())
reconnect_frames = json.loads(open(sys.argv[3], "r", encoding="utf-8").read())
profile = tempfile.mkdtemp(prefix="ct-webrtc-profile-")
port = 43000 + (os.getpid() % 10000)
rooms = {}
rendezvous_audit = {"creates": 0, "joins": 0, "posts": [], "gets": 0, "viewop_rejections": 0}

def contains_viewop(value):
    if isinstance(value, dict):
        keys = {str(k).lower() for k in value.keys()}
        if {"viewop", "viewops", "ops", "operationlog"} & keys:
            return True
        if "kind" in keys and "opid" in keys:
            return True
        return any(contains_viewop(v) for v in value.values())
    if isinstance(value, list):
        return any(contains_viewop(v) for v in value)
    return False

class RendezvousHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("access-control-allow-origin", "*")
        self.send_header("access-control-allow-methods", "GET,POST,OPTIONS")
        self.send_header("access-control-allow-headers", "content-type")
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_json(200, {})

    def read_json(self):
        length = int(self.headers.get("content-length", "0"))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def room_payload(self, room, peer_id, room_token):
        return {
            "roomId": room["roomId"],
            "peerId": peer_id,
            "roomToken": room_token,
            "peers": list(room["peers"].values()),
            "lastSignalSequence": room["nextSeq"],
            "transportHints": [
                "control-plane-only",
                "viewops-not-accepted",
                "control-plane-rendezvous",
                "webrtc-datachannel",
                "p2p-viewops",
            ],
            "acceptsViewOps": False,
            "fallback": "direct-peer-retry-or-rejoin-rendezvous; ci-viewop-relay-disabled",
        }

    def ensure_room(self, room_id):
        return rooms.setdefault(room_id, {
            "roomId": room_id,
            "peers": {},
            "tokens": {},
            "signals": [],
            "nextSeq": 0,
        })

    def join_peer(self, room, peer):
        token = "token-" + peer["peerId"] + "-" + str(len(room["tokens"]) + 1)
        room["tokens"][peer["peerId"]] = token
        room["peers"][peer["peerId"]] = {
            "peerId": peer["peerId"],
            "principalId": peer["principalId"],
            "actorId": peer["actorId"],
            "replicaId": peer["replicaId"],
            "grants": ["observe", "publishAwareness", "mutateSharedViewState"],
            "joinedAt": "2026-05-28T00:00:00Z",
        }
        return token

    def do_POST(self):
        payload = self.read_json()
        if contains_viewop(payload.get("payload")):
            rendezvous_audit["viewop_rejections"] += 1
            self.send_json(400, {"code": "viewops_not_allowed"})
            return

        parts = [urllib.parse.unquote(p) for p in self.path.split("?", 1)[0].split("/") if p]
        if parts == ["api", "v1", "collab", "rooms"]:
            room = self.ensure_room(payload.get("roomId") or "m9-room")
            token = self.join_peer(room, payload["peer"])
            rendezvous_audit["creates"] += 1
            self.send_json(200, self.room_payload(room, payload["peer"]["peerId"], token))
            return

        if len(parts) == 6 and parts[:4] == ["api", "v1", "collab", "rooms"] and parts[5] == "join":
            room = self.ensure_room(parts[4])
            token = self.join_peer(room, payload["peer"])
            rendezvous_audit["joins"] += 1
            self.send_json(200, self.room_payload(room, payload["peer"]["peerId"], token))
            return

        if len(parts) == 6 and parts[:4] == ["api", "v1", "collab", "rooms"] and parts[5] == "signals":
            room = self.ensure_room(parts[4])
            from_peer = payload["fromPeerId"]
            if room["tokens"].get(from_peer) != payload.get("roomToken"):
                self.send_json(403, {"code": "invalid_room_token"})
                return
            room["nextSeq"] += 1
            signal = {
                "sequence": room["nextSeq"],
                "roomId": parts[4],
                "fromPeerId": from_peer,
                "toPeerId": payload.get("toPeerId"),
                "kind": payload["kind"],
                "payload": payload.get("payload") or {},
                "createdAt": "2026-05-28T00:00:00Z",
            }
            room["signals"].append(signal)
            rendezvous_audit["posts"].append(signal["kind"])
            self.send_json(200, signal)
            return

        self.send_json(404, {"code": "not_found", "path": self.path})

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        parts = [urllib.parse.unquote(p) for p in parsed.path.split("/") if p]
        query = urllib.parse.parse_qs(parsed.query)
        if len(parts) == 6 and parts[:4] == ["api", "v1", "collab", "rooms"] and parts[5] == "signals":
            room = self.ensure_room(parts[4])
            peer_id = query.get("peerId", [""])[0]
            room_token = query.get("roomToken", [""])[0]
            after_sequence = int(query.get("afterSequence", ["0"])[0])
            if room["tokens"].get(peer_id) != room_token:
                self.send_json(403, {"code": "invalid_room_token"})
                return
            signals = [
                signal for signal in room["signals"]
                if signal["sequence"] > after_sequence
                and signal["fromPeerId"] != peer_id
                and (signal["toPeerId"] is None or signal["toPeerId"] == peer_id)
            ]
            rendezvous_audit["gets"] += 1
            self.send_json(200, {
                "roomId": parts[4],
                "peerId": peer_id,
                "signals": signals,
                "acceptsViewOps": False,
            })
            return
        self.send_json(404, {"code": "not_found", "path": self.path})

rendezvous_server = ThreadingHTTPServer(("127.0.0.1", 0), RendezvousHandler)
rendezvous_thread = threading.Thread(target=rendezvous_server.serve_forever, daemon=True)
rendezvous_thread.start()
rendezvous_port = rendezvous_server.server_port
proc = subprocess.Popen([
    chromium,
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--password-store=basic",
    "--use-mock-keychain",
    "--remote-debugging-address=127.0.0.1",
    "--remote-debugging-port=" + str(port),
    "--user-data-dir=" + profile,
    "about:blank",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def get_json(path):
    with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path), timeout=1) as response:
        return json.loads(response.read().decode("utf-8"))

def put_json(path):
    request = urllib.request.Request(
        "http://127.0.0.1:%d%s" % (port, path),
        data=b"",
        method="PUT")
    with urllib.request.urlopen(request, timeout=1) as response:
        return json.loads(response.read().decode("utf-8"))

try:
    deadline = time.time() + 10
    target = None
    while time.time() < deadline:
        try:
            get_json("/json/version")
            target = put_json("/json/new?about:blank")
            break
        except Exception:
            time.sleep(0.05)
    if target is None:
        raise RuntimeError("could not connect to headless Chromium CDP")

    ws_url = target["webSocketDebuggerUrl"]
    _, rest = ws_url.split("://", 1)
    host_port, path = rest.split("/", 1)
    path = "/" + path
    host, port_text = host_port.split(":", 1)
    sock = socket.create_connection((host, int(port_text)), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        "GET %s HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    ) % (path, host_port, key)
    sock.sendall(request.encode("ascii"))
    response = sock.recv(4096)
    if b" 101 " not in response.split(b"\r\n", 1)[0]:
        raise RuntimeError("CDP WebSocket upgrade failed")

    def send_ws_text(text):
        payload = text.encode("utf-8")
        header = bytearray([0x81])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        elif len(payload) < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", len(payload)))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", len(payload)))
        mask = os.urandom(4)
        header.extend(mask)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        sock.sendall(bytes(header) + masked)

    def recv_exact(count):
        chunks = []
        remaining = count
        while remaining:
            chunk = sock.recv(remaining)
            if not chunk:
                raise RuntimeError("unexpected EOF from CDP WebSocket")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def recv_ws_text():
        first, second = recv_exact(2)
        opcode = first & 0x0f
        length = second & 0x7f
        if length == 126:
            length = struct.unpack("!H", recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", recv_exact(8))[0]
        masked = (second & 0x80) != 0
        mask = recv_exact(4) if masked else b""
        payload = recv_exact(length)
        if masked:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        if opcode == 8:
            raise RuntimeError("CDP WebSocket closed")
        return payload.decode("utf-8")

    js = '''
(async () => {
  const frames = %s;
  const reconnectFrames = %s;
  const apiBase = "http://127.0.0.1:%d/api/v1/collab";
  const inviteToken = "invite-token";

  async function postJson(url, payload) {
    const response = await fetch(url, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify(payload),
    });
    const text = await response.text();
    if (!response.ok) return {status: response.status, error: text};
    return Object.assign({status: response.status}, text ? JSON.parse(text) : {});
  }

  async function startPeer(roomId, peerId, client, host) {
    const record = {
      roomId, peerId, client, host,
      pc: new RTCPeerConnection({iceServers: []}),
      channel: null,
      received: [],
      roomToken: "",
      remotePeerId: "",
      lastSignalSequence: 0,
      ready: false,
      events: [],
    };
    const roomUrl = () => apiBase + "/rooms/" + encodeURIComponent(roomId);
    const log = event => record.events.push(event);
    async function postSignal(kind, payload, toPeerId) {
      const signal = await postJson(roomUrl() + "/signals", {
        roomToken: record.roomToken,
        fromPeerId: peerId,
        toPeerId: toPeerId || record.remotePeerId || null,
        kind,
        payload,
      });
      if (signal.status !== 200) throw new Error(signal.error || "post signal failed");
      record.lastSignalSequence = Math.max(record.lastSignalSequence, signal.sequence || 0);
      log("post-" + kind);
    }
    function attach(channel) {
      record.channel = channel;
      channel.onopen = () => { record.ready = true; log("open"); };
      channel.onmessage = event => {
        record.received.push(String(event.data || ""));
        log("data");
      };
    }
    record.pc.onicecandidate = event => {
      if (event.candidate) {
        postSignal("candidate", event.candidate.toJSON ? event.candidate.toJSON() : event.candidate)
          .catch(error => log("candidate-error:" + error.message));
      }
    };
    if (host) attach(record.pc.createDataChannel("codetracer-viewops", {ordered: true}));
    else record.pc.ondatachannel = event => attach(event.channel);

    if (host) {
      const room = await postJson(apiBase + "/rooms", {
        inviteToken,
        roomId,
        peer: {peerId, principalId: "principal-" + peerId, actorId: "actor-" + peerId, replicaId: "replica-" + peerId},
        payload: {client, intent: "create-webrtc-room"},
      });
      if (room.acceptsViewOps) throw new Error("rendezvous accepted ViewOps");
      record.roomToken = room.roomToken;
      await record.pc.setLocalDescription(await record.pc.createOffer());
      await postSignal("offer", record.pc.localDescription.toJSON(), null);
    } else {
      const room = await postJson(roomUrl() + "/join", {
        inviteToken,
        peer: {peerId, principalId: "principal-" + peerId, actorId: "actor-" + peerId, replicaId: "replica-" + peerId},
        payload: {client, intent: "join-webrtc-room"},
      });
      if (room.acceptsViewOps) throw new Error("rendezvous accepted ViewOps");
      record.roomToken = room.roomToken;
      for (const peer of room.peers || []) {
        if (peer.peerId !== peerId) {
          record.remotePeerId = peer.peerId;
          break;
        }
      }
    }

    record.poll = async () => {
      const deadline = Date.now() + 10000;
      while (Date.now() < deadline && !record.ready) {
        const url = roomUrl() + "/signals?peerId=" + encodeURIComponent(peerId) +
          "&roomToken=" + encodeURIComponent(record.roomToken) +
          "&afterSequence=" + encodeURIComponent(String(record.lastSignalSequence));
        const response = await fetch(url);
        const payload = await response.json();
        if (payload.acceptsViewOps) throw new Error("rendezvous accepted ViewOps");
        for (const signal of payload.signals || []) {
          record.lastSignalSequence = Math.max(record.lastSignalSequence, signal.sequence || 0);
          if (signal.kind === "offer") {
            record.remotePeerId = signal.fromPeerId;
            await record.pc.setRemoteDescription(signal.payload);
            await record.pc.setLocalDescription(await record.pc.createAnswer());
            await postSignal("answer", record.pc.localDescription.toJSON(), record.remotePeerId);
          } else if (signal.kind === "answer") {
            record.remotePeerId = signal.fromPeerId;
            await record.pc.setRemoteDescription(signal.payload);
          } else if (signal.kind === "candidate") {
            record.remotePeerId = signal.fromPeerId || record.remotePeerId;
            await record.pc.addIceCandidate(signal.payload);
          }
        }
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      if (!record.ready) throw new Error("timed out waiting for " + peerId);
    };
    return record;
  }

  async function runPair(roomId, hostId, joinId, payloads) {
    const host = await startPeer(roomId, hostId, "webui", true);
    const join = await startPeer(roomId, joinId, "isonim-tui", false);
    await Promise.all([host.poll(), join.poll()]);
    for (const frame of payloads) host.channel.send(frame);
    const deadline = Date.now() + 5000;
    while (join.received.length < payloads.length && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    host.pc.close();
    join.pc.close();
    return {host, join};
  }

  const first = await runPair("m9-rendezvous-room", "webui", "isonim-tui", frames);
  let reconnect = {join: {received: [], events: []}, host: {events: []}};
  if (reconnectFrames.length > 0) {
    reconnect = await runPair("m9-rendezvous-room", "webui-r2", "isonim-tui-r2", reconnectFrames);
  }
  const rejected = await postJson(apiBase + "/rooms/m9-rendezvous-room/signals", {
    roomToken: first.host.roomToken,
    fromPeerId: "webui",
    toPeerId: "isonim-tui",
    kind: "offer",
    payload: {viewOp: {opId: "actor:bad", kind: "debugCommand"}},
  });
  return {
    ok: first.join.received.length === frames.length &&
      reconnect.join.received.length === reconnectFrames.length &&
      rejected.status === 400,
    received: first.join.received,
    reconnectReceived: reconnect.join.received,
    events: first.host.events.concat(first.join.events).concat(reconnect.host.events || []).concat(reconnect.join.events || []),
    rejectedViewOpStatus: rejected.status,
  };
})()
''' % (json.dumps(frames), json.dumps(reconnect_frames), rendezvous_port)
    send_ws_text(json.dumps({
        "id": 1,
        "method": "Runtime.evaluate",
        "params": {
            "expression": js,
            "awaitPromise": True,
            "returnByValue": True,
            "timeout": 30000,
        },
    }))
    while True:
        message = json.loads(recv_ws_text())
        if message.get("id") == 1:
            if "result" not in message:
                raise RuntimeError(json.dumps(message))
            if "exceptionDetails" in message:
                raise RuntimeError(json.dumps(message["exceptionDetails"]))
            result = message["result"]["result"]["value"]
            result["rendezvousAudit"] = rendezvous_audit
            print(json.dumps(result))
            break
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
    rendezvous_server.shutdown()
    rendezvous_server.server_close()
    shutil.rmtree(profile, ignore_errors=True)
"""
  try:
    writeFile(framesPath, $(%(@frames)))
    writeFile(reconnectPath, $(%(@reconnectFrames)))
    writeFile(runnerPath, runner)
    let cmd = "python3 " & quoteShell(runnerPath) & " " &
      quoteShell(chromium) & " " & quoteShell(framesPath) & " " &
      quoteShell(reconnectPath)
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      checkpoint "CDP WebRTC rendezvous harness failed:\n" & output
      raise newException(IOError, "CDP WebRTC rendezvous harness failed")
    result = parseJson(output.strip)
    check result{"ok"}.getBool(false)
  finally:
    removeDir(tempDir)

proc renderTuiProjection(harness: TerminalTestHarness;
                         adapter: FrontEndAdapter): string =
  let projection = adapter.projection
  harness.mount(proc(r: TerminalRenderer): TerminalNode =
    let root = r.createElement("div")
    r.setAttribute(root, "id", "m9-tui-root")
    let calltrace = r.createElement("div")
    r.setAttribute(calltrace, "id", "m9-tui-calltrace")
    r.appendChild(calltrace, r.createTextNode(
      "Calltrace selected=" & projection.calltraceSelectionId))
    r.appendChild(root, calltrace)
    let focus = r.createElement("div")
    r.setAttribute(focus, "id", "m9-tui-focus")
    r.appendChild(focus, r.createTextNode(
      "Focus panel=" & projection.focusedPanelId))
    r.appendChild(root, focus)
    root)
  harness.root.textContent

suite "M9 WebRTC collaboration transport":

  test "integration_collab_webrtc_transport_conformance":
    let op1 = sampleOp("actor-a", 1, 11)
    let op2 = sampleOp("actor-a", 2, 12)
    let reconnectOp = sampleOp("actor-a", 3, 13)
    let snapshot = initSharedSessionDocument(
      sessionId = "webrtc-conformance",
      traceIdentity = "trace",
      authorityPrincipalId = "principal-a",
      backendOwnerId = "principal-a").snapshot
    let backend = backendSnapshot(
      sessionId = "webrtc-conformance",
      backendOwnerId = "principal-a",
      emittedByPrincipalId = "principal-a",
      family = "debugger",
      backendEpoch = 1,
      payload = %*{"rrTicks": 44, "file": "trace.nim", "line": 7})

    let frames = @[
      encodeViewOpFrame("a", "b", op2),
      encodeViewOpFrame("a", "b", op1),
      encodeViewOpFrame("a", "b", op2),
      encodeJoinSnapshotFrame("a", "b", snapshot, @[op1]),
      encodeBackendSnapshotFrame("a", "b", backend),
    ]
    let payload = runRendezvousBackedWebRtc(frames, @[
      encodeViewOpFrame("a", "b", reconnectOp),
    ])
    var received: seq[string]
    for item in payload{"received"}.getElems:
      received.add item.getStr
    check received.len == frames.len
    check parseWebRtcFrame(received[0]).op.opId == op2.opId
    check parseWebRtcFrame(received[1]).op.opId == op1.opId
    check parseWebRtcFrame(received[2]).op.opId == op2.opId
    let join = parseWebRtcFrame(received[3])
    check join.kind == wrfkJoinSnapshot
    check join.tail.len == 1
    check join.tail[0].opId == op1.opId
    let backendFrame = parseWebRtcFrame(received[4])
    check backendFrame.kind == wrfkBackendSnapshot
    check backendFrame.backendSnapshot.family == "debugger"

    var receiver = createCollaborativeSessionCore(
      sessionId = "webrtc-conformance",
      traceIdentity = "trace",
      localPrincipalId = "principal-b",
      localActorId = "actor-b",
      localReplicaId = "replica-b",
      backendOwnerId = "principal-a")
    receiver.loadJoinSnapshot(snapshot)
    check receiver.applyWebRtcFrame(parseWebRtcFrame(received[0])).status != asRejected
    check receiver.applyWebRtcFrame(parseWebRtcFrame(received[1])).status != asRejected
    check receiver.applyWebRtcFrame(parseWebRtcFrame(received[2])).status == asDuplicate
    check receiver.document.state.calltrace.selectedEntry.value == "12"
    check receiver.applyWebRtcFrame(backendFrame).status == asApplied
    check receiver.document.state.backendSnapshots.len == 1

    var converged = createCollaborativeSessionCore(
      sessionId = "webrtc-conformance",
      traceIdentity = "trace",
      localPrincipalId = "principal-c",
      localActorId = "actor-c",
      localReplicaId = "replica-c",
      backendOwnerId = "principal-a")
    converged.loadJoinSnapshot(snapshot)
    discard converged.applyWebRtcFrame(parseWebRtcFrame(received[1]))
    discard converged.applyWebRtcFrame(parseWebRtcFrame(received[0]))
    check converged.document.state.calltrace.selectedEntry.value ==
      receiver.document.state.calltrace.selectedEntry.value
    expect ValueError:
      discard parseWebRtcFrame(%*{"protocol": "codetracer.collab.webrtc", "kind": "fault"})
    check fallbackDecision(true, "closed datachannel").shouldRetryRendezvous
    check payload{"reconnectReceived"}.getElems.len == 1
    check parseWebRtcFrame(payload{"reconnectReceived"}[0].getStr).op.opId ==
      reconnectOp.opId
    check payload{"rejectedViewOpStatus"}.getInt == 400
    let audit = payload{"rendezvousAudit"}
    check audit{"creates"}.getInt == 2
    check audit{"joins"}.getInt == 2
    check audit{"viewop_rejections"}.getInt == 1
    check "offer" in audit{"posts"}.getElems.mapIt(it.getStr)
    check "answer" in audit{"posts"}.getElems.mapIt(it.getStr)

  test "e2e_collab_webrtc_webui_tui_driver_session":
    let h = newM9Harness()
    var web = h.web
    var tui = h.tui
    let webAdapter = initWebUiCollabAdapter(web.principalId, web.actorId)
    let tuiAdapter = initIsoNimTuiCollabAdapter(tui.principalId, tui.actorId)
    web.core.installFrontEndAdapterProjection(webAdapter)
    tui.core.installFrontEndAdapterProjection(tuiAdapter)
    let selection = h.peerOp(web, vokSetCalltraceSelection,
      "calltrace.selectedEntry", %*{"entryId": "42"})
    let payload = runRendezvousBackedWebRtc(@[
      encodeViewOpFrame(web.peerId, tui.peerId, selection),
    ])
    var frames: seq[string]
    for item in payload{"received"}.getElems:
      frames.add item.getStr
    check frames.len == 1
    h.audit.recordDataChannel()
    let applyResult = tui.core.applyWebRtcFrame(parseWebRtcFrame(frames[0]))
    check applyResult.status != asRejected
    check tui.core.document.state.calltrace.selectedEntry.value == "42"
    check tuiAdapter.projection.calltraceSelectionId == "42"
    check webAdapter.projection.frontEndKind == cfkWebUI
    check tuiAdapter.projection.frontEndKind == cfkIsoNimTUI
    let tuiHarness = newTerminalTestHarness(80, 5)
    let visibleText = tuiHarness.renderTuiProjection(tuiAdapter)
    check "Calltrace selected=42" in visibleText
    check h.audit.dataChannelMessages == 1
    h.audit.rendezvousMessages = payload{"rendezvousAudit"}{"creates"}.getInt +
      payload{"rendezvousAudit"}{"joins"}.getInt +
      payload{"rendezvousAudit"}{"gets"}.getInt
    check h.audit.rendezvousMessages > 0
    check payload{"rejectedViewOpStatus"}.getInt == 400
    check not h.audit.rejectCiViewOpRelay()

    let unauthorizedDebug = h.peerOp(tui, vokDebugCommand,
      "debugger.commands",
      %*{"command": "next", "leaseId": "lease-web", "args": {"threadId": 1}})
    let rejectedBeforeHandoff = h.applyAuthority(unauthorizedDebug)
    check rejectedBeforeHandoff.status == asRejected

    h.grantDriver(tui.principalId, "lease-tui")
    let authorizedDebug = h.peerOp(tui, vokDebugCommand,
      "debugger.commands",
      %*{"command": "next", "leaseId": "lease-tui", "args": {"threadId": 1}})
    let acceptedAfterHandoff = h.applyAuthority(authorizedDebug)
    check acceptedAfterHandoff.status != asRejected

  test "security_collab_non_driver_webrtc_command_rejected":
    let h = newM9Harness()
    var tui = h.tui
    let forged = h.peerOp(tui, vokDebugCommand,
      "debugger.commands",
      %*{"command": "next", "leaseId": "lease-web", "args": {"threadId": 1}})
    let frame = parseWebRtcFrame(encodeViewOpFrame(tui.peerId, "authority", forged))
    let result = h.applyAuthority(frame.op)
    check result.status == asRejected
    check "active driver" in result.reason or "driver lease" in result.reason

  test "integration_collab_webrtc_fallback_keeps_ci_control_plane_only":
    let decision = fallbackDecision(true, "ice failed")
    let audit = WebRtcControlPlaneAudit()
    audit.recordRendezvous()
    check decision.directPeerFailed
    check decision.shouldRetryRendezvous
    check not decision.mayRelayViewOpsThroughCi
    check not audit.rejectCiViewOpRelay()
    check audit.rendezvousMessages == 1
    check audit.ciViewOpRelayAttempts == 1
    check acceptsWebRtcP2P(@[
      "control-plane-only",
      "viewops-not-accepted",
      "control-plane-rendezvous",
      "webrtc-datachannel",
      "p2p-viewops",
    ])
