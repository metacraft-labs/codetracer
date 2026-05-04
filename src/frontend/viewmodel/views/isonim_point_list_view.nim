## views/isonim_point_list_view.nim
##
## IsoNim DOM-rendering view for the Point List (breakpoints /
## tracepoints) panel.
##
## Renders a live, reactive DOM tree driven by `PointListVM` signals.
## Both renderer overloads (Mock and Web) produce the same structure,
## hoisted into a single template that is materialised into one
## concrete proc per renderer.
##
## Structure:
##   div.point-list-component
##     div.point-list-header
##       span.point-list-title             "Points"
##     div.point-list-items                 reactive item list
##     span.point-selected-indicator       text + class reactive
##     span.point-edit-indicator           text + display reactive

import std/options

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/point_list_vm

# ---------------------------------------------------------------------------
# Reactive expressions used inside DSL attributes
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  if cond: "inline" else: "none"

proc selectedIndicatorText(vm: PointListVM): string =
  let sel = vm.selectedPoint.val
  if sel.isSome: "Selected: " & $sel.get else: ""

proc selectedIndicatorClass(vm: PointListVM): string =
  if vm.selectedPoint.val.isSome:
    "point-selected-indicator active"
  else:
    "point-selected-indicator"

proc editIndicatorText(vm: PointListVM): string =
  let editing = vm.editingPoint.val
  if editing.isSome: "Editing: " & $editing.get else: ""

proc pointRowClass(vm: PointListVM; index: int; enabled: bool): string =
  var cls = "point-list-row"
  if vm.selectedPoint.val.isSome and vm.selectedPoint.val.get == index:
    cls.add " selected"
  if not enabled:
    cls.add " disabled"
  cls

proc pointLocationText(point: PointListEntry): string =
  if point.line > 0:
    point.path & ":" & $point.line
  else:
    point.path

proc onPointClick(vm: PointListVM; index: int): proc() =
  let captured = index
  result = proc() = vm.selectPoint(some(captured))

# ---------------------------------------------------------------------------
# Panel template
# ---------------------------------------------------------------------------

template renderPointListPanelImpl(r, vm, rootClass: untyped): untyped =
  ui(r):
    tdiv(class = rootClass):
      tdiv(class = "point-list-header"):
        span(class = "point-list-title"):
          text "Points"
      tdiv(class = "point-list-items"):
        for i, point in vm.points.val:
          tdiv(class = pointRowClass(vm, i, point.enabled),
               onclick = onPointClick(vm, i)):
            span(class = "point-list-kind"):
              text point.kind
            span(class = "point-list-label"):
              text point.label
            span(class = "point-list-location"):
              text pointLocationText(point)
        if vm.points.val.len == 0:
          tdiv(class = "point-list-empty"):
            text "No breakpoints or tracepoints."
      tdiv(class = "point-list-footer"):
        span(class = selectedIndicatorClass(vm)):
          text selectedIndicatorText(vm)
        span(class = "point-edit-indicator",
             display = displayIf(vm.editingPoint.val.isSome)):
          text editIndicatorText(vm)

# ---------------------------------------------------------------------------
# Renderer overloads
# ---------------------------------------------------------------------------

proc renderPointListPanel*(r: MockRenderer; vm: PointListVM): MockNode =
  renderPointListPanelImpl(r, vm, "point-list-component")

when defined(js):
  proc renderPointListPanel*(r: WebRenderer;
                             vm: PointListVM): isonim_dom.Element =
    renderPointListPanelImpl(r, vm, "point-list-component isonim-point-list")

  proc mountIsoNimPointList*(container: isonim_dom.Element;
                             vm: PointListVM) =
    ## Mount the IsoNim Point List panel as a child of `container`.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderPointListPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
