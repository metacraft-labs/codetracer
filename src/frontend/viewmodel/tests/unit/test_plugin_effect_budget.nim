## test_plugin_effect_budget.nim — PLAT-7's synchronous-effect budget:
## "A plugin exceeding the effect budget is reported and does not freeze the
## UI."
##
## ## THE RISK THIS SUITE IS ABOUT
##
## Extensibility-Model.md §5.3: "Effects run synchronously. An extension doing
## real work inside one blocks the front-end, and on a terminal that means a
## frozen screen — the failure mode CTUI-14 spent a milestone eliminating from
## the product's own code." And the requirement: "a declared budget for
## synchronous effects that the host **enforces rather than documents**. An
## extension exceeding it is reported by name."
##
## ## THE CLAIM IS EXACT, AND IT IS NOT "NO OVERRUN"
##
## Nim has no safe way to preempt a synchronous call — an interval timer and a
## `longjmp` out of the handler would skip every `finally` between the timer
## and the frame it lands in. So the enforced claim has two halves, and this
## suite asserts each against a plugin written to exercise it:
##
##   `checkpointed_loop_plugin` — a plugin whose loop OBSERVES is stopped
##   INSIDE its first overrun, at the first read past the deadline. Asserted
##   on `didFinish == false`, which is a fact about the plugin's own code, not
##   about the host's account of what it did.
##
##   `hot_loop_plugin` — a plugin whose loop touches nothing completes its
##   first overrun and is then SUSPENDED. Asserted on `bodyEntries` not
##   moving across two hundred further writes, while a well-behaved plugin's
##   counter moves across those same two hundred.
##
##   A measured refinement, recorded because the first version of that case
##   asserted the wrong number and the right answer is stronger: the suspended
##   plugin's body is refused ONCE, not two hundred times. `isonim`'s
##   `updateComputation` calls `cleanNode(comp)` before running a body, so a
##   run re-subscribes by READING — and the suspended wrapper reads nothing.
##   After one refused run the effect is no longer an observer of the signal,
##   so the host pays nothing at all for the remaining writes. The case
##   asserts that, on the signal's own `observers`.
##
## ## VERIFICATION-HARNESS-TRAPS §12: NO COIN FLIPS
##
## Every timing comparison here is between quantities separated by a large,
## constructed factor rather than by chance:
##
##   * the offending plugins burn `budget * 8`, read from the run state, so
##     "over budget" is true by construction at any host load;
##   * the well-behaved plugin does O(1) work against a 40 ms budget;
##   * the post-suspension cost of two hundred writes is compared against ONE
##     overrun (320 ms), which it beats by orders of magnitude — the arm
##     exists to catch a host that forgot to suspend, and such a host would
##     spend sixty-four seconds there.
##
## The one measurement that is not a constructed factor — that the
## well-behaved plugin is never tripped — is paired with a `checkpoint` of its
## observed elapsed time, so a failure on a heavily loaded machine reads as
## the load it is rather than as a defect in the budget.
##
## ## NO MOCKS, AND THE ONE NAME THAT LOOKS LIKE ONE
##
## `backend/mock_backend.MockBackendService` — see
## `test_plugin_lifecycle.nim`'s header for the justification; it is one of
## the four `BackendService` implementations the ViewModel layer ships and is
## exported from the SDK facade as part of §3.1's `BackendService` row. It is
## present here only because a `ReplayDataStore` needs a transport; this
## suite's subject is the budget, and its signals are plain `Signal[int]`s.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## Every assertion helper in this file is a `template`.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_plugin_effect_budget.nim

import std/[monotimes, strutils, times, unittest]

import isonim/core/graph

import codetracer_embed
import plugin_host/host
import plugin_fixtures/hot_loop_plugin
import plugin_fixtures/checkpointed_loop_plugin

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  CoreVersion = semver(1, 4, 0)
  Budget = initDuration(milliseconds = 40)
  BurnMultiple = 8
    ## The offenders burn eight budgets. Eight rather than two so that the
    ## "did it exceed?" question has no answer that depends on the machine.

# A well-behaved plugin, written inline because it is three lines and its
# whole purpose is to be the control: it must keep observing after the
# offender has been suspended.
type
  QuietPlugin = ref object
    signal: Signal[int]
    runs: int

proc newQuietPlugin(s: Signal[int]): QuietPlugin =
  QuietPlugin(signal: s)

proc quietActivator(q: QuietPlugin): proc(ctx: PluginContext) =
  result = proc(ctx: PluginContext) =
    let body = proc() =
      inc q.runs
      discard ctx.observe(q.signal)
    ctx.pluginEffect("quiet", body)

