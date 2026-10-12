## The shortcut presets bind what they display, and reach the editor.
##
## LANE: `frontend-js` (listed in `ci/lib/test-lane-files.sh`). JS backend
## only: `frontend/config.nim` is built on `std/jsffi`'s `JsAssoc`.
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
import ../viewmodel/keymap/[binding_sets, user_keymap, keymap_router,
                            scope_path, context_keys, editing_keymap]
import ../../common/key_names

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 409
  ## PLAT-68: 526 → 409. The cases about the retired key registries (the
  ## Monaco delegation whitelist, the hard-bound chords) and the tooltip that
  ## read the YAML went with them; the include-set case came (a preset's
  ## chords ARE its `keybindings.json` include set).

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

  test "the governed set is exactly the debugger's stepping family":
    ## A preset is a `keybindings.json` include set of STEPPING chords; the
    ## router delivers them in every focus context, the editor included (one
    ## capture-phase listener — no per-surface registry to prove reachability
    ## against any more). Pinned so a preset cannot quietly start governing a
    ## non-stepping action, whose chord the user's own rows would then lose to
    ## a preset they chose for stepping.
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

  test "the empty preset really unbinds — it does not fall back to the YAML":
    ## `spNone` means "the nine debugger commands have no chord". Leaving the
    ## YAML's in place would mean "they have the chords you were turning off",
    ## and the user would press the toolbar's advertised key and step anyway.
    let config = defaultRendererConfig(spNone)
    counted not config.isNil
    for action in PresetActions:
      checkpoint("unbound: " & $action)
      counted chordsFor(config, action).len == 0
    # THE NEGATIVE, and the one that proves the config was really built rather
    # than returned empty: everything OUTSIDE the preset's remit is untouched.
    counted chordsFor(config, ClientAction.build).len == 1
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

  test "every preset's chords ARE its keybindings.json include set":
    ## PLAT-68: the dialog names a preset; the keyboard runs its INCLUDE SET
    ## (`binding_sets`, `stepping:<id>`) over the CUA base. The two tables
    ## must say the same thing, move for move — a preset whose dialog row
    ## promised a chord its include set does not bind is the flattering-dialog
    ## defect one level down.
    const Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                                keyProtocol: kpNative)
    for id in [spVsCode, spChorded]:
      var router = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap(
        """[{"include": "stepping:""" & $id & """"}]"""))
      let facts = SessionFacts(product: pmDebug, editor: sourceViewFacts())
      for b in presetOf(id).bindings:
        for single in b.chord.splitWhitespace():
          checkpoint($id & " " & $b.action & " " & single)
          let res = router.route(facts, @[element(ekWindow, "window")],
                                 nmNormal, normalizeChord(single), 0)
          counted res.kind == erOperation
    # `none` binds no move at all.
    var none = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap(
      """[{"include": "stepping:none"}]"""))
    counted none.route(SessionFacts(product: pmDebug, editor: sourceViewFacts()),
                       @[element(ekWindow, "window")], nmNormal, "F10",
                       0).kind == erNothing
    counted bindingSetIndex("stepping:vscode") >= 0

  test "shortcut_presets_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
