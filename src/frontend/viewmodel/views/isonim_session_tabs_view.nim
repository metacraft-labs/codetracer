## IsoNim view for the global multi-session tab bar.
##
## The tab bar lives outside GoldenLayout and outside ``#ROOT`` so session
## switches cannot destroy it.  This view owns the tab DOM structure; callers
## provide plain records derived from ``Data.sessions`` and trigger a refresh
## when that session list, active index, or visible trace label changes.

import isonim/dsl/ui
from isonim/core/computation import createRenderEffect
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

type
  SessionTabRecord* = object
    label*: string

  SessionTabsCallbacks* = object
    onSelect*: proc(index: int)
    onClose*: proc(index: int)
    onAdd*: proc()

const
  SessionTabBarId* = "session-tab-bar"
  SessionTabBarClass* = "session-tab-bar"
  SessionTabBarSingleClass* = "session-tab-bar single-session"
  SessionTabClass* = "session-tab"
  SessionTabActiveClass* = "session-tab active"
  SessionTabLabelClass* = "session-tab-label"
  SessionTabCloseClass* = "session-tab-close"
  SessionTabAddClass* = "session-tab-add"
  SessionTabOverflowClass* = "session-tab-overflow"
  SessionTabOverflowMenuClass* = "session-tab-overflow-menu"
  SessionTabOverflowItemClass* = "session-tab-overflow-item"
  SessionTabIdPrefix* = "session-tab-"

proc tabBarClass*(tabCount: int): string =
  if tabCount <= 1: SessionTabBarSingleClass else: SessionTabBarClass

proc tabClass*(active: bool): string =
  if active: SessionTabActiveClass else: SessionTabClass

proc invokeSelect(callbacks: SessionTabsCallbacks; index: int) =
  if not callbacks.onSelect.isNil:
    callbacks.onSelect(index)

proc invokeClose(callbacks: SessionTabsCallbacks; index: int) =
  if not callbacks.onClose.isNil:
    callbacks.onClose(index)

proc invokeAdd(callbacks: SessionTabsCallbacks) =
  if not callbacks.onAdd.isNil:
    callbacks.onAdd()

proc renderSessionTab(
    r: MockRenderer;
    tab: SessionTabRecord;
    index: int;
    active: bool;
    multiSession: bool;
    callbacks: SessionTabsCallbacks): MockNode =
  ui(r):
    tdiv(class = tabClass(active),
         id = SessionTabIdPrefix & $index,
         onclick = proc() = callbacks.invokeSelect(index)):
      span(class = SessionTabLabelClass):
        text tab.label
      if multiSession:
        span(class = SessionTabCloseClass,
             onclick = proc() = callbacks.invokeClose(index)):
          text "×"

proc renderAddButton(
    r: MockRenderer;
    callbacks: SessionTabsCallbacks): MockNode =
  ui(r):
    tdiv(class = SessionTabAddClass,
         onclick = proc() = callbacks.invokeAdd()):
      text "+"

proc renderOverflowButton(r: MockRenderer): MockNode =
  ui(r):
    tdiv(class = SessionTabOverflowClass):
      text "v"

proc renderOverflowMenu(
    r: MockRenderer;
    tabs: seq[SessionTabRecord];
    activeIndex: int;
    callbacks: SessionTabsCallbacks): MockNode =
  result = ui(r):
    tdiv(class = SessionTabOverflowMenuClass):
      discard
  for i, tab in tabs:
    let tabIndex = i
    let itemClass = SessionTabOverflowItemClass &
      (if i == activeIndex: " active" else: "")
    let item = ui(r):
      tdiv(class = itemClass,
           onclick = proc() = callbacks.invokeSelect(tabIndex)):
        text tab.label
    r.appendChild(result, item)

