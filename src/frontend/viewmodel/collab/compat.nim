## Compatibility helpers for mixed-version collaboration sessions.
##
## The reducer remains intentionally strict about applying unsupported protocol
## versions. These helpers cover the other half of compatibility: older peers
## may parse, log, and forward future-safe envelope metadata without dropping
## it, even when they do not understand the field yet.

import std/json

import ./[codec, types]

type
  CompatibilityDecisionKind* = enum
    cdkApplyLocally,
    cdkForwardOnly,
    cdkReject

  CompatibilityDecision* = object
    kind*: CompatibilityDecisionKind
    reason*: string
    protocolVersion*: int
    unknownFieldCount*: int

const KnownEnvelopeFieldsForCompat = [
  "protocolVersion", "sessionId", "principalId", "actorId", "replicaId",
  "actorSeq", "opId", "lamport", "capabilityIds", "targetPath", "kind",
  "payload"
]

proc unknownEnvelopeFieldCount*(node: JsonNode): int =
  if node.isNil or node.kind != JObject:
    return 0
  for key, _ in node:
    if key notin KnownEnvelopeFieldsForCompat:
      inc result

proc isSafeUnknownEnvelopeField*(key: string; value: JsonNode): bool =
  ## Safe means the field cannot shadow a known envelope key and can be
  ## round-tripped as JSON. Privacy policy is enforced by telemetry/export code,
  ## not by the wire codec, because dropping wire data would break forwarding.
  key.len > 0 and key notin KnownEnvelopeFieldsForCompat and not value.isNil

proc preservesSafeUnknownEnvelopeFields*(before, after: JsonNode): bool =
  if before.isNil or before.kind != JObject:
    return true
  if after.isNil or after.kind != JObject:
    return false
  for key, value in before:
    if key.isSafeUnknownEnvelopeField(value):
      if after{key}.isNil or after{key} != value:
        return false
  true

proc compatibilityDecision*(node: JsonNode): CompatibilityDecision =
  let version = node{"protocolVersion"}.getInt(CurrentCollabProtocolVersion)
  result = CompatibilityDecision(
    protocolVersion: version,
    unknownFieldCount: node.unknownEnvelopeFieldCount,
  )
  if version == CurrentCollabProtocolVersion:
    result.kind = cdkApplyLocally
    result.reason = "current protocol"
  elif version > CurrentCollabProtocolVersion:
    result.kind = cdkForwardOnly
    result.reason = "future protocolVersion"
  else:
    result.kind = cdkReject
    result.reason = "older unsupported protocolVersion"

proc forwardCompatibleViewOpJson*(node: JsonNode): JsonNode =
  ## Parse and re-emit through the local envelope type. This is the path an
  ## older peer exercises when it receives future-safe metadata and forwards the
  ## operation through logs, transports, or diagnostics.
  parseViewOpEnvelope(node).toJson

proc assertSafeUnknownFieldsPreserved*(before, after: JsonNode) =
  if not preservesSafeUnknownEnvelopeFields(before, after):
    raise newException(ValueError,
      "safe unknown collaboration envelope fields were not preserved")

proc protocolVersionLabel*(version: int): string =
  if version == CurrentCollabProtocolVersion:
    "current"
  elif version > CurrentCollabProtocolVersion:
    "future+" & $(version - CurrentCollabProtocolVersion)
  else:
    "legacy-" & $(CurrentCollabProtocolVersion - version)