const QuietManifest = """
{
  "id": "codetracer.quiet",
  "version": "1.0.0",
  "activation": [ { "event": "trace-opened" } ]
}
"""

# ---------------------------------------------------------------------------

suite "PLAT-7: a plugin exceeding the budget is reported by name":

  test "the offender is named, with its effect, its cost and its budget":
    createRoot proc(disposeRoot: proc()) =
      let s = createSignal(0)
      let hot = newHotLoopPlugin(s, BurnMultiple)
      let host = newPluginHost(CoreVersion, Budget)
      host.register(hot_loop_plugin.ManifestJson, "hot.json", hot.activator())
      host.resolveAll()
      ck host.loadErrors().len == 0
      discard host.activateFor(occurrence(aeTraceOpened))

      # The effect ran once at creation and burned eight budgets doing it.
      ck hot.bodyEntries == 1
      ck hot.bodyCompletions == 1        # nothing interrupted it — layer (c)

      let vs = host.violations()
      ck vs.len == 1
      ck vs[0].plugin == "codetracer.hot-loop"
      ck vs[0].effect == "hot-loop"
      ck vs[0].budget == Budget
      ck vs[0].observed > Budget
      ck not vs[0].abortedMidRun

      let line = describe(vs[0])
      checkpoint(line)
      ck line.startsWith("plugin 'codetracer.hot-loop'")
      ck line.contains("hot-loop")
      ck line.contains("40 ms budget")
      ck line.contains("suspended")
      # The host's whole report says the same thing, so a surface that shows
      # only `report()` shows it too.
      ck host.report().contains("codetracer.hot-loop")
      ck host.suspendedPlugins() == @["codetracer.hot-loop"]
      disposeRoot()

  test "a plugin that observes is stopped INSIDE its first overrun":
    createRoot proc(disposeRoot: proc()) =
      let s = createSignal(0)
      let slow = newCheckpointedLoopPlugin(s, BurnMultiple)
      let host = newPluginHost(CoreVersion, Budget)
      host.register(checkpointed_loop_plugin.ManifestJson, "cp.json",
                    slow.activator())
      host.resolveAll()
      let started = getMonoTime()
      discard host.activateFor(occurrence(aeTraceOpened))
      let elapsed = getMonoTime() - started

      ck slow.bodyEntries == 1
      # THE ASSERTION ABOUT THE EFFECT, NOT THE REPORT. The loop wanted to run
      # for eight budgets and never reached its own last line.
      ck not slow.didFinish
      ck slow.iterations > 0

      let ctx = host.contextFor("codetracer.checkpointed-loop")
      ck ctx.state.checkpoints > 0
      let vs = host.violations()
      ck vs.len == 1
      ck vs[0].abortedMidRun
      ck describe(vs[0]).contains("stopped at a checkpoint mid-run")

      # And it was stopped NEAR the budget rather than at the end of the burn.
      # The comparison is against `budget * BurnMultiple`, which is what the
      # plugin would have taken; the margin is a factor of eight, not a
      # threshold picked to pass (Verification-Harness-Traps §12).
      checkpoint("aborted after " & $elapsed.inMilliseconds &
                 " ms; the plugin asked for " &
                 $(Budget * BurnMultiple.int64).inMilliseconds & " ms")
      ck elapsed < Budget * BurnMultiple.int64
      disposeRoot()

