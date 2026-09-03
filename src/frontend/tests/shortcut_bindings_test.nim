## The shipped shortcut table actually binds what it claims to.
##
## LANE: `frontend-js` (listed in `ci/lib/test-lane-files.sh`). JS backend
## only, because `frontend/config.nim` is built on `std/jsffi`'s `JsAssoc`.
##
## Compile and run:
##   nim js -r src/frontend/tests/shortcut_bindings_test.nim
##
## ## Why this file exists
##
## `initShortcutMap` (`frontend/config.nim:23-56`, and its twin
## `common/config.nim:112-135`) is **first-writer-wins**. A chord already
## claimed by an earlier action is NOT registered for the second one: it is
## appended to `conflictList` and dropped. `conflictList` is then read by
## exactly one place — `ui/shortcuts.nim:215-219` — which logs a warning
## nobody sees.
##
## The consequence is the failure shape this area keeps producing: a binding
## that silently does not exist is indistinguishable from a feature that was
## never wired. The action gets no entry in `actionShortcuts`, so
## `menu.nim:152 loadShortcut` returns `""`, so the menu item renders with no
## chord beside it, and the shortcut does nothing — while every other test
## still passes, because nothing else asserts that a chord is reachable.
##
## Edit-Mode-Toolbar.md EMT-D24 asks for a landed conflict to be a **failure**
## rather than a warning. A build-time failure is not available (the table is
## parsed from YAML), so this is the enforceable version of that decision.
##
## ## Why `defaultRendererConfig()` and not a fixture
##
## That proc is what a browser tab actually uses: `frontend/config.nim`
## `staticRead`s the real `src/config/default_config.yaml` and parses it,
## because a statically hosted tab has no index process to send it a config.
## Testing a fixture would test this file's copy of the table; testing
## `defaultRendererConfig()` tests the table the product loads.
##
## ## The two false passes this is shaped against
##
## 1. Asserting a binding **by name** — `actionShortcuts.hasKey(action)` —
##    passes for an action bound to the *wrong* chord, and would *require* the
##    current behaviour while being unable to catch it changing wrongly. So
##    every chord is asserted BY VALUE, in both spellings its two consumers
##    read (`renderer` for Mousetrap and the menu, `editor` for Monaco).
## 2. "my chord is not in `conflictList`" passes vacuously when that list is
##    empty for an unrelated reason — including the reason that the whole
##    parse failed. So the parse is sized first, and the conflict list's
##    length is asserted alongside its membership.

import std/[strutils, unittest, jsffi]

import ../config
import ../types
import ../lib/jslib
from ../ui/shortcut_labels import
  MONACO_SHORTCUTS_WHITELIST, hardBoundChords, hardBindShadowedActions,
  PERMITTED_HARD_BIND_SHADOWS

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 107
  ## 31 before the two Stop cases below; +5 for the binding pin and +20 for the
  ## Monaco-delegation family (9 non-vacuity checks, 10 membership checks and
  ## the total) — 56.
  ##
  ## +37 for the hard-bound registry's staleness guard: 1 sizing check, 17
  ## source-literal-in-registry checks, 17 registry-entry-in-source checks and
  ## the 2 discriminating negatives. The two 17s are the count of
  ## `Mousetrap.bind("...")` literals in `ui/shortcuts.nim` and `ui_js.nim`, so
  ## adding or removing a hardcoded bind moves this number — deliberately.
  ##
  ## +14 for the shadow rule: 3 on F2; 1 sizing the permitted table; 1 per
  ## REPORTED shadow (there is one, `CTRL+B`, so this number moves the day a
  ## shadow is added or removed — deliberately); 3 asserting that F2, CTRL+E
  ## and ALT+1 are NOT reported; 4 asserting the config still claims CTRL+E and
  ## ALT+1 for the right actions, which is what distinguishes "the hard bind
  ## was removed" from "the config entry was"; and 2 on the instrument that
  ## proves the reporter can report anything at all.

proc chordsFor(config: Config; action: ClientAction): seq[Shortcut] =
  for shortcut in config.shortcutMap.actionShortcuts[action]:
    result.add(shortcut)

proc conflictedChords(config: Config): seq[string] =
  for pair in config.shortcutMap.conflictList:
    result.add($pair[0])

