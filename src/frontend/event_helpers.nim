import
  std / [jsffi, jsconsole],
  .. / common / ct_event,
  types,
  communication, dap,
  lib/[ jslib ]

const HISTORY_JUMP_VALUE*: string = "history-jump"

proc makeNotification*(kind: NotificationKind, text: cstring, isOperationStatus: bool = false): Notification =
  Notification(
    kind: kind,
    text: text,
    time: Date.now(),
    active: true,
    isOperationStatus: isOperationStatus)

proc ctSourceLineJump*(dap: DapApi, line: int, path: cstring, behaviour: JumpBehaviour) {.exportc.} =
    let target = SourceLineJumpTarget(
    path: path,
    line: line,
    behaviour: behaviour,
    )
    dap.sendCtRequest(CtSourceLineJump, target.toJs)

proc ctAddToScratchpad*(api: MediatorWithSubscribers, expression: cstring) {.exportc.} =
  api.emit(InternalAddToScratchpadFromExpression, expression)

proc historyJump*(api: MediatorWithSubscribers, location: types.Location) =
  api.emit(InternalNewOperation, NewOperation(name: HISTORY_JUMP_VALUE, stableBusy: true))
  api.emit(CtHistoryJump, location)

proc installCt() =
  when not defined(ctInExtension):
    data.ipc.send "CODETRACER::install-ct", js{}

proc showNotification*(api: MediatorWithSubscribers, notification: Notification) =
  api.emit(CtNotification, notification)

proc infoMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationInfo, text)
  api.showNotification(notification)

proc installMessage*(api: MediatorWithSubscribers) =
  let notification = newNotification(
    NotificationKind.NotificationInfo,
    "CodeTracer isn't installed. Do you want to install it?",
    actions = @[newNotificationButtonAction("Install", proc = installCt())]
  )
  api.showNotification(notification)

proc warnMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationWarning, text)
  api.showNotification(notification)

proc errorMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationError, text)
  api.showNotification(notification)

proc successMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationSuccess, text)
  api.showNotification(notification)

proc openValueInScratchpad*(api: MediatorWithSubscribers, arg: ValueWithExpression) =
  api.emit(InternalAddToScratchpad, arg)

# ---------------------------------------------------------------------------
# Per-session DAP wiring and routing
#
# Every replay tab is its own `ReplaySession` with its own `DapApi` and its own
# views mediator, while the window has ONE IPC channel on which the main
# process delivers every session's DAP traffic. Each frame is tagged with the
# `sessionId` of the session it belongs to (`index/ipc_subsystems/dap.nim`),
# and the two procs below are what make that tag mean something in the
# renderer: a frame reaches the `DapApi` of the tab it was tagged for, and that
# `DapApi` hands what the user must see to the same tab's views.
# ---------------------------------------------------------------------------

proc wireSessionNotifications*(dapApi: DapApi; viewsApi: MediatorWithSubscribers) =
  ## Forward a replay session's backend notices to that session's own views:
  ## every `ct/notification` (the status bar's active notifications) and
  ## `ct/launch-failed` (which ends the tab's busy state when its replay
  ## cannot start).
  ##
  ## Called for EVERY session: by `middleware.setupMiddlewareApis` for the
  ## session the window opened with, and by `attachSessionApis` for each tab
  ## opened after it. Before the second call site existed only the first
  ## session had these forwarders, so a refusal sent to a later tab reached a
  ## `DapApi` with no handler for it and the tab stayed empty with no reason
  ## given.
  ##
  ## Idempotent per `DapApi` (`notificationsWired`): a session wired a second
  ## time — by a later call site, or a re-run of either — must not show every
  ## notice twice.
  if dapApi.isNil or viewsApi.isNil or dapApi.notificationsWired:
    return
  dapApi.notificationsWired = true
  dapApi.on(CtNotification, proc(kind: CtEventKind, value: Notification) =
    viewsApi.emit(CtNotification, value))
  dapApi.on(CtLaunchFailed, proc(kind: CtEventKind, value: LaunchFailure) =
    viewsApi.emit(CtLaunchFailed, value))

