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

# `std/jsffi` FOR `JsAssoc`'s `[]`, which is where the element accessor lives.
import std/jsffi

# `lib/jslib` FOR `JsAssoc.hasKey`, and it is that module rather than `jsffi`
# because `hasKey` is declared there (`jslib.nim:86`) as an `importcpp` over
# `(#[#] != undefined)` — `std/jsffi` does not supply one.
# `ShortcutMap.shortcutActions` is `TableLike[langstring, ClientAction]` and
# `frontend/types.nim` resolves `TableLike` to `JsAssoc`, so this is what makes
# `hardBindShadowedActions` below able to ask whether the config claims a chord.
# `renderChord` needs none of it — `actionShortcuts` is a plain `array`.
import ../lib/jslib

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
      # TOGGLE READ-ONLY — `CTRL+E`, spelled as `default_config.yaml` spells it
      # (`aToggleReadOnly: "CTRL+E"`); `ui/shortcuts.nim:18` is what makes that
      # equivalent to Monaco's `CTRL+KeyE`.
      #
      # It is here for the reason `CTRL+B` above is, and the measurement is the
      # same one: a `CTRL+<letter>` keydown raised inside Monaco never reaches
      # `document`'s bubble phase, so the global Mousetrap bind cannot answer
      # it. Measured on the assembled bundle, caret in the editor: `CTRL+E`
      # produced no `shortcuts: global handle` line.
      #
      # WHAT IT REPLACES, so the entry is not read as a new delegation. A
      # hardcoded `commands[cstring"CTRL+KeyE"]` in `ui/editor.nim` used to
      # register this chord on every Monaco instance, calling
      # `data.functions.toggleReadOnly` directly. That is a claim on a chord
      # that neither `conflictList` nor `hardBoundChords` can see, and it made
      # `CTRL+E` dispatch `switchEdit` outside the editor and toggle read-only
      # inside it. Delegating from the CONFIG instead is what makes the two
      # contexts one action.
      #
      # NOT A DOUBLE-DELIVERY, and it is asserted rather than assumed:
      # `ci/test/chord-and-pane-uniqueness.sh` presses `CTRL+E` in both focus
      # contexts and requires `mousetrap`/`monaco` to be `1/0` outside and
      # `0/1` inside, so a Monaco version that started binding `ctrl+e`
      # natively reddens here instead of toggling read-only twice per press.
      "CTRL+E",
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
  # The entries above predate that override and are left alone: F8/F10-F12
  # are chords Monaco itself would otherwise consume, and changing them is a
  # separate question from this one. `F2` is on the list for the same reason and
  # is now live on BOTH paths — see `hardBoundChords` below for what used to
  # make it the exception.

