## tui/agent_harbor/ah_tui_inbox_panel.nim — CTF-P3. The terminal views of
## the operator's Agent Harbor inbox: the Inbox panel over `InboxVM` and an
## item's page over `InboxItemVM` (nim-agents-isonim-viewmodels `inbox_vm`,
## `inbox_item_vm`).
##
## The same parts, order and words as the web views
## (`viewmodel/views/isonim_agent_harbor_inbox_view.nim`) and GPUI's
## (`gpui/agent_harbor/ah_inbox_panel.nim`), drawn in cells in the manner of
## CodeTracer-TUI §3.4: areas told apart by their ground, no box.
##
## **The Inbox panel**, top to bottom:
##
## - the head band: `INBOX`, whose inbox it is, the counts (`3 waiting · 1
##   blocked`);
## - Previous / Next, a band on the raised ground: `←  3 of 5  →
##   Auto-switch: off`, the arrows on the controls' ground; on a panel 50rem
##   wide or narrower (100 cells) the arrows and `Auto: off` without the
##   position; a step that cannot be taken in the disabled ink and pressing
##   it does nothing. A press asks the viewmodel, which asks the source's
##   cursor: this view keeps no order and no stack;
## - `Incomplete: <server> could not be read (<reason>)` for each server the
##   inbox could not read, a band in the warning ink;
## - one row per item in the server's order, never re-sorted, striped as the
##   fleet's rows: the kind's mark, the session's label, the priority and
##   warmth chips, the age at the right; the kind's words, who holds an item
##   whose agent died, the pending feedback count, `Open` for a kind the
##   client does not know; the server's explanation as served, wrapping. A
##   run of rows from another server is headed by its name and count. The
##   row of the item on screen is a selection: the selection's ground and
##   the action-colour bar `▎`. A press on a row opens its item;
## - with the viewmodel's pages on, the item on screen's page under the rows,
##   or beside them on a panel 60rem wide or wider (120 cells), past a
##   column of the raised ground; headed by the explanation strip while it
##   was reached through Previous or Next.
##
## **An item's page**: its head band (the kind's mark and words, the
## session, the priority menu at the right), then what the agent asks or
## reports and the form that answers it, for each kind and state the
## viewmodel gives, and the viewmodel's validation and answer state under
## it; a submitting answer's words lead with the spinner.
##
## A form's first action is the filled primary button, the others on the
## controls' ground. Every press calls the viewmodel, which validates it and
## sends it only through the data source's `submitAction`; a host action
## (`Open sign-in`, a completed sign-in's `Continue`) is drawn only when the
## host gives one. A sudo password is never drawn: the field says whether one
## was given. The story hosts take no typing, so a field shows what the
## viewmodel holds.
##
## Facts (`AhNode`), named as GPUI's: `surface`, `state`, `width-px`; the
## steps (`inbox-step`, `enabled`, `ink`), `position`, `inbox-auto-switch`,
## `auto-switch-text`, `degraded`; a row (`item`, `item-server`, `kind`,
## `item-position`, `current`, `item-label`, `chip`, `chip-text`, `age`,
## `kind-word`, `holder`, `explanation`), a server's head (`server`,
## `server-name`); the page (`page`, `strip`, `page-state`, `item-kind`,
## `kind-words`, `item-session`, `priority-menu`, `summary-first`, `banner`,
## `question`, `draft`, `form`, `answer-field`, `choices`, `choice`,
## `checked`, `choice-label`, `approval`, `approval-summary`,
## `password-field`, `permission-options`, `login`, `login-state`, …,
## `validation`, `phase`, `phase-text`, `button`).

import std/strutils

import nim_agents/agent_harbor/fleet_records
import nim_agents_isonim_viewmodels/agent_harbor/[inbox_vm, inbox_item_vm]
import ../../viewmodel/views/agent_harbor_changes_inbox_words

import ./ah_tui_changes_inbox_parts
from ./ah_tui_initiative_panels import drawSectionHeader

export inbox_vm, inbox_item_vm, agent_harbor_changes_inbox_words, ah_tui_changes_inbox_parts

const
  CompactStepperMaxPx* = 50 * 16
    ## `@container ah-inbox (max-width: 50rem)`: at this panel width and
    ## narrower the Previous / Next group drops the position and says
    ## `Auto: off`.
  PageBesideMinPx* = 60 * 16
    ## `@container ah-inbox (min-width: 60rem)`: at this panel width and
    ## wider the item's page stands beside the rows.
  ListBesideCells* = 26 * 16 div CellPx
    ## `.ah-inbox-list`: 26rem beside the page.
  CheckOff = "[ ]"
  CheckOn = "[\xE2\x9C\x93]"
    ## [✓]: the design system's checkbox in cells (a box and its check), as
    ## the omnibox composer marks a chosen one of several (`✓`).
  ReadingCells* = 48 * 16 div CellPx
    ## `AH_ITEM_READING_WIDTH`, 48rem: an item page's parts keep to a column
    ## this many cells wide, centred, on a wider pane.
  HintPadRows = 1
    ## Under the rows, a row of the page's ground above and below the hint.
  PasswordGiven = "\xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2"
  PasswordCells = 192 div CellPx  ## `.ah-password-field`: 12rem
  InboxScrollKey* = "inbox"
    ## The scrolling region of the rows and the page under them.
  InboxListScrollKey* = "inbox-list"
  InboxPageScrollKey* = "inbox-page"
    ## The two regions when the page stands beside the rows.
  PageScrollKey* = "page"
    ## The region of an item's page standing alone.
  SubPageRows = 2000
    ## The page's ground under its content in a scrolling region.

type
  PageDraw = object
    ## What every part of a page draws with.
    page: InboxItemVM
    ctx: AgentHarborInboxItemContext
    s: AhP3State
    g: P3Grounds
    col, width: int       ## the page's columns (its reading measure)
    bandCol, bandWidth: int
      ## The whole page's columns: the head band runs across them, so the
      ## band, not the page's ground, meets what is above the page.
    ground: string        ## the page's own ground

