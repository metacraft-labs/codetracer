## views/agent_harbor_changes_inbox_words.nim
##
## The words and the state roles the Changes panel and the Inbox views say,
## in every front-end: the buttons' labels, the header strips' phrases, the
## group heads, the status words and the role each state is drawn in, the
## Previous / Next group's words.
##
## ## Why a module of its own
##
## The web views (`isonim_agent_harbor_changes_view.nim`,
## `isonim_agent_harbor_inbox_view.nim`) say these words, and the GPUI and
## terminal views of the same viewmodels must say exactly the same ones. A
## native view never imports a web view (that would put the web's DSL
## templates and its JS-only DOM hooks into the native front-end's closure),
## so the words live here, in a module that renders nothing and imports no
## renderer: only the viewmodels and the standard library. This is the
## pattern `agent_harbor_words.nim` set for the earlier Agent Harbor views;
## these words are a file of their own so the Changes and Inbox work stays
## out of a module other Agent Harbor work edits.
##
## Every fact a word is built from comes from the viewmodels
## (nim-agents-isonim-viewmodels `changes_vm`, `inbox_vm`, `inbox_item_vm`)
## or from the domain they re-export (nim-agents `review_record`,
## `change_diff`, `inbox`). Nothing here decides a state: it only names it.

import std/strutils

import nim_agents_isonim_viewmodels/agent_harbor/[changes_vm, inbox_vm, inbox_item_vm]
import ../keymap/[base_keymaps, context_keys, editing_keymap, keymap_router, scope_path]
from ../keymap/operation_catalogue import InboxTable

export changes_vm, inbox_vm

# ---------------------------------------------------------------------------
# What a host tells the views
# ---------------------------------------------------------------------------

type
  AgentHarborChangesContext* = object
    ## What the host knows about the session the Changes panel shows, which
    ## the change itself does not say.
    sessionLabel*: string
      ## How the session is named (the header strip's context phrase).
    ended*: bool
      ## The session has ended: its `n files +a −r` roll-up is final and is
      ## shown (a running session's diff still moves, INV-P2-18).

  AgentHarborInboxContext* = object
    ## What the host tells the Inbox panel.
    scope*: string
      ## The header strip's context phrase: whose inbox it is (`this
      ## server`, a fleet's servers).
    nowMs*: int64
      ## The moment ages and warmth chips are read at: the host's clock in a
      ## live host, the inbox's own moment in a story (no motion in a web
      ## capture).
    onOpenSignIn*: proc()
      ## The host's action behind a login request's `Open sign-in` (it opens
      ## the sign-in window on this desktop); the button is drawn only when
      ## the host has one.

  AgentHarborInboxItemContext* = object
    ## What the host tells an item's page.
    sessionLabel*: string
      ## How the item's session is named.
    nowMs*: int64
      ## The moment a feedback request's expiry is judged at.
    onOpenSignIn*: proc()
      ## As `AgentHarborInboxContext.onOpenSignIn`.
    onTyping*: proc(typing: bool)
      ## Told whether the page's text field holds typed text, so the inbox's
      ## auto-switch holds still while the operator types.
    onContinue*: proc()
      ## The host's action behind a completed sign-in's `Continue`: moving
      ## on from the item (the Inbox panel's Next); the button is drawn only
      ## when the host has one.

# ---------------------------------------------------------------------------
# Shared
# ---------------------------------------------------------------------------

