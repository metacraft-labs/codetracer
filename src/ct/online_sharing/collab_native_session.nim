## Native-client M6 collaboration invite session activation.
##
## M6 keeps the standalone client on the collaboration session-core path while
## CI remains a control-plane rendezvous service. Resolving an invite bootstrap
## must retain an active native collaboration session instead of merely printing
## CI's bootstrap document.

import std/[json, tables]

import ../../frontend/viewmodel/collab/[join_session, reducer, session_core, types]

type
  NativeCollabBootstrap* = object
    replayId*: string
    traceId*: string
    traceIdentity*: string
    roomId*: string
    initialGrants*: seq[string]
    webUiUrl*: string
    nativeJoinUrl*: string
    rendezvousUrl*: string
    transportHints*: seq[string]

  NativeCollabSession* = object
    entered*: bool
    replayId*: string
    traceId*: string
    traceIdentity*: string
    roomId*: string
    initialGrants*: seq[string]
    webUiUrl*: string
    nativeJoinUrl*: string
    rendezvousUrl*: string
    transportHints*: seq[string]
    transportStarted*: bool
    acceptsViewOpsThroughCi*: bool

  NativeCollabTransport* = object
    active*: bool
    kind*: string
    roomId*: string
    rendezvousUrl*: string
    hints*: seq[string]
    acceptsViewOps*: bool

  NativeCollabRuntime* = ref object
    activeSession*: NativeCollabSession
    sessionCore*: CollaborativeSessionCore
    transport*: NativeCollabTransport
    activation*: CollabJoinActivation

var nativeRuntimeRegistry = initTable[string, NativeCollabRuntime]()

proc acceptsViewOpsThroughCi(hints: openArray[string]): bool =
  for hint in hints:
    if hint == "viewops-not-accepted":
      return false
  false

proc enterNativeCollabSession*(bootstrap: NativeCollabBootstrap):
    NativeCollabSession =
  if bootstrap.roomId.len == 0:
    raise newException(ValueError, "collaboration bootstrap is missing roomId")
  if bootstrap.replayId.len == 0:
    raise newException(ValueError, "collaboration bootstrap is missing replayId")

  NativeCollabSession(
    entered: true,
    replayId: bootstrap.replayId,
    traceId: bootstrap.traceId,
    traceIdentity: bootstrap.traceIdentity,
    roomId: bootstrap.roomId,
    initialGrants: bootstrap.initialGrants,
    webUiUrl: bootstrap.webUiUrl,
    nativeJoinUrl: bootstrap.nativeJoinUrl,
    rendezvousUrl: bootstrap.rendezvousUrl,
    transportHints: bootstrap.transportHints,
    transportStarted: true,
    acceptsViewOpsThroughCi: acceptsViewOpsThroughCi(bootstrap.transportHints),
  )

proc bootstrapJson(bootstrap: NativeCollabBootstrap): JsonNode =
  %*{
    "replayId": bootstrap.replayId,
    "traceId": bootstrap.traceId,
    "traceIdentity": bootstrap.traceIdentity,
    "roomId": bootstrap.roomId,
    "initialGrants": bootstrap.initialGrants,
    "webUiUrl": bootstrap.webUiUrl,
    "nativeJoinUrl": bootstrap.nativeJoinUrl,
    "rendezvousUrl": bootstrap.rendezvousUrl,
    "transportHints": bootstrap.transportHints,
  }

proc startNativeCollabRuntime*(bootstrap: NativeCollabBootstrap):
    NativeCollabRuntime =
  ## Activate the native collaboration runtime path for a consumed invite.
  ## The standalone client enters the same shared-session core used by the
  ## ViewModel collaboration path and retains it in a process-local registry.
  ## The transport is CI rendezvous metadata only; normal ViewOps are not sent
  ## through CI.
  var session = enterNativeCollabSession(bootstrap)
  let core = createCollaborativeSessionCore(
    sessionId = "native-prejoin-" & bootstrap.roomId,
    traceIdentity = bootstrap.traceIdentity,
    localPrincipalId = "native-guest-" & bootstrap.roomId,
    localActorId = "native-actor-" & bootstrap.roomId,
    localReplicaId = "native-replica-" & bootstrap.roomId,
    backendOwnerId = "ci-control-plane")
  let activation = core.startCollabJoinSession(bootstrap.bootstrapJson)
  session.transportStarted = activation.transportStarted
  result = NativeCollabRuntime(
    activeSession: session,
    sessionCore: core,
    transport: NativeCollabTransport(
      active: activation.transportStarted,
      kind: "control-plane-rendezvous",
      roomId: bootstrap.roomId,
      rendezvousUrl: bootstrap.rendezvousUrl,
      hints: bootstrap.transportHints,
      acceptsViewOps: false),
    activation: activation)
  nativeRuntimeRegistry[bootstrap.roomId] = result

proc isActive*(runtime: NativeCollabRuntime): bool =
  not runtime.isNil and runtime.activeSession.entered and
    runtime.activeSession.transportStarted and
    not runtime.sessionCore.isNil and
    runtime.sessionCore.collaborationEnabled and
    runtime.transport.active

proc registeredNativeCollabRuntime*(roomId: string): NativeCollabRuntime =
  nativeRuntimeRegistry.getOrDefault(roomId, nil)

proc registeredNativeCollabRuntimeCount*(): int =
  nativeRuntimeRegistry.len

proc observeNativeCollabState*(runtime: NativeCollabRuntime): JsonNode =
  if not runtime.isActive:
    raise newException(ValueError, "native collaboration runtime is not active")
  let core = runtime.sessionCore
  %*{
    "roomId": runtime.activeSession.roomId,
    "traceIdentity": core.document.state.traceIdentity,
    "sessionId": core.document.state.sessionId,
    "transportKind": runtime.transport.kind,
    "transportActive": runtime.transport.active,
    "peerTransportStarted": core.peerTransportStarted,
    "remoteAwarenessStarted": core.remoteAwarenessStarted,
    "selectedPath": core.document.state.statePane.selectedPath.value,
    "localOperationCount": core.localOperationLog.len,
    "acceptsViewOpsThroughCi": runtime.activeSession.acceptsViewOpsThroughCi,
  }

proc setNativeSelectedPath*(runtime: NativeCollabRuntime;
                            selectedPath: string): ApplyResult =
  if not runtime.isActive:
    return rejected("native collaboration runtime is not active")
  runtime.sessionCore.dispatchLocalViewOp(
    vokSetRegister,
    "statePane.selectedPath",
    %*{"value": selectedPath})

proc toJson*(session: NativeCollabSession): JsonNode =
  %*{
    "kind": "nativeCollabSession",
    "entered": session.entered,
    "replayId": session.replayId,
    "traceId": session.traceId,
    "traceIdentity": session.traceIdentity,
    "roomId": session.roomId,
    "initialGrants": session.initialGrants,
    "webUiUrl": session.webUiUrl,
    "nativeJoinUrl": session.nativeJoinUrl,
    "rendezvousUrl": session.rendezvousUrl,
    "transportHints": session.transportHints,
    "transportStarted": session.transportStarted,
    "acceptsViewOpsThroughCi": session.acceptsViewOpsThroughCi,
  }
