import ../utils, ../../common/ct_event, value, ui_imports, shell, command, editor, times, std/[strformat, jsconsole]
from dom import Node

const HEIGHT_OFFSET = 2
const AGENT_MSG_DIV = "msg-content"
const PLACEHOLDER_MSG = "placeholder-msg"
const TERMINAL_PREFIX = "acp-term-"

proc jsHasKey(obj: JsObject; key: cstring): bool {.importjs: "#.hasOwnProperty(#)".}

proc createModel*(value, language: cstring): js
  {.importjs: "monaco.editor.createModel(#, #)".}

proc setDiffModel*(editor: DiffEditor, original, modified: js)
  {.importjs: "#.setModel({ original: #, modified: # })".}

proc setValue*(model: js, value: cstring)
  {.importjs: "#.setValue(#)".}

var originalModel = createModel("".cstring, "plaintext".cstring)
var modifiedModel = createModel("".cstring, "plaintext".cstring)

proc scrollAgentCom() =
  let el = document.getElementsByClassName("agent-com")
  for e in el:
    e.toJs.scrollTop = e.toJs.scrollHeight

proc autoResizeTextarea(id: cstring) =
  let el = document.getElementById(id)
  if el.isNil: return
  el.style.height = "auto"
  el.style.height = $el.toJs.scrollHeight & "px"
  el.toJs.scrollTop = el.toJs.scrollHeight.to(int) + HEIGHT_OFFSET

proc componentBySessionId(sessionId: cstring): AgentActivityComponent =
  ## Locate the AgentActivity component for a given sessionId. If sessionId is
  ## empty, return the first available component.
  for _, comp in data.ui.componentMapping[Content.AgentActivity]:
    let candidate = AgentActivityComponent(comp)
    if sessionId.len == 0 or candidate.sessionId == sessionId:
      return candidate
  nil

proc editorLineNumber(self: AgentActivityComponent, line: int): cstring =
  let trueLineNumber = toCString(line - 1)
  let lineHtml = cstring"<div class='gutter-line' onmousedown='event.stopPropagation()'>" & trueLineNumber & cstring"</div>"
  result = cstring"<div class='gutter " & "' data-line=" & trueLineNumber & cstring" onmousedown='event.stopPropagation()'>" & lineHtml & cstring"</div>"

proc createUserMessageContent(msg: AgentMessage): VNode =
  buildHtml(tdiv(class="agent-msg-wrapper")):
    tdiv(class="header-wrapper"):
      tdiv(class="content-header"):
        tdiv(class="user-img")
        span(class="user-name"): text "author"
      tdiv(class="msg-controls"):
        tdiv(class="command-palette-copy-button")
        # tdiv(class="command-palette-edit-button")
    tdiv(class="msg-content"):
      text msg.content

proc createMessageContent(self: AgentActivityComponent, msg: AgentMessage): VNode =
  result = buildHtml(tdiv(class="agent-msg-wrapper")):
    tdiv(class="header-wrapper"):
      tdiv(class="content-header"):
        tdiv(class="ai-img")
        span(class="ai-name"):
          text "agent"
          if msg.canceled:
            span(style=style((StyleAttr.color, cstring"red"))):
              text " (canceled)"
        if self.isLoading and not msg.canceled:
          span(class="ai-status")
      tdiv(class="msg-controls"):
        tdiv(class="command-palette-copy-button")
        # tdiv(class="command-palette-upload-button")
        # tdiv(class="command-palette-redo-button")
    tdiv(class="msg-content", id = fmt"{AGENT_MSG_DIV}-{msg.id}"):
      text msg.content