proc endArea(c: var AhCanvas; name: string; row, col, width, height: int; bg: string) =
  ## A row on the panel's own ground is the panel: it is not an area of its
  ## own, so it has no boundary with the panel around it.
  if height > 0 and bg != c.p3Grounds.panel:
    c.areas.add AhArea(name: name, row: row, col: col, width: width, height: height, bg: bg)

# ---------------------------------------------------------------------------
# An item's page
# ---------------------------------------------------------------------------

# A press made in a loop is made by a proc of its own, so each closure owns
# its value: a closure in a Nim loop body shares the body's variables with
# every other iteration's (https://nim-lang.org/docs/manual.html#closures-creating-closures-in-loops).

proc choicePress(page: InboxItemVM; id: string): proc() =
  result = proc() = page.toggleChoice(id)

proc decisionPress(page: InboxItemVM; requestId: string; decision: ApprovalDecision): proc() =
  result = proc() = discard page.decideApproval(requestId, decision)

proc permissionPress(page: InboxItemVM; id: string): proc() =
  result = proc() = discard page.choosePermission(id)

proc x(d: PageDraw): int = d.col + 1
proc w(d: PageDraw): int = max(1, d.width - 2)

proc prose(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int; text: string;
           fact = "prose"; fg = ""; bold = false): int =
  ## Prose, wrapped across the page (`.ah-item-prose`); a line of the text
  ## a line here. Returns the rows.
  let n = c.node(parent, row, d.x, d.w, 1, [(fact, text)])
  var r = row
  for part in text.splitLines:
    let lines = if part.len == 0: @[""] else: wrapCells(part, d.w)
    for l in lines:
      discard c.put(r, d.x, l, if fg.len > 0: fg else: c.p.textBody, bold)
      inc r
  n.height = r - row
  r - row

proc sectionHead(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int;
                 name, meta: string) =
  ## A page section's small-caps head and its quiet meta (`.ah-item-section-head`).
  let used = c.drawSmallCaps(parent, row, d.x, d.w, name)
  if meta.len > 0:
    discard c.text(parent, row, d.x + used + 2, max(1, d.w - used - 2), meta, c.p.textCaption,
                   fact = "section-meta")

proc drawDraft(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int; draft: Draft;
               disabled: bool): int =
  ## A manager's draft (`.ah-item-draft`): its provenance, rationale and
  ## text a cell further in, past the information-colour bar `▎`, then
  ## `Send draft`.
  let n = c.node(parent, row, d.col, d.width, 1, [("draft", "true")])
  var inner = d
  inner.col = d.col + 2
  inner.width = d.width - 2
  var r = row
  c.sectionHead(inner, n, r, DraftHead, confidenceText(draft))
  inc r
  if draft.rationale.len > 0:
    r += c.prose(inner, n, r, draft.rationale, "draft-rationale", c.p.textCaption)
  if draft.text.len > 0: r += c.prose(inner, n, r, draft.text, "draft-text")
  if draft.choices.len > 0: r += c.prose(inner, n, r, draft.choices.join(", "), "draft-text")
  let page = d.page
  r += c.drawButtons(n, r, inner.x, inner.w, @[AhButton(label: SendDraftLabel, primary: true,
    disabled: disabled, press: proc() = discard page.sendDraft())])
  for k in row ..< r: discard c.put(k, d.col + 1, BarGlyph, c.inks.borderInfo)
  n.height = r - row
  r - row

proc drawToggles(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int;
                 options: seq[AnswerOption]; disabled: bool): int =
  ## One choice: a row of the omnibox composer's toggles (the design system
  ## has no radio button), each ` label ` on a ground of its own, a cell
  ## apart: the chosen one on the selection's ground, its label bold in the
  ## body ink, the others on the controls' ground in the label ink. A line
  ## that cannot hold the next toggle wraps, a row of the page's ground
  ## between the lines, so two toggles one above the other never share a
  ## ground edge to edge. A press on a toggle chooses it. Returns the rows.
  let n = c.node(parent, row, d.x, d.w, 1, [("choices", "single")])
  let chosen = d.page.choices.val
  let page = d.page
  var r = row
  var x = d.x
  for o in options:
    let checked = o.id in chosen
    let label = " " & o.label & (if o.description.len > 0: "  " & o.description else: "") & " "
    let w = min(widthOf(label), d.w)
    if x > d.x and x + w > d.x + d.w:
      r += 2
      x = d.x
    let fg = if disabled: c.p.textDisabled elif checked: c.p.textBody else: c.p.textLabel
    discard c.put(r, x, elide(label, w), fg, bold = checked and not disabled,
                  bg = (if checked: d.g.selection else: d.g.control))
    let t = c.node(n, r, x, w, 1, [("choice", o.id), ("checked", $checked),
                                    ("control", "toggle")])
    discard c.node(t, r, x + 1, min(widthOf(o.label), w - 1), 1, [("choice-label", o.label)])
    if not disabled: c.target(r, x, w, 1, choicePress(page, o.id))
    x += w + 1
  n.height = r - row + 1
  r - row + 1

