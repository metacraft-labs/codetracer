## Search Results panel — workspace-wide text-search results list.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_search_results_view.nim``) that mounts
## directly into the GoldenLayout container.  The legacy
## ``SearchResultsComponent`` retains its identity so existing wiring
## (auto-hide auto-reveal, search-service routing) keeps working; the
## panel data is sourced from ``data.services.search.results[SearchFixed]``
## and mirrored into a ``SearchResultsVM`` whose signals drive the
## IsoNim view.
##
## This is the last panel to come off the ``vnodeToDom`` Karax bridge:
## with build (1.33), errors (1.34), and search_results (this migration)
## all on IsoNim, the entire ``vnodeToDom`` trio of "lowest-friction"
## panels is now migrated.
## ---------------------------------------------------------------------------

import ui_imports, auto_hide, ../[types, communication]

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import SearchResultLine
from ../viewmodel/viewmodels/search_results_vm import
  SearchResultsVM, createSearchResultsVM,
  setQuery, setResults, appendResults, clearResults,
  setActive, setFilter, jumpToResult
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_search_results_view import
  mountIsoNimSearchResults

# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls.  Mirrors
# the pattern used by the build, errors, terminal-output and event-log
# migrations.
var searchResultsVMInstance*: SearchResultsVM
var searchResultsVMStore: ReplayDataStore
var searchResultsComponentRef: SearchResultsComponent
var isoNimSearchResultsMounted*: bool = false

proc tryMountIsoNimSearchResultsPanel*()

# ---------------------------------------------------------------------------
# fixedSearchView — kept as the legacy Karax renderer for the floating
# fixed-search overlay.  This view is mounted at the global
# ``#fixed-search`` element, NOT inside the search-results panel, so it
# stays on Karax for now (separate migration; the floating overlay is
# not in section 5.4's vnodeToDom trio).
# ---------------------------------------------------------------------------

proc fixedSearchView*: VNode =
  let active = if data.services.search.active[SearchFixed]: cstring"" else: cstring"fixed-search-non-active"
  # TODO active
  buildHtml(
    tdiv(
      id = "fixed-search",
      class = active
    )
  ):
    tdiv(class = "fixed-search-query-field"):
      input(
        `type` = "text",
        id = "fixed-search-query",
        name = "search-query",
        class = "mousetrap",
        onkeydown = proc(e: KeyboardEvent, v: VNode) =
          if e.keyCode == ENTER_KEY_CODE and e.isTrusted:
            let value = jq("#fixed-search-query").toJs.value.to(cstring)
            let includeValue = jq("#fixed-search-include").toJs.value.to(cstring)
            let excludeValue = jq("#fixed-search-exclude").toJs.value.to(cstring)
            data.services.search.active[SearchFixed] = false
            discard data.services.search.run(value, includeValue, excludeValue)
          else:
            data.services.search.active[SearchFixed] = true
      )
    tdiv(class = "fixed-search-include-field " & active):
      input(
        `type` = "text",
        id = "fixed-search-include",
        placeholder = "include"
      )
    tdiv(
      class = "fixed-search-exclude-field " & active
    ):
      input(
        `type` = "text",
        id = "fixed-search-exclude",
        placeholder = "exclude"
      )

proc parseRawLocation*(location: cstring): (cstring, int) =
  let tokens = location.split(cstring":")

  if tokens.len == 2:
    (tokens[0], parseJsInt(tokens[1]))
  else:
    raise newException(ValueError, "expected <path>:<line>")

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initSearchResultsVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel ``SearchResultsVM`` using an externally-provided
  ## ``ReplayDataStore`` (typically the shared store from
  ## ``SessionViewModel``).  If a stub-backed instance already exists
  ## (created by ``initSearchResultsVM`` before the real backend was
  ## available) it is replaced so the panel uses the real backend.
  if searchResultsVMInstance != nil:
    clog "SearchResultsVM: replacing existing instance with shared-store version"
    isoNimSearchResultsMounted = false
  searchResultsVMStore = store
  searchResultsVMInstance = createSearchResultsVM(store)
  clog "SearchResultsVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimSearchResultsPanel()

