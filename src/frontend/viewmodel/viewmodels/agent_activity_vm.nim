## viewmodels/agent_activity_vm.nim
##
## AgentActivityVM — ViewModel for the ACP Agent Activity panel.
##
## The legacy ``AgentActivityComponent`` keeps owning ACP IPC/session
## state, but its Karax ``render`` path is bypassed.  This VM carries
## the platform-neutral snapshot that the IsoNim view renders: ordered
## conversation messages, terminal shell placeholders, prompt flags,
## input value, loading state, and re-record button state.

import std/options

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]
import evidence_call_vm, review_open, test_run_summary_vm, trace_open

export evidence_call_vm, review_open, test_run_summary_vm, trace_open

type
  AgentTestRunEntry* = object
    ## AA-2 — a `ct test` execution the session feed renders as a summary
    ## card *in place of* the raw runner output.
    ##
    ## The message it replaces stays in `messages`: it is the feed's ordering
    ## spine, and anchoring the card to its id keeps a run in the position the
    ## agent produced it in without the message list having to know what a test
    ## run is.  `store/types.nim` is "intentionally independent" of everything
    ## (see its header), so the runner's vocabulary is deliberately kept out
    ## of `AgentActivityMessageEntry` and carried alongside it instead.
    anchorId*: string
    summary*: TestRunSummary

  EvidenceDatasetEntry* = object
    ## AA-3 — one answer from the host about one dataset path.
    datasetPath*: string
    dataset*: EvidenceDataset

  AgentActivityVM* = ref object of ViewModel
    store*: ReplayDataStore

    traceOpen*: TraceOpenService
      ## AA-2 — how this panel opens the recording of a test.  The *existing*
      ## trace-opening path (`trace_open.nim`), wired by the host to the same
      ## IPC the welcome screen and the tab model already use.  Nil in a
      ## headless test, and `openTestRecording` reports honestly when it is.

    reviewOpen*: ReviewOpenService
      ## AA-3 — how this panel reads the review dataset an evidence tool call
      ## produced.  The *ordinary* review path (`review_open.nim`), wired by
      ## the host to the same read `ct review <PATH>` performs.  Nil in a
      ## headless test, in which case no dataset is ever inspected, every
      ## evidence card stays at `edsUnknown`, and none offers an affordance —
      ## the honest answer for a panel with no host that can read files.

    messages*: Signal[seq[AgentActivityMessageEntry]]
    testRuns*: Signal[seq[AgentTestRunEntry]]
      ## Derived from `messages` on every `setMessages`, so a live session, a
      ## replayed review session and the legacy Karax mirror all get the same
      ## rendering from the same projection with no third path to keep in
      ## step.
    expandedTestRuns*: Signal[seq[string]]
      ## Anchor ids of runs the reviewer has expanded.  §2.1.2: "The summary
      ## is **drillable**".  Collapsed is the default: a run summary that
      ## opened to fifty rows would bury the conversation it sits in.
    expandedTests*: Signal[seq[string]]
      ## `expansionKey(anchorId, testId)` for each expanded test row.
    evidenceCalls*: Signal[seq[EvidenceCall]]
      ## AA-3 — the session's evidence handoffs, re-derived from `messages` on
      ## every `setMessages` for the same reason `testRuns` is: one projection,
      ## no opt-in, and no third path for the legacy carrier to drift down.
      ##
      ## The `dataset` field of each entry is **not** filled in here — a
      ## projection cannot read a file.  `evidenceCallFor` merges
      ## `evidenceDatasets` in on the way out.
    evidenceDatasets*: Signal[seq[EvidenceDatasetEntry]]
      ## What the host found out about each dataset *path*.
      ##
      ## Keyed by path rather than by anchor because it is a fact about the
      ## file: a session that collected once and handed over once names the
      ## same dataset twice, and reading it twice to tell the reviewer the
      ## same thing would be work done for no answer.  It survives
      ## `setMessages` — a re-synced conversation must not throw away what has
      ## already been read and start the cards blank again.
    terminals*: Signal[seq[AgentActivityTerminalEntry]]
    inputValue*: Signal[string]
    isLoading*: Signal[bool]
    reRecordInProgress*: Signal[bool]
    wantsPassword*: Signal[bool]
    wantsPermission*: Signal[bool]
    sessionKey*: Signal[string]
    sessionNotice*: Signal[string]
      ## RV-6 — an explicit statement about *why* this panel is showing the
      ## conversation it is showing, or "" when the conversation speaks for
      ## itself.
      ##
      ## It exists because the panel previously had no state between "here
      ## are the messages" and nothing at all: a review whose session had
      ## been pruned, or whose agent cannot replay sessions, rendered an
      ## empty `.agent-com` that reads as "the agent did nothing".
      ## DeepReview-GUI.md §2.1 names that a defect — "it must not silently
      ## render an empty session".  A loaded session that genuinely carries
      ## nothing also sets it, for the same reason.

    messageCount*: Memo[int]
    terminalCount*: Memo[int]
    hasMessages*: Memo[bool]
    hasSessionNotice*: Memo[bool]
    testRunCount*: Memo[int]
    evidenceCallCount*: Memo[int]

