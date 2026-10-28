## viewmodel/host/native_agent_host.nim — PLAT-54. **The Agent Activity
## pane's host for the native front-ends** (the terminal and the GPUI
## window): it owns the desktop's own `AgentActivityVM` and answers every
## request that ViewModel makes of a host, the way the desktop's renderer and
## main process answer them.
##
## | The ViewModel asks                       | The desktop answers            | Here                                       |
## |------------------------------------------|--------------------------------|--------------------------------------------|
## | the session a review names (RV-6)        | `--review-session` → `applyReviewSession` | `loadReviewSession` → the same       |
## | a live session's events                  | `agent_service` → store → `AgenticSessionVM` | a real ACP agent on a worker thread → `agent_service.applyEvents` → the store → `applyAgentSession` |
## | a dataset's shape (AA-3 inspect)         | `index/review_dataset` read    | `agent_session_files.readDatasetShape`      |
## | enter a review over a dataset (AA-3 open)| `vcs.openReviewDataset` → `enterReview` | `readReviewDataset` → `resetReviewEntry` + `enterReview` over the host's VCS ViewModel |
## | open a test's recording (AA-2)           | `createNewSession` / `load-trace-file` | the front-end's own opener (`openRecording`) |
## | the prompt's attachments (the `+` menu)   | a system file dialog → `contextPaths` → `acp-prompt` | the omnibox or the editor → `attachContext` → `contextPaths` → `sendPrompt` |
##
## The live session's events land in the SESSION'S STORE
## (`ReplayDataStore.agentSessions`), which is also what the session tab's
## agent indicator reads (`headless_app/session_tabs.agentOf`), so the tab
## and the pane cannot disagree about whether the agent is working: both
## read the one entry.
##
## What the agent is: the desktop's ACP agent (`codex-acp`), overridable by
## the environment variables a review's session reference already uses —
## `CODETRACER_AGENT_ACP_COMMAND` and `CODETRACER_AGENT_ACP_ARGS`
## (`ct/review_session`).

import std/[json, os, strutils, times]

import isonim/core/[owner, signals]

import ../store/[replay_data_store, types]
import nim_agents
import ../agent_service
import ../viewmodels/[agent_activity_vm, agent_activity_feed, review_entry,
                      review_session, vcs_vm]
import ./agent_session_files
import ./agent_live_worker

export agent_activity_vm, agent_activity_feed

const
  AgentCommandEnvVar* = "CODETRACER_AGENT_ACP_COMMAND"
  AgentArgsEnvVar* = "CODETRACER_AGENT_ACP_ARGS"
  DefaultAgentCommand* = "codex-acp"
    ## The desktop's (`acp_ipc.defaultCmd`).
  NativeAgentTabPrefix* = "native-acp:"
  NewSessionTabNote* = "in a new session tab"
    ## What the status line says a recording opened in (§2.2.4): both of a
    ## test row's buttons open one natively.
  NoCurrentTabReplacementNote* =
    "this window cannot replace its current session yet"
    ## Why `[Open recording]` (the desktop's current-tab open) opened a new
    ## tab natively (DeepReview-GUI.md §2.2.4, the recorded deviation).

type
  OpenRecordingProc* = proc(request: TraceOpenRequest): string {.closure.}
    ## Open a recording the front-end's way; "" or the reason it could not.

  UserTurn = object
    beforeEvent: int
      ## How many of the session's events preceded it.
    message: AgentActivityMessageEntry

  NativeAgentHost* = ref object
    vm*: AgentActivityVM
    store*: ReplayDataStore
      ## The session's store, whose `agentSessions` the live agent writes and
      ## the session tab reads.
    service: CodeTracerAgentService
    vcs*: VCSVM
      ## The front-end's VCS pane's ViewModel, into which an evidence click
      ## enters a review; nil when the front-end has none.
    openRecording*: OpenRecordingProc
    openFile*: proc(path: string) {.closure.}
      ## Opens a review's first file (§7 step 2); nil to open nothing.
    agentCommand*: string
    agentArgs*: seq[string]
    cwd*: string
    worker: AgentLiveWorker
    tabId: string
    pendingPrompts: seq[string]
    userTurns: seq[UserTurn]
    turnRunning: bool
    message*: string
      ## The last thing the host has to tell the user ("" for nothing).
    reviewsOpened*: int
      ## How many evidence clicks entered a review (a suite reads it).
    changed*: bool
      ## Something the pane shows changed since the front-end last painted.
    dispose: proc()

