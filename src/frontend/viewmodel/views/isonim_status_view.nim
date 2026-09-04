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
    buildLabel*: string
      ## WHAT THIS PAGE WAS BUILT FROM, e.g. `cloud 7ae43783`, or "" when the
      ## build does not know — which is every desktop build, because Electron
      ## is not served by anything and carries no deployment descriptor.
      ##
      ## "" renders NO ELEMENT. That is the property that keeps this change
      ## invisible to the desktop: `#status-base`'s DOM is byte-for-byte what
      ## it was, so the status-bar footer contract, the render-stability spec
      ## and the bottom-strip selector guard all see exactly what they saw.
      ##
      ## Status-Bar.md's inclusion rule is "the status bar shows facts that are
      ## currently true", and "this tab is running commit X" is one — it is,
      ## in fact, the only fact about the page that a user cannot obtain from
      ## the page by any other means.
    buildTitle*: string
      ## The full 40-hex identity for the label's `title=`. The label is
      ## abbreviated so it fits; the tooltip is what a user copies into a bug
      ## report.

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

proc notificationSignature(notification: StatusNotificationRecord): string =
  ## Everything about one notification record that decides its DOM shape.
  ## Notification text is included even though it is "just text": the
  ## notification list is rebuilt wholesale when it changes, so there is no
  ## in-place update path for it and no benefit in distinguishing the cases.
  result = $notification.index & "\x1f" & notification.kindClass & "\x1f" &
    notification.variantClass & "\x1f" & notification.text & "\x1f" &
    (if notification.dismissible: "1" else: "0")
  for action in notification.actions:
    result.add("\x1f" & action.label)

