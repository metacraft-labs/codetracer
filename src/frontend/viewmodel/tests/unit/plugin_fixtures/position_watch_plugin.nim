## position_watch_plugin.nim — PLAT-7's well-behaved plugin fixture.
##
## It does exactly the two things Extensibility-Model.md §5 says an extension
## does, and nothing else:
##
##   OBSERVE (§5.1) — it reads `ReplayDataStore.debugger`, a real core signal,
##   inside a `pluginMemo` and a `pluginEffect`. There is no subscribe, no
##   unsubscribe and no event name anywhere in this file.
##
##   ACT (§5.2) — when the position it is watching crosses the threshold it
##   was constructed with, it calls `DebugControlsVM.stepForward`, which is
##   the product's own action proc. It does not send a command, because there
##   is nothing to send a command to.
##
## ## IT DOES NOT CALL THE RAW PRIMITIVES, AND IT COULD NOT
##
## There is no `createEffect`, `createMemo`, `createRoot`, `createComputed`,
## `createRenderEffect`, `onMount`, `onCleanup`, `runWithOwner`, `getOwner` or
## `updateComputation` anywhere in this file's code — only `ctx.pluginEffect`
## and `ctx.pluginMemo`, whose bodies the host budgets and whose computations
## the activation scope owns.
##
## That is not restraint. This file imports `codetracer_plugin`, the surface
## that filters those ten names out, so the unqualified call would not compile;
## and `ci/test/plugin-reactive-boundary.sh` refuses the module-qualified
## spelling that `export … except` cannot filter. The ten names above are in a
## DOC COMMENT, which is why that gate's check 8 uses this file to prove its
## comment stripper discriminates: they must all be present in the raw bytes
## and none of them may survive the strip.
##
## ## THE VIEWMODELS ARRIVE THROUGH THE CONSTRUCTOR
##
## `PluginContext` carries no CodeTracer state at all — see
## `plugin_host/plugin_api.nim`'s header. A plugin is handed the ViewModels it
## needs by whoever instantiates it, which for an in-process Nim plugin is a
## constructor and for a later WASM one would be an import binding. Either way
## the data comes from the facade and the plugin never reaches the store.
##
## ## IT ACTS ONCE, DELIBERATELY
##
## `stepForward` reaches the backend, whose answer moves the position, which
## re-runs this effect. A fixture that acted on every run would be a feedback
## loop, and the thing it would then be testing is Nim's stack depth. The
## `acted` latch keeps the fixture about the layering.

import codetracer_plugin

const ManifestJson* = """
{
  "id": "codetracer.position-watch",
  "displayName": "Position watch",
  "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "capabilities": ["trace"],
  "activation": [
    { "event": "trace-opened" },
    { "event": "language", "value": "noir" }
  ],
  "contributes": {
    "pane": [
      { "id": "codetracer.position-watch.pane",
        "title": "Positions",
        "views": ["Table", "Text"] }
    ],
    "viewModel": [
      { "id": "codetracer.position-watch.model", "version": "1.0.0" }
    ]
  }
}
"""

type
  PositionWatchPlugin* = ref object
    controls: DebugControlsVM
    stepAtTicks: uint64
    acted: bool
    effectRuns*: int
      ## How many times the plugin's effect body ran. THE assertion for
      ## "a deactivated plugin's effects no longer run" is that this stops
      ## moving — paired with the structural one on the signal's observer
      ## list, because a counter that stopped is also what a plugin guarding
      ## its own body looks like.
    memoRuns*: int
    seenTicks*: seq[uint64]
    lastCaption*: string
    stepsIssued*: int
    caption: Memo[string]

proc newPositionWatchPlugin*(controls: DebugControlsVM;
                             stepAtTicks: uint64 = high(uint64)):
                             PositionWatchPlugin =
  PositionWatchPlugin(controls: controls, stepAtTicks: stepAtTicks)

proc captionNow*(p: PositionWatchPlugin): string =
  ## The plugin's published derived value, read the way another plugin would
  ## read it: through the memo, not through a cached field.
  p.caption.val

proc activator*(p: PositionWatchPlugin): proc(ctx: PluginContext) =
  ## The `activate` the host calls inside the plugin's activation scope.
  ## Everything created in here is owned by that scope.
  result = proc(ctx: PluginContext) =
    let store = p.controls.store

    # §5.1's memo. `observe` is `isonim`'s own `val` with a budget checkpoint
    # in front of it, so the dependency is tracked exactly as a direct read
    # would be.
    let captionBody = proc(): string =
      inc p.memoRuns
      let st = ctx.observe(store.debugger)
      st.location.file & ":" & $st.location.line
    p.caption = ctx.pluginMemo("caption", captionBody)

    let watchBody = proc() =
      inc p.effectRuns
      let st = ctx.observe(store.debugger)
      p.seenTicks.add st.rrTicks
      p.lastCaption = ctx.observe(p.caption)
      # §5.2. The product's own action proc, invoked directly. There is no
      # second dispatch path and this is what its absence looks like.
      if not p.acted and st.rrTicks >= p.stepAtTicks:
        p.acted = true
        inc p.stepsIssued
        p.controls.stepForward()
    ctx.pluginEffect("position-watch", watchBody)
