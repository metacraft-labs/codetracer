## IsoNim view for the collapsed auto-hide status-bar icon zone.
##
## The status bar remains a Karax shell, but its leftmost collapsed-icon host is
## refreshed directly through this view after status redraws.  Each icon opens
## the corresponding side-pinned auto-hide panel.

import isonim/dsl/ui
from isonim/core/computation import createRenderEffect
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

type
  AutoHideCollapsedIconRecord* = object
    icon*: string
    title*: string

  AutoHideCollapsedIconCallbacks* = object
    onSelect*: proc(index: int)

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

proc renderCollapsedIcon(
    r: MockRenderer;
    icon: AutoHideCollapsedIconRecord;
    index: int;
    callbacks: AutoHideCollapsedIconCallbacks): MockNode =
  ui(r):
    tdiv(
        class = AutoHideCollapsedIconClass,
        title = icon.title,
        onclick = proc() = callbacks.invokeSelect(index)):
      text icon.icon

when defined(js):
  proc renderCollapsedIcon(
      r: WebRenderer;
      icon: AutoHideCollapsedIconRecord;
      index: int;
      callbacks: AutoHideCollapsedIconCallbacks): isonim_dom.Element =
    ui(r):
      tdiv(
          class = AutoHideCollapsedIconClass,
          title = icon.title,
          onclick = proc() = callbacks.invokeSelect(index)):
        text icon.icon

proc renderAutoHideCollapsedIconsPanel*(
    r: MockRenderer;
    icons: seq[AutoHideCollapsedIconRecord];
    callbacks: AutoHideCollapsedIconCallbacks =
      AutoHideCollapsedIconCallbacks()): MockNode =
  result = ui(r):
    tdiv(class = collapsedIconZoneClass(icons.len > 0))
  for i, icon in icons:
    r.appendChild(result, renderCollapsedIcon(r, icon, i, callbacks))

when defined(js):
  proc renderAutoHideCollapsedIconsPanel*(
      r: WebRenderer;
      icons: seq[AutoHideCollapsedIconRecord];
      callbacks: AutoHideCollapsedIconCallbacks =
        AutoHideCollapsedIconCallbacks()): isonim_dom.Element =
    result = ui(r):
      tdiv(class = collapsedIconZoneClass(icons.len > 0))
    for i, icon in icons:
      r.appendChild(result, renderCollapsedIcon(r, icon, i, callbacks))

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
      cstring collapsedIconZoneClass(icons.len > 0))

    let panel = renderAutoHideCollapsedIconsPanel(r, icons, callbacks)
    let panelNode = isonim_dom.Node(panel)
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)
