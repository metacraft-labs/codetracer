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
    active*: bool

  AutoHideSideStripCallbacks* = object
    onSelect*: proc(index: int)
    onClose*: proc(index: int)
    onUnpin*: proc(index: int)
    onCollapsedSelect*: proc()
    ## Called when mouse enters a tab. Used to trigger the 200ms hover preview.
    onHoverEnter*: proc(index: int)
    ## Called on right-click with the tab index and mouse viewport coordinates.
    onContextMenu*: proc(index: int; x: int; y: int)

const
  AutoHideSideStripHasTabsClass* = "has-tabs"
  AutoHideSideStripCollapsedClass* = "has-tabs collapsed-mode"
  AutoHideSideStripTabClass* = "auto-hide-strip-tab"
  AutoHideSideStripTabActiveClass* = "auto-hide-strip-tab active"
  AutoHideSideStripTabLabelClass* = "auto-hide-strip-tab-label"
  AutoHideSideStripTabButtonsClass* = "auto-hide-strip-tab-buttons"
  AutoHideSideStripTabBtnClass* = "auto-hide-strip-tab-btn"
  AutoHideSideStripTabCloseBtnClass* = "auto-hide-strip-tab-btn auto-hide-strip-tab-close"
  AutoHideSideStripTabUnpinBtnClass* = "auto-hide-strip-tab-btn auto-hide-strip-tab-unpin"
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

proc invokeClose(callbacks: AutoHideSideStripCallbacks; index: int) =
  if not callbacks.onClose.isNil:
    callbacks.onClose(index)

proc invokeUnpin(callbacks: AutoHideSideStripCallbacks; index: int) =
  if not callbacks.onUnpin.isNil:
    callbacks.onUnpin(index)

proc invokeCollapsedSelect(callbacks: AutoHideSideStripCallbacks) =
  if not callbacks.onCollapsedSelect.isNil:
    callbacks.onCollapsedSelect()

proc invokeHoverEnter(callbacks: AutoHideSideStripCallbacks; index: int) =
  if not callbacks.onHoverEnter.isNil:
    callbacks.onHoverEnter(index)

proc invokeContextMenu(callbacks: AutoHideSideStripCallbacks; index: int; x: int; y: int) =
  if not callbacks.onContextMenu.isNil:
    callbacks.onContextMenu(index, x, y)

proc renderSideStripTab(
    r: MockRenderer;
    tab: AutoHideSideStripRecord;
    index: int;
    callbacks: AutoHideSideStripCallbacks): MockNode =
  let cls = if tab.active: AutoHideSideStripTabActiveClass
            else: AutoHideSideStripTabClass
  # Buttons are always rendered (CSS controls visibility via :hover / .active).
  # They sit at the TOP of the tab so they appear above the text label.
  ui(r):
    tdiv(
        class = cls,
        onclick = proc() = callbacks.invokeSelect(index)):
      tdiv(class = AutoHideSideStripTabButtonsClass):
        tdiv(class = AutoHideSideStripTabCloseBtnClass,
             title = "Close",
             onclick = proc() = callbacks.invokeClose(index))
        tdiv(class = AutoHideSideStripTabUnpinBtnClass,
             title = "Unpin (restore to layout)",
             onclick = proc() = callbacks.invokeUnpin(index))
      span(class = AutoHideSideStripTabLabelClass):
        text tab.title

proc renderCollapsedLine(
    r: MockRenderer;
    callbacks: AutoHideSideStripCallbacks): MockNode =
  ui(r):
    tdiv(
        class = AutoHideCollapsedStripLineClass,
        onclick = proc() = callbacks.invokeCollapsedSelect())

when defined(js):
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}
  proc preventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}
  proc eventClientX(ev: isonim_dom.Event): int {.importcpp: "(#.clientX || 0)".}
  proc eventClientY(ev: isonim_dom.Event): int {.importcpp: "(#.clientY || 0)".}

  proc renderSideStripTab(
      r: WebRenderer;
      tab: AutoHideSideStripRecord;
      index: int;
      callbacks: AutoHideSideStripCallbacks): isonim_dom.Element =
    let cls = if tab.active: AutoHideSideStripTabActiveClass
              else: AutoHideSideStripTabClass
    # Buttons are always rendered (CSS controls visibility via :hover / .active).
    # They sit at the TOP of the tab div above the text label.
    # Both buttons use manual addEventListener with stopPropagation so that
    # clicking a button on an inactive tab doesn't also trigger showOverlay.
    # mouseenter on the tab itself triggers the 200ms hover-preview timer.
    var tabEl: isonim_dom.Element
    var closeBtnEl: isonim_dom.Element
    var unpinBtnEl: isonim_dom.Element
    result = ui(r):
      tdiv(ref = tabEl,
           class = cls,
           onclick = proc() = callbacks.invokeSelect(index)):
        tdiv(class = AutoHideSideStripTabButtonsClass):
          tdiv(ref = closeBtnEl,
               class = AutoHideSideStripTabCloseBtnClass,
               title = "Close")
          tdiv(ref = unpinBtnEl,
               class = AutoHideSideStripTabUnpinBtnClass,
               title = "Unpin (restore to layout)")
        span(class = AutoHideSideStripTabLabelClass):
          text tab.title
    isonim_dom.addEventListener(isonim_dom.Node(tabEl), cstring"mouseenter",
      proc(ev: isonim_dom.Event) =
        callbacks.invokeHoverEnter(index))
    isonim_dom.addEventListener(isonim_dom.Node(tabEl), cstring"contextmenu",
      proc(ev: isonim_dom.Event) =
        ev.preventDefault()
        ev.stopPropagation()
        callbacks.invokeContextMenu(index, ev.eventClientX(), ev.eventClientY()))
    isonim_dom.addEventListener(isonim_dom.Node(closeBtnEl), cstring"click",
      proc(ev: isonim_dom.Event) =
        ev.stopPropagation()
        callbacks.invokeClose(index))
    isonim_dom.addEventListener(isonim_dom.Node(unpinBtnEl), cstring"click",
      proc(ev: isonim_dom.Event) =
        ev.stopPropagation()
        callbacks.invokeUnpin(index))

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
