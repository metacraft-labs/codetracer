## gpui/agent_harbor/ah_stories.nim — CTF-P1b. A CodeTracer story of the
## Agent Harbor section, mounted in GPUI.
##
## The web mounts a story with `mountCodeTracerStory` (`storybook_components.nim`):
## it builds the story's viewmodel with the constructor
## `stories/agent_harbor_stories.nim` names for the story's surface and
## fixture, inside a reactive root, and renders the production IsoNim view
## over it. `mountAgentHarborStoryGpui` is the same for GPUI: the SAME
## constructors, so a GPUI story shows the same viewmodel state as the web
## story of the same id, drawn by this directory's views. The stories
## themselves are declared once, in `stories/codetracer_stories.nim`.
##
## A surface the web mounts and this module does not is a story with no GPUI
## rendering: `hasGpuiRendering` says so, and mounting it raises. The CTF-P1b
## coverage test (`gpui/tests/test_ctf_p1b_gpui_views_cover_web_states.nim`)
## walks every story of the section through both.

import isonim/core/owner

import ../../stories/agent_harbor_stories
import ./ah_theme
import ./ah_session_views
import ./ah_initiative_tab_bar
import ./ah_initiative_panels
import ./ah_fleet_panel
import ./ah_playback_bar
import ./ah_composer
import ./ah_pie
import ../../stories/agent_harbor_composer_stories
import ./ah_results
import ../../stories/agent_harbor_results_stories
import ./ah_session_activity
import ./ah_suggested_actions
import ../../stories/agent_harbor_suggested_actions_stories
import ./ah_control_center
import ../../stories/agent_harbor_control_center_stories
import ./ah_gaze_mark
import ../../stories/agent_harbor_gaze_stories
import ./ah_process_switcher
import ../../stories/agent_harbor_process_switcher_stories
import ../agent_activity_leaf
import ../window_geometry
import ../../viewmodel/agent_harbor_activity_cards
import ../../viewmodel/store/replay_data_store
import ../../viewmodel/backend/[mock_backend, backend_service]
import ./ah_changes_inbox_stories
import ../../viewmodel/input/element_press
import ../../viewmodel/keymap/[base_keymaps, context_keys, editing_keymap,
                               keymap_router,
                               scope_path, user_keymap]
import ../../../common/key_names

export agent_harbor_stories, ah_theme, ah_playback_bar, user_keymap, ah_composer,
  ah_control_center, ah_gaze_mark, ah_process_switcher,
  ah_results, ah_changes_inbox_stories, ah_pie

const
  GpuiAgentHarborSurfaces* = [
    "agent-harbor-fleet",
    "agent-harbor-session-tabs",
    "agent-harbor-session-list",
    "agent-harbor-initiative-tabs",
    "agent-harbor-initiatives",
    "agent-harbor-initiative-progress",
    "agent-harbor-composer",
    "agent-harbor-results",
    "agent-harbor-session-activity",
    "agent-harbor-suggested-actions",
    "agent-harbor-control-center",
    "agent-harbor-status-gaze",
    "agent-harbor-changes",
    "agent-harbor-inbox",
    "agent-harbor-inbox-item",
    "agent-harbor-pie",
    "agent-harbor-process-switcher",
  ]
    ## Every surface of the Agent Harbor section this module draws (the
    ## Changes panel's and the Inbox's through `ah_changes_inbox_stories`,
    ## the progress pie's through `ah_pie`).
  FrameTitlePx = 32          ## `.lm_header`
  FrameInsetPx = 4           ## the golden-layout root's side inset

