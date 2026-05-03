## IsoNim view for bottom auto-hide tabs in the status bar.
##
## The status bar remains a Karax shell, but its bottom-tab host is refreshed
## directly through this view after status redraws. Each tab opens the
## corresponding bottom-pinned auto-hide panel.

import isonim/dsl/ui
from isonim/core/computation import createRenderEffect
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

type
  AutoHideBottomTabRecord* = object
    title*: string

  AutoHideBottomTabsCallbacks* = object
    onSelect*: proc(index: int)

const
  AutoHideBottomTabsClass* = "auto-hide-bottom-tabs"
  AutoHideBottomTabClass* = "auto-hide-strip-tab"

proc invokeSelect(callbacks: AutoHideBottomTabsCallbacks; index: int) =
  if not callbacks.onSelect.isNil:
    callbacks.onSelect(index)

proc renderBottomTab(
    r: MockRenderer;
    tab: AutoHideBottomTabRecord;
    index: int;
    callbacks: AutoHideBottomTabsCallbacks): MockNode =
  ui(r):
    tdiv(
        class = AutoHideBottomTabClass,
        onclick = proc() = callbacks.invokeSelect(index)):
      text tab.title

when defined(js):
  proc renderBottomTab(
      r: WebRenderer;
      tab: AutoHideBottomTabRecord;
      index: int;
      callbacks: AutoHideBottomTabsCallbacks): isonim_dom.Element =
    ui(r):
      tdiv(
          class = AutoHideBottomTabClass,
          onclick = proc() = callbacks.invokeSelect(index)):
        text tab.title

proc renderAutoHideBottomTabsPanel*(
    r: MockRenderer;
    tabs: seq[AutoHideBottomTabRecord];
    callbacks: AutoHideBottomTabsCallbacks =
      AutoHideBottomTabsCallbacks()): MockNode =
  result = ui(r):
    tdiv(class = AutoHideBottomTabsClass)
  for i, tab in tabs:
    r.appendChild(result, renderBottomTab(r, tab, i, callbacks))

when defined(js):
  proc renderAutoHideBottomTabsPanel*(
      r: WebRenderer;
      tabs: seq[AutoHideBottomTabRecord];
      callbacks: AutoHideBottomTabsCallbacks =
        AutoHideBottomTabsCallbacks()): isonim_dom.Element =
    result = ui(r):
      tdiv(class = AutoHideBottomTabsClass)
    for i, tab in tabs:
      r.appendChild(result, renderBottomTab(r, tab, i, callbacks))

  proc renderAutoHideBottomTabsInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      tabs: seq[AutoHideBottomTabRecord];
      callbacks: AutoHideBottomTabsCallbacks =
        AutoHideBottomTabsCallbacks()) =
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    isonim_dom.setAttribute(
      container,
      cstring"class",
      cstring AutoHideBottomTabsClass)

    let panel = renderAutoHideBottomTabsPanel(r, tabs, callbacks)
    let panelNode = isonim_dom.Node(panel)
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)
