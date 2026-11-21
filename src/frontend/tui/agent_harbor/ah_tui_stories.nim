## tui/agent_harbor/ah_tui_stories.nim — CTF-P1b. A story of the
## `CodeTracer/Agent Harbor` StoryBook section, mounted in the terminal.
##
## The web mounts a story with `mountCodeTracerStory` and GPUI with
## `gpui/agent_harbor/ah_stories.mountAgentHarborStoryGpui`; this is the
## terminal's: the SAME constructors (`stories/agent_harbor_stories.nim`), so
## a terminal story shows the viewmodel state the web story shows, drawn by
## this directory's views. A panel story is framed as the web frames one —
## a header row holding the panel's title tab, the panel under it — and a
## view story is drawn bare at the screen's width.
##
## `draw` paints the whole screen afresh from the viewmodel, so a click or a
## hover that changes the viewmodel is followed by a `draw` and the screen is
## the viewmodel's again; there is no retained drawing to go stale.
##
## A playback story (`stories/agent_harbor_playback.nim`) plays on the clock
## the mount is given (IsoNim's `RealClock` in the story host, a `TestClock`
## in a test), opens at a named moment when asked, and has the host's
## playback bar on its last row (`ah_tui_playback_bar.nim`): the story is
## drawn one row shorter. Its viewmodels move under the screen as the
## playback delivers entries; `idle` says when the screen must be drawn
## again.

import std/strutils

import ../../stories/agent_harbor_stories
import ../../stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories
import ./ah_tui_canvas
import ./ah_tui_session_views
import ./ah_tui_initiative_tab_bar
import ./ah_tui_initiative_panels
import ./ah_tui_fleet_panel
import ./ah_tui_playback_bar
import ./ah_tui_composer
import ./ah_tui_pie
import ../../stories/agent_harbor_composer_stories
import ./ah_tui_results
import ../../stories/agent_harbor_results_stories
import ./ah_tui_session_activity
import ../../stories/agent_harbor_suggested_actions_stories
import ./ah_tui_control_center
import ../../stories/agent_harbor_control_center_stories
import ./ah_tui_gaze_mark
import ../../stories/agent_harbor_gaze_stories
import ../app/views/agent_activity_pane
import ../app/layout/cells
import ../../viewmodel/agent_harbor_activity_cards
import ../../viewmodel/viewmodels/agent_activity_feed
import ../../viewmodel/store/replay_data_store
import ../../viewmodel/backend/[mock_backend, backend_service]
import std/base64
import nim_everywhere/async_compat
import ../../viewmodel/input/element_press
import ../../viewmodel/keymap/[base_keymaps, context_keys, editing_keymap,
                               keymap_router, scope_path, user_keymap]
import ../../../common/key_names

export agent_harbor_stories, codetracer_stories, emit_storybook_stories, ah_tui_canvas,
  ah_tui_composer, ah_tui_results, ah_tui_control_center, ah_tui_gaze_mark

const
  TuiAgentHarborSurfaces* = [
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
    "agent-harbor-pie",
  ]
    ## Every surface of the Agent Harbor section this module draws.
  AgentHarborSectionTitle* = "CodeTracer/Agent Harbor"
  StoryIdPrefix* = "codetracer-agent-harbor--"
  TuiSizes* = [("laptop", 180, 56), ("sidebar", 45, 56)]
    ## The brief's laptop 1440×900 and sidebar 360×900, at 8×16 px a cell
    ## (`CellPx`; a row is 16 px).
  TuiPanelSize* = ("panel", 95, 40)
    ## The brief's panel 760×640: the session activity timeline is a panel,
    ## so its stories are also captured at this size (`sizesOf`).
  TuiWideSize* = ("wide", 240, 67)
    ## The brief's wide 1920×1080 (at 8×16 px a cell, 67 whole rows): the
    ## control center fills a window, so its stories are captured at a
    ## desktop monitor's size too.

