## Search Results panel — workspace-wide text-search results list.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The pane is the generic view
## (``viewmodel/views/isonim_search_results_view.nim``) over the session's
## ``SearchResultsVM`` — the model the terminal and GPUI draw too — mounted by
## the panel host (``ui/panel_host``) into the container GoldenLayout or the
## auto-hide strip creates. The ``SearchResultsComponent`` keeps its identity
## for the layout's and the auto-hide wiring. A search runs in the
## main process through the one shared runner
## (``viewmodel/host/find_in_files``); its batches arrive through
## ``search_service`` and go straight into the ViewModel.
## ---------------------------------------------------------------------------

import ui_imports, auto_hide, ../[types, communication]

import std/json
from ../viewmodel/store/types as vmtypes import SearchResultLine
from ../viewmodel/viewmodels/search_results_vm import
  SearchResultsVM, search, acceptBatch, stepResult,
  openResult, toggleOption, searchOptionOf, openField,
  TextMatchOptions
import ./panel_host
from ../viewmodel/session_vm import SessionViewModel

proc requestFixedSearchRender*()
proc installSearchVMCallbacks*(vm: SearchResultsVM)

proc paneVM(): SearchResultsVM =
  ## The ViewModel the pane renders: the shown session's
  ## (``ui/panel_host``), or nil before the renderer has one.
  let session = panelSession()
  if session.isNil: nil else: session.searchResultsVM

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

proc initSearchResultsVMFromSession*(vm: SearchResultsVM) =
  ## Wire the session's ``SearchResultsVM`` to this window. The panel host
  ## mounts the pane over it (``ui/panel_host``).
  installSearchVMCallbacks(vm)

proc rowOf(r: SearchResultRow): SearchResultLine =
  ## A main-process row as the pane's value.
  SearchResultLine(text: (if r.text.isNil: "" else: $r.text),
                   path: (if r.path.isNil: "" else: $r.path),
                   line: r.line, matchStart: r.matchStart,
                   matchLength: r.matchLength)

proc acceptFindInFilesBatch(batch: SearchResultsBatch) =
  ## The main process's batch, into the pane — dropped by the ViewModel
  ## unless it belongs to the latest search.
  let vm = paneVM()
  if vm.isNil:
    return
  var rows: seq[SearchResultLine] = @[]
  for r in batch.rows:
    rows.add rowOf(r)
  discard vm.acceptBatch(
    batch.id, rows, batch.done,
    (if batch.note.isNil: "" else: $batch.note))

proc stepSearchResult*(delta: int) =
  ## `search.next-result` / `search.previous-result` (`F4` / `Shift+F4`):
  ## the next / previous result, wrapping, opened at its line.
  let vm = paneVM()
  if vm.isNil:
    return
  let i = vm.stepResult(delta)
  if i >= 0:
    discard vm.openResult(i)

proc toggleSearchOption*(operation: string) =
  ## `search.toggle-case` / `-whole-word` / `-regex` (`Alt+C` / `Alt+W` /
  ## `Alt+R` in the pane's field): the toggle flips, and a search that ran
  ## runs again with it.
  let vm = paneVM()
  if vm.isNil:
    return
  let (known, which) = searchOptionOf(operation)
  if known:
    vm.toggleOption(which)

proc editorSelectionText(): string =
  ## The active editor's selection as Monaco holds it ("" with no editor).
  let active = data.services.editor.active
  if active.len == 0 or not data.ui.editors.hasKey(active) or
     data.ui.editors[active].monacoEditor.isNil:
    return ""
  $data.getMonacoSelectionText()

proc openFindInFilesField*() =
  ## PLAT-70 Part D: ``search.find-in-files`` with no pattern —
  ## ``Ctrl+Shift+F``, ``:grep`` alone, Edit › Find in Files (Find-And-
  ## Incremental-Search.md §5.2): the pane revealed, opened or focused
  ## (``openLayoutTab``) and its field focused, seeded with the editor's
  ## selection when that is one line, else holding the pane's query
  ## (``SearchResultsVM.openField``), its text selected so typing replaces
  ## it. The panel's view acts on the request. Nothing is searched until
  ## ``Enter``.
  data.openLayoutTab(Content.SearchResults)
  let vm = paneVM()
  if not vm.isNil:
    discard vm.openField(editorSelectionText())

proc startFindInFiles(query: string) =
  ## The omnibar's ``:grep``: the pane's own search.
  let vm = paneVM()
  if not vm.isNil:
    vm.search(query)

method register*(self: SearchResultsComponent, api: MediatorWithSubscribers) =
  ## The pane subscribes to nothing: its rows are the session's
  ## ``SearchResultsVM``, which the main process's batches fill.
  self.api = api

# ---------------------------------------------------------------------------
# The ``search_service`` hooks (it cannot import this module; see the note
# there): the omnibar's ``:grep`` and the main process's batches both reach the
# pane's ViewModel.
# ---------------------------------------------------------------------------

startFindInFilesHook = startFindInFiles
openFindInFilesFieldHook = openFindInFilesField
acceptFindInFilesBatchHook = acceptFindInFilesBatch
