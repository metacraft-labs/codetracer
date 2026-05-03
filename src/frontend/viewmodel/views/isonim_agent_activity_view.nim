## views/isonim_agent_activity_view.nim
##
## IsoNim DOM-rendering view for the Agent Activity panel.

import std/tables

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/agent_activity_vm

const AgentActivityContainerClass* = "agent-ha-container"
const AgentActivityConversationClass* = "agent-com"
const AgentActivityInteractionClass* = "agent-interaction"
const AgentActivityInputClass* = "mousetrap agent-command-input"
const AgentActivityInputPrefix* = "agent-query-text"
const AgentActivityMessageContentClass* = "msg-content"
const AgentActivityDiffEditorPrefix* = "diff-editor"
const AgentActivityTerminalShellPrefix* = "shellComponent-"
const AgentActivityPlaceholderText* = "Ask anything"

type
  AgentActivityCallbacks* = object
    onFocusInput*: proc()
    onInputChange*: proc(value: string)
    onSubmitPrompt*: proc()
    onStopPrompt*: proc()
    onNewAgentInstance*: proc()
    onAddFiles*: proc()
    onModelSelect*: proc()
    afterDynamicRender*: proc()

proc messageWrapperClass*(role: AgentActivityMessageRole): string =
  case role
  of aamrUser: "agent-msg-wrapper user-wrapper"
  of aamrAgent: "agent-msg-wrapper"

proc messageName*(role: AgentActivityMessageRole): string =
  case role
  of aamrUser: "author"
  of aamrAgent: "agent"

proc messageAvatarClass*(role: AgentActivityMessageRole): string =
  case role
  of aamrUser: "user-img"
  of aamrAgent: "ai-img"

proc inputId*(componentId: int; commandInputId: string = ""): string =
  AgentActivityInputPrefix & "-" & $componentId & commandInputId

proc diffEditorId*(componentId: int; diffId: int): string =
  AgentActivityDiffEditorPrefix & "-" & $componentId & "-" & $diffId

proc shellContainerId*(shellId: int; commandInputId: string = ""): string =
  AgentActivityTerminalShellPrefix & $shellId & commandInputId

proc renderMockMessage(r: MockRenderer; componentId: int;
                       message: AgentActivityMessageEntry): MockNode =
  let wrapperClass = messageWrapperClass(message.role)
  let avatarClass = messageAvatarClass(message.role)
  let name = messageName(message.role)
  let contentId = AgentActivityMessageContentClass & "-" & message.id
  let content = message.content
  ui(r):
    tdiv(class = wrapperClass):
      tdiv(class = "header-wrapper"):
        tdiv(class = "content-header"):
          tdiv(class = avatarClass)
          span(class = (if message.role == aamrAgent: "ai-name" else: "user-name")):
            text name
            if message.canceled:
              span:
                text " (canceled)"
          if message.role == aamrAgent and message.isLoading and
             not message.canceled:
            span(class = "ai-status")
        tdiv(class = "msg-controls"):
          button(class = "ct-button-image-sm-secondary command-palette-copy-button",
                 `type` = "button")
      tdiv(class = AgentActivityMessageContentClass, id = contentId):
        text content
      for diffValue in message.diffs:
        let diff = diffValue
        tdiv(class = "component-wrapper"):
          tdiv(class = "header-wrapper"):
            tdiv(class = "task-name"):
              text diff.path
          tdiv(class = "agent-editor-wrapper"):
            tdiv(class = "agent-editor",
                 id = diffEditorId(componentId, diff.id))

proc renderMockTerminal(r: MockRenderer; terminal: AgentActivityTerminalEntry;
                        commandInputId: string): MockNode =
  ui(r):
    tdiv(class = "terminal-wrapper"):
      tdiv(class = "header-wrapper"):
        tdiv(class = "task-name"):
          text "Terminal " & terminal.id
        tdiv(class = "msg-controls"):
          button(class = "ct-button-image-sm-secondary command-palette-copy-button terminal-copy-button",
                 `type` = "button")
          tdiv(class = "agent-model-img")
      tdiv(id = shellContainerId(terminal.shellId, commandInputId),
           class = "shell-container")

