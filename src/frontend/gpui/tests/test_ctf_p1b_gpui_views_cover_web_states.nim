## test_ctf_p1b_gpui_views_cover_web_states.nim — CTF-P1b: **every web story
## of CodeTracer as an Agent Harbor front-end has a GPUI rendering of the
## same viewmodel state.**
##
## The stories are not listed here. They are read from their one
## declaration, `stories/codetracer_stories.nim` (`codeTracerStorySections`),
## the list StoryBook's generated story files and the IsoNim Editor are both
## built from, and their StoryBook ids are computed by the generator's own
## `storybookId`. So a story added to the web is a story this suite renders
## on the day it is declared, and a story whose surface has no GPUI view
## fails here BY ITS STORYBOOK ID -- it is not skipped.
##
## For every story of the `CodeTracer/Agent Harbor` section, at each of the
## design brief's named sizes (laptop 1440×900, panel 760×640, sidebar
## 360×900) and in both colour modes:
##
##   * `mountAgentHarborStoryGpui` mounts it in a real isonim-gpui shadow
##     tree (the shim loaded in process; no window). It builds the viewmodel
##     with the SAME constructor the web mount uses (`agent_harbor_stories`),
##     so the GPUI view and the web view show one state;
##   * the drawn tree is then read back through its `data-ah-*` facts and
##     compared with that viewmodel, value by value: the load state; which
##     tabs a strip draws (one line: the viewmodel's `singleLine.visible`,
##     the `+N` chip its `overflow`; several lines: every tab), their order,
##     labels, attention and the active one; the list's groups, folded nodes
##     and rows; the initiative bar's tabs, recording buttons, popup,
##     sessions started elsewhere and inbox position; the initiatives' rows,
##     selection and session lines; the progress panel's milestones by
##     group; the fleet's filters, counts, rows, selection and unfolded
##     activity; and the error a failing source reported.
##
## A story whose surface is not drawn is a failure naming its id; a view that
## draws a different state (another tab active, a row missing, the overflow
## miscounted) is a failure naming the story, the size and the mode.
##
## No mocks: the viewmodels read the committed synthetic fixture set through
## the production data-source seam, and the renderer is isonim-gpui's own.
##
## Trap 13 / §29 (`Verification-Harness-Traps.md`): every helper that calls
## `check` is a template; the procs return the mismatches they found.

import std/[math, os, sequtils, sets, strutils, unittest]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../../stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories
import ../agent_harbor/ah_stories
import ../agent_harbor/ah_session_views
import ../agent_harbor/ah_fleet_panel
import ../agent_harbor/ah_composer
import ../agent_harbor/ah_session_activity
from ../agent_harbor/ah_theme import textWidth, textPx, CaptionPx, InsetPx, MarkPx
from ../chrome import contrastRatio
import nim_agents_isonim_viewmodels/agent_harbor/session_timeline_vm
from ../../viewmodel/views/agent_harbor_activity_words import runningLineId,
  runningStripText, showsUnseenChip
from ../../viewmodel/views/agent_harbor_palette import timelineInk
import ../../viewmodel/agent_harbor_activity_cards
import ../../viewmodel/viewmodels/agent_activity_feed
import nim_agents/agent_harbor/fleet_records
import nim_agents_isonim_viewmodels/agent_harbor/[fleet_vm, session_tabs_vm,
  initiative_tabs_vm, initiatives_vm, initiative_progress_vm, data_source, fixture_source]
from ../../viewmodel/views/agent_harbor_words import tabLabelOf, filterCount,
  activityLineIsError, countsFloor

const
  AgentHarborSectionTitle = "CodeTracer/Agent Harbor"
  Sizes = [("laptop", 1440, 900), ("panel", 760, 640), ("sidebar", 360, 900)]
  Modes = [dmDark, dmLight]
  MinimumStories = 59 + 21
    ## The section's stories at CTF-P2a's landing (9 fleet, 11 session tabs,
    ## 10 session list, 12 initiative tabs, 8 initiatives, 9 progress), and
    ## CTF-P2b's 21 of the session activity timeline. A floor, so a
    ## declaration that silently lost its stories cannot pass by rendering
    ## nothing.

var countedAssertions = 0
template ck(cond: untyped) =
  inc countedAssertions
  check cond

# ---------------------------------------------------------------------------
# Reading the drawn tree
# ---------------------------------------------------------------------------

proc collect(node: GpuiElement; name: string; into: var seq[GpuiElement]) =
  if node.isNil: return
  if getAttribute(node, name).len > 0: into.add node
  for i in 0 ..< childCount(node): collect(nthChild(node, i), name, into)

proc all(root: GpuiElement; attr: string): seq[GpuiElement] =
  ## Every element under `root` (itself included) carrying `data-ah-<attr>`,
  ## in document order.
  collect(root, "data-ah-" & attr, result)

proc values(root: GpuiElement; attr: string): seq[string] =
  for e in root.all(attr): result.add getAttribute(e, "data-ah-" & attr)

proc attr(e: GpuiElement; name: string): string = getAttribute(e, "data-ah-" & name)

proc first(root: GpuiElement; name: string): GpuiElement =
  let found = root.all(name)
  if found.len > 0: found[0] else: nil

const DrawnTextFacts = [
  "label", "title", "summary", "headline", "executive-summary", "status", "meta",
  "progress", "source", "counts", "detail", "age", "activity", "origin", "more",
  "inbox-position", "elsewhere-label", "frame-title", "caveat", "failure", "error",
  "button"]
  ## The `data-ah-*` facts that name a text the element draws. The checks
  ## below compare these facts with the viewmodel; `drawnTextProblems` holds
  ## every one of them to the text actually drawn under its element, so a
  ## view that tags one word and draws another is a mismatch too -- the facts
  ## are read off the drawing, not trusted beside it.

proc drawnText(e: GpuiElement): string =
  ## The text `e` draws: its text nodes' contents, in document order.
  if childCount(e) == 0: return textContent(e)
  for i in 0 ..< childCount(e): result.add drawnText(nthChild(e, i))

