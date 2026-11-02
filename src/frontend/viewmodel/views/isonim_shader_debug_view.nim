## IsoNim DOM-rendering view for the visual replay Shader Debugger panel.

import std/[options, strformat]

import isonim/core/[computation, signals]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

import ../viewmodels/shader_debug_vm
import ../viewmodels/visual_replay_client

# The generic procs expand the DSL at their instantiation site.
export signals, computation, components

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

proc showsEmptyHint(vm: ShaderDebugVM): bool =
  vm.debugInfo.val.isNone and not vm.loading.val and vm.error.val.len == 0

proc stageText(vm: ShaderDebugVM): string =
  if vm.debugInfo.val.isSome:
    vm.debugInfo.val.get.shaderStage & " / " & vm.debugInfo.val.get.entryPoint
  else: ""

proc sourceLinesOf(vm: ShaderDebugVM): seq[string] =
  if vm.debugInfo.val.isSome: vm.debugInfo.val.get.sourceLines else: @[]

proc instructionText(vm: ShaderDebugVM): string =
  let step = vm.currentStep()
  if step.isSome: step.get.instruction else: ""

proc variablesOf(vm: ShaderDebugVM): seq[VisualReplayShaderValue] =
  let step = vm.currentStep()
  if step.isSome: step.get.variables else: @[]

proc registersOf(vm: ShaderDebugVM): seq[VisualReplayShaderValue] =
  let step = vm.currentStep()
  if step.isSome: step.get.registers else: @[]

proc renderShaderValueRow[R, N](r: R; value: proc(): VisualReplayShaderValue): N =
  ui(r):
    tdiv(class = "shader-debug-value-row"):
      span(class = "shader-debug-value-name"):
        text value().name
      span(class = "shader-debug-value-type"):
        text value().valueType
      span(class = "shader-debug-value-current"):
        text value().value

proc renderShaderValues[R, N](r: R; title, emptyText, tableClass: string;
                              values: proc(): seq[VisualReplayShaderValue]): N =
  ## One "Variables" / "Registers" section of the current step: its rows, or
  ## the empty line when the step has none.
  var slot: N
  let section = ui(r):
    tdiv(class = "shader-debug-values-section"):
      tdiv(class = "shader-debug-values-title"):
        text title
      tdiv(ref = slot):
        discard
  let emptyBody = proc(): N =
    ui(r):
      tdiv(class = "shader-debug-values-empty"):
        text emptyText
  let tableBody = proc(): N =
    var table: N
    let t = ui(r):
      tdiv(class = tableClass, ref = table):
        discard
    indexEach[VisualReplayShaderValue, R, N](r, table, values,
      proc(value: proc(): VisualReplayShaderValue; index: int): N =
        renderShaderValueRow[R, N](r, value))
    t
  show(r, slot, proc(): bool = values().len == 0, emptyBody, tableBody)
  section

proc renderShaderDebugBody[R, N](r: R; vm: ShaderDebugVM): N =
  ## The toolbar, the shader source and the current step's inspector, shown
  ## while a shader trace is loaded.
  mixin appendChild   # the renderer's, resolved where the proc is instantiated
  var source, inspector: N
  let body = ui(r):
    tdiv:
      tdiv(class = "shader-debug-toolbar"):
        span(class = "shader-debug-stage"):
          text stageText(vm)
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
        tdiv(class = "shader-debug-source", ref = source):
          discard
        tdiv(class = "shader-debug-inspector", ref = inspector):
          discard
  indexEach[string, R, N](r, source,
    proc(): seq[string] = sourceLinesOf(vm),
    proc(line: proc(): string; index: int): N =
      ui(r):
        tdiv(class = sourceLineClass(vm, index + 1)):
          span(class = "shader-debug-line-number"):
            text lineNumberText(index + 1)
          code(class = "shader-debug-line-code"):
            text line())
  show(r, inspector,
    proc(): bool = vm.currentStep().isSome,
    proc(): N =
      var sections: N
      let current = ui(r):
        tdiv(ref = sections):
          tdiv(class = "shader-debug-instruction"):
            span(class = "shader-debug-instruction-label"):
              text "Instruction"
            span(class = "shader-debug-instruction-value"):
              text instructionText(vm)
      let variables: N = renderShaderValues[R, N](r, "Variables",
        "No variables", "shader-debug-values-table shader-debug-variables-table",
        proc(): seq[VisualReplayShaderValue] = variablesOf(vm))
      let registers: N = renderShaderValues[R, N](r, "Registers",
        "No registers", "shader-debug-values-table shader-debug-registers-table",
        proc(): seq[VisualReplayShaderValue] = registersOf(vm))
      r.appendChild(sections, variables)
      r.appendChild(sections, registers)
      current)
  body

proc renderShaderDebugPanel*[R, N](r: R; vm: ShaderDebugVM): N =
  ## The Shader Debugger panel, under any renderer (Shared-DOM-Front-Ends
  ## D3); every region follows the ViewModel reactively, so a loaded trace or
  ## a step redraws in place. The panel host (`ui/panel_host`) mounts it.
  var emptySlot, bodySlot: N
  let panel = ui(r):
    tdiv(class = "shader-debug-component isonim-shader-debug"):
      tdiv(class = "shader-debug-header"):
        span(class = "shader-debug-title"):
          text "Shader Debugger"
        span(class = "shader-debug-context"):
          text contextText(vm)
      tdiv(class = "shader-debug-loading", display = displayIf(vm.loading.val)):
        text "Loading shader trace..."
      tdiv(class = "shader-debug-error", display = displayIf(vm.error.val.len > 0)):
        text vm.error.val
      tdiv(ref = emptySlot):
        discard
      tdiv(ref = bodySlot):
        discard
  show(r, emptySlot,
    proc(): bool = showsEmptyHint(vm),
    proc(): N =
      ui(r):
        tdiv(class = "shader-debug-empty"):
          text "Select a frame pixel or pixel history entry")
  show(r, bodySlot,
    proc(): bool = vm.debugInfo.val.isSome,
    proc(): N = renderShaderDebugBody[R, N](r, vm))
  panel
