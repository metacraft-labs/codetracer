## The debug toolbar's tooltips name the chords the SHIPPED table binds.
##
## LANE: `frontend-js` (listed in `ci/lib/test-lane-files.sh`). JS backend
## only, for the same reason `shortcut_bindings_test.nim` is: `frontend/config.nim`
## and `frontend/types.nim` are built on `std/jsffi`'s `JsAssoc`.
##
## Compile and run:
##   nim js -r src/frontend/tests/debug_toolbar_tooltips_test.nim
##
## ## What was wrong
##
## The toolbar carried its chords as STRING LITERALS — `text "Next (F10)"`,
## `text "Continue (F8)"`, and six more. `isonim/dsl/transform.nim`'s
## `isDynamic` classifies a string literal as static, so the DSL painted them
## once and never again. They matched `default_config.yaml` by coincidence and
## would have gone on matching nothing at all the moment anybody rebound a key,
## while continuing to promise the old chord.
##
## Five of the thirteen controls had no chord to name in the first place: they
## had no `ClientAction`, so `loadShortcut` had nothing to look up and pressing
## a key could not reach them. Those five are now in the table
## (`aHistoryBack`, `aHistoryForward`, `aRunToEntry`, `aResetOperation`,
## `aRunTests`) and this file is what says so.
##
## ## The false pass this is shaped against
##
## Asserting a tooltip EXISTS, or CONTAINS AN EXPECTED LITERAL, proves nothing:
## a hardcoded label passes both, which is exactly how the defect survived. The
## discriminating assertion is that CHANGING THE BINDING CHANGES THE ANSWER, so
## the last test rebinds a chord in the config table and requires the rendered
## chord to follow. Its "before" value is asserted too, so it cannot pass by
## having been the expected value all along.
##
## The painting half — that the DOM node a user hovers actually carries this
## string, and that it follows a rebind with no remount — is asserted in
## `src/tests/gui/tests/views/isonim_views_test.nim`, suite "IsoNim Debug
## Controls — tooltips read the binding".

import std/[strutils, unittest, jsffi, options]

import ../config
import ../types
import ../ui/shortcut_labels
import ../lib/jslib

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 67

## Every control on the toolbar, with the chord the shipped table binds to it.
## BY VALUE, not merely "is bound": a by-name assertion passes for a control
## wired to the wrong chord, and would require today's behaviour while being
## unable to notice it changing wrongly.
const expectedToolbarChords: array[13, tuple[id: string; chord: string]] = [
  (id: "history-back",     chord: "CTRL+ALT+B"),
  (id: "history-forward",  chord: "CTRL+ALT+F"),
  (id: "reverse-next",     chord: "SHIFT+F10"),
  (id: "next",             chord: "F10"),
  (id: "reverse-step-in",  chord: "SHIFT+F11"),
  (id: "step-in",          chord: "F11"),
  (id: "reverse-step-out", chord: "SHIFT+F12"),
  (id: "step-out",         chord: "F12"),
  (id: "reverse-continue", chord: "SHIFT+F8"),
  # `forwardContinue` is bound to two chords ("F8 F2") and always has been;
  # the menu has always shown both, space-joined, and so does the tooltip.
  (id: "continue",         chord: "F8 F2"),
  (id: "run-to-entry",     chord: "CTRL+ALT+E"),
  (id: "reset-operation",  chord: "CTRL+ALT+R"),
  (id: "run-tests",        chord: "ALT+L"),
]