proc recordingOpenedNote*(request: TraceOpenRequest): string =
  ## The status line after a test's recording opened natively: which
  ## recording, that it is in a NEW session tab, and — for `[Open
  ## recording]`, which the desktop opens in the current tab — why.
  let name = extractFilename(request.tracePath.strip(leading = false,
                                                     chars = {'/'}))
  result = "Opened " & (if name.len > 0: name else: request.tracePath) &
           " " & NewSessionTabNote
  if request.policy == topCurrentTab:
    result.add ": " & NoCurrentTabReplacementNote

proc splitArgs(value: string): seq[string] =
  for a in value.splitWhitespace():
    if a.len > 0: result.add a

proc wire(h: NativeAgentHost) =
  let host = h
  h.vm.traceOpen = TraceOpenService(openProc: proc(request: TraceOpenRequest) =
    if host.openRecording.isNil:
      host.message = "this front-end cannot open a recording from the " &
                     "agent's session"
    else:
      let why = host.openRecording(request)
      host.message = if why.len > 0: why else: recordingOpenedNote(request)
    host.changed = true)
  h.vm.reviewOpen = ReviewOpenService(requestProc:
    proc(request: ReviewDatasetRequest) =
      case request.kind
      of rdrInspect:
        host.vm.applyEvidenceDataset(request.datasetPath,
                                     readDatasetShape(request.datasetPath))
      of rdrOpen:
        let read = readReviewDataset(request.datasetPath)
        if not read.ok:
          # The card said it was readable; it is not any more. Say so on the
          # card rather than entering an empty review (§2.1.1).
          host.vm.applyEvidenceDataset(request.datasetPath, EvidenceDataset(
            state: edsUnavailable, message: read.message))
          host.message = read.message
        elif host.vcs.isNil:
          host.message = "this front-end has no VCS pane to review " &
                         request.datasetPath & " in"
        else:
          host.vcs.resetReviewEntry()
          let openFile = host.openFile
          discard host.vcs.enterReview(read.dataset,
            proc(action: VCSOpenAction) =
              if not openFile.isNil and action.path.len > 0:
                openFile(action.path))
          inc host.reviewsOpened
          host.message = "Review: " & read.dataset.title
      host.changed = true)

proc newNativeAgentHost*(store: ReplayDataStore): NativeAgentHost =
  ## A host over `store` — the session's own, so its agent sessions are the
  ## ones the session tab reports.
  result = NativeAgentHost(
    store: store,
    agentCommand: getEnv(AgentCommandEnvVar, DefaultAgentCommand),
    agentArgs: splitArgs(getEnv(AgentArgsEnvVar)),
    cwd: getCurrentDir())
  let h = result
  createRoot proc(dispose: proc()) =
    h.vm = createAgentActivityVM(h.store)
    h.dispose = dispose
  # The service's client is the worker's; this one only names the backend.
  h.service = newCodeTracerAgentService(h.store, AgentClient(backend: abkAcp))
  h.wire()

proc feedRows*(h: NativeAgentHost): seq[AgentFeedRow] =
  if h.isNil: @[] else: h.vm.agentFeed()

# ---------------------------------------------------------------------------
# A recorded session (RV-6)
# ---------------------------------------------------------------------------

proc loadReviewSession*(h: NativeAgentHost; path: string): ReviewSession =
  ## The session `ct review` resolved, into the pane — `applyReviewSession`,
  ## the routine every desktop launch path lands a review's session through.
  result = readReviewSessionFile(path)
  applyReviewSession(h.vm, result)
  h.changed = true

proc loadReviewDataset*(h: NativeAgentHost; path: string): bool =
  ## `--deepreview <dataset>`: enter the review the window opens on.
  let read = readReviewDataset(path)
  if not read.ok:
    h.message = read.message
    return false
  if h.vcs.isNil:
    return false
  let openFile = h.openFile
  discard h.vcs.enterReview(read.dataset, proc(action: VCSOpenAction) =
    if not openFile.isNil and action.path.len > 0:
      openFile(action.path))
  h.changed = true
  true

