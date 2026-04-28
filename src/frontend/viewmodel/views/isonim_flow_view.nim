## views/isonim_flow_view.nim
##
## IsoNim DOM-rendering view for the Flow panel.
##
## Renders a live, reactive DOM tree driven by FlowVM signals.
## When the VM's signals change (flow mode, iteration, hovered step,
## loading state), the DOM updates automatically via IsoNim's
## `createRenderEffect`.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## This view is intended to eventually replace the Karax flow.nim
## component. It consumes the same FlowVM but renders through
## IsoNim's renderer API instead of Karax's VDOM.
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderFlowPanel(r, flowVM)
##   check panel.textContent.contains("Call")
##
## Usage (web):
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let panel = renderFlowPanel(r, flowVM)
##   # panel is a dom_api.Element, append to any real DOM container

import std/options

import isonim/core/[signals, computation]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/flow_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc modeLabel(mode: FlowMode): string =
  ## Display label for a flow mode button.
  case mode
  of fmCall:     "Call"
  of fmLine:     "Line"
  of fmFunction: "Function"

proc modeCssClass(mode: FlowMode): string =
  ## CSS class name for a flow mode button.
  case mode
  of fmCall:     "mode-call"
  of fmLine:     "mode-line"
  of fmFunction: "mode-function"

# ---------------------------------------------------------------------------
# Mode selector renderer
# ---------------------------------------------------------------------------

proc makeModeClickHandler(vm: FlowVM; mode: FlowMode): proc() =
  ## Factory to create a click handler for a mode button.
  let m = mode
  result = proc() =
    vm.setMode(m)

proc makeModeActiveEffect[R, N](r: R; btn: N; vm: FlowVM;
                                  mode: FlowMode): proc() =
  ## Factory to create a reactive effect that updates the active CSS class.
  let m = mode
  result = proc() =
    let isActive = vm.flowMode.val == m
    let cls = modeCssClass(m) & (if isActive: " active" else: "")
    r.setAttribute(btn, "class", cls)

proc renderModeSelector*[R, N](r: R; parent: N; vm: FlowVM) =
  ## Render the three flow mode buttons (Call, Line, Function) into `parent`.
  ## The active mode gets the "active" CSS class reactively.
  let modeBar = r.createElement("div")
  r.setAttribute(modeBar, "class", "flow-mode-selector")
  r.appendChild(parent, modeBar)

  for mode in [fmCall, fmLine, fmFunction]:
    let btn = r.createElement("button")
    r.setAttribute(btn, "class", modeCssClass(mode))
    r.setTextContent(btn, modeLabel(mode))
    r.appendChild(modeBar, btn)

    r.addEventListener(btn, "click", makeModeClickHandler(vm, mode))

    # Reactive "active" class update
    createRenderEffect makeModeActiveEffect(r, btn, vm, mode)

# ---------------------------------------------------------------------------
# Iteration slider renderer
# ---------------------------------------------------------------------------

proc renderIterationSlider*[R, N](r: R; parent: N; vm: FlowVM) =
  ## Render the iteration slider and its label.
  ## The slider range is [0, totalIterations - 1], and its position
  ## is driven by the selectedIteration signal.
  let sliderRow = r.createElement("div")
  r.setAttribute(sliderRow, "class", "flow-iteration-slider")
  r.appendChild(parent, sliderRow)

  let label = r.createElement("span")
  r.setAttribute(label, "class", "iteration-label")
  r.appendChild(sliderRow, label)

  createRenderEffect proc() =
    let current = vm.selectedIteration.val
    let total = vm.totalIterations.val
    r.setTextContent(label, "Iteration " & $current & " / " & $total)

  # The slider input itself. In a real browser we would wire up
  # input/change events to call vm.selectIteration. With MockRenderer,
  # the slider acts as a placeholder; tests exercise the VM directly.
  let slider = r.createElement("input")
  r.setAttribute(slider, "class", "iteration-range")
  r.setAttribute(slider, "type", "range")
  r.setAttribute(slider, "min", "0")
  r.appendChild(sliderRow, slider)

  createRenderEffect proc() =
    let maxVal = vm.totalIterations.val - 1
    r.setAttribute(slider, "max", $(if maxVal >= 0: maxVal else: 0))
    r.setAttribute(slider, "value", $vm.selectedIteration.val)

# ---------------------------------------------------------------------------
# Flow step list renderer (placeholder — no flow step data yet)
# ---------------------------------------------------------------------------

