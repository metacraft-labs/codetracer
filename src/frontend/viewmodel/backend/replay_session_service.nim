## Asking for a replay session, from a module that must not know how to make one.
##
## ## Why an injected service and not a call
##
## The Run path lives in `ui/web_noir_build.nim` and holds the only copy of the
## `MemoryTrace` the tracer produced (`producer.stdoutText`, which the next
## `beginPhase` clears). The thing that can open a session lives in
## `ui_js.nim`, which imports `ui/web_noir_build` — so the call has to go the
## other way, and a direct one would be a cycle.
##
## This is the pattern the renderer already uses for exactly this shape:
## `agent_activity.installAgentActivityTraceOpenService` and
## `installAgentActivityReviewOpenService` are both a record of proc fields
## that `ui_js.configure` fills in and a `ui/` module calls. Their headers give
## the reason this one is filled in from `configure` rather than from
## `configureMiddleware`: that routine runs only from `onTraceLoaded` and
## `onNoTrace`, and wiring placed there is a silent no-op in every launch mode
## that reaches neither.
##
## ## Why the request carries the path spellings
##
## The trace records `hello_noir/src/main.nr` — the key the browser compiler
## was handed — and the renderer opens tabs by `/hello_noir/src/main.nr`. Only
## the Run path knows the package directory and project root that relate them
## (`NoirBuildProducer.packageDir` / `.projectRoot`), and only the host can
## apply them to the frames coming back. Passing them in the request is what
## lets `rendererSpelling` stay a pure function that neither side owns.

import std/strutils

type
  ReplaySessionRequest* = object
    ## Everything needed to open a session over a trace made in this tab.
    rawMemoryTrace*: string
      ## The `MemoryTrace` document, verbatim. Copied at the call site rather
      ## than referenced: the producer clears `stdoutText` on the next
      ## `beginPhase`, and a session that started after the next Build would
      ## be opened over an empty string.
    packageDir*: string
      ## The compiler's spelling of the project root, e.g. `hello_noir`.
    projectRoot*: string
      ## The renderer's, e.g. `/hello_noir`.

  ReplaySessionService* = ref object
    startProc*: proc(request: ReplaySessionRequest)

var installedReplaySessionService: ReplaySessionService

proc installReplaySessionService*(service: ReplaySessionService) =
  ## Called once, from the renderer's `configure`.
  installedReplaySessionService = service

proc replaySessionServiceInstalled*(): bool =
  ## Whether anything can answer a request.
  ##
  ## Exported so a caller can say "this deployment cannot replay" by name
  ## instead of calling into nothing and reporting success — which is the
  ## shape of every defect this campaign has found.
  not installedReplaySessionService.isNil and
    not installedReplaySessionService.startProc.isNil

proc requestReplaySession*(request: ReplaySessionRequest): bool =
  ## Ask for a session. Returns whether anything took the request.
  ##
  ## `false` is a real answer and not an error: a desktop build, an extension
  ## build, and a web deployment that ships no engine all reach here, and all
  ## three should carry on showing the trace summary they already show.
  if not replaySessionServiceInstalled(): return false
  if request.rawMemoryTrace.strip.len == 0: return false
  installedReplaySessionService.startProc(request)
  true

proc resetReplaySessionServiceForTests*() =
  ## Tests share a process; without this the third case would inherit the
  ## second's service and pass for the wrong reason.
  installedReplaySessionService = nil
