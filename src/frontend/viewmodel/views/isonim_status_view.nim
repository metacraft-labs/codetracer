## IsoNim view for the global status bar shell.
##
## State derivation and legacy side effects stay in ``ui/status.nim``; this
## module owns the DOM structure for the shared ``#status`` host and exposes a
## MockRenderer/WebRenderer-compatible surface for focused structure tests.

import isonim/dsl/ui
from isonim/core/computation import createRenderEffect
import isonim/testing/mock_dom

when defined(js):
  import jsffi
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

type
  StatusNotificationActionRecord* = object
    label*: string

  StatusNotificationRecord* = object
    index*: int
    kindClass*: string
    variantClass*: string
    text*: string
    dismissible*: bool
    actions*: seq[StatusNotificationActionRecord]

  StatusBaseModel* = object
    language*: string
    encoding*: string
    processClass*: string
    processText*: string
    showTestMovement*: bool
    testMovementText*: string
    showDisconnected*: bool
    disconnectedText*: string
    disconnectedTitle*: string
    showFinished*: bool
    locationText*: string
    locationTitle*: string
    copyTooltipActive*: bool

  StatusShellModel* = object
    activeNotifications*: seq[StatusNotificationRecord]
    hasOperationNotification*: bool
    operationNotification*: StatusNotificationRecord
    base*: StatusBaseModel
    showNotifications*: bool
    notificationHistory*: seq[StatusNotificationRecord]
    showBugReport*: bool

  StatusShellCallbacks* = object
    onPauseActiveNotifications*: proc()
    onResumeActiveNotifications*: proc()
    onDismissNotification*: proc(notificationIndex: int)
    onNotificationAction*: proc(notificationIndex: int; actionIndex: int)
    onCopyLocation*: proc()
    onSendBugReport*: proc(title: string; description: string)

const
  StatusRootClass* = "status-shell"
  StatusBaseId* = "status-base"
  CollapsedIconZoneHostId* = "auto-hide-collapsed-icon-zone"
  CollapsedIconZoneClass* = "collapsed-icon-zone"
  BottomStripHostId* = "auto-hide-bottom-strip"
  BottomStripClass* = "auto-hide-bottom-strip"

proc invokePause(callbacks: StatusShellCallbacks) =
  if not callbacks.onPauseActiveNotifications.isNil:
    callbacks.onPauseActiveNotifications()

proc invokeResume(callbacks: StatusShellCallbacks) =
  if not callbacks.onResumeActiveNotifications.isNil:
    callbacks.onResumeActiveNotifications()

proc invokeDismiss(callbacks: StatusShellCallbacks; notificationIndex: int) =
  if not callbacks.onDismissNotification.isNil:
    callbacks.onDismissNotification(notificationIndex)

proc invokeAction(
    callbacks: StatusShellCallbacks;
    notificationIndex: int;
    actionIndex: int) =
  if not callbacks.onNotificationAction.isNil:
    callbacks.onNotificationAction(notificationIndex, actionIndex)

proc invokeCopyLocation(callbacks: StatusShellCallbacks) =
  if not callbacks.onCopyLocation.isNil:
    callbacks.onCopyLocation()

proc invokeSendBugReport(
    callbacks: StatusShellCallbacks;
    title: string;
    description: string) =
  if not callbacks.onSendBugReport.isNil:
    callbacks.onSendBugReport(title, description)

proc notificationClass(notification: StatusNotificationRecord): string =
  "status-notification ct-notification ct-notification-" &
    notification.kindClass & "-" & notification.variantClass

proc copyTooltipClass(active: bool): string =
  if active:
    "custom-tooltip active"
  else:
    "custom-tooltip "

