## viewmodels/search_vm.nim
##
## SearchVM — ViewModel for the Search / Command palette panel.
##
## Holds reactive state for:
## - Search mode (command, file, find-in-files, find-symbol)
## - Query text
## - Selected result index
## - Whether results are visible
##
## Usage:
##   let vm = createSearchVM(store)
##   echo vm.mode.val              # smCommand
##   vm.setMode(smFile)
##   vm.setQuery("main.nim")
##   echo vm.resultsVisible.val    # true

import std/options

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/replay_data_store

type
  SearchMode* = enum
    ## The available search modes for the command palette.
    smCommand     ## Command search (Ctrl+Shift+P style)
    smFile        ## File search (Ctrl+P style)
    smFindInFiles ## Full-text search across all files
    smFindSymbol  ## Symbol search

  SearchVM* = ref object of ViewModel
    ## Reactive state for the Search / Command palette panel.
    ##
    ## Mutable signals:
    ##   mode            — which search mode is active
    ##   query           — the current search query text
    ##   selectedResult  — index of the selected result, or none
    ##   resultsVisible  — whether the results list is displayed
    ##
    ## The store reference is kept for potential future backend queries.
    store*: ReplayDataStore

    # -- Mutable state --
    mode*: Signal[SearchMode]
    query*: Signal[string]
    selectedResult*: Signal[Option[int]]
    resultsVisible*: Signal[bool]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setMode*(vm: SearchVM; mode: SearchMode) =
  ## Switch to a different search mode. Clears the query and
  ## selected result to start fresh in the new mode.
  vm.mode.val = mode
  vm.query.val = ""
  vm.selectedResult.val = none(int)

proc setQuery*(vm: SearchVM; query: string) =
  ## Update the search query text. Shows results if the query
  ## is non-empty, hides them if empty.
  vm.query.val = query
  if query.len > 0:
    vm.resultsVisible.val = true
  else:
    vm.resultsVisible.val = false
  # Reset selection when the query changes.
  vm.selectedResult.val = none(int)

proc selectResult*(vm: SearchVM; index: Option[int]) =
  ## Set the selected result index. Pass `none(int)` to clear.
  vm.selectedResult.val = index

proc toggleResults*(vm: SearchVM) =
  ## Toggle visibility of the results list.
  vm.resultsVisible.val = not vm.resultsVisible.val

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createSearchVM*(store: ReplayDataStore): SearchVM =
  ## Create a SearchVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up mutable signals with sensible defaults.
  withViewModel proc(dispose: proc()): SearchVM =
    SearchVM(
      store: store,
      mode: createSignal(smCommand),
      query: createSignal(""),
      selectedResult: createSignal(none(int)),
      resultsVisible: createSignal(false),
      disposeProc: dispose,
    )