proc sizesOf*(surface: string): seq[(string, int, int)] =
  ## The named sizes a story of `surface` is captured at: laptop and sidebar,
  ## panel for the session activity timeline, and panel and wide for the
  ## control center, which fills whatever window holds it.
  result = @TuiSizes
  if surface in ["agent-harbor-session-activity", "agent-harbor-suggested-actions"]:
    result.add TuiPanelSize
  if surface == "agent-harbor-control-center":
    result.add TuiPanelSize
    result.add TuiWideSize

type
  AhTuiMount* = ref object
    ## A mounted story: its viewmodel (the one field its surface uses), and
    ## the screen it draws.
    surface*, fixture*, frameTitle*: string
    cols*, rows*: int
    mode*: DesignMode
    fleet*: FleetSnapshotVM
    sessions*: SessionTabStripVM
    initiativeTabs*: InitiativeTabStripVM
    initiatives*: InitiativesVM
    progress*: InitiativeProgressVM
    composer*: OmniboxComposerVM
    results*: ResultCommandsVM
    timeline*: SessionTimelineVM
    suggestion*: SuggestedActionsVM
      ## The suggested-actions block at the timeline's end (its stories
      ## only).
    center*: ControlCenterVM
      ## The control center (its stories only).
    gaze*: GazeStatusVM
      ## The status line's gaze mark (its stories only).
    cards*: ActivityAgainstCards
      ## The comparison story's cards (`agent_harbor_activity_cards`); unset
      ## for any other story.
    copied*: string
      ## The last text a timeline's Copy handed the clipboard.
    output*: string
      ## Bytes for the terminal that the host writes after a draw (a Copy's
      ## OSC 52, https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands).
    playback*: AhPlayback
      ## A playback story's playback (nil for any other story).
    drawnAt: int
      ## `playback.changed` when the screen was last drawn.
    canvas*: AhCanvas
      ## The last `draw`.
    router*: KeymapRouter
      ## The story host's router: the base keymap, a user's rows over it. A
      ## playback control's key and a press on its button resolve here.
    lastOperation*: string
      ## The operation the last routed key or press resolved to ("" for
      ## none), whether or not this host performs it.
    view*: AhNode
      ## The view's own root in it, the node carrying `surface`.

proc hasTuiRendering*(surface: string): bool = surface in TuiAgentHarborSurfaces

proc agentHarborSection*(): CodeTracerStorySection =
  for s in codeTracerStorySections():
    if s.title == AgentHarborSectionTitle: return s

proc captureIdOf*(storyId, sizeName, theme: string; moment = ""): string =
  ## The capture name the web and GPUI records use:
  ## `agent-harbor-<story>-<size>-<theme>`, and for a playback story opened
  ## at a named moment `agent-harbor-<story>-at-<moment>-<size>-<theme>` (the
  ## CTF-P1c moment captures' names, `capture-storybook.mjs --moments` and
  ## `ci/test/ctf_p1b_gpui_story_capture.nim`).
  "agent-harbor-" & storyId[StoryIdPrefix.len .. ^1] &
    (if moment.len > 0: "-at-" & moment else: "") & "-" & sizeName & "-" & theme

proc findStory*(id: string): CodeTracerStory =
  ## The story whose StoryBook id is `id`; raises `KeyError` for none.
  let section = agentHarborSection()
  for story in section.stories:
    if storybookId(section, story) == id: return story
  raise newException(KeyError, "no Agent Harbor story " & id)

const PinGlyph* = "\xE2\x9A\xB2"
  ## ⚲ (U+26B2): the panel tab's pin (dock to an edge). The web draws the
  ## app's pin icon there; a terminal has no picture, and this narrow glyph
  ## — a round head on a stem — is the nearest a monospace font holds.

const
  TerminalDelivery = KeyDelivery(frontEnd: feTerminal, platform: hostPlatform(),
                                 keyProtocol: kpLegacy)
    ## The story host reads its keys as bytes (`key_names.keyName`).

let PlaybackScopePath = @[element(ekWindow, "window"), pane(StoryPlaybackScope)]
  ## Where the playback chrome's keys and presses resolve.
let ActivityScopePath = @[element(ekWindow, "window"), pane(SessionActivityScope)]
  ## Where the timeline's keys and presses resolve.