type
  AhStoryMount* = object
    ## A mounted story: its root element and the viewmodel it shows (the one
    ## field its surface uses), torn down by `dispose`.
    surface*, fixture*: string
    root*: GpuiElement
      ## The frame (a panel story's title tab and body), or the view itself.
    view*: GpuiElement
      ## The view's own root, the element its `data-ah-surface` is on.
    fleet*: FleetSnapshotVM
    sessions*: SessionTabStripVM
    initiativeTabs*: InitiativeTabStripVM
    initiatives*: InitiativesVM
    progress*: InitiativeProgressVM
    composer*: OmniboxComposerVM
    results*: ResultCommandsVM
    timeline*: SessionTimelineVM
    suggestion*: SuggestedActionsVM
      ## The suggested-actions block at the timeline's end (its stories only).
    center*: ControlCenterVM
      ## The control center (its stories only).
    gaze*: GazeStatusVM
      ## The status line's gaze mark (its stories only).
    processes*: ProcessSwitcherVM
      ## A multi-process recording's process switcher (its stories only).
    cards*: ActivityAgainstCards
      ## The comparison story's cards (`agent_harbor_activity_cards`): its
      ## store, the events both halves were fed, and today's Agent Activity
      ## panel's viewmodel. Unset for any other story.
    cardsFeed*: GpuiElement
      ## The comparison story's cards half (nil for any other story).
    changesInbox*: ChangesInboxMount
      ## A Changes or Inbox story's viewmodel (`ah_changes_inbox_stories`).
    playback*: AhPlayback
      ## A playback story's playback (nil for any other story): its source
      ## feeds the viewmodel, and the bar under the story controls it.
    bar*: GpuiElement
      ## The playback bar's host (nil for any other story).
    dispose*: proc()

proc hasGpuiRendering*(surface: string): bool =
  surface in GpuiAgentHarborSurfaces

proc playbackPresses*(keymap: UserKeymap; pb: AhPlayback): PlaybackPress =
  ## **THE STORY HOST'S ROUTE FOR A PRESS ON ITS PLAYBACK BAR**
  ## (Input-Routing-And-Keymaps.md §5.1): the press is resolved in the
  ## `storyPlayback` scope by the window's router — the base keymap with
  ## `keymap` (a user's `keybindings.json` rows) laid over it — and a
  ## user's row for the press takes it; a primary press with no row runs
  ## the operation the button carries (`element_press`). The story host
  ## performs only the playback's own operations (`performPlaybackOperation`):
  ## a press resolved to any other is inert.
  # GPUI's three keys (`edit_arm.GpuiDelivery`): it receives keys, not bytes.
  let router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feGpui,
                                                   platform: hostPlatform(),
                                                   keyProtocol: kpNative),
                                user = keymap)
  let resolve = routerResolver(router, SessionFacts())
  result = proc(operation: string; mods: KeyModifiers) =
    let outcome = resolveElementPress(resolve,
                                      @[element(ekWindow, "window"),
                                        pane(StoryPlaybackScope)],
                                      ButtonElementKind, operation, mods, "Click")
    discard pb.performPlaybackOperation(outcome.operation)

proc gpuiRouter(keymap: UserKeymap): KeymapRouter =
  ## The story host's router: the base keymap with a user's rows over it,
  ## for GPUI's three keys (`edit_arm.GpuiDelivery`: it receives keys, not
  ## bytes).
  initKeymapRouter(bkCua, KeyDelivery(frontEnd: feGpui, platform: hostPlatform(),
                                      keyProtocol: kpNative), user = keymap)

let ComposerScopePath = @[element(ekWindow, "window"), pane(ComposerScope)]
  ## Where the composer's keys and presses resolve.

proc composerPresses*(keymap: UserKeymap; vm: OmniboxComposerVM): ComposerPress =
  ## **THE STORY HOST'S ROUTE FOR A PRESS ON THE COMPOSER**
  ## (Input-Routing-And-Keymaps.md §5.1): resolved in the `composer` scope
  ## by the window's router — a user's row for the press first, else the
  ## operation the element carries — and run on the composer's viewmodel on
  ## the element's target (`runComposerPress`); the view redraws itself from
  ## the viewmodel.
  let resolve = routerResolver(gpuiRouter(keymap), SessionFacts())
  result = proc(operation, target: string) =
    let outcome = resolveElementPress(resolve, ComposerScopePath, ButtonElementKind,
                                      operation, {}, "Click")
    discard vm.runComposerPress(outcome.operation, target)

proc composerKey*(m: AhStoryMount; name: string; keymap = UserKeymap()): string =
  ## A key (its canonical name) while the composer is shown, ROUTED
  ## (Input-Routing-And-Keymaps.md §4) in the `composer` scope: `Enter`
  ## sends, `Down` / `Up` move the destination. Runs the operation it
  ## resolves to and returns it ("" for none).
  if m.composer.isNil: return ""
  var router = gpuiRouter(keymap)
  let res = router.route(SessionFacts(), ComposerScopePath, nmNormal, name, 0)
  if res.kind != erOperation or not m.composer.runComposerOperation(res.operation):
    return ""
  res.operation

let ControlCenterScopePath = @[element(ekWindow, "window"), pane(ControlCenterScope)]
  ## Where the control center's keys and presses resolve; its launch form's
  ## (the composer's) resolve in the composer's scope inside it.
