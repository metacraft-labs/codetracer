import
  std/[sequtils, strutils],
  ../communication,
  ../../common/ct_event,
  ui_imports, auto_hide

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

proc onNotification*(self: StatusComponent, notification: Notification) =
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
      copyTooltipActive: self.copyMessageActive)

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

  proc requestStatusRender*(self: StatusComponent) =
    ## Refresh the shared status bar through IsoNim direct DOM.
    let container = dom_api.getElementById(dom_api.document, cstring"status")
    if dom_api.isNodeNil(dom_api.Node(container)):
      return

    let r = WebRenderer()
    renderStatusInto(r, container, self.statusShellModel(), self.statusShellCallbacks())
    discard windowSetTimeout(proc() =
      requestCollapsedIconZoneRender(cstring"auto-hide-collapsed-icon-zone")
      requestBottomAutoHideTabsRender(cstring"auto-hide-bottom-tabs")
    , 0)

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
