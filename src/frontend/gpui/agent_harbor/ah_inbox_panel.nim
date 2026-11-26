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

import ../../viewmodel/keymap/user_keymap
from ../../viewmodel/keymap/scope_path import InboxPanelScope
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
  RowLinePx = 24           ## a line of an inbox row's label line: the panel's line
  CheckboxGapPx = 7        ## `.ct-checkmark-field`: 0.5em at the choices' 14px
  ChoiceGapPx = 4          ## `.ah-choices`: 0.25rem; the toggles' row gap too
  ReadingMaxPx* = 768
    ## `AH_ITEM_READING_WIDTH`, 48rem: an item's page keeps its parts to a
    ## column this wide, centred, on a wider pane.
  HintPadPx = 24           ## `AH_INBOX_HINT_PAD`, 1.5rem
  StepperPx = 5 + ControlPx + 5 + 1
    ## `.ah-inbox-stepper`: 5px above and below the controls, its hairline.
  ServerHeadPx = 35        ## `.ah-inbox-server-head`
  InboxRegionKey* = "inbox"
    ## The scrolling region of the rows and the page under them.
  InboxListRegionKey* = "inbox-list"
  InboxPageRegionKey* = "inbox-page"
    ## The two regions while the page stands beside the rows.
  PageRegionKey* = "page"
    ## The region of an item's page standing alone.

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
    items.add FlowItem(el: r.actionButton(c.p, c.ink, label, primary, InboxItemActionOperation,
                                          action, disabled),
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

proc choicePress(page: InboxItemVM; id: string): proc() =
  ## A choice's press: a proc of its own so each closure owns its id (a
  ## closure made in a Nim loop body shares the body's variables with every
  ## other iteration's).
  result = proc() = page.toggleChoice(id)

proc pressChoice(r: GpuiRenderer; el: GpuiElement; page: InboxItemVM; id: string) =
  ## The one press a choice takes, whichever control draws it (a single
  ## choice's toggle, one of several's checkbox line): choosing it, as
  ## `inbox.choose-option` (`pressable`). One place for both, so the
  ## drawings cannot disagree on what a press does.
  r.pressable(el, InboxChooseOptionOperation, choicePress(page, id))

proc decisionPress(page: InboxItemVM; requestId: string; decision: ApprovalDecision): proc() =
  ## An approval's button: a proc of its own so each closure owns its
  ## decision (a closure made in a Nim loop body shares the body's variables
  ## with every other iteration's: every button sent the last one's).
  result = proc() = discard page.decideApproval(requestId, decision)

proc permissionPress(page: InboxItemVM; id: string): proc() =
  ## A permission option's button, its id its own (as `decisionPress`).
  result = proc() = discard page.choosePermission(id)

proc choicesItems(options: seq[AnswerOption]): seq[FlowItem] =
  ## The single choice's toggles as a wrapping row measures them: each
  ## toggle, its description after its label.
  for o in options:
    var w = toggleChipPx(o.label)
    if o.description.len > 0: w += 6 + textPx(o.description, CaptionPx)
    result.add FlowItem(widthPx: w)

proc choicesPx(options: seq[AnswerOption]; single: bool; availPx: int): int =
  ## The choices' height: the toggles' lines, or one 24px line a checkbox.
  if options.len == 0: return 0
  if single:
    let lines = flowLineCount(choicesItems(options), availPx, ChoiceGapPx)
    lines * ControlPx + (lines - 1) * ChoiceGapPx
  else:
    options.len * BodyLinePx + (options.len - 1) * ChoiceGapPx

proc drawChoices(r: GpuiRenderer; c: PageCtx; options: seq[AnswerOption];
                 single, disabled: bool): GpuiElement =
  ## One choice: a row of the omnibox composer's toggles, wrapping, 4px
  ## apart (the design system has no radio button); several: a column of
  ## the design system's checkboxes, each with its label and description,
  ## 4px apart (`.ah-choices`, `.ct-checkmark-field`).
  let chosen = c.page.choices.val
  let page = c.page
  if single:
    var items = choicesItems(options)
    for i, o in options:
      let checked = o.id in chosen
      let t = r.toggleChip(c.p, o.label, checked, disabled)
      if o.description.len > 0:
        r.appendChild(t, r.text(o.description, CaptionPx, c.p.textCaption, shrink = false,
                                pairs = [("margin-left", "6px")]))
      r.tag(t, "choice", o.id)
      r.tag(t, "checked", $checked)
      if not disabled: r.pressChoice(t, page, o.id)
      items[i].el = t
    result = r.flowLines(items, c.avail, ChoiceGapPx, ControlPx, ChoiceGapPx)
    r.setStyle(result, "flex-shrink", "0")
    r.tag(result, "choices", "single")
    return
  result = r.box(column = true, pairs = [("gap", $ChoiceGapPx & "px"), ("flex-shrink", "0")])
  r.tag(result, "choices", "multi")
  for o in options:
    let checked = o.id in chosen
    # `.ct-checkmark-field`: the box and its label 7px apart on the panel's
    # 24px line (its 3.5px above and below and the label's 1.2 line).
    let line = r.box(pairs = [("gap", $CheckboxGapPx & "px"), ("items", "center"),
                              ("min-width", "0px"), ("height", $BodyLinePx & "px"),
                              ("flex-shrink", "0"),
                              ("cursor", cursorOf(if disabled: hkNone else: hkControl))])
    r.tag(line, "choice", o.id)
    r.tag(line, "checked", $checked)
    r.appendChild(line, r.checkbox(c.p, c.ink, checked, disabled))
    let label = r.text(o.label, BodyPx, if disabled: c.p.textDisabled else: c.p.textBody,
                       shrink = false)
    r.tag(label, "choice-label", o.label)
    r.appendChild(line, label)
    if o.description.len > 0:
      r.appendChild(line, r.text(o.description, CaptionPx, c.p.textCaption))
    if not disabled: r.pressChoice(line, page, o.id)
    r.appendChild(result, line)

proc drawDraft(r: GpuiRenderer; c: PageCtx; draft: Draft; disabled: bool): GpuiElement =
  ## A manager's draft (`.ah-item-draft`): 8px in past an inset bar in the
  ## information border role; its provenance, rationale and text, and `Send
  ## draft` in an actions row of its own, as compact as `Submit` and at the
  ## row's start (the web's `.ah-item-actions` inside the draft).
  result = r.section(c, DraftHead, confidenceText(draft))
  r.styles(result, [("padding-left", "8px"), ("position", "relative")])
  r.appendChild(result, r.insetBar(c.ink.borderInfo, BarPx))
  r.tag(result, "draft", "true")
  if draft.rationale.len > 0: r.appendChild(result, r.quiet(c, draft.rationale))
  if draft.text.len > 0: r.appendChild(result, r.prose(c, draft.text, fact = "draft-text"))
  if draft.choices.len > 0:
    r.appendChild(result, r.prose(c, draft.choices.join(", "), fact = "draft-text"))
  # The row wraps within the draft's column: the page's width less the 8px
  # the draft stands in.
  let page = c.page
  var inner = c
  inner.avail = c.avail - 8
  r.appendChild(result, r.actions(inner, @[(SendDraftLabel, true, disabled,
                                            proc() = discard page.sendDraft())]))

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
  # The command (or the domain) on a line of its own, in code style
  # (`.ah-item-approval-subject`: Space Mono on the raised ground, 2px by
  # 6px in, rounded 4px, as wide as it is); why the agent asks under it in
  # prose.
  let subject = approvalSubject(a)
  let code = r.box(pairs = [("padding-top", "2px"), ("padding-bottom", "2px"),
                            ("padding-left", "6px"), ("padding-right", "6px"),
                            ("rounded", "4px"), ("background", c.p.secondary),
                            ("flex-shrink", "0"), ("min-width", "0px"),
                            ("max-width", $c.avail & "px")])
  let codeText = r.mono(r.wrapping(subject, BodyPx, BodyLinePx, c.p.textBody))
  r.tag(codeText, "approval-subject", subject)
  r.appendChild(code, codeText)
  r.tag(code, "approval-code", "true")
  let codeRow = r.box(pairs = [("flex-shrink", "0"), ("min-width", "0px")])
  r.appendChild(codeRow, code)
  r.appendChild(result, codeRow)
  let purpose = approvalPurposeText(a)
  if purpose.len > 0:
    r.appendChild(result, r.prose(c, purpose, fact = "approval-purpose"))
  let page = c.page
  let requestId = a.requestId
  var items: seq[FlowItem]
  if a.scope == asSudo:
    # The password field: what is typed is the viewmodel's to hold and is
    # never drawn back, so the field shows its placeholder, or that a
    # password was given.
    # An `input` (`input.ah-text-field`): holding a password, the app's
    # input rule draws it with the action border on the input surface
    # (`inputLook`). Its value is never drawn back, so a
    # password given stands for the value.
    let look = inputLook(c.p, if page.passwordSet.val: "\xE2\x80\xA2" else: "",
                         PasswordPlaceholder, c.p.borderSecondary, c.ink.inputSurface)
    let field = r.inputBox(look, pairs = [("width", $PasswordPx & "px"),
                                          ("height", $ControlPx & "px"),
                                          ("items", "center"), ("padding-left", "8px"),
                                          ("padding-right", "8px"), ("rounded", "6px"),
                                          ("flex-shrink", "0")])
    r.tag(field, "password-field", $page.passwordSet.val)
    r.appendChild(field, r.text(if page.passwordSet.val: "\xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2"
                                else: PasswordPlaceholder, BodyPx,
                                if page.passwordSet.val: c.p.textBody else: c.ink.placeholder))
    items.add FlowItem(el: field, widthPx: PasswordPx)
  for (label, primary, decision) in [(ApproveLabel, true, adApprove),
                                     (ApproveForSessionLabel, false, adApproveForSession),
                                     (DenyLabel, false, adDeny)]:
    items.add FlowItem(el: r.actionButton(c.p, c.ink, label, primary, InboxItemActionOperation,
                                          decisionPress(page, requestId, decision)),
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
      buttons.add (o.label, i == 0, false, permissionPress(page, o.id))
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
  # The design system's dropdown, its value whole (`Priority`), as wide as
  # that value: the session's label gives way first, so the head keeps the
  # page's inset (`.ah-item-head > .ah-dropdown`: `flex-shrink: 0`).
  let menu = r.selectBox(c.p, PriorityLabel, labels, "priority-menu")
  r.setStyle(menu, "flex-shrink", "0")
  r.appendChild(result, menu)

# ---------------------------------------------------------------------------
# A page's height, for the regions that scroll it
# ---------------------------------------------------------------------------
#
# The page's parts at the heights the drawing above gives them, wrapped
# prose counted by the face's widths (`textRows`): what a scrolling region
# holds. Each mirrors the drawing proc it names.

proc actionsPx(labels: seq[string]; availPx: int; leadPx = 0): int =
  ## `actions`: the buttons' lines (6px apart), after a field `leadPx` wide.
  var items: seq[FlowItem]
  if leadPx > 0: items.add FlowItem(widthPx: leadPx)
  for l in labels: items.add FlowItem(widthPx: actionButtonPx(l))
  if items.len == 0: return 0
  let lines = flowLineCount(items, availPx, 6)
  lines * ControlPx + (lines - 1) * 6

proc gapped(parts: seq[int]; gap: int): int =
  ## Parts one under another, `gap` apart; a part of no height takes none.
  var n = 0
  for h in parts:
    if h > 0:
      result += h
      inc n
  if n > 1: result += (n - 1) * gap

proc draftPx(c: PageCtx; draft: Draft): int =
  ## `drawDraft`: its head, rationale, text, choices and `Send draft`'s
  ## actions row, 4px apart, 8px in.
  let w = c.avail - 8
  gapped(@[BodyLinePx, ShortLinePx * textRows(draft.rationale, CaptionPx, w),
           BodyLinePx * textRows(draft.text, BodyPx, w),
           BodyLinePx * textRows(draft.choices.join(", "), BodyPx, w),
           actionsPx(@[SendDraftLabel], w)], 4)

proc bannerPx(c: PageCtx; text: string): int =
  ## `drawBanner`: 6px above and below, the words wrapped past the dot.
  if text.len == 0: return 0
  12 + BodyLinePx * textRows(text, BodyPx, c.avail - 16 - StateDotPx - 8)

proc approvalPx(c: PageCtx; a: ApprovalRequest): int =
  ## `drawApproval`: its hairline, 6px above and below, the code line (2px
  ## above and below), the purpose and the decisions, 6px apart.
  let lead = if a.scope == asSudo: PasswordPx else: 0
  1 + 12 + gapped(@[4 + BodyLinePx * textRows(approvalSubject(a), BodyPx, c.avail - 12),
                     BodyLinePx * textRows(approvalPurposeText(a), BodyPx, c.avail),
                     actionsPx(@[ApproveLabel, ApproveForSessionLabel, DenyLabel], c.avail, lead)],
                   6)

proc itemContentPx(c: PageCtx; d: InboxItemDetail): int =
  ## The page's parts for `d`, 8px apart, as `drawItemPageBody` draws them.
  let page = c.page
  var parts = @[ControlPx]                                  # the head
  if page.leadsWithSummary:
    parts.add BodyLinePx + 4 + BodyLinePx * textRows(d.executiveSummary, BodyPx, c.avail)
  case d.kind
  of ikBlockedQuestion, ikUnknown:
    parts.add bannerPx(c, page.banner)
    parts.add BodyLinePx * textRows(d.prompt, BodyLargePx, c.avail)
    if d.draft.present: parts.add draftPx(c, d.draft)
    if page.optionsNotice.len > 0:
      parts.add ShortLinePx * textRows(page.optionsNotice, CaptionPx, c.avail)
    else:
      let field = case d.form
        of qfFreeForm: TextFieldRowsPx
        of qfSingle, qfMulti: choicesPx(d.options, d.form == qfSingle, c.avail)
        of qfConfirmation: 0
      let buttons = if d.form == qfConfirmation: @[ApproveLabel, RejectLabel] else: @[SubmitLabel]
      parts.add gapped(@[field, actionsPx(buttons, c.avail)], 6)
  of ikEndedTurn:
    if d.lastReply.len > 0:
      parts.add BodyLinePx + 4 + BodyLinePx * textRows(d.lastReply, BodyPx, c.avail)
    parts.add gapped(@[TextFieldRowsPx, ControlPx], 6)
  of ikPermissionGate:
    parts.add BodyLinePx * textRows(d.prompt, BodyLargePx, c.avail)
    var labels: seq[string]
    for o in d.permissionOptions: labels.add o.label
    parts.add actionsPx(labels, c.avail)
    for a in d.approvals: parts.add approvalPx(c, a)
  of ikLoginRequest:
    let login = d.login
    let has = page.hasLoginRequest
    var buttons: seq[string]
    if page.canCancelLogin and c.ctx.onOpenSignIn != nil: buttons.add OpenSignInLabel
    if page.canCancelLogin: buttons.add CancelLabel
    if page.canContinueLogin and c.ctx.onContinue != nil: buttons.add ContinueLabel
    parts.add gapped(@[
      (if has: BodyLinePx * textRows(login.provider, BodyLargePx, c.avail) else: 0),
      (if has and login.mode == lmLocalDesktop: BodyLinePx * textRows(login.prompt, BodyPx, c.avail)
       else: 0),
      BodyLinePx * textRows(page.loginText, BodyPx, c.avail),
      ShortLinePx * textRows(page.loginError, CaptionPx, c.avail),
      actionsPx(buttons, c.avail)], 6)
  of ikAsyncFeedback:
    let fb = d.feedback
    if page.expiredBadge(c.ctx.nowMs).len > 0: parts.add BodyLinePx
    parts.add BodyLinePx * textRows(fb.prompt, BodyLargePx, c.avail)
    parts.add ShortLinePx * textRows(fb.context, CaptionPx, c.avail)
    if fb.attachments.len > 0:
      parts.add BodyLinePx + 4 + fb.attachments.len * BodyLinePx + (fb.attachments.len - 1) * 4
    if d.draft.present: parts.add draftPx(c, d.draft)
    let field = case fb.feedbackType
      of ftQuestion: TextFieldRowsPx
      of ftOptions: choicesPx(fb.options, false, c.avail)
      else: 0
    let buttons = case fb.feedbackType
      of ftConfirmation: @[ApproveLabel, RejectLabel]
      of ftInformation: @[AcknowledgeLabel]
      else: @[SubmitLabel]
    parts.add gapped(@[field, actionsPx(buttons, c.avail)], 6)
  parts.add gapped(@[ShortLinePx * textRows(page.validation.val, CaptionPx, c.avail),
                     ShortLinePx * textRows(page.phaseText, CaptionPx, c.avail)], 4)
  gapped(parts, 8)

proc readingAvailPx(widthPx: int): int =
  ## The width an item page's parts take: the page less its insets, at most
  ## the reading measure.
  min(widthPx - 2 * InsetPx, ReadingMaxPx)

proc itemPagePx*(p: AhPalette; page: InboxItemVM; ctx: AgentHarborInboxItemContext;
                 widthPx: int): int =
  ## How tall `pageBox` draws `page` at `widthPx`: its 8px above, 12px
  ## below, and its parts (0 while it is not ready: then it fills its room
  ## with a centred notice and does not scroll).
  if page.state.val != asReady: return 0
  let c = PageCtx(p: p, ink: changesInboxInks(p.mode), page: page, ctx: ctx,
                  avail: readingAvailPx(widthPx))
  8 + itemContentPx(c, page.detail) + 12

proc drawItemPageBody*(r: GpuiRenderer; p: AhPalette; page: InboxItemVM;
                       ctx: AgentHarborInboxItemContext; body: GpuiElement; widthPx: int) =
  ## One page's content for its load state, into `body` (which the caller
  ## clears); `widthPx` is the page's own width. A ready page's parts keep
  ## to a column at most `ReadingMaxPx` wide, centred in the page
  ## (`.ah-item-page > *`: `max-width: 48rem; align-self: center`).
  let c = PageCtx(p: p, ink: changesInboxInks(p.mode), page: page, ctx: ctx,
                  avail: readingAvailPx(widthPx))
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
      r.appendChild(body, r.routedErrorBlock(p, ItemErrorTitle, page.error.val,
                                             InboxRetryOperation, proc() = target.load()))
  of asReady:
    let d = page.detail
    let inner = widthPx - 2 * InsetPx
    let content = r.box(column = true, pairs = [("gap", "8px"), ("flex-shrink", "0"),
                                                ("min-width", "0px"),
                                                ("width", $c.avail & "px")])
    if inner > c.avail: r.setStyle(content, "margin-left", $((inner - c.avail) div 2) & "px")
    r.tag(content, "reading-width", $c.avail)
    r.appendChild(body, content)
    let body = content
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

proc inboxPresses*(vm: InboxVM; page: InboxItemVM; keymap = UserKeymap()): PanelPress =
  ## The route for a press on the Inbox over `vm` (nil for an item's page
  ## standing alone) and `page` (the page on screen; nil: the Inbox's):
  ## resolved in the `inbox` scope under `keymap`'s rows over the base
  ## keymap's; a user's row that names one of the Inbox's key operations runs
  ## it (`runInboxOperation`).
  panelPresses(InboxPanelScope, keymap, proc(operation: string): bool =
    let shown = if page.isNil and not vm.isNil: vm.page else: page
    runInboxOperation(vm, shown, operation))

proc drawInboxItemPageParts(r: GpuiRenderer; host: GpuiElement; page: InboxItemVM;
                            p: AhPalette; widthPx: int; ctx: AgentHarborInboxItemContext;
                            heightPx: int; scroll: P3Scroll) =
  scroll.beginDraw()
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", "100%"),
                  ("background", p.panel), ("overflow", "hidden")])
  r.tag(host, "surface", "agent-harbor-inbox-item")
  r.tag(host, "width-px", $widthPx)
  r.tag(host, "state", stateName(page.state.val))
  let body = r.pageBox()
  r.tag(body, "page", "standalone")
  r.drawItemPageBody(p, page, ctx, body, widthPx)
  let contentPx = itemPagePx(p, page, ctx, widthPx)
  if heightPx > 0 and contentPx > 0:
    # The page fills the panel (`.ah-fleet-body`), and holds more than it
    # shows when its parts run past the foot.
    r.setStyle(body, "min-height", $heightPx & "px")
    r.appendChild(host, r.scrollWindow(scroll, PageRegionKey,
      @[ScrollPart(el: body, heightPx: max(contentPx, heightPx))], heightPx, ""))
  else:
    r.setStyle(body, "flex-grow", "1")
    r.appendChild(host, body)