suite "PLAT-7: an over-budget plugin does not freeze the front-end":

  test "after the trip the body is refused, and a quiet plugin keeps observing":
    createRoot proc(disposeRoot: proc()) =
      let s = createSignal(0)
      let hot = newHotLoopPlugin(s, BurnMultiple)
      let quiet = newQuietPlugin(s)
      let host = newPluginHost(CoreVersion, Budget)
      host.register(hot_loop_plugin.ManifestJson, "hot.json", hot.activator())
      host.register(QuietManifest, "quiet.json", quiet.quietActivator())
      host.resolveAll()
      ck host.loadErrors().len == 0
      discard host.activateFor(occurrence(aeTraceOpened))

      let entriesAtTrip = hot.bodyEntries
      let quietAtTrip = quiet.runs
      ck entriesAtTrip == 1
      ck quietAtTrip == 1
      ck host.contextFor("codetracer.hot-loop").state.suspended

      const Writes = 200
      let started = getMonoTime()
      for i in 1 .. Writes:
        s.val = i
      let elapsed = getMonoTime() - started

      # 1. THE BODY WAS REFUSED, and the count is exact rather than "did not
      #    grow much". This is the structural half and it involves no clock.
      ck hot.bodyEntries == entriesAtTrip

      #    AND IT WAS REFUSED EXACTLY ONCE, which is a stronger result than
      #    the two hundred this case first asserted — and the reason is worth
      #    recording rather than adjusting the number to. `isonim`'s
      #    `updateComputation` calls `cleanNode(comp)` BEFORE running the
      #    body, so a run re-subscribes by reading. The suspended wrapper
      #    reads nothing, so after its one refused run the effect is no longer
      #    an observer of the signal at all: the host does not pay even the
      #    early return on writes two hundred through two.
      let hotComps = host.contextFor("codetracer.hot-loop").state.effects
      ck hotComps.len == 1
      ck host.contextFor("codetracer.hot-loop").state.refusedRuns == 1
      var stillObserving = 0
      for obs in s.observers:
        if obs == hotComps[0]: inc stillObserving
      ck stillObserving == 0

      # 2. THE REST OF THE APPLICATION KEPT WORKING. Same signal, same host,
      #    same two hundred writes — the positive control that says the writes
      #    really did propagate and the first assertion is not green because
      #    nothing happened at all.
      ck quiet.runs == quietAtTrip + Writes

      # 3. AND IT WAS NOT A FREEZE. Two hundred writes after the trip cost
      #    less than the ONE overrun did. Unsuspended they would have cost
      #    two hundred overruns — sixty-four seconds — so the margin here is
      #    four orders of magnitude rather than a tuned threshold.
      checkpoint($Writes & " writes after the trip took " &
                 $elapsed.inMilliseconds & " ms; one overrun is " &
                 $(Budget * BurnMultiple.int64).inMilliseconds & " ms")
      ck elapsed < Budget * BurnMultiple.int64

      # 4. THE QUIET PLUGIN WAS NEVER TRIPPED. Paired with its observed cost
      #    so that a failure on a loaded machine reads as the load it is.
      let quietCtx = host.contextFor("codetracer.quiet")
      checkpoint("quiet plugin's last run: " &
                 $quietCtx.state.lastElapsed.inMicroseconds & " us against a " &
                 $Budget.inMilliseconds & " ms budget")
      ck not quietCtx.state.suspended
      ck quietCtx.state.violations.len == 0
      ck host.suspendedPlugins() == @["codetracer.hot-loop"]
      disposeRoot()

  test "deactivating a suspended plugin still releases its subscriptions":
    # A suspended plugin is still SUBSCRIBED — suspension refuses the body,
    # it does not unlink the graph. So the two mechanisms are independent and
    # the release still has to happen, which is what this asserts.
    createRoot proc(disposeRoot: proc()) =
      let s = createSignal(0)
      let hot = newHotLoopPlugin(s, BurnMultiple)
      let host = newPluginHost(CoreVersion, Budget)
      host.register(hot_loop_plugin.ManifestJson, "hot.json", hot.activator())
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      let comps = host.contextFor("codetracer.hot-loop").state.effects
      ck comps.len == 1

      var observing = 0
      for c in comps:
        for obs in s.observers:
          if obs == c: inc observing
      ck observing == 1                  # suspended and still subscribed

      ck host.deactivate("codetracer.hot-loop")
      observing = 0
      for c in comps:
        for obs in s.observers:
          if obs == c: inc observing
      ck observing == 0
      ck s.observers.len == 0
      disposeRoot()

suite "PLAT-7: the budget is the host's, and a plugin cannot raise it":

  test "the budget on the context is the one the host was constructed with":
    createRoot proc(disposeRoot: proc()) =
      let s = createSignal(0)
      let quiet = newQuietPlugin(s)
      let tight = initDuration(milliseconds = 3)
      let host = newPluginHost(CoreVersion, tight)
      host.register(QuietManifest, "quiet.json", quiet.quietActivator())
      host.resolveAll()
      discard host.activateFor(occurrence(aeTraceOpened))
      ck host.budget == tight
      ck host.contextFor("codetracer.quiet").state.budget == tight
      # The default is half a 60 Hz frame, and it is not zero — a budget of
      # zero would trip every plugin and a budget nobody can hit is
      # documentation.
      ck DefaultEffectBudget == initDuration(milliseconds = 8)
      ck DefaultEffectBudget > initDuration(milliseconds = 0)
      disposeRoot()

suite "PLAT-7: the counted-assertion tally":

  test "the tally":
    # Written from a run. Verification-Harness-Traps §4c.
    check countedAssertions == 45
