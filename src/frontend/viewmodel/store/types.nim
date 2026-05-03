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

  # -------------------------------------------------------------------
  # HTTP Request panel — captured HTTP request inspector.
  #
  # Mirrors the legacy ``HttpRequestEntry`` record in
  # ``frontend/types.nim`` but uses ``string`` instead of ``cstring``
  # so the same value works on both native and JS backends without
  # conversion noise.  Used by ``RequestPanelVM`` to drive the IsoNim
  # view that replaces the legacy Karax ``method render`` on
  # ``RequestPanelComponent``.
  # -------------------------------------------------------------------

  RequestRecord* = object
    ## One captured HTTP request displayed in the inspector table.
    ##
    ## ``id``           — sequential 1-based number assigned at
    ##                    capture time; rendered in the ``#`` column.
    ## ``httpMethod``   — request verb (``"GET"``, ``"POST"`` …).
    ##                    Drives both the column text and the method
    ##                    filter dropdown.
    ## ``url``          — request URL.  The free-text search filter
    ##                    matches case-insensitively on this field.
    ## ``statusCode``   — HTTP response status code.  The status
    ##                    bucket filter ("2xx", "3xx", "4xx", "5xx")
    ##                    classifies on this value, and the view
    ##                    derives the ``request-status-<bucket>`` CSS
    ##                    class from it.
    ## ``durationMs``   — wall-clock time spent serving the request,
    ##                    in milliseconds.  Rendered as ``"NNNms"`` /
    ##                    ``"N.Ns"`` in the duration column.
    ## ``responseSize`` — size of the response body in bytes.
    ##                    Rendered as ``"N B"`` / ``"N.N KB"`` /
    ##                    ``"N.N MB"`` in the size column.
    ## ``startGeid``    — Global Event ID at the handler entry point;
    ##                    used by ``jumpToHandler`` so the debugger
    ##                    can seek to the captured handler frame.
    id*: int
    httpMethod*: string
    url*: string
    statusCode*: int
    durationMs*: int
    responseSize*: int
    startGeid*: int64

  # -------------------------------------------------------------------
  # Welcome screen — recent traces, recent folders, start options,
  # edit-mode + launch-config state.
  #
  # Mirrors the legacy ``WelcomeScreenComponent`` (see
  # ``frontend/ui/welcome_screen.nim``) but with plain ``string`` value
  # types so the same data works on both native (``test-vm-native``)
  # and JS (``test-vm-js``) backends without ``cstring`` /
  # ``langstring`` conversion noise.  The Karax view keeps its own
  # ``Trace``/``RecentFolder``/``WelcomeScreenOption`` ref-objects in
  # ``frontend/types.nim``; the legacy bridge translates those into
  # the value types below before mirroring them into the VM signals.
  # -------------------------------------------------------------------

  RecentTraceRecord* = object
    ## One trace listed in the welcome-screen "RECENT TRACES" panel.
    ##
    ## ``id``       — unique trace identifier (matches
    ##                ``Trace.id`` on the legacy ref-object).
    ## ``program``  — captured program path / name; rendered in the
    ##                ``recent-trace-title-content`` span.
    ## ``args``     — command-line arguments captured for the recording.
    ##                Joined with spaces in the tooltip's ``Args`` line.
    ## ``workdir``  — working directory the recording ran from.
    ## ``date``     — recorded date string (``"yyyy/MM/dd"`` or
    ##                ``"yyyy/MM/dd HH:mm:ss"``).  ``formatTimeAgo`` in
    ##                the legacy view turns this into the
    ##                ``recent-trace-title-time`` "N minutes/hours/days
    ##                ago" string.
    ## ``duration`` — recorded duration string (free text, may be
    ##                empty).  Surfaced verbatim in the tooltip.
    id*: int
    program*: string
    args*: seq[string]
    workdir*: string
    date*: string
    duration*: string

  RecentFolderRecord* = object
    ## One folder listed in the welcome-screen "RECENT FOLDERS" panel.
    ##
    ## ``id``   — unique identifier for the folder entry.
    ## ``name`` — display name (rendered in the
    ##            ``recent-folder-name`` div).
    ## ``path`` — absolute folder path; the legacy click handler
    ##            sends ``CODETRACER::load-recent-folder`` with this
    ##            path.
    id*: int
    name*: string
    path*: string

  WelcomeStartOptionRecord* = object
    ## One button in the start-options strip below the recent panels.
    ##
    ## Mirrors ``WelcomeScreenOption`` from ``frontend/types.nim`` but
    ## drops the per-render ``hovered`` flag — the IsoNim view derives
    ## the hover modifier from the VM's ``hoveredOption`` signal so
    ## the option records themselves stay immutable in the
    ## ``startOptions`` signal.
    ##
    ## ``key``      — stable identifier used in click dispatch and
    ##                CSS class derivation (e.g. ``"open-folder"``,
    ##                ``"record-new-trace"``).  The Karax view derives
    ##                this from ``toLowerAscii($name).split.join("-")``.
    ## ``name``     — visible label (e.g. ``"Open folder"``).
    ## ``inactive`` — when true, the button is rendered with the
    ##                ``inactive-start-option`` modifier and clicks
    ##                are no-ops.
    key*: string
    name*: string
    inactive*: bool

  WelcomeScreenMode* = enum
    ## Which top-level surface the welcome screen is rendering.
    ##
    ## Mirrors the three mutually-exclusive Karax flags
    ## (``welcomeScreen`` / ``newRecordScreen`` / ``openOnlineTrace``)
    ## as a single typed enum so the VM cannot fall into the
    ## "all three false" fallthrough state the Karax method
    ## allowed.
    wsmWelcome     ## "welcome-screen" surface (recent traces / folders / start options)
    wsmNewRecord   ## "new-record-screen" surface (record-form)
    wsmOnlineTrace ## "new-record-screen" surface (online-download form)
    wsmEdit        ## edit-mode (no welcome surface; main UI is shown)

  LaunchConfigEntry* = object
    ## One entry in the "Debug → Launch Configurations" submenu.
    ##
    ## Mirrors the entries the GUI ``launch_config.spec.ts`` asserts
    ## on (``.menu-element-python-fibonacci`` /
    ## ``.menu-element-ruby-fibonacci`` etc.).  ``slug`` is the kebab-
    ## case suffix the spec's locator uses; ``label`` is the rendered
    ## menu text; ``language`` is the preconfigured language tag
    ## (``"python"``, ``"ruby"`` …); ``program`` is the script the
    ## launch config will run.
    slug*: string
    label*: string
    language*: string
    program*: string
    enabled*: bool

  # -------------------------------------------------------------------
  # Trace Log panel — tabular tracepoint-result inspector.
  #
  # Mirrors the legacy ``Stop`` records from
  # ``common_types/debugger_features/tracepoints`` that the Karax
  # ``TraceLogComponent`` rendered in a DataTables grid (one row per
  # tracepoint hit).  Columns in the legacy view: rr-ticks, file:line,
  # function name, formatted locals.  ``TraceLogEntry`` collapses
  # those into plain ``string`` fields so the same value works on
  # both native (``test-vm-native``) and JS (``test-vm-js``) backends
  # without ``cstring`` / ``langstring`` conversion noise.
  # -------------------------------------------------------------------

  TraceLogEntry* = object
    ## One captured tracepoint stop displayed as a row in the trace
    ## log panel.
    ##
    ## ``rrTicks``       — replay timeline tick at the stop.  Used as
    ##                     the sort key (legacy view sorted ascending
    ##                     by this column) and to render the
    ##                     ``event-rr-ticks-line`` indicator.
    ## ``minRRTicks`` /
    ## ``maxRRTicks``    — recording timeline extent at capture time.
    ##                     The legacy renderer scaled the rr-ticks
    ##                     line position from this range; carrying
    ##                     them per-row keeps the value type stable
    ##                     even if the live timeline shifts later.
    ## ``path``          — full source path the tracepoint fired in.
    ## ``line``          — 1-based source line number.
    ## ``functionName``  — enclosing function.  Rendered verbatim in
    ##                     the function-name column.
    ## ``localsText``    — pre-formatted "name=repr name=repr ..."
    ##                     string mirroring the legacy column 4
    ##                     renderer (literal strings emit as bare
    ##                     text; error variables emit as
    ##                     ``name=<span class=error-trace>...</span>``
    ##                     in the legacy view; the IsoNim view emits
    ##                     a flat string and lets CSS style the row).
    ## ``eventId``       — rr event id used by the row click handler
    ##                     to dispatch ``ct/event-jump`` (matches the
    ##                     legacy ``CtEventJump`` event payload — the
    ##                     ``Stop`` cast to ``ProgramEvent`` carries
    ##                     the ``event`` field).
    ## ``tracepointId``  — owning tracepoint identifier; reserved for
    ##                     future per-tracepoint deletion / toggle
    ##                     wiring in the IsoNim view.
    rrTicks*: int
    minRRTicks*: int
    maxRRTicks*: int
    path*: string
    line*: int
    functionName*: string
    localsText*: string
    eventId*: int
    tracepointId*: int

  # -------------------------------------------------------------------
  # Scratchpad panel — list of values pinned by the user.
  #
  # Mirrors the legacy ``ScratchpadComponent`` (``frontend/ui/scratchpad.nim``)
  # which kept a parallel ``programValues: seq[(cstring, Value)]`` and
  # ``values: seq[ValueComponent]``.  The Karax view rendered each
  # entry by delegating to the rich ``ValueComponent`` sub-tree.
  # ``ScratchpadValueEntry`` collapses just the data the IsoNim view
  # needs into plain ``string`` fields so the same value type works on
  # both ``test-vm-native`` and ``test-vm-js`` without ``cstring`` /
  # ``langstring`` conversion noise.
  #
  # NOTE: rich ``ValueComponent`` rendering (expandable trees, charts,
  # inline / verbose toggles) remains a follow-up.  The value is
  # carried as a pre-rendered ``valueText`` string so the IsoNim
  # renderer can paint it verbatim, mirroring what trace_log §1.69 did
  # with ``localsToText``.  The ``isError`` and ``isLiteral`` flags
  # are surfaced so future work can apply the legacy ``error-trace``
  # CSS rule and the literal-string display branch without re-fetching
  # the original ``Value`` tree.
  # -------------------------------------------------------------------

  ScratchpadValueEntry* = object
    ## One pinned value displayed in the Scratchpad panel.
    ##
    ## ``expression`` — the source-level expression / variable name the
    ##                  user sent to the scratchpad (e.g. ``"i"`` or
    ##                  ``"board[2][3]"``).  Rendered verbatim in the
    ##                  ``scratchpad-value-cell`` row.
    ## ``valueText``  — pre-rendered text representation of the value
    ##                  at capture time, mirroring the legacy
    ##                  ``ValueComponent`` collapsed view.  The
    ##                  ``valueTextRepr`` helper (in ``ui/scratchpad.nim``)
    ##                  produces this string from a ``Value`` ref-object
    ##                  before it is mirrored into the VM.
    ## ``isError``    — true when the captured value was a
    ##                  ``types.Error``.  The IsoNim view colours these
    ##                  rows with the ``scratchpad-value-error`` CSS
    ##                  modifier (mirrors the ``error-trace`` rule on
    ##                  the legacy DOM).
    ## ``isLiteral``  — true when the captured value was a literal
    ##                  string (the legacy view rendered such values as
    ##                  bare text without the ``name=`` prefix); reserved
    ##                  for the rich-rendering follow-up.
    expression*: string
    valueText*: string
    isError*: bool
    isLiteral*: bool

  LaunchConfigState* = object
    ## Reactive launch-config state.
    ##
    ## ``configs``        — full list of available launch
    ##                      configurations (typically populated from
    ##                      ``examples/launch.json`` or the IDE's
    ##                      ``.codetracer/launch.json``).
    ## ``selectedSlug``   — currently-selected launch config slug.
    ##                      Empty string means "no selection".
    ## ``editFolderPath`` — folder path the IDE is editing (mirrors
    ##                      the GUI spec's ``editFolderPath`` fixture
    ##                      param).  Empty string in welcome /
    ##                      record / online-trace mode.
    configs*: seq[LaunchConfigEntry]
    selectedSlug*: string
    editFolderPath*: string

  # -------------------------------------------------------------------
  # Filesystem panel — file-tree explorer.
  #
  # Mirrors the legacy ``FilesystemComponent`` (``frontend/ui/filesystem.nim``)
  # which used jstree for the in-Karax tree rendering plus a parallel
  # diff-files list when ``data.startOptions.diff`` was populated.
  # ``FilesystemEntryNode`` collapses just the data the IsoNim view
  # needs into plain ``string`` / ``bool`` / ``seq`` shapes so the same
  # value type works on both ``test-vm-native`` and ``test-vm-js``
  # without ``cstring`` / ``langstring`` conversion noise.
  #
  # NOTE: rich jstree-style rendering (animated open/close, contextmenu
  # plugin, search plugin, drag-and-drop) remains a follow-up.  The
  # value carries enough state for the IsoNim view to render a
  # collapsible tree with one row per entry, optional devicon class,
  # and a diff-class modifier so the view can apply the legacy
  # ``diff-file-added`` / ``diff-file-changed`` / ``diff-file-deleted``
  # CSS modifiers without re-querying the legacy ``EditorService``.
  # -------------------------------------------------------------------

  FilesystemDiffClass* = enum
    ## Per-entry diff modifier the legacy view threaded through jstree
    ## via ``reapplyDiffClasses`` after every load / refresh / open
    ## event.  Captured as an enum here so the IsoNim view never has to
    ## re-derive it from the path comparison the legacy code did.
    fdcNone     ## No diff modifier (the default).
    fdcAdded    ## Maps to the legacy ``diff-file-added`` CSS class.
    fdcChanged  ## Maps to the legacy ``diff-file-changed`` CSS class.
    fdcDeleted  ## Maps to the legacy ``diff-file-deleted`` CSS class.

  FilesystemEntryNode* = object
    ## One node in the filesystem tree displayed by the panel.
    ##
    ## ``id``           — stable identifier matching the legacy
    ##                    ``"j{1}_{index}"`` jstree node id.  Empty
    ##                    string when not yet assigned (e.g. a synthetic
    ##                    placeholder root).  Carrying it explicitly
    ##                    keeps the IsoNim row's ``id`` attribute stable
    ##                    for any external CSS targeting the diff
    ##                    classes by ``#j…``.
    ## ``text``         — display label (bare basename).  Rendered
    ##                    inside the row's ``filesystem-entry-label``
    ##                    span.
    ## ``path``         — full path the entry resolves to (the legacy
    ##                    ``original.path``).  Click handlers use this
    ##                    to dispatch ``ViewSource`` opens through
    ##                    ``data.openTab``.
    ## ``icon``         — devicon CSS class (e.g.
    ##                    ``"devicon-python-plain"``).  Empty string
    ##                    falls back to the bundled folder icon in the
    ##                    view CSS.
    ## ``isFolder``     — true when the entry has children and should
    ##                    render the expand/collapse twisty.
    ## ``isExpanded``   — true when the children are currently visible.
    ##                    The view toggles a ``.expanded`` modifier on
    ##                    the row root from this signal so a second
    ##                    click on the twisty collapses the subtree.
    ## ``diffClass``    — optional diff modifier (see
    ##                    ``FilesystemDiffClass``).  The IsoNim view
    ##                    applies the corresponding ``diff-file-…``
    ##                    class on the row.
    ## ``children``     — recursive list of child entries (folders carry
    ##                    them; files leave the seq empty).
    id*: string
    text*: string
    path*: string
    icon*: string
    isFolder*: bool
    isExpanded*: bool
    diffClass*: FilesystemDiffClass
    children*: seq[FilesystemEntryNode]

  FilesystemDiffEntry* = object
    ## One row in the synthetic ``diff-files-list`` the legacy view
    ## rendered below the jstree when ``data.startOptions.diff`` was
    ## populated (e.g. a recorded session opened from a diff fixture).
    ##
    ## ``path``    — full source path the diff row links to.  Click
    ##               opens it via ``data.openTab`` exactly like the
    ##               legacy ``diffItem`` helper did.
    ## ``zebra``   — true for the legacy ``path-odd`` row, false for
    ##               ``path-even``.  Pushed in from the bridge so the
    ##               view does not need to re-derive the alternation.
    path*: string
    zebra*: bool

