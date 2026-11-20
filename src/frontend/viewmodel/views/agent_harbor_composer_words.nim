## views/agent_harbor_composer_words.nim
##
## What every host's omnibox composer draws besides the rows and chips the
## viewmodel publishes (`OmniboxComposerVM`): the state word in a
## destination row's one slot, what a delivery adds under its label and in
## which role, which row the action bar marks, the header line (with a form
## open it names the destination; a form with problems counts them), the
## send line's hint and its `· N more` count, the folded schedule's summary,
## and the words of a field's empty value.
##
## The web (`isonim_agent_harbor_composer_view.nim`), GPUI
## (`gpui/agent_harbor/ah_composer.nim`) and the terminal
## (`tui/agent_harbor/ah_tui_composer.nim`) draw the same viewmodel and must
## decide these things alike. As with `agent_harbor_words` and
## `agent_harbor_activity_words`, the rules live in a module that renders
## nothing and imports no renderer, so each host imports it without the
## others' rendering code.
##
## ## The keys and the presses
##
## The composer's keys and presses are routed (Input-Routing-And-Keymaps.md
## §4 and §5.1): its keys are keymap rows in the `composer` scope
## (`overlay_rows`, the table `ComposerTable`: `Enter` sends, `Down` and
## `Up` move the destination), and a host resolves a key through its router
## and hands the operation to `runComposerOperation`. Each element a press
## acts on carries its operation (`data-ct-operation` on the web, the
## `operation` fact in the terminal, the same attribute in GPUI) and its
## target (`data-ah-target`): a chip `composer.cite` and its id, `+`
## `composer.add-context`, a row's `Send to …` `composer.send-again` and its
## destination, Retry `composer.retry`, Stop `composer.stop`, a recent
## instruction `composer.recall` and its index, the send button
## `composer.send`. The host's hit test hands both to its router
## (`element_press`), and what it resolves to, with the target, to
## `runComposerPress`. A view holds no handler that decides what a press
## does; the web field's text input is the one listener a view keeps (the
## operator's typing, not a press).

import std/strutils

import nim_agents_isonim_viewmodels/agent_harbor/omnibox_composer_vm

export omnibox_composer_vm

const
  ComposerSendOperation* = "composer.send"
  ComposerNextOperation* = "composer.next-destination"
  ComposerPreviousOperation* = "composer.previous-destination"
  ComposerCiteOperation* = "composer.cite"
  ComposerAddContextOperation* = "composer.add-context"
  ComposerSendAgainOperation* = "composer.send-again"
  ComposerRetryOperation* = "composer.retry"
  ComposerStopOperation* = "composer.stop"
  ComposerRecallOperation* = "composer.recall"
  ComposerOperations* = [ComposerSendOperation, ComposerNextOperation,
                         ComposerPreviousOperation]
    ## Every operation the composer's keys run (`operation_catalogue`).
  ComposerPressOperations* = [ComposerCiteOperation, ComposerAddContextOperation,
                              ComposerSendAgainOperation, ComposerRetryOperation,
                              ComposerStopOperation, ComposerRecallOperation,
                              ComposerSendOperation]
    ## Every operation a press on the composer carries.
  ComposerTargetAttribute* = "data-ah-target"
    ## What a press acts on: a chip's id, a destination, a recent index.

proc operationOfAction*(action: string): string =
  ## The routed operation of an element's `data-ah-action` ("" for an
  ## element no press acts on yet: a form's choices and its schedule).
  case action
  of "cite": ComposerCiteOperation
  of "add-context": ComposerAddContextOperation
  of "send-again": ComposerSendAgainOperation
  of "retry": ComposerRetryOperation
  of "stop": ComposerStopOperation
  of "recall": ComposerRecallOperation
  of "send": ComposerSendOperation
  else: ""

proc runComposerOperation*(vm: OmniboxComposerVM; operation: string): bool =
  ## Runs one of the composer's key operations on `vm`; false for an
  ## operation that is not the composer's.
  case operation
  of ComposerSendOperation:
    vm.submit()
    true
  of ComposerNextOperation:
    vm.moveSelection(1)
    true
  of ComposerPreviousOperation:
    vm.moveSelection(-1)
    true
  else: false

type
  ComposerPress* = proc(operation, target: string)
    ## A host's route for a press: the operation the pressed element carries
    ## and its target. The host resolves it through its router and runs what
    ## it resolves to (`runComposerPress`).