let ControlCenterFormScopePath = @[element(ekWindow, "window"), pane(ControlCenterScope),
                                   pane(ComposerScope)]

proc controlCenterPresses*(keymap: UserKeymap; vm: ControlCenterVM): ControlCenterPress =
  ## **THE STORY HOST'S ROUTE FOR A PRESS ON THE CONTROL CENTER**
  ## (Input-Routing-And-Keymaps.md §5.1): resolved by the window's router --
  ## a user's row for the press first, else the operation the element
  ## carries -- in the scope the element is in (its launch form's in the
  ## composer's), and run on the control center (`runControlCenterPress`).
  let resolve = routerResolver(gpuiRouter(keymap), SessionFacts())
  result = proc(operation, target: string) =
    let path = if operation in ComposerPressOperations: ControlCenterFormScopePath
               else: ControlCenterScopePath
    let outcome = resolveElementPress(resolve, path, ButtonElementKind,
                                      operation, {}, "Click")
    discard vm.runControlCenterPress(outcome.operation, target)

proc controlCenterKey*(m: AhStoryMount; name: string; keymap = UserKeymap()): string =
  ## A key while the control center is shown, ROUTED in its scope (`Down` /
  ## `Up` walk the waiting sessions, `Enter` opens one). Runs the operation it
  ## resolves to and returns it ("" for none).
  if m.center.isNil: return ""
  var router = gpuiRouter(keymap)
  let res = router.route(SessionFacts(), ControlCenterScopePath, nmNormal, name, 0)
  if res.kind != erOperation or not m.center.runControlCenterOperation(res.operation):
    return ""
  res.operation

let WindowScopePath = @[element(ekWindow, "window")]
  ## Where a window-level key (the gaze pause key) resolves.

proc gazePresses*(keymap: UserKeymap; vm: GazeStatusVM): GazePress =
  ## The route for a press on the gaze mark: resolved at the window's scope,
  ## a user's row first, and run on the mark (`runGazeOperation`).
  let resolve = routerResolver(gpuiRouter(keymap), SessionFacts())
  result = proc(operation: string) =
    let outcome = resolveElementPress(resolve, WindowScopePath, ButtonElementKind,
                                      operation, {}, "Click")
    discard vm.runGazeOperation(outcome.operation)

proc gazeKey*(m: AhStoryMount; name: string; keymap = UserKeymap()): string =
  ## A key while the gaze story is shown, ROUTED at the window's scope (the
  ## pause key, `Ctrl+Alt+Y`). Runs the operation it resolves to and returns
  ## it ("" for none).
  if m.gaze.isNil: return ""
  var router = gpuiRouter(keymap)
  let res = router.route(SessionFacts(), WindowScopePath, nmNormal, name, 0)
  if res.kind != erOperation or not m.gaze.runGazeOperation(res.operation): return ""
  res.operation

let ProcessSwitcherScopePath = @[element(ekWindow, "window"), pane(ProcessSwitcherScope)]
  ## Where the process switcher's number keys and presses resolve; its next
  ## and previous keys are window rows, found from here too.

proc processSwitcherPresses*(keymap: UserKeymap; vm: ProcessSwitcherVM): ProcessPress =
  ## The route for a press on a process's button: resolved in the
  ## `processSwitcher` scope, a user's row first, and run on the switcher.
  let resolve = routerResolver(gpuiRouter(keymap), SessionFacts())
  result = proc(operation, target: string) =
    let outcome = resolveElementPress(resolve, ProcessSwitcherScopePath, ButtonElementKind,
                                      operation, {}, "Click")
    discard vm.runProcessSwitcherPress(outcome.operation, target)

proc processSwitcherKey*(m: AhStoryMount; name: string; keymap = UserKeymap()): string =
  ## A key while the process switcher story is shown, ROUTED in its scope
  ## (the digits; `Ctrl+Alt+PageDown` / `PageUp`). Runs the operation it
  ## resolves to and returns it ("" for none).
  if m.processes.isNil: return ""
  var router = gpuiRouter(keymap)
  let res = router.route(SessionFacts(), ProcessSwitcherScopePath, nmNormal, name, 0)
  if res.kind != erOperation or
     not m.processes.runProcessSwitcherOperation(res.operation, res.argument):
    return ""
  res.operation

let ResultsScopePath = @[element(ekWindow, "window"), pane(ResultsScope)]
  ## Where the results' keys and presses resolve.