proc renderFlowStepList*[R, N](r: R; parent: N; vm: FlowVM) =
  ## Render the flow step list container.
  ## Currently a placeholder — when flow step data is added to the VM,
  ## this will use indexEach to render steps.
  let container = r.createElement("div")
  r.setAttribute(container, "class", "flow-steps")
  r.appendChild(parent, container)

  # The container is empty for now. When FlowVM gains a
  # `visibleSteps` signal, steps will be rendered here.

# ---------------------------------------------------------------------------
# Value display renderer
# ---------------------------------------------------------------------------

proc renderValueDisplay*[R, N](r: R; parent: N; vm: FlowVM) =
  ## Render the value display area that shows the value at the
  ## current flow step. Includes a toggle for raw values.
  let display = r.createElement("div")
  r.setAttribute(display, "class", "flow-value-display")
  r.appendChild(parent, display)

  let valueText = r.createElement("span")
  r.setAttribute(valueText, "class", "flow-value-text")
  r.appendChild(display, valueText)

  # Raw value toggle button
  let toggleBtn = r.createElement("button")
  r.setAttribute(toggleBtn, "class", "raw-value-toggle")
  r.appendChild(display, toggleBtn)
  r.addEventListener(toggleBtn, "click", proc() = vm.toggleRawValues())

  createRenderEffect proc() =
    let raw = vm.showRawValues.val
    r.setTextContent(toggleBtn, if raw: "Formatted" else: "Raw")
    let cls = "raw-value-toggle" & (if raw: " active" else: "")
    r.setAttribute(toggleBtn, "class", cls)

# ---------------------------------------------------------------------------
# Loading indicator
# ---------------------------------------------------------------------------

proc renderFlowLoading*[R, N](r: R; parent: N; vm: FlowVM) =
  ## Render a loading indicator that appears when flow data is loading.
  let indicator = r.createElement("div")
  r.setAttribute(indicator, "class", "flow-loading")
  r.setTextContent(indicator, "Loading...")
  r.appendChild(parent, indicator)

  createRenderEffect proc() =
    let loading = vm.isLoading.val
    r.setStyle(indicator, "display", if loading: "block" else: "none")

# ---------------------------------------------------------------------------
# Main panel renderer — MockRenderer overload
# ---------------------------------------------------------------------------

proc renderFlowPanel*(r: MockRenderer; vm: FlowVM): MockNode =
  ## Render the complete Flow panel.
  ##
  ## Structure:
  ##   div.flow-component
  ##     div.flow-mode-selector
  ##       button.mode-call
  ##       button.mode-line
  ##       button.mode-function
  ##     div.flow-loading               (hidden when not loading)
  ##     div.flow-iteration-slider
  ##       span.iteration-label
  ##       input.iteration-range
  ##     div.flow-steps                 (placeholder for step list)
  ##     div.flow-value-display
  ##       span.flow-value-text
  ##       button.raw-value-toggle
  ##
  ## All content is reactive: changing FlowVM signals automatically
  ## updates the DOM tree via createRenderEffect.
  let panel = r.createElement("div")
  r.setAttribute(panel, "class", "flow-component")

  # Mode selector
  renderModeSelector(r, panel, vm)

  # Loading indicator
  renderFlowLoading(r, panel, vm)

  # Iteration slider
  renderIterationSlider(r, panel, vm)

  # Flow step list (placeholder)
  renderFlowStepList(r, panel, vm)

  # Value display
  renderValueDisplay(r, panel, vm)

  panel

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------

when defined(js):
  proc renderFlowPanel*(r: WebRenderer;
                         vm: FlowVM): isonim_dom.Element =
    ## Render the complete Flow panel using real DOM elements.
    let panel = r.createElement("div")
    r.setAttribute(panel, "class", "flow-component isonim-flow")

    renderModeSelector(r, panel, vm)
    renderFlowLoading(r, panel, vm)
    renderIterationSlider(r, panel, vm)
    renderFlowStepList(r, panel, vm)
    renderValueDisplay(r, panel, vm)

    panel

  proc mountIsoNimFlow*(container: isonim_dom.Element;
                         vm: FlowVM) =
    ## Mount the IsoNim flow view into a real DOM container.
    ##
    ## Creates the reactive DOM tree and appends it as a child of
    ## `container`. The IsoNim reactive effects handle all subsequent
    ## updates — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderFlowPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
