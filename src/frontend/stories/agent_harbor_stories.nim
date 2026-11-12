## The Agent Harbor stories' viewmodel constructors.
##
## A story of the `agent-harbor-fleet` surface (declared in
## `codetracer_stories.nim`) is a `FleetSnapshotVM` built by
## `createFleetStoryVM` over the story's fixture, and the production view
## `isonim_agent_harbor_fleet_view` rendered over it. StoryBook and the IsoNim
## Editor instance both reach this through `mountCodeTracerStory`
## (`storybook_components.nim`), so the two surfaces build the same viewmodel
## for the same story.
##
## The viewmodels and their data-source seam come from
## nim-agents-isonim-viewmodels; this module only says which source and which
## view state each fixture names.

import nim_agents_isonim_viewmodels/agent_harbor/[data_source, fixture_source,
                                                   fleet_vm, records, synthetic_fleet]

const fleetFixtures* = ["snapshot", "needs-input", "failed", "selected",
                        "expanded", "filtered-empty", "loading", "error", "empty"]
  ## Every fixture an `agent-harbor-fleet` story may name.

proc fleetStorySource*(fixture: string): AgentHarborDataSource =
  ## The data source a fleet story reads. Every populated state is the
  ## captured fleet snapshot; the states no capture shows come from the
  ## data-source seam's state sources, so the view is exercised through the
  ## same seam a live source will use.
  case fixture
  of "loading":
    newPendingDataSource("waiting for the Agent Harbor server")
  of "error":
    newFailingDataSource(
      "GET /api/v1/sessions failed: connection refused (the server is not " &
      "running, or its address is wrong)", "unreachable server")
  of "empty":
    newSnapshotDataSource(FleetSnapshot(sourceLabel: "empty server"),
                          "empty server")
  of "filtered-empty":
    # A small invented set with no queued session, so the Queued filter
    # leaves nothing (the snapshot has queued sessions in some captures).
    let (snapshot, plans) = syntheticWorkingSet(3, 2, newFixtureDataSource().capturedAtMs)
    newSnapshotDataSource(snapshot, "invented working set: 3 sessions over 2 initiatives", plans)
  else:
    newFixtureDataSource()

proc createFleetStoryVM*(fixture: string): FleetSnapshotVM =
  ## The viewmodel of the fleet story named by `fixture`: `snapshot` (the
  ## captured fleet), `needs-input` and `failed` (the snapshot under that
  ## filter), `selected` (its first captured session selected), `loading`,
  ## `error`, `empty`. Call inside a reactive root; the caller disposes it.
  ## An unknown fixture raises rather than showing some other state under
  ## the story's name.
  if fixture notin fleetFixtures:
    raise newException(ValueError, "no Agent Harbor fleet story fixture named " & fixture)
  let source = fleetStorySource(fixture)
  result = newFleetSnapshotVM(source)
  result.load()
  case fixture
  of "needs-input": result.setFilter(ffNeedsInput)
  of "failed": result.setFilter(ffFailed)
  of "filtered-empty": result.setFilter(ffQueued)
  of "selected":
    if source of FixtureDataSource:
      let rows = result.rows
      if rows.len > 0: result.select(rows[0].id)
  of "expanded":
    # The first row with more than one distinct activity line, unfolded.
    for row in result.rows:
      if row.activity.len + row.activityMore > 1:
        result.toggleExpanded(row.id)
        break
  else: discard

# ---------------------------------------------------------------------------
# Sessions as tabs, initiatives, initiative progress
# ---------------------------------------------------------------------------
#
# Populated stories run over ONE coherent working set (never real and
# invented data in one story, and a session shown under an initiative works
# on that initiative). The default is the invented working set
# (`defaultWorkingSet`): fourteen sessions over four invented initiatives,
# each session's title one of its initiative's, with the front-end of origin
# each states. The `real` stories use the captured real set: sessions of the
# real fleet snapshot and the real running plans; Agent Harbor reports no
# session's plan yet, so only the association known for real (the capturing
# host's own session runs the CodeTracer plan) is made, and the other plans
# show no session. Captured scenario runs are never attached to an invented
# initiative here. The states no capture shows come from the seam's state
# sources: an invented working set of forty sessions over five initiatives
# (overflow), one with very long names, an empty server, a server that has
# not answered, one that cannot be reached.

import std/[strutils, times]
import nim_agents_isonim_viewmodels/agent_harbor/[session_tabs_vm, initiatives_vm,
  initiative_progress_vm]

export session_tabs_vm, initiatives_vm, initiative_progress_vm

