## views/isonim_agent_activity_view.nim
##
## IsoNim DOM-rendering view for the Agent Activity panel.
##
## The panel is DeepReview's third pillar, and what it shows in a review is
## **the agent session that produced it** —
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.  It used to render a
## static DeepReview roll-up (a coverage summary, a test-results row, a
## per-file coverage table and a notification feed) beneath the conversation;
## AA-1 removed that outright, because it restated facts the VCS panel already
## carries and filled the panel with a summary when what the reviewer came for
## is the session itself ("There is no 'DeepReview section' in this panel").

import std/tables

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/agent_activity_vm

const AgentActivityContainerClass* = "component-container agent-ha-container"
const AgentActivityConversationClass* = "agent-com"
const AgentActivityInteractionClass* = "agent-interaction"
const AgentActivityInputClass* = "mousetrap agent-command-input"
const AgentActivityInputPrefix* = "agent-query-text"
const AgentActivityMessageContentClass* = "msg-content"
const AgentActivityDiffEditorPrefix* = "diff-editor"
const AgentActivityTerminalShellPrefix* = "shellComponent-"
const AgentActivityPlaceholderText* = "Ask anything"

const AgentActivityTestRunClass* = "agent-test-run"
  ## AA-2 — a `ct test` execution, rendered as a summary of the run *in place
  ## of* the raw runner output (DeepReview-GUI.md §2.1.2).
  ##
  ## The card takes the feed position of the message whose content carried the
  ## runner's events, so a run stays where the agent produced it.  The message
  ## itself is not deleted from the model — it is simply not painted as text,
  ## which is what "in place of raw runner output" means.

const AgentActivityTestRunPrefix* = "agent-test-run-"
const AgentActivityTestRowClass* = "agent-test-row"
const AgentActivityTestRowPrefix* = "agent-test-row-"
const AgentActivityOpenRecordingClass* = "agent-test-row-open-recording"
  ## The drill-down affordance.  §2.1.2: it exists **only** where a test has a
  ## recording — "not an affordance that fails when used" — so this class is
  ## emitted under `TestRunRow.hasRecording` and nowhere else.
const AgentActivityRecordingFailedClass* = "agent-test-row-recording-failed"
  ## The other half of the same rule: a recording that failed before a trace
  ## existed says so, and still offers nothing to open.

const AgentActivitySessionNoticeClass* = "agent-session-notice"
  ## RV-6 — the panel's explicit statement about a review's agent session.
  ##
  ## It paints only when `AgentActivityVM.sessionNotice` is non-empty, which
  ## is every case except "here is the conversation" and "this review has no
  ## session".  DeepReview-GUI.md §2.1: when the backend cannot resolve the
  ## referenced session, "the panel says so explicitly.  It must not silently
  ## render an empty session, which reads as 'the agent did nothing'."

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
    onOpenTestRecording*: proc(anchorId, testId: string;
                               policy: TraceOpenPolicy)
      ## AA-2 — the host's hook for "the reviewer clicked into a recording".
      ##
      ## The view does **not** decide whether a recording exists; the VM does
      ## (`AgentActivityVM.openTestRecording`), and the view calls it.  This
      ## callback exists only so a host can observe the drill-down, not so it
      ## can implement a second one — §2.1.2 requires the *existing*
      ## trace-opening path, which `trace_open.nim` already is.

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

proc testRunId*(anchorId: string): string =
  AgentActivityTestRunPrefix & anchorId

proc testRowId*(anchorId, testId: string): string =
  AgentActivityTestRowPrefix & anchorId & "-" & testId

proc testRunStateClass*(summary: TestRunSummary): string =
  ## The card's overall state, as a class a stylesheet and a test can both
  ## read.  Deliberately three-valued rather than boolean: "running" is not a
  ## kind of failure, and an empty run is not a kind of success.
  if summary.inProgress:
    AgentActivityTestRunClass & " " & AgentActivityTestRunClass & "-running"
  elif summary.failed > 0 or summary.errored > 0:
    AgentActivityTestRunClass & " " & AgentActivityTestRunClass & "-failed"
  else:
    AgentActivityTestRunClass & " " & AgentActivityTestRunClass & "-passed"