proc drawInboxItemPage*(r: GpuiRenderer; host: GpuiElement; page: InboxItemVM; p: AhPalette;
                        widthPx: int; ctx = AgentHarborInboxItemContext();
                        heightPx = 0; scroll: P3Scroll = nil; press: PanelPress = nil) =
  ## An item's page standing alone (the session tab's page), `widthPx` wide.
  ## Given its `heightPx`, a ready page taller than that scrolls as a region
  ## (`PageRegionKey`, its first pixel kept by `scroll`); without, it is
  ## clipped at the panel's foot. Its presses go through `press` (the base
  ## keymap's `inboxPresses` when nil).
  drawingWith(if press.isNil: inboxPresses(nil, page) else: press):
    drawInboxItemPageParts(r, host, page, p, widthPx, ctx, heightPx, scroll)

proc mountInboxItemPage*(r: GpuiRenderer; host: GpuiElement; page: InboxItemVM; p: AhPalette;
                         widthPx: int; ctx = AgentHarborInboxItemContext();
                         heightPx = 0; scroll: P3Scroll = nil; redraw: Signal[int] = nil;
                         press: PanelPress = nil) =
  ## Draws the page, redraws it whenever what it reads changes (or the host
  ## moves `redraw`, after a scroll), and marks it visible while mounted
  ## (its viewing heartbeat runs), as the web mount does. Its presses go
  ## through `press` (the base keymap's `inboxPresses` when nil).
  let route = if press.isNil: inboxPresses(nil, page) else: press
  createRenderEffect proc() =
    discard page.revision.val
    if redraw != nil: discard redraw.val
    drawInboxItemPage(r, host, page, p, widthPx, ctx, heightPx, scroll, route)
  page.setVisible(true)

