## Deterministic reducers for collaborative SharedSessionViewState operations.

import std/[algorithm, json, strutils]

import ./types
import ./capabilities

type
  ApplyStatus* = enum
    asApplied,
    asDuplicate,
    asIgnored,
    asRejected

  ApplyResult* = object
    status*: ApplyStatus
    reason*: string

proc applied*(reason = ""): ApplyResult =
  ApplyResult(status: asApplied, reason: reason)

proc duplicate*(reason = "duplicate opId"): ApplyResult =
  ApplyResult(status: asDuplicate, reason: reason)

proc ignored*(reason = ""): ApplyResult =
  ApplyResult(status: asIgnored, reason: reason)

proc rejected*(reason = ""): ApplyResult =
  ApplyResult(status: asRejected, reason: reason)

proc containsString(items: openArray[string]; value: string): bool =
  for item in items:
    if item == value:
      return true

proc addUnique(items: var seq[string]; value: string) =
  if value.len > 0 and not items.containsString(value):
    items.add value

proc hasApplied(document: SharedSessionDocument; opId: ViewOpId): bool =
  document.appliedOpIds.containsString(opId)

proc markApplied(document: var SharedSessionDocument; op: ViewOpEnvelope) =
  document.appliedOpIds.addUnique(op.opId)
  document.appliedOpIds.sort(cmp[string])
  document.state.revision.inc

proc isNewer*(candidate, current: CollabStamp): bool =
  ## Normative "newer" comparison: greater (lamport, actorId) pair.
  candidate.lamport > current.lamport or
    (candidate.lamport == current.lamport and candidate.actorId > current.actorId)

proc liveTags(addTags, removedAddTags: openArray[string]): seq[string] =
  for tag in addTags:
    if not removedAddTags.containsString(tag):
      result.add tag

proc isLive*(entry: AddWinsSetEntry): bool =
  liveTags(entry.addTags, entry.removedAddTags).len > 0

proc isLive*(watch: SharedWatch): bool =
  liveTags(watch.addTags, watch.removedAddTags).len > 0

proc isLive*(bp: SharedBreakpoint): bool =
  liveTags(bp.addTags, bp.removedAddTags).len > 0

proc isLive*(panel: LogicalPanel): bool =
  liveTags(panel.addTags, panel.removedAddTags).len > 0

proc getStrField(payload: JsonNode; keys: openArray[string]; fallback = ""): string =
  if payload.isNil:
    return fallback
  for key in keys:
    let value = payload{key}
    if not value.isNil:
      return value.getStr(fallback)
  fallback

proc getIntField(payload: JsonNode; keys: openArray[string]; fallback = 0): int =
  if payload.isNil:
    return fallback
  for key in keys:
    let value = payload{key}
    if not value.isNil:
      return value.getInt(fallback)
  fallback

proc getBoolField(payload: JsonNode; keys: openArray[string]; fallback = false): bool =
  if payload.isNil:
    return fallback
  for key in keys:
    let value = payload{key}
    if not value.isNil:
      return value.getBool(fallback)
  fallback

proc getStrSeqField(payload: JsonNode; keys: openArray[string]): seq[string] =
  if payload.isNil:
    return @[]
  for key in keys:
    let value = payload{key}
    if not value.isNil:
      for item in value.getElems(@[]):
        result.add item.getStr("")
      return

proc getCapabilitySeq(payload: JsonNode): seq[CapabilityKind] =
  for item in payload{"capabilities"}.getElems(@[]):
    for value in CapabilityKind:
      if $value == item.getStr(""):
        result.add value
        break

proc applyRegister(register: var LwwStringRegister; value: string; stamp: CollabStamp): bool =
  if stamp.isNewer(register.stamp):
    register.value = value
    register.stamp = stamp
    return true

proc normalize(state: var SharedSessionViewState) =
  for entry in state.calltrace.expandedNodes.mitems:
    entry.addTags.sort(cmp[string])
    entry.removedAddTags.sort(cmp[string])
  for entry in state.statePane.expandedPaths.mitems:
    entry.addTags.sort(cmp[string])
    entry.removedAddTags.sort(cmp[string])
  for watch in state.statePane.watchExpressions.mitems:
    watch.addTags.sort(cmp[string])
    watch.removedAddTags.sort(cmp[string])
  for bp in state.breakpoints.mitems:
    bp.addTags.sort(cmp[string])
    bp.removedAddTags.sort(cmp[string])
  for panel in state.layout.mitems:
    panel.addTags.sort(cmp[string])
    panel.removedAddTags.sort(cmp[string])
  state.closedDriverLeases.sort(cmp[string])
  state.capabilityGrants.sort(proc(a, b: CapabilityGrant): int = cmp(a.id, b.id))
  state.calltrace.expandedNodes.sort(proc(a, b: AddWinsSetEntry): int = cmp(a.id, b.id))
  state.statePane.expandedPaths.sort(proc(a, b: AddWinsSetEntry): int = cmp(a.id, b.id))
  state.statePane.watchExpressions.sort(proc(a, b: SharedWatch): int = cmp(a.id, b.id))
  state.breakpoints.sort(proc(a, b: SharedBreakpoint): int = cmp(a.id, b.id))
  state.layout.sort(proc(a, b: LogicalPanel): int = cmp(a.id, b.id))
  state.followState.sort(proc(a, b: FollowRegister): int = cmp(a.actorId, b.actorId))
  # ---------------------------------------------------------------------
  # PLAT-33 — AND THE TEXT LOG IS SORTED BY A DIFFERENT KEY FOR A DIFFERENT
  # REASON, WHICH IS WORTH SAYING WHERE IT IS DONE.
  # ---------------------------------------------------------------------
  # Every sort above imposes a canonical order on a SET so two replicas that
  # accepted the same operations in different orders hold equal values. The
  # text log is not a set: its order is its meaning, and the order is the
  # AUTHORITY'S, carried on each entry as `version`. Sorting it by `opId` —
  # the shape every line above has — would silently reorder the document.
  state.editor.documents.sort(proc(a, b: SharedTextDocument): int = cmp(a.id, b.id))
  for doc in state.editor.documents.mitems:
    doc.log.sort(proc(a, b: SharedTextUpdate): int = cmp(a.version, b.version))
  state.editor.remoteSelections.sort(proc(a, b: SharedTextSelection): int =
    let actorCmp = cmp(a.actorId, b.actorId)
    if actorCmp != 0: actorCmp else: cmp(a.documentId, b.documentId))
  for sel in state.editor.remoteSelections.mitems:
    sel.anchors.sort(proc(a, b: SharedCaretAnchor): int =
      let posCmp = cmp(a.pos, b.pos)
      if posCmp != 0: posCmp else: cmp(a.sideAfter, b.sideAfter))
  state.backendSnapshots.sort(proc(a, b: BackendSnapshotRegister): int =
    let familyCmp = cmp(a.family, b.family)
    if familyCmp != 0: familyCmp else: cmp(a.ownerId, b.ownerId))

