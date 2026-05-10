## src/tests/hmr_fixture/main.nim
##
## Standalone HMR fixture for the codetracer GUI. Exercises the same
## integration pattern that production panels use:
##
##   - A `renderXxxPanel(r: WebRenderer; vm: XxxVM): Element {.uiComponent.}`
##     proc — the parametric component slot.
##   - A `mountIsoNimXxx(container, vm)` proc that under `-d:ctHmr`
##     hosts the panel inside a `mountUiHot` reactive boundary.
##   - Two independent panel mounts on the same page, so the spec can
##     prove that swapping one panel's slot leaves the other panel's
##     DOM untouched.
##
## The fixture intentionally does *not* import codetracer's real
## ViewModels (e.g. `ShellVM`) because those drag in the whole
## debugger / DAP / store dependency tree. Instead it defines a
## tiny `FixtureVM` with the same shape of reactive state that real
## panels read from. The HMR mechanism we're proving — pragma at the
## render proc, `mountUiHot` at the mount proc, slot rewrite on
## reload — is independent of the VM definition, so this is a
## faithful smoke test of the integration.

when not defined(js):
  {.error: "HMR fixture requires the JS backend".}

when not defined(ctHmr):
  {.error: "HMR fixture requires `-d:ctHmr` (which implies `-d:isonimHmr`)".}

import std/jsffi
import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/web/dom_api as isonim_dom
import isonim/web/web_renderer
import isonim/web/hmr_component
import isonim/web/hmr

# ---------------------------------------------------------------------------
# Tiny ViewModel — the panel only reads `inputBuffer.val` and
# `counter.val`. Everything else stays out of the dependency tree.
# ---------------------------------------------------------------------------

type
  FixtureVM = ref object
    inputBuffer: Signal[string]
    counter: Signal[int]
    label: Signal[string]

let panelAVm = FixtureVM(
  inputBuffer: signals.createSignal(""),
  counter: signals.createSignal(0),
  label: signals.createSignal("a"))

let panelBVm = FixtureVM(
  inputBuffer: signals.createSignal(""),
  counter: signals.createSignal(0),
  label: signals.createSignal("before"))

# ---------------------------------------------------------------------------
# Components — the production pattern: parametric `{.uiComponent.}` proc
# returning isonim_dom.Element, plus a thin `mountIsoNimXxx` wrapper.
# ---------------------------------------------------------------------------

template renderPanelImpl(r, vm: untyped; rootClass: string): untyped =
  ui(r):
    tdiv(class = rootClass):
      tdiv(class = "ct-shell-input-row"):
        span(class = "ct-shell-prompt"):
          text "$ "
        input(class = "ct-shell-input",
              placeholder = "Enter command...",
              value = vm.inputBuffer.val)
      tdiv(class = "ct-shell-output"):
        span(class = "ct-shell-counter"):
          text $vm.counter.val
        span(class = "ct-shell-label"):
          text vm.label.val

proc renderPanelA*(r: WebRenderer; vm: FixtureVM): isonim_dom.Element {.uiComponent.} =
  ## Panel A — kept stable across the test's swap. Identity of every
  ## element produced here must survive when Panel B's slot factory
  ## is rewritten.
  renderPanelImpl(r, vm, "ct-hmr-panel-a")

proc renderPanelB*(r: WebRenderer; vm: FixtureVM): isonim_dom.Element {.uiComponent.} =
  ## Panel B — the mutation target. The harness swaps its slot to
  ## simulate a recompile.
  renderPanelImpl(r, vm, "ct-hmr-panel-b")

# Replacement factories the harness installs into Panel B's slot.
# Same signature as `renderPanelB`; not pragma-marked because they
# should not register slots of their own — they are factories the
# harness writes into Panel B's existing slot.
proc renderPanelBAfter(r: WebRenderer; vm: FixtureVM): isonim_dom.Element =
  ## After-variant of Panel B. Preserves the outer shape of the
  ## before-variant (same input row, prompt, output region) so the
  ## panel's height does not shift — Chromium's scroll-anchoring
  ## otherwise drifts the scroll-preservation test by however much
  ## the layout grew or shrank. The visible behavioural change is
  ## the label's text being hard-coded to "AFTER" plus a marker
  ## class on the root.
  ui(r):
    tdiv(class = "ct-hmr-panel-b ct-hmr-after"):
      tdiv(class = "ct-shell-input-row"):
        span(class = "ct-shell-prompt"):
          text "$ "
        input(class = "ct-shell-input",
              placeholder = "Enter command...",
              value = vm.inputBuffer.val)
      tdiv(class = "ct-shell-output"):
        span(class = "ct-shell-counter"):
          text $vm.counter.val
        span(class = "ct-shell-label"):
          text "AFTER"

