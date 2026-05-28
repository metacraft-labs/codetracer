## M6 invite-bootstrap activation for collaborative ViewModel sessions.
##
## This module deliberately starts only the local collaboration session
## abstraction. CI remains a control plane: bootstrap/rendezvous metadata may
## arrive from CI, but normal ViewOps are loaded from snapshot/tail fields in
## the bootstrap document and are not posted back to CI.

import std/[json, strutils]

import ./[codec, reducer, session_core, types]
import ./transport/browser_channel

type
  CollabJoinActivation* = object
    activated*: bool
    roomId*: string
    replayId*: string
    traceIdentity*: string
    grants*: seq[string]
    snapshotInstalled*: bool
    tailApplied*: int
    tailRejected*: int
    transportStarted*: bool
    acceptsViewOpsThroughCi*: bool
    canDrive*: bool

proc grantToCapability(grant: string): tuple[ok: bool, cap: CapabilityKind] =
  case grant.strip
  of "observe":
    (true, capObserve)
  of "publishAwareness":
    (true, capPublishAwareness)
  of "mutateSharedViewState":
    (true, capMutateSharedViewState)
  of "controlDebugger":
    (true, capControlDebugger)
  of "manageBreakpoints":
    (true, capManageBreakpoints)
  of "manageWatches":
    (true, capManageWatches)
  of "manageLayout":
    (true, capManageLayout)
  of "grantCapabilities":
    (true, capGrantCapabilities)
  of "invite":
    (true, capInvite)
  of "exportSession":
    (true, capExportSession)
  of "hostBackend":
    (true, capHostBackend)
  else:
    (false, capObserve)

proc stringItems(node: JsonNode): seq[string] =
  if node.isNil or node.kind != JArray:
    return @[]
  for item in node:
    result.add item.getStr("")

proc transportHintsAcceptViewOps(hints: openArray[string]): bool =
  for hint in hints:
    if hint == "viewops-not-accepted":
      return false
  false

proc ensureDescriptor(state: var SharedSessionViewState;
                      principalId, actorId, replicaId: string) =
  if principalId.len > 0:
    var hasPrincipal = false
    for principal in state.principals:
      if principal.id == principalId:
        hasPrincipal = true
        break
    if not hasPrincipal:
      state.principals.add PrincipalDescriptor(
        id: principalId,
        kind: pkUser,
        displayName: principalId)

  if actorId.len > 0:
    var hasActor = false
    for actor in state.actors:
      if actor.id == actorId:
        hasActor = true
        break
    if not hasActor:
      state.actors.add ActorDescriptor(id: actorId, principalId: principalId)

  if replicaId.len > 0:
    var hasReplica = false
    for replica in state.replicas:
      if replica.id == replicaId:
        hasReplica = true
        break
    if not hasReplica:
      state.replicas.add ReplicaDescriptor(id: replicaId, actorId: actorId)

proc installInitialGrants(core: CollaborativeSessionCore;
                          grants: openArray[string]) =
  if core.isNil:
    return

  var capabilities: seq[CapabilityKind] = @[]
  for grant in grants:
    let mapped = grant.grantToCapability
    if mapped.ok:
      capabilities.add mapped.cap

  if capabilities.len == 0:
    return

  let grantId = "bootstrap:" & core.document.state.sessionId & ":" &
    core.localPrincipalId
  var existing = -1
  for i, grant in core.document.state.capabilityGrants:
    if grant.id == grantId:
      existing = i
      break

  let row = CapabilityGrant(
    id: grantId,
    subject: core.localPrincipalId,
    issuer: core.document.state.authority.principalId,
    capabilities: capabilities,
    targetPaths: @[""],
    addOpId: grantId,
    revokedByOpId: "")
  if existing >= 0:
    core.document.state.capabilityGrants[existing] = row
  else:
    core.document.state.capabilityGrants.add row

proc canDriveFromGrants(grants: openArray[string]): bool =
  "controlDebugger" in grants and "mutateSharedViewState" in grants

proc toJson*(activation: CollabJoinActivation): JsonNode =
  %*{
    "activated": activation.activated,
    "roomId": activation.roomId,
    "replayId": activation.replayId,
    "traceIdentity": activation.traceIdentity,
    "grants": activation.grants,
    "snapshotInstalled": activation.snapshotInstalled,
    "tailApplied": activation.tailApplied,
    "tailRejected": activation.tailRejected,
    "transportStarted": activation.transportStarted,
    "acceptsViewOpsThroughCi": activation.acceptsViewOpsThroughCi,
    "canDrive": activation.canDrive,
  }

