## later_session_launch_failure_test.nim
##
## A REPLAY THAT CANNOT START SAYS SO IN ITS OWN TAB — in every tab, not only
## the one the window opened with.
##
## ## The defect this pins
##
## When a replay cannot start, the replay server sends two events tagged with
## the session they belong to (`send_launch_failure_notification` in
## `src/db-backend/src/dap_server.rs`): an Error `ct/notification` carrying the
## reason, which the status bar lists in `#active-notifications`, and
## `ct/launch-failed` (`{message}`), which says the launch is over. For the
## first tab both arrived. For a tab opened later the user saw nothing — the
## tab sat with empty panes and no reason — because:
##
##   * only the first session's `DapApi` forwarded `ct/notification` to its
##     views (`middleware.setupMiddlewareApis` then ran once per window), so a
##     later tab's `DapApi` had no handler for it;
##   * every event was handed to the `DapApi` of the tab ON SCREEN, whatever
##     session it was tagged with, so a later tab's refusal arriving while
##     another tab was shown went to the wrong tab;
##   * `ct/launch-failed` had no `CtEventKind`, so it was dropped as unmapped
##     and nothing ended the tab's busy state.
##
## ## What is asserted
##
## Two tabs, the first one on screen. A refusal tagged for the SECOND tab is
## delivered through the renderer's real event entry point
## (`event_helpers.deliverDapEvent`, the whole body of
## `ui_js.onDapReceiveEvent`) and must:
##
##   * land in the second tab's status bar, once, and end its busy state;
##   * leave the first tab's status bar exactly as it was;
##   * not be painted into the window's one `#status` element while its tab is
##     hidden, and be painted there — with its auto-dismiss timer not yet
##     started — when its tab is switched to.
##
## The routing is held from the other side too: a move of the FIRST tab
## delivered while the later tab is shown updates the first tab's status bar
## and run state only, and is drawn when the first tab is shown again.
##
## ## What is real, and the one stand-in
##
## REAL: `types`' window `Data` and its first session;
## `middleware.setupMiddlewareApis`, what `ui_js.configureSessionMiddleware` runs for
## each tab (here, only the first: the second tab's notices are wired by
## `attachSessionApis` alone, which is what this suite is about); the second tab's DAP API and views mediator, built by
## `event_helpers.attachSessionApis` — the call `session_switch.createNewSession`
## (the code a "+" click runs) makes for them; each tab's `StatusComponent`,
## built by `utils.makeStatusComponent` while its tab is the active one, as
## both `renderer.createUIComponents` and `createNewSession` build it, and its
## render into `#status` over jsdom's DOM; and `deliverDapEvent`. The event
## frames have the shape the main process delivers: the server's event plus
## the `sessionId` the main process tags it with
## (`index/ipc_subsystems/dap.nim`).
##
## NOT CALLED, and why: `createNewSession` and `switchSession` themselves.
## `session_switch` reaches the editor through its menu, and the editor
## creates a Monaco model when its module loads, so importing it here would
## mean standing in a fake Monaco for a suite about the status bar. What this
## suite needs from them is done the way they do it: the second tab's
## remaining fields are the subset of `createNewSession`'s the status bar
## reads, and a switch is `switchSession`'s two steps that concern the bar —
## make the target the active session, then redraw its status component.
##
## THE ONE STAND-IN: the `ipc` object's `send`, which records outgoing frames
## instead of writing them to the main process. Nothing under test is replaced
## or observed through it; it exists because the session code copies the
## window's IPC bridge into each tab's `DapApi`, and there is no main process
## in this suite. `ui_js.onDapReceiveEvent` itself is not called because
## `ui_js.nim` is the renderer's entry module (importing it boots the
## application); its body is one call to `deliverDapEvent`.
##
## Lane: `renderer-dom` — the BROWSER target (`nim js -d:ctRenderer`, no
## `-d:nodejs`: the status bar's kdom graph does not compile under it), run by
## `jsdom-run.mjs` over a real DOM. WITHOUT `-d:ctInExtension`: the desktop
## `DapApi` is the one that carries the Electron IPC bridge. Without
## `-d:nodejs` `std/unittest` cannot set the exit status, so this suite sets
## it. The scenarios await the status bar's coalesced render, which a
## `std/unittest` `test` block cannot, so each prints its own `[OK]` /
## `[FAILED]` line in unittest's format for the lane runner to count.

import std/[unittest, jsffi, strutils, sequtils, asyncjs, dom]

import ../types
import ../dap
import ../communication
import ../middleware
import ../event_helpers
import ../utils
import ../ui/status
import ../../common/ct_event

const ExpectedChecks = 30
var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
  check cond

