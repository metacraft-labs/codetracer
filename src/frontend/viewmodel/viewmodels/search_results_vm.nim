## viewmodels/search_results_vm.nim
##
## SearchResultsVM — ViewModel for the Search Results panel.
##
## Holds reactive state for:
## - The currently active search query string (``query``).
## - The list of ``SearchResultLine`` rows the backend has returned for
##   the active query.
## - The "active" flag — set to true once a search has run, false on
##   ``clearResults``.  Mirrors the legacy ``SearchResultsComponent.active``
##   flag (used by CSS to flip the panel between
##   ``search-results-active`` and ``search-results-non-active``).
## - The find/filter sub-query the user types into the ``Filter
##   results...`` input (``filter`` signal).
##
## Derives:
## - ``visibleResults``: the ``results`` list filtered by the active
##   ``filter`` value (case-insensitive substring match against any of
##   ``text`` / ``path`` / ``$line``).  The view consumes this so the
##   empty-state overlay renders whenever the filter wipes every row
##   out.
## - ``resultCount``: convenience alias for ``results.val.len`` —
##   feeds the header count badge.
##
## The VM has no auto-load effect: the legacy ``SearchService`` already
## pushes results into ``data.services.search.results[SearchFixed]``
## via the ``search-results-updated`` IPC; the search_results module
## mirrors that payload into ``SearchResultsVM`` via the ``setResults``
## / ``appendResults`` actions.  The contract mirrors ``ErrorsVM``
## (1.34): events arrive through the legacy mediator subscriptions; the
## VM is a platform-neutral facade so headless tests under
## ``src/tests/gui/tests/views/isonim_views_test.nim`` can drive the
## full reactive flow without needing the IPC backend.
##
## Usage::
##
##   let vm = createSearchResultsVM(store)
##   vm.setQuery("foo")
##   vm.setResults(@[
##     SearchResultLine(text: "let foo = 1", path: "main.nim", line: 1),
##     SearchResultLine(text: "echo foo",   path: "main.nim", line: 2)])
##   echo vm.resultCount.val          # 2
##   echo vm.active.val               # true
##   vm.setFilter("echo")
##   echo vm.visibleResults.val.len   # 1
##
## When the user clicks a result row the view calls
## ``vm.jumpToResult(result)`` which dispatches a ``ct/jump-location``
## request via the backend.  In production the legacy
## ``SearchResultsComponent`` rendered an inline
## ``data.openLocation(res.path, res.line)`` closure; routing the
## click through the VM keeps the signal flow self-contained for
## headless tests.

import std/[json, strutils]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

type
  SearchResultsVM* = ref object of ViewModel
    ## Reactive state for the Search Results panel.
    ##
    ## Mutable signals:
    ##   query         — the active workspace search query string.
    ##   results       — every match row produced by the search pipeline.
    ##   active        — true once a search has run (drives the legacy
    ##                   ``search-results-active`` CSS modifier).
    ##   filter        — find-results sub-query typed by the user.
    ##
    ## Derived memos:
    ##   visibleResults — ``results`` filtered by ``filter``.
    ##   resultCount    — convenience: ``results.val.len``.
    store*: ReplayDataStore

    # -- Mutable state --
    query*: Signal[string]
    results*: Signal[seq[SearchResultLine]]
    active*: Signal[bool]
    filter*: Signal[string]

    # -- Derived state --
    visibleResults*: Memo[seq[SearchResultLine]]
    resultCount*: Memo[int]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setQuery*(vm: SearchResultsVM; query: string) =
  ## Set the active workspace search query.  Used by the legacy
  ## ``SearchService.run`` path when a new search is dispatched.
  vm.query.val = query

proc setResults*(vm: SearchResultsVM; results: seq[SearchResultLine]) =
  ## Replace the result list wholesale.  Used by the legacy bulk-replay
  ## path (``syncLegacySearchResultsIntoVM``).  Per-row updates use
  ## ``appendResults`` instead.  Setting any non-empty list also flips
  ## ``active`` to true so the panel becomes visible.
  vm.results.val = results
  if results.len > 0:
    vm.active.val = true

proc appendResults*(vm: SearchResultsVM; results: seq[SearchResultLine]) =
  ## Append a batch of result rows.  Called by the legacy ``onSearchResultsUpdated``
  ## handler whenever the IPC layer streams in another set of matches.
  ## Like ``setResults``, flips ``active`` to true so the first batch
  ## activates the panel.
  if results.len == 0:
    return
  var entries = vm.results.val
  for r in results:
    entries.add(r)
  vm.results.val = entries
  vm.active.val = true

proc clearResults*(vm: SearchResultsVM) =
  ## Reset the result list and the active flag.  The view re-displays
  ## the ``"Run a search to see results here."`` empty-state overlay.
  vm.results.val = @[]
  vm.active.val = false

proc setActive*(vm: SearchResultsVM; on: bool) =
  ## Set the panel-active flag explicitly.  Mirrors direct mutations
  ## to the legacy ``SearchResultsComponent.active`` field (the
  ## existing fixed-search input toggles it on focus / blur).
  vm.active.val = on

proc setFilter*(vm: SearchResultsVM; filter: string) =
  ## Set the active find-results filter string.  Memoed signals
  ## (``visibleResults``) recompute automatically.
  vm.filter.val = filter

proc jumpToResult*(vm: SearchResultsVM; res: SearchResultLine) =
  ## Dispatch a jump-location request for the given result row.  The
  ## legacy view called ``data.openLocation(res.path, res.line)``
  ## directly; routing this via the backend keeps the signal flow
  ## self-contained for headless tests.  In production the legacy
  ## ``SearchResultsComponent`` is no longer rendered, so the VM is the
  ## single source for jump dispatch — the ``ct/jump-location`` request
  ## is the same one ``ErrorsVM.jumpToProblem`` issues.
  let args = %*{
    "path": res.path,
    "line": res.line,
  }
  discard vm.store.backend.send("ct/jump-location", args)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc filterRows(rows: seq[SearchResultLine];
                filter: string): seq[SearchResultLine] =
  ## Return only the rows that match the active ``filter`` (case-insensitive
  ## substring against ``text`` / ``path`` / ``$line``).  An empty
  ## filter is treated as "match everything" so the panel shows the
  ## full result list while the user is not narrowing further.
  if filter.len == 0:
    return rows
  let needle = filter.toLowerAscii()
  for r in rows:
    if needle in r.text.toLowerAscii() or
       needle in r.path.toLowerAscii() or
       needle in $r.line:
      result.add(r)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createSearchResultsVM*(store: ReplayDataStore): SearchResultsVM =
  ## Create a SearchResultsVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults (empty query, empty
  ##    result list, ``active`` off, empty filter).
  ## 2. Derived memos for ``visibleResults`` and ``resultCount``.
  withViewModel proc(dispose: proc()): SearchResultsVM =
    let query = createSignal("")
    let results = createSignal(newSeq[SearchResultLine]())
    let active = createSignal(false)
    let filter = createSignal("")

    let visibleResults = createMemo[seq[SearchResultLine]] proc(): seq[SearchResultLine] =
      filterRows(results.val, filter.val)

    let resultCount = createMemo[int] proc(): int =
      results.val.len

    SearchResultsVM(
      store: store,
      query: query,
      results: results,
      active: active,
      filter: filter,
      visibleResults: visibleResults,
      resultCount: resultCount,
      disposeProc: dispose,
    )
