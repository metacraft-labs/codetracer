import
  std/[ jsffi, dom, async, typetraits, tables ],
  vdom, karax, kdom,
  lang, communication, dap,
  lib/[ monaco_lib, jslib ],
  rr_gdb

type
  defaultstring = cstring
  langstring = cstring
  TableLike = JsAssoc

include ../common/common_types

type
  CodetracerFile* = ref object
    text*:          langstring
    children*:      seq[CodetracerFile]
    state*:         JsObject
    icon*:          langstring
    original*:      CodetracerFileData
    index*:         int
    parentIndices*: seq[int]

  CodetracerFileData* = object
    text*:          langstring
    path*:          langstring

  Group* = ref object
    baseID*:        int
    focusedLoopID*: int
    loopWidths*: TableLike[int, seq[float]]
    loopFinal*: TableLike[int, float]
    lastCalculationID*: int
    baseWidth*:     float
    visibleStart*:  float
    element*:       JsObject


  TabInfo* = ref object
    viewLine*:        int
    highlightLine*:   int
    activeOverlay*:   Overlay
    overlayExpanded*: int
    monacoEditor*:    MonacoEditor
    lang*:            Lang
    name*:            cstring
    changed*:          bool
    reloadChange*:    bool
    untitled*:        bool
    location*:        Location
    offset*:          int
    error*:           cstring
    instructions*:    Instructions
    active*:          int
    source*:          cstring
    sourceLines*:     seq[cstring]
    received*:        bool
    path*:            cstring
    loading*:         bool
    noInfo*:          bool

  UIBreakpoint* = object
    line*: int
    path*: cstring
    fun*: cstring
    level*: int
    id*: int
    enabled*: bool
    error*: bool

  BreakpointMenu* = ref object
    program*: int
    frame*: seq[int]
    active*: bool
    jumped*: int

  ContextMenu* = ref object
    options*: JsAssoc[int, cstring]
    actions*: JsAssoc[int, proc()]
    dom*: dom.Node

  ContextMenuItem* = ref object
    name*: cstring
    hint*: cstring
    handler*: proc(ev: kdom.Event) {.closure.}

  EventTag* = enum EventStd, EventReads, EventWrites, EventNetwork, EventTrace, EventFiles, EventErrorEvents, EventEvm

  EventDropDownBox* = enum Filter, OnlyTrace, OnlyRecordedEvent, EnableDisable

  ExpireTraceState* = enum ThreeDaysLeft, Expired, NotExpiringSoon, NoExpireState

  # works great yes
  WithLocation* = concept a
    a.path is cstring
    a.line is int
    a.event is int
    # a.codeID is int64
    # a.functionID is FunctionID
    # a.callID is int64

  MenuLocation* = ref object
    x*:           int
    y*:           int

  Completion* = object
    line*:  int
    text*:  cstring

  MoveState* = ref object
    status*:  cstring
    location*: Location
    cLocation*: Location
    main*:    bool
    resetFlow*: bool
    stopSignal*: RRGDBStopSignal
    frameInfo*: FrameInfo

  ValueWithExpression* = ref object
    expression*: cstring
    value*: Value

  SourceLine* = object
    path*:                  cstring
    line*:                  int

  Overlay* {.pure.} = enum None, LowLevel, Hit

  MessageLevel* = enum MsgInfo, MsgWarn, MsgError

  LogMessage* = object
    message*: string
    level*: MessageLevel
    time*: BiggestInt
    # just finish it
    # when we finish messages, jumping busy stuff etc and breakpoints
    # and simple diffing and testing before

  TagKind* = enum TagLine, TagRegex

  Tag* = object
    path*:  cstring
    case kind*: TagKind:
    of TagLine:
      line*:  int
    of TagRegex:
      regex*: cstring

const CALLSTACK_DEFAULT_LIMIT* = -1 # 8

const MAX_WHITESPACE_WIDTH = 8

