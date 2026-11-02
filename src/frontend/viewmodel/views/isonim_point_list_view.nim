## views/isonim_point_list_view.nim
##
## IsoNim DOM-rendering view for the Point List (breakpoints /
## tracepoints) panel.
##
## Renders a live, reactive DOM tree driven by `PointListVM` signals: one
## generic view (`renderPointListPanel[R, N]`) for every renderer, mounted on
## the desktop by `ui/panel_host`.
##
## Structure:
##   div.point-list-component
##     div.point-list-header
##       span.point-list-title             "Points"
##     div.point-list-items                 indexEach over the points
##     div.point-list-empty                 shown while there are none
##     span.point-selected-indicator       text + class reactive
##     span.point-edit-indicator           text + display reactive

import std/options
when defined(js):
  # Enter and Space on a `role="button"` row are its click.
  import ./isonim_activation

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  # The DSL's calls on a `WebRenderer` resolve where the generic view is
  # instantiated; the overloads must be in scope there.
  import isonim/web/web_renderer

import ../viewmodels/point_list_vm

# The generic view expands the DSL (`val=`, `createRenderEffect`, `indexEach`)
# where it is instantiated.
export signals, computation, components

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
# The panel
# ---------------------------------------------------------------------------

proc emptyDisplay(vm: PointListVM): string =
  if vm.points.val.len == 0: "block" else: "none"

proc renderPointRow[R, N](r: R; vm: PointListVM; point: proc(): PointListEntry;
                          index: int): N =
  ## One point. `indexEach` reuses a row for whatever point now sits at
  ## `index`, so every attribute and text reads `point()`.
  ui(r):
    tdiv(role = "button", tabindex = "0", class = pointRowClass(vm, index, point().enabled),
         onclick = onPointClick(vm, index)):
      span(class = "point-list-kind"):
        text point().kind
      span(class = "point-list-label"):
        text point().label
      span(class = "point-list-location"):
        text pointLocationText(point())

proc renderPointListPanel*[R, N](r: R; vm: PointListVM): N =
  ## The Point List panel, under any renderer (Shared-DOM-Front-Ends D3).
  ## The rows are an `indexEach` over `vm.points`, so a breakpoint set after
  ## the pane opened appears without re-rendering the panel.
  var items: N
  let panel = ui(r):
    tdiv(class = "point-list-component isonim-point-list"):
      tdiv(class = "point-list-header"):
        span(class = "point-list-title"):
          text "Points"
      tdiv(class = "point-list-items", ref = items):
        discard
      tdiv(class = "point-list-empty", display = emptyDisplay(vm)):
        text "No breakpoints or tracepoints."
      tdiv(class = "point-list-footer"):
        span(class = selectedIndicatorClass(vm)):
          text selectedIndicatorText(vm)
        span(class = "point-edit-indicator",
             display = displayIf(vm.editingPoint.val.isSome)):
          text editIndicatorText(vm)
  indexEach[PointListEntry, R, N](r, items,
    proc(): seq[PointListEntry] = vm.points.val,
    proc(point: proc(): PointListEntry; index: int): N =
      renderPointRow[R, N](r, vm, point, index))
  panel
