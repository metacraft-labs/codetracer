## Privacy-conscious collaboration telemetry event builders.
##
## Events intentionally avoid trace paths, source text, watch expressions,
## payload args, raw principal IDs, and raw peer IDs. Callers may submit the
## returned JSON to an environment-specific telemetry sink.

import std/[json, strutils]

import ./[authority, reducer, types]

type
  CollabTelemetryEventKind* = enum
    ctekConvergenceFailure,
    ctekRejectedCommand,
    ctekReconnectRecovery

  CollabTelemetryEvent* = object
    kind*: CollabTelemetryEventKind
    payload*: JsonNode

  CollabTelemetrySink* = proc(event: CollabTelemetryEvent) {.closure.}

proc fnv1a(value: string): string =
  var hash = 1469598103934665603'u64
  for ch in value:
    hash = hash xor uint64(ord(ch))
    hash = hash * 1099511628211'u64
  result = hash.toHex

proc redactedId*(value: string): string =
  if value.len == 0: "" else: "h:" & fnv1a(value)

proc reasonCode(reason: string): string =
  let normalized = reason.toLowerAscii
  if "capability" in normalized:
    "capability"
  elif "driver" in normalized or "lease" in normalized:
    "driver"
  elif "protocol" in normalized:
    "protocol"
  elif "session" in normalized:
    "session"
  elif "command" in normalized:
    "command"
  else:
    "other"

proc toJson*(event: CollabTelemetryEvent): JsonNode =
  %*{
    "kind": $event.kind,
    "payload": if event.payload.isNil: newJObject() else: event.payload,
  }

proc emit*(sink: CollabTelemetrySink; event: CollabTelemetryEvent) =
  if not sink.isNil:
    sink(event)

proc convergenceFailureEvent*(sessionId: string;
                              peerCount, acceptedOps, pendingOps: int;
                              stateDigest: string): CollabTelemetryEvent =
  CollabTelemetryEvent(
    kind: ctekConvergenceFailure,
    payload: %*{
      "sessionIdHash": redactedId(sessionId),
      "peerCount": peerCount,
      "acceptedOps": acceptedOps,
      "pendingOps": pendingOps,
      "stateDigest": redactedId(stateDigest),
    },
  )

proc rejectedCommandEvent*(sessionId: string;
                           op: ViewOpEnvelope;
                           applyResult: ApplyResult): CollabTelemetryEvent =
  CollabTelemetryEvent(
    kind: ctekRejectedCommand,
    payload: %*{
      "sessionIdHash": redactedId(sessionId),
      "principalIdHash": redactedId(op.principalId),
      "actorIdHash": redactedId(op.actorId),
      "opIdHash": redactedId(op.opId),
      "kind": $op.kind,
      "command": if op.kind == vokDebugCommand: op.debugCommandName else: "",
      "status": $applyResult.status,
      "reasonCode": reasonCode(applyResult.reason),
    },
  )

proc reconnectRecoveryEvent*(sessionId, peerId: string;
                             missedOps, recoveredOps: int;
                             converged: bool): CollabTelemetryEvent =
  CollabTelemetryEvent(
    kind: ctekReconnectRecovery,
    payload: %*{
      "sessionIdHash": redactedId(sessionId),
      "peerIdHash": redactedId(peerId),
      "missedOps": missedOps,
      "recoveredOps": recoveredOps,
      "converged": converged,
    },
  )