const
  Dot* = " \xC2\xB7 "
    ## The separator of a header strip's counts and of a meta line.
  RetryLabel* = "Retry"
  SubmitLabel* = "Submit"
  CancelLabel* = "Cancel"

  # The Changes panel
  ChangesSectionLabel* = "Changes"
  ApproveLabel* = "Approve"
  ApproveApplyLabel* = "Approve & Apply"
  DiscardLabel* = "Discard"
  RequestChangesLabel* = "Request Changes"
  RevertLabel* = "Undo / Revert"
  ConfirmRevertLabel* = "Revert"
    ## The confirmation's own button: the press that sends the revert.
  SummaryLabel* = "Summary"
  DiffLabel* = "Diff"
  RequestChangesPlaceholder* = "What should change in this spec?"
  CommitsLabel* = "Commits"
  SectionsLabel* = "Sections"
  KeySourceFilesLabel* = "Key source files"
  LoadDiffLabel* = "Load diff"
  BinaryLabel* = "binary"
  SearchFilesPlaceholder* = "Search files\xE2\x80\xA6"
  OpenInEditorLabel* = "Open in editor"
  PreviousFileLabel* = "Previous file"
  NextFileLabel* = "Next file"
  LoadingFileText* = "Loading the diff\xE2\x80\xA6"
  NoHunksText* = "No changed lines to show."
  RenamedFromLabel* = "from"
    ## Before a renamed file's old path, under its row.
  KeyFileMark* = "key"
    ## A file row's mark for one of the plan's key source files
    ## (`CodeMarksLegend` says what it stands for).
  KeyFileTitle* = "A key source file of the plan"
    ## The key-file mark's tooltip.
  BinaryTitle* = "A binary file: no lines to show"
    ## The binary mark's tooltip.
  CodeMarksLegend* = "C committed \xC2\xB7 U uncommitted \xC2\xB7 key: a key source file"
    ## Over the Code tab's files: what the file rows' short marks
    ## (`originShort`, `KeyFileMark`) stand for.

  # The Inbox and an item's page
  InboxSectionLabel* = "Inbox"
  PreviousArrow* = "\xE2\x86\x90"
  NextArrow* = "\xE2\x86\x92"
  PreviousTitle* = "Previous: back to the item you saw before"
  NextTitle* = "Next: the item at the top of the inbox"
  InboxNextOperation* = "inbox.next"
  InboxPreviousOperation* = "inbox.previous"
  InboxChooseOptionOperation* = "inbox.choose-option"
    ## The operation a single choice's toggle carries: choose that option.
  AutoSwitchOn* = "Auto-switch: on"
  AutoSwitchOff* = "Auto-switch: off"
  AutoOn* = "Auto: on"
  AutoOff* = "Auto: off"
  AutoSwitchTitle* = "Move to the next item after you answer one"
  OpenLabel* = "Open"
  SendLabel* = "Send"
  SendDraftLabel* = "Send draft"
  RejectLabel* = "Reject"
  ApproveForSessionLabel* = "Approve for session"
  DenyLabel* = "Deny"
  AcknowledgeLabel* = "Acknowledge"
  OpenSignInLabel* = "Open sign-in"
  ContinueLabel* = "Continue"
    ## A completed sign-in's press: move on from the item.
  PasswordPlaceholder* = "Password"
  AnswerPlaceholder* = "Your answer"
  InstructionPlaceholder* = "Your next instruction"
  ResponsePlaceholder* = "Your response"
  SummaryHead* = "Summary"
  LastReplyHead* = "The agent's last reply"
  DraftHead* = "Draft"
  AttachmentsHead* = "Attachments"
  PriorityLabel* = "Priority"
  ThisServerLabel* = "this server"
    ## The head of a fleet inbox's run of rows from the server the operator
    ## is connected to (its items carry no server name).

# ---------------------------------------------------------------------------
# State roles
# ---------------------------------------------------------------------------
#
# A role names the design-system colour family a state word and its dot are
# drawn in: `warning` amber, `success` green, `error` red, `info` blue,
# `quiet` the caption colour. Every host maps a role to its own ink (the web
# through `ah-role-<role>` classes, `agent_harbor_changes.styl`).

proc roleClass*(role: string): string =
  ## The web class of a role (`ah-role-warning`); `quiet` for none.
  "ah-role-" & (if role.len > 0: role else: "quiet")

