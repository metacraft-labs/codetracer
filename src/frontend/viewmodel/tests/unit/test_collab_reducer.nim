## Unit tests for M1 collaborative ViewModel operation envelopes and reducers.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_collab_reducer.nim

import std/[algorithm, json, sequtils, unittest]

import ../../collab/types
import ../../collab/codec
import ../../collab/reducer

const
  TestSession = "session-m1"
  AdminPrincipal = "principal-admin"
  BackendOwner = "principal-backend"

proc op(
    kind: ViewOpKind;
    opId: string;
    lamport: uint64;
    actorId = "actor-a";
    principalId = AdminPrincipal;
    targetPath = "";
    payload = newJObject()): ViewOpEnvelope =
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: TestSession,
    principalId: principalId,
    actorId: actorId,
    replicaId: actorId & "-replica",
    actorSeq: lamport,
    opId: opId,
    lamport: lamport,
    capabilityIds: @["grant-root"],
    targetPath: targetPath,
    kind: kind,
    kindName: "",
    payload: payload,
    unknownFields: newJObject(),
  )

proc grantCapabilitiesOp(
    grantId, subject, opId: string;
    capabilities: seq[CapabilityKind];
    targetPaths: seq[string];
    lamport: uint64): ViewOpEnvelope =
  op(vokGrantCapabilities, opId, lamport,
    actorId = "actor-admin",
    principalId = AdminPrincipal,
    targetPath = "capabilityGrants",
    payload = %*{
      "grantId": grantId,
      "subject": subject,
      "capabilities": capabilities.mapIt($it),
      "targetPaths": targetPaths,
    })

proc newDoc(): SharedSessionDocument =
  initSharedSessionDocument(
    sessionId = TestSession,
    traceIdentity = "trace-1",
    authorityPrincipalId = AdminPrincipal,
    backendOwnerId = BackendOwner,
  )

proc applyAll(ops: openArray[ViewOpEnvelope]): SharedSessionDocument =
  result = newDoc()
  for item in ops:
    discard result.applyViewOp(item)

proc canonicalState(doc: SharedSessionDocument): string =
  $(doc.state.toJson)

proc addWatchOp(id, expression, orderKey, opId: string;
                lamport: uint64; actorId = "actor-a"): ViewOpEnvelope =
  op(vokAddWatch, opId, lamport, actorId = actorId,
    targetPath = "statePane.watchExpressions",
    payload = %*{
      "watchId": id,
      "expression": expression,
      "orderKey": orderKey,
    })

proc moveWatchOp(id, orderKey, opId: string;
                 lamport: uint64; actorId = "actor-a"): ViewOpEnvelope =
  op(vokMoveWatch, opId, lamport, actorId = actorId,
    targetPath = "statePane.watchExpressions",
    payload = %*{"watchId": id, "orderKey": orderKey})

proc breakpointOp(id, opId: string; lamport: uint64;
                  actorId = "actor-a"; line = 10): ViewOpEnvelope =
  op(vokSetBreakpoint, opId, lamport, actorId = actorId,
    targetPath = "breakpoints",
    payload = %*{
      "breakpointId": id,
      "file": "src/main.nim",
      "line": line,
      "condition": "x > 0",
      "enabled": true,
    })

proc removeBreakpointOp(id, opId: string; lamport: uint64;
                        observed: seq[string];
                        actorId = "actor-b"): ViewOpEnvelope =
  op(vokRemoveBreakpoint, opId, lamport, actorId = actorId,
    targetPath = "breakpoints",
    payload = %*{"breakpointId": id, "observedAddTags": observed})

proc createPanelOp(id, orderKey, opId: string; lamport: uint64;
                   kind = lpkEditor; actorId = "actor-a"): ViewOpEnvelope =
  op(vokCreatePanel, opId, lamport, actorId = actorId,
    targetPath = "layout.panels",
    payload = %*{
      "panelId": id,
      "kind": $kind,
      "parentId": "root",
      "orderKey": orderKey,
      "isVisible": true,
    })

proc movePanelOp(id, parentId, orderKey, opId: string; lamport: uint64;
                 actorId = "actor-a"): ViewOpEnvelope =
  op(vokMovePanel, opId, lamport, actorId = actorId,
    targetPath = "layout.panels",
    payload = %*{
      "panelId": id,
      "parentId": parentId,
      "orderKey": orderKey,
    })

