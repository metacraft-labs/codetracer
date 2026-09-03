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
## ## THE ARGUMENT FOR THIS DESIGN, AS AN OUTCOME RATHER THAN A PRINCIPLE
##
## The two specs that state these bindings **already contradict each other**,
## and the contradiction is live in the repository right now:
##
## - `GUI/Debugging-Features/Debugger-Controls.md:22` gives Reverse Continue as
##   `Shift+F5` — and line 28 gives `Shift+F5` to Stop as well, in the same
##   table. Line 26 gives Run to Cursor `F8`, which `forwardContinue` holds.
## - `GUI/Keyboard-Shortcuts-System.md:112` gives `reverseContinue: SHIFT+F8`
##   and `stop: SHIFT+F5`.
##
## A label copied from either document is wrong somewhere, and the copy is the
## one the user believes. **Because the tooltip reads the config, it is right
## without anyone adjudicating** — nobody had to decide which spec wins in
## order for the toolbar to stop lying, and nobody has to revisit this file
## when they do decide. That is the whole return on the indirection, and it is
## why "just write the correct string in" is not the cheaper version of this
## change: there is no correct string to write.
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
# ---------------------------------------------------------------------------
# The Monaco delegation whitelist.
#
# MOVED HERE FROM `ui/editor.nim`, unchanged apart from being exported.
# `ui/editor.nim` still owns the delegation itself (`delegateShortcut`); what
# lives here is the LIST, because the list is a claim about the shipped
# binding table and `ui/editor.nim` cannot be imported by a suite — `nim js`
# on it pulls the whole Karax/Monaco tree. This module already compiles into
# `src/frontend/tests/debug_toolbar_tooltips_test.nim`, so the list can now be
# asserted against `defaultRendererConfig()` in
# `src/frontend/tests/shortcut_bindings_test.nim`.
#
# The absence that made that worth doing: `SHIFT+F5` (Stop) was bound in
# `default_config.yaml` and missing from this list, so the command that leaves
# Debug mode did not fire while the caret was in the editor — and nothing
# could say so.
#
# for now applied to user config, but not to commands:
# the commands shortcuts are hardcoded in this file
# so review them if needed!
const MONACO_SHORTCUTS_WHITELIST*: seq[cstring] =
  @[
      "F2",
      "F8",
      "F10",
      "F11",
      "F12",
      "SHIFT+F2",
      # STOP — `SHIFT+F5`, spelled as `default_config.yaml:75` spells it.
      #
      # Required by name: `codetracer-specs` `latest`
      # `GUI/Debugging-Features/Debugger-Controls.md` § "Ending a session from
      # inside it" — "because it must work while the editor holds focus it
      # belongs in `MONACO_SHORTCUTS_WHITELIST` as well as in the YAML".
      #
      # The reason that requirement is not decoration is the one measured for
      # `CTRL+B` below: Monaco stops keydown propagation before the bubble
      # phase Mousetrap listens on, so a global bind cannot fire while the
      # caret is in the editor. Every OTHER debugger control is on this list
      # already; Stop was the one omission, so the command that LEAVES Debug
      # mode was the one command unavailable from the surface a user is
      # looking at when they want to leave it.
      "SHIFT+F5",
      "SHIFT+F8",
      "SHIFT+F10",
      "SHIFT+F11",
      "SHIFT+F12",
      "CTRL+KeyS",
      # BUILD — `CTRL+B`, spelled as `default_config.yaml` spells it.
      #
      # `initShortcutMap` copies the YAML string into `Shortcut.editor`
      # VERBATIM (`common/config.nim`: `editor: normalShortcut`, and
      # `normalize` is the identity), so the entry that matches `build`'s
      # binding is `CTRL+B` and not `CTRL+KeyB`. `ui/shortcuts.nim:18` is what
      # makes the two spellings equivalent to Monaco — a one-character final
      # token becomes `Key<X>` there — so `CTRL+KeyS` above and `CTRL+B` here
      # both resolve, and matching the YAML is what makes the lookup on line
      # 295 hit at all.
      #
      # WHY IT IS NEEDED, measured on the deployed site rather than reasoned
      # from the comment below. `noirstudio.dev`, caret placed in
      # `src/main.nr` by clicking a `.view-line`, then `Ctrl+B`: ZERO
      # `nargo compile` worker starts, zero `.wasm` fetches, and no
      # `shortcuts: global handle ctrl+b build` line. The same page with focus
      # on `<body>`: the build ran, `nbpCompile-exit verdict=npvSucceeded`.
      # Two in-editor trials, one after typing into the buffer — the user's
      # actual gesture — both dead. This is the bug report.
      #
      # WHERE THE EVENT DIES, and it is NOT `stopCallback`. A keydown listener
      # installed before any page script saw `ctrl+b` arrive at `document` in
      # the CAPTURE phase, `defaultPrevented == false`, target
      # `div.native-edit-context` — and then never reach `document` in the
      # BUBBLE phase, which is where Mousetrap listens. Something between the
      # two stops propagation while the caret is in Monaco. So a global bind
      # cannot fire from inside the editor no matter what `stopCallback`
      # answers, because `stopCallback` is only consulted for events that
      # arrive.
      #
      # NOT A DOUBLE-DELIVERY, and this is the question the ALT+F8 note below
      # says to ask. Monaco binds nothing to `ctrl+b`: the standalone editor's
      # own keybinding resolver, queried on the live page, returns an EMPTY
      # list for Ctrl+B/Cmd+B — unlike ALT+F8, which is Monaco's marker
      # navigation and which is why that chord fired twice. The two paths stay
      # exclusive for the reason `ui/shortcuts.nim` records: with the caret in
      # Monaco the event never reaches Mousetrap (measured above), and with
      # the caret outside, the delegated Monaco command does not run.
      "CTRL+B",
      # ---------------------------------------------------------------------
      # THE PRESET CHORDS.
      #
      # Every chord any preset in `ui/shortcut_presets.nim` binds must appear
      # here, for the reason the `SHIFT+F5` and `CTRL+B` entries above already
      # record: Monaco stops keydown propagation before the bubble phase
      # Mousetrap listens on, so a chord off this list is DEAD while the caret
      # is in the editor. In an IDE that is where the caret usually is, so an
      # omission here does not degrade a preset — it silently empties it.
      #
      # THIS LIST IS HAND-MAINTAINED ON PURPOSE. Deriving it from the preset
      # tables would guarantee the containment and thereby make
      # `shortcut_presets_test.nim`'s assertion of it unfalsifiable — a check
      # that cannot fail, which is the failure this repository's test files
      # keep naming. Hand-maintained, adding a preset chord and forgetting this
      # list reddens, which is exactly the `SHIFT+F5` bug caught one step
      # earlier than it was last time.
      #
      # ONLY THE FUNCTION KEYS, and that asymmetry is the whole rule.
      #
      # A chord needs to be here when MONACO WOULD OTHERWISE EAT IT. Monaco
      # binds the function row, so `F5` and the `ALT` forms below must be
      # delegated or they are dead with the caret in the editor. Monaco binds
      # nothing in the `CTRL+ALT+<letter>` family, so the browser-safe preset's
      # nine chords reach `document`'s bubble phase on their own and Mousetrap's
      # global bind already answers them.
      #
      # PUTTING THEM HERE ANYWAY WOULD BE THE `ALT+F8` BUG. Registering a
      # Monaco command for a chord that also reaches Mousetrap is what made
      # `ALT+F8` fire TWICE per press. `default_config.yaml` states the same
      # conclusion from the other side for this exact family — "no chord here
      # is in `ui/editor.nim`'s MONACO_SHORTCUTS_WHITELIST — Monaco binds no
      # CTRL+ALT+<letter> natively" — and the six `CTRL+ALT` chords it already
      # ships are deliberately absent from this list for that reason. The
      # browser-safe preset follows the decision this repository already made
      # rather than reopening it.
      #
      # `shortcut_presets_test.nim` asserts reachability with both arms, so
      # neither "off the list and eaten by Monaco" nor "on the list and fired
      # twice" can be introduced silently.
      #
      # `F5` and `ALT+F5` are the VS Code preset's Continue pair; `ALT+F11` and
      # `ALT+SHIFT+F11` are its two reverse moves. `ALT+F10` is NOT here,
      # because that chord is hard-bound to `stepOverStatement` and no preset
      # may use it.
      "F5",
      "ALT+F5",
      "ALT+F11",
      "ALT+SHIFT+F11",
  ]
  # BUILD-ERROR NAVIGATION IS DELIBERATELY *NOT* IN THE LIST ABOVE, and the
  # reason is worth recording because the obvious change is the wrong one.
  #
  # Mousetrap's DEFAULT `stopCallback` ignores a chord raised inside a
  # textarea, and Monaco's input surface is one — so a global binding would
  # normally never fire while the user was editing, which is the only place
  # anybody presses "go to next error" from. That is what this whitelist is
  # for, and `ALT+F8` was added to it on exactly that reasoning.
  #
  # But `ui/shortcuts.nim:318` overrides `stopCallback` to `return false` for
  # the whole application. The global binding therefore ALREADY fires with the
  # caret in the editor, and adding the chord here made it fire TWICE — once
  # through Mousetrap and once through the delegated Monaco command. Measured
  # in a browser tab: one press of ALT+F8 on a one-error build advanced to the
  # error and then wrapped, reporting "wrapped to first error" for a list the
  # user had not finished walking once.
  #
  # THE SENTENCE ABOVE IS TRUE OF ALT+F8 AND FALSE IN GENERAL — see the
  # `CTRL+B` entry in the list. "The global binding ALREADY fires with the
  # caret in the editor" holds only for chords whose keydown still REACHES
  # `document`'s bubble phase. ALT+F8 does; `ctrl+b` does not, so for it the
  # whitelist is the only path and there is nothing to double up with. The
  # distinguishing question is not `stopCallback`, it is whether Monaco
  # consumes the chord — which `default_config.yaml`'s own note records from
  # the other side: "with the chord removed from the whitelist it fired NOT AT
  # ALL, because Monaco consumed the key before it reached the document."
  #
  # The entries above predate that override and are left alone: F2/F8/F10-F12
  # are chords Monaco itself would otherwise consume, and changing them is a
  # separate question from this one.
