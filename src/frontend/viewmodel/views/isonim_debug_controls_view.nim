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
##   tooltips and `.separate-bar` dividers, IDs `{action}-image` for
##   Playwright targeting (see `page-objects/debug-toolbar-ids.ts`; the
##   ids were renamed from `{action}-debug` and this line said so for
##   longer than it was true — `jump-to-live-debug` is the one control
##   the rename left alone), and click handlers that delegate to the
##   VM's legacy bridge callbacks (`onDapStep`, `onAction`).
##
## Every button carries a `.custom-tooltip` child whose text is built by
## `DebugControlsVM.toolbarTooltip`, which READS the chord currently bound
## to that control instead of restating it. Both panels use it, so the
## headless lane can assert the same text the browser paints.
##
## Each panel is expressed as a single `ui()` block; per-button
## reactivity (the `disabled` attribute) is wired afterwards via the
## `reactiveDisabled` helper so the structure remains visible at one
## source location.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

import ./debug_control_marks

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
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("reverse-next", "Reverse next")
      button(ref = stepFwd, class = "step-forward",
             onclick = proc() = vm.stepForward()):
        text "▶"
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("next", "Next")
      button(ref = stepIn, class = "step-in",
             onclick = proc() = vm.stepIn()):
        text "↓"
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("step-in", "Step in")
      button(ref = stepOut, class = "step-out",
             onclick = proc() = vm.stepOut()):
        text "↑"
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("step-out", "Step out")
      button(ref = contBtn, class = "continue-btn",
             onclick = proc() = vm.continueExecution()):
        text "⏩"
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("continue", "Continue")
      button(ref = revContBtn, class = "reverse-continue",
             onclick = proc() = vm.reverseContinue()):
        text "⏪"
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("reverse-continue", "Reverse continue")
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
# All button IDs use the `{action}-image` pattern that Playwright page
# objects expect (e.g. `#next-image`, `#continue-image`), mapped in
# `src/tests/gui/page-objects/debug-toolbar-ids.ts`.

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
      headIndicator: isonim_dom.Element
      # jumpLiveBtn: isonim_dom.Element  # TODO: re-enable with jump-to-live-debug button

    let panel = ui(r):
      tdiv(class = "ct-header isonim-debug-controls",
           # WHICH SURFACE THIS IS. `#isonim-debug-controls` now holds one of
           # two panels — this one or the edit-mode toolbar — and they share
           # `run-tests-image`. Declaring the surface on both roots is what
           # lets a selector say which one it means, and it lets a check
           # distinguish "the debugger controls are mounted" from "no panel is
           # mounted at all", which reading the buttons alone cannot.
           `data-topbar-surface` = "debugger-controls",
           `data-session-mode` = $vm.store.session.val.debugSessionMode,
           `data-recording-head` = $vm.store.session.val.recordingHeadRRTicks):
        tdiv(class = "separate-bar"):
          discard
        # -- History navigation --
        button(id = "history-back-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = actionClick(vm, "history-back")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("history-back", "History back")
        button(id = "history-forward-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = actionClick(vm, "history-forward")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("history-forward", "History forward")
        tdiv(class = "separate-bar"):
          discard
        # -- Reverse next / Next --
        button(ref = revNextBtn, id = "reverse-next-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "reverse-next")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("reverse-next", "Reverse next")
        button(ref = nextBtn, id = "next-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "next")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("next", "Next")
        tdiv(class = "separate-bar"):
          discard
        # -- Reverse step-in / Step-in --
        button(ref = revStepInBtn, id = "reverse-step-in-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "reverse-step-in")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("reverse-step-in", "Reverse step in")
        button(ref = stepInBtn, id = "step-in-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "step-in")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("step-in", "Step in")
        tdiv(class = "separate-bar"):
          discard
        # -- Reverse step-out / Step-out --
        button(ref = revStepOutBtn, id = "reverse-step-out-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "reverse-step-out")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("reverse-step-out", "Reverse step out")
        button(ref = stepOutBtn, id = "step-out-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "step-out")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("step-out", "Step out")
        tdiv(class = "separate-bar"):
          discard
        # -- Reverse continue / Continue --
        button(ref = revContBtn, id = "reverse-continue-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "reverse-continue")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("reverse-continue", "Reverse continue")
        button(ref = contBtn, id = "continue-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = stepClick(vm, "continue")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("continue", "Continue")
        tdiv(class = "separate-bar"):
          discard
        # -- Run to entry --
        button(id = "run-to-entry-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = actionClick(vm, "run-to-entry")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("run-to-entry", "Run to entry")
        tdiv(class = "separate-bar"):
          discard
        # -- Reset operation --
        button(id = "reset-operation-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = actionClick(vm, "reset-operation")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("reset-operation", "Reset operation")
        tdiv(class = "separate-bar"):
          discard
        # -- Run tests --
        button(id = "run-tests-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               onclick = actionClick(vm, "run-tests")):
          tdiv(class = "custom-tooltip"):
            text vm.toolbarTooltip("run-tests", "Record and replay tests in a new window")
        if vm.toolbarModeText.val.len > 0:
          span(id = "debug-toolbar-mode",
               class = "debug-toolbar-mode"):
            text vm.toolbarModeText.val
        span(ref = headIndicator,
             id = "recording-head-indicator",
             class = "recording-head-indicator"):
          text vm.recordingHeadText.val
        # TODO: re-enable jump-to-live-debug button when ready
        # button(ref = jumpLiveBtn,
        #        id = "jump-to-live-debug",
        #        class = "ct-button-image-md-secondary ct-button-no-border jump-to-live-debug",
        #        onclick = proc() = vm.jumpToLive()):
        #   tdiv(class = "custom-tooltip"):
        #     text "Jump to live"
        # tdiv(class = "separate-bar"):
        #   discard

    reactiveDisabled(r, revNextBtn,    proc(): bool = not vm.canStepBackward.val)
    reactiveDisabled(r, nextBtn,       proc(): bool = not vm.canStepForward.val)
    reactiveDisabled(r, revStepInBtn,  proc(): bool = not vm.canStepBackward.val)
    reactiveDisabled(r, stepInBtn,     proc(): bool = not vm.canStepForward.val)
    reactiveDisabled(r, revStepOutBtn, proc(): bool = not vm.canStepBackward.val)
    reactiveDisabled(r, stepOutBtn,    proc(): bool = not vm.canStepForward.val)
    reactiveDisabled(r, revContBtn,    proc(): bool = not vm.canReverseContinue.val)
    reactiveDisabled(r, contBtn,       proc(): bool = not vm.canContinue.val)
    # reactiveDisabled(r, jumpLiveBtn,   proc(): bool = not vm.canJumpToLive.val)  # TODO: re-enable with jump-to-live-debug
    # reactiveDisabled(r, jumpLiveBtn,   proc(): bool = not vm.showJumpToLive.val)  # TODO: re-enable with jump-to-live-debug
    reactiveHidden(r, headIndicator,   proc(): bool = not vm.showRecordingHead.val)

    # The stepping marks. They are attached from the `ControlMarks` table
    # rather than written into the twelve `button(...)` calls above, so the
    # bar's structure stays readable at one glance and the marks stay in one
    # place. They are inline SVG painted with `currentColor` — see
    # `debug_control_marks` for why a `background-image` could not be themed.
    # A short count logs itself there: a bar whose marks failed to attach
    # still renders its buttons and they still click, so nothing else notices.
    discard attachControlMarks(panel)

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
