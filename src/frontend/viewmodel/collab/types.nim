## Shared ViewModel collaboration types.
##
## M1 keeps this model front-end-neutral: it represents logical session state,
## operation envelopes, reducer stamps, and snapshots without renderer objects,
## networking, or ViewModel projection.

import std/json

const
  CurrentCollabSchemaVersion* = 1
  CurrentCollabProtocolVersion* = 1

type
  ActorId* = string
  SessionReplicaId* = string
  PrincipalId* = string
  ViewOpId* = string
  CapabilityGrantId* = string
  DriverLeaseId* = string

  PrincipalKind* = enum
    pkUser,
    pkService

  CapabilityKind* = enum
    capObserve,
    capPublishAwareness,
    capMutateSharedViewState,
    capControlDebugger,
    capManageBreakpoints,
    capManageWatches,
    capManageLayout,
    capGrantCapabilities,
    capInvite,
    capExportSession,
    capHostBackend

  LogicalPanelKind* = enum
    lpkEditor,
    lpkCalltrace,
    lpkState,
    lpkEventLog,
    lpkTimeline,
    lpkSearch,
    lpkScratchpad,
    lpkShell,
    lpkCustom

  ViewOpKind* = enum
    vokUnknown,
    vokSetRegister,
    vokRequestDriver,
    vokGrantDriver,
    vokReleaseDriver,
    vokRevokeDriver,
    vokGrantCapabilities,
    vokRevokeCapabilities,
    vokSetFocusedPanel,
    vokSetCalltraceSelection,
    vokToggleCalltraceExpansion,
    vokSetCalltraceSearch,
    vokSetStateTab,
    vokToggleStatePath,
    vokExpand,
    vokCollapse,
    vokAddWatch,
    vokEditWatch,
    vokRemoveWatch,
    vokMoveWatch,
    vokCreatePanel,
    vokClosePanel,
    vokMovePanel,
    vokSetPanelVisibility,
    vokSetBreakpoint,
    vokRemoveBreakpoint,
    vokDebugCommand,
    vokFollowParticipant,
    vokUnfollowParticipant

  CollabStamp* = object
    lamport*: uint64
    actorId*: ActorId

  LwwStringRegister* = object
    value*: string
    stamp*: CollabStamp

  LwwBoolRegister* = object
    value*: bool
    stamp*: CollabStamp

  LwwIntRegister* = object
    value*: int
    stamp*: CollabStamp

  SessionAuthority* = object
    principalId*: PrincipalId
    backendOwnerId*: PrincipalId

  PrincipalDescriptor* = object
    id*: PrincipalId
    kind*: PrincipalKind
    displayName*: string

  ActorDescriptor* = object
    id*: ActorId
    principalId*: PrincipalId

  ReplicaDescriptor* = object
    id*: SessionReplicaId
    actorId*: ActorId

  CapabilityGrant* = object
    id*: CapabilityGrantId
    subject*: PrincipalId
    issuer*: PrincipalId
    capabilities*: seq[CapabilityKind]
    targetPaths*: seq[string]
    addOpId*: ViewOpId
    revokedByOpId*: ViewOpId

  DriverRegister* = object
    principalId*: PrincipalId
    leaseId*: DriverLeaseId
    stamp*: CollabStamp

  AddWinsSetEntry* = object
    id*: string
    addTags*: seq[ViewOpId]
    removedAddTags*: seq[ViewOpId]

  SharedWatch* = object
    id*: string
    expression*: string
    orderKey*: string
    addTags*: seq[ViewOpId]
    removedAddTags*: seq[ViewOpId]
    expressionStamp*: CollabStamp
    orderStamp*: CollabStamp

  SharedBreakpoint* = object
    id*: string
    file*: string
    line*: int
    condition*: string
    enabled*: bool
    addTags*: seq[ViewOpId]
    removedAddTags*: seq[ViewOpId]
    fileStamp*: CollabStamp
    lineStamp*: CollabStamp
    conditionStamp*: CollabStamp
    enabledStamp*: CollabStamp

  LogicalPanel* = object
    id*: string
    kind*: LogicalPanelKind
    parentId*: string
    orderKey*: string
    isVisible*: bool
    addTags*: seq[ViewOpId]
    removedAddTags*: seq[ViewOpId]
    parentStamp*: CollabStamp
    orderStamp*: CollabStamp
    visibilityStamp*: CollabStamp

  FollowRegister* = object
    actorId*: ActorId
    followedPrincipalId*: PrincipalId
    stamp*: CollabStamp

  SharedCalltraceViewState* = object
    selectedEntry*: LwwStringRegister
    searchQuery*: LwwStringRegister
    expandedNodes*: seq[AddWinsSetEntry]

  SharedStateViewState* = object
    activeTab*: LwwStringRegister
    selectedPath*: LwwStringRegister
    expandedPaths*: seq[AddWinsSetEntry]
    watchExpressions*: seq[SharedWatch]

  SharedEditorViewState* = object
    activeDocumentId*: LwwStringRegister

  BackendSnapshotRegister* = object
    family*: string
    ownerId*: PrincipalId
    backendEpoch*: uint64
    payload*: JsonNode

  BackendDataSnapshotEnvelope* = object
    sessionId*: string
    backendOwnerId*: PrincipalId
    emittedByPrincipalId*: PrincipalId
    family*: string
    backendEpoch*: uint64
    payload*: JsonNode

  SharedSessionViewState* = object
    schemaVersion*: int
    traceIdentity*: string
    sessionId*: string
    revision*: uint64
    activeSessionId*: LwwStringRegister
    authority*: SessionAuthority
    principals*: seq[PrincipalDescriptor]
    actors*: seq[ActorDescriptor]
    replicas*: seq[ReplicaDescriptor]
    capabilityGrants*: seq[CapabilityGrant]
    activeDriver*: DriverRegister
    closedDriverLeases*: seq[DriverLeaseId]
    focusedPanelId*: LwwStringRegister
    layout*: seq[LogicalPanel]
    calltrace*: SharedCalltraceViewState
    statePane*: SharedStateViewState
    editor*: SharedEditorViewState
    breakpoints*: seq[SharedBreakpoint]
    followState*: seq[FollowRegister]
    backendSnapshots*: seq[BackendSnapshotRegister]

  SharedSessionSnapshot* = object
    schemaVersion*: int
    documentRevision*: uint64
    state*: SharedSessionViewState
    appliedOpIds*: seq[ViewOpId]

  SharedSessionDocument* = object
    state*: SharedSessionViewState
    appliedOpIds*: seq[ViewOpId]

  ViewOpEnvelope* = object
    protocolVersion*: int
    sessionId*: string
    principalId*: PrincipalId
    actorId*: ActorId
    replicaId*: SessionReplicaId
    actorSeq*: uint64
    opId*: ViewOpId
    lamport*: uint64
    capabilityIds*: seq[CapabilityGrantId]
    targetPath*: string
    kind*: ViewOpKind
    ## Original wire kind. For known operations this is normally empty and
    ## ``kind`` is authoritative; for unknown operations it preserves the
    ## future operation name for safe round-trips.
    kindName*: string
    payload*: JsonNode
    ## Unknown top-level envelope fields are preserved by the M1 codec so a
    ## peer can round-trip future metadata even if this reducer ignores it.
    unknownFields*: JsonNode

