## Deterministic reducers for collaborative SharedSessionViewState operations.

import std/[algorithm, json, strutils]

import ./types

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

proc isAuthority(state: SharedSessionViewState; principalId: PrincipalId): bool =
  if principalId.len > 0 and
      (principalId == state.authority.principalId or
       principalId == state.authority.backendOwnerId):
    return true

proc pathCovers(grantPath, targetPath: string): bool =
  grantPath.len == 0 or grantPath == "*" or grantPath == targetPath or
    targetPath.startsWith(grantPath & ".") or
    targetPath.startsWith(grantPath & "[")

proc targetPathsCover(targetPaths: openArray[string]; targetPath: string): bool =
  if targetPaths.len == 0:
    return true
  for grantPath in targetPaths:
    if grantPath.pathCovers(targetPath):
      return true

proc liveCapability(
    state: SharedSessionViewState;
    principalId: PrincipalId;
    cap: CapabilityKind;
    targetPath = "";
    capabilityIds: openArray[CapabilityGrantId] = []): bool =
  if state.isAuthority(principalId):
    return true
  for grant in state.capabilityGrants:
    if grant.subject == principalId and grant.revokedByOpId.len == 0 and
        (capabilityIds.len == 0 or capabilityIds.containsString(grant.id)) and
        grant.targetPaths.targetPathsCover(targetPath):
      for granted in grant.capabilities:
        if granted == cap:
          return true

proc canGrantCapabilities(state: SharedSessionViewState; principalId: PrincipalId): bool =
  liveCapability(state, principalId, capGrantCapabilities, "capabilityGrants")

proc canDelegateCapabilities(state: SharedSessionViewState;
                             principalId: PrincipalId;
                             capabilities: openArray[CapabilityKind];
                             targetPaths: openArray[string]): bool =
  if state.isAuthority(principalId):
    return true
  for capability in capabilities:
    if targetPaths.len == 0:
      if not state.liveCapability(principalId, capability):
        return false
    else:
      for targetPath in targetPaths:
        if not state.liveCapability(principalId, capability, targetPath):
          return false
  true

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

proc opTargetPath(op: ViewOpEnvelope; fallback: string): string =
  if op.targetPath.len > 0: op.targetPath else: fallback

proc requiredCapability(op: ViewOpEnvelope): tuple[needed: bool, cap: CapabilityKind, targetPath: string] =
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
  else:
    (false, capObserve, "")

proc hasRequiredCapability(state: SharedSessionViewState; op: ViewOpEnvelope): bool =
  let required = op.requiredCapability
  not required.needed or state.liveCapability(
    op.principalId, required.cap, required.targetPath, op.capabilityIds)

proc driverPrincipalId(op: ViewOpEnvelope): PrincipalId =
  getStrField(op.payload, ["principalId"], op.principalId)

proc canApplyDriverOp(state: SharedSessionViewState; op: ViewOpEnvelope): bool =
  case op.kind
  of vokRequestDriver, vokGrantDriver:
    state.liveCapability(op.principalId, capControlDebugger, "activeDriver",
      op.capabilityIds)
  of vokReleaseDriver:
    op.principalId == op.driverPrincipalId or
      state.liveCapability(op.principalId, capControlDebugger, "activeDriver",
        op.capabilityIds)
  of vokRevokeDriver:
    state.liveCapability(op.principalId, capControlDebugger, "activeDriver",
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
