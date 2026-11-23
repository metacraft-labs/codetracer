## ctf_p3_tui_cover.nim — CTF-P3: the comparisons the terminal's CTF-P1b
## coverage test (`real_terminal/test_ctf_p1b_tui_views_cover_web_states.nim`)
## runs for the Changes panel, the Inbox and an inbox item's page: each
## drawing, read back through its `AhNode` facts and its cells, against the
## viewmodel the story built.
##
## A module of its own, beside the suites that call it, so the Changes and
## Inbox comparisons stay out of the lines other Agent Harbor work changes in
## the coverage test. It is not a suite (no `test_` prefix, so no lane runs
## it alone): the coverage test calls `checkChangesInbox` and
## `changesInboxStyleProblems` for every story of the three surfaces, and
## `test_ctf_p3_tui_changes_inbox_cover.nim` holds each comparison to a
## drawing that disagrees with its viewmodel.
##
## What is compared is GPUI's (`gpui/tests/ctf_p3_gpui_cover.nim`), over the
## terminal's facts, which carry GPUI's names:
##
##   * the Changes panel: the load state; the tabs (order, counts, the active
##     one, the full or the compact label by the panel's width); the
##     milestone selector and the tab shown; a tab's notice; every spec card
##     (key, tier, state word, open, and an open card's revert question,
##     Request Changes input, Summary or Diff side and last write's state);
##     every test (name and status); every milestone's details and key
##     files; every file of the Code tab (path, the VCS row's state letter and
##     name, origin, key-file mark, selection) and the selected file's diff
##     state; the roll-up;
##   * the Inbox: the load state; the counts; Previous and Next (enabled or
##     not) and the position, shown or not by the panel's width; auto-switch;
##     the degraded servers; every row in the server's order, the item on
##     screen and each row's explanation; the page under or beside the rows
##     and its explanation strip;
##   * an item's page: its load state, kind, banner, validation and answer
##     state, a login's state, Cancel, Continue and Open sign-in, the expired
##     badge, each choice, whether it is chosen and its control (the
##     checkbox for several, the composer's toggle for one), each queued
##     approval's command and purpose apart, the priority dropdown's value
##     whole, and its parts within the reading measure;
##   * the Inbox's hint in the page's place while items wait and none is on
##     screen;
##   * the Code tab's marks, each with its tooltip, and the legend that says
##     what the short marks stand for.
##
## And, the terminal's own:
##
##   * THE CODE TAB IS THE VCS PANE'S ROWS (broken copy B14). Each file row's cells
##     must be the spans the terminal VCS pane draws a review's changed file
##     with (`app/views/vcs_pane.reviewFileSpans`) for the VCS row value the
##     web and GPUI draw (`agent_harbor_changes_code.vcsFileRow`), glyph for
##     glyph, each span in the ink its role is given here; the name may be
##     cut in its middle to fit (`elidePath`) and nowhere else;
##   * every P3 fact that names a text against the cells under it: the whole
##     text, its end cut with "…", a path cut in its middle, or a wrapped
##     text's words in order;
##   * the inks and grounds the viewmodel decides: each state word's dot and
##     word in its role's colours, the active tab on its ground, the item on
##     screen on the selection with the action bar `▎`, an open card's and the
##     selected file's bar, Previous / Next in the body or the disabled ink.
##
## The panel-width rules are spelled here from the web stylesheets'
## container queries (30rem, 50rem, 60rem), not taken from the views'
## constants, so a comparison cannot agree with a view because it shares its
## rule (Verification-Harness-Traps §30).
##
## Trap 13 / §29: these are procs that return the mismatches they found;
## only test bodies `check`.

import std/strutils
from std/unicode import runes, `$`

import ../agent_harbor/ah_tui_stories
import ../app/views/vcs_pane

