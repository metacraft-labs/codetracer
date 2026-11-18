## IsoNim views of the operator's Agent Harbor inbox: the Inbox panel over
## `InboxVM` and an item's page over `InboxItemVM` (nim-agents-isonim-viewmodels
## `inbox_vm`, `inbox_item_vm`).
##
## **The Inbox panel**, an INBOX LIST pattern, top to bottom:
##
## - the header strip (`.ah-fleet-head`): `INBOX`, whose inbox it is (the
##   host's context), and the counts (`3 waiting · 1 blocked`), its title
##   the inbox control's (`3 tasks need input`);
## - the Previous / Next group: `←  3 of 5  →  Auto-switch: off`, and at a
##   narrow width the arrows and `Auto: off` without the position, the
##   disabled arrows in the disabled colour (the wording of the initiative
##   bar's group). Previous and Next ask the viewmodel, which asks the source's
##   cursor; this view keeps no order and no stack;
## - `Incomplete: <server> could not be read (<reason>)` for each server the
##   inbox could not read;
## - one row per item, in the server's order, never re-sorted: the kind's
##   mark, the session's label, the priority and warmth chips, the age; the
##   kind's words and, for an item whose agent died, who holds it; the
##   server's one-line explanation, as served. Rows from another server are
##   headed by the server's name where the run of its rows starts, so the
##   order stays the server's. The row of the item on screen is a selection
##   (the raised fill with the action-colour inset bar);
## - with the viewmodel's pages on (`showPages`), the item on screen's page
##   under the rows, headed by the explanation strip while it was reached
##   through Previous or Next.
##
## **An item's page**, an ITEM PAGE pattern: what the agent asks or reports
## and the form that answers it -- a question (free form, single or multiple
## choice, a confirmation), an ended turn's last reply and the next
## instruction, a permission request's options, queued sudo and network
## approvals, a login request, a feedback request of each type, a manager's
## draft, the executive summary first for a session the operator no longer
## remembers. Its answer state (submitting, `Answer sent; waiting for the
## agent to continue.`, `Failed to submit answer`) and the reason a press
## sent nothing are the viewmodel's.
##
## **Cardless.** Rows and the page are on the panel's ground: no border, box
## or background around an item (`agent_harbor_inbox.styl`).
## A form's first action is the filled primary button and the others are
## outlined, as the Agent Activity pane's permission buttons.
##
## **Writes.** Every press (an answer, a decision, a draft, a priority, a
## cancelled login) calls the viewmodel, which validates it and sends it
## through the data source's `submitAction` and nothing else. A sudo
## password is handed to the viewmodel as it is typed and is never drawn
## back.
##
## Every element a host test reads carries its fact (`data-ah-*`).

import std/strutils

import isonim/core/[signals, computation, batch]
import isonim/dsl/[ui, components]
import ./ah_cut_text

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import nim_agents/agent_harbor/fleet_records
import nim_agents_isonim_viewmodels/agent_harbor/[inbox_vm, inbox_item_vm]
import ./agent_harbor_changes_inbox_words

export signals, computation, components, inbox_vm, inbox_item_vm,
  agent_harbor_changes_inbox_words

const
  AgentHarborInboxClass* = "component-container agent-harbor-inbox"
  AgentHarborInboxItemClass* = "component-container agent-harbor-inbox-item"

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc setFlag[R, N](r: R; node: N; name: string; on: bool) =
  ## A boolean attribute, present only when `on`.
  mixin setAttribute
  if on: r.setAttribute(node, name, name)

proc renderRoleWord[R](r: R; text, role, cls: string): auto =
  ## A word in a role's colour with a dot before it.
  ui(r):
    span(class = cls & " ah-state-word " & roleClass(role), `data-ah-state-word` = text):
      span(class = "ah-state-dot"):
        discard
      span(class = "ah-state-text"):
        text text

proc renderChip[R](r: R; text, role, kind: string): auto =
  ui(r):
    span(class = "ah-chip " & roleClass(role), `data-ah-chip` = kind):
      text text