proc draw*(m: AhTuiMount)

proc pressPlayback*(m: AhTuiMount; operation: string): bool {.discardable.} =
  ## **A PRESS ON A PLAYBACK BUTTON** (Input-Routing-And-Keymaps.md §5.1),
  ## from its target (the hit test): resolved by the story host's router in
  ## the `storyPlayback` scope — a user's row for the press first — else the
  ## operation the button carries. A playback operation runs, and the screen
  ## is drawn again; any other is inert here.
  if m.isNil or m.playback.isNil: return false
  let outcome = resolveElementPress(routerResolver(m.router, SessionFacts()),
                                    PlaybackScopePath,
                                    ButtonElementKind, operation, {}, "Click")
  m.lastOperation = outcome.operation
  if not m.playback.performPlaybackOperation(outcome.operation):
    return false
  m.draw()
  true

let ComposerScopePath = @[element(ekWindow, "window"), pane(ComposerScope)]
  ## Where the composer's keys and presses resolve.

proc pressComposer*(m: AhTuiMount; operation, target: string): bool {.discardable.} =
  ## **A PRESS ON A COMPOSER ELEMENT** (Input-Routing-And-Keymaps.md §5.1),
  ## from its target (the hit test): resolved by the story host's router in
  ## the `composer` scope — a user's row for the press first — else the
  ## operation the element carries, run on the composer's viewmodel on the
  ## element's target; the screen is drawn again.
  if m.isNil or m.composer.isNil: return false
  let outcome = resolveElementPress(routerResolver(m.router, SessionFacts()),
                                    ComposerScopePath, ButtonElementKind,
                                    operation, {}, "Click")
  m.lastOperation = outcome.operation
  if not m.composer.runComposerPress(outcome.operation, target): return false
  m.draw()
  true

proc composerKey*(m: AhTuiMount; token: string): bool =
  ## A key while the composer is shown, ROUTED (Input-Routing-And-Keymaps.md
  ## §4): decoded by the terminal's byte decoder and resolved in the
  ## `composer` scope (`Enter` sends, `Down` / `Up` move the destination). A
  ## key that resolves to a composer operation runs it, and the screen is
  ## drawn again.
  if m.composer.isNil: return false
  let name = keyName(token)
  if name.len == 0: return false
  let res = m.router.route(SessionFacts(), ComposerScopePath, nmNormal, name, 0)
  m.lastOperation = if res.kind == erOperation: res.operation else: ""
  if res.kind != erOperation or not m.composer.runComposerOperation(res.operation):
    return false
  m.draw()
  true

let ControlCenterScopePath = @[element(ekWindow, "window"), pane(ControlCenterScope)]
  ## Where the control center's keys and presses resolve.
let ControlCenterFormScopePath = @[element(ekWindow, "window"), pane(ControlCenterScope),
                                   pane(ComposerScope)]
  ## Where a press on its launch form (the composer's) resolves.

proc pressControlCenter*(m: AhTuiMount; operation, target: string): bool {.discardable.} =
  ## **A PRESS ON THE CONTROL CENTER** (Input-Routing-And-Keymaps.md §5.1):
  ## resolved by the story host's router in the scope the element is in (its
  ## launch form's in the composer's) -- a user's row for the press first --
  ## else the operation the element carries, run on the control center on
  ## the element's target; drawn again.
  if m.isNil or m.center.isNil: return false
  let path = if operation in ComposerPressOperations: ControlCenterFormScopePath
             else: ControlCenterScopePath
  let outcome = resolveElementPress(routerResolver(m.router, SessionFacts()), path,
                                    ButtonElementKind, operation, {}, "Click")
  m.lastOperation = outcome.operation
  if not m.center.runControlCenterPress(outcome.operation, target): return false
  m.draw()
  true

