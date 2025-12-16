import ../utils, ../../common/ct_event, value, ui_imports, shell, editor, times, std/[strformat, jsconsole]
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
  ## Locate the AgentActivity component for a given sessionId. Match either the
  ## pending client-side id (init handshake) or the established ACP session id.
  if sessionId.len == 0:
    return nil
  for _, comp in data.ui.componentMapping[Content.AgentActivity]:
    let candidate = AgentActivityComponent(comp)
    if candidate.sessionId == sessionId or candidate.pendingSessionId == sessionId:
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

proc currentSessionKey(self: AgentActivityComponent): cstring

proc addAgentMessage(self: AgentActivityComponent, messageId: cstring, initialContent: cstring = cstring"", role: AgentMessageRole = AgentMessageAgent, canceled: bool = false): AgentMessage =
  if not self.messages.hasKey(messageId):
    try:
      let message = AgentMessage(id: messageId, content: initialContent, role: role, canceled: canceled)
      self.messages[messageId] = message
      self.messageOrder.add(messageId)
    except:
      discard
  result = self.messages[messageId]

proc updateAgentMessageContent(self: AgentActivityComponent, messageId: cstring, content: cstring, append: bool, role: AgentMessageRole = AgentMessageAgent, canceled: bool = false) =
  var message = self.addAgentMessage(messageId, content, role, canceled)
  if append and message.content.len > 0:
    message.content = message.content & content
  else:
    message.content = content
  if canceled:
    message.canceled = true

  self.messages[messageId] = message
  console.log cstring(fmt"[agent-activity] storing message sessionKey={self.currentSessionKey()} messageId={messageId} role={role} canceled={canceled} content={message.content} append={append}")
  self.redraw()

proc bufferMessageChunk(self: AgentActivityComponent, messageId: cstring, content: cstring) =
  ## Accumulate streamed content for a message id until the stop event.
  var existing = cstring""
  if self.messageBuffers.hasKey(messageId):
    existing = self.messageBuffers[messageId]
  self.messageBuffers[messageId] = existing & content

proc flushMessageBuffer(self: AgentActivityComponent, messageId: cstring, role: AgentMessageRole, canceled: bool) =
  ## Flush buffered content to the UI and clear the buffer.
  var content = cstring""
  if self.messageBuffers.hasKey(messageId):
    content = self.messageBuffers[messageId]
  self.messageBuffers.del(messageId)
  console.log cstring(fmt"[agent-activity] flush sessionKey={self.currentSessionKey()} componentId={self.id} messageId={messageId} len={content.len} canceled={canceled}")
  self.updateAgentMessageContent(messageId, content, false, role, canceled)

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
      discard
  result = self.terminals[terminalId]

const INPUT_ID = cstring"agent-query-text"

proc setActiveAgent(self: AgentActivityComponent) =
  ## Mark this component as the active agent prompt sender.
  data.ui.activeAgentSessionId =
    if self.sessionId.len > 0: self.sessionId else: self.pendingSessionId

proc currentSessionKey(self: AgentActivityComponent): cstring =
  if self.sessionId.len > 0:
    self.sessionId
  else:
    self.pendingSessionId

proc ensureSessionMessageList(self: AgentActivityComponent, sessionKey: cstring) =
  if not self.sessionMessageIds.hasKey(sessionKey):
    self.sessionMessageIds[sessionKey] = @[]

proc ensureSessionDiffList(self: AgentActivityComponent, sessionKey: cstring) =
  if not self.sessionDiffs.hasKey(sessionKey):
    self.sessionDiffs[sessionKey] = @[]

proc addDiffPreview(self: AgentActivityComponent, sessionKey, path, original, modified: cstring) =
  self.ensureSessionDiffList(sessionKey)
  var lst = self.sessionDiffs[sessionKey]
  lst.add(DiffPreview(path: path, original: original, modified: modified))
  self.sessionDiffs[sessionKey] = lst

proc addMessageToSession(self: AgentActivityComponent, sessionKey, messageId: cstring) =
  self.ensureSessionMessageList(sessionKey)
  var list = self.sessionMessageIds[sessionKey]
  if list.len == 0 or list[^1] != messageId:
    list.add(messageId)
  self.sessionMessageIds[sessionKey] = list

proc isActiveAgent(self: AgentActivityComponent): bool =
  let activeId = data.ui.activeAgentSessionId
  if activeId.len == 0:
    return true
  activeId == self.sessionId or activeId == self.pendingSessionId