proc resultsPresses*(keymap: UserKeymap; vm: ResultCommandsVM): ResultsPress =
  ## **THE STORY HOST'S ROUTE FOR A PRESS ON THE RESULTS**
  ## (Input-Routing-And-Keymaps.md §5.1): resolved in the `results` scope by
  ## the window's router -- a user's row for the press first, else the
  ## operation the element carries -- and run on the results' viewmodel on
  ## the element's target (`runResultsPress`).
  let resolve = routerResolver(gpuiRouter(keymap), SessionFacts())
  result = proc(operation, target: string) =
    let outcome = resolveElementPress(resolve, ResultsScopePath, ButtonElementKind,
                                      operation, {}, "Click")
    discard vm.runResultsPress(outcome.operation, target)

proc resultsKey*(m: AhStoryMount; name: string; keymap = UserKeymap()): string =
  ## A key (its canonical name) while the results are shown, ROUTED in the
  ## `results` scope: `Enter` opens, `Down` / `Up` move, `Tab` inserts.
  ## Runs the operation it resolves to and returns it ("" for none).
  if m.results.isNil: return ""
  var router = gpuiRouter(keymap)
  let res = router.route(SessionFacts(), ResultsScopePath, nmNormal, name, 0)
  if res.kind != erOperation or not m.results.runResultsOperation(res.operation):
    return ""
  res.operation

proc changesKey*(m: AhStoryMount; name: string; keymap = UserKeymap()): string =
  ## A key (its canonical name) while a Changes story is shown, ROUTED in the
  ## `changes` scope (`overlay_rows`: `Down` / `Up` the keyboard's item,
  ## `Enter` opens or closes it, `Right` / `Left` the tabs, `PageDown` /
  ## `PageUp` scroll the tab's content). Runs the operation it resolves to
  ## and returns it ("" for none, and for a scroll that did not move).
  if m.changesInbox.changes.isNil: return ""
  var router = gpuiRouter(keymap)
  let res = router.route(SessionFacts(), @[element(ekWindow, "window"), pane(ChangesPanelScope)],
                         nmNormal, name, 0)
  if res.kind != erOperation: return ""
  if res.operation in ScrollOperations:
    return (if m.changesInbox.scrollStory(res.operation): res.operation else: "")
  if not m.changesInbox.changes.runChangesOperation(res.operation): return ""
  res.operation

proc inboxKey*(m: AhStoryMount; name: string; keymap = UserKeymap()): string =
  ## A key while an Inbox or an item's page is shown, ROUTED in the `inbox`
  ## scope (`]` / `[` Next and Previous, `1`-`4` the item's priority, the
  ## arrows and the page keys scroll). Runs the operation it resolves to and
  ## returns it ("" for none, and for a scroll that did not move).
  let inbox = m.changesInbox.inbox
  let item = m.changesInbox.inboxItem
  if inbox.isNil and item.isNil: return ""
  var router = gpuiRouter(keymap)
  let res = router.route(SessionFacts(), @[element(ekWindow, "window"), pane(InboxPanelScope)],
                         nmNormal, name, 0)
  if res.kind != erOperation: return ""
  if res.operation in ScrollOperations:
    return (if m.changesInbox.scrollStory(res.operation): res.operation else: "")
  let page = if inbox.isNil: item else: inbox.page
  if not runInboxOperation(inbox, page, res.operation): return ""
  res.operation

let ActivityScopePath* = @[element(ekWindow, "window"), pane(SessionActivityScope)]
  ## Where the timeline's keys and presses resolve.

proc activityRouter(keymap: UserKeymap): KeymapRouter =
  # GPUI's three keys (`edit_arm.GpuiDelivery`): it receives keys, not bytes.
  initKeymapRouter(bkCua, KeyDelivery(frontEnd: feGpui, platform: hostPlatform(),
                                      keyProtocol: kpNative), user = keymap)

proc activityPresses*(keymap: UserKeymap; vm: SessionTimelineVM;
                      copy: proc(text: string)): ActivityPress =
  ## **THE STORY HOST'S ROUTE FOR A PRESS ON THE TIMELINE**: the press is
  ## resolved in the `sessionActivity` scope by the window's router -- a
  ## user's row for the press first, else the operation the element carries
  ## -- and the timeline runs it on the element's target
  ## (`runActivityPress`); a Copy goes to `copy`, the host's clipboard.
  let resolve = routerResolver(activityRouter(keymap), SessionFacts())
  result = proc(operation, target: string) =
    let outcome = resolveElementPress(resolve, ActivityScopePath, ButtonElementKind,
                                      operation, {}, "Click")
    discard vm.runActivityPress(outcome.operation, target, copy)

