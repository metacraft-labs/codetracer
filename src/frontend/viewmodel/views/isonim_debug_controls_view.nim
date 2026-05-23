## views/isonim_debug_controls_view.nim
##
## IsoNim DOM-rendering view for the Debug Controls toolbar — primary
## renderer.
##
## Renders a live, reactive DOM tree driven by `DebugControlsVM`
## signals. Button enabled/disabled state is reactive on the VM's
## `canStepForward`, `canStepBackward`, `canContinue` memos; the
## status text reads `vm.statusText.val`.
##
## Two structures are produced:
##
## - `MockRenderer` — a minimal toolbar with text-glyph buttons used by
##   headless unit tests.
## - `WebRenderer` — the Karax-compatible toolbar with SVG icons,
##   tooltips and `.separate-bar` dividers, IDs `{action}-debug` for
##   Playwright targeting, and click handlers that delegate to the
##   VM's legacy bridge callbacks (`onDapStep`, `onAction`).
##
## Each panel is expressed as a single `ui()` block; per-button
## reactivity (the `disabled` attribute) is wired afterwards via the
## `reactiveDisabled` helper so the structure remains visible at one
## source location.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/debug_controls_vm

# ---------------------------------------------------------------------------
# Reactive disabled — a small helper used by both panels
# ---------------------------------------------------------------------------
#
# Browsers treat any value of `disabled` (including the empty string)
# as "disabled", so we must add the attribute when the condition is
# true and *remove* it when false. The DSL's dynamic-attribute path
# always emits `setAttribute`, so this case is wired imperatively
# against an element captured via `ref = var` in the surrounding
# `ui()` block.

proc reactiveDisabled[R, N](r: R; el: N; isDisabled: proc(): bool) =
  ## Reactively toggle the `disabled` attribute on `el`. Call once per
  ## button after the panel is built; the effect re-fires whenever a
  ## signal read by `isDisabled()` changes.
  createRenderEffect proc() =
    if isDisabled():
      r.setAttribute(el, "disabled", "true")
    else:
      r.removeAttribute(el, "disabled")

proc reactiveHidden[R, N](r: R; el: N; isHidden: proc(): bool) =
  ## Reactively hide/show an element while keeping its DOM identity stable.
  createRenderEffect proc() =
    if isHidden():
      r.setAttribute(el, "style", "display: none")
    else:
      r.removeAttribute(el, "style")

# ---------------------------------------------------------------------------
# MockRenderer panel — minimal toolbar for headless tests
# ---------------------------------------------------------------------------

proc renderDebugControlsPanel*(r: MockRenderer;
                               vm: DebugControlsVM): MockNode =
  ## Render the complete Debug Controls toolbar for headless tests.
  ##
  ## Structure:
  ##   div.debug-controls
  ##     button.step-backward[disabled reactive]   ◀
  ##     button.step-forward[disabled reactive]    ▶
  ##     button.step-in[disabled reactive]         ↓
  ##     button.step-out[disabled reactive]        ↑
  ##     button.continue-btn[disabled reactive]    ⏩
  ##     button.reverse-continue[disabled reactive] ⏪
  ##     span.debug-toolbar-mode                   mode reactive
  ##     span.recording-head-indicator             head reactive
  ##     button.jump-to-live                       Live
  ##     span.debug-status-text                    text reactive
  var
    stepBack, stepFwd, stepIn, stepOut, contBtn, revContBtn: MockNode
    headIndicator, jumpLiveBtn: MockNode

  let panel = ui(r):
    tdiv(class = "debug-controls",
         `data-session-mode` = $vm.store.session.val.debugSessionMode,
         `data-recording-head` = $vm.store.session.val.recordingHeadRRTicks):
      button(ref = stepBack, class = "step-backward",
             onclick = proc() = vm.stepBackward()):
        text "◀"
      button(ref = stepFwd, class = "step-forward",
             onclick = proc() = vm.stepForward()):
        text "▶"
      button(ref = stepIn, class = "step-in",
             onclick = proc() = vm.stepIn()):
        text "↓"
      button(ref = stepOut, class = "step-out",
             onclick = proc() = vm.stepOut()):
        text "↑"
      button(ref = contBtn, class = "continue-btn",
             onclick = proc() = vm.continueExecution()):
        text "⏩"
      button(ref = revContBtn, class = "reverse-continue",
             onclick = proc() = vm.reverseContinue()):
        text "⏪"
      if vm.toolbarModeText.val.len > 0:
        span(class = "debug-toolbar-mode"):
          text vm.toolbarModeText.val
      span(ref = headIndicator, class = "recording-head-indicator"):
        text vm.recordingHeadText.val
      button(ref = jumpLiveBtn, class = "jump-to-live",
             onclick = proc() = vm.jumpToLive()):
        text "Live"
      span(class = "debug-status-text"):
        text vm.statusText.val

  reactiveDisabled(r, stepBack,    proc(): bool = not vm.canStepBackward.val)
  reactiveDisabled(r, stepFwd,     proc(): bool = not vm.canStepForward.val)
  reactiveDisabled(r, stepIn,      proc(): bool = not vm.canStepForward.val)
  reactiveDisabled(r, stepOut,     proc(): bool = not vm.canStepForward.val)
  reactiveDisabled(r, contBtn,     proc(): bool = not vm.canContinue.val)
  reactiveDisabled(r, revContBtn,  proc(): bool = not vm.canReverseContinue.val)
  reactiveDisabled(r, jumpLiveBtn, proc(): bool = not vm.canJumpToLive.val)
  reactiveHidden(r, headIndicator, proc(): bool = not vm.showRecordingHead.val)
  reactiveHidden(r, jumpLiveBtn,   proc(): bool = not vm.showJumpToLive.val)

  panel

