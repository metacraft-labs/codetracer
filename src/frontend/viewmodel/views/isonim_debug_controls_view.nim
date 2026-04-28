## views/isonim_debug_controls_view.nim
##
## IsoNim DOM-rendering view for the Debug Controls toolbar.
##
## Renders a live, reactive DOM tree driven by DebugControlsVM signals.
## When the VM's memos change (canStepForward, statusText, etc.),
## the DOM updates automatically via IsoNim's `createRenderEffect`.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## This view is intended to eventually replace the Karax debug controls
## component. It consumes the same DebugControlsVM but renders through
## IsoNim's renderer API instead of Karax's VDOM.
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderDebugControlsPanel(r, debugControlsVM)
##   check panel.textContent.contains("Idle")
##
## Usage (web):
##   let panel = renderDebugControlsPanel(webRenderer, debugControlsVM)
##   document.body.appendChild(panel)

import isonim/core/[signals, computation]
discard  # isonim/dsl not needed for this simple view
import isonim/testing/mock_dom  # MockNode type used in generic signatures

import ../viewmodels/debug_controls_vm

# ---------------------------------------------------------------------------
# Button renderer helper
# ---------------------------------------------------------------------------

proc renderControlButton*[R, N](r: R; parent: N;
                                 cssClass: string;
                                 label: string;
                                 enabled: proc(): bool;
                                 onClick: proc()) =
  ## Render a single debug control button with reactive enabled/disabled state.
  ##
  ## The button's "disabled" attribute is toggled reactively based on the
  ## `enabled` thunk. When disabled, the button gets a "disabled" attribute;
  ## when enabled, the attribute is removed.
  let btn = r.createElement("button")
  r.setAttribute(btn, "class", cssClass)
  r.setTextContent(btn, label)
  r.appendChild(parent, btn)

  r.addEventListener(btn, "click", onClick)

  createRenderEffect proc() =
    if enabled():
      r.removeAttribute(btn, "disabled")
    else:
      r.setAttribute(btn, "disabled", "true")

# ---------------------------------------------------------------------------
# Status text renderer
# ---------------------------------------------------------------------------

proc renderStatusText*[R, N](r: R; parent: N; vm: DebugControlsVM) =
  ## Render the status text element that shows the current debugger state.
  let status = r.createElement("span")
  r.setAttribute(status, "class", "debug-status-text")
  r.appendChild(parent, status)

  createRenderEffect proc() =
    r.setTextContent(status, vm.statusText.val)

# ---------------------------------------------------------------------------
# Main panel renderer
# ---------------------------------------------------------------------------

proc renderDebugControlsPanel*(r: MockRenderer; vm: DebugControlsVM): MockNode =
  ## Render the complete Debug Controls toolbar.
  ##
  ## Structure:
  ##   div.debug-controls
  ##     button.step-backward      (disabled when canStepBackward is false)
  ##     button.step-forward       (disabled when canStepForward is false)
  ##     button.step-in            (disabled when canStepForward is false)
  ##     button.step-out           (disabled when canStepForward is false)
  ##     button.continue-btn       (disabled when canContinue is false)
  ##     button.reverse-continue   (disabled when canContinue is false)
  ##     span.debug-status-text    (reactive status text)
  ##
  ## All content is reactive: changing DebugControlsVM memos automatically
  ## updates the DOM tree via createRenderEffect.
  let panel = r.createElement("div")
  r.setAttribute(panel, "class", "debug-controls")

  # Step Backward
  renderControlButton(r, panel, "step-backward", "\u25C0",
    proc(): bool = vm.canStepBackward.val,
    proc() = vm.stepBackward())

  # Step Forward
  renderControlButton(r, panel, "step-forward", "\u25B6",
    proc(): bool = vm.canStepForward.val,
    proc() = vm.stepForward())

  # Step In
  renderControlButton(r, panel, "step-in", "\u2193",
    proc(): bool = vm.canStepForward.val,
    proc() = vm.stepIn())

  # Step Out
  renderControlButton(r, panel, "step-out", "\u2191",
    proc(): bool = vm.canStepForward.val,
    proc() = vm.stepOut())

  # Continue
  renderControlButton(r, panel, "continue-btn", "\u23E9",
    proc(): bool = vm.canContinue.val,
    proc() = vm.continueExecution())

  # Reverse Continue
  renderControlButton(r, panel, "reverse-continue", "\u23EA",
    proc(): bool = vm.canContinue.val,
    proc() = vm.reverseContinue())

  # Status text
  renderStatusText(r, panel, vm)

  panel
