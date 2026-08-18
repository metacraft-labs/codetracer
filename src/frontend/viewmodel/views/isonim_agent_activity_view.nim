## views/isonim_agent_activity_view.nim
##
## IsoNim DOM-rendering view for the Agent Activity panel.
##
## The panel hosts DeepReview's third pillar.
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1: "The section is part
## of the existing Agent Activity panel.  It is *not* a separate panel and does
## not get its own layout slot."  So the DeepReview section
## (`isonim_agent_activity_deepreview_view`) is rendered *inside* this panel's
## container rather than as a component of its own, and it paints only while a
## review is active — a normal debugging session's Agent Activity panel is
## unchanged (the section's container carries `hidden`).

import std/tables

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/agent_activity_vm
import ../viewmodels/agent_activity_deepreview_vm
import isonim_agent_activity_deepreview_view

const AgentActivityContainerClass* = "component-container agent-ha-container"
const AgentActivityConversationClass* = "agent-com"
const AgentActivityInteractionClass* = "agent-interaction"
const AgentActivityInputClass* = "mousetrap agent-command-input"
const AgentActivityInputPrefix* = "agent-query-text"
const AgentActivityMessageContentClass* = "msg-content"
const AgentActivityDiffEditorPrefix* = "diff-editor"
const AgentActivityTerminalShellPrefix* = "shellComponent-"
const AgentActivityPlaceholderText* = "Ask anything"

const AgentActivitySessionNoticeClass* = "agent-session-notice"
  ## RV-6 — the panel's explicit statement about a review's agent session.
  ##
  ## It paints only when `AgentActivityVM.sessionNotice` is non-empty, which
  ## is every case except "here is the conversation" and "this review has no
  ## session".  DeepReview-GUI.md §2.1: when the backend cannot resolve the
  ## referenced session, "the panel says so explicitly.  It must not silently
  ## render an empty session, which reads as 'the agent did nothing'."

const AgentActivityDeepReviewHostClass* = "agent-ha-deepreview-host"
  ## Wrapper the DeepReview section is rendered into.  It carries `hidden`
  ## outside a review so the host contributes neither height nor the
  ## container's flex gap to a normal debugging session's panel.

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

proc invokeFocus(callbacks: AgentActivityCallbacks) =
  if callbacks.onFocusInput != nil:
    callbacks.onFocusInput()

proc invokeInputChange(vm: AgentActivityVM; callbacks: AgentActivityCallbacks;
                       value: string) =
  vm.setInputValue(value)
  if callbacks.onInputChange != nil:
    callbacks.onInputChange(value)

proc invokeSubmit(callbacks: AgentActivityCallbacks) =
  if callbacks.onSubmitPrompt != nil:
    callbacks.onSubmitPrompt()

proc invokeStop(callbacks: AgentActivityCallbacks) =
  if callbacks.onStopPrompt != nil:
    callbacks.onStopPrompt()

proc invokeNewAgent(callbacks: AgentActivityCallbacks) =
  if callbacks.onNewAgentInstance != nil:
    callbacks.onNewAgentInstance()

proc invokeAddFiles(callbacks: AgentActivityCallbacks) =
  if callbacks.onAddFiles != nil:
    callbacks.onAddFiles()

proc invokeModelSelect(callbacks: AgentActivityCallbacks) =
  if callbacks.onModelSelect != nil:
    callbacks.onModelSelect()

proc appendRenderedChild(r: MockRenderer; host, child: MockNode) =
  ## Dynamic collection hosts are stable, but their rows are rebuilt from VM
  ## snapshots. The row markup itself stays declarative in helper ui blocks.
  r.appendChild(host, child)