proc renderOverlay[R](r: R; message, kind: string): auto =
  ui(r):
    tdiv(class = "empty-overlay ah-inbox-notice", `data-ah-notice` = kind):
      text message

proc renderError[R](r: R; title, message: string; retry: proc()): auto =
  ui(r):
    tdiv(class = "ah-fleet-error", `data-ah-notice` = "error"):
      tdiv(class = "ah-fleet-error-title"):
        text title
      tdiv(class = "ah-fleet-error-message"):
        text message
      button(class = "ah-fleet-retry", onclick = retry):
        text RetryLabel

proc renderButton[R](r: R; label: string; primary, disabled: bool;
                     action: proc()): auto =
  ## A form's button: the filled primary or outlined.
  let node = ui(r):
    button(class = (if primary: "ct-button-sm-primary" else: "ct-button-sm-secondary") &
                   " ah-item-action", `data-ah-action` = label, onclick = action):
      text label
  r.setFlag(node, "disabled", disabled)
  node

# ---------------------------------------------------------------------------
# An item's page
# ---------------------------------------------------------------------------

proc renderTextField[R, N](r: R; page: InboxItemVM; ctx: AgentHarborInboxItemContext;
                           placeholder: string; disabled: bool): N =
  ## The page's text input. Its text is the viewmodel's, read once (untracked)
  ## so typing never rebuilds the field it types into.
  mixin inputValue
  var field: N
  let typed = untrack(proc(): string = page.text.val)
  result = ui(r):
    textarea(ref = field, class = "ah-text-field", rows = "3", placeholder = placeholder,
             `data-ah-input` = "answer",
             oninput = proc() =
               let v = r.inputValue(field)
               page.setText(v)
               if ctx.onTyping != nil: ctx.onTyping(v.strip.len > 0)):
      text typed
  r.setFlag(result, "disabled", disabled)

proc renderChoice[R, N](r: R; page: InboxItemVM; o: AnswerOption;
                        single, checked, disabled: bool): N =
  ## One option: a radio button or a checkbox, its label, its description.
  let id = o.id
  var box: N
  result = ui(r):
    label(class = "ah-choice"):
      input(ref = box, class = "ah-choice-input",
            `type` = (if single: "radio" else: "checkbox"), name = "ah-item-choice",
            value = id, onchange = proc() = page.toggleChoice(id))
      span(class = "ah-choice-label"):
        text o.label
      if o.description.len > 0:
        span(class = "ah-choice-description"):
          text o.description
  r.setFlag(box, "checked", checked)
  r.setFlag(box, "disabled", disabled)

proc renderChoices[R, N](r: R; page: InboxItemVM; options: seq[AnswerOption];
                         single, disabled: bool): N =
  ## Radio buttons (one choice) or checkboxes (several), each with its
  ## description.
  var host: N
  result = ui(r):
    tdiv(ref = host, class = "ah-choices", role = (if single: "radiogroup" else: "group"))
  let chosen = page.choices.val
  for o in options:
    r.appendRendered(host, renderChoice[R, N](r, page, o, single, o.id in chosen, disabled))

proc renderDraft[R, N](r: R; page: InboxItemVM; draft: Draft; disabled: bool): N =
  ## A manager's prepared draft: its provenance, rationale and text, and
  ## `Send draft`.
  var host: N
  let provenance = confidenceText(draft)
  result = ui(r):
    tdiv(ref = host, class = "ah-item-section ah-item-draft", `data-ah-draft` = "true"):
      tdiv(class = "ah-item-section-head"):
        span(class = "ah-item-section-name"):
          text DraftHead
        if provenance.len > 0:
          span(class = "ah-item-section-meta"):
            text provenance
      if draft.rationale.len > 0:
        tdiv(class = "ah-item-quiet"):
          text draft.rationale
      if draft.text.len > 0:
        tdiv(class = "ah-item-prose ah-item-draft-text"):
          text draft.text
      if draft.choices.len > 0:
        tdiv(class = "ah-item-prose ah-item-draft-text"):
          text draft.choices.join(", ")
  r.appendRendered(host, renderButton(r, SendDraftLabel, true, disabled,
                                      proc() = discard page.sendDraft()))

