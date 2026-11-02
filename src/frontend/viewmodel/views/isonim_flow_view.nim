## views/isonim_flow_view.nim
##
## IsoNim DOM-rendering view for the Flow panel.
##
## Renders a live, reactive DOM tree driven by `FlowVM` signals. When
## the VM's signals change (flow mode, iteration, hovered step,
## loading state), the DOM updates automatically via IsoNim's
## `createRenderEffect`.
##
## One generic view (`renderFlowPanel[R, N]`) for every renderer: the
## headless tests render it under `MockRenderer`, the VS Code panel bundle,
## the storybook and the standalone app shell under `WebRenderer`.

import std/options
when defined(js):
  # Enter and Space on a `role="button"` row are its click.
  import ./isonim_activation

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/flow_vm

# The generic procs expand the DSL (`val=`, `createRenderEffect`, `indexEach`)
# at their instantiation site, in the caller's module.
export signals, computation, components

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

proc flowStepRowClass(vm: FlowVM; index: int): string =
  if vm.hoveredStep.val.isSome() and vm.hoveredStep.val.get() == index:
    "flow-step-row hovered"
  else:
    "flow-step-row"

proc flowStepTransition(step: FlowStepEntry): string =
  if step.beforeValue.len > 0 and step.afterValue.len > 0:
    step.beforeValue & " -> " & step.afterValue
  elif step.afterValue.len > 0:
    step.afterValue
  else:
    step.beforeValue

proc onStepClick(vm: FlowVM; step: proc(): FlowStepEntry): proc() =
  ## Reads the row's step when clicked, so a reused row clicks the step it
  ## shows.
  result = proc() = vm.clickStep(step().step)

proc emptyStepsDisplay(vm: FlowVM): string =
  if vm.steps.val.len == 0: "block" else: "none"

# ---------------------------------------------------------------------------
# Click handlers
# ---------------------------------------------------------------------------

proc onSetMode(vm: FlowVM; mode: FlowMode): proc() =
  let m = mode
  result = proc() = vm.setMode(m)

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------
#
# Structure:
#   div.flow-component.isonim-flow
#     div.flow-mode-selector
#       button.mode-call[.active]
#       button.mode-line[.active]
#       button.mode-function[.active]
#     div.flow-loading[display reactive]                "Loading..."
#     div.flow-iteration-slider
#       span.iteration-label                            text reactive
#       input.iteration-range[type=range, min=0, max reactive, value reactive]
#     div.flow-steps
#       div.flow-steps-rows                             indexEach over vm.steps
#       div.flow-steps-empty[display reactive]          "No flow values loaded."
#     div.flow-value-display
#       span.flow-value-text
#       button.raw-value-toggle                         class + text reactive
#
# All dynamic attributes / text become per-attribute
# `createRenderEffect`s emitted by the DSL macro.

proc renderFlowStepRow[R, N](r: R; vm: FlowVM; step: proc(): FlowStepEntry;
                            index: int): N =
  ## One step of the flow: its index, location, expression and value.
  ui(r):
    tdiv(role = "button", tabindex = "0", class = flowStepRowClass(vm, index),
         onclick = onStepClick(vm, step)):
      span(class = "flow-step-index"):
        text $step().step
      span(class = "flow-step-location"):
        text step().location
      span(class = "flow-step-expression"):
        text step().expression
      span(class = "flow-step-value"):
        text flowStepTransition(step())

proc renderFlowPanel*[R, N](r: R; vm: FlowVM): N =
  ## The Flow panel. The step rows are an `indexEach` over `vm.steps`, so they
  ## follow the ViewModel after the panel is built.
  var stepsHost: N
  let panel = ui(r):
    tdiv(class = "flow-component isonim-flow"):
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
        tdiv(class = "flow-steps-header"):
          span:
            text "Step"
          span:
            text "Location"
          span:
            text "Expression"
          span:
            text "Value"
        tdiv(ref = stepsHost, class = "flow-steps-rows"):
          discard
        tdiv(class = "flow-steps-empty",
             display = emptyStepsDisplay(vm)):
          text "No flow values loaded."
      tdiv(class = "flow-value-display"):
        span(class = "flow-value-text"):
          discard
        button(class = rawValueToggleClass(vm),
               onclick = proc() = vm.toggleRawValues()):
          text rawValueToggleText(vm)
  indexEach[FlowStepEntry, R, N](r, stepsHost,
    proc(): seq[FlowStepEntry] = vm.steps.val,
    proc(step: proc(): FlowStepEntry; index: int): N =
      renderFlowStepRow[R, N](r, vm, step, index))
  panel

when defined(js):
  proc mountIsoNimFlow*(container: isonim_dom.Element; vm: FlowVM) =
    ## Append the Flow panel to `container` (the storybook and the
    ## standalone app shell). Reactive effects handle every later update.
    let panel = renderFlowPanel[WebRenderer, isonim_dom.Element](
      WebRenderer(), vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
