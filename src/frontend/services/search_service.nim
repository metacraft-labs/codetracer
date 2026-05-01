import
  service_imports,
  ../ui/auto_hide
from ../viewmodel/store/types as vmtypes import SearchResultLine

# Forward declarations of ``search_results`` sync helpers.  The
# concrete implementations live in ``../ui/search_results.nim`` and are
# wired up at module-init time below.  Going through proc variables
# avoids the import cycle (``search_results`` imports ``ui_imports``,
# which imports the renderer, which imports this service).
var syncSearchResultsAppendBatchHook*: proc(matches: seq[SearchResultLine])
var syncSearchResultsSetQueryHook*: proc(query: string)
var syncSearchResultsClearHook*: proc()

#data.services.search.pluginCommands = rendererPluginCommands

proc input*(self: SearchService, query: cstring) {.async.} =
  discard

proc run*(self: SearchService) {.async.} =
  discard

# proc parseSearch*(self: SearchService, query: cstring, includePattern: cstring, excludePattern: cstring): SearchQuery =
#   let tokens = ($query).split(" ", 1)
#   var command = cstring"text"
#   var searchQuery = query
#   if tokens.len > 0 and self.pluginCommands.hasKey(cstring(tokens[0])):
#     command = cstring(tokens[0])
#     searchQuery = cstring(tokens[1])

#   SearchQuery(command: command, query: searchQuery, includePattern: includePattern, excludePattern: excludePattern)

proc run*(self: SearchService, query: cstring, includePattern: cstring, excludePattern: cstring) {.async.} =
  if query.len == 0:
    echo "no search for empty query"
    return
  # let searchQuery = self.parseSearch(query, includePattern, excludePattern)
  # #self.services.search.parseQuery(value, cstring"", cstring"")
  # self.results[searchQuery.searchMode] = @[]
  # self.active[searchQuery.searchMode] = true
  # self.query = searchQuery
  # self.data.ipc.send "CODETRACER::search", searchQuery #, "", seq[CommandResult], noCache=true)
  # self.data.redraw()

proc searchProgram*(self: SearchService, query: cstring) =
  clog "searchProgram in service " & $query
  self.data.ipc.send("CODETRACER::search-program", query)

data.services.search.onSearchResultsUpdated = proc(self: SearchService, results: seq[SearchResult]) {.async.} =
  self.results[self.query.searchMode] = self.results[self.query.searchMode].concat(results)
  self.active[self.query.searchMode] = true
  self.data.ui.status.searchResults.active = true
  # Mirror the streamed batch into the IsoNim ``SearchResultsVM`` so
  # the IsoNim view's reactive body rebuilds in lock-step with the
  # legacy record.  Done as a single bulk-append so the body re-renders
  # only once per IPC delivery.
  if self.query.searchMode == SearchFixed:
    var rows: seq[SearchResultLine] = @[]
    for r in results:
      rows.add(SearchResultLine(
        text: (if r.text.isNil: "" else: $r.text),
        path: (if r.path.isNil: "" else: $r.path),
        line: r.line))
    if not syncSearchResultsAppendBatchHook.isNil:
      syncSearchResultsAppendBatchHook(rows)
    if not self.query.isNil and not self.query.query.isNil and
       not syncSearchResultsSetQueryHook.isNil:
      syncSearchResultsSetQueryHook($self.query.query)
  # Auto-reveal the search results panel if it is pinned to an auto-hide edge.
  if not autoHideState.isNil:
    let panel = autoHideState.findPanelByContent(Content.SearchResults)
    if not panel.isNil:
      showOverlay(panel)
  self.data.redraw()

proc restart*(service: SearchService) =
  discard
