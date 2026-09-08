## checkpointed_loop_plugin.nim — PLAT-7's badly-behaved plugin fixture in the
## shape the host CAN interrupt.
##
## Identical to `hot_loop_plugin.nim` in intent — it wants to burn many times
## its budget inside one synchronous effect — and different in one respect:
## its loop reads a core signal through `ctx.observe` on every iteration,
## which is what §5.1 says observing is. Every such read is a deadline
## checkpoint, so the run is aborted from INSIDE, at the first read past the
## budget, and `didFinish` stays false.
##
## That is the difference `BudgetViolation.abortedMidRun` records, and the
## reason `plugin_api.nim` puts the checkpoint in `observe` rather than only
## in an explicit `checkBudget` a plugin author has to remember: a plugin that
## does real work over trace data reads to do it, and a checkpoint on the read
## is a checkpoint the author did not have to opt into.
##
## PLAT-8's constraint is the other half of the same argument. If the I/O API
## had a synchronous form, a plugin could block for a second without reading
## anything, and no checkpoint anywhere would fire.

import std/[monotimes, times]

import codetracer_plugin

const ManifestJson* = """
{
  "id": "codetracer.checkpointed-loop",
  "displayName": "Checkpointed loop",
  "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "activation": [ { "event": "trace-opened" } ]
}
"""

type
  CheckpointedLoopPlugin* = ref object
    signal: Signal[int]
    burnMultiple: int
    bodyEntries*: int
    didFinish*: bool
      ## THE ASSERTION THAT IS ABOUT THE EFFECT AND NOT THE REPORT. A run that
      ## was genuinely stopped mid-loop never reaches this assignment. A test
      ## that only read `abortedMidRun` off the violation would be reading the
      ## host's own account of what it did.
    iterations*: int

proc newCheckpointedLoopPlugin*(s: Signal[int];
                                burnMultiple = 8): CheckpointedLoopPlugin =
  CheckpointedLoopPlugin(signal: s, burnMultiple: burnMultiple)

proc activator*(p: CheckpointedLoopPlugin): proc(ctx: PluginContext) =
  result = proc(ctx: PluginContext) =
    let body = proc() =
      inc p.bodyEntries
      let deadline = getMonoTime() +
        ctx.state.budget * p.burnMultiple.int64
      while getMonoTime() < deadline:
        inc p.iterations
        # §5.1's observation, and the host's checkpoint, are the same call.
        discard ctx.observe(p.signal)
      p.didFinish = true
    ctx.pluginEffect("checkpointed-loop", body)
