## Search Results panel — workspace-wide text-search results list.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The pane is the IsoNim view
## (``viewmodel/views/isonim_search_results_view.nim``) over the shared
## ``SearchResultsVM`` — the model the terminal and GPUI draw too — mounted
## into the GoldenLayout container. The ``SearchResultsComponent`` keeps its
## identity for the layout's mount and auto-hide wiring. A search runs in the
## main process through the one shared runner
## (``viewmodel/host/find_in_files``); its batches arrive through
## ``search_service`` and go straight into the ViewModel.
## ---------------------------------------------------------------------------

import ui_imports, auto_hide, ../[types, communication]

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import SearchResultLine
from ../viewmodel/viewmodels/search_results_vm import
  SearchResultsVM, createSearchResultsVM, search, acceptBatch, stepResult,
  openResult, toggleOption, searchOptionOf,
  TextMatchOptions
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
proc requestFixedSearchRender*()
proc installSearchVMCallbacks*(vm: SearchResultsVM)

# ---------------------------------------------------------------------------
# Fixed-search overlay — direct DOM renderer.
#
# The global ``#fixed-search`` host is static in ``index.html`` and lives
# outside the Search Results GoldenLayout panel.  Keep it direct-DOM instead
# of preserving a Karax ``setRenderer`` island for an input-only overlay.
# ---------------------------------------------------------------------------

when defined(js):
  proc clearChildren(node: kdom.Element) =
    {.emit: """
      while (`node`.firstChild) {
        `node`.removeChild(`node`.firstChild);
      }
    """.}

  proc inputValue(id: cstring): cstring =
    let input = kdom.document.getElementById(id)
    if input.isNil:
      return cstring""
    input.toJs.value.to(cstring)

  proc makeFixedSearchInput(
      id: cstring;
      placeholder: cstring = cstring"";
      className: cstring = cstring""): kdom.Element =
    result = kdom.document.createElement("input")
    result.setAttribute(cstring"type", cstring"text")
    result.setAttribute(cstring"id", id)
    if placeholder.len > 0:
      result.setAttribute(cstring"placeholder", placeholder)
    if className.len > 0:
      result.setAttribute(cstring"class", className)

  proc updateFixedSearchFieldClasses(inactiveClass: cstring) =
    {.emit: """
      const includeField = document.querySelector(
        '#fixed-search .fixed-search-include-field');
      const excludeField = document.querySelector(
        '#fixed-search .fixed-search-exclude-field');
      if (includeField) {
        includeField.setAttribute(
          'class',
          'fixed-search-include-field ' + `inactiveClass`);
      }
      if (excludeField) {
        excludeField.setAttribute(
          'class',
          'fixed-search-exclude-field ' + `inactiveClass`);
      }
    """.}

  proc requestFixedSearchRender*() =
    ## Refresh the global fixed-search overlay without Karax.
    ##
    ## Preserves the old ``fixedSearchView`` ids/classes and Enter-to-search
    ## behavior while allowing ``#fixed-search`` to remain a static DOM host.
    let container = kdom.document.getElementById(cstring"fixed-search")
    if container.isNil:
      return

    let inactiveClass =
      if data.services.search.active[SearchFixed]:
        cstring""
      else:
        cstring"fixed-search-non-active"
    container.setAttribute(cstring"class", inactiveClass)
    updateFixedSearchFieldClasses(inactiveClass)
    if not kdom.document.getElementById(cstring"fixed-search-query").isNil:
      return

    container.clearChildren()

    let queryField = kdom.document.createElement("div")
    queryField.setAttribute(cstring"class", cstring"fixed-search-query-field")
    let queryInput = makeFixedSearchInput(
      cstring"fixed-search-query",
      className = cstring"mousetrap")
    queryInput.setAttribute(cstring"name", cstring"search-query")
    queryInput.addEventListener(cstring"keydown", proc(ev: Event) =
      let event = cast[KeyboardEvent](ev)
      if event.keyCode == ENTER_KEY_CODE and event.isTrusted:
        let value = inputValue(cstring"fixed-search-query")
        let includeValue = inputValue(cstring"fixed-search-include")
        let excludeValue = inputValue(cstring"fixed-search-exclude")
        data.services.search.active[SearchFixed] = false
        discard data.services.search.run(value, includeValue, excludeValue)
      else:
        data.services.search.active[SearchFixed] = true)
    queryField.appendChild(queryInput)

    let includeField = kdom.document.createElement("div")
    includeField.setAttribute(
      cstring"class",
      cstring("fixed-search-include-field " & $inactiveClass))
    includeField.appendChild(makeFixedSearchInput(
      cstring"fixed-search-include",
      placeholder = cstring"include"))

    let excludeField = kdom.document.createElement("div")
    excludeField.setAttribute(
      cstring"class",
      cstring("fixed-search-exclude-field " & $inactiveClass))
    excludeField.appendChild(makeFixedSearchInput(
      cstring"fixed-search-exclude",
      placeholder = cstring"exclude"))

    container.appendChild(queryField)
    container.appendChild(includeField)
    container.appendChild(excludeField)
else:
  proc requestFixedSearchRender*() =
    discard

