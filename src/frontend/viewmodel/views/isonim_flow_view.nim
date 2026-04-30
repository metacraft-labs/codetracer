## views/isonim_flow_view.nim
##
## IsoNim DOM-rendering view for the Flow panel.
##
## Renders a live, reactive DOM tree driven by `FlowVM` signals. When
## the VM's signals change (flow mode, iteration, hovered step,
## loading state), the DOM updates automatically via IsoNim's
## `createRenderEffect`.
##
## Both renderer overloads (Mock and Web) produce the same structure;
## the markup lives in a single `renderFlowPanelImpl` template that is
## materialised into one concrete proc per renderer so the `ui()`
## macro can resolve element types at compile time.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/flow_vm

# ---------------------------------------------------------------------------
# Static labels and class names
# ---------------------------------------------------------------------------

proc modeLabel(mode: FlowMode): string =
  case mode
  of fmCall:     "Call"
  of fmLine:     "Line"
  of fmFunction: "Function"

proc modeCssClass(mode: FlowMode): string =
  case mode
  of fmCall:     "mode-call"
  of fmLine:     "mode-line"
  of fmFunction: "mode-function"

# ---------------------------------------------------------------------------
# Reactive expression helpers
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc modeButtonClass(vm: FlowVM; mode: FlowMode): string =
  ## Mode-button class with the optional `active` modifier.
  let cls = modeCssClass(mode)
  if vm.flowMode.val == mode: cls & " active" else: cls

proc rawValueToggleClass(vm: FlowVM): string =
  if vm.showRawValues.val: "raw-value-toggle active" else: "raw-value-toggle"

proc rawValueToggleText(vm: FlowVM): string =
  if vm.showRawValues.val: "Formatted" else: "Raw"

proc iterationLabelText(vm: FlowVM): string =
  "Iteration " & $vm.selectedIteration.val & " / " & $vm.totalIterations.val

proc sliderMaxAttr(vm: FlowVM): string =
  let maxVal = vm.totalIterations.val - 1
  $(if maxVal >= 0: maxVal else: 0)

# ---------------------------------------------------------------------------
# Click handlers
# ---------------------------------------------------------------------------

proc onSetMode(vm: FlowVM; mode: FlowMode): proc() =
  let m = mode
  result = proc() = vm.setMode(m)

# ---------------------------------------------------------------------------
# Panel template — shared between Mock and Web renderers
# ---------------------------------------------------------------------------
#
# Structure:
#   div.flow-component
#     div.flow-mode-selector
#       button.mode-call[.active]
#       button.mode-line[.active]
#       button.mode-function[.active]
#     div.flow-loading[display reactive]                "Loading..."
#     div.flow-iteration-slider
#       span.iteration-label                            text reactive
#       input.iteration-range[type=range, min=0, max reactive, value reactive]
#     div.flow-steps                                    placeholder
#     div.flow-value-display
#       span.flow-value-text
#       button.raw-value-toggle                         class + text reactive
#
# All dynamic attributes / text become per-attribute
# `createRenderEffect`s emitted by the DSL macro.

template renderFlowPanelImpl(r, vm, rootClass: untyped): untyped =
  ui(r):
    tdiv(class = rootClass):
      tdiv(class = "flow-mode-selector"):
        button(class = modeButtonClass(vm, fmCall),
               onclick = onSetMode(vm, fmCall)):
          text modeLabel(fmCall)
        button(class = modeButtonClass(vm, fmLine),
               onclick = onSetMode(vm, fmLine)):
          text modeLabel(fmLine)
        button(class = modeButtonClass(vm, fmFunction),
               onclick = onSetMode(vm, fmFunction)):
          text modeLabel(fmFunction)
      tdiv(class = "flow-loading",
           display = displayIf(vm.isLoading.val)):
        text "Loading..."
      tdiv(class = "flow-iteration-slider"):
        span(class = "iteration-label"):
          text iterationLabelText(vm)
        # `min` and `max` collide with `system.min` / `system.max`,
        # which is fine — the DSL's `attrNameStr` accepts symbol-choice
        # nodes and reads the underlying identifier name.
        input(class = "iteration-range",
              `type` = "range",
              min = "0",
              max = sliderMaxAttr(vm),
              value = $vm.selectedIteration.val)
      tdiv(class = "flow-steps"):
        discard
      tdiv(class = "flow-value-display"):
        span(class = "flow-value-text"):
          discard
        button(class = rawValueToggleClass(vm),
               onclick = proc() = vm.toggleRawValues()):
          text rawValueToggleText(vm)

# ---------------------------------------------------------------------------
# Renderer overloads
# ---------------------------------------------------------------------------

proc renderFlowPanel*(r: MockRenderer; vm: FlowVM): MockNode =
  ## Render the full Flow panel for headless tests.
  renderFlowPanelImpl(r, vm, "flow-component")

when defined(js):
  proc renderFlowPanel*(r: WebRenderer; vm: FlowVM): isonim_dom.Element =
    ## Render the Flow panel into real DOM elements.
    renderFlowPanelImpl(r, vm, "flow-component isonim-flow")

  proc mountIsoNimFlow*(container: isonim_dom.Element; vm: FlowVM) =
    ## Mount the IsoNim Flow panel as a child of `container`. Reactive
    ## effects handle every subsequent update — no manual redraw is
    ## needed.
    let r = WebRenderer()
    let panel = renderFlowPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