template renderStatusShellImpl(
    r: untyped;
    model: StatusShellModel;
    callbacks: StatusShellCallbacks): untyped =
  ui(r):
    tdiv(id = "status", class = StatusRootClass):
      tdiv(
          id = "active-notifications",
          onmouseenter = proc() = callbacks.invokePause(),
          onmouseleave = proc() = callbacks.invokeResume()):
        for modelIndex in 0 ..< model.activeNotifications.len:
          var notification = model.activeNotifications[modelIndex]
          let notificationIndex = notification.index
          tdiv(class = notificationClass(notification)):
            tdiv(class = "notification-wrapper"):
              tdiv(class = "notification-icon " & notification.kindClass):
                discard
              tdiv(class = "notification-message"):
                text notification.text
              if notification.dismissible:
                tdiv(
                    class = "notification-button dismiss-notification-button " &
                      notification.kindClass,
                    onclick = proc() =
                      callbacks.invokeDismiss(notificationIndex)):
                  discard
            for actionIndex, action in notification.actions:
              let currentActionIndex = actionIndex
              tdiv(class = "notification-action-wrapper"):
                tdiv(
                    class = "notification-action-button action-notification-button " &
                      notification.kindClass,
                    onclick = proc() =
                      callbacks.invokeAction(notificationIndex, currentActionIndex)):
                  text action.label

      if model.hasOperationNotification:
        tdiv(class = "debug-notification"):
          var notification = model.operationNotification
          let notificationIndex = notification.index
          tdiv(class = notificationClass(notification)):
            tdiv(class = "notification-wrapper"):
              tdiv(class = "notification-icon " & notification.kindClass):
                discard
              tdiv(class = "notification-message"):
                text notification.text
              if notification.dismissible:
                tdiv(
                    class = "notification-button dismiss-notification-button " &
                      notification.kindClass,
                    onclick = proc() =
                      callbacks.invokeDismiss(notificationIndex)):
                  discard
            for actionIndex, action in notification.actions:
              let currentActionIndex = actionIndex
              tdiv(class = "notification-action-wrapper"):
                tdiv(
                    class = "notification-action-button action-notification-button " &
                      notification.kindClass,
                    onclick = proc() =
                      callbacks.invokeAction(notificationIndex, currentActionIndex)):
                  text action.label

      tdiv(id = StatusBaseId):
        tdiv(id = CollapsedIconZoneHostId, class = CollapsedIconZoneClass):
          discard
        tdiv(id = "file-info-status"):
          span(class = "file-info-status-language status-inline"):
            text model.base.language
          tdiv(class = "separate-bar"):
            discard
          span(class = "file-info-status-encoding status-inline"):
            text model.base.encoding
          tdiv(class = "separate-bar"):
            discard
          span(id = "operation-status"):
            span(id = "stable-status", class = model.base.processClass):
              text model.base.processText
        tdiv(id = BottomStripHostId, class = BottomStripClass):
          discard
        if model.base.showTestMovement:
          span(class = "test-movement"):
            text model.base.testMovementText
        span(class = "status-right"):
          if model.base.showDisconnected:
            span(
                class = "status-inline disconnected-status",
                role = "status",
                `aria-live` = "polite",
                title = model.base.disconnectedTitle):
              text model.base.disconnectedText
          span(id = "location-status"):
            if model.base.showFinished:
              span(class = "finished"):
                text "FINISHED"
            elif model.base.locationText.len > 0:
              span(
                  class = "location-path status-inline",
                  `data-toggle` = "tooltip",
                  `data-placement` = "bottom",
                  title = model.base.locationTitle):
                text model.base.locationText
              button(
                  id = "copy-path-image",
                  class = "ct-button-image-md-secondary ct-button-no-border",
                  onclick = proc() = callbacks.invokeCopyLocation()):
                discard
              tdiv(class = copyTooltipClass(model.base.copyTooltipActive)):
                text "Path copied to clipboard"

      if model.showNotifications:
        tdiv(id = "notifications-container"):
          tdiv(class = "status-notification-header"):
            text "NOTIFICATIONS:"
          for modelIndex in 0 ..< model.notificationHistory.len:
            var notification = model.notificationHistory[modelIndex]
            let notificationIndex = notification.index
            tdiv(class = notificationClass(notification)):
              tdiv(class = "notification-wrapper"):
                tdiv(class = "notification-icon " & notification.kindClass):
                  discard
                tdiv(class = "notification-message"):
                  text notification.text
                if notification.dismissible:
                  tdiv(
                      class = "notification-button dismiss-notification-button " &
                        notification.kindClass,
                      onclick = proc() =
                        callbacks.invokeDismiss(notificationIndex)):
                    discard
              for actionIndex, action in notification.actions:
                let currentActionIndex = actionIndex
                tdiv(class = "notification-action-wrapper"):
                  tdiv(
                      class = "notification-action-button action-notification-button " &
                        notification.kindClass,
                      onclick = proc() =
                        callbacks.invokeAction(notificationIndex, currentActionIndex)):
                    text action.label

      if model.showBugReport:
        tdiv(id = "bug-report-container"):
          tdiv(class = "bug-report-header"):
            text "BUG REPORT"
          tdiv(class = "status-bug-report-form"):
            tdiv(class = "status-bug-report-textarea"):
              tdiv(class = "bug-report-text"):
                text "Title (Optional)"
              tdiv():
                input(id = "bug-report-title", `type` = "text")
              tdiv(class = "bug-report-text"):
                text "Description (Optional)"
              tdiv():
                textarea(id = "bug-report-description"):
                  discard
            tdiv(class = "bug-report-button-container"):
              text "logs will be sent automatically\n(internal release: can include sensitive info!)"
              button(
                  class = "bug-report-button",
                  onclick = proc() =
                    callbacks.invokeSendBugReport("", "")):
                text "Send logs and report"

