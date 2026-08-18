## viewmodels/agent_activity_vm.nim
##
## AgentActivityVM — ViewModel for the ACP Agent Activity panel.
##
## The legacy ``AgentActivityComponent`` keeps owning ACP IPC/session
## state, but its Karax ``render`` path is bypassed.  This VM carries
## the platform-neutral snapshot that the IsoNim view renders: ordered
## conversation messages, terminal shell placeholders, prompt flags,
## input value, loading state, and re-record button state.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]

type
  AgentActivityVM* = ref object of ViewModel
    store*: ReplayDataStore

    messages*: Signal[seq[AgentActivityMessageEntry]]
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

proc setMessages*(vm: AgentActivityVM;
                  messages: openArray[AgentActivityMessageEntry]) =
  vm.messages.val = @messages

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

    AgentActivityVM(
      store: store,
      messages: messages,
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
      disposeProc: dispose,
    )