proc createTerminalContent(self: AgentActivityComponent, term: AgentTerminal): VNode =
  # Ensure the terminal is created after the VNode mounts so the container exists.
  let shellRef = term.shell
  if not shellRef.initialized:
    self.kxi.afterRedraws.add(proc() =
      if not shellRef.initialized:
        discard shellRef.createShell()
        shellRef.initialized = true
    )

  result = buildHtml(tdiv(class="terminal-wrapper")):
    tdiv(class="header-wrapper"):
      tdiv(class="task-name"): text fmt"Terminal {term.id}"
      tdiv(class="msg-controls"):
        tdiv(class="command-palette-copy-button", style=style(StyleAttr.marginRight, "6px".cstring))
        tdiv(class="agent-model-img")
    tdiv(id=fmt"shellComponent-{term.shell.id}{self.commandInputId}", class="shell-container")

proc addAgentMessage(self: AgentActivityComponent, messageId: cstring, initialContent: cstring = cstring"", role: AgentMessageRole = AgentMessageAgent, canceled: bool = false): AgentMessage =
  console.log cstring"Adding agent message"
  if not self.messages.hasKey(messageId):
    try:
      let message = AgentMessage(id: messageId, content: initialContent, role: role, canceled: canceled)
      self.messages[messageId] = message
      self.messageOrder.add(messageId)
    except:
      console.log cstring(fmt"[agent-activity] addAgentMessage failed: {getCurrentExceptionMsg()}")
  result = self.messages[messageId]

proc updateAgentMessageContent(self: AgentActivityComponent, messageId: cstring, content: cstring, append: bool, role: AgentMessageRole = AgentMessageAgent, canceled: bool = false) =
  console.log cstring("[agent-activity] update: begin")
  var message = self.addAgentMessage(messageId, content, role, canceled)
  if append and message.content.len > 0:
    message.content = message.content & content
  else:
    message.content = content
  if canceled:
    message.canceled = true

  self.messages[messageId] = message
  self.redraw()

proc addTerminal(self: AgentActivityComponent, terminalId: cstring): AgentTerminal =
  if not self.terminals.hasKey(terminalId):
    try:
      let shellId = self.data.generateId(Content.Shell)
      let shellComp = ShellComponent(self.data.makeComponent(Content.Shell, shellId))
      shellComp.initialized = false
      let term = AgentTerminal(id: terminalId, shell: shellComp)
      self.terminals[terminalId] = term
      self.terminalOrder.add(terminalId)
    except:
      console.log cstring(fmt"[agent-activity] addTerminal failed: {getCurrentExceptionMsg()}")
  result = self.terminals[terminalId]

const INPUT_ID = cstring"agent-query-text"

proc sendAcpPrompt(self: AgentActivityComponent, prompt: cstring) =
  data.ipc.send ("CODETRACER::acp-prompt"), js{
    "sessionId": self.sessionId,
    "text": prompt
  }

proc submitPrompt(self: AgentActivityComponent) =
  # Use the latest input value to avoid stale data.
  let inputEl = document.getElementById(INPUT_ID & fmt"-{self.id}{self.commandInputId}")
  let promptText =
    if not inputEl.isNil:
      inputEl.toJs.value.to(cstring)
    else:
      self.inputValue

  if promptText.len == 0:
    return

  self.inputValue = promptText
  self.activeAgentMessageId = PLACEHOLDER_MSG.cstring
  let userMessageId = cstring(fmt"user-{self.id}-{self.messageOrder.len}{self.commandInputId}")
  self.updateAgentMessageContent(userMessageId, promptText, false, AgentMessageUser)
  self.updateAgentMessageContent(PLACEHOLDER_MSG, "".cstring, false, AgentMessageAgent)
  discard setTimeout(proc() = scrollAgentCom(), 0)
  sendAcpPrompt(self, promptText)
  self.clear()

proc clear(self: AgentActivityComponent) =
  self.inputValue = cstring""
  let inputEl = document.getElementById(INPUT_ID  & fmt"-{self.id}{self.commandInputId}")
  if not inputEl.isNil:
    inputEl.toJs.value = cstring""
    autoResizeTextarea(INPUT_ID & fmt"-{self.id}{self.commandInputId}")

proc passwordPromp(self: AgentActivityComponent): VNode =
  result = buildHtml(tdiv(class="prompt-wrapper")):
    tdiv(class="password-wrapper"):
      input(class="password-prompt-input", `type`="password", placeholder="Password to continue")
      tdiv(class="password-continue-button"):
        text "Continue"

