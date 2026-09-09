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
##   field, which the wiring layer still writes; no CSS reads it any
##   more (see the note on the retired filter below).
## - ``loading`` — true while the search is in flight; cleared on the
##   first batch of results or when a new search clears the list.
## - ``recentSearches`` — list of ``RecentSearch`` entries (query + hit
##   count) shown in the empty state before a search is run.
##
## Derives:
## - ``resultCount``: convenience alias for ``results.val.len``.
## - ``fileCount``: number of distinct file paths in ``results``.
##
## THERE IS NO CLIENT-SIDE RESULT FILTER, and there never was one that
## worked.  This VM used to carry a ``filter`` signal, a ``setFilter``
## action and a ``visibleResults`` memo for a ``Filter results...``
## input whose only handler, from the initial open-source release
## through the Karax era, logged ``TODO find`` and narrowed nothing.
## The IsoNim migration carried the input into the new view still
## unwired, and the Find in Files redesign dropped the input with the
## rest of the old DOM.  The machinery was retired with it rather than
## given a first driver here: what the panel needs to search a
## workspace is a new ripgrep query, which its own input already
## submits.  The same redesign retired the ``search-results-active`` /
## ``search-results-non-active`` root modifier (``display: flex`` /
## ``display: none``) — the panel now owns the query input, so hiding
## it before a search would hide the only way to start one.
##
## The VM also carries an ``onSearch`` callback that the wiring layer
## installs (``search_results.nim``) so the view can trigger a search
## without importing the search service directly.

import std/[json, tables]

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
    ##   active          — true once a search has run.
    ##   loading         — true while the search pipeline is running.
    ##   recentSearches  — past searches shown in the empty state.
    ##
    ## Derived memos:
    ##   resultCount    — convenience: ``results.val.len``.
    ##   fileCount      — distinct file paths in ``results``.
    ##
    ## Callback:
    ##   onSearch       — installed by the wiring layer; called when the
    ##                    user submits a query from the search input.
    store*: ReplayDataStore

    # -- Mutable state --
    query*: Signal[string]
    results*: Signal[seq[SearchResultLine]]
    active*: Signal[bool]
    loading*: Signal[bool]
    recentSearches*: Signal[seq[RecentSearch]]

    # -- Derived state --
    resultCount*: Memo[int]
    fileCount*: Memo[int]

    # -- Callbacks installed by wiring layer --
    onSearch*: proc(query: string)
    onJumpToResult*: proc(path: string, line: int)

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
  ## An empty batch still clears the loading shimmer so the empty-state
  ## is shown when ripgrep produces no matches.
  vm.loading.val = false
  if results.len == 0:
    return
  var entries = vm.results.val
  for r in results:
    entries.add(r)
  vm.results.val = entries
  vm.active.val = true

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
  ## Open the source file at the matched line.  Delegates to the
  ## ``onJumpToResult`` callback installed by the wiring layer
  ## (``search_results.nim``) which calls ``data.openLocation`` — the
  ## same path the editor uses for file navigation.
  ##
  ## There is deliberately **no backend fallback**. This used to dispatch
  ## ``ct/jump-location`` when no callback was wired, which
  ## `backend/dap_dialect.md` §7 records as reaching no engine handler at all;
  ## the request went nowhere and the click did nothing, while the view tests
  ## asserting the dispatch stayed green. Opening a file is the host's job,
  ## and a VM without a host does not have one to do.
  if vm.onJumpToResult.isNil:
    return
  vm.onJumpToResult(res.path, res.line)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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
  ##    result list, ``active`` off, ``loading`` off).
  ## 2. Derived memos for ``resultCount`` and ``fileCount``.
  withViewModel proc(dispose: proc()): SearchResultsVM =
    let query = createSignal("")
    let results = createSignal(newSeq[SearchResultLine]())
    let active = createSignal(false)
    let loading = createSignal(false)
    let recentSearches = createSignal(newSeq[RecentSearch]())

    let resultCount = createMemo[int] proc(): int =
      results.val.len

    let fileCount = createMemo[int] proc(): int =
      countDistinctPaths(results.val)

    SearchResultsVM(
      store: store,
      query: query,
      results: results,
      active: active,
      loading: loading,
      recentSearches: recentSearches,
      resultCount: resultCount,
      fileCount: fileCount,
      disposeProc: dispose,
    )