proc renderStatusLines[R, N](r: R; page: InboxItemVM; host: N) =
  ## Why a press sent nothing, and the page's last action's state: in their
  ## own effect, so a validation message never rebuilds the form.
  mixin clearChildren
  var lines: N
  let node = ui(r):
    tdiv(ref = lines, class = "ah-item-status-lines")
  r.appendRendered(host, node)
  createRenderEffect proc() =
    r.clearChildren(lines)
    let problem = page.validation.val
    if problem.len > 0:
      let v = ui(r):
        tdiv(class = "ah-item-validation " & roleClass("error"), `data-ah-validation` = problem):
          text problem
      r.appendRendered(lines, v)
    let phaseText = page.phaseText
    if phaseText.len > 0:
      let role = case page.phase
        of ppFailed: "error"
        of ppAnswered: "success"
        else: "quiet"
      let p = ui(r):
        tdiv(class = "ah-item-phase " & roleClass(role), `data-ah-phase` = $page.phase):
          text phaseText
      r.appendRendered(lines, p)

proc renderPriorityOption[R](r: R; p: InboxPriority): auto =
  ui(r):
    option(value = $p):
      text priorityKeyText(p)

proc renderPriorityMenu[R, N](r: R; page: InboxItemVM): N =
  ## The session's priority (keys `1`-`4`, or this menu): a write, through
  ## the viewmodel.
  mixin inputValue
  var sel: N
  result = ui(r):
    select(ref = sel, class = "ah-changes-select ah-priority-select", title = PriorityLabel,
           onchange = proc() =
             let v = r.inputValue(sel)
             if v.len > 0: discard page.setPriority(parsePriority(v)))
  let placeholder = ui(r):
    option(value = ""):
      text PriorityLabel & "\xE2\x80\xA6"
  r.appendRendered(sel, placeholder)
  for p in priorityChoices():
    r.appendRendered(sel, renderPriorityOption(r, p))

proc renderQuestion[R, N](r: R; page: InboxItemVM; d: InboxItemDetail;
                          ctx: AgentHarborInboxItemContext; host: N) =
  let banner = page.banner
  if banner.len > 0:
    let b = ui(r):
      tdiv(class = "ah-item-banner " & roleClass(if d.blocked: "warning" else: "info"),
           `data-ah-banner` = banner):
        span(class = "ah-state-dot"):
          discard
        span(class = "ah-item-banner-text"):
          text banner
    r.appendRendered(host, b)
  if d.prompt.len > 0:
    let q = ui(r):
      tdiv(class = "ah-item-prose ah-item-question"):
        text d.prompt
    r.appendRendered(host, q)
  if d.draft.present:
    r.appendRendered(host, renderDraft[R, N](r, page, d.draft, false))
  let noOptions = page.optionsNotice
  if noOptions.len > 0:
    let n = ui(r):
      tdiv(class = "ah-item-quiet", `data-ah-notice` = "no-options"):
        text noOptions
    r.appendRendered(host, n)
    return
  var actions: N
  let form = ui(r):
    tdiv(class = "ah-item-form")
  case d.form
  of qfFreeForm:
    r.appendRendered(form, renderTextField[R, N](r, page, ctx, AnswerPlaceholder, false))
  of qfSingle, qfMulti:
    r.appendRendered(form, renderChoices[R, N](r, page, d.options, d.form == qfSingle, false))
  of qfConfirmation: discard
  # The actions follow the field.
  let a = ui(r):
    tdiv(ref = actions, class = "ah-item-actions")
  case d.form
  of qfFreeForm, qfSingle, qfMulti:
    r.appendRendered(actions, renderButton(r, SubmitLabel, true, false,
                                           proc() = discard page.submit(ctx.nowMs)))
  of qfConfirmation:
    r.appendRendered(actions, renderButton(r, ApproveLabel, true, false, proc() =
      page.setDecision("approve")
      discard page.submit(ctx.nowMs)))
    r.appendRendered(actions, renderButton(r, RejectLabel, false, false, proc() =
      page.setDecision("reject")
      discard page.submit(ctx.nowMs)))
  r.appendRendered(form, a)
  r.appendRendered(host, form)