const
  SessionMenuOverPanelFixture* = "menu-over-panel"
    ## The strip's `single-line-active-late` state (its overflow menu open)
    ## with a panel under the caption bar, as in the shell, so the menu drops
    ## over a panel's ground rather than the window's.
  sessionTabsFixtures* = ["single-line", "single-line-active-late",
    SessionMenuOverPanelFixture, "multi-line",
    "single-line-40", "multi-line-40", "long-names", "needs-input-wins",
    "focused-initiative", "empty", "loading", "error"]
  sessionListFixtures* = ["sidebar", "sidebar-ungrouped", "sidebar-collapsed",
    "sidebar-tree-folded",
    "sidebar-40", "docked", "docked-40", "empty", "loading", "error"]
  initiativesFixtures* = ["populated", "selected", "overflow-40", "long-names",
    "real", "empty", "loading", "error"]
  progressFixtures* = ["current", "blocked", "progress-event", "long-names",
    "no-summary", "real-plan", "unknown", "loading", "error"]

proc fixtureNowMs(): int64 =
  ## The fixture set's own clock, so invented sets age like captured ones.
  let fixtures = newFixtureDataSource()
  if fixtures.capturedAtMs > 0: fixtures.capturedAtMs
  else: int64(epochTime() * 1000)

proc invented(sessions, initiatives: int; longNames = false): SnapshotDataSource =
  let (snapshot, plans) = syntheticWorkingSet(sessions, initiatives, fixtureNowMs(),
                                              longNames)
  newSnapshotDataSource(snapshot,
    if longNames: "invented working set with long names"
    else: "invented working set: " & $sessions & " sessions over " & $initiatives & " initiatives",
    plans)

proc sessionsStorySource*(fixture: string;
                          endpoint = "/api/v1/sessions"): AgentHarborDataSource =
  ## The source a sessions, initiatives or progress story reads. `endpoint`
  ## is the read an error story names; "" for a read Agent Harbor's API has
  ## no route for yet (the initiatives), whose error names no route.
  case fixture
  of "loading": newPendingDataSource("waiting for the Agent Harbor server")
  of "error":
    let failed = if endpoint.len > 0: "GET " & endpoint & " failed"
                 else: "The Agent Harbor server did not answer"
    newFailingDataSource(failed & ": connection refused " &
                         "(the server is not running, or its address is wrong)",
                         "unreachable server")
  of "empty", "unknown": newSnapshotDataSource(FleetSnapshot(sourceLabel: "empty server"),
                                               "empty server")
  of "single-line-40", "multi-line-40", "sidebar-40", "docked-40", "overflow-40",
     "overflow-menu-over-panel", "overflow-menu-near-left":
    invented(40, 5)
  of "long-names":
    # Four sessions over five initiatives: the last initiative has none.
    invented(4, 5, longNames = true)
  of "real", "real-plan", "blocked": newWorkingSetDataSource(wsReal)
  else: invented(DefaultSessions, DefaultInitiatives)

proc busiestInitiative(source: AgentHarborDataSource): string =
  ## The initiative with the most sessions (the first on a tie).
  var best = -1
  var chosen = ""
  source.loadInitiatives proc(answer: DataResult[seq[Initiative]]) =
    if not answer.ok: return
    for initiative in answer.value:
      if initiative.sessionIds.len > best:
        best = initiative.sessionIds.len
        chosen = initiative.id
  chosen

proc createSessionTabsStoryVM*(fixture: string): SessionTabStripVM =
  ## The tab strip in the caption bar: one line, or several.
  if fixture notin sessionTabsFixtures:
    raise newException(ValueError, "no session tab strip story fixture named " & fixture)
  let source = sessionsStorySource(fixture)
  var policy = tabStripSessionPolicy()
  if fixture == "needs-input-wins": policy.status = espNeedsInputWins
  # The focused initiative is shown on several lines, so all its tabs are seen.
  let mode = if fixture.startsWith("multi-line") or fixture == "focused-initiative": tsmMultiLine
             else: tsmSingleLine
  result = newSessionTabStripVM(source, mode, policy)
  result.load()
  case fixture
  of "single-line-active-late", SessionMenuOverPanelFixture:
    let tabs = result.tabs
    if tabs.len > 0: discard result.activate(tabs[^2].id)
    result.overflowOpen.val = true
  of "focused-initiative":
    result.focusInitiative(busiestInitiative(source))
  else: discard