when defined(js):
  proc renderSessionTab(
      r: WebRenderer;
      tab: SessionTabRecord;
      index: int;
      active: bool;
      multiSession: bool;
      callbacks: SessionTabsCallbacks): isonim_dom.Element =
    var closeBtn: isonim_dom.Element
    let node = ui(r):
      tdiv(class = tabClass(active),
           id = SessionTabIdPrefix & $index,
           onclick = proc() = callbacks.invokeSelect(index)):
        span(class = SessionTabLabelClass):
          text tab.label
        if multiSession:
          span(ref = closeBtn, class = SessionTabCloseClass):
            text "×"

    if multiSession:
      isonim_dom.addEventListener(isonim_dom.Node(closeBtn), cstring"click",
        proc(ev: isonim_dom.Event) =
          {.emit: "`ev`.stopPropagation();".}
          callbacks.invokeClose(index))
    node

  proc renderAddButton(
      r: WebRenderer;
      callbacks: SessionTabsCallbacks): isonim_dom.Element =
    ui(r):
      tdiv(class = SessionTabAddClass,
           onclick = proc() = callbacks.invokeAdd()):
        text "+"

  proc renderOverflowMenu(
      r: WebRenderer;
      tabs: seq[SessionTabRecord];
      activeIndex: int;
      callbacks: SessionTabsCallbacks): isonim_dom.Element =
    result = ui(r):
      tdiv(class = SessionTabOverflowMenuClass):
        discard
    for i, tab in tabs:
      let tabIndex = i
      let itemClass = SessionTabOverflowItemClass &
        (if i == activeIndex: " active" else: "")
      let item = ui(r):
        tdiv(class = itemClass,
             onclick = proc() = callbacks.invokeSelect(tabIndex)):
          text tab.label
      r.appendChild(result, item)

  proc renderOverflowButton(
      r: WebRenderer): isonim_dom.Element =
    ui(r):
      tdiv(class = SessionTabOverflowClass,
           onclick = proc() =
             {.emit: """
               const bar = document.getElementById('session-tab-bar');
               if (bar) bar.classList.toggle('overflow-open');
             """.}):
        text "v"

proc renderSessionTabsPanel*(
    r: MockRenderer;
    tabs: seq[SessionTabRecord];
    activeIndex: int;
    callbacks: SessionTabsCallbacks = SessionTabsCallbacks()): MockNode =
  let multiSession = tabs.len > 1
  result = ui(r):
    tdiv(id = SessionTabBarId, class = tabBarClass(tabs.len))
  for i, tab in tabs:
    r.appendChild(result,
      renderSessionTab(r, tab, i, i == activeIndex, multiSession, callbacks))
  r.appendChild(result, renderOverflowButton(r))
  r.appendChild(result, renderAddButton(r, callbacks))
  r.appendChild(result, renderOverflowMenu(r, tabs, activeIndex, callbacks))

when defined(js):
  proc renderSessionTabsPanel*(
      r: WebRenderer;
      tabs: seq[SessionTabRecord];
      activeIndex: int;
      callbacks: SessionTabsCallbacks = SessionTabsCallbacks()):
      isonim_dom.Element =
    let multiSession = tabs.len > 1
    result = ui(r):
      tdiv(id = SessionTabBarId, class = tabBarClass(tabs.len))
    for i, tab in tabs:
      r.appendChild(result,
        renderSessionTab(r, tab, i, i == activeIndex, multiSession, callbacks))
    r.appendChild(result, renderOverflowButton(r))
    r.appendChild(result, renderAddButton(r, callbacks))
    r.appendChild(result, renderOverflowMenu(r, tabs, activeIndex, callbacks))

  proc renderSessionTabsInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      tabs: seq[SessionTabRecord];
      activeIndex: int;
      callbacks: SessionTabsCallbacks = SessionTabsCallbacks()) =
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    r.setAttribute(container, "class", tabBarClass(tabs.len))
    let panel = renderSessionTabsPanel(r, tabs, activeIndex, callbacks)
    let panelNode = isonim_dom.Node(panel)
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)

    {.emit: """
      requestAnimationFrame(() => {
        const bar = `container`;
        if (!bar) return;
        const tabs = Array.from(bar.querySelectorAll('.session-tab'));
        const add = bar.querySelector('.session-tab-add');
        const needed = tabs.reduce((sum, el) => sum + el.getBoundingClientRect().width, 0) +
          (add ? add.getBoundingClientRect().width : 0) + 34;
        bar.classList.toggle('has-overflow', needed > bar.clientWidth);
        if (needed <= bar.clientWidth) bar.classList.remove('overflow-open');
      });
    """.}