# ---------------------------------------------------------------------------
# WebRenderer panel — Karax-compatible toolbar
# ---------------------------------------------------------------------------
#
# The toolbar layout matches the legacy Karax debug controls exactly:
#   [history-back] [history-forward] | [reverse-next] [next] |
#   [reverse-step-in] [step-in] | [reverse-step-out] [step-out] |
#   [reverse-continue] [continue] | [run-to-entry] |
#   [reset-operation] | [run-tests] |
#
# All button IDs use the `{action}-debug` pattern that Playwright page
# objects expect (e.g. `#next-debug`, `#continue-debug`).

when defined(js):

  template stepClick(vm: DebugControlsVM; actionId: string): proc() =
    ## Build a click handler that dispatches through the VM. The VM prefers
    ## the legacy DAP bridge when installed and falls back to the shared
    ## backend otherwise, so clicks do not silently disappear during VM
    ## replacement/mount ordering.
    let action = cstring(actionId)
    proc() =
      vm.invokeToolbarStep($action)

  template actionClick(vm: DebugControlsVM; actionId: string): proc() =
    ## Build a click handler for non-step actions (run-to-entry,
    ## reset-operation, run-tests). Delegates to `vm.onAction`.
    let action = actionId
    proc() =
      if not vm.onAction.isNil:
        vm.onAction(action)

  proc renderDebugControlsPanel*(r: WebRenderer;
                                 vm: DebugControlsVM): isonim_dom.Element =
    ## Render the complete Debug Controls toolbar using real DOM
    ## elements. Every step button's `disabled` attribute is reactive
    ## on the relevant VM memo; the structure itself is static.
    var
      revNextBtn, nextBtn:        isonim_dom.Element
      revStepInBtn, stepInBtn:    isonim_dom.Element
      revStepOutBtn, stepOutBtn:  isonim_dom.Element
      revContBtn, contBtn:        isonim_dom.Element
      headIndicator, jumpLiveBtn: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = "ct-header isonim-debug-controls",
           `data-session-mode` = $vm.store.session.val.debugSessionMode,
           `data-recording-head` = $vm.store.session.val.recordingHeadRRTicks):
        tdiv(class = "separate-bar"):
          discard
        # -- History navigation --
        button(id = "history-back-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = actionClick(vm, "history-back")):
          img(src = "public/resources/debug/history_back_black.svg",
              height = "20px", width = "18px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "History back"
        button(id = "history-forward-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = actionClick(vm, "history-forward")):
          img(src = "public/resources/debug/history_forward_black.svg",
              height = "20px", width = "18px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "History forward"
        tdiv(class = "separate-bar"):
          discard
        # -- Reverse next / Next --
        button(ref = revNextBtn, id = "reverse-next-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "reverse-next")):
          img(src = "public/resources/debug/reverse_next_dark.svg",
              height = "20px", width = "18px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "Reverse next (Shift-F10)"
        button(ref = nextBtn, id = "next-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "next")):
          img(src = "public/resources/debug/next_dark.svg",
              height = "20px", width = "18px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "Next (F10)"
        tdiv(class = "separate-bar"):
          discard
        # -- Reverse step-in / Step-in --
        button(ref = revStepInBtn, id = "reverse-step-in-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "reverse-step-in")):
          img(src = "public/resources/debug/reverse_step-in_dark.svg",
              height = "14px", width = "16px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "Reverse step in (Shift-F11)"
        button(ref = stepInBtn, id = "step-in-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "step-in")):
          img(src = "public/resources/debug/step-in_dark.svg",
              height = "14px", width = "16px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "Step in (F11)"
        tdiv(class = "separate-bar"):
          discard
        # -- Reverse step-out / Step-out --
        button(ref = revStepOutBtn, id = "reverse-step-out-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "reverse-step-out")):
          img(src = "public/resources/debug/reverse_step-out_dark.svg",
              height = "14px", width = "16px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "Reverse step out (Shift-F12)"
        button(ref = stepOutBtn, id = "step-out-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "step-out")):
          img(src = "public/resources/debug/step-out_dark.svg",
              height = "14px", width = "16px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "Step out (F12)"
        tdiv(class = "separate-bar"):
          discard
        # -- Reverse continue / Continue --
        button(ref = revContBtn, id = "reverse-continue-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "reverse-continue")):
          img(src = "public/resources/debug/reverse_continue_dark.svg",
              height = "16px", width = "28px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "Reverse continue (Shift-F8)"
        button(ref = contBtn, id = "continue-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "continue")):
          img(src = "public/resources/debug/continue_dark.svg",
              height = "16px", width = "28px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "Continue (F8)"
        tdiv(class = "separate-bar"):
          discard
        # -- Run to entry --
        button(id = "run-to-entry-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = actionClick(vm, "run-to-entry")):
          img(src = "public/resources/debug/run_to_entry_dark.svg",
              height = "20px", width = "18px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "Run to entry"
        tdiv(class = "separate-bar"):
          discard
        # -- Reset operation --
        button(id = "reset-operation-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = actionClick(vm, "reset-operation")):
          img(src = "public/resources/debug/reset_operation_dark.svg",
              height = "16px", width = "18px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "Reset operation"
        tdiv(class = "separate-bar"):
          discard
        # -- Run tests --
        button(id = "run-tests-debug",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = actionClick(vm, "run-tests")):
          img(src = "public/resources/shared/run_test_img.svg",
              height = "12px", width = "18px", class = "debug-button-svg")
          tdiv(class = "custom-tooltip"):
            text "Record and replay tests in a new window"
        tdiv(class = "separate-bar"):
          discard
        if vm.toolbarModeText.val.len > 0:
          span(id = "debug-toolbar-mode",
               class = "debug-toolbar-mode"):
            text vm.toolbarModeText.val
        span(ref = headIndicator,
             id = "recording-head-indicator",
             class = "recording-head-indicator"):
          text vm.recordingHeadText.val
        button(ref = jumpLiveBtn,
               id = "jump-to-live-debug",
               class = "ct-button-image-md-secondary ct-button-no-border jump-to-live-debug",
               onclick = proc() = vm.jumpToLive()):
          text "Live"
          tdiv(class = "custom-tooltip"):
            text "Jump to live"
        tdiv(class = "separate-bar"):
          discard

    reactiveDisabled(r, revNextBtn,    proc(): bool = not vm.canStepBackward.val)
    reactiveDisabled(r, nextBtn,       proc(): bool = not vm.canStepForward.val)
    reactiveDisabled(r, revStepInBtn,  proc(): bool = not vm.canStepBackward.val)
    reactiveDisabled(r, stepInBtn,     proc(): bool = not vm.canStepForward.val)
    reactiveDisabled(r, revStepOutBtn, proc(): bool = not vm.canStepBackward.val)
    reactiveDisabled(r, stepOutBtn,    proc(): bool = not vm.canStepForward.val)
    reactiveDisabled(r, revContBtn,    proc(): bool = not vm.canReverseContinue.val)
    reactiveDisabled(r, contBtn,       proc(): bool = not vm.canContinue.val)
    reactiveDisabled(r, jumpLiveBtn,   proc(): bool = not vm.canJumpToLive.val)
    reactiveHidden(r, headIndicator,   proc(): bool = not vm.showRecordingHead.val)
    reactiveHidden(r, jumpLiveBtn,     proc(): bool = not vm.showJumpToLive.val)

    panel

  proc mountIsoNimDebugControls*(container: isonim_dom.Element;
                                 vm: DebugControlsVM) =
    ## Mount the IsoNim debug controls toolbar as a child of
    ## `container`. Reactive effects handle every subsequent update —
    ## no manual redraw is needed. Call once after the
    ## `DebugControlsVM` exists.
    let r = WebRenderer()
    let panel = renderDebugControlsPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
