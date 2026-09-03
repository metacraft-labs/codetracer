## stop_command_test.nim
##
## Regression test for "Stop is bound and discoverable and does nothing", and
## the guard on what Stop means now that the owner has settled it.
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
## WHAT STOP DOES. Stop ENDS the debugging session: Edit mode, and the replay
## backend behind the session is terminated. The tab is NOT closed — it becomes
## an edit tab that a new debugging session can be started in. The reasoning,
## the owner's words and why `closeSession` is the wrong call are in
## `ui/stop_command.nim`'s module doc, not repeated here.
##
## THIS SUITE PREVIOUSLY ASSERTED THE OPPOSITE. The case named "Stop does not
## close the session or touch the replay" pinned the resumable reading, which
## was chosen while the spec declined the question. It is now the case that had
## to invert, which is exactly why it was written as an explicit assertion
## instead of being left implicit.
##
## WHY THE ASSERTIONS LIVE AT `stopReplaySession` AND NOT AT `stopAction`.
## `renderer.nim` cannot be imported by any runnable lane — `nim js` on it
## pulls the Karax/Monaco tree — so `renderer-electron` / `renderer-web`
## compile-check it and no suite runs it. An empty body is invisible to a
## compile check, which is how this one lasted. `stopAction`'s entire body is
## `discard stopReplaySession(data)`, and `stopReplaySession` is a leaf.
##
## Lane: `frontend-js` (`ci/lib/test-lane-files.sh`, `just test-frontend-js`).
## `types.nim`'s `Data` is `std/jsffi`-based, so this is JS-only, and `data`
## itself is declared under `when defined(ctRenderer)` (`types.nim:2286`) —
## compiling this file without `-d:ctRenderer` fails with `undeclared
## identifier: 'data'`, which is a wrong invocation and not a broken suite.

import std/[unittest, jsffi]
import ../types
import ../ui/stop_command

var switchToEditCalls = 0
  ## How many times the transition was actually performed. `data.functions`
  ## is the seam `ui_js.nim` fills in with the real `switchToEdit`; here it is
  ## filled with a recorder, so "did Stop do anything" is a counted VALUE.

var sentChannels: seq[cstring] = @[]
var sentReplayIds: seq[int] = @[]
  ## Every `data.ipc.send` Stop made, as values. `CODETRACER::close-replay-session`
  ## is the message the index process turns into `ct/stop-replay`, so "the
  ## backend was told to die, and for WHICH replay" is observable here without
  ## a main process.

proc installSwitchToEdit() =
  switchToEditCalls = 0
  data.functions.switchToEdit = proc(d: Data) =
    switchToEditCalls += 1
    # The real `ui_js.switchToEdit` sets this first and then rearranges the
    # layout; the mode flip is the part `stopReplaySession` is responsible for
    # causing, and the only part reproducible without a DOM.
    d.ui.mode = EditMode

proc installIpcRecorder() =
  sentChannels = @[]
  sentReplayIds = @[]
  let fake = newJsObject()
  fake.send = proc(channel: cstring; payload: JsObject) =
    sentChannels.add(channel)
    sentReplayIds.add(payload["replayId"].to(int))
  data.ipc = fake

proc enterDebugMode(replayId: int) =
  data.ui.mode = DebugMode
  data.activeSession.replayId = replayId
  data.activeSession.liveDebugSession = true