# Explicit ``==`` overrides for the Filesystem panel value types so the
# IsoNim signal write path can compile under Nim's side-effect inference.
# The default structural ``==`` Nim derives for ``FilesystemEntryNode``
# walks a recursive ``seq[FilesystemEntryNode]``, and that recursion is
# inferred as side-effecting (the recursive call is treated as
# potentially side-effecting by ``system.==``).  Marking these
# operators ``{.noSideEffect.}`` and computing structural equality
# explicitly keeps the signal write path pure so
# ``writeSignal`` compiles for ``Signal[FilesystemEntryNode]`` /
# ``Signal[seq[FilesystemDiffEntry]]`` etc.

proc `==`*(a, b: FilesystemEntryNode): bool {.noSideEffect.} =
  if a.id != b.id: return false
  if a.text != b.text: return false
  if a.path != b.path: return false
  if a.icon != b.icon: return false
  if a.isFolder != b.isFolder: return false
  if a.isExpanded != b.isExpanded: return false
  if a.diffClass != b.diffClass: return false
  if a.children.len != b.children.len: return false
  for i in 0 ..< a.children.len:
    if a.children[i] != b.children[i]: return false
  true

proc `==`*(a, b: FilesystemDiffEntry): bool {.noSideEffect.} =
  a.path == b.path and a.zebra == b.zebra
