import
  std/[sequtils, strutils],
  ../communication,
  ../../common/ct_event,
  ui_imports, flow, shell, build, auto_hide

from editor import clearViewZones

const NOTIFICATION_LIMIT = 3

proc locationView(self: StatusComponent): VNode =
  buildHtml(span(id = "location-status")):
    if self.state.finished:
      span(class = "finished"):
        text "FINISHED"
    else:
      # When ViewTargetSource is active for Nim traces, show the C location
      # so the status bar reflects the displayed C file, not the Nim source.
      var displayLocation = self.location
      if not self.data.trace.isNil and self.data.trace.lang == LangNim and
         not self.data.services.editor.active.isNil and
         self.data.ui.editors.hasKey(self.data.services.editor.active) and
         not self.data.ui.editors[self.data.services.editor.active].isNil and
         self.data.ui.editors[self.data.services.editor.active].editorView == ViewTargetSource:
        let cLoc = self.data.services.debugger.cLocation
        if not cLoc.path.isNil and cLoc.path.len > 0:
          displayLocation = cLoc

      if not displayLocation.path.isNil:
        let path = displayLocation.path
        let line = displayLocation.line
        let rrTicks = displayLocation.rrTicks
        let fullPathWithRRTicks = fmt"{path}:{line}#{rrTicks}"
        let activeClass = if self.copyMessageActive: "active" else: ""

        span(
          class = "location-path status-inline",
          `data-toggle` = "tooltip",
          `data-placement` = "bottom",
          title = fullPathWithRRTicks
        ):
          text fullPathWithRRTicks
        button(
          id = "copy-path-image",
          class = "ct-button-image-md-secondary ct-button-no-border",
          onclick = proc =
            clipboardCopy(path)
            self.copyMessageActive = true
            self.redraw()
            discard setTimeout(proc() =
              self.copyMessageActive = false
              self.redraw(),
              2000
            )
        )
        tdiv(class = fmt"custom-tooltip {activeClass}"):
          text "Path copied to clipboard"

proc disconnectedBadge(self: StatusComponent): VNode =
  if self.data.connection.connected:
    return nil

  let detail = if self.data.connection.detail.len > 0:
      self.data.connection.detail
    else:
      connectionLossMessage(self.data.connection.reason)

  buildHtml(
    span(
      class = "status-inline disconnected-status",
      role = "status",
      `aria-live` = "polite",
      title = detail
    )
  ):
    text "Disconnected"

method onCompleteMove*(self: StatusComponent, response: MoveState) {.async.} =
  self.stopSignal = response.stopSignal
  self.location = response.location
  self.state.stableBusy = false
  self.completeMoveId += 1

proc counterHandler(self: StatusComponent): void {.async.} =
  const SLOW_MESSAGE_TIME = 2.0 # seconds
  const MAXIMUM_TIME_ALLOWED = 180 # seconds
  const WAIT_TIME = 25 # milliseconds

  if self.service.timer == nil:
    # Nothing currently running, init anew.
    self.service.timer = initTimer()
    self.service.timer.startTimer(self.state.operationCount)

    while self.state.stableBusy and self.state.operationCount == self.service.timer.currentOpID:
      document.getElementById("timer").innerHTML = self.service.timer.formatted()

      # Handle slower processes.
      let elapsed = self.service.timer.elapsed()
      self.service.lastRRTickTime = self.service.timer.elapsed()

      if elapsed > SLOW_MESSAGE_TIME:
        try:
          document.getElementById("slower-message").innerHTML = "Loading…"
        except:
          # it might not exist yet
          discard

      # We do not allow the loop to run for longer than MTA.
      if elapsed < MAXIMUM_TIME_ALLOWED:
        await wait(WAIT_TIME)
      else:
        try:
          document.getElementById("slower-message").innerHTML = "ERROR: Operation took too long!"
          break
        except:
          discard

    # Clean up.
    self.service.timer.stopTimer()
    self.service.timer = nil
    try:
      document.getElementById("slower-message").innerHTML = ""
    except:
      discard

  else:
    # There's a loop already running.
    let same: bool = self.service.timer.compareMetadata(self.state.operationCount)
    if not same:
      # But its timer is measuring another process and the process
      # is now changed.  In that case we simply restart it and make
      # it track the new process.
      self.service.timer.startTimer(self.state.operationCount)

proc upcountTimerBase(self: StatusComponent): VNode =
  result = buildHtml(
    span(class = "status-timer")
  ):
    span(id = "timer"): text "0.000s"
    span(id = "slower-message"): text ""
    span(id = "timer-eta"): text "ETA=0.000s"
  counterHandler(self)

