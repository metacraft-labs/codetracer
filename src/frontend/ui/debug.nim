import ui_imports, ../renderer

proc messageView(self: DebugComponent): VNode =
  var current = now()

  if self.message.time != -1 and current - self.message.time > 5_000:
    self.message = LogMessage(time: -1)

  if self.message.message.len == 0 or self.message.time == -1:
    buildHtml(tdiv())
  else:
    let kl = cstring("message-" & ($self.message.level)[3 .. ^1].toLowerAscii)

    buildHtml(
      tdiv(id = "message", class = kl)
    ):
      text self.message.message

proc jumpBeforeList*(self: DebugComponent) =
  self.after = false
  self.before = true
  self.data.redraw()

proc jumpAfterList*(self: DebugComponent) =
  self.before = false
  self.after = true
  self.data.redraw()

proc stopJump*(self: DebugComponent) =
  self.before = false
  self.after = false
  self.data.redraw()

proc runToEntry*(self: DebugComponent) =
  self.service.runToEntry()

proc action(self: DebugComponent, id: string) =
  case id:
  of "reset-operation":
    let taskId = genTaskId(ResetOperation)
    clog "start reset-operation", taskId
    self.service.resetOperation(full=false, taskId=taskId)
    if self.service.jumpHistory.len != 0:
      self.service.jumpHistory[^1].lastOperation = cstring"reset-operation"

  of "full-reset-operation":
    let taskId = genTaskId(ResetOperation)
    clog "start reset-operation", taskId
    self.service.resetOperation(full=true, resetLastLocation=true, taskId=taskId)
    if self.service.jumpHistory.len != 0:
      self.service.jumpHistory[^1].lastOperation = cstring"full-reset-operation"

  of "stop": stopAction()

  of "jump-before": self.jumpBeforeList()

  of "jump-after": self.jumpAfterList()

  of "run-to-entry": self.runToEntry()

  of "history-back":
    self.handleHistoryJump(isForward = true)

  of "history-forward":
    self.handleHistoryJump(isForward = false)

  else:
    discard


var buttons = JsAssoc[cstring, VNode]{
  "history-back": buildHtml(img(src="public/resources/debug/history_back_black.svg", height="20px", width="18px", class="debug-button-svg")),
  "history-forward": buildHtml(img(src="public/resources/debug/history_forward_black.svg", height="20px", width="18px", class="debug-button-svg")),
  "next": buildHtml(img(src="public/resources/debug/next_dark.svg", height="20px", width="18px", class="debug-button-svg")),
  "reverse-next": buildHtml(img(src="public/resources/debug/reverse_next_dark.svg", height="20px", width="18px", class="debug-button-svg")),
  "step-in": buildHtml(img(src="public/resources/debug/step-in_dark.svg", height="14px", width="16px", class="debug-button-svg")),
  "reverse-step-in": buildHtml(img(src="public/resources/debug/reverse_step-in_dark.svg", height="14px", width="16px", class="debug-button-svg")),
  "step-out": buildHtml(img(src="public/resources/debug/step-out_dark.svg", height="14px", width="16px", class="debug-button-svg")),
  "reverse-step-out": buildHtml(img(src="public/resources/debug/reverse_step-out_dark.svg", height="14px", width="16px", class="debug-button-svg")),
  "continue": buildHtml(img(src="public/resources/debug/continue_dark.svg", height="16px", width="28px", class="debug-button-svg")),
  "reverse-continue": buildHtml(img(src="public/resources/debug/reverse_continue_dark.svg", height="16px", width="28px", class="debug-button-svg")),
  "reset-operation": buildHtml(img(src="public/resources/debug/reset_operation_dark.svg", height="16px", width="18px", class="debug-button-svg")),
  "reset-operation-loading": buildHtml(img(src="public/resources/debug/pause_ongoing_16.gif", height="16px", width="16px", class="debug-button-svg")),
  "stop": buildHtml(img(src="public/resources/debug/stop_16_dark.svg", height="16px", width="16px", class="debug-button-svg")),
  "jump-before": buildHtml(img(src="public/resources/debug/jump-before_16_dark.svg", height="16px", width="16px", class="debug-button-svg")),
  "jump-after": buildHtml(img(src="public/resources/debug/jump-after_16_dark.svg", height="16px", width="16px", class="debug-button-svg")),
  "run-to-entry": buildHtml(img(src="public/resources/debug/run_to_entry_dark.svg", height="20px", width="18px", class="debug-button-svg"))
 }

let shortcuts = JsAssoc[cstring, cstring]{
  "next": "F10",
  "reverse-next": "Shift-F10",
  "step-in": "F11",
  "reverse-step-in": "Shift-F11",
  "step-out": "F12",
  "reverse-step-out": "Shift-F12",
  "continue": "F8",
  "reverse-continue": "Shift-F8",
 }

let tooltipText = JsAssoc[cstring, cstring]{
  "next": "Next",
  "reverse-next": "Reverse next",
  "step-in": "Step in",
  "reverse-step-in": "Reverse step in",
  "step-out": "Step out",
  "reverse-step-out": "Reverse step out",
  "continue": "Continue",
  "reverse-continue": "Reverse continue",
  "run-to-entry": "Run to entry",
  "history-back": "History back",
  "history-forward": "History forward",
  "reset-operation": "Reset operation",
}

