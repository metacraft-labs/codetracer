## The shortcut presets bind what they display, and reach the editor.
##
## LANE: `frontend-js` (listed in `ci/lib/test-lane-files.sh`). JS backend
## only, for the same reason `shortcut_bindings_test.nim` is: `frontend/config.nim`
## is built on `std/jsffi`'s `JsAssoc`.
##
## Compile and run:
##   nim js -r src/frontend/tests/shortcut_presets_test.nim
##
## ## The failure this file is written against
##
## A preset system has one interesting way to be wrong and it is not "the
## chords are ugly". It is that THE CHORD SHOWN AND THE CHORD THAT WORKS COME
## APART — a tooltip or a dialog naming `F10` while the dispatcher answers
## something else, or naming a chord that no surface listens for at all. The
## sibling product's own specs already did this to themselves:
## `Debugger-Controls.md` gives `Shift+F5` to Reverse Continue *and* to Stop in
## one table, while `Keyboard-Shortcuts-System.md` gives `reverseContinue:
## SHIFT+F8`. A user who believes the wrong copy learns that the shortcuts do
## not work.
##
## So nothing below asserts that a handler exists. Every assertion is about a
## VALUE: the chord string a surface would render, and the `ClientAction` a
## press would dispatch.
##
## ## EVERY CLAIM HAS A NEGATIVE
##
## The discipline is borrowed from a suite that shipped green over a broken
## feature: a renderer that ignores its preset argument satisfies "the dialog
## lists the bindings" perfectly. So it is never enough that a preset renders
## chords — a DIFFERENT preset must render DIFFERENT chords, and `spNone` must
## render none. Where a count is asserted, it is asserted against a keymap
## whose length is not the length every preset happens to share, because a
## mutation replacing `$len` with the literal `"9"` survives otherwise.
##
## ## Nothing here writes a chord as an expected literal
##
## …except in the two tests where the SPELLING RULE itself is the subject, and
## in the one test that pins the default preset against the shipped YAML. A
## purely relational suite is correctly insensitive to both sides being wrong
## together, which is why that pin exists.

import std/[strutils, unittest, options, sets, jsffi]

import ../config
import ../types
import ../lib/jslib
from ../ui/shortcut_labels import
  MONACO_SHORTCUTS_WHITELIST, renderChord, hardBoundChords

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 526
  ## 525 before the F2 fix. The hard-bind case swapped its `"F2" in
  ## hardSwallowed` pin for `"F2" notin hardBoundChords` (one for one) and
  ## added `"F1" in hardBoundChords` beside it, so that the absence being
  ## asserted is an absence from a registry that demonstrably contains things.

const boundPresets = [spCodeTracer, spVsCode, spChorded]
  ## The presets that bind something. `spNone` is the negative and is used as
  ## one throughout rather than iterated with these.

proc chordsFor(config: Config; action: ClientAction): seq[Shortcut] =
  for shortcut in config.shortcutMap.actionShortcuts[action]:
    result.add(shortcut)

proc conflictedChords(config: Config): seq[string] =
  for pair in config.shortcutMap.conflictList:
    result.add($pair[0])

