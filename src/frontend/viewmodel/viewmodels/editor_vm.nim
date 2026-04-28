## viewmodels/editor_vm.nim
##
## EditorVM — ViewModel for the Editor panel.
##
## Holds reactive state for:
## - Active tab index (which editor tab is focused)
## - Cursor position (line, column)
## - Scroll position
## - Whether the flow overlay is visible
## - Whether the breakpoint gutter is visible
##
## Derives:
## - `activeFileName`: the file name for the currently active tab,
##   read from the store's debugger location
##
## Usage:
##   let vm = createEditorVM(store)
##   echo vm.activeTabIndex.val       # 0
##   vm.switchTab(2)
##   echo vm.cursorLine.val           # 1

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]

type
  EditorVM* = ref object of ViewModel
    ## Reactive state for the Editor panel.
    ##
    ## Mutable signals:
    ##   activeTabIndex       — index of the currently focused editor tab
    ##   cursorLine           — current cursor line (1-based)
    ##   cursorColumn         — current cursor column (1-based)
    ##   scrollTop            — scroll offset in lines from the top
    ##   showFlowOverlay      — whether the flow overlay is displayed
    ##   showBreakpointGutter — whether the breakpoint gutter is visible
    ##
    ## Derived memos:
    ##   activeFileName       — file name from the store's debugger location
    ##
    ## The store reference is kept for deriving state from the debugger.
    store*: ReplayDataStore

    # -- Mutable state --
    activeTabIndex*: Signal[int]
    cursorLine*: Signal[int]
    cursorColumn*: Signal[int]
    scrollTop*: Signal[int]
    showFlowOverlay*: Signal[bool]
    showBreakpointGutter*: Signal[bool]

    # -- Derived state --
    activeFileName*: Memo[string]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc switchTab*(vm: EditorVM; index: int) =
  ## Switch to a different editor tab by index.
  ## Negative indices are clamped to 0.
  if index < 0:
    vm.activeTabIndex.val = 0
  else:
    vm.activeTabIndex.val = index

proc closeTab*(vm: EditorVM; index: int) =
  ## Close the tab at `index`. If the closed tab was active (or to
  ## the left of the active tab), the active tab index is adjusted.
  ## In this minimal VM we just reset activeTabIndex to 0 when the
  ## closed tab is the active one.
  if index == vm.activeTabIndex.val:
    vm.activeTabIndex.val = 0
  elif index < vm.activeTabIndex.val:
    # A tab to the left was closed — shift active index left.
    vm.activeTabIndex.val = vm.activeTabIndex.val - 1

proc setCursor*(vm: EditorVM; line: int; column: int) =
  ## Set the cursor position. Line and column are 1-based.
  ## Values below 1 are clamped.
  vm.cursorLine.val = max(1, line)
  vm.cursorColumn.val = max(1, column)

proc toggleFlowOverlay*(vm: EditorVM) =
  ## Toggle visibility of the flow overlay in the editor.
  vm.showFlowOverlay.val = not vm.showFlowOverlay.val

proc toggleBreakpointGutter*(vm: EditorVM) =
  ## Toggle visibility of the breakpoint gutter in the editor.
  vm.showBreakpointGutter.val = not vm.showBreakpointGutter.val

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createEditorVM*(store: ReplayDataStore): EditorVM =
  ## Create an EditorVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults
  ## 2. Derived memo for `activeFileName`
  withViewModel proc(dispose: proc()): EditorVM =
    let activeTabIndex = createSignal(0)
    let cursorLine = createSignal(1)
    let cursorColumn = createSignal(1)
    let scrollTop = createSignal(0)
    let showFlowOverlay = createSignal(false)
    let showBreakpointGutter = createSignal(true)

    # Derived: the file name from the store's current debugger location.
    let activeFileName = createMemo[string] proc(): string =
      store.debugger.val.location.file

    EditorVM(
      store: store,
      activeTabIndex: activeTabIndex,
      cursorLine: cursorLine,
      cursorColumn: cursorColumn,
      scrollTop: scrollTop,
      showFlowOverlay: showFlowOverlay,
      showBreakpointGutter: showBreakpointGutter,
      activeFileName: activeFileName,
      disposeProc: dispose,
    )