type
  EventOptionalColumn* = enum FullPath, LowLevelLocation

  Service* = ref object of RootObj
    data*: Data
    rrTicks*: int

  EventLogService* = ref object of Service
    events*: seq[ProgramEvent]
    debugger*: DebuggerService
    ignoreOutput*: bool
    started*: bool
    updatedContent*: bool
    onUpdatedEvents*: proc(self: EventLogService, response: seq[ProgramEvent]): Future[void]
    # onUpdatedTrace*: proc(self: EventLogService, response: TraceUpdate): Future[void]
    onUpdatedEventsContent*: proc(self: EventLogService, response: cstring): Future[void]
    onCompleteMove*: proc(self: EventLogService, response: MoveState): Future[void]

  ShellService* = ref object of Service
    onUpdatedShell*: proc(self: ShellService, response: ShellUpdate): Future[void]

  CalltraceService* = ref object of Service
    # slice*: GraphSlice
    calltraceJumps*: seq[cstring]
    # calltraceCallstack*: seq[Call]
    nonLocalJump*: bool


    isCalltrace*:    bool
    # callstack*:             seq[Call] # the names of the functions
    inCalltraceJump*:       bool
    calltraceCodeID*:       int64
    calltraceFunction*:     string
    callstackCollapse*:     tuple[name: cstring, level: int]
    callstackLimit*:        int
    # current*:     int64
    # callNames*: JsAssoc[cstring, cstring]
    loadingArgs*: JsSet[cstring]
    # onUpdatedCallArgs*: proc(self: CalltraceService, response: CallArgsUpdateResults): Future[void]

  TabService* = ref object of Service
    tabs*:          JsAssoc[cstring, TabInfo]
    active*:        cstring

  DebuggerService* = ref object of Service
    location*: Location
    locals*:  seq[Variable] # the locals while stepping
    registerState*: JsAssoc[cstring, cstring]
    watchExpressions*:    seq[cstring]
    startedFutures*: seq[Future[void]]
    hasStarted*: bool
    stableBusy*:            bool
    historyBusy*:           bool
    traceBusy*:             bool
    finished*:              bool
    currentOperation*:      cstring
    currentHistoryOperation*: cstring
    lastDirection*:         DebuggerDirection
    stableBuffer*:          seq[(string, bool)]
    editorView*:            EditorView
    lastAction*:            cstring
    cLocation*:             Location
    error*:                 DebuggerError
    breakpointTable*: JsAssoc[cstring, JsAssoc[int, UIBreakpoint]]
    currentJump*: int
    stopSignal*:            RRGDBStopSignal
    frameInfo*:             FrameInfo
    timer*:                 Timer
    operationCount*:        int
    lastRRTickTime*:        float
    avgRRTickTime*:         float
    expressionMap*:         JsAssoc[cstring, seq[FlowExpression]]
    showInlineValues*:      bool
    valueHistory*:          JsAssoc[cstring, ValueHistory]
    skipInternal*:          bool
    skipNoSource*:          bool
    jumpHistory*:           seq[JumpHistory]
    historyIndex*:          int
    historyDirection*:      bool
    listHistory*:           bool
    fullHistory*:           bool
    activeHistory*:         cstring
    usingContextMenu*:      bool

    # TODO: think if this is the best place for it
    paths*:                 seq[string]
    functions*:             seq[Function]

    onCompleteMove*: proc(self: DebuggerService, response: MoveState): Future[void]
    onLoadedLocals*: proc(self: DebuggerService, response: JsAssoc[cstring, Value]): Future[void]
    onDebuggerStarted*: proc(self: DebuggerService, response: int): Future[void]
    onUpdatedEvents*: proc(self: DebuggerService, response: seq[ProgramEvent]): Future[void]
    onFinished*:  proc(self: DebuggerService, response: JsObject): Future[void]
    onError*: proc(self: DebuggerService, response: DebuggerError): Future[void]
    onUpdatedWatches*: proc(self: DebuggerService, response: seq[Variable])
    onDebugOutput*: proc(self: DebuggerService, response: DebugOutput): Future[void]
    onAddBreakResponse*: proc(self: DebuggerService, response: BreakpointInfo): Future[void]
    onAddBreakCResponse*: proc(self: DebuggerService, response: BreakpointInfo): Future[void]

  JumpHistory* = ref object
    location*:  Location
    lastOperation*: cstring

  LowLevel* = ref object
    code*:      cstring
    functionName*: cstring

  EditorViewTabArgs* = object
    name*: cstring
    editorView*: EditorView

  EditorService* = ref object of Service
    loading*:   seq[cstring]
    open*:      JsAssoc[cstring, TabInfo]
    onCompleteMove*: proc(self: EditorService, response: MoveState): Future[void]
    onOpenedTab*: proc(self: EditorService, response: OpenedTab): Future[void]
    # lowLevelTabs*:      JsAssoc[cstring, LowLevelTab]
    # lowLevelActive*:    array[LowLevelView, (cstring, int)]
    # lowLevelPanels*:    array[LowLevelView, GoldenTab] # sorry, easier for now
    active*:    cstring
    # lowLevel*:  LowLevel
    tabHistory*: seq[EditorViewTabArgs]
    closedTabs*: seq[EditorViewTabArgs]
    historyIndex*: int
    lastSwitch*: BiggestInt
    untitledIndex*: int
    changeLine*: bool
    filesystem*: CodetracerFile
    currentLine*: int
    tags*:                  JsAssoc[cstring, seq[Tag]]
    completeMoveResponses*: JsAssoc[cstring, MoveState]
    expandedOpen*: JsAssoc[cstring, TabInfo]
    saveHistoryTimeoutId*: int
    hasSaveHistoryTimeout*: bool
    switchTabHistoryLimit*: int
    cachedFiles*: JsAssoc[cstring, TabInfo]
    addedDiffId*: seq[cstring]
    changedDiffId*: seq[cstring]
    deletedDiffId*: seq[cstring]
    index*: int
    # commandData*: CommandData


  PluginClient* = ref object
    cancelled*: bool
    running*: bool
    cancelOrWaitFunction*: proc: void
    window*: js
    trace*: Trace
    startOptions*: StartOptions
    # debugger*: DebuggerIPC


  SearchContext* = enum SearchContextClient, SearchContextIndex, SearchContextBackend

  SearchSource* = ref object
    # TODO fields it takes/supports
    # renderer-specific things like hints/checkboxes/color
    # search is nil when ctRenderer
    name*: cstring # used in menu
    helpText*: cstring # used in menu
    customFieldNames*: seq[cstring]
    context*: SearchContext
    search*: proc(query: SearchQuery, client: PluginClient): Future[void]

  SearchMode* = enum
    SearchCommandRealtime,
    SearchFileRealtime,
    SearchFixed,
    SearchFindInFiles,
    SearchFindSymbol
    ## Realtime is based on commandP (Sublime Text-like)
    ## Fixed on results panel (inspired by Vim/VsCode/Sublime Text/discussion with zahary)

  CommandKind* = enum ParentCommand, ActionCommand

  Command* = ref object
    name*: cstring
    case kind*: CommandKind:
    of ParentCommand:
      subcommands*: seq[cstring]
    of ActionCommand:
      action*: ClientAction
      shortcut*: cstring

  CommandInterpreter* = ref object
    data*: Data
    commands*: JsAssoc[cstring, Command]
    commandsPrepared*: seq[js]
    files*: JsAssoc[cstring, cstring]
    filesPrepared*: seq[js]
    symbols*: JsAssoc[cstring, seq[Symbol]]
    symbolsPrepared*: seq[js]
  # SearchCommand* = enum SearchCommandText, SearchCommandPlugin

  SearchService* = ref object of Service
    active*:  array[SearchMode, bool]
    mode*: SearchMode
    results*: array[SearchMode, seq[SearchResult]]
    queries*: array[SearchMode, cstring]
    selected*: int
    paths*:     JsAssoc[cstring, bool]
    pathsPrepared*:  seq[js]
    commandsPrepared*: seq[js]
    functionsPrepared*: seq[js]
    functionsInSourcemapPrepared*: seq[js]
    # currentCommand*: SearchCommand
    pluginCommands*: JsAssoc[cstring, SearchSource]
    activeCommandName*: cstring
    query*: SearchQuery
    onSearchResultsUpdated*: proc(self: SearchService, results: seq[SearchResult]): Future[void]

  QueryKind* = enum
    CommandQuery,
    FileQuery,
    ProgramQuery,
    TextSearchQuery,
    SymbolQuery

  CommandPanelResult* = ref object
    value*: cstring
    valueHighlighted*: cstring
    # if warn/error, only value used for now
    # as an warn/error message
    level*: NotificationKind
    case kind*: QueryKind:
    of FileQuery:
      fullPath*: cstring
    of CommandQuery:
      shortcut*: cstring
      action*: ClientAction
    of ProgramQuery:
      # content is in value
      # possibly additional context like
      # `var = x` / # ticks/step_id or others
      codeSnippet*: CodeSnippet
      location*: SourceLocation
    of TextSearchQuery, SymbolQuery:
      file*: cstring
      line*: int
      symbolKind*: cstring

  CodeSnippet* = object
    line*: int
    source*: cstring
    # eventually: lines*: seq[CodeSnippetLinecstring]
    # location*: SourceLocation


  SearchQuery* = ref object
    value*: cstring
    expectArgs*: bool
    case kind*: QueryKind
    of CommandQuery:
      args*: seq[cstring]
    else:
      discard

    query*: cstring
    includePattern*: cstring
    excludePattern*: cstring
    searchMode*: SearchMode

  HistoryService* = ref object of Service
    loading*:    bool

  FlowService* = ref object of Service
    enabledFlow*:  bool

  TraceService* = ref object of Service
    traceSessions*:   seq[TraceSession] # all traces
    unchanged*:       seq[ProgramEvent] # all current active and unchanged trace logs
    drawId*:          int
    tracePID*:        int

  ServiceConcept* = concept a
    a.restart() is void
    a.clearCache() is void

  GoldenLayoutConfigClass* = ref object of js
    fromResolved*: proc(resolvedConfig: GoldenLayoutResolvedConfig): GoldenLayoutConfig
    resolve*: proc(config: GoldenLayoutConfig): GoldenLayoutResolvedConfig

  GoldenLayoutItemConfigClass* = ref object of js
    resolve*: proc(config: GoldenLayoutConfig): GoldenLayoutResolvedConfig

  GoldenLayoutConfig* = ref object of js
    `type`*: cstring
    componentName*: cstring
    componentState*: GoldenItemState
    content*: seq[GoldenContentItem]

  GoldenLayoutResolvedConfig* = ref object of js

  GoldenLayout* = ref object of js
    loadLayout*:        proc(layoutConfig: GoldenLayoutResolvedConfig)
    saveLayout*:        proc(): GoldenLayoutResolvedConfig
    groundItem*:        GoldenContentItem
    registerComponent*: proc(name: cstring, factoryFunction: proc(container: GoldenContainer, state: GoldenItemState))
    newItem*:           proc(config: js): GoldenContentItem
    newItemAtLocation*: proc(config: js, locationSelectors: seq[GoldenLayoutLocationSelector]): GoldenContentItem
    createAndInitContentItem*: proc(resolvedConfig: GoldenLayoutResolvedConfig, parent: GoldenContentItem): GoldenContentItem

  GoldenLayoutLocationsSelectorTypeId* = enum
    FocusedItem,
    FocusedStack,
    FirstStack,
    FirstRowOrColumn,
    FirstRow,
    FirstColumn,
    Empty,
    Root

  GoldenLayoutLocationSelector* = ref object of js
    typeId*: GoldenLayoutLocationsSelectorTypeId
    index*: int

  GoldenTab* = ref object of js
    contentItem*:          GoldenContentItem
    titleElement*:         JsObject
    element*:              JsObject

  GoldenContent* = ref object of js
    container*:           GoldenContainer

  GoldenContainer* = ref object of js
    isHidden*:   bool
    tab*:        JsObject
    getElement*: proc(): JsObject

  GoldenContentItem* =     ref object
    container*:            GoldenContainer
    componentState*:       GoldenItemState
    contentItems*:         seq[GoldenContentItem]
    parent*:               GoldenContentItem
    tab*:                  GoldenTab
    isComponent*:          bool
    isStack*:              bool
    toggleMaximize*:       proc()
    remove*:               proc()
    setSize*:              proc(width: int, height: int)
    popout*:               proc()
    addItem*:              proc(itemConfig: js, index: int = 0): int
    addChild*:             proc(child: GoldenContentItem, index: int = 0, suspendResize: bool = false): int
    removeChild*:          proc(child: GoldenContentItem)
    undisplayChild*:       proc(child: GoldenContentItem)
    getActiveContentItem*: proc(): GoldenContentItem
    setActiveContentItem*: proc(contentItem: GoldenContentItem)
    toConfig*: proc(): GoldenLayoutResolvedConfig

  GoldenItemState* = ref object
    id*: int
    name*: cstring
    label*: cstring
    content*: Content
    fullPath*: cstring
    isEditor*: bool
    editorView*: EditorView
    lang*: Lang
    noInfoMessage*: cstring

  Component* = ref object of RootObj
    data*: Data
    isDbBasedTrace*: bool
    config*: Config
    id*: int
    rendered*: bool
    rrTicks*: int
    readOnly*: js
    content*: Content
    layoutItem*: GoldenContentItem
    kxi*: KaraxInstance
    inExtension*: bool
    api*: MediatorWithSubscribers
    location*: Location
    stableBusy*: bool

  DataTableComponent* = ref object
    context*: js
    rowsCount*: int
    startRow*: int
    endRow*: int
    scrollAreaHeight*: int
    rowHeight*: int
    activeRowIndex*: int
    autoScroll*: bool
    inputFieldChange*: bool
    footerDom*: kdom.Element

  EventLogComponent* = ref object of Component
    init*:          bool
    denseTable*:     DataTableComponent
    detailedTable*:  DataTableComponent
    drawId*:         int
    tableCallback*: proc(data: js)
    autoScrollUpdate*: bool
    isDetailed*:   bool
    kinds*: JsAssoc[EventLogKind, bool]
    columns*: JsAssoc[EventOptionalColumn, bool]
    tags*: JsAssoc[EventTag, bool]
    kindsEnabled*: JsAssoc[EventLogKind, bool]
    redrawColumns*: bool
    index*: int
    eventsIndex*:   int
    service*:       EventLogService
    dropDowns*: array[EventDropDownBox, bool]
    focusedDropDowns*: array[EventDropDownBox, bool]
    selectedKinds*: array[EventLogKind, bool]
    isOptionalColumnsMenuOpen*: bool
    resizeObserver*: ResizeObserver
    traceRenderedLength*: int
    traceService*:  TraceService
    traceSessionID*: int
    traceUpdateID*:  int
    rowSelected*: int
    activeRowTicks*:  int
    hiddenRows*: int
    lastJumpFireTime*: int64
    isFlowUpdate*: bool
    started*: bool
    ignoreOutput*: bool
    programEvents*: seq[ProgramEvent]


  DebugComponent* = ref object of Component
    service*:       DebuggerService
    message*:       LogMessage
    # TODO dropdown
    after*: bool
    before*: bool
    listHistory*: bool
    fullHistory*: bool
    historyIndex*: int
    usingContextMenu*: bool
    historyDirection*: bool
    activeHistory*: cstring
    finished*: bool
    jumpHistory*: seq[JumpHistory]



  ChartComponent* = ref object of Component
    tableView*:     proc: VNode
    viewKind*:      ViewKind
    stateID*:       int
    line*:          js
    lineConfig*:    js
    pie*:           js
    pieConfig*:     js
    changed*:       bool
    trace*:         TraceComponent
    datasets*:      seq[JsObject]
    pieDatasets*:   seq[JsObject]
    pieLabels*:     seq[cstring]
    pieValues*:     seq[float]
    lineLabels*:    seq[cstring]
    lineDatasetIndices*: JsAssoc[cstring, int]
    pieDatasetIndices*: JsAssoc[cstring, int]
    lineDatasetValues*:  JsAssoc[cstring,seq[Value]]
    results*:       seq[float]
    expression*:    cstring
    expressions*:   seq[cstring]
    chartId*:       int
    kindSelectorIsClicked*: bool
    historyScrollTop*: int

  ValueComponent* = ref object of Component
    expanded*:           JsAssoc[cstring, bool]
    state*:              StateComponent
    showInline*:         JsAssoc[cstring, bool]
    baseValue*:          Value
    baseExpression*:     cstring
    charts*:             JsAssoc[cstring, ChartComponent]
    i*:                  int
    fresh*:              bool
    freshIndex*:         int
    stateID*:            int
    selected*:           bool
    nameWidth*:          float
    valueWidth*:         float
    customRedraw*:       proc(self: ValueComponent): void
    isTooltipValue*:     bool
    isScratchpadValue*:  bool
    isOperationRunning*: bool
    historyScrollTop*:   int

  ScratchpadComponent* = ref object of Component
    i*:             int
    programValues*:   seq[(cstring, Value)]
    values*:        seq[ValueComponent]
    service*:       DebuggerService
    locals*:        seq[Variable]

  TimelineMode* = enum TimelineVariables, TimelineRegisters

  TimelineComponent* = ref object of Component
    views*:         array[TimelineMode, Component]
    active*:        TimelineMode
    flow*:          FlowUpdate
    service*:       FlowService

  # TimelineVariablesComponent* = ref object of Component
  #   timeline*:      TimelineComponent
  #   service*:       FlowService

  # TimelineRegistersComponent* = ref object of Component
  #   timeline*:      TimelineComponent
  #   service*:          FlowService

  FilesystemComponent* = ref object of Component
    files*:         JsAssoc[cstring, CodetracerFile]
    initFilesystem*: bool
    service*:       EditorService
    forceRedraw*:   bool

  ViewKind* =       enum ViewTable, ViewLine, ViewPie

  StateComponent* = ref object of Component
    isState*:       bool
    watchExpressions*: seq[cstring]
    valueHistory*:  JsAssoc[cstring, ValueHistory]
    i*:             int
    inState*:       bool
    locals*:        seq[Variable]
    values*:        JsAssoc[cstring, ValueComponent]
    completeMoveIndex*: int
    nameWidth*:     float
    valueWidth*:    float
    chevronClicked*: bool
    minNameWidth*: float # %
    maxNameWidth*: float # %
    totalValueWidth*: float # %

  CallExpandedValuesComponent* = ref object of Component
    values*:        JsAssoc[cstring, ValueComponent]
    depth*:         int
    backIndentCount*: int
    callHasChildren*: bool
    callIsLastChild*: bool
    callIsCollapsed*: bool
    callIsLastElement*: bool

  CalltraceLineKind* = enum LineCall, LineHiddenCallstack, LineHiddenCalls

  CalltraceLine* = ref object
    kind*: CalltraceLineKind
    call*: Call

  CalltraceComponent* = ref object of Component
    callstack*:             seq[Call] # the names of the functions
    searchResults*: seq[Call]
    lastChange*: BiggestInt
    lastSearch*: BiggestInt
    lastQuery*: cstring
    expandedValues*: JsAssoc[cstring, CallExpandedValuesComponent]
    callLines*: seq[CallLine]
    originalCallLines*: seq[CallLine]
    args*: JsAssoc[cstring, seq[CallArg]] # location key
    returnValues*: JsAssoc[cstring, Value]
    lastSelectedCallKey*: cstring
    rawIgnorePatterns*: cstring
    lineIndex*: JsAssoc[cstring, int]
    callsByLine*: seq[CalltraceLine]
    selectedCallNumber*: int
    isSearching*: bool
    searchText*: cstring
    # call key => index in rendered call lines
    # including between potential non-expanded info lines
    loadedCallKeys*: JsAssoc[cstring, int]
    totalCallsCount*: int
    startCallLineIndex*: int
    activeCallIndex*:       int
    lastScrollFireTime*: int64
    forceCollapse*: bool
    depthStart*: int
    coordinates*: seq[(float, float, float)]
    startPositionX*: float
    startPositionY*: float
    scrollLeftOffset*: float
    callValuePosition*: JsAssoc[cstring, float]
    width*: cstring
    resizeObserver*: ResizeObserver
    isCalltrace*: bool

    debugger*:       DebuggerService
    service*:        CalltraceService
    modalValueComponent*: JsAssoc[cstring, ValueComponent]
    forceRerender*: JsAssoc[cstring, bool]

  StepListComponent* = ref object of Component
    lineSteps*: seq[LineStep]
    # startStepLineIndex*: int
    # totalStepsCount*: int
    # lastScrollFireTime*: int64
    service*: FlowService

  LowLevelCodeComponent* = ref object of Component
    editor*: EditorViewComponent
    instructionsMapping*: JsAssoc[int, int]
    viewZones*: JsAssoc[int, int]
    multilineZones*: JsAssoc[int, MultilineZone]
    viewDom*: JsAssoc[int, kdom.Node]
    mutationObserver*: MutationObserver
    path*: cstring
    partialTabInfo*: TabInfo

  EditorViewComponent* = ref object of Component
    editorView*:     EditorView
    path*:           cstring
    line*:           int
    name*:           cstring
    lang*:           Lang
    tokens*:         JsAssoc[int, JsAssoc[cstring, int]]
    decorations*:    seq[(DeltaDecoration, bool)]
    whitespace*:     Whitespace
    encoding*:       cstring
    # monacoJsonSchemes*: JsAssoc[cstring, js]
    monacoEditor*:   MonacoEditor
    contentItem*:    GoldenTab
    lastMouseMoveLine*: int
    lastMouseClickCol*:  int
    lastMouseClickLine*: int
    viewZone*:       JsObject
    topLevelEditor*: EditorViewComponent
    zoneId*:        int
    isExpanded*:    bool # zone expanded
    isExpansion*:   bool # is an expansion editor
    parentLine*:    int
    renderer*:      KaraxInstance
    tabInfo*:       TabInfo
    flowUpdate*:    FlowUpdate
    flow*:          FlowComponent
    traces*:        JsAssoc[int, TraceComponent]
    expanded*:      JsAssoc[int, EditorViewComponent]
    noInfo*:        NoSourceComponent
    service*:       EditorService
    currentTooltip*: (int, int, int)
    viewZones*:     JsAssoc[int, int]
    shouldLoadFlow*: bool
    lastScrollFireTime*: int64
    diffViewZones*: JsAssoc[int, MultilineZone]
    diffAddedLines*: seq[int]
    diffEditors*: JsAssoc[int, MonacoEditor]

  # LowLevelComponent* = ref object of Component
    # levels*:        array[LowLevelView, LLViewComponent]

  # LLViewComponent* = ref object of Component
    # view*:          LowLevelView
    # tab*:           LowLevelTab
    # contentItem*:   GoldenTab
    # service*:       EditorService


  # LLMonacoComponent* = ref object of LLViewComponent
    # monacoEditor*:  MonacoEditor
    # decorations*:   seq[cstring]

  # LLSourceComponent* = ref object of LLMonacoComponent


    # contentItem*:   GoldenTab
    # service*:       EditorService

  # LLInstructionsComponent* = ref object of LLMonacoComponent
    # functionName*:  cstring
    # instructions*:  seq[Instruction]
    # contentItem*:   GoldenTab
    # service*:       EditorService
  MonacoEditorPosition* = object of RootObj
    lineNumber*: float
    column*:     float

  TraceComponent* = ref object of Component
    expanded*:      bool
    line*:          int
    name*:          cstring
    tableCallback*: proc(data: js)
    drawId*:        int
    locals*:        seq[seq[(langstring, Value)]]
    m*:             KaraxInstance
    zoneId*:                int
    newZoneId*:             int
    dataTable*:             DataTableComponent
    # editorId*:              int
    viewZone*:              js
    indexInSession*:        int
    isDisabled*:            bool
    forceReload*:           bool
    isRan*:                 bool
    showSettings*:          bool
    showSearch*:            bool
    error*:                 DebuggerError
    monacoEditor*:          MonacoEditor
    source*:                cstring
    selectorId*:            cstring
    isChanged*:             bool
    loggedSource*:          cstring
    isUpdating*:            bool
    isLoading*:             bool
    isReached*:             bool
    editorWidth*:           float
    splitterClicked*:       bool
    chevronPosition*:       int
    traceHeight*:           float
    traceWidth*:            int
    hamburgerButton*:       kdom.Element
    hamburgerDropdownList*: kdom.Element
    overlayDom*:            kdom.Element
    resultsOverlayDom*:     kdom.Element
    kindSwitchButton*:      kdom.Element
    kindSwitchDropDownList*:kdom.Element
    chartTableDom*:          kdom.Element
    chartLineDom*:          kdom.Element
    chartPieDom*:           kdom.Element
    runTraceButtonDom*:     kdom.Element
    searchInput*:           kdom.Element
    traceViewDom*:          kdom.Element
    lineCount*:             int
    resultsHeight*:         int

    chart*:         ChartComponent
    tracepoint*:    Tracepoint
    editorUI*:      EditorViewComponent
    modalValueComponent*: ValueComponent
    service*:       TraceService

    resizeObserver*: ResizeObserver
    mouseIsOverTable*: bool

  FlowLoopBackgroundStyleProps* = ref object
    top*: int
    left*: int
    width*: int
    height*: float

  FlowLoopBackground* = ref object
    dom*: kdom.Node
    backgroundProps*: FlowLoopBackgroundStyleProps
    maxWidth*: int

  LoopViewState* = enum LoopInitial, LoopValues, LoopShrinked, LoopContinuous

  LoopState* = ref object
    legendWidth*: int
    minWidth*: int
    maxWidth*: int
    totalLoopWidth*: int
    defaultIterationWidth*: int
    maxPositionValuesChars*: int
    iterationsWidth*: JsAssoc[int, float]
    sumOfPreviousIterations*: JsAssoc[int, float]
    positions*: JsAssoc[int, LoopPosition]
    containerDoms*: JsAssoc[int, kdom.Node]
    viewState*: LoopViewState
    viewStateChangesCount*: int
    sliderIteration*: int
    activeIteration*: int
    containerOffset*: float
    focused*: bool
    background*: FlowLoopBackground
    backgroundHeight*: float

  PositionColumn* = ref object
    iteration*: int
    positionMaxValuesChars*: int
    valuesExpressions*: JsAssoc[cstring, ExpressionColumn]
    valueGapPercentage*: float

  LoopPosition* = ref object
    positionColumns*: JsAssoc[int, PositionColumn]
    loopIndex*: int
    expressionsChars*: int
    legendValueGapPercentage*: float
    # add all info from flowLines for loops

  ExpressionColumn* = ref object
    expressionCharacters*: int
    expressionLegendPercent*: float
    valueCharsCount*: int
    valuePercent*: float

  LegendColumn* = ref object
    width*: int
    positions*: JsAssoc[int, PositionColumn]

  FlowBufferKind* = enum FlowLineBuffer, FlowLoopBuffer
  FlowBuffer* = ref object
    domElement*: kdom.Node
    initialSize*: int
    size*: int
    case kind*: FlowBufferKind:
    of FlowLineBuffer:
      position*: int
      firstLoopId*: int
      loopIds*: seq[int]
    of FlowLoopBuffer:
      loopId*: int
      firstIteration*: int
      iterations*: seq[int]

  FlowLineContainerStyleProps* = ref object
    left*: int
    width*: int
    height*: int

  FlowLine* = ref object
    startBuffer*: FlowBuffer
    endBuffer*: FlowBuffer
    firstLoopId*: int
    firstIteration*: int
    number*:  int
    baseOffsetleft*: int
    offsetLeft*: float
    totalLineWidth*: int
    indentationsCount*: int
    variablesPositions*: JsAssoc[cstring, int]
    sortedVariables*: JsAssoc[cstring, Value]
    decorationsIds*: seq[cstring]
    decorationsDoms*: JsAssoc[cstring, kdom.Node]
    stepLoopCells*: JsAssoc[int, JsAssoc[int, kdom.Node]]
    loopContainers*: JsAssoc[int, kdom.Node]
    iterationContainers*: JsAssoc[int, kdom.Node]
    mainLoopContainer*: kdom.Node
    loopIds*: seq[int]
    activeLoopIteration*: tuple[loopIndex: int, iteration: int]
    activeIterationPosition*: float
    sliderDom*: kdom.Node
    sliderPosition*: tuple[loopIndex: int, iteration: int]
    sliderPositions*: seq[int]
    contentWidget*: kdom.Node
    legendDom*: kdom.Node
    loopStepCounts*: JsAssoc[int, seq[int]]

  FlowLoop* = ref object
    flowDom*: kdom.Node
    flowZones*: MultilineZone
    sliderDom*: kdom.Node
    loopStep*: FlowStep

  FlowComponent* = ref object of Component
    bufferMaxOffsetInPx*: int
    distanceBetweenValues*: int
    distanceToSource*: int
    editor*: EditorService
    editorUI*: EditorViewComponent
    focusedLine*: int
    flow*: FlowViewUpdate
    flowLines*: JsAssoc[int, FlowLine]
    flowViewWidth*: int
    flowLoops*: JsAssoc[int, FlowLoop]
    lineHeight*: int
    fontSize*: int
    shouldRecalcFlow*: bool
    flowDom*: JsAssoc[int, kdom.Node]
    activeStep*: FlowStep
    groups*: seq[Group]
    inlineFlowVariables*: JsAssoc[int, JsAssoc[cstring, KaraxInstance]]
    inlineDecorations*: JsAssoc[int, InlineDecorations]
    inlineValueWidth*: int
    key*: cstring
    lastSliderUpdateTimeInMs*: int64
    lineGroups*: JsAssoc[int, Group]
    lineWidgets*: JsAssoc[int, js]
    loopColumnMinWidth*: int
    loopLineSteps*: JsAssoc[int, int]
    loopStates*: JsAssoc[int, LoopState]
    maxLoopActiveIterationOffset*: float
    maxFlowLineWidth*: int
    multilineFlowLines*: JsAssoc[int, KaraxInstance]
    multilineValuesDoms*: JsAssoc[int, JsAssoc[cstring, kdom.Node]]
    multilineWidgets*: JsAssoc[int, JsAssoc[cstring, js]]
    multilineZones*: JsAssoc[int, MultilineZone]
    mutationObserver*: MutationObserver
    pixelsPerSymbol*: int
    recalculate*: bool
    scratchpadUI*: ScratchpadComponent
    selected*: bool
    selectedLine*: int
    selectedLineInGroup*: int
    selectedGroup*: Group
    selectedIndex*: int
    selectedStepCount*: int
    service*: FlowService
    shrinkedLoopColumnMinWidth*: int
    sliderWidgets*: JsAssoc[int, js]
    status*: FlowUpdateState
    statusDom*: kdom.Node
    statusWidget*: js
    stepNodes*: JsAssoc[int, kdom.Node]
    tab*: TabInfo
    valueMode*: ValueMode
    viewZones*: JsAssoc[int, int]
    loopViewZones*: JsAssoc[int, int]
    width*: int
    maxWidth*: int
    tooltipId*: cstring
    modalValueComponent*: JsAssoc[cstring, ValueComponent]
    tippyElement*: JsObject
    leftPos*: cstring
    lastScrollFireTime*: int64
    # codeID*: int64



  XTermBufferNamespace* = ref object
    normal*: XTermBuffer

  XTermBuffer* = ref object
    cursorY*: int
    length*: int
    viewportY*: int

  XtermJsLib* = ref object
    Terminal*: Terminal

  TerminalIEvent* = ref object
    key*: cstring
    domEvent*: dom.KeyboardEvent
    cols*: int
    rows*: int

  TerminalDimensions* = ref object
    rows*: int
    cols*: int

  RenderEvent* = ref object
    start*: int
    `end`*: int

  TerminalAddon* = ref object of RootObj

  XtermFitAddon* = ref object of TerminalAddon

  XtermFitAddonLib* = ref object
    FitAddon*: XtermFitAddon

  ShellBuffer* = ref object
    viewportY*: int

  ShellTheme* = ref object
    background*: cstring
    foreground*: cstring

  TerminalOptions* = ref object
    theme*: ShellTheme

  Terminal* {.importc.} = ref object
    allowProposedApi*: bool
    buffer*: XTermBufferNamespace
    cols*: int
    lineHeight*: int
    prompt*: proc(): void
    rendererType*: cstring
    rows*: int
    write*: proc(data: cstring): void
    options*: TerminalOptions
    theme*: ShellTheme

  ShellComponent* = ref object of Component
    lineHeight*: int
    shell*: Terminal
    gutterDom*: kdom.Node
    events*: JsAssoc[int, JsAssoc[int, SessionEvent]]
    eventContainers*: JsAssoc[int, kdom.Node]
    eventsDoms*: JsAssoc[int, kdom.Node]
    progressOffset*: int
    rowIsClicked*: bool
    clickedRow*: int
    buffer*: ShellBuffer
    themes*: JsAssoc[cstring, ShellTheme]

  RecordStatusKind* = enum RecordInit, InProgress, RecordError, RecordSuccess
  RecordStatus* = ref object
    kind*: RecordStatusKind
    errorMessage*: cstring

  NewDownloadRecord* = ref object
    args*: seq[cstring]
    status*: RecordStatus

  NewTraceRecord* = ref object
    kit*: cstring
    executable*: cstring
    args*: seq[cstring]
    workDir*: cstring
    runInTerminal*: bool
    breakAtMain*: bool
    debugInfo*: cstring
    recent*: cstring
    status*: RecordStatus
    pid*: cstring
    outputFolder*: cstring
    defaultOutputFolder*: bool
    formValidator*: RecordScreenFormValidator

  RecordScreenFormValidator* = ref object
    validExecutable*: bool
    invalidExecutableMessage*: cstring
    validWorkDir*: bool
    invalidWorkDirMessage*: cstring
    validOutputFolder*: bool
    invalidOutputFolderMessage*: cstring
    requiredFields*: JsAssoc[cstring, bool]


  WelcomeScreenOption* = ref object
    name*: cstring
    command*: proc: void
    hovered*: bool
    inactive*: bool # grayed out by default (lower opacity)

  MessageKind* = enum UploadError, DeleteError, ResetMessage

  WelcomeScreenComponent* = ref object of Component
    options*: seq[WelcomeScreenOption]
    welcomeScreen*: bool
    newRecordScreen*: bool
    openOnlineTrace*: bool
    newRecord*: NewTraceRecord
    newDownload*: NewDownloadRecord
    loading*: bool
    loadingTrace*: Trace
    recentTracesScroll*: int
    copyMessageActive*: JsAssoc[int, bool]
    infoMessageActive*: JsAssoc[int, bool]
    errorMessageActive*: JsAssoc[int, MessageKind]
    isUploading*: JsAssoc[int, bool]
    showTraceSharing*: bool

  ReplComponent* = ref object of Component
    history*: seq[DebugInteraction]
    service*: DebuggerService

  ValueMode* = enum BeforeAndAfterValueMode, BeforeValueMode, AfterValueMode

  MultilineZone* = ref object
    dom* : kdom.Node
    expanded*: bool
    zoneID*: int
    variables*: JsAssoc[cstring, bool]

  InlineZone* = ref object
    line*: int
    column*: int
    length*: int

  InlineDecorations* = ref object
    # expanded*: bool
    # variables*: JsAssoc[cstring, InlineDecoration]
    identifiers*: seq[cstring]

  InlineDecoration* = ref object
    expanded*: bool
    decoration*: DeltaDecoration

  BuildComponent* = ref object of Component
    build*: Build
    builds*: seq[Build]
    expanded*: bool
    service*: DebuggerService

  ErrorsComponent* = ref object of Component
    errors*: seq[(Location, cstring)]
    expanded*: bool
    service*: DebuggerService

  SearchResultsComponent* = ref object of Component
    query*: cstring
    includePattern*: cstring
    excludePattern*: cstring
    findQuery*: cstring
    results*: seq[SearchResult]
    active*: bool
    service*: SearchService

  CommandPaletteComponent* = ref object of Component
    active*:  bool
    query*: SearchQuery
    prevCommandValue*: cstring
    queries*: seq[string]
    activeCommandName*: cstring
    selected*: int
    interpreter*: CommandInterpreter
    results*: seq[CommandPanelResult]
    inputField*: dom.Node
    inputValue*: cstring
    inputPlaceholder*: cstring

  NoSourceComponent* = ref object of Component
    message*: cstring
    instructions*: Instructions
    state*: VNode

  MenuComponent* = ref object of Component
    active*: bool
    activeDomElement*: dom.Node
    elements*: MenuData
    activePath*: seq[int]
    activePathWidths*: JsAssoc[int, int]
    activePathOffsets*: JsAssoc[int, int]
    prepared*: seq[js]
    searchResults*: seq[cstring]
    nameMap*: JsAssoc[cstring, ClientAction]
    activeIndex*: int
    activeSearchIndex*: int
    activeLength*: int
    searchQuery*: cstring
    debug*: DebugComponent
    service*: EditorService
    iconWidth*: int
    mainMenuWidth*: int
    folderArrowCharWidth*: int
    search*: bool
    keyNavigation*: bool

  TraceLogComponent* = ref object of Component
    table*: DataTableComponent
    renderedLength*: int
    service*: TraceService
    resizeObserver*: ResizeObserver
    traceSessionID*: int
    traceUpdateID*:  int

  MenuData* = ref object
    node*:    MenuNode


  MenuNodeOS* = enum
    MenuNodeOSAny       = 0,
    MenuNodeOSMacOS     = 1 shl 0,
    MenuNodeOSNonMacOS  = 1 shl 1,
    MenuNodeOSHost      = 1 shl 2,
    MenuNodeOSNonHost   = 1 shl 3,
    MenuNodeOSMax       = ord(MenuNodeOSMacOS) or ord(MenuNodeOSNonMacOS) or ord(MenuNodeOSHost) or ord(MenuNodeOSNonHost)

  MenuNodeKind* = enum MenuFolder, MenuElement

  MenuNode* = ref object
    name*:                  cstring
    action*:                ClientAction
    enabled*:               bool
    kind*:                  MenuNodeKind
    elements*:              seq[MenuNode]
    isBeforeNextSubGroup*:  bool
    menuOs*:                int
    role*:                  cstring

  StatusComponent* = ref object of Component
    build*: BuildComponent
    errors*: ErrorsComponent
    notifications*: seq[Notification]
    maxNotificationsCount*: int
    showNotifications*: bool
    activeNotificationDuration*: int
    searchResults*: SearchResultsComponent
    versionControlBranch*: cstring
    service*: DebuggerService
    flowMenuIsOpen*: bool
    showBugReport*: bool
    copyMessageActive*: bool
    completeMoveId*: int
    stopSignal*: RRGDBStopSignal
    state*: StatusState

  CalltraceEditorComponent* = ref object of Component
    loading*:   JsAssoc[cstring, bool]
    service*:   EditorService
    calltrace*: CalltraceService

  TerminalEvent* = ref object
    text*: cstring
    eventIndex*: int

  TerminalOutputComponent* = ref object of Component
    cachedLines*: JsAssoc[int, seq[TerminalEvent]]
    cachedEvents*: seq[ProgramEvent]
    lineEventIndices*: JsAssoc[int, int]
    service*:     EventLogService
    renderedEventIndex*: int
    currentLine*:    int
    initialUpdate*:  bool

  LayoutSizes* = ref object
    normalSize*: float
    filesystemSize*: float
    lowLevelCodeSize*: float
    editorSize*: float
    othersSize*: float
    startSize*: bool

  ComponentConcept* = concept a
    a.restart() is void

  Services* = ref object
    eventLog*:      EventLogService
    calltrace*:     CalltraceService
    trace*:         TraceService
    tab*:           TabService
    debugger*:      DebuggerService
    history*:       HistoryService
    editor*:        EditorService
    flow*:          FlowService
    search*:        SearchService
    shell*:         ShellService

  Components* = ref object
    welcomeScreen*:  WelcomeScreenComponent
    editors*:        JsAssoc[cstring, EditorViewComponent] # ast! ir kind etc
    status*:         StatusComponent
    searchResults*:  SearchResultsComponent
    menu*:           MenuComponent
    commandPalette*: CommandPaletteComponent
    idMap*:          JsAssoc[cstring, int] # inside editor => traces, flows
    lastRedraw*:     int64
    componentMapping*:  array[Content, JsAssoc[int, Component]]
    layoutConfig*:   GoldenLayoutConfigClass
    contentItemConfig*: GoldenLayoutItemConfigClass
    resolvedConfig*: GoldenLayoutResolvedConfig
    layout*:         GoldenLayout
    mode*:           LayoutMode
    readOnly*:       bool
    # not the same: we might want DebugMode layout with readonly off soon
    # or readonly editor to browse
    layoutSizes*:    LayoutSizes
    activeFocus*:    Component
    contentViews*:   array[Content, proc: VNode]
    fontSize*:       int
    monacoEditors*:  seq[MonacoEditor]
    traceMonacoEditors*: seq[MonacoEditor]
    hasLowLevelTabs*: bool
    editorPanels*:    array[EditorView, GoldenContentItem]
    activeEditorPanel*: GoldenContentItem
    openViewOnCompleteMove*: array[EditorView, bool]
    openComponentIds*:        array[Content, seq[int]]
    saveLayout*:     bool
    menuNode*: MenuNode
    pageLoaded*: bool
    initEventReceived*: bool
    focusHistory*: seq[JsObject]


  ClientActionHandler* = proc: void {.nimcall.}

  Data* = ref object
    dapApi*:                DapApi
    viewsApi*:              MediatorWithSubscribers
    services*:              Services
    ui*:                    Components
    redraw*:                proc: void
    ipc*:                   JsObject
    network*:               Network
    asyncSendCache*:        JsAssoc[cstring, JsAssoc[cstring, Future[JsObject]]]
    config*:                Config
    trace*:                 Trace
    startOptions*:          StartOptions
    lastNoInfoMessage*:     cstring
    functions*:             Functions
    actions*: array[ClientAction, ClientActionHandler]
    contentActions*: array[ClientAction, array[Content, proc(data: Data): void]]
    keyPlugins*:            array[Content, JsAssoc[cstring, proc(context: KeyPluginContext): Future[void]]]
    recentProjects*:        seq[Project]
    recentTraces*:          seq[Trace]
    stylusTransactions*:    seq[StylusTransaction]
    pointList*:             PointListData
    minRRTicks*:            int
    maxRRTicks*:            int
    breakpointMenu*:        JsAssoc[cstring, JsAssoc[int, BreakpointMenu]]
    connection*:            ConnectionState

    # FrontendTestRunner, but i(alexander) don't want
    # to depend on the frontend test code here
    # so we use casting in ui_js.nim/similar for it
    testRunner*:            JsObject

    save*:                  Save
    homedir*:               cstring
    status*:                StatusState


  KeyPluginContext* = ref object
    ## "" / -1 might mean no valid word info for that position
    path*:    cstring
    line*:    int
    column*:  int
    startColumn*: int
    endColumn*: int
    word*:    cstring
    data*:    Data

  # workaround for calling data ui_js functions: their impls are be defined there to be able to eventually use
  # services and components, but we need to call them sometimes in components/services
  Functions* = object
    toggleMode*:     proc(data: Data): void
    update*:         proc(data: Data, build: bool): void
    switchToDebug*:    proc(data: Data): void
    switchToEdit*:     proc(data: Data): void
    focusEventLog*:    proc(data: Data): void
    focusCalltrace*:   proc(data: Data): void
    focusEditorView*:      proc(data: Data): void

  Network* = ref object
    futures*:               JsAssoc[cstring, JsAssoc[cstring, JsObject]] # easier to type, but they are futures of different types, we use type only in asyncSend?

  PointListData* = ref object
    init*: bool
    breakpointTable*: js
    tracepointTable*: js
    lastBreakpoint*: int
    lastTracepoint*: int
    breakpoints*: seq[UIBreakpoint]
    tracepoints*: JsAssoc[int, Tracepoint]
    redrawBreakpoints*: bool
    redrawTracepoints*: bool

  Build* = object
    output*: seq[(cstring, bool)]
    errors*: seq[(Location, cstring, cstring)]
    code*:   int
    running*: bool
    command*: cstring

  BuildOutput* = object
    data*:    cstring

  BuildCommand* = object
    command*: cstring

  BuildCode* = object
    code*: int

  OpenedTab* = object
    path*: cstring
    lang*: Lang

  SearchResult* = object
    text*:      cstring
    path*:      cstring
    line*:      int
    customFields*: seq[cstring]
    # names are in SearchSource

  FlowConfigObjWrapper* = object
    enabled*: bool
    ui*: cstring
    realFlowUI*: FlowUI

  TraceSharingConfigObj* = object
    enabled*:             bool
    baseUrl*:             cstring
    getUploadUrlApi*:     cstring
    downloadApi*:         cstring
    deleteApi*:           cstring

  Config* = ref object
    # The config object is the schema for config yaml files
    # keep it in sync with common/config.nim definition
    theme*:                   cstring
    version*:                 cstring
    flow*:                    FlowConfigObjWrapper
    callArgs*:                bool
    history*:                 bool
    repl*:                    bool
    trace*:                   bool
    default*:                 cstring
    calltrace*:               bool
    layout*:                  cstring
    telemetry*:               bool
    test*:                    bool
    debug*:                   bool
    events*:                  bool
    bindings*:                InputShortcutMap
    shortcutMap*:             ShortcutMap
    defaultBuild*:            cstring
    showMinimap*:             bool
    traceSharing*:            TraceSharingConfigObj
    skipInstall*:             bool
    rrBackend*:               RRBackendConfig

  RRBackendConfig* = ref object
    enabled*: bool
    path*: cstring

  BreakpointSave* = ref object of js
    # Serialized breakpoint
    line*:   int
    path*:   int

  Layout* = ref object
    # a wrapper
    # sys*: SysConfig