proc processStatusView(self: StatusComponent, busy: bool, currentOperation: cstring, process: string): VNode =
  let processClass =
    if busy:
      "busy-status"
    else:
      "ready-status"
  buildHtml(
    span(
      id = &"{process}-status",
      class=processClass)
    ):
      if busy:
        text &"{process}: {currentOperation}"
      else:
        text &"{process}: ready"

proc editorWhitespaceOption(self: StatusComponent, editor: EditorViewComponent): VNode =
  if not editor.isNil:
    buildHtml(
      tdiv(id = "file-info-status-editor-whitespace")
    ):
      tdiv(class = "whitespace-set"):
        tdiv(
          class = "whitespace-up whitespace-change",
          onclick = proc =
            editor.increaseWhitespaceWidth()
            self.redraw()
        ):
          fa "arrow-up"
        tdiv(
          class = "whitespace-down whitespace-change",
          onclick = proc =
            editor.decreaseWhitespaceWidth()
            self.redraw()
        ):
          fa "arrow-down"
      if editor.whitespace.character == WhitespaceSpaces:
        span(class = "whitespace-label whitespace-spaces"):
          text &"Spaces: {editor.whitespace.width}"
      else:
        span(class = "whitespace-label whitespace-tabs"):
          text &"Tab width: {editor.whitespace.width}"
  else:
    buildHtml(tdiv(id = "file-info-status-editor-whitespace"))

proc operationView(self: StatusComponent): VNode =
  buildHtml(span(id = "operation-status")):
    processStatusView(self, self.state.stableBusy, self.state.currentOperation, "stable")

proc fileInfoView(self: StatusComponent): VNode =
  let activeKey = self.data.services.editor.active
  let editor =
    if not activeKey.isNil and self.data.ui.editors.hasKey(activeKey):
      self.data.ui.editors[activeKey]
    else:
      nil
  let lang = if not editor.isNil: toName(editor.lang) else: "_"
  let encoding = if not editor.isNil: editor.encoding else: cstring"_"

  buildHtml(
    tdiv(id = "file-info-status")
  ):
    span(class = "file-info-status-language", class = "status-inline"):
      text lang
    separateBar()
    span(class = "file-info-status-encoding", class = "status-inline"):
      text encoding
    separateBar()
    operationView(self)

proc signalView(self: StatusComponent): VNode =
  buildHtml(span(id="signal-status")):
    text $self.stopSignal

proc buildStatusView(self: StatusComponent): VNode =
  let klass =
    if self.build.build.running:
      "build-running"
    else:
      ""
  buildHtml(
    span(id = "build-status", class = klass)
  ):
    if self.build.build.running:
      span(id = "build-command"):
        text "running " & self.build.build.command & ":"
      span(id = "build-output"):
        if self.build.build.output.len > 0:
          text self.build.build.output[^1][0]
        else:
          text ""
    else:
      text ""

proc bugReportButtonStatusView(self: StatusComponent): VNode =
  var buttonClass = cstring("status-button")

  if self.showBugReport:
    buttonClass = buttonClass & cstring("-clicked")

  buildHtml(
    span(
      id = "bug-report-status-button",
      class = buttonClass,
      onclick = proc =
        self.showBugReport = not self.showBugReport
        self.redraw()
    )
  ):
    text "Report a Bug"

proc newNotificationsCountView(self: StatusComponent): VNode =
  let newNotificationsCount = self.notifications.filterIt(not it.seen and it.kind != NotificationKind.NotificationSuccess).len

  buildHtml(tdiv(class = "new-notifications-counter")):
    text $newNotificationsCount

proc setAllNotificationsToSeen(self: StatusComponent) =
  for notification in self.notifications.filterIt(not it.seen):
    notification.seen = true

proc notificationsButtonStatusView(self: StatusComponent): VNode =
  var buttonClass = cstring("status-button")
  if self.showNotifications:
    buttonClass = buttonClass & cstring("-clicked")

  buildHtml(
    span(
      id = "notifications-status-button",
      class = buttonClass,
      onclick = proc =
        self.showNotifications = not self.showNotifications
        setAllNotificationsToSeen(self)
        self.redraw()
    )
  ):
    if self.notifications.filterIt(not it.seen and it.kind != NotificationKind.NotificationSuccess).len > 0:
      newNotificationsCountView(self)
    text "Notifications"

proc buildOutputButtonStatusView(self: StatusComponent): VNode =
  ## Open the Build GL panel when clicked instead of expanding inline.
  buildHtml(
    tdiv(
      id = "build-output-status-button",
      class = "status-button",
      onclick = proc =
        self.build.focusBuild()
    )
  ):
    text "Build Output"

proc toggleSearchResultsView(self: StatusComponent): VNode =

  buildHtml(tdiv(class = "toggle-search-results")):
    if self.searchResults.active:
      tdiv(
        id = "toggle-search-results-active",
        onclick = proc =
          self.searchResults.active = not self.searchResults.active
          self.redraw()
      ):
        text "minimize search results"
    else:
      tdiv(
        id = "toggle-search-results-non-active",
        onclick = proc =
          self.searchResults.active = true
          self.redraw()
      ):
        text "search results"