proc stamp*(op: ViewOpEnvelope): CollabStamp =
  CollabStamp(lamport: op.lamport, actorId: op.actorId)

proc initSharedSessionViewState*(
    sessionId = "";
    traceIdentity = "";
    authorityPrincipalId = "";
    backendOwnerId = ""): SharedSessionViewState =
  result = SharedSessionViewState(
    schemaVersion: CurrentCollabSchemaVersion,
    traceIdentity: traceIdentity,
    sessionId: sessionId,
    revision: 0'u64,
    authority: SessionAuthority(
      principalId: authorityPrincipalId,
      backendOwnerId: backendOwnerId,
    ),
  )
  if authorityPrincipalId.len > 0:
    result.principals.add PrincipalDescriptor(
      id: authorityPrincipalId,
      kind: pkUser,
      displayName: authorityPrincipalId,
    )
  if backendOwnerId.len > 0 and backendOwnerId != authorityPrincipalId:
    result.principals.add PrincipalDescriptor(
      id: backendOwnerId,
      kind: pkService,
      displayName: backendOwnerId,
    )

proc initSharedSessionDocument*(
    sessionId = "";
    traceIdentity = "";
    authorityPrincipalId = "";
    backendOwnerId = ""): SharedSessionDocument =
  SharedSessionDocument(
    state: initSharedSessionViewState(
      sessionId = sessionId,
      traceIdentity = traceIdentity,
      authorityPrincipalId = authorityPrincipalId,
      backendOwnerId = backendOwnerId,
    ),
    appliedOpIds: @[],
  )

proc snapshot*(document: SharedSessionDocument): SharedSessionSnapshot =
  SharedSessionSnapshot(
    schemaVersion: CurrentCollabSchemaVersion,
    documentRevision: document.state.revision,
    state: document.state,
    appliedOpIds: document.appliedOpIds,
  )
