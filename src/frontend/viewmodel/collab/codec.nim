## Schema-versioned JSON codec for collaborative ViewModel operations.
##
## Unknown top-level fields on operation envelopes are preserved in
## ``ViewOpEnvelope.unknownFields`` and emitted again. Unknown operation kind
## names are preserved separately so they are never coerced to a known reducer
## mutation. Unknown payload fields are naturally preserved because payloads are
## opaque JSON for M1 reducers.
## Unknown state/snapshot fields are ignored in M1 because reducers own the
## canonical in-memory schema and snapshots are not forwarded as envelopes.

import std/[algorithm, json, strutils]

import ./types

const KnownEnvelopeFields = [
  "protocolVersion", "sessionId", "principalId", "actorId", "replicaId",
  "actorSeq", "opId", "lamport", "capabilityIds", "targetPath", "kind",
  "payload"
]

proc parseEnumValue[T: enum](name: string; fallback: T): T =
  for value in T:
    if $value == name:
      return value
  fallback

proc parseViewOpKind(name: string): ViewOpKind =
  for value in ViewOpKind:
    if value != vokUnknown and $value == name:
      return value
  vokUnknown

proc parseUint64(node: JsonNode; fallback = 0'u64): uint64 =
  if node.isNil:
    return fallback
  case node.kind
  of JInt:
    node.getBiggestInt.uint64
  of JString:
    try:
      parseUInt(node.getStr).uint64
    except ValueError:
      fallback
  else:
    fallback

proc jsonArray(items: openArray[string]): JsonNode =
  result = newJArray()
  for item in items:
    result.add %item

proc jsonArray(items: openArray[CapabilityKind]): JsonNode =
  result = newJArray()
  for item in items:
    result.add %($item)

proc toJson*(stamp: CollabStamp): JsonNode =
  %*{
    "lamport": %stamp.lamport,
    "actorId": stamp.actorId,
  }

proc parseStamp*(node: JsonNode): CollabStamp =
  if node.isNil:
    return CollabStamp()
  CollabStamp(
    lamport: parseUint64(node{"lamport"}),
    actorId: node{"actorId"}.getStr(""),
  )

proc toJson*(reg: LwwStringRegister): JsonNode =
  %*{"value": reg.value, "stamp": reg.stamp.toJson}

proc parseLwwStringRegister(node: JsonNode): LwwStringRegister =
  if node.isNil:
    return LwwStringRegister()
  LwwStringRegister(
    value: node{"value"}.getStr(""),
    stamp: parseStamp(node{"stamp"}),
  )

proc toJson*(reg: DriverRegister): JsonNode =
  %*{
    "principalId": reg.principalId,
    "leaseId": reg.leaseId,
    "stamp": reg.stamp.toJson,
  }

proc parseDriverRegister(node: JsonNode): DriverRegister =
  if node.isNil:
    return DriverRegister()
  DriverRegister(
    principalId: node{"principalId"}.getStr(""),
    leaseId: node{"leaseId"}.getStr(""),
    stamp: parseStamp(node{"stamp"}),
  )

proc toJson*(entry: AddWinsSetEntry): JsonNode =
  %*{
    "id": entry.id,
    "addTags": jsonArray(entry.addTags),
    "removedAddTags": jsonArray(entry.removedAddTags),
  }

proc parseAddWinsSetEntry(node: JsonNode): AddWinsSetEntry =
  result.id = node{"id"}.getStr("")
  for tag in node{"addTags"}.getElems(@[]):
    result.addTags.add tag.getStr("")
  for tag in node{"removedAddTags"}.getElems(@[]):
    result.removedAddTags.add tag.getStr("")

proc toJson*(grant: CapabilityGrant): JsonNode =
  %*{
    "id": grant.id,
    "subject": grant.subject,
    "issuer": grant.issuer,
    "capabilities": jsonArray(grant.capabilities),
    "targetPaths": jsonArray(grant.targetPaths),
    "addOpId": grant.addOpId,
    "revokedByOpId": grant.revokedByOpId,
  }

proc parseCapabilityGrant(node: JsonNode): CapabilityGrant =
  result.id = node{"id"}.getStr("")
  result.subject = node{"subject"}.getStr("")
  result.issuer = node{"issuer"}.getStr("")
  result.addOpId = node{"addOpId"}.getStr("")
  result.revokedByOpId = node{"revokedByOpId"}.getStr("")
  for capNode in node{"capabilities"}.getElems(@[]):
    result.capabilities.add parseEnumValue(capNode.getStr(""), capObserve)
  for pathNode in node{"targetPaths"}.getElems(@[]):
    result.targetPaths.add pathNode.getStr("")

proc toJson*(principal: PrincipalDescriptor): JsonNode =
  %*{
    "id": principal.id,
    "kind": $principal.kind,
    "displayName": principal.displayName,
  }

proc parsePrincipalDescriptor(node: JsonNode): PrincipalDescriptor =
  PrincipalDescriptor(
    id: node{"id"}.getStr(""),
    kind: parseEnumValue(node{"kind"}.getStr(""), pkUser),
    displayName: node{"displayName"}.getStr(""),
  )

proc toJson*(actor: ActorDescriptor): JsonNode =
  %*{
    "id": actor.id,
    "principalId": actor.principalId,
  }

proc parseActorDescriptor(node: JsonNode): ActorDescriptor =
  ActorDescriptor(
    id: node{"id"}.getStr(""),
    principalId: node{"principalId"}.getStr(""),
  )

proc toJson*(replica: ReplicaDescriptor): JsonNode =
  %*{
    "id": replica.id,
    "actorId": replica.actorId,
  }

proc parseReplicaDescriptor(node: JsonNode): ReplicaDescriptor =
  ReplicaDescriptor(
    id: node{"id"}.getStr(""),
    actorId: node{"actorId"}.getStr(""),
  )

proc toJson*(watch: SharedWatch): JsonNode =
  %*{
    "id": watch.id,
    "expression": watch.expression,
    "orderKey": watch.orderKey,
    "addTags": jsonArray(watch.addTags),
    "removedAddTags": jsonArray(watch.removedAddTags),
    "expressionStamp": watch.expressionStamp.toJson,
    "orderStamp": watch.orderStamp.toJson,
  }

proc parseSharedWatch(node: JsonNode): SharedWatch =
  result.id = node{"id"}.getStr("")
  result.expression = node{"expression"}.getStr("")
  result.orderKey = node{"orderKey"}.getStr("")
  result.expressionStamp = parseStamp(node{"expressionStamp"})
  result.orderStamp = parseStamp(node{"orderStamp"})
  for tag in node{"addTags"}.getElems(@[]):
    result.addTags.add tag.getStr("")
  for tag in node{"removedAddTags"}.getElems(@[]):
    result.removedAddTags.add tag.getStr("")

proc toJson*(bp: SharedBreakpoint): JsonNode =
  %*{
    "id": bp.id,
    "file": bp.file,
    "line": bp.line,
    "condition": bp.condition,
    "enabled": bp.enabled,
    "addTags": jsonArray(bp.addTags),
    "removedAddTags": jsonArray(bp.removedAddTags),
    "fileStamp": bp.fileStamp.toJson,
    "lineStamp": bp.lineStamp.toJson,
    "conditionStamp": bp.conditionStamp.toJson,
    "enabledStamp": bp.enabledStamp.toJson,
  }

proc parseSharedBreakpoint(node: JsonNode): SharedBreakpoint =
  result.id = node{"id"}.getStr("")
  result.file = node{"file"}.getStr("")
  result.line = node{"line"}.getInt(0)
  result.condition = node{"condition"}.getStr("")
  result.enabled = node{"enabled"}.getBool(false)
  result.fileStamp = parseStamp(node{"fileStamp"})
  result.lineStamp = parseStamp(node{"lineStamp"})
  result.conditionStamp = parseStamp(node{"conditionStamp"})
  result.enabledStamp = parseStamp(node{"enabledStamp"})
  for tag in node{"addTags"}.getElems(@[]):
    result.addTags.add tag.getStr("")
  for tag in node{"removedAddTags"}.getElems(@[]):
    result.removedAddTags.add tag.getStr("")

proc toJson*(panel: LogicalPanel): JsonNode =
  %*{
    "id": panel.id,
    "kind": $panel.kind,
    "parentId": panel.parentId,
    "orderKey": panel.orderKey,
    "isVisible": panel.isVisible,
    "addTags": jsonArray(panel.addTags),
    "removedAddTags": jsonArray(panel.removedAddTags),
    "parentStamp": panel.parentStamp.toJson,
    "orderStamp": panel.orderStamp.toJson,
    "visibilityStamp": panel.visibilityStamp.toJson,
  }

proc parseLogicalPanel(node: JsonNode): LogicalPanel =
  result.id = node{"id"}.getStr("")
  result.kind = parseEnumValue(node{"kind"}.getStr(""), lpkCustom)
  result.parentId = node{"parentId"}.getStr("")
  result.orderKey = node{"orderKey"}.getStr("")
  result.isVisible = node{"isVisible"}.getBool(false)
  result.parentStamp = parseStamp(node{"parentStamp"})
  result.orderStamp = parseStamp(node{"orderStamp"})
  result.visibilityStamp = parseStamp(node{"visibilityStamp"})
  for tag in node{"addTags"}.getElems(@[]):
    result.addTags.add tag.getStr("")
  for tag in node{"removedAddTags"}.getElems(@[]):
    result.removedAddTags.add tag.getStr("")

proc toJson*(follow: FollowRegister): JsonNode =
  %*{
    "actorId": follow.actorId,
    "followedPrincipalId": follow.followedPrincipalId,
    "stamp": follow.stamp.toJson,
  }

proc parseFollowRegister(node: JsonNode): FollowRegister =
  FollowRegister(
    actorId: node{"actorId"}.getStr(""),
    followedPrincipalId: node{"followedPrincipalId"}.getStr(""),
    stamp: parseStamp(node{"stamp"}),
  )

proc toJson*(backend: BackendSnapshotRegister): JsonNode =
  %*{
    "family": backend.family,
    "ownerId": backend.ownerId,
    "backendEpoch": %backend.backendEpoch,
    "payload": if backend.payload.isNil: newJObject() else: backend.payload,
  }

proc parseBackendSnapshotRegister(node: JsonNode): BackendSnapshotRegister =
  BackendSnapshotRegister(
    family: node{"family"}.getStr(""),
    ownerId: node{"ownerId"}.getStr(""),
    backendEpoch: parseUint64(node{"backendEpoch"}),
    payload: if node{"payload"}.isNil: newJObject() else: node{"payload"},
  )

proc toJson*(state: SharedSessionViewState): JsonNode =
  var grants = newJArray()
  for grant in state.capabilityGrants:
    grants.add grant.toJson
  var principals = newJArray()
  for principal in state.principals:
    principals.add principal.toJson
  var actors = newJArray()
  for actor in state.actors:
    actors.add actor.toJson
  var replicas = newJArray()
  for replica in state.replicas:
    replicas.add replica.toJson
  var layout = newJArray()
  for panel in state.layout:
    layout.add panel.toJson
  var calltraceExpanded = newJArray()
  for entry in state.calltrace.expandedNodes:
    calltraceExpanded.add entry.toJson
  var stateExpanded = newJArray()
  for entry in state.statePane.expandedPaths:
    stateExpanded.add entry.toJson
  var watches = newJArray()
  for watch in state.statePane.watchExpressions:
    watches.add watch.toJson
  var breakpoints = newJArray()
  for bp in state.breakpoints:
    breakpoints.add bp.toJson
  var follows = newJArray()
  for follow in state.followState:
    follows.add follow.toJson
  var backends = newJArray()
  for backend in state.backendSnapshots:
    backends.add backend.toJson

  %*{
    "schemaVersion": state.schemaVersion,
    "traceIdentity": state.traceIdentity,
    "sessionId": state.sessionId,
    "revision": %state.revision,
    "activeSessionId": state.activeSessionId.toJson,
    "authority": {
      "principalId": state.authority.principalId,
      "backendOwnerId": state.authority.backendOwnerId,
    },
    "principals": principals,
    "actors": actors,
    "replicas": replicas,
    "capabilityGrants": grants,
    "activeDriver": state.activeDriver.toJson,
    "closedDriverLeases": jsonArray(state.closedDriverLeases),
    "focusedPanelId": state.focusedPanelId.toJson,
    "layout": layout,
    "calltrace": {
      "selectedEntry": state.calltrace.selectedEntry.toJson,
      "searchQuery": state.calltrace.searchQuery.toJson,
      "expandedNodes": calltraceExpanded,
    },
    "statePane": {
      "activeTab": state.statePane.activeTab.toJson,
      "selectedPath": state.statePane.selectedPath.toJson,
      "expandedPaths": stateExpanded,
      "watchExpressions": watches,
    },
    "editor": {
      "activeDocumentId": state.editor.activeDocumentId.toJson,
    },
    "breakpoints": breakpoints,
    "followState": follows,
    "backendSnapshots": backends,
  }

proc parseSharedSessionViewState*(node: JsonNode): SharedSessionViewState =
  result.schemaVersion = node{"schemaVersion"}.getInt(CurrentCollabSchemaVersion)
  result.traceIdentity = node{"traceIdentity"}.getStr("")
  result.sessionId = node{"sessionId"}.getStr("")
  result.revision = parseUint64(node{"revision"})
  result.activeSessionId = parseLwwStringRegister(node{"activeSessionId"})
  result.authority = SessionAuthority(
    principalId: node{"authority"}{"principalId"}.getStr(""),
    backendOwnerId: node{"authority"}{"backendOwnerId"}.getStr(""),
  )
  for principal in node{"principals"}.getElems(@[]):
    result.principals.add parsePrincipalDescriptor(principal)
  for actor in node{"actors"}.getElems(@[]):
    result.actors.add parseActorDescriptor(actor)
  for replica in node{"replicas"}.getElems(@[]):
    result.replicas.add parseReplicaDescriptor(replica)
  result.activeDriver = parseDriverRegister(node{"activeDriver"})
  for leaseId in node{"closedDriverLeases"}.getElems(@[]):
    result.closedDriverLeases.add leaseId.getStr("")
  result.focusedPanelId = parseLwwStringRegister(node{"focusedPanelId"})
  for grant in node{"capabilityGrants"}.getElems(@[]):
    result.capabilityGrants.add parseCapabilityGrant(grant)
  for panel in node{"layout"}.getElems(@[]):
    result.layout.add parseLogicalPanel(panel)
  for entry in node{"calltrace"}{"expandedNodes"}.getElems(@[]):
    result.calltrace.expandedNodes.add parseAddWinsSetEntry(entry)
  result.calltrace.selectedEntry =
    parseLwwStringRegister(node{"calltrace"}{"selectedEntry"})
  result.calltrace.searchQuery =
    parseLwwStringRegister(node{"calltrace"}{"searchQuery"})
  result.statePane.activeTab =
    parseLwwStringRegister(node{"statePane"}{"activeTab"})
  result.statePane.selectedPath =
    parseLwwStringRegister(node{"statePane"}{"selectedPath"})
  for entry in node{"statePane"}{"expandedPaths"}.getElems(@[]):
    result.statePane.expandedPaths.add parseAddWinsSetEntry(entry)
  for watch in node{"statePane"}{"watchExpressions"}.getElems(@[]):
    result.statePane.watchExpressions.add parseSharedWatch(watch)
  result.editor.activeDocumentId =
    parseLwwStringRegister(node{"editor"}{"activeDocumentId"})
  for bp in node{"breakpoints"}.getElems(@[]):
    result.breakpoints.add parseSharedBreakpoint(bp)
  for follow in node{"followState"}.getElems(@[]):
    result.followState.add parseFollowRegister(follow)
  for backend in node{"backendSnapshots"}.getElems(@[]):
    result.backendSnapshots.add parseBackendSnapshotRegister(backend)

proc toJson*(op: ViewOpEnvelope): JsonNode =
  result = newJObject()
  if not op.unknownFields.isNil and op.unknownFields.kind == JObject:
    for key, value in op.unknownFields:
      result[key] = value
  result["protocolVersion"] = %op.protocolVersion
  result["sessionId"] = %op.sessionId
  result["principalId"] = %op.principalId
  result["actorId"] = %op.actorId
  result["replicaId"] = %op.replicaId
  result["actorSeq"] = %op.actorSeq
  result["opId"] = %op.opId
  result["lamport"] = %op.lamport
  result["capabilityIds"] = jsonArray(op.capabilityIds)
  result["targetPath"] = %op.targetPath
  result["kind"] = %(
    if op.kind == vokUnknown and op.kindName.len > 0: op.kindName else: $op.kind)
  result["payload"] = if op.payload.isNil: newJObject() else: op.payload

proc parseViewOpEnvelope*(node: JsonNode): ViewOpEnvelope =
  var unknown = newJObject()
  if not node.isNil and node.kind == JObject:
    for key, value in node:
      if not KnownEnvelopeFields.contains(key):
        unknown[key] = value

  let kindName = node{"kind"}.getStr("")
  let kind = parseViewOpKind(kindName)
  result = ViewOpEnvelope(
    protocolVersion:
      node{"protocolVersion"}.getInt(CurrentCollabProtocolVersion),
    sessionId: node{"sessionId"}.getStr(""),
    principalId: node{"principalId"}.getStr(""),
    actorId: node{"actorId"}.getStr(""),
    replicaId: node{"replicaId"}.getStr(""),
    actorSeq: parseUint64(node{"actorSeq"}),
    opId: node{"opId"}.getStr(""),
    lamport: parseUint64(node{"lamport"}),
    targetPath: node{"targetPath"}.getStr(""),
    kind: kind,
    kindName: if kind == vokUnknown: kindName else: "",
    payload: if node{"payload"}.isNil: newJObject() else: node{"payload"},
    unknownFields: unknown,
  )
  for capId in node{"capabilityIds"}.getElems(@[]):
    result.capabilityIds.add capId.getStr("")

proc toJson*(snapshot: SharedSessionSnapshot): JsonNode =
  let opIds = snapshot.appliedOpIds.sorted(cmp[string])
  %*{
    "schemaVersion": snapshot.schemaVersion,
    "documentRevision": %snapshot.documentRevision,
    "state": snapshot.state.toJson,
    "appliedOpIds": jsonArray(opIds),
  }

proc parseSharedSessionSnapshot*(node: JsonNode): SharedSessionSnapshot =
  result.schemaVersion = node{"schemaVersion"}.getInt(CurrentCollabSchemaVersion)
  result.documentRevision = parseUint64(node{"documentRevision"})
  result.state = parseSharedSessionViewState(node{"state"})
  for opId in node{"appliedOpIds"}.getElems(@[]):
    result.appliedOpIds.add opId.getStr("")
