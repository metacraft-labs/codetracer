## viewmodel/app/isonim_app.nim
##
## IsoNim application shell for CodeTracer.
##
## This module provides the standalone IsoNim rendering entry point. It renders
## all panels from SessionViewModel signals into a dedicated `#isonim-app`
## container div. The GoldenLayout-mounted per-panel IsoNim views are the
## canonical application path while the standalone shell remains available for
## future layout-manager work.
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

import ../session_vm
import ./isonim_app_shell

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
  ## The app shell is emitted as one IsoNim ``ui()`` tree.  Each mounted
  ## panel gets a stable ``.isonim-section-content`` host inside that tree.
  ## The layout is a simple vertical stack for now — GoldenLayout / app
  ## layout-manager integration remains the next architectural layer.
  ## The panels read directly from the SessionViewModel's signals (the
  ## same-process fast path), so all updates are automatic.
  let root = isonim_dom.document.getElementById(cstring"isonim-app")
  if isonim_dom.isNodeNil(isonim_dom.Node(root)):
    return nil

  let r = WebRenderer()
  let shell = renderIsoNimAppShell(r)
  isonim_dom.appendChild(isonim_dom.Node(root), isonim_dom.Node(shell.root))

  # Debug controls are mounted separately into `#isonim-debug-controls`
  # (defined in index.html) by `tryMountIsoNimDebugControls` in debug.nim.
  # Do NOT mount them here — that would create duplicate elements with the
  # same IDs (e.g. `#next-debug`), breaking Playwright locators.

  mountIsoNimStatePanel(shell.sections[0].content, session.stateVM)
  mountIsoNimCalltrace(shell.sections[1].content, session.calltraceVM)
  mountIsoNimEventLog(shell.sections[2].content, session.eventLogVM)
  mountIsoNimFlow(shell.sections[3].content, session.flowVM)
  mountIsoNimTimeline(shell.sections[4].content, session.timelineVM)
  mountIsoNimSearch(shell.sections[5].content, session.searchVM)
  mountIsoNimPointList(shell.sections[6].content, session.pointListVM)
  mountIsoNimScratchpadPanel(shell.sections[7].content, session.scratchpadVM)
  mountIsoNimShell(shell.sections[8].content, session.shellVM)

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
  ## The standalone shell is mounted only by callers that opt into this entry
  ## point. The regular application mounts IsoNim views directly into
  ## GoldenLayout containers.
  result = createIsoNimApp(session)
  if result.isNil:
    return
  # The reactive effects created by each panel's mount proc handle all
  # subsequent DOM updates. No render loop is needed.