proc renderStatusShell*(
    r: MockRenderer;
    model: StatusShellModel;
    callbacks: StatusShellCallbacks = StatusShellCallbacks()): MockNode =
  renderStatusShellImpl(r, model, callbacks)

when defined(js):
  proc inputValue(node: isonim_dom.Element): cstring {.importjs: "(#.value || '')".}
  proc setInputValue(node: isonim_dom.Element; value: cstring) {.importjs: "#.value = #".}
  proc isCtrlEnter(ev: isonim_dom.Event): bool {.importjs: "(function(ev) { return !!(ev.ctrlKey && ev.keyCode === 13); })(#)".}

  proc readInputValue(id: cstring): string =
    let node = isonim_dom.getElementById(isonim_dom.document, id)
    if isonim_dom.isNodeNil(isonim_dom.Node(node)):
      return ""
    $node.inputValue()

  proc clearInputValue(id: cstring) =
    let node = isonim_dom.getElementById(isonim_dom.document, id)
    if not isonim_dom.isNodeNil(isonim_dom.Node(node)):
      node.setInputValue(cstring"")

  proc sendBugReportFromDom(callbacks: StatusShellCallbacks) =
    callbacks.invokeSendBugReport(
      readInputValue(cstring"bug-report-title"),
      readInputValue(cstring"bug-report-description"))
    clearInputValue(cstring"bug-report-title")
    clearInputValue(cstring"bug-report-description")

  proc wireBugReportShortcuts(callbacks: StatusShellCallbacks) =
    for id in [cstring"bug-report-title", cstring"bug-report-description"]:
      let node = isonim_dom.getElementById(isonim_dom.document, id)
      if isonim_dom.isNodeNil(isonim_dom.Node(node)):
        continue
      isonim_dom.addEventListener(isonim_dom.Node(node), cstring"keydown",
        proc(ev: isonim_dom.Event) =
          if ev.isCtrlEnter():
            sendBugReportFromDom(callbacks))

  proc renderStatusShell*(
      r: WebRenderer;
      model: StatusShellModel;
      callbacks: StatusShellCallbacks = StatusShellCallbacks()):
        isonim_dom.Element =
    renderStatusShellImpl(r, model, callbacks)

  proc renderStatusInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      model: StatusShellModel;
      callbacks: StatusShellCallbacks = StatusShellCallbacks()) =
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    let shell = renderStatusShell(r, model, callbacks)
    let shellNode = isonim_dom.Node(shell)
    while not isonim_dom.isNodeNil(shellNode.firstChild):
      discard isonim_dom.appendChild(containerNode, shellNode.firstChild)

    if model.showBugReport:
      let button = isonim_dom.getElementById(
        isonim_dom.document,
        cstring"bug-report-container").toJs.querySelector(cstring".bug-report-button")
      if not button.isNil:
        button.onclick = proc() = sendBugReportFromDom(callbacks)
      wireBugReportShortcuts(callbacks)
