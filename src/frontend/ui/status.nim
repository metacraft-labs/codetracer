import
  std/[sequtils, strutils],
  ../communication,
  ../../common/ct_event,
  ui_imports, auto_hide

# The build identity this renderer is showing. Unconditional, not under
# `when defined(js)`: the accessors answer "" on every backend that never set
# one, which is the desktop's correct answer and keeps `statusBaseModel`
# backend-neutral.
from ../viewmodel/platform/displayed_build_identity import
  displayedBuildLabel, displayedBuildTitle

when defined(js):
  import isonim/web/web_renderer
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_status_view import
    StatusBaseModel, StatusNotificationActionRecord,
    StatusNotificationRecord, StatusShellCallbacks, StatusShellModel,
    renderStatusInto

const NOTIFICATION_LIMIT = 3

method onCompleteMove*(self: StatusComponent, response: MoveState) {.async.} =
  self.stopSignal = response.stopSignal
  self.location = response.location
  self.state.stableBusy = false
  self.completeMoveId += 1
  self.redraw()

proc deactivateNotification*(self: StatusComponent, notification: Notification) =
  notification.active = false
  notification.hasTimeout = false
  windowClearTimeout(notification.timeoutId)

  self.redraw()

proc canAutoDismiss(notification: Notification): bool =
  notification.active and not notification.isOperationStatus and notification.actions.len == 0

proc clearNotificationTimer(notification: Notification) =
  if not notification.hasTimeout:
    return

  notification.hasTimeout = false
  windowClearTimeout(notification.timeoutId)

proc notificationKindClass(notificationKind: NotificationKind): string =
  (($notificationKind)["Notification".len .. ^1]).toLowerAscii()

proc notificationVariantClass(notification: Notification, dismiss: bool): string =
  ## Keep the three notification variants tied to their current UI context:
  ## dismissible toast stack -> primary, notification history -> secondary,
  ## operation-status/debug line -> tertiary.
  if notification.isOperationStatus:
    "tertiary"
  elif dismiss:
    "primary"
  else:
    "secondary"

proc setNotificationTimer(self: StatusComponent, notification: Notification) =
  if self.activeNotificationsHovered or not canAutoDismiss(notification) or notification.hasTimeout:
    return

  notification.timeoutId = windowSetTimeout(proc =
    self.deactivateNotification(notification), self.activeNotificationDuration)
  notification.hasTimeout = true

proc pauseActiveNotificationTimers(self: StatusComponent) =
  if self.activeNotificationsHovered:
    return

  self.activeNotificationsHovered = true
  for notification in self.notifications:
    if canAutoDismiss(notification):
      clearNotificationTimer(notification)

proc resumeActiveNotificationTimers(self: StatusComponent) =
  if not self.activeNotificationsHovered:
    return

  self.activeNotificationsHovered = false
  for notification in self.notifications:
    if canAutoDismiss(notification):
      self.setNotificationTimer(notification)

proc sendBugReport(self: StatusComponent; title, description: string) =
  self.data.ipc.send "CODETRACER::send-bug-report-and-logs",
    BugReportArg(
      title: cstring title,
      description: cstring description
    )
  self.showBugReport = false

  self.redraw()

proc onStatusUpdate*(self: StatusComponent, update: StatusState) =
  self.state = update
  self.redraw()

var notificationsDelivered* = 0
  ## How many notifications this page load has handed to a status bar.
  ##
  ## A COUNTER, NOT A FLAG, and that is the whole point of it. "Was the notice
  ## shown?" is answerable by a boolean, and a boolean is exactly what cannot
  ## tell a notice that was raised once from the same notice raised three
  ## times — which is what a user reported seeing on the live site. A flag read
  ## early is also stale-but-plausible, whereas a counter that has not advanced
  ## is unambiguous.
  ##
  ## It counts DELIVERIES rather than rendered nodes, so it separates the two
  ## explanations for N copies on screen: an emitter that fired N times moves
  ## this by N, while one delivery drawn N times by a render fault does not
  ## move it at all. `ci/test/noir_edit_persists_probe.mjs` reads it either
  ## side of a page load and `ci/test/noir-edit-persists.sh` asserts the delta.
  ##
  ## Module-level rather than a field, because the question is about the page
  ## and not about one component: a second status component would keep its own
  ## field at 1 each and hide precisely the duplication being measured.

proc onNotification*(self: StatusComponent, notification: Notification) =
  inc notificationsDelivered

  if self.notifications.len == self.maxNotificationsCount:
    self.notifications.delete(0)

  self.notifications.add(notification)
  self.redraw()

