## M10 telemetry and failure diagnostics export tests.
##
##   nim c -r src/frontend/viewmodel/tests/integration/test_collab_m10_diagnostics.nim

import std/[json, options, os, sequtils, strutils, unittest]

import ../../collab/[reducer, runtime_role, telemetry, types]
import collab_headless_harness

proc telemetryPayload(events: openArray[CollabTelemetryEvent];
                      kind: CollabTelemetryEventKind): JsonNode =
  for event in events:
    if event.kind == kind:
      return event.payload
  newJObject()

suite "collaborative ViewModel M10 diagnostics":

  test "e2e_collab_export_protocol_log_on_failure":
    let outputRoot = getTempDir() / "ct-collab-m10-diagnostics-test"
    if dirExists(outputRoot):
      removeDir(outputRoot)

    let harness = newCollabHeadlessHarness(sessionId = "m10-diagnostics")
    try:
      discard harness.addPeer("owner", vrrBackendOwner,
        principalId = harness.authorityPrincipalId)
      discard harness.addPeer("peer-b", vrrCollaborator)
      harness.grantAllCollaborators()
      harness.deliverAll()

      let peerB = harness.findPeer("peer-b")
      let stalePeerSnapshot = harness.currentAuthoritySnapshot
      let unauthorized = harness.forgedOp(
        principalId = peerB.principalId,
        actorId = peerB.actorId,
        opId = "peer-b-debug-without-driver",
        kind = vokDebugCommand,
        targetPath = "debugger.commands",
        payload = %*{
          "command": "next",
          "leaseId": "missing-lease",
          "args": {"threadId": 1},
        },
      )
      let rejected = harness.submitToAuthority("peer-b", unauthorized)
      check rejected.status == asRejected
      check harness.telemetryEvents.anyIt(it.kind == ctekRejectedCommand)
      let rejectedTelemetry = harness.telemetryEvents.telemetryPayload(
        ctekRejectedCommand)
      let rejectedTelemetryText = $rejectedTelemetry
      check rejectedTelemetry["principalIdHash"].getStr.startsWith("h:")
      check rejectedTelemetry["actorIdHash"].getStr.startsWith("h:")
      check rejectedTelemetry["opIdHash"].getStr.startsWith("h:")
      check rejectedTelemetry["reasonCode"].getStr == "capability"
      check "principal-peer-b" notin rejectedTelemetryText
      check "actor-peer-b" notin rejectedTelemetryText
      check "peer-b-debug-without-driver" notin rejectedTelemetryText
      check "missing-lease" notin rejectedTelemetryText
      check "threadId" notin rejectedTelemetryText

      harness.disconnectPeer("peer-b")
      harness.selectCalltrace("owner", some(123'i64))
      harness.deliverAll()
      check not harness.allPeerStatesMatchAuthority
      harness.recordConvergenceFailure()
      check harness.telemetryEvents.anyIt(it.kind == ctekConvergenceFailure)
      let convergenceTelemetry = harness.telemetryEvents.telemetryPayload(
        ctekConvergenceFailure)
      let convergenceTelemetryText = $convergenceTelemetry
      check convergenceTelemetry["sessionIdHash"].getStr.startsWith("h:")
      check convergenceTelemetry["stateDigest"].getStr.startsWith("h:")
      check "m10-diagnostics" notin convergenceTelemetryText
      check "headless-trace" notin convergenceTelemetryText
      check "calltrace" notin convergenceTelemetryText

      harness.reconnectPeer("peer-b")
      harness.enqueueJoin("peer-b", stalePeerSnapshot)
      harness.deliverAll()
      check harness.telemetryEvents.anyIt(it.kind == ctekReconnectRecovery)
      let reconnectTelemetry = harness.telemetryEvents.telemetryPayload(
        ctekReconnectRecovery)
      let reconnectTelemetryText = $reconnectTelemetry
      check reconnectTelemetry["peerIdHash"].getStr.startsWith("h:")
      check reconnectTelemetry["missedOps"].getInt >= 1
      check reconnectTelemetry["recoveredOps"].getInt >= 1
      check "peer-b" notin reconnectTelemetryText

      let exported = harness.exportFailureArtifacts(
        outputRoot,
        "e2e_collab_export_protocol_log_on_failure",
      )
      check fileExists(exported.protocolLogPath)
      check fileExists(exported.snapshotPath)
      check fileExists(exported.manifestPath)
      check exported.artifactPaths.len == 3

      let protocolLog = readFile(exported.protocolLogPath)
      let snapshotJson = parseJson(readFile(exported.snapshotPath))
      let manifest = parseJson(readFile(exported.manifestPath))

      check "authority asRejected peer-b-debug-without-driver" in protocolLog
      check snapshotJson["state"]["sessionId"].getStr == "m10-diagnostics"
      check snapshotJson["appliedOpIds"].getElems.len > 0
      check "protocol.log" in manifest["artifacts"].getElems.mapIt(it.getStr)
      check "SharedSessionSnapshot.json" in
        manifest["artifacts"].getElems.mapIt(it.getStr)
      check "source text" in manifest["privacy"]["snapshot"].getStr
    finally:
      harness.dispose()
      if dirExists(outputRoot):
        removeDir(outputRoot)
