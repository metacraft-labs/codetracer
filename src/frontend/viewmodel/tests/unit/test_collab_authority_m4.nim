## Unit tests for M4 backend command authority and snapshots.
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_collab_authority_m4.nim

import std/[asyncdispatch, json, sequtils, unittest]

import isonim/core/async_compat

import ../../backend/[backend_service, mock_backend]
import ../../collab/[authority, backend_snapshots, capabilities, codec, reducer, types]

const
  TestSession = "session-m4"
  AdminPrincipal = "principal-admin"
  BackendOwner = "principal-backend"

proc newDoc(authorityPrincipalId = AdminPrincipal;
            backendOwnerId = BackendOwner): SharedSessionDocument =
  initSharedSessionDocument(
    sessionId = TestSession,
    traceIdentity = "trace-m4",
    authorityPrincipalId = authorityPrincipalId,
    backendOwnerId = backendOwnerId,
  )

proc op(kind: ViewOpKind;
        opId: string;
        lamport: uint64;
        principalId = AdminPrincipal;
        actorId = "actor-admin";
        targetPath = "";
        payload = newJObject();
        capabilityIds: seq[CapabilityGrantId] = @[]): ViewOpEnvelope =
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: TestSession,
    principalId: principalId,
    actorId: actorId,
    replicaId: actorId & "-replica",
    actorSeq: lamport,
    opId: opId,
    lamport: lamport,
    capabilityIds: capabilityIds,
    targetPath: targetPath,
    kind: kind,
    payload: payload,
    unknownFields: newJObject(),
  )

proc grantOp(grantId, subject, opId: string;
             capabilities: seq[CapabilityKind];
             targetPaths: seq[string];
             lamport: uint64;
             principalId = AdminPrincipal;
             actorId = "actor-admin";
             cited: seq[CapabilityGrantId] = @[]): ViewOpEnvelope =
  op(vokGrantCapabilities, opId, lamport,
    principalId = principalId,
    actorId = actorId,
    targetPath = "capabilityGrants",
    capabilityIds = cited,
    payload = %*{
      "grantId": grantId,
      "subject": subject,
      "capabilities": capabilities.mapIt($it),
      "targetPaths": targetPaths,
    })

proc revokeOp(grantId, opId: string; lamport: uint64): ViewOpEnvelope =
  op(vokRevokeCapabilities, opId, lamport,
    targetPath = "capabilityGrants",
    payload = %*{"grantId": grantId})

proc driverGrantOp(principalId, leaseId, opId: string; lamport: uint64):
                   ViewOpEnvelope =
  op(vokGrantDriver, opId, lamport,
    targetPath = "activeDriver",
    payload = %*{"principalId": principalId, "leaseId": leaseId})

proc driverRequestOp(principalId, actorId, leaseId, opId: string; lamport: uint64;
                     grantIds: seq[CapabilityGrantId] = @[]): ViewOpEnvelope =
  op(vokRequestDriver, opId, lamport,
    principalId = principalId,
    actorId = actorId,
    targetPath = "activeDriver",
    capabilityIds = grantIds,
    payload = %*{"principalId": principalId, "leaseId": leaseId})

proc driverReleaseOp(principalId, actorId, leaseId, opId: string; lamport: uint64):
                     ViewOpEnvelope =
  op(vokReleaseDriver, opId, lamport,
    principalId = principalId,
    actorId = actorId,
    targetPath = "activeDriver",
    payload = %*{"principalId": principalId, "leaseId": leaseId})

proc driverRevokeOp(principalId, actorId, leaseId, opId: string; lamport: uint64;
                    grantIds: seq[CapabilityGrantId] = @[]): ViewOpEnvelope =
  op(vokRevokeDriver, opId, lamport,
    principalId = principalId,
    actorId = actorId,
    targetPath = "activeDriver",
    capabilityIds = grantIds,
    payload = %*{"leaseId": leaseId})

proc debugOp(principalId, actorId, opId, leaseId: string;
             lamport: uint64;
             grantIds: seq[CapabilityGrantId] = @["grant-debug"];
             command = "next"): ViewOpEnvelope =
  op(vokDebugCommand, opId, lamport,
    principalId = principalId,
    actorId = actorId,
    targetPath = "debugger.commands",
    capabilityIds = grantIds,
    payload = %*{
      "command": command,
      "leaseId": leaseId,
      "args": {"threadId": 1},
    })

