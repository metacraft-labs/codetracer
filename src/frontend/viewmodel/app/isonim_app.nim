## viewmodel/app/isonim_app.nim
##
## IsoNim application shell for CodeTracer.
##
## This module provides the primary IsoNim rendering entry point that
## coexists with the Karax layout manager. It renders all panels from
## SessionViewModel signals into a dedicated `#isonim-app` container div,
## which is visible by default. Disable via:
##
##   - URL parameter: `?karax=1` (opt-out, falls back to legacy Karax rendering)
##
## Architecture:
##
##   Same-process fast path (Electron renderer):
##     The IsoNim app reads directly from the SessionViewModel signals —
##     no mirroring or message bus needed. Both the ViewModel and the
##     IsoNim Views live in the same renderer process.
##
##   Cross-process path (VS Code / multi-window, future):
##     A mirror SessionViewModel is created from a message bus, and the
##     same `createIsoNimApp` proc is called with the mirror. The View
##     code is identical — it does not know whether it reads from the
##     primary or mirror signals.
##
## Usage:
##   # In ui_js.nim configureMiddleware, after creating activeSessionVM:
##   import viewmodel/app/isonim_app
##   mountIsoNimApp(activeSessionVM)

when not defined(js):
  {.error: "isonim_app requires the JS backend".}

import isonim/web/dom_api as isonim_dom
import isonim/web/web_renderer
import isonim/dsl/ui
import isonim/core/computation  # createRenderEffect — emitted by the DSL

import ../session_vm

# Import all IsoNim view mount procs.
# Each view reads from its corresponding ViewModel's signals and renders
# into the DOM container it is given. Reactive effects handle all
# subsequent updates — no manual redraw loop is needed.
import ../views/[
  isonim_debug_controls_view,
  isonim_state_view,
  isonim_calltrace_view,
  isonim_event_log_view,
  isonim_flow_view,
  isonim_editor_view,
  isonim_timeline_view,
  isonim_search_view,
  isonim_point_list_view,
  isonim_scratchpad_view,
  isonim_shell_view,
]

type
  IsoNimApp* = ref object
    ## The IsoNim application instance.
    ##
    ## Holds references to the root DOM element and the SessionViewModel
    ## so that the app can be disposed or reconfigured later (e.g. when
    ## switching sessions in a multi-session UI).
    root*: isonim_dom.Element
    session*: SessionViewModel

# ---------------------------------------------------------------------------
# Panel section helper
# ---------------------------------------------------------------------------

proc addPanelSection(r: WebRenderer; parent: isonim_dom.Element;
                     panelId: string; title: string): isonim_dom.Element =
  ## Create a collapsible section wrapper for a panel.
  ##
  ## Structure:
  ##   <div class="isonim-panel-section" id="isonim-section-{panelId}">
  ##     <h3 class="isonim-section-header">{title}</h3>
  ##     <div class="isonim-section-content">
  ##       <!-- panel content mounted here -->
  ##     </div>
  ##   </div>
  ##
  ## Returns the inner content div so the caller can mount the panel into it.
  var content: isonim_dom.Element
  let section = ui(r):
    tdiv(class = "isonim-panel-section",
         id = "isonim-section-" & panelId):
      h3(class = "isonim-section-header"):
        text title
      tdiv(ref = content, class = "isonim-section-content"):
        discard
  r.appendChild(parent, section)
  content

# ---------------------------------------------------------------------------
# App creation
# ---------------------------------------------------------------------------

proc createIsoNimApp*(session: SessionViewModel): IsoNimApp =
  ## Create the IsoNim application, rendering all panels from the given
  ## SessionViewModel's signals.
  ##
  ## The `#isonim-app` div must exist in the HTML. If it is missing (e.g.
  ## running in a context where IsoNim is not enabled), this proc returns
  ## nil and does nothing.
  ##
  ## Each panel is mounted into its own section wrapper. The layout is a
  ## simple vertical stack for now — GoldenLayout integration comes later.
  ## The panels read directly from the SessionViewModel's signals (the
  ## same-process fast path), so all updates are automatic.
  let root = isonim_dom.document.getElementById(cstring"isonim-app")
  if isonim_dom.isNodeNil(isonim_dom.Node(root)):
    return nil

  let r = WebRenderer()

  # App header — identifies this as the IsoNim rendering surface
  let appHeader = ui(r):
    tdiv(class = "isonim-app-header"):
      text "IsoNim Rendering (experimental)"
  r.appendChild(root, appHeader)

  # Debug controls are mounted separately into `#isonim-debug-controls`
  # (defined in index.html) by `tryMountIsoNimDebugControls` in debug.nim.
  # Do NOT mount them here — that would create duplicate elements with the
  # same IDs (e.g. `#next-debug`), breaking Playwright locators.

  # --- State (Locals / Globals / Watches) ---
  let stateSection = addPanelSection(r, root, "state", "State")
  mountIsoNimStatePanel(stateSection, session.stateVM)

  # --- Calltrace ---
  let calltraceSection = addPanelSection(r, root, "calltrace", "Calltrace")
  mountIsoNimCalltrace(calltraceSection, session.calltraceVM)

  # --- Event Log ---
  let eventLogSection = addPanelSection(r, root, "event-log", "Event Log")
  mountIsoNimEventLog(eventLogSection, session.eventLogVM)

  # --- Flow ---
  let flowSection = addPanelSection(r, root, "flow", "Flow")
  mountIsoNimFlow(flowSection, session.flowVM)

  # --- Timeline ---
  let timelineSection = addPanelSection(r, root, "timeline", "Timeline")
  mountIsoNimTimeline(timelineSection, session.timelineVM)

  # --- Search ---
  let searchSection = addPanelSection(r, root, "search", "Search")
  mountIsoNimSearch(searchSection, session.searchVM)

  # --- Point List ---
  let pointListSection = addPanelSection(r, root, "point-list", "Point List")
  mountIsoNimPointList(pointListSection, session.pointListVM)

  # --- Scratchpad ---
  let scratchpadSection = addPanelSection(r, root, "scratchpad", "Scratchpad")
  mountIsoNimScratchpadPanel(scratchpadSection, session.scratchpadVM)

  # --- Shell ---
  let shellSection = addPanelSection(r, root, "shell", "Shell")
  mountIsoNimShell(shellSection, session.shellVM)

  # Note: Editor is not mounted here because it requires additional
  # parameters (index, path, isExpansion, expansionDepth) that depend
  # on the GoldenLayout tab context. Editor integration will be added
  # when the IsoNim app gets its own layout manager.

  IsoNimApp(
    root: root,
    session: session,
  )

# ---------------------------------------------------------------------------
# Top-level mount proc — called from ui_js.nim
# ---------------------------------------------------------------------------

proc mountIsoNimApp*(session: SessionViewModel): IsoNimApp =
  ## Mount the IsoNim application into the `#isonim-app` container.
  ##
  ## This is the main entry point called from ui_js.nim. It creates the
  ## full IsoNim app with all panels, or returns nil if the container div
  ## is not present in the HTML.
  ##
  ## The app is enabled by default. The `#isonim-app` div is visible and
  ## IsoNim mounts into it automatically. Disable with `?karax=1` URL
  ## parameter to fall back to legacy Karax rendering.
  result = createIsoNimApp(session)
  if result.isNil:
    return
  # The reactive effects created by each panel's mount proc handle all
  # subsequent DOM updates. No render loop is needed.