proc flushPendingPrompts(self: AgentActivityComponent) =
  ## Send any queued prompts once the component has a session id.
  if self.sessionId.len == 0:
    return

  if self.pendingPrompts.len == 0:
    return

  for queuedPrompt in self.pendingPrompts:
    data.ipc.send("CODETRACER::acp-prompt", js{
      "sessionId": self.sessionId,
      "clientSessionId": self.pendingSessionId,
      "text": queuedPrompt
    })
  self.pendingPrompts.setLen(0)

proc sendAcpPrompt(self: AgentActivityComponent, prompt: cstring) =
  if not self.isActiveAgent():
    return
  if self.sessionId.len == 0:
    self.pendingPrompts.add(prompt)
    return
  self.flushPendingPrompts()
  console.log cstring(fmt"[agent-activity] sending prompt sessionKey={self.currentSessionKey()} sessionId={self.sessionId} pending={self.pendingSessionId} prompt={prompt}")
  data.ipc.send ("CODETRACER::acp-prompt"), js{
    "sessionId": self.sessionId,
    "clientSessionId": self.pendingSessionId,
    "text": prompt
  }

proc updateAgentUi*(self: AgentActivityComponent, promptText: cstring) =
  self.setActiveAgent()
  if self.promptInFlight:
    return
  self.inputValue = promptText
  let userMessageId = cstring(fmt"user-{self.id}-{self.messageOrder.len}{self.commandInputId}")
  self.updateAgentMessageContent(userMessageId, promptText, false, AgentMessageUser)
  self.updateAgentMessageContent(PLACEHOLDER_MSG, "".cstring, false, AgentMessageAgent)
  self.addMessageToSession(self.currentSessionKey(), userMessageId)
  discard setTimeout(proc() = scrollAgentCom(), 0)
  sendAcpPrompt(self, promptText)
  self.promptInFlight = true
  self.clear()

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

  self.updateAgentUi(promptText)

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
      "clientSessionId": self.pendingSessionId
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
    if data.lastAgentPrompt != "" and not data.lastAgentPrompt.isNil:
      let agent = cast[AgentActivityComponent](data.ui.componentMapping[Content.AgentActivity][data.ui.componentMapping[Content.AgentActivity].len() - 1])
      agent.updateAgentUi(data.lastAgentPrompt)
      data.lastAgentPrompt = ""
      redrawAll()
  )

  result = buildHtml(
    tdiv(class="agent-ha-container")
  ):
    tdiv(class="agent-com"):
      let sessionKey = self.currentSessionKey()
      let orderedMessages =
        if self.sessionMessageIds.hasKey(sessionKey):
          self.sessionMessageIds[sessionKey]
        else:
          @[]
      for msgId in orderedMessages:
        let message = self.messages[msgId]
        if message.role == AgentMessageUser:
          createUserMessageContent(message)
        else:
          createMessageContent(self, message)
      if self.sessionDiffs.hasKey(sessionKey):
        for diff in self.sessionDiffs[sessionKey]:
          tdiv(class="agent-diff-wrapper"):
            tdiv(class="header-wrapper"):
              tdiv(class="task-name"): text fmt"Diff: {diff.path}"
            tdiv(class="agent-diff-content"):
              tdiv(class="agent-diff-original"):
                pre: text diff.original
              tdiv(class="agent-diff-modified"):
                pre: text diff.modified

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
        onfocus = proc (e: Event; n: VNode) =
          self.setActiveAgent(),
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
          class="agent-button new-agent-instance",
          onclick = proc = 
            let options = RunTestOptions(newWindow: true, path: data.services.debugger.location.path, testName: "")
            data.runTests(options)
        )
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
              self.setActiveAgent()
              self.submitPrompt()
              self.inputField.toJs.value = "".cstring
              self.isLoading = true
          )
        else:
          tdiv(
            class="agent-stop-button",
            onclick = proc =
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
              self.promptInFlight = false
              self.redraw()
          )

proc asyncSleep(ms: int): Future[void] =
  newPromise(proc(resolve: proc(): void) =
    discard windowSetTimeout(resolve, ms)
  )

