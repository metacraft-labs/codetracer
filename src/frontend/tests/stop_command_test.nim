## stop_command_test.nim
##
## Regression test for "Stop is bound and discoverable and does nothing".
##
## THE CHAIN, AND WHERE IT DIED
##
##   `src/config/default_config.yaml:75`      `stop: "SHIFT+F5"`
##     -> `common_types/codetracer_features/frontend.nim`  `ClientAction.stop`
##     -> `frontend/config.nim` `initShortcutMap` fills `actionShortcuts[stop]`
##     -> `ui/shortcuts.nim` `configureShortcuts` -> `bindShortcut`
##     -> `data.actions[stop](nil)`
##     -> `ui_js.nim`'s action table slot -> `renderer.stopAction()`
##     -> `renderer.nim`  `proc stopAction* {.locks: 0.} = discard`   <-- HERE
##
## `git log -L` on those two lines returns one commit: `3fc21a75`, "the initial
## open-source release". The body has never done anything.
##
## Two further links were missing rather than dead, and both fed the report:
## `SHIFT+F5` was absent from `MONACO_SHORTCUTS_WHITELIST`, so the chord did
## not survive the caret being in the editor (asserted in
## `shortcut_bindings_test.nim`), and the "Stop" menu entry was commented out
## in `ui_js.nim`, which also removed it from the command palette and the
## native macOS menu, since both are generated from the same `menuNode`.
##
## WHAT STOP DOES — and this suite is where that decision is checkable.
## `codetracer-specs` `latest` settles the core and leaves one thing open; the
## quotations and the reasoning are in `ui/stop_command.nim`'s module doc, not
## repeated here. In one line: Stop returns the workspace to Edit mode and
## does NOT terminate the replay backend or close the session tab.
##
## WHY THE ASSERTION LIVES AT `stopReplaySession` AND NOT AT `stopAction`.
## `renderer.nim` cannot be imported by any runnable lane — `nim js` on it
## pulls the Karax/Monaco tree — so `renderer-electron` / `renderer-web`
## compile-check it and no suite runs it. An empty body is invisible to a
## compile check, which is how this one lasted. `stopAction`'s entire body is
## now `discard stopReplaySession(data)`, and `stopReplaySession` is a leaf.
##
## Lane: `frontend-js` (`ci/lib/test-lane-files.sh`, `just test-frontend-js`).
## `types.nim`'s `Data` is `std/jsffi`-based, so this is JS-only.

import std/unittest
import ../types
import ../ui/stop_command

var switchToEditCalls = 0
  ## How many times the transition was actually performed. `data.functions`
  ## is the seam `ui_js.nim` fills in with the real `switchToEdit`; here it is
  ## filled with a recorder, so "did Stop do anything" is a counted VALUE.

proc installSwitchToEdit() =
  switchToEditCalls = 0
  data.functions.switchToEdit = proc(d: Data) =
    switchToEditCalls += 1
    # The real `ui_js.switchToEdit` sets this first and then rearranges the
    # layout; the mode flip is the part `stopReplaySession` is responsible for
    # causing, and the only part reproducible without a DOM.
    d.ui.mode = EditMode

proc enterDebugMode() =
  data.ui.mode = DebugMode

suite "Stop leaves Debug mode":

  test "Stop in Debug mode returns the workspace to Edit mode":
    installSwitchToEdit()
    enterDebugMode()

    let outcome = data.stopReplaySession()

    echo "outcome: ", outcome,
      ", switchToEdit calls: ", switchToEditCalls,
      ", mode after: ", data.ui.mode
    # Before the fix `stopAction` was `discard`: zero calls, mode unchanged.
    check outcome == stopLeftDebugMode
    check switchToEditCalls == 1
    check data.ui.mode == EditMode

  test "Stop does not close the session or touch the replay":
    # The half of the behaviour the spec leaves open, pinned to the reading
    # `ui/stop_command.nim` documents: the session survives and stays
    # resumable. If the owner decides the other way this case is the one that
    # has to change, which is the point of asserting it explicitly rather
    # than leaving "we didn't call it" implicit.
    installSwitchToEdit()
    enterDebugMode()
    let sessionsBefore = data.sessions.len
    let activeBefore = data.activeSessionIndex

    discard data.stopReplaySession()

    echo "sessions: ", sessionsBefore, " -> ", data.sessions.len,
      ", activeSessionIndex: ", activeBefore, " -> ", data.activeSessionIndex
    check data.sessions.len == sessionsBefore
    check data.activeSessionIndex == activeBefore
    check data.sessions.len >= 1

  test "Stop in Edit mode is a reported no-op, not a silent one":
    # `Shift+F5` is a global chord, so it is pressable in Edit mode. Doing
    # nothing is correct there; doing nothing INDISTINGUISHABLY from the
    # defect is not, which is why the outcome is a distinct value.
    installSwitchToEdit()
    data.ui.mode = EditMode

    let outcome = data.stopReplaySession()

    echo "outcome in Edit mode: ", outcome,
      ", switchToEdit calls: ", switchToEditCalls
    check outcome == stopAlreadyInEditMode
    check switchToEditCalls == 0
    check data.ui.mode == EditMode

  test "a host with no switchToEdit installed says so":
    # The nil seam. `ui_js.nim` fills it at module init, so this is the
    # non-renderer host case — and it must report rather than return quietly,
    # because a quiet return is the behaviour being fixed.
    switchToEditCalls = 0
    data.functions.switchToEdit = nil
    enterDebugMode()

    let outcome = data.stopReplaySession()

    echo "outcome with no switchToEdit: ", outcome,
      ", mode after: ", data.ui.mode
    check outcome == stopNoSwitchInstalled
    check switchToEditCalls == 0
    # Still in Debug mode: the transition did not half-happen. `switchToEdit`
    # assigning `data.ui.mode` before doing the work is a real failure mode in
    # this codebase — see the `NilAccessDefect` note in `ui_js.switchToEdit`,
    # which left a session claiming Edit while showing Debug.
    check data.ui.mode == DebugMode

  test "and Stop works again once the seam is filled":
    # Non-vacuity for the case above: the nil path must be recoverable, or
    # the previous case would pass for a `stopReplaySession` that had simply
    # stopped working.
    installSwitchToEdit()
    enterDebugMode()

    let outcome = data.stopReplaySession()

    echo "outcome after reinstalling: ", outcome,
      ", switchToEdit calls: ", switchToEditCalls
    check outcome == stopLeftDebugMode
    check switchToEditCalls == 1
