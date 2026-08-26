## viewmodels/trace_open.nim
##
## The one way a ViewModel asks CodeTracer to open a recording.
##
## `codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md` §20.5.5:
## "Recorded executions are normal CodeTracer traces.  Opening a test
## recording uses the existing trace-opening path and tab model" — **current
## tab** replaces the active session, **new tab** opens beside it.  The
## request and the policy live here, apart from any one panel, precisely so
## that a second surface wanting to open a recording (AA-2's Agent Activity
## session feed, after the editor gutter controls) reaches for *this* and does
## not grow a second opening path.  `Agent-Activity-Panel.milestones.org`
## states that as a constraint on AA-2: "reuse it, not add a second way to
## open a trace."
##
## Extracted from `test_explorer_vm.nim`, which re-exports it so every
## existing importer keeps the same surface.

type
  TraceOpenPolicy* = enum
    ## The `--open-policy` distinction, spelled exactly as the CLI spells it
    ## so the argv builders can stringify the enum directly.
    topCurrentTab = "current-tab"
    topNewTab = "new-tab"

  TraceOpenRequest* = object
    ## A recording to open.  Flat strings only: this crosses from headless
    ## ViewModel code into the renderer's IPC, and neither side should need
    ## the runner's `TraceMetadata` to talk to the other.
    tracePath*: string
    traceId*: string
    recordingId*: string
    testId*: string
    policy*: TraceOpenPolicy

  TraceOpenService* = ref object
    ## The host's implementation of "open this".  Nil-safe on purpose: a
    ## headless ViewModel is fully constructible without a renderer, and a
    ## test that never wires one gets silence rather than a crash.
    openProc*: proc(request: TraceOpenRequest)

proc openTrace*(service: TraceOpenService; request: TraceOpenRequest) =
  if not service.isNil and not service.openProc.isNil:
    service.openProc(request)