proc controlCenterKey*(m: AhTuiMount; token: string): bool =
  ## A key while the control center is shown, ROUTED in its scope (`Down` /
  ## `Up` walk the waiting sessions, `Enter` opens one); drawn again when it
  ## ran one of its operations.
  if m.center.isNil: return false
  let name = keyName(token)
  if name.len == 0: return false
  let res = m.router.route(SessionFacts(), ControlCenterScopePath, nmNormal, name, 0)
  m.lastOperation = if res.kind == erOperation: res.operation else: ""
  if res.kind != erOperation or not m.center.runControlCenterOperation(res.operation):
    return false
  m.draw()
  true

let WindowScopePath = @[element(ekWindow, "window")]
  ## Where a window-level key (the gaze pause key) resolves.

proc pressGaze*(m: AhTuiMount; operation: string): bool {.discardable.} =
  ## A press on the gaze mark, resolved at the window's scope; drawn again.
  if m.isNil or m.gaze.isNil: return false
  let outcome = resolveElementPress(routerResolver(m.router, SessionFacts()),
                                    WindowScopePath, ButtonElementKind, operation, {},
                                    "Click")
  m.lastOperation = outcome.operation
  if not m.gaze.runGazeOperation(outcome.operation): return false
  m.draw()
  true

proc gazeKey*(m: AhTuiMount; token: string): bool =
  ## A key while the gaze story is shown, ROUTED at the window's scope (the
  ## pause key); drawn again when it moved the mark.
  if m.gaze.isNil: return false
  let name = keyName(token)
  if name.len == 0: return false
  let res = m.router.route(SessionFacts(), WindowScopePath, nmNormal, name, 0)
  m.lastOperation = if res.kind == erOperation: res.operation else: ""
  if res.kind != erOperation or not m.gaze.runGazeOperation(res.operation): return false
  m.draw()
  true

let ResultsScopePath = @[element(ekWindow, "window"), pane(ResultsScope)]
  ## Where the results' keys and presses resolve.

proc pressResults*(m: AhTuiMount; operation, target: string): bool {.discardable.} =
  ## **A PRESS ON A RESULTS ELEMENT** (Input-Routing-And-Keymaps.md §5.1):
  ## resolved by the story host's router in the `results` scope -- a user's
  ## row for the press first -- else the operation the element carries, run
  ## on the results' viewmodel on the element's target; drawn again.
  if m.isNil or m.results.isNil: return false
  let outcome = resolveElementPress(routerResolver(m.router, SessionFacts()),
                                    ResultsScopePath, ButtonElementKind,
                                    operation, {}, "Click")
  m.lastOperation = outcome.operation
  if not m.results.runResultsPress(outcome.operation, target): return false
  m.draw()
  true

proc resultsKey*(m: AhTuiMount; token: string): bool =
  ## A key while the results are shown, ROUTED in the `results` scope
  ## (`Enter` opens, `Down` / `Up` move, `Tab` inserts); drawn again when it
  ## ran a results operation.
  if m.results.isNil: return false
  let name = keyName(token)
  if name.len == 0: return false
  let res = m.router.route(SessionFacts(), ResultsScopePath, nmNormal, name, 0)
  m.lastOperation = if res.kind == erOperation: res.operation else: ""
  if res.kind != erOperation or not m.results.runResultsOperation(res.operation):
    return false
  m.draw()
  true

proc cardInk(p: AhPalette; style: AgentFeedSpanStyle): string =
  ## A card's span in the palette's ink for its style, as the GPUI pane
  ## colours them (`gpui/agent_activity_leaf.colourOf`).
  case style
  of fsMuted: p.textCaption
  of fsError, fsRemoved: p.textError
  of fsAdded: p.textSuccess
  of fsCode: p.iconInfo
  of fsHeading, fsButton: p.textLabel
  else: p.textBody

proc copyText*(m: AhTuiMount; text: string) =
  ## The story host's clipboard: the terminal's, through OSC 52
  ## (`ESC ] 52 ; c ; <base64> BEL`), and the text it got.
  m.copied = text
  m.output.add "\e]52;c;" & encode(text) & "\a"

