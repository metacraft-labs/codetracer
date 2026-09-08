## test_plugin_lifecycle.nim — PLAT-7's real-stack lifecycle suite:
## `discover → resolve → activate → run → deactivate`, over the product's own
## `ReplayDataStore`, its own `DebugControlsVM`, and `isonim`'s own reactive
## graph and owner tree.
##
## ## NO MOCKS, AND THE ONE NAME THAT LOOKS LIKE ONE
##
## The workspace policy asks every use of a mock object to be justified in a
## test file's header. **There is one name here that reads like a mock and is
## not**, and it is justified by name:
##
##   `backend/mock_backend.MockBackendService` — one of the four
##   `BackendService` implementations the ViewModel layer ships, exported from
##   `codetracer_embed` as part of the SDK's public surface
##   (CodeTracer-Embed-SDK.md §3.1's `BackendService` row) and constructed by
##   essentially every suite under this directory. It is a real transport that
##   answers DAP commands from a table rather than from a `replay-server`
##   process; the alternative transports either spawn one (`stdio_backend`,
##   which `codetracer_embed` deliberately withholds) or need a browser
##   (`worker_backend`). It is what the store is DESIGNED to be driven by in
##   process, not a stand-in for a collaborator this suite is avoiding.
##
## Everything else is the real thing: real signals, real memos, real effects,
## real owner nodes, a real monotonic clock, and plugins that are ordinary Nim
## modules under `plugin_fixtures/` — a tree declared BOTH an SDK-consumer tree
## and a plugin tree, because those are two different claims:
## `ci/test/sdk-facade-boundary.sh` holds them to §2.1's rule that an extension
## consumes the facade and not the store, and
## `ci/test/plugin-reactive-boundary.sh` holds them to §5.3's rule that an
## extension cannot reach a raw `isonim` reactive primitive — which is what
## makes the budget enforcement rather than advice, and which PLAT-7 shipped
## claiming and did not have.
##
## ## THE ASSERTION THAT MATTERS, AND WHY IT IS TWO ASSERTIONS
##
## PLAT-7: "A deactivated plugin's effects no longer run — asserted, because
## this is the leak that makes plugin hosts degrade over a session."
##
## A counter that stops moving is necessary and not sufficient: a plugin that
## guarded its own body with `if active` would produce exactly that reading
## while remaining subscribed forever. So this suite asserts BOTH:
##
##   1. **The effect did not run.** `p.effectRuns` does not move across five
##      further writes to the signal it was watching — and, as the positive
##      control on the same code path, a SECOND plugin that was not
##      deactivated has its counter move across those same five writes.
##   2. **The subscription is gone from the graph.** Every computation the
##      plugin created is absent from `store.debugger.observers` after
##      deactivation, and present before it. That is `cleanNode` unlinking
##      them, and it is what makes the release structural rather than a
##      convention the plugin has to honour.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## `unittest.check` inside a plain `proc` assigns a module-level
## `testStatusIMPL` and the test still reports `[OK]`. **Every assertion
## helper in this file is a `template`.**
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_plugin_lifecycle.nim

import std/[monotimes, strutils, tables, times, unittest]

# `codetracer_embed` carries the store, the ViewModels, the mock transport,
# the reactive core and PLAT-7's plugin API. The two extra imports are the
# parts of isonim the facade does not re-export and this suite needs in order
# to look at the graph rather than at the host's account of it: `graph` for
# `ComputationBase` and a signal's `observers`, `batch` for the queued-effect
# case. IsoNim is a peer package, not an SDK internal (§4.1).
import isonim/core/graph
import isonim/core/batch as isonim_batch

import codetracer_embed
import plugin_host/host
import plugin_fixtures/position_watch_plugin

# The `compiles` answers, computed in a module whose import list is a PLUGIN's.
# They cannot be computed here: this suite imports `codetracer_embed`, which is
# the trusted audience's door, so `compiles(createEffect(...))` written in this
# file would answer `true` and would be answering about the suite.
import plugin_fixtures/surface_probe_plugin

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckObserves(sig: untyped; comps: seq[ComputationBase];
                    expected: bool) =
  ## Is every one of `comps` in the signal's own `observers` sequence?
  ##
  ## THIS IS THE STRUCTURAL ASSERTION and it reads `isonim`'s graph directly
  ## rather than asking the host what it did. `graph.removeSourceObserver` is
  ## what `cleanNode` calls; this is the sequence it removes from.
  var present = 0
  for c in comps:
    for obs in sig.observers:
      if obs == c:
        inc present
        break
  checkpoint("plugin computations: " & $comps.len & ", observing: " &
             $present & ", signal has " & $sig.observers.len & " observer(s)")
  ck comps.len > 0
  if expected:
    ck present == comps.len
  else:
    ck present == 0