suite "collaborative ViewModel M1 reducers and codec":

  test "test_collab_viewop_json_roundtrip_all_kinds":
    for kind in ViewOpKind:
      var original = op(kind, "op-" & $kind, 42'u64,
        actorId = "actor-json",
        principalId = "principal-json",
        targetPath = "statePane.watchExpressions",
        payload = %*{
          "kindName": $kind,
          "watchId": "watch-json",
          "orderKey": "m",
          "futurePayloadField": {"nested": true},
        })
      original.replicaId = "replica-json"
      original.actorSeq = 99'u64
      original.capabilityIds = @["cap-a", "cap-b"]
      original.unknownFields = %*{
        "futureEnvelopeField": {"preserve": true},
        "futureScalar": "kept",
      }

      let encoded = original.toJson
      check encoded["protocolVersion"].getInt == CurrentCollabProtocolVersion
      check encoded["futureEnvelopeField"]["preserve"].getBool
      let parsed = parseViewOpEnvelope(encoded)

      check parsed.protocolVersion == original.protocolVersion
      check parsed.sessionId == original.sessionId
      check parsed.principalId == original.principalId
      check parsed.actorId == original.actorId
      check parsed.replicaId == original.replicaId
      check parsed.actorSeq == original.actorSeq
      check parsed.opId == original.opId
      check parsed.lamport == original.lamport
      check parsed.capabilityIds == original.capabilityIds
      check parsed.targetPath == original.targetPath
      check parsed.kind == kind
      check parsed.payload["kindName"].getStr == $kind
      check parsed.payload["futurePayloadField"]["nested"].getBool
      check parsed.unknownFields["futureScalar"].getStr == "kept"
      check parsed.toJson["futureEnvelopeField"]["preserve"].getBool

    var doc = newDoc()
    let select = op(vokSetCalltraceSelection, "snapshot-op", 1,
      targetPath = "calltrace.selectedEntry",
      payload = %*{"entryId": "call-1"})
    discard doc.applyViewOp(select)
    let snap = doc.snapshot
    let snapJson = snap.toJson
    check snapJson["schemaVersion"].getInt == CurrentCollabSchemaVersion
    check snapJson["documentRevision"].getBiggestInt == 1
    check snapJson["appliedOpIds"][0].getStr == "snapshot-op"
    let parsedSnap = parseSharedSessionSnapshot(snapJson)
    check parsedSnap.documentRevision == 1'u64
    check parsedSnap.appliedOpIds == @["snapshot-op"]
    check parsedSnap.state.calltrace.selectedEntry.value == "call-1"

  test "test_collab_reducer_idempotent_duplicate_ops":
    var doc = newDoc()
    let select = op(vokSetCalltraceSelection, "select-1", 10,
      actorId = "actor-a",
      targetPath = "calltrace.selectedEntry",
      payload = %*{"entryId": "call-42"})

    let first = doc.applyViewOp(select)
    let afterFirst = canonicalState(doc)
    let revision = doc.state.revision
    let second = doc.applyViewOp(select)

    check first.status == asApplied
    check second.status == asDuplicate
    check doc.state.revision == revision
    check doc.appliedOpIds == @["select-1"]
    check canonicalState(doc) == afterFirst
    check doc.state.calltrace.selectedEntry.value == "call-42"

  test "test_collab_reducer_converges_under_reordered_ops":
    let ops = @[
      op(vokSetCalltraceSelection, "select-old", 3, actorId = "actor-a",
        targetPath = "calltrace.selectedEntry",
        payload = %*{"entryId": "call-old"}),
      op(vokSetCalltraceSelection, "select-new", 3, actorId = "actor-b",
        targetPath = "calltrace.selectedEntry",
        payload = %*{"entryId": "call-new"}),
      op(vokExpand, "expand-a", 4, actorId = "actor-a",
        targetPath = "calltrace.expandedNodes",
        payload = %*{"nodeId": "node-1"}),
      op(vokCollapse, "collapse-observed-a", 5, actorId = "actor-b",
        targetPath = "calltrace.expandedNodes",
        payload = %*{"nodeId": "node-1", "observedAddTags": ["expand-a"]}),
      op(vokExpand, "expand-concurrent", 5, actorId = "actor-c",
        targetPath = "calltrace.expandedNodes",
        payload = %*{"nodeId": "node-1"}),
      addWatchOp("watch-a", "a", "m", "watch-a-add", 6, actorId = "actor-a"),
      moveWatchOp("watch-a", "z", "watch-a-move", 7, actorId = "actor-b"),
      breakpointOp("bp-1", "bp-add", 8, actorId = "actor-a", line = 10),
      removeBreakpointOp("bp-1", "bp-remove", 9, @["bp-add"], actorId = "actor-b"),
      breakpointOp("bp-1", "bp-update", 9, actorId = "actor-c", line = 20),
      createPanelOp("panel-calltrace", "m", "panel-create", 10,
        kind = lpkCalltrace, actorId = "actor-a"),
      movePanelOp("panel-calltrace", "right", "b", "panel-move", 11,
        actorId = "actor-b"),
      op(vokGrantCapabilities, "grant-watches", 12, actorId = "actor-admin",
        principalId = AdminPrincipal,
        targetPath = "capabilityGrants",
        payload = %*{
          "grantId": "grant-watches",
          "subject": "principal-user",
          "capabilities": [$capManageWatches],
          "targetPaths": ["statePane.watchExpressions"],
        }),
      op(vokRevokeCapabilities, "revoke-watches", 13, actorId = "actor-admin",
        principalId = AdminPrincipal,
        targetPath = "capabilityGrants",
        payload = %*{"grantId": "grant-watches"}),
      op(vokGrantDriver, "driver-a", 14, actorId = "actor-a",
        principalId = AdminPrincipal,
        targetPath = "activeDriver",
        payload = %*{"principalId": "principal-driver-a", "leaseId": "lease-a"}),
      op(vokGrantDriver, "driver-b", 14, actorId = "actor-b",
        principalId = AdminPrincipal,
        targetPath = "activeDriver",
        payload = %*{"principalId": "principal-driver-b", "leaseId": "lease-b"}),
    ]

    let forward = applyAll(ops)
    let reverse = applyAll(ops.reversed)

    check canonicalState(forward) == canonicalState(reverse)
    check forward.state.calltrace.selectedEntry.value == "call-new"
    check visibleExpansionIds(forward.state.calltrace.expandedNodes) == @["node-1"]
    check visibleWatches(forward.state.statePane)[0].orderKey == "z"
    check visibleBreakpoints(forward.state)[0].line == 20
    check visiblePanels(forward.state)[0].parentId == "right"
    check forward.state.capabilityGrants[0].revokedByOpId == "revoke-watches"
    check forward.state.activeDriver.principalId == "principal-driver-b"

  test "test_collab_reducer_rejects_unauthorized_shared_mutations":
    var doc = newDoc()
    let user = "principal-user"
    let unauthorized = @[
      op(vokSetCalltraceSelection, "unauth-select", 1,
        principalId = user,
        targetPath = "calltrace.selectedEntry",
        payload = %*{"entryId": "call-unauthorized"}),
      op(vokExpand, "unauth-expand", 2,
        principalId = user,
        targetPath = "calltrace.expandedNodes",
        payload = %*{"nodeId": "call-node"}),
      op(vokAddWatch, "unauth-watch", 3,
        principalId = user,
        targetPath = "statePane.watchExpressions",
        payload = %*{"watchId": "watch-unauth", "expression": "x"}),
      op(vokSetBreakpoint, "unauth-breakpoint", 4,
        principalId = user,
        targetPath = "breakpoints",
        payload = %*{"breakpointId": "bp-unauth", "file": "a.nim", "line": 1}),
      op(vokCreatePanel, "unauth-panel", 5,
        principalId = user,
        targetPath = "layout.panels",
        payload = %*{"panelId": "panel-unauth", "kind": $lpkState}),
      op(vokFollowParticipant, "unauth-follow", 6,
        principalId = user,
        targetPath = "followState",
        payload = %*{"principalId": AdminPrincipal}),
    ]

    for item in unauthorized:
      let before = canonicalState(doc)
      let result = doc.applyViewOp(item)
      check result.status == asRejected
      check canonicalState(doc) == before

    check doc.state.revision == 0'u64
    check doc.appliedOpIds.len == 0
    check visibleExpansionIds(doc.state.calltrace.expandedNodes).len == 0
    check visibleWatches(doc.state.statePane).len == 0
    check visibleBreakpoints(doc.state).len == 0
    check visiblePanels(doc.state).len == 0
    check doc.state.followState.len == 0

  test "test_collab_reducer_enforces_capability_target_paths":
    var doc = newDoc()
    let user = "principal-user"
    let grant = grantCapabilitiesOp(
      "grant-calltrace-mutator", user, "grant-calltrace-mutator-op",
      @[capMutateSharedViewState], @["calltrace"], 1)
    check doc.applyViewOp(grant).status == asApplied

    var allowed = op(vokSetCalltraceSelection, "allowed-select", 2,
      principalId = user,
      targetPath = "calltrace.selectedEntry",
      payload = %*{"entryId": "call-allowed"})
    allowed.capabilityIds = @["grant-calltrace-mutator"]
    check doc.applyViewOp(allowed).status == asApplied
    check doc.state.calltrace.selectedEntry.value == "call-allowed"

    var wrongKind = op(vokAddWatch, "wrong-kind-watch", 3,
      principalId = user,
      targetPath = "statePane.watchExpressions",
      payload = %*{"watchId": "watch-wrong-kind", "expression": "x"})
    wrongKind.capabilityIds = @["grant-calltrace-mutator"]
    check doc.applyViewOp(wrongKind).status == asRejected
    check visibleWatches(doc.state.statePane).len == 0

    var wrongPath = op(vokSetRegister, "wrong-path-register", 4,
      principalId = user,
      targetPath = "statePane.activeTab",
      payload = %*{"value": "locals"})
    wrongPath.capabilityIds = @["grant-calltrace-mutator"]
    check doc.applyViewOp(wrongPath).status == asRejected
    check doc.state.statePane.activeTab.value == ""

  test "test_collab_debug_command_requires_capability_and_active_driver_lease":
    var doc = newDoc()
    let user = "principal-driver"
    var unauthorized = op(vokDebugCommand, "debug-unauthorized", 1,
      principalId = user,
      targetPath = "debugger.commands",
      payload = %*{"command": "stepOver", "leaseId": "lease-missing"})
    unauthorized.capabilityIds = @[]
    check doc.applyViewOp(unauthorized).status == asRejected
    check doc.state.revision == 0'u64
    check doc.state.backendSnapshots.len == 0

    let grant = grantCapabilitiesOp(
      "grant-debug-driver", user, "grant-debug-driver-op",
      @[capControlDebugger], @["activeDriver", "debugger.commands"], 2)
    check doc.applyViewOp(grant).status == asApplied

    let driver = op(vokGrantDriver, "driver-grant-user", 3,
      principalId = AdminPrincipal,
      targetPath = "activeDriver",
      payload = %*{"principalId": user, "leaseId": "lease-user"})
    check doc.applyViewOp(driver).status == asApplied

    var wrongLease = op(vokDebugCommand, "debug-wrong-lease", 4,
      principalId = user,
      targetPath = "debugger.commands",
      payload = %*{"command": "stepOver", "leaseId": "lease-other"})
    wrongLease.capabilityIds = @["grant-debug-driver"]
    check doc.applyViewOp(wrongLease).status == asRejected

    var accepted = op(vokDebugCommand, "debug-accepted", 5,
      principalId = user,
      targetPath = "debugger.commands",
      payload = %*{"command": "stepOver", "leaseId": "lease-user"})
    accepted.capabilityIds = @["grant-debug-driver"]
    let acceptedResult = doc.applyViewOp(accepted)
    check acceptedResult.status == asIgnored
    check doc.appliedOpIds.contains("debug-accepted")
    check doc.state.backendSnapshots.len == 0

  test "test_collab_driver_release_admin_grant_reorders_deterministically":
    let oldDriver = "principal-old-driver"
    let newDriver = "principal-new-driver"
    let initialGrant = op(vokGrantDriver, "driver-old", 1,
      principalId = AdminPrincipal,
      targetPath = "activeDriver",
      payload = %*{"principalId": oldDriver, "leaseId": "lease-old"})
    let adminGrant = op(vokGrantDriver, "driver-new", 2,
      principalId = AdminPrincipal,
      targetPath = "activeDriver",
      payload = %*{"principalId": newDriver, "leaseId": "lease-new"})
    let oldRelease = op(vokReleaseDriver, "driver-old-release", 3,
      principalId = oldDriver,
      targetPath = "activeDriver",
      payload = %*{"principalId": oldDriver, "leaseId": "lease-old"})

    var releaseThenGrant = newDoc()
    check releaseThenGrant.applyViewOp(initialGrant).status == asApplied
    check releaseThenGrant.applyViewOp(oldRelease).status == asApplied
    check releaseThenGrant.applyViewOp(adminGrant).status == asApplied

    var grantThenRelease = newDoc()
    check grantThenRelease.applyViewOp(initialGrant).status == asApplied
    check grantThenRelease.applyViewOp(adminGrant).status == asApplied
    check grantThenRelease.applyViewOp(oldRelease).status == asApplied

    check canonicalState(releaseThenGrant) == canonicalState(grantThenRelease)
    check releaseThenGrant.appliedOpIds == grantThenRelease.appliedOpIds
    check releaseThenGrant.state.revision == grantThenRelease.state.revision
    check releaseThenGrant.state.activeDriver.principalId == newDriver
    check releaseThenGrant.state.activeDriver.leaseId == "lease-new"
    check releaseThenGrant.state.closedDriverLeases == @["lease-old"]

  test "test_collab_unknown_operation_kind_is_preserved_and_ignored":
    let parsed = parseViewOpEnvelope(%*{
      "protocolVersion": CurrentCollabProtocolVersion,
      "sessionId": TestSession,
      "principalId": AdminPrincipal,
      "actorId": "actor-future",
      "replicaId": "actor-future-replica",
      "actorSeq": 1,
      "opId": "future-op",
      "lamport": 1,
      "capabilityIds": ["grant-root"],
      "targetPath": "calltrace.selectedEntry",
      "kind": "vokFutureSetSelection",
      "payload": {"value": "must-not-apply"},
      "futureEnvelopeField": true,
    })

    check parsed.kind == vokUnknown
    check parsed.kindName == "vokFutureSetSelection"
    check parsed.toJson["kind"].getStr == "vokFutureSetSelection"
    check parsed.toJson["futureEnvelopeField"].getBool

    var doc = newDoc()
    let result = doc.applyViewOp(parsed)
    check result.status == asIgnored
    check doc.state.calltrace.selectedEntry.value == ""
    check doc.appliedOpIds == @["future-op"]

  test "test_collab_lww_register_tie_breaker_is_deterministic":
    let a = op(vokSetRegister, "lww-a", 100, actorId = "actor-a",
      targetPath = "editor.activeDocumentId",
      payload = %*{"value": "doc-a"})
    let b = op(vokSetRegister, "lww-b", 100, actorId = "actor-b",
      targetPath = "editor.activeDocumentId",
      payload = %*{"value": "doc-b"})

    let ab = applyAll([a, b])
    let ba = applyAll([b, a])

    check canonicalState(ab) == canonicalState(ba)
    check ab.state.editor.activeDocumentId.value == "doc-b"
    check ab.state.editor.activeDocumentId.stamp.actorId == "actor-b"

  test "test_collab_expansion_set_is_add_wins_or_set":
    let expand = op(vokExpand, "expand-node", 1, actorId = "actor-a",
      targetPath = "calltrace.expandedNodes",
      payload = %*{"nodeId": "call-node"})
    let concurrentCollapse = op(vokCollapse, "collapse-unobserved", 1,
      actorId = "actor-b",
      targetPath = "calltrace.expandedNodes",
      payload = %*{"nodeId": "call-node", "observedAddTags": []})

    let concurrent = applyAll([concurrentCollapse, expand])
    check visibleExpansionIds(concurrent.state.calltrace.expandedNodes) ==
      @["call-node"]

    let observedCollapse = op(vokCollapse, "collapse-observed", 2,
      actorId = "actor-b",
      targetPath = "calltrace.expandedNodes",
      payload = %*{"nodeId": "call-node", "observedAddTags": ["expand-node"]})
    var observed = applyAll([observedCollapse, expand])
    check visibleExpansionIds(observed.state.calltrace.expandedNodes).len == 0

    let stateExpand = op(vokExpand, "expand-state", 3,
      targetPath = "statePane.expandedPaths",
      payload = %*{"path": "locals.user"})
    discard observed.applyViewOp(stateExpand)
    check visibleExpansionIds(observed.state.statePane.expandedPaths) ==
      @["locals.user"]

  test "test_collab_watch_list_fractional_ordering":
    let addB = addWatchOp("watch-b", "b", "m", "watch-b-add", 1,
      actorId = "actor-b")
    let addA = addWatchOp("watch-a", "a", "m", "watch-a-add", 1,
      actorId = "actor-a")
    let moveA = moveWatchOp("watch-a", "z", "watch-a-move-a", 2,
      actorId = "actor-a")
    let moveAConcurrent = moveWatchOp("watch-a", "a", "watch-a-move-b", 2,
      actorId = "actor-b")

    let doc = applyAll([moveA, addB, moveAConcurrent, addA])
    let watches = visibleWatches(doc.state.statePane)

    check watches.mapIt(it.id) == @["watch-a", "watch-b"]
    check watches[0].orderKey == "a"
    check watches[0].expression == "a"
    check watches[1].orderKey == "m"

  test "test_collab_breakpoint_observed_remove_set":
    let add1 = breakpointOp("bp-1", "bp-add-1", 1, actorId = "actor-a", line = 10)
    let removeObserved = removeBreakpointOp("bp-1", "bp-remove-1", 2,
      @["bp-add-1"], actorId = "actor-b")
    let add2 = breakpointOp("bp-1", "bp-add-2", 2, actorId = "actor-c", line = 20)

    let forward = applyAll([add1, removeObserved, add2])
    let reverse = applyAll([add2, removeObserved, add1])

    check canonicalState(forward) == canonicalState(reverse)
    let live = visibleBreakpoints(forward.state)
    check live.len == 1
    check live[0].id == "bp-1"
    check live[0].line == 20
    check live[0].addTags.sorted(cmp[string]) == @["bp-add-1", "bp-add-2"]
    check live[0].removedAddTags == @["bp-add-1"]

  test "test_collab_layout_panel_move_uses_stable_ids":
    let createA = createPanelOp("panel-a", "m", "panel-a-create", 1,
      kind = lpkCalltrace, actorId = "actor-a")
    let createB = createPanelOp("panel-b", "m", "panel-b-create", 1,
      kind = lpkState, actorId = "actor-b")
    let moveA = movePanelOp("panel-a", "left", "a", "panel-a-move", 2,
      actorId = "actor-a")
    let moveB = movePanelOp("panel-b", "left", "a", "panel-b-move", 2,
      actorId = "actor-b")
    let moveAConcurrent = movePanelOp("panel-a", "right", "z",
      "panel-a-move-b", 2, actorId = "actor-b")

    let doc = applyAll([moveA, createB, moveB, moveAConcurrent, createA])
    let panels = visiblePanels(doc.state)

    check panels.mapIt(it.id) == @["panel-b", "panel-a"]
    check panels[0].parentId == "left"
    check panels[0].orderKey == "a"
    check panels[1].parentId == "right"
    check panels[1].orderKey == "z"
    check doc.state.layout.anyIt(it.id == "panel-a" and it.kind == lpkCalltrace)
    check doc.state.layout.anyIt(it.id == "panel-b" and it.kind == lpkState)

  test "test_collab_backend_snapshots_reject_cross_owner_merge":
    var state = initSharedSessionViewState(
      sessionId = TestSession,
      traceIdentity = "trace-1",
      authorityPrincipalId = AdminPrincipal,
      backendOwnerId = "owner-a",
    )

    check state.applyBackendSnapshot("locals", "owner-a", 1, %*{"value": "a1"})
    check not state.applyBackendSnapshot("locals", "owner-b", 2, %*{"value": "b2"})
    check not state.applyBackendSnapshot("locals", "owner-a", 1, %*{"value": "stale"})
    check state.applyBackendSnapshot("locals", "owner-a", 2, %*{"value": "a2"})

    check state.backendSnapshots.len == 1
    check state.backendSnapshots[0].family == "locals"
    check state.backendSnapshots[0].ownerId == "owner-a"
    check state.backendSnapshots[0].backendEpoch == 2'u64
    check state.backendSnapshots[0].payload["value"].getStr == "a2"
