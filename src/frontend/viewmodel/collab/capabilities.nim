## Principal and capability helpers for collaborative ViewModel sessions.

import std/[algorithm, strutils]

import ./types

type
  CapabilityDecision* = object
    allowed*: bool
    reason*: string

proc allowed*(reason = ""): CapabilityDecision =
  CapabilityDecision(allowed: true, reason: reason)

proc denied*(reason: string): CapabilityDecision =
  CapabilityDecision(allowed: false, reason: reason)

proc containsString(items: openArray[string]; value: string): bool =
  for item in items:
    if item == value:
      return true

proc isSessionAuthority*(state: SharedSessionViewState;
                         principalId: PrincipalId): bool =
  principalId.len > 0 and principalId == state.authority.principalId

proc isBackendOwner*(state: SharedSessionViewState;
                     principalId: PrincipalId): bool =
  principalId.len > 0 and principalId == state.authority.backendOwnerId

proc isAuthority*(state: SharedSessionViewState;
                  principalId: PrincipalId): bool =
  ## M1 treated the backend owner as authority for reducer compatibility.
  ## M4 callers that need the narrower distinction use isSessionAuthority
  ## and isBackendOwner explicitly.
  state.isSessionAuthority(principalId) or state.isBackendOwner(principalId)

proc pathCovers*(grantPath, targetPath: string): bool =
  grantPath.len == 0 or grantPath == "*" or grantPath == targetPath or
    targetPath.startsWith(grantPath & ".") or
    targetPath.startsWith(grantPath & "[")

proc targetPathsCover*(targetPaths: openArray[string];
                       targetPath: string): bool =
  if targetPaths.len == 0:
    return true
  for grantPath in targetPaths:
    if grantPath.pathCovers(targetPath):
      return true

proc liveCapabilityGrant*(state: SharedSessionViewState;
                          principalId: PrincipalId;
                          cap: CapabilityKind;
                          targetPath = "";
                          capabilityIds: openArray[CapabilityGrantId] = []):
                          CapabilityGrantId =
  for grant in state.capabilityGrants:
    if grant.subject == principalId and grant.revokedByOpId.len == 0 and
        (capabilityIds.len == 0 or capabilityIds.containsString(grant.id)) and
        grant.targetPaths.targetPathsCover(targetPath):
      for granted in grant.capabilities:
        if granted == cap:
          return grant.id

proc hasLiveCapability*(state: SharedSessionViewState;
                        principalId: PrincipalId;
                        cap: CapabilityKind;
                        targetPath = "";
                        capabilityIds: openArray[CapabilityGrantId] = []): bool =
  if state.isAuthority(principalId):
    return true
  state.liveCapabilityGrant(principalId, cap, targetPath, capabilityIds).len > 0

proc canGrantCapabilities*(state: SharedSessionViewState;
                           principalId: PrincipalId): bool =
  state.hasLiveCapability(principalId, capGrantCapabilities, "capabilityGrants")

proc canDelegateCapabilities*(state: SharedSessionViewState;
                              principalId: PrincipalId;
                              capabilities: openArray[CapabilityKind];
                              targetPaths: openArray[string]): bool =
  if state.isAuthority(principalId):
    return true
  for capability in capabilities:
    if targetPaths.len == 0:
      if not state.hasLiveCapability(principalId, capability):
        return false
    else:
      for targetPath in targetPaths:
        if not state.hasLiveCapability(principalId, capability, targetPath):
          return false
  true

proc explainCapability*(state: SharedSessionViewState;
                        principalId: PrincipalId;
                        cap: CapabilityKind;
                        targetPath = "";
                        capabilityIds: openArray[CapabilityGrantId] = []):
                        CapabilityDecision =
  if state.hasLiveCapability(principalId, cap, targetPath, capabilityIds):
    return allowed("capability allowed")
  denied("principal lacks " & $cap & " for " & targetPath)

proc registerPrincipal*(state: var SharedSessionViewState;
                        principal: PrincipalDescriptor) =
  if principal.id.len == 0:
    return
  for existing in state.principals.mitems:
    if existing.id == principal.id:
      existing = principal
      state.principals.sort(proc(a, b: PrincipalDescriptor): int = cmp(a.id, b.id))
      return
  state.principals.add principal
  state.principals.sort(proc(a, b: PrincipalDescriptor): int = cmp(a.id, b.id))

proc registerActor*(state: var SharedSessionViewState;
                    actor: ActorDescriptor) =
  if actor.id.len == 0:
    return
  for existing in state.actors.mitems:
    if existing.id == actor.id:
      existing = actor
      state.actors.sort(proc(a, b: ActorDescriptor): int = cmp(a.id, b.id))
      return
  state.actors.add actor
  state.actors.sort(proc(a, b: ActorDescriptor): int = cmp(a.id, b.id))

proc registerReplica*(state: var SharedSessionViewState;
                      replica: ReplicaDescriptor) =
  if replica.id.len == 0:
    return
  for existing in state.replicas.mitems:
    if existing.id == replica.id:
      existing = replica
      state.replicas.sort(proc(a, b: ReplicaDescriptor): int = cmp(a.id, b.id))
      return
  state.replicas.add replica
  state.replicas.sort(proc(a, b: ReplicaDescriptor): int = cmp(a.id, b.id))

proc bindActorReplica*(state: var SharedSessionViewState;
                       principalId: PrincipalId;
                       actorId: ActorId;
                       replicaId: SessionReplicaId) =
  state.registerActor ActorDescriptor(id: actorId, principalId: principalId)
  state.registerReplica ReplicaDescriptor(id: replicaId, actorId: actorId)