proc `==`*(a, b: AgentTestRunEntry): bool {.noSideEffect.} =
  a.anchorId == b.anchorId and a.summary == b.summary

proc `==`*(a, b: EvidenceDatasetEntry): bool {.noSideEffect.} =
  a.datasetPath == b.datasetPath and a.dataset == b.dataset

proc projectTestRuns*(messages: openArray[AgentActivityMessageEntry]):
    seq[AgentTestRunEntry] =
  ## Find the `ct test` executions in a conversation.
  ##
  ## Pure, so the recognition rule is assertable without a VM at all.  A
  ## message becomes a run only when its content actually contains runner
  ## events (`parseTestRun` declines otherwise), which is what keeps a message
  ## that merely *mentions* `ct test` from turning into a summary card
  ## claiming a run happened — the fabricated-result failure mode this
  ## milestone family exists to prevent.
  result = @[]
  for message in messages:
    if message.content.len == 0:
      continue
    let summary = parseTestRun(message.content)
    if summary.isSome:
      result.add AgentTestRunEntry(
        anchorId: message.id, summary: summary.get)

proc expansionKey*(anchorId, testId: string): string {.noSideEffect.} =
  ## The identity of one expandable test row.
  ##
  ## Two runs in one session can execute the same test, so neither half alone
  ## identifies a row; the separator is a character no catalog id can contain
  ## (`normalizeIdComponent` collapses whitespace and never emits control
  ## characters), so the pair cannot alias.
  anchorId & "\x1f" & testId

proc datasetIndex(vm: AgentActivityVM; datasetPath: string): int =
  for i, entry in vm.evidenceDatasets.val:
    if entry.datasetPath == datasetPath:
      return i
  -1

proc requestEvidenceInspections(vm: AgentActivityVM) =
  ## Ask the host for the shape of every dataset an evidence call names and
  ## nothing has looked at yet.
  ##
  ## §2.1.1 wants the card to name "enough of its shape (file count, the
  ## reviewed commit) to be recognisable without opening it", which is a fact
  ## that can only come from the file, so it is fetched as soon as a card
  ## exists rather than on the click that needs it.
  ##
  ## Only a **completed** call is inspected: a collect that has not reported
  ## may not have written its output yet, and reporting "missing" about a file
  ## that is merely not finished would be a wrong statement rather than a
  ## missing one.
  ##
  ## A placeholder entry is recorded *before* the request goes out, so a
  ## conversation re-synced on every render (which the legacy carrier does)
  ## asks once per path rather than once per render.
  for call in vm.evidenceCalls.val:
    if call.state != ecsCompleted or call.datasetPath.len == 0:
      continue
    if vm.datasetIndex(call.datasetPath) >= 0:
      continue
    var entries = vm.evidenceDatasets.val
    entries.add EvidenceDatasetEntry(
      datasetPath: call.datasetPath,
      dataset: EvidenceDataset(state: edsUnknown))
    vm.evidenceDatasets.val = entries
    vm.reviewOpen.requestDataset ReviewDatasetRequest(
      anchorId: call.anchorId,
      datasetPath: call.datasetPath,
      kind: rdrInspect)

