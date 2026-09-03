## Named sets of stepping chords, and the one table every surface reads.
##
## ## What this module is, in one sentence
##
## A preset is a NAMED SET OF DEFAULTS for the nine debugger commands, applied
## to `default_config.yaml`'s `bindings:` block before `initShortcutMap` sees
## it — so a preset is not a second binding mechanism, it is a different set of
## values entering the existing one.
##
## That distinction is the whole design, and it is forced by
## `codetracer-specs` `GUI/Keyboard-Shortcuts-System.md` § Requirements:
##
##     Every binding is customisable through the config. A chord bound in code
##     and not routed through the YAML is one the user cannot change and cannot
##     discover, and the config's own listing of it — if any — is then wrong.
##
## A preset that installed its own `Mousetrap.bind` calls would be exactly the
## "hardcoded bind that makes the config a lie" the next bullet of that section
## forbids. So nothing here binds anything. `applyPreset` rewrites strings in
## the `InputShortcutMap`; `frontend/config.nim` then builds the `ShortcutMap`
## from them, and every existing consumer follows for free:
##
##   * `ui/shortcuts.nim configureShortcuts` binds what the map contains,
##   * `ui/editor.nim delegateShortcuts` delegates what the map contains,
##   * `ui/shortcut_labels.nim renderChord` LABELS what the map contains,
##   * `ui/menu.nim loadShortcut` and `debug_controls_vm.toolbarTooltip` read
##     that same label.
##
## ## WHY THE DISPLAYED TEXT CANNOT DRIFT FROM THE BINDING
##
## Because there is no second place to write it. `renderChord` already derives
## a tooltip from `config.shortcutMap.actionShortcuts`, and a preset changes
## precisely that structure. There is no per-preset label table, and adding one
## would reintroduce the defect `shortcut_labels.nim`'s header was written
## against — a hardcoded `text "Next (F10)"` that agreed with the config only
## by coincidence.
##
## `Debugger-Controls.md` states the rule this preserves:
##
##     A tooltip must render the chord that is currently bound, resolved from
##     `data.config.shortcutMap`, not a string copied from the config file at
##     authoring time.
##
## ## WHY EVERY PRESET CHORD MUST BE ON THE MONACO WHITELIST
##
## `ui/editor.nim` delegates a chord into Monaco only if it appears in
## `MONACO_SHORTCUTS_WHITELIST`, and with the caret in the editor Monaco
## `stopPropagation`s before the bubble phase Mousetrap listens on. So a chord
## off that list is DEAD while the caret is in the editor — which, in an IDE,
## is where the caret usually is.
##
## That is not a hypothetical. `SHIFT+F5` (Stop) was bound in the YAML and
## missing from the list, so the one command that LEAVES Debug mode was the one
## command unavailable from the surface a user is looking at when they want to
## leave it. `CTRL+B` (Build) was the same bug, measured on the deployed site.
##
## `shortcut_presets_test.nim` asserts the containment for every chord of every
## preset. The whitelist is deliberately still a HAND-MAINTAINED list rather
## than something derived from these tables: a derived list would make that
## assertion a tautology, and the assertion is the only thing standing between
## a new preset and a repeat of the `SHIFT+F5` omission.
##
## ## WHY BARE LETTERS ARE NOT AVAILABLE HERE, though a sibling product uses them
##
## BlockTracer's debug route binds `n` / `s` / `f` / `c` unmodified, and is
## right to: that surface is read-only and has no text entry. This one is an
## EDITOR. A bare letter is text, and a preset that bound one would type into
## the buffer or step the program depending on focus. Every preset below is
## therefore modified or a function key — which is also why none of them can be
## hazard-free by being unmodified, and why `hazardOf` exists instead.

import std/[strutils, options]

import ../types

