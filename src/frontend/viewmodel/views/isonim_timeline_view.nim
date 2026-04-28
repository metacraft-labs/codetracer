## views/isonim_timeline_view.nim
##
## IsoNim DOM-rendering view for the Timeline panel.
##
## Renders a live, reactive DOM tree driven by TimelineVM signals.
## When the VM's signals change (current position, zoom level,
## hovered tick, markers), the DOM updates automatically via
## IsoNim's `createRenderEffect`.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## This view is intended to eventually replace the Karax trace.nim
## timeline component. It consumes the same TimelineVM but renders
## through IsoNim's renderer API instead of Karax's VDOM.
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderTimelinePanel(r, timelineVM)
##   check findByClass(panel, "timeline-position") != nil
##
## Usage (web):
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let panel = renderTimelinePanel(r, timelineVM)
##   # panel is a dom_api.Element, append to any real DOM container

import std/options

import isonim/core/[signals, computation]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/timeline_vm

# ---------------------------------------------------------------------------
# Position indicator renderer
# ---------------------------------------------------------------------------

proc renderPositionIndicator*[R, N](r: R; parent: N; vm: TimelineVM) =
  ## Render the current-position indicator element.
  ## Shows the debugger's current rrTicks and the percentage through
  ## the recording.
  let posDiv = r.createElement("div")
  r.setAttribute(posDiv, "class", "timeline-position")
  r.appendChild(parent, posDiv)

  let ticksSpan = r.createElement("span")
  r.setAttribute(ticksSpan, "class", "position-ticks")
  r.appendChild(posDiv, ticksSpan)

  createRenderEffect proc() =
    let pos = vm.currentPosition.val
    r.setTextContent(ticksSpan, "Tick: " & $pos)

  let percentSpan = r.createElement("span")
  r.setAttribute(percentSpan, "class", "position-percent")
  r.appendChild(posDiv, percentSpan)

  createRenderEffect proc() =
    let pos = vm.currentPosition.val
    let marks = vm.markers.val
    if marks.len >= 2 and marks[1] > marks[0]:
      let minT = marks[0]
      let maxT = marks[1]
      let range = maxT - minT
      let pct =
        if range > 0'u64:
          float(pos - minT) / float(range) * 100.0
        else:
          0.0
      # Format percentage to 1 decimal place
      let pctInt = int(pct * 10)
      let pctStr = $(pctInt div 10) & "." & $(pctInt mod 10) & "%"
      r.setTextContent(percentSpan, pctStr)
    else:
      r.setTextContent(percentSpan, "")

# ---------------------------------------------------------------------------
# Zoom controls renderer
# ---------------------------------------------------------------------------

proc renderZoomControls*[R, N](r: R; parent: N; vm: TimelineVM) =
  ## Render zoom in/out buttons and a zoom level display.
  let zoomBar = r.createElement("div")
  r.setAttribute(zoomBar, "class", "timeline-zoom-controls")
  r.appendChild(parent, zoomBar)

  # Zoom out button
  let zoomOutBtn = r.createElement("button")
  r.setAttribute(zoomOutBtn, "class", "zoom-out")
  r.setTextContent(zoomOutBtn, "-")
  r.appendChild(zoomBar, zoomOutBtn)
  r.addEventListener(zoomOutBtn, "click", proc() =
    vm.zoom(vm.zoomLevel.val / 2.0))

  # Zoom level display
  let zoomText = r.createElement("span")
  r.setAttribute(zoomText, "class", "zoom-level")
  r.appendChild(zoomBar, zoomText)

  createRenderEffect proc() =
    let level = vm.zoomLevel.val
    # Format zoom level to 1 decimal place
    let levelInt = int(level * 10)
    r.setTextContent(zoomText, $(levelInt div 10) & "." & $(levelInt mod 10) & "x")

  # Zoom in button
  let zoomInBtn = r.createElement("button")
  r.setAttribute(zoomInBtn, "class", "zoom-in")
  r.setTextContent(zoomInBtn, "+")
  r.appendChild(zoomBar, zoomInBtn)
  r.addEventListener(zoomInBtn, "click", proc() =
    vm.zoom(vm.zoomLevel.val * 2.0))

