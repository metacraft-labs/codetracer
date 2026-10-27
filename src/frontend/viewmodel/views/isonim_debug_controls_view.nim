## views/isonim_debug_controls_view.nim
##
## The topbar's debugger controls, as ONE view generic over the renderer
## (Shared-DOM-Front-Ends D3): the same proc runs under `MockRenderer` in the
## headless lanes and under `WebRenderer` in Electron and the web page.
##
## Every button is the toolbar action its id names, dispatched through
## `DebugControlsVM.invokeToolbarAction` — the one route a click, a key chord
## and a menu item take. Ids follow the `{action}-image` pattern the
## Playwright page objects expect (`page-objects/debug-toolbar-ids.ts`).
##
## Every button carries a `.custom-tooltip` child whose text is built by
## `DebugControlsVM.toolbarTooltip`, which READS the chord bound to that
## control instead of restating it.
##
## Structure that changes is expressed with IsoNim's control-flow components,
## never with `if` / `for` over a signal inside `ui(r)`: the mode label and
## the history lists are `show` regions, the lists' rows an `indexEach`. A
## button's `disabled` attribute is a render effect on its VM memo.
##
## `renderTopbar` is what the menu shell puts in its toolbar host: this panel
## or the edit-mode toolbar, chosen by `DebugControlsVM.topbarSurface`.

import std/[options, strutils]

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

import ./debug_control_marks
import ./isonim_edit_mode_toolbar_view

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/[debug_controls_vm, edit_mode_toolbar]
# A generic view is instantiated where it is called, and the `ui` macro's
# expansion names `createRenderEffect` and the control-flow components there:
# exported so a caller needs no IsoNim import of its own to render this view.
export signals, computation, components

const
  HistoryListId* = "history-list"
    ## The open jump-history list's container.

# ---------------------------------------------------------------------------
# Reactive attributes
# ---------------------------------------------------------------------------
#
# Browsers treat any value of `disabled` (including the empty string) as
# "disabled", so the attribute is added when the condition holds and REMOVED
# when it does not. The DSL's dynamic-attribute path always emits
# `setAttribute`, so this case is wired against an element captured with
# `ref = …` in the surrounding `ui()` block.

proc reactiveDisabled[R, N](r: R; el: N; isDisabled: proc(): bool) =
  createRenderEffect proc() =
    if isDisabled():
      r.setAttribute(el, "disabled", "true")
    else:
      r.removeAttribute(el, "disabled")

proc reactiveHidden[R, N](r: R; el: N; isHidden: proc(): bool) =
  ## Hide or show an element while keeping its DOM identity stable.
  createRenderEffect proc() =
    if isHidden():
      r.setAttribute(el, "style", "display: none")
    else:
      r.removeAttribute(el, "style")

proc action(vm: DebugControlsVM; actionId: string): proc() =
  ## A click handler for one toolbar action, closing over THIS id.
  let id = actionId
  proc() = vm.invokeToolbarAction(id)

proc historyEntryLabel*(entry: JumpEntry): string =
  ## How a jump-history entry reads in the list: where, and when.
  let file = entry.location.file
  let base = file[file.rfind('/') + 1 .. ^1]
  result = base & ":" & $entry.location.line & "  tick " & $entry.rrTicks
  if entry.lastOperation.len > 0:
    result.add "  (" & entry.lastOperation & ")"

# ---------------------------------------------------------------------------
# The history lists (`jump-before` / `jump-after`)
# ---------------------------------------------------------------------------