proc testStatusRole*(status: VerificationStatus): string =
  ## A verification entry's status word's role: failing red, passing green,
  ## pending and unknown quiet.
  case status
  of vsFailing: "error"
  of vsPassing: "success"
  of vsPending, vsUnknown: "quiet"

proc testStatusWord*(entry: VerificationEntry): string =
  ## The status word a test row shows: the leading token (`passing`), or, for
  ## a status with no known leading token, the status as written.
  if entry.status == vsUnknown: entry.rawStatus.strip else: $entry.status

proc actionStatusText*(status: ActionStatus; reason: string;
                       kind = oaApproveSpecChange): string =
  ## The line under a card for its last write: submitting, sent, or failed
  ## with the source's reason; "" before any. A revert says what it does
  ## (`Reverting…`, `Reverted`, `Revert failed: <reason>`).
  let revert = kind == oaRevertSpecChange
  case status
  of astIdle: ""
  of astSubmitting: (if revert: "Reverting\xE2\x80\xA6" else: "Sending\xE2\x80\xA6")
  of astConfirmed: (if revert: "Reverted" else: "Sent")
  of astFailed:
    let head = if revert: "Revert failed" else: "Failed"
    if reason.len > 0: head & ": " & reason else: head

proc actionStatusRole*(status: ActionStatus): string =
  case status
  of astFailed: "error"
  of astConfirmed: "success"
  else: "quiet"

# ---------------------------------------------------------------------------
# The Changes panel
# ---------------------------------------------------------------------------

proc tierHead*(tier: SpecTier): string =
  ## A Spec Changes group's head word (`requirements`, `governance`,
  ## `specs`), set in small caps by the view.
  $tier

proc tabTitle*(tab: ChangesTabView): string =
  ## A tab's tooltip: its whole label and what its count counts.
  let noun = case tab.tab
    of rtSpecChanges: (if tab.count == 1: "spec change" else: "spec changes")
    of rtTests: (if tab.count == 1: "test" else: "tests")
    of rtImplementation: (if tab.count == 1: "milestone with details"
                          else: "milestones with details")
    of rtCode: (if tab.count == 1: "file" else: "files")
  tab.label & ": " & $tab.count & " " & noun

proc changeStateRole*(card: SpecCardView): string =
  ## The role of a card's state word, as the viewmodel names it.
  if card.stateRole.len > 0: card.stateRole else: "quiet"

proc revertQuestion*(card: SpecCardView): string =
  ## The question a card asks after Undo / Revert, before anything is sent:
  ## what reverting undoes, named by the spec's path.
  "Revert this task's changes to " & card.path & "?"

proc commitsText*(card: SpecCardView): string =
  card.commits.join(" ")

proc sectionsText*(card: SpecCardView): string =
  card.sections.join("; ")

proc originMark*(origin: ChangeOrigin): string =
  ## A file row's committed / uncommitted mark, as its tooltip reads it.
  case origin
  of coCommitted: "committed"
  of coUncommitted: "uncommitted"
  of coBoth: "committed and uncommitted"

proc originShort*(origin: ChangeOrigin): string =
  ## The mark's drawn text: `C` committed, `U` uncommitted, `C+U` both
  ## (`CodeMarksLegend` says so; `originMark` is its tooltip).
  case origin
  of coCommitted: "C"
  of coUncommitted: "U"
  of coBoth: "C+U"

proc fileRowTitle*(row: FileRow): string =
  ## A file row's tooltip: its path, a rename's old path, and its origin.
  result = row.file.path
  if row.file.oldPath.len > 0: result = row.file.oldPath & " \xE2\x86\x92 " & result
  result.add Dot & originMark(row.file.origin)
  if row.key: result.add Dot & "a key source file"

proc filterChoices*(): seq[StatusFilter] =
  @[sfAll, sfAdded, sfModified, sfDeleted, sfRenamed]