suite "shipped shortcut bindings":

  let config = defaultRendererConfig()

  test "the bundled table parsed, so everything below is about a real table":
    # NON-VACUITY FIRST, and this is not ceremony: `shortcutBindingCount`'s own
    # doc comment records that a Config with an empty shortcutMap is non-nil,
    # dereferences cleanly everywhere, and produces a product that mounts,
    # paints, and has no keyboard. Every assertion below would pass over it.
    counted not config.isNil
    counted not config.shortcutMap.shortcutActions.isNil
    counted config.shortcutBindingCount() > 40
    # And a couple of bindings that predate this feature, so a parser that
    # produced only the last section would be caught.
    counted chordsFor(config, ClientAction.forwardContinue).len == 2
    counted chordsFor(config, ClientAction.build).len == 1

  test "next / previous error are bound, to the chords the menu will show":
    # BY VALUE, in both spellings. A binding correct in one spelling and wrong
    # in the other works from one place and not the other, which is the
    # hardest version of this bug to see: it would work from the topbar and do
    # nothing with the caret in the editor, or the reverse.
    let next = chordsFor(config, ClientAction.aGotoNextError)
    counted next.len == 1
    counted $next[0].renderer == "ctrl+alt+n"
    counted $next[0].editor == "CTRL+ALT+N"

    let prev = chordsFor(config, ClientAction.aGotoPreviousError)
    counted prev.len == 1
    counted $prev[0].renderer == "ctrl+alt+p"
    counted $prev[0].editor == "CTRL+ALT+P"

  test "the menu will render those chords, uppercased, beside the labels":
    # `menu.nim:152 loadShortcut` is the only producer of a menu item's
    # shortcut text and it reads `actionShortcuts` — the same table asserted
    # above. Reproducing its transform here asserts the STRING A USER SEES,
    # rather than merely that a binding exists.
    for (action, expected) in [
        (ClientAction.aGotoNextError, "CTRL+ALT+N"),
        (ClientAction.aGotoPreviousError, "CTRL+ALT+P")]:
      var rendered = ""
      for index, shortcut in chordsFor(config, action):
        if index > 0:
          rendered &= " "
        rendered &= ($shortcut.renderer).toUpperAscii
      counted rendered == expected

  test "and the reverse mapping agrees, so nothing else claimed those chords":
    counted config.shortcutMap.shortcutActions.hasKey(cstring"CTRL+ALT+N")
    counted config.shortcutMap.shortcutActions[cstring"CTRL+ALT+N"] ==
      ClientAction.aGotoNextError
    counted config.shortcutMap.shortcutActions.hasKey(cstring"CTRL+ALT+P")
    counted config.shortcutMap.shortcutActions[cstring"CTRL+ALT+P"] ==
      ClientAction.aGotoPreviousError

  test "the chords they did NOT take are still held by the debugger":
    # The PREMISE of the CTRL+ALT+N / CTRL+ALT+P choice, asserted so it cannot
    # rot into an unexplained oddity. F8 / SHIFT+F8 are what VS Code uses for
    # this and what the spec proposed; they were unavailable because
    # `forwardContinue` and `reverseContinue` already hold them, and ALT+F8 --
    # the next candidate -- is bound by Monaco's own marker navigation, which
    # both swallowed the key and, when whitelisted, made it fire twice. If the
    # debugger ever gives F8 up, this reddens and the decision should be
    # revisited rather than inherited.
    counted config.shortcutMap.shortcutActions[cstring"F8"] ==
      ClientAction.forwardContinue
    counted config.shortcutMap.shortcutActions[cstring"SHIFT+F8"] ==
      ClientAction.reverseContinue

  test "neither new chord landed in conflictList":
    let conflicts = conflictedChords(config)
    counted "ALT+F8" notin conflicts
    counted "ALT+SHIFT+F8" notin conflicts
    # And neither action appears as the LOSER of somebody else's chord — the
    # form the bug actually takes, since the loser is what gets dropped.
    var losers: seq[ClientAction] = @[]
    for pair in config.shortcutMap.conflictList:
      for action in pair[1]:
        losers.add(action)
    counted ClientAction.aGotoNextError notin losers
    counted ClientAction.aGotoPreviousError notin losers

  test "the conflict set is exactly the known pre-existing one":
    # EMT-D24 in its enforceable form: a NEW conflict is a failure here.
    #
    # The five below are the Video Player / navigation double-bindings the
    # spec already records. They are PINNED, not blessed — this test says
    # "these five are known", and a sixth reddens rather than silently
    # dropping a binding. The COUNT is asserted as well as the membership,
    # because "every chord I expect is present" is satisfied by a longer list.
    let conflicts = conflictedChords(config)
    counted conflicts.len == 5
    for expected in ["Left", "Right", "Home", "End", "Esc"]:
      counted expected in conflicts

  test "every bound action can be named back from its own chord":
    # `shortcutActions` and `actionShortcuts` are one fact stored twice, and
    # the menu reads one while Mousetrap reads the other. Drift shows up to a
    # user as a menu item advertising a chord that does nothing.
    var checkedPairs = 0
    for action, chords in config.shortcutMap.actionShortcuts:
      for chord in chords:
        if config.shortcutMap.shortcutActions.hasKey(chord.editor):
          if config.shortcutMap.shortcutActions[chord.editor] == action:
            inc checkedPairs
    # Every registered pair round-trips. Asserted as an equality against the
    # binding count rather than as "no failures found", so a loop that ranged
    # over nothing cannot pass.
    counted checkedPairs == config.shortcutBindingCount()
    counted checkedPairs > 40

  test "Stop is bound, and to the chord both specs and the YAML agree on":
    # `stop` was the one debugger command whose whole chain ended in
    # `renderer.nim`'s `proc stopAction* = discard`. The binding was never the
    # broken link, so this half is a regression guard: it pins the chord the
    # fix is reachable through, in both spellings, since the Monaco assertion
    # below reads the `editor` one and Mousetrap reads the `renderer` one.
    let stop = chordsFor(config, ClientAction.stop)
    counted stop.len == 1
    counted $stop[0].renderer == "shift+f5"
    counted $stop[0].editor == "SHIFT+F5"
    counted config.shortcutMap.shortcutActions[cstring"SHIFT+F5"] ==
      ClientAction.stop
    # And it is not somebody else's dropped loser — `initShortcutMap` is
    # first-writer-wins, and `Debugger-Controls.md` gives `Shift+F5` to
    # Reverse Continue as well as to Stop in the same table, which is exactly
    # the collision that would silence one of them.
    var losers: seq[ClientAction] = @[]
    for pair in config.shortcutMap.conflictList:
      for action in pair[1]:
        losers.add(action)
    counted ClientAction.stop notin losers

  test "every debugger command reaches Monaco, Stop included":
    # THE LINK THIS TEST EXISTS FOR.
    #
    # `ui/editor.nim` delegates a config chord into Monaco only if it appears
    # in `MONACO_SHORTCUTS_WHITELIST` (`editor.nim`, the `notin` guard in
    # `configureShortcuts`). Monaco stops keydown propagation before the
    # bubble phase Mousetrap listens on, so a chord left off that list is
    # DEAD while the caret is in the editor — which for a source debugger is
    # where the caret usually is.
    #
    # `SHIFT+F5` was missing from the list. Every other member of the family
    # was present, so Stop was the single debugger command a user could not
    # invoke from the editor, which is a large part of why it read as "bound
    # and does nothing" even before you reach `stopAction`'s empty body.
    #
    # Asserted over the family rather than for Stop alone, so the next command
    # added to the YAML and forgotten here reddens too. The `editor` spelling
    # is the one used, because that is the string `editor.nim` looks up.
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
    var checkedChords = 0
    for action in debuggerCommands:
      let chords = chordsFor(config, action)
      # Non-vacuity per action: an unbound action has no chords, and a loop
      # over an empty seq asserts nothing while looking like it did.
      counted chords.len >= 1
      for chord in chords:
        checkpoint($action & " -> " & $chord.editor)
        counted chord.editor in MONACO_SHORTCUTS_WHITELIST
        inc checkedChords
    # `forwardContinue` is bound to two chords ("F8 F2"), so nine commands
    # contribute ten chords. Pinning the total is what stops this passing on a
    # table that parsed only half of itself.
    counted checkedChords == 10

  test "the hard-bound registry is COMPLETE — derived from the source, not copied":
    ## THE GUARD THAT STOPS `hardBoundChords` GOING STALE, and without which
    ## every check written over it is vacuous.
    ##
    ## `ui/shortcut_labels.nim`'s `hardBoundChords` is a hand-maintained list of
    ## the chords bound with `Mousetrap.bind` outside the config table. A
    ## hand-maintained list of what some other file does is exactly the copy
    ## this area keeps being bitten by: someone adds a bind, nobody adds a row,
    ## and the "no preset collides with a hard bind" check in
    ## `shortcut_presets_test.nim` goes on passing over a list that no longer
    ## describes the product.
    ##
    ## So the list is checked against the SOURCE. `staticRead` pulls in the two
    ## files that bind chords in code, every `Mousetrap.bind("...")` literal is
    ## extracted, and each must appear in the registry. Adding a hardcoded bind
    ## and forgetting the registry reddens HERE, one step before it can silently
    ## kill a config entry.
    const shortcutsSource = staticRead("../ui/shortcuts.nim")
    const uiJsSource = staticRead("../ui_js.nim")

    proc literalBinds(source: string): seq[string] =
      ## Every `Mousetrap.bind("<chord>")` literal, upper-cased to the spelling
      ## `shortcutActions` is keyed by.
      ##
      ## Commented-out binds are skipped — both files carry several, and a
      ## disabled bind replaces nothing. Non-literal binds are skipped too:
      ## `Mousetrap.bind("CTRL+" & $i)` is the CTRL+1..9 loop, which no YAML
      ## entry contests and which cannot be extracted as a string anyway.
      const marker = "Mousetrap.`bind`(\""
      for rawLine in source.splitLines():
        let line = rawLine.strip()
        if line.startsWith("#"):
          continue
        let start = line.find(marker)
        if start < 0:
          continue
        let openQuote = start + marker.len
        let closeQuote = line.find('"', openQuote)
        if closeQuote < 0:
          continue
        let chord = line[openQuote ..< closeQuote]
        # `"CTRL+" & $i` — the literal is a prefix, not a chord.
        if line[closeQuote + 1] != ')':
          continue
        result.add(chord.toUpperAscii)

    let found = literalBinds(shortcutsSource) & literalBinds(uiJsSource)

    # NON-VACUITY FIRST. An extractor that matched nothing would satisfy every
    # membership check below while measuring nothing at all — the empty-haystack
    # pass this repository's harnesses keep naming. The count is pinned, so a
    # bind added or removed has to be accounted for deliberately.
    counted found.len == 17

    for chord in found:
      checkpoint("hardcoded Mousetrap bind: " & chord)
      counted cstring(chord) in hardBoundChords

    # THE OTHER DIRECTION: the registry claims nothing the source does not do.
    # Without this the list could accumulate chords that were removed years ago
    # and go on forbidding presets from using keys that are actually free.
    for chord in hardBoundChords:
      checkpoint("registry entry: " & $chord)
      counted ($chord) in found

    # THE NEGATIVE, so the two containments above are not both satisfied by an
    # extractor that returns the registry. `F10` is bound through the YAML and
    # must NOT appear; `ALT+F10` is bound in code and must.
    counted "ALT+F10" in found
    counted "F10" notin found

  test "F2 DISPATCHES — the swallow is gone and the config is no longer a lie":
    ## THE REGRESSION, pinned at the level this suite can reach.
    ##
    ## `default_config.yaml` gives `forwardContinue` two chords, "F8 F2".
    ## `ui/shortcuts.nim` used to re-bind `f2` to an empty body AFTER the loop
    ## that installs the config table, so outside the editor F2 did nothing
    ## while the menu, the toolbar tooltips and the shortcuts dialog all went on
    ## advertising it.
    ##
    ## WHAT THIS TEST CAN AND CANNOT SEE, stated because the distinction is the
    ## whole trap. That the CONFIG binds F2 was true throughout the defect —
    ## `chordsFor(config, forwardContinue).len == 2` passed the entire time the
    ## key was dead. So a config-level assertion is exactly the vacuous one, and
    ## the real proof is a press in a browser tab:
    ## `ci/test/chord-and-pane-uniqueness.sh` presses F2 in both focus contexts
    ## and asserts `forwardContinue` was DISPATCHED once.
    ##
    ## What this test contributes instead is the STRUCTURAL fact that made the
    ## press dead: F2 is claimed by the config AND was in the hard-bound
    ## registry at the same time. That conjunction is now forbidden for F2, and
    ## it is checkable here in milliseconds.
    let config = defaultRendererConfig()
    counted cstring"F2" notin hardBoundChords
    counted config.shortcutMap.shortcutActions.hasKey(cstring"F2")
    counted config.shortcutMap.shortcutActions[cstring"F2"] ==
      ClientAction.forwardContinue

    # AND THE GENERAL PROPERTY, WHICH IS NOW ENFORCED RATHER THAN RECORDED.
    #
    # `hardBindShadowedActions` reports every chord the config declares that a
    # hardcoded bind overwrites. This used to pin that report as a LITERAL LIST
    # — `@["CTRL+B", "CTRL+E", "ALT+1"]` — with a comment saying the last two
    # were real defects left for later. A list of the answer can only ever
    # agree with itself: it went green on a tree carrying two known defects,
    # and it would have gone green on a tree carrying a third the moment
    # somebody updated the literal.
    #
    # `GUI/Keyboard-Shortcuts-System.md` states the rule as a rule: "Every
    # other shadow is a defect. A chord in `hardBindShadowedActions` that is
    # not listed above must be resolved by removing one of the two claims,
    # never by leaving the config entry declared and dead." So the check is
    # against `PERMITTED_HARD_BIND_SHADOWS`, which is that table. A new shadow
    # fails HERE, and the only way to make it pass is to remove a claim or to
    # change the spec — which `ci/test/shortcut-shadow-spec-agreement.sh`
    # requires, because it compares the constant with the spec's own table.
    let shadowed = hardBindShadowedActions(config)
    var shadowedChords: seq[string] = @[]
    for (chord, _) in shadowed:
      shadowedChords.add($chord)
    checkpoint("config entries killed by a hard bind: " & shadowedChords.join(", "))

    # NON-VACUITY FIRST, and on the RULE rather than on the report. "Every
    # reported shadow is permitted" is vacuously true of an empty permitted
    # list AND of an empty report; the second is checked by the instrument arm
    # below, and this is the first.
    counted PERMITTED_HARD_BIND_SHADOWS.len == 1

    # THE RULE. Chord AND action, because permitting `CTRL+B` to shadow `build`
    # is not permitting it to shadow whatever a future YAML puts there.
    for (chord, action) in shadowed:
      checkpoint("shadow: " & $chord & " kills " & $action)
      counted (chord, action) in PERMITTED_HARD_BIND_SHADOWS

    # THE REGRESSIONS, named individually so a re-introduction says WHICH.
    # These are not restatements of the loop above: the loop is silent about a
    # chord that is absent from the report, and "absent from the report" is
    # exactly what these three assert.
    counted "F2" notin shadowedChords
    counted "CTRL+E" notin shadowedChords
    counted "ALT+1" notin shadowedChords

    # AND THE OTHER HALF OF EACH, because a chord leaves the report either by
    # having its hard bind removed (what happened) or by having its CONFIG
    # entry removed (which would leave the key unrebindable and the action
    # unreachable — the outcome the spec forbids). Only the first is a fix, and
    # only these say which one landed.
    counted config.shortcutMap.shortcutActions.hasKey(cstring"CTRL+E")
    counted config.shortcutMap.shortcutActions[cstring"CTRL+E"] ==
      ClientAction.aToggleReadOnly
    counted config.shortcutMap.shortcutActions.hasKey(cstring"ALT+1")
    counted config.shortcutMap.shortcutActions[cstring"ALT+1"] ==
      ClientAction.aLowLevel1

    # THE INSTRUMENT. `hardBindShadowedActions` must be able to REPORT a shadow,
    # or the rule above is satisfied by a proc that always returns nothing —
    # which is precisely what a fix that deleted the registry would produce.
    counted cstring"CTRL+B" in hardBoundChords
    counted config.shortcutMap.shortcutActions[cstring"CTRL+B"] ==
      ClientAction.build

  test "shortcut_bindings_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
