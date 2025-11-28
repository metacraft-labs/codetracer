import ../utils, ../../common/ct_event, value, ui_imports, shell, command, editor, times, std/[strformat, jsconsole]
from dom import Node

const HEIGHT_OFFSET = 2
const AGENT_MSG_DIV = "msg-content"

proc jsHasKey(obj: JsObject; key: cstring): bool {.importjs: "#.hasOwnProperty(#)".}

proc autoResizeTextarea(id: cstring) =
  let el = document.getElementById(id)
  if el.isNil: return

  el.style.height = $(el.toJs.scrollHeight.to(int) + HEIGHT_OFFSET) & "px"
  el.toJs.scrollTop = el.toJs.scrollHeight.to(int) + HEIGHT_OFFSET

proc editorLineNumber(self: AgentActivityComponent, line: int, lineNumber: int): cstring =
  let trueLineNumber = toCString(line + lineNumber - 1)
  let lineHtml = cstring"<div class='gutter-line' onmousedown='event.stopPropagation()'>" & trueLineNumber & cstring"</div>"
  result = cstring"<div class='gutter " & "' data-line=" & trueLineNumber & cstring" onmousedown='event.stopPropagation()'>" & lineHtml & cstring"</div>"

proc createUserMessageContent(msg: AgentMessage): VNode =
  buildHtml(tdiv(class="user-msg")):
    tdiv(class="header-wrapper"):
      tdiv(class="content-header"):
        tdiv(class="user-img")
        span(class="user-name"): text "author"
      tdiv(class="msg-controls"):
        tdiv(class="command-palette-copy-button")
        tdiv(class="command-palette-edit-button")
    tdiv(class="msg-content"):
      text msg.content

proc createMessageContent(msg: AgentMessage): VNode =
  result = buildHtml(tdiv(class="ai-msg")):
    tdiv(class="header-wrapper"):
      tdiv(class="content-header"):
        tdiv(class="ai-img")
        span(class="ai-name"): text "agent"
        span(class="ai-status"): text "working..."
      tdiv(class="msg-controls"):
        tdiv(class="command-palette-copy-button")
        tdiv(class="command-palette-upload-button")
        tdiv(class="command-palette-redo-button")
    tdiv(class="msg-content", id = fmt"{AGENT_MSG_DIV}-{msg.id}"):
      text msg.content

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
  let userMessageId = cstring(fmt"user-{self.messageOrder.len}")
  self.updateAgentMessageContent(userMessageId, promptText, false, AgentMessageUser)
  sendAcpPrompt(promptText)
  self.clear()

proc clear(self: AgentActivityComponent) =
  self.inputValue = cstring""
  let inputEl = document.getElementById(INPUT_ID)
  if not inputEl.isNil:
    inputEl.toJs.value = cstring""
    autoResizeTextarea(INPUT_ID)

method render*(self: AgentActivityComponent): VNode =
  let inputId = INPUT_ID
  self.commandPalette = data.ui.commandPalette
  data.ui.commandPalette.agent = self
  # let source =
  if not self.kxi.isNil and not self.shell.initialized:
    self.kxi.afterRedraws.add(proc() =
      self.inputField = cast[dom.Node](jq(fmt"#{inputId}"))
      self.shell.createShell() #TODO: Maybe pass in the lines and column sizes
      self.shell.initialized = true
      # let source = """mod foo;
      #   mod bar;
      #
      #   use crate::foo::foo;
      #
      #   fn main(x: Field, y: pub Field, z: Field) {
      #       let w = looper(x, y);
      #       assert(w == z, "expected w to equal z!");
      #   }
      #
      #   fn looper(x: Field, y: Field) -> Field {
      #       let mut result = x;
      #       for i in 0..10 {
      #           println(i + 1);
      #           println(i + 1);
      #           if i % 3 == 0 {
      #               result = result + y + 2;
      #           }
      #
      #
      #       }
      #       result
      #   }
      #
      #   """
      let source = cstring""
      var lang = fromPath(self.data.services.debugger.location.path)
      let theme = if self.data.config.theme == cstring"default_white": cstring"codetracerWhite" else: cstring"codetracerDark"
      self.monacoEditor = createMonacoEditor(
        "#agentEditor-0".cstring,
        MonacoEditorOptions(
          value: source,
          language: lang.toCLang(),
          readOnly: true,
          theme: theme,
          automaticLayout: true,
          folding: true,
          fontSize: self.data.ui.fontSize,
          minimap: js{ enabled: false },
          find: js{ addExtraSpaceOnTop: false },
          renderLineHighlight: "".cstring,
          lineNumbers: proc(line: int): cstring = self.editorLineNumber(line, 100),
          lineDecorationsWidth: 20,
          mouseWheelScrollSensitivity: 0,
          fastScrollSensitivity: 0,
          scrollBeyondLastLine: false,
          smoothScrolling: false,
          contextmenu: false,
          scrollbar: js{
            horizontalScrollbarSize: 14,
            horizontalSliderSize: 8,
            verticalScrollbarSize: 14,
            verticalSliderSize: 8
          },
        )
      )
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
          createMessageContent(message)
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
        onmousedown = proc =
          echo "#### SEARCH"
          discard,
        onkeydown = proc (e: Event; n: VNode) =
          let ke = cast[KeyboardEvent](e)
          if ke.key == "Enter":
            if ke.shiftKey:
              return
            else:
              e.preventDefault()
              self.submitPrompt()

        ,
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
        tdiv(
          class="agent-enter",
          onclick = proc =
            echo "#TODO: Upload me master!"

            self.submitPrompt()
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
    break

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
      block:
        let orderLen = if self.messageOrder.len == 0: 0 else: self.messageOrder.len
        cstring(fmt"acp-{orderLen}")

  console.log cstring"[agent-activity] got messageId"

  let hasContent = jsHasKey(response, cstring"content")
  let content =
    if hasContent:
      cast[cstring](response[cstring"content"])
    else:
      cstring""

  let isFinal = jsHasKey(response, cstring"stopReason")
  let appendFlag = self.messages.hasKey(messageId) and not isFinal and hasContent

  console.log cstring"[agent-activity] got content"
  console.log content

  if hasContent or not self.messages.hasKey(messageId):
    try:
      self.updateAgentMessageContent(messageId, content, appendFlag)
      console.log cstring"[agent-activity] update + redraw complete"
      console.log cstring(fmt"[agent-activity] stored messages now={self.messages.len} order={self.messageOrder.len}")
    except:
      console.log cstring(fmt"[agent-activity] update failed: {getCurrentExceptionMsg()}")
  else:
    console.log cstring"[agent-activity] no content; skipping update"