# ---------------------------------------------------------------------------
# The Inbox panel
# ---------------------------------------------------------------------------

proc drawStep(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; arrow, title: string;
              enabled: bool; operation: string; onClick: proc()): GpuiElement =
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
  if enabled: r.pressable(result, operation, onClick)

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
                                   InboxPreviousOperation, proc() = discard target.prev()))
  if not compact:
    let pos = r.text(position, LabelPx, p.textLabel, shrink = false)
    r.tag(pos, "position", position)
    r.appendChild(result, pos)
  r.appendChild(result, r.drawStep(p, ink, NextArrow, stepperTitle(true), vm.canNext,
                                   InboxNextOperation, proc() = discard target.next()))
  let words = autoSwitchText(on, compact)
  let auto = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                            ("padding-left", "8px"), ("padding-right", "8px"),
                            ("margin-left", "8px"), ("rounded", $ControlRadiusPx & "px"),
                            ("flex-shrink", "0"), ("cursor", cursorOf(hkControl))])
  let label = r.text(words, LabelPx, if on: p.textBody else: p.textLabel, shrink = false)
  r.tag(label, "auto-switch-text", words)
  r.appendChild(auto, label)
  r.tag(auto, "inbox-auto-switch", if on: "on" else: "off")
  r.pressable(auto, InboxToggleAutoSwitchOperation, proc() = target.setAutoSwitch(not on))
  r.appendChild(result, auto)

