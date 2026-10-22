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
## The panes reached this way are `PanelHostKinds`; the others still mount
## through `ui/layout.mountPaneForState` until their views are converted.

import std/sequtils

import isonim/core/[owner, signals, computation]
import isonim/web/web_renderer
from isonim/web/dom_api import nil
from ./isonim_panel_mount import findIsoNimPaneHost

import ../types
import ../viewmodel/session_vm
import ../viewmodel/pane_viewport
from ../viewmodel/viewmodels/calltrace_vm import followDebuggerCall,
  setViewport, setRowHeightPx
from ../viewmodel/viewmodels/state_vm import setViewport
from ../viewmodel/viewmodels/low_level_code_vm import setShown
from ../viewmodel/viewmodels/request_panel_vm import setViewport
from ../viewmodel/store/replay_data_store import nil
import ../viewmodel/views/[isonim_calltrace_view, isonim_state_view,
                            isonim_low_level_code_view,
                            isonim_point_list_view, isonim_step_list_view,
                            isonim_calltrace_editor_view, isonim_build_view,
                            isonim_errors_view, isonim_scratchpad_view,
                            isonim_repl_view, isonim_filesystem_view,
                            isonim_command_palette_view]
import ../viewmodel/views/[isonim_search_results_view, isonim_trace_log_view,
                            isonim_terminal_output_view]
from ../viewmodel/viewmodels/terminal_output_vm import nil
from ../viewmodel/viewmodels/trace_log_vm import setViewport

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
                     Content.CommandPalette, Content.Verification}
    ## The panes `mountPanel` renders.
  RequestRowFallbackPx = 24.0
    ## The Request panel's row pitch until a row is rendered to measure.
  StateRowFallbackPx = 22.0
    ## The State pane's row pitch until a row is rendered to measure.
  TraceRowFallbackPx = 22.0
    ## The Trace Log's row pitch until a row is rendered to measure.
  TerminalLineFallbackPx = 18.0
    ## A terminal line's height until one is drawn to measure.

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
    disposeRoot: proc()
    stopMeasuring: StopWatching
    disposed: bool

  StopWatching = proc()
    ## Disconnects a pane's resize observer and scroll listener.

  PaneMeasure = object
    ## How the host measures a pane it mounted (Viewport-Driven-Loading V3):
    ## the element that scrolls, a row's selector (the rows' measured
    ## advance), the pixels one depth level indents, and where the result
    ## goes. `fallbackRowPx` is the row pitch to use before a row exists.
    scroller: cstring
    row: cstring
    pxPerLevel: float
    countPartialRow: bool
      ## A row any of which shows counts (the State pane: it sizes how many
      ## values a stop and a "Load More" fetch).
    reportHidden: bool
      ## A hidden pane reports no rows, so the ViewModel falls back to its
      ## defaults, rather than keeping the last size it was told.
    fallbackRowPx: proc(): float
    report: proc(v: Viewport; rowPx: float)
    changed: proc()
      ## Read inside an effect: the pane's rows changed, measure again.

var decorators: array[Content, PanelDecorator]
var renderers: array[Content, PanelRenderer]
  ## Per pane whose ViewModel the session does not own (the visual-replay
  ## and agent panes): the module that owns it registers how to render it
  ## (`setPanelRenderer`).
  ## Per pane, set by the module that owns the pane's host behaviour.
var hostSession: SessionViewModel
  ## The session the panes show; nil until the renderer has one.
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
# One ResizeObserver and one scroll listener per mounted pane, owned here and
# disconnected when the mount is disposed: the pane's body height over the
# rows' measured advance is its rows, the scroll offset over the advance is
# the first row shown, and the width over a depth level's indent is the levels
# that fit (`pane_viewport.pixelPaneViewport`, the conversion every front-end
# shares). The views measure nothing for their ViewModels.

proc qsIn(el: dom_api.Element; sel: cstring): dom_api.Element
  {.importjs: "(#.querySelector(#) || null)".}
