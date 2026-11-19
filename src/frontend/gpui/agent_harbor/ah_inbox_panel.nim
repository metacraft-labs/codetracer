## gpui/agent_harbor/ah_inbox_panel.nim — CTF-P3. The GPUI views of the
## operator's Agent Harbor inbox: the Inbox panel over `InboxVM` and an
## item's page over `InboxItemVM` (nim-agents-isonim-viewmodels `inbox_vm`,
## `inbox_item_vm`).
##
## The web prototype is `viewmodel/views/isonim_agent_harbor_inbox_view.nim`,
## styled by `styles/components/agent_harbor_inbox.styl`; this view draws
## the same parts, in the same order, at the stylesheet's sizes:
##
## - the header strip (`INBOX`, whose inbox it is, the counts), the
##   Initiative Progress panel's (`ah_initiative_panels.drawSectionHeader`);
## - Previous / Next: `←  3 of 5  →  Auto-switch: off`, and on a panel 50rem
##   wide or narrower the arrows and `Auto: off` without the position, a
##   disabled arrow in the disabled colours;
## - each server the inbox could not read, `Incomplete: …`;
## - one row per item in the server's order, never re-sorted (the kind's
##   mark, the session's label, the priority and warmth chips and the age;
##   the kind's words, who holds an item whose agent died, the pending
##   feedback count, `Open` for a kind the client does not know; the
##   server's explanation as served), a run of rows from another server
##   headed by its name; the row of the item on screen a selection (the
##   raised fill and the action-colour inset bar);
## - with the viewmodel's pages on, the item on screen's page under the rows,
##   or beside them on a panel 60rem wide or wider, headed by the
##   explanation strip while it was reached through Previous or Next.
##
## An item's page draws what the agent asks or reports and the form that
## answers it, for each kind and state the viewmodel gives (a question in
## each form, an ended turn, a permission request, sudo and network
## approvals, a login request in each state, a feedback request of each
## type, a manager's draft, the executive summary first), and the
## viewmodel's answer state and validation under it.
##
## Rows and the page are cardless, on the panel's ground. A form's first
## action is the filled primary button and the others are outlined. Every
## press calls the viewmodel, which validates it and sends it through the
## data source's `submitAction` and nothing else; a host action (`Open
## sign-in`, a completed sign-in's `Continue`) is drawn only when the host
## gives one. A sudo password is never drawn. The words are the viewmodels'
## and those of `viewmodel/views/agent_harbor_changes_inbox_words.nim`, which
## the web view says too.

import ../../../common/pointer_shape
import std/strutils

import isonim/core/[signals, computation]
import nim_agents/agent_harbor/fleet_records
import nim_agents_isonim_viewmodels/agent_harbor/[inbox_vm, inbox_item_vm]
import ../../viewmodel/views/agent_harbor_changes_inbox_words

import ./ah_changes_inbox_parts
from ./ah_initiative_panels import drawSectionHeader

export inbox_vm, inbox_item_vm, ah_changes_inbox_parts

const
  CompactStepperMaxPx* = 800
    ## `@container ah-inbox (max-width: 50rem)`: at this panel width and
    ## narrower the Previous / Next group drops the position and says
    ## `Auto: off`.
  PageBesideMinPx* = 960
    ## `@container ah-inbox (min-width: 60rem)`: at this panel width and
    ## wider the item's page stands beside the rows.
  ListBesidePx = 416       ## `.ah-inbox-list`: 26rem beside the page
  BarPx = 2                ## the focus inset bar, 0.125rem
  PasswordPx = 192         ## `.ah-password-field`: 12rem
  ChoiceMarkPx = 13        ## a radio button or a checkbox, as the browser draws one
  RowLinePx = 24           ## a line of an inbox row's label line: the panel's line
  NativeBorder = "#767676" ## Chromium's unstyled checkbox and radio outline
  NativeAccent = "#0075ff" ## Chromium's default accent, a chosen checkbox's fill

# ---------------------------------------------------------------------------
# An item's page
# ---------------------------------------------------------------------------

type
  PageCtx = object
    ## What every part of a page draws with.
    p: AhPalette
    ink: ChangesInboxInks
    page: InboxItemVM
    ctx: AgentHarborInboxItemContext
    avail: int             ## the page's inner width

proc actions(r: GpuiRenderer; c: PageCtx; buttons: seq[(string, bool, bool, proc())]): GpuiElement =
  ## `.ah-item-actions`: the buttons 6px apart, wrapping onto 24px lines.
  var items: seq[FlowItem]
  for (label, primary, disabled, action) in buttons:
    items.add FlowItem(el: r.actionButton(c.p, c.ink, label, primary, action, disabled),
                       widthPx: actionButtonPx(label))
  result = r.flowLines(items, c.avail, 6, ControlPx, 6)
  r.setStyle(result, "flex-shrink", "0")
  r.tag(result, "actions", $buttons.len)

proc prose(r: GpuiRenderer; c: PageCtx; text: string; sizePx = BodyPx;
           fact = "prose"): GpuiElement =
  ## `.ah-item-prose`: body text on 24px lines, wrapping (`.ah-item-question`
  ## at the large body size).
  result = r.wrapping(text, sizePx, BodyLinePx, c.p.textBody)
  r.tag(result, fact, text)

proc quiet(r: GpuiRenderer; c: PageCtx; text: string): GpuiElement =
  ## `.ah-item-quiet`: the caption size on 16px lines in the caption colour.
  r.wrapping(text, CaptionPx, ShortLinePx, c.p.textCaption)

