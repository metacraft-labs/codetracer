## status_notifications_across_reload_test.nim
##
## A NOTICE OUTLIVES THE STATUS BAR IT WAS SHOWN IN.
##
## Loading a trace rebuilds the layout (`renderer.resetLayoutState` replaces
## `data.ui`, `createUIComponents` builds a new status bar). A notice raised
## just before was dropped with the old bar. The case that showed it: a second
## Ctrl+R while a re-record runs is refused with "A recording is already in
## progress", and when the recording is quick its trace loads a few hundred
## milliseconds later, so the refusal was on screen for that long instead of
## its dismiss time.
##
## This suite drives the real constructor and the real reset hand-over:
## `keepStatusNotificationsAcrossReset` (what `resetLayoutState` calls) and
## `makeStatusComponent` (what `createUIComponents` calls).
##
## Lane: `renderer-dom` (imports `utils.nim`, a renderer module).

import std/[unittest, jsffi]

import ../types
import ../utils
import ../lib/jslib

const ExpectedChecks = 7
var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
  check cond

template scenario(name: string; body: untyped) =
  block:
    let failedBefore = failedChecks
    body
    echo(if failedChecks == failedBefore: "  [OK] " else: "  [FAILED] ", name)

proc freshUi() =
  ## The `data.ui` that `resetLayoutState` installs: empty component maps.
  data.ui = Components(editors: JsAssoc[cstring, EditorViewComponent]{})
  for content in Content:
    data.ui.componentMapping[content] = JsAssoc[int, Component]{}
    data.ui.openComponentIds[content] = @[]

proc buildStatus(): StatusComponent =
  data.makeStatusComponent(nil, nil, nil)

scenario "a notice shown before a trace reload is shown after it":
  freshUi()
  let before = buildStatus()
  let refused = newNotification(NotificationWarning,
    "A recording is already in progress; the new request was ignored.")
  # Drawn by the old bar, which armed its dismiss timer.
  refused.hasTimeout = true
  refused.timeoutId = windowSetTimeout(proc = discard, 60_000)
  before.notifications.add(refused)

  keepStatusNotificationsAcrossReset(data.ui.status)
  freshUi()
  ck data.ui.status.isNil
  let after = buildStatus()
  ck after != before
  ck after.notifications.len == 1
  ck after.notifications.len == 1 and after.notifications[0] == refused
  ck refused.active
  # The old bar's timer is gone; the new bar arms its own when it draws it.
  ck not refused.hasTimeout

scenario "a hand-over is used once":
  freshUi()
  let fresh = buildStatus()
  ck fresh.notifications.len == 0

if checks != ExpectedChecks:
  echo "  [FAILED] every check ran: expected ", ExpectedChecks, ", ran ", checks
  inc failedChecks
echo "CHECKS: ", checks
if failedChecks > 0:
  {.emit: "process.exitCode = 1;".}
