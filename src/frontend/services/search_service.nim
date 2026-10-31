import
  service_imports

# THE FIND IN FILES PANE IS `SearchResultsVM`, and its wiring lives in
# ``../ui/search_results.nim``, which this service cannot import (cycle:
# ``search_results`` imports ``ui_imports``, which imports the renderer, which
# imports this service). Two hooks, installed there at module init, carry the
# two directions: a search the omnibar's ``:grep`` starts goes INTO the pane's
# ViewModel (``startFindInFilesHook`` → ``SearchResultsVM.search``), and the
# main process's batches go into it too (``acceptFindInFilesBatchHook`` →
# ``SearchResultsVM.acceptBatch``).
var startFindInFilesHook*: proc(query: string)
var acceptFindInFilesBatchHook*: proc(batch: SearchResultsBatch)
var openFindInFilesFieldHook*: proc()
  ## PLAT-70 Part D: ``:grep`` with no pattern is ``Ctrl+Shift+F`` (Find-And-
  ## Incremental-Search.md §5.1): the pane's field, seeded and selected
  ## (``ui/search_results.openFindInFilesField``).

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
  ## The omnibar's ``:grep <query>``: a search of the Find in Files pane —
  ## the same one its own field runs (``SearchResultsVM.search``). ``:grep``
  ## alone opens the pane's field instead, as ``Ctrl+Shift+F`` does.
  if query.len == 0:
    if not openFindInFilesFieldHook.isNil:
      openFindInFilesFieldHook()
    return
  if not startFindInFilesHook.isNil:
    startFindInFilesHook($query)

proc requestFindInFiles*(self: SearchService; runId: int; query: string;
                         caseSensitive, wholeWord, regex: bool) =
  ## Ask the main process to run search ``runId`` through the shared runner
  ## (``index/ipc_utils.onSearchProgram``).
  self.data.ipc.send("CODETRACER::search-program", js{
    id: runId, query: cstring(query), caseSensitive: caseSensitive,
    wholeWord: wholeWord, regex: regex})

data.services.search.onSearchResultsUpdated = proc(self: SearchService, batch: SearchResultsBatch) {.async.} =
  ## One batch of the shared runner's rows, handed to the pane's ViewModel,
  ## which drops it unless it belongs to the latest search.
  if not acceptFindInFilesBatchHook.isNil:
    acceptFindInFilesBatchHook(batch)
  self.data.redraw()

proc restart*(service: SearchService) =
  discard