proc drawRow(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: InboxVM;
             ctx: AgentHarborInboxContext; item: InboxItem; onScreen: bool;
             widthPx: int): tuple[el: GpuiElement, heightPx: int] =
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
  let row = r.box(pairs = [("gap", "8px"), ("items", "start"), ("padding-top", "6px"),
                           ("padding-bottom", "6px"), ("padding-left", $InsetPx & "px"),
                           ("padding-right", $InsetPx & "px"), ("flex-shrink", "0"),
                           ("min-width", "0px"), ("position", "relative"),
                           ("cursor", cursorOf(hkRow))])
  r.tag(row, "item", item.id)
  r.tag(row, "item-server", item.server)
  r.tag(row, "kind", item.kindText)
  r.tag(row, "item-position", $item.position)
  r.tag(row, "current", $onScreen)
  if onScreen:
    r.setStyle(row, "background", p.hover)
    r.appendChild(row, r.insetBar(p.borderAction, BarPx))
  let markHolder = r.box(pairs = [("width", $ItemMarkPx & "px"), ("padding-top", "6px"),
                                  ("flex-shrink", "0")])
  r.appendChild(markHolder, r.mark(p.roleDot(kindRole(item.kind)), ItemMarkPx))
  r.appendChild(row, markHolder)
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
    line2.add FlowItem(el: r.actionButton(p, ink, OpenLabel, false, InboxOpenItemOperation,
                                          proc() = target.open(itemRef)),
                       widthPx: actionButtonPx(OpenLabel), alignEnd: true)
    heights2.add ControlPx
  r.appendChild(main, r.flowLinesFit(line2, heights2, avail, 6, 2))
  if item.explanation.len > 0:
    let e = r.wrapping(item.explanation, CaptionPx, ShortLinePx, p.textCaption)
    r.tag(e, "explanation", item.explanation)
    r.appendChild(main, e)
  r.appendChild(row, main)
  let target = vm
  r.pressable(row, InboxOpenItemOperation, proc() = target.open(itemRef))
  # Its height, from the same lines it was drawn with: the label line, the
  # kind's line and the explanation, 2px apart, beside the mark's 14px, 6px
  # above and below.
  let mainPx = gapped(@[flowFitHeightPx(line1, heights1, avail, 6, 2),
                        flowFitHeightPx(line2, heights2, avail, 6, 2),
                        ShortLinePx * textRows(item.explanation, CaptionPx, avail)], 2)
  r.tag(row, "row-px", $(12 + max(mainPx, 6 + ItemMarkPx)))
  (row, 12 + max(mainPx, 6 + ItemMarkPx))

