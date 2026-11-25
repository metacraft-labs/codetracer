## The omnibox as the composer for agent instructions, over
## `OmniboxComposerVM` (nim-agents-isonim-viewmodels): the caption bar's
## omnibox field in agent mode (`/ai …`), and under it the composer's sheet.
##
## Built from the omnibox's own parts, so it reads as the omnibox extended,
## not a new panel: the field is the palette's `command-input-row`
## (`command-palette.styl`), and the sheet is the omnibox's results surface
## (`dropdown-surface()`), wider than the field and centred under it
## (`agent_harbor_composer.styl`). The sheet, top to bottom:
##
## - the header line: where the instruction is in its flow (`Enter sends it
##   · ↑↓ another destination`, `Routing…`, `Could not route: …`, `Sent`);
## - the whole instruction when it has more than one line (the field shows
##   its first line and `+N lines`);
## - `In view`: the context the window offers, one chip each, the cited ones
##   in the action role, an uncited one struck through, a note quiet; `+`
##   for the "add context" items, and the `Cites …` line;
## - the three destinations in their fixed order (this session, the manager
##   agent, a UI action): title, what it is, the router's mark and reason or
##   why it cannot be reached, its delivery and result, and its action
##   (`Stop agent`, `Send to …`, `Retry`);
## - the launch or new-initiative form under the manager row, when the
##   instruction is a launch or a new initiative;
## - the send line: the send button (`Send`, `Launch`, `Start initiative`)
##   and its hint, or the reason it cannot send;
## - with nothing typed, `Recent`: the last deliveries.
##
## Presses and keys are routed (Input-Routing-And-Keymaps.md §5.1, the
## `input-routing-gate`): the composer is the `composer` scope
## (`data-ct-pane`), and each element a press acts on carries its operation
## (`data-ct-operation`, `agent_harbor_composer_words`) and its target
## (`data-ah-target`). The page's one pointer listener resolves a press
## through the pointer keymap and the host runs it (`runComposerPress`); the
## keys reach the composer through the host's router
## (`runComposerOperation`). The view keeps one listener, the field's text
## input (the operator's typing, not a press), and none that decides what a
## press does. Every element also names its action (`data-ah-action`), so a
## check reads the facts off the drawing.
##
## One generic proc for every renderer, as the other Agent Harbor views.

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
# Its one-line texts (`data-ah-cut`) are cut in code, by the views' one rule
# for a cut (`ah_cut_text`, CTF-P1c D6), and its form fields' values in their
# middle by the one-line input rule (`CutInputValue`, P2c D35).
import ./ah_cut_text
from ../keymap/scope_path import ComposerScope
from ../input/element_press import OperationAttribute

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

  proc setInputValue(node: isonim_dom.Node; value: cstring) {.importjs: "#.value = #".}
  proc followMoreBelow(body: isonim_dom.Node) {.importjs: """
    (function (b) {
      // `data-ah-more` while the body holds more than it shows below: the
      // stylesheet's quiet "More below" line (a capture's browser hides
      // scrollbars, and a thin one is easy to miss). `data-ah-above` while
      // it is scrolled past its start: the matching "More above" line, its
      // hairline under the header, so what is above reads as above rather
      // than gone.
      if (b.__ahMore) return;
      var mark = function () {
        // Measured on the content alone: the line's own height is not more
        // content (counting it made the line keep itself shown at the end).
        var line = b.hasAttribute('data-ah-more') ?
          (parseFloat(getComputedStyle(b, '::after').height) || 0) : 0;
        var more = b.scrollHeight - line - b.scrollTop - b.clientHeight > 4;
        if (more) b.setAttribute('data-ah-more', ''); else b.removeAttribute('data-ah-more');
        // The "More above" line takes no room in the content (its negative
        // margin), so the scroll offset alone says whether it shows.
        if (b.scrollTop > 4) b.setAttribute('data-ah-above', ''); else b.removeAttribute('data-ah-above');
      };
      b.__ahMore = mark;
      b.addEventListener('scroll', mark);
      if (typeof ResizeObserver !== 'undefined') new ResizeObserver(mark).observe(b);
      var n = 0; var tick = function () { mark(); if (++n < 60) requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
    })(#)""".}
  proc scrollOpenScheduleIntoView(body: isonim_dom.Node) {.importjs: """
    (function (b) {
      // After layout, and again on every frame for a while: the view may
      // render before its host is in the page, and fonts and the "More
      // below" line still move the layout after the first frame. The open
      // schedule's end goes to the bottom of the scrollport, above the
      // "More below" line (the header above the body says where the form
      // goes, so its head may scroll away).
      var go = function () {
        var s = b.querySelector('.ah-composer-schedule-open');
        if (!(s && b.isConnected && b.clientHeight > 0)) return;
        var line = b.hasAttribute('data-ah-more') ?
          (parseFloat(getComputedStyle(b, '::after').height) || 0) : 0;
        var contentEnd = b.scrollHeight - line;
        var schedEnd = s.offsetTop + s.offsetHeight;
        // The schedule is the form's last part: only padding follows it, so
        // the content's own end is its end.
        var end = contentEnd - schedEnd < 40 ? contentEnd : schedEnd + 8;
        b.scrollTop = Math.max(0, end - b.clientHeight);
        if (b.__ahMore) b.__ahMore();
      };
      var tries = 0;
      var step = function () { go(); if (++tries < 45) requestAnimationFrame(step); };
      requestAnimationFrame(step);
    })(#)""".}
  proc inputValueOf(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc keepFieldEndInView(field: isonim_dom.Node) {.importjs: """
    (function (f) {
      // The field's end, where the caret is, stays in view (P2c D36): the
      // input scrolled to its end, never cut (D32). Again on the next
      // frames, as the field reaches the sheet's width only once laid out.
      var n = 0;
      var go = function () {
        f.scrollLeft = f.scrollWidth;
        if (++n < 30) requestAnimationFrame(go);
      };
      go();
    })(#)""".}

import ./agent_harbor_composer_words

export signals, computation, components, agent_harbor_composer_words

static:
  # The DSL spells the attributes literally; they are the ones the page's
  # listener and the host read.
  doAssert OperationAttribute == "data-ct-operation"
  doAssert ComposerTargetAttribute == "data-ah-target"

const
  AgentHarborComposerClass* = "ah-composer"

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc textNode[R](r: R; class, words: string): auto =
  ## A `div` holding a line of text.
  ui(r):
    tdiv(class = class):
      text words

proc textSpan[R](r: R; class, words: string): auto =
  ui(r):
    span(class = class):
      text words

proc chipClass(chip: ComposerChip): string =
  result = "ah-composer-chip ah-chip-" & $chip.item.kind
  if chip.item.note: result.add " ah-chip-note"
  elif chip.cited: result.add " ah-chip-cited"
  elif chip.item.excluded: result.add " ah-chip-excluded"

proc renderChip[R](r: R; chip: ComposerChip): auto =
  let state = if chip.item.note: "note" elif chip.cited: "cited"
              elif chip.item.excluded: "uncited" else: "offered"
  let title = chip.item.detail & (if chip.item.reference.len > 0:
                                    " (" & chip.item.reference & ")" else: "")
  ui(r):
    button(class = chipClass(chip), title = title, `data-ah-action` = "cite",
           `data-ct-operation` = ComposerCiteOperation,
           `data-ah-target` = chip.item.id, `data-ah-chip` = state):
      span(`data-ah-cut` = "line", class = "ah-composer-chip-text"):
        text chip.item.label

proc renderRow[R](r: R; vm: OmniboxComposerVM; row: DestinationRow): auto =
  ## One destination, a grid of named areas (agent_harbor_composer.styl):
  ## the title, what it is, the router's mark, its actions, then the reason
  ## and the delivery under the label. At sidebar width the areas re-flow:
  ## the mark beside the title, the label on a line of its own, the actions
  ## last, after the failure or result they answer.
  var actions: typeof(r.createElement("div"))
  let mark = stateWord(row)
  let markClass = if row.delivered: "delivery-" & $row.delivery else: $row.mark
  let delivery = deliveryText(row)
  # The bar marks the one destination Enter sends to; after sending, the
  # newest delivery's.
  let marked = vm.rowMarked(row)
  let classes = "ah-composer-row ah-composer-row-" & $row.target &
    (if marked: " ah-composer-row-selected" else: "") &
    (if not row.enabled and not row.delivered and row.reason.len > 0 and
        row.mark == rmNone and row.label.len == 0: " ah-composer-row-off" else: "") &
    (if row.mark != rmNone: " ah-composer-mark-" & $row.mark else: "")
  let unavailable = vm.rowUnavailable(row)
  # An unreachable destination says why in its label's place; once
  # delivered, a row says only what the delivery adds; a row selected
  # because the router failed says so (`agent_harbor_composer_words`).
  let label = vm.rowLabel(row)
  let reason = vm.rowReason(row)
  let node = ui(r):
    tdiv(class = classes & (if unavailable: " ah-composer-row-unavailable" else: ""),
         role = "option", `aria-selected` = (if marked: "true" else: "false"),
         `data-ah-target` = $row.target):
      span(class = "ah-composer-row-title"):
        text row.title
      span(`data-ah-cut` = "line", class = "ah-composer-row-label", title = label):
        text label
      span(class = "ah-composer-row-mark ah-composer-row-mark-" & markClass):
        text mark
      tdiv(ref = actions, class = "ah-composer-row-actions")
      if reason.len > 0:
        tdiv(class = "ah-composer-row-reason"):
          text reason
      if delivery.len > 0:
        tdiv(class = "ah-composer-row-delivery ah-role-" & deliveryRole(row)):
          text delivery
  if row.canStop:
    let stopping = vm.stopState.val
    let label = case stopping
                of ssStopping: "Stopping\xE2\x80\xA6"
                else: "Stop agent"
    let b = ui(r):
      button(class = "ah-composer-action ah-composer-stop", `data-ah-action` = "stop",
             `data-ct-operation` = ComposerStopOperation,
             `data-ah-target` = $row.target,
             title = "Stop the turn this session is running"):
        text label
    r.appendRendered(actions, b)
  if row.canSendAgain:
    let b = ui(r):
      button(class = "ah-composer-action", `data-ah-action` = "send-again",
             `data-ct-operation` = ComposerSendAgainOperation,
             `data-ah-target` = $row.target,
             title = "Send this instruction here as well; nothing is withdrawn"):
        text sendAgainLabel(row)
    r.appendRendered(actions, b)
  if row.delivered and row.delivery == dsFailed:
    let b = ui(r):
      button(class = "ah-composer-action", `data-ah-action` = "retry",
             `data-ct-operation` = ComposerRetryOperation,
             `data-ah-target` = $row.target):
        text "Retry"
    r.appendRendered(actions, b)
  node

proc renderField[R](r: R; label, value: string; problem = "";
                    wide = false; placeholder = ""): auto =
  ## One form field: its label over a value drawn as the app's input field.
  ## A value wider than the field is cut in its middle by the one-line input
  ## rule (`data-ah-cut="input"`, the P2c study's D35), as GPUI and the
  ## terminal cut it, so a goal keeps its end and a plan file its file name;
  ## the element keeps the whole value as its text (what a reader and the
  ## accessibility tree read) and in its tooltip. A placeholder is cut at
  ## its end like any line. The value is a read-only text box
  ## (`role="textbox"`, `aria-readonly`, labelled by its field): what
  ## assistive technology announces, and what StoryBook's render check
  ## counts as a control, so an empty field's placeholder is never read as
  ## an empty state (P2c study D72).
  let shown = if value.len > 0: value else: placeholder
  let cut = if value.len > 0: CutInputValue else: "line"
  ui(r):
    tdiv(class = "ah-composer-field" & (if wide: " ah-composer-field-wide" else: "") &
                 (if problem.len > 0: " ah-composer-field-problem" else: ""),
         `data-ah-field` = label):
      span(class = "ah-composer-field-label"):
        text label
      span(`data-ah-cut` = cut, title = shown, role = "textbox", `aria-readonly` = "true",
           `aria-label` = label,
           class = "ah-composer-field-value" & (if value.len == 0: " ah-composer-field-empty" else: "")):
        text shown
      if problem.len > 0:
        span(class = "ah-composer-field-problem-text"):
          text problem

proc renderChoice[R](r: R; label: string; options: openArray[string];
                     chosen: openArray[string]; problem = "";
                     several = false; locked = false): auto =
  ## A field whose value is chosen among a few options: a row of toggles,
  ## the chosen ones pressed (the VCS panel's mode toggles). `several`: any
  ## number may be chosen, and each chosen one carries a check mark.
  ## `locked`: the toggles are disabled (a launch waiting for its answer).
  mixin setAttribute
  var host: typeof(r.createElement("div"))
  let node = ui(r):
    tdiv(class = "ah-composer-field ah-composer-field-wide" &
                 (if problem.len > 0: " ah-composer-field-problem" else: ""),
         `data-ah-field` = label):
      span(class = "ah-composer-field-label"):
        text label
      tdiv(ref = host, class = "ah-composer-toggles" &
                               (if several: " ah-composer-toggles-several" else: ""),
           role = (if several: "group" else: "radiogroup"))
      if problem.len > 0:
        span(class = "ah-composer-field-problem-text"):
          text problem
  for each in options:
    let option = each
    let on = option in chosen
    let shown = if several and on: "\xE2\x9C\x93 " & option else: option
    let t = ui(r):
      button(class = "ah-composer-toggle" & (if on: " active" else: ""),
             `aria-pressed` = (if on: "true" else: "false"), `data-ah-action` = "choose-option"):
        text shown
    if locked: r.setAttribute(t, "disabled", "true")
    r.appendRendered(host, t)
  node

proc renderLaunchForm*[R, N](r: R; vm: OmniboxComposerVM; host: N; locked = false) =
  ## The launch form's fields into `host` (the composer's sheet, the control
  ## center's launch column). `locked`: its toggles disabled, while the
  ## control center's launch waits for its answer.
  let o = vm.launch
  let problems = vm.problems
  r.appendRendered(host, renderField(r, "Repository", o.repository,
    problemOf(problems, "repository"), placeholder = "Choose a repository"))
  r.appendRendered(host, renderField(r, "Branch", o.branch, placeholder = "default branch"))
  r.appendRendered(host, renderChoice(r, "Agents", vm.agentChoices, o.agents,
    problemOf(problems, "agents"), several = true, locked = locked))
  var runOn: seq[string]
  for v in RunOn: runOn.add $v
  r.appendRendered(host, renderChoice(r, "Runs on", runOn, [$o.runOn], locked = locked))
  if o.runOn == roExecutor:
    r.appendRendered(host, renderField(r, "Executor", o.executor,
      problemOf(problems, "executor"), placeholder = "Choose an executor"))
  r.appendRendered(host, renderField(r, "Session name", o.sessionName,
    placeholder = "named by the server"))
  var openIn: seq[string]
  for v in OpenIn: openIn.add $v
  r.appendRendered(host, renderChoice(r, "Opens in", openIn, [$o.openIn], locked = locked))
  let s = o.schedule
  let (scheduleSummary, scheduleHasProblem) = vm.scheduleSummary
  var sched: N
  let scheduleOpen = vm.scheduleOpen.val
  let fold = if scheduleOpen: "\xE2\x96\xBE" else: "\xE2\x96\xB8"
  let schedNode = ui(r):
    tdiv(class = "ah-composer-schedule" & (if scheduleOpen: " ah-composer-schedule-open" else: "")):
      tdiv(class = "ah-composer-schedule-head", `data-ah-action` = "schedule"):
        span(class = "ah-composer-fold"):
          text fold
        span(class = "ah-composer-field-label"):
          text "Schedule"
        span(`data-ah-cut` = "line", class = "ah-composer-schedule-summary" &
             (if scheduleHasProblem: " ah-composer-schedule-problem" else: "")):
          text scheduleSummary
      tdiv(ref = sched, class = "ah-composer-form-grid")
  if scheduleOpen:
    r.appendRendered(sched, renderField(r, "Cron", s.cron, problemOf(problems, "cron"),
      placeholder = "minute hour day month weekday"))
    r.appendRendered(sched, renderField(r, "Time zone", s.timezone,
      problemOf(problems, "timezone"), placeholder = "UTC"))
    r.appendRendered(sched, renderField(r, "Jitter", $s.jitterSeconds & " s",
      problemOf(problems, "jitter")))
    var conc: seq[string]
    for v in Concurrency: conc.add $v
    r.appendRendered(sched, renderChoice(r, "Concurrency", conc, [$s.concurrency], locked = locked))
    var mis: seq[string]
    for v in Misfire: mis.add $v
    r.appendRendered(sched, renderChoice(r, "Misfire", mis, [$s.misfire], locked = locked))
  r.appendRendered(host, schedNode)

proc renderInitiativeForm*[R, N](r: R; vm: OmniboxComposerVM; host: N; locked = false) =
  ## The new-initiative form's fields into `host`, as `renderLaunchForm`.
  let f = vm.initiative
  let problems = vm.problems
  r.appendRendered(host, renderField(r, "Goal", f.goal, problemOf(problems, "goal"),
    wide = true, placeholder = "What the initiative is for"))
  var modes: seq[string]
  for v in IterationMode: modes.add $v
  r.appendRendered(host, renderChoice(r, "Iterations", modes, [$f.iteration], locked = locked))
  if f.iteration == imCount:
    r.appendRendered(host, renderField(r, "Number of iterations", $f.iterations,
      problemOf(problems, "iterations")))
  r.appendRendered(host, renderField(r, "Plan file", vm.planPreview,
    problemOf(problems, "plan"), wide = true))
  r.appendRendered(host, renderField(r, "Related specs", f.relatedSpecs.join(", "),
    wide = true, placeholder = "none"))

proc renderAgentHarborComposer*[R, N](r: R; vm: OmniboxComposerVM): N =
  ## The field and the sheet; the sheet redrawn whenever the draft or a
  ## section of it changes.
  mixin clearChildren, setAttribute
  var field, more, sheet, footer, top: N
  let root = ui(r):
    tdiv(class = AgentHarborComposerClass & " command-view", `data-ct-pane` = ComposerScope):
      tdiv(class = "command-input-row ah-composer-input-row"):
        input(ref = field, class = "command-input-field ah-composer-input",
              `aria-label` = "Agent instruction", spellcheck = "false")
        span(ref = more, class = "ah-composer-more")
      tdiv(class = "ah-composer-sheet", role = "dialog",
           `aria-label` = "Where the instruction goes"):
        tdiv(ref = top, class = "ah-composer-top")
        tdiv(ref = sheet, class = "ah-composer-body")
        tdiv(ref = footer, class = "ah-composer-footer")
  when defined(js):
    when N is isonim_dom.Element:
      let target = vm
      isonim_dom.addEventListener(isonim_dom.Node(field), cstring"input",
        proc(ev: isonim_dom.Event) =
          var v = $inputValueOf(isonim_dom.Node(field))
          if v.startsWith(ComposerPrefix): v = v[ComposerPrefix.len .. ^1]
          elif v.startsWith(ComposerPrefix.strip): v = v[ComposerPrefix.strip.len .. ^1]
          target.setText(v))
  createRenderEffect proc() =
    let fieldText = vm.fieldText
    when defined(js):
      when N is isonim_dom.Element:
        setInputValue(isonim_dom.Node(field), cstring(ComposerPrefix & fieldText))
        keepFieldEndInView(isonim_dom.Node(field))
    r.setAttribute(field, "value", ComposerPrefix & fieldText)
    r.clearChildren(more)
    let moreText = vm.moreLines
    if moreText.len > 0:
      r.appendRendered(more, textSpan(r, "ah-composer-more-text", moreText))
  createRenderEffect proc() =
    discard vm.revision.val
    let optionsOpen = vm.optionsOpen.val
    discard vm.scheduleOpen.val
    let addOpen = vm.addContextOpen.val
    discard vm.stopState.val
    r.clearChildren(sheet)
    r.clearChildren(footer)
    r.clearChildren(top)
    r.setAttribute(sheet, "data-ah-phase", $vm.phase)
    r.setAttribute(sheet, "data-ah-route", $vm.route)
    let header = vm.headerText
    let headerRole = case vm.headerRole
                     of "error": " ah-role-error"
                     of "body": " ah-role-body"
                     else: ""
    # The header stays above the scrolling body.
    r.appendRendered(top, textNode(r, "ah-composer-header" & headerRole, header))
    let whole = vm.instructionBlock
    if whole.len > 0 and vm.phase == cpComposing:
      r.appendRendered(sheet, textNode(r, "ah-composer-instruction", whole))
    # What was sent, and where it went (no line while every delivery
    # failed: the header and the row say it, D37).
    let (sentText, sent) = vm.sentBlock
    if sentText.len > 0:
      var sentNode: N
      let sentHost = ui(r):
        tdiv(ref = sentNode, class = "ah-composer-sent"):
          span(class = "ah-composer-sent-text"):
            text sentText
      if sent.len > 0:
        r.appendRendered(sentNode, textSpan(r, "ah-composer-sent-line", sent))
      r.appendRendered(sheet, sentHost)
    if vm.isEmptyField:
      # Nothing typed: what was sent lately.
      let recent = vm.recent
      if recent.len > 0:
        var list: N
        let recentNode = ui(r):
          tdiv(class = "ah-composer-recent"):
            tdiv(class = "ah-composer-section-label"):
              text "Recent"
            tdiv(ref = list, class = "ah-composer-recent-list")
        r.appendRendered(sheet, recentNode)
        for i, rec in recent:
          let line = ui(r):
            tdiv(class = "ah-composer-recent-row" & (if rec.failed: " ah-composer-recent-failed" else: ""),
                 role = "option", `data-ah-action` = "recall", `data-ah-target` = $i,
                 `data-ct-operation` = ComposerRecallOperation):
              span(`data-ah-cut` = "line", class = "ah-composer-recent-text"):
                text rec.text
              span(`data-ah-cut` = "line", class = "ah-composer-recent-line"):
                text rec.line
          r.appendRendered(list, line)
      return
    # The context the window offers.
    var chipsHost, menuHost: N
    # What is cited is said only once the router has answered: never while
    # it decides, even if Enter already waits for it.
    let cites = vm.citesShown
    let contextNode = ui(r):
      tdiv(class = "ah-composer-context"):
        tdiv(ref = chipsHost, class = "ah-composer-chips"):
          span(class = "ah-composer-section-label"):
            text "In view"
        tdiv(ref = menuHost, class = "ah-composer-menu-host")
        if cites.len > 0:
          tdiv(`data-ah-cut` = "line", class = "ah-composer-cites"):
            text cites
    let chips = vm.chips
    if chips.len == 0:
      r.appendRendered(chipsHost, textSpan(r, "ah-composer-none", "nothing"))
    for chip in chips:
      r.appendRendered(chipsHost, renderChip(r, chip))
    if vm.phase == cpComposing:
      let add = ui(r):
        button(class = "ah-composer-chip ah-composer-add" & (if addOpen: " active" else: ""),
               title = "Add context", `data-ah-action` = "add-context",
               `data-ct-operation` = ComposerAddContextOperation):
          text "+"
      r.appendRendered(chipsHost, add)
    if addOpen:
      var menu: N
      let menuNode = ui(r):
        tdiv(ref = menu, class = "ah-composer-menu", role = "menu")
      r.appendRendered(menuHost, menuNode)
      for item in AddContextItems:
        let entry = ui(r):
          tdiv(class = "ah-composer-menu-item ct-menu-item", role = "menuitem",
               `data-ah-action` = "attach"):
            text item
        r.appendRendered(menu, entry)
    r.appendRendered(sheet, contextNode)
    # The destinations.
    var list: N
    let listNode = ui(r):
      tdiv(ref = list, class = "ah-composer-rows", role = "listbox",
           `aria-label` = "Destinations")
    r.appendRendered(sheet, listNode)
    for row in vm.rows:
      r.appendRendered(list, renderRow(r, vm, row))
    # The launch or initiative form: what the manager is sent with it.
    if vm.showsForm:
      var form: N
      let title = vm.formTitle
      let formNode = ui(r):
        tdiv(class = "ah-composer-form" & (if optionsOpen: "" else: " ah-composer-form-folded"),
             `data-ah-form` = $vm.intent):
          tdiv(class = "ah-composer-form-title"):
            text title
          tdiv(ref = form, class = "ah-composer-form-grid")
      r.appendRendered(sheet, formNode)
      if optionsOpen:
        if vm.intent == riLaunchTask: renderLaunchForm(r, vm, form)
        else: renderInitiativeForm(r, vm, form)
    let stopMessage = vm.stopMessage.val
    if stopMessage.len > 0:
      r.appendRendered(sheet, textNode(r, "ah-composer-stopped" &
        (if vm.stopState.val == ssFailed: " ah-role-error" else: ""), stopMessage))
    # The send line, in the footer, always in view: while composing, and
    # while the instruction waits to be sent.
    if vm.showsSendLine:
      let sending = vm.phase == cpSending
      let canSend = vm.canSend and not sending
      # The count is never cut: a part of its own after the cut hint.
      let (hint, moreText, blocked) = vm.sendHint
      let reason = if blocked: hint else: ""
      let label = vm.sendLabel
      var sendButton: N
      let sendLine = ui(r):
        tdiv(class = "ah-composer-send"):
          span(`data-ah-cut` = "line", class = "ah-composer-send-hint"):
            text hint
          span(class = "ah-composer-send-more"):
            text moreText
          button(ref = sendButton, class = "ah-composer-send-button",
                 `data-ah-action` = "send", `data-ct-operation` = ComposerSendOperation,
                 title = (if reason.len > 0: reason else: "Enter")):
            text label
      if not canSend: r.setAttribute(sendButton, "disabled", "true")
      if reason.len > 0:
        r.setAttribute(sendLine, "class", "ah-composer-send ah-composer-send-blocked")
      r.appendRendered(footer, sendLine)
  when defined(js):
    when N is isonim_dom.Element:
      # Opening a section of the form brings it into view: the sheet's body
      # scrolls, and the section just opened is what the operator wants.
      createRenderEffect proc() =
        discard vm.revision.val
        if vm.scheduleOpen.val:
          scrollOpenScheduleIntoView(isonim_dom.Node(sheet))
      followMoreBelow(isonim_dom.Node(sheet))
  root

when defined(js):
  proc mountAgentHarborComposer*(container: isonim_dom.Element; vm: OmniboxComposerVM) =
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborComposer[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