proc runComposerPress*(vm: OmniboxComposerVM; operation, target: string): bool =
  ## Runs the operation a press resolved to, on `target`: citing or unciting
  ## a chip, opening the add-context menu, sending again to a destination,
  ## retrying, stopping the session's turn, recalling a recent instruction;
  ## or any of the keys' operations. False for an operation that is not the
  ## composer's, or a target it cannot read.
  case operation
  of ComposerCiteOperation:
    if target.len == 0: return false
    vm.toggleContext(target)
    true
  of ComposerAddContextOperation:
    vm.toggleAddContext()
    true
  of ComposerSendAgainOperation:
    try:
      vm.sendAgain(parseEnum[TargetKind](target))
      true
    except ValueError:
      false
  of ComposerRetryOperation:
    vm.retry()
    true
  of ComposerStopOperation:
    vm.stop()
    true
  of ComposerRecallOperation:
    try:
      vm.recall(parseInt(target))
      true
    except ValueError:
      false
  else: vm.runComposerOperation(operation)

const
  ComposerPrefix* = "/ai "
    ## The omnibox's agent prefix (`omnibar_vm.classifyOmnibarQuery`).
  ComposerDot* = " \xC2\xB7 "
  InViewLabel* = "In view"
  RecentLabel* = "Recent"
  NothingInView* = "nothing"
  ScheduleLabel* = "Schedule"
  ScheduleOnce* = "Runs once, now"
  MoreBelow* = "More below \xE2\x86\x93"
  MoreAbove* = "More above \xE2\x86\x91"
    ## A scrolled body's first line in a host that draws no scrollbar.
  ShownAfterRouteFailure* = "Shown because the router did not answer"

proc markText*(mark: RowMark): string =
  case mark
  of rmNone: ""
  of rmRouted: "Routed"
  of rmChosen: "Chosen by you"
  of rmRouterChoice: "Router's choice"

proc stateWord*(row: DestinationRow): string =
  ## The row's state word, in the one slot every state uses (the right of
  ## the title line): the router's mark before sending, the delivery's
  ## state after.
  if row.delivered:
    case row.delivery
    of dsSending: "Sending\xE2\x80\xA6"
    of dsSent: "Sent"
    of dsFailed: "Failed to send"
  else: markText(row.mark)

proc stateRole*(row: DestinationRow): string =
  ## The state word's role: quiet for the router's choice and while
  ## sending, the error role for a failure, the label's otherwise.
  if row.delivered:
    case row.delivery
    of dsSending: "quiet"
    of dsSent: "body"
    of dsFailed: "error"
  else:
    case row.mark
    of rmRouterChoice: "quiet"
    else: "label"

proc deliveryText*(row: DestinationRow): string =
  ## What a delivery adds under the label: the failure's reason, a launch's
  ## notice or a UI action's result; "" when the state word says it all.
  if not row.delivered: return ""
  case row.delivery
  of dsSending: ""
  of dsFailed: row.error
  of dsSent: outcomeLine(row.receipt)

proc deliveryRole*(row: DestinationRow): string =
  ## The role the delivery line takes: an error, a warning (a refused or
  ## partly done UI action), or the body.
  if not row.delivered: return ""
  case row.delivery
  of dsSending: "quiet"
  of dsFailed: "error"
  of dsSent:
    case row.receipt.outcome
    of uoRefused, uoPartial: "warning"
    else: "body"

proc lastDelivered*(vm: OmniboxComposerVM): TargetKind =
  ## The destination of the newest delivery: after sending, the row the
  ## action bar marks (each delivered row says `Sent` itself).
  let d = vm.draft.deliveries
  if d.len > 0: d[^1].target else: tkSession

proc rowMarked*(vm: OmniboxComposerVM; row: DestinationRow): bool =
  ## The row the action bar marks: the one Enter sends to; after sending,
  ## the newest delivery's.
  if vm.draft.isBeforeSend: row.selected
  else: row.delivered and row.target == vm.lastDelivered

proc rowUnavailable*(vm: OmniboxComposerVM; row: DestinationRow): bool =
  not vm.draft.targetOf(row.target).available

proc rowLabel*(vm: OmniboxComposerVM; row: DestinationRow): string =
  ## What the row is; an unreachable destination with no label of its own
  ## says why in its place.
  if vm.rowUnavailable(row) and row.label.len == 0: row.reason else: row.label

