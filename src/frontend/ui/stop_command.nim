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
## `../types` and `../lib/logging` and that
## `src/frontend/tests/stop_command_test.nim` runs under node.
##
## ## What Stop does, and where that is settled
##
## `codetracer-specs` `latest`, `GUI/Debugging-Features/Debugger-Controls.md`
## § "Ending a session from inside it":
##
##   "A user who has entered Debug mode must be able to leave it without
##    closing the window or the application. *Stop* is that command, and it is
##    the reverse of *Run*: it returns the workspace to Edit mode."
##
## and `GUI/Layout-And-Navigation/Mode-Transitions.md` § 1, whose transition
## table gives the Debug → Edit row the trigger "*Stop*, or the mode toggle",
## the duration "Instant, always" and the verdict column "No" — it cannot fail.
##
## ## What Stop does NOT do, and why that is also from the spec
##
## The same spec section carries an unresolved owner decision:
##
##   "Whether *Stop* also terminates the replay backend and closes the session
##    tab, or leaves the session tab intact and resumable, is **not** decided
##    here; the two answers give different meanings to the session strip of
##    Multi-Window Tab Management."
##
## This implements the resumable reading, for three reasons, none of them a
## preference:
##
## 1. It is the only one consistent with what Mode-Transitions § 5 and § 6
##    already REQUIRE of every Debug → Edit transition — that it preserve the
##    working set and be reversible. Terminating the backend would make the
##    transition irreversible, and § 1 says it "cannot fail".
## 2. It is recoverable in the direction a user can act on. Someone who wanted
##    the session gone can still close the tab, which is the path that really
##    ends a replay (`ui/session_switch.nim`'s `closeSession` →
##    `CODETRACER::close-replay-session` → `ct/stop-replay` → the backend
##    manager's `stop_replay`, which kills the subprocess). A Stop that killed
##    the backend cannot be undone by any gesture.
## 3. `closeSession` refuses to close the last remaining session, so wiring
##    Stop to it would make Stop a no-op in the single-session case — which is
##    the case the defect was reported in.
##
## If the owner decides the other way, the change is one added call in
## `stopReplaySession`, and this comment is the record of what was assumed
## meanwhile.

import ../types
import ../lib/logging

type
  StopOutcome* = enum
    ## What a `stopReplaySession` call did. Returned rather than logged only,
    ## so the behaviour is a VALUE a test can assert instead of a side effect
    ## it has to infer.
    stopLeftDebugMode
      ## The session was in Debug mode and is now in Edit mode.
    stopAlreadyInEditMode
      ## Nothing to leave. Not an error: `Shift+F5` is a global chord and Edit
      ## mode is a legitimate place to press it.
    stopNoSwitchInstalled
      ## `data.functions.switchToEdit` was nil, so the transition could not be
      ## performed. This is the shape of the original defect and is reported
      ## rather than swallowed.

proc stopReplaySession*(data: Data): StopOutcome =
  ## Leave Debug mode for Edit mode. See the module doc for what this
  ## deliberately does not touch.
  if data.isNil or data.ui.isNil:
    cerror "stop: no session to stop"
    return stopNoSwitchInstalled

  if data.ui.mode != DebugMode:
    clog "stop: already in Edit mode, nothing to leave"
    return stopAlreadyInEditMode

  if data.functions.switchToEdit.isNil:
    # `ui_js.nim` assigns `data.functions.switchToEdit` at module init, so a
    # renderer always has it. A host that links `renderer.nim` without
    # `ui_js.nim` does not, and the honest answer there is a logged refusal —
    # a silent return is precisely the defect being fixed.
    cerror "stop: switchToEdit is not installed; staying in Debug mode"
    return stopNoSwitchInstalled

  clog "stop: leaving Debug mode for Edit mode"
  data.functions.switchToEdit(data)
  stopLeftDebugMode
