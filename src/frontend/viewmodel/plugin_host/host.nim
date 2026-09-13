## plugin_host/host.nim — PLAT-7's host: the registry, the total resolution,
## lazy activation on declared events, and deactivation that releases
## everything through `isonim`'s owner tree.
##
## This module is NOT part of the Embed SDK facade and is not re-exported by
## it. A plugin does not load plugins; the application does. `plugin_api.nim`
## is the half a plugin sees, and it is on the facade.
##
## ## THE ORDER IS ENFORCED, NOT DOCUMENTED
##
## Extensibility-Model.md §4.2 gives the lifecycle as
## `discover → resolve → activate → run → deactivate` and says resolution "is
## total and happens before any activation". `activate` therefore RAISES if
## `resolveAll` has not run — the ordering is a precondition with a failure
## mode, not a comment. A host that resolved lazily, plugin by plugin, could
## not report a cycle at all until it happened to walk into one.
##
## ## DEACTIVATION, AND THE ONE THING THE OWNER TREE DOES NOT COVER
##
## `deactivate` is `cleanNode(scope)`. That is the whole release: `cleanNode`
## walks the scope's `owned` computations, and for each one removes it from
## every signal's `observers` sequence (`graph.removeSourceObserver`). After
## it, no signal holds a reference to a deactivated plugin's effect, so no
## write can reach it. `test_plugin_lifecycle.nim` asserts the observer count
## on the real signal, not just that a counter stopped moving, because "the
## counter stopped" is also what a plugin that guards its own body looks like.
##
## THE ONE GAP, AND IT IS ISONIM'S RATHER THAN OURS. `signals.notifySignalWrite`
## pushes observers onto the `Effects` queue AND sets `state = csStale` at
## WRITE time; `batch.flushUpdates` later runs anything still `csStale`.
## `cleanNode` does not touch `state`. So an effect that was queued inside a
## batch and whose plugin was deactivated later in that same batch would run
## once more, after its release. `deactivate` closes that by marking the
## plugin's recorded computations `csClean`, which is what `flushUpdates`
## reads. That is a SCHEDULING fix for a queue that already holds the pointer;
## it is not the release, and removing it does not make deactivation leak — it
## makes exactly one already-queued run survive, which is the case
## `test_plugin_lifecycle.nim` drives explicitly.
##
## ## NO SECOND DISPATCH PATH
##
## There is no `dispatch`, no `emit`, no `invoke`, no command table and no
## event bus in this file. An activation EVENT is not a message to a plugin —
## it is the question "which plugins should now exist", answered once, by
## `plugin_model/activation.plan`. Once a plugin exists it observes through
## signals (§5.1) and acts through the ViewModels' own action procs (§5.2).
##
## ## NO MOCKS
##
## The host drives `isonim`'s real reactive graph, a real monotonic clock and
## real `PluginImplementation`s. The suites hand it plugin modules that are
## ordinary code, not stand-ins: `tests/unit/plugin_fixtures/` is a declared
## SDK-consumer tree, so `ci/test/sdk-facade-boundary.sh` holds those plugins
## to §2.1's rule the same way it holds the terminal front-end to it.

import std/[options, sets, strutils, tables, times]

import isonim/core/types as isonim_types
import isonim/core/graph as isonim_graph
import isonim/core/owner as isonim_owner

import ./plugin_api
import ./plugin_io
import ./surface_host

export plugin_api
export surface_host

