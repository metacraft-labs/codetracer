## Backend command authority for collaborative sessions.

import std/json

import isonim/core/async_compat

import ../backend/[backend_service, dap_commands]
import ./[reducer, types]

type
  AuditEventKind* = enum
    aekCapabilityGranted,
    aekCapabilityDenied,
    aekCapabilityRevoked,
    aekDriverRequested,
    aekDriverGranted,
    aekDriverReleased,
    aekDriverRevoked,
    aekDebugCommandAccepted,
    aekDebugCommandRejected

  AuditLogEntry* = object
    sequence*: uint64
    kind*: AuditEventKind
    principalId*: PrincipalId
    actorId*: ActorId
    opId*: ViewOpId
    grantId*: CapabilityGrantId
    leaseId*: DriverLeaseId
    command*: string
    status*: ApplyStatus
    reason*: string

  QueuedBackendCommand* = object
    sequence*: uint64
    opId*: ViewOpId
    principalId*: PrincipalId
    actorId*: ActorId
    leaseId*: DriverLeaseId
    command*: string
    args*: JsonNode

  BackendCommandAuthority* = ref object
    backendOwnerId*: PrincipalId
    backend*: BackendService
    nextSequence*: uint64
    inFlight*: bool
    pending*: seq[QueuedBackendCommand]
    acceptedCommands*: seq[QueuedBackendCommand]
    auditLog*: seq[AuditLogEntry]

const DriverOnlyDebugCommands* = [
  "next",
  "stepIn",
  "stepOut",
  "continue",
  "stepBack",
  "reverseContinue",
  "ct/reverseStepIn",
  "ct/reverseStepOut",
  "ct/calltrace-jump",
  "ct/event-jump",
  "ct/source-line-jump",
  "ct/source-call-jump",
  "ct/local-step-jump",
  "ct/trace-jump",
  "ct/timeline-seek",
  "ct/flow-jump",
  "ct/mcr-restore-at",
  "ct/live-restore-at",
  "ct/mcr-live-step",
  "ct/seek-to-geid",
]

proc newBackendCommandAuthority*(backendOwnerId: PrincipalId;
                                 backend: BackendService):
                                 BackendCommandAuthority =
  BackendCommandAuthority(
    backendOwnerId: backendOwnerId,
    backend: backend,
    pending: @[],
    acceptedCommands: @[],
    auditLog: @[],
  )

proc containsString(items: openArray[string]; value: string): bool =
  for item in items:
    if item == value:
      return true

proc payloadStr(op: ViewOpEnvelope; key: string): string =
  if op.payload.isNil: "" else: op.payload{key}.getStr("")

proc driverLeaseId*(op: ViewOpEnvelope): DriverLeaseId =
  op.payloadStr("leaseId")

proc grantId(op: ViewOpEnvelope): CapabilityGrantId =
  if op.payload.isNil: "" else: op.payload{"grantId"}.getStr(op.payload{"id"}.getStr(""))

proc canonicalDebugCommand*(command: string): string =
  case command
  of "stepOver": "next"
  of "reverseStepOver": "stepBack"
  else: command

proc debugCommandName*(op: ViewOpEnvelope): string =
  canonicalDebugCommand(op.payloadStr("command"))

proc isDriverOnlyDebugCommand*(command: string): bool =
  DriverOnlyDebugCommands.containsString(canonicalDebugCommand(command))

proc debugCommandArgs(op: ViewOpEnvelope): JsonNode =
  if op.payload.isNil:
    return newJObject()
  let args = op.payload{"args"}
  if args.isNil: newJObject() else: args

proc appendAudit(authority: BackendCommandAuthority;
                 kind: AuditEventKind;
                 op: ViewOpEnvelope;
                 status: ApplyStatus;
                 reason = "") =
  if authority.isNil:
    return
  authority.nextSequence.inc
  authority.auditLog.add AuditLogEntry(
    sequence: authority.nextSequence,
    kind: kind,
    principalId: op.principalId,
    actorId: op.actorId,
    opId: op.opId,
    grantId: op.grantId,
    leaseId: op.driverLeaseId,
    command: op.debugCommandName,
    status: status,
    reason: reason,
  )

proc auditViewOp*(authority: BackendCommandAuthority;
                  op: ViewOpEnvelope;
                  result: ApplyResult) =
  let kind =
    case op.kind
    of vokGrantCapabilities:
      if result.status == asRejected: aekCapabilityDenied else: aekCapabilityGranted
    of vokRevokeCapabilities:
      if result.status == asRejected: aekCapabilityDenied else: aekCapabilityRevoked
    of vokRequestDriver:
      aekDriverRequested
    of vokGrantDriver:
      aekDriverGranted
    of vokReleaseDriver:
      aekDriverReleased
    of vokRevokeDriver:
      aekDriverRevoked
    of vokDebugCommand:
      if result.status == asRejected: aekDebugCommandRejected else: aekDebugCommandAccepted
    else:
      return
  authority.appendAudit(kind, op, result.status, result.reason)

proc processQueue(authority: BackendCommandAuthority) =
  if authority.isNil or authority.backend.isNil or authority.inFlight:
    return
  if authority.pending.len == 0:
    return

  let command = authority.pending[0]
  authority.pending.delete(0)
  authority.inFlight = true
  authority.acceptedCommands.add command
  let fut = authority.backend.send(command.command, command.args)
  let a = authority
  async_compat.onComplete(fut,
    onSuccess = proc(response: JsonNode) =
      a.inFlight = false
      a.processQueue(),
    onError = proc(msg: string) =
      a.inFlight = false
      a.processQueue(),
  )

proc enqueueBackendCommand(authority: BackendCommandAuthority;
                           op: ViewOpEnvelope) =
  authority.nextSequence.inc
  authority.pending.add QueuedBackendCommand(
    sequence: authority.nextSequence,
    opId: op.opId,
    principalId: op.principalId,
    actorId: op.actorId,
    leaseId: op.driverLeaseId,
    command: op.debugCommandName,
    args: op.debugCommandArgs,
  )
  authority.processQueue()

proc submitDebugCommand*(authority: BackendCommandAuthority;
                         document: var SharedSessionDocument;
                         op: ViewOpEnvelope): ApplyResult =
  if op.kind != vokDebugCommand:
    return rejected("not a debug command")

  let command = op.debugCommandName
  if command.len == 0:
    result = rejected("missing debug command")
    authority.auditViewOp(op, result)
    return
  if not command.isValidDapCommand:
    result = rejected("invalid debug command")
    authority.auditViewOp(op, result)
    return
  if not command.isDriverOnlyDebugCommand:
    result = rejected("debug command is not driver-authorized in M4")
    authority.auditViewOp(op, result)
    return

  result = document.applyViewOp(op)
  authority.auditViewOp(op, result)
  if result.status notin {asRejected, asDuplicate}:
    authority.enqueueBackendCommand(op)
