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
    aStartAgenticWorktreeSession, # Start a worktree-isolated agentic session
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
    videoPlayerCancelPicker,      # Esc (picker on) — Cancel picker without commit
    # VN-M5. Open the verification panel. Appended at the end for the reason
    # the two notes above give: the `actions` array in `ui_js.nim` is indexed
    # positionally by this enum, so inserting anywhere but the end silently
    # re-points every handler after the insertion.
    aVerification,                # Open the Verification panel
    # The five debug-toolbar controls that had no `ClientAction`, and so had no
    # chord that `ui/menu.nim`'s `loadShortcut` — or a tooltip — could read.
    #
    # The other eight toolbar buttons were already covered: `forwardNext` /
    # `reverseNext` / `forwardStep` / `reverseStep` / `forwardStepOut` /
    # `reverseStepOut` / `forwardContinue` / `reverseContinue` are in
    # `default_config.yaml` with exactly the conventional F10/F11/F12/F8 family
    # the toolbar's hardcoded tooltip strings had been *restating*. Nothing was
    # displaced to add these five; they occupy chords nothing claimed.
    #
    # Appended at the end for the reason the three notes above give: `actions`
    # in `ui_js.nim` is `array[ClientAction, ClientActionHandler]` written as a
    # positional literal, so inserting anywhere but the end silently re-points
    # every handler after the insertion. `test_verification_panel_registration`
    # pins `ord(aVerification) == 183`, which an append leaves true.
    aHistoryBack,                 # CTRL+ALT+B — toolbar `history-back`
    aHistoryForward,              # CTRL+ALT+F — toolbar `history-forward`
    aRunToEntry,                  # CTRL+ALT+E — toolbar `run-to-entry`
    aResetOperation,              # CTRL+ALT+R — toolbar `reset-operation`
    aRunTests,                    # ALT+L      — toolbar `run-tests`
    # OPENS THE KEYBOARD-SHORTCUTS DIALOG, and it is an action rather than a
    # hardcoded `Mousetrap.bind` for the same reason everything above it is:
    # a chord bound in code is one `renderChord` cannot see, so the menu item
    # that opens the shortcuts dialog would be the one menu item in the product
    # with no chord printed beside it.
    #
    # Appended, per the note above — `actions` in `ui_js.nim` is a positional
    # literal and an insertion anywhere else re-points every handler after it.
    aKeyboardShortcuts            # CTRL+ALT+K — menu `Keyboard Shortcuts`

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
    reviewSession*: DeepReviewSessionTranscript
      ## RV-6 — the agent session the review's dataset named, already
      ## resolved by `ct` (`src/ct/review_session.nim`), or nil.
      ##
      ## Nil covers *two* cases and the panel must tell them apart, which is
      ## why the failures are not nil: a dataset with no reference has none
      ## of this (a complete review, no session shown), while a reference
      ## that would not resolve arrives here with a non-`"loaded"` `state`
      ## and the backend's own message, so the panel can say why rather than
      ## rendering an empty conversation (DeepReview-GUI.md §2.1).
      ##
      ## It is *not* part of the dataset and is never written back into one:
      ## `review.json` carries the reference only.

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
    ## Ordinal 36 was `DeepReview`, the standalone review panel.  That panel
    ## is deleted: DeepReview introduces no panel of its own — it is a
    ## combination of features of the Editor, the VCS panel and the Agent
    ## Activity panel (codetracer-specs/DeepReview/DeepReview-GUI.md §7).
    ##
    ## The member survives only to keep `Content` a contiguous ordinal, which
    ## `Components.componentMapping` needs (`array[Content, ...]`), exactly as
    ## `FrameViewer` does after its own retirement.  It has no
    ## `makeComponent` arm, so a stale persisted layout that still names it
    ## logs through `renderer.createUIComponent`'s `ValueError` guard and
    ## leaves an empty tab instead of resurrecting a review surface.  Nothing
    ## emits it: `--deepreview` layouts are never persisted
    ## (`renderer.saveConfig`) and the agentic launcher stopped opening one in
    ## DR-R7.  Do not reuse the ordinal for a different panel.
    RetiredDeepReviewPanel = 36,
    AgentWorkspace = 37,
    CaptionBarProgress = 38,
    ## The review's identity in the Agent Activity pillar's layout.
    ##
    ## AA-1 deleted the roll-up this pane used to draw — the coverage summary,
    ## the test-results row, the per-file coverage table and the notification
    ## feed (DeepReview-GUI.md §2.1: "There is no 'DeepReview section' in this
    ## panel").  The *id* survives the deletion, unlike ordinal 36's: the panel
    ## keeps a review role (AA-2 renders `ct test` runs into it, AA-3 renders
    ## evidence tool calls), `index/config.reviewPillarContentIds` names it so
    ## review mode keeps it visible where edit mode would hide it, and a layout
    ## persisted by an older build may host a pane of it.  Its *contents*
    ## changed, not its identity: `makeComponent` still constructs a
    ## (stateless) component for it, which renders an empty pane until AA-2 /
    ## AA-3 fill it with the session's own content.
    AgentActivityDeepReview = 39,
    RequestPanel = 40,
    VCS = 41,
    FrameViewer = 42,
    PixelHistory = 43,
    ShaderDebug = 44,
    VideoPlayer = 45,
    ## An editor-area tab holding one unified diff, as a Monaco document.
    ##
    ## GUI/Core-Panes/VCS-Panel.md, "Unified Diff View (Editor Integration)":
    ## "clicking a file in the Changed Files list opens a special editor tab
    ## that shows the file's diff: Uses the standard CodeTracer Monaco
    ## editor".  It is a content kind of its own rather than a second instance
    ## of `VCS` because it is a *document*, keyed by its diff target, and
    ## shares nothing with the docked panel's branch picker and commit
    ## history.
    UnifiedDiff = 46,
    ## VN-M5. The verification panel: a Verno run's status and findings, and —
    ## when the run's payload carries a counterexample with values in it — the
    ## solver's counterexample, walked with the debugger's ordinary controls.
    ##
    ## **One content kind, not two, and that is the data-gating.** The
    ## counterexample is not a panel a user can open: it is a region of this
    ## one that exists only while a session is open, and a session opens only
    ## from a finding whose payload passes `canOpenCounterexample`. A
    ## `Content.Counterexample` with its own menu entry would be a standing
    ## affordance for a thing that usually is not there — the promise this
    ## campaign exists to avoid making.
    Verification = 47
    ## NS9. The two panes `Planned-Features/Noir-Studio.md` §1a's first screen
    ## shows beside the Filesystem and the Editor, and which no platform had.
    ##
    ## They are CodeTracer's rather than the studio's, which is why they are
    ## here and not in a web-only module: §1a is explicit that "a desktop user
    ## running Noir tests gets both, because the web is a build of the product
    ## and not a fork of it". Both are absent from `editModeHiddenContentIds`
    ## below, so an editing session shows them on either platform, and both
    ## are ordinary `genericUiComponent` panes with an IsoNim view — nothing
    ## about them is web-shaped.
    TestResults = 48
      ## Per-test pass/fail for the open project. Its model is the one that
      ## already existed and had no pane: `TestItem` / `TestCatalog` from
      ## `src/ct_test/contracts.nim` for what tests EXIST, and
      ## `TestRunSummary` / `TestRunRow` from
      ## `viewmodel/viewmodels/test_run_summary_vm.nim` for what a run SAID.
    Constraints = 49
      ## What the circuit costs, as `nargo info --json` reports it. See
      ## `src/common/noir_constraints.nim` for why the rows are per ACIR
      ## function rather than the per-module roll-up §1a's picture draws.

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