suite "debug toolbar tooltips":

  let config = defaultRendererConfig()

  test "the bundled table parsed, so everything below is about a real table":
    # NON-VACUITY FIRST. Every assertion in this file is of the form "this
    # control's chord is X"; over a Config whose shortcutMap failed to parse
    # they would all read "" and the interesting ones would simply be absent.
    counted not config.isNil
    counted not config.shortcutMap.shortcutActions.isNil
    counted config.shortcutBindingCount() > 40
    # And the toolbar table itself is the size the toolbar is. The view emits
    # 13 buttons and 13 `.custom-tooltip` divs; a table that had drifted
    # shorter would let a control fall out of this file unnoticed.
    counted debugToolbarActions.len == 13
    counted expectedToolbarChords.len == 13

  test "EVERY toolbar control has a chord — none renders a bare label":
    # The count is asserted as well as the property, because "every control has
    # a chord" is satisfied by a toolbar with no controls.
    var withChord = 0
    var checkedControls = 0
    for entry in expectedToolbarChords:
      inc checkedControls
      if toolbarChord(config, entry.id).len > 0:
        inc withChord
    counted checkedControls == 13
    counted checkedControls > 0
    counted withChord == checkedControls

  test "and each one is the chord it should be":
    for entry in expectedToolbarChords:
      counted toolbarChord(config, entry.id) == entry.chord

  test "the five that had no ClientAction at all now resolve to one":
    # These are the controls that could not have shown a chord before, because
    # there was nothing to look one up by. `run-tests` additionally had its
    # ALT+L hard-bound in `ui/shortcuts.nim`, where `loadShortcut` cannot see
    # it — a chord that worked and was invisible.
    for (id, action) in [
        ("history-back",    ClientAction.aHistoryBack),
        ("history-forward", ClientAction.aHistoryForward),
        ("run-to-entry",    ClientAction.aRunToEntry),
        ("reset-operation", ClientAction.aResetOperation),
        ("run-tests",       ClientAction.aRunTests)]:
      let resolved = toolbarClientAction(id)
      counted resolved.isSome
      counted resolved.get == action

  test "nothing the toolbar claims was taken from something else":
    # The reverse mapping. `initShortcutMap` is first-writer-wins and pushes a
    # loser into `conflictList`, which nothing reads — so a chord this file
    # says belongs to the toolbar could in fact belong to an earlier action,
    # with the toolbar control silently getting nothing.
    for (chord, action) in [
        ("CTRL+ALT+B", ClientAction.aHistoryBack),
        ("CTRL+ALT+F", ClientAction.aHistoryForward),
        ("CTRL+ALT+E", ClientAction.aRunToEntry),
        ("CTRL+ALT+R", ClientAction.aResetOperation),
        ("ALT+L",      ClientAction.aRunTests)]:
      counted config.shortcutMap.shortcutActions.hasKey(cstring(chord))
      counted config.shortcutMap.shortcutActions[cstring(chord)] == action

  test "the eight stepping controls kept the chords they already had":
    # THE PREMISE OF THIS WHOLE CHANGE, asserted so it cannot rot. The removed
    # hardcoded strings said F10/F11/F12/F8; they were RIGHT, which is why the
    # defect was invisible. Nothing was displaced to make the toolbar readable
    # — if that ever stops being true, the decision should be revisited rather
    # than inherited.
    counted config.shortcutMap.shortcutActions[cstring"F10"] ==
      ClientAction.forwardNext
    counted config.shortcutMap.shortcutActions[cstring"F11"] ==
      ClientAction.forwardStep
    counted config.shortcutMap.shortcutActions[cstring"F12"] ==
      ClientAction.forwardStepOut
    counted config.shortcutMap.shortcutActions[cstring"F8"] ==
      ClientAction.forwardContinue

  test "no toolbar action lost its chord to a conflict":
    var losers: seq[ClientAction] = @[]
    for pair in config.shortcutMap.conflictList:
      for action in pair[1]:
        losers.add(action)
    var checkedControls = 0
    for entry in debugToolbarActions:
      counted entry.action notin losers
      inc checkedControls
    counted checkedControls == 13

  test "REBINDING THE CONFIG TABLE CHANGES THE CHORD THE TOOLTIP SHOWS":
    # The only assertion in this file that distinguishes "reads the binding"
    # from "happens to say the same thing today". A hardcoded tooltip passes
    # every test above and fails this one.
    let rebound = defaultRendererConfig()

    # BEFORE, measured rather than assumed, so the arm has a starting point
    # and cannot pass by having always been "CTRL+ALT+9".
    counted toolbarChord(rebound, "run-to-entry") == "CTRL+ALT+E"
    counted toolbarChord(rebound, "next") == "F10"

    # THE REBIND, through the same `initShortcutMap` a user's edited
    # `.config.yaml` goes through.
    rebound.bindings[cstring"aRunToEntry"] = cstring"CTRL+ALT+9"
    rebound.shortcutMap = initShortcutMap(rebound.bindings)

    # AFTER.
    counted toolbarChord(rebound, "run-to-entry") == "CTRL+ALT+9"
    # The control that was NOT rebound did not move — the arm's own control,
    # catching a mutation that simply blanked or rewrote the whole table.
    counted toolbarChord(rebound, "next") == "F10"
    # And the shipped config is untouched by the above, so the assertions in
    # the other tests were not reading a mutated table.
    counted toolbarChord(config, "run-to-entry") == "CTRL+ALT+E"

  test "an action with no binding renders as no chord, not as empty text":
    # `renderChord` returning "" is what a first-writer-wins loss looks like,
    # and callers must render it as *no chord*. `aVerification` is a real
    # ClientAction that the shipped table deliberately does not bind.
    counted renderChord(ClientAction.aVerification, config) == ""
    counted toolbarChord(config, "not-a-toolbar-control") == ""
    counted toolbarClientAction("not-a-toolbar-control").isNone

  test "debug_toolbar_tooltips_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