when defined(ctRenderer):
  proc attachSessionApis*(session: ReplaySession; sessionId: int; ipc: JsObject) =
    ## Give a replay tab created after the first its own DAP API and views
    ## mediator (`session_switch.createNewSession`), wired as the first tab's
    ## are for what the user must see: its backend notices.
    ##
    ## M8/issue #327: the per-session `DapApi` is tagged with `sessionId` so
    ## outgoing DAP requests carry the correct `sessionId` field and the
    ## main-process router in `ipc_subsystems/dap.nim` can switch the Backend
    ## Manager to the right replay. Defaulting to 0 here would make every
    ## non-default session impersonate session 0 on the wire; it is also the
    ## id `deliverDapEvent` routes the tab's events back by.
    ##
    ## Desktop sessions need the Electron IPC bridge copied from the app-wide
    ## data object. Extension builds use a different `DapApi` shape and fill
    ## in the VS Code handles elsewhere.
    when defined(ctInExtension):
      session.dapApi = DapApi(sessionId: sessionId)
    else:
      session.dapApi = DapApi(sessionId: sessionId, ipc: ipc)
    session.viewsApi = setupSinglePageViewsApi(
      cstring("single-page-frontend-to-views-" & $sessionId))
    # Without this a later tab whose replay cannot start received the refusal
    # on a `DapApi` with no handler for it and stayed empty with no reason.
    wireSessionNotifications(session.dapApi, session.viewsApi)

func jsHasOwnKey(obj: JsObject; key: cstring): bool {.
  importjs: "Object.prototype.hasOwnProperty.call(# || {}, #)", noSideEffect.}
  ## Presence probe that tolerates a `null`/`undefined` frame.

proc sessionDapApi*(data: Data; sessionId: int): DapApi =
  ## The `DapApi` of the replay session whose id is `sessionId`, or nil when
  ## no open tab has that id (its tab was closed while the frame was in
  ## flight).
  ##
  ## Matched on `DapApi.sessionId`, the id the session stamps on the requests
  ## it sends, rather than on the position in `data.sessions`: closing a tab
  ## shifts the positions of the tabs after it, but not the ids the main
  ## process routes by.
  for session in data.sessions:
    if not session.isNil and not session.dapApi.isNil and
        session.dapApi.sessionId == sessionId:
      return session.dapApi
  nil

proc dapApiForFrame*(data: Data; raw: JsObject): DapApi =
  ## The `DapApi` a DAP frame from the main process belongs to.
  ##
  ## A frame that carries a `sessionId` belongs to that session's tab, whether
  ## or not that tab is on screen; nil when the tab is gone. A frame without
  ## one (the browser replay host, which serves a single session, posts its
  ## frames untagged) belongs to the tab on screen, `data.dapApi`.
  if not jsHasOwnKey(raw, cstring"sessionId"):
    return data.dapApi
  sessionDapApi(data, raw["sessionId"].to(int))

proc deliverDapEvent*(data: Data; raw: JsObject) =
  ## Deliver one DAP event frame to the subscribers of the session it was
  ## tagged for (`dapApiForFrame`).
  ##
  ## This is the whole of `ui_js.onDapReceiveEvent`, kept here so a test can
  ## drive it without booting the renderer's entry module.
  ##
  ## An event is never handed to the tab on screen in place of the tab it
  ## belongs to: a later tab's `ct/launch-failed` delivered to the first tab
  ## would end the wrong tab's busy state, and its other events would draw one
  ## replay's data into another's panes. An event for a tab that has been
  ## closed is dropped.
  if raw.isNil:
    return
  let event = raw["event"].to(cstring)
  let dapApi = dapApiForFrame(data, raw)
  if dapApi.isNil:
    console.log(cstring"dap: dropping event for a closed session: ", event,
      raw["sessionId"])
    return
  try:
    receiveEvent(dapApi, event, raw["body"])
  except ValueError:
    console.log(cstring"dap: ignoring event for unmapped event type: ", event)
