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
    # Language-specific View-menu actions (currently Nim-only — see
    # `nimSpecificViewItems` in src/frontend/ui_js.nim).  Appended at
    # the end of the enum on purpose so existing ordinal-based menu
    # array layouts (the `actions` array in ui_js.nim) stay stable.
    aViewGeneratedCSource,    # View the C source generated for the current Nim file
    aViewDisassembly,         # View disassembly of the current binary
    aTraceMacroAtCursor,      # Trace macro expansion at the editor cursor
    aTraceStaticBlockAtCursor, # Trace `static:` block at the editor cursor
    aCollabInvite,            # Create/copy/revoke a collaboration invite URL
    aTimeline,                # Open the Timeline panel
    # Visual Replay / Video Player keyboard shortcuts — M4.  Routed through the
    # standard ClientAction mechanism but scoped to the Video Player component
    # (handlers query a focus marker before delegating to VideoPlayerVM).  See
    # codetracer-specs/GUI/Debugging-Features/Visual-Replay.md §Keyboard
    # Shortcuts and Visual-Replay.milestones.org §M4.  Appended at the end of
    # the enum so existing ordinal-keyed arrays (notably the `actions` array in
    # `ui_js.nim`) stay layout-stable.
    videoPlayerTogglePlay,        # Space / K — Play / Pause
    videoPlayerRewind,            # J — Rewind / cycle reverse speed
    videoPlayerFastForward,       # L — Fast forward / cycle speed
    videoPlayerStepFrameBack,     # ← — Previous frame (paused only)
    videoPlayerStepFrameForward,  # → — Next frame (paused only)
    videoPlayerStepDrawBack,      # Shift+← — Previous draw call
    videoPlayerStepDrawForward,   # Shift+→ — Next draw call
    videoPlayerJumpStart,         # Home — Seek to first frame
    videoPlayerJumpEnd,           # End — Seek to last frame
    videoPlayerTogglePicker,      # P — Enter / exit picker mode
    videoPlayerCancelPicker       # Esc (picker on) — Cancel picker without commit

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
    # M-REC-3: UUIDv7 recording-id string.  Pre-M-REC-2 this was an
    # ``int`` field named ``traceID``; M-REC-2 flipped the type and
    # M-REC-3 renamed it from ``traceID`` to ``recordingID`` so the
    # codebase speaks "recording" rather than the overloaded
    # "trace_id".
    recordingID*: langstring
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
    ShaderDebug = 44,
    VideoPlayer = 45

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