proc drawChoices(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int;
                 options: seq[AnswerOption]; single, disabled: bool): int =
  ## One choice: the toggles (`drawToggles`); several: the design system's
  ## checkboxes, `[✓]` or `[ ]`, each with its label and description; a
  ## press on a choice's line toggles it.
  if single: return c.drawToggles(d, parent, row, options, disabled)
  let n = c.node(parent, row, d.x, d.w, max(1, options.len),
                 [("choices", "multi")])
  let chosen = d.page.choices.val
  let page = d.page
  var r = row
  for o in options:
    let checked = o.id in chosen
    let box = if checked: CheckOn else: CheckOff
    let line = c.node(n, r, d.x, d.w, 1, [("choice", o.id), ("checked", $checked)])
    discard c.node(line, r, d.x, widthOf(box), 1, [("control", "checkbox")])
    discard c.put(r, d.x, box, if disabled: c.p.textDisabled
                               elif checked: c.p.borderAction else: c.p.textLabel,
                  bold = checked)
    let lx = d.x + widthOf(box) + 1
    let lw = max(1, d.x + d.w - lx)
    let used = c.text(line, r, lx, lw, o.label, if disabled: c.p.textDisabled else: c.p.textBody,
                      fact = "choice-label")
    var rows = 1
    if o.description.len > 0:
      let dx = lx + used + 2
      if dx + 8 <= d.x + d.w:
        rows = max(1, c.para(line, r, dx, d.x + d.w - dx, o.description, c.p.textCaption,
                             fact = "choice-description"))
      else:
        rows = 1 + c.para(line, r + 1, lx, lw, o.description, c.p.textCaption,
                          fact = "choice-description")
    line.height = rows
    if not disabled: c.target(r, d.x, d.w, rows, choicePress(page, o.id))
    r += rows
  n.height = r - row
  r - row

proc textInput(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int; placeholder: string;
               disabled: bool): int =
  let n = c.node(parent, row, d.x, d.w, FieldRows, [("answer-field", placeholder)])
  c.drawTextField(n, row, d.x, d.w, d.page.text.val, placeholder, disabled)

proc drawBanner(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int; text, role: string): int =
  ## A question's banner (`.ah-item-banner`): a band of its own ground, the
  ## dot in its role and the words in its ink, wrapping.
  let lines = wrapCells(text, max(1, d.w - 2))
  c.area("banner", row, d.col, d.width, lines.len, d.g.banner)
  let n = c.node(parent, row, d.col, d.width, lines.len, [("banner", text), ("role", role)])
  discard c.mark(n, row, d.x, c.p.roleDot(role))
  let ink = c.p.roleInk(c.inks, role)
  for i, l in lines: discard c.put(row + i, d.x + 2, l, ink)
  lines.len

proc drawQuestion(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int; it: InboxItemDetail): int =
  let page = d.page
  var r = row
  let banner = page.banner
  if banner.len > 0:
    r += c.drawBanner(d, parent, r, banner, if it.blocked: "warning" else: "info")
    inc r
  if it.prompt.len > 0:
    r += c.prose(d, parent, r, it.prompt, "question", bold = true)
    inc r
  if it.draft.present:
    r += c.drawDraft(d, parent, r, it.draft, false)
    inc r
  let noOptions = page.optionsNotice
  if noOptions.len > 0:
    r += c.prose(d, parent, r, noOptions, "no-options", c.p.textCaption)
    return r - row
  let form = c.node(parent, r, d.x, d.w, 1, [("form", $it.form)])
  let now = d.ctx.nowMs
  case it.form
  of qfFreeForm: r += c.textInput(d, form, r, AnswerPlaceholder, false)
  of qfSingle, qfMulti: r += c.drawChoices(d, form, r, it.options, it.form == qfSingle, false)
  of qfConfirmation: discard
  if it.form != qfConfirmation: inc r
  case it.form
  of qfFreeForm, qfSingle, qfMulti:
    r += c.drawButtons(form, r, d.x, d.w, @[AhButton(label: SubmitLabel, primary: true,
      press: proc() = discard page.submit(now))])
  of qfConfirmation:
    r += c.drawButtons(form, r, d.x, d.w, @[
      AhButton(label: ApproveLabel, primary: true, press: proc() =
        page.setDecision("approve")
        discard page.submit(now)),
      AhButton(label: RejectLabel, press: proc() =
        page.setDecision("reject")
        discard page.submit(now))])
  form.height = r - form.row
  r - row

proc drawEndedTurn(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int; it: InboxItemDetail): int =
  let page = d.page
  var r = row
  if it.lastReply.len > 0:
    c.sectionHead(d, parent, r, LastReplyHead, "")
    inc r
    r += c.prose(d, parent, r, it.lastReply, "last-reply")
    inc r
  let now = d.ctx.nowMs
  let form = c.node(parent, r, d.x, d.w, 1, [("form", "instruction")])
  r += c.textInput(d, form, r, InstructionPlaceholder, false)
  inc r
  r += c.drawButtons(form, r, d.x, d.w, @[AhButton(label: SendLabel, primary: true,
    press: proc() = discard page.submit(now))])
  form.height = r - form.row
  r - row