proc changesContextPhrase*(sessionLabel: string): string =
  ## The header strip's quiet context phrase: the session the change is of.
  sessionLabel

# ---------------------------------------------------------------------------
# The Inbox
# ---------------------------------------------------------------------------

proc inboxCountsText*(vm: InboxVM): string =
  ## The header strip's counts: `3 waiting · 1 blocked`, the feedback
  ## requests named when there are any; "" for an empty inbox.
  let n = vm.count
  if n == 0: return ""
  result = countText(n)
  let blocked = vm.blockedCount
  if blocked > 0: result.add Dot & $blocked & " blocked"
  let feedback = vm.feedbackCount
  if feedback > 0:
    result.add Dot & $feedback & (if feedback == 1: " feedback request" else: " feedback requests")

proc kindRole*(kind: InboxKind): string =
  ## The role of an inbox row's kind mark: an agent stopped on it (a
  ## question, a permission, a sign-in, an ended turn) amber; a feedback
  ## request, which blocks nothing, blue; a kind the client does not know,
  ## quiet.
  case kind
  of ikBlockedQuestion, ikPermissionGate, ikLoginRequest: "warning"
  of ikEndedTurn: "idle"
  of ikAsyncFeedback: "info"
  of ikUnknown: "quiet"

proc loginStateRole*(state: LoginState; hasRequest: bool): string =
  ## The role of a login request's state line: completed green, failed red,
  ## pending, cancelling and no request quiet.
  if not hasRequest: return "quiet"
  case state
  of lsCompleted: "success"
  of lsFailed: "error"
  of lsPending, lsCancelling: "quiet"

proc kindWordOf*(kind: InboxKind): string =
  ## A page's kind words, the same as its row's (`inbox.kindWord`).
  if kind == ikUnknown: "waits for you"
  else: waitWords(waitWordKindOf(kind))

proc priorityRole*(item: InboxItem): string =
  case item.effectivePriority
  of ipUrgent: "error"
  of ipHigh: "warning"
  of ipNormal: "info"
  of ipLow: "quiet"

proc warmthRole*(chip: string): string =
  ## A warmth chip's role: warm green, expiring amber, cold quiet.
  if chip.startsWith("warm") or chip == "likely warm": "success"
  elif chip == "expiring": "warning"
  else: "quiet"

proc autoSwitchText*(on, compact: bool): string =
  ## `Auto-switch: off`; `Auto: off` where the group has no room for the
  ## position (the initiative bar's at `panel` width).
  if compact: (if on: AutoOn else: AutoOff)
  else: (if on: AutoSwitchOn else: AutoSwitchOff)

proc stepperKey*(next: bool): string =
  ## The key the base keymap binds to Next or Previous in the Inbox's scope
  ## (`overlay_rows`: `]` and `[`), as a tooltip names it (IR-3: the key
  ## shown is one that, typed there, runs it); "" when none does.
  ##
  ## Only the Inbox table's own rows are candidates. The window's table binds
  ## the same operations to `Alt+]` / `Alt+[` (the sessions bar's keys, which
  ## work from anywhere) and those resolve in the panel too, so the router's
  ## `chordFor`, which answers with the first row in table order, would name
  ## them; the panel names its own, unmodified key. Each candidate is typed
  ## through the router in the panel's scope, as `chordFor` checks its rows,
  ## and named only when it lands on the operation.
  let router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feWeb, platform: hostPlatform(),
                                                   keyProtocol: kpNative))
  let operation = if next: InboxNextOperation else: InboxPreviousOperation
  let path = @[element(ekWindow, "window"), pane(InboxPanelScope)]
  for b in router.effective.bindingsFor(operation):
    if tableOf(b) != InboxTable: continue
    var typed = router
    var res: EditingResolution
    for chord in b.chords:
      res = typed.route(SessionFacts(), path, nmNormal, chord, 0)
    if res.kind == erOperation and res.operation == operation and res.argument.len == 0:
      return b.spelling
  ""