proc serverHead(r: GpuiRenderer; p: AhPalette; server: string; count: int): GpuiElement =
  ## A run of rows from another server, headed by its name and count
  ## (`.ah-inbox-server-head`).
  let name = if server.len > 0: server else: ThisServerLabel
  result = r.box(pairs = [("gap", "8px"), ("items", "center"), ("padding-top", "6px"),
                          ("padding-bottom", "4px"), ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("flex-shrink", "0"),
                          ("height", $ServerHeadPx & "px"), ("min-width", "0px")])
  r.rule(result, p.borderSecondary)
  r.tag(result, "server", server)
  let n = r.text(name, LabelPx, p.textLabel, bold = true,
                 pairs = [("line-height", $ShortLinePx & "px")])
  r.tag(n, "server-name", name)
  r.appendChild(result, n)
  r.appendChild(result, r.text($count, LabelPx, p.textCaption, shrink = false))

proc rowParts(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: InboxVM;
              ctx: AgentHarborInboxContext; widthPx: int): seq[ScrollPart] =
  ## The rows in the server's order, each with its height and its item's id.
  ## A run of rows from another server is headed by its name and count; the
  ## order is never changed to group them.
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
      result.add ScrollPart(el: r.serverHead(p, items[i].server, j - i), heightPx: ServerHeadPx)
    for k in i ..< j:
      let (el, h) = r.drawRow(p, ink, vm, ctx, items[k], items[k].refOf == current, widthPx)
      result.add ScrollPart(el: el, heightPx: h, key: items[k].id)
    i = j