proc pressActivity*(m: AhTuiMount; operation, target: string): bool {.discardable.} =
  ## **A PRESS ON THE TIMELINE**, from its target (the hit test): resolved
  ## by the story host's router in the `sessionActivity` scope -- a user's
  ## row for the press first -- else the operation the element carries, and
  ## run on the element's target (`runActivityPress`, the host's clipboard
  ## for a Copy). The screen is drawn again by the caller.
  if m.isNil or m.timeline.isNil: return false
  let outcome = resolveElementPress(routerResolver(m.router, SessionFacts()),
                                    ActivityScopePath,
                                    ButtonElementKind, operation, {}, "Click")
  m.lastOperation = outcome.operation
  if m.suggestion.runSuggestedActionsPress(outcome.operation, target): return true
  let mount = m
  m.timeline.runActivityPress(outcome.operation, target,
                              proc(text: string) = mount.copyText(text))

proc drawFrame(c: var AhCanvas; title: string): int =
  ## The panel's frame header: the window's ground with the panel's tab at
  ## its start, on the panel's own ground (the active tab runs into its
  ## panel, as golden-layout draws it), its title in the label role and the
  ## app's tab controls at its end: the pin, then the close, in the tab
  ## icon role. Returns the rows it takes.
  c.area("frame-header", 0, 0, c.cols, 1, c.tone.frame)
  let header = c.node(nil, 0, 0, c.cols, 1, [("frame-header", title)])
  let w = min(c.cols, widthOf(title) + 8)
  # The tab is an area of its own: the panel's ground, between the
  # header's and the panel head's.
  c.area("frame-tab", 0, 0, w, 1, c.p.panel)
  discard c.text(header, 0, 1, w - 7, title, c.p.textLabel, fact = "frame-title")
  discard c.put(0, w - 5, PinGlyph, c.p.tabIcon)
  discard c.node(header, 0, w - 5, 1, 1, [("frame-pin", "")])
  discard c.put(0, w - 3, "\xE2\x9C\x95", c.p.tabIcon)
  discard c.node(header, 0, w - 3, 1, 1, [("frame-close", "")])
  1