when defined(ctRenderer):
  import
    std / jsconsole,
    .. / common / ct_event

  type
    LocalToViewsTransport* = ref object of Transport
      data*: Data

  proc newFlowUpdate*: FlowUpdate

  proc newLocalToViewsTransport(data: Data): LocalToViewsTransport =
    LocalToViewsTransport(data: data)

  proc setupSinglePageViewsApi(name: cstring): MediatorWithSubscribers =
    # let transport = newLocalToViewsTransport(data)
    let x = Transport()
    newMediatorWithSubscribers(name, isRemote=true, singleSubscriber=false, transport=x)

  var data* = Data(
    dapApi: DapApi(),
    viewsApi: setupSinglePageViewsApi(cstring"single-page-frontend-to-views"),
    connection: ConnectionState(
      connected: true,
      reason: ConnectionLossNone,
      detail: cstring""
    ),
    status: StatusState(
      lastDirection: DebForward,
      currentOperation: cstring"",
      currentHistoryOperation: cstring"",
      finished: false,
      stableBusy: true,
      historyBusy: false,
      traceBusy: false,
      hasStarted: false,
      lastAction: cstring"",
      operationCount: 0,
    ),
    services: Services(
      eventLog: EventLogService(),
      debugger: DebuggerService(
        locals: @[],
        registerState: JsAssoc[cstring, cstring]{},
        breakpointTable: JsAssoc[cstring, JsAssoc[int, UIBreakpoint]]{},
        valueHistory: JsAssoc[cstring, ValueHistory()]{},
        paths: @[],
        skipInternal: true,
        skipNoSource: false,
        historyIndex: 1,
        showInlineValues: true),
      editor: EditorService(
        open: JsAssoc[cstring, TabInfo]{},
        loading: @[],
        completeMoveResponses: JsAssoc[cstring, MoveState]{},
        closedTabs: @[],
        saveHistoryTimeoutId: -1,
        switchTabHistoryLimit: 2000,
        # lowLevelTabs: JsAssoc[cstring, LowLevelTab]{},
        # lowLevel: LowLevel(),
        expandedOpen: JsAssoc[cstring, TabInfo]{},
        cachedFiles: JsAssoc[cstring, TabInfo]{},
        addedDiffId: @[],
        changedDiffId: @[],
        deletedDiffId: @[],
        index: 1),
      calltrace: CalltraceService(
        callstackCollapse: (name: cstring"", level: -1),
        callstackLimit: CALLSTACK_DEFAULT_LIMIT,
        calltraceJumps: @[cstring""],
        nonLocalJump: true,
        isCalltrace: true,
        loadingArgs: initJsSet[cstring]()),
      history: HistoryService(),
      flow: FlowService(),
      trace: TraceService(),
      search: SearchService(
        # commandData: CommandData(),
        paths: JsAssoc[cstring, bool]{},
        pluginCommands: JsAssoc[cstring, SearchSource]{},
        activeCommandName: cstring"",
        selected: 0),
      shell: ShellService()),
    network: Network(
      futures: JsAssoc[cstring, JsAssoc[cstring, JsObject]]{}),
    startOptions: StartOptions(
      loading: true,
      screen: true,
      inTest: false,
      record: false,
      edit: false,
      name: cstring"",
      frontendSocket: SocketAddressInfo(),
      backendSocket: SocketAddressInfo(),
      idleTimeoutMs: 10 * 60 * 1_000),
    pointList: PointListData(
      tracepoints: JsAssoc[int, Tracepoint]{}),
    ui: Components(
      focusHistory: @[]
    ),
    breakpointMenu: JsAssoc[cstring, JsAssoc[int, BreakpointMenu]]{},
    maxRRTicks: 100_000) # TODO, not based on events which don't update? somehow record/send from record
    # TODO max for program, maybe min as well?

  console.log "data.dapApi"
  console.log data.dapApi

  console.log "data.viewsApi"
  console.log data.viewsApi

  data.dapApi.on(CtCompleteMove, proc(kind: CtEventKind, value: MoveState) =
    discard data.services.debugger.onCompleteMove(data.services.debugger, value)
    discard data.services.editor.onCompleteMove(data.services.editor, value))

  var domwindow {.importc: "window".}: JsObject
  domwindow.data = data

  method register*(self: Component, api: MediatorWithSubscribers) {.base.} =
    self.api = api

  # === LocalViewSubscriber:

  type
    LocalViewSubscriber* = ref object of Subscriber
      # viewApi*: MediatorWithSubscribers
      viewTransport*: Transport

  const logging* = true # TODO: maybe reuse/use a dynamic log level mechanism

  method emitRaw*(l: LocalViewSubscriber, kind: CtEventKind, value: JsObject, subscriber: Subscriber) =
    if logging: console.log cstring"webview subscriber emitRaw: ", cstring($kind), cstring" ", value
    l.viewTransport.internalRawReceive(CtRawEvent(kind: kind, value: value).toJs, subscriber)

  proc newLocalViewSubscriber(viewTransport: Transport): LocalViewSubscriber =
    LocalViewSubscriber(viewTransport: viewTransport)

  # === end


  # LocalViewToMiddlewareTransport:

  type
    LocalViewToMiddlewareTransport* = ref object of Transport
      # component*: JsObject
      middlewareToViewsTransport*: Transport

  method send(l: LocalViewToMiddlewareTransport, data: JsObject, subscriber: Subscriber) =
    l.middlewareToViewsTransport.internalRawReceive(data, subscriber)

  # internalRawReceive for this is called by the subscriber in the middleware

  proc newLocalViewToMiddlewareTransport(middlewareToViewsTransport: Transport): LocalViewToMiddlewareTransport =
    LocalViewToMiddlewareTransport(middlewareToViewsTransport: middlewareToViewsTransport)

  # === end

  proc setupLocalViewToMiddlewareApi*(name: cstring, middlewareToViewsApi: MediatorWithSubscribers): MediatorWithSubscribers =
    let transport = newLocalViewToMiddlewareTransport(middlewareToViewsApi.transport)
    result = newMediatorWithSubscribers(name, isRemote=true, singleSubscriber=true, transport=transport)
    result.asSubscriber = newLocalViewSubscriber(transport)

  proc registerComponent*(data: Data, component: Component, content: Content) =
    if data.ui.componentMapping[content].hasKey(component.id):
      echo fmt"WARNING: already having a component for {content} with id {component.id}"
    else:
      component.data = data
      component.content = content
      if not data.viewsApi.isNil and component.api.isNil:
        let componentToMiddlewareApi = setupLocalViewToMiddlewareApi(cstring(fmt"{content} #{component.id} api"), data.viewsApi)
        component.register(componentToMiddlewareApi)
      echo "register component ", content, " ", component.id
      data.ui.componentMapping[content][component.id] = component

  proc projectPath*(project: cstring, path: string): cstring =
    return data.startOptions.app & cstring("/") & project & cstring(path)

  proc newFlowUpdate*: FlowUpdate =
    FlowUpdate(
      # hits: JsAssoc[int, seq[int]]{},
      location: Location())
      # oldValues: JsAssoc[int, JsAssoc[int, JsAssoc[cstring, Value]]]{},
      # lastValues: JsAssoc[cstring, Value]{},
      # afterValues: JsAssoc[StepCount, JsAssoc[cstring, Value]]{},
      # beforeValues: JsAssoc[StepCount, JsAssoc[cstring, Value]]{},
      # stepCounts: StepCountSeq[PreloadStep](@[]),
      # loops: LoopIDSeq[Loop](@[]),
      # lineSteps: JsAssoc[int, LineStep]{},
      # loopIndex: 0)