proc parseUnifiedDiff(patch: string): (string, string) =
  ## Very simple unified diff parser:
  ## - skips headers: diff/index/---/+++/@@
  ## - '+' lines -> only in modified
  ## - '-' lines -> only in original
  ## - ' ' lines -> in both
  ## - others -> in both verbatim
  var origLines: seq[string] = @[]
  var modLines: seq[string] = @[]

  for line in patch.splitLines():
    if line.len == 0:
      origLines.add("")
      modLines.add("")
      continue

    if line.startsWith("diff ") or
       line.startsWith("index ") or
       line.startsWith("--- ") or
       line.startsWith("+++ ") or
       line.startsWith("@@"):
      continue

    let first = line[0]
    case first
    of '+':
      # added line in modified
      modLines.add(line.substr(1))
    of '-':
      # removed line in original
      origLines.add(line.substr(1))
    of ' ':
      let t = line.substr(1)
      origLines.add(t)
      modLines.add(t)
    else:
      # unknown prefix: mirror into both
      origLines.add(line)
      modLines.add(line)

  (origLines.join("\n"), modLines.join("\n"))

proc createPasswordPrompt(self: AgentActivityComponent): VNode =
  result = buildHtml(tdiv(class="prompt-wrapper")):
    tdiv(class="password-wrapper"):
      input(class="password-prompt-input", `type`="password", placeholder="Password to continue")
      tdiv(class="password-continue-button"):
        text "Continue"

proc createUserPrompt(self: AgentActivityComponent, prompt: cstring, options: seq[cstring]): VNode =
  result = buildHtml(tdiv(class="prompt-wrapper")):
    tdiv(class="header-wrapper"):
      text prompt
    tdiv(class="user-options-wrapper"):
      for option in options:
        tdiv(class="user-option"):
          text option

proc loadingState(self: AgentActivityComponent): VNode =
  result = buildHtml(tdiv(class="loading-animation"))