proc findExpansion(entries: var seq[AddWinsSetEntry]; id: string): int =
  for i, entry in entries.mpairs:
    if entry.id == id:
      return i
  entries.add AddWinsSetEntry(id: id)
  entries.len - 1

proc applyExpansion(
    entries: var seq[AddWinsSetEntry];
    op: ViewOpEnvelope;
    expand: bool): bool =
  let id = getStrField(op.payload, ["id", "nodeId", "path"])
  if id.len == 0:
    return false
  let i = entries.findExpansion(id)
  if expand:
    entries[i].addTags.addUnique(op.opId)
  else:
    for tag in getStrSeqField(op.payload, ["observedAddTags", "removeTags"]):
      entries[i].removedAddTags.addUnique(tag)
  true

proc findWatch(watches: var seq[SharedWatch]; id: string): int =
  for i, watch in watches.mpairs:
    if watch.id == id:
      return i
  watches.add SharedWatch(id: id)
  watches.len - 1

proc applyAddWatch(state: var SharedStateViewState; op: ViewOpEnvelope): bool =
  let id = getStrField(op.payload, ["watchId", "id"])
  if id.len == 0:
    return false
  let stamp = op.stamp
  let i = state.watchExpressions.findWatch(id)
  state.watchExpressions[i].addTags.addUnique(op.opId)
  if stamp.isNewer(state.watchExpressions[i].expressionStamp):
    state.watchExpressions[i].expression =
      getStrField(op.payload, ["expression", "value"])
    state.watchExpressions[i].expressionStamp = stamp
  if stamp.isNewer(state.watchExpressions[i].orderStamp):
    state.watchExpressions[i].orderKey = getStrField(op.payload, ["orderKey"])
    state.watchExpressions[i].orderStamp = stamp
  true

proc applyEditWatch(state: var SharedStateViewState; op: ViewOpEnvelope): bool =
  let id = getStrField(op.payload, ["watchId", "id"])
  if id.len == 0:
    return false
  let i = state.watchExpressions.findWatch(id)
  if op.stamp.isNewer(state.watchExpressions[i].expressionStamp):
    state.watchExpressions[i].expression =
      getStrField(op.payload, ["expression", "value"])
    state.watchExpressions[i].expressionStamp = op.stamp
  true

proc applyMoveWatch(state: var SharedStateViewState; op: ViewOpEnvelope): bool =
  let id = getStrField(op.payload, ["watchId", "id"])
  if id.len == 0:
    return false
  let i = state.watchExpressions.findWatch(id)
  if op.stamp.isNewer(state.watchExpressions[i].orderStamp):
    state.watchExpressions[i].orderKey = getStrField(op.payload, ["orderKey"])
    state.watchExpressions[i].orderStamp = op.stamp
  true

proc applyRemoveWatch(state: var SharedStateViewState; op: ViewOpEnvelope): bool =
  let id = getStrField(op.payload, ["watchId", "id"])
  if id.len == 0:
    return false
  let i = state.watchExpressions.findWatch(id)
  for tag in getStrSeqField(op.payload, ["observedAddTags", "removeTags"]):
    state.watchExpressions[i].removedAddTags.addUnique(tag)
  true

proc findBreakpoint(breakpoints: var seq[SharedBreakpoint]; id: string): int =
  for i, bp in breakpoints.mpairs:
    if bp.id == id:
      return i
  breakpoints.add SharedBreakpoint(id: id)
  breakpoints.len - 1