type
  PluginHostError* = object of CatchableError
    ## A misuse of the host by the APPLICATION — activating before resolving,
    ## registering after resolving. Distinct from a `PluginError`, which is a
    ## fault of a plugin, because the two have different audiences.

  PluginRecord* = ref object
    impl*: PluginImplementation
    ctx*: PluginContext
    scope*: OwnerBase
    active*: bool
    activations*: int
      ## How many times this plugin has been brought up. Lazy activation means
      ## a plugin may be activated by one event and must not be activated
      ## again by the next; the counter is what makes that assertable.
    deactivations*: int

  PluginHost* = ref object
    coreVersion*: SemVer
    budget*: Duration
    parsed: seq[ParsedManifest]
    impls: Table[PluginId, PluginImplementation]
    registrationOrder: seq[PluginId]
    resolution*: Resolution
    resolved*: bool
    records*: Table[PluginId, PluginRecord]
    activationLog*: seq[PluginId]
      ## Every activation, in the order it happened. The DEPENDENCY ORDER
      ## claim of §4.2 is a claim about this sequence.
    frontEnd*: FrontEnd
      ## PLAT-9 / §6.3. WHICH FRONT-END THIS HOST IS, and therefore which
      ## surfaces have a view. It is a host field rather than a resolve-time
      ## argument because a host IS a front-end's plugin host — there is no
      ## point in the lifetime of one at which the answer changes.
    surfaces*: SurfaceHost
      ## PLAT-9's registry: the contributed surfaces, their dependency probes,
      ## their degradation and their fault boundary.
    extensionsEnabled*: bool
      ## `--no-extensions`. See `newPluginHost`.
    activationFaults*: seq[string]
      ## PLAT-9 / §7. A plugin whose `activate` RAISED. Recorded rather than
      ## propagated, because "a failing extension must not take down the
      ## debugger" applies to the plugin's first line as much as to its
      ## hundredth, and a host that let `activate` throw would take the
      ## application down before any view had been mounted inside a boundary.
    defectedPlugins*: HashSet[PluginId]
      ## PLAT-9 / §7. Plugins whose `activate` raised a `Defect`. They are not
      ## activated again this session — see `activateOne`. A set rather than a
      ## flag on the record because the question is asked before a record is
      ## guaranteed to exist.
    declaredGrants*: Table[PluginId, GrantSet]
      ## PLAT-10. What each manifest DECLARED, captured at `register` and never
      ## narrowed. The ledger is applied to this rather than to whatever the
      ## last application left behind, so re-granting a revoked capability
      ## restores exactly the declared set and nothing wider — a narrowing
      ## applied to an already-narrowed value could only ever shrink, which
      ## would make `grantCapability` a no-op the day somebody used it.
    ledger*: GrantLedger
      ## PLAT-10 deliverable 3. Per-plugin capability grants, with their
      ## history. Meaningful only when `ledgerAttached`.
    ledgerAttached*: bool
      ## WHETHER A LEDGER GOVERNS THIS HOST, and the default is `false`.
      ##
      ## The two states are genuinely different policies and the flag is how a
      ## reader tells which one is in force. With no ledger the manifest's
      ## declaration IS the grant, which is PLAT-8's model and what every suite
      ## written before this milestone drives. With a ledger attached, a
      ## capability is permitted only if the ledger says `grant` — so an
      ## UNDECIDED capability is refused, which is what makes an upgrade that
      ## widens a manifest safe (`grant_ledger.nim`'s header).
      ##
      ## A front-end that discovers plugins from disk always attaches one;
      ## `PluginHost` does not default to it because a host built by a suite
      ## with three literal manifests and no user root has nobody to have
      ## granted anything.
    reclaimFailures*: seq[string]
      ## PLAT-8. A closer that raised during a handle sweep. It is RECORDED
      ## rather than raised out of `deactivate`, because a deactivation that
      ## propagated the third handle's failure would abandon the fourth — and
      ## the resources this exists to reclaim are exactly the ones that would
      ## then leak. `report()` prints them, so "it did not close cleanly" is a
      ## finding rather than a silence.

proc newPluginHost*(coreVersion: SemVer;
                    budget = DefaultEffectBudget;
                    frontEnd = feWeb;
                    extensionsEnabled = true): PluginHost =
  ## `extensionsEnabled = false` IS `--no-extensions` (§7's last bullet), AND
  ## THE HOST'S HALF OF IT IS: nothing is resolved, nothing is activated, and
  ## no plugin's `activate` is entered. `SurfaceHost`'s half — no registry, no
  ## probe, no render — is in `newSurfaceHost`.
  ##
  ## `register` still RECORDS a manifest with the flag on, deliberately: a
  ## user who passes the flag and then asks what is installed should get the
  ## list, and `report()` names the flag as the reason none of them is running.
  ## What the flag removes is execution, not knowledge.
  PluginHost(coreVersion: coreVersion, budget: budget, frontEnd: frontEnd,
             extensionsEnabled: extensionsEnabled,
             surfaces: newSurfaceHost(frontEnd, extensionsEnabled),
             impls: initTable[PluginId, PluginImplementation](),
             records: initTable[PluginId, PluginRecord](),
             declaredGrants: initTable[PluginId, GrantSet](),
             defectedPlugins: initHashSet[PluginId]())

# ---------------------------------------------------------------------------
# discover
# ---------------------------------------------------------------------------

proc register*(host: PluginHost; manifestText, source: string;
               activate: proc(ctx: PluginContext)): ParsedManifest
               {.discardable.} =
  ## Read one plugin's manifest and remember its implementation.
  ##
  ## A manifest that does not parse is STILL REGISTERED, with its errors, so
  ## that `resolveAll` can report them beside every other plugin's rather than
  ## dropping the plugin on the floor here. §4.1's rule is about what the user
  ## is told, and a plugin that vanished at discovery is told about by nobody.
  if host.resolved:
    raise newException(PluginHostError,
      "register('" & source & "') after resolveAll(): resolution is total " &
      "and happens before any activation, so a plugin discovered afterwards " &
      "would be resolved against a graph the others were not")
  result = parseManifest(manifestText, source)
  host.parsed.add result
  if result.manifest.id.len > 0 and
     not host.impls.hasKey(result.manifest.id):
    host.impls[result.manifest.id] =
      PluginImplementation(manifest: result.manifest, activate: activate)
    # PLAT-10. Captured HERE, from the parse, before anything can narrow it.
    host.declaredGrants[result.manifest.id] = result.manifest.grants
    host.registrationOrder.add result.manifest.id

