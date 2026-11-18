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

import nim_agents_isonim_viewmodels/agent_harbor/[changes_vm, inbox_vm]

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
    ## A file row's mark for one of the plan's key source files.

  # The Inbox and an item's page
  InboxSectionLabel* = "Inbox"
  PreviousArrow* = "\xE2\x86\x90"
  NextArrow* = "\xE2\x86\x92"
  PreviousTitle* = "Previous: back to the item you saw before"
  NextTitle* = "Next: the item at the top of the inbox"
  StepperShortcutHint* = ""
    ## The keys in the Previous / Next tooltip. The operations are bound
    ## in the keymap catalogue with the terminal views;
    ## until a key is bound the tooltip names none rather than a key that
    ## does nothing.
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

proc actionStatusText*(status: ActionStatus; reason: string): string =
  ## The line under a card for its last write: submitting, sent, or failed
  ## with the source's reason; "" before any.
  case status
  of astIdle: ""
  of astSubmitting: "Sending\xE2\x80\xA6"
  of astConfirmed: "Sent"
  of astFailed:
    if reason.len > 0: "Failed: " & reason else: "Failed"

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
  ## The mark's drawn text: `C` committed, `U` uncommitted, `C+U` both.
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

proc pendingFeedbackFor*(items: openArray[InboxItem]; sessionId: string): int =
  ## How many feedback requests of the session `sessionId` the inbox holds:
  ## the count a feedback row shows (`Needs Follow-up`, `N pending`). Here,
  ## not in a view, so every host counts the same way.
  for item in items:
    if item.kind == ikAsyncFeedback and item.session.id == sessionId: inc result

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

proc stepperTitle*(next: bool): string =
  (if next: NextTitle else: PreviousTitle) & StepperShortcutHint

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