type
  ShortcutPresetId* = enum
    ## Which named set is in force.
    ##
    ## The string values are WIRE SPELLINGS. They are written to
    ## `localStorage` and read back by `parsePresetId`, and they are the
    ## `value=` of the dialog's radios, so renaming one is a migration and not
    ## a rename.
    spCodeTracer = "codetracer"
    spVsCode = "vscode"
    spChorded = "chorded"
    spNone = "none"

  PresetBinding* = object
    ## One action and the chord a preset gives it.
    ##
    ## `chord` is the YAML spelling — uppercase, `+`-joined, exactly the form
    ## `default_config.yaml` uses and `Shortcut.editor` carries verbatim. It is
    ## NOT a Mousetrap spelling; `initShortcutMap` lowercases it into
    ## `Shortcut.renderer` on the way past, and that one conversion staying in
    ## one place is why a preset cannot get the two spellings out of step.
    action*: ClientAction
    chord*: string

  ShortcutPreset* = object
    id*: ShortcutPresetId
    bindings*: seq[PresetBinding]

  ChordHazard* = enum
    ## What the platform does to a chord before the page can see it.
    ##
    ## DERIVED from the chord and the platform, never stored beside it — so a
    ## preset cannot claim a key is safe that `hazardOf` knows is not.
    chNone
    chBrowserReserved   ## consumed above the page; it never arrives
    chMacFunctionRow    ## a media key on macOS unless the user changed a setting
    chShadowsBrowser    ## the page CAN take it, but it is also a browser habit

const PresetActions*: array[9, ClientAction] = [
  ClientAction.forwardContinue,
  ClientAction.reverseContinue,
  ClientAction.forwardNext,
  ClientAction.reverseNext,
  ClientAction.forwardStep,
  ClientAction.reverseStep,
  ClientAction.forwardStepOut,
  ClientAction.reverseStepOut,
  ClientAction.stop,
]
  ## The actions a preset governs, and the only ones it may rebind.
  ##
  ## This is exactly the `debuggerCommands` family `shortcut_bindings_test.nim`
  ## already asserts reaches Monaco — the nine commands that move or end a
  ## replay. `shortcut_presets_test.nim` pins the two lists equal, so the two
  ## cannot drift apart.
  ##
  ## WHAT IS DELIBERATELY NOT HERE. The toolbar paints thirteen controls
  ## (`debugToolbarActions`), and the other four — history back/forward, run to
  ## entry, reset, run tests — are NOT preset-governed. They are not directional
  ## stepping moves, no surveyed product varies them between keymaps, and
  ## `aHistoryBack`/`aHistoryForward` have no chord in the YAML at all. A preset
  ## that claimed them would be claiming to rebind chords that do not exist.

# ---------------------------------------------------------------------------
# THE PRESETS
# ---------------------------------------------------------------------------

const CodeTracerBindings = [
  # THE DEFAULT, AND IT IS BYTE-FOR-BYTE WHAT `default_config.yaml` ALREADY
  # SHIPS. That equality is asserted, not intended: `shortcut_presets_test.nim`
  # compares this table against `defaultRendererConfig()`'s own parse of the
  # YAML, chord by chord and in both spellings.
  #
  # WHY THE DEFAULT IS THE SHIPPED SET RATHER THAN THE SAFEST SET. Every user
  # who has ever pressed F10 here has today's bindings in their fingers, and
  # nobody has chosen anything yet — `parsePresetId` returns this for an absent
  # `localStorage` key. A default that differed would be a silent global
  # rebinding delivered as a side effect of adding a settings dialog, which is
  # the opposite of what a settings dialog is for.
  #
  # It is NOT the hazard-free preset, and that is stated rather than hidden:
  # `F11` and `F12` are taken above the page in every mainstream browser and
  # the whole function row is media keys on a default Mac. `spChorded` below
  # exists for exactly that reason, and the dialog says so per row.
  (ClientAction.forwardContinue, "F8 F2"),
  (ClientAction.reverseContinue, "SHIFT+F8"),
  (ClientAction.forwardNext, "F10"),
  (ClientAction.reverseNext, "SHIFT+F10"),
  (ClientAction.forwardStep, "F11"),
  (ClientAction.reverseStep, "SHIFT+F11"),
  (ClientAction.forwardStepOut, "F12"),
  (ClientAction.reverseStepOut, "SHIFT+F12"),
  (ClientAction.stop, "SHIFT+F5"),
]

