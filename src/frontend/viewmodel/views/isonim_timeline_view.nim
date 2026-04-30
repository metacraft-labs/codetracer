## views/isonim_timeline_view.nim
##
## IsoNim DOM-rendering view for the Timeline panel.
##
## Renders a live, reactive DOM tree driven by `TimelineVM` signals.
## When the VM's signals change (current position, zoom level,
## hovered tick, markers), the DOM updates automatically via IsoNim's
## `createRenderEffect`.
##
## Both renderer overloads (Mock and Web) produce the same structure;
## the markup lives in a single template that is materialised into
## one concrete proc per renderer so the `ui()` macro can resolve
## element types at compile time.

import std/options

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/timeline_vm

# ---------------------------------------------------------------------------
# Reactive expression helpers
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc positionTicksText(vm: TimelineVM): string =
  "Tick: " & $vm.currentPosition.val

proc positionPercent(vm: TimelineVM): float =
  ## Percentage through the recording, 0..100. Returns 0 when the
  ## marker range is invalid (no second marker, or markers in the
  ## wrong order).
  let marks = vm.markers.val
  if marks.len < 2 or marks[1] <= marks[0]: return 0.0
  let pos = vm.currentPosition.val
  let minT = marks[0]
  let maxT = marks[1]
  let range = maxT - minT
  if range == 0'u64: 0.0
  else: float(pos - minT) / float(range) * 100.0

proc positionPercentText(vm: TimelineVM): string =
  ## Format the percentage with one decimal place, or empty when the
  ## marker range is unavailable.
  let marks = vm.markers.val
  if marks.len < 2 or marks[1] <= marks[0]: return ""
  let pctInt = int(positionPercent(vm) * 10)
  $(pctInt div 10) & "." & $(pctInt mod 10) & "%"

proc playheadLeft(vm: TimelineVM): string =
  let marks = vm.markers.val
  if marks.len < 2 or marks[1] <= marks[0]: "0%"
  else: $int(positionPercent(vm)) & "%"

proc zoomLevelText(vm: TimelineVM): string =
  let levelInt = int(vm.zoomLevel.val * 10)
  $(levelInt div 10) & "." & $(levelInt mod 10) & "x"

proc hoverTooltipText(vm: TimelineVM): string =
  let hovered = vm.hoveredTick.val
  if hovered.isSome: "Tick: " & $hovered.get else: ""

proc hoverTooltipDisplay(vm: TimelineVM): string =
  if vm.hoveredTick.val.isSome: "block" else: "none"

# ---------------------------------------------------------------------------
# Click handlers
# ---------------------------------------------------------------------------

proc onZoomIn(vm: TimelineVM): proc() =
  result = proc() = vm.zoom(vm.zoomLevel.val * 2.0)

proc onZoomOut(vm: TimelineVM): proc() =
  result = proc() = vm.zoom(vm.zoomLevel.val / 2.0)

# ---------------------------------------------------------------------------
# Panel template — shared between Mock and Web renderers
# ---------------------------------------------------------------------------
#
# Structure:
#   div.timeline-component
#     div.timeline-position
#       span.position-ticks                  text reactive
#       span.position-percent                text reactive
#     div.timeline-zoom-controls
#       button.zoom-out                      onclick = halve zoom level
#       span.zoom-level                      text reactive
#       button.zoom-in                       onclick = double zoom level
#     div.timeline-track
#       div.timeline-playhead                left % reactive
#     div.timeline-hover-tooltip             display + text reactive

template renderTimelinePanelImpl(r, vm, rootClass: untyped): untyped =
  ui(r):
    tdiv(class = rootClass):
      tdiv(class = "timeline-position"):
        span(class = "position-ticks"):
          text positionTicksText(vm)
        span(class = "position-percent"):
          text positionPercentText(vm)
      tdiv(class = "timeline-zoom-controls"):
        button(class = "zoom-out", onclick = onZoomOut(vm)):
          text "-"
        span(class = "zoom-level"):
          text zoomLevelText(vm)
        button(class = "zoom-in", onclick = onZoomIn(vm)):
          text "+"
      tdiv(class = "timeline-track"):
        tdiv(class = "timeline-playhead",
             left = playheadLeft(vm)):
          discard
      tdiv(class = "timeline-hover-tooltip",
           display = hoverTooltipDisplay(vm)):
        text hoverTooltipText(vm)

# ---------------------------------------------------------------------------
# Renderer overloads
# ---------------------------------------------------------------------------

proc renderTimelinePanel*(r: MockRenderer; vm: TimelineVM): MockNode =
  ## Render the full Timeline panel for headless tests.
  renderTimelinePanelImpl(r, vm, "timeline-component")

when defined(js):
  proc renderTimelinePanel*(r: WebRenderer; vm: TimelineVM): isonim_dom.Element =
    ## Render the Timeline panel into real DOM elements.
    renderTimelinePanelImpl(r, vm, "timeline-component isonim-timeline")

  proc mountIsoNimTimeline*(container: isonim_dom.Element; vm: TimelineVM) =
    ## Mount the IsoNim Timeline panel as a child of `container`.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderTimelinePanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
