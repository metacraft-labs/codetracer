## IsoNim view for the collapsed auto-hide status-bar icon zone.
##
## The status bar owns stable hosts at both ends, refreshed directly through
## this view after status redraws. The pinned-tabs dropdown replaces individual
## panel icons when available.

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
  AutoHideCollapsedIconRecord* = object
    icon*: string
    title*: string

  AutoHideCollapsedIconCallbacks* = object
    restoreFirst*: bool
      ## The sidebar toggle leads the zone (the left edge's, so it sits at the
      ## window's outer edge); otherwise it trails it (the right edge's).
    sidebarOpen*: bool
      ## The sidebar is expanded (normal): the toggle shows the Figma
      ## `icons-lg=sidebar-open` icon, else `icons-lg=sidebar-close`.
    restoreLabel*: string
    onRestore*: proc()
    onSelect*: proc(index: int)
    tabListLabel*: string
      ## The tab-list button (Figma `icons-lg=tab_list_sm`) beside the toggle,
      ## on its inner side.  Shown when `onTabList` is set.
    onTabList*: proc()
      ## Opens / closes the dropdown of the sidebar's pinned tabs.
    tabListOpen*: bool
    tabListItems*: seq[string]
      ## The pinned tabs' titles, in strip order.
    tabListActive*: int
      ## The item whose panel is showing; -1 for none.
    onTabListSelect*: proc(index: int)
    onTabListClose*: proc()
      ## The × (Figma `icons-lg=close-sm`) at the end of the selected row:
      ## closes the panel that is showing.  The tab stays pinned.

const
  AutoHideCollapsedIconZoneClass* = "collapsed-icon-zone"
  AutoHideCollapsedIconZoneWithIconsClass* = "collapsed-icon-zone has-icons"
  AutoHideCollapsedIconClass* = "collapsed-icon"

proc collapsedIconZoneClass*(hasIcons: bool): string =
  if hasIcons:
    AutoHideCollapsedIconZoneWithIconsClass
  else:
    AutoHideCollapsedIconZoneClass

proc invokeSelect(callbacks: AutoHideCollapsedIconCallbacks; index: int) =
  if not callbacks.onSelect.isNil:
    callbacks.onSelect(index)

proc renderCollapsedIcon[R, N](
    r: R;
    icon: AutoHideCollapsedIconRecord;
    index: int;
    callbacks: AutoHideCollapsedIconCallbacks): N =
  ui(r):
    button(
        class = AutoHideCollapsedIconClass,
        `type` = "button",
        `aria-label` = icon.title,
        title = icon.title,
        onclick = proc() = callbacks.invokeSelect(index)):
      text icon.icon

proc restoreButtonClass(callbacks: AutoHideCollapsedIconCallbacks): string =
  ## The sidebar toggle: one button, always at the zone's outer end, drawn as
  ## an icon mask (auto_hide.styl), so it stays put whether the sidebar is
  ## expanded or minimal.
  "collapsed-icon auto-hide-restore-button" &
    (if callbacks.sidebarOpen: " sidebar-open" else: " sidebar-close") &
    (if callbacks.restoreFirst: " sidebar-left" else: " sidebar-right")

proc hasRestore(callbacks: AutoHideCollapsedIconCallbacks): bool =
  not callbacks.onRestore.isNil

proc renderRestoreButton[R, N](r: R; callbacks: AutoHideCollapsedIconCallbacks): N =
  ui(r):
    button(class = restoreButtonClass(callbacks), `type` = "button",
        title = callbacks.restoreLabel, `aria-label` = callbacks.restoreLabel,
        onclick = proc() = callbacks.onRestore())

proc hasTabList(callbacks: AutoHideCollapsedIconCallbacks): bool =
  not callbacks.onTabList.isNil

proc tabListButtonClass(callbacks: AutoHideCollapsedIconCallbacks): string =
  "collapsed-icon auto-hide-tablist-button" &
    (if callbacks.tabListOpen: " open" else: "")

proc tabListMenuClass(callbacks: AutoHideCollapsedIconCallbacks): string =
  ## Opens UP from the status bar, aligned to the zone's outer edge.
  "auto-hide-tablist-menu" &
    (if callbacks.restoreFirst: " align-left" else: " align-right")

proc tabListItemClass(callbacks: AutoHideCollapsedIconCallbacks; index: int): string =
  "ct-menu-item auto-hide-tablist-item" &
    (if index == callbacks.tabListActive: " active" else: "")

proc invokeTabListSelect(callbacks: AutoHideCollapsedIconCallbacks; index: int) =
  if not callbacks.onTabListSelect.isNil:
    callbacks.onTabListSelect(index)