proc retryPendingEvidenceInspections*(vm: AgentActivityVM) =
  ## Re-issue the requests that were recorded while there was no host to
  ## answer them.
  ##
  ## `requestEvidenceInspections` is deliberately a one-shot per path, so a
  ## conversation re-synced on every render asks once.  That leaves one hole:
  ## a panel whose VM is built *before* the host installs the service records
  ## its placeholders, sends nothing, and its cards would sit at "Reading …"
  ## for the life of the window.  The installer calls this after back-filling,
  ## which is the only moment at which the answer can change.
  ##
  ## Only entries still at `edsUnknown` are retried; a path already answered —
  ## readable or not — is not read again.
  for entry in vm.evidenceDatasets.val:
    if entry.dataset.state != edsUnknown:
      continue
    for call in vm.evidenceCalls.val:
      if call.datasetPath != entry.datasetPath or call.state != ecsCompleted:
        continue
      vm.reviewOpen.requestDataset ReviewDatasetRequest(
        anchorId: call.anchorId,
        datasetPath: call.datasetPath,
        kind: rdrInspect)
      break

proc setMessages*(vm: AgentActivityVM;
                  messages: openArray[AgentActivityMessageEntry]) =
  vm.messages.val = @messages
  # Re-derived here rather than by a Memo so that *every* producer of the
  # conversation gets the AA-2 rendering without opting in, and so that a
  # caller reading `testRuns` immediately after `setMessages` sees the run
  # (a Memo would be lazy).
  vm.testRuns.val = projectTestRuns(messages)
  # AA-3, and for the same three reasons.
  vm.evidenceCalls.val = projectEvidenceCalls(messages)
  vm.requestEvidenceInspections()

proc testRunIndex*(vm: AgentActivityVM; anchorId: string): int =
  ## The index of the run anchored at `anchorId`, or -1.
  ##
  ## Returned as an index rather than an `Option` because the view uses it to
  ## decide *between* two renderings of the same feed position, and an index
  ## is what it needs for both.
  for i, entry in vm.testRuns.val:
    if entry.anchorId == anchorId:
      return i
  -1

proc testRunFor*(vm: AgentActivityVM; anchorId: string):
    Option[TestRunSummary] =
  let index = vm.testRunIndex(anchorId)
  if index < 0: none(TestRunSummary) else: some(vm.testRuns.val[index].summary)

proc isTestRunExpanded*(vm: AgentActivityVM; anchorId: string): bool =
  anchorId in vm.expandedTestRuns.val

proc toggleTestRun*(vm: AgentActivityVM; anchorId: string) =
  var expanded = vm.expandedTestRuns.val
  let index = expanded.find(anchorId)
  if index >= 0:
    expanded.delete(index)
  else:
    expanded.add anchorId
  vm.expandedTestRuns.val = expanded

proc isTestExpanded*(vm: AgentActivityVM; anchorId, testId: string): bool =
  expansionKey(anchorId, testId) in vm.expandedTests.val

proc toggleTest*(vm: AgentActivityVM; anchorId, testId: string) =
  var expanded = vm.expandedTests.val
  let key = expansionKey(anchorId, testId)
  let index = expanded.find(key)
  if index >= 0:
    expanded.delete(index)
  else:
    expanded.add key
  vm.expandedTests.val = expanded

proc openTestRecording*(vm: AgentActivityVM; anchorId, testId: string;
                        policy = topCurrentTab): bool =
  ## Open the recording of one test through the existing trace-opening path.
  ##
  ## Returns whether anything was opened, and **opens nothing** for a test
  ## that has no recording.  Both halves are §2.1.2's rule: a test with no
  ## recording gets no drill-down affordance rather than one that fails when
  ## used, and a recording that failed before producing a trace must not
  ## become a broken trace tab.  The view gates the affordance on
  ## `hasRecording`; this gates the action on the same fact, so a stale
  ## rendering cannot open a trace that is not there.
  let index = vm.testRunIndex(anchorId)
  if index < 0:
    return false
  let row = vm.testRuns.val[index].summary.rowFor(testId)
  if row.isNone or not row.get.hasRecording:
    return false
  let value = row.get
  vm.traceOpen.openTrace TraceOpenRequest(
    tracePath: value.tracePath,
    traceId: value.traceId,
    recordingId: value.recordingId,
    testId: value.testId,
    policy: policy)
  true