# ---------------------------------------------------------------------------
# THE CHORDS THAT DO NOT COME FROM THE CONFIG, AND THE CONFLICT NOBODY COULD SEE
# ---------------------------------------------------------------------------
#
# `initShortcutMap` (`frontend/config.nim:26`) detects conflicts BETWEEN TWO
# YAML ENTRIES and reports them in `conflictList`. It cannot see a chord that
# never passed through the YAML. About two dozen are bound directly with
# `Mousetrap.bind` in `ui/shortcuts.nim` and `ui_js.nim`, and `Mousetrap.bind`
# REPLACES rather than chains — so wherever such a bind and a config entry name
# the same chord, ONE OF THEM IS DEAD and nothing reports which.
#
# WHICH ONE DIES DEPENDS ON THE FILE, and getting that backwards is how this
# list first reported two non-defects as defects.
#
#   * `ui/shortcuts.nim` — the binds sit INSIDE `configureShortcuts`, below its
#     own loop over the config table. The bind wins; the config entry is dead.
#     This is the F2 defect's mechanism.
#   * `ui_js.nim` — the binds sit in `configure`, which runs at BOOT.
#     `configureShortcuts` runs later, from the `onInit` / `onNoTrace` /
#     `onWelcomeScreen` IPC replies. The CONFIG wins; the hardcoded bind is
#     dead.
#
# Measured on the assembled bundle rather than reasoned from the call graph:
# with the caret outside the editor, `ALT+1` dispatched
# `data.actions[aLowLevel1]` and logged `shortcuts: global handle` — the config
# bind — while `ui_js.nim` still carried `Mousetrap.bind("alt+1")`. A bind that
# loses is still a defect (it is unreachable code claiming a chord), but it is
# the opposite defect from the one this list was built to name, and a report
# that names the wrong casualty sends the next reader to fix the wrong file.
#
# THIS IS NOT HYPOTHETICAL; IT IS THE BUG THIS LIST WAS EXTRACTED FOR.
# `default_config.yaml:67` gives `forwardContinue` two chords, "F8 F2".
# `ui/shortcuts.nim` then carried `Mousetrap.bind("f2") do (): discard`, so
# outside the editor F2 did nothing at all while the menu, every toolbar
# tooltip and the shortcuts dialog went on advertising it — all three RESOLVE
# the chord through `renderChord` above, and the config still said F2. The
# swallow is gone; this list is what makes the NEXT one arrive as a warning and
# a red test instead of as a key that quietly stopped working.
#
# `GUI/Keyboard-Shortcuts-System.md` § Requirements states the rule directly:
# "A chord declared in the config dispatches the action the config gives it. A
# later hardcoded bind that replaces a config-driven one makes the config a lie
# and fails silently... Conflicts between bindings must be detected and
# reported, not resolved by load order."
#
# HAND-MAINTAINED, AND GUARDED AGAINST GOING STALE. Deriving it from the source
# at runtime is not possible, so `shortcut_bindings_test.nim` reads
# `ui/shortcuts.nim` and `ui_js.nim` with `staticRead`, extracts every
# `Mousetrap.bind("...")` literal, and requires each to appear here. Adding a
# hardcoded bind and forgetting this list reddens — which is the whole point,
# because a stale list would make every check over it vacuous.
const hardBoundChords*: seq[cstring] =
  @[
    # `ui/shortcuts.nim`, `configureShortcuts`.
    #
    # `F1` IS THE ONLY DELIBERATE SWALLOW LEFT, and it is harmless precisely
    # because it collides with nothing: no YAML entry names F1, so the bind
    # replaces nothing. The spec's "(disabled) Reserved" row
    # (`GUI/Keyboard-Shortcuts-System.md:33`) named F1 and F2 together; only F1
    # is still true.
    cstring"F1",
    cstring"CTRL+R",
    # `CTRL+B` IS A REAL, DELIBERATE, DOCUMENTED SHADOW — the one member of
    # this list that IS also in the config (`build: "CTRL+B"`) and is meant to
    # be. `ui/shortcuts.nim` records why, and excludes it from the web build
    # where the shadowed action is the only useful one. It is here so that
    # `hardBindShadowedActions` REPORTS it rather than so that it is forbidden:
    # the requirement is that a shadow be visible, not that it never happen.
    cstring"CTRL+B",
    cstring"CTRL+PAGEUP",
    cstring"CTRL+PAGEDOWN",
    cstring"ALT+E",
    cstring"ALT+C",
    cstring"ALT+V",
    cstring"CTRL+ALT+D",
    cstring"CTRL+SHIFT+O",
    cstring"COMMAND+SHIFT+O",
    # THE SIBLING OF THE F2 DEFECT, and the reason this list is not only about
    # F2. `ALT+F10` is `stepOverStatement` and `ALT+SHIFT+F10` is
    # `stepBackStatement`, both bound in code and neither owning a
    # `ClientAction` — so they are invisible to `conflictList`, absent from the
    # shortcuts dialog, and unrebindable. `ALT+F10` is also the obvious reverse
    # of `F10` under the VS Code preset's `ALT` rule; a preset that took it
    # would have had its binding silently replaced here, with nothing anywhere
    # reporting why. `shortcut_presets_test.nim` forbids exactly that.
    cstring"ALT+F10",
    cstring"ALT+SHIFT+F10",
    # `ui_js.nim`.
    #
    # THE LOAD ORDER IS THE OTHER WAY ROUND FOR THIS FILE, which is why
    # `hardBindShadowedActions` below reports what it reports and why two of
    # the entries that used to be here are gone.
    #
    # `configure` (`ui_js.nim`) binds these at BOOT. `configureShortcuts`
    # (`ui/shortcuts.nim`), whose config loop is what they were assumed to
    # overwrite, runs LATER — from `onInit`, `onNoTrace` and `onWelcomeScreen`,
    # which are IPC replies. So for any chord the YAML also declares, the
    # config loop is the last writer and one of these binds is the dead one.
    # Measured on the assembled bundle, and it is the reverse of what the note
    # at the head of this list used to claim.
    #
    # `CTRL+E` and `ALT+1` were here and are deleted from `ui_js.nim`: the YAML
    # declared both, so both binds were already unreachable.
    cstring"CTRL+F5",
    cstring"CTRL+S",
    cstring"CTRL+ENTER",
    cstring"CTRL+SHIFT+E",
  ]
  ## Every chord bound outside the config table, in the spelling
  ## `ShortcutMap.shortcutActions` is keyed by (the YAML's own, upper-case).
  ##
  ## `CTRL+1` .. `CTRL+9` are deliberately absent: they are installed by a loop
  ## over a range rather than as literals, no YAML entry claims any of them, and
  ## listing nine chords to state one fact would be the copy this module exists
  ## to avoid. The staleness guard skips non-literal binds for the same reason.

