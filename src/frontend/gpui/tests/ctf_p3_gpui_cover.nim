## ctf_p3_gpui_cover.nim — CTF-P3: the comparisons the CTF-P1b coverage test
## (`test_ctf_p1b_gpui_views_cover_web_states.nim`) runs for the Changes
## panel, the Inbox and an inbox item's page: each drawn GPUI tree, read back
## through its `data-ah-*` facts, against the viewmodel the story built,
## value by value.
##
## A module of its own, beside the suite that calls it, so the Changes and
## Inbox comparisons stay out of the lines other Agent Harbor work changes
## there. It is not a suite (no `test_` prefix, so no lane runs it alone):
## `test_ctf_p1b_gpui_views_cover_web_states.nim` calls `checkChangesInbox`
## for every story of the three surfaces, and
## `test_ctf_p3_gpui_changes_inbox_cover.nim` holds each comparison to a
## drawing that disagrees with its viewmodel.
##
## What is compared, by surface:
##
##   * the Changes panel: the load state; the tabs (their order, counts, the
##     active one, and the full or the compact label by the panel's width);
##     the milestone selector and the tab shown; a tab's notice; every spec
##     card (its key, tier, state word, whether it is open, and an open
##     card's revert question, Request Changes input, Summary or Diff side
##     and last write's state); every test (name and status); every
##     milestone's details and key files; every file of the Code tab (path,
##     the VCS row's status letter and name, origin, key-file mark,
##     selection) and the selected file's diff state; the roll-up;
##   * the Inbox: the load state; the counts; Previous and Next (enabled or
##     not, in which ink) and the position, shown or not by the panel's
##     width; auto-switch; the degraded servers; every row, in the server's
##     order, the item on screen and each row's explanation; the page under
##     the rows and its explanation strip;
##   * an item's page: its load state, kind, banner, validation and answer
##     state, a login's state, Cancel and Continue, the expired badge, each
##     choice, whether it is chosen and the control it is drawn with (the
##     design system's checkbox for several, the composer's toggle for one),
##     each queued approval's command or domain and its purpose apart, the
##     priority dropdown's value whole, and the column its parts keep to
##     (the reading measure);
##   * the Inbox's hint in the page's place while items wait and none is on
##     screen, and nothing on screen that the reader did not put there;
##   * the Code tab's marks, each with its tooltip, and the legend that says
##     what the short marks stand for;
##   * a scrolling region: what the keyboard is on (the keyboard's card or
##     file, the item on screen) lies in the window it shows.
##
## Every fact that names a text is also held to the text drawn under it
## (`p3DrawnTextProblems`), so a view that tags one word and draws another is
## a mismatch too.
##
## The panel-width rules the views follow are spelled here from the web
## stylesheet's container queries, not taken from the views' constants, so
## the comparison does not agree with a view because it shares its rule
## (Verification-Harness-Traps §30): 30rem for the Changes panel's compact
## tab labels, 50rem for the Inbox's compact Previous / Next group.
##
## Trap 13 / §29: these are procs that return the mismatches they found;
## only test bodies `check`.

import std/strutils

import isonim_gpui/renderer

import nim_agents_isonim_viewmodels/agent_harbor/[changes_vm, inbox_vm, inbox_item_vm]
import ../../viewmodel/views/agent_harbor_changes_inbox_words
import ../../viewmodel/views/agent_harbor_changes_code
import ../../viewmodel/views/agent_harbor_palette

const
  ChangesCompactTabsMaxPx = 30 * 16
    ## `agent_harbor_changes.styl`: `@container ah-changes (max-width: 30rem)`.
  InboxCompactStepperMaxPx = 50 * 16
    ## `agent_harbor_inbox.styl`: `@container ah-inbox (max-width: 50rem)`.
  InboxPageBesideMinPx = 60 * 16
    ## `agent_harbor_inbox.styl`: `@container ah-inbox (min-width: 60rem)`.
  InboxListBesidePx = 26 * 16
    ## `.ah-inbox-list`: `flex: 0 0 26rem` beside the page.
  ItemReadingMaxPx* = 48 * 16
    ## `AH_ITEM_READING_WIDTH`: an item page's parts at most 48rem wide.
  PageInsetPx = 2 * 8
    ## `.ah-item-page`: `PANEL_INSET` each side.

  P3DrawnTextFacts* = [
    "state-word", "tab-label", "card-title", "card-path", "card-summary", "question",
    "action-status-text", "test-name", "annotation", "file-link", "code-summary",
    "file-position", "renamed-from", "vcs-file-status", "vcs-file-name", "vcs-file-stats",
    "select-value", "item-label", "kind-word", "explanation", "chip-text", "age",
    "position", "auto-switch-text", "degraded", "server-name", "strip", "kind-words",
    "item-session", "banner", "prose", "last-reply", "draft-text", "context",
    "approval-summary", "choice-label", "login-provider", "login-state", "login-error",
    "validation", "phase-text", "no-options", "attachment", "executive-summary",
    "approval-subject", "approval-purpose", "item-hint", "code-legend", "mark-word"]
    ## The P3 views' facts that name a text the element draws.