proc renderPanelBBroken(r: WebRenderer; vm: FixtureVM): isonim_dom.Element =
  raise newException(ValueError, "boom")

# ---------------------------------------------------------------------------
# Mount procs — the production pattern.
# ---------------------------------------------------------------------------

proc mountPanelA*(container: isonim_dom.Element; vm: FixtureVM) =
  let vmRef = vm
  discard mountUiHot(container, proc(): isonim_dom.Node =
    let r = WebRenderer()
    isonim_dom.Node(renderPanelA(r, vmRef)))

proc mountPanelB*(container: isonim_dom.Element; vm: FixtureVM) =
  let vmRef = vm
  discard mountUiHot(container, proc(): isonim_dom.Node =
    let r = WebRenderer()
    isonim_dom.Node(renderPanelB(r, vmRef)))

bootstrapHmr()

# ---------------------------------------------------------------------------
# Test harness — drives the registry directly so the spec doesn't
# need a recompile loop. Same pattern the isonim parametric fixture
# uses; transport-level end-to-end behaviour stays in isonim's
# `hmr_transport.spec.ts`.
# ---------------------------------------------------------------------------

proc ctHmrSimulatePanelBAfter*() {.exportc.} =
  hmrRegisterFactory(
    renderPanelBLoc, "panel-b-after-hash", toJs(renderPanelBAfter))

proc ctHmrSimulatePanelBBroken*() {.exportc.} =
  hmrRegisterFactory(
    renderPanelBLoc, "panel-b-broken-hash", toJs(renderPanelBBroken))

proc ctHmrIncCounter*() {.exportc.} =
  panelAVm.counter.val = panelAVm.counter.val + 1

proc ctHmrPanelACounter*(): int {.exportc.} =
  panelAVm.counter.val

proc ctHmrPanelBSetLabel*(s: cstring) {.exportc.} =
  panelBVm.label.val = $s

proc ctHmrRegistrySize*(): int {.exportc.} = registrySize()
proc ctHmrGeneration*(): int {.exportc.} = currentGeneration()

# ---------------------------------------------------------------------------
# Mount + harness wiring
# ---------------------------------------------------------------------------

var globalJs {.importjs: "globalThis".}: JsObject

proc main() =
  let panelAContainer = isonim_dom.document.getElementById(cstring"panel-a")
  let panelBContainer = isonim_dom.document.getElementById(cstring"panel-b")

  proc newJsArrayLit(): JsObject {.importjs: "[@]".}
  let errorCallbacks = newJsArrayLit()
  globalJs["__ctHmrErrorCallbacks"] = errorCallbacks

  proc captureError(err: ref Exception) =
    let msg = cstring(err.msg)
    let len = errorCallbacks["length"].to(int)
    for i in 0 ..< len:
      let cb = errorCallbacks[i].to(proc(m: cstring))
      cb(msg)

  globalUiOnError = proc(loc: string; err: ref Exception) =
    captureError(err)

  mountPanelA(panelAContainer, panelAVm)
  mountPanelB(panelBContainer, panelBVm)

  globalJs["__ctHmrNavigations"] = toJs(0)
  proc registerPageShowCounter()
    {.importjs: "window.addEventListener('pageshow', function () { globalThis.__ctHmrNavigations += 1; })".}
  registerPageShowCounter()

  let harness = newJsObject()
  proc onErrorBridge(cb: JsObject) = discard errorCallbacks.push(cb)
  harness["simulatePanelBAfter"] = toJs(ctHmrSimulatePanelBAfter)
  harness["simulatePanelBBroken"] = toJs(ctHmrSimulatePanelBBroken)
  harness["incCounter"] = toJs(ctHmrIncCounter)
  harness["panelACounter"] = toJs(ctHmrPanelACounter)
  harness["setPanelBLabel"] = toJs(ctHmrPanelBSetLabel)
  harness["registrySize"] = toJs(ctHmrRegistrySize)
  harness["generation"] = toJs(ctHmrGeneration)
  harness["onError"] = toJs(onErrorBridge)
  globalJs["__ctHmrTest"] = harness

main()