const PERMITTED_HARD_BIND_SHADOWS*: seq[(cstring, ClientAction)] =
  @[
    # `ui/shortcuts.nim` re-binds `ctrl+b` to `reRecordCurrent(projectOnly =
    # true)` after the config loop, and excludes itself from the web build
    # where the shadowed `build` action is the only useful one. Deliberate,
    # documented at the bind, and the ONE row the spec's table carries.
    (cstring"CTRL+B", ClientAction.build),
  ]
  ## The shadows that are allowed to exist, as
  ## `GUI/Keyboard-Shortcuts-System.md` § "Hard binds are enumerated and their
  ## shadowing is reported" lists them.
  ##
  ## THIS IS A RULE AND NOT A REPORT, which is the difference between it and
  ## `hardBindShadowedActions` below. That proc says what the shipped table
  ## DOES; this says what it is permitted to do. Until this constant existed
  ## the registry only reported, `configureShortcuts` only warned, and a new
  ## shadow could land and go on warning into a log nobody reads —
  ## `shortcut_bindings_test.nim` now fails on any entry this list does not
  ## carry.
  ##
  ## THE ACTION IS PART OF THE PERMISSION, not just the chord. `CTRL+B` is
  ## permitted to shadow `build`; a future YAML that moved some other action
  ## onto `CTRL+B` would be a shadow nobody had agreed to, and pinning the
  ## chord alone would let it through.
  ##
  ## KEPT HONEST AGAINST THE SPEC BY `ci/test/shortcut-shadow-spec-agreement.sh`,
  ## which parses the table out of the spec and this list out of this file and
  ## requires them to name the same rows. A constant that quietly widened would
  ## otherwise be a way to make the gate below agree with itself.

proc hardBindShadowedActions*(config: Config): seq[(cstring, ClientAction)] =
  ## Every chord the config declares that a later hardcoded bind will replace.
  ##
  ## THE POINT IS THAT THIS IS NORMALLY SHORT, NOT THAT IT IS EMPTY. `CTRL+B`
  ## is a deliberate, documented shadow on the desktop, so an empty return would
  ## be wrong there and asserting emptiness would be asserting the wrong thing.
  ## What must never happen again is a shadow nobody can see — so
  ## `configureShortcuts` logs whatever this returns, and the tests pin the
  ## membership rather than the count.
  ##
  ## Pure, and takes the resolved `Config` rather than reading globals, so a
  ## `nim js` suite with no DOM can call it — which is what makes the F2
  ## regression assertable at all.
  if config.isNil:
    return @[]
  for chord in hardBoundChords:
    if config.shortcutMap.shortcutActions.hasKey(chord):
      let shadowed: ClientAction = config.shortcutMap.shortcutActions[chord]
      let entry: (cstring, ClientAction) = (chord, shadowed)
      result.add(entry)