proc renderAgentActivityPanel*(r: MockRenderer; vm: AgentActivityVM;
    componentId: int; commandInputId: string = "";
    callbacks: AgentActivityCallbacks = AgentActivityCallbacks()): MockNode =
  var conversation: MockNode
  var input: MockNode
  var buttons: MockNode
  let inputIdValue = inputId(componentId, commandInputId)

  let panel = ui(r):
    tdiv(class = AgentActivityContainerClass):
      tdiv(ref = conversation, class = AgentActivityConversationClass):
        discard
      tdiv(class = AgentActivityInteractionClass):
        textarea(ref = input,
                 `type` = "text",
                 id = inputIdValue,
                 name = "agent-query",
                 placeholder = AgentActivityPlaceholderText,
                 class = AgentActivityInputClass,
                 autocomplete = "off",
                 autocorrect = "off",
                 autocapitalize = "off",
                 rows = "1",
                 spellcheck = "false")
        tdiv(ref = buttons, class = "agent-buttons-container"):
          discard

  r.addEventListener(input, "focus", proc() =
    if callbacks.onFocusInput != nil:
      callbacks.onFocusInput())
  r.addEventListener(input, "input", proc() =
    let value = input.attributes.getOrDefault("value", "")
    vm.setInputValue(value)
    if callbacks.onInputChange != nil:
      callbacks.onInputChange(value))
  r.addEventListener(input, "keydown", proc() =
    if callbacks.onSubmitPrompt != nil:
      callbacks.onSubmitPrompt())

  createRenderEffect proc() =
    r.clearChildren(conversation)
    for message in vm.messages.val:
      r.appendChild(conversation, renderMockMessage(r, componentId, message))
    for terminal in vm.terminals.val:
      r.appendChild(conversation,
                    renderMockTerminal(r, terminal, commandInputId))
    if vm.wantsPassword.val:
      let password = ui(r):
        tdiv(class = "prompt-wrapper"):
          tdiv(class = "password-wrapper"):
            input(class = "password-prompt-input", `type` = "password",
                  placeholder = "Password to continue")
            button(class = "ct-button-sm-primary password-continue-button",
                   `type` = "button"):
              text "Continue"
      r.appendChild(conversation, password)
    if vm.wantsPermission.val:
      let permission = ui(r):
        tdiv(class = "prompt-wrapper"):
          tdiv(class = "header-wrapper"):
            text "How are you"
          tdiv(class = "user-options-wrapper"):
            button(class = "ct-button-sm-secondary user-option",
                   `type` = "button"):
              text "well"
            button(class = "ct-button-sm-secondary user-option",
                   `type` = "button"):
              text "bad"
      r.appendChild(conversation, permission)

  createRenderEffect proc() =
    r.setAttribute(input, "value", vm.inputValue.val)
    r.clearChildren(buttons)
    if not vm.reRecordInProgress.val:
      let newAgent = ui(r):
        button(class = "ct-button-image-md-secondary agent-button agent-icon-button new-agent-instance",
               `type` = "button",
               onclick = proc() =
                 if callbacks.onNewAgentInstance != nil:
                   callbacks.onNewAgentInstance())
      r.appendChild(buttons, newAgent)
    else:
      let progress = ui(r):
        button(class = "ct-button-image-md-secondary agent-button agent-icon-button agent-progress-loading",
               `type` = "button",
               disabled = "disabled")
      r.appendChild(buttons, progress)
    let addFiles = ui(r):
      button(class = "ct-button-md-secondary agent-button agent-add-context-button",
             `type` = "button",
             onclick = proc() =
               if callbacks.onAddFiles != nil:
                 callbacks.onAddFiles()):
        span(class = "add-file-img")
        text "Add files and more"
    r.appendChild(buttons, addFiles)
    let model = ui(r):
      button(class = "ct-button-md-secondary agent-button agent-model-select",
             `type` = "button",
             onclick = proc() =
               if callbacks.onModelSelect != nil:
                 callbacks.onModelSelect()):
        tdiv:
          text "GPT 5"
        tdiv(class = "agent-model-img")
    r.appendChild(buttons, model)
    if not vm.isLoading.val:
      let submit = ui(r):
        button(class = "ct-button-image-md-primary agent-submit-button agent-start-button",
               `type` = "button",
               onclick = proc() =
                 if callbacks.onSubmitPrompt != nil:
                   callbacks.onSubmitPrompt())
      r.appendChild(buttons, submit)
    else:
      let stop = ui(r):
        button(class = "ct-button-image-md-secondary agent-submit-button agent-stop-button",
               `type` = "button",
               onclick = proc() =
                 if callbacks.onStopPrompt != nil:
                   callbacks.onStopPrompt())
      r.appendChild(buttons, stop)

  panel