# ---------------------------------------------------------------------------
# AA-3 — the session's evidence handoffs
# ---------------------------------------------------------------------------

proc datasetFor*(vm: AgentActivityVM; datasetPath: string): EvidenceDataset =
  ## What is known about `datasetPath`.  `edsUnknown` when nothing is, which
  ## is a state the rendering distinguishes from "missing" rather than
  ## collapsing into it.
  let index = vm.datasetIndex(datasetPath)
  if index < 0:
    EvidenceDataset(state: edsUnknown)
  else:
    vm.evidenceDatasets.val[index].dataset

proc evidenceIndex*(vm: AgentActivityVM; anchorId: string): int =
  ## The index of the evidence call anchored at `anchorId`, or -1.  An index
  ## rather than an `Option` for the reason `testRunIndex` is one: the view
  ## uses it to decide *between* two renderings of the same feed position.
  for i, call in vm.evidenceCalls.val:
    if call.anchorId == anchorId:
      return i
  -1

proc evidenceCallFor*(vm: AgentActivityVM; anchorId: string):
    Option[EvidenceCall] =
  ## The evidence call at `anchorId`, with what the host has learned about its
  ## dataset merged in.
  ##
  ## The merge happens here rather than being written into `evidenceCalls`
  ## because the projection is re-run on every `setMessages` and would
  ## otherwise erase the host's answers each time.  Reading both signals also
  ## makes the view re-render when either changes, which is how a card turns
  ## from "Reading …" into a shape and an affordance.
  let index = vm.evidenceIndex(anchorId)
  if index < 0:
    return none(EvidenceCall)
  var call = vm.evidenceCalls.val[index]
  call.dataset = vm.datasetFor(call.datasetPath)
  some(call)

proc applyEvidenceDataset*(vm: AgentActivityVM; datasetPath: string;
                           dataset: EvidenceDataset) =
  ## Record the host's answer about one dataset path.
  ##
  ## Idempotent, and safe for a path no card names any more: the entry is
  ## simply kept, and the next conversation that names it starts with the
  ## answer already in hand.
  if datasetPath.len == 0:
    return
  var entries = vm.evidenceDatasets.val
  let index = vm.datasetIndex(datasetPath)
  if index < 0:
    entries.add EvidenceDatasetEntry(
      datasetPath: datasetPath, dataset: dataset)
  else:
    entries[index].dataset = dataset
  vm.evidenceDatasets.val = entries

proc openEvidence*(vm: AgentActivityVM; anchorId: string): bool =
  ## Enter a review over the dataset the evidence call at `anchorId` names.
  ##
  ## Returns whether a request was issued, and **issues none** for a call with
  ## nothing to open.  Both halves are §2.1.1's rule as AA-2 read it for the
  ## test drill-down: the view gates the affordance on `canOpenEvidence`, and
  ## this gates the action on the same fact, so a rendering that is a moment
  ## stale cannot ask for a dataset that has just been reported missing.
  ##
  ## Opening **replaces** the review the window is showing, rather than adding
  ## one beside it.  That is what `ct review <PATH>` does — one window, one
  ## review, routed into the panels the layout already has (DeepReview-GUI.md
  ## §2, "DeepReview has no workspace of its own and no panel of its own") —
  ## and a second concurrent review would need a second VCS panel, a second
  ## changed-files selection and a second answer to "which review is this
  ## editor tab from".
  let call = vm.evidenceCallFor(anchorId)
  if call.isNone or not call.get.canOpenEvidence():
    return false
  vm.reviewOpen.requestDataset ReviewDatasetRequest(
    anchorId: anchorId,
    datasetPath: call.get.datasetPath,
    kind: rdrOpen)
  true