proc section(r: GpuiRenderer; c: PageCtx; name, meta: string): GpuiElement =
  ## `.ah-item-section`: a column, 4px apart, under its small-caps head.
  result = r.box(column = true, pairs = [("gap", "4px"), ("flex-shrink", "0"),
                                         ("min-width", "0px")])
  # `.ah-item-section-head`: on the panel's 24px line.
  let head = r.box(pairs = [("gap", "8px"), ("items", "center"), ("min-width", "0px"),
                            ("height", $BodyLinePx & "px"), ("flex-shrink", "0")])
  r.appendChild(head, r.sectionLabel(c.p, name))
  if meta.len > 0:
    r.appendChild(head, r.text(meta, CaptionPx, c.p.textCaption))
  r.appendChild(result, head)

proc textInput(r: GpuiRenderer; c: PageCtx; placeholder: string; disabled: bool): GpuiElement =
  result = r.textField(c.p, c.ink, c.page.text.val, placeholder, disabled)
  r.tag(result, "answer-field", placeholder)

proc drawChoices(r: GpuiRenderer; c: PageCtx; options: seq[AnswerOption];
                 single, disabled: bool): GpuiElement =
  ## Radio buttons (one choice) or checkboxes (several), each with its
  ## label and description (`.ah-choices`, `.ah-choice`), 4px apart.
  result = r.box(column = true, pairs = [("gap", "4px"), ("flex-shrink", "0")])
  r.tag(result, "choices", if single: "single" else: "multi")
  let chosen = c.page.choices.val
  let page = c.page
  for o in options:
    let id = o.id
    let checked = id in chosen
    # `.ah-choice` is a `label`, which the shared stylesheet gives 8px
    # below; on the panel's 24px line.
    let line = r.box(pairs = [("gap", "8px"), ("items", "start"), ("min-width", "0px"),
                              ("height", $BodyLinePx & "px"), ("margin-bottom", "8px"),
                              ("flex-shrink", "0"), ("cursor", cursorOf(hkControl))])
    r.tag(line, "choice", id)
    r.tag(line, "checked", $checked)
    # The browser's own radio button (round) and checkbox (2px corners), as
    # Chromium draws them unstyled: 13px, 4px down on the label's baseline, a
    # grey outline on white, its accent blue when chosen
    # (https://html.spec.whatwg.org/multipage/input.html#checkbox-state-(type=checkbox)
    # leaves the look to the browser; these are Chromium's defaults).
    let markEl = r.box(pairs = [("width", $ChoiceMarkPx & "px"),
                                ("height", $ChoiceMarkPx & "px"), ("margin-top", "4px"),
                                ("rounded", (if single: $(ChoiceMarkPx div 2) else: "2") & "px"),
                                ("border-width", "1px"),
                                ("border-color", if checked: NativeAccent else: NativeBorder),
                                ("background", if checked: NativeAccent else: "#ffffff"),
                                ("flex-shrink", "0")])
    r.appendChild(line, markEl)
    let label = r.text(o.label, BodyPx, if disabled: c.p.textDisabled else: c.p.textBody,
                       shrink = false, pairs = [("line-height", $BodyLinePx & "px")])
    r.tag(label, "choice-label", o.label)
    r.appendChild(line, label)
    if o.description.len > 0:
      r.appendChild(line, r.text(o.description, CaptionPx, c.p.textCaption,
                                 pairs = [("line-height", $BodyLinePx & "px")]))
    if not disabled: r.addEventListener(line, "click", proc() = page.toggleChoice(id))
    r.appendChild(result, line)

proc drawDraft(r: GpuiRenderer; c: PageCtx; draft: Draft; disabled: bool): GpuiElement =
  ## A manager's draft (`.ah-item-draft`): 8px in past an inset bar in the
  ## information border role; its provenance, rationale and text, `Send
  ## draft`.
  result = r.section(c, DraftHead, confidenceText(draft))
  r.styles(result, [("padding-left", "8px"), ("position", "relative")])
  r.appendChild(result, r.insetBar(c.ink.borderInfo, BarPx))
  r.tag(result, "draft", "true")
  if draft.rationale.len > 0: r.appendChild(result, r.quiet(c, draft.rationale))
  if draft.text.len > 0: r.appendChild(result, r.prose(c, draft.text, fact = "draft-text"))
  if draft.choices.len > 0:
    r.appendChild(result, r.prose(c, draft.choices.join(", "), fact = "draft-text"))
  # The web view appends `Send draft` to the draft's column itself, not in
  # an actions row, so the button takes the column's whole width.
  let page = c.page
  let send = r.actionButton(c.p, c.ink, SendDraftLabel, true,
                            proc() = discard page.sendDraft(), disabled)
  r.setStyle(send, "justify", "start")
  r.appendChild(result, send)

proc drawBanner(r: GpuiRenderer; c: PageCtx; text, role: string): GpuiElement =
  ## A question's banner (`.ah-item-banner`): a band on the raised ground,
  ## 6px by 8px in, rounded 4px, the dot in its role and the words at the
  ## body size.
  result = r.box(pairs = [("gap", "8px"), ("items", "center"), ("padding-top", "6px"),
                          ("padding-bottom", "6px"), ("padding-left", "8px"),
                          ("padding-right", "8px"), ("rounded", "4px"),
                          ("background", c.p.secondary), ("flex-shrink", "0")])
  r.tag(result, "banner", text)
  r.tag(result, "role", role)
  r.appendChild(result, r.mark(c.p.roleDot(role), StateDotPx))
  r.appendChild(result, r.wrapping(text, BodyPx, BodyLinePx, c.p.roleInk(c.ink, role)))

