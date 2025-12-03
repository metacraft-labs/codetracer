import ../utils, ../../common/ct_event, value, ui_imports, shell, command, editor, times, std/[strformat, jsconsole]
from dom import Node

const HEIGHT_OFFSET = 2
const AGENT_MSG_DIV = "msg-content"
const PLACEHOLDER_MSG = "placeholder-msg"
const TERMINAL_PREFIX = "acp-term-"
const PLACEHOLDER_MSG = "placeholder-msg"

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

proc editorLineNumber(self: AgentActivityComponent, line: int): cstring =
  let trueLineNumber = toCString(line - 1)
  let lineHtml = cstring"<div class='gutter-line' onmousedown='event.stopPropagation()'>" & trueLineNumber & cstring"</div>"
  result = cstring"<div class='gutter " & "' data-line=" & trueLineNumber & cstring" onmousedown='event.stopPropagation()'>" & lineHtml & cstring"</div>"

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
        span(class="ai-name"): text "agent"
        if self.isLoading:
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
    tdiv(id=fmt"shellComponent-{term.shell.id}", class="shell-container")

proc addAgentMessage(self: AgentActivityComponent, messageId: cstring, initialContent: cstring = cstring"", role: AgentMessageRole = AgentMessageAgent): AgentMessage =
  console.log cstring"Adding agent message"
  if not self.messages.hasKey(messageId):
    try:
      let message = AgentMessage(id: messageId, content: initialContent, role: role)
      self.messages[messageId] = message
      self.messageOrder.add(messageId)
    except:
      console.log cstring(fmt"[agent-activity] addAgentMessage failed: {getCurrentExceptionMsg()}")
  result = self.messages[messageId]

proc updateAgentMessageContent(self: AgentActivityComponent, messageId: cstring, content: cstring, append: bool, role: AgentMessageRole = AgentMessageAgent) =
  console.log cstring("[agent-activity] update: begin")
  var message = self.addAgentMessage(messageId, content, role)
  if append and message.content.len > 0:
    message.content = message.content & content
  else:
    message.content = content

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

proc sendAcpPrompt(prompt: cstring) =
  data.ipc.send ("CODETRACER::acp-prompt"), js{
    "text": prompt
  }

proc submitPrompt(self: AgentActivityComponent) =
  # Use the latest input value to avoid stale data.
  let inputEl = document.getElementById(INPUT_ID)
  let promptText =
    if not inputEl.isNil:
      inputEl.toJs.value.to(cstring)
    else:
      self.inputValue

  if promptText.len == 0:
    return

  self.inputValue = promptText
  self.activeAgentMessageId = PLACEHOLDER_MSG.cstring
  let userMessageId = cstring(fmt"user-{self.messageOrder.len}")
  self.updateAgentMessageContent(userMessageId, promptText, false, AgentMessageUser)
  self.updateAgentMessageContent(PLACEHOLDER_MSG, "".cstring, false, AgentMessageAgent)
  discard setTimeout(proc() = scrollAgentCom(), 0)
  sendAcpPrompt(promptText)
  self.clear()

proc clear(self: AgentActivityComponent) =
  self.inputValue = cstring""
  let inputEl = document.getElementById(INPUT_ID)
  if not inputEl.isNil:
    inputEl.toJs.value = cstring""
    autoResizeTextarea(INPUT_ID)

proc passwordPromp(self: AgentActivityComponent): VNode =
  result = buildHtml(tdiv(class="prompt-wrapper")):
    tdiv(class="password-wrapper"):
      input(class="password-prompt-input", `type`="password", placeholder="Password to continue")
      tdiv(class="password-continue-button"):
        text "Continue"

proc userPrompt(self: AgentActivityComponent, prompt: cstring, options: seq[cstring]): VNode =
  result = buildHtml(tdiv(class="prompt-wrapper")):
    tdiv(class="header-wrapper"):
      text prompt
    tdiv(class="user-options-wrapper"):
      for option in options:
        tdiv(class="user-option"):
          text option

proc loadingState(self: AgentActivityComponent): VNode =
  result = buildHtml(tdiv(class="loading-animation"))

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

proc passwordPrompt(self: AgentActivityComponent): VNode =
  result = buildHtml(tdiv(class="prompt-wrapper")):
    tdiv(class="password-wrapper"):
      input(class="password-prompt-input", `type`="password", placeholder="Password to continue")
      tdiv(class="password-continue-button"):
        text "Continue"