proc renderEndedTurn[R, N](r: R; page: InboxItemVM; d: InboxItemDetail;
                           ctx: AgentHarborInboxItemContext; host: N) =
  if d.lastReply.len > 0:
    let reply = ui(r):
      tdiv(class = "ah-item-section"):
        tdiv(class = "ah-item-section-head"):
          span(class = "ah-item-section-name"):
            text LastReplyHead
        tdiv(class = "ah-item-prose"):
          text d.lastReply
    r.appendRendered(host, reply)
  var actions: N
  let form = ui(r):
    tdiv(class = "ah-item-form")
  r.appendRendered(form, renderTextField[R, N](r, page, ctx, InstructionPlaceholder, false))
  let a = ui(r):
    tdiv(ref = actions, class = "ah-item-actions")
  r.appendRendered(actions, renderButton(r, SendLabel, true, false,
                                         proc() = discard page.submit(ctx.nowMs)))
  r.appendRendered(form, a)
  r.appendRendered(host, form)

proc renderApproval[R, N](r: R; page: InboxItemVM; a: ApprovalRequest): N =
  ## One queued sudo or network approval: `<command> in order to: <reason>`,
  ## a password field for sudo, Approve / Approve for session / Deny.
  mixin inputValue
  let requestId = a.requestId
  var actions, password: N
  result = ui(r):
    tdiv(class = "ah-item-approval", `data-ah-approval` = $a.scope):
      tdiv(class = "ah-item-prose ah-mono"):
        text approvalSummary(a)
      tdiv(ref = actions, class = "ah-item-actions")
  if a.scope == asSudo:
    let field = ui(r):
      input(ref = password, class = "ah-text-field ah-password-field", `type` = "password",
            placeholder = PasswordPlaceholder, autocomplete = "off",
            oninput = proc() = page.setPassword(r.inputValue(password)))
    r.appendRendered(actions, field)
  r.appendRendered(actions, renderButton(r, ApproveLabel, true, false,
    proc() = discard page.decideApproval(requestId, adApprove)))
  r.appendRendered(actions, renderButton(r, ApproveForSessionLabel, false, false,
    proc() = discard page.decideApproval(requestId, adApproveForSession)))
  r.appendRendered(actions, renderButton(r, DenyLabel, false, false,
    proc() = discard page.decideApproval(requestId, adDeny)))

proc renderPermission[R, N](r: R; page: InboxItemVM; d: InboxItemDetail; host: N) =
  if d.prompt.len > 0:
    let q = ui(r):
      tdiv(class = "ah-item-prose ah-item-question"):
        text d.prompt
    r.appendRendered(host, q)
  if d.permissionOptions.len > 0:
    var actions: N
    let a = ui(r):
      tdiv(ref = actions, class = "ah-item-actions ah-permission-options")
    for i, o in d.permissionOptions:
      let id = o.id
      r.appendRendered(actions, renderButton(r, o.label, i == 0, false,
                                             proc() = discard page.choosePermission(id)))
    r.appendRendered(host, a)
  for approval in d.approvals:
    r.appendRendered(host, renderApproval[R, N](r, page, approval))

proc renderLogin[R, N](r: R; page: InboxItemVM; d: InboxItemDetail;
                       ctx: AgentHarborInboxItemContext; host: N) =
  let login = d.login
  let state = page.loginText
  var actions: N
  let node = ui(r):
    tdiv(class = "ah-item-login", `data-ah-login` = $login.state):
      if login.provider.len > 0:
        tdiv(class = "ah-item-login-provider"):
          text login.provider
      if login.prompt.len > 0 and login.mode == lmLocalDesktop:
        tdiv(class = "ah-item-prose"):
          text login.prompt
      tdiv(class = "ah-item-login-state " &
                   roleClass(case login.state
                             of lsFailed: "error"
                             of lsCompleted: "success"
                             else: "quiet")):
        text state
      tdiv(ref = actions, class = "ah-item-actions")
  let pending = login.state == lsPending
  if pending and ctx.onOpenSignIn != nil:
    let open = ctx.onOpenSignIn
    r.appendRendered(actions, renderButton(r, OpenSignInLabel, true, false, proc() = open()))
  if pending:
    r.appendRendered(actions, renderButton(r, CancelLabel, ctx.onOpenSignIn == nil, false,
                                           proc() = discard page.cancelLogin()))
  r.appendRendered(host, node)