const
  CoreVersion = semver(1, 4, 0)
  GenerousBudget = initDuration(seconds = 5)
    ## The lifecycle suite is not about the budget, and a tight budget here
    ## would make an unrelated case fail on a loaded host —
    ## Verification-Harness-Traps §12. `test_plugin_effect_budget.nim` is
    ## where the budget is the subject and the burn is a multiple of it.

proc trivialManifest(id: string; body = ""): string =
  result = "{\n  \"id\": \"" & id & "\",\n  \"version\": \"1.0.0\""
  if body.len > 0: result.add ",\n" & body
  result.add "\n}"

# ---------------------------------------------------------------------------

suite "PLAT-7: a manifest naming something that does not exist fails at load":

  test "the plugin is named, and its activate is never called":
    createRoot proc(disposeRoot: proc()) =
      let host = newPluginHost(CoreVersion, GenerousBudget)
      var brokenActivated = false
      var healthyActivated = false

      host.register(trivialManifest("acme.broken", """
  "activation": [ { "event": "trace-opened" } ],
  "contributes": {
    "pane": [ { "id": "acme.broken.pane", "views": ["Text", "Sparkline"] } ]
  }"""), "acme.broken.json", proc(ctx: PluginContext) =
        brokenActivated = true)

      host.register(trivialManifest("acme.healthy", """
  "activation": [ { "event": "trace-opened" } ]"""),
        "acme.healthy.json", proc(ctx: PluginContext) =
        healthyActivated = true)

      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))

      # THE EFFECT, NOT THE REPORT. The milestone's rule from six prior
      # milestones: assert that the broken plugin did not come up, not that a
      # message was produced.
      ck not brokenActivated
      ck not host.isActive("acme.broken")
      # And the positive control on the same path: a healthy plugin
      # registered in the same host, resolved in the same pass and matched by
      # the same event DID come up. Without it, "nothing activated" would
      # score green on a host that activates nothing at all.
      ck healthyActivated
      ck host.isActive("acme.healthy")

      let text = host.report()
      checkpoint(text)
      ck text.contains("acme.broken")
      ck text.contains("Sparkline")
      ck host.resolution.failureFor("acme.broken").code == pecUnknownView
      disposeRoot()

  test "a plugin whose dependency failed does not activate half-alive":
    createRoot proc(disposeRoot: proc()) =
      let host = newPluginHost(CoreVersion, GenerousBudget)
      var dependentActivated = false
      var brokenActivated = false
      host.register(trivialManifest("acme.base", """
  "capabilities": ["telepathy"]"""), "base.json",
        proc(ctx: PluginContext) = brokenActivated = true)
      host.register(trivialManifest("acme.dependent", """
  "requires": { "plugins": { "acme.base": "^1.0.0" } },
  "activation": [ { "event": "trace-opened" } ]"""), "dependent.json",
        proc(ctx: PluginContext) = dependentActivated = true)
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      ck not brokenActivated
      ck not dependentActivated
      ck host.resolution.failureFor("acme.dependent").code ==
        pecBlockedByDependency
      ck host.report().contains("acme.base")
      disposeRoot()

suite "PLAT-7: resolution is total before any activation":

  test "activating before resolveAll raises, naming the rule":
    createRoot proc(disposeRoot: proc()) =
      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(trivialManifest("acme.a"), "a.json",
        proc(ctx: PluginContext) = discard)
      var raised = false
      var message = ""
      try:
        discard host.activateOne("acme.a")
      except PluginHostError as e:
        raised = true
        message = e.msg
      ck raised
      ck message.contains("resolution to be total")
      # The control: after resolving, the same call succeeds. A refusal that
      # could not be lifted would be indistinguishable from a broken host.
      host.resolveAll()
      ck host.activateOne("acme.a")
      disposeRoot()

  test "registering after resolveAll raises rather than resolving in halves":
    createRoot proc(disposeRoot: proc()) =
      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.resolveAll()
      var raised = false
      try:
        host.register(trivialManifest("acme.late"), "late.json",
          proc(ctx: PluginContext) = discard)
      except PluginHostError:
        raised = true
      ck raised
      disposeRoot()

