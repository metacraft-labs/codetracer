## client_actions.nim — the operations GPUI and the desktop perform through
## the desktop's `ClientAction`s.
##
## Owns: the table between the operation names a keymap row runs
## (`operation_catalogue`) and the desktop's action vocabulary
## (`common_types/.../frontend.ClientAction`, spelled as its names) — the
## mapping Input-Routing §3.2 asks for, for the actions the desktop and the
## GPUI window already perform. GPUI's window and the desktop's one key
## listener dispatch a resolved operation through it; the YAML importer reads
## it the other way.
##
## Refuses to own: what an action does (the desktop's `ui_js` action table,
## GPUI's `runGpuiMenuAction`), and every operation without a `ClientAction`
## (those are dispatched by the front-end directly — the editor's
## vocabulary, the lists', the layer operations).
##
## **ONE TABLE, READ BOTH WAYS.** An operation has at most one action; an
## action may be reached by more than one operation (`findOrFilter` is the
## editor's find and the list's filter), and the importer reads an action as
## the FIRST operation listed for it. An old spelling of an action already
## listed (`aBuild` beside `build`) follows its original in `LegacyAliases`:
## it reaches the same operation, and `clientActionOf` keeps naming the
## original because that row comes first.
##
## **EVERY MEMBER IS ACCOUNTED FOR** (Input-Routing §3.2): `ClientAction` is
## this table plus `MonacoClientActions` (Monaco's own commands, which leave
## with Monaco rather than being mapped), asserted both directions by
## `test_plat64_operation_mapping`.
##
## Pure; compiles on C, JS and wasm32.