when defined(js):
  proc inputValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc setInputValue(node: isonim_dom.Element; value: cstring) {.importjs: "#.value = #".}
  proc eventKey(ev: isonim_dom.Event): cstring {.importjs: "(#.key || '')".}
  proc shiftKey(ev: isonim_dom.Event): bool {.importjs: "!!#.shiftKey".}

  proc appendRenderedChild(r: WebRenderer; host, child: isonim_dom.Element) =
    ## Dynamic collection hosts are stable, but their rows are rebuilt from VM
    ## snapshots. appendChild is the browser interop needed to attach a
    ## finished IsoNim row node to that host.
    r.appendChild(host, child)

  proc readInputValue(node: isonim_dom.Node): string =
    $node.inputValue()

  proc setInputElementValue(node: isonim_dom.Element; value: string) =
    node.setInputValue(cstring(value))

proc syncInputValue(r: MockRenderer; input: MockNode; value: string) =
  r.setAttribute(input, "value", value)

when defined(js):
  proc syncInputValue(r: WebRenderer; input: isonim_dom.Element; value: string) =
    input.setInputElementValue(value)

proc attachInputEvents(r: MockRenderer; input: MockNode; vm: AgentActivityVM;
                       callbacks: AgentActivityCallbacks) =
  r.addEventListener(input, "focus", proc() =
    callbacks.invokeFocus())
  r.addEventListener(input, "input", proc() =
    vm.invokeInputChange(callbacks, input.attributes.getOrDefault("value", "")))
  r.addEventListener(input, "keydown", proc() =
    callbacks.invokeSubmit())

when defined(js):
  proc attachInputEvents(r: WebRenderer; input: isonim_dom.Element;
                         vm: AgentActivityVM;
                         callbacks: AgentActivityCallbacks) =
    ## Input and keydown need native DOM event fields/value; WebRenderer's
    ## declarative event adapter intentionally exposes only proc().
    isonim_dom.addEventListener(isonim_dom.Node(input), cstring"focus",
      proc(ev: isonim_dom.Event) =
        callbacks.invokeFocus())
    isonim_dom.addEventListener(isonim_dom.Node(input), cstring"input",
      proc(ev: isonim_dom.Event) =
        vm.invokeInputChange(callbacks, readInputValue(isonim_dom.Node(input))))
    isonim_dom.addEventListener(isonim_dom.Node(input), cstring"keydown",
      proc(ev: isonim_dom.Event) =
        if ev.eventKey() == cstring"Enter" and not ev.shiftKey() and not vm.isLoading.val:
          callbacks.invokeSubmit())

proc renderMessage[R](r: R; componentId: int;
                      message: AgentActivityMessageEntry): auto =
  let contentId = AgentActivityMessageContentClass & "-" & message.id
  ui(r):
    tdiv(class = messageWrapperClass(message.role)):
      tdiv(class = "header-wrapper"):
        tdiv(class = "content-header"):
          tdiv(class = messageAvatarClass(message.role))
          span(class = (if message.role == aamrAgent: "ai-name" else: "user-name")):
            text messageName(message.role)
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
        text message.content
      for diffValue in message.diffs:
        let diff = diffValue
        tdiv(class = "component-wrapper"):
          tdiv(class = "header-wrapper"):
            tdiv(class = "task-name"):
              text diff.path
          tdiv(class = "agent-editor-wrapper"):
            tdiv(class = "agent-editor",
                 id = diffEditorId(componentId, diff.id))

proc renderTerminal[R](r: R; terminal: AgentActivityTerminalEntry;
                       commandInputId: string): auto =
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

proc renderPasswordPrompt[R](r: R): auto =
  ui(r):
    tdiv(class = "prompt-wrapper"):
      tdiv(class = "password-wrapper"):
        input(class = "password-prompt-input", `type` = "password",
              placeholder = "Password to continue")
        button(class = "ct-button-sm-primary password-continue-button",
               `type` = "button"):
          text "Continue"

proc renderPermissionPrompt[R](r: R): auto =
  ui(r):
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

