## views/isonim_scratchpad_view.nim
##
## IsoNim DOM-rendering view for the Scratchpad panel.
##
## Renders a live, reactive DOM tree driven by ScratchpadVM signals.
## When the VM's signals change (selected item, comparison mode),
## the DOM updates automatically via IsoNim's `createRenderEffect`.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderScratchpadPanel(r, scratchpadVM)
##   check panel.textContent.contains("Scratchpad")
##
## Usage (web):
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let panel = renderScratchpadPanel(r, scratchpadVM)
##   # panel is a dom_api.Element, append to any real DOM container

import std/options

import isonim/core/[signals, computation]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/scratchpad_vm

# ---------------------------------------------------------------------------
# Header renderer
# ---------------------------------------------------------------------------

proc renderScratchpadHeader*[R, N](r: R; parent: N; vm: ScratchpadVM) =
  ## Render the scratchpad header with the title.
  let header = r.createElement("div")
  r.setAttribute(header, "class", "scratchpad-header")
  r.appendChild(parent, header)

  let title = r.createElement("span")
  r.setAttribute(title, "class", "scratchpad-title")
  r.setTextContent(title, "Scratchpad")
  r.appendChild(header, title)

# ---------------------------------------------------------------------------
# Items container renderer
# ---------------------------------------------------------------------------

proc renderItemsContainer*[R, N](r: R; parent: N; vm: ScratchpadVM) =
  ## Render the scratchpad items list container.
  ## Currently a placeholder — when scratchpad items are added to the store,
  ## this will use indexEach to render item rows.
  let container = r.createElement("div")
  r.setAttribute(container, "class", "scratchpad-items")
  r.appendChild(parent, container)

  # Reactive: show selected item indicator
  let selectedIndicator = r.createElement("span")
  r.setAttribute(selectedIndicator, "class", "scratchpad-selected-indicator")
  r.appendChild(container, selectedIndicator)

  createRenderEffect proc() =
    let sel = vm.selectedItem.val
    if sel.isSome:
      r.setTextContent(selectedIndicator, "Selected: " & $sel.get)
      r.setAttribute(selectedIndicator, "class", "scratchpad-selected-indicator active")
    else:
      r.setTextContent(selectedIndicator, "")
      r.setAttribute(selectedIndicator, "class", "scratchpad-selected-indicator")

# ---------------------------------------------------------------------------
# Comparison mode toggle renderer
# ---------------------------------------------------------------------------

proc renderComparisonToggle*[R, N](r: R; parent: N; vm: ScratchpadVM) =
  ## Render the comparison mode toggle button.
  ## When active, the scratchpad shows two values side by side.
  let toggleBtn = r.createElement("button")
  r.setAttribute(toggleBtn, "class", "comparison-toggle")
  r.setTextContent(toggleBtn, "Compare")
  r.appendChild(parent, toggleBtn)

  r.addEventListener(toggleBtn, "click", proc() = vm.toggleComparisonMode())

  createRenderEffect proc() =
    let active = vm.comparisonMode.val
    r.setTextContent(toggleBtn, if active: "Exit Compare" else: "Compare")
    let cls = "comparison-toggle" & (if active: " active" else: "")
    r.setAttribute(toggleBtn, "class", cls)

# ---------------------------------------------------------------------------
# Main panel renderer — MockRenderer overload
# ---------------------------------------------------------------------------

proc renderScratchpadPanel*(r: MockRenderer; vm: ScratchpadVM): MockNode =
  ## Render the complete Scratchpad panel.
  ##
  ## Structure:
  ##   div.scratchpad-component
  ##     div.scratchpad-header
  ##       span.scratchpad-title
  ##     div.scratchpad-items          (placeholder for item rows)
  ##       span.scratchpad-selected-indicator
  ##     button.comparison-toggle
  ##
  ## All content is reactive: changing ScratchpadVM signals automatically
  ## updates the DOM tree via createRenderEffect.
  let panel = r.createElement("div")
  r.setAttribute(panel, "class", "scratchpad-component")

  # Header
  renderScratchpadHeader(r, panel, vm)

  # Items container (placeholder)
  renderItemsContainer(r, panel, vm)

  # Comparison toggle
  renderComparisonToggle(r, panel, vm)

  panel

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------

when defined(js):
  proc renderScratchpadPanel*(r: WebRenderer;
                               vm: ScratchpadVM): isonim_dom.Element =
    ## Render the complete Scratchpad panel using real DOM elements.
    let panel = r.createElement("div")
    r.setAttribute(panel, "class", "scratchpad-component isonim-scratchpad")

    renderScratchpadHeader(r, panel, vm)
    renderItemsContainer(r, panel, vm)
    renderComparisonToggle(r, panel, vm)

    panel

  proc mountIsoNimScratchpad*(container: isonim_dom.Element;
                               vm: ScratchpadVM) =
    ## Mount the IsoNim scratchpad view into a real DOM container.
    ##
    ## Creates the reactive DOM tree and appends it as a child of
    ## `container`. The IsoNim reactive effects handle all subsequent
    ## updates — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderScratchpadPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
