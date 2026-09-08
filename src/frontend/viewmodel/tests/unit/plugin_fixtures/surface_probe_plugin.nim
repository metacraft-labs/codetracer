## surface_probe_plugin.nim — what a plugin can and cannot NAME, decided by the
## compiler in a module that imports the plugin surface AND NOTHING ELSE.
##
## ## WHY THIS IS A FIXTURE AND NOT A TEST CASE
##
## `compiles` answers the question "does this resolve HERE", and "here" is the
## module it is written in. `test_plugin_effect_budget.nim` and
## `test_plugin_lifecycle.nim` both import `codetracer_embed` — they are the
## APPLICATION driving the host, which is exactly the trusted audience the
## facade is for — so `compiles(createEffect(...))` written there would answer
## `true` and would be answering about the suite rather than about a plugin.
##
## So the answers are computed in a module whose import list is a plugin's:
## `codetracer_plugin`, and nothing else. The suite then asserts on the
## constants, and what it is asserting is a fact about a plugin's own scope.
##
## ## THE NEGATIVE AND THE POSITIVE COME FROM THE SAME MECHANISM
##
## Verification-Harness-Traps §4a: a "must not contain" is only self-controlling
## when its positive twin runs through the same scanner. Every constant below is
## a `compiles` over a call, in this module, at compile time. `RawEffectInScope`
## must be `false` and `WrappedEffectInScope` must be `true`, and a `compiles`
## that had stopped working — a renamed symbol, a changed signature, a module
## that failed to import — would make BOTH `false` and redden the positive one.
## A file asserting only the negatives would go green the day this module
## stopped compiling anything at all.
##
## The same argument is why `SignalReadInScope` is here. §4.1's "signals cross
## no boundary" is not narrowed for plugins: `val`, `createSignal` and the
## `Signal` / `Memo` types stay in scope, because a read is not a computation
## and a signal is not one either. A denial that had swallowed those would be a
## different, wrong rule, and this constant is what would say so.

import codetracer_plugin

# ONE symbol, by name, so the suite can assert the surface's own constant
# without importing the surface — which would put the plugin's door into the
# suite's scope and make every `compiles` above answer about the suite. The
# explicit-symbol form is used rather than `export codetracer_plugin` for the
# same reason: measured on nim 2.2.8, `export m` makes `m`'s module name
# reachable for qualification in the importer, and `export m.sym` does not.
export codetracer_plugin.CodeTracerPluginSurfaceModule

const
  # --- the ten denied primitives, as a plugin sees them ---------------------
  #
  # `codetracer_plugin.nim` filters each of these out of its re-export of
  # `codetracer_embed`, so every one of these must be `false`. Their names are
  # written out one per constant rather than folded into a set, because a
  # single `false` for "none of them resolve" is satisfied by a module that
  # failed to import anything.
  RawEffectInScope* = compiles(createEffect(proc() = discard))
  RawRenderEffectInScope* = compiles(createRenderEffect(proc() = discard))
  RawComputedInScope* = compiles(createComputed(proc() = discard))
  RawMemoInScope* = compiles(createMemo(proc(): int = 1))
  RawOnMountInScope* = compiles(onMount(proc() = discard))
  RawRootInScope* = compiles(createRoot(proc(dispose: proc()) = discard))
  RawOnCleanupInScope* = compiles(onCleanup(proc() = discard))
  RawRunWithOwnerInScope* = compiles(runWithOwner(nil, proc() = discard))
  RawGetOwnerInScope* = compiles(getOwner())
  RawUpdateComputationInScope* = compiles(updateComputation(nil))

  # --- the sanctioned replacements, through the SAME mechanism --------------
  WrappedEffectInScope* =
    compiles(PluginContext(nil).pluginEffect("n", proc() = discard))
  WrappedRenderEffectInScope* =
    compiles(PluginContext(nil).pluginRenderEffect("n", proc() = discard))
  WrappedComputedInScope* =
    compiles(PluginContext(nil).pluginComputed("n", proc() = discard))
  WrappedMemoInScope* =
    compiles(PluginContext(nil).pluginMemo("n", proc(): int = 1))
  WrappedOnMountInScope* =
    compiles(PluginContext(nil).pluginOnMount("n", proc() = discard))
  WrappedRootInScope* =
    compiles(PluginContext(nil).pluginRoot("n", proc(d: proc()) = discard))
  WrappedCleanupInScope* =
    compiles(PluginContext(nil).onPluginCleanup(proc() = discard))
  ObserveInScope* =
    compiles(PluginContext(nil).observe(createSignal(0)))

  # --- what is deliberately NOT narrowed (§4.1) -----------------------------
  SignalCreateInScope* = compiles(createSignal(0))
  SignalReadInScope* = compiles(createSignal(0).val)

  # --- and the ViewModels still arrive, which is §2.1's whole point ---------
  ViewModelsInScope* = compiles(DebugControlsVM)