proc stepperHint(r: GpuiRenderer; p: AhPalette; beside: bool): GpuiElement =
  ## The quiet line in the page's place while items wait and none is on
  ## screen (`.ah-inbox-hint`, `InboxVM.wantsItemHint`): the caption size in
  ## the caption colour, centred, 24px above and below and 8px in; beside
  ## the rows, in the middle of the empty page. Nothing is opened.
  let hint = itemHintText()
  result = r.box(column = true, pairs = [("padding-top", $HintPadPx & "px"),
                                         ("padding-bottom", $HintPadPx & "px"),
                                         ("padding-left", $InsetPx & "px"),
                                         ("padding-right", $InsetPx & "px"),
                                         ("items", "center"), ("justify", "center"),
                                         ("flex-shrink", "0"), ("min-width", "0px")])
  if beside: r.setStyle(result, "flex-grow", "1")
  let t = r.wrapping(hint, CaptionPx, ShortLinePx, p.textCaption)
  r.setStyle(t, "text-align", "center")
  r.tag(t, "item-hint", hint)
  r.appendChild(result, t)

proc hintPx(widthPx: int): int =
  ## `stepperHint`'s height under the rows.
  2 * HintPadPx + ShortLinePx * textRows(itemHintText(), CaptionPx, widthPx - 2 * InsetPx)