proc paneClientHeight(el: dom_api.Element): float
  {.importjs: "(#.clientHeight || 0)".}
proc paneClientWidth(el: dom_api.Element): float
  {.importjs: "(#.clientWidth || 0)".}
proc paneScrollTop(el: dom_api.Element): float
  {.importjs: "(#.scrollTop || 0)".}
proc rowPitchIn(el: dom_api.Element; sel: cstring): float {.importjs:
  "((el, sel) => { var r = el.querySelectorAll(sel); if (r.length === 0) return 0; if (r.length === 1) return r[0].getBoundingClientRect().height; return (r[r.length - 1].getBoundingClientRect().top - r[0].getBoundingClientRect().top) / (r.length - 1); })(#, #)".}
  ## The rows' ADVANCE, top to top, averaged over the rendered rows: what
  ## positions them (a sub-pixel advance is recovered exactly), not a row box.
proc watchPane(el: dom_api.Element; onChange: proc()): StopWatching {.importjs:
  "((el, cb) => { var ro = (typeof ResizeObserver !== 'undefined') ? new ResizeObserver(() => cb()) : null; if (ro) ro.observe(el); el.addEventListener('scroll', cb, {passive: true}); return () => { if (ro) ro.disconnect(); el.removeEventListener('scroll', cb); }; })(#, #)".}
  ## Call `onChange` on every resize and scroll of `el`; the result stops it.
proc panelSetTimeout(fn: proc(); ms: int) {.importjs: "setTimeout(#, #)".}

proc measureOf(kind: Content; session: SessionViewModel): PaneMeasure =
  ## The measurement of a pane the host mounts.
  case kind
  of Content.Calltrace:
    let vm = session.calltraceVM
    PaneMeasure(
      scroller: cstring".local-calltrace-view",
      row: cstring".calltrace-call-line",
      pxPerLevel: CallDepthIndentPx,
      fallbackRowPx: proc(): float = vm.rowHeightPx.val,
      report: proc(v: Viewport; rowPx: float) =
        vm.setRowHeightPx(rowPx)
        vm.setViewport(v),
      changed: proc() = discard session.store.calltrace.lines.val)
  of Content.State:
    let vm = session.stateVM
    PaneMeasure(
      scroller: cstring".value-components-container",
      row: cstring".value-expanded",
      pxPerLevel: 0.0,
      countPartialRow: true,
      reportHidden: true,
      fallbackRowPx: proc(): float = StateRowFallbackPx,
      report: proc(v: Viewport; rowPx: float) = vm.setViewport(v),
      changed: proc() = discard session.store.locals.locals.val)
  of Content.TraceLog:
    # The rows it shows (Viewport-Driven-Loading Q4): their locals are read
    # by window. A hidden pane reports none and reads nothing.
    let vm = session.traceLogVM
    PaneMeasure(
      scroller: cstring".trace-log-table-body",
      row: cstring".trace-log-row",
      pxPerLevel: 0.0,
      countPartialRow: true,
      reportHidden: true,
      fallbackRowPx: proc(): float = TraceRowFallbackPx,
      report: proc(v: Viewport; rowPx: float) = vm.setViewport(v),
      changed: proc() = discard vm.entries.val)
  of Content.TerminalOutput:
    # The line view asks for the lines it shows (Viewport-Driven-Loading
    # Q3): the `pre` holding the lines is the scroller. A hidden pane (no
    # height) reports none and asks nothing until it is shown.
    let vm = session.terminalOutputVM
    PaneMeasure(
      scroller: cstring"pre",
      row: cstring".terminal-line",
      pxPerLevel: 0.0,
      countPartialRow: true,
      reportHidden: true,
      fallbackRowPx: proc(): float = TerminalLineFallbackPx,
      report: proc(v: Viewport; rowPx: float) =
        terminal_output_vm.setViewport(vm, v),
      changed: proc() = discard vm.lines.val)
  of Content.RequestPanel:
    # The rows the table body shows (Viewport-Driven-Loading V2): a partly
    # visible row counts; the window held is padded by the view.
    let vm = session.requestPanelVM
    PaneMeasure(
      scroller: cstring".request-table-body",
      row: cstring".request-row",
      pxPerLevel: 0.0,
      countPartialRow: true,
      fallbackRowPx: proc(): float = RequestRowFallbackPx,
      report: proc(v: Viewport; rowPx: float) = vm.setViewport(v),
      changed: proc() = discard vm.filteredRequests.val)
  else:
    PaneMeasure()

