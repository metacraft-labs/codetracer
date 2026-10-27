## IsoNim view for left/right auto-hide side strips.
##
## The strip hosts are static DOM nodes in index.html. This view renders the
## host class state and either vertical text tabs or the collapsed click line,
## preserving the legacy selector contract used by layout and GUI tests.

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
  AutoHideSideStripRecord* = object
    title*: string
    active*: bool
    ## Opened by a click (docked, or the overlay pinned open) rather than shown
    ## as a hover preview.  Only such a tab gets the × (Nikolay, 2026-10-17):
    ## a preview closes itself when the pointer leaves.
    pinned*: bool

  AutoHideSideStripCallbacks* = object
    modeLabel*: string
    modeGlyph*: string
    onToggleMode*: proc()
    onSelect*: proc(index: int)
    onClose*: proc(index: int)
    onUnpin*: proc(index: int)
    ## The × on the active tab: hide its panel, keeping the tab pinned — what
    ## the × on the selected row of the status bar's tab-list menu does.
    onHide*: proc(index: int)
    onCollapsedSelect*: proc()
    ## Called when the mouse enters the collapsed line — starts the same
    ## hover-preview timer a tab does, so the line opens its edge's overlay
    ## (with the edge's tabs down its side) on hover as well as on click.
    onCollapsedHoverEnter*: proc()
    ## Called when mouse enters a tab — starts the hover-preview timer.
    onHoverEnter*: proc(index: int)
    ## Called when mouse leaves a tab — cancels the pending hover-preview timer.
    onHoverLeave*: proc(index: int)
    ## Called on right-click with the tab index and mouse viewport coordinates.
    onContextMenu*: proc(index: int; x: int; y: int)

const
  AutoHideSideStripHasTabsClass* = "has-tabs"
  AutoHideSideStripCollapsedClass* = "has-tabs collapsed-mode"
  AutoHideSideStripTabClass* = "auto-hide-strip-tab"
  AutoHideSideStripTabActiveClass* = "auto-hide-strip-tab active"
  AutoHideSideStripTabLabelClass* = "auto-hide-strip-tab-label"
  ## The × on the active tab (Nikolay, 2026-10-16): the same `close_sm` icon
  ## and behaviour as `auto-hide-tablist-close` in the status bar's tab-list
  ## menu — it hides the panel that is showing and leaves the tab pinned.
  AutoHideSideStripTabHideClass* = "auto-hide-strip-tab-hide"
  HideTabLabel = "Close panel"
  ## The four button classes below have **no producer**.  `f214d703b` added
  ## the tab context menu and `1af471302` then removed the inline close /
  ## unpin buttons from `renderSideStripTab`, so a strip tab is now just its
  ## label span and the context menu is the only close/unpin affordance on
  ## any strip, side or bottom.  They are kept because `auto_hide.styl` still
  ## carries the matching rules and the names must stay in step if the inline
  ## buttons ever return; do not read them as evidence that tabs have buttons.
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

proc invokeHide(callbacks: AutoHideSideStripCallbacks; index: int) =
  if not callbacks.onHide.isNil:
    callbacks.onHide(index)

proc showsHide(callbacks: AutoHideSideStripCallbacks; tab: AutoHideSideStripRecord): bool =
  tab.active and tab.pinned and not callbacks.onHide.isNil

proc invokeUnpin(callbacks: AutoHideSideStripCallbacks; index: int) =
  if not callbacks.onUnpin.isNil:
    callbacks.onUnpin(index)

proc invokeCollapsedHoverEnter(callbacks: AutoHideSideStripCallbacks) =
  if not callbacks.onCollapsedHoverEnter.isNil:
    callbacks.onCollapsedHoverEnter()

proc invokeCollapsedSelect(callbacks: AutoHideSideStripCallbacks) =
  if not callbacks.onCollapsedSelect.isNil:
    callbacks.onCollapsedSelect()

proc invokeHoverEnter(callbacks: AutoHideSideStripCallbacks; index: int) =
  if not callbacks.onHoverEnter.isNil:
    callbacks.onHoverEnter(index)

proc invokeHoverLeave(callbacks: AutoHideSideStripCallbacks; index: int) =
  if not callbacks.onHoverLeave.isNil:
    callbacks.onHoverLeave(index)

proc invokeContextMenu(callbacks: AutoHideSideStripCallbacks; index: int; x: int; y: int) =
  if not callbacks.onContextMenu.isNil:
    callbacks.onContextMenu(index, x, y)

