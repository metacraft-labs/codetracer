## views/debug_controls_view.nim
##
## View-state extraction for the debug controls toolbar.
##
## Provides `DebugControlsViewState`, a plain data object that captures
## the current state of the DebugControlsVM as a renderer-agnostic
## snapshot.  Any view layer (Karax, IsoNim `ui`, TUI) can call
## `getViewState` to obtain a flat struct suitable for rendering.
##
## This is the contract between the ViewModel and View layers for the
## debug controls toolbar.  The view state is intentionally a value
## type with no reactive dependencies — it is a one-shot snapshot that
## the renderer reads synchronously.
##
## Usage:
##   let vs = getViewState(session.debugControlsVM)
##   if vs.stepForwardEnabled:
##     renderButton("Step Forward")

import isonim/core/[signals, computation]

import ../viewmodels/debug_controls_vm

type
  DebugControlsViewState* = object
    ## Renderer-agnostic snapshot of the debug controls toolbar.
    ##
    ## Each field maps directly to a ViewModel memo:
    ##   stepForwardEnabled   — can the user step forward?
    ##   stepBackwardEnabled  — can the user step backward?
    ##   continueEnabled      — can the user continue execution?
    ##   reverseContinueEnabled — can the user reverse-continue?
    ##   stepInEnabled        — can the user step into a call?
    ##   stepOutEnabled       — can the user step out of a call?
    ##   statusText           — human-readable debugger status
    ##   isRunning            — is the debugger actively running?
    stepForwardEnabled*: bool
    stepBackwardEnabled*: bool
    continueEnabled*: bool
    reverseContinueEnabled*: bool
    stepInEnabled*: bool
    stepOutEnabled*: bool
    statusText*: string
    isRunning*: bool

proc getViewState*(vm: DebugControlsVM): DebugControlsViewState =
  ## Extract the current view state from the DebugControlsVM.
  ##
  ## Reads each memo exactly once and returns a plain object.
  ## The `stepIn` and `stepOut` buttons share the `canStepForward`
  ## guard (you can only step into or out of a call when the
  ## debugger is in a steppable state), and `reverseContinue` shares
  ## the `canContinue` guard.
  DebugControlsViewState(
    stepForwardEnabled: vm.canStepForward.val,
    stepBackwardEnabled: vm.canStepBackward.val,
    continueEnabled: vm.canContinue.val,
    reverseContinueEnabled: vm.canContinue.val,
    stepInEnabled: vm.canStepForward.val,
    stepOutEnabled: vm.canStepForward.val,
    statusText: vm.statusText.val,
    isRunning: vm.isRunning.val,
  )