template eecho*(s: untyped) =
  # eventual echo
  when IN_DEBUG:
    echo s
  else:
    discard

proc duration*(call: nil Call): int64 =
  # TODO
  0
  # if not call.isNil:
  #   delta(call.finishTime, call.startTime)
  # else:
  #   0

proc toCamelCase*(name: string): string =
  let tokens = name.split("-")
  tokens[0] & tokens[1..^1].mapIt(it.capitalizeAscii).join("")

method restart*(self: Component) {.base.} =
  discard

method clear*(self: Component) {.base.} =
  discard

method render*(self: Component): VNode {.base.} =
  discard

method onUp*(self: Component) {.base, async.} =
  discard

method onDown*(self: Component) {.base, async.} =
  discard

method onPageUp*(self: Component) {.base, async.} =
  discard

method onPageDown*(self: Component) {.base, async.} =
  discard

method delete*(self: Component) {.base, async.} =
  discard

method select*(self: Component) {.base, async.} =
  discard

method onRight*(self: Component) {.base, async.} =
  discard

method onLeft*(self: Component) {.base, async.} =
  discard

method onGotoStart*(self: Component) {.base, async.} =
  discard

method onGotoEnd*(self: Component) {.base, async.} =
  discard

method onEnter*(self: Component) {.base, async.} =
  discard

