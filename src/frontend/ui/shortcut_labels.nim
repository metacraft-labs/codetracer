## Rendering a bound chord as the text a user reads, in one place.
##
## ## Why this module exists
##
## `codetracer-specs/GUI/Keyboard-Shortcuts-System.md` lists under § Future
## Work: "Shortcut hints in UI: Show keyboard shortcut hints on toolbar buttons
## (tooltips), menu items (already partial)". The menu half was done by
## `menu.nim`'s `loadShortcut`; the toolbar half was done by WRITING THE CHORD
## INTO THE TOOLTIP AS A STRING LITERAL — `text "Next (F10)"` — which is not
## the same thing and fails in the way the spec's § Known Issues predicts: it
## agrees with `default_config.yaml` only by coincidence, and the moment
## anybody rebinds the key the toolbar goes on promising a chord that no longer
## does anything.
##
## The fix is to read the binding, and the reason that has to be shared code
## rather than a second implementation is that a second implementation is the
## same bug one level up: the menu and the tooltip would be free to render the
## same binding differently. `menu.nim`'s `loadShortcut` now delegates here, so
## a menu item and a toolbar tooltip showing "the shortcut for Next" are
## showing one string produced once.
##
## ## The table
##
## `debugToolbarActions` is the toolbar's 13 controls, in the order the toolbar
## paints them, each paired with the `ClientAction` whose chord it should show.
## Five of those `ClientAction`s were added for this work — the toolbar's
## non-stepping controls had no action at all, so there was nothing for a
## tooltip to read and nothing a user could press. See
## `src/config/default_config.yaml` for which chords they got and why.
##
## This module is deliberately a LEAF: `ui/menu.nim` imports `ui/debug.nim`, so
## `ui/debug.nim` — which injects the lookup into `DebugControlsVM` — cannot
## import `ui/menu.nim` back. Importing only `../types` keeps both able to use
## it.

import std/[strutils, options]

import ../types

proc renderChord*(action: ClientAction; config: Config): string =
  ## The chord bound to `action`, spelled the way it is shown to a user, or
  ## "" when nothing is bound.
  ##
  ## "" IS THE IMPORTANT RETURN VALUE. `initShortcutMap` is first-writer-wins:
  ## an action whose chord was already claimed gets no entry in
  ## `actionShortcuts` at all, so it lands here as "" rather than as an error.
  ## Callers must render that as *no chord* — never as an empty pair of
  ## parentheses, which would advertise a shortcut that does not exist.
  ##
  ## Multiple chords are joined with a space, which is how `forwardContinue`
  ## ("F8 F2") has always been shown in the menu.
  # `actionShortcuts` is `array[ClientAction, seq[Shortcut]]` — a value type,
  # always fully sized and never nil, so only the `Config` ref needs guarding.
  # It is nil in practice: the toolbar can mount before `CODETRACER::no-trace`
  # has delivered a config.
  if config.isNil:
    return ""
  var parts: seq[string] = @[]
  for shortcut in config.shortcutMap.actionShortcuts[action]:
    var name = ($shortcut.renderer).toUpperAscii
    # The two chords whose honest spelling is too wide for a menu column.
    # Preserved from `menu.nim`'s `loadShortcut`, which this replaces.
    if name == "CTRL+PAGEUP":
      name = "CTRL+PGUP"
    elif name == "CTRL+PAGEDOWN":
      name = "CTRL+PGDN"
    parts.add(name)
  parts.join(" ")

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
  ## `DebugControlsVM.invokeToolbarStep` and `onAction` already switch on —
  ## so this table cannot drift from the buttons without the buttons
  ## breaking too.

proc toolbarClientAction*(actionId: string): Option[ClientAction] =
  ## The `ClientAction` behind one toolbar control, or `none` for an id that
  ## is not a toolbar control.
  for entry in debugToolbarActions:
    if entry.id == actionId:
      return some(entry.action)
  none(ClientAction)

proc toolbarChord*(config: Config; actionId: string): string =
  ## The chord currently bound to one debug-toolbar control, or "".
  ##
  ## This is what `ui/debug.nim` injects into `DebugControlsVM.shortcutFor`,
  ## and therefore what ends up inside the parentheses in a tooltip.
  let action = toolbarClientAction(actionId)
  if action.isNone:
    return ""
  renderChord(action.get, config)
