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
    onToggleOverflow*: proc()

const
  SessionTabBarId* = "session-tab-bar"
  SessionTabBarClass* = "session-tab-bar"
  SessionTabBarSingleClass* = "session-tab-bar single-session"
  SessionTabBarOverflowClass* = "session-tab-bar has-overflow"
  SessionTabMinWidthPx* = 96
  SessionTabButtonWidthPx* = 28
  SessionTabHorizontalPaddingPx* = 8
  SessionTabGapPx* = 2
  SessionTabClass* = "session-tab"
  SessionTabActiveClass* = "session-tab active"
  SessionTabLabelClass* = "session-tab-label"
  SessionTabCloseClass* = "session-tab-close"
  SessionTabAddClass* = "session-tab-add"
  SessionTabOverflowClass* = "session-tab-overflow"
  SessionTabOverflowMenuClass* = "session-tab-overflow-menu"
  SessionTabOverflowItemClass* = "session-tab-overflow-item"
  SessionTabIdPrefix* = "session-tab-"

proc normalizedVisibleTabCount*(tabCount, visibleTabCount: int): int =
  if tabCount <= 0:
    0
  elif visibleTabCount < 0:
    tabCount
  else:
    max(0, min(tabCount, visibleTabCount))

proc hasTabOverflow*(tabCount, visibleTabCount: int): bool =
  normalizedVisibleTabCount(tabCount, visibleTabCount) < tabCount

proc visibleTabIndexes*(tabCount, activeIndex, visibleTabCount: int): seq[int] =
  ## Keep a selected tab visible without shrinking tabs below their minimum
  ## width. When an overflowed tab becomes active, it replaces the last visible
  ## tab and pushes that previous tab into the overflow menu.
  let visibleCount = normalizedVisibleTabCount(tabCount, visibleTabCount)
  if visibleCount <= 0:
    return @[]

  let active =
    if activeIndex >= 0 and activeIndex < tabCount: activeIndex
    else: 0
  if active < visibleCount:
    for i in 0 ..< visibleCount:
      result.add(i)
  elif visibleCount == 1:
    result.add(active)
  else:
    for i in 0 ..< visibleCount - 1:
      result.add(i)
    result.add(active)

proc tabBarClass*(tabCount: int; visibleTabCount: int = -1): string =
  if tabCount <= 1:
    SessionTabBarSingleClass
  elif hasTabOverflow(tabCount, visibleTabCount):
    SessionTabBarOverflowClass
  else:
    SessionTabBarClass

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

proc invokeToggleOverflow(callbacks: SessionTabsCallbacks) =
  if not callbacks.onToggleOverflow.isNil:
    callbacks.onToggleOverflow()

proc tabSelectHandler(
    callbacks: SessionTabsCallbacks;
    index: int): proc() =
  let capturedIndex = index
  result = proc() = callbacks.invokeSelect(capturedIndex)

proc tabCloseHandler(
    callbacks: SessionTabsCallbacks;
    index: int): proc() =
  let capturedIndex = index
  result = proc() = callbacks.invokeClose(capturedIndex)

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
      text "⌄"

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
           onclick = tabSelectHandler(callbacks, tabIndex)):
        text tab.label
    r.appendChild(result, item)

when defined(js):
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}

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
          ev.stopPropagation()
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
             onclick = tabSelectHandler(callbacks, tabIndex)):
          text tab.label
      r.appendChild(result, item)

  proc renderOverflowButton(
      r: WebRenderer;
      callbacks: SessionTabsCallbacks): isonim_dom.Element =
    ui(r):
      tdiv(class = SessionTabOverflowClass,
           onclick = proc() = callbacks.invokeToggleOverflow()):
        text "⌄"

proc renderSessionTabsPanel*(
    r: MockRenderer;
    tabs: seq[SessionTabRecord];
    activeIndex: int;
    visibleTabCount: int = -1;
    callbacks: SessionTabsCallbacks = SessionTabsCallbacks()): MockNode =
  let multiSession = tabs.len > 1
  let visibleCount = normalizedVisibleTabCount(tabs.len, visibleTabCount)
  let visibleIndexes = visibleTabIndexes(tabs.len, activeIndex, visibleCount)
  ui(r):
    tdiv(id = SessionTabBarId, class = tabBarClass(tabs.len, visibleCount)):
      for visibleIndex in visibleIndexes:
        let tabIndex = visibleIndex
        let tab = tabs[tabIndex]
        tdiv(class = tabClass(tabIndex == activeIndex),
             id = SessionTabIdPrefix & $tabIndex,
             onclick = tabSelectHandler(callbacks, tabIndex)):
          span(class = SessionTabLabelClass):
            text tab.label
          if multiSession:
            span(class = SessionTabCloseClass,
                 onclick = tabCloseHandler(callbacks, tabIndex)):
              text "×"
      tdiv(class = SessionTabOverflowClass):
        text "⌄"
      tdiv(class = SessionTabAddClass,
           onclick = proc() = callbacks.invokeAdd()):
        text "+"
      tdiv(class = SessionTabOverflowMenuClass):
        for i, tab in tabs:
          let tabIndex = i
          let itemClass = SessionTabOverflowItemClass &
            (if i == activeIndex: " active" else: "")
          tdiv(class = itemClass,
               onclick = tabSelectHandler(callbacks, tabIndex)):
            text tab.label

when defined(js):
  proc renderSessionTabsPanel*(
      r: WebRenderer;
      tabs: seq[SessionTabRecord];
      activeIndex: int;
      visibleTabCount: int = -1;
      callbacks: SessionTabsCallbacks = SessionTabsCallbacks()):
      isonim_dom.Element =
    let multiSession = tabs.len > 1
    let visibleCount = normalizedVisibleTabCount(tabs.len, visibleTabCount)
    let visibleIndexes = visibleTabIndexes(tabs.len, activeIndex, visibleCount)
    result = ui(r):
      tdiv(id = SessionTabBarId, class = tabBarClass(tabs.len, visibleCount))
    for i in visibleIndexes:
      let tab = tabs[i]
      r.appendChild(result,
        renderSessionTab(r, tab, i, i == activeIndex, multiSession, callbacks))
    r.appendChild(result, renderOverflowButton(r, callbacks))
    r.appendChild(result, renderAddButton(r, callbacks))
    r.appendChild(result, renderOverflowMenu(r, tabs, activeIndex, callbacks))

  proc renderSessionTabsInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      tabs: seq[SessionTabRecord];
      activeIndex: int;
      visibleTabCount: int = -1;
      callbacks: SessionTabsCallbacks = SessionTabsCallbacks()) =
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    let visibleCount = normalizedVisibleTabCount(tabs.len, visibleTabCount)
    r.setAttribute(container, "class", tabBarClass(tabs.len, visibleCount))
    let panel = renderSessionTabsPanel(
      r, tabs, activeIndex, visibleCount, callbacks)
    let panelNode = isonim_dom.Node(panel)
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)
