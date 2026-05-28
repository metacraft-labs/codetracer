## M6 same-origin browser collaboration transport.
##
## This is intentionally a browser-local transport for WebUI invite E2E
## coverage. CI remains the control plane; normal ViewOps and join
## snapshot/tail messages move through BroadcastChannel.

import std/json

import ../[codec, session_core, types]

when defined(js):
  import ../reducer

  proc startChannel(roomId, peerId: cstring;
                    onMessage: proc(raw: cstring) {.closure.}): bool {.
    importjs: """
      (function(roomId, peerId, onMessage) {
        if (typeof BroadcastChannel === "undefined") return false;
        window.CODETRACER_COLLAB_TRANSPORT_LOG =
          window.CODETRACER_COLLAB_TRANSPORT_LOG || [];
        window.__ctCollabChannels = window.__ctCollabChannels || {};

        const key = String(roomId || "");
        if (!key) return false;
        if (window.__ctCollabChannels[key]) {
          try { window.__ctCollabChannels[key].close(); } catch (_error) {}
        }

        const channelName = "codetracer-collab-" + key;
        const channel = new BroadcastChannel(channelName);
        const record = {
          roomId: key,
          peerId: String(peerId || ""),
          channel,
          sent: [],
          received: []
        };
        window.__ctCollabChannels[key] = record;

        channel.onmessage = function(event) {
          const message = event && event.data ? event.data : {};
          if (message.fromPeerId === record.peerId) return;
          if (message.roomId !== key) return;
          record.received.push(message);
          window.CODETRACER_COLLAB_TRANSPORT_LOG.push({
            direction: "receive",
            roomId: key,
            peerId: record.peerId,
            kind: message.kind,
            fromPeerId: message.fromPeerId || ""
          });
          onMessage(JSON.stringify(message));
        };

        const join = {
          kind: "join",
          roomId: key,
          fromPeerId: record.peerId
        };
        record.sent.push(join);
        window.CODETRACER_COLLAB_TRANSPORT_LOG.push({
          direction: "send",
          roomId: key,
          peerId: record.peerId,
          kind: "join"
        });
        setTimeout(function() { channel.postMessage(join); }, 0);
        return true;
      })(#, #, #)
    """.}

  proc publishChannel(roomId, peerId, raw: cstring): bool {.importjs: """
    (function(roomId, peerId, raw) {
      const key = String(roomId || "");
      const channels = window.__ctCollabChannels || {};
      const record = channels[key];
      if (!record || !record.channel) return false;

      const message = JSON.parse(String(raw || "{}"));
      message.roomId = key;
      message.fromPeerId = String(peerId || record.peerId || "");
      record.sent.push(message);
      window.CODETRACER_COLLAB_TRANSPORT_LOG =
        window.CODETRACER_COLLAB_TRANSPORT_LOG || [];
      window.CODETRACER_COLLAB_TRANSPORT_LOG.push({
        direction: "send",
        roomId: key,
        peerId: record.peerId,
        kind: message.kind,
        opId: message.op && message.op.opId || ""
      });
      record.channel.postMessage(message);
      return true;
    })(#, #, #)
  """.}

  proc recordTransportApply(kind, status: cstring) {.importjs: """
    (function(kind, status) {
      window.CODETRACER_COLLAB_TRANSPORT_APPLY =
        window.CODETRACER_COLLAB_TRANSPORT_APPLY || [];
      window.CODETRACER_COLLAB_TRANSPORT_APPLY.push({
        kind: String(kind || ""),
        status: String(status || "")
      });
    })(#, #)
  """.}

proc viewOpArray(ops: openArray[ViewOpEnvelope]): JsonNode =
  result = newJArray()
  for op in ops:
    result.add op.toJson

proc publishSnapshotTail(core: CollaborativeSessionCore; roomId, peerId: string): bool =
  when defined(js):
    let snapshot =
      if core.hasTransportSnapshotBase:
        core.transportSnapshotBase
      else:
        core.joinSnapshot
    let message = %*{
      "kind": "snapshotTail",
      "snapshot": snapshot.toJson,
      "tail": viewOpArray(core.localOperationLog),
    }
    publishChannel(cstring(roomId), cstring(peerId), cstring($message))
  else:
    false

proc publishViewOp(roomId, peerId: string; op: ViewOpEnvelope): bool =
  when defined(js):
    let message = %*{
      "kind": "viewop",
      "op": op.toJson,
    }
    publishChannel(cstring(roomId), cstring(peerId), cstring($message))
  else:
    false

proc startBrowserRoomTransport*(core: CollaborativeSessionCore;
                                roomId: string;
                                host: bool): bool =
  if core.isNil or roomId.len == 0:
    return false

  let peerId = core.localReplicaId
  core.transportSnapshotBase = core.joinSnapshot
  core.hasTransportSnapshotBase = true
  core.publishLocalViewOp = proc(op: ViewOpEnvelope): bool =
    publishViewOp(roomId, peerId, op)

  when defined(js):
    result = startChannel(cstring(roomId), cstring(peerId),
      proc(raw: cstring) {.closure.} =
        try:
          let message = parseJson($raw)
          case message{"kind"}.getStr("")
          of "join":
            if host:
              discard core.publishSnapshotTail(roomId, peerId)
          of "snapshotTail":
            var localGrants: seq[CapabilityGrant] = @[]
            for grant in core.document.state.capabilityGrants:
              if grant.subject == core.localPrincipalId and
                  grant.revokedByOpId.len == 0:
                localGrants.add grant
            core.loadJoinSnapshot(parseSharedSessionSnapshot(message{"snapshot"}))
            for grant in localGrants:
              var exists = false
              for existing in core.document.state.capabilityGrants:
                if existing.id == grant.id:
                  exists = true
                  break
              if not exists:
                core.document.state.capabilityGrants.add grant
            var applied = 0
            var rejected = 0
            for opNode in message{"tail"}.getElems(@[]):
              let applyResult = core.applyRemoteViewOp(parseViewOpEnvelope(opNode))
              if applyResult.status == asRejected:
                inc rejected
              else:
                inc applied
            recordTransportApply(cstring"snapshotTail",
              cstring("applied=" & $applied & ";rejected=" & $rejected))
          of "viewop":
            let applyResult = core.applyRemoteViewOp(
              parseViewOpEnvelope(message{"op"}))
            recordTransportApply(cstring"viewop", cstring($applyResult.status))
          else:
            discard
        except CatchableError as e:
          recordTransportApply(cstring"error", cstring(e.msg)))
  else:
    result = false

  if result:
    core.peerTransportStarted = true
    core.remoteAwarenessStarted = true
    core.remoteGossipStarted = false