# ---------------------------------------------------------------------------
# Hover tooltip renderer
# ---------------------------------------------------------------------------

proc renderHoverTooltip*[R, N](r: R; parent: N; vm: TimelineVM) =
  ## Render a tooltip that appears when hovering over the timeline.
  ## Shows the tick value at the hovered position.
  ## Hidden when no tick is hovered.
  let tooltip = r.createElement("div")
  r.setAttribute(tooltip, "class", "timeline-hover-tooltip")
  r.appendChild(parent, tooltip)

  createRenderEffect proc() =
    let hovered = vm.hoveredTick.val
    if hovered.isSome:
      r.setStyle(tooltip, "display", "block")
      r.setTextContent(tooltip, "Tick: " & $hovered.get)
    else:
      r.setStyle(tooltip, "display", "none")
      r.setTextContent(tooltip, "")

# ---------------------------------------------------------------------------
# Timeline track renderer (placeholder for the visual bar)
# ---------------------------------------------------------------------------

proc renderTimelineTrack*[R, N](r: R; parent: N; vm: TimelineVM) =
  ## Render the main timeline track area.
  ## This is a placeholder — the actual visual representation (canvas,
  ## SVG, or positioned divs) will be added when the timeline rendering
  ## logic is ported.
  let track = r.createElement("div")
  r.setAttribute(track, "class", "timeline-track")
  r.appendChild(parent, track)

  # Playhead indicator within the track
  let playhead = r.createElement("div")
  r.setAttribute(playhead, "class", "timeline-playhead")
  r.appendChild(track, playhead)

  createRenderEffect proc() =
    let marks = vm.markers.val
    let pos = vm.currentPosition.val
    if marks.len >= 2 and marks[1] > marks[0]:
      let minT = marks[0]
      let maxT = marks[1]
      let range = maxT - minT
      let pct =
        if range > 0'u64:
          float(pos - minT) / float(range) * 100.0
        else:
          0.0
      r.setStyle(playhead, "left", $int(pct) & "%")
    else:
      r.setStyle(playhead, "left", "0%")

# ---------------------------------------------------------------------------
# Main panel renderer — MockRenderer overload
# ---------------------------------------------------------------------------

proc renderTimelinePanel*(r: MockRenderer; vm: TimelineVM): MockNode =
  ## Render the complete Timeline panel.
  ##
  ## Structure:
  ##   div.timeline-component
  ##     div.timeline-position
  ##       span.position-ticks
  ##       span.position-percent
  ##     div.timeline-zoom-controls
  ##       button.zoom-out
  ##       span.zoom-level
  ##       button.zoom-in
  ##     div.timeline-track
  ##       div.timeline-playhead
  ##     div.timeline-hover-tooltip     (hidden when not hovering)
  ##
  ## All content is reactive: changing TimelineVM signals automatically
  ## updates the DOM tree via createRenderEffect.
  let panel = r.createElement("div")
  r.setAttribute(panel, "class", "timeline-component")

  # Position indicator
  renderPositionIndicator(r, panel, vm)

  # Zoom controls
  renderZoomControls(r, panel, vm)

  # Timeline track
  renderTimelineTrack(r, panel, vm)

  # Hover tooltip
  renderHoverTooltip(r, panel, vm)

  panel

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------

when defined(js):
  proc renderTimelinePanel*(r: WebRenderer;
                             vm: TimelineVM): isonim_dom.Element =
    ## Render the complete Timeline panel using real DOM elements.
    let panel = r.createElement("div")
    r.setAttribute(panel, "class", "timeline-component isonim-timeline")

    renderPositionIndicator(r, panel, vm)
    renderZoomControls(r, panel, vm)
    renderTimelineTrack(r, panel, vm)
    renderHoverTooltip(r, panel, vm)

    panel

  proc mountIsoNimTimeline*(container: isonim_dom.Element;
                             vm: TimelineVM) =
    ## Mount the IsoNim timeline view into a real DOM container.
    ##
    ## Creates the reactive DOM tree and appends it as a child of
    ## `container`. The IsoNim reactive effects handle all subsequent
    ## updates — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderTimelinePanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