proc applySetBreakpoint(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  let id = getStrField(op.payload, ["breakpointId", "id"])
  if id.len == 0:
    return false
  let i = state.breakpoints.findBreakpoint(id)
  let stamp = op.stamp
  state.breakpoints[i].addTags.addUnique(op.opId)
  if stamp.isNewer(state.breakpoints[i].fileStamp):
    state.breakpoints[i].file = getStrField(op.payload, ["file"])
    state.breakpoints[i].fileStamp = stamp
  if stamp.isNewer(state.breakpoints[i].lineStamp):
    state.breakpoints[i].line = getIntField(op.payload, ["line"])
    state.breakpoints[i].lineStamp = stamp
  if stamp.isNewer(state.breakpoints[i].conditionStamp):
    state.breakpoints[i].condition = getStrField(op.payload, ["condition"])
    state.breakpoints[i].conditionStamp = stamp
  if stamp.isNewer(state.breakpoints[i].enabledStamp):
    state.breakpoints[i].enabled = getBoolField(op.payload, ["enabled"], true)
    state.breakpoints[i].enabledStamp = stamp
  true

proc applyRemoveBreakpoint(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  let id = getStrField(op.payload, ["breakpointId", "id"])
  if id.len == 0:
    return false
  let i = state.breakpoints.findBreakpoint(id)
  for tag in getStrSeqField(op.payload, ["observedAddTags", "removeTags"]):
    state.breakpoints[i].removedAddTags.addUnique(tag)
  true

proc findPanel(layout: var seq[LogicalPanel]; id: string): int =
  for i, panel in layout.mpairs:
    if panel.id == id:
      return i
  layout.add LogicalPanel(id: id)
  layout.len - 1

proc parsePanelKind(value: string): LogicalPanelKind =
  for kind in LogicalPanelKind:
    if $kind == value:
      return kind
  lpkCustom

proc applyCreatePanel(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  let id = getStrField(op.payload, ["panelId", "id"])
  if id.len == 0:
    return false
  let i = state.layout.findPanel(id)
  let stamp = op.stamp
  state.layout[i].addTags.addUnique(op.opId)
  if state.layout[i].kind == lpkEditor and state.layout[i].addTags.len == 1:
    state.layout[i].kind = parsePanelKind(getStrField(op.payload, ["kind"], $lpkCustom))
  if stamp.isNewer(state.layout[i].parentStamp):
    state.layout[i].parentId = getStrField(op.payload, ["parentId"])
    state.layout[i].parentStamp = stamp
  if stamp.isNewer(state.layout[i].orderStamp):
    state.layout[i].orderKey = getStrField(op.payload, ["orderKey"])
    state.layout[i].orderStamp = stamp
  if stamp.isNewer(state.layout[i].visibilityStamp):
    state.layout[i].isVisible = getBoolField(op.payload, ["isVisible"], true)
    state.layout[i].visibilityStamp = stamp
  true

proc applyClosePanel(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  let id = getStrField(op.payload, ["panelId", "id"])
  if id.len == 0:
    return false
  let i = state.layout.findPanel(id)
  for tag in getStrSeqField(op.payload, ["observedAddTags", "removeTags"]):
    state.layout[i].removedAddTags.addUnique(tag)
  true

proc applyMovePanel(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  let id = getStrField(op.payload, ["panelId", "id"])
  if id.len == 0:
    return false
  let i = state.layout.findPanel(id)
  let stamp = op.stamp
  if stamp.isNewer(state.layout[i].parentStamp):
    state.layout[i].parentId = getStrField(op.payload, ["parentId"])
    state.layout[i].parentStamp = stamp
  if stamp.isNewer(state.layout[i].orderStamp):
    state.layout[i].orderKey = getStrField(op.payload, ["orderKey"])
    state.layout[i].orderStamp = stamp
  true

proc applyPanelVisibility(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  let id = getStrField(op.payload, ["panelId", "id"])
  if id.len == 0:
    return false
  let i = state.layout.findPanel(id)
  if op.stamp.isNewer(state.layout[i].visibilityStamp):
    state.layout[i].isVisible = getBoolField(op.payload, ["isVisible", "visible"])
    state.layout[i].visibilityStamp = op.stamp
  true

# ===========================================================================
# THE CAPABILITY PREDICATES ARE `capabilities.nim`'s, NOT A SECOND COPY
# ===========================================================================
#
# **SIX ROUTINES WERE WRITTEN OUT HERE A SECOND TIME UNTIL PLAT-33**, and
# **NO REASON FOR IT IS RECORDED ANYWHERE.** An earlier version of this
# comment said the duplication existed "to avoid an import cycle" and
# attributed that to a comment in `capabilities.nim`. No such comment ever
# existed — at the commit before this one `capabilities.nim` is a one-line
# docstring — and `git log --all -S"cycle"` over both files returns nothing,
# ever. The explanation was invented retroactively and is withdrawn; the
# honest statement is that a duplicate existed and its reason is unrecorded.
#
# There is in fact no cycle — `capabilities.nim` imports `std/[algorithm,
# strutils]` and `./types` and nothing else — so this module can import it and
# does.
#
# **THE SUBSTITUTION IS NOT A PURE REFACTOR, AND SAYING SO WAS THE SECOND
# UNRUN COMPARISON IN THIS COMMENT.** An earlier version claimed the two
# copies "were line-for-line identical when they were compared, which is the
# only reason the substitution below is a refactor rather than a behaviour
# change". Nobody had compared them; the claim was read off a substitution
# that compiled. The comparison, actually run:
#
#   - `pathCovers`, `targetPathsCover` — identical bodies. A refactor.
#   - `isAuthority` — rewritten. The copy here inlined the conjunction;
#     `capabilities.isAuthority` delegates to `isSessionAuthority` and
#     `isBackendOwner`. Sound (the `len > 0` distributes over the `or`) but
#     not the same lines.
#   - `liveCapability` — **gone, not moved.** The predicate that replaces it
#     is named `hasLiveCapability` and has a different body: the old one
#     returned `true` from inside the grant walk, the new one asks
#     `liveCapabilityGrant` for the matching grant's id and tests `.len > 0`.
#     On a grant whose id is empty the two disagree — old `true`, new
#     `false` — and `canGrantCapabilities` / `canDelegateCapabilities`
#     inherit that through their callee.
#
# The disagreement was reachable: `codec.parseCapabilityGrant` decoded `id`
# unguarded, so a snapshot omitting `"id"` produced exactly that grant, and a
# compiled probe over it divided the two predicates. The new answer is the
# fail-closed one, so it is kept; PLAT-33 also made the decoder refuse the
# grant outright, since `applyGrantCapabilities` and `applyRevokeCapabilities`
# below BOTH already refuse `id.len == 0` — an empty-id grant admitted by the
# decoder was one no revoke operation could ever retract.
#
# The lesson is §38's, appearing inside the module §38's own milestone was
# written against: an equivalence asserted from a change that worked, rather
# than from a comparison run, is not evidence.
#
# This is `Verification-Harness-Traps.md` §30 — *one predicate, one function,
# rule and control both calling it*. It matters here rather than in general:
# PLAT-33 adds a capability rule, and with two copies in the tree the cheapest
# way to add it is to add it twice. §30b's second bullet is the one that
# applies — "count the copies before you believe the extraction is done" — so
# the extraction is all six and not the one this milestone needed.
#
# The dividend is §30b's first bullet: `test_collab_reducer.nim` and
# `test_collab_authority_m4.nim` now grade ONE implementation from two sides,
# so a defect in the grant walk cannot be green in one suite and red in the
# other.

proc applyGrantCapabilities(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  if not state.canGrantCapabilities(op.principalId):
    return false
  let id = getStrField(op.payload, ["grantId", "id"])
  if id.len == 0:
    return false
  var index = -1
  for i, grant in state.capabilityGrants.mpairs:
    if grant.id == id:
      index = i
      break
  if index < 0:
    state.capabilityGrants.add CapabilityGrant(id: id)
    index = state.capabilityGrants.len - 1
  let revokedBy = state.capabilityGrants[index].revokedByOpId
  state.capabilityGrants[index] = CapabilityGrant(
    id: id,
    subject: getStrField(op.payload, ["subject", "principalId"]),
    issuer: op.principalId,
    capabilities: getCapabilitySeq(op.payload),
    targetPaths: getStrSeqField(op.payload, ["targetPaths"]),
    addOpId: op.opId,
    revokedByOpId: revokedBy,
  )
  true

proc applyRevokeCapabilities(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  if not state.canGrantCapabilities(op.principalId):
    return false
  let id = getStrField(op.payload, ["grantId", "id"])
  if id.len == 0:
    return false
  var index = -1
  for i, grant in state.capabilityGrants.mpairs:
    if grant.id == id:
      index = i
      break
  if index < 0:
    state.capabilityGrants.add CapabilityGrant(id: id)
    index = state.capabilityGrants.len - 1
  if state.capabilityGrants[index].revokedByOpId.len == 0:
    state.capabilityGrants[index].revokedByOpId = op.opId
  true

proc driverLeaseId(op: ViewOpEnvelope): DriverLeaseId =
  getStrField(op.payload, ["leaseId"], "")

proc applyDriver(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  case op.kind
  of vokReleaseDriver, vokRevokeDriver:
    let leaseId = op.driverLeaseId
    if leaseId.len == 0:
      return false
    if not state.closedDriverLeases.containsString(leaseId):
      state.closedDriverLeases.add leaseId
      result = true
    if state.activeDriver.leaseId == leaseId:
      state.activeDriver = DriverRegister()
      result = true
  else:
    let leaseId = op.driverLeaseId
    if leaseId.len == 0 or state.closedDriverLeases.containsString(leaseId):
      return false
    if state.activeDriver.principalId.len > 0 and
        not op.stamp.isNewer(state.activeDriver.stamp):
      return false
    state.activeDriver = DriverRegister(
      principalId: getStrField(op.payload, ["principalId"], op.principalId),
      leaseId: leaseId,
      stamp: op.stamp,
    )
    result = true

proc applyFollow(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  var index = -1
  for i, follow in state.followState.mpairs:
    if follow.actorId == op.actorId:
      index = i
      break
  if index < 0:
    state.followState.add FollowRegister(actorId: op.actorId)
    index = state.followState.len - 1
  if op.stamp.isNewer(state.followState[index].stamp):
    state.followState[index].followedPrincipalId =
      if op.kind == vokUnfollowParticipant: "" else:
        getStrField(op.payload, ["principalId", "followedPrincipalId"])
    state.followState[index].stamp = op.stamp
  true

proc applyScalarRegister(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  let value = getStrField(op.payload, ["value"])
  case op.targetPath
  of "activeSessionId":
    state.activeSessionId.applyRegister(value, op.stamp)
  of "focusedPanelId":
    state.focusedPanelId.applyRegister(value, op.stamp)
  of "calltrace.selectedEntry":
    state.calltrace.selectedEntry.applyRegister(value, op.stamp)
  of "calltrace.searchQuery":
    state.calltrace.searchQuery.applyRegister(value, op.stamp)
  of "statePane.activeTab":
    state.statePane.activeTab.applyRegister(value, op.stamp)
  of "statePane.selectedPath":
    state.statePane.selectedPath.applyRegister(value, op.stamp)
  of "editor.activeDocumentId":
    state.editor.activeDocumentId.applyRegister(value, op.stamp)
  else:
    false

proc applyTypedScalar(state: var SharedSessionViewState; op: ViewOpEnvelope): bool =
  case op.kind
  of vokSetFocusedPanel:
    state.focusedPanelId.applyRegister(
      getStrField(op.payload, ["panelId", "value"]), op.stamp)
  of vokSetCalltraceSelection:
    state.calltrace.selectedEntry.applyRegister(
      getStrField(op.payload, ["entryId", "value"]), op.stamp)
  of vokSetCalltraceSearch:
    state.calltrace.searchQuery.applyRegister(
      getStrField(op.payload, ["query", "value"]), op.stamp)
  of vokSetStateTab:
    state.statePane.activeTab.applyRegister(
      getStrField(op.payload, ["tab", "value"]), op.stamp)
  else:
    false

# ===========================================================================
# PLAT-33 — TEXT, THE FOURTH MERGE FAMILY
# ===========================================================================
#
# The normative merge table is `Architecture/Editor-ViewModel.md` §12.1, and
# its fourth row is this block. What makes text a FAMILY rather than a fourth
# register is visible in what is absent below: there is no `isNewer`, no
# stamp comparison, and no `applyRegister`. A text update is never resolved by
# comparing two values and keeping one — both survive, in the authority's
# order, and the loser of a race is REBASED rather than discarded.
#
# **THE AUTHORITY IS THE ONLY WRITER OF THE LOG**, which is what makes this
# reducer deterministic without needing to be a CRDT. A peer's
# `vokSubmitTextUpdate` is a REQUEST: every replica records it for dedup and
# changes nothing, exactly as `vokDebugCommand` does. The session authority
# runs `editor/collab_text.accept`, which rebases the submission over
# `log[peerVersion..]`, and emits one `vokAcceptTextUpdate` per accepted
# update carrying the index it was given. So every replica applies the same
# accepts and folds the same document, and no replica ever has to decide an
# order for itself.

proc findTextDocument(docs: var seq[SharedTextDocument];
                      id: string; baseLength: int): int =
  for i, doc in docs.mpairs:
    if doc.id == id:
      return i
  docs.add SharedTextDocument(id: id, baseLength: baseLength, log: @[])
  docs.len - 1

func committedLog*(doc: SharedTextDocument): seq[SharedTextUpdate] =
  ## The longest GAP-FREE PREFIX of the log, from version 0.
  ##
  ## This is what makes the document converge under REORDERED delivery
  ## without the reducer having to buffer anything: an accept for version 4
  ## that overtakes version 3 is stored in its own slot and simply is not part
  ## of the document yet. When 3 lands, both become visible in one step. A
  ## replica therefore shows a SHORTER prefix than another, never a different
  ## one — which is exactly the property `LAW-X1` quantifies over the reordered
  ## schedule class.
  ##
  ## `log` is kept sorted by `version` by `normalize`, so this is a walk.
  var expected = 0
  for entry in doc.log:
    if entry.version != expected:
      break
    result.add entry
    inc expected

func committedVersion*(doc: SharedTextDocument): int =
  ## The authority version this replica has folded. **Not** `log.len`: an
  ## entry parked beyond a gap is held and not counted.
  doc.committedLog.len

proc applyAcceptTextUpdate(state: var SharedSessionViewState;
                           op: ViewOpEnvelope): bool =
  ## Append one authority-assigned log entry.
  let documentId = getStrField(op.payload, ["documentId", "id"])
  if documentId.len == 0:
    return false
  let changes = getStrField(op.payload, ["changes"])
  if changes.len == 0:
    return false
  if op.authorityVersion < 0:
    return false
  let i = state.editor.documents.findTextDocument(
    documentId, getIntField(op.payload, ["baseLength"], 0))
  # **IDEMPOTENT BY VERSION AS WELL AS BY `opId`.** `hasApplied` already stops
  # the same envelope twice; this stops two DIFFERENT envelopes claiming one
  # slot, which is not a duplicate but a conflicting authority — and silently
  # taking the second would make the document a function of arrival order
  # again. The first claim on a version wins and the second changes nothing.
  for entry in state.editor.documents[i].log:
    if entry.version == op.authorityVersion:
      return false
  state.editor.documents[i].log.add SharedTextUpdate(
    producer: getStrField(op.payload, ["producer"], op.principalId),
    opId: getStrField(op.payload, ["updateId"], op.opId),
    changes: changes,
    version: op.authorityVersion,
  )
  true

proc applyTextSelection(state: var SharedSessionViewState;
                        op: ViewOpEnvelope): bool =
  ## A remote caret. **NOT A REGISTER**, and the difference is structural
  ## rather than a matter of which comparison is used:
  ##
  ##   * what is stored is a set of ANCHORS plus the authority version they
  ##     were expressed against, and a reader MAPS them forward through
  ##     `log[atVersion..]` — the value is resolved by a change set, not by a
  ##     stamp;
  ##   * there is exactly ONE writer per `(actorId, documentId)`, so there is
  ##     no conflict to resolve. Ordering one writer's own updates by the
  ##     version they were produced against is sequencing, not merging, and it
  ##     is why `isNewer` does not appear here.
  ##
  ## Two people's carets therefore cannot fight, which is the failure §12.2a
  ## names when it says a caret must not be an LWW register.
  let documentId = getStrField(op.payload, ["documentId"])
  if documentId.len == 0 or op.actorId.len == 0:
    return false
  var anchors: seq[SharedCaretAnchor] = @[]
  if not op.payload.isNil:
    for item in op.payload{"anchors"}.getElems(@[]):
      anchors.add SharedCaretAnchor(
        pos: item{"pos"}.getInt(0),
        sideAfter: item{"sideAfter"}.getBool(false))
  var index = -1
  for i, sel in state.editor.remoteSelections.mpairs:
    if sel.actorId == op.actorId and sel.documentId == documentId:
      index = i
      break
  if index < 0:
    state.editor.remoteSelections.add SharedTextSelection(
      actorId: op.actorId, documentId: documentId, atVersion: -1)
    index = state.editor.remoteSelections.len - 1
  if op.authorityVersion < state.editor.remoteSelections[index].atVersion:
    return false
  state.editor.remoteSelections[index].anchors = anchors
  state.editor.remoteSelections[index].atVersion = op.authorityVersion
  true

# ===========================================================================
# THE NORMATIVE MERGE TABLE, AS CODE
# ===========================================================================
#
# `Architecture/Editor-ViewModel.md` §12.1a publishes four families and this
# is their implementation side. The two are compared in both directions, with
# the cardinality asserted, by `test_editor_collab_examples.nim` — a family
# published and not implemented, or implemented and not published, fails by
# name (Conformance Suite §7.1).
#
# The dispatch below is EXHAUSTIVE for the same reason `requiredCapability`
# now is: a new op kind that belongs to no family is a kind whose conflict
# behaviour nobody decided, and the compiler is the only reviewer that never
# forgets to ask.

type
  MergeFamily* = enum
    mfNone            ## the op mutates no shared field (a request, or unknown)
    mfLww             ## `MF-LWW` — last-writer-wins register
    mfAddWins         ## `MF-AddWins` — add-wins observed-remove set
    mfOwnerEpoch      ## `MF-OwnerEpoch` — owner-locked epoch
    mfTextRebase      ## `MF-TextRebase` — rebase against the authority

const
  MergeFamilyIds*: array[MergeFamily, string] = [
    "", "MF-LWW", "MF-AddWins", "MF-OwnerEpoch", "MF-TextRebase"]
    ## The published ids, in enum order. `mfNone` has none because it is not a
    ## family — it is the absence of one, and giving it an id would put a
    ## fifth row into a four-row comparison.

  PublishedMergeFamilyCount* = 4
    ## A NAMED CARDINALITY. Without it the two set differences in §7.1's
    ## two-way count are both satisfied by two empty sets.

func mergeFamilyOf*(kind: ViewOpKind): MergeFamily =
  case kind
  of vokSetRegister, vokSetFocusedPanel, vokSetCalltraceSelection,
      vokSetCalltraceSearch, vokSetStateTab, vokFollowParticipant,
      vokUnfollowParticipant:
    mfLww
  of vokToggleCalltraceExpansion, vokToggleStatePath, vokExpand, vokCollapse,
      vokAddWatch, vokEditWatch, vokRemoveWatch, vokMoveWatch,
      vokSetBreakpoint, vokRemoveBreakpoint, vokCreatePanel, vokClosePanel,
      vokMovePanel, vokSetPanelVisibility, vokGrantCapabilities,
      vokRevokeCapabilities:
    mfAddWins
  of vokRequestDriver, vokGrantDriver, vokReleaseDriver, vokRevokeDriver:
    mfOwnerEpoch
  of vokAcceptTextUpdate, vokSetTextSelection:
    mfTextRebase
  of vokSubmitTextUpdate:
    # A REQUEST, not a mutation: it changes no shared field, so it belongs to
    # no family. Classifying it `mfTextRebase` would say the reducer merges it,
    # and the reducer does not — the authority does, and what the authority
    # emits is `vokAcceptTextUpdate`.
    mfNone
  of vokDebugCommand, vokUnknown:
    mfNone

proc opTargetPath(op: ViewOpEnvelope; fallback: string): string =
  if op.targetPath.len > 0: op.targetPath else: fallback

proc requiredCapability(op: ViewOpEnvelope): tuple[needed: bool, cap: CapabilityKind, targetPath: string] =
  ## **THIS `case` IS EXHAUSTIVE, AND IT WAS NOT UNTIL PLAT-33.**
  ##
  ## It carried `else: (false, capObserve, "")` — a fail-OPEN default, because
  ## `hasRequiredCapability` reads `not required.needed` as "allowed". An
  ## operation kind added to the enum and to `applyViewOp`'s exhaustive
  ## dispatch but not to this table therefore compiled, ran, and was
  ## **ungated**: capability-checked as observe-only, which is no check at
  ## all. The compiler covered the reducer half and nothing covered this one,
  ## and `Architecture/Editor-ViewModel.md` §12.1 recorded it as the hazard to
  ## carry into this milestone.
  ##
  ## The repair is not a run-time assertion — it is the removal of the
  ## `else`. Every kind is now named, including the ones that need nothing
  ## here, and a new enum member fails to COMPILE in **three** places instead
  ## of one. That is the only form of this check that cannot itself be
  ## forgotten.
  ##
  ## **THREE, AND IT IS MEASURED RATHER THAN COUNTED BY EYE.** Planting a
  ## `vokProbeNewKindPLAT33` member on `ViewOpKind` and compiling with
  ## `--errorMax` raised produces exactly three `not all cases are covered`
  ## errors, in `mergeFamilyOf`, in this routine, and in `applyViewOp`. The
  ## figure stood at "two" here and in the spec, and was reported as "four"
  ## elsewhere; all three numbers disagreed, so none of them had been run.
  ## `mergeFamilyOf` is the one an eye-count misses — it is new in PLAT-33 and
  ## is a third exhaustive `case` over the same enum, not a second.
  ##
  ## Note that the mutation arm `M6` does NOT evidence this: it kills four
  ## cases, but it rewrites an arm *body* rather than planting an enum
  ## omission, and the `case` stays exhaustive under it.
  ##
  ## The kinds that answer `(false, …)` do so for a stated reason each, and
  ## none of them is "no rule was written":
  ##
  ##   * `vokUnknown` is a forward-compatibility placeholder whose reducer arm
  ##     changes nothing, so there is nothing to gate;
  ##   * the four driver kinds are gated by `canApplyDriverOp`, which is a
  ##     narrower rule than a single capability (it also accepts the lease's
  ##     own holder releasing it);
  ##   * the two capability kinds are gated by `canGrantCapabilities` plus
  ##     `canDelegateCapabilities`, which is a rule about the grant's CONTENTS
  ##     and cannot be expressed as one `(cap, path)` pair.
  ##
  ## Gating those a second time here would be two predicates for one rule —
  ## `Verification-Harness-Traps.md` §30 — so they are named and delegated
  ## rather than named and duplicated.
  case op.kind
  of vokSetRegister, vokSetFocusedPanel, vokSetCalltraceSelection,
      vokSetCalltraceSearch, vokSetStateTab, vokToggleCalltraceExpansion,
      vokToggleStatePath, vokExpand, vokCollapse:
    (true, capMutateSharedViewState, op.opTargetPath(""))
  of vokAddWatch, vokEditWatch, vokRemoveWatch, vokMoveWatch:
    (true, capManageWatches, op.opTargetPath("statePane.watchExpressions"))
  of vokSetBreakpoint, vokRemoveBreakpoint:
    (true, capManageBreakpoints, op.opTargetPath("breakpoints"))
  of vokCreatePanel, vokClosePanel, vokMovePanel, vokSetPanelVisibility:
    (true, capManageLayout, op.opTargetPath("layout"))
  of vokFollowParticipant, vokUnfollowParticipant:
    (true, capPublishAwareness, op.opTargetPath("followState"))
  of vokDebugCommand:
    (true, capControlDebugger, op.opTargetPath("debugger.commands"))
  of vokSubmitTextUpdate, vokAcceptTextUpdate:
    ## PLAT-33. **A capability of its own** (§12.2a), on the documents path.
    (true, capEditSharedText, op.opTargetPath("editor.documents"))
  of vokSetTextSelection:
    ## A caret is AWARENESS, not an edit: a reviewer who may watch and point
    ## but not type is the principal this distinction exists for. It shares
    ## `capPublishAwareness` with the follow ops for that reason, and the
    ## two-sidedness — a text op refused for a principal whose caret op is
    ## accepted — is asserted rather than assumed.
    (true, capPublishAwareness, op.opTargetPath("editor.remoteSelections"))
  of vokUnknown:
    (false, capObserve, "")
  of vokRequestDriver, vokGrantDriver, vokReleaseDriver, vokRevokeDriver:
    (false, capObserve, "")
  of vokGrantCapabilities, vokRevokeCapabilities:
    (false, capObserve, "")

proc hasRequiredCapability(state: SharedSessionViewState; op: ViewOpEnvelope): bool =
  let required = op.requiredCapability
  not required.needed or state.hasLiveCapability(
    op.principalId, required.cap, required.targetPath, op.capabilityIds)

proc driverPrincipalId(op: ViewOpEnvelope): PrincipalId =
  getStrField(op.payload, ["principalId"], op.principalId)

proc canApplyDriverOp(state: SharedSessionViewState; op: ViewOpEnvelope): bool =
  case op.kind
  of vokRequestDriver, vokGrantDriver:
    state.hasLiveCapability(op.principalId, capControlDebugger, "activeDriver",
      op.capabilityIds)
  of vokReleaseDriver:
    op.principalId == op.driverPrincipalId or
      state.hasLiveCapability(op.principalId, capControlDebugger, "activeDriver",
        op.capabilityIds)
  of vokRevokeDriver:
    state.hasLiveCapability(op.principalId, capControlDebugger, "activeDriver",
      op.capabilityIds)
  else:
    false

proc validateDebugCommand(state: SharedSessionViewState; op: ViewOpEnvelope): ApplyResult =
  if not state.hasRequiredCapability(op):
    return rejected("principal lacks capability for debug command")
  if state.activeDriver.principalId.len == 0:
    return rejected("no active driver")
  if op.principalId != state.activeDriver.principalId:
    return rejected("principal is not active driver")
  if op.driverLeaseId.len == 0 or op.driverLeaseId != state.activeDriver.leaseId:
    return rejected("driver lease mismatch")
  ignored("debug command accepted by reducer but not executed in M1")

proc applyViewOp*(document: var SharedSessionDocument; op: ViewOpEnvelope): ApplyResult =
  if op.opId.len == 0:
    return rejected("missing opId")
  if document.hasApplied(op.opId):
    return duplicate()
  if op.protocolVersion != CurrentCollabProtocolVersion:
    return rejected("unsupported protocolVersion")
  if document.state.sessionId.len > 0 and op.sessionId != document.state.sessionId:
    return rejected("sessionId mismatch")
  if document.state.sessionId.len == 0:
    document.state.sessionId = op.sessionId

  var changed = false
  case op.kind
  of vokUnknown:
    changed = false
  of vokSetRegister:
    # =====================================================================
    # `LAW-X5` — TEXT IS NEVER RESOLVED BY A REGISTER, AND THE REFUSAL IS
    # EXPLICIT RATHER THAN A FALL-THROUGH
    # =====================================================================
    # `applyScalarRegister`'s `case op.targetPath` has an `else: false`, so a
    # register op aimed at `editor.documents` would be *ignored* — "recorded
    # but did not change shared state" — which is indistinguishable from a
    # stale stamp losing a race. The milestone's verification gate asks for an
    # explicit refusal for exactly that reason: the failure mode it exists to
    # catch is text QUIETLY landing in the register path, and quiet is what an
    # `ignored` is.
    #
    # It is checked before the capability, deliberately. A principal who holds
    # `capMutateSharedViewState` and aims it at the text is the case this is
    # for, and a capability refusal would tell them the wrong thing.
    if op.targetPath.startsWith("editor.documents") or
        op.targetPath.startsWith("editor.remoteSelections"):
      return rejected(
        "text is not a register: editor.documents and editor.remoteSelections " &
        "are resolved by rebase against the authority (the fourth merge " &
        "family), never by last-writer-wins")
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for scalar register mutation")
    changed = document.state.applyScalarRegister(op)
  of vokSetFocusedPanel, vokSetCalltraceSelection, vokSetCalltraceSearch,
      vokSetStateTab:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for scalar register mutation")
    changed = document.state.applyTypedScalar(op)
  of vokToggleCalltraceExpansion:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for expansion mutation")
    changed = document.state.calltrace.expandedNodes.applyExpansion(
      op, getBoolField(op.payload, ["expanded"], true))
  of vokToggleStatePath:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for expansion mutation")
    changed = document.state.statePane.expandedPaths.applyExpansion(
      op, getBoolField(op.payload, ["expanded"], true))
  of vokExpand:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for expansion mutation")
    if op.targetPath.startsWith("statePane."):
      changed = document.state.statePane.expandedPaths.applyExpansion(op, true)
    else:
      changed = document.state.calltrace.expandedNodes.applyExpansion(op, true)
  of vokCollapse:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for expansion mutation")
    if op.targetPath.startsWith("statePane."):
      changed = document.state.statePane.expandedPaths.applyExpansion(op, false)
    else:
      changed = document.state.calltrace.expandedNodes.applyExpansion(op, false)
  of vokAddWatch:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for watch mutation")
    changed = document.state.statePane.applyAddWatch(op)
  of vokEditWatch:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for watch mutation")
    changed = document.state.statePane.applyEditWatch(op)
  of vokRemoveWatch:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for watch mutation")
    changed = document.state.statePane.applyRemoveWatch(op)
  of vokMoveWatch:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for watch mutation")
    changed = document.state.statePane.applyMoveWatch(op)
  of vokSetBreakpoint:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for breakpoint mutation")
    changed = document.state.applySetBreakpoint(op)
  of vokRemoveBreakpoint:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for breakpoint mutation")
    changed = document.state.applyRemoveBreakpoint(op)
  of vokCreatePanel:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for layout mutation")
    changed = document.state.applyCreatePanel(op)
  of vokClosePanel:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for layout mutation")
    changed = document.state.applyClosePanel(op)
  of vokMovePanel:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for layout mutation")
    changed = document.state.applyMovePanel(op)
  of vokSetPanelVisibility:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for layout mutation")
    changed = document.state.applyPanelVisibility(op)
  of vokGrantCapabilities:
    if not document.state.canGrantCapabilities(op.principalId):
      return rejected("principal cannot grant capabilities")
    if not document.state.canDelegateCapabilities(
        op.principalId, getCapabilitySeq(op.payload),
        getStrSeqField(op.payload, ["targetPaths"])):
      return rejected("principal cannot delegate requested capabilities")
    changed = document.state.applyGrantCapabilities(op)
  of vokRevokeCapabilities:
    if not document.state.canGrantCapabilities(op.principalId):
      return rejected("principal cannot revoke capabilities")
    changed = document.state.applyRevokeCapabilities(op)
  of vokRequestDriver, vokGrantDriver, vokReleaseDriver, vokRevokeDriver:
    if op.driverLeaseId.len == 0:
      return rejected("missing driver leaseId")
    if not document.state.canApplyDriverOp(op):
      return rejected("principal cannot change active driver")
    changed = document.state.applyDriver(op)
  of vokFollowParticipant, vokUnfollowParticipant:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for follow mutation")
    changed = document.state.applyFollow(op)
  of vokDebugCommand:
    let validation = document.state.validateDebugCommand(op)
    if validation.status == asRejected:
      return validation
    changed = false
  of vokSubmitTextUpdate:
    # A REQUEST, not a mutation — the authority appends, every replica
    # records for dedup and changes nothing. The capability is still checked
    # here, so an ungated peer is refused at submission rather than at the
    # authority, which is where a refusal is cheap and visible.
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for text update")
    if getStrField(op.payload, ["documentId", "id"]).len == 0:
      return rejected("text submission names no document")
    document.markApplied(op)
    return ignored("text submission accepted by the reducer; the authority appends it")
  of vokAcceptTextUpdate:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for text update")
    # **ONLY THE SESSION AUTHORITY MAY EXTEND THE LOG.** Without this every
    # replica could append at a version of its own choosing and the log's
    # order would be a function of who spoke, which is the failure mode the
    # whole rebase-with-an-authority design exists to avoid.
    if not document.state.isSessionAuthority(op.principalId):
      return rejected("only the session authority may append to the text log")
    # `LAW-X5`'s other half: a text op wearing a REGISTER'S PAYLOAD — a
    # `value` and a stamp, no change set — is refused by name rather than
    # ignored. Without this the planted LWW-shaped update is "recorded but did
    # not change shared state", which is what a legitimately-losing register
    # write also reports, and the arm that plants it has nothing to land on.
    if getStrField(op.payload, ["changes"]).len == 0:
      return rejected(
        "a text update carries a change set, not a value: this payload has " &
        "no `changes` field and text is not resolved by a register")
    changed = document.state.applyAcceptTextUpdate(op)
  of vokSetTextSelection:
    if not document.state.hasRequiredCapability(op):
      return rejected("principal lacks capability for caret awareness")
    changed = document.state.applyTextSelection(op)

  document.state.normalize()
  document.markApplied(op)
  if changed:
    applied()
  else:
    ignored("operation recorded but did not change shared state")

proc visibleExpansionIds*(entries: openArray[AddWinsSetEntry]): seq[string] =
  for entry in entries:
    if entry.isLive:
      result.add entry.id
  result.sort(cmp[string])

proc visibleWatches*(state: SharedStateViewState): seq[SharedWatch] =
  for watch in state.watchExpressions:
    if watch.isLive:
      result.add watch
  result.sort(proc(a, b: SharedWatch): int =
    let orderCmp = cmp(a.orderKey, b.orderKey)
    if orderCmp != 0: orderCmp else: cmp(a.id, b.id))

proc visibleBreakpoints*(state: SharedSessionViewState): seq[SharedBreakpoint] =
  for bp in state.breakpoints:
    if bp.isLive:
      result.add bp
  result.sort(proc(a, b: SharedBreakpoint): int = cmp(a.id, b.id))

proc visiblePanels*(state: SharedSessionViewState): seq[LogicalPanel] =
  for panel in state.layout:
    if panel.isLive:
      result.add panel
  result.sort(proc(a, b: LogicalPanel): int =
    let parentCmp = cmp(a.parentId, b.parentId)
    if parentCmp != 0:
      parentCmp
    else:
      let orderCmp = cmp(a.orderKey, b.orderKey)
      if orderCmp != 0: orderCmp else: cmp(a.id, b.id))

proc applyBackendSnapshot*(
    state: var SharedSessionViewState;
    family: string;
    ownerId: PrincipalId;
    backendEpoch: uint64;
    payload: JsonNode): bool =
  ## Backend facts are not CRDT-merged. M1 locks each fact family to one owner;
  ## a different owner is rejected until a later authority-transfer protocol
  ## exists. For the same owner, only a greater epoch is accepted.
  for snapshot in state.backendSnapshots.mitems:
    if snapshot.family == family:
      if snapshot.ownerId != ownerId:
        return false
      if backendEpoch <= snapshot.backendEpoch:
        return false
      snapshot.backendEpoch = backendEpoch
      snapshot.payload = payload
      return true
  state.backendSnapshots.add BackendSnapshotRegister(
    family: family,
    ownerId: ownerId,
    backendEpoch: backendEpoch,
    payload: payload,
  )
  state.backendSnapshots.sort(proc(a, b: BackendSnapshotRegister): int =
    cmp(a.family, b.family))
  true
