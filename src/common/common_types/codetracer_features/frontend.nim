type
  DebuggerAction* = enum
    StepIn,
    StepOut,
    Next,
    Continue,
    StepC,
    NextC,
    StepI,
    NextI,
    CoStepIn,
    CoNext,
    NonAction

  DebuggerDirection* = enum
    DebForward,
    DebReverse

  # Each member of this enum maps to some kind of frontend interaction. It is used to route events, set/get shortcuts, etc for a given frontend interaction
  ClientAction* = enum
    forwardContinue,
    reverseContinue,
    forwardNext,
    reverseNext,
    forwardStep,
    reverseStep,
    forwardStepOut,
    reverseStepOut,
    stop,
    build,
    switchTabLeft,
    switchTabRight,
    switchTabHistory,
    openFile,
    newTab,
    reopenTab,
    closeTab,
    switchEdit,
    switchDebug,
    commandSearch, # credits to Sublime Text
    fileSearch,
    fixedSearch,
    del,
    selectFlow,
    selectState,
    goUp,
    goDown,
    goRight,
    goLeft,
    pageUp,
    pageDown,
    gotoStart,
    gotoEnd,
    aEnter, # affects only renderer, map manually editor differently
    aEscape,
    zoomIn,
    zoomOut,
    example,
    aExit,
    newFile,
    preferences,
    openFolder,
    openRecent,
    aSave,
    saveAs,
    saveAll,
    closeAllDocuments,
    aCut,
    aCopy,
    aPaste,
    findOrFilter,
    aReplace,
    findInFiles,
    replaceInFiles,
    aToggleComment,
    aIncreaseIndentation,
    aDecreaseIndentation,
    aMakeUppercase,
    aMakeLowercase,
    aCollapseUnderCursor,
    aExpandUnderCursor,
    aExpandAll,
    aCollapseAll,
    aUndo,
    aRedo,
    aProgramCallTrace,
    aProgramStateExplorer,
    aFindResults,
    aBuildLog,
    aFileExplorer,
    aSaveLayout,
    aLoadLayout,
    switchDebugWide,
    switchEditNormal,
    aNewHorizontalTabGroup,
    aNewVerticalTabGroup,
    aNotifications,
    aStartWindow,
    aFullScreen,
    aTheme0,
    aTheme1,
    aTheme2,
    aTheme3,
    aMonacoTheme0,
    aMultiline,
    aSingleLine,
    aNoPreview,
    aLowLevel0,
    aLowLevel1
    aShowMinimap,
    aGotoFile,
    aGotoSymbol,
    aGotoDefinition,
    aFindReferences,
    aGotoLine,
    aGotoPreviousCursorLocation,
    aGotoNextCursorLocation,
    aGotoPrevious,
    aGotoNextEditLocation,
    aGotoPreviousPointInTime,
    aGotoNextPointInTime,
    aGotoNextError,
    aGotoPreviousError,
    aGotoNextSearchResult,
    aGotoPreviousSearchResult,
    aBuild,
    aCompile,
    aRunStatic,
    aTrace,
    aLoadTrace,
    aNewState,
    aNewEventLog,
    aNewFullCalltrace,
    aNewTerminal,
    aPointList,
    aLocalCalltrace,
    aFullCalltrace,
    aState,
    aEventLog,
    aTerminal,
    aStepList,
    aScratchpad,
    aAgentActivity,
    aFilesystem,
    aShell,
    aOptions,
    aDebug,
    aBreakpoint,
    aDeleteBreakpoint,
    aDeleteAllBreakpoints,
    aEnableBreakpoint,
    aEnableAllBreakpoint,
    aDisableBreakpoint,
    aDisableAllBreakpoints,
    aTracepoint,
    aDeleteTracepoint,
    aEnableTracepoint,
    aEnableAllTracepoints,
    aDisableTracepoint,
    aDisableAllTracepoints,
    aCollectEnabledTracepointResults,
    aUserManual,
    aReportProblem,
    aSuggestFeature,
    aAbout,
    aMenu,
    zoomFlowLoopIn,
    zoomFlowLoopOut,
    switchFocusedLoopLevelUp,
    switchFocusedLoopLevelDown,
    switchFocusedLoopLevelAtPosition,
    setFlowTypeToMultiline,
    setFlowTypeToParallel,
    setFlowTypeToInline,
    aRestart,
    findSymbol,
    aReRecord,
    aReRecordProject,
    aRestartDbBackend,
    aRestartBackendManager,
    aOpenTrace,          # Open existing trace file/folder
    aOpenTraceInNewTab,  # Open existing trace in a new session tab
    aRecordNewTrace,     # Show record new trace dialog
    aRecordFromLaunch,   # Record using launch.json configuration
    aNewTraceTab,        # Open a new empty session tab

    # ── Language-dynamic menu actions ─────────────────────────────────────
    # These actions only appear in the View menu for traces whose
    # language exposes the corresponding capability. See
    # `appendLanguageSpecificViewItems` in `ui_js.nim` for the
    # gating logic. They are intentionally part of the global enum
    # (rather than registered dynamically) so that ShortcutMap layout
    # is stable across trace switches and `array[ClientAction, ...]`
    # sizes do not depend on runtime state.

    aSwitchSourceView,    # Cycle Nim → C → Asm → Nim (Nim traces only)
    aTraceMacroExecution, # Trace the macro call at the editor cursor (Nim)
    aTraceStaticBlock     # Trace the static: block at the editor cursor (Nim)

  InputShortcutMap* = TableLike[langstring, langstring]

  ShortcutMap* = object
    actionShortcuts*: array[ClientAction, seq[Shortcut]]
    shortcutActions*: TableLike[langstring, ClientAction]
    conflictList*: seq[(langstring, seq[ClientAction])]

  Shortcut* = object
    renderer*: langstring
    editor*: langstring

  StartOptions* = object ## Frontend start options
    loading*: bool
    screen*: bool
    inTest*: bool
    record*: bool
    isInstalled*: bool
    # M-REC-2: ``traceID`` is the recording_id (UUIDv7 string).  The
    # identifier-name rename to ``recordingId`` is M-REC-3 scope.
    traceID*: langstring
    edit*: bool
    name*: langstring
    folder*: langstring
    welcomeScreen*: bool
    stylusExplorer*: bool
    app*: langstring
    shellUi*: bool
    address*: langstring
    port*: int
    frontendSocket*: SocketAddressInfo
    backendSocket*: SocketAddressInfo
    idleTimeoutMs*: int
    rawTestStrategy*: langstring
    diff*: Diff
    withDiff*: bool
    rawDiffIndex*: langstring
    deepReview*: DeepReviewData
    withDeepReview*: bool

  # The contents of a window in the frontend
  Content* {.pure.} = enum
    History = 0,
    Trace = 1,
    EditorView = 2,
    Events = 3,
    State = 4,
    Statistics = 5,
    Calltrace = 6,
    Animate = 7,
    EventLog = 8,
    Filesystem = 9,
    Repl = 10,
    Build = 11,
    Errors = 12,
    FullCalltrace = 13,
    RegionGraph = 14,
    CommandView = 15,
    PointList = 16,
    Scratchpad = 17,
    LowLevelCode = 18,
    Timeline = 19,
    SearchResults = 20,
    BuildErrors = 21,
    TraceLog = 22,
    CalltraceEditor = 23,
    TerminalOutput = 24,
    Shell = 25,
    WelcomeScreen = 26,
    CallExpandedValue = 27,
    Value = 28,
    Debug = 29,
    Menu = 30,
    Status = 31,
    CommandPalette = 32,
    StepList = 33,
    NoInfo = 34,
    AgentActivity = 35,
    DeepReview = 36,
    AgentWorkspace = 37,
    CaptionBarProgress = 38,
    AgentActivityDeepReview = 39,
    RequestPanel = 40,
    VCS = 41,
    FrameViewer = 42,
    PixelHistory = 43,
    ShaderDebug = 44

  ConnectionLossReason* = enum
    ConnectionLossNone,
    ConnectionLossIdleTimeout,
    ConnectionLossSuperseded,
    ConnectionLossUnknown

  ConnectionState* = object
    connected*:        bool
    reason*:           ConnectionLossReason
    detail*:           cstring

  StatusState* = ref object
    lastDirection*:         DebuggerDirection
    currentOperation*:      langstring
    currentHistoryOperation*: langstring
    finished*:              bool
    stableBusy*:            bool
    historyBusy*:           bool
    traceBusy*:             bool
    hasStarted*: bool
    lastAction*:            langstring
    # TODO: how to depend on this, if in errors
    # error*:                 DebuggerError
    operationCount*:        int

  # updates the middleware current operation/operation count/stableBusy
  # and usually produces StatusUpdate from middleware
  NewOperation* = ref object
    name*: langstring
    stableBusy*: bool