proc createSessionListStoryVM*(fixture: string): SessionTabStripVM =
  ## The same tabs as a sidebar list, or docked as a panel.
  if fixture notin sessionListFixtures:
    raise newException(ValueError, "no session list story fixture named " & fixture)
  let mode = if fixture.startsWith("docked"): tsmDocked else: tsmSidebar
  # A list is read top to bottom: within each initiative the sessions that
  # need a person come first (the strip keeps launch order: tabs never jump).
  var policy = tabStripSessionPolicy()
  policy.order = soAttention
  result = newSessionTabStripVM(sessionsStorySource(fixture), mode, policy)
  result.load()
  case fixture
  of "sidebar-ungrouped":
    result.grouped.val = false
    let groups = result.groups
    if groups.len > 0 and groups[0].tabs.len > 0: discard result.activate(groups[0].tabs[0].id)
  of "docked", "docked-40", "sidebar", "sidebar-40", "sidebar-collapsed":
    # The session in view is the first the list shows.
    let groups = result.groups
    if groups.len > 0 and groups[0].tabs.len > 0: discard result.activate(groups[0].tabs[0].id)
  of "sidebar-tree-folded":
    # The initiatives tree with its first two nodes folded; the session in
    # view is the first one still shown.
    let groups = result.groups
    for i in 0 ..< min(2, groups.len): result.toggleGroup(groups[i].planId)
    if groups.len > 2 and groups[2].tabs.len > 0: discard result.activate(groups[2].tabs[0].id)
  else: discard
  if fixture == "sidebar-collapsed": result.collapsed.val = true

proc createInitiativesStoryVM*(fixture: string): InitiativesVM =
  if fixture notin initiativesFixtures:
    raise newException(ValueError, "no initiatives story fixture named " & fixture)
  let source = sessionsStorySource(fixture, endpoint = "")
  result = newInitiativesVM(source)
  result.load()
  if fixture == "selected": result.select(busiestInitiative(source))

proc createProgressStoryVM*(fixture: string): InitiativeProgressVM =
  ## One initiative's progress: the one most sessions work on (`current`),
  ## one with a blocked milestone, one receiving a progress event (its
  ## current milestone completes), long names, a plan with no executive
  ## summary, an initiative the server does not know.
  if fixture notin progressFixtures:
    raise newException(ValueError, "no initiative progress story fixture named " & fixture)
  var source = sessionsStorySource(fixture, endpoint = "")
  var initiativeId = ""
  case fixture
  of "current", "progress-event", "real-plan": initiativeId = busiestInitiative(source)
  of "blocked":
    # A captured plan with a blocked milestone where the set has one; else
    # the invented set's.
    var found = ""
    source.loadInitiatives proc(answer: DataResult[seq[Initiative]]) =
      if answer.ok:
        for initiative in answer.value:
          if found.len == 0 and statusCounts(initiative.progress)[mscBlocked] > 0:
            found = initiative.id
    if found.len == 0:
      source = invented(40, 5)
      source.loadInitiatives proc(answer: DataResult[seq[Initiative]]) =
        for initiative in answer.value:
          if found.len == 0 and statusCounts(initiative.progress)[mscBlocked] > 0:
            found = initiative.id
    initiativeId = found
  of "no-summary":
    let snapshotSource = SnapshotDataSource(source)
    if snapshotSource.initiatives.len > 0:
      snapshotSource.initiatives[0].executiveSummary = ""
      initiativeId = snapshotSource.initiatives[0].id
  of "unknown": initiativeId = "an-initiative-the-server-does-not-know"
  else: discard
  if fixture == "progress-event":
    # The invented plan made coherent with the event before it arrives: the
    # milestone it completes has all its deliverables and passing tests, and
    # the summary already names the next one current.
    let snapshotSource = SnapshotDataSource(source)
    for initiative in snapshotSource.initiatives.mitems:
      if initiative.id == initiativeId:
        discard initiative.readyForCompletion(initiative.progress.currentMilestone)
  result = newInitiativeProgressVM(source, initiativeId)
  result.load()
  if fixture == "progress-event":
    let current = result.current.progress.currentMilestone
    discard result.applyProgress(initiativeId, current, "completed")

# ---------------------------------------------------------------------------
# Initiatives as tabs (the tab bar of CodeTracer as an Agent Harbor front-end)
# ---------------------------------------------------------------------------

import nim_agents_isonim_viewmodels/agent_harbor/initiative_tabs_vm

export initiative_tabs_vm

const PopupOverPanelFixture* = "popup-over-panel"
  ## The initiative bar's `popup` state with a panel under the caption bar,
  ## as in the shell, so the popup opens over a panel's ground rather than
  ## the window's.

const ElsewhereOverPanelFixture* = "elsewhere-over-panel"
  ## The `elsewhere` state (the sessions-started-elsewhere menu open) over
  ## a panel under the caption bar.

const OverflowMenuOverPanelFixture* = "overflow-menu-over-panel"
  ## The invented `overflow-40` set with the `+N` overflow menu open, over a
  ## panel under the caption bar.

