## M10 deterministic long-run collaboration soak.
##
## Default duration is short for CI. Set CT_COLLAB_SOAK_SECONDS=3600 to run the
## one-hour variant:
##
##   CT_COLLAB_SOAK_SECONDS=3600 nim c -r src/frontend/viewmodel/tests/soak/test_collab_soak.nim

import std/[options, os, random, strutils, times, unittest]

import ../../collab/runtime_role
import ../../viewmodels/state_vm
import ../integration/collab_headless_harness

proc soakSeconds(): float =
  let raw = getEnv("CT_COLLAB_SOAK_SECONDS", "2")
  try:
    max(0.2, raw.parseFloat)
  except ValueError:
    2.0

proc chooseConnectedPeer(rng: var Rand;
                         peerIds: openArray[string];
                         connected: openArray[bool]): int =
  for _ in 0 ..< 16:
    let index = rng.rand(peerIds.high)
    if connected[index]:
      return index
  for i, isConnected in connected:
    if isConnected:
      return i
  0

proc driveRandomOperation(harness: CollabHeadlessHarness;
                          rng: var Rand;
                          peerId: string;
                          opIndex: int) =
  case rng.rand(4)
  of 0:
    harness.selectCalltrace(peerId, some(int64(rng.rand(500))))
  of 1:
    harness.toggleCalltrace(peerId, int64(rng.rand(60)))
  of 2:
    harness.toggleStatePath(peerId, "frame.locals.value" & $rng.rand(40))
  of 3:
    let tab =
      case rng.rand(2)
      of 0: stLocals
      of 1: stGlobals
      else: stWatches
    harness.selectStateTab(peerId, tab)
  else:
    harness.addWatch(peerId, "soak_watch_" & $(opIndex mod 80))

suite "collaborative ViewModel M10 soak":

  test "soak_collab_randomized_three_peer_session_one_hour":
    let configuredSeconds = soakSeconds()
    var rng = initRand(0xC011AB)
    let harness = newCollabHeadlessHarness(sessionId = "m10-soak")
    try:
      let peerIds = @["owner", "peer-b", "peer-c"]
      var connected = @[true, true, true]
      discard harness.addPeer("owner", vrrBackendOwner,
        principalId = harness.authorityPrincipalId)
      discard harness.addPeer("peer-b", vrrCollaborator)
      discard harness.addPeer("peer-c", vrrCollaborator)
      harness.grantAllCollaborators()
      harness.deliverAll()

      var operations = 0
      var churns = 0
      var reconnects = 0

      harness.disconnectPeer("peer-c")
      connected[2] = false
      inc churns
      harness.selectCalltrace("owner", some(1'i64))
      harness.deliverAll()
      harness.reconnectPeer("peer-c")
      connected[2] = true
      harness.enqueueCurrentJoin("peer-c")
      harness.deliverAll()
      inc reconnects

      let deadline = epochTime() + configuredSeconds
      while epochTime() < deadline:
        let roll = rng.rand(99)
        if roll < 68:
          let peerIndex = chooseConnectedPeer(rng, peerIds, connected)
          harness.driveRandomOperation(rng, peerIds[peerIndex], operations)
          inc operations
        elif roll < 80:
          let peerIndex = rng.rand(peerIds.high)
          if connected[peerIndex]:
            harness.disconnectPeer(peerIds[peerIndex])
            connected[peerIndex] = false
            inc churns
        elif roll < 94:
          let peerIndex = rng.rand(peerIds.high)
          if not connected[peerIndex]:
            harness.reconnectPeer(peerIds[peerIndex])
            connected[peerIndex] = true
            harness.enqueueCurrentJoin(peerIds[peerIndex])
            inc reconnects
        else:
          harness.duplicateAllPending()

        if rng.rand(1) == 0:
          harness.deliverAll()
        else:
          harness.deliverReverse()
        sleep(5)

      for i, isConnected in connected:
        if not isConnected:
          harness.reconnectPeer(peerIds[i])
          connected[i] = true
          harness.enqueueCurrentJoin(peerIds[i])
          inc reconnects
      for peerId in peerIds:
        harness.enqueueCurrentJoin(peerId)
      harness.deliverAll()

      if not harness.allPeerStatesMatchAuthority or
          not harness.allProjectedSignalsMatch:
        harness.recordConvergenceFailure()
        echo harness.protocolDump()

      check operations >= 20
      check churns >= 1
      check reconnects >= 1
      check harness.allPeerStatesMatchAuthority
      check harness.allProjectedSignalsMatch
      check harness.telemetryEvents.len >= 1
    finally:
      harness.dispose()