proc drawApproval(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int; a: ApprovalRequest;
                  ground: string): int =
  ## One queued sudo or network approval (`.ah-item-approval`), a band of
  ## its own (where the web draws a hairline above it): `<command> in order
  ## to: <reason>`, then (sudo) the password field and the three decisions.
  let page = d.page
  let requestId = a.requestId
  let subject = approvalSubject(a)
  let purpose = approvalPurposeText(a)
  var buttons: seq[AhButton]
  for (label, primary, decision) in [(ApproveLabel, true, adApprove),
                                     (ApproveForSessionLabel, false, adApproveForSession),
                                     (DenyLabel, false, adDeny)]:
    buttons.add AhButton(label: label, primary: primary,
                         press: decisionPress(page, requestId, decision))
  # The command (or the domain) on a line of its own in code style (bold, in
  # the information ink, as the panels draw a path or a hunk's head), why
  # the agent asks under it in prose.
  let subjectLines = wrapCells(subject, d.w)
  let purposeLines = if purpose.len > 0: wrapCells(purpose, d.w) else: @[]
  let lines = subjectLines & purposeLines
  # The rows first: the band is painted before what is drawn on it.
  var actionRows = 1
  var x = d.x + (if a.scope == asSudo: PasswordCells + 1 else: 0)
  for b in buttons:
    if x > d.x and x + buttonCells(b.label) > d.x + d.w:
      inc actionRows
      x = d.x
    x += buttonCells(b.label) + 1
  let rows = 1 + lines.len + 1 + actionRows + 1
  c.fill(row, d.col, d.width, rows, ground)
  c.endArea("approval", row, d.col, d.width, rows, ground)
  let n = c.node(parent, row, d.col, d.width, rows, [("approval", $a.scope)])
  var r = row + 1
  r += c.prose(d, n, r, subject, "approval-subject", c.inks.textInfo, bold = true)
  if purpose.len > 0: r += c.prose(d, n, r, purpose, "approval-purpose")
  inc r
  let actions = c.node(n, r, d.x, d.w, actionRows, [("actions", $buttons.len)])
  x = d.x
  if a.scope == asSudo:
    let given = page.passwordSet.val
    discard c.put(r, x, " " & alignLeft(if given: PasswordGiven else: PasswordPlaceholder,
                                         PasswordCells - 2) & " ",
                  if given: c.p.textBody else: c.inks.placeholder, bg = d.g.field)
    discard c.node(actions, r, x, PasswordCells, 1, [("password-field", $given)])
    x += PasswordCells + 1
  for b in buttons:
    if x > d.x and x + buttonCells(b.label) > d.x + d.w:
      inc r
      x = d.x
    x += c.drawButton(actions, r, x, b) + 1
  rows

proc drawPermission(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int; it: InboxItemDetail): int =
  let page = d.page
  var r = row
  if it.prompt.len > 0:
    r += c.prose(d, parent, r, it.prompt, "question", bold = true)
    inc r
  if it.permissionOptions.len > 0:
    var buttons: seq[AhButton]
    for i, o in it.permissionOptions:
      buttons.add AhButton(label: o.label, primary: i == 0,
                           press: permissionPress(page, o.id))
    let n = c.node(parent, r, d.x, d.w, 1, [("permission-options", $it.permissionOptions.len)])
    r += c.drawButtons(n, r, d.x, d.w, buttons)
    # A row apart from the approvals under it (none: the answer's state
    # follows the buttons directly, as on the web).
    if it.approvals.len > 0: inc r
  for i, approval in it.approvals:
    let ground = if i mod 2 == 0: d.g.stripe else: d.ground
    r += c.drawApproval(d, parent, r, approval, ground)
  r - row

proc drawLogin(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int; it: InboxItemDetail): int =
  ## A login request in the state the viewmodel gives it (`.ah-item-login`).
  let page = d.page
  let login = it.login
  let hasRequest = page.hasLoginRequest
  let state = page.loginState
  let error = page.loginError
  let canCancel = page.canCancelLogin
  let n = c.node(parent, row, d.x, d.w, 1, [("login", if hasRequest: $state else: "none")])
  var r = row
  if hasRequest and login.provider.len > 0:
    r += c.prose(d, n, r, login.provider, "login-provider", bold = true)
  if hasRequest and login.prompt.len > 0 and login.mode == lmLocalDesktop:
    r += c.prose(d, n, r, login.prompt)
  r += c.prose(d, n, r, page.loginText, "login-state",
               c.p.roleInk(c.inks, loginStateRole(state, hasRequest)))
  if error.len > 0: r += c.prose(d, n, r, error, "login-error", c.p.textError)
  var buttons: seq[AhButton]
  if canCancel and d.ctx.onOpenSignIn != nil:
    let open = d.ctx.onOpenSignIn
    buttons.add AhButton(label: OpenSignInLabel, primary: true, press: proc() = open())
  if canCancel:
    buttons.add AhButton(label: CancelLabel, primary: d.ctx.onOpenSignIn == nil,
                         press: proc() = discard page.cancelLogin())
  if page.canContinueLogin and d.ctx.onContinue != nil:
    let onContinue = d.ctx.onContinue
    buttons.add AhButton(label: ContinueLabel, primary: true, press: proc() = onContinue())
  if buttons.len > 0:
    inc r
    r += c.drawButtons(n, r, d.x, d.w, buttons)
  n.height = r - row
  r - row

proc drawFeedback(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int; it: InboxItemDetail): int =
  let page = d.page
  let fb = it.feedback
  let now = d.ctx.nowMs
  let expired = page.isExpired(now)
  let badge = page.expiredBadge(now)
  var r = row
  if badge.len > 0:
    discard c.drawChip(parent, r, d.x, badge, "error", "expired")
    r += 2
  if fb.prompt.len > 0:
    r += c.prose(d, parent, r, fb.prompt, "question", bold = true)
  if fb.context.len > 0:
    r += c.prose(d, parent, r, fb.context, "context", c.p.textCaption)
  if fb.prompt.len > 0 or fb.context.len > 0: inc r
  if fb.attachments.len > 0:
    c.sectionHead(d, parent, r, AttachmentsHead, "")
    inc r
    for att in fb.attachments:
      discard c.text(parent, r, d.x, d.w, attachmentText(att), c.p.textLabel, fact = "attachment")
      inc r
    inc r
  if it.draft.present:
    r += c.drawDraft(d, parent, r, it.draft, expired)
    inc r
  let form = c.node(parent, r, d.x, d.w, 1, [("form", $fb.feedbackType)])
  var buttons: seq[AhButton]
  case fb.feedbackType
  of ftQuestion:
    r += c.textInput(d, form, r, ResponsePlaceholder, expired)
    inc r
    buttons = @[AhButton(label: SubmitLabel, primary: true, disabled: expired,
                         press: proc() = discard page.submit(now))]
  of ftOptions:
    r += c.drawChoices(d, form, r, fb.options, false, expired)
    inc r
    buttons = @[AhButton(label: SubmitLabel, primary: true, disabled: expired,
                         press: proc() = discard page.submit(now))]
  of ftConfirmation:
    buttons = @[
      AhButton(label: ApproveLabel, primary: true, disabled: expired, press: proc() =
        page.setDecision("approve")
        discard page.submit(now)),
      AhButton(label: RejectLabel, disabled: expired, press: proc() =
        page.setDecision("reject")
        discard page.submit(now))]
  of ftInformation:
    buttons = @[AhButton(label: AcknowledgeLabel, primary: true, disabled: expired,
                         press: proc() = discard page.submit(now))]
  r += c.drawButtons(form, r, d.x, d.w, buttons)
  form.height = r - form.row
  r - row