proc buildListItem(self: DebugComponent, history: JumpHistory, id: int): VNode =
  let myLocation = history
  let fileName = history.location.highLevelPath.split("/")[^1]
  var activeFlag = id == self.service.historyIndex - 1
  var active = if activeFlag: "active" else: ""

  buildHtml(
    tdiv(class="history-list-item-wrapper")
  ):
    span(class=cstring(fmt"history-list-item {active}"),
      onmousedown = proc (ev: Event, et: VNode) =
        ev.preventDefault(),
      onclick = proc(ev: Event, v: VNode) =
        ev.stopPropagation()
        capture myLocation:
          self.service.listHistory = false
          self.service.fullHistory = false
          data.services.history.historyJump(myLocation.location)
          self.service.historyIndex = id + 1
          self.service.currentOperation = HISTORY_JUMP_VALUE):
      text fmt"{history.lastOperation} => {history.location.highLevelFunctionName} || {fileName}:{history.location.line}"

proc buildFullHistory(self: DebugComponent): VNode =
  var hidden = if not self.service.fullHistory: "hidden" else: ""
  return buildHtml(
    tdiv(class = cstring(fmt"full-history-list {hidden}"))
  ):
    for id, history in self.service.jumpHistory.reversed():
      buildListItem(self, history, id)
      if id > 30:
        break

proc buildHistoryMenu(self: DebugComponent): VNode =
  buildHtml(
    tdiv(class = "history-list")
  ):
    if not self.service.historyDirection:
      for id, history in self.service.jumpHistory.reversed():
        if id >= self.service.historyIndex - 1:
          buildListItem(self, history, id)
          if id > 30: break
    else:
      for id, history in self.service.jumpHistory.reversed():
        if id < self.service.historyIndex - 1:
          buildListItem(self, history, id)
          if id > 30: break
    tdiv(class = "history-list-item-wrapper"):
      span(class = cstring(fmt"history-list-item full-history-item"),
        id = "history-focus-id",
        tabIndex = "0",
        onblur = proc() =
          self.service.listHistory = false
          self.service.fullHistory = false
          self.service.usingContextMenu = false,
        onclick = proc(ev: Event, tg: VNode) =
          ev.stopPropagation()
          ev.preventDefault()
          self.service.fullHistory = not self.service.fullHistory
          self.data.redraw()
      ):
        text fmt"View full history"
        span(class = "menu-expand")
      buildFullHistory(self)


method render*(self: DebugComponent): VNode =
  # let klass = if self.service.stableBusy and delta(now(), self.data.ui.lastRedraw) >= 1_000: "debug-button busy" else: "debug-button"
  let finished = if self.service.finished: cstring"debug-finished-background" else: cstring""

  result = buildHtml(
    tdiv()
  ):
    messageView(self)
    tdiv(id="debug", class=finished):

      proc debugStepButton(id: string, action: Action, reverse: bool): VNode {.closure.} =
        # let klass = if self.service.stableBusy and delta(now(), self.data.ui.lastRedraw) >= 1_000:
        #       cstring"debug-button busy"
        #     else:
        #       cstring"debug-button"

        var click = proc =
          let taskId = genTaskId(Step)
          clog "click on step button", taskId
          step(data, id, action, reverse, 1, fromShortcutArg=false, taskId)

        buildHtml(tdiv(class="debug-button-container")):
          span(
            id = cstring(fmt"{id}-debug"),
            class = "debug-button",
            onclick = click
          ):
            buttons[j(id)]
            tdiv(
              class = "custom-tooltip",
            ):
              text tooltipText[id] & cstring(fmt" ({shortcuts[id]})")

      proc debugButton(id: string, disabled: bool = false): VNode {.closure.} =
        let disabledClass = if disabled: "disabled" else: ""
        # let klass = if self.service.stableBusy and delta(now(), self.data.ui.lastRedraw) >= 1_000: "debug-button busy" else: "debug-button"
        var click = proc = action(self, id)

        if not self.service.usingContextMenu:
          self.service.activeHistory = ""

        buildHtml(tdiv(class=cstring(fmt"debug-button-container {disabledClass}"))):
          span(
            id = cstring(fmt"{id}-debug"),
            class = "debug-button",
            onclick = proc() =
              if not disabled:
                click()
              else:
                discard,
            oncontextmenu = proc(ev: Event, tg: VNode) =
              if id == "history-back" or id == "history-forward":
                self.service.usingContextMenu = true
                if self.service.activeHistory == id:
                  self.service.activeHistory = ""
                  self.service.listHistory = false
                else:
                  self.service.activeHistory = id
                  self.service.listHistory = true
                self.service.historyDirection = id == "history-forward"
                self.service.fullHistory = false
                discard setTimeout(proc() =
                  try:
                    jq("#history-focus-id").focus()
                  except:
                    discard,
                  100
                )
          ):
            tdiv(class=cstring(fmt"{disabledClass}")):
              buttons[cstring(id)]
            tdiv(
              class = "custom-tooltip",
            ):
              text tooltipText[id]

      if not self.service.finished:
        separateBar()
        debugButton("history-back")
        if self.service.listHistory:
          buildHistoryMenu(self)
        debugButton("history-forward")
        separateBar()
        debugStepButton("reverse-next", Next, true)
        debugStepButton("next", Next, false)
        separateBar()
        debugStepButton("reverse-step-in", StepIn, true)
        debugStepButton("step-in", StepIn, false)
        separateBar()
        debugStepButton("reverse-step-out", StepOut, true)
        debugStepButton("step-out", StepOut, false)
        separateBar()
        debugStepButton("reverse-continue", Continue, true)
        debugStepButton("continue", Continue, false)
        separateBar()
        debugButton("run-to-entry")
        separateBar()
        debugButton("reset-operation", not self.service.stableBusy)
        separateBar()
      else:
        debugStepButton("continue", Continue, false)
        debugButton("run-to-entry")
        tdiv(class="debug-finished"):
          text "FINISHED"
      render(data.ui.commandPalette)
