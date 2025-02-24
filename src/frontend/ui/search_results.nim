import ui_imports

proc fixedSearchView*: VNode =
  let active = if data.services.search.active[SearchFixed]: j"" else: j"fixed-search-non-active"
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

proc renderSearchResult(self: SearchResultsComponent, res: SearchResult): VNode =
  let location = if res.path.isNil: $res.line else: fmt"{res.path}:{res.line}"

  buildHtml(
    tr(
      onclick = proc =
        discard self.data.openLocation(res.path, res.line)
    )
  ):
    td:
      tdiv(class = "search-results-location"):
        text location
    td:
      tdiv(class = "search-results-text"):
        text res.text

method render*(self: SearchResultsComponent): VNode =
  if self.service.results[SearchFixed].len > 0:
    kxiMap[j"search-results"].afterRedraws.add(proc =
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
    tdiv(class = "search-results-find-query"):
      input(
        `type` = "text",
        id = "search-results-find-input",
        oninput = proc =
          clog "search_results: TODO find " & $(jq("#search-results-find-input").toJs.value.to(cstring))
      )
    table:
      thead:
        th:
          tdiv(class = "search-results-location"):
            text "location"
        th:
          tdiv(class = "search-results-text"):
            text "text"
      tbody:
        for res in self.service.results[SearchFixed]:
          renderSearchResult(self, res)
