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
    host.registrationOrder.add result.manifest.id

# ---------------------------------------------------------------------------
# resolve
# ---------------------------------------------------------------------------

proc resolveAll*(host: PluginHost) =
  ## The whole registry, once, before anything is activated.
  ##
  ## THE FRONT-END IS PASSED IN, and that is what makes §6.3's refusal real
  ## rather than a function nobody calls: `resolve` evaluates a required
  ## surface against it in phase 3b, fails the plugin that has no view there,
  ## and blocks that plugin's dependents in phase 6 like any other failure.
  ## Passing `none` here would leave `surfaceRefusals` a pure function with no
  ## effect on anything — which is exactly what it was before this line.
  host.resolution = resolve(host.parsed, host.coreVersion,
                            some(host.frontEnd))
  host.resolved = true

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
