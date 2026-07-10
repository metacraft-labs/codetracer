## IsoNim view for the bottom auto-hide strip.
##
## Mirrors isonim_auto_hide_side_strip_view but lays tabs out horizontally
## inside the status bar.  Curves appear on the TOP side of the active tab
## (the open end faces the docked panel / GL content above).
##
## Uses the same CSS classes as the side strip (.auto-hide-strip-tab, etc.)
## so shared button, label, and state styles are inherited automatically.
## Bottom-specific overrides live in auto_hide.styl under #auto-hide-bottom-strip.

import isonim/dsl/ui
from isonim/core/computation import createRenderEffect
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

# Re-export the same record / callback types as the side strip so callers
# share a single type and auto_hide.nim doesn't need two callback structs.
type
  AutoHideBottomStripRecord* = object
    title*: string
    active*: bool

  AutoHideBottomStripCallbacks* = object
    onSelect*: proc(index: int)
    onClose*: proc(index: int)
    onUnpin*: proc(index: int)
    ## Called when mouse enters a tab — starts the 200ms hover-preview timer.
    onHoverEnter*: proc(index: int)
    ## Called on right-click with the tab index and mouse viewport coordinates.
    onContextMenu*: proc(index: int; x: int; y: int)

const
  ## Class applied to #auto-hide-bottom-strip when it contains at least one tab.
  AutoHideBottomStripHasTabsClass* = "has-tabs"
  ## Shared tab classes — same as side strip so button/label CSS is reused.
  AutoHideBottomStripTabClass*         = "auto-hide-strip-tab"
  AutoHideBottomStripTabActiveClass*   = "auto-hide-strip-tab active"
  AutoHideBottomStripTabLabelClass*    = "auto-hide-strip-tab-label"
  AutoHideBottomStripTabButtonsClass*  = "auto-hide-strip-tab-buttons"
  AutoHideBottomStripTabCloseBtnClass* = "auto-hide-strip-tab-btn auto-hide-strip-tab-close"
  AutoHideBottomStripTabUnpinBtnClass* = "auto-hide-strip-tab-btn auto-hide-strip-tab-unpin"

proc invokeSelect(cb: AutoHideBottomStripCallbacks; i: int) =
  if not cb.onSelect.isNil: cb.onSelect(i)

proc invokeClose(cb: AutoHideBottomStripCallbacks; i: int) =
  if not cb.onClose.isNil: cb.onClose(i)

proc invokeUnpin(cb: AutoHideBottomStripCallbacks; i: int) =
  if not cb.onUnpin.isNil: cb.onUnpin(i)

proc invokeHoverEnter(cb: AutoHideBottomStripCallbacks; i: int) =
  if not cb.onHoverEnter.isNil: cb.onHoverEnter(i)

proc invokeContextMenu(cb: AutoHideBottomStripCallbacks; i: int; x: int; y: int) =
  if not cb.onContextMenu.isNil: cb.onContextMenu(i, x, y)

# ---------------------------------------------------------------------------
# MockRenderer path (for tests)
# ---------------------------------------------------------------------------

proc renderBottomStripTab(
    r: MockRenderer;
    tab: AutoHideBottomStripRecord;
    index: int;
    cb: AutoHideBottomStripCallbacks): MockNode =
  let cls = if tab.active: AutoHideBottomStripTabActiveClass
            else: AutoHideBottomStripTabClass
  ui(r):
    tdiv(class = cls, onclick = proc() = cb.invokeSelect(index)):
      span(class = AutoHideBottomStripTabLabelClass):
        text tab.title

proc renderAutoHideBottomStripPanel*(
    r: MockRenderer;
    tabs: seq[AutoHideBottomStripRecord];
    cb: AutoHideBottomStripCallbacks = AutoHideBottomStripCallbacks()): MockNode =
  result = ui(r):
    tdiv(class = if tabs.len > 0: AutoHideBottomStripHasTabsClass else: "")
  for i, tab in tabs:
    r.appendChild(result, renderBottomStripTab(r, tab, i, cb))

# ---------------------------------------------------------------------------
# WebRenderer path (live DOM)
# ---------------------------------------------------------------------------

when defined(js):
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}
  proc preventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}
  proc eventClientX(ev: isonim_dom.Event): int {.importcpp: "(#.clientX || 0)".}
  proc eventClientY(ev: isonim_dom.Event): int {.importcpp: "(#.clientY || 0)".}

  proc renderBottomStripTab(
      r: WebRenderer;
      tab: AutoHideBottomStripRecord;
      index: int;
      cb: AutoHideBottomStripCallbacks): isonim_dom.Element =
    let cls = if tab.active: AutoHideBottomStripTabActiveClass
              else: AutoHideBottomStripTabClass
    # mouseenter on the tab triggers the 200ms hover-preview timer.
    var tabEl: isonim_dom.Element
    result = ui(r):
      tdiv(ref = tabEl,
           class = cls,
           onclick = proc() = cb.invokeSelect(index)):
        span(class = AutoHideBottomStripTabLabelClass):
          text tab.title
    isonim_dom.addEventListener(isonim_dom.Node(tabEl), cstring"mouseenter",
      proc(ev: isonim_dom.Event) =
        cb.invokeHoverEnter(index))
    isonim_dom.addEventListener(isonim_dom.Node(tabEl), cstring"contextmenu",
      proc(ev: isonim_dom.Event) =
        ev.preventDefault()
        ev.stopPropagation()
        cb.invokeContextMenu(index, ev.eventClientX(), ev.eventClientY()))

  proc renderAutoHideBottomStripPanel*(
      r: WebRenderer;
      tabs: seq[AutoHideBottomStripRecord];
      cb: AutoHideBottomStripCallbacks = AutoHideBottomStripCallbacks()): isonim_dom.Element =
    result = ui(r):
      tdiv(class = if tabs.len > 0: AutoHideBottomStripHasTabsClass else: "")
    for i, tab in tabs:
      r.appendChild(result, renderBottomStripTab(r, tab, i, cb))

  proc renderAutoHideBottomStripInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      tabs: seq[AutoHideBottomStripRecord];
      cb: AutoHideBottomStripCallbacks = AutoHideBottomStripCallbacks()) =
    ## Replace the container's children with a fresh bottom strip render.
    ## Also updates the container's class (has-tabs / empty) to match state.
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    isonim_dom.setAttribute(
      container,
      cstring"class",
      cstring(if tabs.len > 0: AutoHideBottomStripHasTabsClass else: ""))

    let panel = renderAutoHideBottomStripPanel(r, tabs, cb)
    let panelNode = isonim_dom.Node(panel)
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)