const VsCodeBindings = [
  # VS CODE'S SET, for the muscle memory of everyone who has debugged in an
  # editor — and the set vscode.dev, github.dev and Gitpod's browser IDE all
  # ship unchanged, since their debug keybindings are byte-identical to
  # `microsoft/vscode`'s.
  #
  # `F5` continue, `F10` step over, `F11` step into, `SHIFT+F11` step out.
  #
  # THE REVERSE MOVES TAKE `ALT`, and they have to come from somewhere else
  # because VS Code has no reverse moves to copy. `SHIFT` is not available for
  # "backwards" here — `SHIFT+F11` is already Step Out in the set being
  # reproduced — so this preset cannot carry the desktop app's "Shift means
  # backwards" rule. That is the cost of adopting a keymap designed for a
  # debugger that only goes forwards, and it is why this is not the default.
  #
  # NOT `ALT+F8`, anywhere in this table. Monaco binds `ALT+F8` natively to its
  # marker navigation, and this repository has already measured what that
  # costs: whitelisted, the chord fired TWICE per press; not whitelisted, it
  # fired not at all. `default_config.yaml` records the measurement and routes
  # build-error navigation to `CTRL+ALT+N`/`CTRL+ALT+P` because of it.
  #
  # AND NOT `ALT+F10`, WHICH IS THE SAME TRAP ONE STEP FURTHER ON. The obvious
  # reverse of `F10` under the `ALT` rule is `ALT+F10`, and `ui/shortcuts.nim`
  # HARD-BINDS that chord to `stepOverStatement` — with `ALT+SHIFT+F10` for
  # `stepBackStatement` beside it. Hard-bound chords are invisible to
  # `initShortcutMap`, so they never appear in `conflictList` and no
  # config-level check can see them; and because `configureShortcuts` registers
  # them AFTER the loop over the YAML table, `Mousetrap.bind` silently replaces
  # the preset's handler with theirs. The preset's Step Back would simply have
  # stopped working, with nothing anywhere reporting why.
  #
  # So `reverseNext` takes `SHIFT+F10` — which is CodeTracer's own reverse of
  # `F10` and is free in this set, since VS Code spends `SHIFT` only on
  # `SHIFT+F11`. `shortcut_presets_test.nim` pins every preset chord against
  # the hard-bound list for exactly this reason.
  #
  # `stop` keeps `SHIFT+F5`, which is VS Code's Stop as well as CodeTracer's —
  # the one chord the two sets already agree on.
  (ClientAction.forwardContinue, "F5"),
  (ClientAction.reverseContinue, "ALT+F5"),
  (ClientAction.forwardNext, "F10"),
  (ClientAction.reverseNext, "SHIFT+F10"),
  (ClientAction.forwardStep, "F11"),
  (ClientAction.reverseStep, "ALT+F11"),
  (ClientAction.forwardStepOut, "SHIFT+F11"),
  (ClientAction.reverseStepOut, "ALT+SHIFT+F11"),
  (ClientAction.stop, "SHIFT+F5"),
]

