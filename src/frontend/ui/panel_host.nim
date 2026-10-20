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

import isonim/core/owner
import isonim/web/web_renderer
from isonim/web/dom_api import nil
from ./isonim_panel_mount import findIsoNimPaneHost

import ../types
import ../viewmodel/session_vm
from ../viewmodel/viewmodels/calltrace_vm import followDebuggerCall
import ../viewmodel/views/[isonim_calltrace_view, isonim_state_view]

const
  PanelHostKinds* = {Content.Calltrace, Content.State}
    ## The panes `mountPanel` renders.

type
  PanelDecorator* = proc(host: dom_api.Element; session: SessionViewModel)
    ## Browser behaviour a pane's host adds around its view — run inside the
    ## mount's reactive root, so the effects it creates are disposed with it.

  PanelMount* = ref object
    ## One mounted pane: its host, what it shows, and the root to dispose.
    host: dom_api.Element
    kind: Content
    disposeRoot: proc()
    disposed: bool

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
    else:
      discard
    let decorate = decorators[mount.kind]
    if not decorate.isNil:
      decorate(host, session)

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

proc dispose*(m: PanelMount) =
  ## Dispose the pane's reactive root; its container is GoldenLayout's.
  if m.isNil or m.disposed:
    return
  m.disposed = true
  waiting.keepItIf(it != m)
  live.keepItIf(it != m)
  if not m.disposeRoot.isNil:
    m.disposeRoot()
    m.disposeRoot = nil

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