proc drawnTextProblems(root: GpuiElement): seq[string] =
  for fact in DrawnTextFacts:
    for e in root.all(fact):
      let drawn = e.drawnText
      if drawn != e.attr(fact):
        result.add "a " & fact & " says '" & e.attr(fact) & "' but draws '" & drawn & "'"

proc expect(problems: var seq[string]; what: string; drawn, wanted: auto) =
  if drawn != wanted:
    problems.add what & ": drawn " & $drawn & ", the viewmodel says " & $wanted

# ---------------------------------------------------------------------------
# Per surface: the drawn tree against the viewmodel
# ---------------------------------------------------------------------------

proc commonState(view: GpuiElement; state: AsyncState; error: string;
                 problems: var seq[string]) =
  if state == asError:
    var shown = false
    for e in view.all("error"):
      if error in e.attr("error"): shown = true
    if not shown: problems.add "the error the source reported (" & error & ") is not drawn"
  if state in {asIdle, asLoading}:
    problems.expect("loading notice", view.values("notice").contains("loading"), true)

proc severityOf(failed, waiting: bool): string =
  ## What a `+N` chip says of what it hides, by the brief's rule written out
  ## here: a failure over a wait over nothing.
  if failed: "failed" elif waiting: "needs-input" else: "none"

proc checkSessionTabs(view: GpuiElement; vm: SessionTabStripVM): seq[string] =
  result.expect("state", view.attr("state"), stateName(vm.state.val))
  commonState(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  let tabs = vm.tabs
  if tabs.len == 0:
    result.expect("empty notice", view.values("notice"), @["empty"])
    return
  var wanted: seq[string]
  var overflow: seq[int]
  if vm.mode.val == tsmMultiLine:
    for t in tabs: wanted.add t.id
  else:
    let layout = vm.singleLine
    for i in layout.visible: wanted.add tabs[i].id
    overflow = layout.overflow
  let drawn = view.all("tab")
  var ids, labels, attention, wantedLabels, wantedAttention: seq[string]
  var active = ""
  for e in drawn:
    ids.add e.attr("tab")
    labels.add e.first("label").attr("label")
    attention.add e.attr("attention")
    if e.attr("active") == "true": active = e.attr("tab")
  for id in wanted:
    for t in tabs:
      if t.id == id:
        wantedLabels.add tabLabelOf(t)
        wantedAttention.add $t.attention
  result.expect("tabs", ids, wanted)
  result.expect("tab labels", labels, wantedLabels)
  result.expect("tab attention", attention, wantedAttention)
  result.expect("active tab", active, vm.activeId.val)
  result.expect("+N chip", view.values("overflow"),
                if overflow.len > 0: @[$overflow.len] else: @[])
  var failed, waiting = false
  for i in overflow:
    failed = failed or tabs[i].attention == saFailed
    waiting = waiting or tabs[i].attention == saNeedsInput
  result.expect("+N chip's status", view.values("overflow-severity"),
                if overflow.len > 0: @[severityOf(failed, waiting)] else: @[])
  var menuItems: seq[string]
  let menu = view.first("menu")
  if menu != nil: menuItems = menu.values("menu-item")
  var wantedMenu: seq[string]
  if vm.overflowOpen.val:
    for i in overflow: wantedMenu.add tabs[i].id
  result.expect("overflow menu", menuItems, wantedMenu)

proc checkSessionList(view: GpuiElement; vm: SessionTabStripVM): seq[string] =
  result.expect("state", view.attr("state"), stateName(vm.state.val))
  result.expect("layout", view.attr("mode"), $vm.mode.val)
  let collapsed = vm.mode.val == tsmSidebar and vm.collapsed.val
  result.expect("collapsed", view.attr("collapsed"), $collapsed)
  commonState(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  if vm.tabs.len == 0:
    result.expect("empty notice", view.values("notice"), @["empty"])
    return
  let headers = vm.grouped.val and not collapsed
  var groups, folded, rows: seq[string]
  for g in vm.groups:
    if headers:
      groups.add g.planId
      folded.add $g.collapsed
    if not (g.collapsed and headers):
      for t in g.tabs: rows.add t.id
  var drawnFolded: seq[string]
  for e in view.all("folded"): drawnFolded.add e.attr("folded")
  # `data-ah-group` of the no-initiative node is "", which `all` skips: count
  # the headers by their fold fact instead, then compare the named ones.
  result.expect("tree nodes", drawnFolded, folded)
  var namedGroups: seq[string]
  for g in groups:
    if g.len > 0: namedGroups.add g
  result.expect("initiative nodes", view.values("group"), namedGroups)
  result.expect("rows", view.values("row"), rows)
  if not collapsed:
    result.expect("summary", view.values("summary"), @[vm.summaryText])
  for e in view.all("row"):
    if e.attr("active") == "true":
      result.expect("active row", e.attr("row"), vm.activeId.val)

proc checkInitiativeTabs(view: GpuiElement; vm: InitiativeTabStripVM): seq[string] =
  let tabs = vm.tabs
  let ready = vm.state.val == asReady
  result.expect("state", view.attr("state"),
                if ready and tabs.len == 0: "empty" else: stateName(vm.state.val))
  commonState(view, vm.state.val, vm.error.val, result)
  if not ready: return
  let layout = vm.singleLine
  var wanted: seq[string]
  for i in layout.visible:
    wanted.add(if tabs[i].kind == stkInitiative: initiativeKey(tabs[i].id)
               else: sessionKey(tabs[i].id))
  result.expect("tabs", view.values("tab"), wanted)
  var active = ""
  for e in view.all("tab"):
    if e.attr("active") == "true": active = e.attr("tab")
  result.expect("active tab", active, vm.activeTab.val)
  result.expect("+N chip", view.values("overflow"),
                if layout.overflow.len > 0: @[$layout.overflow.len] else: @[])
  var barFailed, barWaiting = false
  for i in layout.overflow:
    let t = tabs[i]
    if t.kind == stkInitiative:
      barFailed = barFailed or t.state == isBlocked
      barWaiting = barWaiting or t.state == isNeedsInput
    else:
      barFailed = barFailed or t.session.attention == saFailed
      barWaiting = barWaiting or t.session.attention == saNeedsInput
  result.expect("+N chip's status", view.values("overflow-severity"),
                if layout.overflow.len > 0: @[severityOf(barFailed, barWaiting)] else: @[])
  # The active initiative's recording switcher.
  var wantedNumbers: seq[string]
  var wantedHidden, wantedHiddenStatus: seq[string]
  for t in tabs:
    if t.active and t.kind == stkInitiative:
      let buttons = vm.recordingButtonsOf(t.id)
      for b in buttons.buttons: wantedNumbers.add $b.number
      if buttons.hidden > 0:
        wantedHidden.add $buttons.hidden
        # The hidden recordings are those whose numbers are not shown.
        var shown: seq[int]
        for b in buttons.buttons: shown.add b.number
        var failed, missing = false
        for e in vm.recordingButtonsOf(t.id, maxShown = high(int)).buttons:
          if e.number notin shown:
            failed = failed or e.state == rsFailed
            missing = missing or e.state == rsMissing
        wantedHiddenStatus.add severityOf(failed, missing)
  result.expect("recording buttons", view.values("recording"), wantedNumbers)
  result.expect("recordings behind +N", view.values("recordings-hidden"), wantedHidden)
  result.expect("recordings' +N status", view.values("recordings-hidden-severity"),
                wantedHiddenStatus)
  # The progress popup of the hovered initiative.
  let popupId = vm.popupId.val
  result.expect("popup", view.values("popup"), if popupId.len > 0: @[popupId] else: @[])
  if popupId.len > 0:
    let popup = vm.popupOf(popupId)
    let drawn = view.first("popup")
    if drawn != nil:
      result.expect("popup title", drawn.first("title").attr("title"), popup.title)
      result.expect("popup headline", drawn.values("headline"), @[popup.headline])
      var sessions: seq[string]
      for s in popup.sessions: sessions.add s.id
      result.expect("popup sessions", drawn.values("session"), sessions)
  # The sessions started elsewhere, and their menu.
  result.expect("elsewhere badge", view.values("elsewhere"),
                if vm.elsewhereCount > 0: @[$vm.elsewhereCount] else: @[])
  var elsewhereMenu: seq[string]
  for m in view.all("menu"):
    if m.attr("menu") == "elsewhere": elsewhereMenu = m.values("menu-item")
  var wantedElsewhere: seq[string]
  if vm.elsewhereOpen.val:
    for e in vm.elsewhere: wantedElsewhere.add e.item.id
  result.expect("elsewhere menu", elsewhereMenu, wantedElsewhere)
  # Previous / Next and auto-switch.
  let position = if vm.inboxPosition.len == 0: "inbox empty" else: vm.inboxPosition
  result.expect("inbox", view.values("inbox"), @[position])
  result.expect("auto-switch", view.values("auto-switch"), @[$vm.autoSwitch.val])

proc checkInitiatives(view: GpuiElement; vm: InitiativesVM): seq[string] =
  result.expect("state", view.attr("state"), stateName(vm.state.val))
  commonState(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  let rows = vm.rows
  if rows.len == 0:
    result.expect("empty notice", view.values("notice"), @["empty"])
    return
  var ids, selected, folded: seq[string]
  for row in rows:
    ids.add row.id
    selected.add $row.selected
    folded.add $row.folded
  result.expect("initiatives", view.values("initiative"), ids)
  result.expect("selection", view.values("selected"), selected)
  result.expect("folded", view.values("folded"), folded)
  result.expect("summary", view.values("summary"), @[vm.summaryText])
  for row in rows:
    for e in view.all("initiative"):
      if e.attr("initiative") == row.id:
        var wantedSessions: seq[string]
        if not row.folded:
          let shown = if row.expanded: row.sessions.len
                      else: min(row.sessions.len, 4)
          for i in 0 ..< shown: wantedSessions.add row.sessions[i].id
        result.expect("sessions of " & row.id, e.values("session"), wantedSessions)
        result.expect("progress of " & row.id, e.values("progress"), @[row.progressText])

proc checkProgress(view: GpuiElement; vm: InitiativeProgressVM): seq[string] =
  let found = vm.state.val == asReady and vm.found
  result.expect("state", view.attr("state"),
                if vm.state.val == asReady and not vm.found: "empty"
                else: stateName(vm.state.val))
  commonState(view, vm.state.val, vm.error.val, result)
  if not found: return
  var groups, milestones, current: seq[string]
  for g in vm.groups:
    groups.add g.name
    for m in g.milestones:
      milestones.add m.id
      current.add $m.current
  result.expect("status groups", view.values("group"), groups)
  result.expect("milestones", view.values("milestone"), milestones)
  var drawnCurrent: seq[string]
  for e in view.all("milestone"): drawnCurrent.add e.attr("current")
  result.expect("current milestone", drawnCurrent, current)
  result.expect("headline", view.values("summary"), @[vm.headline])
  let summary = vm.current.executiveSummary
  result.expect("executive summary", view.values("executive-summary"),
                @[if summary.len > 0: summary else: "The plan states no executive summary."])

proc fleetInkProblems(view: GpuiElement; vm: FleetSnapshotVM; p: AhPalette): seq[string] =
  ## The inks the shared rules decide (the views tag each as `ink`, the
  ## colour they hand the text): an activity line red only on a row with no
  ## failure line (`activityLineIsError`), else the caption role, the
  ## selection's text on the selected row; the active filter's count in the
  ## body role even at 0, another 0 in the disabled role.
  for row in vm.rows:
    for e in view.all("row"):
      if e.attr("row") != row.id: continue
      for i, a in e.all("activity"):
        let wanted = if row.selected: p.selectedText
                     elif activityLineIsError(row, i): p.textError else: p.rowDetail
        if a.attr("ink") != wanted:
          result.add "activity line " & $i & " of " & row.shortId &
                     (if row.failureText.len > 0: " (under a failure line)" else: "") &
                     " is drawn in " & a.attr("ink") & ", not " & wanted
  for e in view.all("filter"):
    let n = parseInt(e.attr("filter-count"))
    let wanted = if e.attr("active") == "true": p.textBody
                 elif n == 0: p.textDisabled else: p.textCaption
    let count = e.first("ink")
    if count.isNil or count.attr("ink") != wanted:
      result.add "the count of filter " & e.attr("filter") & " is drawn in " &
                 (if count.isNil: "nothing" else: count.attr("ink")) & ", not " & wanted

proc checkFleet(view: GpuiElement; vm: FleetSnapshotVM): seq[string] =
  result.expect("state", view.attr("state"), stateName(vm.state.val))
  commonState(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  let counts = vm.counts
  var filters, filterCounts: seq[string]
  for f in FleetFilter:
    filters.add $f
    filterCounts.add $counts.filterCount(f)
  result.expect("filters", view.values("filter"), filters)
  result.expect("filter counts", view.values("filter-count"), filterCounts)
  for e in view.all("filter"):
    if e.attr("active") == "true":
      result.expect("active filter", e.attr("filter"), $vm.filter.val)
  let rows = vm.rows
  if rows.len == 0:
    result.expect("empty notice", view.values("notice"), @["empty"])
    return
  var ids, selected, expanded: seq[string]
  for row in rows:
    ids.add row.id
    selected.add $row.selected
    expanded.add $row.expanded
  result.expect("rows", view.values("row"), ids)
  result.expect("selection", view.values("selected"), selected)
  result.expect("unfolded", view.values("expanded"), expanded)
  for row in rows:
    for e in view.all("row"):
      if e.attr("row") == row.id:
        let shown = if row.expanded: row.activity.len else: min(1, row.activity.len)
        result.expect("activity of " & row.shortId, e.values("activity"), row.activity[0 ..< shown])
        result.expect("title of " & row.shortId, e.first("title").attr("title"), row.title)

const
  TextMinContrast = 4.5
    ## A line's words in the body, label, monospace and ended roles against
    ## the panel's ground (WCAG 2.2 SC 1.4.3,
    ## https://www.w3.org/TR/WCAG22/#contrast-minimum).
  StatusMinContrast = 3.0
    ## A status role's text (quiet, error, removed, warning, added, running):
    ## the design system's status colours, whose Light steps reach 3:1 and
    ## not 4.5:1 on the panel (WCAG 2.2 SC 1.4.11's floor for what tells a
    ## state apart, https://www.w3.org/TR/WCAG22/#non-text-contrast).
  TimelineFacts = ["line-kind", "level", "indent", "text", "role", "item-kind", "state",
                   "expanded", "focused", "count", "failed", "running", "path", "copy"]
    ## The facts a drawn timeline line carries (`lineFacts`), each compared
    ## with the viewmodel's line of the same id.

proc factsOf(line: TimelineLine): seq[(string, string)] =
  ## The viewmodel's line as the facts it should be drawn with, by the rule
  ## written out here rather than through `lineFacts`, so the check does not
  ## share the views' function.
  result = @[("line-kind", $line.kind), ("level", $line.level), ("indent", $line.indent),
             ("text", line.text), ("role", line.textRole)]
  if line.itemKind.len > 0: result.add ("item-kind", line.itemKind)
  if line.state != tisNone: result.add ("state", $line.state)
  if line.expandable: result.add ("expanded", $line.expanded)
  if line.focused: result.add ("focused", "true")
  if line.kind == tlkGroup:
    result.add ("count", $line.count)
    result.add ("failed", $line.failed)
    result.add ("running", $line.running)
  if line.path.len > 0: result.add ("path", line.path)
  if line.copyText.len > 0: result.add ("copy", line.copyText)

proc checkTimeline(view: GpuiElement; vm: SessionTimelineVM): seq[string] =
  ## The timeline's drawn lines against the viewmodel's: a run of its lines
  ## with no gap (the window the view shows), each with the viewmodel's
  ## facts; a group holding a running command names it on its line (never
  ## hidden); the chrome (status, connection badge, filter, the unseen chip,
  ## the running strip) as the viewmodel says.
  result.expect("load state", view.attr("state"),
                (case vm.state.val
                 of asIdle, asLoading: "loading"
                 of asError: "error"
                 of asReady: "ready"))
  result.expect("status", view.attr("session-status"), vm.statusLabel)
  result.expect("connection", view.attr("connection"), vm.connection.val)
  if vm.connection.val.len > 0:
    result.expect("badge", view.values("badge"), @[vm.connection.val])
  result.expect("filter", view.values("filter"),
                if vm.filter.val.len > 0: @[vm.filter.val] else: @[])
  case vm.state.val
  of asIdle, asLoading:
    result.expect("loading notice", view.values("notice"), @["loading"])
    return
  of asError:
    if vm.unresolvable.val.len > 0:
      result.expect("cannot-be-loaded notice", view.values("notice"), @["unresolvable"])
    else:
      commonState(view, vm.state.val, vm.error.val, result)
    return
  of asReady: discard
  if vm.isEmpty:
    result.expect("empty notice", view.values("notice"), @["empty"])
    return
  let lines = vm.lines
  let drawn = view.all("line")
  if drawn.len == 0:
    result.add "no line is drawn of the " & $lines.len & " the viewmodel has"
    return
  var start = -1
  for i, line in lines:
    if line.id == drawn[0].attr("line"): start = i
  if start < 0:
    result.add "the first drawn line " & drawn[0].attr("line") & " is not the viewmodel's"
    return
  for k, e in drawn:
    if start + k >= lines.len:
      result.add "a line drawn past the viewmodel's last: " & e.attr("line")
      break
    let line = lines[start + k]
    if e.attr("line") != line.id:
      result.add "drawn line " & $k & " is " & e.attr("line") & ", the viewmodel's is " & line.id
      continue
    let wanted = factsOf(line)
    for fact in TimelineFacts:
      var want = ""
      for (k2, v) in wanted:
        if k2 == fact: want = v
      if e.attr(fact) != want:
        result.add line.id & "'s " & fact & ": drawn '" & e.attr(fact) &
                   "', the viewmodel says '" & want & "'"
    if line.kind == tlkGroup and line.running > 0:
      var named = false
      for part in e.all("part"):
        if part.attr("part") == "running" and part.drawnText.len > 0: named = true
      if not named: result.add "the group " & line.id & " holds a running command it does not name"
  # The chrome.
  let ids = drawn.mapIt(it.attr("line"))
  let runningId = runningLineId(lines, vm.runningLine)
  let strip = runningStripText(vm)
  let wantStrip = if strip.len > 0 and runningId notin ids: @[strip] else: @[]
  result.expect("running strip", view.values("running-strip"), wantStrip)
  result.expect("unseen chip", view.values("unseen"),
                if showsUnseenChip(vm): @[$vm.unseen.val] else: @[])

proc minContrastOf(role: string): float =
  if role in ["quiet", "error", "removed", "warning", "added", "running"]: StatusMinContrast
  else: TextMinContrast

proc timelineInkProblems(view: GpuiElement; p: AhPalette): seq[string] =
  ## Every drawn part of a line in its role's colour (`timelineInk`, the
  ## roles `agent_harbor_activity.styl` names), and every text at least
  ## its role's floor (`minContrastOf`) against the panel's ground in both
  ## modes.
  for e in view.all("part"):
    let role = e.attr("part")
    if e.attr("ink") != timelineInk(p, role):
      result.add "a " & role & " part is drawn in " & e.attr("ink") & ", not " &
                 timelineInk(p, role)
    elif contrastRatio(e.attr("ink"), p.panel) < minContrastOf(role):
      result.add "a " & role & " part (" & e.attr("ink") & ") is " &
                 formatFloat(contrastRatio(e.attr("ink"), p.panel), ffDecimal, 2) &
                 ":1 on the panel " & p.panel & ", under " & $minContrastOf(role) & ":1"

proc inkProblems(m: AhStoryMount; mode: DesignMode): seq[string] =
  ## The colours the shared rules decide, by surface: the fleet's
  ## (`fleetInkProblems`), and the inbox's Previous / Next in the disabled
  ## role while nothing waits.
  let p = ahPalette(mode)
  case m.surface
  of "agent-harbor-fleet":
    if m.fleet.state.val == asReady: result = fleetInkProblems(m.view, m.fleet, p)
  of "agent-harbor-session-activity":
    result = timelineInkProblems(m.view, p)
  of "agent-harbor-initiative-tabs":
    # Previous / Next: the disabled role while nothing waits, the label role
    # while something does (what the browser computes). Each step is drawn
    # at full opacity: the colour alone says whether it can be pressed.
    let empty = m.initiativeTabs.inboxPosition.len == 0
    let wanted = if empty: p.textDisabled else: p.textLabel
    for e in m.view.all("step"):
      if e.attr("step") != (if empty: "disabled" else: "enabled"):
        result.add "the inbox step " & e.attr("button") & " is marked " & e.attr("step") &
                   " while the inbox is " & (if empty: "empty" else: "not empty")
      if e.attr("ink") != wanted:
        result.add "the inbox step " & e.attr("button") & " (" & e.attr("step") &
                   ") is drawn in " & e.attr("ink") & ", not " & wanted
      # The pointer over it: the hand only where it can be pressed, the
      # default arrow where it cannot (the browser's pointer stamp gives a
      # step in an empty inbox no hit kind). Spelled as the CSS names, not
      # through `cursorOf`, so the check does not share the view's rule.
      let cursor = if empty: "default" else: "pointer"
      if e.attr("cursor") != cursor:
        result.add "the inbox step " & e.attr("button") & " (" & e.attr("step") &
                   ") shows the " & e.attr("cursor") & " cursor, not " & cursor
    # Auto-switch on: its dot in the action border role in both modes
    # (`.ah-inbox-auto-on::before`: `colors-ui-border-action`).
    for e in m.view.all("auto-switch"):
      if e.attr("auto-switch") != "true": continue
      let dot = e.first("mark")
      if dot.isNil or dot.attr("mark") != p.borderAction:
        result.add "the auto-switch dot is " &
                   (if dot.isNil: "not drawn" else: "drawn in " & dot.attr("mark")) &
                   ", not in the action border colour " & p.borderAction
  else: discard

proc checkComposer(view: GpuiElement; vm: OmniboxComposerVM): seq[string] =
  ## The composer's drawn tree against its viewmodel (CTF-P2c): the phase
  ## and the route, the field, the header, the chips and their states, the
  ## destinations in their fixed order with the marked row, each state
  ## word, label and reason, the actions each offers, `Recent`, the form,
  ## and the send line. A body scrolled past a row (the sheet says how many
  ## sections it hid) may leave it out; the rows drawn keep their order.
  result.expect("phase", view.attr("phase"), $vm.phase)
  result.expect("route", view.attr("route"), $vm.route)
  result.expect("field", view.values("field"), @[ComposerPrefix & vm.fieldText])
  result.expect("header", view.values("header"), @[vm.headerText])
  if vm.isEmptyField:
    var recent: seq[string]
    for rec in vm.recent: recent.add rec.text
    result.expect("recent", view.values("recent-text"), recent)
    result.expect("destinations", view.values("dest").len, 0)
    # Nothing typed: no send line (the web draws none).
    result.expect("send", view.values("send").len, 0)
    return
  # A body that holds more than the sheet shows is scrolled (the web's
  # scrollport): the sections it scrolled past are not drawn, and the sheet
  # says how many it hid. Only then may a section be missing; what is
  # drawn is compared.
  let sheet = view.first("sheet")
  let scrolled = not sheet.isNil and
                 (sheet.attr("hidden-above") != "0" or sheet.attr("hidden-below") != "0")
  let drawnDests = view.values("dest")
  template section(what: string; drawn, wanted: untyped) =
    if not (scrolled and drawn.len == 0): result.expect(what, drawn, wanted)
  var chips, states: seq[string]
  for ch in vm.chips:
    chips.add ch.item.id
    states.add chipState(ch)
  section("chips", view.values("chip"), chips)
  section("chip states", view.values("chip-state"), states)
  let cites = vm.citesShown
  section("cites", view.values("cites"), if cites.len > 0: @[cites] else: @[])
  var dests, marked: seq[string]
  for row in vm.rows:
    if scrolled and $row.target notin drawnDests: continue
    dests.add $row.target
    marked.add $vm.rowMarked(row)
  result.expect("destinations", drawnDests, dests)
  result.expect("marked rows", view.values("marked"), marked)
  for row in vm.rows:
    for e in view.all("dest"):
      if e.attr("dest") != $row.target: continue
      result.expect("label of " & $row.target, e.values("label"), @[vm.rowLabel(row)])
      let word = stateWord(row)
      result.expect("state of " & $row.target, e.values("state"),
                    if word.len > 0: @[word] else: @[])
      let reason = vm.rowReason(row)
      result.expect("reason of " & $row.target, e.values("detail"),
                    if reason.len > 0: @[reason] else: @[])
      var actions: seq[string]
      if row.canStop: actions.add "stop"
      if row.canSendAgain: actions.add "send-again"
      if row.delivered and row.delivery == dsFailed: actions.add "retry"
      result.expect("actions of " & $row.target, e.values("action"), actions)
  section("form", view.values("form"), if vm.showsForm: @[$vm.intent] else: @[])
  if vm.showsSendLine and not vm.isEmptyField:
    result.expect("send", view.values("send"), @[vm.sendLabel])
    result.expect("send enabled", view.values("send-enabled"),
                  @[$(vm.canSend and vm.phase != cpSending)])
  else:
    result.expect("send", view.values("send").len, 0)

proc checkStory(m: AhStoryMount): seq[string] =
  ## The drawn tree against the viewmodel the story built; empty when they
  ## agree.
  let view = m.view
  if view.attr("surface") != m.surface:
    return @["the view's root says surface '" & view.attr("surface") & "'"]
  case m.surface
  of "agent-harbor-session-tabs": checkSessionTabs(view, m.sessions)
  of "agent-harbor-session-list": checkSessionList(view, m.sessions)
  of "agent-harbor-initiative-tabs": checkInitiativeTabs(view, m.initiativeTabs)
  of "agent-harbor-initiatives": checkInitiatives(view, m.initiatives)
  of "agent-harbor-initiative-progress": checkProgress(view, m.progress)
  of "agent-harbor-fleet": checkFleet(view, m.fleet)
  of "agent-harbor-composer": checkComposer(view, m.composer)
  of "agent-harbor-session-activity":
    if m.cardsFeed.isNil: checkTimeline(view, m.timeline)
    else:
      # The comparison story: the timeline half, and the cards half drawn
      # from the cards' viewmodel over the same events.
      var problems = checkTimeline(view, m.timeline)
      let painted = getAttribute(m.cardsFeed, "data-ct-agent")
      if painted != $m.cards.cards.agentFeed().len:
        problems.add "the cards half draws " & painted & " rows, the cards' feed has " &
                     $m.cards.cards.agentFeed().len
      problems & m.cards.againstCardsProblems(m.timeline, m.cards.timelineSource)
  else: @["this suite has no comparison for surface " & m.surface]

# ---------------------------------------------------------------------------
# The suites
# ---------------------------------------------------------------------------

proc agentHarborSection(): CodeTracerStorySection =
  for s in codeTracerStorySections():
    if s.title == AgentHarborSectionTitle: return s

let section = agentHarborSection()
let r = GpuiRenderer()

proc renderStory(story: CodeTracerStory; w, h: int; mode: DesignMode;
                 frame = true): tuple[problems: seq[string], mount: AhStoryMount] =
  ## Mounts the story, compares, tears it down. A story with no GPUI
  ## rendering is a problem, not an exception that ends the suite.
  gpui_reset_tree()
  let frameTitle = if frame and story.kind == "panel": frameTitleOf(story) else: ""
  try:
    let m = r.mountAgentHarborStoryGpui(story.surface, story.fixture, w, h, mode,
                                        frameTitle)
    result.mount = m
    result.problems = checkStory(m) & drawnTextProblems(m.root) & inkProblems(m, mode)
    if not r.verifyRenderPlan(m.root):
      result.problems.add "the shadow tree builds no valid render plan"
    if frameTitle.len > 0 and m.root.first("frame-title").attr("frame-title") != frameTitle:
      result.problems.add "the panel's frame does not say " & frameTitle
    m.dispose()
  except ValueError as e:
    result.problems = @["no GPUI rendering: " & e.msg]

suite "CTF-P1b: the stories come from their one declaration":
  test "the Agent Harbor section is declared and holds the P2a stories":
    ck section.title == AgentHarborSectionTitle
    ck section.stories.len >= MinimumStories
    ck validateStorySections(@[section]).len == 0
    var ids: HashSet[string]
    for story in section.stories: ids.incl storybookId(section, story)
    ck ids.len == section.stories.len
    # The ids are StoryBook's: the reference captures are named after them.
    ck "codetracer-agent-harbor--initiative-tabs-popup" in ids
    ck "codetracer-agent-harbor--session-list-sidebar-tree-folded" in ids

suite "CTF-P1b: every Agent Harbor story has a GPUI rendering":
  test "test_ctf_p1b_gpui_views_cover_web_states":
    var missing: seq[string]
    for story in section.stories:
      if not hasGpuiRendering(story.surface):
        missing.add storybookId(section, story) & " (surface " & story.surface & ")"
    if missing.len > 0:
      echo "Stories with no GPUI rendering:\n  " & missing.join("\n  ")
    ck missing.len == 0
    var failures: seq[string]
    var rendered = 0
    for story in section.stories:
      let id = storybookId(section, story)
      for (sizeName, w, h) in Sizes:
        for mode in Modes:
          let (problems, _) = renderStory(story, w, h, mode)
          if problems.len == 0: inc rendered
          else:
            failures.add id & " @ " & sizeName & "/" & $mode & ": " & problems.join("; ")
    if failures.len > 0:
      echo "GPUI renderings that differ from the viewmodel (" & $failures.len & "):\n  " &
        failures.join("\n  ")
    ck failures.len == 0
    ck rendered == section.stories.len * Sizes.len * Modes.len
    echo "  rendered ", rendered, " story renderings (", section.stories.len,
      " stories × ", Sizes.len, " sizes × ", Modes.len, " modes)"

suite "CTF-P1b: the comparison can fail":
  # Positive controls: a drawn tree that disagrees with its viewmodel must be
  # reported, or a green run above would mean nothing.
  test "a tab activated after drawing is a mismatch until the view redraws":
    gpui_reset_tree()
    var story: CodeTracerStory
    for s in section.stories:
      if s.surface == "agent-harbor-session-tabs" and s.fixture == "multi-line": story = s
    ck story.surface.len > 0
    let host = r.createElement("div")
    let vm = createSessionTabsStoryVM(story.fixture)
    drawSessionTabStrip(r, host, vm, ahPalette(dmDark), 1440)
    ck checkSessionTabs(host, vm).len == 0
    let tabs = vm.tabs
    ck vm.activate(tabs[^1].id)
    let stale = checkSessionTabs(host, vm)
    ck stale.len > 0
    ck stale.join(" ").contains("active tab")
    drawSessionTabStrip(r, host, vm, ahPalette(dmDark), 1440)
    ck checkSessionTabs(host, vm).len == 0
    vm.dispose()

  test "the drawn tree follows the viewmodel through its own render effect":
    var story: CodeTracerStory
    for s in section.stories:
      if s.surface == "agent-harbor-initiatives" and s.fixture == "populated": story = s
    gpui_reset_tree()
    let m = r.mountAgentHarborStoryGpui(story.surface, story.fixture, 760, 640)
    ck checkStory(m).len == 0
    let first = m.initiatives.rows[0].id
    m.initiatives.select(first)
    ck checkStory(m).len == 0
    ck m.view.first("selected").attr("selected") in ["true", "false"]
    var selectedDrawn = ""
    for e in m.view.all("initiative"):
      if e.attr("selected") == "true": selectedDrawn = e.attr("initiative")
    ck selectedDrawn == first
    m.dispose()

  test "a timeline line opened after drawing is reported until the view redraws":
    # The session activity timeline: a group opened in the viewmodel with no
    # redraw is drawn closed, and the check says so; the view's own render
    # effect then redraws it, and the two agree again.
    gpui_reset_tree()
    let host = r.createElement("div")
    let vm = createSessionActivityStoryVM("populated")
    drawSessionActivity(r, host, vm, ahPalette(dmDark), 760, 600)
    ck checkTimeline(host, vm).len == 0
    var group = ""
    for line in vm.lines:
      if line.kind == tlkGroup and group.len == 0: group = line.id
    ck group.len > 0
    vm.toggle(group)
    let stale = checkTimeline(host, vm)
    ck stale.len > 0
    ck stale.join(" ").contains(group & "'s expanded")
    drawSessionActivity(r, host, vm, ahPalette(dmDark), 760, 600)
    ck checkTimeline(host, vm).len == 0
    # A group line whose count is drawn other than the viewmodel's is
    # reported too.
    for e in host.all("line"):
      if e.attr("line") == group: r.setAttribute(e, "data-ah-count", "99")
    ck checkTimeline(host, vm).join(" ").contains(group & "'s count")
    vm.dispose()

  test "a fact that names a word the view does not draw is a mismatch":
    # The text checks compare `data-ah-*` facts with the viewmodel; this holds
    # the facts to the drawing. Redraw one tab's title under its fact and the
    # suite must say so.
    var story: CodeTracerStory
    for s in section.stories:
      if s.surface == "agent-harbor-session-tabs" and s.fixture == "single-line": story = s
    gpui_reset_tree()
    let m = r.mountAgentHarborStoryGpui(story.surface, story.fixture, 1440, 900)
    ck drawnTextProblems(m.root).len == 0
    let label = m.view.first("label")
    ck label != nil and childCount(label) == 1
    r.setTextContent(nthChild(label, 0), "not the viewmodel's title")
    let problems = drawnTextProblems(m.root)
    ck problems.len == 1
    ck problems.join(" ").contains("draws 'not the viewmodel's title'")
    m.dispose()

  test "the two colour modes draw the design system's two palettes":
    var story: CodeTracerStory
    for s in section.stories:
      if s.surface == "agent-harbor-session-tabs" and s.fixture == "single-line": story = s
    for mode in Modes:
      gpui_reset_tree()
      let m = r.mountAgentHarborStoryGpui(story.surface, story.fixture, 1440, 900, mode)
      let tab = m.view.first("tab")
      let att = m.sessions.tabs[0].attention
      let want = ahPalette(mode).markOf(att)
      ck tab.first("mark").attr("mark") ==
        (if want.ring: "ring:" & want.colour else: want.colour)
      m.dispose()
    ck ahPalette(dmDark).panel != ahPalette(dmLight).panel

proc fixtureSnapshot(): FleetSnapshot =
  var got: ref FleetSnapshot
  newFixtureDataSource().loadFleet proc(answer: DataResult[FleetSnapshot]) =
    doAssert answer.ok, answer.error
    got = new FleetSnapshot
    got[] = answer.value
  doAssert not got.isNil, "the fixture source answers synchronously"
  got[]

suite "CTF-P1b: the fleet's and the inbox's inks follow the shared rules":
  test "an error-level activity line: red without a failure line, caption under one":
    # The story data holds error-level activity only under failure lines, so
    # the other case is made from it: one failed session of the embedded
    # synthetic fleet given the running status, served through the
    # production `SnapshotDataSource` seam.
    # A failed row shows its reason once, as its failure line, so the line
    # the reason was read from is no activity line under it (the fleet
    # viewmodel leaves it out); an error-level line under a failure line is
    # an OLDER, different error. Every other failed session is given one,
    # oldest in its history, so that case is on screen too.
    var snapshot = fixtureSnapshot()
    var id = ""
    for s in snapshot.sessions.mitems:
      if id.len == 0 and s.status == fsFailed:
        for a in s.recent:
          if a.level == "error": id = s.id
        if id.len > 0:
          s.status = fsRunning
          s.rawStatus = "running"
      elif s.status == fsFailed:
        s.recent.insert(FleetActivity(kind: fakLog, level: "error",
                                      text: "error: an earlier attempt failed"), 0)
    ck id.len > 0
    for mode in Modes:
      gpui_reset_tree()
      let p = ahPalette(mode)
      let vm = newFleetSnapshotVM(newSnapshotDataSource(snapshot))
      vm.load()
      let host = r.createElement("div")
      r.drawFleetPanel(host, vm, p, 1440)
      ck fleetInkProblems(host, vm, p).len == 0
      var red, quiet: GpuiElement
      for row in vm.rows:
        for e in host.all("row"):
          if e.attr("row") != row.id: continue
          for i, a in e.all("activity"):
            if row.activityLevels[i] != "error": continue
            if row.failureText.len == 0 and red.isNil: red = a
            elif row.failureText.len > 0 and quiet.isNil: quiet = a
      ck not red.isNil and not quiet.isNil
      ck red.attr("ink") == p.textError
      ck quiet.attr("ink") == p.rowDetail
      # Negative control: the two inks swapped are both reported.
      r.tag(red, "ink", p.rowDetail)
      r.tag(quiet, "ink", p.textError)
      let problems = fleetInkProblems(host, vm, p).join(" ")
      ck problems.contains("of " & id[0 ..< 8] & " is drawn in " & p.rowDetail)
      ck problems.contains("(under a failure line) is drawn in " & p.textError)
      vm.dispose()

  test "a pressable arrow with nothing waiting, and the active 0 quiet, are reported":
    for (surface, fixture) in [("agent-harbor-initiative-tabs", "empty"),
                               ("agent-harbor-fleet", "empty")]:
      gpui_reset_tree()
      let m = r.mountAgentHarborStoryGpui(surface, fixture, 1440, 900, dmLight)
      ck inkProblems(m, dmLight).len == 0
      let p = ahPalette(dmLight)
      if surface == "agent-harbor-fleet":
        for f in m.view.all("filter"):
          if f.attr("active") == "true": r.tag(f.first("ink"), "ink", p.textDisabled)
        ck inkProblems(m, dmLight).join(" ").contains("the count of filter")
      else:
        r.tag(m.view.first("step"), "ink", p.textLabel)
        ck inkProblems(m, dmLight).join(" ").contains("the inbox step")
      m.dispose()

  test "an arrow drawn disabled while a session waits is reported":
    for mode in [dmDark, dmLight]:
      gpui_reset_tree()
      let m = r.mountAgentHarborStoryGpui("agent-harbor-initiative-tabs", "next",
                                          1440, 900, mode)
      ck inkProblems(m, mode).len == 0
      let step = m.view.first("step")
      ck step.attr("step") == "enabled"
      r.tag(step, "ink", ahPalette(mode).textDisabled)
      ck inkProblems(m, mode).join(" ").contains("the inbox step")
      m.dispose()

  test "a disabled arrow under the pressable cursor is reported":
    for mode in [dmDark, dmLight]:
      gpui_reset_tree()
      let m = r.mountAgentHarborStoryGpui("agent-harbor-initiative-tabs", "empty",
                                          1440, 900, mode)
      ck inkProblems(m, mode).len == 0
      let step = m.view.first("step")
      ck step.attr("step") == "disabled"
      r.tag(step, "cursor", "pointer")
      ck inkProblems(m, mode).join(" ").contains("shows the pointer cursor")
      m.dispose()

  test "the auto-switch dot in the action surface's colour is reported":
    # Light only: in Dark the action surface and the action border are one
    # colour (#6366f1), which is why the defect showed only in Light.
    for mode in [dmLight]:
      gpui_reset_tree()
      let m = r.mountAgentHarborStoryGpui("agent-harbor-initiative-tabs", "auto-switch",
                                          1440, 900, mode)
      ck inkProblems(m, mode).len == 0
      let toggle = m.view.first("auto-switch")
      ck toggle.attr("auto-switch") == "true"
      r.tag(toggle.first("mark"), "mark", ahPalette(mode).action)
      ck inkProblems(m, mode).join(" ").contains("the auto-switch dot is drawn in " &
                                                 ahPalette(mode).action)
      m.dispose()

suite "CTF-P1c D7: a tree node's counts keep their floor":
  test "the counts never go below their floor, and the title gives way first":
    # The limits `drawGroupHeader` hands GPUI's flex layout. At a laptop's
    # and a sidebar's width the title keeps half the line; on a node about
    # 20 terminal cells (200px) wide the title's least drops below half,
    # and the counts' least stays their floor, `1…`, a pixel over its
    # words.
    const counts = "1 needs input \xC2\xB7 2 running"
    let floorPx = int(ceil(textWidth(countsFloor(counts), CaptionPx))) + 1
    for widthPx in [1440, 360]:
      let w = groupHeaderWidths(widthPx, counts, "1/4", marked = true)
      ck w.titleMin == (widthPx - 2 * InsetPx) div 2
      ck w.countsMin == floorPx
    let narrow = groupHeaderWidths(200, counts, "10/12", marked = true)
    ck narrow.countsMin == floorPx
    ck narrow.titleMin < (200 - 2 * InsetPx) div 2
    ck narrow.titleMin + narrow.countsMin + 12 + MarkPx +
       textPx("10/12", CaptionPx, tabular = true) + 4 * 8 <= 200 - 2 * InsetPx

suite "CTF-P1b: the GPUI views share the viewmodels, not the web views":
  test "no GPUI Agent Harbor view imports a web view or the web renderer":
    # The words both front-ends say live in `viewmodel/views/agent_harbor_words`,
    # which renders nothing. A GPUI view that imported an `isonim_*_view`
    # module, the IsoNim DSL or the web renderer to reach a helper would put
    # the web's rendering code in the native front-end's closure.
    const viewDir = currentSourcePath().parentDir.parentDir / "agent_harbor"
    var scanned = 0
    var offenders: seq[string]
    for path in walkFiles(viewDir / "*.nim"):
      inc scanned
      for line in readFile(path).splitLines:
        let code = line.strip
        if not (code.startsWith("import ") or code.startsWith("from ")): continue
        for forbidden in ["views/isonim_", "isonim/dsl", "isonim/web"]:
          if forbidden in code: offenders.add path.extractFilename & ": " & code
    ck scanned >= 6
    if offenders.len > 0: echo "  web imports:\n    " & offenders.join("\n    ")
    ck offenders.len == 0

suite "CTF-P1b: assertion count":
  test "every assertion ran":
    check countedAssertions == 73
