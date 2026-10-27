## The debug toolbar's tooltips name the chords the ROUTER runs.
##
## LANE: `frontend-js` (listed in `ci/lib/test-lane-files.sh`). JS backend:
## `frontend/types.nim` is built on `std/jsffi`'s `JsAssoc`.
##
## Compile and run:
##   nim js -r src/frontend/tests/debug_toolbar_tooltips_test.nim
##
## ## What was wrong, twice
##
## The toolbar first carried its chords as STRING LITERALS — `text "Next
## (F10)"` — which matched the binding table by coincidence and would have gone
## on promising a chord after anybody rebound it. It then read the YAML
## `bindings:` table, which was right about the YAML and wrong about the keys:
## the keys went through three registries (Mousetrap, hard binds, Monaco
## commands) that the table did not describe.
##
## PLAT-68: the keys go through ONE router (`ui/key_router`), and a tooltip
## shows the chord that router RUNS the control's action with
## (`keymap_router.chordFor`, through `ui/chord_display`). This suite builds
## that router — the CUA base, the desktop's delivery — and the toolbar's
## lookup over it.
##
## ## The false pass this is shaped against
##
## A tooltip that CONTAINS AN EXPECTED LITERAL proves nothing: a hardcoded
## label passes. The discriminating assertion is that CHANGING THE BINDING
## CHANGES THE ANSWER — the last case lays a user's `keybindings.json` over the
## base and requires the rendered chord to follow, its "before" asserted too.
##
## No mocks: the shipped base rows, the shipped router, the shipped toolbar
## table.

import std/[unittest, options]

import ../types
import ../ui/shortcut_labels
import ../viewmodel/keymap/[keymap_router, client_actions, user_keymap,
                            operation_catalogue, scope_path, context_keys,
                            editing_keymap]

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 46

const expectedToolbarChords: array[13, tuple[id: string; chord: string]] = [
  (id: "history-back",     chord: "Ctrl+Alt+-"),
  (id: "history-forward",  chord: "Ctrl+Shift+-"),
  (id: "reverse-next",     chord: "Shift+F10"),
  (id: "next",             chord: "F10"),
  (id: "reverse-step-in",  chord: "Shift+F11"),
  (id: "step-in",          chord: "F11"),
  (id: "reverse-step-out", chord: "Shift+F12"),
  (id: "step-out",         chord: "F12"),
  (id: "reverse-continue", chord: "Shift+F8"),
  (id: "continue",         chord: "F8"),
  (id: "run-to-entry",     chord: "Ctrl+Alt+E"),
  (id: "reset-operation",  chord: "Ctrl+Alt+R"),
  (id: "run-tests",        chord: "Alt+L"),
]

const Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                            keyProtocol: kpNative)

proc chordOfRouter(router: KeymapRouter): proc(action: ClientAction): string =
  ## `key_router.chordForAction`'s lookup over `router`, at the window.
  result = proc(action: ClientAction): string =
    let op = operationOfClientAction($action)
    if op.len == 0:
      return ""
    let (name, arg) = splitOperation(op)
    router.chordFor(name, SessionFacts(product: pmDebug,
                                       editor: sourceViewFacts()),
                    @[element(ekWindow, "window")], nmNormal, arg)

suite "debug toolbar tooltips":

  let base = initKeymapRouter(bkCua, Desktop)
  let chordOf = chordOfRouter(base)

  test "the toolbar table is the toolbar":
    # The view emits 13 buttons and 13 `.custom-tooltip` divs; a table that had
    # drifted shorter would let a control fall out of this file unnoticed.
    counted debugToolbarActions.len == 13
    counted expectedToolbarChords.len == 13

  test "EVERY toolbar control has a chord — none renders a bare label":
    var withChord = 0
    for entry in expectedToolbarChords:
      if toolbarChord(chordOf, entry.id).len > 0:
        inc withChord
    counted withChord == 13

  test "and each one is the chord the router runs it with":
    for entry in expectedToolbarChords:
      checkpoint(entry.id)
      counted toolbarChord(chordOf, entry.id) == entry.chord

  test "the five non-stepping controls resolve to an action":
    for (id, action) in [
        ("history-back",    ClientAction.aHistoryBack),
        ("history-forward", ClientAction.aHistoryForward),
        ("run-to-entry",    ClientAction.aRunToEntry),
        ("reset-operation", ClientAction.aResetOperation),
        ("run-tests",       ClientAction.aRunTests)]:
      let resolved = toolbarClientAction(id)
      counted resolved.isSome
      counted resolved.get == action

  test "the chord shown RUNS the control's action, at the window":
    var r = initKeymapRouter(bkCua, Desktop)
    let facts = SessionFacts(product: pmDebug, editor: sourceViewFacts())
    for entry in debugToolbarActions:
      let res = r.route(facts, @[element(ekWindow, "window")], nmNormal,
                        normalizeChordSequence(toolbarChord(chordOf, entry.id)),
                        0)
      checkpoint(entry.id)
      counted res.kind == erOperation and
              clientActionOf(if res.argument.len > 0:
                               res.operation & "(" & res.argument & ")"
                             else: res.operation) == $entry.action

  test "A USER'S keybindings.json CHANGES THE CHORD THE TOOLTIP SHOWS":
    # The only assertion in this file that distinguishes "reads the binding"
    # from "happens to say the same thing today".
    counted toolbarChord(chordOf, "run-to-entry") == "Ctrl+Alt+E"
    counted toolbarChord(chordOf, "next") == "F10"
    let user = parseUserKeymap("""[
      { "key": "ctrl+alt+9", "command": "debugger.run-to-entry" },
      { "key": "ctrl+alt+e", "command": "-debugger.run-to-entry" }
    ]""")
    let rebound = chordOfRouter(initKeymapRouter(bkCua, Desktop, user = user))
    counted toolbarChord(rebound, "run-to-entry") == "Ctrl+Alt+9"
    # The control that was NOT rebound did not move.
    counted toolbarChord(rebound, "next") == "F10"

  test "an action no key reaches renders as no chord, not as empty text":
    counted chordOf(ClientAction.aVerification) == ""
    counted toolbarChord(chordOf, "not-a-toolbar-control") == ""
    counted toolbarClientAction("not-a-toolbar-control").isNone

  test "debug_toolbar_tooltips_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