proc suggestedActivityPresses*(keymap: UserKeymap; vm: SessionTimelineVM;
                               suggestion: SuggestedActionsVM;
                               copy: proc(text: string)): ActivityPress =
  ## `activityPresses` for a timeline with a suggested-actions block at its
  ## end: a press the router resolves to one of the block's operations runs
  ## on the block (`runSuggestedActionsPress`), any other on the timeline.
  let resolve = routerResolver(activityRouter(keymap), SessionFacts())
  result = proc(operation, target: string) =
    let outcome = resolveElementPress(resolve, ActivityScopePath, ButtonElementKind,
                                      operation, {}, "Click")
    if not suggestion.runSuggestedActionsPress(outcome.operation, target):
      discard vm.runActivityPress(outcome.operation, target, copy)

proc activityKey*(m: AhStoryMount; keymap: UserKeymap; key: string): bool =
  ## A key while a timeline story is shown, ROUTED: resolved by the window's
  ## router in the `sessionActivity` scope and run on the timeline
  ## (`runActivityOperation`). False for a key that resolves to nothing the
  ## timeline does, or with no timeline.
  if m.timeline.isNil: return false
  var router = activityRouter(keymap)
  let res = router.route(SessionFacts(), ActivityScopePath, nmNormal, key, 0)
  res.kind == erOperation and m.timeline.runActivityOperation(res.operation)

proc drawFrame(r: GpuiRenderer; p: AhPalette; title: string;
               widthPx, heightPx: int): tuple[frame, body: GpuiElement] =
  ## A panel's frame as the web story frames one (a golden-layout stack):
  ## 4px in from the window's sides, a 32px header holding the panel's tab
  ## (4px down, 24px high, rounded on top, on the panel's surface, its title
  ## at 14px in the label role, then its pin and close icons at its end,
  ## 4.8px apart), then the panel body on the same surface, 8px below the
  ## tab and rounded at the bottom.
  let frame = r.box(column = true, pairs = [("width", $widthPx & "px"),
                                            ("height", $heightPx & "px"),
                                            ("padding-left", $FrameInsetPx & "px"),
                                            ("padding-right", $FrameInsetPx & "px"),
                                            ("background", p.ground)])
  let strip = r.box(pairs = [("height", $FrameTitlePx & "px"), ("flex-shrink", "0"),
                             ("items", "end")])
  r.tag(strip, "frame-header", title)
  # `.lm_tab`: 24px, 4px down in the 32px header (4 + 24 + 4); the active
  # tab's fill runs on down into its panel (its `box-shadow` bridge), so the
  # box reaches the header's foot and its contents keep to the top 24px.
  let tab = r.box(pairs = [("height", "28px"), ("flex-grow", "1"), ("items", "center"),
                           ("padding-bottom", "4px"),
                           ("padding-left", "8px"), ("padding-right", "8px"),
                           ("background", p.panel),
                           ("border-top-left-radius", $ControlRadiusPx & "px"),
                           ("border-top-right-radius", $ControlRadiusPx & "px")])
  # `.lm_title`: 14px on the face's normal line (18px), centred in the tab.
  let t = r.text(title, BodyPx, p.textLabel, pairs = [("flex-grow", "1"), ("line-height", "18px")])
  r.tag(t, "frame-title", title)
  r.appendChild(tab, t)
  # `.lm_pin_tab` (0.85em, 0.3em before the close) and `.lm_close_tab`
  # (0.6em): the active tab's icons, at full strength.
  let pin = r.framePinIcon(p)
  r.setStyle(pin, "margin-right", "4.8px")
  r.tag(pin, "frame-pin", "")
  r.appendChild(tab, pin)
  let close = r.frameCloseIcon(p)
  r.tag(close, "frame-close", "")
  r.appendChild(tab, close)
  r.appendChild(strip, tab)
  r.appendChild(frame, strip)
  let body = r.box(column = true, pairs = [("flex-grow", "1"), ("min-height", "0px"),
                                           ("overflow", "hidden"), ("padding-top", "8px"),
                                           ("background", p.panel),
                                           ("border-bottom-left-radius", $ControlRadiusPx & "px"),
                                           ("border-bottom-right-radius", $ControlRadiusPx & "px")])
  r.appendChild(frame, body)
  (frame, body)

