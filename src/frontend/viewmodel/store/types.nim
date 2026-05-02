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

  # -------------------------------------------------------------------
  # Build panel value types
  #
  # The Build panel renders three logical lists: stdout/stderr output
  # lines (with optional clickable source-location parsing), structured
  # build errors that a user can jump to, and severity-tagged problems
  # surfaced in the Problems panel.  The legacy ``Build`` object on
  # ``frontend/types.nim`` keeps tuple-shaped data; the ViewModel layer
  # uses these named value types so signals stay readable and the
  # headless view tests can assert against well-named fields.
  # -------------------------------------------------------------------

  BuildLineSeverity* = enum
    ## Severity tag attached to a parsed build line. Matches the
    ## ``BuildSeverity`` enum in ``frontend/ui/build_location_parser``;
    ## kept independent so the ViewModel layer does not depend on the
    ## legacy ui module.
    blsNone     ## No diagnostic — plain stdout / stderr line.
    blsError    ## Compiler error.
    blsWarning  ## Compiler warning.
    blsInfo     ## Informational note.

  BuildOutputLine* = object
    ## One rendered line in the Build panel's output stream.
    ##
    ## ``htmlText`` carries the ANSI-converted HTML the legacy view
    ## inserts via Karax's ``verbatim`` (the JS-side ``ansi_up``
    ## library produces ``<span style="color:...">`` runs).  The view's
    ## Web overload writes this string into ``innerHTML``; the Mock
    ## overload assigns it to ``textContent`` so headless tests can
    ## assert on the text directly.
    ##
    ## ``isStdout`` selects the ``build-stdout`` vs ``build-stderr``
    ## CSS class — stderr is rendered in red/orange in production CSS.
    ##
    ## ``severity`` is ``blsNone`` for unparseable output; otherwise it
    ## carries the diagnostic level extracted by ``parseBuildLocation``
    ## so the view can apply ``build-line-error`` / ``build-line-warning``
    ## / ``build-line-info`` classes.  When the line carries a parsed
    ## location the view turns it into a clickable jump target.
    ##
    ## ``locationPath`` / ``locationLine`` describe the source location
    ## referenced by the line.  ``locationPath`` is empty when the line
    ## has no parsed location.  ``locationLine`` is 1-based; 0 means
    ## unknown.
    htmlText*: string
    isStdout*: bool
    severity*: BuildLineSeverity
    locationPath*: string
    locationLine*: int

  BuildErrorLine* = object
    ## One row in the Problems / Errors view.  ``rawLocation`` is the
    ## ``"path(line, col)"``-style display string the legacy view
    ## emitted; ``other`` carries the diagnostic message text.  Click
    ## navigates to ``locationPath`` : ``locationLine``.
    locationPath*: string
    locationLine*: int
    rawLocation*: string
    other*: string

  BuildProblemLine* = object
    ## One BuildProblem row.  Mirrors the legacy ``BuildProblem`` object
    ## but with ``string`` instead of ``cstring`` so the value lives on
    ## both native and JS backends without conversion noise.
    severity*: BuildLineSeverity
    path*: string
    line*: int
    col*: int
    message*: string

  # -------------------------------------------------------------------
  # Errors / Problems panel value types
  #
  # The Errors panel renders the same ``BuildProblemLine`` rows the
  # Build panel produces, so it reuses ``BuildProblemLine`` directly.
  # Its panel-specific state is the active filter and the
  # group-by-file toggle, both captured below.
  # -------------------------------------------------------------------

  ProblemFilterTag* = enum
    ## Severity filter for the Problems panel.  Mirrors the legacy
    ## ``ProblemFilter`` enum in ``frontend/types.nim`` but lives in
    ## the platform-neutral viewmodel layer so it does not depend on
    ## the JS-only Karax types.
    pfAll       ## Show every problem regardless of severity.
    pfErrors    ## Show only ``blsError`` rows.
    pfWarnings  ## Show only ``blsWarning`` rows.

  # -------------------------------------------------------------------
  # Search results panel value types
  #
  # The Search Results panel renders a flat list of file/line/snippet
  # rows produced by a workspace-wide search (``data.services.search``
  # in the legacy world).  ``SearchResultLine`` is the simple, platform-
  # neutral shape the view layer needs without dragging the JS-only
  # ``SearchResult`` Karax record into the ViewModel layer.
  # -------------------------------------------------------------------

  SearchResultLine* = object
    ## One row in the Search Results panel.  Mirrors the legacy
    ## ``SearchResult`` object in ``frontend/types.nim`` but uses
    ## ``string`` instead of ``cstring`` so the same value works on
    ## both the native and JS backends.
    ##
    ## ``text`` is the matched line snippet (the panel highlights any
    ## occurrence of the active query inside it).  ``path`` is the
    ## absolute / project-relative source path; clicking a row asks
    ## the backend to navigate to ``path : line`` via
    ## ``ct/jump-location``.  ``line`` is 1-based.
    text*: string
    path*: string
    line*: int

  # -------------------------------------------------------------------
  # No-source panel value types
  #
  # The "no source" panel is shown inside the editor tab when the
  # debugger lands on a location whose source file cannot be opened
  # (no debug-info path, jumped into a stripped binary, etc.).  The
  # legacy Karax view in ``frontend/ui/no_source.nim`` rendered a
  # fixed "Whoops!" header followed by a free-form message, the
  # current high-level function/path/line trio, and — if jump history
  # was available — the previous location with a "Jump back" button.
  # The value types below mirror that contract without dragging the
  # JS-only Karax structures (``Component`` / ``VNode``) into the
  # view-model layer.
  # -------------------------------------------------------------------

  NoSourceLocationInfo* = object
    ## High-level context the no-source panel renders below the
    ## "Whoops!" header.  Mirrors the legacy
    ## ``data.services.debugger.location`` lookup; using a value type
    ## keeps the panel tests from depending on the live debugger
    ## service.
    ##
    ## ``functionName`` is shown unconditionally (legacy view used
    ## ``- Function: '<name>'`` even when the name is empty).
    ## ``path`` and ``line`` are shown only when populated — empty
    ## strings / negative line numbers omit the row, matching the
    ## ``NO_PATH``/``NO_CODE`` guards in the legacy code.
    functionName*: string
    path*: string
    line*: int

  NoSourceHistoryInfo* = object
    ## Optional jump-history context the no-source panel shows when
    ## ``jumpHistory`` had at least two entries.  Mirrors the legacy
    ## render's ``history[^2].location`` + ``history[^1].lastOperation``
    ## fan-out.  The "Jump back" button is rendered only when
    ## ``hasHistory`` is true and ``action`` is non-empty (matching the
    ## legacy ``if hasHistory and action != ""`` guard).
    hasHistory*: bool
    previousPath*: string
    action*: string

  # -------------------------------------------------------------------
  # Step List panel value types
  #
  # The Step List panel renders a linear list of step lines around the
  # current debugger position.  Each entry has a relative ``delta``
  # offset from the current position, a source location, the source
  # text the step lands on, and zero or more ``StepLineFlowValue``
  # entries (the legacy view used these for inline expression / value
  # repr strings — for ``Line`` rows they are the captured flow values,
  # for ``Call`` rows the function arguments, for ``Return`` rows the
  # single returned expression).  The shape mirrors the legacy
  # ``LineStep`` record in ``common_types/debugger_features/stepping``
  # but uses ``string`` instead of ``langstring`` so the same value
  # works on both native and JS backends without conversion noise.
  # -------------------------------------------------------------------

  StepLineKind* = enum
    ## Mirrors ``LineStepKind`` from
    ## ``common_types/debugger_features/stepping.nim`` (Line / Call /
    ## Return).  Kept as a plain (non-pure) enum so the ``$`` produces
    ## the bare names the legacy CSS classes used (``step-line``,
    ## ``step-line-call``, ``step-line-return``).
    slkLine
    slkCall
    slkReturn

  StepLineFlowValue* = object
    ## One ``expression = repr`` pair attached to a step line.  The
    ## legacy view used ``stepFlowValue.expression`` and
    ## ``stepFlowValue.value.textRepr``; the VM caller pre-renders the
    ## value to text so the view layer does not depend on the JS-only
    ## ``Value`` type tree.
    expression*: string
    value*: string

  StepLineLocation* = object
    ## Minimal location info the Step List panel needs.  ``rrTicks``
    ## drives the active-step highlight (the legacy view compared the
    ## current debugger ``rrTicks`` + ``path`` + ``line`` against each
    ## row's location).  ``functionName`` feeds the ``filename:line[fn]``
    ## label rendered for ``Line`` rows.
    path*: string
    line*: int
    functionName*: string
    rrTicks*: int

  StepLine* = object
    ## One row in the Step List panel.
    ##
    ## ``delta`` is the signed offset from the current debugger position
    ## (negative = backward, positive = forward).  It also drives the
    ## ``lineStepJump`` step request (``repeat = delta``,
    ## ``reverse = delta < 0``).
    ##
    ## ``sourceLine`` is the rendered source / description text the
    ## panel emits inside the ``<pre><code>`` block (Line rows) or the
    ## ``step-line-description`` span (Call / Return rows).
    ##
    ## ``values`` is the list of ``expression = repr`` pairs the legacy
    ## view rendered alongside the row.  ``Line`` rows render every
    ## entry inside ``.step-line-flow-value``; ``Call`` rows render
    ## every entry inside ``.step-line-args``; ``Return`` rows render
    ## only the first entry inside ``.step-line-return-value``.
    kind*: StepLineKind
    delta*: int
    location*: StepLineLocation
    sourceLine*: string
    values*: seq[StepLineFlowValue]

  # -------------------------------------------------------------------
  # Low Level Code panel — assembly / IR view.
  #
  # Mirrors the legacy ``Instruction`` / ``Instructions`` records in
  # ``common_types/language_features/code.nim`` but uses ``string``
  # instead of ``langstring`` so the same value works on both native
  # and JS backends without conversion noise.  Used by
  # ``LowLevelCodeVM`` to drive the IsoNim view that replaces the
  # legacy Karax ``method render`` on ``LowLevelCodeComponent``.
  # -------------------------------------------------------------------

  LowLevelInstruction* = object
    ## One row in the asm/bytecode listing.  ``offset`` is the
    ## program-counter offset / step id used to flag the active row
    ## (``LowLevelCodeVM.activeOffset`` matches this column for the
    ## ``active-instruction`` highlight).  ``highLevelPath`` /
    ## ``highLevelLine`` carry the back-pointer to the source line the
    ## instruction was generated from — the legacy view used these to
    ## populate Monaco view zones; the IsoNim view exposes them so the
    ## same source-line cross-reference can be rendered as a list.
    name*: string
    args*: string
    other*: string
    offset*: int
    highLevelPath*: string
    highLevelLine*: int

  LowLevelInstructionList* = object
    ## The full asm-load response payload.  ``address`` is the
    ## function's load address (rendered as the panel's
    ## "Originating address" hex string); ``error`` carries any
    ## backend-side load failure that should replace the listing.
    address*: int
    instructions*: seq[LowLevelInstruction]
    error*: string
