## Principal and capability helpers for collaborative ViewModel sessions.
##
## **THESE ARE THE ONLY COPIES, SINCE PLAT-33.** `reducer.nim` carried its own
## `isAuthority`, `pathCovers`, `targetPathsCover`, `liveCapability`,
## `canGrantCapabilities` and `canDelegateCapabilities` — six routines
## covering the same ground as the six here, but not, as it turns out, the
## same six routines. See the measured comparison below; note in particular
## that the removed one was named `liveCapability`, not `hasLiveCapability`.
##
## **NO REASON FOR THE DUPLICATION IS RECORDED ANYWHERE**, and that is stated
## as the fact it is rather than filled in with a plausible one: neither file's
## history contains a justification, and `git log --all -S"cycle"` over both
## returns nothing, ever. An earlier version of this comment asserted the
## copies existed "to avoid an import cycle"; that explanation was invented
## after the fact and is withdrawn. There is no cycle to avoid — this module
## imports `std/[algorithm, strutils]` and `./types` and nothing else — but
## the absence of a cycle is not evidence about what anyone intended, and
## nothing here should pretend to know.
##
## **THE SURVIVING PREDICATES ARE NOT THE ONES THAT WERE REMOVED, AND THE
## DIFFERENCE IS REACHABLE.** An earlier version of this comment said the two
## copies "were line-for-line identical when compared, which is the only
## reason this is a refactor rather than a behaviour change". That was
## asserted from a substitution that compiled, not from a comparison anyone
## ran. Running it gives three different answers, not one:
##
## - `pathCovers` and `targetPathsCover` — identical bodies, export marker
##   aside. These two are a refactor.
## - `isAuthority` — **not** identical. The removed copy inlined
##   `principalId.len > 0 and (principalId == …principalId or principalId ==
##   …backendOwnerId)`; this one delegates to `isSessionAuthority` and
##   `isBackendOwner`. The two agree on every input — `len > 0 and (A or B)`
##   distributes to `(len > 0 and A) or (len > 0 and B)`, which is what the
##   two helpers each compute — so the rewrite is sound, but it is a rewrite.
## - `liveCapability` → `hasLiveCapability` — **differs in name and in body,
##   and the bodies do not agree.** The removed routine returned `true` from
##   inside the grant walk. This one asks `liveCapabilityGrant` for the
##   matching grant's *id* and tests `.len > 0`. For every grant with a
##   non-empty id those coincide; for a grant whose id is empty the old
##   predicate said `true` and this one says `false`.
##   `canGrantCapabilities` and `canDelegateCapabilities` call it and inherit
##   the difference.
##
## The gap was reachable when it was found: `codec.parseCapabilityGrant` set
## `id` from `node{"id"}.getStr("")` with no guard, so any snapshot that
## merely omitted the `"id"` key decoded to an empty-id grant, and a compiled
## probe over that state gave old = `true`, new = `false`. **The new behaviour
## is the fail-closed one** and is the behaviour kept. PLAT-33 additionally
## closed the hole at the decoder — an empty-id grant is now refused there,
## because `applyGrantCapabilities` and `applyRevokeCapabilities` both already
## refuse `id.len == 0`, which meant such a grant could never be revoked once
## admitted. So the two predicates now agree on everything the system can
## actually construct, but they agree because the input was removed, not
## because the routines were ever the same.
##
## The six duplicates are gone.
##
## The rule that says so is `Verification-Harness-Traps.md` §30: one
## predicate, one function, rule and control both calling it. A capability
## rule added to only one of two identical tables is a rule that is enforced
## in one of two places, and nothing about either place says which.

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