proc onAcpReceiveResponse*(sender: js, response: JsObject) {.async.} =

  let sessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""

  if sessionId.len == 0:
    return
  var self = componentBySessionId(sessionId)
  if self.isNil:
    return

  # Filter the placeholder msg for the agent:
  self.messageOrder = self.messageOrder.filterIt($it != PLACEHOLDER_MSG)
  self.messages.del(PLACEHOLDER_MSG)

  scrollAgentCom()

  let messageId =
    if jsHasKey(response, cstring"messageId"):
      cast[cstring](response[cstring"messageId"])
    elif jsHasKey(response, cstring"id"):
      cast[cstring](response[cstring"id"])
    else:
      PLACEHOLDER_MSG
  if messageId.len == 0 or messageId == PLACEHOLDER_MSG:
    return

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

  let canceledFlag = isFinal and stopReason == cstring"cancelled"

  if hasContent and not isFinal:
    let previewStr = $content
    let preview =
      if previewStr.len > 200: previewStr[0..199].cstring else: previewStr.cstring
    console.log cstring(fmt"[agent-activity] chunk sessionId={sessionId} componentId={self.id} messageId={messageId} len={content.len} content={preview}")
    self.bufferMessageChunk(messageId, content)
    self.activeAgentMessageId = messageId
    return

  let appendFlag = self.messages.hasKey(messageId) and not isFinal and hasContent

  if isFinal:
    try:
      if self.messageBuffers.hasKey(messageId):
        self.flushMessageBuffer(messageId, AgentMessageAgent, canceledFlag)
      elif hasContent:
        self.updateAgentMessageContent(messageId, content, false, AgentMessageAgent, canceledFlag)
      self.addMessageToSession(sessionId, messageId)
      self.activeAgentMessageId = cstring""
    except:
      discard
    self.isLoading = false
    self.promptInFlight = false
    redrawAll()
  elif hasContent or not self.messages.hasKey(messageId):
    try:
      console.log cstring(fmt"[agent-activity] render update sessionKey={self.currentSessionKey()} componentId={self.id} messageId={messageId} append={appendFlag} canceled={canceledFlag} len={content.len}")
      self.updateAgentMessageContent(messageId, content, appendFlag, AgentMessageAgent, canceledFlag)
      self.activeAgentMessageId = messageId
    except:
      discard

proc onAcpCreateTerminal*(sender: js, response: JsObject) {.async.} =

  let sessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""

  let self = componentBySessionId(sessionId)

  if self.isNil:
    return

  let terminalId =
    if jsHasKey(response, cstring"id"):
      cast[cstring](response[cstring"id"])
    else:
      cstring(fmt"{TERMINAL_PREFIX}{self.terminalOrder.len}")

  discard self.addTerminal(terminalId)
  self.redraw()

proc onAcpPromptStart*(sender: js, response: JsObject) {.async.} =

  let sessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""

  let self = componentBySessionId(sessionId)

  if self.isNil:
    return

  if jsHasKey(response, cstring"id"):
    self.activeAgentMessageId = cast[cstring](response[cstring"id"])

proc onAcpRenderDiff*(sender: js, response: JsObject) {.async.} =
  let sessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""
  let self = componentBySessionId(sessionId)
  if self.isNil:
    return
  let path =
    if jsHasKey(response, cstring"path"):
      response[cstring"path"].to(cstring)
    else:
      cstring""
  let original =
    if jsHasKey(response, cstring"original"):
      response[cstring"original"].to(cstring)
    else:
      cstring""
  let modified =
    if jsHasKey(response, cstring"modified"):
      response[cstring"modified"].to(cstring)
    else:
      cstring""
  if original.len == 0 and modified.len == 0:
    return
  self.addDiffPreview(sessionId, path, original, modified)
  self.redraw()

proc onAcpSessionReady*(sender: js, response: JsObject) {.async.} =
  let clientSessionId =
    if jsHasKey(response, cstring"clientSessionId"):
      response[cstring"clientSessionId"].to(cstring)
    else:
      cstring""
  let acpSessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""

  let comp = componentBySessionId(clientSessionId)
  if comp.isNil:
    return
  if acpSessionId.len == 0:
    return
  if jsHasKey(response, cstring"response"):
    let resp = response[cstring"response"]
    if jsHasKey(resp, cstring"_ah"):
      let ahObj = resp[cstring"_ah"]
      if jsHasKey(ahObj, cstring"workspaceDir"):
        comp.workspaceDir = ahObj[cstring"workspaceDir"].to(cstring)
  # migrate any pending-session messages to the established acp session id
  if comp.sessionMessageIds.hasKey(clientSessionId):
    comp.sessionMessageIds[acpSessionId] = comp.sessionMessageIds[clientSessionId]
    comp.sessionMessageIds.del(clientSessionId)
  comp.sessionId = acpSessionId
  comp.acpInitSent = true
  # reset active message when binding a new session to avoid mixing prompts
  comp.activeAgentMessageId = cstring""
  comp.flushPendingPrompts()

proc onAcpSessionLoadError*(sender: js, response: JsObject) {.async.} =
  let clientSessionId =
    if jsHasKey(response, cstring"clientSessionId"):
      response[cstring"clientSessionId"].to(cstring)
    elif jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""
  let comp = componentBySessionId(clientSessionId)
  if not comp.isNil:
    comp.acpInitSent = false
    comp.promptInFlight = false
  # session load failed; keep component idle
  discard

proc onAcpRequestPermission*(sender: js, response: JsObject) {.async.} =
  discard
