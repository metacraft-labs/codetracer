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

import std/[strutils, tables, times]

import isonim/core/types as isonim_types
import isonim/core/graph as isonim_graph
import isonim/core/owner as isonim_owner

import ./plugin_api

export plugin_api

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

proc newPluginHost*(coreVersion: SemVer;
                    budget = DefaultEffectBudget): PluginHost =
  PluginHost(coreVersion: coreVersion, budget: budget,
             impls: initTable[PluginId, PluginImplementation](),
             records: initTable[PluginId, PluginRecord]())

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
    host.registrationOrder.add result.manifest.id

# ---------------------------------------------------------------------------
# resolve
# ---------------------------------------------------------------------------

proc resolveAll*(host: PluginHost) =
  ## The whole registry, once, before anything is activated.
  host.resolution = resolve(host.parsed, host.coreVersion)
  host.resolved = true

proc loadErrors*(host: PluginHost): seq[PluginError] =
  host.resolution.errors

proc isLoadable*(host: PluginHost; id: PluginId): bool =
  host.resolved and host.resolution.isLoadable(id)

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
  if host.isActive(id): return true
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

  # `runWithOwner` makes `scope` the AMBIENT owner, so every `createEffect`
  # and `createMemo` the plugin reaches — through `plugin_api`, which is the
  # only way it can — attaches itself to `scope.owned`. The plugin does not
  # opt in and cannot opt out.
  let enter = proc() =
    if not impl.activate.isNil:
      impl.activate(ctx)
  isonim_owner.runWithOwner(scope, enter)
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

proc deactivate*(host: PluginHost; id: PluginId): bool {.discardable.} =
  ## Release everything the plugin holds. See this module's header for why
  ## `cleanNode` is the release and the `csClean` sweep is not.
  if not host.isActive(id): return false
  let rec = host.records[id]

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
  for e in host.resolution.errors:
    lines.add render(e)
  for v in host.violations():
    lines.add describe(v)
  lines.join("\n")
