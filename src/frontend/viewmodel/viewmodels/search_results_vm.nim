## viewmodels/search_results_vm.nim
##
## SearchResultsVM — ViewModel for the Find in Files panel.
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
## - ``loading`` — true while the search is in flight; cleared on the
##   first batch of results or when a new search clears the list.
## - ``recentSearches`` — list of ``RecentSearch`` entries (query + hit
##   count) shown in the empty state before a search is run.
##
## Derives:
## - ``visibleResults``: the ``results`` list filtered by the active
##   ``filter`` value (case-insensitive substring match against any of
##   ``text`` / ``path`` / ``$line``).  The view consumes this so the
##   empty-state overlay renders whenever the filter wipes every row
##   out.
## - ``resultCount``: convenience alias for ``results.val.len`` —
##   feeds the header count badge.
## - ``fileCount``: number of distinct file paths in ``visibleResults``.
##
## The VM also carries an ``onSearch`` callback that the wiring layer
## installs (``search_results.nim``) so the view can trigger a search
## without importing the search service directly.

import std/[json, strutils, tables]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

type
  RecentSearch* = object
    ## A past search kept in the "recent searches" empty-state list.
    query*: string
    hitCount*: int

  SearchResultsVM* = ref object of ViewModel
    ## Reactive state for the Find in Files panel.
    ##
    ## Mutable signals:
    ##   query           — the active workspace search query string.
    ##   results         — every match row produced by the search pipeline.
    ##   active          — true once a search has run (drives the legacy
    ##                     ``search-results-active`` CSS modifier).
    ##   filter          — find-results sub-query typed by the user.
    ##   loading         — true while the search pipeline is running.
    ##   recentSearches  — past searches shown in the empty state.
    ##
    ## Derived memos:
    ##   visibleResults — ``results`` filtered by ``filter``.
    ##   resultCount    — convenience: ``results.val.len``.
    ##   fileCount      — distinct file paths in ``visibleResults``.
    ##
    ## Callback:
    ##   onSearch       — installed by the wiring layer; called when the
    ##                    user submits a query from the search input.
    store*: ReplayDataStore

    # -- Mutable state --
    query*: Signal[string]
    results*: Signal[seq[SearchResultLine]]
    active*: Signal[bool]
    filter*: Signal[string]
    loading*: Signal[bool]
    recentSearches*: Signal[seq[RecentSearch]]

    # -- Derived state --
    visibleResults*: Memo[seq[SearchResultLine]]
    resultCount*: Memo[int]
    fileCount*: Memo[int]

    # -- Callback installed by wiring layer --
    onSearch*: proc(query: string)

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
    vm.loading.val = false

proc appendResults*(vm: SearchResultsVM; results: seq[SearchResultLine]) =
  ## Append a batch of result rows.  Called by the legacy ``onSearchResultsUpdated``
  ## handler whenever the IPC layer streams in another set of matches.
  ## Like ``setResults``, flips ``active`` to true so the first batch
  ## activates the panel and also clears the loading spinner.
  if results.len == 0:
    return
  var entries = vm.results.val
  for r in results:
    entries.add(r)
  vm.results.val = entries
  vm.active.val = true
  vm.loading.val = false

proc clearResults*(vm: SearchResultsVM) =
  ## Reset the result list and the active flag.  The view re-displays
  ## the empty-state overlay (recent searches list).
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

proc setLoading*(vm: SearchResultsVM; on: bool) =
  ## Show or hide the loading shimmer.  Set to ``true`` when a new
  ## search is submitted; cleared automatically by ``appendResults`` /
  ## ``setResults`` on the first data batch.
  vm.loading.val = on

proc addRecentSearch*(vm: SearchResultsVM; query: string; hitCount: int) =
  ## Prepend a completed search to the recent-searches list.  Keeps at
  ## most 10 entries; duplicate queries are promoted to the front.
  var entries = vm.recentSearches.val
  # Remove any existing entry for the same query so we can re-insert at
  # the front with the updated hit count.
  var filtered: seq[RecentSearch]
  for e in entries:
    if e.query != query:
      filtered.add(e)
  filtered.insert(RecentSearch(query: query, hitCount: hitCount), 0)
  if filtered.len > 10:
    filtered.setLen(10)
  vm.recentSearches.val = filtered

proc currentQuery*(vm: SearchResultsVM): string =
  ## Return the current query string.  Convenience accessor used by the
  ## wiring layer to read the query without importing ``Signal``.
  vm.query.val

proc currentResultCount*(vm: SearchResultsVM): int =
  ## Return the current result count.  Convenience accessor used by the
  ## wiring layer to read the count without importing ``Memo``.
  vm.resultCount.val

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

proc countDistinctPaths(rows: seq[SearchResultLine]): int =
  ## Count the number of unique ``path`` values in ``rows``.
  var seen: Table[string, bool]
  for r in rows:
    let k = if r.path.len == 0: "<unknown>" else: r.path
    seen[k] = true
  seen.len

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
  ##    result list, ``active`` off, empty filter, ``loading`` off).
  ## 2. Derived memos for ``visibleResults``, ``resultCount``, and
  ##    ``fileCount``.
  withViewModel proc(dispose: proc()): SearchResultsVM =
    let query = createSignal("")
    let results = createSignal(newSeq[SearchResultLine]())
    let active = createSignal(false)
    let filter = createSignal("")
    let loading = createSignal(false)
    let recentSearches = createSignal(newSeq[RecentSearch]())

    let visibleResults = createMemo[seq[SearchResultLine]] proc(): seq[SearchResultLine] =
      filterRows(results.val, filter.val)

    let resultCount = createMemo[int] proc(): int =
      results.val.len

    let fileCount = createMemo[int] proc(): int =
      countDistinctPaths(visibleResults.val)

    SearchResultsVM(
      store: store,
      query: query,
      results: results,
      active: active,
      filter: filter,
      loading: loading,
      recentSearches: recentSearches,
      visibleResults: visibleResults,
      resultCount: resultCount,
      fileCount: fileCount,
      disposeProc: dispose,
    )