# ---------------------------------------------------------------------------
# Layout routing rules
# ---------------------------------------------------------------------------
#
# Defined here (rather than in the JS-only frontend `utils.nim`) so the rule
# is a single definition shared by `src/frontend/types.nim` and
# `src/common/types.nim`, and therefore reachable from headless tests that
# compile on the C backend.  `openLayoutTab` itself cannot be tested that way
# because it manipulates GoldenLayout through the DOM.

func opensAsIndependentTab*(content: Content; isEditor: bool): bool =
  ## Whether a panel of `content` requested with `isEditor = true` must be
  ## opened as its own tab in the editor area rather than being collapsed onto
  ## the (usually sidebar-docked) singleton instance of that content kind.
  ##
  ## Most panel kinds — FILESYSTEM, EVENT LOG, STATE … — are singletons: asking
  ## for one when it is already on screen should just focus it.  But a panel
  ## may also be asked for as an *editor-area document*, keyed by the thing it
  ## displays; the VCS panel does this for `View Diff`, opening one tab per
  ## diff target.  Those instances are not interchangeable with the singleton
  ## and must not be folded into it.
  ##
  ## `EditorView` is excluded because editor tabs already have their own,
  ## richer reuse path in `openLayoutTab` (keyed by `data.ui.editors`), which
  ## also carries the tab-history and source-loading bookkeeping.
  isEditor and content != Content.EditorView