proc rowReason*(vm: OmniboxComposerVM; row: DestinationRow): string =
  ## The line under the label before any delivery: the router's reason, or
  ## why a row is selected after the router failed; "" once delivered.
  if vm.rowUnavailable(row) and row.label.len == 0 or row.delivered: return ""
  result = row.reason
  if result.len == 0 and vm.draft.isBeforeSend and row.selected and vm.route == rsFailed:
    result = ShownAfterRouteFailure

proc problemOf*(problems: seq[LaunchProblem]; field: string): string =
  for p in problems:
    if p.field == field: return p.text
  ""

proc headerText*(vm: OmniboxComposerVM): string =
  ## The sheet's header line. With a form open it also names where the form
  ## goes, since the form can scroll the destinations out of view; a form
  ## with problems counts them.
  let problems = if vm.phase == cpComposing: vm.problems else: @[]
  let formTo = if vm.showsForm: ComposerDot & "to " & vm.draft.targetOf(tkManager).label else: ""
  if problems.len > 0:
    "Complete the form to send" & ComposerDot & $problems.len &
      (if problems.len == 1: " problem" else: " problems") & formTo
  else: vm.headerLine & formTo

proc headerRole*(vm: OmniboxComposerVM): string =
  if vm.phase == cpComposing and vm.route == rsFailed or vm.phase == cpSendFailed: "error"
  elif vm.phase == cpSent: "body"
  else: "caption"

proc showsSendLine*(vm: OmniboxComposerVM): bool =
  ## While composing and while the instruction waits to be sent; after
  ## sending, the rows' own actions take its place.
  vm.phase == cpComposing or vm.phase == cpSending

proc sendHint*(vm: OmniboxComposerVM): tuple[hint, more: string; blocked: bool] =
  ## The send line's hint and its `· N more` count (never cut: a part of its
  ## own after the cut hint), and whether a problem blocks sending.
  if vm.phase == cpSending:
    return ((if vm.draft.awaitingRoute: "Sends when routed" else: "Sending\xE2\x80\xA6"), "", false)
  let problems = vm.problems
  let reason = vm.sendDisabledReason
  if reason.len == 0: return ("Enter", "", false)
  let more = problems.len - 1
  (reason, (if more > 0: ComposerDot & $more & " more" else: ""), true)

proc citesShown*(vm: OmniboxComposerVM): string =
  ## What is cited, said only once the router has answered: never while it
  ## decides, even if Enter already waits for it.
  if vm.route == rsRouting: "" else: vm.citesLine

proc scheduleSummary*(vm: OmniboxComposerVM): tuple[text: string; problem: bool] =
  ## The schedule's head line: a folded schedule with a problem says its
  ## first problem (error role); otherwise its cron and time zone, or that
  ## it runs once.
  let s = vm.launch.schedule
  var problem = ""
  for field in ["cron", "timezone", "jitter"]:
    if problem.len == 0: problem = problemOf(vm.problems, field)
  if not vm.scheduleOpen.val and problem.len > 0: (problem, true)
  elif s.enabled: (s.cron & ComposerDot & s.timezone, false)
  else: (ScheduleOnce, false)

proc sentBlock*(vm: OmniboxComposerVM): tuple[text, line: string] =
  ## What the sheet shows of a sent instruction, above the destinations:
  ## the instruction as sent, and where it went. The line is left out while
  ## every delivery failed (P2c study D37): the header and
  ## the failed row already say `Failed to send`, the row with its reason.
  ## ("", "") before anything was sent.
  let d = vm.draft
  if not (vm.phase in {cpSent, cpSendFailed} or
          vm.phase == cpSending and d.deliveries.len > 1) or d.deliveries.len == 0:
    return ("", "")
  var delivered = false
  for x in d.deliveries:
    if x.state != dsFailed: delivered = true
  (d.sentText, if delivered: vm.sentLine else: "")

proc sendAgainLabel*(row: DestinationRow): string =
  "Send to " & destinationPhrase(row.target)

proc formTitle*(vm: OmniboxComposerVM): string =
  (if vm.intent == riLaunchTask: "Launch a task" else: "Start an initiative") &
    ComposerDot & "sent to the manager agent"

proc chipState*(chip: ComposerChip): string =
  ## `note`, `cited`, `uncited` (switched off by the operator) or `offered`.
  if chip.item.note: "note" elif chip.cited: "cited"
  elif chip.item.excluded: "uncited" else: "offered"