proc sectionHeaderPx(source, counts: string; widthPx: int): int =
  ## The header strip's height (`drawSectionHeader`): its 24px lines, 2px
  ## apart, 4px above and below, its hairline.
  let items = @[FlowItem(widthPx: textPx(InboxSectionLabel.toUpperAscii, CaptionPx) * 11 div 10),
                FlowItem(widthPx: textPx(source, CaptionPx), grow: true),
                FlowItem(widthPx: textPx(counts, CaptionPx), alignEnd: true)]
  let lines = flowLineCount(items, max(1, widthPx - 2 * InsetPx), 8)
  8 + lines * 24 + (lines - 1) * 2 + 1

proc drawInboxPanelParts(r: GpuiRenderer; host: GpuiElement; vm: InboxVM; p: AhPalette;
                         widthPx: int; ctx: AgentHarborInboxContext; heightPx: int;
                         scroll: P3Scroll) =
  ## The Inbox panel over `vm`, `widthPx` wide; with the viewmodel's pages
  ## on, the item on screen's page under (or beside) the rows, or, while
  ## items wait and none is on screen, the hint in the page's place.
  ## Redrawn whole on each call. Given its `heightPx`, the rows and the page
  ## under them scroll as one region (`InboxRegionKey`), or, beside, the
  ## rows and the page each as one (`InboxListRegionKey`,
  ## `InboxPageRegionKey`); the item on screen is brought to its region's
  ## top when it changes and is out of view, so its page under the rows
  ## shows with it. Without a height they are clipped at the panel's foot.
  scroll.beginDraw()
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
    r.appendChild(host, r.routedErrorBlock(p, InboxErrorTitle, vm.error.val,
                                           InboxRetryOperation, proc() = target.restart()))
    return
  of asReady: discard
  r.appendChild(host, r.drawStepper(p, ink, vm, widthPx))
  var used = sectionHeaderPx(ctx.scope, counts, widthPx) + StepperPx
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
    used += 8 + ShortLinePx * textRows(line, CaptionPx, widthPx - 2 * InsetPx) + 1
  let viewPx = if heightPx > 0: max(1, heightPx - used) else: 0
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
  var parts: seq[ScrollPart]
  if notice.len > 0:
    # The list is not a flex container (`.ah-fleet-list`), so the overlay's
    # centring has no height to centre in: the notice sits at the top of the
    # list, one line high, centred across it.
    let n = r.notice(p, notice, "empty")
    r.styles(n, [("flex-grow", "0"), ("flex-shrink", "0")])
    r.appendChild(list, n)
  else:
    parts = r.rowParts(p, ink, vm, ctx, listW - (if beside: 1 else: 0))
  let page = vm.page
  let keep = if page.isNil: "" else: vm.current.val.id
  let pageW = if beside: widthPx - ListBesidePx else: widthPx
  var pageHost: GpuiElement
  var pagePx = 0
  if not page.isNil:
    # Under the rows the page keeps its content's height (`.ah-inbox-page`
    # is not a flex item that shrinks; the column scrolls); beside them it
    # takes the free width.
    pageHost = r.box(column = true, pairs = [("min-width", "0px"), ("flex-shrink", "0"),
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
      pagePx += 10 + ShortLinePx * textRows(strip, CaptionPx, pageW - 2 * InsetPx)
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
    pagePx += itemPagePx(p, page, pageCtx, pageW)
  elif vm.wantsItemHint:
    # Items wait and none is on screen: the page's place says how to put
    # one there. Nothing is opened for the reader.
    pageHost = r.stepperHint(p, beside)
    pagePx = hintPx(pageW)
  if viewPx > 0 and parts.len > 0 and not beside:
    # The rows and what stands under them scroll as one region.
    # The rows in a box of their own (the web's `.ah-inbox-list` inside its
    # scrolling `.ah-inbox-main`), the page under it.
    let rowCount = parts.len
    if pageHost != nil: parts.add ScrollPart(el: pageHost, heightPx: pagePx)
    let region = r.scrollWindow(scroll, InboxRegionKey, parts, viewPx, keep, keepAtTop = true,
                                groupCount = rowCount, groupFact = "rows",
                                groupValue = "inbox")
    r.appendChild(main, region)
    r.appendChild(host, main)
    return
  if viewPx > 0 and parts.len > 0:
    r.setStyle(list, "height", $viewPx & "px")
    r.appendChild(list, r.scrollWindow(scroll, InboxListRegionKey, parts, viewPx, keep,
                                       keepAtTop = true))
  else:
    for part in parts: r.appendChild(list, part.el)
  r.appendChild(main, list)
  if pageHost != nil:
    if viewPx > 0 and beside and not page.isNil and pagePx > viewPx:
      let w = r.box(column = true, pairs = [("flex-grow", "1"), ("flex-shrink", "1"),
                                            ("min-width", "0px")])
      r.styles(pageHost, [("flex-grow", "0"), ("flex-shrink", "0")])
      r.appendChild(w, r.scrollWindow(scroll, InboxPageRegionKey,
        @[ScrollPart(el: pageHost, heightPx: pagePx)], viewPx, ""))
      r.appendChild(main, w)
    else:
      r.appendChild(main, pageHost)
  r.appendChild(host, main)

proc drawInboxPanel*(r: GpuiRenderer; host: GpuiElement; vm: InboxVM; p: AhPalette;
                     widthPx: int; ctx = AgentHarborInboxContext(); heightPx = 0;
                     scroll: P3Scroll = nil; press: PanelPress = nil) =
  ## `drawInboxPanelParts`, its presses through `press` (the base keymap's
  ## `inboxPresses` when nil).
  drawingWith(if press.isNil: inboxPresses(vm, nil) else: press):
    drawInboxPanelParts(r, host, vm, p, widthPx, ctx, heightPx, scroll)

proc mountInboxPanel*(r: GpuiRenderer; host: GpuiElement; vm: InboxVM; p: AhPalette;
                      widthPx: int; ctx = AgentHarborInboxContext(); heightPx = 0;
                      scroll: P3Scroll = nil; redraw: Signal[int] = nil;
                      press: PanelPress = nil) =
  ## Draws the panel, redraws it whenever what it reads changes (or the host
  ## moves `redraw`, after a scroll), and (with the viewmodel's pages on)
  ## marks its pages visible while it is mounted, as the web mount does. Its
  ## presses go through `press` (the base keymap's `inboxPresses` when nil).
  let route = if press.isNil: inboxPresses(vm, nil) else: press
  createRenderEffect proc() =
    discard vm.revision.val
    if redraw != nil: discard redraw.val
    drawInboxPanel(r, host, vm, p, widthPx, ctx, heightPx, scroll, route)
  if vm.showPages: vm.setPagesVisible(true)