template scenario(name: string; body: untyped) =
  ## One named case: `[OK]` when none of its checks failed.
  block:
    let failedBefore = failedChecks
    body
    echo(if failedChecks == failedBefore: "  [OK] " else: "  [FAILED] ", name)

proc settle(): Future[void] =
  ## Yield one task turn: the status bar coalesces its renders onto the next
  ## turn (`requestStatusRender`), so a render asked for by a delivery has
  ## happened only after this.
  newPromise proc(resolve: proc()) =
    {.emit: "setTimeout(`resolve`, 0);".}

# ---------------------------------------------------------------------------
# The window: two tabs, the first one on screen
# ---------------------------------------------------------------------------

var sentPackets: seq[JsObject] = @[]

proc recordingIpc(): JsObject =
  let ipc = JsObject{}
  ipc.send = proc(channel: cstring, packet: JsObject) =
    sentPackets.add(packet)
  ipc

# The one `#status` element every tab's status bar draws into.
let statusHost = document.createElement("div")
statusHost.id = "status"
document.body.appendChild(statusHost)

proc initComponentRegistry(ui: Components) =
  ## What `createNewSession` does before it builds a tab's components.
  for content in Content:
    ui.componentMapping[content] = JsAssoc[int, Component]{}
    ui.openComponentIds[content] = @[]

# The first tab: the session `types` builds with the window.
data.ipc = recordingIpc()
data.dapApi.ipc = data.ipc
data.ui.initComponentRegistry()
discard data.makeStatusComponent(nil, nil, nil)
setupMiddlewareApis(data.dapApi, data.viewsApi)

# A tab opened after it.
block:
  let sessionId = data.sessions.len
  let session = newReplaySession(ReplaySessionId(sessionId))
  attachSessionApis(session, sessionId, data.ipc)
  session.services = Services(
    debugger: DebuggerService(),
    editor: EditorService(open: JsAssoc[cstring, TabInfo]{}))
  session.ui = Components(editors: JsAssoc[cstring, EditorViewComponent]{})
  session.ui.initComponentRegistry()
  session.connection = ConnectionState(connected: true)
  session.status = StatusState(stableBusy: false)
  session.startOptions = StartOptions()
  data.sessions.add(session)
  # Its components are built while it is the active session, as
  # `createNewSession` builds them: `makeStatusComponent` registers on the
  # ACTIVE session's views mediator.
  data.activeSessionIndex = sessionId
  discard data.makeStatusComponent(nil, nil, nil)
  data.activeSessionIndex = 0

proc showTab(index: int) =
  ## A tab switch, as far as the status bar is concerned (see the header).
  data.activeSessionIndex = index
  data.ui.status.redraw()

let firstTab = data.sessions[0]
let laterTab = data.sessions[1]
let laterSessionId = laterTab.dapApi.sessionId

const refusal =
  "trace mode serves a Linux interpose recording through the stage0 " &
  "emulator replay, and this recording has no stage0 boundary the emulator " &
  "can start from"

proc eventFrame(sessionId: int; event: cstring; body: JsObject): JsObject =
  ## A DAP event as the renderer receives it: the server's frame plus the
  ## `sessionId` the main process tags it with.
  js{"type": cstring"event", "event": event, "body": body,
     "sessionId": sessionId}

proc errorNotificationBody(text: cstring): JsObject =
  ## The server's `task::Notification` of kind Error, serialised camelCase
  ## (`NotificationKind` is `repr(u8)`: Error is 2).
  js{"kind": 2, "time": 0, "text": text, "active": true, "seen": false,
     "timeoutId": 0, "hasTimeout": false, "isOperationStatus": false,
     "actions": newSeq[JsObject]()}

proc notificationTexts(tab: ReplaySession): seq[string] =
  for notification in tab.ui.status.notifications:
    result.add $notification.text

proc paintedNotifications(): string =
  ## What the window's `#status` element shows in its active-notifications
  ## stack, as text.
  let stack = document.getElementById("active-notifications")
  if stack.isNil: "" else: $stack.textContent

