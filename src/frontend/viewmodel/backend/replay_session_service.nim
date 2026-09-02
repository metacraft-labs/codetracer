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
    label*: string
      ## What this session is OF, for the tab that carries it — a test's
      ## fully-qualified selector, or "" for a Run of `main`.
      ##
      ## Carried on the request rather than derived, because only the caller
      ## knows: the trace document names source files and step counts and
      ## nothing about the gesture that produced it, and "the recording of
      ## `tests::test_main`" and "the recording of this program" are different
      ## things for a tab to say.
    newSessionTab*: bool
      ## Open this recording in a NEW session tab rather than replacing the
      ## current one.
      ##
      ## §9.1's interaction: "debugging two tests at once means two tabs, each
      ## with its own layout, each independently navigable — a developer
      ## comparing a passing and a failing case does not lose one to look at
      ## the other."
      ##
      ## A REQUEST AND NOT A COMMAND. A host that cannot hold two live sessions
      ## answers `rsoNoSecondSession` rather than opening one tab and quietly
      ## killing the other, which would leave a visible tab over a dead engine
      ## — the dead-affordance shape, with a tab bar to make it convincing.

  ReplaySessionOutcomeKind* = enum
    ## What happened to a request. Returned rather than a `bool` because
    ## "nothing took it" and "it was taken but not the way you asked" are
    ## different answers, and a caller shows different things for them.
    rsoNoHost = "no-host"
      ## Nothing can open a session in this build: a desktop build, an
      ## extension build, or a web deployment that ships no engine.
    rsoEmptyTrace = "empty-trace"
      ## There was nothing to open.
    rsoOpened = "opened"
      ## Opened, as asked.
    rsoNoSecondSession = "no-second-session"
      ## A NEW TAB was asked for and this host can hold only one live session,
      ## so NOTHING was opened. See `ui/web_replay_host.openSession`: it
      ## terminates any previous engine before starting one, because "two
      ## engines answering one store would interleave two recordings into one
      ## timeline". Honouring the request would need per-session engines and
      ## per-session frame routing, which is a second engine rather than a
      ## flag — so this says so instead, and the caller offers the current-tab
      ## option that does work.

  ReplaySessionService* = ref object
    startProc*: proc(request: ReplaySessionRequest)
    canOpenSecondSession*: proc(): bool
      ## Whether this host can hold a SECOND live session beside the current
      ## one. Nil is read as `false`: a host that does not answer the question
      ## has not established that it can.

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

proc canOpenSecondReplaySession*(): bool =
  ## Whether a `newSessionTab` request could be honoured.
  ##
  ## Asked BEFORE the gesture is offered, so a menu never shows an option that
  ## will be refused. Nil-safe in both directions: no service and no predicate
  ## both mean no.
  if not replaySessionServiceInstalled(): return false
  if installedReplaySessionService.canOpenSecondSession.isNil: return false
  installedReplaySessionService.canOpenSecondSession()

proc openReplaySession*(request: ReplaySessionRequest): ReplaySessionOutcomeKind =
  ## Ask for a session, and say what happened.
  ##
  ## Every non-`rsoOpened` answer is a real state and not an error: a desktop
  ## build, an extension build, and a web deployment that ships no engine all
  ## reach here, and all of them should carry on showing the trace summary they
  ## already show.
  if not replaySessionServiceInstalled(): return rsoNoHost
  if request.rawMemoryTrace.strip.len == 0: return rsoEmptyTrace
  if request.newSessionTab and not canOpenSecondReplaySession():
    # NOTHING IS OPENED. Falling back to the current tab would answer a
    # different question than the one asked and would destroy the session the
    # user wanted to keep beside this one — which is the entire reason they
    # asked for a new tab.
    return rsoNoSecondSession
  installedReplaySessionService.startProc(request)
  rsoOpened

proc requestReplaySession*(request: ReplaySessionRequest): bool =
  ## Ask for a session. Returns whether anything took the request.
  ##
  ## Kept as the two-valued form for callers that only branch on "did a
  ## debugger open" — `noir_build_producer`'s trace arm is one — and defined in
  ## terms of `openReplaySession` so there is one decision and not two.
  openReplaySession(request) == rsoOpened

proc resetReplaySessionServiceForTests*() =
  ## Tests share a process; without this the third case would inherit the
  ## second's service and pass for the wrong reason.
  installedReplaySessionService = nil