proc drawQuestion(r: GpuiRenderer; c: PageCtx; d: InboxItemDetail; body: GpuiElement) =
  let page = c.page
  let banner = page.banner
  if banner.len > 0:
    r.appendChild(body, r.drawBanner(c, banner, if d.blocked: "warning" else: "info"))
  if d.prompt.len > 0: r.appendChild(body, r.prose(c, d.prompt, BodyLargePx, "question"))
  if d.draft.present: r.appendChild(body, r.drawDraft(c, d.draft, false))
  let noOptions = page.optionsNotice
  if noOptions.len > 0:
    let n = r.quiet(c, noOptions)
    r.tag(n, "no-options", noOptions)
    r.appendChild(body, n)
    return
  let form = r.box(column = true, pairs = [("gap", "6px"), ("flex-shrink", "0")])
  r.tag(form, "form", $d.form)
  let now = c.ctx.nowMs
  case d.form
  of qfFreeForm:
    r.appendChild(form, r.textInput(c, AnswerPlaceholder, false))
  of qfSingle, qfMulti:
    r.appendChild(form, r.drawChoices(c, d.options, d.form == qfSingle, false))
  of qfConfirmation: discard
  case d.form
  of qfFreeForm, qfSingle, qfMulti:
    r.appendChild(form, r.actions(c, @[(SubmitLabel, true, false,
                                        proc() = discard page.submit(now))]))
  of qfConfirmation:
    r.appendChild(form, r.actions(c, @[
      (ApproveLabel, true, false, proc() =
        page.setDecision("approve")
        discard page.submit(now)),
      (RejectLabel, false, false, proc() =
        page.setDecision("reject")
        discard page.submit(now))]))
  r.appendChild(body, form)

proc drawEndedTurn(r: GpuiRenderer; c: PageCtx; d: InboxItemDetail; body: GpuiElement) =
  if d.lastReply.len > 0:
    let reply = r.section(c, LastReplyHead, "")
    r.appendChild(reply, r.prose(c, d.lastReply, fact = "last-reply"))
    r.appendChild(body, reply)
  let page = c.page
  let now = c.ctx.nowMs
  let form = r.box(column = true, pairs = [("gap", "6px"), ("flex-shrink", "0")])
  r.tag(form, "form", "instruction")
  r.appendChild(form, r.textInput(c, InstructionPlaceholder, false))
  r.appendChild(form, r.actions(c, @[(SendLabel, true, false,
                                      proc() = discard page.submit(now))]))
  r.appendChild(body, form)

proc drawApproval(r: GpuiRenderer; c: PageCtx; a: ApprovalRequest): GpuiElement =
  ## One queued sudo or network approval (`.ah-item-approval`): over a
  ## hairline, 6px above and below; `<command> in order to: <reason>` in
  ## Space Mono, then (sudo) the password field and the three decisions.
  result = r.box(column = true, pairs = [("gap", "6px"), ("padding-top", "6px"),
                                         ("padding-bottom", "6px"), ("flex-shrink", "0"),
                                         ("border-top-width", "1px"),
                                         ("border-color", c.p.borderSecondary)])
  r.tag(result, "approval", $a.scope)
  let summary = r.mono(r.prose(c, approvalSummary(a), fact = "approval-summary"))
  r.appendChild(result, summary)
  let page = c.page
  let requestId = a.requestId
  var items: seq[FlowItem]
  if a.scope == asSudo:
    # The password field: what is typed is the viewmodel's to hold and is
    # never drawn back, so the field shows its placeholder, or that a
    # password was given.
    let field = r.box(pairs = [("width", $PasswordPx & "px"), ("height", $ControlPx & "px"),
                               ("items", "center"), ("padding-left", "8px"),
                               ("padding-right", "8px"), ("border-width", "1px"),
                               ("border-color", c.p.borderSecondary), ("rounded", "6px"),
                               ("background", c.ink.inputSurface), ("flex-shrink", "0")])
    r.tag(field, "password-field", $page.passwordSet.val)
    r.appendChild(field, r.text(if page.passwordSet.val: "\xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2"
                                else: PasswordPlaceholder, BodyPx,
                                if page.passwordSet.val: c.p.textBody else: c.ink.placeholder))
    items.add FlowItem(el: field, widthPx: PasswordPx)
  for (label, primary, decision) in [(ApproveLabel, true, adApprove),
                                     (ApproveForSessionLabel, false, adApproveForSession),
                                     (DenyLabel, false, adDeny)]:
    let choice = decision
    items.add FlowItem(el: r.actionButton(c.p, c.ink, label, primary,
                                          proc() = discard page.decideApproval(requestId, choice)),
                       widthPx: actionButtonPx(label))
  let row = r.flowLines(items, c.avail, 6, ControlPx, 6)
  r.tag(row, "actions", $items.len)
  r.appendChild(result, row)

