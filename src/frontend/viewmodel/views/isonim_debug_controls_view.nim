## views/isonim_debug_controls_view.nim
##
## IsoNim DOM-rendering view for the Debug Controls toolbar.
##
## Renders a live, reactive DOM tree driven by DebugControlsVM signals.
## When the VM's memos change (canStepForward, statusText, etc.),
## the DOM updates automatically via IsoNim's `createRenderEffect`.
##
## This view is the primary renderer for the debug controls toolbar,
## replacing the legacy Karax debug controls component. It uses the
## same CSS classes, element IDs and SVG icons so that Playwright
## GUI tests continue to find buttons via their existing selectors
## (e.g. `#next-debug`, `#continue-debug`).
##
## Button clicks are delegated to the DebugControlsVM's legacy bridge
## callbacks (`onDapStep`, `onAction`) which route through the existing
## DAP event mediator — the only path that reaches the replay backend
## today. When the new `ct/step` backend path is wired end-to-end,
## the callbacks can be replaced with direct VM action calls.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderDebugControlsPanel(r, debugControlsVM)
##   check panel.textContent.contains("Idle")
##
## Usage (web):
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let panel = renderDebugControlsPanel(r, debugControlsVM)
##   # panel is a dom_api.Element, append to any real DOM container

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom  # MockNode type used in generic signatures

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

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
  let btn = ui(r):
    button(class = cssClass, onclick = onClick):
      text label
  r.appendChild(parent, btn)

  # Reactive disabled toggle — uses removeAttribute which the DSL
  # does not support, so this effect stays imperative.
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
  let status = ui(r):
    span(class = "debug-status-text"):
      text vm.statusText.val
  r.appendChild(parent, status)

# ---------------------------------------------------------------------------
# Main panel renderer (MockRenderer — for headless unit tests)
# ---------------------------------------------------------------------------

proc renderDebugControlsPanel*(r: MockRenderer; vm: DebugControlsVM): MockNode =
  ## Render the complete Debug Controls toolbar (mock version for tests).
  ##
  ## Structure mirrors the web version but uses plain text labels
  ## instead of SVG images.
  let panel = ui(r):
    tdiv(class = "debug-controls"):
      discard
  # Attach child buttons to the panel via helper calls. The helpers
  # handle reactive disabled state which the DSL cannot express.
  renderControlButton(r, panel, "step-backward", "\u25C0",
    proc(): bool = vm.canStepBackward.val,
    proc() = vm.stepBackward())
  renderControlButton(r, panel, "step-forward", "\u25B6",
    proc(): bool = vm.canStepForward.val,
    proc() = vm.stepForward())
  renderControlButton(r, panel, "step-in", "\u2193",
    proc(): bool = vm.canStepForward.val,
    proc() = vm.stepIn())
  renderControlButton(r, panel, "step-out", "\u2191",
    proc(): bool = vm.canStepForward.val,
    proc() = vm.stepOut())
  renderControlButton(r, panel, "continue-btn", "\u23E9",
    proc(): bool = vm.canContinue.val,
    proc() = vm.continueExecution())
  renderControlButton(r, panel, "reverse-continue", "\u23EA",
    proc(): bool = vm.canContinue.val,
    proc() = vm.reverseContinue())
  renderStatusText(r, panel, vm)
  panel

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------
#
# The web version matches the Karax debug toolbar exactly:
#   - Same element IDs (`{action}-debug`) so Playwright tests find them
#   - Same SVG icon <img> elements
#   - Same CSS classes (`ct-button-image-md-secondary ct-button-no-border`)
#   - Same button grouping with `.separate-bar` dividers
#   - Click handlers delegate to the VM's legacy bridge callbacks
#     (`onDapStep`, `onAction`) so stepping actually reaches the
#     replay backend via the DAP event mediator.
# ---------------------------------------------------------------------------

