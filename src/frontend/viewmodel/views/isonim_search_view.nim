## views/isonim_search_view.nim
##
## IsoNim DOM-rendering view for the Search / Command Palette panel.
##
## Renders a live, reactive DOM tree driven by SearchVM signals.
## When the VM's signals change (mode, query, selected result,
## results visibility), the DOM updates automatically via IsoNim's
## `createRenderEffect`.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderSearchPanel(r, searchVM)
##   check panel.textContent.contains("Command")
##
## Usage (web):
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let panel = renderSearchPanel(r, searchVM)
##   # panel is a dom_api.Element, append to any real DOM container

import std/options

import isonim/core/[signals, computation]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/search_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc modeLabel(mode: SearchMode): string =
  ## Display label for a search mode button.
  case mode
  of smCommand:     "Command"
  of smFile:        "File"
  of smFindInFiles: "Find in Files"
  of smFindSymbol:  "Find Symbol"

proc modeCssClass(mode: SearchMode): string =
  ## CSS class name for a search mode button.
  case mode
  of smCommand:     "mode-command"
  of smFile:        "mode-file"
  of smFindInFiles: "mode-find-in-files"
  of smFindSymbol:  "mode-find-symbol"

# ---------------------------------------------------------------------------
# Mode selector renderer
# ---------------------------------------------------------------------------

proc makeModeClickHandler(vm: SearchVM; mode: SearchMode): proc() =
  ## Factory to create a click handler for a mode button.
  let m = mode
  result = proc() =
    vm.setMode(m)

proc makeModeActiveEffect[R, N](r: R; btn: N; vm: SearchVM;
                                  mode: SearchMode): proc() =
  ## Factory to create a reactive effect that updates the active CSS class.
  let m = mode
  result = proc() =
    let isActive = vm.mode.val == m
    let cls = modeCssClass(m) & (if isActive: " active" else: "")
    r.setAttribute(btn, "class", cls)

proc renderModeSelector*[R, N](r: R; parent: N; vm: SearchVM) =
  ## Render the four search mode buttons into `parent`.
  ## The active mode gets the "active" CSS class reactively.
  let modeBar = r.createElement("div")
  r.setAttribute(modeBar, "class", "search-mode-selector")
  r.appendChild(parent, modeBar)

  for mode in [smCommand, smFile, smFindInFiles, smFindSymbol]:
    let btn = r.createElement("button")
    r.setAttribute(btn, "class", modeCssClass(mode))
    r.setTextContent(btn, modeLabel(mode))
    r.appendChild(modeBar, btn)

    r.addEventListener(btn, "click", makeModeClickHandler(vm, mode))

    # Reactive "active" class update
    createRenderEffect makeModeActiveEffect(r, btn, vm, mode)

# ---------------------------------------------------------------------------
# Search input renderer
# ---------------------------------------------------------------------------

proc renderSearchInput*[R, N](r: R; parent: N; vm: SearchVM) =
  ## Render the search query input field.
  let inputRow = r.createElement("div")
  r.setAttribute(inputRow, "class", "search-input-row")
  r.appendChild(parent, inputRow)

  let input = r.createElement("input")
  r.setAttribute(input, "class", "search-query-input")
  r.setAttribute(input, "placeholder", "Search...")
  r.appendChild(inputRow, input)

  # Reactive: reflect current query text
  createRenderEffect proc() =
    let q = vm.query.val
    r.setAttribute(input, "value", q)

# ---------------------------------------------------------------------------
# Results list renderer
# ---------------------------------------------------------------------------

proc renderResultsList*[R, N](r: R; parent: N; vm: SearchVM) =
  ## Render the results list container.
  ## Currently a placeholder — when search results are added to the VM,
  ## this will use indexEach to render result rows.
  let container = r.createElement("div")
  r.setAttribute(container, "class", "search-results")
  r.appendChild(parent, container)

  # Reactive visibility controlled by resultsVisible signal
  createRenderEffect proc() =
    let visible = vm.resultsVisible.val
    r.setStyle(container, "display", if visible: "block" else: "none")

  # Reactive: show selected result highlight text
  let selectedIndicator = r.createElement("span")
  r.setAttribute(selectedIndicator, "class", "search-selected-indicator")
  r.appendChild(container, selectedIndicator)

  createRenderEffect proc() =
    let sel = vm.selectedResult.val
    if sel.isSome:
      r.setTextContent(selectedIndicator, "Selected: " & $sel.get)
      r.setAttribute(selectedIndicator, "class", "search-selected-indicator active")
    else:
      r.setTextContent(selectedIndicator, "")
      r.setAttribute(selectedIndicator, "class", "search-selected-indicator")

# ---------------------------------------------------------------------------
# Main panel renderer — MockRenderer overload
# ---------------------------------------------------------------------------

proc renderSearchPanel*(r: MockRenderer; vm: SearchVM): MockNode =
  ## Render the complete Search panel.
  ##
  ## Structure:
  ##   div.search-component
  ##     div.search-mode-selector
  ##       button.mode-command
  ##       button.mode-file
  ##       button.mode-find-in-files
  ##       button.mode-find-symbol
  ##     div.search-input-row
  ##       input.search-query-input
  ##     div.search-results            (hidden when no results)
  ##       span.search-selected-indicator
  ##
  ## All content is reactive: changing SearchVM signals automatically
  ## updates the DOM tree via createRenderEffect.
  let panel = r.createElement("div")
  r.setAttribute(panel, "class", "search-component")

  # Mode selector
  renderModeSelector(r, panel, vm)

  # Search input
  renderSearchInput(r, panel, vm)

  # Results list
  renderResultsList(r, panel, vm)

  panel

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------

when defined(js):
  proc renderSearchPanel*(r: WebRenderer;
                           vm: SearchVM): isonim_dom.Element =
    ## Render the complete Search panel using real DOM elements.
    let panel = r.createElement("div")
    r.setAttribute(panel, "class", "search-component isonim-search")

    renderModeSelector(r, panel, vm)
    renderSearchInput(r, panel, vm)
    renderResultsList(r, panel, vm)

    panel

  proc mountIsoNimSearch*(container: isonim_dom.Element;
                           vm: SearchVM) =
    ## Mount the IsoNim search view into a real DOM container.
    ##
    ## Creates the reactive DOM tree and appends it as a child of
    ## `container`. The IsoNim reactive effects handle all subsequent
    ## updates — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderSearchPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