proc testRowClass*(row: TestRunRow): string =
  AgentActivityTestRowClass & " " & AgentActivityTestRowPrefix & $row.outcome

proc testRunTitle*(summary: TestRunSummary): string =
  ## What the card calls itself.
  ##
  ## The runner's own reported command when there is one, because that is the
  ## thing the reviewer actually asked for; otherwise the provider's id.  Never
  ## a reconstructed command line — a command CodeTracer invented would read as
  ## one that ran.
  if summary.commandLine.len > 0:
    summary.commandLine
  elif summary.providerId.len > 0:
    summary.providerId
  else:
    "ct test"

proc testRowDetailText*(row: TestRunRow): string =
  ## The line an expanded test shows: its status and how long it took.
  ## §2.1.2: "an individual test can be expanded to its status, duration and
  ## captured output."  A duration of zero is omitted rather than printed,
  ## for the same reason a zero count is: it is not a measurement.
  result = "Status: " & $row.outcome
  if row.durationMs > 0:
    result.add " · Duration: " & formatDurationMs(row.durationMs)

proc renderTestRow[R](r: R; vm: AgentActivityVM; anchorId: string;
                      rowValue: TestRunRow;
                      callbacks: AgentActivityCallbacks): auto =
  let row = rowValue
  let expanded = vm.isTestExpanded(anchorId, row.testId)
  let testId = row.testId
  proc open(policy: TraceOpenPolicy) =
    # The VM is the single gate: it refuses a row with no recording even if a
    # stale rendering somehow offered one.  The host callback is notified only
    # when something was actually opened.
    if vm.openTestRecording(anchorId, testId, policy) and
       callbacks.onOpenTestRecording != nil:
      callbacks.onOpenTestRecording(anchorId, testId, policy)
  ui(r):
    tdiv(class = testRowClass(row), id = testRowId(anchorId, row.testId)):
      tdiv(class = "agent-test-row-header",
           onclick = proc() = vm.toggleTest(anchorId, testId)):
        span(class = "agent-test-row-status"):
          text $row.outcome
        span(class = "agent-test-row-name"):
          text row.name
        if row.durationMs > 0:
          span(class = "agent-test-row-duration"):
            text formatDurationMs(row.durationMs)
      # §2.1.2: the affordance exists only where the recording does.  A test
      # that was never recorded, and a recording that failed before producing
      # a trace, both fall through here and render no button at all.
      if row.hasRecording:
        tdiv(class = "agent-test-row-actions"):
          button(class = "ct-button-sm-secondary " &
                   AgentActivityOpenRecordingClass,
                 `type` = "button",
                 onclick = proc() = open(topCurrentTab)):
            text "Open recording"
          button(class = "ct-button-sm-secondary " &
                   AgentActivityOpenRecordingClass & "-new-tab",
                 `type` = "button",
                 onclick = proc() = open(topNewTab)):
            text "Open in new tab"
      if expanded:
        tdiv(class = "agent-test-row-details"):
          tdiv(class = "agent-test-row-detail"):
            text testRowDetailText(row)
          if row.recordingFailed:
            tdiv(class = AgentActivityRecordingFailedClass):
              text "Recording failed before a trace was produced; " &
                "there is no recording to open."
          for diagnosticValue in row.diagnostics:
            let diagnostic = diagnosticValue
            tdiv(class = "agent-test-row-diagnostic " &
                   AgentActivityTestRowPrefix & "diagnostic-" &
                   diagnostic.severity):
              text diagnostic.message
          if row.output.len > 0:
            pre(class = "agent-test-row-output"):
              text row.output