proc initSearchResultsVM*() =
  ## Lazily create the parallel ``SearchResultsVM`` backed by a stub
  ## ``BackendService``.  Fallback when no shared store has been
  ## provided via ``initSearchResultsVMWithStore``.
  if searchResultsVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  searchResultsVMStore = createReplayDataStore(stubBackend)
  searchResultsVMInstance = createSearchResultsVM(searchResultsVMStore)
  clog "SearchResultsVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimSearchResultsPanel()

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  Mirrors the
  ## helper in ``ui/build.nim`` / ``ui/errors.nim``: E2E tests can land
  ## a null cstring in the legacy record, and naive ``$`` would throw
  ## inside ``cstrToNimstr``.
  if s.isNil:
    ""
  else:
    $s

proc resultToVMRow(r: SearchResult): SearchResultLine =
  ## Convert a legacy Karax ``SearchResult`` into the platform-neutral
  ## row shape consumed by the IsoNim view.  Keeps the ViewModel layer
  ## free of JS-only types.
  SearchResultLine(
    text: safeStr(r.text),
    path: safeStr(r.path),
    line: r.line)

proc syncLegacySearchResultsIntoVM*(self: SearchResultsComponent) =
  ## Mirror the legacy ``self.service.results[SearchFixed]`` list into
  ## the IsoNim ``SearchResultsVM``.  Used by the layout when the panel
  ## container becomes visible (or is rebuilt) so the panel reflects
  ## every result already accumulated by the search service.  Per-row
  ## updates go through ``syncSearchResultsAppendMatch`` directly;
  ## this proc covers the bulk-replace scenario the auto-hide /
  ## ``__ctRenderPanel`` paths use.
  if searchResultsVMInstance.isNil or self.isNil:
    return
  let service = self.service
  if service.isNil:
    searchResultsVMInstance.setResults(@[])
    return

  var rows: seq[SearchResultLine] = @[]
  for r in service.results[SearchFixed]:
    rows.add(resultToVMRow(r))

  # Use ``setResults`` for the wholesale replace path so re-running
  # ``__ctRenderPanel`` after E2E tests inject results does not double
  # up the rows.  ``setResults`` flips ``active`` to true when the
  # list is non-empty so the panel becomes visible.
  searchResultsVMInstance.setResults(rows)

  # Mirror the active-flag and the query string from the legacy
  # records so the panel root's ``search-results-active`` modifier
  # tracks the legacy state.
  searchResultsVMInstance.setActive(self.active or
    (not service.query.isNil and service.query.query.len > 0))
  if not service.query.isNil:
    searchResultsVMInstance.setQuery(safeStr(service.query.query))

proc syncSearchResultsAppendMatch*(matchRow: SearchResultLine) =
  ## Push a single search-result row into the ``SearchResultsVM``.
  ## Called from the ``onSearchResultsUpdated`` path so streamed
  ## matches flow through the VM without coupling the search service
  ## to the VM's type.  A no-op when the VM has not been bootstrapped
  ## yet (e.g. during early register-time wiring before
  ## ``configureMiddleware`` runs).
  if searchResultsVMInstance.isNil:
    return
  searchResultsVMInstance.appendResults(@[matchRow])

proc syncSearchResultsAppendBatch*(matches: seq[SearchResultLine]) =
  ## Bulk variant of ``syncSearchResultsAppendMatch`` — append a batch
  ## of result rows in a single ``problems.val`` write so the reactive
  ## body rebuilds only once.  No-op when the VM is not initialised.
  if searchResultsVMInstance.isNil or matches.len == 0:
    return
  searchResultsVMInstance.appendResults(matches)

proc syncSearchResultsClear*() =
  ## Reset the SearchResultsVM result list and active flag.  Called
  ## when a new query begins so the previous run's results don't
  ## bleed into the next.
  if searchResultsVMInstance.isNil:
    return
  searchResultsVMInstance.clearResults()

