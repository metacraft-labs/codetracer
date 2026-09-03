## *Stop* — what the command does, in a module a suite can reach.
##
## ## Why this is not just a body in `renderer.nim`
##
## `renderer.stopAction` is where the chord and the action table land, and it
## is where the behaviour lived as `discard` from the initial open-source
## commit until this change: bound in `src/config/default_config.yaml:75`,
## dispatched through `ui_js.nim`'s action table, and inert.
##
## The reason that could survive is that nothing can test it. `nim js` on
## `renderer.nim` pulls the Karax/Monaco tree, so no runnable lane imports it —
## `renderer-electron` and `renderer-web` compile-check it and stop there. A
## proc body that is only ever compiled is a proc body whose emptiness no
## check can see. So the decision lives here, in a leaf that imports only
## `std/jsffi`, `../types` and `../lib/logging` and that
## `src/frontend/tests/stop_command_test.nim` runs under node.
##
## ## What Stop does
##
## **Stop ENDS the debugging session.** It is not a pause. After Stop the
## workspace is in Edit mode, the replay backend for the session is gone, and
## the tab is an ordinary edit tab from which a *new* debugging session can be
## started in the usual way — Run, or opening a trace.
##
## That is the Visual Studio reading of the command, and it is the one the
## owner chose. `codetracer-specs` `latest`,
## `GUI/Debugging-Features/Debugger-Controls.md` § "Ending a session from
## inside it" now states it rather than leaving it open:
##
##   "*Stop* ends the debugging session. It is the reverse of *Run* ... The
##    session tab is **not** closed. It survives as an edit tab ... *Pause* is
##    a separate, resumable operation and is not what *Stop* does."
##
## and `GUI/Layout-And-Navigation/Mode-Transitions.md` § 1, whose transition
## table gives the Debug → Edit row the trigger "*Stop*, or the mode toggle",
## the duration "Instant, always" and the verdict column "No" — it cannot fail.
##
## ## Why the tab survives, rather than Stop calling `closeSession`
##
## Two reasons, and the first is dispositive:
##
## 1. `ui/session_switch.nim`'s `closeSession` REFUSES to close the last
##    remaining session (`if data.sessions.len <= 1: return`, `:303`). Wiring
##    Stop to it would make Stop a no-op in the single-session case — which is
##    the case the defect was reported in, and the case an ordinary user is
##    always in.
## 2. The owner's sentence is "you get back to the edit mode and you can start
##    a new debugging session in the usual way". A closed tab is not somewhere
##    you get back *to*. The tab is the workspace; the replay is what ends.
##
## So Stop performs `closeSession`'s replay half — the
## `CODETRACER::close-replay-session` message that reaches `ct/stop-replay` and
## the backend manager's `stop_replay`, which kills the subprocess — and skips
## its tab half. It then clears the two fields that make a session a
## *debugging* session (`replayId`, `liveDebugSession`), so the tab is an edit
## tab and the next `dap-replay-selected` writes a fresh replay into it.
##
## The note this module used to carry claimed the flip to this behaviour was
## "one added call in `stopReplaySession`". It is not, and the claim is
## recorded here because it is the kind of estimate that gets believed:
## `closeSession` is the wrong call (see 1 above), and it lives in
## `ui/session_switch.nim`, which imports `../renderer` — importing it here
## would pull the Karax/Monaco tree into this leaf and destroy the only reason
## `stop_command.nim` exists.
##
## ## Pause is a separate operation and DOES NOT EXIST YET
##
## The owner has settled that *Pause* is a distinct, resumable operation. It
## is not implemented, anywhere, and nothing in this module stands in for it:
##
## * there is no `ClientAction` for it —
##   `common_types/codetracer_features/frontend.nim` has `forwardContinue`,
##   `reverseContinue`, the four step pairs and `stop`, and no pause;
## * `ui_js.nim:927` carries the only trace of an attempt, a commented-out menu
##   entry `element "Pause (currently using stop shortcut?)", stop, false` —
##   which, had it been live, would have dispatched Pause to *this* proc;
## * `ui/dap/response.nim:25` names a DAP `Pause` response body in a type
##   sketch that nothing constructs.
##
## Folding Pause into Stop is therefore the one thing this module must not do,
## and the parenthesis in that dead menu entry is what it would have looked
## like.

import std/jsffi
import ../types
import ../lib/logging