suite "Stop ends the debugging session":

  test "Stop in Debug mode returns the workspace to Edit mode":
    installSwitchToEdit()
    installIpcRecorder()
    enterDebugMode(replayId = 7)

    let r = data.stopReplaySession()

    echo "outcome: ", r.outcome,
      ", switchToEdit calls: ", switchToEditCalls,
      ", mode after: ", data.ui.mode
    # Before the fix `stopAction` was `discard`: zero calls, mode unchanged.
    check r.outcome == stopLeftDebugMode
    check switchToEditCalls == 1
    check data.ui.mode == EditMode

  test "Stop terminates the replay backend for the session it was pressed in":
    # THE OWNER DECISION, and the case that inverted. The previous version of
    # this suite asserted that nothing was sent. `CODETRACER::close-replay-session`
    # is `index/traces.nim`'s `onCloseReplaySession`, which writes
    # `ct/stop-replay` to the backend manager socket — the message that kills
    # the replay subprocess.
    installSwitchToEdit()
    installIpcRecorder()
    enterDebugMode(replayId = 42)

    let r = data.stopReplaySession()

    echo "termination: ", r.termination,
      ", endedReplayId: ", r.endedReplayId,
      ", channels: ", sentChannels,
      ", replayIds: ", sentReplayIds
    check r.termination == replayEnded
    # WHICH replay, not merely that a message went out: a Stop that ends
    # someone else's replay is worse than one that ends nothing.
    check r.endedReplayId == 42
    check sentChannels == @[cstring"CODETRACER::close-replay-session"]
    check sentReplayIds == @[42]

  test "the tab survives Stop, as an edit session a new run can start in":
    # `closeSession` refuses to close the last session (`session_switch.nim:303`),
    # so "terminate the session" cannot mean calling it. What must be true
    # instead is that the tab is still there AND is no longer a debugging
    # session — otherwise Run cannot start a new one in it.
    installSwitchToEdit()
    installIpcRecorder()
    let sessionsBefore = data.sessions.len
    let activeBefore = data.activeSessionIndex
    enterDebugMode(replayId = 9)

    discard data.stopReplaySession()

    echo "sessions: ", sessionsBefore, " -> ", data.sessions.len,
      ", activeSessionIndex: ", activeBefore, " -> ", data.activeSessionIndex,
      ", replayId after: ", data.activeSession.replayId,
      ", liveDebugSession after: ", data.activeSession.liveDebugSession
    check data.sessions.len == sessionsBefore
    check data.activeSessionIndex == activeBefore
    check data.sessions.len >= 1
    # The two fields that make a session a DEBUGGING session. A stale
    # `replayId` would have the next `closeSession` stop a dead replay; a stale
    # `liveDebugSession` makes `middleware.nim:52` suppress the relaunch, so
    # the promised "start a new debugging session in the usual way" would not
    # work.
    check data.activeSession.replayId == -1
    check not data.activeSession.liveDebugSession

  test "Stop pressed twice ends one replay, not two":
    # Non-vacuity for the case above, and the shape of a real double-press:
    # the second Stop must find nothing running rather than re-sending a stop
    # for an id the backend manager has already reclaimed.
    installSwitchToEdit()
    installIpcRecorder()
    enterDebugMode(replayId = 11)

    let first = data.stopReplaySession()
    data.ui.mode = DebugMode      # as if the user re-entered Debug mode
    let second = data.stopReplaySession()

    echo "first: ", first.termination, "/", first.endedReplayId,
      ", second: ", second.termination, "/", second.endedReplayId,
      ", channels: ", sentChannels
    check first.termination == replayEnded
    check second.termination == replayNotRunning
    check second.endedReplayId == -1
    check sentChannels.len == 1

  test "Stop in Edit mode is a reported no-op, not a silent one":
    # `Shift+F5` is a global chord, so it is pressable in Edit mode. Doing
    # nothing is correct there; doing nothing INDISTINGUISHABLY from the
    # defect is not, which is why the outcome is a distinct value.
    installSwitchToEdit()
    installIpcRecorder()
    data.ui.mode = EditMode

    let r = data.stopReplaySession()

    echo "outcome in Edit mode: ", r.outcome,
      ", termination: ", r.termination,
      ", switchToEdit calls: ", switchToEditCalls,
      ", channels: ", sentChannels
    check r.outcome == stopAlreadyInEditMode
    check r.termination == replayNotAttempted
    check switchToEditCalls == 0
    check data.ui.mode == EditMode
    check sentChannels.len == 0

  test "a host with no switchToEdit installed says so, and keeps its replay":
    # The nil seam. `ui_js.nim` fills it at module init, so this is the
    # non-renderer host case — and it must report rather than return quietly,
    # because a quiet return is the behaviour being fixed.
    switchToEditCalls = 0
    installIpcRecorder()
    data.functions.switchToEdit = nil
    enterDebugMode(replayId = 5)

    let r = data.stopReplaySession()

    echo "outcome with no switchToEdit: ", r.outcome,
      ", termination: ", r.termination,
      ", mode after: ", data.ui.mode,
      ", replayId after: ", data.activeSession.replayId,
      ", channels: ", sentChannels
    check r.outcome == stopNoSwitchInstalled
    check switchToEditCalls == 0
    # Still in Debug mode: the transition did not half-happen. `switchToEdit`
    # assigning `data.ui.mode` before doing the work is a real failure mode in
    # this codebase — see the `NilAccessDefect` note in `ui_js.switchToEdit`,
    # which left a session claiming Edit while showing Debug.
    check data.ui.mode == DebugMode
    # AND THE REPLAY IS STILL ALIVE. A host stuck in Debug mode with a dead
    # backend is the one state neither reading of Stop permits.
    check r.termination == replayNotAttempted
    check data.activeSession.replayId == 5
    check sentChannels.len == 0

  test "and Stop works again once the seam is filled":
    # Non-vacuity for the case above: the nil path must be recoverable, or
    # the previous case would pass for a `stopReplaySession` that had simply
    # stopped working.
    installSwitchToEdit()
    installIpcRecorder()
    enterDebugMode(replayId = 5)

    let r = data.stopReplaySession()

    echo "outcome after reinstalling: ", r.outcome,
      ", termination: ", r.termination,
      ", switchToEdit calls: ", switchToEditCalls,
      ", replayIds: ", sentReplayIds
    check r.outcome == stopLeftDebugMode
    check r.termination == replayEnded
    check switchToEditCalls == 1
    check sentReplayIds == @[5]
