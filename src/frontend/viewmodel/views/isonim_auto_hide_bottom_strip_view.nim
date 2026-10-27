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
import isonim/core/[signals, computation]
import isonim/dsl/components
import isonim/testing/mock_dom

# The generic procs expand the DSL at their caller.
export signals, computation, components

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

# Re-export the same record / callback types as the side strip so callers
# share a single type and auto_hide.nim doesn't need two callback structs.
type
  AutoHideBottomStripRecord* = object
    title*: string
    active*: bool
    ## Opened by a click, not a hover preview — only then the × shows, as on
    ## the side strips (`AutoHideSideStripRecord.pinned`).
    pinned*: bool

  AutoHideBottomStripCallbacks* = object
    onSelect*: proc(index: int)
    onClose*: proc(index: int)
    onUnpin*: proc(index: int)
    ## The × on the active tab: hide its panel, keeping the tab pinned — as
    ## the × on an active side-strip tab does (`isonim_auto_hide_side_strip_view`).
    onHide*: proc(index: int)
    ## Called when mouse enters a tab — starts the hover-preview timer.
    onHoverEnter*: proc(index: int)
    ## Called when mouse leaves a tab — cancels the pending hover-preview timer.
    onHoverLeave*: proc(index: int)
    ## Called on right-click with the tab index and mouse viewport coordinates.
    onContextMenu*: proc(index: int; x: int; y: int)

const
  ## Semantic class the status-bar shell gives the host
  ## (`isonim_status_view.BottomStripClass`).  Repeated here because
  ## `renderAutoHideBottomStripInto` rewrites the host's `class` attribute
  ## and must not drop it: before this, every strip mount replaced
  ## `class="auto-hide-bottom-strip"` with `class="has-tabs"` (or ""), and
  ## every status-bar render put it back, so the host's class flip-flopped
  ## and `.auto-hide-bottom-strip` matched or did not match depending on
  ## which render ran last.
  AutoHideBottomStripHostClass* = "auto-hide-bottom-strip"
  ## Class applied to #auto-hide-bottom-strip when it contains at least one tab.
  AutoHideBottomStripHasTabsClass* = "has-tabs"
  ## Shared tab classes — same as side strip so button/label CSS is reused.
  AutoHideBottomStripTabClass*         = "auto-hide-strip-tab"
  AutoHideBottomStripTabActiveClass*   = "auto-hide-strip-tab active"
  AutoHideBottomStripTabLabelClass*    = "auto-hide-strip-tab-label"
  ## The × on the active tab (Nikolay, 2026-10-17): the side strips' class and
  ## icon, after the label.
  AutoHideBottomStripTabHideClass*     = "auto-hide-strip-tab-hide"
  HideTabLabel = "Close panel"
  ## The three button classes below have **no producer**.  This file used to
  ## render inline close / unpin buttons on every tab; `1af471302` deleted them
  ## here and from `isonim_auto_hide_side_strip_view` in the same commit, in
  ## favour of the tab context menu `f214d703b` had added earlier that day.  So
  ## `renderBottomStripTab` emits only the label span, and a bottom tab's close
  ## and unpin affordances live in the right-click menu that
  ## `auto_hide.requestAutoHideBottomStripRender` builds.  The names are kept
  ## because `auto_hide.styl` still carries the matching
  ## `#auto-hide-bottom-strip .auto-hide-strip-tab-buttons` override and must
  ## stay in step if inline buttons ever return; do not read them as evidence
  ## that the bottom tabs have buttons today.
  AutoHideBottomStripTabButtonsClass*  = "auto-hide-strip-tab-buttons"
  AutoHideBottomStripTabCloseBtnClass* = "auto-hide-strip-tab-btn auto-hide-strip-tab-close"
  AutoHideBottomStripTabUnpinBtnClass* = "auto-hide-strip-tab-btn auto-hide-strip-tab-unpin"

proc invokeSelect(cb: AutoHideBottomStripCallbacks; i: int) =
  if not cb.onSelect.isNil: cb.onSelect(i)

proc invokeClose(cb: AutoHideBottomStripCallbacks; i: int) =
  if not cb.onClose.isNil: cb.onClose(i)

proc invokeHide(cb: AutoHideBottomStripCallbacks; i: int) =
  if not cb.onHide.isNil: cb.onHide(i)