proc drawPermission(r: GpuiRenderer; c: PageCtx; d: InboxItemDetail; body: GpuiElement) =
  if d.prompt.len > 0: r.appendChild(body, r.prose(c, d.prompt, BodyLargePx, "question"))
  let page = c.page
  if d.permissionOptions.len > 0:
    var buttons: seq[(string, bool, bool, proc())]
    for i, o in d.permissionOptions:
      let id = o.id
      buttons.add (o.label, i == 0, false, proc() = discard page.choosePermission(id))
    let a = r.actions(c, buttons)
    r.tag(a, "permission-options", $d.permissionOptions.len)
    r.appendChild(body, a)
  for approval in d.approvals: r.appendChild(body, r.drawApproval(c, approval))

proc drawLogin(r: GpuiRenderer; c: PageCtx; d: InboxItemDetail; body: GpuiElement) =
  ## A login request in the state the viewmodel gives it (`.ah-item-login`):
  ## the provider, the prompt, the state line, an inline error, and `Open
  ## sign-in` and `Cancel` while Cancel is offered, `Continue` once it
  ## completed (when the host can move on).
  let page = c.page
  let login = d.login
  let hasRequest = page.hasLoginRequest
  let state = page.loginState
  let error = page.loginError
  let canCancel = page.canCancelLogin
  let loginBox = r.box(column = true, pairs = [("gap", "6px"), ("flex-shrink", "0")])
  r.tag(loginBox, "login", if hasRequest: $state else: "none")
  if hasRequest and login.provider.len > 0:
    let provider = r.wrapping(login.provider, BodyLargePx, BodyLinePx, c.p.textBody)
    r.tag(provider, "login-provider", login.provider)
    r.appendChild(loginBox, provider)
  if hasRequest and login.prompt.len > 0 and login.mode == lmLocalDesktop:
    r.appendChild(loginBox, r.prose(c, login.prompt))
  let stateText = page.loginText
  let line = r.wrapping(stateText, BodyPx, BodyLinePx, c.p.roleInk(c.ink, loginStateRole(state, hasRequest)))
  r.tag(line, "login-state", stateText)
  r.appendChild(loginBox, line)
  if error.len > 0:
    let e = r.wrapping(error, CaptionPx, ShortLinePx, c.p.textError)
    r.tag(e, "login-error", error)
    r.appendChild(loginBox, e)
  var buttons: seq[(string, bool, bool, proc())]
  if canCancel and c.ctx.onOpenSignIn != nil:
    let open = c.ctx.onOpenSignIn
    buttons.add (OpenSignInLabel, true, false, proc() = open())
  if canCancel:
    buttons.add (CancelLabel, c.ctx.onOpenSignIn == nil, false,
                 proc() = discard page.cancelLogin())
  if page.canContinueLogin and c.ctx.onContinue != nil:
    let onContinue = c.ctx.onContinue
    buttons.add (ContinueLabel, true, false, proc() = onContinue())
  if buttons.len > 0: r.appendChild(loginBox, r.actions(c, buttons))
  r.appendChild(body, loginBox)

proc drawFeedback(r: GpuiRenderer; c: PageCtx; d: InboxItemDetail; body: GpuiElement) =
  let page = c.page
  let fb = d.feedback
  let now = c.ctx.nowMs
  let expired = page.isExpired(now)
  let badge = page.expiredBadge(now)
  if badge.len > 0:
    # `.ah-item-expired`: the chip on the panel's 24px line.
    let b = r.box(pairs = [("flex-shrink", "0"), ("height", $BodyLinePx & "px"),
                           ("items", "center")])
    r.appendChild(b, r.chip(c.p, c.ink, badge, "error", "expired"))
    r.appendChild(body, b)
  if fb.prompt.len > 0: r.appendChild(body, r.prose(c, fb.prompt, BodyLargePx, "question"))
  if fb.context.len > 0:
    # `ah-item-quiet ah-item-prose`: the quiet rule comes later in the
    # stylesheet, so the context is a caption on 16px lines that wraps.
    let q = r.quiet(c, fb.context)
    r.tag(q, "context", fb.context)
    r.appendChild(body, q)
  if fb.attachments.len > 0:
    let list = r.section(c, AttachmentsHead, "")
    for att in fb.attachments:
      # `.ah-item-attachment`: on the panel's 24px line.
      let a = r.mono(r.text(attachmentText(att), CaptionPx, c.p.textLabel,
                            pairs = [("line-height", $BodyLinePx & "px")]))
      r.tag(a, "attachment", attachmentText(att))
      r.appendChild(list, a)
    r.appendChild(body, list)
  if d.draft.present: r.appendChild(body, r.drawDraft(c, d.draft, expired))
  let form = r.box(column = true, pairs = [("gap", "6px"), ("flex-shrink", "0")])
  r.tag(form, "form", $fb.feedbackType)
  case fb.feedbackType
  of ftQuestion:
    r.appendChild(form, r.textInput(c, ResponsePlaceholder, expired))
    r.appendChild(form, r.actions(c, @[(SubmitLabel, true, expired,
                                        proc() = discard page.submit(now))]))
  of ftOptions:
    r.appendChild(form, r.drawChoices(c, fb.options, false, expired))
    r.appendChild(form, r.actions(c, @[(SubmitLabel, true, expired,
                                        proc() = discard page.submit(now))]))
  of ftConfirmation:
    r.appendChild(form, r.actions(c, @[
      (ApproveLabel, true, expired, proc() =
        page.setDecision("approve")
        discard page.submit(now)),
      (RejectLabel, false, expired, proc() =
        page.setDecision("reject")
        discard page.submit(now))]))
  of ftInformation:
    r.appendChild(form, r.actions(c, @[(AcknowledgeLabel, true, expired,
                                        proc() = discard page.submit(now))]))
  r.appendChild(body, form)