# ---------------------------------------------------------------------------
# resolve
# ---------------------------------------------------------------------------

# Forward-declared. `resolveAll` is ABOVE the grant section because the
# lifecycle order puts it there — §4.2 is `discover → resolve → activate` — but
# it is the one thing in this file that can UNDO a narrowing, so it has to be
# able to reach the repair. The alternative, moving the whole PLAT-10 block
# above `resolve`, would put the ledger before the phase it narrows and read as
# if a grant were an input to resolution. It is not: it is applied to the
# output.
#
# `isActive` is forward-declared for the same reason, from the other direction:
# `effectiveCapabilitiesOf` has to know whether a live context exists before it
# can answer out of the right one, and duplicating the one-line test here would
# be a second copy of a predicate (Verification-Harness-Traps §14).
proc applyLedger*(host: PluginHost)
proc isActive*(host: PluginHost; id: PluginId): bool

proc resolveAll*(host: PluginHost) =
  ## The whole registry, once, before anything is activated.
  ##
  ## THE FRONT-END IS PASSED IN, and that is what makes §6.3's refusal real
  ## rather than a function nobody calls: `resolve` evaluates a required
  ## surface against it in phase 3b, fails the plugin that has no view there,
  ## and blocks that plugin's dependents in phase 6 like any other failure.
  ## Passing `none` here would leave `surfaceRefusals` a pure function with no
  ## effect on anything — which is exactly what it was before this line.
  ##
  ## AND IT RE-APPLIES THE LEDGER, WHICH IS NOT AN OPTIMISATION. See below.
  host.resolution = resolve(host.parsed, host.coreVersion,
                            some(host.frontEnd))
  host.resolved = true

  # PLAT-10. THE LINE THAT KEEPS A REVOCATION REVOKED ACROSS A SECOND
  # DISCOVERY PASS, and the reason it is here rather than left to the caller.
  #
  # `resolve` is a pure function of `host.parsed` — the manifests AS PARSED,
  # which is the one copy of a `GrantSet` in this object that is never narrowed
  # (`declaredGrants` is captured from the same parse for exactly that reason).
  # So this assignment REPLACES `resolution.manifests` with the DECLARED sets,
  # discarding every narrowing `applyLedgerTo` had made; `activateOne` then
  # copies the widened manifest into the next `ctx`. The ledger still says
  # `revoke`, `report()` still prints REVOKED with the date — and the child
  # runs. That is the state PLAT-10's brief names as theatre, reached without
  # touching the ledger at all.
  #
  # Measured before the line existed, with a real `execve` and a sentinel file
  # (`test_plugin_grant_lifecycle.nim`, "re-running discovery does not hand the
  # capability back"): revoke → resolveAll() → deactivate → activate spawned the
  # child and wrote the sentinel, while the identical sequence WITHOUT the
  # `resolveAll()` refused it. `resolveAll` and `deactivate` are both public and
  # neither is privileged, so nothing but this line stood between the two.
  #
  # IT IS ALSO WHAT MAKES `attachGrantLedger` ORDER-INDEPENDENT. That proc's
  # docstring asks to be called after `resolveAll`, because before it there is
  # no `resolution.manifests` to narrow. With this line the other order is
  # merely redundant rather than unsafe, which is the right shape for a
  # precondition nobody can check.
  #
  # `applyLedger` recomputes from `declaredGrants` rather than from the current
  # value, so it is idempotent and running it on every resolve costs one pass
  # over the registration order.
  if host.ledgerAttached: host.applyLedger()

proc loadErrors*(host: PluginHost): seq[PluginError] =
  host.resolution.errors

proc isLoadable*(host: PluginHost; id: PluginId): bool =
  host.resolved and host.resolution.isLoadable(id)

proc failureCodeFor*(host: PluginHost; id: PluginId): PluginErrorCode =
  ## WHY a plugin is not loadable, as the code a caller may branch on.
  ## Verification-Harness-Traps §4b: a test asserting only "it refused" passes
  ## when the refusal was for the wrong reason, so a refusal is asserted by
  ## code and never by the presence of some error.
  host.resolution.failureFor(id).code