# ---------------------------------------------------------------------------
# A live session
# ---------------------------------------------------------------------------

proc liveSession*(h: NativeAgentHost): AgentServiceSessionEntry =
  for s in h.store.agentSessions.val.sessions:
    if s.tabId == h.tabId:
      return s

proc project(h: NativeAgentHost) =
  ## The store's entry, with the user's own prompts in the places they were
  ## sent, into the pane.
  let session = h.liveSession()
  let agent = session.activityMessagesOf()
  var messages: seq[AgentActivityMessageEntry] = @[]
  var turn = 0
  for i, m in agent:
    while turn < h.userTurns.len and h.userTurns[turn].beforeEvent <= i:
      messages.add h.userTurns[turn].message
      inc turn
    messages.add m
  while turn < h.userTurns.len:
    messages.add h.userTurns[turn].message
    inc turn
  h.vm.setMessages(messages)
  # The session's lifecycle alone, as the desktop's `applyAgentSession`
  # reads it — and as the session tab's indicator does, so the two agree.
  h.vm.isLoading.val = session.agentSessionRunning()
  h.vm.sessionKey.val = session.tabId
  h.changed = true

proc setLifecycle(h: NativeAgentHost; lifecycle: AgentServiceLifecycle) =
  var state = h.store.agentSessions.val
  for s in state.sessions.mitems:
    if s.tabId == h.tabId:
      s.lifecycle = lifecycle
  h.store.agentSessions.val = state

proc sendNext(h: NativeAgentHost) =
  if h.turnRunning or h.pendingPrompts.len == 0 or h.worker.isNil:
    return
  let text = h.pendingPrompts[0]
  h.pendingPrompts.delete(0)
  h.turnRunning = true
  h.setLifecycle(aslRunning)
  h.worker.command(%*{"t": "prompt", "text": text})
  h.project()

# ---------------------------------------------------------------------------
# The prompt's attachments (the `+` menu, DeepReview-GUI.md §2.2.7)
# ---------------------------------------------------------------------------

proc attachedPathOf(context: string): string =
  ## The file an attachment names: `path`, or the path of an editor
  ## selection's `path:first[-last]`.
  result = context
  let colon = context.rfind(':')
  if colon > 0:
    let tail = context[colon + 1 .. ^1]
    if tail.len > 0 and tail.allCharsInSet({'0' .. '9', '-'}) and
       tail[0] != '-':
      result = context[0 ..< colon]

proc attachContext*(h: NativeAgentHost; context: string;
                    mustExist = true): string =
  ## Attach `context` — a file or folder, a recording, or an editor
  ## selection (`path:first-last`) — to the next prompt, as the desktop's `+`
  ## items add to `contextPaths`. A path typed or chosen in the omnibox must
  ## exist on disk (a relative one is read from the agent's working
  ## directory); an editor selection names the file the editor shows, and is
  ## attached as it is (`mustExist = false`). "" when attached, else why not;
  ## either way the status line has the words (`message`).
  let c = context.strip()
  if c.len == 0:
    result = "type the path of a file or folder to attach"
  else:
    let path = c.attachedPathOf()
    let onDisk = if path.isAbsolute: path else: h.cwd / path
    if mustExist and not fileExists(onDisk) and not dirExists(onDisk):
      result = "cannot attach " & c & ": no such file or folder"
    elif c in h.vm.contextPaths.val:
      result = c & " is attached already"
    else:
      h.vm.contextPaths.val = withContextPath(h.vm.contextPaths.val, c)
      h.message = "Attached " & c & ": it goes with the next prompt"
      h.changed = true
      return ""
  h.message = result
  h.changed = true