proc userPrompt(self: AgentActivityComponent, prompt: cstring, options: seq[cstring]): VNode =
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
  let inputId = INPUT_ID
  self.commandPalette = data.ui.commandPalette
  data.ui.commandPalette.agent = self
  if not self.acpInitSent:
    data.ipc.send("CODETRACER::acp-init-session", js{})
    self.acpInitSent = true
  # let source =
  self.kxi.afterRedraws.add(proc() =
    if not self.kxi.isNil and not self.shell.initialized and self.diffEditor.isNil:
      self.inputField = cast[dom.Node](jq(fmt"#{inputId}"))
      # self.shell.createShell() #TODO: Maybe pass in the lines and column sizes
      self.shell.initialized = true
      let source ="""
diff --git a/src/db-backend/src/expr_loader.rs b/src/db-backend/src/expr_loader.rs
index 71d1dec8..f8499310 100644
--- a/src/db-backend/src/expr_loader.rs
+++ b/src/db-backend/src/expr_loader.rs
@@ -216,6 +216,12 @@ impl ExprLoader {
    pub fn parse_file(&self, path: &PathBuf) -> Result<Tree, Box<dyn Error>> {
        let raw = &self.processed_files[path].source_code;
        let lang = self.get_current_language(path);
+        info!(
+            "parse_file: path={} lang={:?} bytes={}",
+            path.display(),
+            lang,
+            raw.len()
+        );

        let mut parser = Parser::new();
        if lang == Lang::Noir || lang == Lang::RustWasm {
"""
      var lang = fromPath("/home/asd.nr")
      let theme = if self.data.config.theme == cstring"default_white": cstring"codetracerWhite" else: cstring"codetracerDark"
      self.diffEditor = monaco.editor.createDiffEditor(
        jq("#agentEditor-0".cstring),
        MonacoEditorOptions(
          language: lang.toCLang(),
          readOnly: true,
          theme: theme,
          automaticLayout: true,
          folding: true,
          fontSize: self.data.ui.fontSize,
          minimap: js{ enabled: false },
          find: js{ addExtraSpaceOnTop: false },
          renderLineHighlight: "".cstring,
          lineNumbers: proc(line: int): cstring = self.editorLineNumber(line),
          lineDecorationsWidth: 20,
          mouseWheelScrollSensitivity: 0,
          fastScrollSensitivity: 0,
          scrollBeyondLastLine: false,
          smoothScrolling: false,
          contextmenu: false,
          renderOverviewRuler: false,
          renderSideBySide: false,
          scrollbar: js{
            horizontalScrollbarSize: 14,
            horizontalSliderSize: 8,
            verticalScrollbarSize: 14,
            verticalSliderSize: 8
          },
        )
      )
      let (origText, modText) = parseUnifiedDiff($source)

      # Use "rust" for syntax highlighting on both sides
      let originalModel = createModel(origText.cstring, "rust".cstring)
      let modifiedModel = createModel(modText.cstring, "rust".cstring)

      setDiffModel(self.diffEditor, originalModel, modifiedModel)
      # self.shell.shell.write("Hello there, the terminal will wrap after 60 columns.\r\n")
      # self.shell.shell.write("Another line here.\r\n")
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
    tdiv(class="agent-interaction"):
      textarea(
        `type` = "text",
        id = inputId,
        name = "agent-query",
        placeholder = "Ask anything",
        class = "mousetrap ct-input-cp-background agent-command-input",
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
              if self.activeAgentMessageId.len > 0:
                data.ipc.send("CODETRACER::acp-cancel-prompt", js{
                  "messageId": self.activeAgentMessageId
                })
              else:
                data.ipc.send("CODETRACER::acp-cancel-prompt", js{})
              self.isLoading = false
          )

proc asyncSleep(ms: int): Future[void] =
  newPromise(proc(resolve: proc(): void) =
    discard windowSetTimeout(resolve, ms)
  )

proc onAcpReceiveResponse*(sender: js, response: JsObject) {.async.} =
  console.log cstring"[agent-activity] onAcpReceiveResponse"
  console.log response

  # Find the first AgentActivity component via componentMapping.
  console.log cstring(fmt"[agent-activity] componentMapping[AgentActivity].len={data.ui.componentMapping[Content.AgentActivity].len}")
  var self: AgentActivityComponent = nil
  for _, comp in data.ui.componentMapping[Content.AgentActivity]:
    self = AgentActivityComponent(comp)
    # Filter the placeholder msg for the agent:
    self.messageOrder = self.messageOrder.filterIt($it != PLACEHOLDER_MSG)
    self.messages.del(PLACEHOLDER_MSG)
    # TODO: Make a end-process for the isLoading state
    self.isLoading = false
    self.activeAgentMessageId = cstring""
    break

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

  console.log cstring"[agent-activity] got messageId"

  let hasContent = jsHasKey(response, cstring"content")
  let content =
    if hasContent:
      cast[cstring](response[cstring"content"])
    # TODO: Proper error handling
    else:
      cstring""

  let isFinal = jsHasKey(response, cstring"stopReason")
  let appendFlag = self.messages.hasKey(messageId) and not isFinal and hasContent

  console.log cstring"[agent-activity] got content"
  console.log content

  if hasContent or not self.messages.hasKey(messageId):
    try:
      self.updateAgentMessageContent(messageId, content, appendFlag)
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

  var self: AgentActivityComponent = nil
  for _, comp in data.ui.componentMapping[Content.AgentActivity]:
    self = AgentActivityComponent(comp)
    break

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

  var self: AgentActivityComponent = nil
  for _, comp in data.ui.componentMapping[Content.AgentActivity]:
    self = AgentActivityComponent(comp)
    break

  if self.isNil:
    console.log cstring"[agent-activity] no AgentActivity component to receive prompt start"
    return

  if jsHasKey(response, cstring"id"):
    self.activeAgentMessageId = cast[cstring](response[cstring"id"])
    console.log cstring(fmt"[agent-activity] set activeAgentMessageId from prompt-start: {self.activeAgentMessageId}")
