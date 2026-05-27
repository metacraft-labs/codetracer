## Local collaborative ViewModel session runtime.
##
## M2 intentionally keeps this runtime transport-free. It owns the shared
## document, creates local ViewOps for migrated actions, applies them through
## the M1 reducer, and notifies projection adapters in-process.

import std/[json, options]

import ./[reducer, types]

type
  ProjectionCallback* = proc(state: SharedSessionViewState)

  LocalViewOpDispatch* = object
    op*: ViewOpEnvelope
    result*: ApplyResult
    localOnly*: bool
    publishedToPeer*: bool

  CollaborativeSessionCore* = ref object
    document*: SharedSessionDocument
    localActorId*: ActorId
    localReplicaId*: SessionReplicaId
    localPrincipalId*: PrincipalId
    actorSeq*: uint64
    lamport*: uint64
    localOperationLog*: seq[ViewOpEnvelope]
    dispatchLog*: seq[LocalViewOpDispatch]
    projectionCallbacks*: seq[ProjectionCallback]
    collaborationEnabled*: bool
    peerTransportStarted*: bool
    remoteAwarenessStarted*: bool
    remoteGossipStarted*: bool

proc createCollaborativeSessionCore*(
    sessionId = "local-session";
    traceIdentity = "";
    localPrincipalId = "local-user";
    localActorId = "local-actor";
    localReplicaId = "local-replica";
    backendOwnerId = "local-user"): CollaborativeSessionCore =
  ## Create a local-only collaboration core. The local principal is the
  ## document authority by default, so normal single-user actions can be
  ## reduced without a separate capability grant.
  CollaborativeSessionCore(
    document: initSharedSessionDocument(
      sessionId = sessionId,
      traceIdentity = traceIdentity,
      authorityPrincipalId = localPrincipalId,
      backendOwnerId = backendOwnerId,
    ),
    localPrincipalId: localPrincipalId,
    localActorId: localActorId,
    localReplicaId: localReplicaId,
    localOperationLog: @[],
    dispatchLog: @[],
    projectionCallbacks: @[],
    collaborationEnabled: false,
    peerTransportStarted: false,
    remoteAwarenessStarted: false,
    remoteGossipStarted: false,
  )

proc peerServicesStarted*(core: CollaborativeSessionCore): bool =
  not core.isNil and (
    core.peerTransportStarted or
    core.remoteAwarenessStarted or
    core.remoteGossipStarted)

proc addProjectionCallback*(core: CollaborativeSessionCore;
                            callback: ProjectionCallback) =
  if core.isNil or callback.isNil:
    return
  core.projectionCallbacks.add callback
  callback(core.document.state)

proc projectCurrentState*(core: CollaborativeSessionCore) =
  if core.isNil:
    return
  for callback in core.projectionCallbacks:
    if not callback.isNil:
      callback(core.document.state)

proc nextLocalViewOp*(core: CollaborativeSessionCore;
                      kind: ViewOpKind;
                      targetPath: string;
                      payload: JsonNode): ViewOpEnvelope =
  ## Build a local operation envelope and advance the actor clock.
  assert not core.isNil, "CollaborativeSessionCore is nil"
  core.actorSeq.inc
  core.lamport.inc
  let opId = core.localActorId & ":" & $core.actorSeq
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: core.document.state.sessionId,
    principalId: core.localPrincipalId,
    actorId: core.localActorId,
    replicaId: core.localReplicaId,
    actorSeq: core.actorSeq,
    opId: opId,
    lamport: core.lamport,
    capabilityIds: @[],
    targetPath: targetPath,
    kind: kind,
    payload: if payload.isNil: newJObject() else: payload,
    unknownFields: newJObject(),
  )

proc dispatchLocalViewOp*(core: CollaborativeSessionCore;
                          kind: ViewOpKind;
                          targetPath: string;
                          payload: JsonNode): ApplyResult =
  ## Apply a local ViewOp and project the reducer output. No peer publish or
  ## gossip is performed in M2 local mode.
  if core.isNil:
    return rejected("missing collaborative session core")

  let op = core.nextLocalViewOp(kind, targetPath, payload)
  result = applyViewOp(core.document, op)
  if result.status != asRejected:
    core.localOperationLog.add op
  core.dispatchLog.add LocalViewOpDispatch(
    op: op,
    result: result,
    localOnly: true,
    publishedToPeer: false,
  )
  core.projectCurrentState()

proc joinSnapshot*(core: CollaborativeSessionCore): SharedSessionSnapshot =
  if core.isNil:
    return initSharedSessionDocument().snapshot
  core.document.snapshot

proc lastLocalOperation*(core: CollaborativeSessionCore): Option[ViewOpEnvelope] =
  if core.isNil or core.localOperationLog.len == 0:
    return none(ViewOpEnvelope)
  some(core.localOperationLog[^1])

proc liveAddTags*(core: CollaborativeSessionCore;
                  entries: openArray[AddWinsSetEntry];
                  id: string): seq[string] =
  ## Return live add tags for an observed-remove collapse/removal payload.
  for entry in entries:
    if entry.id == id:
      for tag in entry.addTags:
        if tag notin entry.removedAddTags:
          result.add tag
      return

proc liveWatchForExpression*(core: CollaborativeSessionCore;
                             expression: string): Option[SharedWatch] =
  if core.isNil:
    return none(SharedWatch)
  for watch in core.document.state.statePane.visibleWatches:
    if watch.expression == expression:
      return some(watch)
  none(SharedWatch)