proc versionControlStatusView(self: StatusComponent): VNode =
  buildHtml(span(id = "version-control-status")):
    span(class = "status-branch status-inline"):
      text self.versionControlBranch

proc flowTypesListView(self: StatusComponent, flowType: FlowUI): VNode =
  buildHtml(
    tdiv(
      class = "status-flow-type",
      onclick = proc =
        let editorPath = self.data.services.editor.active
        let editor = self.data.ui.editors[editorPath]
        let flow = editor.flow
        flow.switchFlowType(flowType)
    )
  ):
    text($flowType)

proc flowButtonsView(self: StatusComponent): VNode =
  let editorPath = self.data.services.editor.active
  let editor = self.data.ui.editors[editorPath]

  if not editor.isNil:
    let flow = editor.flow
    var buttonText: cstring

    if not flow.isNil:
      let flowType = $(flow.data.config.flow.realFlowUI)
      buttonText = flowType
    else:
      buttonText = "Loading..."

    var flowTypesListClass =
      if self.flowMenuIsOpen:
        "status-flow-types-list-active"
      else:
        "status-flow-types-list"

    buildHtml(
      tdiv(
        class = "status-flow-button status-button",
        onclick = proc =
          self.flowMenuIsOpen = not self.flowMenuIsOpen
          self.redraw()
      )
    ):
      text(buttonText)
      tdiv(class = flowTypesListClass):
        for flowType in FlowUI:
          flowTypesListView(self, flowType)
  else:
    buildHtml(span(class = "status-flow-button status-button")):
      text "Loading..."

proc createShellContainer(self: StatusComponent): VNode =
  buildHtml(
    span(
      class = "status-shell-button status-button",
      onclick = proc (e: Event, et: VNode) =
        e.stopPropagation()
        self.data.openShellTab()
    )
  ):
    text "Shell"

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

proc buttonActionView(self: StatusComponent, notification: Notification, buttonAction: NotificationAction): VNode =

  let notificationKind = notificationKindClass(notification.kind)

  buildHtml(
    tdiv(class = "notification-action-wrapper")
  ):
    tdiv(class = &"notification-action-button action-notification-button {notificationKind.toLowerCase()}",
         onclick = proc =
          buttonAction.handler()
          self.deactivateNotification(notification)):
      text &"{buttonAction.name}"

proc notificationActionView(self: StatusComponent, notification: Notification, action: NotificationAction): VNode =
  case action.kind:
    of ButtonAction:
      buttonActionView(self, notification, action)

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

proc notificationView(
  self: StatusComponent,
  notification: Notification,
  dismiss: bool = false): VNode =
  let notificationKind = notificationKindClass(notification.kind)
  let notificationVariant = notificationVariantClass(notification, dismiss)
  self.setNotificationTimer(notification)

  buildHtml(
    tdiv(class = &"status-notification ct-notification ct-notification-{notificationKind}-{notificationVariant}")
  ):
    tdiv(class = "notification-wrapper"):
      tdiv(class = &"notification-icon {notificationKind}")
      tdiv(class = "notification-message"):
        text notification.text

      if dismiss:
        tdiv(
          class = &"notification-button dismiss-notification-button {notificationKind}",
          onclick = proc = self.deactivateNotification(notification)
        )
    for action in notification.actions:
      notificationActionView(self, notification, action)

proc activeNotificationView(self: StatusComponent, notification: Notification): VNode =
  notificationView(self, notification, true)

proc activeNotificationsView(self: StatusComponent): VNode =
  var count = 0
  buildHtml(
    tdiv(
      id = "active-notifications",
      onmouseenter = proc(ev: Event, n: VNode) =
        self.pauseActiveNotificationTimers(),
      onmouseleave = proc(ev: Event, n: VNode) =
        self.resumeActiveNotificationTimers()
    )
  ):
    for notification in self.notifications:
      if notification.active and not notification.isOperationStatus and count < NOTIFICATION_LIMIT:
        activeNotificationView(self, notification)
        count += 1

proc sendBugReport(self: StatusComponent) =
  let title = kdom.document.getElementById("bug-report-title")
  let description = kdom.document.getElementById("bug-report-description")
  self.data.ipc.send "CODETRACER::send-bug-report-and-logs",
    BugReportArg(
      title: title.value,
      description: description.value
    )
  # Reset bug report window
  title.value = ""
  description.value = ""
  self.showBugReport = false

  self.redraw()