proc drawStatusLines(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int): int =
  ## Why the last press sent nothing, and the page's last action's state,
  ## each in its role's ink; a submitting answer leads with the spinner.
  let page = d.page
  let problem = page.validation.val
  let phaseText = page.phaseText
  var r = row
  if problem.len == 0 and phaseText.len == 0: return 0
  if problem.len > 0: r += c.prose(d, parent, r, problem, "validation", c.p.textError)
  if phaseText.len > 0:
    let role = case page.phase
      of ppFailed: "error"
      of ppAnswered: "success"
      else: "quiet"
    let busy = page.phase == ppSubmitting
    let lead = if busy: spinnerOf(d.s) & " " else: ""
    if busy and not d.s.isNil: d.s.spinning = true
    let n = c.node(parent, r, d.x, d.w, 1, [("phase", $page.phase)])
    let ink = c.p.roleInk(c.inks, role)
    if lead.len > 0: discard c.put(r, d.x, lead, ink)
    var inner = d
    inner.col = d.col + widthOf(lead)
    inner.width = d.width - widthOf(lead)
    let rows = c.prose(inner, n, r, phaseText, "phase-text", ink)
    n.height = rows
    r += rows
  r - row

proc drawItemHead(c: var AhCanvas; d: PageDraw; parent: AhNode; row: int; it: InboxItemDetail) =
  ## The page's head band (`.ah-item-head`): the kind's mark and words in
  ## small caps, the session's label taking the free width, the priority
  ## menu at the right.
  c.area("item-head", row, d.bandCol, d.bandWidth, 1, d.g.groupHead)
  let n = c.node(parent, row, d.col, d.width, 1, [("item-kind", $it.kind)])
  discard c.mark(n, row, d.x, c.p.roleDot(kindRole(it.kind)))
  let words = kindWordOf(it.kind).toUpperAscii
  var menuChoices: seq[AhMenuChoice]
  for pr in priorityChoices():
    menuChoices.add AhMenuChoice(id: $pr, label: priorityKeyText(pr))
  # The design system's dropdown, its value whole (`Priority`); its menu as
  # wide as its widest choice (`drawMenus`).
  let menuW = min(widthOf(PriorityLabel) + 4, max(4, d.width - 6))
  let menuCol = d.col + d.width - 1 - menuW
  let used = c.text(n, row, d.x + 2, max(1, menuCol - 2 - d.x - 2), words, c.p.textLabel,
                    bold = true, fact = "kind-words")
  let sx = d.x + 2 + used + 2
  if d.ctx.sessionLabel.len > 0 and sx < menuCol - 2:
    discard c.text(n, row, sx, menuCol - 2 - sx, d.ctx.sessionLabel, c.p.textCaption,
                   fact = "item-session", before = menuCol)
  let page = d.page
  discard c.drawSelect(d.s, n, row, menuCol, menuW, "priority", "priority-menu",
                       PriorityLabel, menuChoices, "",
                       proc(id: string) =
                         for pr in priorityChoices():
                           if $pr == id: discard page.setPriority(pr))

proc drawItemPageBody*(c: var AhCanvas; page: InboxItemVM; ctx: AgentHarborInboxItemContext;
                       parent: AhNode; row, col, width, height: int; ground: string;
                       state: AhP3State = nil): int =
  ## One page's content for its load state from (`row`, `col`), `width`
  ## cells wide, on `ground` (which the caller has laid). A ready page's
  ## parts keep to a column at most `ReadingCells` wide, centred (the web's
  ## `.ah-item-page > *`). Returns the rows.
  let bandCol = col
  let bandWidth = width
  var col = col
  var width = width
  if page.state.val == asReady and width > ReadingCells:
    col += (width - ReadingCells) div 2
    width = ReadingCells
  let d = PageDraw(page: page, ctx: ctx, s: state, g: c.p3Grounds, col: col, width: width,
                   bandCol: bandCol, bandWidth: bandWidth, ground: ground)
  let body = c.node(parent, row, col, width, max(1, height),
                    [("page-state", stateName(page.state.val))])
  case page.state.val
  of asIdle, asLoading:
    c.notice(body, row, col, width, height, ItemLoadingNotice, "loading")
    return height
  of asError:
    let unresolvable = page.notice
    if unresolvable.len > 0:
      c.notice(body, row, col, width, height, unresolvable, "unresolvable")
    else:
      let target = page
      c.errorBlock(body, row, col, width, height, ItemErrorTitle, page.error.val,
                   proc() = target.load())
    return height
  of asReady: discard
  let it = page.detail
  body.tag("reading-width", $width)
  c.drawItemHead(d, body, row, it)
  var r = row + 2
  if page.leadsWithSummary:
    let s = c.node(body, r, col, width, 1, [("summary-first", "true")])
    c.sectionHead(d, s, r, SummaryHead, "")
    inc r
    r += c.prose(d, s, r, it.executiveSummary, "executive-summary")
    s.height = r - s.row
    inc r
  case it.kind
  of ikBlockedQuestion, ikUnknown: r += c.drawQuestion(d, body, r, it)
  of ikEndedTurn: r += c.drawEndedTurn(d, body, r, it)
  of ikPermissionGate: r += c.drawPermission(d, body, r, it)
  of ikLoginRequest: r += c.drawLogin(d, body, r, it)
  of ikAsyncFeedback: r += c.drawFeedback(d, body, r, it)
  r += c.drawStatusLines(d, body, r)
  body.height = max(body.height, r - row)
  r - row