# ---------------------------------------------------------------------------
# PLAT-10: the grant lifecycle
#
# THE ONLY THING ANY OF THIS DOES IS CHANGE A `GrantSet`, and that is the whole
# design. `plugin_api.grantsOf(ctx)` is `ctx.manifest.grants`; every I/O the SDK
# offers passes that value to `capabilities.decide`. So a revoked capability is
# not a flag somebody has to remember to consult — it is a capability that is
# NOT IN THE SET, refused by the same arm that refuses a plugin which never
# declared it, with no second predicate anywhere.
#
# The two places a `GrantSet` can be read from are narrowed together:
#
#   * `resolution.manifests[id]` — what `activateOne` copies into a new `ctx`,
#     so a plugin activated AFTER the revocation never sees the capability;
#   * `records[id].ctx.manifest` — the copy a LIVE plugin is already holding.
#     `PluginManifest` is a value type, so narrowing the first does nothing to
#     a plugin that is already running. Without this second line, revocation
#     would take effect at the next activation and a user who revoked
#     `process` from a plugin that is spawning things right now would be told
#     it was done while it went on spawning them.
#
# AND THE AUDIT OF EVERY OTHER WRITER OF THOSE TWO FIELDS, because "the ledger
# is applied in two places" is only true while nothing ELSE assigns them. It was
# taken over the whole tree rather than over this file, and it is written down
# so the next reader counts rather than re-derives (§14b):
#
#   * `resolution.manifests[id]` is assigned in exactly one production place —
#     `resolveAll`, through `resolve()`. That was the hole, and it is closed
#     there. `resolution.nim` builds the table, but from `host.parsed`, which is
#     the input to `resolveAll` and not a second entry point.
#   * `records[id].ctx` is assigned in exactly one place, `activateOne`, and the
#     manifest it copies is `resolution.manifests[id]` — already narrowed, by
#     the line above. It has no second source.
#   * `impls[id].manifest` is the raw parse and is read by nothing on the I/O
#     path (its only reader in the tree is a suite asserting the registration).
#   * `plugin_io.canonicalGrantsOf` DERIVES a `GrantSet` from `grantsOf(ctx)`
#     per call and caches nothing, so it cannot hold a stale narrowing.
#   * `surfaces.register(ctx.manifest)` takes the narrowed copy and reads no
#     capability out of it.
#
# So the shape — "rebuild a narrowed value from an un-narrowed source" — has one
# instance in this tree, and the line in `resolveAll` is it.
# ---------------------------------------------------------------------------

proc applyLedgerTo(host: PluginHost; id: PluginId) =
  if not host.ledgerAttached: return
  if not host.declaredGrants.hasKey(id): return
  let narrowed = effectiveGrants(host.declaredGrants[id], host.ledger, id)
  if host.resolution.manifests.hasKey(id):
    host.resolution.manifests[id].grants = narrowed
    host.resolution.manifests[id].capabilities = narrowed.capabilities
  if host.records.hasKey(id):
    let rec = host.records[id]
    if not rec.ctx.isNil:
      rec.ctx.manifest.grants = narrowed
      rec.ctx.manifest.capabilities = narrowed.capabilities

proc applyLedger*(host: PluginHost) =
  ## Re-narrow every plugin. Idempotent: it recomputes from `declaredGrants`
  ## rather than from the current value, so calling it twice is calling it
  ## once.
  for id in host.registrationOrder:
    host.applyLedgerTo(id)

proc attachGrantLedger*(host: PluginHost; ledger: GrantLedger) =
  ## Put a ledger in force, at any point in a host's life, including with
  ## plugins already running.
  ##
  ## THE ORDER AGAINST `resolveAll` NO LONGER MATTERS, and it used to. Before
  ## `resolveAll` there is no `resolution.manifests`, so the narrowing this does
  ## reaches nothing — which was a precondition a caller could get wrong in
  ## silence. `resolveAll` now re-applies the ledger itself, so attaching first
  ## is redundant rather than unsafe. A precondition nobody can check is a
  ## precondition somebody will break.
  host.ledger = ledger
  host.ledgerAttached = true
  host.applyLedger()

proc grantStateOf*(host: PluginHost; id: PluginId;
                   cap: Capability): GrantState =
  ## What the ledger says. With no ledger attached every capability is
  ## `gsUndecided`, which is the honest answer: nobody has recorded anything.
  if not host.ledgerAttached: return gsUndecided
  host.ledger.stateOf(id, cap)

proc effectiveCapabilitiesOf*(host: PluginHost; id: PluginId): set[Capability] =
  ## What the plugin may actually do — the value `decide` will be handed.
  ##
  ## IT IS AN INSPECTION API, SO ITS FAILURE MODE IS A WRONG SENTENCE RATHER
  ## THAN A WRONG PERMISSION, and that is why it needed fixing separately from
  ## enforcement. `test_plugin_grant_lifecycle.nim` uses it as assertion (2) of
  ## three, described there as "the very `set[Capability]` the SDK hands to
  ## `decide`" — so an implementation that reads a DIFFERENT set than the SDK
  ## reads makes that assertion true of something nobody executes, and it is
  ## true or false independently of whether the refusal works.
  ##
  ## THERE ARE TWO STORES AND THEY ARE NOT INTERCHANGEABLE:
  ##
  ##   * a LIVE plugin's I/O goes through `plugin_io.grantsOf(ctx)`, which is
  ##     `records[id].ctx.manifest.grants`;
  ##   * a plugin not currently up will be handed `resolution.manifests[id]`
  ##     when `activateOne` builds its next context.
  ##
  ## So this answers out of the live context when there is one and out of the
  ## stored manifest when there is not — in both cases the store the next
  ## `decide` will actually read.
  ##
  ## AND IT CALLS `grantsOf` RATHER THAN SPELLING `ctx.manifest.grants` AGAIN.
  ## Verification-Harness-Traps §14: a second copy of a predicate is a second
  ## thing that can be wrong while its twin goes on agreeing with itself, and
  ## the copy nobody mutates is the one that stays wrong. One function, two
  ## callers — the SDK's I/O arms and this.
  ##
  ## WHAT THE OLD UNCONDITIONAL READ COST, measured: with arm H1 applied — the
  ## arm that stops `applyLedgerTo` narrowing the live context — the old
  ## implementation read the NARROWED `resolution.manifests` and reported the
  ## capability as gone, so assertion (2) stayed green over a host that spawned
  ## the child. Only the sentinel file caught it. It now reddens too, which is
  ## what an assertion earning its place in a list of three looks like.
  if host.isActive(id):
    let rec = host.records[id]
    if not rec.ctx.isNil:
      return grantsOf(rec.ctx).capabilities
  if host.resolution.manifests.hasKey(id):
    return host.resolution.manifests[id].grants.capabilities
  {}