when defined(js):
  proc readInputValue(node: isonim_dom.Node): string =
    var v: cstring
    {.emit: "`v` = `node`.value || '';".}
    $v

  proc renderAgentActivityPanel*(r: WebRenderer; vm: AgentActivityVM;
      componentId: int; commandInputId: string = "";
      callbacks: AgentActivityCallbacks = AgentActivityCallbacks()):
      isonim_dom.Element =
    var conversation: isonim_dom.Element
    var inputEl: isonim_dom.Element
    var buttons: isonim_dom.Element
    let inputIdValue = inputId(componentId, commandInputId)

    let panel = ui(r):
      tdiv(class = AgentActivityContainerClass):
        tdiv(ref = conversation, class = AgentActivityConversationClass):
          discard
        tdiv(class = AgentActivityInteractionClass):
          textarea(ref = inputEl,
                   `type` = "text",
                   id = inputIdValue,
                   name = "agent-query",
                   placeholder = AgentActivityPlaceholderText,
                   class = AgentActivityInputClass,
                   autocomplete = "off",
                   autocorrect = "off",
                   autocapitalize = "off",
                   rows = "1",
                   spellcheck = "false")
          tdiv(ref = buttons, class = "agent-buttons-container"):
            discard

    isonim_dom.addEventListener(isonim_dom.Node(inputEl), cstring"focus",
      proc(ev: isonim_dom.Event) =
        if callbacks.onFocusInput != nil:
          callbacks.onFocusInput())
    isonim_dom.addEventListener(isonim_dom.Node(inputEl), cstring"input",
      proc(ev: isonim_dom.Event) =
        let v = readInputValue(isonim_dom.Node(inputEl))
        vm.setInputValue(v)
        if callbacks.onInputChange != nil:
          callbacks.onInputChange(v))
    isonim_dom.addEventListener(isonim_dom.Node(inputEl), cstring"keydown",
      proc(ev: isonim_dom.Event) =
        var key: cstring
        var shiftKey: bool
        {.emit: "`key` = `ev`.key || ''; `shiftKey` = !!`ev`.shiftKey;".}
        if key == cstring"Enter" and not shiftKey and not vm.isLoading.val:
          if callbacks.onSubmitPrompt != nil:
            callbacks.onSubmitPrompt())

    proc clearChildren(node: isonim_dom.Element) =
      let asNode = isonim_dom.Node(node)
      while not isonim_dom.isNodeNil(asNode.firstChild):
        discard isonim_dom.removeChild(asNode, asNode.firstChild)

    # Use a small JS builder for the production dynamic subtree.  The
    # mock renderer above remains the authoritative headless structure;
    # this effect mirrors the same class/id/text surface in DOM APIs.
    createRenderEffect proc() =
      clearChildren(conversation)
      for message in vm.messages.val:
        var roleClass = cstring(messageWrapperClass(message.role))
        var avatarClass = cstring(messageAvatarClass(message.role))
        var name = cstring(messageName(message.role))
        var content = cstring(message.content)
        var contentId = cstring(AgentActivityMessageContentClass & "-" & message.id)
        var canceled = message.canceled
        var loading = message.role == aamrAgent and message.isLoading and not message.canceled
        {.emit: """
          const wrap = document.createElement('div');
          wrap.className = `roleClass`;
          const header = document.createElement('div');
          header.className = 'header-wrapper';
          const contentHeader = document.createElement('div');
          contentHeader.className = 'content-header';
          const avatar = document.createElement('div');
          avatar.className = `avatarClass`;
          const nameSpan = document.createElement('span');
          nameSpan.className = `name` === 'author' ? 'user-name' : 'ai-name';
          nameSpan.textContent = `name`;
          if (`canceled`) {
            const canceledSpan = document.createElement('span');
            canceledSpan.textContent = ' (canceled)';
            nameSpan.appendChild(canceledSpan);
          }
          contentHeader.appendChild(avatar);
          contentHeader.appendChild(nameSpan);
          if (`loading`) {
            const status = document.createElement('span');
            status.className = 'ai-status';
            contentHeader.appendChild(status);
          }
          const controls = document.createElement('div');
          controls.className = 'msg-controls';
          const copy = document.createElement('button');
          copy.className = 'ct-button-image-sm-secondary command-palette-copy-button';
          copy.type = 'button';
          controls.appendChild(copy);
          header.appendChild(contentHeader);
          header.appendChild(controls);
          const body = document.createElement('div');
          body.className = 'msg-content';
          body.id = `contentId`;
          body.textContent = `content`;
          wrap.appendChild(header);
          wrap.appendChild(body);
          conversation.appendChild(wrap);
        """.}
        for diff in message.diffs:
          var path = cstring(diff.path)
          var id = cstring(diffEditorId(componentId, diff.id))
          {.emit: """
            const componentWrapper = document.createElement('div');
            componentWrapper.className = 'component-wrapper';
            const diffHeader = document.createElement('div');
            diffHeader.className = 'header-wrapper';
            const task = document.createElement('div');
            task.className = 'task-name';
            task.textContent = `path`;
            diffHeader.appendChild(task);
            const editorWrapper = document.createElement('div');
            editorWrapper.className = 'agent-editor-wrapper';
            const editor = document.createElement('div');
            editor.className = 'agent-editor';
            editor.id = `id`;
            editorWrapper.appendChild(editor);
            componentWrapper.appendChild(diffHeader);
            componentWrapper.appendChild(editorWrapper);
            conversation.appendChild(componentWrapper);
          """.}
      for terminal in vm.terminals.val:
        var terminalId = cstring(terminal.id)
        var shellId = cstring(shellContainerId(terminal.shellId, commandInputId))
        {.emit: """
          const term = document.createElement('div');
          term.className = 'terminal-wrapper';
          const header = document.createElement('div');
          header.className = 'header-wrapper';
          const title = document.createElement('div');
          title.className = 'task-name';
          title.textContent = 'Terminal ' + `terminalId`;
          const controls = document.createElement('div');
          controls.className = 'msg-controls';
          const copy = document.createElement('button');
          copy.className = 'ct-button-image-sm-secondary command-palette-copy-button terminal-copy-button';
          copy.type = 'button';
          const model = document.createElement('div');
          model.className = 'agent-model-img';
          controls.appendChild(copy);
          controls.appendChild(model);
          header.appendChild(title);
          header.appendChild(controls);
          const shell = document.createElement('div');
          shell.id = `shellId`;
          shell.className = 'shell-container';
          term.appendChild(header);
          term.appendChild(shell);
          conversation.appendChild(term);
        """.}
      if vm.wantsPassword.val:
        {.emit: """
          const prompt = document.createElement('div');
          prompt.className = 'prompt-wrapper';
          prompt.innerHTML = '<div class="password-wrapper"><input class="password-prompt-input" type="password" placeholder="Password to continue"><button class="ct-button-sm-primary password-continue-button" type="button">Continue</button></div>';
          conversation.appendChild(prompt);
        """.}
      if vm.wantsPermission.val:
        {.emit: """
          const prompt = document.createElement('div');
          prompt.className = 'prompt-wrapper';
          prompt.innerHTML = '<div class="header-wrapper">How are you</div><div class="user-options-wrapper"><button class="ct-button-sm-secondary user-option" type="button">well</button><button class="ct-button-sm-secondary user-option" type="button">bad</button></div>';
          conversation.appendChild(prompt);
        """.}
      if callbacks.afterDynamicRender != nil:
        callbacks.afterDynamicRender()

    createRenderEffect proc() =
      var currentInputValue = cstring(vm.inputValue.val)
      {.emit: "`inputEl`.value = `currentInputValue`;".}
      clearChildren(buttons)
      var loading = vm.isLoading.val
      var rerecord = vm.reRecordInProgress.val
      {.emit: """
        const makeButton = (className, handler) => {
          const b = document.createElement('button');
          b.className = className;
          b.type = 'button';
          b.addEventListener('click', handler);
          return b;
        };
        if (!`rerecord`) {
          buttons.appendChild(makeButton('ct-button-image-md-secondary agent-button agent-icon-button new-agent-instance', () => {
            if (`callbacks`.onNewAgentInstance) `callbacks`.onNewAgentInstance();
          }));
        } else {
          const b = makeButton('ct-button-image-md-secondary agent-button agent-icon-button agent-progress-loading', () => {});
          b.disabled = true;
          buttons.appendChild(b);
        }
        const add = makeButton('ct-button-md-secondary agent-button agent-add-context-button', () => {
          if (`callbacks`.onAddFiles) `callbacks`.onAddFiles();
        });
        const icon = document.createElement('span');
        icon.className = 'add-file-img';
        add.appendChild(icon);
        add.appendChild(document.createTextNode('Add files and more'));
        buttons.appendChild(add);
        const model = makeButton('ct-button-md-secondary agent-button agent-model-select', () => {
          if (`callbacks`.onModelSelect) `callbacks`.onModelSelect();
        });
        const text = document.createElement('div');
        text.textContent = 'GPT 5';
        const img = document.createElement('div');
        img.className = 'agent-model-img';
        model.appendChild(text);
        model.appendChild(img);
        buttons.appendChild(model);
        buttons.appendChild(makeButton(
          `loading`
            ? 'ct-button-image-md-secondary agent-submit-button agent-stop-button'
            : 'ct-button-image-md-primary agent-submit-button agent-start-button',
          () => {
            if (`loading`) {
              if (`callbacks`.onStopPrompt) `callbacks`.onStopPrompt();
            } else if (`callbacks`.onSubmitPrompt) {
              `callbacks`.onSubmitPrompt();
            }
          }));
      """.}

    panel

  proc mountIsoNimAgentActivityPanel*(container: isonim_dom.Element;
                                      vm: AgentActivityVM;
                                      componentId: int;
                                      commandInputId: string = "";
                                      callbacks: AgentActivityCallbacks =
                                        AgentActivityCallbacks()) =
    let r = WebRenderer()
    let panel = renderAgentActivityPanel(r, vm, componentId,
                                         commandInputId, callbacks)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