method render*(self: AgentActivityComponent): VNode =
  self.commandInputId = if self.inCommandPalette: "-command" else: ""
  var inputId = INPUT_ID & fmt"-{self.id}{self.commandInputId}"
  data.ui.commandPalette.agent = self
  if not self.acpInitSent:
    data.ipc.send("CODETRACER::acp-session-init", js{
      "sessionId": self.sessionId
    })
    self.acpInitSent = true
  # let source =
  self.kxi.afterRedraws.add(proc() =
    if not self.kxi.isNil:
      self.inputField = cast[dom.Node](jq(fmt"#{inputId}"))
      # self.shell.createShell() #TODO: Maybe pass in the lines and column sizes
      
      # # Use "rust" for syntax highlighting on both sides
      # let originalModel = createModel(origText.cstring, "rust".cstring)
      # let modifiedModel = createModel(modText.cstring, "rust".cstring)

      # setDiffModel(self.diffEditor, originalModel, modifiedModel)
      # # self.shell.shell.write("Hello there, the terminal will wrap after 60 columns.\r\n")
      # # self.shell.shell.write("Another line here.\r\n")
  )

  result = buildHtml(
    tdiv(class="agent-ha-container")
  ):
    tdiv(class="agent-com"):
      for msgId in self.messageOrder:
        let message = self.messages[msgId]
        if message.role == AgentMessageUser:
          createUserMessageContent(message)
        else:
          createMessageContent(self, message)

      for termId in self.terminalOrder:
        let terminal = self.terminals[termId]
        createTerminalContent(self, terminal)
          # TODO: For now hardcoded id - should be shellComponent-{custom-id}
          # tdiv(class="terminal-wrapper"):
          #   tdiv(class="header-wrapper"):
          #     tdiv(class="task-name"):
          #       text "Running task..."
          #     tdiv(class="msg-controls"):
          #       tdiv(class="command-palette-copy-button", style=style(StyleAttr.marginRight, "6px".cstring))
          #       tdiv(
          #         class="agent-model-img"
          #       )
          #   # if self.expandControl[self.shell.id]:
          #   tdiv(id=fmt"shellComponent-{self.shell.id}", class="shell-container")
          # tdiv(class="editor-wrapper"):
          #   tdiv(id="agentEditor-0", class="agent-editor")
        # TODO: Integrate it
      if self.wantsPassword:
        createPasswordPrompt(self)
      if self.wantsPermission:
        createUserPrompt(self, cstring"How are you", @[cstring"well", cstring"bad"])

    tdiv(class="agent-interaction"):
      textarea(
        `type` = "text",
        id = inputId,
        name = "agent-query",
        placeholder = "Ask anything",
        class = "mousetrap agent-command-input",
        autocomplete="off", # https://stackoverflow.com/questions/254712/disable-spell-checking-on-html-textfields
        autocorrect="off",
        autocapitalize="off",
        rows="1",
        spellcheck="false",
        onkeydown = proc (e: Event; n: VNode) =
          let ke = cast[KeyboardEvent](e)
          if ke.key == "Enter":
            if ke.shiftKey:
              return
            else:
              if not self.isLoading:
                e.preventDefault()
                self.submitPrompt()
                self.inputField.toJs.value = "".cstring
                self.isLoading = true,
        oninput = proc (e: Event; n: VNode) =
          self.inputValue = self.inputField.toJs.value.to(cstring)
          autoResizeTextarea(inputId)
      )
      tdiv(class="agent-buttons-container"):
        tdiv(
          class="agent-button",
          onclick = proc =
            echo "#TODO: add a file"
        ):
          span(class="add-file-img")
          text "Add files and more"
        tdiv(
          class="agent-button agent-model-select",
          onclick = proc =
            echo "#TODO: Open the model table"
        ):
          tdiv(): text "#TODO: name"
          tdiv(class="agent-model-img")
        if not self.isLoading:
          tdiv(
            class="agent-start-button",
            onclick = proc =
              self.submitPrompt()
              self.inputField.toJs.value = "".cstring
              self.isLoading = true
          )
        else:
          tdiv(
            class="agent-stop-button",
            onclick = proc =
              echo fmt"[agent-activity] stopping session: {self.data.services.debugger.location.path}"

              var cancelId = cstring""
              if self.activeAgentMessageId.len > 0:
                cancelId = self.activeAgentMessageId
              elif self.messageOrder.len > 0:
                cancelId = self.messageOrder[^1]

              if cancelId.len > 0:
                var msg = self.addAgentMessage(cancelId, cstring"", AgentMessageAgent)
                msg.canceled = true
                self.messages[cancelId] = msg

              if self.activeAgentMessageId.len > 0:
                data.ipc.send("CODETRACER::acp-cancel-prompt", js{
                  "sessionId": self.sessionId,
                  "messageId": self.activeAgentMessageId
                })
              else:
                data.ipc.send("CODETRACER::acp-cancel-prompt", js{
                  "sessionId": self.sessionId
                })
              self.isLoading = false
              self.redraw()
          )

proc asyncSleep(ms: int): Future[void] =
  newPromise(proc(resolve: proc(): void) =
    discard windowSetTimeout(resolve, ms)
  )