proc runChecks() {.async.} =
  scenario "the suite builds two tabs, the first on screen, both busy":
    ck data.sessions.len == 2
    ck data.activeSessionIndex == 0
    ck not firstTab.ui.status.isNil
    ck not laterTab.ui.status.isNil
    ck firstTab.ui.status != laterTab.ui.status
    ck laterSessionId != firstTab.dapApi.sessionId
    ck firstTab.ui.status.state.stableBusy
    ck laterTab.ui.status.state.stableBusy
    await settle()
    ck refusal notin paintedNotifications()

  scenario "ct/launch-failed is a known event, not an unmapped one":
    var mapped = ""
    try:
      mapped = $dapEventToCtEventKind(cstring"ct/launch-failed")
    except ValueError:
      mapped = "unmapped"
    ck mapped == "CtLaunchFailed"

  scenario "a hidden later tab's refusal reaches that tab only, and waits":
    deliverDapEvent(data, eventFrame(laterSessionId, cstring"ct/notification",
      errorNotificationBody(refusal)))
    deliverDapEvent(data, eventFrame(laterSessionId, cstring"ct/launch-failed",
      js{"message": cstring(refusal)}))
    await settle()
    # Once, in its own tab, and the launch is no longer shown as running.
    ck laterTab.notificationTexts() == @[refusal]
    ck not laterTab.ui.status.state.stableBusy
    # Not in the tab on screen.
    ck firstTab.notificationTexts().len == 0
    ck firstTab.ui.status.state.stableBusy
    # Not painted over the tab on screen.
    ck refusal notin paintedNotifications()
    # Still active, its display time not yet started.
    ck laterTab.ui.status.notifications.len == 1 and
      laterTab.ui.status.notifications[0].active and
      not laterTab.ui.status.notifications[0].hasTimeout

  scenario "switching to the later tab shows the refusal, for its full time":
    showTab(1)
    await settle()
    ck refusal in paintedNotifications()
    ck laterTab.ui.status.notifications.len == 1 and
      laterTab.ui.status.notifications[0].active and
      laterTab.ui.status.notifications[0].hasTimeout

  scenario "switching back takes the refusal off the bar":
    showTab(0)
    await settle()
    ck refusal notin paintedNotifications()

  scenario "the first tab's move while another tab is shown stays in the first tab":
    # The handlers on the first session's `DapApi` (`types`' service update,
    # `setupMiddlewareApis`' status update) once wrote into whichever tab was
    # on screen. Routed by session, they now run while a later tab is shown,
    # and must touch only the first tab: this suite's later tab has services
    # with no move callbacks (as `createNewSession` built them before it
    # gave each tab copies, `types.wireSessionServiceMoves`), so a move
    # applied to them threw, and its status bar showed the first tab's
    # location.
    showTab(1)
    await settle()
    let laterLocationBefore = laterTab.ui.status.location
    # A whole `MoveState`, every field present, as the server's frame has it:
    # the debugger service copies the move field by field.
    let move = MoveState(
      status: cstring"",
      location: types.Location(path: cstring"/src/first_tab_program.py",
        line: 7, rrTicks: 3),
      cLocation: types.Location(),
      frameInfo: FrameInfo())
    deliverDapEvent(data, eventFrame(firstTab.dapApi.sessionId,
      cstring"ct/complete-move", move.toJs))
    await settle()
    ck not firstTab.ui.status.location.path.isNil and
      $firstTab.ui.status.location.path == "/src/first_tab_program.py" and
      firstTab.ui.status.location.line == 7
    ck firstTab.status.hasStarted
    ck laterTab.ui.status.location == laterLocationBefore
    ck not laterTab.status.hasStarted
    ck "first_tab_program" notin $statusHost.textContent
    showTab(0)
    await settle()
    ck "first_tab_program.py:7" in $statusHost.textContent

  scenario "wiring a session twice does not show its notices twice":
    wireSessionNotifications(laterTab.dapApi, laterTab.viewsApi)
    deliverDapEvent(data, eventFrame(laterSessionId, cstring"ct/notification",
      errorNotificationBody(cstring"second notice")))
    await settle()
    ck laterTab.notificationTexts().count("second notice") == 1

  scenario "an event for a tab that no longer exists reaches no tab":
    deliverDapEvent(data, eventFrame(laterSessionId + 100,
      cstring"ct/notification", errorNotificationBody(cstring"orphan")))
    await settle()
    ck "orphan" notin firstTab.notificationTexts()
    ck "orphan" notin laterTab.notificationTexts()

  scenario "an untagged event belongs to the tab on screen":
    deliverDapEvent(data, js{"type": cstring"event",
      "event": cstring"ct/notification",
      "body": errorNotificationBody(cstring"untagged")})
    await settle()
    ck firstTab.notificationTexts() == @["untagged"]
    ck "untagged" notin laterTab.notificationTexts()

  # Every check above ran: a scenario that stopped early is a failure, not a
  # shorter pass.
  if checks != ExpectedChecks:
    echo "  [FAILED] every check ran: expected ", ExpectedChecks, ", ran ", checks
    inc failedChecks
  echo "CHECKS: ", checks
  if failedChecks > 0:
    {.emit: "process.exitCode = 1;".}

discard runChecks().catch(proc(error: Error) =
  echo "  [FAILED] the suite stopped: ", error.message
  {.emit: "process.exitCode = 1;".})