const
  ChangesCompactTabsMaxPx = 30 * 16
    ## `agent_harbor_changes.styl`: `@container ah-changes (max-width: 30rem)`.
  InboxCompactStepperMaxPx = 50 * 16
    ## `agent_harbor_inbox.styl`: `@container ah-inbox (max-width: 50rem)`.
  ItemReadingMaxCells = 48 * 16 div CellPx
    ## `AH_ITEM_READING_WIDTH`, 48rem: an item page's parts at most this wide.

  P3TextFacts* = [
    "state-text", "tab-label", "card-title", "card-path", "card-summary", "question",
    "action-status-text", "test-name", "annotation", "file-link", "code-summary",
    "file-position", "renamed-from", "vcs-file-status", "vcs-file-name", "select-value",
    "item-label", "kind-word", "explanation", "chip-text", "position", "auto-switch-text",
    "degraded", "server-name", "strip", "kind-words", "item-session", "prose", "last-reply",
    "draft-text", "context", "approval-subject", "approval-purpose", "choice-label",
    "login-provider", "item-hint", "code-legend", "mark-word",
    "login-state", "login-error", "validation", "phase-text", "no-options", "attachment",
    "executive-summary", "button", "description", "purpose", "group-name"]
    ## The P3 views' facts that name a text their node's cells draw.

type
  P3Cell* = object
    ## What a cell shows: its glyph and colours as `#rrggbb`.
    rune*, fg*, bg*: string
  P3Look* = proc(row, col: int): P3Cell {.closure.}

proc p3GridLook*(m: AhTuiMount): P3Look =
  ## The in-process drawing's cells.
  let g = m.canvas.grid
  result = proc(row, col: int): P3Cell =
    let s = g.styleAt(row, col)
    P3Cell(rune: g.runeAt(row, col), fg: s.fg, bg: s.bg)

proc nonEmpty(values: seq[string]): seq[string] =
  ## A fact's values less the empty ones (a header strip with no summary
  ## tags an empty one, which the web does not draw).
  for v in values:
    if v.len > 0: result.add v

proc expect(problems: var seq[string]; what: string; drawn, wanted: auto) =
  if drawn != wanted:
    problems.add what & ": drawn " & $drawn & ", the viewmodel says " & $wanted

proc shown(text: string): seq[string] =
  if text.len > 0: @[text] else: @[]

proc loadState(state: AsyncState): string =
  case state
  of asIdle, asLoading: "loading"
  of asError: "error"
  of asReady: "ready"

proc commonLoad(view: AhNode; state: AsyncState; error: string; problems: var seq[string]) =
  if state == asError:
    var drawn = false
    for e in view.all("error"):
      if error in e.attr("error"): drawn = true
    if not drawn: problems.add "the error the source reported (" & error & ") is not drawn"
  if state in {asIdle, asLoading}:
    problems.expect("loading notice", "loading" in view.values("notice"), true)

# ---------------------------------------------------------------------------
# Texts against their cells
# ---------------------------------------------------------------------------

proc cellsOf(m: AhTuiMount; n: AhNode): seq[string] =
  ## A node's rows of cells, each trimmed.
  for r in n.row ..< min(m.rows, n.row + max(1, n.height)):
    result.add m.canvas.grid.cellsText(r, n.col, n.width).strip

proc squeezed(s: string): string =
  for ch in s:
    if ch notin Whitespace: result.add ch

proc textMatches*(drawn, value: string; cells: int): bool =
  ## `drawn` (a node's cells, trimmed) shows `value`: whole, its end cut with
  ## "…", or (a path) cut in its middle to `cells` by the views' one rule.
  if drawn == value: return true
  if drawn.endsWith(Ellipsis):
    let kept = drawn[0 ..< drawn.len - Ellipsis.len]
    if value.startsWith(kept.strip(leading = false)): return true
  Ellipsis in drawn and elidePath(value, cells) == drawn