proc drawStatusLines(r: GpuiRenderer; c: PageCtx; body: GpuiElement) =
  ## Why the last press sent nothing, and the page's last action's state
  ## (`.ah-item-status-lines`), each at the caption size in its role.
  let page = c.page
  let problem = page.validation.val
  let phaseText = page.phaseText
  if problem.len == 0 and phaseText.len == 0: return
  let lines = r.box(column = true, pairs = [("gap", "4px"), ("flex-shrink", "0")])
  if problem.len > 0:
    let v = r.wrapping(problem, CaptionPx, ShortLinePx, c.p.textError)
    r.tag(v, "validation", problem)
    r.appendChild(lines, v)
  if phaseText.len > 0:
    let role = case page.phase
      of ppFailed: "error"
      of ppAnswered: "success"
      else: "quiet"
    let ph = r.wrapping(phaseText, CaptionPx, ShortLinePx, c.p.roleInk(c.ink, role))
    r.tag(ph, "phase", $page.phase)
    r.tag(ph, "phase-text", phaseText)
    r.appendChild(lines, ph)
  r.appendChild(body, lines)

proc drawItemHead(r: GpuiRenderer; c: PageCtx; d: InboxItemDetail): GpuiElement =
  ## The page's head (`.ah-item-head`): the kind's mark, its words in small
  ## caps, the session's label taking the free width, the priority menu at
  ## the right.
  result = r.box(pairs = [("gap", "8px"), ("items", "center"), ("min-width", "0px"),
                          ("flex-shrink", "0")])
  r.tag(result, "item-kind", $d.kind)
  let role = kindRole(d.kind)
  r.appendChild(result, r.mark(c.p.roleDot(role), ItemMarkPx))
  let kind = r.sectionLabel(c.p, kindWordOf(d.kind))
  r.tag(kind, "kind-words", kindWordOf(d.kind).toUpperAscii)
  r.appendChild(result, kind)
  let session = r.text(c.ctx.sessionLabel, CaptionPx, c.p.textCaption)
  r.fillWidth(session)
  r.tag(session, "item-session", c.ctx.sessionLabel)
  r.appendChild(result, session)
  var labels: seq[string]
  for pr in priorityChoices(): labels.add priorityKeyText(pr)
  let menu = r.selectBox(c.p, PriorityLabel & "\xE2\x80\xA6", labels, "priority-menu")
  r.setStyle(menu, "flex-shrink", "0")
  r.appendChild(result, menu)

proc drawItemPageBody*(r: GpuiRenderer; p: AhPalette; page: InboxItemVM;
                       ctx: AgentHarborInboxItemContext; body: GpuiElement; widthPx: int) =
  ## One page's content for its load state, into `body` (which the caller
  ## clears); `widthPx` is the page's own width.
  let c = PageCtx(p: p, ink: changesInboxInks(p.mode), page: page, ctx: ctx,
                  avail: widthPx - 2 * InsetPx)
  r.tag(body, "page-state", stateName(page.state.val))
  case page.state.val
  of asIdle, asLoading:
    r.appendChild(body, r.notice(p, ItemLoadingNotice, "loading"))
  of asError:
    let unresolvable = page.notice
    if unresolvable.len > 0:
      r.appendChild(body, r.notice(p, unresolvable, "unresolvable"))
    else:
      let target = page
      r.appendChild(body, r.errorBlock(p, ItemErrorTitle, page.error.val,
                                       proc() = target.load()))
  of asReady:
    let d = page.detail
    r.appendChild(body, r.drawItemHead(c, d))
    if page.leadsWithSummary:
      let s = r.section(c, SummaryHead, "")
      r.tag(s, "summary-first", "true")
      r.appendChild(s, r.prose(c, d.executiveSummary, fact = "executive-summary"))
      r.appendChild(body, s)
    case d.kind
    of ikBlockedQuestion, ikUnknown: r.drawQuestion(c, d, body)
    of ikEndedTurn: r.drawEndedTurn(c, d, body)
    of ikPermissionGate: r.drawPermission(c, d, body)
    of ikLoginRequest: r.drawLogin(c, d, body)
    of ikAsyncFeedback: r.drawFeedback(c, d, body)
    r.drawStatusLines(c, body)

proc pageBox(r: GpuiRenderer): GpuiElement =
  ## `.ah-item-page`: a column 8px above, 12px below, 8px in, its parts 8px
  ## apart.
  result = r.box(column = true, pairs = [("gap", "8px"), ("padding-top", "8px"),
                                         ("padding-bottom", "12px"),
                                         ("padding-left", $InsetPx & "px"),
                                         ("padding-right", $InsetPx & "px"), ("min-height", "0px"),
                                         ("min-width", "0px"), ("overflow", "hidden")])
  r.tag(result, "item-page", "true")

proc drawInboxItemPage*(r: GpuiRenderer; host: GpuiElement; page: InboxItemVM; p: AhPalette;
                        widthPx: int; ctx = AgentHarborInboxItemContext()) =
  ## An item's page standing alone (the session tab's page), `widthPx` wide.
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", "100%"),
                  ("background", p.panel), ("overflow", "hidden")])
  r.tag(host, "surface", "agent-harbor-inbox-item")
  r.tag(host, "width-px", $widthPx)
  r.tag(host, "state", stateName(page.state.val))
  let body = r.pageBox()
  r.setStyle(body, "flex-grow", "1")
  r.tag(body, "page", "standalone")
  r.drawItemPageBody(p, page, ctx, body, widthPx)
  r.appendChild(host, body)