proc draw*(m: AhTuiMount) =
  ## The whole screen, from the viewmodel as it is now.
  var c = newAhCanvas(m.cols, m.rows, ahPalette(m.mode))
  c.area("window", 0, 0, m.cols, m.rows, c.tone.frame)
  var top = 0
  if m.frameTitle.len > 0: top = c.drawFrame(m.frameTitle)
  if hasPanelUnderCaption(m.surface, m.fixture):
    # The caption bar over a panel, as in the shell: the window under the
    # bar is the panel's (the bar paints its own rows), where its popup drops.
    c.area("panel", top, 0, m.cols, m.rows - top, c.tone.body)
  # A playback story leaves its last row to the host's playback bar.
  let storyRows = if m.playback.isNil: m.rows else: m.rows - 1
  let h = storyRows - top
  case m.surface
  of "agent-harbor-fleet": c.drawFleetPanel(m.fleet, top, 0, m.cols, h)
  of "agent-harbor-session-tabs": c.drawSessionTabStrip(m.sessions, top, 0, m.cols)
  of "agent-harbor-session-list": c.drawSessionList(m.sessions, top, 0, m.cols, h)
  of "agent-harbor-initiative-tabs": c.drawInitiativeTabBar(m.initiativeTabs, top, 0, m.cols)
  of "agent-harbor-initiatives": c.drawInitiativesPanel(m.initiatives, top, 0, m.cols, h)
  of "agent-harbor-initiative-progress": c.drawProgressPanel(m.progress, top, 0, m.cols, h)
  of "agent-harbor-composer":
    c.drawComposer(m.composer, top, 0, m.cols, h, (proc(operation, target: string) =
      discard m.pressComposer(operation, target)))
  of "agent-harbor-results":
    c.drawResults(m.results, top, 0, m.cols, h, (proc(operation, target: string) =
      discard m.pressResults(operation, target)))
  of "agent-harbor-suggested-actions":
    let mount = m
    let press: ActivityPress = proc(operation, target: string) =
      discard mount.pressActivity(operation, target)
    c.drawSessionActivity(m.timeline, top, 0, m.cols, h, press, m.suggestion)
  of "agent-harbor-control-center":
    let mount = m
    c.drawControlCenter(m.center, top, 0, m.cols, h, proc(operation, target: string) =
      discard mount.pressControlCenter(operation, target))
  of "agent-harbor-status-gaze":
    let mount = m
    c.drawGazeStory(m.gaze, top, 0, m.cols, h, GazeStoryStatusItemsTui, proc(operation: string) =
      discard mount.pressGaze(operation))
  of PieStorySurface: c.drawPieStory(m.fixture, top, 0, m.cols, h)
  of "agent-harbor-session-activity":
    let mount = m
    let press: ActivityPress = proc(operation, target: string) =
      discard mount.pressActivity(operation, target)
    if m.cards.cards.isNil:
      c.drawSessionActivity(m.timeline, top, 0, m.cols, h, press)
    else:
      # The comparison story: the timeline on the left half, today's Agent
      # Activity cards on the right -- the rows the production pane draws
      # (`agent_activity_feed`, laid out by `app/views/agent_activity_pane`'s
      # `layoutAgent`), each span in the palette's ink for its style -- and
      # a column on the raised ground between them (a step off the window,
      # the head band and the panel).
      let half = m.cols div 2
      c.drawSessionActivity(m.timeline, top, 0, half - 1, h, press)
      c.area("against-gap", top, half - 1, 1, h, c.tone.filters)
      c.area("card-feed", top, half, m.cols - half, h, c.tone.body)
      let cards = m.cards.cards
      # The caption over the cards half (`AgainstCardsCaption`): today's
      # cards as that pane draws them, wrapped in the caption's ink.
      let captionLines = wrapCells(AgainstCardsCaption, m.cols - half - 2)
      for k, line in captionLines:
        discard c.put(top + k, half + 1, line, c.p.textCaption)
      discard c.node(c.root, top, half, m.cols - half, captionLines.len,
                     [("against-caption", AgainstCardsCaption)])
      let area = CellArea(col: half + 1, row: top + captionLines.len,
                          width: m.cols - half - 2, height: h - captionLines.len)
      let screen = layoutAgent(AgentPaneModel(loaded: true, rows: cards.agentFeed(),
        prompt: promptPlaceholder(cards), promptIsPlaceholder: true,
        scroll: initFeedScroll()), area)
      for k in 0 ..< screen.listRows:
        let i = screen.top + k
        if i >= screen.lines.len: break
        var col = area.col
        for span in screen.lines[i].spans:
          let room = area.col + screen.width - col
          if room <= 0: break
          col += c.put(screen.listTop + k, col, elide(span.text, room), cardInk(c.p, span.style),
                       span.style in {fsBold, fsBoldItalic, fsHeading, fsButton})
      discard c.put(screen.promptRow, area.col,
                    elide("\xE2\x80\xBA " & promptPlaceholder(cards), area.width), c.p.textCaption)
      discard c.node(c.root, top, half, m.cols - half, h,
                     [("card-feed", $min(screen.lines.len, screen.listRows))])
  else: discard
  if not m.playback.isNil:
    c.drawPlaybackBar(m.playback, m.rows - 1, (proc(operation: string) =
      m.pressPlayback(operation)), routerKeyOf(m.router))
    m.drawnAt = m.playback.changed.val
  m.view = c.root.first("surface")
  m.canvas = c