proc setTerminals*(vm: AgentActivityVM;
                   terminals: openArray[AgentActivityTerminalEntry]) =
  vm.terminals.val = @terminals

proc setInputValue*(vm: AgentActivityVM; value: string) =
  vm.inputValue.val = value

proc setLoading*(vm: AgentActivityVM; isLoading: bool) =
  vm.isLoading.val = isLoading

proc setReRecordInProgress*(vm: AgentActivityVM; inProgress: bool) =
  vm.reRecordInProgress.val = inProgress

proc setPromptFlags*(vm: AgentActivityVM; wantsPassword, wantsPermission: bool) =
  vm.wantsPassword.val = wantsPassword
  vm.wantsPermission.val = wantsPermission

proc setSessionKey*(vm: AgentActivityVM; sessionKey: string) =
  vm.sessionKey.val = sessionKey

proc setSessionNotice*(vm: AgentActivityVM; notice: string) =
  ## Publish (or, with "", withdraw) the panel's explanatory notice.
  ## Idempotent so subscribers do not refire on a re-entered review.
  if vm.sessionNotice.val == notice:
    return
  vm.sessionNotice.val = notice

proc clearConversation*(vm: AgentActivityVM) =
  vm.messages.val = @[]
  vm.testRuns.val = @[]
  vm.expandedTestRuns.val = @[]
  vm.expandedTests.val = @[]
  vm.evidenceCalls.val = @[]
  # The dataset answers go too: they belong to the conversation that named
  # them, and a file read for the previous session may since have changed.
  vm.evidenceDatasets.val = @[]
  vm.terminals.val = @[]
  vm.inputValue.val = ""
  vm.isLoading.val = false
  vm.reRecordInProgress.val = false
  vm.wantsPassword.val = false
  vm.wantsPermission.val = false
  vm.sessionNotice.val = ""

proc createAgentActivityVM*(store: ReplayDataStore): AgentActivityVM =
  withViewModel proc(dispose: proc()): AgentActivityVM =
    let messages = createSignal(newSeq[AgentActivityMessageEntry]())
    let testRuns = createSignal(newSeq[AgentTestRunEntry]())
    let expandedTestRuns = createSignal(newSeq[string]())
    let expandedTests = createSignal(newSeq[string]())
    let evidenceCalls = createSignal(newSeq[EvidenceCall]())
    let evidenceDatasets = createSignal(newSeq[EvidenceDatasetEntry]())
    let terminals = createSignal(newSeq[AgentActivityTerminalEntry]())
    let inputValue = createSignal("")
    let isLoading = createSignal(false)
    let reRecordInProgress = createSignal(false)
    let wantsPassword = createSignal(false)
    let wantsPermission = createSignal(false)
    let sessionKey = createSignal("")
    let sessionNotice = createSignal("")

    let messageCount = createMemo[int] proc(): int =
      messages.val.len
    let terminalCount = createMemo[int] proc(): int =
      terminals.val.len
    let hasMessages = createMemo[bool] proc(): bool =
      messages.val.len > 0
    let hasSessionNotice = createMemo[bool] proc(): bool =
      sessionNotice.val.len > 0
    let testRunCount = createMemo[int] proc(): int =
      testRuns.val.len
    let evidenceCallCount = createMemo[int] proc(): int =
      evidenceCalls.val.len

    AgentActivityVM(
      store: store,
      messages: messages,
      testRuns: testRuns,
      expandedTestRuns: expandedTestRuns,
      expandedTests: expandedTests,
      evidenceCalls: evidenceCalls,
      evidenceDatasets: evidenceDatasets,
      terminals: terminals,
      inputValue: inputValue,
      isLoading: isLoading,
      reRecordInProgress: reRecordInProgress,
      wantsPassword: wantsPassword,
      wantsPermission: wantsPermission,
      sessionKey: sessionKey,
      sessionNotice: sessionNotice,
      messageCount: messageCount,
      terminalCount: terminalCount,
      hasMessages: hasMessages,
      hasSessionNotice: hasSessionNotice,
      testRunCount: testRunCount,
      evidenceCallCount: evidenceCallCount,
      disposeProc: dispose,
    )