proc mountInboxItemPage*(r: GpuiRenderer; host: GpuiElement; page: InboxItemVM; p: AhPalette;
                         widthPx: int; ctx = AgentHarborInboxItemContext()) =
  ## Draws the page, redraws it whenever what it reads changes, and marks
  ## it visible while mounted (its viewing heartbeat runs), as the web
  ## mount does.
  createRenderEffect proc() =
    discard page.revision.val
    drawInboxItemPage(r, host, page, p, widthPx, ctx)
  page.setVisible(true)

# ---------------------------------------------------------------------------
# The Inbox panel
# ---------------------------------------------------------------------------

proc drawStep(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; arrow, title: string;
              enabled: bool; onClick: proc()): GpuiElement =
  ## Previous or Next (`.ah-step`): 24px, at least as wide, 6px in, a 1px
  ## border in the control border role on the secondary surface, the arrow
  ## in the body colour; disabled, the arrow in the disabled colour inside
  ## the disabled border, and no pressable pointer.
  let colour = if enabled: p.textBody else: p.textDisabled
  result = r.box(pairs = [("height", $ControlPx & "px"), ("min-width", $ControlPx & "px"),
                          ("items", "center"), ("justify", "center"),
                          ("padding-left", "6px"), ("padding-right", "6px"),
                          ("border-width", "1px"),
                          ("border-color", if enabled: p.borderSecondary else: ink.borderDisabled),
                          ("rounded", $ControlRadiusPx & "px"), ("background", p.secondary),
                          ("flex-shrink", "0"),
                          ("cursor", cursorOf(if enabled: hkControl else: hkNone))])
  r.appendChild(result, r.text(arrow, LabelPx, colour, shrink = false))
  r.tag(result, "inbox-step", title)
  r.tag(result, "enabled", $enabled)
  r.tag(result, "ink", colour)
  r.tag(result, "tooltip", title)
  if enabled and onClick != nil: r.addEventListener(result, "click", onClick)

proc drawStepper(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: InboxVM;
                 widthPx: int): GpuiElement =
  ## `←  3 of 5  →  Auto-switch: off` (`.ah-inbox-stepper`): 5px by 8px in,
  ## 6px apart, over a hairline; compact at 50rem and narrower.
  let compact = widthPx <= CompactStepperMaxPx
  let position = vm.positionText
  let on = vm.autoSwitch.val
  result = r.box(pairs = [("gap", "6px"), ("items", "center"), ("padding-top", "5px"),
                          ("padding-bottom", "5px"), ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("flex-shrink", "0"),
                          ("height", $(5 + ControlPx + 5 + 1) & "px")])
  r.rule(result, p.borderSecondary)
  r.tag(result, "stepper", "inbox")
  r.tag(result, "stepper-position", position)
  let target = vm
  r.appendChild(result, r.drawStep(p, ink, PreviousArrow, stepperTitle(false), vm.canPrev,
                                   proc() = discard target.prev()))
  if not compact:
    let pos = r.text(position, LabelPx, p.textLabel, shrink = false)
    r.tag(pos, "position", position)
    r.appendChild(result, pos)
  r.appendChild(result, r.drawStep(p, ink, NextArrow, stepperTitle(true), vm.canNext,
                                   proc() = discard target.next()))
  let words = autoSwitchText(on, compact)
  let auto = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                            ("padding-left", "8px"), ("padding-right", "8px"),
                            ("margin-left", "8px"), ("rounded", $ControlRadiusPx & "px"),
                            ("flex-shrink", "0"), ("cursor", cursorOf(hkControl))])
  let label = r.text(words, LabelPx, if on: p.textBody else: p.textLabel, shrink = false)
  r.tag(label, "auto-switch-text", words)
  r.appendChild(auto, label)
  r.tag(auto, "inbox-auto-switch", if on: "on" else: "off")
  r.addEventListener(auto, "click", proc() = target.setAutoSwitch(not on))
  r.appendChild(result, auto)