proc standaloneBody(page: InboxItemVM; ctx: AgentHarborInboxItemContext; state: AhP3State;
                    g: P3Grounds; col, height: int): ScrolledBody =
  ## A scrolling region's content: an item's page standing alone.
  result = proc(sub: var AhCanvas; parent: AhNode; row, w: int): int =
    sub.drawItemPageBody(page, ctx, parent, row, col, w, height, g.panel, state)

proc drawInboxItemPage*(c: var AhCanvas; page: InboxItemVM; row, col, width, height: int;
                        ctx = AgentHarborInboxItemContext(); state: AhP3State = nil) =
  ## An item's page standing alone (the session tab's page).
  state.beginDraw()
  let g = c.p3Grounds
  let root = c.node(nil, row, col, width, height,
                    [("surface", "agent-harbor-inbox-item"), ("width-px", $(width * CellPx)),
                     ("state", stateName(page.state.val))])
  c.area("page", row, col, width, height, g.panel)
  let n = c.node(root, row, col, width, height, [("page", "standalone")])
  discard c.drawScrolled(state, PageScrollKey, n, row, col, width, height, g.panel, "", "",
                         standaloneBody(page, ctx, state, g, col, height))
  c.drawMenus(state)

# ---------------------------------------------------------------------------
# The Inbox panel
# ---------------------------------------------------------------------------

proc drawStepper(c: var AhCanvas; vm: InboxVM; parent: AhNode; row, col, width: int;
                 g: P3Grounds) =
  ## `←  3 of 5  →  Auto-switch: off` (`.ah-inbox-stepper`), a band on the
  ## raised ground; compact at 50rem and narrower.
  c.area("stepper", row, col, width, 1, g.tabBand)
  let compact = width * CellPx <= CompactStepperMaxPx
  let position = vm.positionText
  let on = vm.autoSwitch.val
  let n = c.node(parent, row, col, width, 1, [("stepper", "inbox"), ("stepper-position", position)])
  let target = vm
  var x = col + 1
  proc step(c: var AhCanvas; arrow, title: string; enabled: bool; act: proc()) =
    let ink = if enabled: c.p.textBody else: c.p.textDisabled
    discard c.put(row, x, " " & arrow & " ", ink, bg = g.control)
    discard c.node(n, row, x, 3, 1, [("inbox-step", title), ("enabled", $enabled),
                                     ("ink", ink), ("tooltip", title)])
    if enabled: c.target(row, x, 3, 1, act)
    x += 4
  c.step(PreviousArrow, stepperTitle(false), vm.canPrev, proc() = discard target.prev())
  if not compact and position.len > 0:
    discard c.text(n, row, x, widthOf(position), position, c.p.textLabel, fact = "position")
    x += widthOf(position) + 1
  c.step(NextArrow, stepperTitle(true), vm.canNext, proc() = discard target.next())
  let words = autoSwitchText(on, compact)
  x += 1
  let a = c.node(n, row, x, widthOf(words) + 2, 1, [("inbox-auto-switch", if on: "on" else: "off")])
  if on: discard c.put(row, x, DotGlyph, c.p.borderAction)
  discard c.text(a, row, x + 2, widthOf(words), words, if on: c.p.textBody else: c.p.textLabel,
                 fact = "auto-switch-text")
  c.target(row, x, widthOf(words) + 2, 1, proc() = target.setAutoSwitch(not on))

proc drawRow(c: var AhCanvas; vm: InboxVM; ctx: AgentHarborInboxContext; parent: AhNode;
             item: InboxItem; onScreen: bool; row, col, width: int; ground: string): int =
  ## One item: the kind's mark, then the label line (the label, the chips,
  ## the age at the right), the kind's words line and the explanation,
  ## wrapping; on screen, the selection and its bar. Returns the rows.
  let itemRef = item.refOf
  let label = if item.session.label.len > 0: item.session.label else: item.session.title
  let priority = priorityChip(item)
  let warmth = warmthChip(item.warmth, ctx.nowMs)
  let age = ageLabel(ctx.nowMs, item.enteredAtMs)
  let holder = holderText(item)
  let pendingText = vm.pendingFeedbackText(itemRef)
  let x = col + 3
  let w = max(1, width - 4)
  let explanation = if item.explanation.len > 0: wrapCells(item.explanation, w) else: @[]
  let rows = 2 + explanation.len
  let bg = if onScreen: c.p3Grounds.selection else: ground
  c.fill(row, col, width, rows, bg)
  let n = c.node(parent, row, col, width, rows,
                 [("item", item.id), ("item-server", item.server), ("kind", item.kindText),
                  ("item-position", $item.position), ("current", $onScreen),
                  ("tooltip", label)])
  if onScreen:
    for k in 0 ..< rows: discard c.put(row + k, col, BarGlyph, c.p.borderAction)
  discard c.mark(n, row, col + 1, c.p.roleDot(kindRole(item.kind)))
  # The label line, from its end: the age, then the chips before it.
  var right = col + width - 1
  if age.len > 0:
    right -= widthOf(age)
    discard c.text(n, row, right, widthOf(age), age, c.p.textCaption, fact = "age")
    right -= 1
  var chips: seq[(string, string, string)]
  if priority.len > 0: chips.add (priority, priorityRole(item), "priority")
  if warmth.len > 0: chips.add (warmth, warmthRole(warmth), "warmth")
  var chipsW = 0
  for (t, _, _) in chips: chipsW += widthOf(t) + 3
  if chipsW > 0 and right - chipsW > x + 8:
    var cx = right - chipsW + 1
    for (t, role, kind) in chips:
      cx += c.drawChip(n, row, cx, t, role, kind) + 1
    right -= chipsW
  discard c.text(n, row, x, max(1, right - 1 - x), label, c.p.textBody, fact = "item-label",
                 before = right + 1)
  # The kind's words line.
  var lx = x
  lx += c.text(n, row + 1, lx, w, kindWord(item), c.p.textLabel, fact = "kind-word") + 2
  if holder.len > 0:
    let h = c.drawStateWord(n, row + 1, lx, holder,
                            if item.heldBy == ihOperator: "warning" else: "quiet",
                            maxCells = max(3, x + w - lx))
    h.tag("holder", holder)
    lx += h.width + 2
  if pendingText.len > 0 and lx + widthOf(pendingText) + 2 <= x + w:
    lx += c.drawChip(n, row + 1, lx, pendingText, "info", "pending") + 2
  if item.kind == ikUnknown:
    let target = vm
    let bw = buttonCells(OpenLabel)
    discard c.drawButton(n, row + 1, max(lx, col + width - 1 - bw), AhButton(label: OpenLabel,
      press: proc() = target.open(itemRef)))
  for i, l in explanation:
    discard c.put(row + 2 + i, x, l, c.p.textCaption)
  if explanation.len > 0:
    discard c.node(n, row + 2, x, w, explanation.len, [("explanation", item.explanation)])
  let target = vm
  c.target(row, col, width, rows, proc() = target.open(itemRef))
  c.endArea("row", row, col, width, rows, bg)
  rows