proc p3TextProblems*(m: AhTuiMount): seq[string] =
  ## Every P3 fact that names a text against the cells under it. A node
  ## below the screen's foot, or one the foot cuts through, is clipped as the
  ## web's list is: it is not read.
  for fact in P3TextFacts:
    for n in m.canvas.root.all(fact):
      let value = n.attr(fact)
      if value.len == 0 or n.row >= m.rows or n.row + max(1, n.height) > m.rows: continue
      if n.width == 0:
        result.add "a " & fact & " says '" & value & "' but draws no cell"
        continue
      let lines = m.cellsOf(n)
      if lines.len <= 1:
        if not textMatches(lines[0], value, n.width):
          result.add "a " & fact & " says '" & value & "' but draws '" & lines[0] & "'"
      elif lines.join(" ").squeezed != value.squeezed:
        result.add "a " & fact & " says '" & value & "' but draws '" & lines.join(" / ") & "'"

# ---------------------------------------------------------------------------
# The Code tab: the VCS pane's rows (B14)
# ---------------------------------------------------------------------------

proc vcsSpanInk*(p: AhPalette; ink: ChangesInboxInks; role: SemanticRole): string =
  ## The ink each VCS pane span is to be drawn in, written out here from the
  ## roles the web's VCS row gives its parts (`vcs.styl`): an addition's
  ## green, a deletion's red, a modification's amber, the path in the body.
  case role
  of srChromeSuccess: ink.vcsAdded
  of srChromeError: ink.vcsDeleted
  of srChromeNotification: ink.vcsModified
  of srChromeMuted: p.textCaption
  of srChromeTitle: p.textLabel
  else: p.textBody

proc vcsRowProblems*(m: AhTuiMount; look: P3Look): seq[string] =
  ## Each drawn file row of the Code tab against the VCS pane's spans for the
  ## same file: the same glyphs from the row's second cell (the first is the
  ## selection's bar), each in its span's ink.
  if m.changes.isNil: return
  let p = ahPalette(m.mode)
  let ink = changesInboxInks(m.mode)
  var rows: seq[FileRow]
  for f in m.changes.files: rows.add f
  for n in m.canvas.root.all("vcs-row"):
    if n.row >= m.rows: continue
    var found = false
    var row: FileRow
    for f in rows:
      if f.file.path == n.attr("file"):
        row = f
        found = true
    if not found:
      result.add "a file row " & n.attr("file") & " the viewmodel does not list"
      continue
    let vcs = vcsFileRow(row)
    let name = n.attr("vcs-name-shown")
    if name != vcs.baseName and elidePath(vcs.baseName, widthOf(name)) != name:
      result.add "the file " & vcs.baseName & " is named '" & name &
                 "', which is no middle cut of it"
      continue
    let spans = reviewFileSpans(VcsReviewLine(
      status: vcsStatusLabel(vcs.status), name: name, path: vcs.path,
      additions: vcs.additions, deletions: vcs.deletions, coverage: vcs.coverageText,
      selected: vcs.selected))
    var col = n.col + 1
    for s in spans:
      let want = p.vcsSpanInk(ink, s.style.role)
      for r in s.text.runes:
        let cell = look(n.row, col)
        if cell.rune != $r and not (cell.rune.len == 0 and $r == " "):
          result.add "the file row " & vcs.path & " draws '" & cell.rune & "' at column " &
                     $col & " where the VCS pane's row has '" & $r & "'"
          break
        if $r != " " and cell.fg != want:
          result.add "the file row " & vcs.path & "'s '" & s.text.strip & "' is in " & cell.fg &
                     ", the VCS pane's role gives " & want
          break
        col += 1
      if result.len > 0 and result[^1].startsWith("the file row " & vcs.path): break

# ---------------------------------------------------------------------------
# The Changes panel
# ---------------------------------------------------------------------------

