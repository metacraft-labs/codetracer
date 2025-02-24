import ui_imports, flow, shell, sequtils

const NOTIFICATION_LIMIT = 5

proc locationView(self: StatusComponent): VNode =
  buildHtml(span(id = "location-status")):
    if self.service.finished:
      span(class = "finished"):
        text "FINISHED"
    else:
      if not self.service.location.path.isNil:
        let path = self.service.location.path
        let line = self.service.location.line
        let rrTicks = self.service.location.rrTicks
        let fullPathWithRRTicks = fmt"{path}:{line}#{rrTicks}"
        let activeClass = if self.copyMessageActive: "active" else: ""

        span(
          class = "location-path status-inline",
          `data-toggle` = "tooltip",
          `data-placement` = "bottom",
          title = fullPathWithRRTicks
        ):
          text fullPathWithRRTicks
        tdiv(
          class = "copy-file-path",
          onclick = proc =
            clipboardCopy(path)
            self.copyMessageActive = true
            self.data.redraw()
            discard setTimeout(proc() =
              self.copyMessageActive = false
              self.data.redraw(),
              2000
            )
        )
        tdiv(class = fmt"custom-tooltip {activeClass}"):
          text "Path copied to clipboard"

proc counterHandler(self: StatusComponent): void {.async.} =
  const SLOW_MESSAGE_TIME = 2.0 # seconds
  const MAXIMUM_TIME_ALLOWED = 180 # seconds
  const WAIT_TIME = 25 # milliseconds

  if self.service.timer == nil:
    # Nothing currently running, init anew.
    self.service.timer = initTimer()
    self.service.timer.startTimer(self.service.operationCount)

    while self.service.stableBusy and self.service.operationCount == self.service.timer.currentOpID:
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
    let same: bool = self.service.timer.compareMetadata(self.service.operationCount)
    if not same:
      # But its timer is measuring another process and the process
      # is now changed.  In that case we simply restart it and make
      # it track the new process.
      self.service.timer.startTimer(self.service.operationCount)

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
            self.data.redraw()
        ):
          fa "arrow-up"
        tdiv(
          class = "whitespace-down whitespace-change",
          onclick = proc =
            editor.decreaseWhitespaceWidth()
            self.data.redraw()
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
    processStatusView(self, self.service.stableBusy, self.service.currentOperation, "stable")

proc fileInfoView(self: StatusComponent): VNode =
  let editor = self.data.ui.editors[self.data.services.editor.active]
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
    text $self.service.stopSignal

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
        self.data.redraw()
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
        self.data.redraw()
    )
  ):
    if self.notifications.filterIt(not it.seen and it.kind != NotificationKind.NotificationSuccess).len > 0:
      newNotificationsCountView(self)
    text "Notifications"

proc buildOutputButtonStatusView(self: StatusComponent): VNode =
  if not self.build.expanded:
    buildHtml(
      tdiv(
        id = "build-output-status-button",
        class = "status-button",
        onclick = proc =
          self.build.expanded = true
          self.data.redraw()
      )
    ):
      text "Build Output"
  else:
    buildHtml(
      tdiv(
        id = "build-output-status-minimize",
        class = "status-button status-minimize-button",
        onclick = proc =
          self.build.expanded = false
          self.data.redraw()
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
          self.data.redraw()
      ):
        text "minimize search results"
    else:
      tdiv(
        id = "toggle-search-results-non-active",
        onclick = proc =
          self.searchResults.active = true
          self.data.redraw()
      ):
        text "search results"

proc buildExpandedView(self: StatusComponent): VNode =
  self.build.render()

proc errorsExpandedView(self: StatusComponent): VNode =
  self.errors.render()

proc versionControlStatusView(self: StatusComponent): VNode =
  buildHtml(span(id = "version-control-status")):
    span(class = "status-branch status-inline"):
      text self.versionControlBranch

proc statusExpandedView(self: StatusComponent): VNode =
  result = buildHtml(tdiv(id = "status-expanded")):
    if self.build.expanded:
      buildExpandedView(self)
    if self.errors.expanded:
      errorsExpandedView(self)

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
      let flowType = $(flow.data.config.realFlowUI)
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
          self.data.redraw()
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

  self.data.redraw()

proc buttonActionView(self: StatusComponent, notification: Notification, buttonAction: NotificationAction): VNode =

  let notificationKind = convertNotificationKind(notification.kind)

  buildHtml(
    tdiv(class = &"notification-button action-notification-button {notificationKind.toLowerCase()}",
         onclick = proc =
          buttonAction.handler()
          self.deactivateNotification(notification))):
      text &"{buttonAction.name}"

proc notificationActionView(self: StatusComponent, notification: Notification, action: NotificationAction): VNode =
  case action.kind:
    of ButtonAction:
      buttonActionView(self, notification, action)


proc notificationView(
  self: StatusComponent,
  notification: Notification,
  dismiss: bool = false): VNode =
  let notificationKind = convertNotificationKind(notification.kind)

  buildHtml(
    tdiv(class = &"status-notification {notificationKind.toLowerCase()} {notification.active}")
  ):
    tdiv(class = &"notification-icon {notificationKind.toLowerCase()}")
    tdiv(class = &"notification-message-prefix {notificationKind.toLowerCase()}"):
      text &"{notificationKind}: "
    tdiv(class = "notification-message"):
      text notification.text

    for action in notification.actions:
      notificationActionView(self, notification, action)

    if dismiss:
      tdiv(class = &"notification-button dismiss-notification-button {notificationKind.toLowerCase()}",
           onclick = proc = self.deactivateNotification(notification)):
        text "Dismiss"

proc activeNotificationView(self: StatusComponent, notification: Notification): VNode =

  # TODO: Add proper bookkeeping. For now we assume:
  # actions.len != 0 <=> We require user input and we don't timeout
  if not notification.hasTimeout and notification.actions.len == 0:
    notification.timeoutId = windowSetTimeout(proc =
      self.deactivateNotification(notification), self.activeNotificationDuration)
    notification.hasTimeout = true

  notificationView(self, notification, true)

proc activeNotificationsView(self: StatusComponent): VNode =
  var count = 0
  buildHtml(tdiv(id = "active-notifications")):
    for notification in self.notifications:
      if notification.active and not notification.isOperationStatus and count <= NOTIFICATION_LIMIT:
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

  self.data.redraw()

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
        clearViewZones(self.data.ui.editors[self.service.location.highLevelPath]),
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
        self.data.redraw(),
      value = "Enable flow"
    )
    span(class="checkbox-text"):
      text "Enable flow"

method render*(self: StatusComponent): VNode =
  let statusExpanded = if self.build.expanded or self.errors.expanded: statusExpandedView(self) else: nil
  let statusClass = if self.build.expanded or self.errors.expanded: "status-with-expanded" else: ""
  var value: string

  result = buildHtml(tdiv(class=statusClass)):
    activeNotificationsView(self)
    if self.build.expanded or self.errors.expanded:
      statusExpandedView(self)
    tdiv(id = "status-base"):
      fileInfoView(self)
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
      span(class = "status-right"):
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
