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

import std/[os, sets, strutils, unittest]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../../stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories
import ../agent_harbor/ah_stories
import ../agent_harbor/ah_session_views
import ../agent_harbor/ah_fleet_panel
import nim_agents/agent_harbor/fleet_records
import nim_agents_isonim_viewmodels/agent_harbor/[fleet_vm, session_tabs_vm,
  initiative_tabs_vm, initiatives_vm, initiative_progress_vm, data_source, fixture_source]
from ../../viewmodel/views/agent_harbor_words import tabLabelOf, filterCount,
  activityLineIsError

const
  AgentHarborSectionTitle = "CodeTracer/Agent Harbor"
  Sizes = [("laptop", 1440, 900), ("panel", 760, 640), ("sidebar", 360, 900)]
  Modes = [dmDark, dmLight]
  MinimumStories = 59
    ## The section's stories at CTF-P2a's landing (9 fleet, 11 session tabs,
    ## 10 session list, 12 initiative tabs, 8 initiatives, 9 progress). A
    ## floor, so a declaration that silently lost its stories cannot pass
    ## by rendering nothing.

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
  # The active initiative's recording switcher.
  var wantedNumbers: seq[string]
  var wantedHidden: seq[string]
  for t in tabs:
    if t.active and t.kind == stkInitiative:
      let buttons = vm.recordingButtonsOf(t.id)
      for b in buttons.buttons: wantedNumbers.add $b.number
      if buttons.hidden > 0: wantedHidden.add $buttons.hidden
  result.expect("recording buttons", view.values("recording"), wantedNumbers)
  result.expect("recordings behind +N", view.values("recordings-hidden"), wantedHidden)
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

proc inkProblems(m: AhStoryMount; mode: DesignMode): seq[string] =
  ## The colours the shared rules decide, by surface: the fleet's
  ## (`fleetInkProblems`), and the inbox's Previous / Next in the disabled
  ## role while nothing waits.
  let p = ahPalette(mode)
  case m.surface
  of "agent-harbor-fleet":
    if m.fleet.state.val == asReady: result = fleetInkProblems(m.view, m.fleet, p)
  of "agent-harbor-initiative-tabs":
    let wanted = if m.initiativeTabs.inboxPosition.len == 0: p.textDisabled else: p.textLabel
    for e in m.view.all("step"):
      if e.attr("ink") != wanted:
        result.add "the inbox step " & e.attr("button") & " (" & e.attr("step") &
                   ") is drawn in " & e.attr("ink") & ", not " & wanted
  else: discard

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
    var snapshot = fixtureSnapshot()
    var id = ""
    for s in snapshot.sessions.mitems:
      if id.len == 0 and s.status == fsFailed:
        for a in s.recent:
          if a.level == "error": id = s.id
        if id.len > 0:
          s.status = fsRunning
          s.rawStatus = "running"
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
    check countedAssertions == 45
