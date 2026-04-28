## viewmodels/shell_vm.nim
##
## ShellVM — ViewModel for the Shell / REPL panel.
##
## Holds reactive state for:
## - Current input buffer text
## - Scroll position within the output
## - Input history (list of previously submitted commands)
## - History navigation index
##
## Usage:
##   let vm = createShellVM(store)
##   vm.setInput("print(x)")
##   vm.submitInput()
##   echo vm.inputHistory.val    # @["print(x)"]
##   echo vm.inputBuffer.val     # "" (cleared after submit)

import std/[json, options]

import isonim/core/[signals, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

type
  ShellVM* = ref object of ViewModel
    ## Reactive state for the Shell / REPL panel.
    ##
    ## Mutable signals:
    ##   inputBuffer    — the text currently in the input field
    ##   scrollPosition — scroll offset in the output area (in lines)
    ##   inputHistory   — list of previously submitted commands
    ##   historyIndex   — current position when navigating history
    ##                    (-1 means "not navigating", 0 = most recent)
    ##
    ## The store reference is kept for submitting commands to the backend.
    store*: ReplayDataStore

    # -- Mutable state --
    inputBuffer*: Signal[string]
    scrollPosition*: Signal[int]
    inputHistory*: Signal[seq[string]]
    historyIndex*: Signal[int]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setInput*(vm: ShellVM; text: string) =
  ## Set the input buffer text.
  vm.inputBuffer.val = text

proc submitInput*(vm: ShellVM) =
  ## Submit the current input buffer to the backend.
  ## Adds the input to history and clears the buffer.
  ## Empty inputs are ignored.
  let text = vm.inputBuffer.val
  if text.len == 0:
    return

  # Add to history.
  var history = vm.inputHistory.val
  history.add(text)
  vm.inputHistory.val = history

  # Reset history navigation.
  vm.historyIndex.val = -1

  # Clear the input buffer.
  vm.inputBuffer.val = ""

  # Send to backend.
  let args = %*{"command": text}
  discard vm.store.backend.send("ct/shell-eval", args)

proc historyUp*(vm: ShellVM) =
  ## Navigate up (older) in the input history.
  ## Replaces the input buffer with the history entry.
  let history = vm.inputHistory.val
  if history.len == 0:
    return

  let currentIdx = vm.historyIndex.val
  var newIdx: int
  if currentIdx == -1:
    # Start navigating from the most recent entry.
    newIdx = history.len - 1
  elif currentIdx > 0:
    newIdx = currentIdx - 1
  else:
    # Already at the oldest entry.
    return

  vm.historyIndex.val = newIdx
  vm.inputBuffer.val = history[newIdx]

proc historyDown*(vm: ShellVM) =
  ## Navigate down (newer) in the input history.
  ## Replaces the input buffer with the history entry, or clears
  ## it if moving past the most recent entry.
  let history = vm.inputHistory.val
  let currentIdx = vm.historyIndex.val

  if currentIdx == -1:
    # Not navigating history — nothing to do.
    return

  if currentIdx < history.len - 1:
    let newIdx = currentIdx + 1
    vm.historyIndex.val = newIdx
    vm.inputBuffer.val = history[newIdx]
  else:
    # Move past the most recent entry — clear input and exit
    # history navigation mode.
    vm.historyIndex.val = -1
    vm.inputBuffer.val = ""

proc scroll*(vm: ShellVM; position: int) =
  ## Set the scroll position in the output area.
  ## Negative values are clamped to 0.
  if position < 0:
    vm.scrollPosition.val = 0
  else:
    vm.scrollPosition.val = position

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createShellVM*(store: ReplayDataStore): ShellVM =
  ## Create a ShellVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up mutable signals with sensible defaults.
  withViewModel proc(dispose: proc()): ShellVM =
    ShellVM(
      store: store,
      inputBuffer: createSignal(""),
      scrollPosition: createSignal(0),
      inputHistory: createSignal(newSeq[string]()),
      historyIndex: createSignal(-1),
      disposeProc: dispose,
    )