proc renderAttachment[R](r: R; att: Attachment): auto =
  ui(r):
    tdiv(`data-ah-cut` = "line", class = "ah-item-attachment", title = att.name):
      text attachmentText(att)

proc renderFeedback[R, N](r: R; page: InboxItemVM; d: InboxItemDetail;
                          ctx: AgentHarborInboxItemContext; host: N) =
  let fb = d.feedback
  let expired = page.isExpired(ctx.nowMs)
  let badge = page.expiredBadge(ctx.nowMs)
  if badge.len > 0:
    let b = ui(r):
      tdiv(class = "ah-item-expired"):
        span(class = "ah-chip " & roleClass("error"), `data-ah-chip` = "expired"):
          text badge
    r.appendRendered(host, b)
  if fb.prompt.len > 0:
    let q = ui(r):
      tdiv(class = "ah-item-prose ah-item-question"):
        text fb.prompt
    r.appendRendered(host, q)
  if fb.context.len > 0:
    let c = ui(r):
      tdiv(class = "ah-item-quiet ah-item-prose"):
        text fb.context
    r.appendRendered(host, c)
  if fb.attachments.len > 0:
    var list: N
    let a = ui(r):
      tdiv(ref = list, class = "ah-item-section ah-item-attachments"):
        tdiv(class = "ah-item-section-head"):
          span(class = "ah-item-section-name"):
            text AttachmentsHead
    for att in fb.attachments:
      r.appendRendered(list, renderAttachment(r, att))
    r.appendRendered(host, a)
  if d.draft.present:
    r.appendRendered(host, renderDraft[R, N](r, page, d.draft, expired))
  var actions: N
  let form = ui(r):
    tdiv(class = "ah-item-form")
  let a = ui(r):
    tdiv(ref = actions, class = "ah-item-actions")
  case fb.feedbackType
  of ftQuestion:
    r.appendRendered(form, renderTextField[R, N](r, page, ctx, ResponsePlaceholder, expired))
    r.appendRendered(actions, renderButton(r, SubmitLabel, true, expired,
                                           proc() = discard page.submit(ctx.nowMs)))
  of ftOptions:
    r.appendRendered(form, renderChoices[R, N](r, page, fb.options, false, expired))
    r.appendRendered(actions, renderButton(r, SubmitLabel, true, expired,
                                           proc() = discard page.submit(ctx.nowMs)))
  of ftConfirmation:
    r.appendRendered(actions, renderButton(r, ApproveLabel, true, expired, proc() =
      page.setDecision("approve")
      discard page.submit(ctx.nowMs)))
    r.appendRendered(actions, renderButton(r, RejectLabel, false, expired, proc() =
      page.setDecision("reject")
      discard page.submit(ctx.nowMs)))
  of ftInformation:
    r.appendRendered(actions, renderButton(r, AcknowledgeLabel, true, expired,
                                           proc() = discard page.submit(ctx.nowMs)))
  r.appendRendered(form, a)
  r.appendRendered(host, form)