proc drawRows(c: var AhCanvas; vm: InboxVM; ctx: AgentHarborInboxContext; parent: AhNode;
              row, col, width: int; g: P3Grounds): int =
  ## The rows in the server's order. A run of rows from another server is
  ## headed by its name and count; the order is never changed to group them.
  let items = vm.items
  var fleet = false
  for item in items:
    if item.server.len > 0: fleet = true
  let current = vm.current.val
  var r = row
  var i = 0
  var k = 0
  var previous = ""
  while i < items.len:
    var j = i + 1
    if fleet:
      while j < items.len and items[j].server == items[i].server: inc j
      let server = items[i].server
      let name = if server.len > 0: server else: ThisServerLabel
      c.area("server-head", r, col, width, 1, g.groupHead)
      let head = c.node(parent, r, col, width, 1, [("server", server)])
      let used = c.text(head, r, col + 1, max(1, width - 6), name, c.p.textLabel, bold = true,
                        fact = "server-name")
      discard c.put(r, col + 1 + used + 1, $(j - i), c.p.textCaption)
      inc r
      previous = g.groupHead
      k = 0
    for m in i ..< j:
      var ground = g.stripeOf(k)
      if ground == previous:
        inc k
        ground = g.stripeOf(k)
      inc k
      let onScreen = items[m].refOf == current
      r += c.drawRow(vm, ctx, parent, items[m], onScreen, r, col, width, ground)
      previous = if onScreen: g.selection else: ground
    i = j
  r - row

proc drawInboxList(sub: var AhCanvas; vm: InboxVM; ctx: AgentHarborInboxContext;
                   g: P3Grounds; parent: AhNode; row, col, w: int): int =
  ## The rows, or the empty notice at the list's top, one line high,
  ## centred across it (the web's list is no flex container, so the overlay
  ## has no height to centre in). Returns the rows.
  let list = sub.node(parent, row, col, w, 1, [("rows", "inbox")])
  var rows = 0
  if vm.notice().len > 0:
    sub.notice(list, row, col, w, 3, vm.notice(), "empty")
    rows = 3
  else:
    rows = sub.drawRows(vm, ctx, list, row, col, w, g)
  list.height = max(1, rows)
  rows

proc drawInboxPage(sub: var AhCanvas; page: InboxItemVM; pageCtx: AgentHarborInboxItemContext;
                   strip: string; state: AhP3State; g: P3Grounds; parent: AhNode;
                   row, pageCol, w, height: int): int =
  ## The page on screen: the explanation strip while it was reached through
  ## Previous or Next, a row of the page's ground, then the page. Returns
  ## the rows.
  let host = sub.node(parent, row, pageCol, w, 1, [("page", "inbox")])
  sub.area("page", row, pageCol, w, SubPageRows, g.panel)
  var pr = row
  if strip.len > 0:
    let lines = wrapCells(strip, max(1, w - 2))
    sub.area("strip", pr, pageCol, w, lines.len, g.strip)
    discard sub.para(host, pr, pageCol + 1, w - 2, strip, sub.p.textBody, fact = "strip")
    pr += lines.len + 1
  pr += sub.drawItemPageBody(page, pageCtx, host, pr, pageCol, w, height, g.panel, state)
  host.height = pr - row
  pr - row

proc itemContextOf(vm: InboxVM; ctx: AgentHarborInboxContext;
                   label: string): AgentHarborInboxItemContext =
  ## The page on screen's context: the panel's moment and sign-in action,
  ## its typing told to the inbox (auto-switch holds still), its Continue
  ## the inbox's Next.
  result = AgentHarborInboxItemContext(nowMs: ctx.nowMs, onOpenSignIn: ctx.onOpenSignIn,
    onTyping: proc(typing: bool) = vm.setTyping(typing),
    onContinue: proc() = discard vm.next(), sessionLabel: label)

proc drawHint(c: var AhCanvas; parent: AhNode; row, col, width, height: int): int =
  ## The quiet line in the page's place while items wait and none is on
  ## screen (the web's `.ah-inbox-hint`, `InboxVM.wantsItemHint`): the
  ## caption ink, centred across `width`, a row of the page's ground above
  ## and below it; given more `height` than that, in its middle. Nothing is
  ## opened. Returns the rows.
  let hint = itemHintText()
  let lines = wrapCells(hint, max(1, width - 2))
  let rows = lines.len + 2 * HintPadRows
  let top = row + max(HintPadRows, (height - lines.len) div 2)
  let n = c.node(parent, top, col + 1, max(1, width - 2), lines.len, [("item-hint", hint)])
  for i, l in lines:
    discard c.put(top + i, col + max(1, (width - widthOf(l)) div 2), l, c.p.textCaption)
  max(rows, height)