when defined(js):
  # -----------------------------------------------------------------------
  # Helper: create a separator bar (matches Karax `separateBar()`)
  # -----------------------------------------------------------------------
  proc addSeparator(r: WebRenderer; parent: isonim_dom.Element) =
    let sep = ui(r):
      tdiv(class = "separate-bar"):
        discard
    r.appendChild(parent, sep)

  # -----------------------------------------------------------------------
  # Helper: create a debug step button with SVG icon and tooltip
  # -----------------------------------------------------------------------
  proc addStepButton(r: WebRenderer; parent: isonim_dom.Element;
                     vm: DebugControlsVM;
                     actionId: string;
                     imgSrc: string; imgHeight: string; imgWidth: string;
                     tooltipText: string; shortcut: string;
                     enabled: proc(): bool) =
    ## Render a single debug step button that matches the Karax version.
    ##
    ## Structure per button:
    ##   <button id="{actionId}-debug" class="ct-button-image-md-secondary ct-button-no-border">
    ##     <img src="{imgSrc}" class="debug-button-svg" />
    ##     <div class="custom-tooltip">{tooltipText} ({shortcut})</div>
    ##   </button>
    let tipText = if shortcut.len > 0: tooltipText & " (" & shortcut & ")"
                  else: tooltipText
    let action = cstring(actionId)
    let clickHandler = proc() =
      if not vm.onDapStep.isNil:
        vm.onDapStep(action)

    let btn = ui(r):
      button(id = actionId & "-debug",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = clickHandler):
        img(src = imgSrc, height = imgHeight, width = imgWidth,
            class = "debug-button-svg")
        tdiv(class = "custom-tooltip"):
          text tipText
    r.appendChild(parent, btn)

    # Reactive disabled toggle — uses removeAttribute which the DSL
    # does not support, so this effect stays imperative.
    createRenderEffect proc() =
      if enabled():
        r.removeAttribute(btn, "disabled")
      else:
        r.setAttribute(btn, "disabled", "true")

  # -----------------------------------------------------------------------
  # Helper: create a debug action button (non-step, e.g. run-to-entry)
  # -----------------------------------------------------------------------
  proc addActionButton(r: WebRenderer; parent: isonim_dom.Element;
                       vm: DebugControlsVM;
                       actionId: string;
                       imgSrc: string; imgHeight: string; imgWidth: string;
                       tooltipText: string;
                       disabled: bool = false) =
    ## Render a non-step debug button (run-to-entry, reset-operation, etc.).
    let action = actionId
    let clickHandler = proc() =
      if not disabled and not vm.onAction.isNil:
        vm.onAction(action)

    let btn = ui(r):
      button(id = actionId & "-debug",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = clickHandler):
        img(src = imgSrc, height = imgHeight, width = imgWidth,
            class = "debug-button-svg")
        tdiv(class = "custom-tooltip"):
          text tooltipText
    if disabled:
      r.setAttribute(btn, "disabled", "true")
    r.appendChild(parent, btn)

  # -----------------------------------------------------------------------
  # Main panel renderer (WebRenderer)
  # -----------------------------------------------------------------------

  proc renderDebugControlsPanel*(r: WebRenderer;
                                  vm: DebugControlsVM): isonim_dom.Element =
    ## Render the complete Debug Controls toolbar using real DOM elements.
    ##
    ## The button layout matches the Karax version exactly:
    ##   [history-back] [history-forward] | [reverse-next] [next] |
    ##   [reverse-step-in] [step-in] | [reverse-step-out] [step-out] |
    ##   [reverse-continue] [continue] | [run-to-entry] |
    ##   [reset-operation] | [run-tests] |
    ##
    ## All IDs follow the `{action}-debug` pattern expected by
    ## Playwright page objects (e.g. `#next-debug`, `#continue-debug`).
    let panel = ui(r):
      tdiv(class = "ct-header isonim-debug-controls"):
        discard

    let alwaysEnabled = proc(): bool = true
    let canStep = proc(): bool = vm.canStepForward.val
    let canStepBack = proc(): bool = vm.canStepBackward.val
    let canCont = proc(): bool = vm.canContinue.val

    # -- History back / forward --
    addSeparator(r, panel)

    addActionButton(r, panel, vm, "history-back",
      "public/resources/debug/history_back_black.svg", "20px", "18px",
      "History back")

    addActionButton(r, panel, vm, "history-forward",
      "public/resources/debug/history_forward_black.svg", "20px", "18px",
      "History forward")

    addSeparator(r, panel)

    # -- Reverse next / Next --
    addStepButton(r, panel, vm, "reverse-next",
      "public/resources/debug/reverse_next_dark.svg", "20px", "18px",
      "Reverse next", "Shift-F10", canStepBack)

    addStepButton(r, panel, vm, "next",
      "public/resources/debug/next_dark.svg", "20px", "18px",
      "Next", "F10", canStep)

    addSeparator(r, panel)

    # -- Reverse step-in / Step-in --
    addStepButton(r, panel, vm, "reverse-step-in",
      "public/resources/debug/reverse_step-in_dark.svg", "14px", "16px",
      "Reverse step in", "Shift-F11", canStepBack)

    addStepButton(r, panel, vm, "step-in",
      "public/resources/debug/step-in_dark.svg", "14px", "16px",
      "Step in", "F11", canStep)

    addSeparator(r, panel)

    # -- Reverse step-out / Step-out --
    addStepButton(r, panel, vm, "reverse-step-out",
      "public/resources/debug/reverse_step-out_dark.svg", "14px", "16px",
      "Reverse step out", "Shift-F12", canStepBack)

    addStepButton(r, panel, vm, "step-out",
      "public/resources/debug/step-out_dark.svg", "14px", "16px",
      "Step out", "F12", canStep)

    addSeparator(r, panel)

    # -- Reverse continue / Continue --
    addStepButton(r, panel, vm, "reverse-continue",
      "public/resources/debug/reverse_continue_dark.svg", "16px", "28px",
      "Reverse continue", "Shift-F8", canCont)

    addStepButton(r, panel, vm, "continue",
      "public/resources/debug/continue_dark.svg", "16px", "28px",
      "Continue", "F8", canCont)

    addSeparator(r, panel)

    # -- Run to entry --
    addActionButton(r, panel, vm, "run-to-entry",
      "public/resources/debug/run_to_entry_dark.svg", "20px", "18px",
      "Run to entry")

    addSeparator(r, panel)

    # -- Reset operation --
    addActionButton(r, panel, vm, "reset-operation",
      "public/resources/debug/reset_operation_dark.svg", "16px", "18px",
      "Reset operation")

    addSeparator(r, panel)

    # -- Run tests --
    addActionButton(r, panel, vm, "run-tests",
      "public/resources/shared/run_test_img.svg", "12px", "18px",
      "Record and replay tests in a new window")

    addSeparator(r, panel)

    panel

  proc mountIsoNimDebugControls*(container: isonim_dom.Element;
                                  vm: DebugControlsVM) =
    ## Mount the IsoNim debug controls view into a real DOM container.
    ##
    ## Creates the reactive DOM tree and appends it as a child of
    ## `container`. The IsoNim reactive effects handle all subsequent
    ## updates — no manual redraw is needed.
    ##
    ## Call this once after the DebugControlsVM has been created.
    ## This view is the primary debug toolbar — the Karax debug controls
    ## are hidden via `display: none` on `#debug`.
    let r = WebRenderer()
    let panel = renderDebugControlsPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