proc showsHide(cb: AutoHideBottomStripCallbacks; tab: AutoHideBottomStripRecord): bool =
  tab.active and tab.pinned and not cb.onHide.isNil

proc invokeUnpin(cb: AutoHideBottomStripCallbacks; i: int) =
  if not cb.onUnpin.isNil: cb.onUnpin(i)

proc invokeHoverEnter(cb: AutoHideBottomStripCallbacks; i: int) =
  if not cb.onHoverEnter.isNil: cb.onHoverEnter(i)

proc invokeHoverLeave(cb: AutoHideBottomStripCallbacks; i: int) =
  if not cb.onHoverLeave.isNil: cb.onHoverLeave(i)

proc invokeContextMenu(cb: AutoHideBottomStripCallbacks; i: int; x: int; y: int) =
  if not cb.onContextMenu.isNil: cb.onContextMenu(i, x, y)

when defined(js):
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}
  proc preventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}
  proc eventClientX(ev: isonim_dom.Event): int {.importcpp: "(#.clientX || 0)".}
  proc eventClientY(ev: isonim_dom.Event): int {.importcpp: "(#.clientY || 0)".}

# ---------------------------------------------------------------------------
# One tab, and the strip, for every renderer
# ---------------------------------------------------------------------------

proc renderBottomStripTab[R, N](
    r: R;
    tab: AutoHideBottomStripRecord;
    index: int;
    cb: AutoHideBottomStripCallbacks): N =
  let cls = if tab.active: AutoHideBottomStripTabActiveClass
            else: AutoHideBottomStripTabClass
  var tabEl: N
  result = ui(r):
    tdiv(ref = tabEl,
         class = cls,
         onclick = proc() = cb.invokeSelect(index)):
      span(class = AutoHideBottomStripTabLabelClass):
        text tab.title
  if cb.showsHide(tab):
    var hideEl: N
    let hide = ui(r):
      span(ref = hideEl, class = AutoHideBottomStripTabHideClass, role = "button",
          title = HideTabLabel, `aria-label` = HideTabLabel,
          onclick = proc() = cb.invokeHide(index))
    r.appendChild(result, hide)
    when defined(js):
      when N is isonim_dom.Element:
        # Stopped here: the tab's click would reopen the panel the × just
        # closed.
        isonim_dom.addEventListener(isonim_dom.Node(hideEl), cstring"click",
          proc(ev: isonim_dom.Event) =
            ev.preventDefault()
            ev.stopPropagation())
  when defined(js):
    when N is isonim_dom.Element:
      # mouseenter on the tab triggers the 200ms hover-preview timer.
      isonim_dom.addEventListener(isonim_dom.Node(tabEl), cstring"mouseenter",
        proc(ev: isonim_dom.Event) =
          cb.invokeHoverEnter(index))
      isonim_dom.addEventListener(isonim_dom.Node(tabEl), cstring"mouseleave",
        proc(ev: isonim_dom.Event) =
          cb.invokeHoverLeave(index))
      isonim_dom.addEventListener(isonim_dom.Node(tabEl), cstring"contextmenu",
        proc(ev: isonim_dom.Event) =
          ev.preventDefault()
          ev.stopPropagation()
          cb.invokeContextMenu(index, ev.eventClientX(), ev.eventClientY()))

proc renderAutoHideBottomStripPanel*[R, N](
    r: R;
    tabs: seq[AutoHideBottomStripRecord];
    cb: AutoHideBottomStripCallbacks = AutoHideBottomStripCallbacks()): N =
  ## The bottom strip, for every renderer. `tabs` is a value the caller
  ## re-derives and redraws (`renderAutoHideBottomStripInto`).
  result = ui(r):
    tdiv(class = if tabs.len > 0: AutoHideBottomStripHasTabsClass else: "")
  for i, tab in tabs:
    r.appendChild(result, renderBottomStripTab[R, N](r, tab, i, cb))

when defined(js):
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
      cstring(
        if tabs.len > 0:
          AutoHideBottomStripHostClass & " " & AutoHideBottomStripHasTabsClass
        else:
          AutoHideBottomStripHostClass))

    let panel = renderAutoHideBottomStripPanel[WebRenderer, isonim_dom.Element](
      r, tabs, cb)
    let panelNode = isonim_dom.Node(panel)
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)
