## viewmodel/vm_log.nim
##
## Diagnostic logging for the ViewModel layer, with **no renderer dependency**.
##
## WHY THIS EXISTS
## ---------------
## `ReplayDataStore` and `CalltraceVM` used to log their `[PIPELINE]`
## diagnostics through `frontend/lib/logging`, which is the Electron
## renderer's logger. That module imports `frontend/lib/jslib`, which imports
## `dom` and `kdom` — so on the `nim js` target the Embed SDK's data layer and
## one of its seven public panels reached the Karax DOM shim, for eleven debug
## lines.
##
## CodeTracer-Embed-SDK.md §3.2 excludes "any rendering", and
## BlockTracer.milestones.org M2a asks for a "package graph free of rendering
## dependencies". `ci/test/sdk-facade-boundary.sh` is what checks it, and
## `lib/logging` was the only edge in the facade's transitive import graph that
## failed — on the target where embedding actually happens. Eleven developer
## log lines are not a reason to ship a DOM shim inside an embeddable library.
##
## What changed observably: these lines no longer carry `lib/logging`'s
## `withDebugInfo` prefix (task id, timestamp, source location). Nothing reads
## them: no Playwright spec, no test and no script greps `[PIPELINE]` outside
## the renderer's own modules, which still use `cdebug` and are untouched.
##
## This module deliberately imports nothing at all, so it can never become the
## edge it was written to remove.

when defined(js):
  proc consoleLog(msg: cstring) {.importjs: "console.log(#)".}

  template vmDebug*(msg: string) =
    ## Emit a ViewModel-layer diagnostic on the JS target.
    consoleLog(msg.cstring)
else:
  template vmDebug*(msg: string) =
    ## No-op on the native target, matching the previous behaviour: every
    ## `cdebug` call site replaced by this one was already inside a
    ## `when defined(js)` branch.
    discard