proc startMeasuring(m: PanelMount; session: SessionViewModel) =
  ## Attach the pane's one observer and one scroll listener; report now (one
  ## tick later, so the view's elements are laid out) and whenever the pane is
  ## resized or scrolled, or its rows change.
  let spec = measureOf(m.kind, session)
  if spec.report.isNil:
    return
  let scroller = qsIn(m.host, spec.scroller)
  if dom_api.isNodeNil(dom_api.Node(scroller)):
    return
  let measure = proc() =
    var rowPx = rowPitchIn(scroller, spec.row)
    if rowPx <= 0.0:
      rowPx = spec.fallbackRowPx()
    let v = pixelPaneViewport(scroller.paneClientHeight,
                              scroller.paneClientWidth, rowPx,
                              scroller.paneScrollTop, spec.pxPerLevel,
                              countPartialRow = spec.countPartialRow)
    if v.measured or spec.reportHidden:
      spec.report(v, rowPx)
  m.stopMeasuring = watchPane(scroller, measure)
  createEffect proc() =
    spec.changed()
    panelSetTimeout(measure, 0)

proc render(m: PanelMount; session: SessionViewModel) =
  ## Render `m`'s pane into its host, in a root of its own.
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
  ## then.
  if session.isNil or session.lowLevelCodeVM.isNil:
    return
  session.lowLevelCodeVM.setShown(
    live.anyIt(it.kind == Content.LowLevelCode and not it.disposeRoot.isNil))

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
  if hostSession.isNil:
    waiting.add result
  else:
    result.render(hostSession)
    reportShown(hostSession)

proc dispose*(m: PanelMount) =
  ## Dispose the pane's reactive root; its container is GoldenLayout's.
  if m.isNil or m.disposed:
    return
  m.disposed = true
  waiting.keepItIf(it != m)
  live.keepItIf(it != m)
  if not m.stopMeasuring.isNil:
    m.stopMeasuring()
    m.stopMeasuring = nil
  if not m.disposeRoot.isNil:
    m.disposeRoot()
    m.disposeRoot = nil
  reportShown(hostSession)

proc setPanelSession*(session: SessionViewModel) =
  ## Install the session the panes show, and mount every pane whose container
  ## was waiting for it.
  hostSession = session
  if session.isNil:
    return
  # The desktop and the web mark the call the debugger is in after every
  # move, as the Call Trace component did before it was mounted here.
  if not session.calltraceVM.isNil:
    session.calltraceVM.followDebuggerCall()
  let pending = waiting
  waiting = @[]
  for m in pending:
    if not m.disposed:
      m.render(session)
  reportShown(session)

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
  ## The session the panes show, or nil before the renderer has one — for a
  ## pane's key handlers, which act on the same ViewModel the pane renders.
  hostSession

proc ensurePanelMountedById*(containerId: cstring; kind: Content;
                             activeTab: int) =
  ## `ensurePanelMounted` on tab `activeTab`'s host with id `containerId`, if
  ## that tab has one. Every tab of a window carries the same pane ids, so a
  ## document-wide lookup would find the first tab's host
  ## (`isonim_panel_mount.findIsoNimPaneHost`).
  let host = findIsoNimPaneHost(containerId, activeTab)
  if not dom_api.isNodeNil(dom_api.Node(host)):
    ensurePanelMounted(host, kind)