const
  ClientActionOperations*: seq[tuple[operation, action: string]] = @[
    ("debugger.continue", "forwardContinue"),
    ("debugger.reverse-continue", "reverseContinue"),
    ("debugger.step-over", "forwardNext"),
    ("debugger.reverse-step-over", "reverseNext"),
    ("debugger.step-into", "forwardStep"),
    ("debugger.reverse-step-into", "reverseStep"),
    ("debugger.step-out", "forwardStepOut"),
    ("debugger.reverse-step-out", "reverseStepOut"),
    ("debugger.stop", "stop"),
    ("editor.toggle-inline-breakpoint", "aInlineBreakpoint"),
    ("debugger.restart", "aRestart"),
    ("debugger.run-to-entry", "aRunToEntry"),
    ("debugger.reset-operation", "aResetOperation"),
    ("build.run", "build"),
    ("tests.run", "aRunTests"),
    ("view.low-level-code", "aLowLevel1"),
    ("session-tabs.previous", "switchTabLeft"),
    ("session-tabs.next", "switchTabRight"),
    ("session-tabs.next-recent", "switchTabHistory"),
    ("session.open-file", "openFile"),
    ("session-tabs.new", "newTab"),
    ("session-tabs.reopen-closed", "reopenTab"),
    ("session-tabs.close", "closeTab"),
    ("editor.toggle-read-only", "aToggleReadOnly"),
    ("editor.trace-macro-at-cursor", "aNimTraceMacro"),
    ("editor.trace-static-block-at-cursor", "aNimTraceStaticBlock"),
    ("editor.trace-constant-at-cursor", "aNimTraceConstant"),
    ("editor.trace-eval", "aNimTraceEval"),
    ("palette.quick-open-file", "fileSearch"),
    ("palette.open-commands", "commandSearch"),
    ("find.open", "findOrFilter"),
    ("list.filter", "findOrFilter"),
    ("window.zoom-in", "zoomIn"),
    ("window.zoom-out", "zoomOut"),
    ("flow.loop-level-up", "switchFocusedLoopLevelUp"),
    ("flow.loop-level-down", "switchFocusedLoopLevelDown"),
    ("flow.set-multiline", "setFlowTypeToMultiline"),
    ("flow.set-parallel", "setFlowTypeToParallel"),
    ("flow.set-inline", "setFlowTypeToInline"),
    ("search.find-in-files", "findInFiles"),
    ("search.next-result", "aGotoNextSearchResult"),
    ("search.previous-result", "aGotoPreviousSearchResult"),
    ("palette.go-to-symbol", "findSymbol"),
    ("problems.next", "aGotoNextError"),
    ("problems.previous", "aGotoPreviousError"),
    ("navigation.back", "aHistoryBack"),
    ("navigation.forward", "aHistoryForward"),
    ("layout.focus-pane(call-trace)", "aFullCalltrace"),
    ("layout.focus-pane(event-log)", "aEventLog"),
    ("layout.focus-pane(variables)", "aState"),
    ("layout.focus-pane(file-tree)", "aFilesystem"),
    ("layout.focus-pane(terminal)", "aTerminal"),
    ("layout.focus-pane(points)", "aPointList"),
    ("app.quit", "aExit"),
    ("preferences.open", "preferences"),
    ("help.keyboard-shortcuts", "aKeyboardShortcuts"),
    ("list.focus-previous", "goUp"),
    ("list.focus-next", "goDown"),
    ("list.focus-page-up", "pageUp"),
    ("list.focus-page-down", "pageDown"),
    ("list.focus-first", "gotoStart"),
    ("list.focus-last", "gotoEnd"),
    ("list.collapse", "goLeft"),
    ("list.expand", "goRight"),
    ("list.activate", "aEnter"),
    ("list.clear-selection", "aEscape"),
    ("session.switch-to-edit", "switchEdit"),
    ("session.switch-to-debug", "switchDebug"),
    ("palette.fixed-search", "fixedSearch"),
    ("layout.focus-pane(flow)", "selectFlow"),
    ("session.new-file", "newFile"),
    ("session.open-folder", "openFolder"),
    ("session.open-recent", "openRecent"),
    ("session.save", "aSave"),
    ("session.save-as", "saveAs"),
    ("session.save-all", "saveAll"),
    ("session-tabs.close-all", "closeAllDocuments"),
    ("find.open-replace", "aReplace"),
    ("search.replace-in-files", "replaceInFiles"),
    ("layout.save", "aSaveLayout"),
    ("layout.load", "aLoadLayout"),
    ("layout.switch-debug-wide", "switchDebugWide"),
    ("layout.switch-edit-normal", "switchEditNormal"),
    ("layout.new-horizontal-group", "aNewHorizontalTabGroup"),
    ("layout.new-vertical-group", "aNewVerticalTabGroup"),
    ("view.notifications", "aNotifications"),
    ("view.start-window", "aStartWindow"),
    ("window.toggle-fullscreen", "aFullScreen"),
    ("view.theme-0", "aTheme0"),
    ("view.theme-1", "aTheme1"),
    ("view.theme-2", "aTheme2"),
    ("view.theme-3", "aTheme3"),
    ("view.editor-theme-0", "aMonacoTheme0"),
    ("view.preview-multiline", "aMultiline"),
    ("view.preview-single-line", "aSingleLine"),
    ("view.preview-none", "aNoPreview"),
    ("view.source-code", "aLowLevel0"),
    ("palette.go-to-symbol-in-file", "aGotoSymbol"),
    ("palette.go-to-line", "aGotoLine"),
    ("view.previous-point-in-time", "aGotoPreviousPointInTime"),
    ("view.next-point-in-time", "aGotoNextPointInTime"),
    ("build.compile", "aCompile"),
    ("build.run-static", "aRunStatic"),
    ("session.trace", "aTrace"),
    ("session.load-trace", "aLoadTrace"),
    ("layout.new-state", "aNewState"),
    ("layout.new-event-log", "aNewEventLog"),
    ("layout.new-full-calltrace", "aNewFullCalltrace"),
    ("layout.new-terminal", "aNewTerminal"),
    ("layout.focus-pane(local-call-trace)", "aLocalCalltrace"),
    ("layout.focus-pane(step-list)", "aStepList"),
    ("layout.focus-pane(scratchpad)", "aScratchpad"),
    ("layout.focus-pane(agent-activity)", "aAgentActivity"),
    ("layout.focus-pane(shell)", "aShell"),
    ("layout.focus-pane(verification)", "aVerification"),
    ("layout.focus-pane(constraints)", "aConstraints"),
    ("preferences.options", "aOptions"),
    ("session.debug", "aDebug"),
    ("editor.toggle-breakpoint", "aBreakpoint"),
    ("editor.delete-breakpoint", "aDeleteBreakpoint"),
    ("editor.delete-all-breakpoints", "aDeleteAllBreakpoints"),
    ("editor.enable-breakpoint", "aEnableBreakpoint"),
    ("editor.enable-all-breakpoints", "aEnableAllBreakpoint"),
    ("editor.disable-breakpoint", "aDisableBreakpoint"),
    ("editor.disable-all-breakpoints", "aDisableAllBreakpoints"),
    ("editor.toggle-tracepoint", "aTracepoint"),
    ("editor.delete-tracepoint", "aDeleteTracepoint"),
    ("editor.enable-tracepoint", "aEnableTracepoint"),
    ("editor.enable-all-tracepoints", "aEnableAllTracepoints"),
    ("editor.disable-tracepoint", "aDisableTracepoint"),
    ("editor.disable-all-tracepoints", "aDisableAllTracepoints"),
    ("editor.collect-tracepoint-results", "aCollectEnabledTracepointResults"),
    ("help.user-manual", "aUserManual"),
    ("help.report-problem", "aReportProblem"),
    ("help.suggest-feature", "aSuggestFeature"),
    ("help.about", "aAbout"),
    ("flow.zoom-loop-in", "zoomFlowLoopIn"),
    ("flow.zoom-loop-out", "zoomFlowLoopOut"),
    ("flow.loop-level-at-position", "switchFocusedLoopLevelAtPosition"),
    ("session.re-record", "aReRecord"),
    ("session.re-record-project", "aReRecordProject"),
    ("session.restart-db-backend", "aRestartDbBackend"),
    ("session.restart-backend-manager", "aRestartBackendManager"),
    ("session.open-trace", "aOpenTrace"),
    ("session.open-trace-in-new-tab", "aOpenTraceInNewTab"),
    ("session.record-new-trace", "aRecordNewTrace"),
    ("session.record-from-launch", "aRecordFromLaunch"),
    ("session.new-trace-tab", "aNewTraceTab"),
    ("view.generated-c-source", "aViewGeneratedCSource"),
    ("view.disassembly", "aViewDisassembly"),
    ("editor.trace-macro-at-cursor", "aTraceMacroAtCursor"),
    ("editor.trace-static-block-at-cursor", "aTraceStaticBlockAtCursor"),
    ("session.collab-invite", "aCollabInvite"),
    ("agent-activity.start-worktree-session", "aStartAgenticWorktreeSession"),
    ("video-player.toggle-play", "videoPlayerTogglePlay"),
    ("video-player.rewind", "videoPlayerRewind"),
    ("video-player.fast-forward", "videoPlayerFastForward"),
    ("video-player.step-frame-back", "videoPlayerStepFrameBack"),
    ("video-player.step-frame-forward", "videoPlayerStepFrameForward"),
    ("video-player.step-draw-back", "videoPlayerStepDrawBack"),
    ("video-player.step-draw-forward", "videoPlayerStepDrawForward"),
    ("video-player.jump-start", "videoPlayerJumpStart"),
    ("video-player.jump-end", "videoPlayerJumpEnd"),
    ("video-player.toggle-picker", "videoPlayerTogglePicker"),
    ("video-player.cancel-picker", "videoPlayerCancelPicker"),
    ("session.apply-edit-and-reload", "aApplyEditAndReload"),
    ("layout.toggle-live-edit-panel", "aToggleLiveEditPanel"),
    ("session.launch-under-hcr", "aLaunchUnderHcr"),
    ("layout.reset", "aResetLayout"),
    ("list.show-detail", "aShowDetail"),
    ("table.resize-column(+1)", "aWidenColumn"),
    ("table.resize-column(-1)", "aNarrowColumn"),
    ("view.scroll-left", "aScrollViewLeft"),
    ("view.scroll-right", "aScrollViewRight"),
    ("find.cancel", "aFindCancel"),
    ("tests.open-in-new-tab", "aTestsOpenInNewTab"),
    ("tests.open-in-current-tab", "aTestsOpenInCurrentTab"),
    ("tests.run-test", "aTestsRun"),
    ("tests.run-test-in-current-tab", "aTestsRunInCurrentTab"),
    ("build.run-program", "aRunProgram"),
    ("build.run-program-in-current-tab", "aRunProgramInCurrentTab"),
  ]

  LegacyAliases*: seq[tuple[operation, action: string]] = @[
    ("layout.focus-pane(variables)", "selectState"),
    ("layout.focus-pane(call-trace)", "aProgramCallTrace"),
    ("layout.focus-pane(variables)", "aProgramStateExplorer"),
    ("layout.focus-pane(search)", "aFindResults"),
    ("layout.focus-pane(build-output)", "aBuildLog"),
    ("layout.focus-pane(file-tree)", "aFileExplorer"),
    ("palette.quick-open-file", "aGotoFile"),
    ("build.run", "aBuild"),
    ("menu.toggle", "aMenu"),
  ]
    ## A second spelling of an action, reached through the same operation.

  MonacoClientActions* = [
    "del", "aCut", "aCopy", "aPaste", "aToggleComment",
    "aIncreaseIndentation", "aDecreaseIndentation", "aMakeUppercase",
    "aMakeLowercase", "aCollapseUnderCursor", "aExpandUnderCursor",
    "aExpandAll", "aCollapseAll", "aUndo", "aRedo", "aShowMinimap",
    "aGotoDefinition", "aFindReferences", "aGotoPreviousCursorLocation",
    "aGotoNextCursorLocation", "aGotoPrevious", "aGotoNextEditLocation"]
    ## Members that name a Monaco command (Input-Routing §3.2): they stay
    ## Monaco's until the shared editor replaces it on the desktop, and are
    ## then dropped rather than mapped.

  RetiredClientActions* = ["example", "aRetiredTimeline"]
    ## Members nothing performs: a placeholder and the removed Timeline panel,
    ## kept in the enum only so a stored name still parses.

func clientActionOf*(operation: string): string =
  ## The `ClientAction` name `operation` (with its argument,
  ## `layout.focus-pane(call-trace)`) is performed through, or "".
  for (o, a) in ClientActionOperations:
    if o == operation: return a
  ""

func operationOfClientAction*(action: string): string =
  ## The first operation that reaches `action`, or "".
  for (o, a) in ClientActionOperations:
    if a == action: return o
  for (o, a) in LegacyAliases:
    if a == action: return o
  ""