# ---------------------------------------------------------------------------
# THE THIRD REGISTRY: MONACO'S OWN `commands` TABLE
# ---------------------------------------------------------------------------
#
# There were two enumerated claimants on a keyboard chord in this repository
# and a guard that walked both: the YAML table (`conflictList` sees a collision
# between two of its entries) and `hardBoundChords` above (every
# `Mousetrap.bind("...")` literal, checked against the source by
# `shortcut_bindings_test.nim`).
#
# `ui/editor.nim`'s `commands` table is a THIRD, and until this constant
# existed nothing enumerated it. `delegateShortcuts` walks that table and calls
# `monacoEditor.addCommand` for every entry, on every Monaco instance, in every
# build. A chord claimed there is invisible to both existing guards: it never
# passed through the YAML, so `conflictList` cannot see it, and it is not a
# `Mousetrap.bind` literal, so the hard-bind extractor cannot either.
#
# THE COST OF THE INVISIBILITY IS ON THE RECORD TWICE, in this file's own
# history. `CTRL+E` was a `commands` entry that made one key run two different
# actions — `switchEdit` outside the editor, toggle-read-only inside it — and
# `ui/editor.nim` still carries the post-mortem where the entry stood. And
# `ui_js.nim`'s web Run binding was written under the comment "RUN has no
# configured chord, so it gets one that nothing else binds": its author checked
# the two registries that were enumerable and concluded `CTRL+Enter` was free.
# It was not. `commands` had claimed it all along.
#
# So the table is enumerated here, in the same shape and for the same reason
# `hardBoundChords` is: hand-maintained, and guarded against going stale by
# `shortcut_bindings_test.nim`, which `staticRead`s `ui/editor.nim`, extracts
# every literal key of the `commands` table and requires the two lists to name
# the same chords in both directions.

proc canonicalChord*(chord: string): string =
  ## One chord, in the ONE spelling every registry can be compared in.
  ##
  ## THE SPELLING MISMATCH IS THE HAZARD A NAIVE GUARD DIES OF. The three
  ## registries write the same key three ways, because each is written for a
  ## different consumer:
  ##
  ##   * the YAML / `shortcutActions` — `CTRL+E`, `CTRL+PageUp`, and
  ##     `CTRL+KeyS` for the one entry that predates the convention;
  ##   * `Mousetrap.bind` — lower case, `alt+e`, upper-cased on extraction;
  ##   * `ui/editor.nim`'s `commands` — Monaco's own `KeyCode` member names,
  ##     `ALT+KeyE`, `CTRL+Digit3`, because `ui/shortcuts.nim`'s `shortcut()`
  ##     looks the final token up in `monaco.KeyCode` directly.
  ##
  ## String equality across those three answers "no collision" for every
  ## single-letter and digit chord in the product — which is to say it answers
  ## "no collision" for `ALT+KeyE` vs `ALT+E`, the collision that is live right
  ## now. Every comparison must go through here first.
  ##
  ## The transform is `shortcut()`'s, read backwards: that proc turns a
  ## one-character final token into `Key<X>`, so this turns `Key<X>` back into
  ## `<X>`, and `Digit<N>` — which the `CTRL+1..9` loop builds — into `<N>`.
  ## Everything else is upper-cased and left alone.
  var tokens: seq[string] = @[]
  for token in chord.split('+'):
    tokens.add(token.strip().toUpperAscii)
  if tokens.len > 0:
    let last = tokens[^1]
    if last.len == 4 and last.startsWith("KEY"):
      tokens[^1] = last[3 .. 3]
    elif last.len > 5 and last.startsWith("DIGIT"):
      tokens[^1] = last[5 .. ^1]
  result = tokens.join("+")

const MONACO_COMMAND_CHORDS*: seq[cstring] =
  @[
    # `ui/editor.nim`'s `commands`, in `canonicalChord` spelling, in source
    # order. The Monaco spelling each one is written in there is in brackets.
    cstring"ALT+I",       # `ALT+KeyI`  — switchFlowUI(FlowInline)
    # THE SURVIVING INSTANCE OF THE `CTRL+E` BUG, three lines above the comment
    # that diagnoses it. See `KNOWN_MONACO_SEMANTIC_COLLISIONS` below.
    cstring"ALT+E",       # `ALT+KeyE`  — toggleMacroExpansion
    cstring"ALT+T",       # `ALT+KeyT`  — runTracepoints
    cstring"CTRL+ENTER",  # `CTRL+Enter` — runTracepoints
    cstring"CTRL+S",      # `CTRL+KeyS` — update / saveFiles
    cstring"CTRL+F5",     # `CTRL+F5`   — toggleMode
    cstring"CTRL+F8",     # `CTRL+F8`   — editorLineJump(SmartJump)
    cstring"CTRL+F10",    # `CTRL+F10`  — editorLineJump(ForwardJump), run to cursor
    cstring"CTRL+F11",    # `CTRL+F11`  — sourceCallJump(SmartJump)
  ]
  ## Every chord `ui/editor.nim`'s `commands` table claims as a STRING LITERAL.
  ##
  ## `CTRL+1` .. `CTRL+9` ARE DELIBERATELY ABSENT, for the same reason the nine
  ## `CTRL+<n>` Mousetrap binds are absent from `hardBoundChords`: they are
  ## installed by `for i in 1 .. 9: commands[cstring("CTRL+Digit" & $i)] = ...`,
  ## a loop over a range with no literal to extract. The guard skips
  ## non-literals rather than pretending to cover them, and says so.
  ##
  ## `CTRL+E` IS ABSENT BECAUSE IT WAS REMOVED, and the guard asserts its
  ## absence rather than merely omitting it — that is the fix being pinned, not
  ## an oversight being inherited.