when defined(js):
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}
  proc preventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}
  proc eventClientX(ev: isonim_dom.Event): int {.importcpp: "(#.clientX || 0)".}
  proc eventClientY(ev: isonim_dom.Event): int {.importcpp: "(#.clientY || 0)".}

proc renderSideStripTab[R, N](
    r: R;
    tab: AutoHideSideStripRecord;
    index: int;
    callbacks: AutoHideSideStripCallbacks): N =
  let cls = if tab.active: AutoHideSideStripTabActiveClass
            else: AutoHideSideStripTabClass
  var tabEl: N
  result = ui(r):
    tdiv(ref = tabEl,
         class = cls,
         onclick = proc() = callbacks.invokeSelect(index)):
      span(class = AutoHideSideStripTabLabelClass):
        text tab.title
  if callbacks.showsHide(tab):
    var hideEl: N
    let hide = ui(r):
      span(ref = hideEl, class = AutoHideSideStripTabHideClass, role = "button",
          title = HideTabLabel, `aria-label` = HideTabLabel,
          onclick = proc() = callbacks.invokeHide(index))
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
          callbacks.invokeHoverEnter(index))
      isonim_dom.addEventListener(isonim_dom.Node(tabEl), cstring"mouseleave",
        proc(ev: isonim_dom.Event) =
          callbacks.invokeHoverLeave(index))
      isonim_dom.addEventListener(isonim_dom.Node(tabEl), cstring"contextmenu",
        proc(ev: isonim_dom.Event) =
          ev.preventDefault()
          ev.stopPropagation()
          callbacks.invokeContextMenu(index, ev.eventClientX(), ev.eventClientY()))

proc renderCollapsedLine[R, N](
    r: R;
    callbacks: AutoHideSideStripCallbacks): N =
  ui(r):
    tdiv(
        class = AutoHideCollapsedStripLineClass,
        onclick = proc() = callbacks.invokeCollapsedSelect(),
        onmouseenter = proc() = callbacks.invokeCollapsedHoverEnter())

proc renderModeButton[R, N](r: R; callbacks: AutoHideSideStripCallbacks): N =
  ui(r):
    button(class = "auto-hide-mode-button", `type` = "button",
        title = callbacks.modeLabel, `aria-label` = callbacks.modeLabel,
        onclick = proc() = callbacks.onToggleMode()):
      text callbacks.modeGlyph

proc renderAutoHideSideStripPanel*[R, N](
    r: R;
    tabs: seq[AutoHideSideStripRecord];
    collapsed: bool;
    callbacks: AutoHideSideStripCallbacks =
      AutoHideSideStripCallbacks()): N =
  ## The side strip, for every renderer. `tabs` is a value the caller
  ## re-derives and redraws (`renderAutoHideSideStripInto`).
  result = ui(r):
    tdiv(class = sideStripClass(tabs.len > 0, collapsed and tabs.len > 0))
  if collapsed:
    r.appendChild(result, renderCollapsedLine[R, N](r, callbacks))
  else:
    for i, tab in tabs:
      r.appendChild(result, renderSideStripTab[R, N](r, tab, i, callbacks))
    if tabs.len > 0 and not callbacks.onToggleMode.isNil:
      r.appendChild(result, renderModeButton[R, N](r, callbacks))

when defined(js):
  proc renderAutoHideSideStripInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      tabs: seq[AutoHideSideStripRecord];
      collapsed: bool;
      callbacks: AutoHideSideStripCallbacks =
        AutoHideSideStripCallbacks();
      revealed = false;
      revealClosing = false) =
    ## `revealed`: a minimal edge shown with its tabs while one of its panels
    ## is open — `revealed` keeps the strip's layout footprint at the thin
    ## line's (auto_hide.styl) so the tabs float over the layout instead of
    ## pushing it; `revealClosing` slides it out with the panel.
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    var cls = sideStripClass(tabs.len > 0, collapsed and tabs.len > 0)
    if revealed and not collapsed and tabs.len > 0:
      cls.add(" revealed")
      if revealClosing:
        cls.add(" reveal-closing")
    isonim_dom.setAttribute(container, cstring"class", cstring cls)

    let panel = renderAutoHideSideStripPanel[WebRenderer, isonim_dom.Element](
      r, tabs, collapsed, callbacks)
    let panelNode = isonim_dom.Node(panel)
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)