type
  SerializedBackend = ref object
    inFlight*: bool
    violations*: int
    commands*: seq[string]
    pending*: seq[BackendFuture[JsonNode]]

proc newSerializedBackend(): tuple[service: BackendService, recorder: SerializedBackend] =
  let recorder = SerializedBackend()
  let sendProc = proc(command: string; args: JsonNode): BackendFuture[JsonNode] =
    if recorder.inFlight:
      recorder.violations.inc
    recorder.inFlight = true
    recorder.commands.add command
    result = newFuture[JsonNode]("SerializedBackend.send")
    recorder.pending.add result
  let service = BackendService(
    sendProc: sendProc,
    onEventProc: proc(handler: EventHandler) = discard,
    disconnectProc: proc() = discard,
  )
  (service, recorder)

suite "collaborative ViewModel M4 backend authority":

  test "test_collab_principal_actor_replica_model_roundtrips":
    var doc = newDoc(backendOwnerId = "service-backend")
    doc.state.registerPrincipal PrincipalDescriptor(
      id: "principal-user",
      kind: pkUser,
      displayName: "User",
    )
    doc.state.registerPrincipal PrincipalDescriptor(
      id: "service-backend",
      kind: pkService,
      displayName: "Backend host",
    )
    doc.state.registerActor ActorDescriptor(
      id: "actor-user",
      principalId: "principal-user",
    )
    doc.state.registerReplica ReplicaDescriptor(
      id: "replica-user-1",
      actorId: "actor-user",
    )

    let parsed = parseSharedSessionViewState(doc.state.toJson)

    check parsed.principals.anyIt(it.id == AdminPrincipal and it.kind == pkUser)
    check parsed.principals.anyIt(it.id == "service-backend" and it.kind == pkService)
    check parsed.actors.anyIt(it.id == "actor-user" and it.principalId == "principal-user")
    check parsed.replicas.anyIt(it.id == "replica-user-1" and it.actorId == "actor-user")

  test "test_collab_driver_lease_serializes_step_commands":
    var doc = newDoc()
    let mock = newMockBackendService(autoRespond = true)
    let authority = newBackendCommandAuthority(BackendOwner, mock.toBackendService())
    let driver = "principal-driver"
    let nonDriver = "principal-non-driver"

    check doc.applyViewOp(grantOp(
      "grant-debug", driver, "grant-debug-op",
      @[capControlDebugger], @["activeDriver", "debugger.commands"], 1)).status == asApplied
    check doc.applyViewOp(grantOp(
      "grant-debug-other", nonDriver, "grant-debug-other-op",
      @[capControlDebugger], @["activeDriver", "debugger.commands"], 2)).status == asApplied
    check doc.applyViewOp(driverGrantOp(driver, "lease-driver", "driver-op", 3)).status == asApplied

    let first = authority.submitDebugCommand(
      doc, debugOp(driver, "actor-driver", "debug-driver", "lease-driver", 4))
    let second = authority.submitDebugCommand(
      doc, debugOp(nonDriver, "actor-other", "debug-other", "lease-driver", 5,
        grantIds = @["grant-debug-other"]))

    check first.status != asRejected
    check second.status == asRejected
    check authority.acceptedCommands.len == 1
    check authority.acceptedCommands[0].command == "next"
    check mock.receivedCommands.len == 1
    check mock.receivedCommands[0].command == "next"
    check authority.auditLog.mapIt(it.kind) ==
      @[aekDebugCommandAccepted, aekDebugCommandRejected]

  test "test_collab_backend_command_queue_serializes_accepted_debug_commands":
    var doc = newDoc()
    let backend = newSerializedBackend()
    let authority = newBackendCommandAuthority(BackendOwner, backend.service)
    let driver = "principal-driver"

    check doc.applyViewOp(grantOp(
      "grant-debug", driver, "grant-debug-op",
      @[capControlDebugger], @["activeDriver", "debugger.commands"], 1)).status == asApplied
    check doc.applyViewOp(driverGrantOp(driver, "lease-driver", "driver-op", 2)).status == asApplied

    let first = authority.submitDebugCommand(
      doc, debugOp(driver, "actor-driver", "debug-next", "lease-driver", 3,
        command = "next"))
    let second = authority.submitDebugCommand(
      doc, debugOp(driver, "actor-driver", "debug-step-in", "lease-driver", 4,
        command = "stepIn"))

    check first.status != asRejected
    check second.status != asRejected
    check backend.recorder.commands == @["next"]
    check authority.pending.len == 1
    check authority.acceptedCommands.len == 1
    check backend.recorder.violations == 0

    backend.recorder.inFlight = false
    backend.recorder.pending[0].complete(%*{})
    try:
      poll(0)
    except ValueError:
      discard

    check backend.recorder.commands == @["next", "stepIn"]
    check authority.pending.len == 0
    check authority.acceptedCommands.len == 2
    check backend.recorder.violations == 0

  test "test_collab_non_driver_debug_command_is_rejected":
    var doc = newDoc()
    let mock = newMockBackendService(autoRespond = true)
    let authority = newBackendCommandAuthority(BackendOwner, mock.toBackendService())
    let driver = "principal-driver"
    let other = "principal-other"

    check doc.applyViewOp(grantOp(
      "grant-debug", other, "grant-debug-op",
      @[capControlDebugger], @["activeDriver", "debugger.commands"], 1)).status == asApplied
    check doc.applyViewOp(driverGrantOp(driver, "lease-driver", "driver-op", 2)).status == asApplied

    let result = authority.submitDebugCommand(
      doc, debugOp(other, "actor-other", "debug-other", "lease-driver", 3))

    check result.status == asRejected
    check mock.receivedCommands.len == 0
    check authority.acceptedCommands.len == 0
    check authority.auditLog[^1].kind == aekDebugCommandRejected

  test "test_collab_driver_request_release_revoke_require_authority":
    var doc = newDoc()
    let driver = "principal-driver"
    let outsider = "principal-outsider"

    check doc.applyViewOp(driverRequestOp(
      driver, "actor-driver", "lease-denied", "request-denied", 1)).status ==
        asRejected

    check doc.applyViewOp(grantOp(
      "grant-driver", driver, "grant-driver-op",
      @[capControlDebugger], @["activeDriver", "debugger.commands"], 2)).status ==
        asApplied

    check doc.applyViewOp(driverRequestOp(
      driver, "actor-driver", "lease-driver", "request-driver", 3,
      grantIds = @["grant-driver"])).status == asApplied
    check doc.state.activeDriver.principalId == driver
    check doc.state.activeDriver.leaseId == "lease-driver"

    var accepted = debugOp(driver, "actor-driver", "debug-after-request",
      "lease-driver", 4, grantIds = @["grant-driver"])
    check doc.applyViewOp(accepted).status == asIgnored

    check doc.applyViewOp(driverReleaseOp(
      driver, "actor-driver", "lease-driver", "release-driver", 5)).status ==
        asApplied
    check doc.state.activeDriver.principalId == ""
    check "lease-driver" in doc.state.closedDriverLeases

    check doc.applyViewOp(driverGrantOp(
      driver, "lease-admin", "grant-admin-driver", 6)).status == asApplied
    check doc.applyViewOp(driverRevokeOp(
      outsider, "actor-outsider", "lease-admin", "revoke-denied", 7)).status ==
        asRejected
    check doc.state.activeDriver.leaseId == "lease-admin"

    check doc.applyViewOp(driverRevokeOp(
      AdminPrincipal, "actor-admin", "lease-admin", "revoke-admin", 8)).status ==
        asApplied
    check doc.state.activeDriver.principalId == ""
    check "lease-admin" in doc.state.closedDriverLeases

  test "test_collab_viewer_only_cannot_mutate_shared_state":
    var doc = newDoc()
    let viewer = "principal-viewer"
    check doc.applyViewOp(grantOp(
      "grant-viewer", viewer, "grant-viewer-op",
      @[capObserve, capPublishAwareness], @["followState"], 1)).status == asApplied

    let beforeSelection = doc.state.calltrace.selectedEntry.value
    let mutate = op(vokSetCalltraceSelection, "viewer-select", 2,
      principalId = viewer,
      actorId = "actor-viewer",
      targetPath = "calltrace.selectedEntry",
      payload = %*{"entryId": "42"},
      capabilityIds = @["grant-viewer"])
    check doc.applyViewOp(mutate).status == asRejected
    check doc.state.calltrace.selectedEntry.value == beforeSelection

    let awareness = op(vokFollowParticipant, "viewer-follow", 3,
      principalId = viewer,
      actorId = "actor-viewer",
      targetPath = "followState",
      payload = %*{"followedPrincipalId": AdminPrincipal},
      capabilityIds = @["grant-viewer"])
    check doc.applyViewOp(awareness).status == asApplied
    check doc.state.followState.len == 1

  test "test_collab_capability_grant_attenuation":
    var doc = newDoc()
    let delegator = "principal-delegator"
    let subject = "principal-subject"
    check doc.applyViewOp(grantOp(
      "grant-delegator", delegator, "grant-delegator-op",
      @[capGrantCapabilities, capManageWatches],
      @["capabilityGrants", "statePane.watchExpressions"], 1)).status == asApplied

    let tooBroad = grantOp(
      "grant-too-broad", subject, "grant-too-broad-op",
      @[capManageBreakpoints], @["breakpoints"], 2,
      principalId = delegator,
      actorId = "actor-delegator",
      cited = @["grant-delegator"])
    check doc.applyViewOp(tooBroad).status == asRejected

    let attenuated = grantOp(
      "grant-attenuated", subject, "grant-attenuated-op",
      @[capManageWatches], @["statePane.watchExpressions.locals"], 3,
      principalId = delegator,
      actorId = "actor-delegator",
      cited = @["grant-delegator"])
    check doc.applyViewOp(attenuated).status == asApplied

  test "test_collab_revoked_capability_rejects_later_ops":
    var doc = newDoc()
    let user = "principal-user"
    check doc.applyViewOp(grantOp(
      "grant-watch", user, "grant-watch-op",
      @[capManageWatches], @["statePane.watchExpressions"], 1)).status == asApplied
    check doc.applyViewOp(revokeOp("grant-watch", "revoke-watch-op", 2)).status == asApplied

    let addWatch = op(vokAddWatch, "watch-after-revoke", 3,
      principalId = user,
      actorId = "actor-user",
      targetPath = "statePane.watchExpressions",
      capabilityIds = @["grant-watch"],
      payload = %*{"watchId": "watch-1", "expression": "counter", "orderKey": "m"})
    check doc.applyViewOp(addWatch).status == asRejected
    check visibleWatches(doc.state.statePane).len == 0

  test "test_collab_headless_service_principal_can_host_backend":
    let service = "service-backend"
    var doc = newDoc(authorityPrincipalId = AdminPrincipal, backendOwnerId = service)
    doc.state.registerPrincipal PrincipalDescriptor(
      id: service,
      kind: pkService,
      displayName: "hosted backend",
    )

    let snapshot = backendSnapshot(
      sessionId = TestSession,
      backendOwnerId = service,
      emittedByPrincipalId = service,
      family = "debugger",
      backendEpoch = 1,
      payload = %*{"rrTicks": 10, "status": "dsIdle"},
    )
    let result = doc.applyAuthoritativeBackendSnapshot(snapshot)

    check result.status == asApplied
    check doc.state.backendSnapshots.len == 1
    check doc.state.backendSnapshots[0].ownerId == service
    check doc.state.principals.anyIt(it.id == service and it.kind == pkService)

  test "test_collab_backend_snapshot_epoch_rejects_stale_data":
    var doc = newDoc()
    let fresh = backendSnapshot(
      sessionId = TestSession,
      backendOwnerId = BackendOwner,
      emittedByPrincipalId = BackendOwner,
      family = "debugger",
      backendEpoch = 2,
      payload = %*{"rrTicks": 20, "status": "dsIdle"},
    )
    let stale = backendSnapshot(
      sessionId = TestSession,
      backendOwnerId = BackendOwner,
      emittedByPrincipalId = BackendOwner,
      family = "debugger",
      backendEpoch = 1,
      payload = %*{"rrTicks": 10, "status": "dsIdle"},
    )

    check doc.applyAuthoritativeBackendSnapshot(fresh).status == asApplied
    check doc.applyAuthoritativeBackendSnapshot(stale).status == asRejected
    check doc.state.backendSnapshots.len == 1
    check doc.state.backendSnapshots[0].backendEpoch == 2'u64
    check doc.state.backendSnapshots[0].payload["rrTicks"].getInt == 20