const ChordedBindings = [
  # THE HAZARD-FREE SET, and the answer to an open question this repository
  # has been carrying. `Debugger-Controls.md` says, of the desktop F-key set:
  #
  #     A web page cannot simply adopt it: `F12` opens the browser's developer
  #     tools and a page cannot prevent it, `F11` is fullscreen, and on macOS
  #     — where the report came from — all four are system media keys unless
  #     the user has changed a global setting.
  #
  # No function key appears below, so none of that applies to any row.
  #
  # WHY `CTRL+ALT+<letter>` AND NOT SOMETHING BETTER KNOWN.
  #
  #   * NOT bare letters. This is an editor; a bare letter is text. That is the
  #     one thing separating this preset from BlockTracer's, whose surface has
  #     no text entry.
  #   * NOT `CTRL+SHIFT+<letter>`, which looks tidier and is a minefield: the
  #     browser owns `CTRL+SHIFT+N` (incognito), `T` (reopen tab), `W`, `Q`,
  #     `P` (private window), and `I`/`J`/`C` (developer tools). A preset built
  #     on that family would be hazardous in most of its rows.
  #   * NOT Chrome DevTools' `Cmd/Ctrl+\`, `'`, `;` family, which three
  #     independent products do ship. Those are dispatched from a physical key
  #     position; matched by character, `;` and `'` land on different keys on
  #     AZERTY and most non-US layouts, so the chord would move for a French or
  #     German user. Letters do not move.
  #
  # `CTRL+ALT+<letter>` is the family this repository already reached for and
  # already proved: `default_config.yaml` routes build-error navigation to
  # `CTRL+ALT+N`/`CTRL+ALT+P` after measuring that they are "claimed by nothing
  # in this file, are not hard-bound in `ui/shortcuts.nim`, and are not Monaco
  # defaults -- so exactly one handler runs, and it runs with the caret" in the
  # editor. Every chord below is from that same family and collides with
  # neither of those two.
  #
  # SHIFT IS BACKWARDS, which is the desktop product's own convention
  # (`SHIFT+F8`/`SHIFT+F10`/`SHIFT+F11`/`SHIFT+F12` are the reverse of their
  # bare forms) carried over intact. It is available here, unlike in the VS
  # Code preset, because nothing in this set already spends `SHIFT`.
  #
  # THE LETTERS ARE WHAT WAS LEFT, and the shortlist is short. Seven members of
  # the `CTRL+ALT+<letter>` family are already spoken for and none of them is
  # visible from a keymap table: `N` and `P` are build-error navigation, `B`
  # and `F` are history back/forward, `E` is run-to-entry and `R` is
  # reset-operation (all six in `default_config.yaml`), and `D` is hard-bound
  # to open the developer tools in `ui/shortcuts.nim`. gdb's own letters are
  # therefore mostly unavailable — `n` (next) and `f` (finish) are both taken —
  # so these are the actions' initials instead: `g` go, `o` over, `s` step,
  # `t` ou(t), `x` exit.
  #
  # `I`, `J`, `C` AND `U` ARE AVOIDED DELIBERATELY. On macOS `CTRL` reaches
  # Monaco as `KeyMod.CtrlCmd`, which is COMMAND — and `Cmd+Opt+I`, `Cmd+Opt+J`
  # and `Cmd+Opt+C` are the browser's own developer-tools chords while
  # `Cmd+Opt+U` is View Source. Choosing any of those letters would have put a
  # browser-reserved chord into the one preset whose entire purpose is not
  # having one.
  (ClientAction.forwardContinue, "CTRL+ALT+G"),
  (ClientAction.reverseContinue, "CTRL+ALT+SHIFT+G"),
  (ClientAction.forwardNext, "CTRL+ALT+O"),
  (ClientAction.reverseNext, "CTRL+ALT+SHIFT+O"),
  (ClientAction.forwardStep, "CTRL+ALT+S"),
  (ClientAction.reverseStep, "CTRL+ALT+SHIFT+S"),
  (ClientAction.forwardStepOut, "CTRL+ALT+T"),
  (ClientAction.reverseStepOut, "CTRL+ALT+SHIFT+T"),
  (ClientAction.stop, "CTRL+ALT+X"),
]

const DefaultShortcutPresetId* = spCodeTracer
  ## What a user who has chosen nothing gets: today's shipped bindings.
  ##
  ## `parsePresetId` returns this for an absent key, an empty string and an
  ## unrecognised value, so every path that fails to produce a choice produces
  ## the bindings the product had before presets existed.

proc presetOf*(id: ShortcutPresetId): ShortcutPreset =
  ## The bindings a preset installs.
  ##
  ## `spNone` returns an EMPTY list and is not a degenerate case to be tidied
  ## away: it is a choice a user can make, and it means "leave the nine
  ## debugger commands unbound". `applyPreset` implements that by REMOVING the
  ## keys rather than by leaving the YAML's, which is what makes the dialog's
  ## "no stepping shortcuts" claim true rather than decorative.
  result.id = id
  case id
  of spNone: discard
  of spCodeTracer:
    for (a, c) in CodeTracerBindings:
      result.bindings.add PresetBinding(action: a, chord: c)
  of spVsCode:
    for (a, c) in VsCodeBindings:
      result.bindings.add PresetBinding(action: a, chord: c)
  of spChorded:
    for (a, c) in ChordedBindings:
      result.bindings.add PresetBinding(action: a, chord: c)

