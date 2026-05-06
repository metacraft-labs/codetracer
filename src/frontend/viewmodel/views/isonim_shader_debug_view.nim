## IsoNim DOM-rendering view for the visual replay Shader Debugger panel.

import std/[options, strformat]

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/dom_api as isonim_dom
  import isonim/web/web_renderer

import ../viewmodels/shader_debug_vm
import ../viewmodels/visual_replay_client

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc contextText(vm: ShaderDebugVM): string =
  if vm.selectedContext.val.isNone:
    return "No shader context"
  let context = vm.selectedContext.val.get
  result = "Pixel " & $context.x & ", " & $context.y
  if context.frame.isSome:
    result.add " frame " & $context.frame.get
  if context.drawCallIndex.isSome:
    result.add " draw " & $context.drawCallIndex.get
  if context.geid.isSome:
    result.add " GEID " & $context.geid.get

proc stepText(vm: ShaderDebugVM): string =
  if vm.debugInfo.val.isNone or vm.debugInfo.val.get.steps.len == 0:
    return "Step 0 / 0"
  "Step " & $(vm.currentStepIndex.val + 1) & " / " & $vm.debugInfo.val.get.steps.len

proc sourceLineClass(vm: ShaderDebugVM; lineNumber: int): string =
  if vm.currentSourceLine() == lineNumber:
    "shader-debug-source-line current"
  else:
    "shader-debug-source-line"

proc lineNumberText(lineNumber: int): string =
  &"{lineNumber:>3}"

proc onStepBack(vm: ShaderDebugVM): proc() =
  result = proc() = vm.stepBackward()

proc onStepForward(vm: ShaderDebugVM): proc() =
  result = proc() = vm.stepForward()

proc onStepFirst(vm: ShaderDebugVM): proc() =
  result = proc() = vm.stepFirst()

proc onStepLast(vm: ShaderDebugVM): proc() =
  result = proc() = vm.stepLast()

template renderShaderDebugPanelImpl(r, vm, rootClass: untyped): untyped =
  ui(r):
    tdiv(class = rootClass):
      tdiv(class = "shader-debug-header"):
        span(class = "shader-debug-title"):
          text "Shader Debugger"
        span(class = "shader-debug-context"):
          text contextText(vm)
      tdiv(class = "shader-debug-loading", display = displayIf(vm.loading.val)):
        text "Loading shader trace..."
      tdiv(class = "shader-debug-error", display = displayIf(vm.error.val.len > 0)):
        text vm.error.val
      if vm.debugInfo.val.isNone and not vm.loading.val and vm.error.val.len == 0:
        tdiv(class = "shader-debug-empty"):
          text "Select a frame pixel or pixel history entry"
      if vm.debugInfo.val.isSome:
        let info = vm.debugInfo.val.get
        let step = vm.currentStep()
        tdiv(class = "shader-debug-toolbar"):
          span(class = "shader-debug-stage"):
            text info.shaderStage & " / " & info.entryPoint
          span(class = "shader-debug-step-label"):
            text stepText(vm)
          button(class = "shader-debug-step-first",
                 onclick = onStepFirst(vm)):
            text "First"
          button(class = "shader-debug-step-back",
                 onclick = onStepBack(vm)):
            text "Back"
          button(class = "shader-debug-step-forward",
                 onclick = onStepForward(vm)):
            text "Step"
          button(class = "shader-debug-step-last",
                 onclick = onStepLast(vm)):
            text "Last"
        tdiv(class = "shader-debug-body"):
          tdiv(class = "shader-debug-source"):
            for i, line in info.sourceLines:
              tdiv(class = sourceLineClass(vm, i + 1)):
                span(class = "shader-debug-line-number"):
                  text lineNumberText(i + 1)
                code(class = "shader-debug-line-code"):
                  text line
          tdiv(class = "shader-debug-inspector"):
            if step.isSome:
              let current = step.get
              tdiv(class = "shader-debug-instruction"):
                span(class = "shader-debug-instruction-label"):
                  text "Instruction"
                span(class = "shader-debug-instruction-value"):
                  text current.instruction
              tdiv(class = "shader-debug-values-section"):
                tdiv(class = "shader-debug-values-title"):
                  text "Variables"
                if current.variables.len == 0:
                  tdiv(class = "shader-debug-values-empty"):
                    text "No variables"
                else:
                  tdiv(class = "shader-debug-values-table shader-debug-variables-table"):
                    for valueIndex in 0 ..< current.variables.len:
                      let variable = current.variables[valueIndex]
                      tdiv(class = "shader-debug-value-row"):
                        span(class = "shader-debug-value-name"):
                          text variable.name
                        span(class = "shader-debug-value-type"):
                          text variable.valueType
                        span(class = "shader-debug-value-current"):
                          text variable.value
              tdiv(class = "shader-debug-values-section"):
                tdiv(class = "shader-debug-values-title"):
                  text "Registers"
                if current.registers.len == 0:
                  tdiv(class = "shader-debug-values-empty"):
                    text "No registers"
                else:
                  tdiv(class = "shader-debug-values-table shader-debug-registers-table"):
                    for valueIndex in 0 ..< current.registers.len:
                      let register = current.registers[valueIndex]
                      tdiv(class = "shader-debug-value-row"):
                        span(class = "shader-debug-value-name"):
                          text register.name
                        span(class = "shader-debug-value-type"):
                          text register.valueType
                        span(class = "shader-debug-value-current"):
                          text register.value

proc renderShaderDebugPanel*(r: MockRenderer; vm: ShaderDebugVM): MockNode =
  renderShaderDebugPanelImpl(r, vm, "shader-debug-component")

when defined(js):
  proc renderShaderDebugPanel*(r: WebRenderer;
                               vm: ShaderDebugVM): isonim_dom.Element =
    renderShaderDebugPanelImpl(r, vm,
      "shader-debug-component isonim-shader-debug")

  proc mountIsoNimShaderDebug*(container: isonim_dom.Element;
                               vm: ShaderDebugVM) =
    let r = WebRenderer()
    let panel = renderShaderDebugPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
