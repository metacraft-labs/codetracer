## store/types.nim
##
## Data types for the ViewModel layer's ReplayDataStore.
##
## These are intentionally independent of the legacy frontend types to
## avoid circular imports and keep the ViewModel layer self-contained.
## They represent the "clean" domain model that panels and view-models
## consume via reactive signals.

type
  LoadingState* = enum
    ## Tracks the status of an async data-fetch operation.
    lsIdle      ## No request in flight
    lsLoading   ## Request sent, waiting for response
    lsError     ## Last request failed

  ConnectionStatus* = enum
    ## Backend connection lifecycle.
    csDisconnected  ## Not connected to a backend
    csConnecting    ## Connection attempt in progress
    csConnected     ## Connected and ready
    csError         ## Connection lost or failed

  DebuggerStatus* = enum
    ## Current state of the replay debugger.
    dsIdle      ## Waiting for a command
    dsStepping  ## Single-step in progress
    dsRunning   ## Continue / run in progress
    dsFinished  ## Execution reached the end of the recording
    dsError     ## Debugger hit an internal error

  StepDirection* = enum
    ## Direction argument for step/continue commands.
    sdForward
    sdBackward
    sdStepIn
    sdStepOut
    sdContinue
    sdReverseContinue

  Location* = object
    ## Source-code position.
    file*: string
    line*: int
    column*: int

  # -------------------------------------------------------------------
  # Aggregate state objects — one per logical domain
  # -------------------------------------------------------------------

  SessionState* = object
    ## Top-level session information.
    connectionStatus*: ConnectionStatus

  DebuggerState* = object
    ## Snapshot of the debugger's position in the recording.
    location*: Location
    rrTicks*: uint64
    status*: DebuggerStatus
    threadId*: uint32

  TimelineState* = object
    ## The recording timeline's extent and current position.
    minRRTicks*: uint64
    maxRRTicks*: uint64
    currentRRTicks*: uint64

  # -------------------------------------------------------------------
  # Panel data rows — kept deliberately minimal; expanded as panels
  # are converted to the ViewModel architecture.
  # -------------------------------------------------------------------

  CallLine* = object
    ## One row in the calltrace panel.
    index*: int64
    name*: string
    depth*: int
    rrTicks*: uint64
    location*: Location
    hasChildren*: bool      ## Whether this call has children that can be expanded
    isExpanded*: bool       ## Whether children are currently shown (collapse toggle visible)
    callKey*: string        ## The call key used by the legacy expand/collapse system

  CallArg* = object
    ## One argument value attached to a call. Mirrors the legacy
    ## ``common_types/debugger_features/call.nim`` ``CallArg`` ref-object
    ## but in the simpler value-type shape the ViewModel layer uses.
    ##
    ## The ``text`` field holds the rendered text representation of the
    ## value at the moment the calltrace section was loaded, so the view
    ## layer can render it verbatim without re-evaluating the ``Value``
    ## type tree. This matches the ``arg.value.textRepr`` call the legacy
    ## ``callArgView`` made in ``frontend/ui/calltrace.nim``.
    name*: string
    text*: string

  Variable* = object
    ## A local / global variable entry (recursive for compound types).
    name*: string
    value*: string
    typeName*: string
    hasChildren*: bool
    children*: seq[Variable]

  EventLogRow* = object
    ## One row in the event-log panel.
    eventId*: uint64
    kind*: string
    line*: int
    value*: string

  TerminalEventFragment* = object
    ## One text fragment within a terminal-output line.
    ##
    ## Mirrors the legacy ``TerminalEvent`` ref-object (see
    ## ``frontend/types.nim``) but in the simpler value-type shape the
    ## ViewModel layer uses.
    ##
    ## ``htmlText`` carries the already-ANSI-converted HTML string the
    ## view emits verbatim (the legacy view uses ``verbatim``); the
    ## fragment is associated with one ``ProgramEvent`` via
    ## ``eventIndex`` so click handlers can dispatch a navigation jump.
    ## ``rrTicks`` is the source event's ``directLocationRRTicks`` —
    ## the view compares it against the current debugger position to
    ## colour the fragment as ``past`` / ``active`` / ``future``.
    htmlText*: string
    eventIndex*: int
    rrTicks*: uint64

  TerminalLine* = object
    ## One rendered line of terminal output. Contains zero or more
    ## ``TerminalEventFragment`` entries (one per ANSI run within the
    ## line). The view emits a ``<div class="terminal-line"
    ## id="terminal-line-{lineIndex}">`` element with one child div per
    ## fragment.
    lineIndex*: int
    fragments*: seq[TerminalEventFragment]
