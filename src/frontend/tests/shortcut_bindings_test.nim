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
from ../ui/shortcut_labels import MONACO_SHORTCUTS_WHITELIST

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 56
  ## 31 before the two Stop cases below; +5 for the binding pin and +20 for the
  ## Monaco-delegation family (9 non-vacuity checks, 10 membership checks and
  ## the total).

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

  test "shortcut_bindings_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