method onFindOrFilter*(self: Component) {.base, async.} =
  discard

method aLowLevel1*(self: Component) {.base, async.} =
  discard

method onEscape*(self: Component) {.base, async.} =
  discard

method onCtrlNumber*(self: Component, number: int) {.base, async.} =
  discard

method onDebuggerStarted*(self: Component, response: int) {.base, async.} =
  discard

method afterInit*(self: Component) {.base, async.} =
  discard

method onCompleteMove*(self: Component, response: MoveState) {.base, async.} =
  # echo "no complete"
  discard

method onFocus*(self: Component) {.base, async.} =
  discard

method showHistory*(self: Component, expression: cstring) {.base, async.} =
  discard

method onUpdatedHistory*(self: Component, update: HistoryUpdate) {.base, async.} =
  discard

method onUpdatedFlow*(self: Component, update: FlowUpdate) {.base, async.} =
  discard

method onUpdatedTable*(self: Component, update: TableUpdate) {.base, async.} =
  discard

method onUpdatedTrace*(self: Component, response: TraceUpdate) {.base, async.} =
  discard

method onLoadedTerminal*(self: Component, response: seq[ProgramEvent]) {.base, async.} =
  discard

method onAsdTrace*(self: Component) {.base, async.} =
  discard

method onLoadedFlowShape*(self: Component, update: FlowShape) {.base, async.} =
  discard

