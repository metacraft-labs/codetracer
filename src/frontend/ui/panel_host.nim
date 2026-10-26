## ui/panel_host.nim — whoever creates a panel's container mounts the panel.
##
## Shared-DOM-Front-Ends D4. A pane's view never looks for its container:
## GoldenLayout's component factory (`ui/layout.nim`) — the one place that
## knows the container exists, because it has just created it — calls
## `mountPanel` on it, synchronously, and disposes the mount when GoldenLayout
## destroys the container. There is no timer, no polling for an element id and
## no "is it still mounted" latch.
##
## The panel's ViewModel is the session's (`initializePanelViewModels`); the
## view is the pane's one generic proc, rendered under `WebRenderer` inside a
## reactive root this module owns. A container created before the session
## exists — GoldenLayout builds the layout before the renderer has a trace —
## is held and mounted the moment the session is installed.
##
## WHICH SESSION: the one of the TAB WHOSE CONTAINER HOLDS THE HOST. Every tab
## of a desktop window is an independent session with its own ViewModels
## (`GUI/Multi-Window-Tab-Management.md` §Tab Behavior rules 1 and 2;
## `ui/session_viewmodels.nim`), and every tab's DOM lives in one document, so
## one window-global session would draw one tab's data into every tab's panes
## — which is what it did while the window had one `SessionViewModel`. The
## host process installs the rule (`setPanelSessionResolver`); a host outside
## every tab container (the auto-hide overlay) shows the tab on screen, and is
## re-rendered when another tab is shown (`refreshPanelSessions`).
##
## The panes reached this way are `PanelHostKinds`; the others still mount
## through `ui/layout.mountPaneForState` until their views are converted.

import std/[options, sequtils]

import isonim/core/[owner, signals, computation]
import isonim/web/web_renderer
from isonim/web/dom_api import nil
from ./pane_host_lookup import findPaneHost

import ../types
from ../communication import emit
from ../../common/ct_event import InternalAddToScratchpad
import ../viewmodel/session_vm
from ../viewmodel/viewmodels/calltrace_vm import followDebuggerCall
from ../viewmodel/viewmodels/low_level_code_vm import setShown
from ../viewmodel/store/replay_data_store import nil
import ../viewmodel/views/[isonim_calltrace_view, isonim_state_view,
                            isonim_low_level_code_view,
                            isonim_point_list_view, isonim_step_list_view,
                            isonim_calltrace_editor_view, isonim_build_view,
                            isonim_errors_view, isonim_scratchpad_view,
                            isonim_repl_view, isonim_filesystem_view,
                            isonim_command_palette_view]
import ../viewmodel/views/[isonim_search_results_view, isonim_trace_log_view,
                            isonim_terminal_output_view, isonim_event_log_view]
from ../viewmodel/viewmodels/event_log_vm import followStop
import ../viewmodel/views/pane_measure_dom

const
  PanelHostKinds* = {Content.Calltrace, Content.State, Content.LowLevelCode,
                     Content.PixelHistory, Content.ShaderDebug,
                     Content.VideoPlayer, Content.PointList,
                     Content.StepList, Content.CalltraceEditor,
                     Content.Build, Content.BuildErrors,
                     Content.SearchResults, Content.TraceLog,
                     Content.TerminalOutput, Content.AgentWorkspace,
                     Content.RequestPanel, Content.AgentActivity,
                     Content.Scratchpad, Content.Repl, Content.Filesystem,
                     Content.TestResults, Content.Constraints,
                     Content.CommandPalette, Content.Verification,
                     Content.UnifiedDiff, Content.VCS, Content.EventLog}
    ## The panes `mountPanel` renders.

type
  PanelRenderer* = proc(r: WebRenderer; host: dom_api.Element;
                        session: SessionViewModel): dom_api.Element
    ## Renders a pane whose ViewModel its own module owns, inside the mount's
    ## reactive root; `host` is the container (its id names the component of
    ## a pane that has several).

  PanelDecorator* = proc(host: dom_api.Element; session: SessionViewModel)
    ## Browser behaviour a pane's host adds around its view — run inside the
    ## mount's reactive root, so the effects it creates are disposed with it.

  PanelMount* = ref object
    ## One mounted pane: its host, what it shows, and the root to dispose.
    host: dom_api.Element
    kind: Content
    session: SessionViewModel
      ## The session it was rendered over; nil while it waits for one.
    disposeRoot: proc()
    stopMeasuring: StopMeasuring
    disposed: bool