proc presetName*(id: ShortcutPresetId): string =
  ## What the preset is called in the dialog.
  case id
  of spCodeTracer: "CodeTracer"
  of spVsCode: "VS Code"
  of spChorded: "Browser-safe"
  of spNone: "None"

proc presetWhy*(id: ShortcutPresetId): string =
  ## One sentence saying who each preset is FOR.
  ##
  ## Four bare names would make a user guess, and the thing they most need to
  ## know — that two of these four are built from keys the browser or the
  ## platform may take first — is exactly what a name cannot carry.
  case id
  of spCodeTracer:
    "What CodeTracer has always bound. Function keys; some are taken by the browser."
  of spVsCode:
    "The editor bindings, for muscle memory. Function keys, and F5 is also reload."
  of spChorded:
    "No function keys. Every chord reaches the page on every platform."
  of spNone:
    "No stepping shortcuts. The toolbar buttons still work."

proc parsePresetId*(s: string): ShortcutPresetId =
  ## A stored value back into a preset, tolerantly.
  ##
  ## An unrecognised string is the DEFAULT rather than an error. This is
  ## BlockTracer `Configuration.md` §4's forward-compatibility rule applied at
  ## the field level — "an older build encountering a newer `bt.version` resets
  ## to defaults rather than misinterpreting" — and the consequence of getting
  ## it wrong is a user with no stepping chords at all after a rollback.
  ##
  ## `"none"` is a REAL STORED VALUE and must not be confused with "unset".
  ## A user who chose None and got the default back on reload would have their
  ## choice silently reversed.
  for id in ShortcutPresetId:
    if $id == s:
      return id
  DefaultShortcutPresetId

proc chordFor*(preset: ShortcutPreset; action: ClientAction): Option[string] =
  ## The chord a preset gives an action, or `none`.
  for b in preset.bindings:
    if b.action == action:
      return some(b.chord)
  none(string)

proc actionFor*(preset: ShortcutPreset; chord: string): Option[ClientAction] =
  ## Which action a chord means in this preset, or `none`.
  ##
  ## The inverse of `chordFor` over the same sequence, which is what makes
  ## "a chord that is displayed is a chord that dispatches" checkable rather
  ## than merely intended.
  for b in preset.bindings:
    if b.chord == chord:
      return some(b.action)
  none(ClientAction)

# ---------------------------------------------------------------------------
# Chord spelling
# ---------------------------------------------------------------------------

proc chordTokens*(chord: string): seq[string] =
  ## A chord split into its modifier tokens and its key, e.g.
  ## `"CTRL+ALT+SHIFT+R"` into `@["CTRL", "ALT", "SHIFT", "R"]`.
  ##
  ## THIS EXISTS BECAUSE `ui/shortcuts.nim shortcut()` USED `split("+", 2)`,
  ## which is a maximum of two splits and therefore a maximum of THREE tokens.
  ## A four-token chord parsed its key as `"SHIFT+R"`, `monaco.KeyCode` had no
  ## such member, and `shortcut()` returned `NO_CODE` — so the chord was never
  ## registered with Monaco and was dead with the caret in the editor, silently
  ## and with only a `cerror` line to show for it.
  ##
  ## That limit is why `spChorded` could not have used `SHIFT` for its reverse
  ## moves before this, and it is recorded as a known limitation in
  ## `default_config.yaml`. `shortcut()` now calls this, so the two cannot
  ## disagree about where a chord's key ends.
  chord.split('+')

proc chordKeyToken*(chord: string): string =
  ## The key half of a chord — the last token.
  let tokens = chordTokens(chord)
  if tokens.len == 0: "" else: tokens[^1]