proc renderTestRunTail[R](r: R; summary: TestRunSummary): auto =
  ## Run-level diagnostics and the non-event half of the runner's stdout.
  ##
  ## §2.1.2 requires both to be reachable when recording failed, and they are
  ## the only place a failure with *no test row* — a missing recorder binary,
  ## say — can be read at all.
  ui(r):
    tdiv(class = "agent-test-run-tail"):
      for diagnosticValue in summary.diagnostics:
        let diagnostic = diagnosticValue
        tdiv(class = "agent-test-run-diagnostic"):
          text diagnostic.message
      if summary.frameworkOutput.len > 0:
        pre(class = "agent-test-run-output"):
          text summary.frameworkOutput

proc renderTestRun[R](r: R; vm: AgentActivityVM; entry: AgentTestRunEntry;
                      callbacks: AgentActivityCallbacks): auto =
  let summary = entry.summary
  let anchorId = entry.anchorId
  let expanded = vm.isTestRunExpanded(anchorId)
  var body: typeof(r.createElement("div"))
  let card = ui(r):
    tdiv(class = testRunStateClass(summary), id = testRunId(anchorId)):
      tdiv(class = "agent-test-run-header",
           onclick = proc() = vm.toggleTestRun(anchorId)):
        span(class = "agent-test-run-toggle"):
          text (if expanded: "▾" else: "▸")
        span(class = "agent-test-run-title"):
          text testRunTitle(summary)
        span(class = "agent-test-run-status"):
          text summaryText(summary)
      tdiv(ref = body, class = "agent-test-run-body")
  # The rows are appended rather than declared inline because the `ui` DSL
  # nests *tags*, not calls to other render procs — a bare call inside a `ui`
  # block builds a node nothing attaches.  Same reason the conversation host
  # itself is filled with `appendRenderedChild`.
  if expanded:
    for rowValue in summary.rows:
      r.appendRenderedChild(
        body, renderTestRow(r, vm, anchorId, rowValue, callbacks))
    r.appendRenderedChild(body, renderTestRunTail(r, summary))
  card

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
    callbacks: AgentActivityCallbacks): auto =
  var conversation: typeof(r.createElement("div"))
  var input: typeof(r.createElement("textarea"))
  var buttons: typeof(r.createElement("div"))
  let inputIdValue = inputId(componentId, commandInputId)

  let panel = ui(r):
    tdiv(class = AgentActivityContainerClass):
      # §2.1: the session is what this panel shows in a review, so the
      # conversation is the panel's whole body above the prompt.  Nothing sits
      # between them any more — the roll-up that used to went with AA-1.
      tdiv(ref = conversation, class = AgentActivityConversationClass)
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
      # AA-2: a message whose content carried the runner's event stream is
      # painted as the run's summary card *instead of* as raw output
      # (§2.1.2).  The lookup is by the message's own id, so the card lands in
      # the feed position the run happened in and everything around it renders
      # unchanged.
      let runIndex = vm.testRunIndex(message.id)
      if runIndex >= 0:
        r.appendRenderedChild(
          conversation,
          renderTestRun(r, vm, vm.testRuns.val[runIndex], callbacks))
      else:
        r.appendRenderedChild(
          conversation, renderMessage(r, componentId, message))
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
    callbacks: AgentActivityCallbacks = AgentActivityCallbacks()): MockNode =
  renderAgentActivityPanelImpl(r, vm, componentId, commandInputId, callbacks)

when defined(js):
  proc renderAgentActivityPanel*(r: WebRenderer; vm: AgentActivityVM;
      componentId: int; commandInputId: string = "";
      callbacks: AgentActivityCallbacks = AgentActivityCallbacks()):
      isonim_dom.Element =
    renderAgentActivityPanelImpl(r, vm, componentId, commandInputId, callbacks)

  proc mountIsoNimAgentActivityPanel*(container: isonim_dom.Element;
                                      vm: AgentActivityVM;
                                      componentId: int;
                                      commandInputId: string = "";
                                      callbacks: AgentActivityCallbacks =
                                        AgentActivityCallbacks()) =
    let r = WebRenderer()
    let panel = renderAgentActivityPanel(r, vm, componentId,
                                         commandInputId, callbacks)
    # External mount interop: the AgentActivity component owns this container.
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