# ---------------------------------------------------------------------------
# Reading the drawn tree
# ---------------------------------------------------------------------------

proc collect(node: GpuiElement; name: string; into: var seq[GpuiElement]) =
  if node.isNil: return
  if getAttribute(node, name).len > 0: into.add node
  for i in 0 ..< childCount(node): collect(nthChild(node, i), name, into)

proc all*(root: GpuiElement; attr: string): seq[GpuiElement] =
  ## Every element under `root` (itself included) carrying `data-ah-<attr>`,
  ## in document order.
  collect(root, "data-ah-" & attr, result)

proc values*(root: GpuiElement; attr: string): seq[string] =
  for e in root.all(attr): result.add getAttribute(e, "data-ah-" & attr)

proc fact*(e: GpuiElement; name: string): string = getAttribute(e, "data-ah-" & name)

proc firstOf*(root: GpuiElement; name: string): GpuiElement =
  let found = root.all(name)
  if found.len > 0: found[0] else: nil

proc drawn(e: GpuiElement): string =
  ## The text `e` draws: its text nodes' contents, in document order.
  if childCount(e) == 0: return textContent(e)
  for i in 0 ..< childCount(e): result.add drawn(nthChild(e, i))

proc p3DrawnTextProblems*(root: GpuiElement): seq[string] =
  ## Every P3 fact that names a text, against the text drawn under it.
  for name in P3DrawnTextFacts:
    for e in root.all(name):
      if e.drawn != e.fact(name):
        result.add "a " & name & " says '" & e.fact(name) & "' but draws '" & e.drawn & "'"

proc expect(problems: var seq[string]; what: string; drawn, wanted: auto) =
  if drawn != wanted:
    problems.add what & ": drawn " & $drawn & ", the viewmodel says " & $wanted

proc shown(text: string): seq[string] =
  ## What a fact reads back for `text`: an element whose fact is empty is
  ## not found (`all` keeps the non-empty ones), so "" reads as nothing.
  if text.len > 0: @[text] else: @[]

proc loadState(state: AsyncState): string =
  ## The load state a view's root reports, as the views' shared rule
  ## (`ah_theme.stateName`) names it.
  case state
  of asIdle, asLoading: "loading"
  of asError: "error"
  of asReady: "ready"

proc commonLoad(view: GpuiElement; state: AsyncState; error: string;
                problems: var seq[string]) =
  if state == asError:
    var shown = false
    for e in view.all("error"):
      if error in e.fact("error"): shown = true
    if not shown: problems.add "the error the source reported (" & error & ") is not drawn"
  if state in {asIdle, asLoading}:
    problems.expect("loading notice", view.values("notice").contains("loading"), true)

# ---------------------------------------------------------------------------
# The Changes panel
# ---------------------------------------------------------------------------

proc checkSpecCards(view: GpuiElement; vm: ChangesVM): seq[string] =
  let cards = vm.specCards
  var keys, tiers, states, opens: seq[string]
  for c in cards:
    keys.add c.key
    tiers.add $c.tier
    states.add c.stateText
    opens.add $c.open
  result.expect("spec cards", view.values("card"), keys)
  result.expect("card tiers", view.values("tier"), tiers)
  result.expect("card states", view.values("card-state"), states)
  result.expect("open cards", view.values("open"), opens)
  var groups: seq[string]
  for c in cards:
    if groups.len == 0 or groups[^1] != tierHead(c.tier): groups.add tierHead(c.tier)
  result.expect("tier groups", view.values("changes-group"), groups)
  for c in cards:
    for e in view.all("card"):
      if e.fact("card") != c.key: continue
      result.expect("state word of " & c.key, e.firstOf("state-word").fact("state-word"),
                    c.stateText)
      if not c.open: continue
      result.expect("revert question of " & c.key, e.values("confirm").len, ord(c.confirmingRevert))
      result.expect("Request Changes input of " & c.key, e.values("request-input").len,
                    ord(c.requestOpen))
      result.expect("side of " & c.key, e.values("side"),
                    @[if c.showsDiff: "diff" else: "summary"])
      let status = actionStatusText(c.action, c.actionReason, c.actionKind)
      result.expect("last write of " & c.key, e.values("action-status-text"), shown(status))