method onBuildCommand*(self: Component, response: BuildCommand) {.base, async.} =
  discard

method onBuildStdout*(self: Component, response: BuildOutput) {.base, async.} =
  discard

method onBuildStderr*(self: Component, response: BuildOutput) {.base, async.} =
  discard

method onBuildCode*(self: Component, response: BuildCode) {.base, async.} =
  discard

method onUpdatedTable*(self: Component, response: CtUpdatedTableResponseBody) {.base, async.} =
  discard

method onUpdatedCalltrace*(self: Component, response: CtUpdatedCalltraceResponseBody) {.base, async.} =
  discard

method onUpdatedShell*(self: Component, response: ShellUpdate) {.base, async.} =
  discard

method restart*(self: Service) {.base.} =
  discard

method onDebugOutput*(self: Component, response: DebugOutput) {.base, async.} =
  discard

method onError*(self: Component, error: DebuggerError) {.base, async.} =
  discard

method onAddBreakResponse*(self: Component, response: BreakpointInfo) {.base, async.} =
  discard

method onAddBreakCResponse*(self: Component, response: BreakpointInfo) {.base, async.} =
  discard

method onOutputJumpFromShellUi*(self: Component, response: int) {.base, async.} =
  discard

method onDapStopped*(self: Component, response: DapStoppedEvent) {.base, async.} =
  discard