proc revokeCapability*(host: PluginHost; id: PluginId; cap: Capability;
                       at: string; note = ""): GrantRecordOutcome =
  ## Take a capability back, and say WHICH of the four things happened.
  ##
  ## IT WAS A `bool {.discardable.}` UNTIL 2026-09-13, meaning "this changed the
  ## state in force" — so `false` was the benign "already revoked", and closing
  ## the ledger's row grammar gave the same `false` a second, opposite meaning:
  ## "nothing was written at all". Verification-Harness-Traps §5a is that
  ## collision, and its worked example is this side of the pair: a revocation
  ## that reports success and does not happen leaves the capability in force.
  ## `decisionStands` is the one function that separates the two, and the
  ## pragma is gone so a caller that drops the answer has to be seen doing it.
  ##
  ## It does NOT deactivate the plugin, and that is the point: §8.1.1's
  ## "resources are reclaimable without restarting CodeTracer" has the same
  ## shape one level up — a user revoking one grant from a working plugin
  ## wants the rest of it to go on working.
  if not host.ledgerAttached:
    raise newException(PluginHostError,
      "revokeCapability('" & id & "', '" & $cap & "') with no grant ledger " &
      "attached. A revocation that nothing records is not a revocation; call " &
      "attachGrantLedger() first")
  result = host.ledger.revoke(id, cap, at, note)
  host.applyLedgerTo(id)

proc grantCapability*(host: PluginHost; id: PluginId; cap: Capability;
                      at: string; note = ""): GrantRecordOutcome =
  ## Give one back, or give one for the first time. A capability the MANIFEST
  ## does not declare cannot be granted into existence — `effectiveGrants`
  ## intersects with the declared set — so this widens only as far as the
  ## plugin asked for.
  ##
  ## `revokeCapability`'s answer and its reason, on the side that fails closed.
  ## The twins are written to look alike on purpose (§5a's second bullet: a
  ## repair that is safe at one call site can be unsafe at its twin), so they
  ## report through the same enum and the same `decisionStands`.
  if not host.ledgerAttached:
    raise newException(PluginHostError,
      "grantCapability('" & id & "', '" & $cap & "') with no grant ledger " &
      "attached; call attachGrantLedger() first")
  result = host.ledger.grant(id, cap, at, note)
  host.applyLedgerTo(id)

proc acceptDeclaredGrants*(host: PluginHost; id: PluginId; at: string;
                           note = ""): GrantDeclaredOutcome =
  ## The acceptance step for a plugin the user has just installed: grant every
  ## capability its manifest declares that has no decision yet. Says how many
  ## were recorded AND what happened, for `grant_ledger.GrantDeclaredOutcome`'s
  ## reason: `0` already meant "everything was already decided", so a refused
  ## field would have been a second reason for the same number (§5a).
  ##
  ## A REVOKED CAPABILITY IS LEFT REVOKED — see `grant_ledger.grantDeclared`.
  ## Re-running this after an upgrade grants only what the upgrade ADDED and
  ## only if the user had not already said no to it.
  if not host.ledgerAttached:
    raise newException(PluginHostError,
      "acceptDeclaredGrants('" & id & "') with no grant ledger attached")
  if not host.declaredGrants.hasKey(id):
    # Not a plugin this host has a declared set for, so there is nothing to
    # accept and nothing to record it against.
    return GrantDeclaredOutcome(outcome: groNoPlugin)
  result = host.ledger.grantDeclared(
    id, host.declaredGrants[id].capabilities, at, note)
  host.applyLedgerTo(id)

proc grantLedgerReport*(host: PluginHost): string =
  ## The INSPECTABLE half of deliverable 3: every decision, per plugin, with
  ## the date it was taken and what is in force now.
  if not host.ledgerAttached:
    return "no capability grant ledger is attached to this host"
  var lines: seq[string] = @[]
  for id in host.registrationOrder:
    lines.add host.ledger.describe(id)
  lines.join("\n")

# ---------------------------------------------------------------------------
# activate
# ---------------------------------------------------------------------------

