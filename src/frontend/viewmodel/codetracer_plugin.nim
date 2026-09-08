## codetracer_plugin.nim — the surface a PLUGIN consumes.
##
## SDK-CONSUMER: this module is the plugin-facing door, and it is held to the
## facade-only rule by the same check that holds every other consumer to it.
## `ci/test/sdk-facade-boundary.sh` admits `codetracer_plugin` as a permitted
## import, so without this marker the second door could quietly become a wider
## one: an SDK internal imported HERE would be re-exported to every plugin, and
## nothing would have said so. With it, check 4 asserts the only module this
## file reaches inside `src/frontend/viewmodel/` is `codetracer_embed`.
##
## `codetracer_embed.nim` is the SDK facade and this is the same facade with
## ten symbols filtered out. It exists because the two audiences that reach for
## that facade are not equally trusted, and until this module existed they were
## served the same door.
##
## ## WHY THIS IS NOT JUST `codetracer_embed`
##
## Extensibility-Model.md §5.3 asks for "a declared budget for synchronous
## effects that the host **enforces rather than documents**", and PLAT-7's
## answer is `plugin_host/plugin_api.nim`: a plugin's effect and memo bodies run
## inside `runBudgeted`, are measured against a monotonic clock, and suspend the
## plugin when they overrun.
##
## That answer was only as good as the claim underneath it — "a plugin never
## receives `createEffect`" — AND THAT CLAIM WAS FALSE. `codetracer_embed.nim`
## re-exports `isonim/core/[signals, computation, owner]` for §4.1's Mode N
## consumers ("signals cross no boundary", and the facade's own docs promise
## `createMemo` in scope). A plugin importing nothing but the sanctioned facade
## therefore had `createEffect`, `createMemo`, `createRoot` and `runWithOwner`
## in scope already. Measured on a plugin using only that facade, with a 20 ms
## budget: a raw `createEffect` in `activate` ran on every write, 160 ms each
## time, was never entered through `runBudgeted`, never attributed, never
## suspended, and would have gone on doing it for the life of the session.
##
## ## THE TWO AUDIENCES
##
## | who | imports | why |
## |---|---|---|
## | An **SDK consumer** — an application embedding CodeTracer | `codetracer_embed` | It is application code. §4.1 makes IsoNim's signals part of the consumption model and §3.1's Clock row is IsoNim's own. Nothing here narrows that surface, and no boundary check binds it. |
## | A **plugin** — third-party code the product loads | `codetracer_plugin` | It is not application code. It gets the same ViewModels, the same store, the same clock, and the reactive primitives only in their wrapped, budgeted, scope-owned form. |
##
## An SDK consumer that also loads plugins imports both; they compose, because
## this module adds nothing and removes ten names.
##
## ## WHAT `except` DOES AND DOES NOT DO — MEASURED, NOT ASSUMED
##
## `export … except` filters UNQUALIFIED lookup. Compiled against nim 2.2.8:
## a module importing this one cannot resolve `createEffect`, and cannot
## resolve it under any of its overloads or generic instantiations either.
##
## It does NOT filter MODULE-QUALIFIED lookup. `computation.createEffect(…)`
## still resolves through the re-export chain, because `codetracer_embed` makes
## the module name reachable and qualification bypasses the filter. That was
## measured rather than reasoned about, and it is why this file is only half of
## the denial:
##
##   * this module is the half that makes the spelling a plugin author would
##     actually write — a bare `createEffect(proc() = …)` — fail to compile;
##   * `ci/test/plugin-reactive-boundary.sh` is the half that is the BOUNDARY.
##     It refuses a declared plugin that imports `isonim/core/computation`,
##     `isonim/core/owner` or the wider `codetracer_embed`, and that names any
##     denied primitive in code by any spelling, qualified or not —
##     **over the plugin's whole reachable closure, not over its own file.**
##     Scoped to the file it was defeated by one undeclared helper module doing
##     the import on the plugin's behalf, measured at `rawRuns=4` with every
##     check green. This module is the terminal of that walk: it is reached and
##     not entered, because entering it would find the `import codetracer_embed`
##     below — a denied import — and report every plugin for using the surface
##     correctly. What binds this file instead is the gate's surface-present,
##     surface-narrows and denied-list-agrees checks, plus the SDK facade lint.
##
##     **AND THE WALK TERMINATES**, which is a property of it rather than a
##     hope: a visited set over repo-relative paths, each file enqueued at most
##     once, over the finite set of files that EXIST ON DISK under the
##     importing module's directory or one of the gate's search roots — the
##     resolver yields a candidate only when `[ -f … ]` holds. A cycle between
##     two modules is legal nim and costs exactly one visit; the contract suite
##     carries it as a case, because a lint that hangs is a lint somebody
##     removes from the lane. (Until 2026-09-08 this named "the finite set
##     `git ls-files` reports". That set is where the gate finds its SEEDS, and
##     even there it is unioned with `--others`; it reports zero of the four
##     modules in this milestone's plugin closure, so it cannot be what bounds
##     the walk.)
##
##     What the walk can READ is the third bound, and it is why the import
##     extractor is now one shared function (`ci/lib/nim-imports.sh`) rather
##     than one per gate. The gate shipped with its own copy that could not see
##     nim's newline-continued `import` — the form 138 files in `src/` use — so
##     the same helper-module escape respelled across two lines ran identically
##     and the gate reported `15 checks, 0 failing` without reporting that it
##     had failed to read anything. A spec it cannot resolve, and a line it
##     declines to analyse, are both findings now.
##
## Neither half is decoration. Without the first, the denial would be a lint
## over code that compiles and runs on every developer's machine; without the
## second it would be a speed bump.
##
## ## THE FILTERED SET IS NOT WRITTEN TWICE
##
## The `except` clause below and `plugin_api.PluginDeniedPrimitives` name the
## same ten symbols, and `ci/test/plugin-reactive-boundary.sh` asserts that they
## agree. Nim cannot splice a `const` into an `except` clause, so the list is
## genuinely typed out in two places; a checked duplication is the cheapest
## honest answer to that, and it is the same shape as the facade's
## `CodeTracerEmbedFacadeModule` constant, which the SDK lint reads rather than
## hardcodes.
##
## Each of the ten has a replacement on `PluginContext`, which is the property
## that makes this a narrowing rather than a removal — `PluginDeniedPrimitives`
## carries the mapping and the gate's remedy line prints it.
##
## ## WHAT IS DELIBERATELY STILL HERE
##
## `createSignal`, `val`, `update` and the `Signal` / `Memo` types. A read is
## not a computation and a signal is not one either, so none of them can create
## work the host does not budget. A raw `val` DOES cost something and
## Extensibility-Model.md §5.4 now names it: it is not a deadline checkpoint,
## and only `ctx.observe` is. A plugin reading raw inside a budgeted body is
## still measured and still suspended — it has moved itself from the budget's
## layer (b) to its layer (c), one overrun instead of none.

import codetracer_embed
export codetracer_embed except
  createEffect, createRenderEffect, createComputed, createMemo, onMount,
  createRoot, onCleanup, runWithOwner, getOwner, updateComputation

const
  CodeTracerPluginSurfaceModule* = "codetracer_plugin"
    ## The one module name a PLUGIN may import from this SDK.
    ## `ci/test/plugin-reactive-boundary.sh` reads it from here rather than
    ## hardcoding the string, so renaming this file cannot silently disarm the
    ## guard — exactly as `CodeTracerEmbedFacadeModule` does for the wider
    ## facade.