suite "shortcut presets":

  test "a chord that is DISPLAYED is a chord that DISPATCHES — the round trip":
    ## The one invariant the whole design rests on. `chordFor` is what a
    ## dialog row and a tooltip are built from; `actionFor` is the inverse the
    ## dispatcher's table realises. If the two ever disagree, a user is shown a
    ## key that does nothing.
    for id in boundPresets:
      let preset = presetOf(id)
      counted preset.bindings.len > 0   # nothing here quantifies over nothing
      for b in preset.bindings:
        let dispatched = preset.actionFor(b.chord)
        counted dispatched.isSome
        counted dispatched.get == b.action
        let shown = preset.chordFor(b.action)
        counted shown.isSome
        counted shown.get == b.chord

  test "no preset gives one chord two meanings, or one move two chords":
    ## A duplicate would make dispatch depend on binding order — and worse,
    ## `initShortcutMap` is FIRST-WRITER-WINS, so the second claim would not be
    ## registered at all. It would land in `conflictList`, which only a warning
    ## nobody reads consumes, and the action would end up with no chord.
    for id in boundPresets:
      let preset = presetOf(id)
      var chords: HashSet[string]
      var actions: HashSet[string]
      for b in preset.bindings:
        chords.incl b.chord
        actions.incl $b.action
      counted chords.len == preset.bindings.len
      counted actions.len == preset.bindings.len

  test "every preset binds every move it governs, and no other":
    ## The dialog's claim to list the bound set is only meaningful if the bound
    ## set IS the governed set.
    var governed: HashSet[string]
    for action in PresetActions:
      governed.incl $action
    counted governed.len == PresetActions.len
    for id in boundPresets:
      let preset = presetOf(id)
      var bound: HashSet[string]
      for b in preset.bindings:
        bound.incl $b.action
      counted bound == governed
    # THE NEGATIVE. `spNone` binds none of them, so the equality above is a
    # statement about the presets and not something every value satisfies.
    counted presetOf(spNone).bindings.len == 0

  test "the governed set is exactly the family already proved to reach Monaco":
    ## `PresetActions` and `shortcut_bindings_test.nim`'s `debuggerCommands`
    ## are one fact written twice, in two files. Pinned equal so a preset
    ## cannot start governing an action whose editor reachability nothing
    ## asserts.
    const debuggerCommands = [
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
    counted PresetActions.len == debuggerCommands.len
    for action in debuggerCommands:
      counted action in PresetActions

  test "EVERY preset chord reaches the caret in the editor, by one route or the other":
    ## THE CODETRACER-SPECIFIC INVARIANT, and it has a shipped bug behind it in
    ## BOTH directions — which is why it is not simply "everything is
    ## whitelisted".
    ##
    ## OFF THE LIST AND EATEN. `ui/editor.nim` delegates a chord into Monaco
    ## only if it is in `MONACO_SHORTCUTS_WHITELIST`, and for a chord Monaco
    ## binds natively Monaco stops keydown propagation before the bubble phase
    ## Mousetrap listens on. `SHIFT+F5` (Stop) was missing, so the one command
    ## that LEAVES Debug mode was unavailable from the editor; `CTRL+B` (Build)
    ## was missing and was measured dead on the deployed site.
    ##
    ## ON THE LIST AND DOUBLED. A chord Monaco does NOT bind reaches `document`
    ## on its own, so Mousetrap's global bind already answers it — and adding a
    ## Monaco command as well made `ALT+F8` fire TWICE per press.
    ##
    ## So reachability has two arms and each chord must satisfy exactly one:
    ## a function key must be delegated, and a `CTRL+ALT+<letter>` chord must
    ## not be. `default_config.yaml` records the measurement the second arm
    ## rests on — "Monaco binds no CTRL+ALT+<letter> natively" — and already
    ## ships six such chords deliberately absent from the whitelist.
    var delegated = 0
    var uncontested = 0
    for id in boundPresets:
      let preset = presetOf(id)
      for b in preset.bindings:
        # A binding may carry two chords ("F8 F2"); each must reach the editor.
        for single in b.chord.splitWhitespace():
          let key = chordKeyToken(single)
          let isFunctionKey = key.len >= 2 and key[0] == 'F' and
            key[1] in {'0' .. '9'}
          checkpoint($id & " " & $b.action & " -> " & single &
            (if isFunctionKey: " (must be delegated)"
             else: " (must NOT be delegated)"))
          if isFunctionKey:
            counted cstring(single) in MONACO_SHORTCUTS_WHITELIST
            inc delegated
          else:
            # Monaco binds nothing here, so a Monaco command would be the
            # second delivery that made ALT+F8 fire twice.
            counted cstring(single) notin MONACO_SHORTCUTS_WHITELIST
            counted single.startsWith("CTRL+ALT+")
            inc uncontested
    # Pinning both totals is what stops this passing over a loop that ranged
    # over an empty preset table, and what makes the split itself visible: the
    # two F-key presets contribute 19 chords, the browser-safe one 9.
    counted delegated == 19
    counted uncontested == 9

  test "the reachability assertion can fail — the whitelist is not everything":
    ## The containment above is only informative if the whitelist is not simply
    ## every string. These are real chords the product binds elsewhere and
    ## deliberately does not delegate, so membership discriminates.
    for absent in ["CTRL+ALT+N", "CTRL+ALT+P", "ALT+F8", "CTRL+P", "CTRL+M",
                   "ALT+F10"]:
      counted cstring(absent) notin MONACO_SHORTCUTS_WHITELIST
    # And the entries a preset genuinely needs ARE there, so the first arm is
    # not passing because the list is empty.
    for present in ["F5", "ALT+F5", "ALT+F11", "ALT+SHIFT+F11", "SHIFT+F5"]:
      counted cstring(present) in MONACO_SHORTCUTS_WHITELIST

  test "no preset chord is one that `ui/shortcuts.nim` HARD-BINDS":
    ## THE COLLISION `conflictList` CANNOT SEE, and the one that already
    ## claimed a chord in the first draft of this feature.
    ##
    ## About two dozen chords are bound directly with `Mousetrap.bind` in
    ## `ui/shortcuts.nim` and `ui_js.nim`, never passing through the YAML. They
    ## are therefore invisible to `initShortcutMap`, absent from
    ## `conflictList`, and — because `configureShortcuts` registers them AFTER
    ## the loop over the config table — they silently REPLACE any binding the
    ## table gave the same chord. A preset that used one would simply stop
    ## working, with no conflict reported anywhere.
    ##
    ## `ALT+F10` is the live example: it is `stepOverStatement`, and it is the
    ## obvious reverse of `F10` under the VS Code preset's `ALT` rule. That
    ## preset uses `SHIFT+F10` instead because of this test.
    ## THE LIST IS NO LONGER A COPY. It used to be an 18-entry literal right
    ## here, restating what `ui/shortcuts.nim` and `ui_js.nim` do — and a
    ## restatement of another file's behaviour goes stale silently, which is
    ## how it kept saying `F2` was swallowed after the swallow was removed.
    ## `ui/shortcut_labels.nim` now owns `hardBoundChords`, and
    ## `shortcut_bindings_test.nim` derives it from those two files with
    ## `staticRead` — so this suite reads a list something else is responsible
    ## for keeping true.
    var hardBound: seq[string] = @[]
    for chord in hardBoundChords:
      hardBound.add($chord)
    var checkedPairs = 0
    for id in boundPresets:
      for b in presetOf(id).bindings:
        for single in b.chord.splitWhitespace():
          checkpoint($id & " " & single)
          counted single notin hardBound
          inc checkedPairs
    counted checkedPairs == 28
    # THE NEGATIVE: the list is real and this comparison discriminates —
    # `CTRL+B` really is hard-bound, and really is a chord the product uses.
    counted "CTRL+B" in hardBound
    counted "ALT+F10" in hardBound
    counted "F10" notin hardBound

    # `F2` WAS A PRE-EXISTING DEFECT, AND IT IS FIXED. THE PIN IS NOW THE
    # OPPOSITE ASSERTION.
    #
    # `default_config.yaml` gives `forwardContinue` two chords, "F8 F2", and
    # `ui/shortcuts.nim` used to hard-bind `f2` to an empty body AFTER the loop
    # that registers the config table. `Mousetrap.bind` replaces, so the second
    # Continue chord was swallowed: pressing F2 outside the editor did nothing,
    # while the menu and every tooltip went on advertising it, because
    # `renderChord` reads the config and the config still said F2.
    #
    # The previous version of this test pinned that defect as KNOWN, and said
    # "the day `f2`'s hard bind is removed... this reddens and the pin can go."
    # It did not redden, because it compared F2 against a `hardSwallowed`
    # literal declared three lines above it rather than against the source —
    # a check that could only ever agree with itself. That is why `hardBound`
    # above is now the shared registry, and why this asserts F2's ABSENCE from
    # it instead of its presence in a local copy.
    #
    # THE BEHAVIOUR ITSELF IS NOT ASSERTABLE HERE, and this test must not
    # pretend otherwise. That the config binds F2 was true throughout the
    # defect. The proof is a press in a browser tab:
    # `ci/test/chord-and-pane-uniqueness.sh` measures F2 in both focus contexts
    # and requires `forwardContinue` to be DISPATCHED once by each.
    counted cstring"F2" notin hardBoundChords
    # `F1` IS STILL RESERVED, and that is what makes the line above a
    # discriminating check rather than a statement about an empty registry.
    counted cstring"F1" in hardBoundChords
    var presetsUsingASwallowedChord = 0
    for id in boundPresets:
      for b in presetOf(id).bindings:
        for single in b.chord.splitWhitespace():
          if cstring(single) in hardBoundChords:
            checkpoint("swallowed chord still advertised: " & $id & " " &
              $b.action & " -> " & single)
            inc presetsUsingASwallowedChord
    # ZERO NOW. It was one — the default preset's `forwardContinue`, through
    # "F8 F2" — and that one was the defect.
    counted presetsUsingASwallowedChord == 0
    counted presetOf(spCodeTracer).chordFor(
      ClientAction.forwardContinue).get == "F8 F2"
    # And no preset INTRODUCES another one.
    counted presetOf(spVsCode).chordFor(
      ClientAction.forwardContinue).get == "F5"
    counted presetOf(spChorded).chordFor(
      ClientAction.forwardContinue).get == "CTRL+ALT+G"

  test "the DEFAULT preset is byte-for-byte what the YAML already shipped":
    ## THE PIN, and the reason this suite is not purely relational.
    ##
    ## Adopting presets must rebind NOBODY. A user who has never opened the
    ## dialog has `DefaultShortcutPresetId` in force, and its table has to be
    ## the one `default_config.yaml` carries — otherwise shipping a settings
    ## dialog would silently move every stepping key, which is the opposite of
    ## what a settings dialog is for.
    ##
    ## Asserted against `defaultRendererConfig()`'s own parse of the real file,
    ## not against a fixture, and in both spellings — a binding right in one
    ## spelling and wrong in the other works from the toolbar and not from the
    ## editor, or the reverse.
    let config = defaultRendererConfig()
    counted not config.isNil
    counted config.shortcutBindingCount() > 40
    let preset = presetOf(DefaultShortcutPresetId)
    counted preset.bindings.len == PresetActions.len
    for b in preset.bindings:
      let shipped = chordsFor(config, b.action)
      var rendered: seq[string] = @[]
      var editorSpelled: seq[string] = @[]
      for shortcut in shipped:
        rendered.add ($shortcut.renderer).toUpperAscii
        editorSpelled.add $shortcut.editor
      checkpoint($b.action & " shipped=" & rendered.join(" ") &
        " preset=" & b.chord)
      counted rendered.join(" ") == b.chord
      counted editorSpelled.join(" ") == b.chord
    # And the literal the whole pin turns on, so a table that drifted in BOTH
    # the preset and the YAML together is still caught.
    counted preset.chordFor(ClientAction.forwardNext).get == "F10"
    counted preset.chordFor(ClientAction.stop).get == "SHIFT+F5"

  test "a DIFFERENT preset produces DIFFERENT bindings in the same config":
    ## Three builds of the real config, one per preset. Each must carry its own
    ## table's chord for a given move, which no single hardcoded string can
    ## satisfy — and which a `defaultRendererConfig` that ignored its argument
    ## would fail.
    var seen: seq[string] = @[]
    for id in boundPresets:
      let config = defaultRendererConfig(id)
      let preset = presetOf(id)
      var line: seq[string] = @[]
      for b in preset.bindings:
        var rendered: seq[string] = @[]
        for shortcut in chordsFor(config, b.action):
          rendered.add ($shortcut.renderer).toUpperAscii
        checkpoint($id & " " & $b.action)
        counted rendered.join(" ") == b.chord
        line.add rendered.join(" ")
      seen.add line.join(",")
    # Pairwise distinct: three presets, three different binding tables.
    counted seen.len == boundPresets.len
    counted seen.toHashSet.len == boundPresets.len

  test "the TOOLTIP text follows the preset, because it is derived not copied":
    ## `renderChord` is the single producer of displayed chord text — the menu
    ## reads it through `loadShortcut`, the toolbar through `toolbarChord` and
    ## `toolbarTooltip`. It reads `config.shortcutMap`, which is what a preset
    ## changes, so a rebinding moves every label with it.
    ##
    ## This is the assertion that would catch someone "helpfully" adding a
    ## per-preset label table, which is the defect `shortcut_labels.nim` was
    ## created to remove.
    for id in boundPresets:
      let config = defaultRendererConfig(id)
      let preset = presetOf(id)
      for b in preset.bindings:
        checkpoint($id & " tooltip for " & $b.action)
        counted renderChord(b.action, config) == b.chord
    # THE NEGATIVE: the same action's label is not the same string across
    # presets, so the check above is not satisfied by a constant.
    counted renderChord(ClientAction.forwardContinue,
                        defaultRendererConfig(spCodeTracer)) !=
            renderChord(ClientAction.forwardContinue,
                        defaultRendererConfig(spChorded))

  test "the empty preset really unbinds — it does not fall back to the YAML":
    ## `spNone` means "the nine debugger commands have no chord". Leaving the
    ## YAML's in place would mean "they have the chords you were turning off",
    ## and the user would press the toolbar's advertised key and step anyway.
    let config = defaultRendererConfig(spNone)
    counted not config.isNil
    for action in PresetActions:
      checkpoint("unbound: " & $action)
      counted chordsFor(config, action).len == 0
      # And therefore no tooltip names a chord for it.
      counted renderChord(action, config) == ""
    # THE NEGATIVE, and the one that proves the config was really built rather
    # than returned empty: everything OUTSIDE the preset's remit is untouched.
    counted chordsFor(config, ClientAction.build).len == 1
    counted renderChord(ClientAction.build, config) == "CTRL+B"
    counted chordsFor(config, ClientAction.aGotoNextError).len == 1
    counted config.shortcutBindingCount() > 30

  test "no preset collides with a chord the rest of the config already claims":
    ## `initShortcutMap` is FIRST-WRITER-WINS: a preset chord already claimed
    ## by another action would not be registered at all — the action would get
    ## no entry, `renderChord` would return "", and the menu would show a
    ## command with no key beside it. Indistinguishable from a feature that was
    ## never wired.
    ##
    ## The known-good conflict set is five (`Left`, `Right`, `Home`, `End`,
    ## `Esc`) — the Video Player double-bindings the spec already records. A
    ## sixth, under ANY preset, reddens here.
    for id in ShortcutPresetId:
      let config = defaultRendererConfig(id)
      let conflicts = conflictedChords(config)
      checkpoint($id & " conflicts: " & conflicts.join(" "))
      counted conflicts.len == 5
      for expected in ["Left", "Right", "Home", "End", "Esc"]:
        counted expected in conflicts
      # And no preset-governed action is the LOSER of somebody else's chord,
      # which is the form the bug actually takes since the loser is dropped.
      var losers: HashSet[string]
      for pair in config.shortcutMap.conflictList:
        for action in pair[1]:
          losers.incl $action
      for action in PresetActions:
        counted $action notin losers

  test "every preset chord round-trips through the reverse mapping":
    ## `shortcutActions` and `actionShortcuts` are one fact stored twice, and
    ## Mousetrap reads one while the menu reads the other. Drift shows up to a
    ## user as a menu item advertising a chord that does nothing.
    for id in boundPresets:
      let config = defaultRendererConfig(id)
      let preset = presetOf(id)
      for b in preset.bindings:
        for single in b.chord.splitWhitespace():
          checkpoint($id & " " & single)
          counted config.shortcutMap.shortcutActions.hasKey(cstring(single))
          counted config.shortcutMap.shortcutActions[cstring(single)] == b.action

  test "hazards are COMPUTED per platform — the same preset differs on a Mac":
    ## `hazardOf` is a function of the chord and the platform, never a field on
    ## a preset. The test that this is real is that one preset yields two
    ## different hazard sets.
    let preset = presetOf(spCodeTracer)
    var macCount = 0
    var pcCount = 0
    var reservedOnMac = 0
    var reservedOnPc = 0
    for b in preset.bindings:
      if hazardOf(b.chord, mac = true) != chNone: inc macCount
      if hazardOf(b.chord, mac = false) != chNone: inc pcCount
      if hazardOf(b.chord, mac = true) == chBrowserReserved: inc reservedOnMac
      if hazardOf(b.chord, mac = false) == chBrowserReserved: inc reservedOnPc
    # The Mac's function row is a weaker hazard than a browser-reserved key,
    # and it applies to strictly more rows.
    counted macCount > pcCount
    counted pcCount > 0
    # F11 and F12 are taken above the page on every platform, so THAT count
    # does not move between the two.
    counted reservedOnMac == reservedOnPc
    counted reservedOnMac > 0
    # And the two hazards are spelled differently, so a dialog can tell them
    # apart.
    counted hazardMarker(chBrowserReserved) != hazardMarker(chMacFunctionRow)
    counted hazardText(chBrowserReserved) != hazardText(chMacFunctionRow)
    counted hazardText(chNone) == ""
    counted hazardMarker(chNone) == ""

  test "the browser-safe preset is hazard-free on EVERY platform":
    ## The claim `presetWhy(spChorded)` makes to the user in the dialog —
    ## "every chord reaches the page on every platform" — asserted rather than
    ## promised. It is also the answer to `Debugger-Controls.md`'s open
    ## question about a keymap that is honest in a browser.
    let preset = presetOf(spChorded)
    counted preset.bindings.len == PresetActions.len
    for b in preset.bindings:
      for mac in [false, true]:
        checkpoint("chorded " & b.chord & " mac=" & $mac)
        counted hazardOf(b.chord, mac) == chNone
    # THE NEGATIVE: the check above is not vacuous, because the other two
    # presets DO report hazards through the same function.
    for id in [spCodeTracer, spVsCode]:
      var found = 0
      for b in presetOf(id).bindings:
        if hazardOf(b.chord, mac = false) != chNone: inc found
      checkpoint($id & " hazards on a PC: " & $found)
      counted found > 0

  test "the browser-safe preset uses no function key at all":
    ## The structural reason it is hazard-free, stated independently of
    ## `hazardOf` — so a `hazardOf` that lost its F-key branch would not make
    ## the test above pass by accident.
    for b in presetOf(spChorded).bindings:
      let key = chordKeyToken(b.chord)
      checkpoint("chorded key token: " & key)
      counted not (key.len >= 2 and key[0] == 'F' and key[1] in {'0' .. '9'})
    # THE NEGATIVE: the other two presets are built almost entirely of them.
    var fkeys = 0
    for b in presetOf(spCodeTracer).bindings:
      let key = chordKeyToken(b.chord)
      if key.len >= 2 and key[0] == 'F' and key[1] in {'0' .. '9'}: inc fkeys
    counted fkeys == PresetActions.len

  test "a stored preset round-trips, and an unknown one falls back to default":
    ## The wire spellings go to `localStorage` under
    ## `ShortcutPresetStorageKey`, so a rename is a migration. An unrecognised
    ## value must not leave a user with no chords at all — BlockTracer
    ## `Configuration.md` §4's forward-compatibility rule at the field level.
    for id in ShortcutPresetId:
      counted parsePresetId($id) == id
    counted parsePresetId("nonsense-from-a-newer-build") == DefaultShortcutPresetId
    counted parsePresetId("") == DefaultShortcutPresetId
    counted parsePresetId("CodeTracer") == DefaultShortcutPresetId  # case matters
    # `none` is a REAL stored value and must NOT be mistaken for "unset".
    counted parsePresetId("none") == spNone
    counted parsePresetId("none") != DefaultShortcutPresetId
    # The storage key is the one the sibling product already reserved.
    counted ShortcutPresetStorageKey == "codetracer.ui.keymap"

  test "every preset has a name and a reason, and they are distinct":
    ## Four bare names would make a user guess. The reason matters more than
    ## the name for two of the four, because it is where the hazard is stated.
    var names: HashSet[string]
    var whys: HashSet[string]
    for id in ShortcutPresetId:
      counted presetName(id).len > 0
      counted presetWhy(id).len > 0
      names.incl presetName(id)
      whys.incl presetWhy(id)
    counted names.len == 4
    counted whys.len == 4

  test "Cmd on a Mac, Ctrl everywhere else — one modifier, one decision":
    ## THE SPELLING RULE, so the expectations are literals deliberately.
    ##
    ## `shortcut()` maps `CTRL` onto Monaco's `KeyMod.CtrlCmd`, which IS
    ## Command on macOS. A dialog that printed "Ctrl" to a Mac user would be
    ## naming the modifier their every other application spells `⌘`.
    counted describeChord("CTRL+ALT+R", mac = false) == "Ctrl+Alt+R"
    counted describeChord("CTRL+ALT+R", mac = true) == "Cmd+Option+R"
    counted describeChord("CTRL+ALT+SHIFT+R", mac = false) == "Ctrl+Alt+Shift+R"
    counted describeChord("CTRL+ALT+SHIFT+R", mac = true) == "Cmd+Option+Shift+R"
    # A chord with no CTRL is identical on both platforms.
    counted describeChord("SHIFT+F10", mac = false) == "Shift+F10"
    counted describeChord("SHIFT+F10", mac = true) == "Shift+F10"
    counted describeChord("F10", mac = false) == "F10"
    # A two-chord binding keeps both, space-separated, as the menu shows it.
    counted describeChord("F8 F2", mac = false) == "F8 F2"
    # THE NEGATIVE: the platform argument is actually read.
    counted describeChord("CTRL+B", mac = true) !=
            describeChord("CTRL+B", mac = false)

  test "a four-token chord parses its key as the KEY, not as SHIFT+something":
    ## The tokenizer `ui/shortcuts.nim shortcut()` now shares. With
    ## `split("+", 2)` the last token of `CTRL+ALT+SHIFT+R` was `"SHIFT+R"`,
    ## `monaco.KeyCode` had no such member, and the chord silently never
    ## reached Monaco — dead with the caret in the editor.
    counted chordTokens("CTRL+ALT+SHIFT+R") == @["CTRL", "ALT", "SHIFT", "R"]
    counted chordKeyToken("CTRL+ALT+SHIFT+R") == "R"
    counted chordKeyToken("CTRL+ALT+R") == "R"
    counted chordKeyToken("SHIFT+F11") == "F11"
    counted chordKeyToken("F10") == "F10"
    # The chords whose key IS punctuation still work, which is what made the
    # old maxsplit look harmless.
    counted chordKeyToken("CTRL+=") == "="
    counted chordKeyToken("CTRL+-") == "-"
    # Every browser-safe reverse chord is four tokens, so the fix is load-
    # bearing rather than hypothetical.
    var fourTokenChords = 0
    for b in presetOf(spChorded).bindings:
      if chordTokens(b.chord).len == 4: inc fourTokenChords
    counted fourTokenChords == 4

  test "the dialog's own chord is bound, reachable, and not a preset's":
    ## The affordance has to obey the rules the presets do. It is a real
    ## binding in the YAML rather than a hardcoded `Mousetrap.bind`, because a
    ## hardcoded one is invisible to `renderChord` — and the menu item that
    ## opens the shortcuts dialog would then be the one menu item in the
    ## product with no chord printed beside it.
    let config = defaultRendererConfig()
    let opener = chordsFor(config, ClientAction.aKeyboardShortcuts)
    counted opener.len == 1
    counted $opener[0].editor == "CTRL+ALT+K"
    counted $opener[0].renderer == "ctrl+alt+k"
    counted renderChord(ClientAction.aKeyboardShortcuts, config) == "CTRL+ALT+K"
    counted config.shortcutMap.shortcutActions[cstring"CTRL+ALT+K"] ==
      ClientAction.aKeyboardShortcuts
    # NOT delegated into Monaco, by the same rule the browser-safe preset
    # follows: Monaco binds nothing in the CTRL+ALT family, so the global bind
    # already reaches the editor and a Monaco command would be a second
    # delivery.
    counted cstring"CTRL+ALT+K" notin MONACO_SHORTCUTS_WHITELIST
    # And it survives EVERY preset, because it is not preset-governed — a user
    # who chooses "None" must still be able to reopen the dialog and choose
    # again.
    for id in ShortcutPresetId:
      checkpoint("opener under " & $id)
      counted renderChord(ClientAction.aKeyboardShortcuts,
                          defaultRendererConfig(id)) == "CTRL+ALT+K"
    counted ClientAction.aKeyboardShortcuts notin PresetActions

  test "shortcut_presets_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