when defined(js):
  proc displayLocation(self: StatusComponent): types.Location =
    ## When ViewTargetSource is active for Nim traces, show the C location so
    ## the status bar reflects the displayed C file, not the Nim source.
    result = self.location
    if not self.data.trace.isNil and self.data.trace.lang == LangNim and
       not self.data.services.editor.active.isNil and
       self.data.ui.editors.hasKey(self.data.services.editor.active) and
       not self.data.ui.editors[self.data.services.editor.active].isNil and
       self.data.ui.editors[self.data.services.editor.active].editorView == ViewTargetSource:
      let cLoc = self.data.services.debugger.cLocation
      if not cLoc.path.isNil and cLoc.path.len > 0:
        result = cLoc

  proc statusNotificationRecord(
      self: StatusComponent;
      notification: Notification;
      index: int;
      dismiss: bool): StatusNotificationRecord =
    var actions: seq[StatusNotificationActionRecord] = @[]
    for action in notification.actions:
      case action.kind:
        of ButtonAction:
          actions.add(StatusNotificationActionRecord(label: $action.name))
    StatusNotificationRecord(
      index: index,
      kindClass: notificationKindClass(notification.kind),
      variantClass: notificationVariantClass(notification, dismiss),
      text: $notification.text,
      dismissible: dismiss,
      actions: actions)

  proc statusBaseModel(self: StatusComponent): StatusBaseModel =
    let activeKey = self.data.services.editor.active
    let editor =
      if not activeKey.isNil and self.data.ui.editors.hasKey(activeKey):
        self.data.ui.editors[activeKey]
      else:
        nil
    let lang = if not editor.isNil: $toName(editor.lang) else: "_"
    let encoding = if not editor.isNil: $editor.encoding else: "_"

    let processClass =
      if self.state.stableBusy:
        "busy-status"
      else:
        "ready-status"
    let processText =
      if self.state.stableBusy:
        "stable: " & $self.state.currentOperation
      else:
        "stable: ready"

    var disconnectedTitle = ""
    if not self.data.connection.connected:
      disconnectedTitle =
        if self.data.connection.detail.len > 0:
          $self.data.connection.detail
        else:
          $connectionLossMessage(self.data.connection.reason)

    var locationText = ""
    var locationTitle = ""
    let loc = self.displayLocation()
    if not loc.path.isNil:
      locationText = fmt"{loc.path}:{loc.line}#{loc.rrTicks}"
      locationTitle = locationText

    StatusBaseModel(
      language: lang,
      encoding: encoding,
      processClass: processClass,
      processText: processText,
      showTestMovement: data.startOptions.inTest,
      testMovementText: $self.completeMoveId,
      showDisconnected: not self.data.connection.connected,
      disconnectedText: "Disconnected",
      disconnectedTitle: disconnectedTitle,
      showFinished: self.state.finished,
      locationText: locationText,
      locationTitle: locationTitle,
      copyTooltipActive: self.copyMessageActive,
      # WHAT THIS PAGE WAS BUILT FROM. Both are "" on the desktop and on any
      # web build whose entry document carries no `commit`, and the view then
      # renders no element — see `StatusBaseModel.buildLabel`. The value is
      # pushed here once by `ui_js.nim`'s web arm, which is the only code that
      # reads the deployment descriptor.
      buildLabel: displayedBuildLabel(),
      buildTitle: displayedBuildTitle())

  proc statusShellModel(self: StatusComponent): StatusShellModel =
    var activeNotifications: seq[StatusNotificationRecord] = @[]
    for index, notification in self.notifications:
      if notification.active and not notification.isOperationStatus and
          activeNotifications.len < NOTIFICATION_LIMIT:
        self.setNotificationTimer(notification)
        activeNotifications.add(
          self.statusNotificationRecord(notification, index, dismiss = true))

    var hasOperationNotification = false
    var operationNotification = StatusNotificationRecord()
    if self.notifications.len > 0 and self.notifications[^1].isOperationStatus and
        self.notifications[^1].active:
      hasOperationNotification = true
      operationNotification = self.statusNotificationRecord(
        self.notifications[^1],
        self.notifications.high,
        dismiss = false)

    var history: seq[StatusNotificationRecord] = @[]
    if self.showNotifications:
      for notificationId in countdown(self.notifications.high, 0):
        history.add(self.statusNotificationRecord(
          self.notifications[notificationId],
          notificationId,
          dismiss = false))

    StatusShellModel(
      activeNotifications: activeNotifications,
      hasOperationNotification: hasOperationNotification,
      operationNotification: operationNotification,
      base: self.statusBaseModel(),
      showNotifications: self.showNotifications,
      notificationHistory: history,
      showBugReport: self.showBugReport)

  proc statusShellCallbacks(self: StatusComponent): StatusShellCallbacks =
    StatusShellCallbacks(
      onPauseActiveNotifications: proc() = self.pauseActiveNotificationTimers(),
      onResumeActiveNotifications: proc() = self.resumeActiveNotificationTimers(),
      onDismissNotification: proc(notificationIndex: int) =
        if notificationIndex >= 0 and notificationIndex < self.notifications.len:
          self.deactivateNotification(self.notifications[notificationIndex]),
      onNotificationAction: proc(notificationIndex: int; actionIndex: int) =
        if notificationIndex >= 0 and notificationIndex < self.notifications.len:
          let notification = self.notifications[notificationIndex]
          if actionIndex >= 0 and actionIndex < notification.actions.len:
            notification.actions[actionIndex].handler()
            self.deactivateNotification(notification),
      onCopyLocation: proc() =
        let loc = self.displayLocation()
        if not loc.path.isNil:
          clipboardCopy(loc.path)
          self.copyMessageActive = true
          self.redraw()
          discard setTimeout(proc() =
            self.copyMessageActive = false
            self.redraw(),
            2000),
      onSendBugReport: proc(title: string; description: string) =
        self.sendBugReport(title, description))

  # ---------------------------------------------------------------------
  # Render bookkeeping
  #
  # A single trace open asks the status bar to redraw 60+ times. The
  # sources are all legitimate on their own and there is no one place to
  # fix them:
  #
  #   * `CtCompleteMove` — one per debugger step, plus the burst the
  #     replay backend emits while it settles on the entry location;
  #   * `InternalStatusUpdate` — one per `newOperationHandler` call in
  #     `middleware.nim`, i.e. one per queued operation;
  #   * `ui_js.nim::refreshStatusFromDebugger` — a deliberate 10x/500ms
  #     poll that re-pushes the debugger's last known location into the
  #     status component during startup;
  #   * `layout.nim`'s `autoHideState.onChanged` — every pin/unpin/dock;
  #   * notification arrival, dismissal and auto-dismiss timers.
  #
  # So the redraws are coalesced here instead: callers keep signalling
  # freely, and at most one render pass runs per task turn. The counters
  # are read by
  # `src/tests/gui/tests/status-bar/status-bar-render-stability.spec.ts`.
  # ---------------------------------------------------------------------
  var statusRenderRequests = 0
  var statusRenderPasses = 0
  var statusShellRebuilds = 0
  var statusRenderScheduled = false

  proc renderStatusNow(self: StatusComponent) =
    ## Perform one coalesced render pass. Never call this directly from
    ## event handlers — use `requestStatusRender`.
    let container = dom_api.getElementById(dom_api.document, cstring"status")
    if dom_api.isNodeNil(dom_api.Node(container)):
      cerror "status: #status container missing during render"
      return

    try:
      inc statusRenderPasses
      let model = self.statusShellModel()
      let r = WebRenderer()
      let rebuilt = renderStatusInto(
        r, container, model, self.statusShellCallbacks())
      if rebuilt:
        inc statusShellRebuilds
        # The collapsed icon zone and the bottom strip are hosts *inside*
        # the shell, so they only need re-mounting when the shell itself
        # was re-created. While the shell is only being patched their
        # contents are owned by `auto_hide.nim` / `layout.nim`, which
        # re-render them directly whenever the auto-hide state changes.
        # Deferring by a task turn keeps the previous ordering guarantee:
        # the hosts exist before anything mounts into them.
        discard windowSetTimeout(proc() =
          requestCollapsedIconZoneRender(cstring"auto-hide-collapsed-icon-zone")
          requestAutoHideBottomStripRender(cstring"auto-hide-bottom-strip")
        , 0)
    except CatchableError as e:
      cerror "status: render failed: " & e.msg

  proc requestStatusRender*(self: StatusComponent) =
    ## Ask for the shared status bar to be refreshed.
    ##
    ## Coalescing: repeated requests inside one task turn collapse into a
    ## single render pass on the next turn. Every reader of the status bar
    ## in the test suite polls (`expect.poll`, `toHaveText`, `StatusBar`'s
    ## own retry loop), so a one-turn delay is not observable, while the
    ## burst of identical renders it removes is.
    inc statusRenderRequests
    if statusRenderScheduled:
      return
    statusRenderScheduled = true
    discard windowSetTimeout(proc() =
      statusRenderScheduled = false
      self.renderStatusNow()
    , 0)

  proc statusRenderStats*(): JsObject =
    ## Render bookkeeping for the GUI stability spec (see above).
    js{
      requests: statusRenderRequests,
      passes: statusRenderPasses,
      rebuilds: statusShellRebuilds,
      # Not a render count — see `notificationsDelivered`. It rides on this
      # hook because a second `window.__ct*` global for one integer would be a
      # second thing for a probe to discover and keep in step.
      delivered: notificationsDelivered
    }

  {.emit: """
    window.__ctStatusRenderStats = function() {
      return `statusRenderStats`();
    };
  """.}

  method redraw*(self: StatusComponent) =
    self.requestStatusRender()
else:
  proc requestStatusRender*(self: StatusComponent) =
    discard

method register*(self: StatusComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(InternalStatusUpdate, proc(kind: CtEventKind, response: StatusState, sub: Subscriber) =
    self.onStatusUpdate(response)
  )
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
  )
  api.subscribe(CtNotification, proc(kind: CtEventKind, response: Notification, sub: Subscriber) =
    self.onNotification(response)
  )
