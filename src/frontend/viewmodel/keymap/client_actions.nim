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
## the FIRST operation listed for it.
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
  ]

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
  ""