proc onAcpReceiveResponse*(sender: js, response: JsObject) {.async.} =
  console.log cstring"[agent-activity] onAcpReceiveResponse"
  console.log response

  let sessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""

  console.log cstring(fmt"[agent-activity] componentMapping[AgentActivity].len={data.ui.componentMapping[Content.AgentActivity].len}")
  var self = componentBySessionId(sessionId)
  if not self.isNil:
    # Filter the placeholder msg for the agent:
    self.messageOrder = self.messageOrder.filterIt($it != PLACEHOLDER_MSG)
    self.messages.del(PLACEHOLDER_MSG)
    # TODO: Make a end-process for the isLoading state
    self.activeAgentMessageId = cstring""

    scrollAgentCom()

    if self.isNil:
      console.log cstring"[agent-activity] no AgentActivity component to receive ACP response yet"
      return

    console.log cstring(fmt"[agent-activity] handler using component id={self.id} messages={self.messages.len} orderLen={self.messageOrder.len}")

    let messageId =
      if jsHasKey(response, cstring"messageId"):
        cast[cstring](response[cstring"messageId"])
      elif jsHasKey(response, cstring"id"):
        cast[cstring](response[cstring"id"])
      else:
        PLACEHOLDER_MSG

    if self.activeAgentMessageId == messageId:
      console.log cstring"[agent-activity] got messageId"

      let hasContent = jsHasKey(response, cstring"content")
      let content =
        if hasContent:
          cast[cstring](response[cstring"content"])
        # TODO: Proper error handling
        else:
          cstring""

  let isFinal = jsHasKey(response, cstring"stopReason")
  let stopReason =
    if isFinal:
      cast[cstring](response[cstring"stopReason"])
    else:
      cstring""

  if isFinal:
    console.log cstring"[agent-activity] got stopReason"
    self.isLoading = false
    redrawAll()

  let appendFlag = self.messages.hasKey(messageId) and not isFinal and hasContent
  let canceledFlag = isFinal and stopReason == cstring"cancelled"

      console.log cstring"[agent-activity] got content"
      console.log content

  if hasContent or not self.messages.hasKey(messageId):
    try:
      self.updateAgentMessageContent(messageId, content, appendFlag, AgentMessageAgent, canceledFlag)
      console.log cstring(fmt"[agent-activity] updated active messageId={messageId} append={appendFlag}")
      self.activeAgentMessageId = messageId
      console.log cstring"[agent-activity] update + redraw complete"
      console.log cstring(fmt"[agent-activity] stored messages now={self.messages.len} order={self.messageOrder.len}")
    except:
      console.log cstring(fmt"[agent-activity] update failed: {getCurrentExceptionMsg()}")
  else:
    console.log cstring"[agent-activity] no content; skipping update"

proc onAcpCreateTerminal*(sender: js, response: JsObject) {.async.} =
  console.log cstring"[agent-activity] onAcpCreateTerminal"
  console.log response

  let sessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""

  let self = componentBySessionId(sessionId)

  if self.isNil:
    console.log cstring"[agent-activity] no AgentActivity component to receive ACP terminal yet"
    return

  let terminalId =
    if jsHasKey(response, cstring"id"):
      cast[cstring](response[cstring"id"])
    else:
      cstring(fmt"{TERMINAL_PREFIX}{self.terminalOrder.len}")

  discard self.addTerminal(terminalId)
  self.redraw()

proc onAcpPromptStart*(sender: js, response: JsObject) {.async.} =
  console.log cstring"[agent-activity] onAcpPromptStart"
  console.log response

  let sessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""

  let self = componentBySessionId(sessionId)

  if self.isNil:
    console.log cstring"[agent-activity] no AgentActivity component to receive prompt start"
    return

  if jsHasKey(response, cstring"id"):
    self.activeAgentMessageId = cast[cstring](response[cstring"id"])
    console.log cstring(fmt"[agent-activity] set activeAgentMessageId from prompt-start: {self.activeAgentMessageId}")

proc onAcpSessionReady*(sender: js, response: JsObject) {.async.} =
  let sessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""
  let comp = componentBySessionId(sessionId)
  if not comp.isNil:
    comp.acpInitSent = true
    console.log cstring(fmt"[agent-activity] session ready for {sessionId}")

proc onAcpSessionLoadError*(sender: js, response: JsObject) {.async.} =
  let sessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""
  let comp = componentBySessionId(sessionId)
  if not comp.isNil:
    comp.acpInitSent = false
  console.log cstring(fmt"[agent-activity] session load error for {sessionId}")

proc onAcpRequestPermission*(sender: js, response: JsObject) {.async.} =
  console.log cstring(fmt"[agent-activity] onAcpRequestPermission")