proc renderItemPageBody[R, N](r: R; page: InboxItemVM; ctx: AgentHarborInboxItemContext;
                              body: N) =
  ## One page's content for its load state; the caller clears `body`.
  let target = page
  case page.state.val
  of asIdle, asLoading:
    r.appendRendered(body, renderOverlay(r, ItemLoadingNotice, "loading"))
  of asError:
    let unresolvable = page.notice
    if unresolvable.len > 0:
      r.appendRendered(body, renderOverlay(r, unresolvable, "unresolvable"))
    else:
      r.appendRendered(body, renderError(r, ItemErrorTitle, page.error.val,
                                         proc() = target.load()))
  of asReady:
    let d = page.detail
    var head: N
    let headNode = ui(r):
      tdiv(ref = head, class = "ah-item-head", `data-ah-kind` = $d.kind):
        span(class = "ah-item-mark " & roleClass(kindRole(d.kind))):
          discard
        span(class = "ah-item-kind"):
          text kindWordOf(d.kind)
        if ctx.sessionLabel.len > 0:
          span(`data-ah-cut` = "line", class = "ah-item-session", title = ctx.sessionLabel):
            text ctx.sessionLabel
    r.appendRendered(head, renderPriorityMenu[R, N](r, page))
    r.appendRendered(body, headNode)
    if page.leadsWithSummary:
      let s = ui(r):
        tdiv(class = "ah-item-section ah-item-summary", `data-ah-summary-first` = "true"):
          tdiv(class = "ah-item-section-head"):
            span(class = "ah-item-section-name"):
              text SummaryHead
          tdiv(class = "ah-item-prose"):
            text d.executiveSummary
      r.appendRendered(body, s)
    case d.kind
    of ikBlockedQuestion, ikUnknown: renderQuestion[R, N](r, page, d, ctx, body)
    of ikEndedTurn: renderEndedTurn[R, N](r, page, d, ctx, body)
    of ikPermissionGate: renderPermission[R, N](r, page, d, body)
    of ikLoginRequest: renderLogin[R, N](r, page, d, ctx, body)
    of ikAsyncFeedback: renderFeedback[R, N](r, page, d, ctx, body)
    renderStatusLines[R, N](r, page, body)

proc renderAgentHarborInboxItemPage*[R, N](r: R; page: InboxItemVM;
    ctx = AgentHarborInboxItemContext()): N =
  ## An item's page over `page`, standing alone (the session tab's page).
  mixin clearChildren
  var body: N
  result = ui(r):
    tdiv(class = AgentHarborInboxItemClass):
      tdiv(ref = body, class = "ah-fleet-body ah-item-page")
  createRenderEffect proc() =
    r.clearChildren(body)
    discard page.revision.val
    renderItemPageBody[R, N](r, page, ctx, body)

# ---------------------------------------------------------------------------
# The Inbox panel
# ---------------------------------------------------------------------------

proc renderStepper[R, N](r: R; vm: InboxVM): N =
  ## `←  3 of 5  →  Auto-switch: off`; at a narrow width the arrows and
  ## `Auto: off` (both forms are drawn, the stylesheet shows one).
  let canPrev = vm.canPrev
  let canNext = vm.canNext
  let position = vm.positionText
  let on = vm.autoSwitch.val
  var prev, next: N
  result = ui(r):
    tdiv(class = "ah-inbox-stepper", role = "group", `data-ah-position` = position):
      button(ref = prev, class = "ah-step ah-step-prev", title = stepperTitle(false),
             onclick = proc() = discard vm.prev()):
        text PreviousArrow
      span(class = "ah-step-position"):
        text position
      button(ref = next, class = "ah-step ah-step-next", title = stepperTitle(true),
             onclick = proc() = discard vm.next()):
        text NextArrow
      button(class = "ah-auto-switch" & (if on: " ah-auto-switch-on" else: ""),
             title = AutoSwitchTitle, `data-ah-auto-switch` = (if on: "on" else: "off"),
             onclick = proc() = vm.setAutoSwitch(not on)):
        span(class = "ah-auto-full"):
          text autoSwitchText(on, compact = false)
        span(class = "ah-auto-compact"):
          text autoSwitchText(on, compact = true)
  r.setFlag(prev, "disabled", not canPrev)
  r.setFlag(next, "disabled", not canNext)