method increaseWhitespaceWidth*(self: EditorViewComponent) {.base.} =
  if self.whitespace.width < MAX_WHITESPACE_WIDTH:
    self.whitespace.width += 1

method decreaseWhitespaceWidth*(self: EditorViewComponent) {.base.} =
  if self.whitespace.width > 1:
    self.whitespace.width -= 1

method onTracepointLocals*(self: Component, response: TraceValues) {.base, async.} =
  discard

method onProgramSearchResults*(self: Component, response: seq[CommandPanelResult]) {.base, async.} =
  discard

method onUpdatedLoadStepLines*(self: Component, stepLinesUpdate: LoadStepLinesUpdate) {.base, async.} =
  discard

method refreshTrace*(self: Component) {.base.} =
  discard

method onUploadTraceProgress*(self: Component, uploadProgress: UploadProgress) {.base, async.} =
  discard

method handleHistoryJump*(self: Component, isForward: bool) {.base.} =
  discard

method redrawForExtension*(self: Component) {.base.} =
  if not self.kxi.isNil:
    self.kxi.redraw()

method redrawForSinglePage*(self: Component) {.base.} =
  if not self.kxi.isNil:
    self.kxi.redraw()

method redraw*(self: Component) {.base.} =
  if self.inExtension:
    self.redrawForExtension()
  else:
    self.redrawForSinglePage()