proc renderNewAgentButton[R](r: R; callbacks: AgentActivityCallbacks): auto =
  ui(r):
    button(class = "ct-button-image-md-secondary agent-button agent-icon-button new-agent-instance",
           `type` = "button",
           onclick = proc() = callbacks.invokeNewAgent())

proc renderProgressButton[R](r: R): auto =
  ui(r):
    button(class = "ct-button-image-md-secondary agent-button agent-icon-button agent-progress-loading",
           `type` = "button",
           disabled = "disabled")

proc renderAddFilesButton[R](r: R; callbacks: AgentActivityCallbacks): auto =
  ui(r):
    button(class = "ct-button-md-secondary agent-button agent-add-context-button",
           `type` = "button",
           onclick = proc() = callbacks.invokeAddFiles()):
      span(class = "add-file-img")
      text "Add files and more"

proc renderModelButton[R](r: R; callbacks: AgentActivityCallbacks): auto =
  ui(r):
    button(class = "ct-button-md-secondary agent-button agent-model-select",
           `type` = "button",
           onclick = proc() = callbacks.invokeModelSelect()):
      tdiv:
        text "GPT 5"
      tdiv(class = "agent-model-img")

proc renderSessionNotice[R](r: R; notice: string): auto =
  ## One line explaining the state of the review's agent session.
  ##
  ## Deliberately a plain block rather than a message row: it is CodeTracer
  ## speaking, not the agent, and styling it as a conversation turn would
  ## attribute the sentence to the agent.
  ui(r):
    tdiv(class = AgentActivitySessionNoticeClass):
      text notice

proc renderSubmitButton[R](r: R; callbacks: AgentActivityCallbacks): auto =
  ui(r):
    button(class = "ct-button-image-md-primary agent-submit-button agent-start-button",
           `type` = "button",
           onclick = proc() = callbacks.invokeSubmit())

proc renderStopButton[R](r: R; callbacks: AgentActivityCallbacks): auto =
  ui(r):
    button(class = "ct-button-image-md-secondary agent-submit-button agent-stop-button",
           `type` = "button",
           onclick = proc() = callbacks.invokeStop())

