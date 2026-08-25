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
import test_run_summary_vm, trace_open

export test_run_summary_vm, trace_open

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

  AgentActivityVM* = ref object of ViewModel
    store*: ReplayDataStore

    traceOpen*: TraceOpenService
      ## AA-2 — how this panel opens the recording of a test.  The *existing*
      ## trace-opening path (`trace_open.nim`), wired by the host to the same
      ## IPC the welcome screen and the tab model already use.  Nil in a
      ## headless test, and `openTestRecording` reports honestly when it is.

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

proc `==`*(a, b: AgentTestRunEntry): bool {.noSideEffect.} =
  a.anchorId == b.anchorId and a.summary == b.summary

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

proc setMessages*(vm: AgentActivityVM;
                  messages: openArray[AgentActivityMessageEntry]) =
  vm.messages.val = @messages
  # Re-derived here rather than by a Memo so that *every* producer of the
  # conversation gets the AA-2 rendering without opting in, and so that a
  # caller reading `testRuns` immediately after `setMessages` sees the run
  # (a Memo would be lazy).
  vm.testRuns.val = projectTestRuns(messages)

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

    AgentActivityVM(
      store: store,
      messages: messages,
      testRuns: testRuns,
      expandedTestRuns: expandedTestRuns,
      expandedTests: expandedTests,
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
      disposeProc: dispose,
    )