proc renderHistoryList[R, N](r: R; parent: N; vm: DebugControlsVM) =
  ## The open history list: one row per entry, most relevant first; choosing
  ## a row jumps there, `Escape`-like closing is the close button.
  show(r, parent,
    condition = proc(): bool = vm.historyList.val != hlNone,
    body = proc(): N =
      var rows: N
      let list = ui(r):
        tdiv(id = HistoryListId, class = "history-list",
             `data-history-list` = (if vm.historyList.val == hlBefore: "before"
                                    else: "after")):
          tdiv(ref = rows, class = "history-list-rows"):
            discard
          button(class = "history-list-close",
                 onclick = proc() = vm.stopJump()):
            text "Close"
      indexEach[JumpEntry, R, N](r, rows,
        proc(): seq[JumpEntry] = vm.historyListEntries.val,
        proc(entry: proc(): JumpEntry, index: int): N =
          let position = index
          ui(r):
            button(class = "history-list-entry",
                   onclick = proc() = vm.chooseHistoryEntry(position)):
              text historyEntryLabel(entry()))
      list)

# ---------------------------------------------------------------------------
# The debugger controls
# ---------------------------------------------------------------------------

proc renderDebugControlsPanel*[R, N](r: R; vm: DebugControlsVM): N =
  ## The debugger-controls toolbar. Its layout is the desktop's, which the
  ## Mode-Transitions rules forbid reordering:
  ##   [history-back] [history-list-before] [history-forward]
  ##   [history-list-after] | [reverse-next] [next] | [reverse-step-in]
  ##   [step-in] | [reverse-step-out] [step-out] | [reverse-continue]
  ##   [continue] | [run-to-entry] | [reset-operation] | [run-tests] | [stop]
  ## `stop` is last behind its own divider: it is the only control here that
  ## LEAVES the session rather than moving within it.
  var
    backBtn, forwardBtn: N
    revNextBtn, nextBtn: N
    revStepInBtn, stepInBtn: N
    revStepOutBtn, stepOutBtn: N
    revContBtn, contBtn: N
    runTestsBtn: N
    modeHost, headIndicator, listHost: N

  let panel = ui(r):
    tdiv(class = "ct-header isonim-debug-controls",
         # WHICH SURFACE THIS IS. The toolbar host carries this panel or the
         # edit-mode toolbar, and they share `run-tests-image`; the root says
         # which one a selector is looking at.
         `data-topbar-surface` = DebugToolbarSurfaceValue,
         `data-session-mode` = $vm.store.session.val.debugSessionMode,
         `data-recording-head` = $vm.store.session.val.recordingHeadRRTicks):
      tdiv(class = "separate-bar"):
        discard
      # -- History navigation, and its two lists --
      button(ref = backBtn, id = "history-back-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "history-back")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("history-back", "History back")
      button(id = "history-list-before-image",
             class = "ct-button-image-md-secondary ct-button-no-border history-list-toggle",
             onclick = action(vm, "jump-before")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("jump-before", "Earlier positions")
      button(ref = forwardBtn, id = "history-forward-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "history-forward")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("history-forward", "History forward")
      button(id = "history-list-after-image",
             class = "ct-button-image-md-secondary ct-button-no-border history-list-toggle",
             onclick = action(vm, "jump-after")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("jump-after", "Later positions")
      tdiv(class = "separate-bar"):
        discard
      # -- Reverse next / Next --
      button(ref = revNextBtn, id = "reverse-next-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "reverse-next")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("reverse-next")
      button(ref = nextBtn, id = "next-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "next")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("next")
      tdiv(class = "separate-bar"):
        discard
      # -- Reverse step-in / Step-in --
      button(ref = revStepInBtn, id = "reverse-step-in-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "reverse-step-in")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("reverse-step-in")
      button(ref = stepInBtn, id = "step-in-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "step-in")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("step-in")
      tdiv(class = "separate-bar"):
        discard
      # -- Reverse step-out / Step-out --
      button(ref = revStepOutBtn, id = "reverse-step-out-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "reverse-step-out")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("reverse-step-out")
      button(ref = stepOutBtn, id = "step-out-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "step-out")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("step-out")
      tdiv(class = "separate-bar"):
        discard
      # -- Reverse continue / Continue --
      button(ref = revContBtn, id = "reverse-continue-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "reverse-continue")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("reverse-continue")
      button(ref = contBtn, id = "continue-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "continue")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("continue")
      tdiv(class = "separate-bar"):
        discard
      # -- Run to entry --
      button(id = "run-to-entry-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "run-to-entry")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("run-to-entry")
      tdiv(class = "separate-bar"):
        discard
      # -- Reset operation --
      button(id = "reset-operation-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "reset-operation")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("reset-operation", "Reset operation")
      tdiv(class = "separate-bar"):
        discard
      # -- Run tests: pending while the run it started is in progress --
      button(ref = runTestsBtn, id = "run-tests-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "run-tests")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("run-tests", "Record and replay tests in a new window")
      tdiv(class = "separate-bar"):
        discard
      # -- Stop: the way out of the replay session, and back to editing.
      # `GUI/Debugging-Features/Debugger-Controls.md` requires Stop to be
      # reachable as a button, a menu entry and a chord.
      button(id = "stop-image",
             class = "ct-button-image-md-secondary ct-button-no-border",
             onclick = action(vm, "stop")):
        tdiv(class = "custom-tooltip"):
          text vm.toolbarTooltip("stop", "Stop and return to editing")
      span(ref = modeHost, class = "debug-toolbar-mode-host"):
        discard
      span(ref = headIndicator,
           id = "recording-head-indicator",
           class = "recording-head-indicator"):
        text vm.recordingHeadText.val
      tdiv(ref = listHost, class = "history-list-host"):
        discard

  show(r, modeHost,
    condition = proc(): bool = vm.toolbarModeText.val.len > 0,
    body = proc(): N =
      ui(r):
        span(id = "debug-toolbar-mode", class = "debug-toolbar-mode"):
          text vm.toolbarModeText.val)
  renderHistoryList(r, listHost, vm)

  reactiveDisabled(r, backBtn,       proc(): bool = not vm.canGoBack.val)
  reactiveDisabled(r, forwardBtn,    proc(): bool = not vm.canGoForward.val)
  reactiveDisabled(r, revNextBtn,    proc(): bool = not vm.canStepBackward.val)
  reactiveDisabled(r, nextBtn,       proc(): bool = not vm.canStepForward.val)
  reactiveDisabled(r, revStepInBtn,  proc(): bool = not vm.canStepBackward.val)
  reactiveDisabled(r, stepInBtn,     proc(): bool = not vm.canStepForward.val)
  reactiveDisabled(r, revStepOutBtn, proc(): bool = not vm.canStepBackward.val)
  reactiveDisabled(r, stepOutBtn,    proc(): bool = not vm.canStepForward.val)
  reactiveDisabled(r, revContBtn,    proc(): bool = not vm.canReverseContinue.val)
  reactiveDisabled(r, contBtn,       proc(): bool = not vm.canContinue.val)
  reactiveDisabled(r, runTestsBtn,   proc(): bool = vm.runTestsPending.val)
  reactiveHidden(r, headIndicator,   proc(): bool = not vm.showRecordingHead.val)

  # The stepping marks, attached from the `ControlMarks` table on the web: they
  # are inline SVG painted with `currentColor` (see `debug_control_marks`).
  when defined(js):
    when N is isonim_dom.Element:
      discard attachControlMarks(panel)

  panel

# ---------------------------------------------------------------------------
# The topbar host's content
# ---------------------------------------------------------------------------

proc renderTopbar*[R, N](r: R; parent: N; vm: DebugControlsVM) =
  ## Fill the menu shell's toolbar host: the debugger controls, or the
  ## edit-mode commands a platform installed, by `vm.topbarSurface`.
  show(r, parent,
    condition = proc(): bool = vm.topbarSurface.val == tsDebuggerControls,
    body = proc(): N = renderDebugControlsPanel[R, N](r, vm),
    fallback = proc(): N =
      renderEditModeToolbarPanel[R, N](r,
        proc(): EditToolbarModel = vm.editToolbar.val.get(EditToolbarModel()),
        proc(id: string) =
          if not vm.editToolbarInvoke.isNil:
            vm.editToolbarInvoke(id)))