proc describeChord*(chord: string; mac: bool): string =
  ## A chord as a reader sees it.
  ##
  ## THE ONLY PLATFORM DIFFERENCE IS THE NAME OF ONE MODIFIER, and getting it
  ## wrong has already cost this product a bug report. `ui/shortcuts.nim`
  ## `shortcut()` maps `CTRL` onto Monaco's `KeyMod.CtrlCmd`, which Monaco
  ## defines as COMMAND on macOS — so a chord the config and every label spell
  ## `CTRL+B` was answered in the editor by `Cmd+B` and not by `Ctrl+B`.
  ##
  ## `delegateShortcut` now registers a second command under `KeyMod.WinCtrl`
  ## on macOS, so the literal Control key works there too and the label is not
  ## false. But "Ctrl" is still the wrong FIRST thing to show a Mac user, whose
  ## every other application spells this modifier `⌘`. So the dialog prints
  ## `Cmd` on macOS and `Ctrl` elsewhere, and this is the single place that
  ## decision is made.
  ##
  ## Multi-chord bindings ("F8 F2") are space-separated in the YAML and are
  ## spelled through this proc one chord at a time.
  var spelled: seq[string] = @[]
  for single in chord.splitWhitespace():
    var parts: seq[string] = @[]
    let tokens = chordTokens(single)
    for i, token in tokens:
      if i == tokens.len - 1:
        parts.add token
      else:
        case token
        of "CTRL": parts.add(if mac: "Cmd" else: "Ctrl")
        of "ALT": parts.add(if mac: "Option" else: "Alt")
        of "SHIFT": parts.add "Shift"
        else: parts.add token
    spelled.add parts.join("+")
  spelled.join(" ")

proc hazardOf*(chord: string; mac: bool): ChordHazard =
  ## What the platform does to this chord before the page can see it.
  ##
  ## COMPUTED from the chord and the platform, never stored on a preset.
  ##
  ## `F11` and `F12` are consumed above the page on every desktop browser this
  ## product targets — fullscreen and developer tools. A page cannot
  ## `preventDefault` either, because the event is not dispatched to the
  ## document at all, and `SHIFT` does not rescue them.
  ##
  ## `F5` IS deliverable — reload is preventable — and is flagged anyway,
  ## because the habit is near-universal and the surprise is expensive: a user
  ## who presses F5 expecting a refresh and gets a `continue` has lost their
  ## place. Checked BEFORE the macOS branch, because on a Mac F5 is both a
  ## function-row key and the reload habit, and the reload habit is the one
  ## that costs the user their position.
  ##
  ## The rest of the function row reaches a page; the only thing between it and
  ## a Mac user is the function-key preference, which is a WEAKER statement
  ## than browser-reserved — the user can change it, or hold `Fn` — so it is a
  ## different hazard with a different sentence.
  for single in chord.splitWhitespace():
    let key = chordKeyToken(single)
    if key.len >= 2 and key[0] == 'F' and key[1] in {'0' .. '9'}:
      if key == "F11" or key == "F12":
        return chBrowserReserved
      if key == "F5":
        return chShadowsBrowser
      if mac:
        return chMacFunctionRow
  chNone

proc hazardText*(h: ChordHazard): string =
  ## The sentence the dialog prints beside a row. Empty when there is nothing
  ## to say, so the caller renders nothing rather than the word "None".
  case h
  of chNone: ""
  of chBrowserReserved:
    "your browser takes this key before the page can see it"
  of chMacFunctionRow:
    "a media key on this Mac unless you hold Fn, or turn on " &
      "\"Use F1, F2, etc. keys as standard function keys\""
  of chShadowsBrowser:
    "this is also your browser's reload — the page takes it here"

proc hazardMarker*(h: ChordHazard): string =
  ## The stable token a test and the DOM both use for a hazard.
  case h
  of chNone: ""
  of chBrowserReserved: "reserved"
  of chMacFunctionRow: "mac-fn"
  of chShadowsBrowser: "shadows-reload"

const ShortcutPresetStorageKey* = "codetracer.ui.keymap"
  ## Where an anonymous user's choice lives.
  ##
  ## The dotted-lowercase shape is this product's existing one for browser
  ## storage — `web_project_persistence.nim` uses
  ## `codetracer.durability.told` — and the `keymap` leaf is the name
  ## BlockTracer `Configuration.md` §4 already reserved for this exact setting
  ## (`"bt.ui": { ..., "keymap": "default", ... }`). Naming it anything else
  ## would give one preference two names across two products in one family.