proc renderTabListButton[R, N](r: R; callbacks: AutoHideCollapsedIconCallbacks): N =
  ui(r):
    button(class = tabListButtonClass(callbacks), `type` = "button",
        title = callbacks.tabListLabel, `aria-label` = callbacks.tabListLabel,
        `aria-haspopup` = "menu",
        `aria-expanded` = (if callbacks.tabListOpen: "true" else: "false"),
        onclick = proc() = callbacks.onTabList())

const TabListCloseLabel = "Close panel"

proc showsTabListClose(callbacks: AutoHideCollapsedIconCallbacks; index: int): bool =
  index == callbacks.tabListActive and not callbacks.onTabListClose.isNil

when defined(js):
  proc stopEvent(ev: isonim_dom.Event) {.importjs:
    "(function(e){ e.stopPropagation(); e.preventDefault(); })(#)".}

proc renderTabListItem[R, N](r: R; callbacks: AutoHideCollapsedIconCallbacks;
                             title: string; index: int): N =
  result = ui(r):
    button(class = tabListItemClass(callbacks, index), `type` = "button",
        role = "menuitem", title = title,
        onclick = proc() = callbacks.invokeTabListSelect(index)):
      span(class = "ct-menu-item-label"):
        text title
  if callbacks.showsTabListClose(index):
    var closeEl: N
    let close = ui(r):
      span(ref = closeEl, class = "auto-hide-tablist-close", role = "button",
          title = TabListCloseLabel, `aria-label` = TabListCloseLabel,
          onclick = proc() = callbacks.onTabListClose())
    r.appendChild(result, close)
    when defined(js):
      when N is isonim_dom.Element:
        # Stopped here: the row's click would reopen the panel the × just
        # closed.
        isonim_dom.addEventListener(isonim_dom.Node(closeEl), cstring"click",
          proc(ev: isonim_dom.Event) = ev.stopEvent())

proc renderTabListMenu[R, N](r: R; callbacks: AutoHideCollapsedIconCallbacks): N =
  result = ui(r):
    tdiv(class = tabListMenuClass(callbacks), role = "menu",
        `aria-label` = callbacks.tabListLabel)
  for i, title in callbacks.tabListItems:
    r.appendChild(result, renderTabListItem[R, N](r, callbacks, title, i))

proc renderAutoHideCollapsedIconsPanel*[R, N](
    r: R;
    icons: seq[AutoHideCollapsedIconRecord];
    callbacks: AutoHideCollapsedIconCallbacks =
      AutoHideCollapsedIconCallbacks()): N =
  ## The collapsed-icon zone, for every renderer. `icons` is a value the
  ## caller re-derives and redraws (`renderAutoHideCollapsedIconsInto`).
  result = ui(r):
    tdiv(class = collapsedIconZoneClass(icons.len > 0 or callbacks.hasRestore))
  if callbacks.restoreFirst and callbacks.hasRestore:
    r.appendChild(result, renderRestoreButton[R, N](r, callbacks))
  if callbacks.restoreFirst and callbacks.hasTabList:
    r.appendChild(result, renderTabListButton[R, N](r, callbacks))
  # The dropdown already lists every pinned panel; avoid a duplicate icon row.
  if not callbacks.hasTabList:
    for i, icon in icons:
      r.appendChild(result, renderCollapsedIcon[R, N](r, icon, i, callbacks))
  if not callbacks.restoreFirst and callbacks.hasTabList:
    r.appendChild(result, renderTabListButton[R, N](r, callbacks))
  if not callbacks.restoreFirst and callbacks.hasRestore:
    r.appendChild(result, renderRestoreButton[R, N](r, callbacks))
  if callbacks.hasTabList and callbacks.tabListOpen:
    r.appendChild(result, renderTabListMenu[R, N](r, callbacks))

when defined(js):
  proc renderAutoHideCollapsedIconsInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      icons: seq[AutoHideCollapsedIconRecord];
      callbacks: AutoHideCollapsedIconCallbacks =
        AutoHideCollapsedIconCallbacks()) =
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    isonim_dom.setAttribute(
      container,
      cstring"class",
      cstring collapsedIconZoneClass(icons.len > 0 or callbacks.hasRestore))

    # This view is refreshed into a status-bar host owned by legacy chrome.
    # Move the DSL-rendered children into that stable host.
    let panel = renderAutoHideCollapsedIconsPanel[WebRenderer, isonim_dom.Element](
      r, icons, callbacks)
    let panelNode = isonim_dom.Node(panel)
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)