proc syncSearchResultsSetQuery*(query: string) =
  ## Update the active query string on the VM.  Called from the
  ## ``onSearchResultsUpdated`` IPC handler so the panel header text
  ## (``"<N> results for \"<query>\""``) tracks the live search.
  if searchResultsVMInstance.isNil:
    return
  searchResultsVMInstance.setQuery(query)

proc tryMountIsoNimSearchResultsPanel*() =
  ## Mount the IsoNim search results view into the GoldenLayout-managed
  ## (or standalone auto-hide) container.  The container's id is
  ## ``searchResultsComponent-{id}``; the panel is a singleton (id
  ## always 0) but we still resolve through the registered component's
  ## id field for symmetry with the other IsoNim mounts.
  ##
  ## Safe to call multiple times — mounts only once.  Retries until the
  ## DOM container appears (capped at 200 attempts, ~2 s) since
  ## GoldenLayout creates the host slightly after the layout state
  ## changes.
  if isoNimSearchResultsMounted or searchResultsVMInstance.isNil:
    return
  if searchResultsComponentRef.isNil:
    return

  let key = cstring("searchResultsComponent-" & $searchResultsComponentRef.id)
  var retryCount = 0
  proc doMount() =
    if isoNimSearchResultsMounted:
      return
    retryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if retryCount > 200:
        cerror "tryMountIsoNimSearchResultsPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    # Replace any prior content (the layout bridge may have planted a
    # stub element before the IsoNim mount fires).
    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimSearchResultsMounted = true
    try:
      mountIsoNimSearchResults(container, searchResultsVMInstance)
    except:
      cerror "tryMountIsoNimSearchResultsPanel: mount EXCEPTION: " & getCurrentExceptionMsg()

    # Re-sync any data the legacy service already carries so the
    # freshly-mounted view reflects the latest result list.
    if not searchResultsComponentRef.isNil:
      syncLegacySearchResultsIntoVM(searchResultsComponentRef)

  doMount()

proc autoRevealSearchResultsPanel*() =
  ## If the search results panel is pinned to an auto-hide edge strip,
  ## show the overlay so the user can see results. No-op if the panel
  ## is not in auto-hide state.
  if autoHideState.isNil:
    return
  let panel = autoHideState.findPanelByContent(Content.SearchResults)
  if not panel.isNil:
    showOverlay(panel)

# SearchResultsComponent.render() removed: IsoNim is the primary renderer.
# Generic callers are expected to use direct IsoNim mount paths; all real
# DOM construction happens in
# ``viewmodel/views/isonim_search_results_view.nim``.

method register*(self: SearchResultsComponent, api: MediatorWithSubscribers) =
  ## Register the SearchResultsComponent with the mediator.  Bring up the
  ## IsoNim SearchResultsVM lazily so the mount procedure can find it;
  ## the shared-store version is installed by ``configureMiddleware`` if
  ## the ViewModel layer is enabled.
  self.api = api
  initSearchResultsVM()
  if searchResultsComponentRef.isNil:
    searchResultsComponentRef = self
    tryMountIsoNimSearchResultsPanel()

# ---------------------------------------------------------------------------
# Wire the ``search_service`` forward hooks.  ``search_service`` cannot
# import this module directly (cycle: ``ui_imports`` → ``renderer`` →
# ``search_service`` → ``search_results`` → ``ui_imports``), so it
# declares ``syncSearchResults*Hook`` proc variables and we install the
# concrete implementations at module-init time here.  The hooks are
# called from ``onSearchResultsUpdated`` in ``search_service.nim``.
# ---------------------------------------------------------------------------

syncSearchResultsAppendBatchHook = syncSearchResultsAppendBatch
syncSearchResultsSetQueryHook = syncSearchResultsSetQuery
syncSearchResultsClearHook = syncSearchResultsClear
