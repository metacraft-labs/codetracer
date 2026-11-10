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

export agent_harbor_stories, ah_theme

const
  GpuiAgentHarborSurfaces* = [
    "agent-harbor-fleet",
    "agent-harbor-session-tabs",
    "agent-harbor-session-list",
    "agent-harbor-initiative-tabs",
    "agent-harbor-initiatives",
    "agent-harbor-initiative-progress",
  ]
    ## Every surface of the Agent Harbor section this module draws.
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
    dispose*: proc()

proc hasGpuiRendering*(surface: string): bool =
  surface in GpuiAgentHarborSurfaces

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
                                frameTitle = ""): AhStoryMount =
  ## Builds the story's viewmodel and mounts its GPUI view, `widthPx` ×
  ## `heightPx`. A `frameTitle` frames it as a panel. Raises `ValueError` for
  ## a surface with no GPUI rendering, and (from the story constructors) for
  ## a fixture the surface does not name.
  if not hasGpuiRendering(surface):
    raise newException(ValueError, "no GPUI rendering for the Agent Harbor surface " &
                       surface & " (story fixture " & fixture & ")")
  let p = ahPalette(mode)
  var m = AhStoryMount(surface: surface, fixture: fixture)
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
  m.view = host
  let bodyW = if frameTitle.len > 0: widthPx - 2 * FrameInsetPx else: widthPx
  var rootDisposer: proc()
  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    case surface
    of "agent-harbor-fleet":
      m.fleet = createFleetStoryVM(fixture)
      r.mountFleetPanel(host, m.fleet, p, bodyW)
    of "agent-harbor-session-tabs":
      m.sessions = createSessionTabsStoryVM(fixture)
      r.mountSessionTabStrip(host, m.sessions, p, bodyW)
    of "agent-harbor-session-list":
      m.sessions = createSessionListStoryVM(fixture)
      r.mountSessionList(host, m.sessions, p, bodyW)
    of "agent-harbor-initiative-tabs":
      m.initiativeTabs = createInitiativeTabsStoryVM(fixture)
      r.mountInitiativeTabBar(host, m.initiativeTabs, p, bodyW)
    of "agent-harbor-initiatives":
      m.initiatives = createInitiativesStoryVM(fixture)
      r.mountInitiativesPanel(host, m.initiatives, p, bodyW)
    of "agent-harbor-initiative-progress":
      m.progress = createProgressStoryVM(fixture)
      r.mountProgressPanel(host, m.progress, p, bodyW)
    else:
      raise newException(ValueError, "no GPUI rendering for the Agent Harbor surface " &
                         surface)
  let fleet = m.fleet
  let sessions = m.sessions
  let initiativeTabs = m.initiativeTabs
  let initiatives = m.initiatives
  let progress = m.progress
  m.dispose = proc() =
    if fleet != nil: fleet.dispose()
    if sessions != nil: sessions.dispose()
    if initiativeTabs != nil: initiativeTabs.dispose()
    if initiatives != nil: initiatives.dispose()
    if progress != nil: progress.dispose()
    if rootDisposer != nil: rootDisposer()
  m