proc stepperTitle*(next: bool): string =
  ## Previous's or Next's tooltip: what it does and its key (N6).
  let key = stepperKey(next)
  (if next: NextTitle else: PreviousTitle) & (if key.len > 0: " (" & key & ")" else: "")

proc itemHintText*(): string =
  ## The quiet line in the page's place while items wait and none is on
  ## screen: how to put one there, naming the key the base keymap binds to
  ## Next in the Inbox's scope (`stepperKey`). Nothing is opened for the
  ## reader: the line only says how.
  let key = stepperKey(true)
  if key.len > 0: "Select an item, or press " & key & " for the one at the top"
  else: "Select an item"

proc approvalPurposeText*(request: ApprovalRequest): string =
  ## The line under a queued approval's command or domain: why the agent
  ## asks, in prose (`In order to load the new queue limit`); "" for no
  ## reason given.
  let purpose = approvalPurpose(request)
  if purpose.len > 0: "In order to " & purpose else: ""

proc confidenceText*(draft: Draft): string =
  ## `confidence high · by the Manager`, the draft's provenance line.
  var parts: seq[string]
  if draft.confidence.len > 0: parts.add "confidence " & draft.confidence
  if draft.drafter.len > 0: parts.add "by " & draft.drafter
  parts.join(Dot)

proc attachmentText*(a: Attachment): string =
  if a.kind.len > 0: a.name & " (" & a.kind & ")" else: a.name

proc priorityChoices*(): seq[InboxPriority] =
  @[ipUrgent, ipHigh, ipNormal, ipLow]

proc priorityKeyText*(p: InboxPriority): string =
  ## A priority's menu entry with its key (`1  urgent`), keys `1`-`4`.
  let key = case p
    of ipUrgent: "1"
    of ipHigh: "2"
    of ipNormal: "3"
    of ipLow: "4"
  key & "  " & $p

# ---------------------------------------------------------------------------
# Keys (the catalogue's `changes.*` and `inbox.*` operations)
# ---------------------------------------------------------------------------
#
# What each of the panels' key operations does, the same in every host. A
# host resolves a key in the panel's scope through its router (`ChangesPanelScope`,
# `InboxPanelScope`; the rows are `overlay_rows`') and runs what it resolves to
# here; scrolling, which is the host's own drawing, it runs itself.

const
  ChangesFocusNextOperation* = "changes.focus-next"
  ChangesFocusPreviousOperation* = "changes.focus-previous"
  ChangesToggleOperation* = "changes.toggle"
  ChangesNextTabOperation* = "changes.next-tab"
  ChangesPreviousTabOperation* = "changes.previous-tab"
  ChangesPageDownOperation* = "changes.page-down"
  ChangesPageUpOperation* = "changes.page-up"
  ChangesOperations* = [ChangesFocusNextOperation, ChangesFocusPreviousOperation,
                        ChangesToggleOperation, ChangesNextTabOperation,
                        ChangesPreviousTabOperation, ChangesPageDownOperation,
                        ChangesPageUpOperation]
    ## The Changes panel's key operations.
  InboxPriorityOperations* = ["inbox.priority-1", "inbox.priority-2", "inbox.priority-3",
                              "inbox.priority-4"]
    ## Keys `1`-`4`: urgent, high, normal, low (`priorityChoices`' order).
  InboxScrollDownOperation* = "inbox.scroll-down"
  InboxScrollUpOperation* = "inbox.scroll-up"
  InboxPageDownOperation* = "inbox.page-down"
  InboxPageUpOperation* = "inbox.page-up"
  InboxOperations* = [InboxNextOperation, InboxPreviousOperation, "inbox.priority-1",
                      "inbox.priority-2", "inbox.priority-3", "inbox.priority-4",
                      InboxScrollDownOperation, InboxScrollUpOperation,
                      InboxPageDownOperation, InboxPageUpOperation]
    ## The Inbox's key operations.
  ScrollOperations* = [ChangesPageDownOperation, ChangesPageUpOperation,
                       InboxScrollDownOperation, InboxScrollUpOperation,
                       InboxPageDownOperation, InboxPageUpOperation]
    ## The operations a host runs on its own drawing (`runChangesOperation`
    ## and `runInboxOperation` leave them to it).