var decorators: array[Content, PanelDecorator]
var renderers: array[Content, PanelRenderer]
  ## Per pane whose ViewModel the session does not own (the visual-replay
  ## and agent panes): the module that owns it registers how to render it
  ## (`setPanelRenderer`).
  ## Per pane, set by the module that owns the pane's host behaviour.
var shownSession: SessionViewModel
  ## The session of the tab on screen; nil until the renderer has one. What
  ## a host shows when no resolver is installed (a single-session page), and
  ## what the panes' key handlers act on (`panelSession`).
var resolveSession: proc(host: dom_api.Element): SessionViewModel
  ## Which session a host's pane shows (`setPanelSessionResolver`).
var waiting: seq[PanelMount]
  ## Mounts whose container exists but whose session did not yet.
var live: seq[PanelMount]
  ## Every mount not yet disposed, so a destroyed container can dispose the
  ## ones inside it — and only those: a pane auto-hide pins or unpins moves
  ## its DOM to a new container before GoldenLayout destroys the old one.

proc containsNode(outer, inner: dom_api.Element): bool
  {.importjs: "#.contains(#)".}

# ---------------------------------------------------------------------------
# HSF-V2: THE HOST REPORTS WHAT EACH PANE SHOWS
# ---------------------------------------------------------------------------
#
# The measurement is `views/pane_measure_dom`, shared with the VS Code panel
# webviews (`entries/vscode_panel`). The views measure nothing for their
# ViewModels.

proc measuredPaneOf(kind: Content): Option[MeasuredPane] =
  ## The measurement of a pane the host mounts; none for a pane the host does
  ## not measure.
  case kind
  of Content.Calltrace: some(mpCalltrace)
  of Content.State: some(mpState)
  of Content.TraceLog: some(mpTraceLog)
  of Content.TerminalOutput: some(mpTerminalOutput)
  of Content.EventLog: some(mpEventLog)
  of Content.RequestPanel: some(mpRequestPanel)
  else: none(MeasuredPane)

proc startMeasuring(m: PanelMount; session: SessionViewModel) =
  ## Attach the pane's one observer and one scroll listener
  ## (`startMeasuringPane`).
  let pane = measuredPaneOf(m.kind)
  if pane.isSome:
    m.stopMeasuring = startMeasuringPane(m.host, pane.get, session)

proc unrender(m: PanelMount) =
  ## Stop `m`'s measuring and dispose its reactive root, keeping the mount.
  if not m.stopMeasuring.isNil:
    m.stopMeasuring()
    m.stopMeasuring = nil
  if not m.disposeRoot.isNil:
    m.disposeRoot()
    m.disposeRoot = nil