const OverflowMenuNearLeftFixture* = "overflow-menu-near-left"
  ## The invented `overflow-40` set with its shortest-named initiative
  ## active and the `+N` overflow menu open: on a narrow bar the active tab
  ## is the only one drawn, so the chip ends near the window's left edge and
  ## the menu hanging from it must shift right to stay inside the window.

const initiativeTabsFixtures* = ["tabs", "popup", PopupOverPanelFixture, "elsewhere",
  ElsewhereOverPanelFixture, "next", "auto-switch", "recordings-many", "overflow-40",
  OverflowMenuOverPanelFixture, OverflowMenuNearLeftFixture, "long-names", "real", "empty",
  "loading", "error"]

func hasPanelUnderCaption*(surface, fixture: string): bool =
  ## Whether a story draws a panel under the caption bar (its whole window
  ## below the bar on the panel's ground), so the bar's popup or menu drops
  ## over a panel: each front-end's story host draws it, the web's, GPUI's
  ## and the terminal's.
  case surface
  of "agent-harbor-initiative-tabs":
    fixture in [PopupOverPanelFixture, ElsewhereOverPanelFixture, OverflowMenuOverPanelFixture]
  of "agent-harbor-session-tabs": fixture == SessionMenuOverPanelFixture
  else: false

proc inventedRecordings(count: int): seq[RecordingEntry] =
  ## More replays than any capture holds, one still loading, one that
  ## failed to load and one no longer there, for the switcher's overflow and
  ## its states.
  for i in 0 ..< count:
    result.add RecordingEntry(id: "invented-recording-" & $i,
      name: "invented recording " & $(i + 1), revision: "r" & $(1000 + i),
      origin: (if i mod 2 == 0: "ct test run" else: "an agent session"),
      state: (if i == 2: rsLoading elif i == 3: rsFailed
              elif i == 4: rsMissing else: rsReady),
      error: (if i == 3: "the replay server could not open the trace"
              elif i == 4: "the trace is no longer on the server" else: ""))

proc createInitiativeTabsStoryVM*(fixture: string): InitiativeTabStripVM =
  ## The tab bar with one tab per initiative: `tabs` (the first active, with
  ## its loaded recordings), `popup` (its progress popup shown; with a panel
  ## under the bar, `popup-over-panel`), `elsewhere`
  ## (the sessions started elsewhere, listed; over a panel,
  ## `elsewhere-over-panel`), `next` (Next taken: the first
  ## waiting session in view), `auto-switch` (auto-switch on and the
  ## instruction delivered: the view moved on), `recordings-many`, and the
  ## invented `overflow-40` (its `+N` menu open over a panel,
  ## `overflow-menu-over-panel`; open from a chip near the window's left
  ## edge, `overflow-menu-near-left`), `long-names`, and `empty`, `loading`,
  ## `error`.
  if fixture notin initiativeTabsFixtures:
    raise newException(ValueError, "no initiative tab bar story fixture named " & fixture)
  let source = sessionsStorySource(fixture, endpoint = "")
  result = newInitiativeTabStripVM(source)
  result.load()
  let tabs = result.tabs
  if tabs.len == 0 or tabs[0].kind != stkInitiative: return
  let first = tabs[0].id
  # The recordings a front-end has loaded for an initiative are its own
  # state, and no capture associates a recording with a plan: the
  # invented working sets get invented recordings (one ready,
  # one loading, one that failed, one missing); the real set's initiatives
  # none.
  case fixture
  of "recordings-many": result.setRecordings(first, inventedRecordings(12), "invented-recording-0")
  of "real": discard
  else:
    var recordings = inventedRecordings(5)
    recordings.delete(1)
    result.setRecordings(first, recordings, recordings[0].id)
  case fixture
  of "popup", PopupOverPanelFixture: result.popupId.val = first
  of "elsewhere", ElsewhereOverPanelFixture: result.elsewhereOpen.val = true
  of OverflowMenuOverPanelFixture: result.overflowOpen.val = true
  of OverflowMenuNearLeftFixture:
    # The shortest-named initiative (the first of them on a tie) active,
    # then the menu open: activating a tab closes it.
    var shortest = -1
    for i, t in tabs:
      if t.kind == stkInitiative and (shortest < 0 or t.title.len < tabs[shortest].title.len):
        shortest = i
    discard result.activate(initiativeKey(tabs[shortest].id))
    result.overflowOpen.val = true
  of "next": discard result.stepInbox(1)
  of "auto-switch":
    result.autoSwitch.val = true
    discard result.stepInbox(1)
    result.markResumed(result.activeSessionId)
  else: discard
