## IsoNim view for the collapsed auto-hide overlay side tabs.
##
## The overlay tabs live in the static ``#auto-hide-overlay-side-tabs`` host
## and list the panels pinned to the same collapsed side edge as the active
## overlay.  The caller derives plain tab records from the live auto-hide state
## and refreshes this direct DOM surface whenever the overlay changes.

import isonim/dsl/ui
from isonim/core/computation import createRenderEffect
import isonim/testing/mock_dom

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

proc renderOverlayTab(
    r: MockRenderer;
    tab: AutoHideOverlayTabRecord;
    index: int;
    callbacks: AutoHideOverlayTabsCallbacks): MockNode =
  ui(r):
    tdiv(class = overlayTabClass(tab.active),
         onclick = proc() = callbacks.invokeSelect(index)):
      text tab.title

when defined(js):
  proc renderOverlayTab(
      r: WebRenderer;
      tab: AutoHideOverlayTabRecord;
      index: int;
      callbacks: AutoHideOverlayTabsCallbacks): isonim_dom.Element =
    ui(r):
      tdiv(class = overlayTabClass(tab.active),
           onclick = proc() = callbacks.invokeSelect(index)):
        text tab.title

proc renderAutoHideOverlayTabsPanel*(
    r: MockRenderer;
    tabs: seq[AutoHideOverlayTabRecord];
    visible: bool;
    edgeClass: string;
    callbacks: AutoHideOverlayTabsCallbacks =
      AutoHideOverlayTabsCallbacks()): MockNode =
  ui(r):
    tdiv(class = overlayTabsClass(visible, edgeClass)):
      if visible:
        for i, tab in tabs:
          renderOverlayTab(r, tab, i, callbacks)

when defined(js):
  proc renderAutoHideOverlayTabsPanel*(
      r: WebRenderer;
      tabs: seq[AutoHideOverlayTabRecord];
      visible: bool;
      edgeClass: string;
      callbacks: AutoHideOverlayTabsCallbacks =
        AutoHideOverlayTabsCallbacks()): isonim_dom.Element =
    ui(r):
      tdiv(class = overlayTabsClass(visible, edgeClass)):
        if visible:
          for i, tab in tabs:
            renderOverlayTab(r, tab, i, callbacks)

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
    let panel = renderAutoHideOverlayTabsPanel(
      r, tabs, visible, edgeClass, callbacks)
    discard isonim_dom.appendChild(containerNode, isonim_dom.Node(panel))
