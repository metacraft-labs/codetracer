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

import std/strutils

import ../../stories/agent_harbor_stories
import ../../stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories
import ./ah_tui_canvas
import ./ah_tui_session_views
import ./ah_tui_initiative_tab_bar
import ./ah_tui_initiative_panels
import ./ah_tui_fleet_panel

export agent_harbor_stories, codetracer_stories, emit_storybook_stories, ah_tui_canvas

const
  TuiAgentHarborSurfaces* = [
    "agent-harbor-fleet",
    "agent-harbor-session-tabs",
    "agent-harbor-session-list",
    "agent-harbor-initiative-tabs",
    "agent-harbor-initiatives",
    "agent-harbor-initiative-progress",
  ]
    ## Every surface of the Agent Harbor section this module draws.
  AgentHarborSectionTitle* = "CodeTracer/Agent Harbor"
  StoryIdPrefix* = "codetracer-agent-harbor--"
  TuiSizes* = [("laptop", 180, 56), ("sidebar", 45, 56)]
    ## The brief's laptop 1440×900 and sidebar 360×900, at 8×16 px a cell
    ## (`CellPx`; a row is 16 px).

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
    canvas*: AhCanvas
      ## The last `draw`.
    view*: AhNode
      ## The view's own root in it, the node carrying `surface`.

proc hasTuiRendering*(surface: string): bool = surface in TuiAgentHarborSurfaces

proc agentHarborSection*(): CodeTracerStorySection =
  for s in codeTracerStorySections():
    if s.title == AgentHarborSectionTitle: return s

proc captureIdOf*(storyId, sizeName, theme: string): string =
  ## The capture name the web and GPUI records use:
  ## `agent-harbor-<story>-<size>-<theme>`.
  "agent-harbor-" & storyId[StoryIdPrefix.len .. ^1] & "-" & sizeName & "-" & theme

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
  let h = m.rows - top
  case m.surface
  of "agent-harbor-fleet": c.drawFleetPanel(m.fleet, top, 0, m.cols, h)
  of "agent-harbor-session-tabs": c.drawSessionTabStrip(m.sessions, top, 0, m.cols)
  of "agent-harbor-session-list": c.drawSessionList(m.sessions, top, 0, m.cols, h)
  of "agent-harbor-initiative-tabs": c.drawInitiativeTabBar(m.initiativeTabs, top, 0, m.cols)
  of "agent-harbor-initiatives": c.drawInitiativesPanel(m.initiatives, top, 0, m.cols, h)
  of "agent-harbor-initiative-progress": c.drawProgressPanel(m.progress, top, 0, m.cols, h)
  else: discard
  m.view = c.root.first("surface")
  m.canvas = c

proc mountAgentHarborStoryTui*(surface, fixture: string; cols, rows: int;
                               mode = dmDark; frameTitle = ""): AhTuiMount =
  ## Builds the story's viewmodel and draws it at `cols` × `rows`. A
  ## `frameTitle` frames it as a panel. Raises `ValueError` for a surface
  ## with no terminal rendering, and (from the story constructors) for a
  ## fixture the surface does not name.
  if not hasTuiRendering(surface):
    raise newException(ValueError, "no terminal rendering for the Agent Harbor surface " &
                       surface & " (story fixture " & fixture & ")")
  result = AhTuiMount(surface: surface, fixture: fixture, cols: cols, rows: rows,
                      mode: mode, frameTitle: frameTitle)
  case surface
  of "agent-harbor-fleet": result.fleet = createFleetStoryVM(fixture)
  of "agent-harbor-session-tabs":
    result.sessions = createSessionTabsStoryVM(fixture)
    mountSessionTabStrip(result.sessions, cols)
  of "agent-harbor-session-list": result.sessions = createSessionListStoryVM(fixture)
  of "agent-harbor-initiative-tabs":
    result.initiativeTabs = createInitiativeTabsStoryVM(fixture)
    mountInitiativeTabBar(result.initiativeTabs, cols)
  of "agent-harbor-initiatives": result.initiatives = createInitiativesStoryVM(fixture)
  of "agent-harbor-initiative-progress": result.progress = createProgressStoryVM(fixture)
  else: discard
  result.draw()

proc mountStory*(story: CodeTracerStory; cols, rows: int; mode: DesignMode): AhTuiMount =
  ## `mountAgentHarborStoryTui` for a declared story, framed when it is a
  ## panel story.
  mountAgentHarborStoryTui(story.surface, story.fixture, cols, rows, mode,
                           if story.kind == "panel": frameTitleOf(story) else: "")

proc dispose*(m: AhTuiMount) =
  if m.fleet != nil: m.fleet.dispose()
  if m.sessions != nil: m.sessions.dispose()
  if m.initiativeTabs != nil: m.initiativeTabs.dispose()
  if m.initiatives != nil: m.initiatives.dispose()
  if m.progress != nil: m.progress.dispose()

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
  if not ok: return false
  if (button and 32) != 0:
    # Motion: SGR adds 32 to the button for a motion report (1003).
    result = m.canvas.pointAt(row, col)
  elif press and (button and 3) == 0:
    result = m.canvas.press(row, col)
  if result: m.draw()