proc toggleInlineValues(self: StatusComponent): VNode =
  buildHtml(
    tdiv(class = "toggle-switch")
  ):
    input(name = "Toggle inline values",
      `type` = "checkbox",
      class = "checkbox",
      checked = toChecked(self.data.services.debugger.showInlineValues),
      onchange = proc() =
        self.data.services.debugger.showInlineValues = not self.data.services.debugger.showInlineValues
        clearViewZones(self.data.ui.editors[self.location.highLevelPath]),
      value = "Toggle inline values")
    span(class = "checkbox-text"):
      text "Enable inline values"

proc toggleFlow(self: StatusComponent): VNode =
  buildHtml(tdiv(class = "toggle-switch")):
    input(
      name = "Enable flow",
      `type` = "checkbox",
      class = "checkbox",
      checked = toChecked(self.data.services.flow.enabledFlow),
      onchange = proc() =
        self.data.services.flow.enabledFlow = not self.data.services.flow.enabledFlow
        let editor = self.data.ui.editors[self.data.services.editor.active]
        if not self.data.services.flow.enabledFlow:
          if not editor.isNil:
            if not editor.flow.isNil:
              editor.flow.clear()
              editor.flow = nil
        else:
          if not editor.isNil:
            editor.flow = nil
            let taskId = genTaskId(LoadFlow)
            clog "start load-flow", taskId
            discard self.data.services.flow.loadFlow(taskId)
        self.redraw(),
      value = "Enable flow"
    )
    span(class="checkbox-text"):
      text "Enable flow"

proc onStatusUpdate*(self: StatusComponent, update: StatusState) =
  self.state = update
  self.redraw()

proc onNotification*(self: StatusComponent, notification: Notification) =
  if self.notifications.len == self.maxNotificationsCount:
    self.notifications.delete(0)

  self.notifications.add(notification)
  self.redraw()

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


proc renderStatus*(self: StatusComponent): VNode =
  ## Render the shared status bar chrome.
  ##
  ## The status bar still returns a Karax VNode tree for the shared ``#status``
  ## renderer, but this is intentionally a regular proc rather than a generic
  ## Component.render override.
  discard windowSetTimeout(proc() =
    requestCollapsedIconZoneRender(cstring"auto-hide-collapsed-icon-zone")
    requestBottomAutoHideTabsRender(cstring"auto-hide-bottom-tabs")
  , 0)

  result = buildHtml(tdiv):
    activeNotificationsView(self)
    if self.notifications != @[] and self.notifications[^1].isOperationStatus:
      if self.notifications[^1].active:
        tdiv(class="debug-notification"):
          notificationView(self, self.notifications[^1])
    tdiv(id = "status-base"):
      # Icon zone FIRST so it sits at the leftmost position, physically
      # connecting with the collapsed side strip line above it.
      renderCollapsedIconZoneHost()
      fileInfoView(self)
      renderBottomAutoHideTabsHost()
      # TODO: Find another place for these
      # toggleInlineValues(self)
      # toggleFlow(self)
      # TODO: Find another place for these
      # signalView(self)
      # span(class="status-buttons"):
      #   bugReportButtonStatusView(self)
      #   notificationsButtonStatusView(self)
      #   # buildOutputButtonStatusView(self)
      #   span(class="status-flow-buttons"):
      #     flowButtonsView(self)
      #   # createShellContainer(self)
      if data.startOptions.inTest:
        span(class = "test-movement"):
          text $self.completeMoveId
      span(class = "status-right"):
        disconnectedBadge(self)
        locationView(self)
    if self.showNotifications:
      tdiv(id = "notifications-container"):
        tdiv(class = "status-notification-header"):
          text "NOTIFICATIONS:"
        for notificationId in countdown(self.notifications.high, 0):
          notificationView(self, self.notifications[notificationId])
    if self.showBugReport:
      tdiv(id = "bug-report-container"):
        tdiv(class = "bug-report-header"):
          text "BUG REPORT"
        tdiv(class = "status-bug-report-form"):
          tdiv(clas = "status-bug-report-textarea"):
            tdiv(class = "bug-report-text"):
              text "Title (Optional)"
            tdiv():
              input(
                id = "bug-report-title",
                `type` = "text",
                onkeydown = proc(ev: KeyboardEvent, v: VNode) =
                  if ev.ctrlKey and ev.keyCode == ENTER_KEY_CODE:
                    self.sendBugReport()
              )
            tdiv(class = "bug-report-text"):
              text "Description (Optional)"
            tdiv():
              textarea(
                id = "bug-report-description",
                onkeydown = proc(ev: KeyboardEvent, v: VNode) =
                  if ev.ctrlKey and ev.keyCode == ENTER_KEY_CODE:
                    self.sendBugReport()
              )
          tdiv(class = "bug-report-button-container"):
            text "logs will be sent automatically\n(internal release: can include sensitive info!)"
            button(
              class = "bug-report-button",
              onclick = proc = self.sendBugReport(),
            ): text "Send logs and report"
