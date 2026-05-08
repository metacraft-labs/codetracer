import ui_imports, auto_hide

import tables

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

proc highlightMatch(text: cstring, query: cstring): VNode =
  ## Render text with the search term highlighted. If the query is empty
  ## or not found in the text, render the text as-is.
  if query.isNil or query.len == 0:
    return buildHtml(span): text text

  let lowerText = ($text).toLowerAscii()
  let lowerQuery = ($query).toLowerAscii()
  let idx = lowerText.find(lowerQuery)

  if idx < 0:
    return buildHtml(span): text text

  let before = cstring(($text)[0 ..< idx])
  let matched = cstring(($text)[idx ..< idx + query.len])
  let after = cstring(($text)[idx + query.len .. ^1])

  buildHtml(span):
    if before.len > 0:
      text before
    span(class = "search-results-highlight"):
      text matched
    if after.len > 0:
      text after

proc groupResultsByFile(results: seq[SearchResult]): OrderedTable[cstring, seq[SearchResult]] =
  ## Group search results by file path, preserving order of first appearance.
  result = initOrderedTable[cstring, seq[SearchResult]]()
  for res in results:
    let key = if res.path.isNil: cstring"<unknown>" else: res.path
    if not result.hasKey(key):
      result[key] = @[]
    result[key].add(res)

proc renderFileGroup(self: SearchResultsComponent, filePath: cstring, results: seq[SearchResult], query: cstring): VNode =
  ## Render a group of results under a file path header, VS Code-style.
  buildHtml(tdiv(class = "search-results-file-group")):
    tdiv(class = "search-results-file-header"):
      span(class = "search-results-file-path"):
        text filePath
      span(class = "search-results-file-count"):
        text cstring(" (" & $results.len & ")")
    for res in results:
      let capturedRes = res
      tdiv(
        class = "search-results-match-row",
        onclick = proc =
          discard self.data.openLocation(capturedRes.path, capturedRes.line)
      ):
        span(class = "search-results-line-number"):
          text cstring($res.line)
        span(class = "search-results-match-text"):
          highlightMatch(res.text, query)

method render*(self: SearchResultsComponent): VNode =
  let results = self.service.results[SearchFixed]
  let resultCount = results.len
  # SearchResults is part of the shared chrome and can render before the
  # user has run a search, so the query object is legitimately nil at boot.
  let searchQuery =
    if self.service.query.isNil:
      nil
    else:
      self.service.query
  let query =
    if searchQuery.isNil or searchQuery.query.isNil:
      cstring""
    else:
      searchQuery.query

  if resultCount > 0:
    kxiMap[cstring"search-results"].afterRedraws.add(proc =
      discard
    )

  let maybeActiveClass =
    if self.active:
      "search-results-active"
    else:
      "search-results-non-active"

  buildHtml(
    tdiv(
      class = componentContainerClass("search-results " & maybeActiveClass)
    )
  ):
    # Header bar with result count
    tdiv(class = "search-results-header"):
      if resultCount > 0:
        span(class = "search-results-count"):
          text cstring($resultCount & " result" & (if resultCount != 1: "s" else: ""))
        if query.len > 0:
          span(class = "search-results-query-label"):
            text cstring(" for \"")
            span(class = "search-results-highlight"):
              text query
            text cstring("\"")
      else:
        span(class = "search-results-count"):
          text "No results"

    # Find/filter input
    tdiv(class = "search-results-find-query"):
      input(
        `type` = "text",
        id = "search-results-find-input",
        placeholder = "Filter results...",
        oninput = proc =
          clog "search_results: TODO find " & $(jq("#search-results-find-input").toJs.value.to(cstring))
      )

    # Grouped results by file
    tdiv(class = "search-results-body"):
      if resultCount > 0:
        let grouped = groupResultsByFile(results)
        for filePath, fileResults in grouped:
          renderFileGroup(self, filePath, fileResults, query)
      else:
        tdiv(class = "search-results-empty"):
          text "Run a search to see results here."

proc autoRevealSearchResultsPanel*() =
  ## If the search results panel is pinned to an auto-hide edge strip,
  ## show the overlay so the user can see results. No-op if the panel
  ## is not in auto-hide state.
  if autoHideState.isNil:
    return
  let panel = autoHideState.findPanelByContent(Content.SearchResults)
  if not panel.isNil:
    showOverlay(panel)