proc installSearchVMCallbacks*(vm: SearchResultsVM) =
  ## Wire the Find in Files pane's ViewModel to this window:
  ##
  ## * ``onSearch`` — show the pane (``openLayoutTab``: revealed when it is
  ##   docked, focused when placed, opened when not — Find-And-Incremental-
  ##   Search.md §5.1) and hand the run to the main process, where THE shared
  ##   runner executes it;
  ## * ``onJumpToResult`` — open the row's file at its line through the same
  ##   ``data.openLocation`` path the editor uses. The recording position
  ##   does not move.
  vm.onSearch = proc(runId: int; query: string; options: TextMatchOptions) =
    data.openLayoutTab(Content.SearchResults)
    data.services.search.requestFindInFiles(runId, query,
                                            options.caseSensitive,
                                            options.wholeWord, options.regex)

  vm.onJumpToResult = proc(row: SearchResultLine) =
    discard data.openLocation(cstring(row.path), row.line)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initSearchResultsVMFromSession*(vm: SearchResultsVM) =
  ## Hand the pane the session's `SearchResultsVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ##
  ## If a stub-backed instance already exists (created before the session
  ## was available), it is replaced so the panel uses the real backend.
  let store = vm.store
  if searchResultsVMInstance != nil:
    clog "SearchResultsVM: replacing existing instance with shared-store version"
    isoNimSearchResultsMounted = false
  searchResultsVMStore = store
  searchResultsVMInstance = vm
  installSearchVMCallbacks(searchResultsVMInstance)
  clog "SearchResultsVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimSearchResultsPanel()

proc initSearchResultsVM*() =
  ## Lazily create the parallel ``SearchResultsVM`` backed by a stub
  ## ``BackendService``.  Fallback when no shared store has been
  ## provided via ``initSearchResultsVMFromSession``.
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
  installSearchVMCallbacks(searchResultsVMInstance)
  clog "SearchResultsVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimSearchResultsPanel()

proc rowOf(r: SearchResultRow): SearchResultLine =
  ## A main-process row as the pane's value.
  SearchResultLine(text: (if r.text.isNil: "" else: $r.text),
                   path: (if r.path.isNil: "" else: $r.path),
                   line: r.line, matchStart: r.matchStart,
                   matchLength: r.matchLength)

proc acceptFindInFilesBatch(batch: SearchResultsBatch) =
  ## The main process's batch, into the pane — dropped by the ViewModel
  ## unless it belongs to the latest search.
  if searchResultsVMInstance.isNil:
    return
  var rows: seq[SearchResultLine] = @[]
  for r in batch.rows:
    rows.add rowOf(r)
  discard searchResultsVMInstance.acceptBatch(
    batch.id, rows, batch.done,
    (if batch.note.isNil: "" else: $batch.note))

proc stepSearchResult*(delta: int) =
  ## `search.next-result` / `search.previous-result` (`F4` / `Shift+F4`):
  ## the next / previous result, wrapping, opened at its line.
  if searchResultsVMInstance.isNil:
    return
  let vm = searchResultsVMInstance
  let i = vm.stepResult(delta)
  if i >= 0:
    discard vm.openResult(i)

proc toggleSearchOption*(operation: string) =
  ## `search.toggle-case` / `-whole-word` / `-regex` (`Alt+C` / `Alt+W` /
  ## `Alt+R` in the pane's field): the toggle flips, and a search that ran
  ## runs again with it.
  if searchResultsVMInstance.isNil:
    return
  let (known, which) = searchOptionOf(operation)
  if known:
    searchResultsVMInstance.toggleOption(which)

proc startFindInFiles(query: string) =
  ## The omnibar's ``:grep``: the pane's own search.
  if searchResultsVMInstance.isNil:
    initSearchResultsVM()
  searchResultsVMInstance.search(query)

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
  if searchResultsVMInstance.isNil:
    return
  if searchResultsComponentRef.isNil:
    return

  let key = cstring("searchResultsComponent-" & $searchResultsComponentRef.id)
  # The tab whose host this mount is for — see `findIsoNimPaneHost`.
  let tab = data.activeSessionIndex
  var retryCount = 0
  proc doMount() =
    retryCount += 1
    let container = findIsoNimPaneHost(key, tab)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if retryCount > 200:
        cerror "tryMountIsoNimSearchResultsPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    # Per HOST, not per id: tab 0's mount set the latch for a host this
    # tab does not share. See `isoNimPanelNeedsMountInHost`.
    if not isoNimPanelNeedsMountInHost(
        latchSaysMounted = isoNimSearchResultsMounted,
        hostCarriesMark = isoNimPanelContainerIsMounted(container)):
      return

    # Replace any prior content (the layout bridge may have planted a
    # stub element before the IsoNim mount fires).
    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimSearchResultsMounted = true
    markIsoNimPanelContainerMounted(container)
    try:
      mountIsoNimSearchResults(container, searchResultsVMInstance)
    except:
      cerror "tryMountIsoNimSearchResultsPanel: mount EXCEPTION: " & getCurrentExceptionMsg()


  doMount()

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
# The ``search_service`` hooks (it cannot import this module; see the note
# there): the omnibar's ``:grep`` and the main process's batches both reach the
# pane's ViewModel.
# ---------------------------------------------------------------------------

startFindInFilesHook = startFindInFiles
acceptFindInFilesBatchHook = acceptFindInFilesBatch
