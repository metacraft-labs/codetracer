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
## ## AND THERE IS A THIRD HALF NOW, BECAUSE THE FIRST TWO BOUND THE WRONG SET
##
## Both halves above are about the ten reactive primitives, and both were true
## and green on 2026-09-09 over a declared plugin that imported this module and
## `std/posix`, read `/etc/hostname` with no `fs:read` grant and `fork`+`execv`d
## `/bin/sh` with no `process` grant. Neither half could have refused it: they
## bind NAMES, and `std/posix` spells the same operations `open`, `read`,
## `write`, `socket`, `connect`, `fork` and `execv` — and `read` and `write` are
## the SDK's own spellings.
##
## The third half is an ALLOW-LIST over the imports of a plugin's reachable
## closure, with the membership rule and the reason for every entry in
## `src/common/plugin_model/source_admission.nim`, plus a denial of nim's
## foreign-function pragmas, which is the route AROUND an import allow-list and
## needs no import at all. Checks 18-22 of the same gate.
##
## **THE ALLOW-LIST RESTS ON A PROPERTY OF THIS FILE**, so it is stated here
## rather than only there: this module and `plugin_host/plugin_io` are the two
## TERMINALS of the gate's closure walk — reached, reported and NOT entered — so
## nothing in the gate holds `plugin_io`'s `std/os`, `std/osproc` and
## `std/posix` imports against a plugin. That is correct only while `plugin_io`
## re-exports none of them, which it does not (it re-exports `asyncdispatch`
## minus the four blocking spellings, and nothing else). If it ever started to,
## the allow-list would be intact and the boundary would be gone, and no check
## in the gate could see it. `tests/unit/plugin_probes/surface_reach_probe.nim.probe`
## measures it: a module importing only this one, compiled and run, reporting
## `osproc-reachable=false`, `posix-reachable=false`, `os-reachable=false` —
## and `future-reachable=true`, so a probe on which nothing is reachable cannot
## pass it.
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

# PLAT-8. The one thing this door reaches that `codetracer_embed` does not.
#
# `plugin_host/plugin_io.nim` is §8.1's four primitives — process, stream,
# socket, codec — and its native arm imports `std/osproc`. That is why it is
# HERE and not on the facade: `ci/test/sdk-facade-boundary.sh` forbids
# `std/osproc` anywhere in the facade's import graph, because
# CodeTracer-Embed-SDK.md §8 has an EMBEDDER create a worker rather than a
# child process. Putting the plugin SDK on the facade was tried and that check
# reddened, which is the check working: an application embedding CodeTracer
# must not acquire process spawning by linking it.
#
# A plugin must, and §8 is the argument for why: "A plugin that decodes a
# proprietary format, drives an existing analyser, queries a symbol server or
# shells out to a toolchain needs a **process**, and pretending otherwise
# produces either a crippled plugin model or a sandbox with a hole in it."
#
# SO THIS IS A WIDENING, AND IT IS THE DELIBERATE KIND §2.1 ASKS FOR. §2.1's
# "second door" is one that reaches something the first does not *without
# review*; this one is reviewed here, is admitted by name in
# `sdk-facade-boundary.sh` for THIS FILE ONLY, and everything it reaches is
# refused unless the plugin's own manifest declared the capability AND the
# target. An embedder has no manifest and therefore no grants; a plugin has
# both, and a user read them before granting (§8.4).
#
# The narrowing above and this widening are the same decision seen from two
# sides: a plugin is trusted with LESS of the reactive core than an embedder,
# and with MORE of the outside world, because those are the two things the two
# audiences actually need.
import plugin_host/plugin_io
export plugin_io

const
  CodeTracerPluginSurfaceModule* = "codetracer_plugin"
    ## The one module name a PLUGIN may import from this SDK.
    ## `ci/test/plugin-reactive-boundary.sh` reads it from here rather than
    ## hardcoding the string, so renaming this file cannot silently disarm the
    ## guard — exactly as `CodeTracerEmbedFacadeModule` does for the wider
    ## facade.
