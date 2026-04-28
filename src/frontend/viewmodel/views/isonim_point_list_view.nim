## views/isonim_point_list_view.nim
##
## IsoNim DOM-rendering view for the Point List (breakpoints / tracepoints)
## panel.
##
## Renders a live, reactive DOM tree driven by PointListVM signals.
## When the VM's signals change (selected point, editing point),
## the DOM updates automatically via IsoNim's `createRenderEffect`.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderPointListPanel(r, pointListVM)
##   check panel.textContent.contains("Points")
##
## Usage (web):
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let panel = renderPointListPanel(r, pointListVM)
##   # panel is a dom_api.Element, append to any real DOM container

import std/options

import isonim/core/[signals, computation]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/point_list_vm

# ---------------------------------------------------------------------------
# Header renderer
# ---------------------------------------------------------------------------

proc renderPointListHeader*[R, N](r: R; parent: N; vm: PointListVM) =
  ## Render the point list header with the title.
  let header = r.createElement("div")
  r.setAttribute(header, "class", "point-list-header")
  r.appendChild(parent, header)

  let title = r.createElement("span")
  r.setAttribute(title, "class", "point-list-title")
  r.setTextContent(title, "Points")
  r.appendChild(header, title)

# ---------------------------------------------------------------------------
# Points container renderer
# ---------------------------------------------------------------------------

proc renderPointsContainer*[R, N](r: R; parent: N; vm: PointListVM) =
  ## Render the points list container.
  ## Currently a placeholder — when point data is added to the store,
  ## this will use indexEach to render point rows.
  let container = r.createElement("div")
  r.setAttribute(container, "class", "point-list-items")
  r.appendChild(parent, container)

# ---------------------------------------------------------------------------
# Selected point indicator renderer
# ---------------------------------------------------------------------------

proc renderSelectedIndicator*[R, N](r: R; parent: N; vm: PointListVM) =
  ## Render a reactive indicator showing which point is selected.
  let indicator = r.createElement("span")
  r.setAttribute(indicator, "class", "point-selected-indicator")
  r.appendChild(parent, indicator)

  createRenderEffect proc() =
    let sel = vm.selectedPoint.val
    if sel.isSome:
      r.setTextContent(indicator, "Selected: " & $sel.get)
      r.setAttribute(indicator, "class", "point-selected-indicator active")
    else:
      r.setTextContent(indicator, "")
      r.setAttribute(indicator, "class", "point-selected-indicator")

# ---------------------------------------------------------------------------
# Edit mode indicator renderer
# ---------------------------------------------------------------------------

proc renderEditIndicator*[R, N](r: R; parent: N; vm: PointListVM) =
  ## Render a reactive indicator showing whether a point is being edited.
  let indicator = r.createElement("span")
  r.setAttribute(indicator, "class", "point-edit-indicator")
  r.appendChild(parent, indicator)

  createRenderEffect proc() =
    let editing = vm.editingPoint.val
    if editing.isSome:
      r.setTextContent(indicator, "Editing: " & $editing.get)
      r.setStyle(indicator, "display", "inline")
    else:
      r.setTextContent(indicator, "")
      r.setStyle(indicator, "display", "none")

# ---------------------------------------------------------------------------
# Main panel renderer — MockRenderer overload
# ---------------------------------------------------------------------------

proc renderPointListPanel*(r: MockRenderer; vm: PointListVM): MockNode =
  ## Render the complete Point List panel.
  ##
  ## Structure:
  ##   div.point-list-component
  ##     div.point-list-header
  ##       span.point-list-title
  ##     div.point-list-items          (placeholder for point rows)
  ##     span.point-selected-indicator
  ##     span.point-edit-indicator     (hidden when not editing)
  ##
  ## All content is reactive: changing PointListVM signals automatically
  ## updates the DOM tree via createRenderEffect.
  let panel = r.createElement("div")
  r.setAttribute(panel, "class", "point-list-component")

  # Header
  renderPointListHeader(r, panel, vm)

  # Points container (placeholder)
  renderPointsContainer(r, panel, vm)

  # Selected point indicator
  renderSelectedIndicator(r, panel, vm)

  # Edit mode indicator
  renderEditIndicator(r, panel, vm)

  panel

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------

when defined(js):
  proc renderPointListPanel*(r: WebRenderer;
                              vm: PointListVM): isonim_dom.Element =
    ## Render the complete Point List panel using real DOM elements.
    let panel = r.createElement("div")
    r.setAttribute(panel, "class", "point-list-component isonim-point-list")

    renderPointListHeader(r, panel, vm)
    renderPointsContainer(r, panel, vm)
    renderSelectedIndicator(r, panel, vm)
    renderEditIndicator(r, panel, vm)

    panel

  proc mountIsoNimPointList*(container: isonim_dom.Element;
                              vm: PointListVM) =
    ## Mount the IsoNim point list view into a real DOM container.
    ##
    ## Creates the reactive DOM tree and appends it as a child of
    ## `container`. The IsoNim reactive effects handle all subsequent
    ## updates — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderPointListPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