proc drawRow(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: InboxVM;
             ctx: AgentHarborInboxContext; item: InboxItem; onScreen: bool;
             widthPx: int): GpuiElement =
  ## One item (`.ah-inbox-row`): 6px by 8px in; the kind's mark in its own
  ## 8px column, 6px down; then, 8px on, the label line (the session's label
  ## taking the free width, the chips, the age, wrapping), the kind's words
  ## line, and the server's explanation, wrapping, 2px apart.
  let itemRef = item.refOf
  let label = if item.session.label.len > 0: item.session.label else: item.session.title
  let priority = priorityChip(item)
  let warmth = warmthChip(item.warmth, ctx.nowMs)
  let age = ageLabel(ctx.nowMs, item.enteredAtMs)
  let holder = holderText(item)
  result = r.box(pairs = [("gap", "8px"), ("items", "start"), ("padding-top", "6px"),
                          ("padding-bottom", "6px"), ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("flex-shrink", "0"),
                          ("min-width", "0px"), ("position", "relative"),
                          ("cursor", cursorOf(hkRow))])
  r.tag(result, "item", item.id)
  r.tag(result, "item-server", item.server)
  r.tag(result, "kind", item.kindText)
  r.tag(result, "item-position", $item.position)
  r.tag(result, "current", $onScreen)
  if onScreen:
    r.setStyle(result, "background", p.hover)
    r.appendChild(result, r.insetBar(p.borderAction, BarPx))
  let markHolder = r.box(pairs = [("width", $ItemMarkPx & "px"), ("padding-top", "6px"),
                                  ("flex-shrink", "0")])
  r.appendChild(markHolder, r.mark(p.roleDot(kindRole(item.kind)), ItemMarkPx))
  r.appendChild(result, markHolder)
  let avail = widthPx - 2 * InsetPx - ItemMarkPx - 8
  let main = r.box(column = true, pairs = [("gap", "2px"), ("min-width", "0px"),
                                           ("flex-grow", "1"), ("flex-shrink", "1")])
  let labelEl = r.text(label, BodyPx, p.textBody, pairs = [("line-height", $ShortLinePx & "px")])
  r.tag(labelEl, "item-label", label)
  # `.ah-inbox-row-line` wraps, each line as high as its tallest item: the
  # label on its 16px line, a chip 18px, the age on the panel's 24px line.
  var line1 = @[FlowItem(el: labelEl, widthPx: textPx(label, BodyPx), grow: true)]
  var heights1 = @[ShortLinePx]
  if priority.len > 0:
    line1.add FlowItem(el: r.chip(p, ink, priority, priorityRole(item), "priority"),
                       widthPx: chipPx(priority))
    heights1.add ChipPx
  if warmth.len > 0:
    line1.add FlowItem(el: r.chip(p, ink, warmth, warmthRole(warmth), "warmth"),
                       widthPx: chipPx(warmth))
    heights1.add ChipPx
  if age.len > 0:
    let a = r.text(age, CaptionPx, p.textCaption, shrink = false)
    r.tag(a, "age", age)
    line1.add FlowItem(el: a, widthPx: textPx(age, CaptionPx))
    heights1.add RowLinePx
  r.appendChild(main, r.flowLinesFit(line1, heights1, avail, 6, 2))
  let kind = r.text(kindWord(item), CaptionPx, p.textLabel, shrink = false,
                    pairs = [("line-height", $ShortLinePx & "px")])
  r.tag(kind, "kind-word", kindWord(item))
  var line2 = @[FlowItem(el: kind, widthPx: textPx(kindWord(item), CaptionPx))]
  var heights2 = @[ShortLinePx]
  if holder.len > 0:
    let h = r.stateWord(p, ink, holder, if item.heldBy == ihOperator: "warning" else: "quiet",
                        pushEnd = false)
    r.tag(h, "holder", holder)
    line2.add FlowItem(el: h, widthPx: stateWordPx(holder))
    heights2.add ShortLinePx
  let pendingText = vm.pendingFeedbackText(itemRef)
  if pendingText.len > 0:
    line2.add FlowItem(el: r.chip(p, ink, pendingText, "info", "pending"),
                       widthPx: chipPx(pendingText))
    heights2.add ChipPx
  if item.kind == ikUnknown:
    let target = vm
    line2.add FlowItem(el: r.actionButton(p, ink, OpenLabel, false,
                                          proc() = target.open(itemRef)),
                       widthPx: actionButtonPx(OpenLabel), alignEnd: true)
    heights2.add ControlPx
  r.appendChild(main, r.flowLinesFit(line2, heights2, avail, 6, 2))
  if item.explanation.len > 0:
    let e = r.wrapping(item.explanation, CaptionPx, ShortLinePx, p.textCaption)
    r.tag(e, "explanation", item.explanation)
    r.appendChild(main, e)
  r.appendChild(result, main)
  let target = vm
  r.addEventListener(result, "click", proc() = target.open(itemRef))

proc drawRows(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: InboxVM;
              ctx: AgentHarborInboxContext; list: GpuiElement; widthPx: int) =
  ## The rows in the server's order. A run of rows from another server is
  ## headed by its name and count (`.ah-inbox-server-head`); the order is
  ## never changed to group them.
  let items = vm.items
  var fleet = false
  for item in items:
    if item.server.len > 0: fleet = true
  let current = vm.current.val
  var i = 0
  while i < items.len:
    var j = i + 1
    if fleet:
      while j < items.len and items[j].server == items[i].server: inc j
      let server = items[i].server
      let name = if server.len > 0: server else: ThisServerLabel
      let head = r.box(pairs = [("gap", "8px"), ("items", "center"), ("padding-top", "6px"),
                                ("padding-bottom", "4px"), ("padding-left", $InsetPx & "px"),
                                ("padding-right", $InsetPx & "px"), ("flex-shrink", "0"),
                                ("height", "35px"), ("min-width", "0px")])
      r.rule(head, p.borderSecondary)
      r.tag(head, "server", server)
      let n = r.text(name, LabelPx, p.textLabel, bold = true,
                     pairs = [("line-height", $ShortLinePx & "px")])
      r.tag(n, "server-name", name)
      r.appendChild(head, n)
      r.appendChild(head, r.text($(j - i), LabelPx, p.textCaption, shrink = false))
      r.appendChild(list, head)
    for k in i ..< j:
      r.appendChild(list, r.drawRow(p, ink, vm, ctx, items[k], items[k].refOf == current,
                                    widthPx))
    i = j

