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
## - Whether the current execution cursor is live or historical
##
## Derives:
## - `activeFileName`: the file name for the currently active tab,
##   read from the store's debugger location
## - `activeSourceGeneration` / `activeSourceDigest`: source revision
##   identity for workflows where the same file path has multiple recorded
##   contents, such as live HCR
##
## Degraded state (Page-Descriptions.md §14):
## - `degradedState`: the one §14 row this pane renders, resolved from the
##   store's four axes against `EditorPaneDegradations`
## - `sourceAvailability` / `instructionLevelStepping`: §14's "No verified
##   source" row, which is the editor's alone because it is the only pane
##   that renders source
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
    ##   activeSourceGeneration — source revision generation for the active
    ##                            debugger location
    ##   activeSourceDigest   — optional content digest for the active source
    ##                          revision
    ##   executionCursorKind  — semantic cursor kind for live/historical stops
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
    activeSourceGeneration*: Memo[int]
    activeSourceDigest*: Memo[string]
    executionCursorKind*: Memo[string]

    # -- Degraded state (Page-Descriptions.md §14) --
    degradedState*: Memo[PaneDegradation]
      ## The one value the view renders a treatment for, resolved from
      ## the store's four axes against `EditorPaneDegradations`. §14:
      ## "Every row above is a value of an enum on a ViewModel, not a
      ## branch in a view."
    sourceAvailability*: Memo[SourceAvailability]
      ## The raw axis behind §14's "No verified source" row, exposed
      ## alongside `degradedState` because the editor is the pane that
      ## has to tell `savUnverified` (offer the supply-sources action)
      ## from `savAbsent` (there is nothing to supply sources *for*).
    instructionLevelStepping*: Memo[bool]
      ## §14's canonical treatment for "No verified source":
      ## "Instruction-level stepping, with the supply-sources action
      ## prominent." A memo rather than a view-side `if` over
      ## `sourceAvailability`, so both surfaces agree on when the editor
      ## stops being a source view.

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

    let activeSourceGeneration = createMemo[int] proc(): int =
      store.debugger.val.location.sourceGeneration

    let activeSourceDigest = createMemo[string] proc(): string =
      store.debugger.val.location.sourceDigest

    let executionCursorKind = createMemo[string] proc(): string =
      case store.session.val.debugSessionMode
      of liveMcr:
        "live-mcr"
      of liveMaterialized:
        "live-recording"
      of historicalFromLive:
        "historical"
      of completedReplay:
        "replay"

    # Derived: the §14 degraded state this pane renders.
    let degradedState = createMemo[PaneDegradation] proc(): PaneDegradation =
      resolveDegradation(store.degradedSnapshot(), EditorPaneDegradations)

    let sourceAvailability = createMemo[SourceAvailability] proc(): SourceAvailability =
      store.degraded.sourceAvailability.val

    let instructionLevelStepping = createMemo[bool] proc(): bool =
      store.degraded.sourceAvailability.val != savVerified

    EditorVM(
      store: store,
      activeTabIndex: activeTabIndex,
      cursorLine: cursorLine,
      cursorColumn: cursorColumn,
      scrollTop: scrollTop,
      showFlowOverlay: showFlowOverlay,
      showBreakpointGutter: showBreakpointGutter,
      activeFileName: activeFileName,
      activeSourceGeneration: activeSourceGeneration,
      activeSourceDigest: activeSourceDigest,
      executionCursorKind: executionCursorKind,
      degradedState: degradedState,
      sourceAvailability: sourceAvailability,
      instructionLevelStepping: instructionLevelStepping,
      disposeProc: dispose,
    )