proc renderRow[R, N](r: R; vm: InboxVM; ctx: AgentHarborInboxContext;
                     item: InboxItem; onScreen: bool; pending: int): N =
  let itemRef = item.refOf
  let label = if item.session.label.len > 0: item.session.label else: item.session.title
  let priority = priorityChip(item)
  let warmth = warmthChip(item.warmth, ctx.nowMs)
  let age = ageLabel(ctx.nowMs, item.enteredAtMs)
  let holder = holderText(item)
  var line1, line2: N
  result = ui(r):
    tdiv(class = "ah-inbox-row" & (if onScreen: " ah-inbox-row-current" else: ""),
         role = "button", tabindex = "0", title = label,
         `data-ah-item` = item.id, `data-ah-kind` = item.kindText,
         `data-ah-position` = $item.position,
         onclick = proc() = vm.open(itemRef)):
      span(class = "ah-item-mark " & roleClass(kindRole(item.kind))):
        discard
      tdiv(class = "ah-inbox-row-main"):
        tdiv(ref = line1, class = "ah-inbox-row-line"):
          span(`data-ah-cut` = "line", class = "ah-inbox-row-label", title = label):
            text label
        tdiv(ref = line2, class = "ah-inbox-row-line ah-inbox-row-meta"):
          span(class = "ah-inbox-kind"):
            text kindWord(item)
        if item.explanation.len > 0:
          tdiv(class = "ah-inbox-explanation", `data-ah-explanation` = item.explanation):
            text item.explanation
  if priority.len > 0:
    r.appendRendered(line1, renderChip(r, priority, priorityRole(item), "priority"))
  if warmth.len > 0:
    r.appendRendered(line1, renderChip(r, warmth, warmthRole(warmth), "warmth"))
  if age.len > 0:
    let a = ui(r):
      span(class = "ah-inbox-age"):
        text age
    r.appendRendered(line1, a)
  if holder.len > 0:
    r.appendRendered(line2, renderRoleWord(r, holder,
                                           (if item.heldBy == ihOperator: "warning" else: "quiet"),
                                           "ah-inbox-holder"))
  let pendingText = pendingCountText(pending)
  if item.kind == ikAsyncFeedback and pendingText.len > 0:
    r.appendRendered(line2, renderChip(r, pendingText, "info", "pending"))
  if item.kind == ikUnknown:
    let open = ui(r):
      button(class = "ct-button-sm-secondary ah-inbox-open", onclick = proc() = vm.open(itemRef)):
        text OpenLabel
    r.appendRendered(line2, open)

proc renderRows[R, N](r: R; vm: InboxVM; ctx: AgentHarborInboxContext; list: N) =
  ## The rows in the server's order. A run of rows from another server is
  ## headed by its name; the order is never changed to group them.
  let items = vm.items
  var fleet = false
  for item in items:
    if item.server.len > 0: fleet = true
  let current = vm.current.val
  var i = 0
  while i < items.len:
    if fleet:
      let server = items[i].server
      var j = i
      while j < items.len and items[j].server == server: inc j
      let head = ui(r):
        tdiv(class = "ah-inbox-server-head", `data-ah-server` = server):
          span(`data-ah-cut` = "line", class = "ah-inbox-server-name"):
            text (if server.len > 0: server else: ThisServerLabel)
          span(class = "ah-inbox-server-count"):
            text $(j - i)
      r.appendRendered(list, head)
      for k in i ..< j:
        r.appendRendered(list, renderRow[R, N](r, vm, ctx, items[k], items[k].refOf == current,
                                               pendingFeedbackFor(items, items[k].session.id)))
      i = j
    else:
      r.appendRendered(list, renderRow[R, N](r, vm, ctx, items[i], items[i].refOf == current,
                                             pendingFeedbackFor(items, items[i].session.id)))
      inc i

proc renderDegraded[R](r: R; line: string): auto =
  ## `Incomplete: <server> could not be read (<reason>)`.
  ui(r):
    tdiv(class = "ah-inbox-degraded " & roleClass("warning"), `data-ah-degraded` = line):
      text line