proc inWindow(view: GpuiElement; fact, value: string): string =
  ## "" when the part named `value` (the keyboard's card or file, the item
  ## on screen: `scroll-key`) lies in its scrolling region's window (its top
  ## shown, and all of it when it fits); else what is wrong, named by
  ## `fact`. A view drawn without a region (no height given) has nothing to
  ## check; a region that holds no such part either.
  let regions = view.all("scroll-region")
  if regions.len == 0 or value.len == 0: return ""
  for region in regions:
    for e in region.all("scroll-key"):
      if e.fact("scroll-key") != value: continue
      let top = parseInt(region.fact("scroll-top"))
      let viewPx = parseInt(region.fact("scroll-view"))
      let y = parseInt(getAttribute(e, "data-ah-scroll-y"))
      let h = parseInt(getAttribute(e, "data-ah-scroll-h"))
      if y < top or y + min(h, viewPx) > top + viewPx:
        return fact & " " & value & " lies at " & $y & "+" & $h & ", outside the window " &
               $top & "+" & $viewPx & " of region " & region.fact("scroll-region")
      return ""
  ""

proc checkCode(view: GpuiElement; vm: ChangesVM): seq[string] =
  result.expect("summary line", view.values("code-summary"), @[vm.summaryLine])
  let notice = vm.filesNotice
  if notice.len > 0:
    result.expect("filtered notice", view.values("notice"), @["filtered"])
    result.expect("files", view.values("file"), newSeq[string]())
    return
  var paths, letters, names, origins, keys, selected, diffs: seq[string]
  for row in vm.files:
    let vcs = vcsFileRow(row)
    paths.add row.file.path
    letters.add vcsStatusLabel(vcs.status)
    names.add vcs.baseName
    origins.add $row.file.origin
    keys.add $row.key
    selected.add $row.selected
    if row.selected: diffs.add $vm.fileDiff(row.file.path).state
  result.expect("files", view.values("file"), paths)
  result.expect("status letters", view.values("vcs-file-status"), letters)
  result.expect("file names", view.values("vcs-file-name"), names)
  result.expect("origins", view.values("file-origin"), origins)
  result.expect("key-file marks", view.values("key-file"), keys)
  result.expect("selected file", view.values("file-selected"), selected)
  result.expect("file diff", view.values("file-diff"), diffs)
  # The marks: short, each with its tooltip, and the legend saying what
  # they stand for.
  var marks: seq[string]
  for row in vm.files:
    marks.add originShort(row.file.origin)
    if row.key: marks.add KeyFileMark
    if row.file.binary: marks.add BinaryLabel
  result.expect("file marks", view.values("mark-word"), marks)
  for e in view.all("mark-word"):
    if e.fact("mark-title").len == 0:
      result.add "the mark " & e.fact("mark-word") & " has no tooltip"
  result.expect("marks legend", view.values("code-legend"),
                if vm.files.len > 0: @[CodeMarksLegend] else: @[])
  if diffs.len > 0:
    result.expect("file position", view.values("file-position"), shown(vm.selectedPosition))

