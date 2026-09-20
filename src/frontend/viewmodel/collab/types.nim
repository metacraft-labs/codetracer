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
    capHostBackend,
    capEditSharedText
      ## PLAT-33. **A capability of its own, not `capMutateSharedViewState`.**
      ## Editing the buffer somebody is debugging is a different grant from
      ## moving their focus or expanding a tree: a reviewer invited to watch
      ## and annotate is exactly the principal who should have the second and
      ## not the first. It is last in the enum deliberately — the codec
      ## encodes capabilities by NAME (`codec.parseEnumValue`), so ordinal
      ## position is not on the wire and appending cannot renumber an existing
      ## grant.

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
    vokUnfollowParticipant,
    # =====================================================================
    # PLAT-33 — TEXT, WHICH IS A FOURTH MERGE FAMILY AND NOT A FOURTH
    # REGISTER
    # =====================================================================
    # Three kinds and not one, because the three do three different things
    # and each needs its own capability answer and its own reducer arm:
    #
    #   * a peer SUBMITS a change at the authority version it saw;
    #   * the authority ACCEPTS one, and what it broadcasts is the rebased
    #     result in canonical log order — which is not the same change set
    #     the peer sent and must not be confused with it;
    #   * a caret MOVES, which is awareness rather than an edit.
    #
    # Folding the first two into one kind would make "did this peer edit, or
    # did the authority tell me somebody edited?" a question about who sent
    # the envelope, and the answer to that is a property of the transport.
    vokSubmitTextUpdate,
    vokAcceptTextUpdate,
    vokSetTextSelection

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

  SharedTextUpdate* = object
    ## One entry of the authority's append-only log (§12.2), as shared state.
    ##
    ## `changes` is PLAT-25's `"CS1|"` wire encoding of a `ChangeSet`
    ## (`editor/change_set.nim`), carried as an opaque string so this module
    ## keeps its single `std/json` import and the collab layer does not gain a
    ## compile-time dependency on the editor. The decode happens in
    ## `collab/text_ops.nim`, which is where the two layers meet.
    producer*: PrincipalId
    opId*: ViewOpId
    changes*: string
    version*: int
      ## **THE INDEX THIS ENTRY OCCUPIES IN THE LOG**, assigned by the
      ## authority, carried on the envelope as `authorityVersion`.
      ##
      ## It is stored rather than implied by position because delivery is
      ## reordered in one of the five schedule classes this milestone is
      ## graded over, and a log whose order is its arrival order does not
      ## converge under reordering. With the index on the entry, an
      ## out-of-order accept parks in its own slot and the document is the
      ## fold of the longest GAP-FREE PREFIX (`committedLog`) — so a peer that
      ## receives 0, 2, 1 shows the same document as one that receives 0, 1, 2
      ## the moment the gap closes, and shows a shorter PREFIX rather than a
      ## wrong document in between.

  SharedCaretAnchor* = object
    ## A remote caret, as an ANCHOR rather than as a register value.
    ##
    ## §12.2a: *"a remote collaborator's caret is an anchor mapped through
    ## arriving change sets — not an LWW register, which would make two
    ## people's carets fight."* `side` is a bool and not the reference's
    ## signed magnitude, matching `change_set.Side`'s two values.
    pos*: int
    sideAfter*: bool

  SharedTextSelection* = object
    ## Where one actor's carets are, in one document, at one authority
    ## version. Keyed by actor rather than by principal: one person with two
    ## windows has two carets and they are not in conflict.
    actorId*: ActorId
    documentId*: string
    anchors*: seq[SharedCaretAnchor]
    atVersion*: int

  SharedTextDocument* = object
    ## §12.2's authority, as shared state. **The version IS `log.len`** and
    ## there is no second counter here either: a `version` field beside the
    ## log would be a field that can disagree with it.
    id*: string
    baseLength*: int
    log*: seq[SharedTextUpdate]

  SharedEditorViewState* = object
    activeDocumentId*: LwwStringRegister
    documents*: seq[SharedTextDocument]
      ## PLAT-33. Resolved by REBASE AGAINST THE AUTHORITY — the fourth merge
      ## family, and the first one in this file that is not a register, a set
      ## or an ownership claim. See the merge table in
      ## `Architecture/Editor-ViewModel.md` §12.1.
    remoteSelections*: seq[SharedTextSelection]
      ## MAPPED, never merged.

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
    authorityVersion*: int
      ## **PLAT-33: WHAT THE PRODUCER HAD ALREADY SEEN.**
      ##
      ## `lamport` does not substitute for this and the difference is the
      ## whole of §12.2a: a Lamport stamp ORDERS events, and rebase needs to
      ## know what a peer had already SEEN. `SharedSessionViewState.revision`
      ## does not substitute either — it is a LOCAL counter incremented by
      ## `markApplied` on every accepted op and it never travels.
      ##
      ## Zero on every operation that is not a text update, which is also the
      ## decode default, so an envelope from a peer that predates this field
      ## parses to a well-defined value rather than to a missing one.
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
