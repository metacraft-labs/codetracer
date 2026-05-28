## M10 mixed-version compatibility tests.
##
##   nim c -r src/frontend/viewmodel/tests/integration/test_collab_m10_compat.nim

import std/[json, unittest]

import ../../collab/[codec, compat, reducer, runtime_role, types]
import collab_headless_harness

proc futureSafeSelectionJson(sessionId: string): JsonNode =
  %*{
    "protocolVersion": CurrentCollabProtocolVersion,
    "sessionId": sessionId,
    "principalId": "principal-owner",
    "actorId": "actor-newer-peer",
    "replicaId": "replica-newer-peer",
    "actorSeq": 1,
    "opId": "actor-newer-peer:1",
    "lamport": 1,
    "capabilityIds": [],
    "targetPath": "calltrace.selectedEntry",
    "kind": "vokSetCalltraceSelection",
    "payload": {
      "entryId": "37",
      "futurePayloadField": {
        "safe": true,
        "schemaVersion": CurrentCollabSchemaVersion + 1,
      },
    },
    "futureEnvelopeField": {
      "preserve": true,
      "writerProtocolVersion": CurrentCollabProtocolVersion + 1,
    },
    "futureScalar": "kept",
  }

suite "collaborative ViewModel M10 compatibility":

  test "integration_collab_mixed_version_unknown_fields_preserved":
    let harness = newCollabHeadlessHarness(sessionId = "m10-compat")
    try:
      discard harness.addPeer("owner", vrrBackendOwner,
        principalId = harness.authorityPrincipalId)
      discard harness.addPeer("peer-b", vrrCollaborator)
      harness.grantAllCollaborators()
      harness.deliverAll()

      let newerWire = futureSafeSelectionJson(harness.sessionId)
      let forwardedWire = forwardCompatibleViewOpJson(newerWire)
      assertSafeUnknownFieldsPreserved(newerWire, forwardedWire)
      check compatibilityDecision(newerWire).kind == cdkApplyLocally

      let op = parseViewOpEnvelope(forwardedWire)
      let result = harness.submitToAuthority("older-peer", op)
      harness.deliverAll()

      check result.status == asApplied
      check harness.acceptedLog.len >= 2
      let acceptedWire = harness.acceptedLog[^1].toJson
      check acceptedWire["futureEnvelopeField"]["preserve"].getBool
      check acceptedWire["futureScalar"].getStr == "kept"
      check acceptedWire["payload"]["futurePayloadField"]["safe"].getBool
      check harness.findPeer("peer-b").session.collabCore.document.state.
        calltrace.selectedEntry.value == "37"
      check harness.allPeerStatesMatchAuthority

      var futureProtocol = newerWire
      futureProtocol["protocolVersion"] = %(CurrentCollabProtocolVersion + 1)
      let decision = compatibilityDecision(futureProtocol)
      check decision.kind == cdkForwardOnly
      check decision.unknownFieldCount >= 2
      assertSafeUnknownFieldsPreserved(
        futureProtocol,
        forwardCompatibleViewOpJson(futureProtocol))
    finally:
      harness.dispose()