proc mountAgentHarborStoryTui*(surface, fixture: string; cols, rows: int;
                               mode = dmDark; frameTitle = ""; clock: ClockBase = nil;
                               moment = ""; keymap = UserKeymap()): AhTuiMount =
  ## Builds the story's viewmodel and draws it at `cols` × `rows`. A
  ## `frameTitle` frames it as a panel. Raises `ValueError` for a surface
  ## with no terminal rendering, and (from the story constructors) for a
  ## fixture the surface does not name. A playback story plays on `clock`
  ## (a `RealClock` when nil) and opens at `moment` (its first frame when
  ## ""; an unknown name raises `ValueError` naming the moments).
  if not hasTuiRendering(surface):
    raise newException(ValueError, "no terminal rendering for the Agent Harbor surface " &
                       surface & " (story fixture " & fixture & ")")
  result = AhTuiMount(surface: surface, fixture: fixture, cols: cols, rows: rows,
                      mode: mode, frameTitle: frameTitle,
                      router: initKeymapRouter(bkCua, TerminalDelivery, user = keymap))
  if isPlaybackStory(surface, fixture):
    result.playback = newAhPlayback(surface, fixture,
                                    if clock.isNil: ClockBase(newRealClock()) else: clock)
  let pb = result.playback
  case surface
  of "agent-harbor-fleet": result.fleet = createFleetStoryVM(fixture, pb)
  of "agent-harbor-session-tabs":
    result.sessions = createSessionTabsStoryVM(fixture, pb)
    mountSessionTabStrip(result.sessions, cols)
  of "agent-harbor-session-list": result.sessions = createSessionListStoryVM(fixture, pb)
  of "agent-harbor-initiative-tabs":
    result.initiativeTabs = createInitiativeTabsStoryVM(fixture, pb)
    mountInitiativeTabBar(result.initiativeTabs, cols)
  of "agent-harbor-initiatives": result.initiatives = createInitiativesStoryVM(fixture, pb)
  of "agent-harbor-initiative-progress": result.progress = createProgressStoryVM(fixture, pb)
  of "agent-harbor-composer": result.composer = createComposerStoryVM(fixture)
  of "agent-harbor-results":
    result.results = createResultsStoryVM(fixture)
    # A terminal cannot render HTML: every rich row is drawn as its text
    # form, and the header says so (OMNI-AREQ4, P2c study D45).
    result.results.setHtmlEnabled(false)
  of "agent-harbor-session-activity":
    if fixture == "against-cards":
      # The cards' store is the story's own, over the mock backend: nothing
      # is replayed, the cards only read the session's entry.
      let timeline = syntheticTimeline(fixture)
      let store = createReplayDataStore(newMockBackendService().toBackendService())
      result.cards = newActivityAgainstCards(store, timeline.sessionId, timeline.events)
      result.timeline = newSessionTimelineVM(result.cards.timelineSource, timeline.sessionId)
      result.timeline.load()
      result.timeline.connection.val = connectionOf(fixture)
    else:
      result.timeline = createSessionActivityStoryVM(fixture, pb)
  of "agent-harbor-suggested-actions":
    let story = createSuggestedActionsStory(fixture)
    result.timeline = story.timeline
    result.suggestion = story.suggestion
  of "agent-harbor-control-center": result.center = createControlCenterStoryVM(fixture, pb)
  of "agent-harbor-status-gaze": result.gaze = createGazeStoryVM(fixture, gazePauseChord())
  else: discard
  if not pb.isNil: pb.openAtMoment(moment)
  result.draw()

proc mountStory*(story: CodeTracerStory; cols, rows: int; mode: DesignMode;
                 clock: ClockBase = nil; moment = "";
                 keymap = UserKeymap()): AhTuiMount =
  ## `mountAgentHarborStoryTui` for a declared story, framed when it is a
  ## panel story.
  mountAgentHarborStoryTui(story.surface, story.fixture, cols, rows, mode,
                           if story.kind == "panel": frameTitleOf(story) else: "",
                           clock, moment, keymap)

proc idle*(m: AhTuiMount): bool =
  ## Between inputs: a playback story's real clock fires its due timers
  ## (through the platform's event loop, which the story host polls only
  ## here), and the screen is drawn again when the playback moved since the
  ## last `draw`. True when it was.
  if m.isNil or m.playback.isNil: return false
  drainPlatformCallbacks()
  if m.playback.changed.val != m.drawnAt:
    m.draw()
    return true
  false

