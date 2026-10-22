## IsoNim view for the collapsed auto-hide overlay side tabs.
##
## The overlay tabs live in the static ``#auto-hide-overlay-side-tabs`` host
## and list the panels pinned to the same collapsed side edge as the active
## overlay.  The caller derives plain tab records from the live auto-hide state
## and refreshes this direct DOM surface whenever the overlay changes.

import isonim/dsl/ui
import isonim/core/[signals, computation]
import isonim/dsl/components
import isonim/testing/mock_dom

# The generic procs expand the DSL at their caller.
export signals, computation, components

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

type
  AutoHideOverlayTabRecord* = object
    title*: string
    active*: bool

  AutoHideOverlayTabsCallbacks* = object
    onSelect*: proc(index: int)

const
  AutoHideOverlayTabsClass* = "overlay-side-tabs"
  AutoHideOverlayTabsHiddenClass* = "overlay-side-tabs hidden"
  AutoHideOverlayTabsLeftClass* = "overlay-side-tabs side-tabs-left"
  AutoHideOverlayTabsRightClass* = "overlay-side-tabs side-tabs-right"
  AutoHideOverlayTabClass* = "overlay-side-tab"
  AutoHideOverlayTabActiveClass* = "overlay-side-tab active"

proc overlayTabsClass*(visible: bool; edgeClass: string): string =
  if not visible:
    AutoHideOverlayTabsHiddenClass
  else:
    AutoHideOverlayTabsClass & edgeClass

proc overlayTabClass*(active: bool): string =
  if active: AutoHideOverlayTabActiveClass else: AutoHideOverlayTabClass

proc invokeSelect(callbacks: AutoHideOverlayTabsCallbacks; index: int) =
  if not callbacks.onSelect.isNil:
    callbacks.onSelect(index)

proc renderOverlayTab[R, N](
    r: R;
    tab: AutoHideOverlayTabRecord;
    index: int;
    callbacks: AutoHideOverlayTabsCallbacks): N =
  ui(r):
    tdiv(class = overlayTabClass(tab.active),
         onclick = proc() = callbacks.invokeSelect(index)):
      text tab.title

proc renderAutoHideOverlayTabsPanel*[R, N](
    r: R;
    tabs: seq[AutoHideOverlayTabRecord];
    visible: bool;
    edgeClass: string;
    callbacks: AutoHideOverlayTabsCallbacks =
      AutoHideOverlayTabsCallbacks()): N =
  ## The overlay's side tabs, for every renderer. `tabs` is a value the
  ## caller re-derives and redraws (`renderAutoHideOverlayTabsInto`).
  # A plain name for the child call: the `ui` macro passes a call through as
  # a child only when its callee is an identifier, and `f[R, N](...)` is not.
  template overlayTab(tab: AutoHideOverlayTabRecord; i: int): N =
    renderOverlayTab[R, N](r, tab, i, callbacks)
  ui(r):
    tdiv(class = overlayTabsClass(visible, edgeClass)):
      if visible:
        for i, tab in tabs:
          overlayTab(tab, i)

when defined(js):
  proc renderAutoHideOverlayTabsInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      tabs: seq[AutoHideOverlayTabRecord];
      visible: bool;
      edgeClass: string;
      callbacks: AutoHideOverlayTabsCallbacks =
        AutoHideOverlayTabsCallbacks()) =
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    # This surface is refreshed into a static Golden Layout overlay host.
    let panel = renderAutoHideOverlayTabsPanel[WebRenderer, isonim_dom.Element](
      r, tabs, visible, edgeClass, callbacks)
    discard isonim_dom.appendChild(containerNode, isonim_dom.Node(panel))