proc checkChanges*(view: GpuiElement; vm: ChangesVM; widthPx: int;
                   context: AgentHarborChangesContext): seq[string] =
  ## The drawn Changes panel against `vm`; empty when they agree.
  result.expect("state", view.fact("state"), loadState(vm.state.val))
  commonLoad(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  result.expect("roll-up", view.values("summary"), shown(vm.rollUp(context.ended)))
  let compact = widthPx <= ChangesCompactTabsMaxPx
  var tabs, counts, labels: seq[string]
  var active = ""
  for t in vm.tabs:
    tabs.add $t.tab
    counts.add $t.count
    labels.add(if compact: t.compactLabel else: t.label)
    if t.active: active = $t.tab
  result.expect("tabs", view.values("changes-tab"), tabs)
  result.expect("tab counts", view.values("count"), counts)
  result.expect("tab labels", view.values("tab-label"), labels)
  var drawnActive = ""
  for e in view.all("changes-tab"):
    if e.fact("active") == "true": drawnActive = e.fact("changes-tab")
  result.expect("active tab", drawnActive, active)
  let tab = vm.activeTab.val
  result.expect("tab shown", view.values("tab-shown"), @[$tab])
  var chosen = ""
  for (id, label) in vm.milestoneChoices:
    if id == vm.milestone.val: chosen = label
  result.expect("milestone selector", view.values("milestone-select"),
                if vm.hasPlan and tab != rtCode: @[chosen] else: @[])
  let notice = vm.notice
  if notice.len > 0:
    result.expect("tab notice", view.values("notice"), @["empty"])
    return
  case tab
  of rtSpecChanges: result.add checkSpecCards(view, vm)
  of rtTests:
    var names, statuses, groups: seq[string]
    for g in vm.tests:
      groups.add g.milestoneId & ": " & g.title
      for e in g.entries:
        names.add e.testName
        statuses.add $e.status
    result.expect("test groups", view.values("test-group"), groups)
    result.expect("tests", view.values("test"), names)
    result.expect("test statuses", view.values("test-status"), statuses)
  of rtImplementation:
    var ids, files: seq[string]
    for d in vm.details:
      ids.add d.milestoneId
      for k in d.keySourceFiles: files.add k.path
    result.expect("details", view.values("details"), ids)
    result.expect("key source files", view.values("key-file"), files)
  of rtCode: result.add checkCode(view, vm)
  let kept = view.inWindow(if tab == rtCode: "file" else: "card", vm.focus.val)
  if kept.len > 0: result.add "the keyboard's item is out of view: " & kept

# ---------------------------------------------------------------------------
# An item's page
# ---------------------------------------------------------------------------

proc checkItemPage*(view: GpuiElement; page: InboxItemVM; ctx: AgentHarborInboxItemContext;
                    pageWidthPx = 0): seq[string] =
  ## The drawn page (its body, or the whole standalone view) against `page`;
  ## given the page's width, the column its parts keep to too.
  result.expect("page state", view.values("page-state"), @[loadState(page.state.val)])
  commonLoad(view, page.state.val, page.error.val, result)
  if page.state.val != asReady: return
  let d = page.detail
  result.expect("kind", view.values("item-kind"), @[$d.kind])
  let banner = page.banner
  result.expect("banner", view.values("banner"),
                if banner.len > 0 and d.kind in {ikBlockedQuestion, ikUnknown}: @[banner] else: @[])
  let problem = page.validation.val
  result.expect("validation", view.values("validation"), shown(problem))
  let phase = page.phaseText
  result.expect("answer state", view.values("phase-text"), shown(phase))
  result.expect("summary first", view.values("summary-first").len, ord(page.leadsWithSummary))
  result.expect("priority dropdown", view.values("priority-menu"), @[PriorityLabel])
  if pageWidthPx > 0:
    result.expect("reading column", view.values("reading-width"),
                  @[$min(pageWidthPx - PageInsetPx, ItemReadingMaxPx)])
  var subjects, purposes: seq[string]
  for a in d.approvals:
    subjects.add approvalSubject(a)
    if approvalPurposeText(a).len > 0: purposes.add approvalPurposeText(a)
  result.expect("approval commands", view.values("approval-subject"), subjects)
  result.expect("approval purposes", view.values("approval-purpose"), purposes)
  for subject in view.values("approval-subject"):
    if " in order to" in subject: result.add "an approval's command runs on into its purpose: " & subject
  let buttons = view.values("button")
  if d.kind == ikLoginRequest:
    result.expect("login", view.values("login"),
                  @[if page.hasLoginRequest: $page.loginState else: "none"])
    result.expect("login state", view.values("login-state"), shown(page.loginText))
    result.expect("Cancel", CancelLabel in buttons, page.canCancelLogin)
    result.expect("Continue", ContinueLabel in buttons,
                  page.canContinueLogin and ctx.onContinue != nil)
    result.expect("Open sign-in", OpenSignInLabel in buttons,
                  page.canCancelLogin and ctx.onOpenSignIn != nil)
  if d.kind == ikAsyncFeedback:
    let badge = page.expiredBadge(ctx.nowMs)
    result.expect("expired badge", view.values("chip-text"), shown(badge))
  let options = if d.kind == ikAsyncFeedback: d.feedback.options else: d.options
  let shown = view.values("choice")
  # The forms that draw choices: a question asked with options, and a
  # feedback request of the options type. Either compared whenever the
  # viewmodel says it has them, so a view that drops them is reported.
  let asksChoices =
    (d.kind in {ikBlockedQuestion, ikUnknown} and d.form in {qfSingle, qfMulti} and
     page.optionsNotice.len == 0) or
    (d.kind == ikAsyncFeedback and d.feedback.feedbackType == ftOptions)
  if shown.len > 0 or asksChoices:
    var ids, checked: seq[string]
    let chosen = page.choices.val
    for o in options:
      ids.add o.id
      checked.add $(o.id in chosen)
    result.expect("choices", shown, ids)
    result.expect("chosen", view.values("checked"), checked)
    let single = d.kind != ikAsyncFeedback and d.form == qfSingle
    var controls: seq[string]
    for o in options: controls.add(if single: "toggle" else: "checkbox")
    result.expect("choice controls", view.values("control"), controls)

# ---------------------------------------------------------------------------
# The Inbox panel
# ---------------------------------------------------------------------------

proc checkInbox*(view: GpuiElement; vm: InboxVM; widthPx: int;
                 ctx: AgentHarborInboxContext): seq[string] =
  ## The drawn Inbox panel against `vm`; empty when they agree.
  result.expect("state", view.fact("state"), loadState(vm.state.val))
  commonLoad(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  result.expect("counts", view.values("summary"), shown(inboxCountsText(vm)))
  var steps, enabled: seq[string]
  for e in view.all("inbox-step"):
    steps.add e.fact("inbox-step")
    enabled.add e.fact("enabled")
  result.expect("Previous and Next", steps, @[stepperTitle(false), stepperTitle(true)])
  result.expect("Previous and Next enabled", enabled, @[$vm.canPrev, $vm.canNext])
  let compact = widthPx <= InboxCompactStepperMaxPx
  result.expect("position", view.values("position"),
                if compact: @[] else: shown(vm.positionText))
  result.expect("auto-switch", view.values("inbox-auto-switch"),
                @[if vm.autoSwitch.val: "on" else: "off"])
  result.expect("auto-switch words", view.values("auto-switch-text"),
                @[autoSwitchText(vm.autoSwitch.val, compact)])
  var degraded: seq[string]
  if vm.cursorError.val.len > 0: degraded.add vm.cursorError.val
  for line in vm.degradedText: degraded.add line
  result.expect("degraded servers", view.values("degraded"), degraded)
  let notice = vm.notice()
  if notice.len > 0:
    result.expect("empty notice", view.values("notice"), @["empty"])
  var ids, current, explanations: seq[string]
  for item in vm.items:
    ids.add item.id
    current.add $(item.refOf == vm.current.val)
    if item.explanation.len > 0: explanations.add item.explanation
  result.expect("rows", view.values("item"), ids)
  result.expect("item on screen", view.values("current"), current)
  result.expect("explanations", view.values("explanation"), explanations)
  let page = vm.page
  result.expect("item page", view.values("page"), if page.isNil: @[] else: @["inbox"])
  result.expect("item hint", view.values("item-hint"),
                if vm.wantsItemHint: @[itemHintText()] else: @[])
  if vm.wantsItemHint and not vm.current.val.isNone:
    result.add "the hint is drawn while an item is on screen"
  let kept = view.inWindow("item", if page.isNil: "" else: vm.current.val.id)
  if kept.len > 0: result.add "the item on screen is out of view: " & kept
  if not page.isNil:
    let strip = vm.explanationStrip
    result.expect("explanation strip", view.values("strip"), shown(strip))
    let drawnPage = view.firstOf("page")
    if drawnPage != nil:
      var itemCtx = AgentHarborInboxItemContext(nowMs: ctx.nowMs, onOpenSignIn: ctx.onOpenSignIn,
                                                onContinue: proc() = discard)
      let pageW = if widthPx >= InboxPageBesideMinPx: widthPx - InboxListBesidePx else: widthPx
      result.add checkItemPage(drawnPage, page, itemCtx, pageW)

proc inboxInkProblems*(view: GpuiElement; p: AhPalette): seq[string] =
  ## Previous and Next in the body colour while they can be pressed, the
  ## disabled colour while not (`.ah-step`, `.ah-step:disabled`).
  for e in view.all("inbox-step"):
    let wanted = if e.fact("enabled") == "true": p.textBody else: p.textDisabled
    if e.fact("ink") != wanted:
      result.add "the inbox step " & e.fact("inbox-step") & " (enabled " & e.fact("enabled") &
                 ") is drawn in " & e.fact("ink") & ", not " & wanted