proc sendPrompt*(h: NativeAgentHost; text: string): string =
  ## Send `text` to the agent, starting the session first when there is
  ## none — the desktop's `/ai <prompt>` and its prompt field's Enter.
  ## The prompt's attachments go with it, in the desktop's header
  ## (`contextPromptText`), and are cleared, as the desktop clears them.
  ## Returns "" or why nothing was sent.
  let prompt = text.strip()
  if prompt.len == 0:
    return "type a prompt for the agent"
  if h.worker.isNil:
    h.worker = startLiveWorker()
    if h.worker.isNil:
      return "too many agent sessions in this process"
    let session = AgentServiceSessionEntry(
      tabId: NativeAgentTabPrefix & $h.vm.messages.val.len & ":" &
             $int(epochTime()),
      backend: asbAcp, lifecycle: aslConnecting,
      title: (if prompt.len > 48: prompt[0 .. 47] else: prompt),
      prompt: prompt, milestonesTotal: 0)
    h.tabId = session.tabId
    var state = h.store.agentSessions.val
    state.sessions.add session
    state.activeTabId = session.tabId
    h.store.agentSessions.val = state
    h.worker.command(%*{"t": "start", "command": h.agentCommand,
                        "args": h.agentArgs, "cwd": h.cwd})
  h.pendingPrompts.add contextPromptText(prompt, h.vm.contextPaths.val)
  h.vm.clearContextPaths()
  # The user's turn shows at once, where it was sent — the desktop's
  # `updateAgentUi` adds it before the prompt goes out.
  h.userTurns.add UserTurn(
    beforeEvent: h.liveSession().events.len,
    message: AgentActivityMessageEntry(
      id: h.tabId & ":user:" & $h.userTurns.len, content: prompt,
      role: aamrUser, createdAt: epochTime() * 1000.0))
  h.vm.setInputValue("")
  h.project()
  ""

proc stopAgent*(h: NativeAgentHost) =
  ## The prompt's stop control: end the session after its current turn.
  if h.worker.isNil:
    return
  h.pendingPrompts.setLen 0
  h.worker.command(%*{"t": "stop"})

proc poll*(h: NativeAgentHost): bool =
  ## Apply whatever the agent sent since the last call; whether anything
  ## did. Called from the front-end's loop.
  if h.isNil or h.worker.isNil:
    return false
  let reports = h.worker.drain()
  if reports.len == 0:
    return false
  var events: seq[AgentEvent] = @[]
  for r in reports:
    case r{"t"}.getStr("")
    of "started":
      var state = h.store.agentSessions.val
      for s in state.sessions.mitems:
        if s.tabId == h.tabId:
          s.sessionId = r{"sessionId"}.getStr("")
          s.lifecycle = aslRunning
      h.store.agentSessions.val = state
      h.sendNext()
    of "event":
      events.add agentEventFromJson(r{"event"})
    of "turn-ended":
      if events.len > 0:
        h.service.applyEvents(h.tabId, events)
        events.setLen 0
      h.turnRunning = false
      if h.liveSession().lifecycle notin {aslCompleted, aslCancelled, aslError}:
        h.setLifecycle(if h.pendingPrompts.len > 0: aslRunning
                       else: aslCompleted)
      h.sendNext()
    of "error":
      h.message = "agent: " & r{"message"}.getStr("")
      h.turnRunning = false
      h.setLifecycle(aslError)
    of "stopped":
      if h.liveSession().lifecycle in {aslConnecting, aslRunning}:
        h.setLifecycle(aslCancelled)
      h.turnRunning = false
    else:
      discard
  if events.len > 0:
    h.service.applyEvents(h.tabId, events)
  h.project()
  true

proc runFeed*(h: NativeAgentHost; row: AgentFeedRow;
              action: AgentFeedAction): AgentFeedEffect =
  ## A press on a row or one of its buttons, routed through the ViewModel
  ## (`agent_activity_feed.runFeedAction`) and finished here for the two
  ## actions a host owns.
  result = runFeedAction(h.vm, row, action)
  case action.kind
  of faPermission:
    h.message = "the agent asked for no permission this front-end can answer"
  of faOpenDiff:
    h.message = "the agent's file diffs open on the desktop"
  else:
    discard
  h.changed = true

proc close*(h: NativeAgentHost) =
  if h.isNil:
    return
  if not h.worker.isNil:
    h.worker.release(wait = not h.turnRunning)
    h.worker = nil
  if not h.dispose.isNil:
    h.dispose()
    h.dispose = nil