proc mountAgentHarborStoryGpui*(r: GpuiRenderer; surface, fixture: string;
                                widthPx, heightPx: int; mode = dmDark;
                                frameTitle = ""; clock: ClockBase = nil;
                                moment = "";
                                keymap = UserKeymap()): AhStoryMount =
  ## Builds the story's viewmodel and mounts its GPUI view, `widthPx` ×
  ## `heightPx`. A `frameTitle` frames it as a panel. Raises `ValueError` for
  ## a surface with no GPUI rendering, and (from the story constructors) for
  ## a fixture the surface does not name.
  ##
  ## A playback story plays on `clock` (a `RealClock` when nil; a test or a
  ## capture passes a `TestClock`), opens at `moment` (its first frame when
  ## ""), and has the host's playback bar under it: the story is drawn
  ## `PlaybackBarPx` shorter, the bar along the bottom. A press on the bar
  ## is routed under `keymap`'s rows over the base's (`playbackPresses`).
  if not hasGpuiRendering(surface):
    raise newException(ValueError, "no GPUI rendering for the Agent Harbor surface " &
                       surface & " (story fixture " & fixture & ")")
  let p = ahPalette(mode)
  var m = AhStoryMount(surface: surface, fixture: fixture)
  var outer: GpuiElement
  var heightPx = heightPx
  if isPlaybackStory(surface, fixture):
    m.playback = newAhPlayback(surface, fixture,
                               if clock.isNil: ClockBase(newRealClock()) else: clock)
    # The window: the story above, the bar below.
    outer = r.box(column = true, pairs = [("width", $widthPx & "px"),
                                          ("height", $heightPx & "px"),
                                          ("background", p.ground)])
    heightPx = heightPx - PlaybackBarPx
  var host: GpuiElement
  if frameTitle.len > 0:
    let (frame, body) = r.drawFrame(p, frameTitle, widthPx, heightPx)
    m.root = frame
    host = r.createElement("div")
    # The panel takes the body's height (a percentage of a flex item's
    # height does not resolve in GPUI's layout; growing does).
    r.setStyle(host, "flex-grow", "1")
    r.setStyle(host, "min-height", "0px")
    r.appendChild(body, host)
  elif hasPanelUnderCaption(surface, fixture):
    # The caption bar over a panel, as in the shell: the window below the
    # bar on the panel's ground, where the bar's popup drops (the web story
    # fills the window behind its fixed caption with `.ah-story-panel-under`).
    m.root = r.box(column = true, pairs = [("width", $widthPx & "px"),
                                           ("height", $heightPx & "px"),
                                           ("background", p.panel)])
    host = r.createElement("div")
    r.appendChild(m.root, host)
  else:
    host = r.createElement("div")
    m.root = host
    if not outer.isNil:
      # The story's own area, above the bar: a column as tall as the window
      # less the bar, holding the story as the window's root holds any other
      # story, so a caption-bar story keeps its own height instead of
      # stretching to the area's.
      m.root = r.box(column = true, pairs = [("width", $widthPx & "px"),
                                             ("height", $heightPx & "px"),
                                             ("flex-shrink", "0"),
                                             ("overflow", "hidden")])
      r.appendChild(m.root, host)
  m.view = host
  let bodyW = if frameTitle.len > 0: widthPx - 2 * FrameInsetPx else: widthPx
  var rootDisposer: proc()
  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    let pb = m.playback
    case surface
    of "agent-harbor-fleet":
      m.fleet = createFleetStoryVM(fixture, pb)
      r.mountFleetPanel(host, m.fleet, p, bodyW)
    of "agent-harbor-session-tabs":
      m.sessions = createSessionTabsStoryVM(fixture, pb)
      r.mountSessionTabStrip(host, m.sessions, p, bodyW)
    of "agent-harbor-session-list":
      m.sessions = createSessionListStoryVM(fixture, pb)
      r.mountSessionList(host, m.sessions, p, bodyW)
    of "agent-harbor-initiative-tabs":
      m.initiativeTabs = createInitiativeTabsStoryVM(fixture, pb)
      r.mountInitiativeTabBar(host, m.initiativeTabs, p, bodyW)
    of "agent-harbor-initiatives":
      m.initiatives = createInitiativesStoryVM(fixture, pb)
      r.mountInitiativesPanel(host, m.initiatives, p, bodyW)
    of "agent-harbor-initiative-progress":
      m.progress = createProgressStoryVM(fixture, pb)
      r.mountProgressPanel(host, m.progress, p, bodyW)
    of "agent-harbor-composer":
      m.composer = createComposerStoryVM(fixture)
      r.mountComposer(host, m.composer, p, bodyW, heightPx,
                      composerPresses(keymap, m.composer))
    of "agent-harbor-results":
      m.results = createResultsStoryVM(fixture)
      # GPUI cannot render HTML: every rich row is drawn as its text form,
      # and the header says so (OMNI-AREQ4, P2c study D45).
      m.results.setHtmlEnabled(false)
      r.mountResults(host, m.results, p, bodyW, heightPx,
                     resultsPresses(keymap, m.results))
    of SessionActivitySurface:
      # The panel's body: the window less its frame (the header and the 8px
      # above the body) or less the playback bar.
      let bodyH = if frameTitle.len > 0: heightPx - FrameTitlePx - 8 else: heightPx
      # The clipboard is the window's (isonim-gpui `writeClipboard`;
      # `clipboardText` reads back the last text it got).
      let copy = proc(text: string) = writeClipboard(text)
      if fixture == "against-cards":
        # The timeline beside today's Agent Activity cards over the same
        # events. The cards' store is a story's own, over the mock backend:
        # nothing is replayed, the cards only read the session's entry.
        let timeline = syntheticTimeline(fixture)
        let store = createReplayDataStore(newMockBackendService().toBackendService())
        m.cards = newActivityAgainstCards(store, timeline.sessionId, timeline.events)
        m.timeline = newSessionTimelineVM(m.cards.timelineSource, timeline.sessionId)
        m.timeline.load()
        m.timeline.connection.val = connectionOf(fixture)
        let half = bodyW div 2
        let row = r.box(pairs = [("width", $bodyW & "px"), ("height", $bodyH & "px")])
        r.tag(row, "against-cards", "")
        let left = r.createElement("div")
        r.setStyle(left, "flex-shrink", "0")
        r.mountSessionActivity(left, m.timeline, p, half - 1, bodyH,
                               activityPresses(keymap, m.timeline, copy))
        r.appendChild(row, left)
        # The view the story shows is the timeline (the web's surface is its
        # `.agent-harbor-activity`); the cards half is `cardsFeed`.
        m.view = left
        r.appendChild(row, r.box(pairs = [("width", "1px"), ("height", $bodyH & "px"),
                                         ("background", p.borderPrimary),
                                         ("flex-shrink", "0")]))
        # The cards half: a caption saying these are today's cards as that
        # pane draws them (`AgainstCardsCaption`; 12px on 16px lines,
        # wrapped, 4px above and below, 8px in, as the web's
        # `.ah-against-caption`), then the cards below it.
        let halfW = bodyW - half
        let captionH = wrappedRows(AgainstCardsCaption, CaptionPx, halfW - 16) *
                       DetailLinePx + 8
        let cardsHalf = r.box(column = true, pairs = [("width", $halfW & "px"),
                                                      ("height", $bodyH & "px"),
                                                      ("flex-shrink", "0")])
        let caption = r.box(pairs = [("height", $captionH & "px"), ("flex-shrink", "0"),
                                     ("padding-left", "8px"), ("padding-right", "8px"),
                                     ("padding-top", "4px")])
        r.tag(caption, "against-caption", AgainstCardsCaption)
        r.appendChild(caption, r.text(AgainstCardsCaption, CaptionPx, p.textCaption,
                                      shrink = false,
                                      pairs = [("white-space", "pre-wrap"),
                                               ("line-height", $DetailLinePx & "px"),
                                               ("flex-shrink", "1"), ("min-width", "0px")]))
        r.appendChild(cardsHalf, caption)
        m.cardsFeed = r.box(column = true, pairs = [("width", $halfW & "px"),
                                                    ("height", $(bodyH - captionH) & "px"),
                                                    ("flex-shrink", "0")])
        r.tag(m.cardsFeed, "card-feed", "")
        discard r.drawAgentActivity(m.cardsFeed, m.cards.cards.agentFeed(),
                                    promptPlaceholder(m.cards.cards), true, false,
                                    GAgentPane(scroll: initFeedScroll()),
                                    PxRect(x: FrameInsetPx + half,
                                           y: FrameTitlePx + 8 + captionH,
                                           w: halfW, h: bodyH - captionH))
        r.appendChild(cardsHalf, m.cardsFeed)
        r.appendChild(row, cardsHalf)
        r.appendChild(host, row)
      else:
        m.timeline = createSessionActivityStoryVM(fixture, pb)
        r.mountSessionActivity(host, m.timeline, p, bodyW, bodyH,
                               activityPresses(keymap, m.timeline, copy))
    of SuggestedActionsSurface:
      let bodyH = if frameTitle.len > 0: heightPx - FrameTitlePx - 8 else: heightPx
      let copy = proc(text: string) = writeClipboard(text)
      let story = createSuggestedActionsStory(fixture)
      m.timeline = story.timeline
      m.suggestion = story.suggestion
      let press = suggestedActivityPresses(keymap, m.timeline, m.suggestion, copy)
      r.mountSessionActivity(host, m.timeline, p, bodyW, bodyH, press,
                             r.suggestionTail(p, m.suggestion, press))
    of "agent-harbor-control-center":
      m.center = createControlCenterStoryVM(fixture, pb)
      r.mountControlCenter(host, m.center, p, bodyW, heightPx,
                           controlCenterPresses(keymap, m.center))
    of "agent-harbor-status-gaze":
      m.gaze = createGazeStoryVM(fixture, gazePauseChord())
      r.mountGazeStory(host, m.gaze, p, bodyW, heightPx,
                       GazeStoryStatusItems, gazePresses(keymap, m.gaze))
    of ProcessSwitcherSurface:
      m.processes = createProcessSwitcherStoryVM(fixture)
      r.mountProcessSwitcherStory(host, m.processes, p, bodyW, heightPx, OtherTabTitle,
                                  processChord(ProcessNextOperation),
                                  processChord(ProcessPreviousOperation),
                                  RecordingSwitcherSlot,
                                  processSwitcherPresses(keymap, m.processes))
    of "agent-harbor-changes", "agent-harbor-inbox", "agent-harbor-inbox-item":
      # The panel's body: the window less its frame (the header and the 8px
      # above the body) or less the playback bar, so its regions scroll at
      # their drawn heights.
      let bodyH = if frameTitle.len > 0: heightPx - FrameTitlePx - 8 else: heightPx
      # A press on either panel is routed under `keymap`'s rows over the
      # base's, in the panel's scope (`changesPresses`, `inboxPresses`).
      m.changesInbox = r.mountChangesInboxStory(host, surface, fixture, pb, p, bodyW, bodyH,
                                                keymap)
    of PieStorySurface:
      # Static data, no viewmodel (`agent_harbor_pie_stories`).
      r.drawPieStory(host, fixture, p, bodyW, heightPx)
    else:
      raise newException(ValueError, "no GPUI rendering for the Agent Harbor surface " &
                         surface)
    if not pb.isNil:
      m.bar = r.createElement("div")
      r.mountPlaybackBar(m.bar, pb, p, widthPx, playbackPresses(keymap, pb))
  if not outer.isNil:
    r.appendChild(outer, m.root)
    r.appendChild(outer, m.bar)
    m.root = outer
    m.playback.openAtMoment(moment)
  let fleet = m.fleet
  let sessions = m.sessions
  let initiativeTabs = m.initiativeTabs
  let initiatives = m.initiatives
  let progress = m.progress
  let composer = m.composer
  let results = m.results
  let timeline = m.timeline
  let suggestion = m.suggestion
  let center = m.center
  let gaze = m.gaze
  let processes = m.processes
  let cards = m.cards
  let changesInbox = m.changesInbox
  let playback = m.playback
  m.dispose = proc() =
    if playback != nil: playback.dispose()
    if fleet != nil: fleet.dispose()
    if sessions != nil: sessions.dispose()
    if initiativeTabs != nil: initiativeTabs.dispose()
    if initiatives != nil: initiatives.dispose()
    if progress != nil: progress.dispose()
    if composer != nil: composer.dispose()
    if results != nil: results.dispose()
    if suggestion != nil: suggestion.dispose()
    if center != nil: center.dispose()
    if gaze != nil: gaze.dispose()
    if processes != nil: processes.dispose()
    if timeline != nil: timeline.dispose()
    if cards.cards != nil:
      cards.cards.dispose()
      cards.store.dispose()
    changesInbox.dispose()
    if rootDisposer != nil: rootDisposer()
  m