proc checkSpecCards(view: AhNode; vm: ChangesVM): seq[string] =
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
  var focused, drawnFocus: seq[string]
  for c in cards:
    if c.focused: focused.add c.key
  for e in view.all("card"):
    if e.attr("focused") == "true": drawnFocus.add e.attr("card")
  result.expect("the keyboard's card", drawnFocus, focused)
  var groups: seq[string]
  for c in cards:
    if groups.len == 0 or groups[^1] != tierHead(c.tier): groups.add tierHead(c.tier)
  result.expect("tier groups", view.values("changes-group"), groups)
  for c in cards:
    for e in view.all("card"):
      if e.attr("card") != c.key: continue
      let word = e.first("state-word")
      result.expect("state word of " & c.key, (if word.isNil: "" else: word.attr("state-word")),
                    c.stateText)
      if not c.open: continue
      result.expect("revert question of " & c.key, e.values("confirm").len, ord(c.confirmingRevert))
      result.expect("Request Changes input of " & c.key, e.values("request-input").len,
                    ord(c.requestOpen))
      result.expect("side of " & c.key, e.values("side"),
                    @[if c.showsDiff: "diff" else: "summary"])
      let status = actionStatusText(c.action, c.actionReason, c.actionKind)
      result.expect("last write of " & c.key, e.values("action-status-text"), shown(status))

proc checkCode(view: AhNode; vm: ChangesVM): seq[string] =
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
  var focused, drawnFocus: seq[string]
  for row in vm.files:
    if row.focused: focused.add row.file.path
  for e in view.all("vcs-row"):
    if e.attr("focused") == "true": drawnFocus.add e.attr("file")
  result.expect("the keyboard's file", drawnFocus, focused)
  # The marks: short, each with its tooltip, and the legend saying what
  # they stand for.
  var marks: seq[string]
  for row in vm.files:
    marks.add originShort(row.file.origin)
    if row.key: marks.add KeyFileMark
    if row.file.binary: marks.add BinaryLabel
  result.expect("file marks", view.values("mark-word"), marks)
  for e in view.all("mark-word"):
    if e.attr("mark-title").len == 0:
      result.add "the mark " & e.attr("mark-word") & " has no tooltip"
  result.expect("marks legend", view.values("code-legend"),
                if vm.files.len > 0: @[CodeMarksLegend] else: @[])
  if diffs.len > 0:
    result.expect("file position", view.values("file-position"), shown(vm.selectedPosition))