proc isActive*(host: PluginHost; id: PluginId): bool =
  host.records.hasKey(id) and host.records[id].active

proc contextFor*(host: PluginHost; id: PluginId): PluginContext =
  if host.records.hasKey(id): host.records[id].ctx else: nil

proc activateOne*(host: PluginHost; id: PluginId): bool {.discardable.} =
  ## Bring one plugin up in its own activation scope. Returns `false` when the
  ## plugin is not loadable — a caller walking a plan never sees that, because
  ## the plan is built from the loadable set.
  if not host.resolved:
    raise newException(PluginHostError,
      "activateOne('" & id & "') before resolveAll(): Extensibility-Model " &
      "§4.2 requires resolution to be total before any activation")
  # PLAT-9 / §7. `--no-extensions` is checked HERE, at the one point every
  # activation path goes through, rather than at each of the three callers.
  # `activateFor` and `activateEager` both funnel here, so there is no second
  # route by which a plugin's `activate` could be entered.
  if not host.extensionsEnabled: return false
  if host.isActive(id): return true
  # §7, and the one place a `Defect` differs from a handled error on this path.
  if id in host.defectedPlugins: return false
  if not host.isLoadable(id): return false
  if not host.impls.hasKey(id): return false

  let impl = host.impls[id]
  # THE SCOPE. A bare `OwnerBase`, retained by the host, exactly as
  # `isonim.createRoot` builds one — and retained for the same reason
  # `createRoot`'s caller must retain its `dispose`: nothing else in the
  # framework holds a root, so nothing else can release one.
  let scope = OwnerBase(owned: @[], cleanups: @[], owner: nil,
                        contextTable: nil)
  let ctx = PluginContext(manifest: host.resolution.manifests[id],
                          state: newRunState(id, host.budget),
                          scope: scope)
  let rec =
    if host.records.hasKey(id): host.records[id]
    else: PluginRecord(impl: impl)
  rec.ctx = ctx
  rec.scope = scope
  rec.active = true
  inc rec.activations
  host.records[id] = rec
  host.activationLog.add id

  # PLAT-9 / §6.1. The surfaces are registered BEFORE `activate` runs, because
  # `contributeView` joins a view to a surface the manifest declared and the
  # host has to know which surfaces this front-end kept. Registering afterwards
  # would make the ordering a plugin could observe.
  host.surfaces.register(ctx.manifest)

  # `runWithOwner` makes `scope` the AMBIENT owner, so every `createEffect`
  # and `createMemo` the plugin reaches — through `plugin_api`, which is the
  # only way it can — attaches itself to `scope.owned`. The plugin does not
  # opt in and cannot opt out.
  #
  # AND IT RUNS INSIDE A `try`, which is §7's containment applied to the
  # plugin's FIRST line. A plugin whose `activate` raises used to propagate
  # out of here into whatever was booting the application; now it is recorded,
  # attributed, and the plugin is left inactive with everything it managed to
  # create released. `report()` prints the fault.
  #
  # AND IT CATCHES `Defect` AS WELL AS `CatchableError`, for the reason
  # `surface_host.renderSurface` does: `IndexDefect`, `FieldDefect`,
  # `RangeDefect` and a nil dereference are not `CatchableError`s, they are the
  # commonest way Nim code fails at runtime, and a containment that misses them
  # contains the rare case and not the ordinary one. The two are recorded
  # separately because they mean different things — see `surface_host`'s
  # header, including what `--panics:on` does to both — and because a plugin
  # whose FIRST line broke an invariant is not re-entered on the next
  # activation event, while one that raised a handled error is.
  var faulted = false
  var faultedByDefect = false
  var faultMessage = ""
  let enter = proc() =
    if not impl.activate.isNil:
      try:
        impl.activate(ctx)
      except Defect as d:
        faulted = true
        faultedByDefect = true
        faultMessage = "the Defect " & $d.name & ": " & d.msg
      except CatchableError as e:
        faulted = true
        faultMessage = $e.name & ": " & e.msg
  isonim_owner.runWithOwner(scope, enter)
  if faulted:
    host.activationFaults.add "plugin '" & id & "': activate() raised " &
      faultMessage & " — the plugin is not active and contributes nothing" &
      (if faultedByDefect:
         ". A Defect is a broken invariant rather than a handled error, so " &
         "this plugin will not be activated again this session"
       else: "")
    if faultedByDefect:
      # NOT RE-ARMED. `activateFor` walks the plan on every declared event, and
      # a plugin left merely inactive is retried on the next one. A
      # `CatchableError` earns that retry; a `Defect` does not, for the reason
      # `surface_host.containDefect` gives — the retry is a second run over
      # state whose invariants the language has just said do not hold.
      host.defectedPlugins.incl id
    # Release whatever it created before it threw. `cleanNode` over a scope
    # holding nothing is a no-op, so this is correct for a plugin that threw
    # on its first statement as well as for one that threw on its last.
    isonim_graph.cleanNode(scope)
    rec.active = false
    return false

  # PLAT-9. Join the views the plugin contributed to the surfaces it declared.
  host.surfaces.attachViews(ctx)
  true