func opensAsDocumentTab*(content: Content; isEditor: bool): bool =
  ## Whether an `openLayoutTab` request names an editor-area *document* — an
  ## instance keyed by the thing it displays — rather than the singleton
  ## instance of a panel kind.
  ##
  ## Two shapes qualify: `Content.EditorView`, which has one instance per open
  ## file (`GUI/Core-Panes/Editor-Pane.md`, "Tab Management": "Multiple files
  ## can be open simultaneously as tabs"), and the independent tabs of
  ## `opensAsIndependentTab` (the VCS panel's per-diff-target `View Diff` tabs).
  content == Content.EditorView or opensAsIndependentTab(content, isEditor)

func revealsPinnedPanel*(
    content: Content;
    isEditor: bool;
    requestedPath: langstring;
    pinnedPath: langstring): bool =
  ## Whether an `openLayoutTab` request for `content` should be satisfied by
  ## revealing an already auto-hidden (pinned) panel of the same content kind
  ## instead of opening or focusing a GoldenLayout tab.
  ##
  ## `requestedPath` is the layout path the request is keyed by
  ## (`editorTabPath(path, editorView)`); `pinnedPath` is the layout path the
  ## candidate pinned panel carries in its serialised component state (empty
  ## for a singleton, which has no document identity).
  ##
  ## For a SINGLETON panel — FILESYSTEM, STATE, BUILD, PROBLEMS, SEARCH
  ## RESULTS, REQUESTS … — the pinned instance *is* the panel the request asks
  ## for, and revealing it is the entire point of pinning
  ## (`Planned-Features/Auto-Hide-Panes.md` §1.1: the panel "slides in as a
  ## floating overlay on top of the Golden Layout area, without displacing the
  ## existing layout").
  ##
  ## For a DOCUMENT tab the content kind is not an identity.  A pinned panel
  ## only answers a request for the SAME document; a request for a different
  ## file or a different diff target must open its own tab.
  ##
  ## Matching on the content kind alone is a real defect, not a nicety.  Pin one
  ## editor and every later "open a file" request resolves to that one panel, so
  ## no other file can ever be opened again — contradicting Editor-Pane.md's
  ## "Multiple files can be open simultaneously as tabs" — and each such request
  ## instead becomes a `showOverlay` call, i.e. an overlay show/hide toggle that
  ## rebuilds the edge strip from scratch.  The same mistake re-breaks the VCS
  ## `View Diff` button (issues #561 / #611) whenever the VCS panel is pinned.
  if opensAsDocumentTab(content, isEditor):
    requestedPath.len > 0 and requestedPath == pinnedPath
  else:
    true

proc editModeHiddenContentIds*(): seq[int] =
  ## The replay-only panes an EDITING session does not show.
  ##
  ## ## Why this sits beside the `Content` enum rather than in the index process
  ##
  ## It lived in `frontend/index/config.nim`, whose only reachable caller is
  ## `loadEditLayoutConfig` — and `index/config.nim` imports `electron_lib`,
  ## which is `{.error.}` under `-d:ctWeb`. So the web build could not ask
  ## "which panes does edit mode hide?" without either importing Electron or
  ## writing the list a second time, and a second list is how a pane added to
  ## edit mode on one platform silently keeps appearing on the other. That is
  ## the property `Planned-Features/Noir-Studio.md` §3 exists to protect: "the
  ## web is a build of the product and not a fork of it".
  ##
  ## The set is a fact about `Content`, so it belongs where `Content` is
  ## declared. Both platforms now read this one declaration:
  ## `index/config.nim` for the desktop's `default_edit_layout.json`, and
  ## `ui/web_entry_surface.nim` for the layout the browser enters edit mode on.
  @[
    ord(Content.Trace),
    ord(Content.State),
    ord(Content.Scratchpad),
    ord(Content.Repl),
    ord(Content.EventLog),
    ord(Content.Timeline),
    ord(Content.TerminalOutput),
    ord(Content.StepList),
    ord(Content.Calltrace),
    ord(Content.CalltraceEditor),
    ord(Content.TraceLog),
    ord(Content.AgentActivity),
    ord(Content.AgentActivityDeepReview),
    # Content.FrameViewer removed in M3 — pane no longer dispatched.
    ord(Content.PixelHistory),
    ord(Content.ShaderDebug),
    ord(Content.VideoPlayer)
  ]