type
  StopOutcome* = enum
    ## What `stopReplaySession` did to the *mode*. Returned rather than logged
    ## only, so the behaviour is a VALUE a test can assert instead of a side
    ## effect it has to infer.
    stopLeftDebugMode
      ## The session was in Debug mode and is now in Edit mode.
    stopAlreadyInEditMode
      ## Nothing to leave. Not an error: `Shift+F5` is a global chord and Edit
      ## mode is a legitimate place to press it.
    stopNoSwitchInstalled
      ## `data.functions.switchToEdit` was nil, so the transition could not be
      ## performed. This is the shape of the original defect and is reported
      ## rather than swallowed.

  ReplayTermination* = enum
    ## What `stopReplaySession` did to the *replay*. Separate from
    ## `StopOutcome` because the two can disagree — a session already in Edit
    ## mode has no replay to end — and because "the session really ended" is
    ## the half of Stop the owner decision changed, so it must be assertable on
    ## its own.
    replayNotAttempted
      ## Stop did not get as far as the replay: no session, or the mode
      ## transition refused.
    replayNotRunning
      ## The session held no live replay (`replayId < 0`). Pressing Stop in
      ## Edit mode, or twice, lands here.
    replayNoIpc
      ## There is a live `replayId` but no IPC channel to tell anyone about it.
      ## The session fields are still cleared — a renderer with no `ipc` is a
      ## host that has no backend to leak — but this is reported, not silent.
    replayEnded
      ## The backend was told to stop the replay and the session was returned
      ## to edit state. This is the ordinary outcome of Stop in Debug mode.

  StopResult* = object
    ## The whole of what Stop did, as one value.
    outcome*: StopOutcome
    termination*: ReplayTermination
    endedReplayId*: int
      ## The `replayId` that was terminated, or `-1` when none was. Recorded
      ## because "we sent a stop" is not the assertion that matters — WHICH
      ## replay was stopped is.

proc terminateActiveReplay(data: Data): (ReplayTermination, int) =
  ## End the active session's replay and return the session to edit state.
  ##
  ## This is `ui/session_switch.nim`'s `closeSession` MINUS the tab teardown:
  ## the same `CODETRACER::close-replay-session` message, which the index
  ## process turns into `ct/stop-replay` (`index/traces.nim:773`) and also uses
  ## to stop the visual-replay player and clear `selectedReplayId`.
  if data.sessions.len == 0:
    return (replayNotAttempted, -1)

  let session = data.activeSession
  let replayId = session.replayId
  if replayId < 0:
    # Nothing is running. Still clear `liveDebugSession`: a launch that never
    # reached `dap-replay-selected` can leave it set with no id to stop, and
    # leaving it set would make the middleware treat the next trace load as
    # already-live (`middleware.nim:52`).
    session.liveDebugSession = false
    return (replayNotRunning, -1)

  var termination = replayEnded
  if data.ipc.isNil or data.ipc.isUndefined:
    cerror "stop: no ipc channel; replay " & $replayId & " may outlive the session"
    termination = replayNoIpc
  else:
    data.ipc.send(cstring"CODETRACER::close-replay-session",
                  js{"replayId": replayId})

  # THE TAB SURVIVES, THE SESSION DOES NOT. Clearing these two fields is what
  # makes the difference between "a debug tab whose backend is dead" — which
  # would be a session the user cannot restart, because `dap-replay-selected`
  # would overwrite a stale id and `middleware.nim:52` would suppress the
  # relaunch — and an edit tab that Run can start a new debugging session in.
  session.replayId = -1
  session.liveDebugSession = false

  (termination, replayId)

proc stopReplaySession*(data: Data): StopResult =
  ## End the debugging session: leave Debug mode for Edit mode, and terminate
  ## the replay behind it. See the module doc for why the tab is kept.
  if data.isNil or data.ui.isNil:
    cerror "stop: no session to stop"
    return StopResult(outcome: stopNoSwitchInstalled,
                      termination: replayNotAttempted, endedReplayId: -1)

  if data.ui.mode != DebugMode:
    clog "stop: already in Edit mode, nothing to leave"
    return StopResult(outcome: stopAlreadyInEditMode,
                      termination: replayNotAttempted, endedReplayId: -1)

  if data.functions.switchToEdit.isNil:
    # `ui_js.nim` assigns `data.functions.switchToEdit` at module init, so a
    # renderer always has it. A host that links `renderer.nim` without
    # `ui_js.nim` does not, and the honest answer there is a logged refusal —
    # a silent return is precisely the defect being fixed.
    #
    # THE REPLAY IS LEFT ALONE ON THIS PATH, deliberately. A host that cannot
    # reach Edit mode would otherwise be left in Debug mode with a dead
    # backend: the worst of both readings, and unrecoverable by any gesture.
    cerror "stop: switchToEdit is not installed; staying in Debug mode"
    return StopResult(outcome: stopNoSwitchInstalled,
                      termination: replayNotAttempted, endedReplayId: -1)

  # THE MODE FIRST, THE BACKEND SECOND. Mode-Transitions § 1 gives Debug → Edit
  # the verdict "cannot fail", and `switchToEdit` calls `clear()` on every
  # component — which is a `{.base.}` method dispatch that has raised
  # `NilAccessDefect` in this codebase before (see the two long comments in
  # `ui_js.switchToEdit`). Ending the replay first would mean those `clear()`
  # calls run against a backend that is already gone.
  clog "stop: ending the debugging session and returning to Edit mode"
  data.functions.switchToEdit(data)

  let (termination, endedReplayId) = data.terminateActiveReplay()
  clog "stop: replay termination " & $termination & ", replayId " & $endedReplayId
  StopResult(outcome: stopLeftDebugMode,
             termination: termination, endedReplayId: endedReplayId)