proc renderAgentHarborInboxPanel*[R, N](r: R; vm: InboxVM;
    ctx = AgentHarborInboxContext()): N =
  ## The Inbox panel over `vm`; with the viewmodel's pages on, the item on
  ## screen's page under the rows.
  mixin clearChildren, setAttribute
  var body: N
  let panel = ui(r):
    tdiv(class = AgentHarborInboxClass):
      tdiv(ref = body, class = "ah-fleet-body ah-inbox-body")
  let itemCtx = AgentHarborInboxItemContext(nowMs: ctx.nowMs, onOpenSignIn: ctx.onOpenSignIn,
    onTyping: proc(typing: bool) = vm.setTyping(typing))
  createRenderEffect proc() =
    r.clearChildren(body)
    discard vm.revision.val
    let ready = vm.state.val == asReady
    let counts = if ready: inboxCountsText(vm) else: ""
    let head = ui(r):
      tdiv(class = "ah-fleet-head", title = (if ready: vm.controlTitle else: "")):
        tdiv(class = "ah-fleet-section-header"):
          span(class = "ah-fleet-title"):
            text InboxSectionLabel
          span(`data-ah-cut` = "line", class = "ah-fleet-source", title = ctx.scope):
            text ctx.scope
          span(class = "ah-fleet-summary", `data-ah-counts` = counts):
            text counts
    r.appendRendered(body, head)
    let target = vm
    case vm.state.val
    of asIdle, asLoading:
      r.appendRendered(body, renderOverlay(r, vm.notice(), "loading"))
      return
    of asError:
      r.appendRendered(body, renderError(r, InboxErrorTitle, vm.error.val,
                                         proc() = target.restart()))
      return
    of asReady: discard
    r.appendRendered(body, renderStepper[R, N](r, vm))
    if vm.cursorError.val.len > 0:
      let e = ui(r):
        tdiv(class = "ah-inbox-degraded " & roleClass("error")):
          text vm.cursorError.val
      r.appendRendered(body, e)
    for line in vm.degradedText:
      r.appendRendered(body, renderDegraded(r, line))
    var list, pageHost: N
    let main = ui(r):
      tdiv(class = "ah-inbox-main"):
        tdiv(ref = list, class = "ah-fleet-list ah-inbox-list", role = "list")
        tdiv(ref = pageHost, class = "ah-inbox-page")
    r.appendRendered(body, main)
    let notice = vm.notice()
    if notice.len > 0:
      r.appendRendered(list, renderOverlay(r, notice, "empty"))
    else:
      renderRows[R, N](r, vm, ctx, list)
    let page = vm.page
    if page.isNil:
      r.setAttribute(pageHost, "hidden", "hidden")
    else:
      let strip = vm.explanationStrip
      if strip.len > 0:
        let s = ui(r):
          tdiv(class = "ah-inbox-strip", `data-ah-strip` = strip):
            text strip
        r.appendRendered(pageHost, s)
      var pageBody: N
      let label = block:
        let found = vm.currentItem
        if found.found: found.item.session.label else: ""
      let pageNode = ui(r):
        tdiv(ref = pageBody, class = "ah-item-page")
      r.appendRendered(pageHost, pageNode)
      var pageCtx = itemCtx
      pageCtx.sessionLabel = label
      createRenderEffect proc() =
        r.clearChildren(pageBody)
        discard page.revision.val
        renderItemPageBody[R, N](r, page, pageCtx, pageBody)
  panel

when defined(js):
  proc mountAgentHarborInboxPanel*(container: isonim_dom.Element; vm: InboxVM;
                                   ctx = AgentHarborInboxContext()) =
    ## Mounts the Inbox panel; its item pages are visible while it is
    ## mounted (their viewing heartbeat runs).
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborInboxPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm, ctx)))
    if vm.showPages: vm.setPagesVisible(true)

  proc mountAgentHarborInboxItemPage*(container: isonim_dom.Element; page: InboxItemVM;
                                      ctx = AgentHarborInboxItemContext()) =
    ## Mounts an item's page; it is visible while mounted (its viewing
    ## heartbeat runs).
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborInboxItemPage[WebRenderer, isonim_dom.Element](WebRenderer(), page, ctx)))
    page.setVisible(true)
