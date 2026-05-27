## M3 same-process headless collaboration integration tests.
##
##   nim c -r src/frontend/viewmodel/tests/integration/test_collab_headless.nim

import std/[json, options, sequtils, sets, unittest]

import isonim/core/signals

import ../../backend/mock_backend
import ../../collab/[authority, reducer, runtime_role, types]
import ../../viewmodels/state_vm
import collab_headless_harness

proc makeTwoPeerHarness(): CollabHeadlessHarness =
  result = newCollabHeadlessHarness()
  discard result.addPeer("owner", vrrBackendOwner,
    principalId = result.authorityPrincipalId)
  discard result.addPeer("peer-b", vrrCollaborator)
  result.grantAllCollaborators()
  result.deliverAll()

proc makeThreePeerHarness(): CollabHeadlessHarness =
  result = makeTwoPeerHarness()
  discard result.addPeer("peer-c", vrrCollaborator)
  result.grantPeerCapabilities("peer-c")
  result.deliverAll()

proc checkConverged(harness: CollabHeadlessHarness) =
  if not harness.allPeerStatesMatchAuthority or
      not harness.allProjectedSignalsMatch:
    echo harness.protocolDump()
  check harness.allPeerStatesMatchAuthority
  check harness.allProjectedSignalsMatch

suite "collaborative ViewModel M3 headless peers":

  test "test_headless_two_peers_share_calltrace_selection":
    let harness = makeTwoPeerHarness()
    try:
      harness.selectCalltrace("owner", some(42'i64))
      harness.deliverAll()

      let peerB = harness.findPeer("peer-b")
      check peerB.session.calltraceVM.selectedEntry.val == some(42'i64)
      check harness.authorityDocument.state.calltrace.selectedEntry.value == "42"
      checkConverged(harness)
    finally:
      harness.dispose()

  test "test_headless_two_peers_converge_expansion_and_watches":
    let harness = makeTwoPeerHarness()
    try:
      harness.toggleCalltrace("owner", 10)
      harness.toggleStatePath("peer-b", "frame.locals.counter")
      harness.addWatch("owner", "counter + 1")
      harness.addWatch("peer-b", "frame.locals.counter")
      harness.deliverReverse()

      let owner = harness.findPeer("owner")
      check 10'i64 in owner.session.calltraceVM.expandedNodes.val
      check "frame.locals.counter" in owner.session.stateVM.expandedPaths.val
      check owner.session.stateVM.watchExpressions.val ==
        @["counter + 1", "frame.locals.counter"]
      checkConverged(harness)
    finally:
      harness.dispose()

  test "test_headless_join_snapshot_then_ops_reaches_same_state":
    let harness = makeTwoPeerHarness()
    try:
      harness.selectCalltrace("owner", some(7'i64))
      harness.deliverAll()
      let joinBase = harness.currentAuthoritySnapshot()

      harness.addWatch("owner", "tailWatch")
      discard harness.addPeer("peer-c", vrrCollaborator, joinNow = false)
      harness.disconnectPeer("peer-c")
      harness.enqueueJoin("peer-c", joinBase)
      harness.deliverAll()
      check harness.findPeer("peer-c").session.stateVM.watchExpressions.val.len == 0

      harness.reconnectPeer("peer-c")
      harness.enqueueJoin("peer-c", joinBase)
      harness.deliverAll()

      let peerC = harness.findPeer("peer-c")
      check peerC.session.calltraceVM.selectedEntry.val == some(7'i64)
      check peerC.session.stateVM.watchExpressions.val == @["tailWatch"]
      checkConverged(harness)
    finally:
      harness.dispose()

  test "test_headless_three_peers_duplicate_delivery_converges":
    let harness = makeThreePeerHarness()
    try:
      harness.toggleCalltrace("owner", 12)
      harness.addWatch("peer-b", "b.value")
      harness.selectCalltrace("peer-c", some(99'i64))
      harness.duplicateAllPending()
      harness.deliverReverse()

      check harness.pendingCount == 0
      check harness.authorityDocument.appliedOpIds.len ==
        harness.acceptedLog.len
      checkConverged(harness)
    finally:
      harness.dispose()

  test "test_headless_operation_log_replay_matches_live_state":
    let harness = makeThreePeerHarness()
    try:
      harness.selectCalltrace("owner", some(5'i64))
      harness.toggleStatePath("peer-b", "root.child")
      harness.addWatch("peer-c", "root.child")
      harness.deliverAll()

      let replayed = harness.replayAcceptedLog()
      if replayed.state.canonicalState != harness.canonicalAuthorityState:
        echo harness.protocolDump()
      check replayed.state.canonicalState == harness.canonicalAuthorityState
      checkConverged(harness)
    finally:
      harness.dispose()

  test "test_headless_snapshot_plus_tail_matches_full_log":
    let harness = makeTwoPeerHarness()
    try:
      harness.selectCalltrace("owner", some(1'i64))
      harness.deliverAll()
      let snapshot = harness.currentAuthoritySnapshot()

      harness.addWatch("peer-b", "tail.one")
      harness.toggleStatePath("owner", "tail.path")
      harness.deliverAll()

      let full = harness.replayAcceptedLog()
      let fromSnapshot = harness.replaySnapshotPlusTail(snapshot)
      if fromSnapshot.state.canonicalState != full.state.canonicalState:
        echo harness.protocolDump()
      check fromSnapshot.state.canonicalState == full.state.canonicalState
      check fromSnapshot.state.canonicalState == harness.canonicalAuthorityState
      checkConverged(harness)
    finally:
      harness.dispose()

  test "test_headless_rejected_ops_do_not_enter_accepted_log":
    let harness = newCollabHeadlessHarness()
    try:
      discard harness.addPeer("owner", vrrBackendOwner,
        principalId = harness.authorityPrincipalId)
      harness.deliverAll()
      let beforeState = harness.canonicalAuthorityState
      let beforeAccepted = harness.acceptedLog.len
      let unauthorized = harness.forgedOp(
        principalId = "principal-intruder",
        actorId = "actor-intruder",
        opId = "intruder:1",
        kind = vokSetCalltraceSelection,
        targetPath = "calltrace.selectedEntry",
        payload = %*{"entryId": "666"},
      )

      let result = harness.submitToAuthority("intruder", unauthorized)
      harness.deliverAll()

      check result.status == asRejected
      check harness.acceptedLog.len == beforeAccepted
      check harness.rejectionDiagnostics.len == 1
      check not harness.acceptedLog.containsOp("intruder:1")
      check harness.canonicalAuthorityState == beforeState
      check harness.pendingCount == 0
    finally:
      harness.dispose()

  test "integration_collab_mock_backend_step_broadcasts_debugger_snapshot":
    let harness = makeTwoPeerHarness()
    try:
      let peerB = harness.findPeer("peer-b")
      harness.grantPeerCapabilities(
        peerB,
        capabilities = @[capControlDebugger],
        targetPaths = @["activeDriver", "debugger.commands"])
      harness.deliverAll()

      let grantDriver = harness.forgedOp(
        principalId = harness.authorityPrincipalId,
        actorId = harness.authorityActorId,
        opId = "authority-grant-driver-peer-b",
        kind = vokGrantDriver,
        targetPath = "activeDriver",
        payload = %*{
          "principalId": peerB.principalId,
          "leaseId": "lease-peer-b",
        })
      check harness.submitToAuthority("authority", grantDriver).status == asApplied
      harness.deliverAll()
      harness.findPeer("owner").mockBackend.clearReceivedCommands()

      var step = harness.forgedOp(
        principalId = peerB.principalId,
        actorId = peerB.actorId,
        opId = "peer-b-step-next",
        kind = vokDebugCommand,
        targetPath = "debugger.commands",
        payload = %*{
          "command": "next",
          "leaseId": "lease-peer-b",
          "args": {"threadId": 1},
        })
      step.capabilityIds = @["grant-" & peerB.id]

      let result = harness.submitToAuthority(peerB.id, step)
      harness.deliverAll()

      check result.status != asRejected
      check harness.backendCommandAuthority.acceptedCommands.len == 1
      check harness.backendCommandAuthority.acceptedCommands[0].command == "next"
      let stepCommands = harness.findPeer("owner").mockBackend.receivedCommands.
        filterIt(it.command == "next")
      check stepCommands.len == 1
      check harness.authorityDocument.state.backendSnapshots.len == 1
      check harness.authorityDocument.state.backendSnapshots[0].family == "debugger"
      check harness.authorityDocument.state.backendSnapshots[0].backendEpoch == 1'u64
      check harness.findPeer("owner").session.store.debugger.val.rrTicks == 1'u64
      check peerB.session.store.debugger.val.rrTicks == 1'u64
      checkConverged(harness)
      check harness.backendCommandAuthority.auditLog[^1].kind == aekDebugCommandAccepted
    finally:
      harness.dispose()
