## IsoNim view for left/right auto-hide side strips.
##
## The strip hosts are static DOM nodes in index.html. This view renders the
## host class state and either vertical text tabs or the collapsed click line,
## preserving the legacy selector contract used by layout and GUI tests.

import isonim/dsl/ui
from isonim/core/computation import createRenderEffect
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

type
  AutoHideSideStripRecord* = object
    title*: string

  AutoHideSideStripCallbacks* = object
    onSelect*: proc(index: int)
    onCollapsedSelect*: proc()

const
  AutoHideSideStripHasTabsClass* = "has-tabs"
  AutoHideSideStripCollapsedClass* = "has-tabs collapsed-mode"
  AutoHideSideStripTabClass* = "auto-hide-strip-tab"
  AutoHideCollapsedStripLineClass* = "collapsed-strip-line"

proc sideStripClass*(hasTabs, collapsed: bool): string =
  if hasTabs and collapsed:
    AutoHideSideStripCollapsedClass
  elif hasTabs:
    AutoHideSideStripHasTabsClass
  else:
    ""

proc invokeSelect(callbacks: AutoHideSideStripCallbacks; index: int) =
  if not callbacks.onSelect.isNil:
    callbacks.onSelect(index)

proc invokeCollapsedSelect(callbacks: AutoHideSideStripCallbacks) =
  if not callbacks.onCollapsedSelect.isNil:
    callbacks.onCollapsedSelect()

proc renderSideStripTab(
    r: MockRenderer;
    tab: AutoHideSideStripRecord;
    index: int;
    callbacks: AutoHideSideStripCallbacks): MockNode =
  ui(r):
    tdiv(
        class = AutoHideSideStripTabClass,
        onclick = proc() = callbacks.invokeSelect(index)):
      text tab.title

proc renderCollapsedLine(
    r: MockRenderer;
    callbacks: AutoHideSideStripCallbacks): MockNode =
  ui(r):
    tdiv(
        class = AutoHideCollapsedStripLineClass,
        onclick = proc() = callbacks.invokeCollapsedSelect())

when defined(js):
  proc renderSideStripTab(
      r: WebRenderer;
      tab: AutoHideSideStripRecord;
      index: int;
      callbacks: AutoHideSideStripCallbacks): isonim_dom.Element =
    ui(r):
      tdiv(
          class = AutoHideSideStripTabClass,
          onclick = proc() = callbacks.invokeSelect(index)):
        text tab.title

  proc renderCollapsedLine(
      r: WebRenderer;
      callbacks: AutoHideSideStripCallbacks): isonim_dom.Element =
    ui(r):
      tdiv(
          class = AutoHideCollapsedStripLineClass,
          onclick = proc() = callbacks.invokeCollapsedSelect())

proc renderAutoHideSideStripPanel*(
    r: MockRenderer;
    tabs: seq[AutoHideSideStripRecord];
    collapsed: bool;
    callbacks: AutoHideSideStripCallbacks =
      AutoHideSideStripCallbacks()): MockNode =
  result = ui(r):
    tdiv(class = sideStripClass(tabs.len > 0, collapsed and tabs.len > 0))
  if collapsed:
    r.appendChild(result, renderCollapsedLine(r, callbacks))
  else:
    for i, tab in tabs:
      r.appendChild(result, renderSideStripTab(r, tab, i, callbacks))

when defined(js):
  proc renderAutoHideSideStripPanel*(
      r: WebRenderer;
      tabs: seq[AutoHideSideStripRecord];
      collapsed: bool;
      callbacks: AutoHideSideStripCallbacks =
        AutoHideSideStripCallbacks()): isonim_dom.Element =
    result = ui(r):
      tdiv(class = sideStripClass(tabs.len > 0, collapsed and tabs.len > 0))
    if collapsed:
      r.appendChild(result, renderCollapsedLine(r, callbacks))
    else:
      for i, tab in tabs:
        r.appendChild(result, renderSideStripTab(r, tab, i, callbacks))

  proc renderAutoHideSideStripInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      tabs: seq[AutoHideSideStripRecord];
      collapsed: bool;
      callbacks: AutoHideSideStripCallbacks =
        AutoHideSideStripCallbacks()) =
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    isonim_dom.setAttribute(
      container,
      cstring"class",
      cstring sideStripClass(tabs.len > 0, collapsed and tabs.len > 0))

    let panel = renderAutoHideSideStripPanel(r, tabs, collapsed, callbacks)
    let panelNode = isonim_dom.Node(panel)
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)