proc startCollabHostSession*(core: CollaborativeSessionCore;
                             bootstrap: JsonNode): CollabJoinActivation =
  if core.isNil:
    raise newException(ValueError, "collaboration session core is missing")
  if bootstrap.isNil or bootstrap.kind != JObject:
    raise newException(ValueError, "collaboration host bootstrap must be a JSON object")

  let roomId = bootstrap{"roomId"}.getStr("")
  if roomId.len == 0:
    raise newException(ValueError, "collaboration host bootstrap is missing roomId")

  let traceIdentity = bootstrap{"traceIdentity"}.getStr(
    bootstrap{"traceId"}.getStr(""))
  let grants = stringItems(bootstrap{"initialGrants"})

  core.document = initSharedSessionDocument(
    sessionId = roomId,
    traceIdentity = traceIdentity,
    authorityPrincipalId = core.localPrincipalId,
    backendOwnerId = core.localPrincipalId)
  core.document.state.ensureDescriptor(
    core.localPrincipalId,
    core.localActorId,
    core.localReplicaId)
  core.installInitialGrants(grants)
  core.collaborationEnabled = true
  let started = core.startBrowserRoomTransport(roomId, host = true)
  if not started:
    core.peerTransportStarted = true
    core.remoteAwarenessStarted = true
    core.remoteGossipStarted = false
  core.projectCurrentState()

  result.activated = true
  result.roomId = roomId
  result.replayId = bootstrap{"replayId"}.getStr("")
  result.traceIdentity = traceIdentity
  result.grants = grants
  result.snapshotInstalled = true
  result.transportStarted = core.peerTransportStarted
  result.acceptsViewOpsThroughCi = false
  result.canDrive = true

proc startCollabJoinSession*(core: CollaborativeSessionCore;
                             bootstrap: JsonNode): CollabJoinActivation =
  if core.isNil:
    raise newException(ValueError, "collaboration session core is missing")
  if bootstrap.isNil or bootstrap.kind != JObject:
    raise newException(ValueError, "collaboration bootstrap must be a JSON object")

  let roomId = bootstrap{"roomId"}.getStr("")
  if roomId.len == 0:
    raise newException(ValueError, "collaboration bootstrap is missing roomId")

  let traceIdentity = bootstrap{"traceIdentity"}.getStr(
    bootstrap{"traceId"}.getStr(""))
  let grants = stringItems(bootstrap{"initialGrants"})
  let hints = stringItems(bootstrap{"transportHints"})
  core.localActorId = bootstrap{"actorId"}.getStr(
    "collab-guest-actor-" & core.localActorId)
  core.localReplicaId = bootstrap{"replicaId"}.getStr(
    "collab-guest-replica-" & core.localReplicaId)
  core.localPrincipalId = bootstrap{"principalId"}.getStr(
    "collab-guest-" & core.localReplicaId)

  if not bootstrap{"snapshot"}.isNil:
    core.loadJoinSnapshot(parseSharedSessionSnapshot(bootstrap{"snapshot"}))
    result.snapshotInstalled = true
  else:
    core.document = initSharedSessionDocument(
      sessionId = roomId,
      traceIdentity = traceIdentity,
      authorityPrincipalId = "ci-control-plane",
      backendOwnerId = "ci-control-plane")

  core.document.state.sessionId = roomId
  core.document.state.traceIdentity = traceIdentity
  core.document.state.authority.principalId =
    if core.document.state.authority.principalId.len == 0:
      "ci-control-plane"
    else:
      core.document.state.authority.principalId
  core.document.state.authority.backendOwnerId =
    if core.document.state.authority.backendOwnerId.len == 0:
      core.document.state.authority.principalId
    else:
      core.document.state.authority.backendOwnerId
  core.document.state.ensureDescriptor(
    core.localPrincipalId,
    core.localActorId,
    core.localReplicaId)
  core.installInitialGrants(grants)

  if not bootstrap{"tail"}.isNil and bootstrap{"tail"}.kind == JArray:
    for opNode in bootstrap{"tail"}:
      let applyResult = core.applyRemoteViewOp(parseViewOpEnvelope(opNode))
      if applyResult.status == asRejected:
        inc result.tailRejected
      else:
        inc result.tailApplied

  core.collaborationEnabled = true
  let started = core.startBrowserRoomTransport(roomId, host = false)
  if not started:
    core.peerTransportStarted = true
    core.remoteAwarenessStarted = true
    core.remoteGossipStarted = false
  core.projectCurrentState()

  result.activated = true
  result.roomId = roomId
  result.replayId = bootstrap{"replayId"}.getStr("")
  result.traceIdentity = traceIdentity
  result.grants = grants
  result.transportStarted = core.peerTransportStarted
  result.acceptsViewOpsThroughCi = transportHintsAcceptViewOps(hints)
  result.canDrive = canDriveFromGrants(grants)