proc statusStructureSignature*(model: StatusShellModel): string =
  ## A digest of everything in `model` that changes the *shape* of the status
  ## bar's DOM, as opposed to the text/class values carried by nodes that
  ## already exist.
  ##
  ## `renderStatusInto` uses it as a cheap "can I patch instead of rebuild?"
  ## test.  Deliberately excluded — and therefore patched in place — are
  ## `language`, `encoding`, `processClass`, `processText`,
  ## `testMovementText`, `disconnectedText`, `disconnectedTitle`,
  ## `locationText`, `locationTitle` and `copyTooltipActive`.  Those are
  ## exactly the fields that change on every debugger step, and keeping their
  ## nodes alive across a step is what makes `.location-path` a stable element
  ## rather than a new one 60+ times per trace open (Value-Origin-Tracking
  ## milestone M46).
  ##
  ## EVERY field of `StatusShellModel` must appear either here or in
  ## `patchStatusValues`.  A field in neither renders once and then never
  ## updates again, which is a silent staleness bug rather than a loud one —
  ## `disconnectedText` was in neither when this split was introduced, and
  ## escaped notice only because it is currently a constant.
  ##
  ## `locationText` participates only through `locationText.len > 0`, because
  ## an empty location renders no `.location-path` element at all while a
  ## non-empty one always renders the same three nodes.
  result = "v1"
  result.add("|tm:" & (if model.base.showTestMovement: "1" else: "0"))
  result.add("|dc:" & (if model.base.showDisconnected: "1" else: "0"))
  result.add("|fi:" & (if model.base.showFinished: "1" else: "0"))
  result.add("|lo:" & (if model.base.locationText.len > 0: "1" else: "0"))
  # THE WHOLE LABEL, not a presence bit. It is a deployment constant, so it
  # never changes within a page and can never cost a rebuild; including it in
  # full is the cheapest way to satisfy this proc's own rule — every field of
  # the model appears here or in `patchStatusValues` — without adding a patch
  # path for a value that cannot vary. `buildTitle` is derived from the same
  # identity and rides along with it.
  result.add("|bu:" & model.base.buildLabel)
  result.add("|nh:" & (if model.showNotifications: "1" else: "0"))
  result.add("|br:" & (if model.showBugReport: "1" else: "0"))
  result.add("|op:" & (if model.hasOperationNotification: "1" else: "0"))
  if model.hasOperationNotification:
    result.add("\x1e" & notificationSignature(model.operationNotification))
  result.add("|an:" & $model.activeNotifications.len)
  for notification in model.activeNotifications:
    result.add("\x1e" & notificationSignature(notification))
  if model.showNotifications:
    result.add("|hi:" & $model.notificationHistory.len)
    for notification in model.notificationHistory:
      result.add("\x1e" & notificationSignature(notification))

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
          # THE BUILD IDENTITY, first in the right-hand group and rendered only
          # when this build knows one. See `StatusBaseModel.buildLabel`: on the
          # desktop it is "" and nothing at all is emitted here.
          if model.base.buildLabel.len > 0:
            span(
                class = "build-identity status-inline",
                title = model.base.buildTitle):
              text model.base.buildLabel
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
                text "Finished"
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
            text "Notifications"
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
            text "Report a problem"
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
              text "Your logs are attached. They can contain file " &
                   "paths and source code from this session."
              button(
                  class = "bug-report-button",
                  onclick = proc() =
                    callbacks.invokeSendBugReport("", "")):
                text "Send report"

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

  proc querySelectorIn(
      root: isonim_dom.Element;
      selector: cstring): isonim_dom.Element {.importjs: "#.querySelector(#)".}

  proc patchText(
      root: isonim_dom.Element; selector: cstring; value: string) =
    ## Replace the text of an existing node without touching the node itself.
    let node = root.querySelectorIn(selector)
    if isonim_dom.isNodeNil(isonim_dom.Node(node)):
      return
    let next = cstring(value)
    # Skip the write when nothing changed: assigning `textContent` discards
    # and recreates the child text node even for an identical string, and
    # the status bar is asked to re-render far more often than its text
    # actually moves.
    if isonim_dom.Node(node).textContent != next:
      isonim_dom.Node(node).textContent = next

  proc patchAttribute(
      root: isonim_dom.Element; selector, name: cstring; value: string) =
    let node = root.querySelectorIn(selector)
    if isonim_dom.isNodeNil(isonim_dom.Node(node)):
      return
    let next = cstring(value)
    if isonim_dom.getAttribute(node, name) != next:
      isonim_dom.setAttribute(node, name, next)

  proc patchStatusValues(
      container: isonim_dom.Element; model: StatusShellModel) =
    ## Update every value-carrying node the structure signature deliberately
    ## ignores, leaving the elements — and therefore any locator or reference
    ## already resolved against them — in place.
    container.patchText(cstring".file-info-status-language", model.base.language)
    container.patchText(cstring".file-info-status-encoding", model.base.encoding)
    container.patchText(cstring"#stable-status", model.base.processText)
    container.patchAttribute(
      cstring"#stable-status", cstring"class", model.base.processClass)
    if model.base.showTestMovement:
      container.patchText(cstring".test-movement", model.base.testMovementText)
    if model.base.showDisconnected:
      container.patchText(
        cstring".disconnected-status", model.base.disconnectedText)
      container.patchAttribute(
        cstring".disconnected-status", cstring"title",
        model.base.disconnectedTitle)
    if not model.base.showFinished and model.base.locationText.len > 0:
      container.patchText(cstring".location-path", model.base.locationText)
      container.patchAttribute(
        cstring".location-path", cstring"title", model.base.locationTitle)
      container.patchAttribute(
        cstring"#location-status .custom-tooltip", cstring"class",
        copyTooltipClass(model.base.copyTooltipActive))

  const
    ## Attribute stamped on the host so a later render can tell whether the
    ## DOM it finds was built from a structurally identical model.  Kept on
    ## the host rather than in a module-level `var` because the host is the
    ## thing whose children we are reasoning about: if anything else clears
    ## it, the attribute goes with it and we correctly fall back to a rebuild.
    StatusStructureAttr* = cstring"data-status-structure"

  proc renderStatusInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      model: StatusShellModel;
      callbacks: StatusShellCallbacks = StatusShellCallbacks()): bool
      {.discardable.} =
    ## Render `model` into the status host, reusing the existing DOM whenever
    ## the model's *structure* is unchanged.  Returns `true` when the subtree
    ## was rebuilt from scratch, so callers can re-mount anything they own
    ## inside it (the bottom strip and collapsed icon-zone hosts) exactly when
    ## those hosts are actually new.
    ##
    ## Why this is not an unconditional rebuild any more: the previous version
    ## removed every child of `#status` and re-created the whole subtree on
    ## each of the 60+ redraws a single trace open triggers, so `.location-path`,
    ## `#copy-path-image`, `#file-info-status` and both auto-hide hosts were
    ## destroyed and re-created dozens of times per second while the app was
    ## still loading.  See Value-Origin-Tracking milestone M46.
    let containerNode = isonim_dom.Node(container)
    let signature = cstring(statusStructureSignature(model))
    let previous = isonim_dom.getAttribute(container, StatusStructureAttr)

    if not isonim_dom.isNodeNil(containerNode.firstChild) and
       not previous.isNil and previous == signature:
      container.patchStatusValues(model)
      return false

    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    let shell = renderStatusShell(r, model, callbacks)
    let shellNode = isonim_dom.Node(shell)
    while not isonim_dom.isNodeNil(shellNode.firstChild):
      discard isonim_dom.appendChild(containerNode, shellNode.firstChild)

    isonim_dom.setAttribute(container, StatusStructureAttr, signature)

    if model.showBugReport:
      let button = isonim_dom.getElementById(
        isonim_dom.document,
        cstring"bug-report-container").toJs.querySelector(cstring".bug-report-button")
      if not button.isNil:
        button.onclick = proc() = sendBugReportFromDom(callbacks)
      wireBugReportShortcuts(callbacks)

    true
