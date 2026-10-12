## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/input/operation_dispatch.nim — the terminal's half of Input-Routing
## §3.2's mapping: the OPERATIONS a keymap row runs that the terminal performs
## through its dispatcher's `KeyAction`s.
##
## Owns: the one table from an operation (with its argument) to the
## `KeyAction` the terminal's existing action procedures are indexed by
## (`runtime.performAction`, CTUI-10's `interpreter.dispatchAction`). Read
## both ways: the router's resolution is dispatched through it, and the menu
## and the controls' tooltips ask the router for the chord of the operation a
## `KeyAction` is.
##
## Refuses to own: the rows (the bases, `viewmodel/keymap`), resolution (the
## one resolver), and every operation that is not a `KeyAction` — the editing
## vocabulary, the lists', the inputs', the overlays' — which the runtime
## dispatches onto their ViewModels directly.
##
## One `KeyAction` per operation and one operation per `KeyAction`, asserted
## by `test_keymap_no_conflicts.nim`: the table is a bijection over the
## actions it names, so it cannot route one operation two ways.

import ./keymap

const
  OperationActions*: seq[tuple[operation: string, action: KeyAction]] = @[
    ("layout.focus-next-pane", kaFocusNextPane),
    ("layout.focus-previous-pane", kaFocusPrevPane),
    ("layout.focus-left", kaFocusLeft),
    ("layout.focus-down", kaFocusDown),
    ("layout.focus-up", kaFocusUp),
    ("layout.focus-right", kaFocusRight),
    ("layout.focus-pane(call-trace)", kaSelectCallStack),
    ("layout.focus-pane(editor)", kaSelectSource),
    ("layout.focus-pane(variables)", kaSelectVariables),
    ("layout.focus-pane(event-log)", kaSelectEventLog),
    ("layout.maximize-pane", kaMaximizePane),
    ("debugger.step-over", kaStepOver),
    ("debugger.reverse-step-over", kaReverseStepOver),
    ("debugger.step-into", kaStepInto),
    ("debugger.reverse-step-into", kaReverseStepInto),
    ("debugger.step-out", kaStepOut),
    ("debugger.reverse-step-out", kaReverseStepOut),
    ("debugger.continue", kaContinue),
    ("debugger.reverse-continue", kaReverseContinue),
    ("debugger.previous-call", kaPrevCall),
    ("debugger.next-call", kaNextCall),
    ("debugger.previous-mutation", kaPrevMutation),
    ("debugger.next-mutation", kaNextMutation),
    ("debugger.jump-to-start", kaJumpToStart),
    ("debugger.jump-to-end", kaJumpToEnd),
    ("debugger.seek-to-tick", kaSeekToTick),
    ("editor.jump-to-value-origin", kaValueOrigin),
    ("debugger.reverse-origin", kaReverseOrigin),
    ("editor.scroll-line-down", kaScrollLineDown),
    ("editor.scroll-line-up", kaScrollLineUp),
    ("editor.scroll-half-page-up", kaHalfPageUp),
    ("editor.scroll-half-page-down", kaHalfPageDown),
    ("editor.center-on-pointer", kaCenterOnPointer),
    ("editor.toggle-breakpoint", kaToggleBreakpoint),
    ("list.expand", kaExpandNode),
    ("list.collapse", kaCollapseNode),
    ("variables.toggle-hex-dec", kaToggleHexDec),
    ("variables.view-memory-dump", kaViewMemoryDump),
    ("palette.open-commands", kaCommandPalette),
    ("find.open", kaSearchForward),
    ("find.open-backward", kaSearchBackward),
    ("find.next", kaNextMatch),
    ("find.previous", kaPrevMatch),
    ("command-line.open", kaOpenCommandPrompt),
    ("modal.return-to-normal", kaReturnToNormal),
    ("app.quit", kaQuit),
    ("inspect.open", kaEnterInspect),
    ("input.commit", kaCommitPrompt),
    ("input.delete-backward", kaPromptBackspace),
    ("session.toggle-product-mode", kaToggleProductMode),
    ("session-tabs.next", kaNextSessionTab),
    ("session-tabs.previous", kaPrevSessionTab),
  ]

func actionOfOperation*(operation: string): KeyAction =
  ## `operation` — with its argument, `layout.focus-pane(editor)` — as the
  ## terminal's action, or `kaNone`.
  for (o, a) in OperationActions:
    if o == operation: return a
  kaNone

func operationOfAction*(action: KeyAction): string =
  for (o, a) in OperationActions:
    if a == action: return o
  ""