proc activateFor*(host: PluginHost; occurred: ActivationEvent): seq[PluginId]
                  {.discardable.} =
  ## LAZY ACTIVATION. Bring up every loadable plugin that declared this event,
  ## each preceded by its dependency closure, in topological order. Returns
  ## the ids that were activated BY THIS CALL — a plugin already up is not in
  ## the answer, which is how a caller can assert that a second occurrence of
  ## the same event is free.
  if not host.resolved:
    raise newException(PluginHostError,
      "activateFor() before resolveAll(): Extensibility-Model §4.2 requires " &
      "resolution to be total before any activation")
  for id in plan(host.resolution, occurred):
    if host.isActive(id): continue
    if host.activateOne(id): result.add id

proc activateEager*(host: PluginHost): seq[PluginId] {.discardable.} =
  ## The startup set: only plugins that declared `startup` WITH a reason,
  ## because `parseManifest` refuses the declaration without one.
  host.activateFor(occurrence(aeStartup))

proc eagerReasons*(host: PluginHost): Table[PluginId, string] =
  eagerReasonsIn(host.resolution)

# ---------------------------------------------------------------------------
# deactivate
# ---------------------------------------------------------------------------

proc reclaim*(host: PluginHost; id: PluginId): int {.discardable.} =
  ## PLAT-8, §8.1.1: "Every handle is attributable to a plugin, so a
  ## misbehaving one is nameable and its **resources are reclaimable without
  ## restarting CodeTracer**."
  ##
  ## THAT SENTENCE HAS TWO HALVES AND THIS IS THE SECOND. Deactivation also
  ## closes every handle, but deactivation is a different thing to do to a
  ## plugin: it unlinks its effects, so the plugin stops observing and does not
  ## come back until the next activation event. `reclaim` closes the OS
  ## resources and leaves the plugin ALIVE — it is what an operator does to a
  ## plugin that is holding forty sockets, and what "without restarting
  ## CodeTracer" concretely means: not the application, and not the plugin
  ## either.
  ##
  ## A plugin whose handles were reclaimed sees `ioClosed` from the streams it
  ## still holds — a value, per §8.1's "error as values" — rather than a crash.
  ##
  ## Returns how many handles were released. Failures during release are
  ## collected rather than allowed to abandon the sweep; see
  ## `handles.closeAll`.
  if not host.records.hasKey(id): return 0
  let rec = host.records[id]
  if rec.ctx.isNil or rec.ctx.state.isNil or rec.ctx.state.handles.isNil:
    return 0
  var failures: seq[HandleCloseFailure] = @[]
  result = rec.ctx.state.handles.closeAll(failures)
  for f in failures:
    host.reclaimFailures.add "plugin '" & id & "': releasing " & $f.kind &
      " '" & f.description & "' failed: " & f.message

proc liveHandleCount*(host: PluginHost; id: PluginId): int =
  ## What the accounting says this plugin still holds. `test_plugin_io_sdk.nim`
  ## asserts this AND asks the OS the same question, because a table that
  ## reached zero is also what a table that forgot a handle looks like.
  if not host.records.hasKey(id): return 0
  let rec = host.records[id]
  if rec.ctx.isNil or rec.ctx.state.isNil or rec.ctx.state.handles.isNil:
    return 0
  rec.ctx.state.handles.liveCount

proc handleReport*(host: PluginHost): string =
  ## Every plugin's live handles, in registration order. §8.1.1's "a
  ## misbehaving one is nameable", from the side the application drives.
  var lines: seq[string] = @[]
  for id in host.registrationOrder:
    if not host.records.hasKey(id): continue
    let rec = host.records[id]
    if rec.ctx.isNil or rec.ctx.state.isNil or rec.ctx.state.handles.isNil:
      continue
    if rec.ctx.state.handles.liveCount == 0: continue
    lines.add rec.ctx.state.handles.describe()
  lines.join("\n")

proc deactivate*(host: PluginHost; id: PluginId): bool {.discardable.} =
  ## Release everything the plugin holds. See this module's header for why
  ## `cleanNode` is the release and the `csClean` sweep is not.
  if not host.isActive(id): return false
  let rec = host.records[id]

  # PLAT-8, §8.1.1: "Processes and sockets are host-owned resources the plugin
  # holds by handle. **Deactivation closes them** — §4.2's rule, and the reason
  # a plugin cannot leak a daemon past its own lifetime."
  #
  # BEFORE `cleanNode`, deliberately. `cleanNode` runs the scope's cleanups,
  # and a plugin that registered `onPluginCleanup` to tidy its own process
  # would then race the sweep. Closing first means the sweep is the release and
  # the plugin's own cleanup finds the work already done, which is the same
  # ordering `plugin_api.onPluginCleanup`'s docstring promises: the release
  # does not depend on the plugin having registered anything.
  host.reclaim(id)

  # The scheduling half FIRST: a computation already sitting in isonim's
  # `Effects` queue is run by `flushUpdates` if it is still `csStale`, and
  # `cleanNode` does not clear that flag. Marking them clean before the
  # release means an in-flight batch cannot resurrect a released effect.
  for comp in rec.ctx.state.effects:
    comp.state = csClean

  # THE RELEASE. One call. Every computation created under the scope is
  # unlinked from every signal it read, every nested scope is walked, and
  # every registered cleanup runs.
  isonim_graph.cleanNode(rec.scope)

  rec.active = false
  inc rec.deactivations
  true

