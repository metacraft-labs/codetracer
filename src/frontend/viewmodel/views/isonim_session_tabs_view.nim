## IsoNim view for the global multi-session tab bar.
##
## The tab bar lives outside GoldenLayout and outside ``#ROOT`` so session
## switches cannot destroy it.  This view owns the tab DOM structure; callers
## provide plain records derived from ``Data.sessions`` and trigger a refresh
## when that session list, active index, or visible trace label changes.

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
  SessionTabAddTitle* = "New tab"
    ## Accessible name / tooltip of the add-session control.
    ##
    ## `codetracer-specs/GUI/Multi-Window-Tab-Management.md` § Tab Behavior
    ## calls it 'The "+" button' that "opens a new empty tab (for loading a
    ## new trace)".  The plus glyph itself is drawn by
    ## `styles/components/session_tabs.styl` as a background image
    ## (`session_tab_add.svg`), so the button carries no text node; without
    ## this title the control has no name at all for a user hovering it, for
    ## a screen reader, or for a test.
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

when defined(js):
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}

proc renderSessionTab[R, N](
    r: R;
    tab: SessionTabRecord;
    index: int;
    active: bool;
    multiSession: bool;
    callbacks: SessionTabsCallbacks): N =
  var closeBtn: N
  result = ui(r):
    tdiv(class = tabClass(active),
         id = SessionTabIdPrefix & $index,
         onclick = tabSelectHandler(callbacks, index)):
      span(class = SessionTabLabelClass):
        text tab.label
      if multiSession:
        span(ref = closeBtn, class = SessionTabCloseClass,
             onclick = tabCloseHandler(callbacks, index)):
          discard
  when defined(js):
    when N is isonim_dom.Element:
      if multiSession:
        # Stopped here: the tab's own click would select the tab being closed.
        isonim_dom.addEventListener(isonim_dom.Node(closeBtn), cstring"click",
          proc(ev: isonim_dom.Event) = ev.stopPropagation())

proc renderAddButton[R, N](
    r: R;
    callbacks: SessionTabsCallbacks): N =
  ui(r):
    button(class = "ct-button-image-sm-secondary ct-button-no-border session-tab-add",
           title = SessionTabAddTitle,
           onclick = proc() = callbacks.invokeAdd()):
      discard

proc renderOverflowMenu[R, N](
    r: R;
    tabs: seq[SessionTabRecord];
    activeIndex: int;
    callbacks: SessionTabsCallbacks): N =
  result = ui(r):
    tdiv(class = SessionTabOverflowMenuClass):
      discard
  for i, tab in tabs:
    let itemClass = SessionTabOverflowItemClass &
      (if i == activeIndex: " active" else: "")
    let item = ui(r):
      tdiv(class = itemClass,
           onclick = tabSelectHandler(callbacks, i)):
        text tab.label
    r.appendChild(result, item)

proc renderOverflowButton[R, N](
    r: R;
    callbacks: SessionTabsCallbacks): N =
  ui(r):
    tdiv(class = SessionTabOverflowClass,
         onclick = proc() = callbacks.invokeToggleOverflow()):
      text "⌄"

proc renderSessionTabsPanel*[R, N](
    r: R;
    tabs: seq[SessionTabRecord];
    activeIndex: int;
    visibleTabCount: int = -1;
    callbacks: SessionTabsCallbacks = SessionTabsCallbacks()): N =
  ## The session tab bar, for every renderer. `tabs` is a value the caller
  ## re-derives and redraws (`renderSessionTabsInto`). Each handler is built
  ## by a factory (`tabSelectHandler`), so every row's closure owns its index.
  let multiSession = tabs.len > 1
  let visibleCount = normalizedVisibleTabCount(tabs.len, visibleTabCount)
  let visibleIndexes = visibleTabIndexes(tabs.len, activeIndex, visibleCount)
  result = ui(r):
    tdiv(id = SessionTabBarId, class = tabBarClass(tabs.len, visibleCount))
  for i in visibleIndexes:
    r.appendChild(result,
      renderSessionTab[R, N](r, tabs[i], i, i == activeIndex, multiSession,
                             callbacks))
  r.appendChild(result, renderOverflowButton[R, N](r, callbacks))
  r.appendChild(result, renderAddButton[R, N](r, callbacks))
  r.appendChild(result, renderOverflowMenu[R, N](r, tabs, activeIndex, callbacks))

when defined(js):
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
    let panel = renderSessionTabsPanel[WebRenderer, isonim_dom.Element](
      r, tabs, activeIndex, visibleCount, callbacks)
    let panelNode = isonim_dom.Node(panel)
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)