# ---------------------------------------------------------------------------
# Presses (Input-Routing-And-Keymaps.md §5.1)
# ---------------------------------------------------------------------------
#
# The operation each pressable element of the panels carries. A press is
# resolved by the host's router over the pointer keymap (a user's row for the
# press first, else the operation the element carries) and runs the procedure
# the view bound to that element (`element_operations.bindOperation` on the
# web, `ah_changes_inbox_parts.pressable` in GPUI). The views hold no press
# handler of their own.

const
  ChangesRetryOperation* = "changes.retry"
    ## Retry after the panel's read failed.
  ChangesSelectTabOperation* = "changes.select-tab"
    ## A tab: show it.
  ChangesToggleCardOperation* = "changes.toggle-card"
    ## A spec card's head: open or close that card.
  ChangesCardActionOperation* = "changes.card-action"
    ## A card's buttons (Approve, Revert, Request Changes, …), the revert
    ## question's and the Request Changes input's.
  ChangesShowSideOperation* = "changes.show-side"
    ## The Summary ⇄ Diff toggle's sides: show that side.
  ChangesOpenFileOperation* = "changes.open-file"
    ## A file link or Open in Editor: ask the host to open the file.
  ChangesSelectFileOperation* = "changes.select-file"
    ## A changed file's row in the Code tab: select it.
  ChangesStepFileOperation* = "changes.step-file"
    ## The file navigation's previous and next.
  ChangesLoadDiffOperation* = "changes.load-diff"
    ## Load a file's diff.
  InboxRetryOperation* = "inbox.retry"
    ## Retry after the Inbox's or an item's read failed.
  InboxItemActionOperation* = "inbox.item-action"
    ## An item page's form buttons (Send, Submit, Approve, Deny, …).
  InboxToggleAutoSwitchOperation* = "inbox.toggle-auto-switch"
    ## Auto-switch: turn it on or off.
  InboxOpenItemOperation* = "inbox.open-item"
    ## An Inbox row, or its Open: put that item's page on screen.

proc runChangesOperation*(vm: ChangesVM; operation: string): bool =
  ## Runs one of the Changes panel's key operations on `vm`: true when it
  ## changed something. False for a scroll (the host's) and for an
  ## operation that is not the panel's.
  if vm.isNil or vm.state.val != asReady: return false
  case operation
  of ChangesFocusNextOperation: vm.focusNext()
  of ChangesFocusPreviousOperation: vm.focusPrevious()
  of ChangesToggleOperation: vm.toggleFocused()
  of ChangesNextTabOperation: vm.stepTab(1)
  of ChangesPreviousTabOperation: vm.stepTab(-1)
  else: false

proc runInboxOperation*(vm: InboxVM; page: InboxItemVM; operation: string): bool =
  ## Runs one of the Inbox's key operations: Next and Previous on the Inbox
  ## panel's viewmodel (`vm`, nil on an item's page standing alone), a
  ## priority on the page on screen (`page`, nil for none). True when it
  ## was sent; false for a scroll (the host's), a step that cannot be taken,
  ## and an operation that is not the Inbox's.
  let at = InboxPriorityOperations.find(operation)
  if at >= 0:
    if page.isNil or page.state.val != asReady: return false
    return page.setPriority(priorityChoices()[at])
  if vm.isNil or vm.state.val != asReady: return false
  case operation
  of InboxNextOperation: vm.canNext and vm.next()
  of InboxPreviousOperation: vm.canPrev and vm.prev()
  else: false
