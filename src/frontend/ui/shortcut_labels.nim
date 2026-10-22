## The debug toolbar's controls and the chord each one's tooltip shows.
##
## ## Why this module exists
##
## `codetracer-specs/GUI/Keyboard-Shortcuts-System.md` § Future Work asked for
## shortcut hints on toolbar buttons and menu items. The toolbar half used to
## be done by WRITING THE CHORD INTO THE TOOLTIP AS A STRING LITERAL, which
## agrees with the keymap only by coincidence and goes on promising a chord
## after anybody rebinds it. A tooltip has to READ the binding, and read it
## through the same function the menu reads — or the two are free to show the
## same binding differently.
##
## PLAT-68: that function is the router's (`ui/chord_display`,
## `keymap_router.chordFor`): the chord that RUNS the control's action where
## the focus is, the user's `keybindings.json` included. The YAML-table
## spelling (`renderChord`), the Monaco delegation whitelist and the two
## registries of chords bound in code that lived here went with the binding
## table they described (`ui/key_router.nim`'s header).
##
## ## The table
##
## `debugToolbarActions` is the toolbar's 13 controls, in the order the toolbar
## paints them, each paired with the `ClientAction` whose chord it should show.
##
## This module is deliberately a LEAF: `ui/menu.nim` imports `ui/debug.nim`, so
## `ui/debug.nim` — which injects the lookup into `DebugControlsVM` — cannot
## import `ui/menu.nim` back. Importing only `../types` keeps both able to use
## it.

import std/options

import ../types

const debugToolbarActions*: array[13, tuple[id: string; action: ClientAction]] = [
  # History navigation.
  (id: "history-back",       action: ClientAction.aHistoryBack),
  (id: "history-forward",    action: ClientAction.aHistoryForward),
  # The four stepping pairs. These eight already had their conventional
  # chords in `default_config.yaml` — F10/F11/F12/F8 with SHIFT+ for the
  # reverse direction — which is exactly what the removed hardcoded tooltip
  # strings had been restating. Nothing had to move for them.
  (id: "reverse-next",       action: ClientAction.reverseNext),
  (id: "next",               action: ClientAction.forwardNext),
  (id: "reverse-step-in",    action: ClientAction.reverseStep),
  (id: "step-in",            action: ClientAction.forwardStep),
  (id: "reverse-step-out",   action: ClientAction.reverseStepOut),
  (id: "step-out",           action: ClientAction.forwardStepOut),
  (id: "reverse-continue",   action: ClientAction.reverseContinue),
  (id: "continue",           action: ClientAction.forwardContinue),
  # The three non-stepping controls.
  (id: "run-to-entry",       action: ClientAction.aRunToEntry),
  (id: "reset-operation",    action: ClientAction.aResetOperation),
  (id: "run-tests",          action: ClientAction.aRunTests),
]
  ## The debug toolbar's controls, in paint order, each with the
  ## `ClientAction` whose chord its tooltip shows.
  ##
  ## The ids are the toolbar's own dispatch ids — the strings
  ## `DebugControlsVM.invokeToolbarStep` and `DebugCommands.step` already
  ## switch on —
  ## so this table cannot drift from the buttons without the buttons
  ## breaking too.

proc toolbarClientAction*(actionId: string): Option[ClientAction] =
  ## The `ClientAction` behind one toolbar control, or `none` for an id that
  ## is not a toolbar control.
  for entry in debugToolbarActions:
    if entry.id == actionId:
      return some(entry.action)
  none(ClientAction)

proc toolbarChord*(chordOf: proc(action: ClientAction): string;
                   actionId: string): string =
  ## The chord currently bound to one debug-toolbar control, or "" —
  ## `chordOf` is the router's (`ui/chord_display`, PLAT-68).
  ##
  ## This is what `ui/debug_toolbar.nim` (`wireDebugToolbarShortcuts`)
  ## injects into `DebugControlsVM.shortcutFor`,
  ## and therefore what ends up inside the parentheses in a tooltip.
  let action = toolbarClientAction(actionId)
  if action.isNone:
    return ""
  chordOf(action.get)