# templates for singletons
template debugComponent*(data: Data): DebugComponent =
  DebugComponent(data.ui.componentMapping[Content.Debug][0])

template welcomeScreen*(data: Data): WelcomeScreenComponent =
  WelcomeScreenComponent(data.ui.componentMapping[Content.WelcomeScreen][0])

# templates for getting a component from the common mapping
template stateComponent*(data: Data, id: int): StateComponent =
  StateComponent(data.ui.componentMapping[Content.State][id])

template buildComponent*(data: Data, id: int): BuildComponent =
  BuildComponent(data.ui.componentMapping[Content.Build][id])

template errorsComponent*(data: Data, id: int): ErrorsComponent =
  ErrorsComponent(data.ui.componentMapping[Content.BuildErrors][id])

template scratchpadComponent*(data: Data, id: int): ScratchpadComponent =
  ScratchpadComponent(data.ui.componentMapping[Content.Scratchpad][id])

template shellComponent*(data: Data, id: int): ShellComponent =
  ShellComponent(data.ui.componentMapping[Content.Shell][id])

template traceLogComponent*(data: Data, id: int): TraceLogComponent =
  TraceLogComponent(data.ui.componentMapping[Content.TraceLog][id])


# macro delegate*(namespace: static[string], messages: untyped): untyped =
#   # ipc.on message do (sender: js, response: js):
#   #   mainWindow.webContents.send message, response
#   let ipc = ident("debuggeripc")
#   let mainWindow = ident("mainWindow")
#   result = nnkStmtList.newTree()
#   for message in messages:
#     let fullMessage = (namespace & $message).newLit
#     let code = quote:
#       `ipc`.on(`fullMessage`) do (sender: js, response: js):
#         `mainWindow`.webContents.send `fullMessage`, response
#     result.add(code)
#     # echo result.repr

# macro delegateDebugger*(namespace: static[string], messages: untyped): untyped =
#   # ipc.on message do (sender: js, response: js):
#   #   discard debugger.message()
#   let ipc = ident("ipc")
#   let debugger = ident("debugger")
#   result = nnkStmtList.newTree()
#   for message in messages:
#     var fullMessage: NimNode
#     var label: NimNode
#     if message.kind != nnkStrLit:
#       fullMessage = (namespace & $(message[1])).newLit
#       label = ident($message[2])
#     else:
#       fullMessage = (namespace & $(message)).newLit
#       label = ident(toCamelCase($message))
#     let code = quote:
#       `ipc`.on(`fullMessage`) do (sender: js, response: js):
#         discard `debugger`.`label`()
#     result.add(code)

# let INT_TYPE = readType(0)
# let FLOAT_TYPE = readType(48)
# let STRING_TYPE = readType(22)
# let BOOL_TYPE = readType(37)
# let CHAR_TYPE = readType(61)
# let RAW_TYPE* = readType(100)
# let NIL_VALUE* = 2.Value2
# let NIL_TYPE* = 2.Type2

let INT_TYPE = Type(kind: Literal, langType: "int")
let FLOAT_TYPE = Type(kind: Literal, langType: "float")
let STRING_TYPE = Type(kind: Literal, langType: "string")
let BOOL_TYPE = Type(kind: Literal, langType: "bool")
let CHAR_TYPE = Type(kind: Literal, langType: "char")
let RAW_TYPE* = Type(kind: Raw, langType: defaultstring(""), cType: defaultstring(""))
let NIL_VALUE*: Value = nil
let NIL_TYPE*: Type = nil

proc newValue*(kind: TypeKind, typ: Type, i: BiggestInt): Value =
  discard

proc newValue*(kind: TypeKind, typ: Type, f: float): Value =
  discard

proc newValue*(kind: TypeKind, typ: Type, text: string): Value =
  discard

proc newValue*(kind: TypeKind, typ: Type, b: bool): Value =
  discard

proc newValue*(kind: TypeKind, typ: Type, c: char): Value =
  discard

proc newValue*(kind: TypeKind, typ: Type, elements: seq[Value]): Value =
  discard

proc toLiteral*(i: BiggestInt): Value =
  newValue(Int, INT_TYPE, i)

proc toLiteral*(f: float): Value =
  newValue(Float, FLOAT_TYPE, f)

proc toLiteral*(text: string): Value =
  newValue(String, STRING_TYPE, text)

proc toLiteral*(b: bool): Value =
  newValue(Bool, BOOL_TYPE, b)

proc toLiteral*(c: char): Value =
  newValue(Char, CHAR_TYPE, c)

template toSequence*(argKind: TypeKind, argElements: seq[Value]): Value =
  0

proc toInstance*(langType: string, members: JsAssoc[cstring, Value]): Value =
  discard

proc toEnum*(langType: string, i: int, n: defaultstring): Value =
  discard

proc baseName*(a: cstring): cstring =
  cast[seq[cstring]](a.toJs.split(cstring"/"))[^1]