const PERMITTED_MONACO_DOUBLE_CLAIMS*: seq[(cstring, cstring)] =
  @[
    # `ui_js.nim`'s `configure`: `Mousetrap.bind("ctrl+f5") do (): data.toggleMode()`.
    # `commands`: `if not data.functions.toggleMode.isNil: data.functions.toggleMode(data)`.
    # One action, reached two ways. The bodies do not MATCH textually — which
    # is exactly why this table is written by hand and not derived from the
    # source: a source-text comparison calls this a semantic collision and
    # reports a false positive, and a guard with three false positives is a
    # guard somebody switches off.
    (cstring"CTRL+F5", cstring"toggle Debug/Edit mode"),
    # `ui_js.nim`: `data.update()`. `commands`: `data.functions.update(data, false)`,
    # falling back to `data.saveFiles`. Same action, same fallback target.
    (cstring"CTRL+S", cstring"save / update the open editors"),
  ]
  ## The chords TWO registries claim FOR THE SAME ACTION.
  ##
  ## THESE ARE CORRECT, NOT TOLERATED, and the distinction matters because the
  ## obvious "fix" — deleting one of the two claims — breaks the key. Monaco
  ## stops keydown propagation before the bubble phase Mousetrap listens on
  ## (measured; see the `CTRL+B` entry in `MONACO_SHORTCUTS_WHITELIST` above),
  ## so the `commands` entry is the ONLY path with the caret in the editor and
  ## the `Mousetrap.bind` is the only path outside it. Both claims are load
  ## bearing; what makes them benign is that they run the same action, so a
  ## user cannot tell which one answered.
  ##
  ## `CTRL+1` .. `CTRL+9` are a third member of this family — `commands` and
  ## `ui/shortcuts.nim` both route them to `onCtrlNumber(i)` — and are absent
  ## for the reason given on `MONACO_COMMAND_CHORDS`: neither side is a literal,
  ## so no guard can see either, and listing them here would claim a coverage
  ## that does not exist.