proc checkChanges*(view: AhNode; vm: ChangesVM; context: AgentHarborChangesContext): seq[string] =
  ## The drawn Changes panel against `vm`; empty when they agree.
  result.expect("state", view.attr("state"), loadState(vm.state.val))
  commonLoad(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  result.expect("roll-up", view.values("summary").nonEmpty, shown(vm.rollUp(context.ended)))
  let compact = parseInt(view.attr("width-px")) <= ChangesCompactTabsMaxPx
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
    if e.attr("active") == "true": drawnActive = e.attr("changes-tab")
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

# ---------------------------------------------------------------------------
# An item's page
# ---------------------------------------------------------------------------

proc checkItemPage*(view: AhNode; page: InboxItemVM; ctx: AgentHarborInboxItemContext): seq[string] =
  ## The drawn page (under a panel's rows, or standing alone) against `page`.
  result.expect("page state", view.values("page-state"), @[loadState(page.state.val)])
  commonLoad(view, page.state.val, page.error.val, result)
  if page.state.val != asReady: return
  let d = page.detail
  result.expect("kind", view.values("item-kind"), @[$d.kind])
  let banner = page.banner
  result.expect("banner", view.values("banner"),
                if banner.len > 0 and d.kind in {ikBlockedQuestion, ikUnknown}: @[banner] else: @[])
  result.expect("validation", view.values("validation"), shown(page.validation.val))
  result.expect("answer state", view.values("phase-text"), shown(page.phaseText))
  result.expect("summary first", view.values("summary-first").len, ord(page.leadsWithSummary))
  result.expect("priority dropdown", view.values("priority-menu"), @[PriorityLabel])
  for w in view.values("reading-width"):
    if parseInt(w) > ItemReadingMaxCells:
      result.add "the page's parts run " & w & " cells wide, past the reading measure of " &
                 $ItemReadingMaxCells
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
    result.expect("expired badge", view.values("chip-text"), shown(page.expiredBadge(ctx.nowMs)))
  let options = if d.kind == ikAsyncFeedback: d.feedback.options else: d.options
  let drawn = view.values("choice")
  let asksChoices =
    (d.kind in {ikBlockedQuestion, ikUnknown} and d.form in {qfSingle, qfMulti} and
     page.optionsNotice.len == 0) or
    (d.kind == ikAsyncFeedback and d.feedback.feedbackType == ftOptions)
  if drawn.len > 0 or asksChoices:
    var ids, checked: seq[string]
    let chosen = page.choices.val
    for o in options:
      ids.add o.id
      checked.add $(o.id in chosen)
    result.expect("choices", drawn, ids)
    result.expect("chosen", view.values("checked"), checked)
    let single = d.kind != ikAsyncFeedback and d.form == qfSingle
    var controls: seq[string]
    for o in options: controls.add(if single: "toggle" else: "checkbox")
    result.expect("choice controls", view.values("control"), controls)

# ---------------------------------------------------------------------------
# The Inbox panel
# ---------------------------------------------------------------------------

proc checkInbox*(view: AhNode; vm: InboxVM; ctx: AgentHarborInboxContext): seq[string] =
  ## The drawn Inbox panel against `vm`; empty when they agree.
  result.expect("state", view.attr("state"), loadState(vm.state.val))
  commonLoad(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  result.expect("counts", view.values("summary").nonEmpty, shown(inboxCountsText(vm)))
  var steps, enabled: seq[string]
  for e in view.all("inbox-step"):
    steps.add e.attr("inbox-step")
    enabled.add e.attr("enabled")
  result.expect("Previous and Next", steps, @[stepperTitle(false), stepperTitle(true)])
  result.expect("Previous and Next enabled", enabled, @[$vm.canPrev, $vm.canNext])
  let compact = parseInt(view.attr("width-px")) <= InboxCompactStepperMaxPx
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
  if vm.notice().len > 0:
    result.expect("empty notice", "empty" in view.values("notice"), true)
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
  if not page.isNil:
    result.expect("explanation strip", view.values("strip"), shown(vm.explanationStrip))
    let drawnPage = view.first("page")
    if drawnPage != nil:
      let itemCtx = AgentHarborInboxItemContext(nowMs: ctx.nowMs, onOpenSignIn: ctx.onOpenSignIn,
                                                onContinue: proc() = discard)
      result.add checkItemPage(drawnPage, page, itemCtx)

proc checkChangesInbox*(m: AhTuiMount): seq[string] =
  ## The drawn story of a CTF-P3 surface against its viewmodel, and its
  ## texts against its cells.
  let view = m.view
  if view.isNil: return @["no node says which surface was drawn"]
  case m.surface
  of "agent-harbor-changes":
    result = checkChanges(view, m.changes, changesStoryContext(m.fixture))
  of "agent-harbor-inbox":
    result = checkInbox(view, m.inbox, inboxStoryContext(m.fixture, m.requests))
  of "agent-harbor-inbox-item":
    result = checkItemPage(view, m.inboxItem, inboxItemStoryContext(m.fixture, m.requests))
  else: return @["no CTF-P3 comparison for surface " & m.surface]
  result.add p3TextProblems(m)
  result.add vcsRowProblems(m, m.p3GridLook)

# ---------------------------------------------------------------------------
# Inks and grounds the viewmodel decides
# ---------------------------------------------------------------------------

proc changesInboxStyleProblems*(m: AhTuiMount; look: P3Look): seq[string] =
  ## The colours the viewmodel decides, read from `look` (the in-process
  ## drawing, or a real terminal's screen).
  let p = ahPalette(m.mode)
  let ink = changesInboxInks(m.mode)
  let view = m.view
  if view.isNil: return
  # Each state word: its dot in the role's mark colour, its word in the
  # role's ink (`agent_harbor_changes_inbox_palette`).
  for w in view.all("state-word"):
    if w.row >= m.rows: continue
    let role = w.attr("role")
    let dot = look(w.row, w.col)
    if dot.fg != p.roleDot(role).colour:
      result.add "the state word '" & w.attr("state-word") & "'s dot is " & dot.fg & ", its role " &
                 role & " gives " & p.roleDot(role).colour
    let word = look(w.row, w.col + 2)
    if word.fg != p.roleInk(ink, role):
      result.add "the state word '" & w.attr("state-word") & "' is in " & word.fg & ", its role " &
                 role & " gives " & p.roleInk(ink, role)
  # The active tab on the selection's ground, the others on the band's.
  for t in view.all("changes-tab"):
    if t.row >= m.rows: continue
    let bg = look(t.row, t.col).bg
    let want = if t.attr("active") == "true": blendOver(p.selectedTint, p.panel)
               else: (if m.mode == dmDark: tokenHexOf(dtColorsUiSurfaceBaseCanvas, m.mode)
                      else: tokenHexOf(dtColorsUiSurfaceBaseRaised, m.mode))
    if bg != want:
      result.add "the tab " & t.attr("changes-tab") & " (active " & t.attr("active") &
                 ") is on " & bg & ", not " & want
  # The item on screen: the selection's ground and the action bar; every
  # other row not on it.
  let selection = blendOver(p.selectedTint, p.panel)
  for row in view.all("item"):
    if row.row >= m.rows: continue
    let first = look(row.row, row.col)
    let onScreen = row.attr("current") == "true"
    if onScreen and (first.bg != selection or first.rune != BarGlyph or first.fg != p.borderAction):
      result.add "the item on screen " & row.attr("item") & " is not on the selection with the bar"
    if not onScreen and first.bg == selection:
      result.add "the item " & row.attr("item") & ", not on screen, is drawn as the selection"
  # An open card and the selected file carry the bar down their left edge.
  # The keyboard's card has its fold glyph in the action ink (any
  # other card's is the caption ink); the keyboard's file the bar at its
  # row's edge (the web's `.ah-card-focused`, `.ah-code-file-focused`).
  for c in view.all("card"):
    if c.row >= m.rows: continue
    let open = c.attr("open") == "true"
    let focused = c.attr("focused") == "true"
    let fold = look(c.row, c.col + 1)
    if focused and fold.fg != p.borderAction:
      result.add "the keyboard's card " & c.attr("card") & " has its fold glyph out of the action ink"
    if not focused and fold.fg == p.borderAction:
      result.add "the card " & c.attr("card") & ", not the keyboard's, has its fold glyph in the action ink"
    # An open card's bar runs down its edge.
    let lastRow = c.row + max(1, c.height) - 1
    let last = look(min(lastRow, m.rows - 1), c.col)
    if lastRow < m.rows and open != (last.rune == BarGlyph and last.fg == p.borderAction):
      result.add "the card " & c.attr("card") & " (open " & c.attr("open") & ") " &
                 (if open: "has no" else: "has an") & " inset bar"
  for f in view.all("vcs-row"):
    if f.row >= m.rows: continue
    let selected = f.attr("file-selected") == "true"
    let focused = f.attr("focused") == "true"
    let head = look(f.row, f.col)
    if focused and (head.rune != BarGlyph or head.fg != p.borderAction):
      result.add "the keyboard's file " & f.attr("file") & " has no bar at its row's edge"
    if not focused and not selected and head.rune == BarGlyph:
      result.add "the file " & f.attr("file") & ", neither the keyboard's nor selected, has a bar"
    let lastRow = f.row + max(1, f.height) - 1
    let last = look(min(lastRow, m.rows - 1), f.col)
    if lastRow < m.rows and lastRow > f.row and selected != (last.rune == BarGlyph):
      result.add "the file " & f.attr("file") & " (selected " & f.attr("file-selected") & ") " &
                 (if selected: "has no" else: "has an") & " inset bar"
  # Previous and Next: the body ink while they can be pressed, else the
  # disabled ink (`.ah-step`, `.ah-step:disabled`).
  for s in view.all("inbox-step"):
    if s.row >= m.rows: continue
    let arrow = look(s.row, s.col + 1)
    let want = if s.attr("enabled") == "true": p.textBody else: p.textDisabled
    if arrow.fg != want:
      result.add "the inbox step " & s.attr("inbox-step") & " (enabled " & s.attr("enabled") &
                 ") is in " & arrow.fg & ", not " & want
  result.add vcsRowProblems(m, look)