proc drawInboxPanel*(r: GpuiRenderer; host: GpuiElement; vm: InboxVM; p: AhPalette;
                     widthPx: int; ctx = AgentHarborInboxContext()) =
  ## The Inbox panel over `vm`, `widthPx` wide; with the viewmodel's pages
  ## on, the item on screen's page under (or beside) the rows. Redrawn whole
  ## on each call.
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", "100%"),
                  ("background", p.panel), ("overflow", "hidden")])
  r.tag(host, "surface", "agent-harbor-inbox")
  r.tag(host, "width-px", $widthPx)
  r.tag(host, "state", stateName(vm.state.val))
  let ink = changesInboxInks(p.mode)
  let ready = vm.state.val == asReady
  let counts = if ready: inboxCountsText(vm) else: ""
  let head = r.drawSectionHeader(p, InboxSectionLabel, ctx.scope, counts, widthPx)
  r.tag(head, "head", "section header")
  if ready: r.tag(head, "tooltip", vm.controlTitle)
  r.appendChild(host, head)
  case vm.state.val
  of asIdle, asLoading:
    r.appendChild(host, r.notice(p, vm.notice(), "loading"))
    return
  of asError:
    let target = vm
    r.appendChild(host, r.errorBlock(p, InboxErrorTitle, vm.error.val,
                                     proc() = target.restart()))
    return
  of asReady: discard
  r.appendChild(host, r.drawStepper(p, ink, vm, widthPx))
  let notes = if vm.cursorError.val.len > 0: @[(vm.cursorError.val, "error")] else: @[]
  var lines = notes
  for line in vm.degradedText: lines.add (line, "warning")
  for (line, role) in lines:
    let d = r.box(pairs = [("padding-top", "4px"), ("padding-bottom", "4px"),
                           ("padding-left", $InsetPx & "px"), ("padding-right", $InsetPx & "px"),
                           ("flex-shrink", "0")])
    r.rule(d, p.borderSecondary)
    let words = r.wrapping(line, CaptionPx, ShortLinePx, p.roleInk(ink, role))
    r.appendChild(d, words)
    r.tag(d, "degraded", line)
    r.appendChild(host, d)
  let beside = widthPx >= PageBesideMinPx
  let main = r.box(column = not beside, pairs = [("flex-grow", "1"), ("min-height", "0px"),
                                                 ("overflow", "hidden")])
  let listW = if beside: ListBesidePx else: widthPx
  let list = r.box(column = true, pairs = [("flex-shrink", "0"), ("overflow", "hidden")])
  r.tag(list, "rows", "inbox")
  if beside:
    r.styles(list, [("width", $ListBesidePx & "px"), ("border-right-width", "1px"),
                    ("border-color", p.borderSecondary)])
  let notice = vm.notice()
  if notice.len > 0:
    # The list is not a flex container (`.ah-fleet-list`), so the overlay's
    # centring has no height to centre in: the notice sits at the top of the
    # list, one line high, centred across it.
    let n = r.notice(p, notice, "empty")
    r.styles(n, [("flex-grow", "0"), ("flex-shrink", "0")])
    r.appendChild(list, n)
  else:
    r.drawRows(p, ink, vm, ctx, list, listW - (if beside: 1 else: 0))
  r.appendChild(main, list)
  let page = vm.page
  if not page.isNil:
    let pageW = if beside: widthPx - ListBesidePx else: widthPx
    # Under the rows the page keeps its content's height (`.ah-inbox-page`
    # is not a flex item that shrinks; the column scrolls); beside them it
    # takes the free width.
    let pageHost = r.box(column = true, pairs = [("min-width", "0px"), ("flex-shrink", "0"),
                                                 ("overflow", "hidden")])
    if beside: r.styles(pageHost, [("flex-grow", "1"), ("flex-shrink", "1")])
    r.tag(pageHost, "page", "inbox")
    let strip = vm.explanationStrip
    if strip.len > 0:
      let s = r.box(pairs = [("padding-top", "5px"), ("padding-bottom", "5px"),
                             ("padding-left", $InsetPx & "px"), ("padding-right", $InsetPx & "px"),
                             ("background", p.secondary), ("flex-shrink", "0")])
      r.appendChild(s, r.wrapping(strip, CaptionPx, ShortLinePx, p.textBody))
      r.tag(s, "strip", strip)
      r.appendChild(pageHost, s)
    let label = block:
      let found = vm.currentItem
      if found.found: found.item.session.label else: ""
    var pageCtx = AgentHarborInboxItemContext(nowMs: ctx.nowMs, onOpenSignIn: ctx.onOpenSignIn,
      onTyping: proc(typing: bool) = vm.setTyping(typing),
      onContinue: proc() = discard vm.next())
    pageCtx.sessionLabel = label
    let body = r.pageBox()
    discard page.revision.val
    r.drawItemPageBody(p, page, pageCtx, body, pageW)
    r.appendChild(pageHost, body)
    r.appendChild(main, pageHost)
  r.appendChild(host, main)

proc mountInboxPanel*(r: GpuiRenderer; host: GpuiElement; vm: InboxVM; p: AhPalette;
                      widthPx: int; ctx = AgentHarborInboxContext()) =
  ## Draws the panel, redraws it whenever what it reads changes, and (with
  ## the viewmodel's pages on) marks its pages visible while it is mounted,
  ## as the web mount does.
  createRenderEffect proc() =
    discard vm.revision.val
    drawInboxPanel(r, host, vm, p, widthPx, ctx)
  if vm.showPages: vm.setPagesVisible(true)