const KNOWN_MONACO_SEMANTIC_COLLISIONS*: seq[(cstring, cstring, cstring)] =
  @[
    # ALT+E — TWO DIFFERENT ACTIONS, AND THE SPEC ASKS FOR BOTH.
    #
    # `codetracer-specs` `GUI/Keyboard-Shortcuts-System.md` gives this chord to
    # "Focus event log" in its Layer-1 hardcoded-bindings table AND to "Toggle
    # macro expansion" in its Layer-2 Monaco-commands list, in the same
    # document, without noticing. So the product's behaviour — focus the event
    # log with the caret outside the editor, toggle macro expansion with it
    # inside — is what BOTH tables literally ask for, and no source-level fact
    # settles which claimant should lose.
    #
    # WHICH ONE SHOULD WIN, recorded so the decision is not re-derived: the
    # global bind. `ALT+E` is one of three siblings (`ALT+C` focus calltrace,
    # `ALT+V` focus editor view) that form an enumerated, uncontested family,
    # while `toggleMacroExpansion` has no `ClientAction`, no menu item, no
    # tooltip, is unrebindable, and no-ops unless the mouse has already hovered
    # a line (`lastMouseMoveLine != -1`).
    #
    # WHY IT IS NOT FIXED IN THE COMMIT THAT ADDS THIS TABLE: deleting the
    # `commands` entry deletes the ONLY way to invoke macro expansion —
    # `editor.nim:216` is its single call site — and moving it to a free chord
    # is a product decision this change has no measurement to make. The finding
    # is counted here rather than quietly resolved either way.
    #
    # RETIRES WHEN: `toggleMacroExpansion` gets its own chord or a context-menu
    # entry and the `ALT+KeyE` line in `commands` is deleted. The guard then
    # fails on THIS TABLE — an entry naming a collision that no longer exists —
    # so the row cannot be left behind as a lie.
    (cstring"ALT+E",
     cstring"ui/editor.nim `commands`: e.toggleMacroExpansion()",
     cstring"ui/shortcuts.nim `Mousetrap.bind alt+e`: data.focusEventLog()"),
    # CTRL+ENTER — TWO DIFFERENT ACTIONS, IN ONE BUILD ONLY.
    #
    # `commands` runs `runTracepoints(data)` in every build, and `trace.nim`
    # advertises that in three places a user reads: `RUN_TRACE_MESSAGE`, the
    # tracepoint tooltip "Run tracepoints (Ctrl+Enter)", and the results
    # overlay. On the desktop that is the only claim and it is correct.
    #
    # `ui_js.nim`'s `Mousetrap.bind("ctrl+enter") do (): saveThenCompile(runAfter = true)`
    # sits inside `when defined(ctWeb) and not defined(ctInExtension)`, so the
    # collision exists ONLY in the Noir web studio — and there it is the bad
    # kind. Its own comment reads "RUN has no configured chord, so it gets one
    # that nothing else binds", which was written against the two registries
    # that were enumerable; this one was not, and the premise is false.
    #
    # WHAT THE USER GETS, following the propagation fact measured for `CTRL+B`
    # above: with the caret in Monaco the global bind never fires, so in an
    # editor-first product Ctrl+Enter dispatches `runTracepoints` — which in
    # the web studio has no trace and no tracepoint service and returns at
    # `trace.nim`'s "services not yet initialized, skipping". The Run gesture
    # is dead exactly where it is meant to be used, silently.
    #
    # WHICH ONE SHOULD WIN, per build: the web studio's Run in `ctWeb`, and
    # `runTracepoints` everywhere else. That is not a claim either side can be
    # deleted to satisfy — it needs `commands` to become build-aware, or the
    # web Run to be delegated through Monaco instead of through Mousetrap.
    # Landing that without a `ctWeb` browser measurement is how the `ALT+F8`
    # double-fire and the `ctrl+b` dead-bind were introduced, so it is named
    # here and left to the change that can measure it.
    #
    # RETIRES WHEN: the web Run reaches the editor. The guard fails on this
    # table the moment the collision stops being observable.
    (cstring"CTRL+ENTER",
     cstring"ui/editor.nim `commands`: runTracepoints(data)",
     cstring"ui_js.nim (ctWeb only) `Mousetrap.bind ctrl+enter`: saveThenCompile(runAfter = true)"),
  ]
  ## The chords TWO registries claim FOR DIFFERENT ACTIONS: chord, the Monaco
  ## claimant, the other claimant.
  ##
  ## THESE ARE DEFECTS THAT ARE COUNTED, NOT DEFECTS THAT ARE BLESSED. Each row
  ## carries who should win and what retires it, and
  ## `shortcut_bindings_test.nim` requires every row to be OBSERVED — a row
  ## describing a collision that has been fixed fails as loudly as a collision
  ## that has no row. The list is the reason the guard can be green on today's
  ## tree without the finding being deleted.

proc monacoChordCollisions*(config: Config): seq[(cstring, cstring)] =
  ## Every chord `ui/editor.nim`'s `commands` table claims that ANOTHER
  ## registry also claims, paired with the other claimant's name.
  ##
  ## THE CLASSIFICATION IS NOT HERE, and it cannot be. This proc reports the
  ## structural fact — two registries name one chord — because that is the part
  ## derivable from data. Whether the two claimants run the SAME action is a
  ## question about two proc bodies that do not match textually even when the
  ## answer is yes (`CTRL+F5` is `data.toggleMode()` on one side and
  ## `data.functions.toggleMode(data)` on the other), so it is answered by the
  ## two hand-written tables above and enforced as a total, disjoint partition
  ## of what this returns.
  if config.isNil:
    return @[]
  for chord in MONACO_COMMAND_CHORDS:
    if chord in hardBoundChords:
      result.add((chord, cstring"hardBoundChords (a `Mousetrap.bind` literal)"))
    elif config.shortcutMap.shortcutActions.hasKey(chord):
      let claimed: ClientAction = config.shortcutMap.shortcutActions[chord]
      result.add((chord, cstring("default_config.yaml: " & $claimed)))