proc listBody(vm: InboxVM; ctx: AgentHarborInboxContext; g: P3Grounds; col: int;
              page: InboxItemVM; pageCtx: AgentHarborInboxItemContext; strip: string;
              state: AhP3State; height: int; hint = false): ScrolledBody =
  ## A scrolling region's content: the rows and, given a page, the page
  ## under them, or the hint in its place. A proc of its own, so the closure
  ## owns what it draws with.
  result = proc(sub: var AhCanvas; parent: AhNode; row, w: int): int =
    var rows = sub.drawInboxList(vm, ctx, g, parent, row, col, w)
    if not page.isNil:
      rows += sub.drawInboxPage(page, pageCtx, strip, state, g, parent, row + rows, col, w,
                                height)
    elif hint:
      rows += sub.drawHint(parent, row + rows, col, w, 0)
    rows

proc pageBody(page: InboxItemVM; pageCtx: AgentHarborInboxItemContext; strip: string;
              state: AhP3State; g: P3Grounds; pageCol, height: int): ScrolledBody =
  ## A scrolling region's content: the page standing beside the rows.
  result = proc(sub: var AhCanvas; parent: AhNode; row, w: int): int =
    sub.drawInboxPage(page, pageCtx, strip, state, g, parent, row, pageCol, w, height)

proc drawInboxPanel*(c: var AhCanvas; vm: InboxVM; row, col, width, height: int;
                     ctx = AgentHarborInboxContext(); state: AhP3State = nil) =
  ## The Inbox panel over `vm` at (`row`, `col`), `width` × `height` cells;
  ## with the viewmodel's pages on, the item on screen's page under (or
  ## beside) the rows.
  state.beginDraw()
  let g = c.p3Grounds
  let root = c.node(nil, row, col, width, height,
                    [("surface", "agent-harbor-inbox"), ("width-px", $(width * CellPx)),
                     ("state", stateName(vm.state.val))])
  c.area("panel-body", row, col, width, height, g.panel)
  let ready = vm.state.val == asReady
  let counts = if ready: inboxCountsText(vm) else: ""
  var r = row + c.drawSectionHeader(root, row, col, width, InboxSectionLabel, ctx.scope, counts)
  if ready:
    let head = root.first("head")
    if head != nil: head.tag("tooltip", vm.controlTitle)
  let bottom = row + height
  case vm.state.val
  of asIdle, asLoading:
    c.notice(root, r, col, width, bottom - r, vm.notice(), "loading")
    return
  of asError:
    let target = vm
    c.errorBlock(root, r, col, width, bottom - r, InboxErrorTitle, vm.error.val,
                 proc() = target.restart())
    return
  of asReady: discard
  c.drawStepper(vm, root, r, col, width, g)
  inc r
  var notes: seq[(string, string)]
  if vm.cursorError.val.len > 0: notes.add (vm.cursorError.val, "error")
  for line in vm.degradedText: notes.add (line, "warning")
  # One band for every note, where the web draws a hairline under each.
  var noteRows = 0
  for (line, _) in notes: noteRows += wrapCells(line, max(1, width - 2)).len
  if noteRows > 0: c.area("degraded", r, col, width, noteRows, g.stripe)
  for (line, role) in notes:
    r += c.para(root, r, col + 1, width - 2, line, c.p.roleInk(c.inks, role),
                fact = "degraded")
  let page = vm.page
  let hint = page.isNil and vm.wantsItemHint
  let beside = width * CellPx >= PageBesideMinPx and (not page.isNil or hint)
  let listW = if beside: ListBesideCells else: width
  let label = block:
    let found = vm.currentItem
    if found.found: found.item.session.label else: ""
  let pageCtx = itemContextOf(vm, ctx, label)
  let strip = if page.isNil: "" else: vm.explanationStrip
  let keepItem = if page.isNil: "" else: vm.current.val.id
  let regionH = max(1, bottom - r)
  if not beside:
    # The rows and the page under them scroll as one region; when the item
    # on screen changes and is out of view, it is brought to the region's
    # top, so its page under the rows shows with it.
    discard c.drawScrolled(state, InboxScrollKey, root, r, col, width, regionH, g.panel,
                           "item", keepItem,
                           listBody(vm, ctx, g, col, page, pageCtx, strip, state, regionH, hint),
                           keepAtTop = true)
    c.drawMenus(state)
    return
  # Beside: the rows and the page are two regions, parted by a column of a
  # ground of its own (where the web draws the list's right border); the
  # page starts a row of its ground under the Previous / Next band, which
  # its head band would otherwise touch.
  discard c.drawScrolled(state, InboxListScrollKey, root, r, col, listW, regionH, g.panel,
                         "item", keepItem,
                         listBody(vm, ctx, g, col, nil, pageCtx, strip, state, regionH))
  c.area("page-gap", r, col + listW, 1, regionH, g.gap)
  let pageCol = col + listW + 1
  let pageW = width - listW - 1
  if hint:
    # No item on screen: the page's place holds the hint, in its middle.
    c.area("page", r, pageCol, pageW, regionH, g.panel)
    discard c.drawHint(root, r, pageCol, pageW, regionH)
    c.drawMenus(state)
    return
  c.area("page", r, pageCol, pageW, 1, g.panel)
  discard c.drawScrolled(state, InboxPageScrollKey, root, r + 1, pageCol, pageW, regionH - 1,
                         g.panel, "", "",
                         pageBody(page, pageCtx, strip, state, g, pageCol, regionH - 1))
  c.drawMenus(state)
