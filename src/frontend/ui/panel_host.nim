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
from ../viewmodel/store/replay_data_store import nil
import ../viewmodel/views/[isonim_calltrace_view, isonim_state_view,
                            isonim_low_level_code_view]

const
  PanelHostKinds* = {Content.Calltrace, Content.State, Content.LowLevelCode}
    ## The panes `mountPanel` renders.
  StateRowFallbackPx = 22.0
    ## The State pane's row pitch until a row is rendered to measure.

type
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
    else:
      discard
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