proc deactivateAll*(host: PluginHost): int {.discardable.} =
  ## Reverse activation order, so a dependent is released before what it
  ## depends on.
  for i in countdown(host.activationLog.high, 0):
    let id = host.activationLog[i]
    if host.deactivate(id): inc result

# ---------------------------------------------------------------------------
# What a user is shown
# ---------------------------------------------------------------------------

proc violations*(host: PluginHost): seq[BudgetViolation] =
  ## Every budget violation, across every plugin, in plugin-registration
  ## order so the report is stable.
  for id in host.registrationOrder:
    if host.records.hasKey(id):
      for v in host.records[id].ctx.state.violations:
        result.add v

proc suspendedPlugins*(host: PluginHost): seq[PluginId] =
  for id in host.registrationOrder:
    if host.records.hasKey(id) and host.records[id].ctx.state.suspended:
      result.add id

proc report*(host: PluginHost): string =
  ## The whole of what the host has to say about its plugins: the load
  ## failures first, then the budget violations. Every line names a plugin.
  ##
  ## This is one string rather than two lists because the user-facing question
  ## is "why is this plugin not doing anything", and the answer is in one of
  ## the two places. A surface that showed only one of them would be right
  ## half the time.
  var lines: seq[string] = @[]
  if not host.extensionsEnabled:
    # §7's recovery route says so FIRST. A user who started with the flag and
    # then reads a column of "your plugin did not load" lines is being told
    # the wrong thing in the right amount of detail.
    lines.add "extensions are disabled for this session (" &
      NoExtensionsFlag & "): " & $host.parsed.len &
      " manifest(s) were read and none was resolved or activated"
  for e in host.resolution.errors:
    lines.add render(e)
  # PLAT-10. A capability a plugin DECLARED and does not hold is the commonest
  # reason a working plugin suddenly stops doing one of its jobs, and it is a
  # reason only this host knows. Printed with the date, because "you revoked
  # it" and "you never granted it" are different sentences to a user looking
  # at a feature that has gone.
  if host.ledgerAttached:
    for id in host.registrationOrder:
      if not host.declaredGrants.hasKey(id): continue
      for c in Capability:
        if c notin host.declaredGrants[id].capabilities: continue
        case host.ledger.stateOf(id, c)
        of gsGranted: discard
        of gsRevoked:
          lines.add "plugin '" & id & "': '" & $c & "' was REVOKED on " &
            host.ledger.decidedAt(id, c) & "; the plugin declares it and is " &
            "refused it"
        of gsUndecided:
          lines.add "plugin '" & id & "': '" & $c & "' is declared and has " &
            "never been granted, so it is refused"
  for v in host.violations():
    lines.add describe(v)
  for f in host.activationFaults:
    lines.add f
  for f in host.reclaimFailures:
    lines.add f
  let surfaceLines = host.surfaces.report()
  if surfaceLines.len > 0 and host.extensionsEnabled:
    lines.add surfaceLines
  lines.join("\n")

proc renderSurface*(host: PluginHost; qualifiedId: string;
                    core = initDegradedStateSnapshot()): ViewNode =
  ## PLAT-9's one render entry point for the application. Delegates to the
  ## surface host so that a front-end has one call to make and cannot reach
  ## past the boundary by accident.
  host.surfaces.renderSurface(qualifiedId, core)

proc reprobeDependencies*(host: PluginHost;
                          occurred: ActivationEvent): seq[string]
                          {.discardable.} =
  ## §8.2's declared trigger, from the side the application drives. THE SAME
  ## EVENT VALUE that `activateFor` takes, so a front-end announcing "a trace
  ## opened" makes both things happen from one occurrence rather than from two
  ## call sites that could disagree about what happened.
  host.surfaces.reprobe(occurred)

proc grantsReport*(host: PluginHost): string =
  ## What every loadable plugin was granted, with its declared sets —
  ## §8.4's "declared in a manifest the user can read before granting",
  ## rendered for a user who is about to grant it.
  ##
  ## A plugin holding `trace` + `socket:remote` gets `traceEgressDisclosure`
  ## appended by `describeGrants`, so the pair is never shown as two ordinary
  ## rows.
  var lines: seq[string] = @[]
  for id in host.registrationOrder:
    if not host.resolution.manifests.hasKey(id): continue
    lines.add describeGrants(id, host.resolution.manifests[id].grants)
  lines.join("\n")
