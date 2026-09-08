## hot_loop_plugin.nim — PLAT-7's badly-behaved plugin fixture, in the shape
## the host CANNOT interrupt.
##
## Its effect burns a fixed multiple of the budget in a loop that never
## touches the host: no `observe`, no `checkBudget`, no I/O (there is none to
## do — PLAT-8 owns that and gives it no synchronous form). This is
## Extensibility-Model.md §5.3's hazard in its purest form: "An extension
## doing real work inside one blocks the front-end, and on a terminal that
## means a frozen screen."
##
## What the host can do about it is layer (a) of `plugin_api.nim`'s three:
## the FIRST run completes and is measured, the plugin is suspended and named,
## and every subsequent run is refused before the body. So the freeze happens
## once and cannot recur — which is a weaker claim than "no freeze", and the
## reason this fixture exists beside `checkpointed_loop_plugin.nim` rather
## than instead of it.
##
## ## WHY A BUSY LOOP AND NOT A SLEEP
##
## `os.sleep` does not exist on the JS backend, and these suites run on both
## (`vm-unit` and `vm-unit-js`). A monotonic busy-wait behaves identically on
## each, and — more importantly — it is what a plugin doing real CPU work
## actually looks like. A sleeping plugin would be testing the scheduler.
##
## ## THE BURN IS A MULTIPLE OF THE BUDGET, NOT A CONSTANT
##
## Verification-Harness-Traps §12: an inequality between two independently
## noisy measurements asserted against an exact constant is a coin flip. The
## burn is `budget * multiple` read from the plugin's own run state, so
## "exceeded the budget" is true by construction at any host load rather than
## true because the machine was quiet.

import std/[monotimes, times]

import codetracer_plugin

const ManifestJson* = """
{
  "id": "codetracer.hot-loop",
  "displayName": "Hot loop",
  "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "activation": [ { "event": "trace-opened" } ]
}
"""

type
  HotLoopPlugin* = ref object
    signal: Signal[int]
    burnMultiple: int
    bodyEntries*: int
      ## How many times the body was ENTERED. The suspension assertion is
      ## that this stops moving while the writes continue.
    bodyCompletions*: int
      ## How many times it ran to the end. For this fixture the two are
      ## equal — nothing interrupts it — and that equality is itself the
      ## measurement that separates layer (a) from layer (b).
    spins*: int

proc newHotLoopPlugin*(s: Signal[int]; burnMultiple = 8): HotLoopPlugin =
  HotLoopPlugin(signal: s, burnMultiple: burnMultiple)

proc activator*(p: HotLoopPlugin): proc(ctx: PluginContext) =
  result = proc(ctx: PluginContext) =
    let body = proc() =
      inc p.bodyEntries
      discard ctx.observe(p.signal)
      let deadline = getMonoTime() +
        ctx.state.budget * p.burnMultiple.int64
      while getMonoTime() < deadline:
        inc p.spins
      inc p.bodyCompletions
    ctx.pluginEffect("hot-loop", body)