suite "PLAT-7: lazy activation, and eager only with a stated reason":

  test "a plugin waits for the event it declared":
    createRoot proc(disposeRoot: proc()) =
      let host = newPluginHost(CoreVersion, GenerousBudget)
      var activations = 0
      host.register(trivialManifest("acme.noir", """
  "activation": [ { "event": "language", "value": "noir" } ]"""),
        "noir.json", proc(ctx: PluginContext) = inc activations)
      host.resolveAll()

      discard host.activateFor(occurrence(aeTraceOpened))
      ck activations == 0
      discard host.activateFor(occurrence(aeLanguage, "rust"))
      ck activations == 0
      discard host.activateEager()
      ck activations == 0

      let brought = host.activateFor(occurrence(aeLanguage, "noir"))
      ck brought == @["acme.noir"]
      ck activations == 1
      # A second occurrence of the same event is free: a plugin is activated
      # once, not once per event.
      ck host.activateFor(occurrence(aeLanguage, "noir")).len == 0
      ck activations == 1
      disposeRoot()

  test "eager activation happens at startup and carries its reason":
    createRoot proc(disposeRoot: proc()) =
      let host = newPluginHost(CoreVersion, GenerousBudget)
      var eagerUp = false
      var lazyUp = false
      host.register(trivialManifest("acme.eager", """
  "activation": [ { "event": "startup",
                    "reason": "owns the decoder every other plugin resolves against" } ]"""),
        "eager.json", proc(ctx: PluginContext) = eagerUp = true)
      host.register(trivialManifest("acme.lazy", """
  "activation": [ { "event": "trace-opened" } ]"""),
        "lazy.json", proc(ctx: PluginContext) = lazyUp = true)
      host.resolveAll()
      discard host.activateEager()
      ck eagerUp
      ck not lazyUp
      ck host.eagerReasons()["acme.eager"].contains("decoder")
      ck host.eagerReasons().len == 1
      disposeRoot()

  test "an activation plan brings up dependencies first":
    createRoot proc(disposeRoot: proc()) =
      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(trivialManifest("acme.base"), "base.json",
        proc(ctx: PluginContext) = discard)
      host.register(trivialManifest("acme.mid", """
  "requires": { "plugins": { "acme.base": "^1.0.0" } }"""), "mid.json",
        proc(ctx: PluginContext) = discard)
      host.register(trivialManifest("acme.top", """
  "requires": { "plugins": { "acme.mid": "^1.0.0" } },
  "activation": [ { "event": "trace-opened" } ]"""), "top.json",
        proc(ctx: PluginContext) = discard)
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      ck host.activationLog == @["acme.base", "acme.mid", "acme.top"]
      disposeRoot()