proc render(m: PanelMount; session: SessionViewModel) =
  ## Render `m`'s pane into its host over `session`, in a root of its own,
  ## replacing whatever it rendered before.
  m.unrender()
  m.session = session
  let host = m.host
  let node = dom_api.Node(host)
  while not dom_api.isNodeNil(node.firstChild):
    discard dom_api.removeChild(node, node.firstChild)
  let mount = m
  createRoot proc(dispose: proc()) =
    mount.disposeRoot = dispose
    let r = WebRenderer()
    case mount.kind
    of Content.Calltrace:
      let panel = renderCalltracePanel[WebRenderer, dom_api.Element](
        r, session.calltraceVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.State:
      let panel = renderStatePanel[WebRenderer, dom_api.Element](
        r, session.stateVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.LowLevelCode:
      let panel = renderLowLevelCodePanel[WebRenderer, dom_api.Element](
        r, session.lowLevelCodeVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.PointList:
      let panel = renderPointListPanel[WebRenderer, dom_api.Element](
        r, session.pointListVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.StepList:
      let panel = renderStepListPanel[WebRenderer, dom_api.Element](
        r, session.stepListVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.CalltraceEditor:
      let panel = renderCalltraceEditorPanel[WebRenderer, dom_api.Element](
        r, session.calltraceEditorVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.Build:
      let panel = renderBuildPanel[WebRenderer, dom_api.Element](
        r, session.buildVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.BuildErrors:
      let panel = renderErrorsPanel[WebRenderer, dom_api.Element](
        r, session.errorsVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.SearchResults:
      let panel = renderSearchResultsPanel[WebRenderer, dom_api.Element](
        r, session.searchResultsVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.TraceLog:
      let panel = renderTraceLogPanel[WebRenderer, dom_api.Element](
        r, session.traceLogVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.TerminalOutput:
      let panel = renderTerminalOutputPanel[WebRenderer, dom_api.Element](
        r, session.terminalOutputVM)
      dom_api.appendChild(node, dom_api.Node(panel))
      decorateTerminalOutput(panel, session.terminalOutputVM)
    of Content.EventLog:
      let panel = renderEventLogPanel[WebRenderer, dom_api.Element](
        r, session.eventLogVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.Scratchpad:
      let panel = renderScratchpadPanel[WebRenderer, dom_api.Element](
        r, session.scratchpadVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.Repl:
      let panel = renderReplPanel[WebRenderer, dom_api.Element](
        r, session.replVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.Filesystem:
      let panel = renderFilesystemPanel[WebRenderer, dom_api.Element](
        r, session.fileTreeVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    of Content.CommandPalette:
      let panel = renderCommandPalettePanel[WebRenderer, dom_api.Element](
        r, session.commandPaletteVM)
      dom_api.appendChild(node, dom_api.Node(panel))
    else:
      let renderPane = renderers[mount.kind]
      if not renderPane.isNil:
        dom_api.appendChild(node, dom_api.Node(renderPane(r, host, session)))
    let decorate = decorators[mount.kind]
    if not decorate.isNil:
      decorate(host, session)
    mount.startMeasuring(session)

proc reportShown(session: SessionViewModel) =
  ## Tell the session's ViewModels which of the panes that load only while
  ## shown are mounted: the stop loader asks for the low-level code only
  ## then. Only `session`'s own mounts count — another tab's Low Level Code
  ## pane does not make this session load its code.
  if session.isNil or session.lowLevelCodeVM.isNil:
    return
  session.lowLevelCodeVM.setShown(
    live.anyIt(it.kind == Content.LowLevelCode and it.session == session and
               not it.disposeRoot.isNil))

proc sessionFor(host: dom_api.Element): SessionViewModel =
  ## The session `host`'s pane shows: the resolver's answer, or the shown
  ## session where no resolver is installed.
  if resolveSession.isNil: shownSession else: resolveSession(host)

proc prepare(session: SessionViewModel) =
  ## What a session's panes need from the host once, before the first of
  ## them renders. Idempotent: both only set a mode on the ViewModel.
  if session.isNil:
    return
  # The desktop and the web mark the call the debugger is in after every
  # move, as the Call Trace component did before it was mounted here.
  if not session.calltraceVM.isNil:
    session.calltraceVM.followDebuggerCall()
  # The Event Log marks the current event, and asks for it after a move, as
  # the terminal's and GPUI's do (HSF-D6).
  if not session.eventLogVM.isNil:
    session.eventLogVM.followStop()

proc panelHostComponentId*(host: dom_api.Element): int {.importjs:
  "(function(e){var p=(e.id||'').split('-');var n=Number(p[p.length-1]);return isNaN(n)?0:n;})(#)".}
  ## The `<id>` of a host whose id is `<pane>Component-<id>`: which of the
  ## pane's components a `PanelRenderer` renders, for a pane that has several.

proc setPanelRenderer*(kind: Content; render: PanelRenderer) =
  ## Install how `kind` renders, for a pane whose ViewModel the session does
  ## not own. `kind` must be in `PanelHostKinds`.
  renderers[kind] = render

proc setPanelDecorator*(kind: Content; decorate: PanelDecorator) =
  ## Install the host behaviour for `kind`'s mounts made from now on.
  decorators[kind] = decorate

proc mountPanel*(host: dom_api.Element; kind: Content): PanelMount =
  ## Mount the pane `kind` into `host`, now if the session exists, else as
  ## soon as it does (`setPanelSession`). `kind` must be in `PanelHostKinds`.
  doAssert kind in PanelHostKinds, $kind & " is not mounted by the panel host"
  result = PanelMount(host: host, kind: kind)
  live.add result
  let session = sessionFor(host)
  if session.isNil:
    waiting.add result
  else:
    session.prepare()
    result.render(session)
    reportShown(session)

proc dispose*(m: PanelMount) =
  ## Dispose the pane's reactive root; its container is GoldenLayout's.
  if m.isNil or m.disposed:
    return
  m.disposed = true
  waiting.keepItIf(it != m)
  live.keepItIf(it != m)
  let session = m.session
  m.unrender()
  m.session = nil
  reportShown(session)

proc refreshPanelSessions*() =
  ## Ask every live mount again which session it shows, and act on the
  ## answer: a mount waiting for a session that now exists is rendered, and a
  ## mount whose host now shows a different session than it rendered — the
  ## auto-hide overlay after a tab switch, a tab's host rendered before that
  ## tab had ViewModels of its own — is rendered again over it. A mount whose
  ## session is unchanged is left alone, so a tab switch does not rebuild the
  ## panes of the tabs it shows and hides.
  ##
  ## Called by the host whenever the answer can have changed: a session got
  ## its ViewModels, the shown tab changed, a tab was closed.
  var touched: seq[SessionViewModel] = @[]
  for m in live:
    if m.disposed:
      continue
    let session = sessionFor(m.host)
    if session.isNil or session == m.session:
      continue
    if not m.session.isNil and m.session notin touched:
      touched.add m.session
    session.prepare()
    m.render(session)
    if session notin touched:
      touched.add session
  waiting = live.filterIt(not it.disposed and it.session.isNil)
  for session in touched:
    reportShown(session)

proc setPanelSessionResolver*(
    resolve: proc(host: dom_api.Element): SessionViewModel) =
  ## Install which session a host's pane shows — on the desktop, the session
  ## of the tab whose container holds it (`ui_js`). Nil restores the default:
  ## every host shows the session `setPanelSession` installed.
  resolveSession = resolve
  refreshPanelSessions()

# "Add value to scratchpad" on a call-trace argument: the desktop's scratchpad
# takes values over the tab's event bus (`ui/scratchpad`'s
# `InternalAddToScratchpad` subscription). The view only calls the hook, so it
# can be rendered outside the desktop (`codetracer_ui_components`).
proc rawScratchpadValue(text: string): Value =
  Value(kind: TypeKind.Raw, typ: RAW_TYPE, r: cstring(text), isLiteral: false)

addToScratchpadHook = proc(name, text: string) =
  if data.sessions.len == 0:
    return
  data.sessions[data.activeSessionIndex].viewsApi.emit(
    InternalAddToScratchpad,
    ValueWithExpression(expression: cstring(name),
                        value: rawScratchpadValue(text)))

proc setPanelSession*(session: SessionViewModel) =
  ## Install the session of the tab on screen, and mount or re-render every
  ## pane whose session that changes (`refreshPanelSessions`).
  shownSession = session
  refreshPanelSessions()

proc ensurePanelMounted*(host: dom_api.Element; kind: Content) =
  ## Mount `kind` into `host` unless a live mount already renders there — for
  ## a container rebuilt outside GoldenLayout (an auto-hide panel restored
  ## from its saved state), which reaches `mountPaneForState` rather than the
  ## factory.
  for m in live:
    if m.host == host:
      return
  discard mountPanel(host, kind)

proc disposePanelsIn*(container: dom_api.Element) =
  ## GoldenLayout destroyed `container`: dispose the panes still inside it.
  let inside = live.filterIt(containsNode(container, it.host))
  for m in inside:
    m.dispose()

proc panelSession*(): SessionViewModel =
  ## The session of the tab on screen, or nil before the renderer has one —
  ## for a pane's key handlers, which act on the same ViewModel the focused
  ## (and therefore shown) pane renders.
  shownSession

proc ensurePanelMountedById*(containerId: cstring; kind: Content;
                             activeTab: int) =
  ## `ensurePanelMounted` on tab `activeTab`'s host with id `containerId`, if
  ## that tab has one. Every tab of a window carries the same pane ids, so a
  ## document-wide lookup would find the first tab's host
  ## (`pane_host_lookup.findPaneHost`).
  let host = findPaneHost(containerId, activeTab)
  if not dom_api.isNodeNil(dom_api.Node(host)):
    ensurePanelMounted(host, kind)