proc playbackKey*(m: AhTuiMount; token: string): bool =
  ## A key while a playback story is shown, ROUTED (Input-Routing-And-Keymaps.md
  ## §4): decoded to its canonical name (`key_names.keyName`, the terminal's
  ## byte decoder) and resolved by the story host's router in the
  ## `storyPlayback` scope — the base's rows for the controls (`overlay_rows`:
  ## space, `n`, `[`, `]`, `0`), a user's over them. A key that resolves to a
  ## playback operation runs it, and the screen is drawn again (true), whether
  ## or not it moved the playback, so a reader waiting for the next frame
  ## always gets one.
  if m.playback.isNil: return false
  let name = keyName(token)
  if name.len == 0: return false
  let res = m.router.route(SessionFacts(), PlaybackScopePath, nmNormal, name, 0)
  m.lastOperation = if res.kind == erOperation: res.operation else: ""
  if res.kind != erOperation or not m.playback.performPlaybackOperation(res.operation):
    return false
  m.draw()
  true

proc activityKey*(m: AhTuiMount; token: string): bool =
  ## A key while a timeline story is shown, ROUTED: decoded to its canonical
  ## name (`key_names.keyName`) and resolved by the story host's router in
  ## the `sessionActivity` scope (`overlay_rows`' `pane:sessionActivity`:
  ## Right, Left, Enter, `+`, `-`, Down, Up; a user's rows over them). A key that resolves to one of the timeline's operations
  ## runs it on the timeline, and the screen is drawn again (true).
  if m.timeline.isNil: return false
  let name = keyName(token)
  if name.len == 0: return false
  let res = m.router.route(SessionFacts(), ActivityScopePath, nmNormal, name, 0)
  m.lastOperation = if res.kind == erOperation: res.operation else: ""
  if res.kind != erOperation or not m.timeline.runActivityOperation(res.operation):
    return false
  m.draw()
  true

proc dispose*(m: AhTuiMount) =
  if m.timeline != nil: m.timeline.dispose()
  if m.cards.cards != nil:
    m.cards.cards.dispose()
    m.cards.store.dispose()
  if m.playback != nil: m.playback.dispose()
  if m.fleet != nil: m.fleet.dispose()
  if m.sessions != nil: m.sessions.dispose()
  if m.initiativeTabs != nil: m.initiativeTabs.dispose()
  if m.initiatives != nil: m.initiatives.dispose()
  if m.progress != nil: m.progress.dispose()
  if m.composer != nil: m.composer.dispose()
  if m.results != nil: m.results.dispose()
  if m.suggestion != nil: m.suggestion.dispose()
  if m.center != nil: m.center.dispose()
  if m.gaze != nil: m.gaze.dispose()

proc rowsOf*(m: AhTuiMount): seq[StyledRow] =
  ## The screen as styled rows, for `styledRowsTree`.
  for r in 0 ..< m.rows: result.add m.canvas.grid.rowSpans(r)

proc decodeSgrMouse*(token: string): tuple[ok: bool; button, row, col: int; press: bool] =
  ## An SGR-1006 report, `ESC [ < b ; x ; y (M|m)`
  ## (https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Extended-coordinates),
  ## as 0-based row and column.
  if token.len < 9 or not token.startsWith("\x1b[<"): return
  let final = token[^1]
  if final notin {'M', 'm'}: return
  let parts = token[3 ..< token.len - 1].split(';')
  if parts.len != 3: return
  try:
    result = (true, parseInt(parts[0]), parseInt(parts[2]) - 1, parseInt(parts[1]) - 1,
              final == 'M')
  except ValueError:
    result.ok = false

proc handleInput*(m: AhTuiMount; token: string): bool =
  ## A press acts on what is under it; motion moves the hover. True when the
  ## screen must be drawn again.
  let (ok, button, row, col, press) = decodeSgrMouse(token)
  if not ok: return m.playbackKey(token) or m.activityKey(token) or m.composerKey(token) or
                    m.resultsKey(token) or m.controlCenterKey(token) or m.gazeKey(token)
  if (button and 32) != 0:
    # Motion: SGR adds 32 to the button for a motion report (1003).
    result = m.canvas.pointAt(row, col)
  elif press and (button and 3) == 0:
    result = m.canvas.press(row, col)
  if result: m.draw()