proc renderAgentActivityPanelImpl[R](r: R; vm: AgentActivityVM;
    componentId: int; commandInputId: string;
    callbacks: AgentActivityCallbacks;
    deepReviewVm: AgentActivityDeepReviewVM;
    deepReviewCallbacks: AgentActivityDeepReviewCallbacks): auto =
  var conversation: typeof(r.createElement("div"))
  var input: typeof(r.createElement("textarea"))
  var buttons: typeof(r.createElement("div"))
  var deepReviewHost: typeof(r.createElement("div"))
  let inputIdValue = inputId(componentId, commandInputId)

  let panel = ui(r):
    tdiv(class = AgentActivityContainerClass):
      # RV-6, amended §2.1: **the session is primary, the roll-up is
      # secondary.**  The conversation therefore comes first in the panel and
      # the DeepReview roll-up sits beneath it — previously the order was the
      # other way round, which put a static coverage summary above the thing
      # the reviewer opened the review to read.
      tdiv(ref = conversation, class = AgentActivityConversationClass)
      tdiv(ref = deepReviewHost, class = AgentActivityDeepReviewHostClass)
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
        tdiv(ref = buttons, class = "agent-buttons-container")

  r.attachInputEvents(input, vm, callbacks)

  # DeepReview's third pillar (DeepReview-GUI.md §2.1).  Rendered once, not
  # inside a render effect: the section owns reactive effects of its own and
  # rebuilding it on every review-state change would re-create them.  It hides
  # itself (`sectionVisible`) when no review is active, so a normal debugging
  # session sees an empty host div and nothing else.
  if deepReviewVm != nil:
    r.appendRenderedChild(
      deepReviewHost,
      renderAgentActivityDeepReviewPanel(r, deepReviewVm, deepReviewCallbacks))
    createRenderEffect proc() =
      r.setAttribute(
        deepReviewHost, "class",
        if deepReviewVm.sectionVisible.val:
          AgentActivityDeepReviewHostClass
        else:
          AgentActivityDeepReviewHostClass & " hidden")

  createRenderEffect proc() =
    r.clearChildren(conversation)
    # First, and outside the message list: why this conversation looks the way
    # it does.  A loaded-but-empty session, a pruned one and an agent that
    # cannot replay sessions all render an identical empty list, so the
    # sentence is the only thing that tells them apart (§2.1).
    if vm.sessionNotice.val.len > 0:
      r.appendRenderedChild(
        conversation, renderSessionNotice(r, vm.sessionNotice.val))
    for message in vm.messages.val:
      r.appendRenderedChild(conversation, renderMessage(r, componentId, message))
    for terminal in vm.terminals.val:
      r.appendRenderedChild(
        conversation,
        renderTerminal(r, terminal, commandInputId))
    if vm.wantsPassword.val:
      r.appendRenderedChild(conversation, renderPasswordPrompt(r))
    if vm.wantsPermission.val:
      r.appendRenderedChild(conversation, renderPermissionPrompt(r))
    if callbacks.afterDynamicRender != nil:
      callbacks.afterDynamicRender()

  createRenderEffect proc() =
    r.syncInputValue(input, vm.inputValue.val)
    r.clearChildren(buttons)
    if not vm.reRecordInProgress.val:
      r.appendRenderedChild(buttons, renderNewAgentButton(r, callbacks))
    else:
      r.appendRenderedChild(buttons, renderProgressButton(r))
    r.appendRenderedChild(buttons, renderAddFilesButton(r, callbacks))
    r.appendRenderedChild(buttons, renderModelButton(r, callbacks))
    if not vm.isLoading.val:
      r.appendRenderedChild(buttons, renderSubmitButton(r, callbacks))
    else:
      r.appendRenderedChild(buttons, renderStopButton(r, callbacks))

  panel

proc renderAgentActivityPanel*(r: MockRenderer; vm: AgentActivityVM;
    componentId: int; commandInputId: string = "";
    callbacks: AgentActivityCallbacks = AgentActivityCallbacks();
    deepReviewVm: AgentActivityDeepReviewVM = nil;
    deepReviewCallbacks: AgentActivityDeepReviewCallbacks =
      AgentActivityDeepReviewCallbacks()): MockNode =
  renderAgentActivityPanelImpl(r, vm, componentId, commandInputId, callbacks,
                               deepReviewVm, deepReviewCallbacks)

when defined(js):
  proc renderAgentActivityPanel*(r: WebRenderer; vm: AgentActivityVM;
      componentId: int; commandInputId: string = "";
      callbacks: AgentActivityCallbacks = AgentActivityCallbacks();
      deepReviewVm: AgentActivityDeepReviewVM = nil;
      deepReviewCallbacks: AgentActivityDeepReviewCallbacks =
        AgentActivityDeepReviewCallbacks()):
      isonim_dom.Element =
    renderAgentActivityPanelImpl(r, vm, componentId, commandInputId, callbacks,
                                 deepReviewVm, deepReviewCallbacks)

  proc mountIsoNimAgentActivityPanel*(container: isonim_dom.Element;
                                      vm: AgentActivityVM;
                                      componentId: int;
                                      commandInputId: string = "";
                                      callbacks: AgentActivityCallbacks =
                                        AgentActivityCallbacks();
                                      deepReviewVm:
                                        AgentActivityDeepReviewVM = nil;
                                      deepReviewCallbacks:
                                        AgentActivityDeepReviewCallbacks =
                                          AgentActivityDeepReviewCallbacks()) =
    let r = WebRenderer()
    let panel = renderAgentActivityPanel(r, vm, componentId,
                                         commandInputId, callbacks,
                                         deepReviewVm, deepReviewCallbacks)
    # External mount interop: the AgentActivity component owns this container.
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