suite "PLAT-7: observation is a signal read; action is a ViewModel action proc":

  test "a plugin observes the real store and acts through DebugControlsVM":
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let controls = createDebugControlsVM(store)
      let p = newPositionWatchPlugin(controls, stepAtTicks = 30'u64)

      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(ManifestJson, "position_watch.json", p.activator())
      host.resolveAll()
      ck host.loadErrors().len == 0
      discard host.activateFor(occurrence(aeTraceOpened))
      ck host.isActive("codetracer.position-watch")

      # The effect ran once at creation — that is what `createEffect` does.
      ck p.effectRuns == 1
      let commandsBefore = mock.receivedCommands.len

      store.updateDebuggerPosition(10'u64, file = "vault.nr", line = 3)
      ck p.effectRuns == 2
      ck p.seenTicks[^1] == 10'u64
      ck p.lastCaption == "vault.nr:3"
      ck p.captionNow() == "vault.nr:3"
      ck p.stepsIssued == 0

      # The action. §5.2: the product's own proc, and the evidence is that a
      # real DAP command reached the real backend.
      store.updateDebuggerPosition(30'u64, file = "vault.nr", line = 4)
      ck p.stepsIssued == 1
      ck mock.receivedCommands.len > commandsBefore

      store.dispose()
      disposeRoot()

  test "there is no second dispatch path, and the control says the first one exists":
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let controls = createDebugControlsVM(store)
      let host = newPluginHost(CoreVersion, GenerousBudget)

      # §5.2: "there is no separate command dispatch for extensions, and
      # therefore no way for an extension to reach a behaviour the product
      # does not already expose."
      #
      # THE POSITIVE CONTROL RUNS THROUGH THE SAME MECHANISM. `compiles` is
      # the rule and `compiles` is the control: the sanctioned action path
      # must answer `true` to the same question the four absent spellings
      # answer `false` to. A pair of `not compiles` assertions alone would
      # pass on a misspelling of the receiver.
      ck compiles(controls.stepForward())
      ck compiles(controls.continueExecution())
      ck compiles(controls.restoreAt(7'u64))
      ck not compiles(host.dispatch("step-forward"))
      ck not compiles(host.emit("step-forward"))
      ck not compiles(host.send("step-forward"))
      ck not compiles(host.invokeCommand("step-forward"))

      store.dispose()
      disposeRoot()

suite "PLAT-7: deactivation releases everything through the owner tree":

  test "a deactivated plugin's effects no longer run, and its edges are gone":
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let controls = createDebugControlsVM(store)
      let leaving = newPositionWatchPlugin(controls)
      let staying = newPositionWatchPlugin(controls)

      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(ManifestJson, "leaving.json", leaving.activator())
      host.register(
        ManifestJson.replace("codetracer.position-watch", "codetracer.staying"),
        "staying.json", staying.activator())
      host.resolveAll()
      ck host.loadErrors().len == 0
      discard host.activateFor(occurrence(aeTraceOpened))
      ck host.isActive("codetracer.position-watch")
      ck host.isActive("codetracer.staying")

      store.updateDebuggerPosition(1'u64, file = "a.nr", line = 1)
      let leavingRuns = leaving.effectRuns
      let stayingRuns = staying.effectRuns
      let leavingMemoRuns = leaving.memoRuns
      let stayingMemoRuns = staying.memoRuns
      ck leavingRuns == 2
      ck stayingRuns == 2

      let leavingComps = host.contextFor("codetracer.position-watch").state.effects
      let stayingComps = host.contextFor("codetracer.staying").state.effects
      ck leavingComps.len == 2          # the memo and the effect
      # BEFORE: both plugins' computations are observers of the real signal.
      ckObserves store.debugger, leavingComps, true
      ckObserves store.debugger, stayingComps, true
      let observersBefore = store.debugger.observers.len

      ck host.deactivate("codetracer.position-watch")
      ck not host.isActive("codetracer.position-watch")

      # 1. STRUCTURAL: the edges are gone from isonim's own observer list,
      #    and only the deactivated plugin's are.
      ckObserves store.debugger, leavingComps, false
      ckObserves store.debugger, stayingComps, true
      ck store.debugger.observers.len == observersBefore - leavingComps.len

      # 2. BEHAVIOURAL: the effect does not run, across five further writes —
      #    and the still-active plugin's does, over the same writes, through
      #    the same host and the same signal. That is the positive control,
      #    and it runs through the code path the rule is about.
      for i in 2 .. 6:
        store.updateDebuggerPosition(uint64(i), file = "a.nr", line = i)
      ck leaving.effectRuns == leavingRuns
      ck leaving.memoRuns == leavingMemoRuns
      ck staying.effectRuns == stayingRuns + 5
      ck staying.memoRuns == stayingMemoRuns + 5

      store.dispose()
      disposeRoot()

  test "deactivation inside a batch also stops an already-queued effect":
    # isonim's `signals.notifySignalWrite` pushes observers onto the `Effects`
    # queue AND marks them `csStale` at WRITE time; `batch.flushUpdates` later
    # runs anything still stale, and `cleanNode` does not clear that flag. So
    # a plugin released mid-batch would otherwise get one more run AFTER its
    # release. `host.deactivate` marks the plugin's recorded computations
    # clean for exactly this window.
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let controls = createDebugControlsVM(store)
      let p = newPositionWatchPlugin(controls)
      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(ManifestJson, "batched.json", p.activator())
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      let runsAtActivation = p.effectRuns

      batch proc() =
        # The write queues the plugin's effect...
        store.updateDebuggerPosition(42'u64, file = "b.nr", line = 2)
        # ...and the plugin is released before the queue is flushed.
        discard host.deactivate("codetracer.position-watch")
      # The flush happened when `batch` returned.
      ck p.effectRuns == runsAtActivation
      ck isonim_batch.batchDepth == 0

      store.dispose()
      disposeRoot()

  test "a subscription created outside the activation scope is refused":
    # §4.2's rule has a shape the owner tree cannot enforce on its own: an
    # effect created while some OTHER owner is ambient is owned by that owner,
    # and `cleanNode(scope)` will never see it. `requireScope` refuses it
    # instead of creating the one thing deactivation cannot release.
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let controls = createDebugControlsVM(store)
      let p = newPositionWatchPlugin(controls)
      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(ManifestJson, "escapee.json", p.activator())
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))

      let ctx = host.contextFor("codetracer.position-watch")
      ck ctx != nil
      let compsBefore = ctx.state.effects.len
      var raised = false
      var message = ""
      try:
        # Called from the TEST's owner, not from inside `runWithOwner(scope)`.
        ctx.pluginEffect("escaped", proc() = discard)
      except PluginScopeError as e:
        raised = true
        message = e.msg
      ck raised
      ck message.contains("codetracer.position-watch")
      ck message.contains("outside its")
      ck ctx.state.effects.len == compsBefore   # nothing was created

      # THE CONTROL, THROUGH THE SAME CALL. `pluginEffect` refuses a PLACE,
      # not the operation: run it with the plugin's own scope ambient — which
      # is exactly what `activateOne` does — and it succeeds. Without this
      # arm, a `pluginEffect` that had been broken into always raising would
      # score green above.
      var madeInScope = false
      runWithOwner(ctx.scope, proc() =
        ctx.pluginEffect("in-scope", proc() = madeInScope = true))
      ck madeInScope
      ck ctx.state.effects.len == compsBefore + 1
      store.dispose()
      disposeRoot()

  test "a plugin can be deactivated and activated again, in a fresh scope":
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let controls = createDebugControlsVM(store)
      let p = newPositionWatchPlugin(controls)
      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(ManifestJson, "cycle.json", p.activator())
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      let firstComps = host.contextFor("codetracer.position-watch").state.effects
      ck host.deactivate("codetracer.position-watch")
      ck not host.deactivate("codetracer.position-watch")  # idempotent

      ck host.activateOne("codetracer.position-watch")
      let secondComps = host.contextFor("codetracer.position-watch").state.effects
      ck secondComps.len == 2
      # A FRESH SCOPE, not the old one revived: none of the first
      # activation's computations is in the second's, and the first's are
      # still unsubscribed.
      var shared = 0
      for a in firstComps:
        for b in secondComps:
          if a == b: inc shared
      ck shared == 0
      ckObserves store.debugger, firstComps, false
      ckObserves store.debugger, secondComps, true

      let runs = p.effectRuns
      store.updateDebuggerPosition(99'u64, file = "c.nr", line = 9)
      ck p.effectRuns == runs + 1

      store.dispose()
      disposeRoot()

  test "deactivateAll releases every plugin, dependents first":
    createRoot proc(disposeRoot: proc()) =
      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(trivialManifest("acme.base"), "base.json",
        proc(ctx: PluginContext) = discard)
      host.register(trivialManifest("acme.top", """
  "requires": { "plugins": { "acme.base": "^1.0.0" } },
  "activation": [ { "event": "trace-opened" } ]"""), "top.json",
        proc(ctx: PluginContext) = discard)
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      ck host.deactivateAll() == 2
      ck not host.isActive("acme.base")
      ck not host.isActive("acme.top")
      disposeRoot()

suite "PLAT-7: the plugin surface withholds the raw reactive primitives":

  test "a plugin cannot NAME createEffect, and can name ctx.pluginEffect":
    # THE FALSIFIED CLAIM, NOW ASSERTED. PLAT-7 shipped saying "a plugin never
    # receives `createEffect`"; it did, because `codetracer_embed` re-exports
    # `isonim/core/[signals, computation, owner]` for §4.1's Mode N consumers
    # and a plugin was a declared consumer of that same facade. Measured on a
    # plugin using only that facade, 20 ms budget: a raw `createEffect` in
    # `activate` ran 160 ms on every write, never entered `runBudgeted`, and was
    # never attributed or suspended.
    #
    # Every constant below is a `compiles` in `surface_probe_plugin.nim`, whose
    # imports are a plugin's. The negatives and the positives come from the same
    # mechanism, so a `compiles` that had stopped working would redden the
    # positives rather than turning the negatives green
    # (Verification-Harness-Traps §4a).
    ck not RawEffectInScope
    ck not RawRenderEffectInScope
    ck not RawComputedInScope
    ck not RawMemoInScope
    ck not RawOnMountInScope
    ck not RawRootInScope
    ck not RawOnCleanupInScope
    ck not RawRunWithOwnerInScope
    ck not RawGetOwnerInScope
    ck not RawUpdateComputationInScope

    # THE POSITIVE HALF, through the same `compiles`. Ten denials and eight
    # replacements: every denied primitive has one, which is what makes this a
    # narrowing rather than a removal.
    ck WrappedEffectInScope
    ck WrappedRenderEffectInScope
    ck WrappedComputedInScope
    ck WrappedMemoInScope
    ck WrappedOnMountInScope
    ck WrappedRootInScope
    ck WrappedCleanupInScope
    ck ObserveInScope

    # AND WHAT IS DELIBERATELY NOT NARROWED. §4.1's "signals cross no boundary"
    # holds for a plugin too: a read is not a computation and a signal is not
    # one either. A denial that had swallowed these would be a different rule.
    ck SignalCreateInScope
    ck SignalReadInScope
    ck ViewModelsInScope

  test "the surface is the facade minus exactly the denied set":
    # The gate asserts this over the source; this asserts the pair of names
    # exists at all, so a rename cannot leave the gate reading a file nobody
    # imports.
    ck CodeTracerPluginSurfaceModule == "codetracer_plugin"
    ck CodeTracerEmbedFacadeModule == "codetracer_embed"
    ck PluginDeniedPrimitives.len == 10
    var withReplacement = 0
    for entry in PluginDeniedPrimitives:
      if entry.primitive.len > 0 and entry.replacement.len > 0:
        inc withReplacement
    ck withReplacement == PluginDeniedPrimitives.len

suite "PLAT-7: createRoot no longer escapes the activation scope":

  # THE PAIR IS THE POINT. PLAT-7's status section named `createRoot` as the one
  # escape still open and did not close it. These two cases are the same plugin
  # written twice — once with the raw primitive, once with the wrapper — through
  # the same host, the same signal and the same `deactivate` call. The first
  # MEASURES the escape rather than describing it; the second is the fix.
  #
  # The raw one is written here, in the suite, because the suite imports
  # `codetracer_embed`: a plugin cannot write that line any more, in either
  # spelling, which is what the two cases above and
  # `ci/test/plugin-reactive-boundary.sh` respectively assert.

  test "a raw createRoot detaches the root — the escape, measured":
    createRoot proc(disposeRoot: proc()) =
      let s = createSignal(0)
      var runs = 0
      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(trivialManifest("acme.raw-root", """
  "activation": [ { "event": "trace-opened" } ]"""), "raw-root.json",
        proc(ctx: PluginContext) =
          createRoot proc(dispose: proc()) =
            ctx.pluginEffect("inside-raw-root", proc() =
              inc runs
              discard ctx.observe(s)))
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      ck runs == 1
      s.val = 1
      ck runs == 2

      # `createRoot` sets `root.owner` and never adds the root to the parent's
      # `owned` — it cannot, because `owned` is `seq[ComputationBase]` and a
      # root is a plain `OwnerBase`. So `cleanNode(scope)` walks straight past
      # it and the effect keeps its subscription.
      ck host.deactivate("acme.raw-root")
      ck not host.isActive("acme.raw-root")
      s.val = 2
      checkpoint("after deactivation the detached effect ran " & $runs &
                 " time(s); the signal still has " & $s.observers.len &
                 " observer(s)")
      ck runs == 3
      ck s.observers.len == 1
      disposeRoot()

  test "ctx.pluginRoot releases with the scope, over the same plugin":
    createRoot proc(disposeRoot: proc()) =
      let s = createSignal(0)
      var runs = 0
      var cleaned = 0
      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(trivialManifest("acme.wrapped-root", """
  "activation": [ { "event": "trace-opened" } ]"""), "wrapped-root.json",
        proc(ctx: PluginContext) =
          ctx.pluginRoot("root", proc(disposeInner: proc()) =
            ctx.onPluginCleanup(proc() = inc cleaned)
            ctx.pluginEffect("inside-plugin-root", proc() =
              inc runs
              discard ctx.observe(s))))
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      ck runs == 1
      s.val = 1
      ck runs == 2
      ck s.observers.len == 1

      # The wrapper registers the root's own `dispose` on the plugin's scope
      # `cleanups`, which is the list `cleanNode` runs — so ONE `cleanNode`
      # releases the root as well as everything directly owned.
      ck host.deactivate("acme.wrapped-root")
      s.val = 2
      checkpoint("after deactivation the wrapped effect ran " & $runs &
                 " time(s); the signal has " & $s.observers.len &
                 " observer(s)")
      ck runs == 2
      ck s.observers.len == 0
      disposeRoot()

  test "a checkpoint still fires in an OUTER run after a nested one returns":
    # THE RE-ENTRANCY THE WRAPPER HAS TO HAVE, and it is not a nicety. A run
    # nested inside another — a `pluginEffect` created inside a `pluginRoot`,
    # whose first body runs immediately — must not leave the OUTER run marked
    # "not running" when it returns. If it does, every `ctx.observe` and
    # `ctx.checkBudget` after it returns without consulting a deadline, and a
    # plugin buys itself an unbounded, uninterruptible body by putting one
    # wrapped call at the top of its loop.
    createRoot proc(disposeRoot: proc()) =
      let tight = initDuration(milliseconds = 20)
      var raised = false
      var checkpointsAfterNested = 0
      let host = newPluginHost(CoreVersion, tight)
      host.register(trivialManifest("acme.nested", """
  "activation": [ { "event": "trace-opened" } ]"""), "nested.json",
        proc(ctx: PluginContext) =
          ctx.pluginRoot("outer", proc(disposeInner: proc()) =
            # The NESTED budgeted run, which returns normally.
            ctx.pluginEffect("nested", proc() = discard)
            # Now burn past the outer run's deadline and ask.
            let deadline = getMonoTime() + ctx.state.budget * 4
            while getMonoTime() < deadline: discard
            try:
              inc checkpointsAfterNested
              ctx.checkBudget()
            except PluginBudgetExceeded:
              raised = true))
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      ck checkpointsAfterNested == 1
      ck raised
      let vs = host.violations()
      ck vs.len == 1
      ck vs[0].effect == "outer"
      # NOT `abortedMidRun`: this plugin CAUGHT its own `PluginBudgetExceeded`,
      # so the wrapper never saw one. It is tripped anyway, because the wrapper
      # measures elapsed time regardless of who swallowed the exception — which
      # is the distinction `abortedMidRun` exists to record and the reason this
      # case asserts `raised` on the plugin's own side instead.
      ck not vs[0].abortedMidRun
      disposeRoot()

  test "the body inside a plugin root is budgeted like any other":
    createRoot proc(disposeRoot: proc()) =
      let tight = initDuration(milliseconds = 20)
      let host = newPluginHost(CoreVersion, tight)
      host.register(trivialManifest("acme.slow-root", """
  "activation": [ { "event": "trace-opened" } ]"""), "slow-root.json",
        proc(ctx: PluginContext) =
          ctx.pluginRoot("root", proc(disposeInner: proc()) =
            let deadline = getMonoTime() + ctx.state.budget * 8
            while getMonoTime() < deadline: discard))
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      let vs = host.violations()
      ck vs.len == 1
      ck vs[0].effect == "root"
      ck vs[0].plugin == "acme.slow-root"
      ck host.contextFor("acme.slow-root").state.suspended
      disposeRoot()

  test "the body inside a plugin MEMO is budgeted like any other":
    # THE PRIMITIVE §5.1 NAMES FIRST, and until 2026-09-08 nothing graded it.
    # `pluginMemo`'s docstring promises "the memo's body is budgeted exactly as
    # an effect's is", §5.4's layer table promises it and deliverable 6
    # promises it — and a mutation that replaced `runBudgeted(c, name, inner)`
    # with a bare `inner()` SURVIVED all 23 lifecycle cases, all 6 budget cases
    # and the budget suite run alone. The property was real in the shipped code
    # and nothing measured it, which is a promise and not a result.
    #
    # It is a separate case from the one above rather than an assertion added
    # to it because `pluginRoot` and `pluginMemo` reach `runBudgeted` by
    # different routes: the root wraps the body isonim hands it, the memo wraps
    # an INNER closure and returns a captured `latest` afterwards, which is the
    # shape that made it possible to drop the wrapper and still produce the
    # right value.
    createRoot proc(disposeRoot: proc()) =
      let tight = initDuration(milliseconds = 20)
      let host = newPluginHost(CoreVersion, tight)
      var m: Memo[int]
      host.register(trivialManifest("acme.slow-memo", """
  "activation": [ { "event": "trace-opened" } ]"""), "slow-memo.json",
        proc(ctx: PluginContext) =
          m = ctx.pluginMemo("memo", proc(): int =
            let deadline = getMonoTime() + ctx.state.budget * 8
            while getMonoTime() < deadline: discard
            7))
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))

      # READ IT. The value is asserted before the violation is, because a memo
      # that produced nothing would satisfy every claim about its cost for the
      # wrong reason — Verification-Harness-Traps §2: assert what the thing
      # PRODUCED, not only the flags around it. `isonim`'s `createMemo` runs
      # its body once eagerly at creation, so this read is served from the
      # cache; the assertion is that the body ran and its value survived the
      # budget wrapper's `latest` round trip.
      ck val(m) == 7

      let vs = host.violations()
      ck vs.len == 1
      ck vs[0].effect == "memo"
      ck vs[0].plugin == "acme.slow-memo"
      ck vs[0].observed > tight
      ck host.contextFor("acme.slow-memo").state.suspended
      disposeRoot()

suite "PLAT-7: the other wrapped primitives are owned and budgeted too":

  test "pluginComputed, pluginRenderEffect and pluginOnMount are recorded":
    createRoot proc(disposeRoot: proc()) =
      let s = createSignal(0)
      var computedRuns = 0
      var renderRuns = 0
      var mountRuns = 0
      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(trivialManifest("acme.every-shape", """
  "activation": [ { "event": "trace-opened" } ]"""), "every.json",
        proc(ctx: PluginContext) =
          ctx.pluginComputed("computed", proc() =
            inc computedRuns
            discard ctx.observe(s))
          ctx.pluginRenderEffect("render", proc() =
            inc renderRuns
            discard ctx.observe(s))
          ctx.pluginOnMount("mount", proc() = inc mountRuns))
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))

      # THE RECORD IS THE SUBJECT. Each of the three created exactly one
      # computation and each was identified on the ambient owner and recorded;
      # a silently skipped record would show up here as a short sequence.
      let comps = host.contextFor("acme.every-shape").state.effects
      ck comps.len == 3
      ckObserves s, comps[0 .. 1], true
      ck computedRuns == 1
      ck renderRuns == 1
      ck mountRuns == 1

      s.val = 1
      ck computedRuns == 2
      ck renderRuns == 2
      # `onMount` runs its body untracked, so it subscribes to nothing and does
      # not re-run. That is `isonim`'s behaviour, not the wrapper's.
      ck mountRuns == 1

      ck host.deactivate("acme.every-shape")
      ckObserves s, comps[0 .. 1], false
      s.val = 2
      ck computedRuns == 2
      ck renderRuns == 2
      disposeRoot()

  test "every wrapped body enters through the budget wrapper":
    # `state.runs` counts bodies ENTERED through `runBudgeted`. FIVE creations,
    # five immediate runs, and the count is what makes "every body runs inside
    # runBudgeted" a measurement rather than a claim about the source.
    #
    # THE MEMO IS HERE BECAUSE IT WAS MISSING. This case used to create an
    # effect, a computed, a render effect and an onMount and assert 4 — and
    # `pluginMemo`, the primitive §5.1 names FIRST, was not among them. That is
    # why a mutation dropping the memo's `runBudgeted` survived every case in
    # the tree. The tally is only "every body" while every shape is in it.
    createRoot proc(disposeRoot: proc()) =
      let host = newPluginHost(CoreVersion, GenerousBudget)
      host.register(trivialManifest("acme.counted", """
  "activation": [ { "event": "trace-opened" } ]"""), "counted.json",
        proc(ctx: PluginContext) =
          ctx.pluginEffect("e", proc() = discard)
          ctx.pluginComputed("c", proc() = discard)
          ctx.pluginRenderEffect("r", proc() = discard)
          ctx.pluginOnMount("m", proc() = discard)
          discard ctx.pluginMemo("mm", proc(): int = 1))
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      ck host.contextFor("acme.counted").state.runs == 5
      # And the shapes are the five distinct wrapped primitives, not one of
      # them created five times: every one of them was also RECORDED, which is
      # the accounting half `recordCreated` raises on.
      ck host.contextFor("acme.counted").state.effects.len == 5
      disposeRoot()

suite "PLAT-7: the counted-assertion tally":

  test "the tally":
    # Written from a run. Verification-Harness-Traps §4c.
    check countedAssertions == 155
