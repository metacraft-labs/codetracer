## views/isonim_search_results_view.nim
##
## IsoNim DOM-rendering view for the Search Results panel.
##
## Renders a live, reactive DOM tree driven by ``SearchResultsVM``
## signals.  Replaces the legacy Karax ``method render`` in
## ``frontend/ui/search_results.nim`` (the IsoNim view is the single
## source of truth for the panel's DOM). The GoldenLayout, auto-hide,
## onPanelShown, and ``__ctRenderPanel(20)`` paths all sync legacy state
## into this VM and then mount the IsoNim view directly.
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure (matching the Playwright contract used by
## ``src/tests/gui/tests/build/search-results-e2e.spec.ts`` — the spec
## anchors on the ``.search-results`` class on the panel and on
## ``.search-results-match-row`` for individual rows):
##
##   div.component-container.search-results[.search-results-active|-non-active]
##     div.search-results-header
##       span.search-results-count                        text reactive
##         (the optional " for \"<query>\"" suffix is rendered as
##         children of a span.search-results-query-label)
##     div.search-results-find-query
##       input#search-results-find-input                  oninput→setFilter
##     div.search-results-body
##       div.search-results-empty                         when no rows
##       OR div.search-results-file-group +
##          div.search-results-file-header
##          div.search-results-match-row                  click→vm.jumpToResult
##            (one per visible result, grouped by file path in
##             first-appearance order — mirrors the legacy
##             ``groupResultsByFile`` proc.)
##
## The body is reactive: an outer ``createRenderEffect`` tears it down
## and rebuilds it from the latest signal values whenever
## ``vm.visibleResults``, ``vm.query``, or ``vm.active`` changes.  The
## header count text and the panel root's active modifier update
## reactively via DSL attribute expressions because the macro emits
## per-attribute ``createRenderEffect``s automatically.
##
## On the Web renderer the ``.search-results-match-text`` span uses
## ``textContent`` for the surrounding fragments and a child span with
## class ``search-results-highlight`` for the matched substring — the
## same shape the legacy ``highlightMatch`` proc emitted.

import std/[strutils, tables]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/search_results_vm

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc panelClass(vm: SearchResultsVM): string =
  ## Class for the panel root.  Mirrors the legacy
  ## ``componentContainerClass("search-results " & maybeActive)`` —
  ## the page-object queries on ``.search-results`` and ``component-container``.
  if vm.active.val:
    "component-container search-results search-results-active"
  else:
    "component-container search-results search-results-non-active"

proc countText(vm: SearchResultsVM): string =
  ## Header count label.  Matches the legacy view's branching:
  ## "No results" when empty, "<N> result" / "<N> results" otherwise.
  let count = vm.resultCount.val
  if count == 0:
    "No results"
  elif count == 1:
    "1 result"
  else:
    $count & " results"

proc onResultClick(vm: SearchResultsVM;
                   res: SearchResultLine): proc() =
  ## Closure factory so each row captures its own ``SearchResultLine``.
  ## Without this each click handler would share the same loop variable
  ## reference (the same DSL closure-sharing concern as in
  ## ``isonim_errors_view``).
  let captured = res
  result = proc() = vm.jumpToResult(captured)

# Group helper shared by both renderer overloads.  Stays at module
# scope so the Mock and Web bodies can call it without re-declaring.
proc groupByPath(rows: seq[SearchResultLine]):
    tuple[order: seq[string]; groups: Table[string, seq[SearchResultLine]]] =
  ## Group rows by ``path``, preserving the order in which each path
  ## first appears.  Mirrors the legacy ``groupResultsByFile`` proc.
  ## Empty paths fall back to ``"<unknown>"`` for parity with the
  ## legacy behaviour.
  for r in rows:
    let key = if r.path.len == 0: "<unknown>" else: r.path
    if not result.groups.hasKey(key):
      result.groups[key] = @[]
      result.order.add(key)
    result.groups[key].add(r)

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderMatchRowMock(r: MockRenderer; vm: SearchResultsVM;
                        res: SearchResultLine; query: string): MockNode =
  ## Render a single match row for the Mock renderer.  The
  ## ``search-results-match-text`` body is split into pre / highlight
  ## / post fragments when the query appears inside the snippet, so
  ## headless tests can assert on the highlighted text directly via
  ## the ``search-results-highlight`` class.
  let captured = res
  let onClick = onResultClick(vm, captured)
  result = ui(r):
    tdiv(class = "search-results-match-row",
         onclick = onClick):
      span(class = "search-results-line-number"):
        text $captured.line
      span(class = "search-results-match-text"):
        discard

  # Build the highlighted text body imperatively so the highlight
  # span and the surrounding text fragments both live as children of
  # the ``.search-results-match-text`` span.
  let textSpan = result.children[1]
  if query.len > 0 and captured.text.len > 0:
    let lowerText = captured.text.toLowerAscii()
    let lowerQuery = query.toLowerAscii()
    let idx = lowerText.find(lowerQuery)
    if idx >= 0:
      let before = captured.text[0 ..< idx]
      let matched = captured.text[idx ..< idx + query.len]
      let after = captured.text[idx + query.len .. ^1]
      if before.len > 0:
        let beforeNode = ui(r):
          span:
            text before
        r.appendChild(textSpan, beforeNode)
      let highlightNode = ui(r):
        span(class = "search-results-highlight"):
          text matched
      r.appendChild(textSpan, highlightNode)
      if after.len > 0:
        let afterNode = ui(r):
          span:
            text after
        r.appendChild(textSpan, afterNode)
      return
  # Fallback: no query / no match — render the snippet as plain text.
  let plainNode = ui(r):
    span:
      text captured.text
  r.appendChild(textSpan, plainNode)

proc renderSearchResultsPanel*(r: MockRenderer;
                               vm: SearchResultsVM): MockNode =
  ## Render the Search Results panel for the Mock renderer.
  ##
  ## The header / find-query input is built once via the DSL with
  ## reactive attributes (panel root class, header count text).  An
  ## outer ``createRenderEffect`` rebuilds the ``.search-results-body``
  ## subtree whenever ``vm.visibleResults`` / ``vm.query`` /
  ## ``vm.active`` changes — same shape the build / errors views use.
  var bodyContainer: MockNode

  let panel = ui(r):
    tdiv(class = panelClass(vm)):
      tdiv(class = "search-results-header"):
        span(class = "search-results-count"):
          text countText(vm)
      tdiv(class = "search-results-find-query"):
        input(`type` = "text",
              id = "search-results-find-input",
              placeholder = "Filter results...")
      tdiv(ref = bodyContainer,
           class = "search-results-body"):
        discard

  createRenderEffect proc() =
    let visible = vm.visibleResults.val
    let query = vm.query.val
    r.clearChildren(bodyContainer)

    if visible.len == 0:
      let empty = ui(r):
        tdiv(class = "search-results-empty"):
          text "Run a search to see results here."
      r.appendChild(bodyContainer, empty)
      return

    # Group rows by path so the panel renders the VS Code-style file
    # headers + per-file row blocks the legacy view emitted.
    let grouping = groupByPath(visible)
    for path in grouping.order:
      let pathStr = path
      let rows = grouping.groups[pathStr]
      let header = pathStr & " (" & $rows.len & ")"
      let groupNode = ui(r):
        tdiv(class = "search-results-file-group"):
          tdiv(class = "search-results-file-header"):
            span(class = "search-results-file-path"):
              text pathStr
            span(class = "search-results-file-count"):
              text " (" & $rows.len & ")"
      # Surface the path|count combo in textContent for tests that
      # introspect the header by string match (mirrors the errors panel
      # ``"a.nim (2)"`` shape).
      let _ = header  # suppress unused-warning if Nim devirtualises away
      r.appendChild(bodyContainer, groupNode)
      for res in rows:
        let row = renderMatchRowMock(r, vm, res, query)
        r.appendChild(groupNode, row)

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc matchParts(textValue, query: string):
      tuple[matched: bool; before, hit, after: string] =
    if query.len == 0 or textValue.len == 0:
      return (false, "", "", "")
    let lowerText = textValue.toLowerAscii()
    let lowerQuery = query.toLowerAscii()
    let idx = lowerText.find(lowerQuery)
    if idx < 0:
      return (false, "", "", "")
    result.matched = true
    result.before = if idx > 0: textValue[0 ..< idx] else: ""
    result.hit = textValue[idx ..< idx + query.len]
    let afterStart = idx + query.len
    result.after =
      if afterStart < textValue.len: textValue[afterStart .. ^1] else: ""

  proc renderWebMatchRow(r: WebRenderer;
                         vm: SearchResultsVM;
                         res: SearchResultLine;
                         query: string): isonim_dom.Element =
    ## Build a single match row in the real DOM.  The match text is
    ## broken into pre / highlight / post fragments so the
    ## ``search-results-highlight`` span renders as the matched substring
    ## (same as the legacy ``highlightMatch`` proc).  Click handler
    ## dispatches a jump request via the VM.
    let captured = res
    let onClick = onResultClick(vm, captured)
    let parts = matchParts(captured.text, query)
    ui(r):
      tdiv(class = "search-results-match-row",
           onclick = onClick):
        span(class = "search-results-line-number"):
          text $captured.line
        span(class = "search-results-match-text"):
          if parts.matched:
            if parts.before.len > 0:
              span:
                text parts.before
            span(class = "search-results-highlight"):
              text parts.hit
            if parts.after.len > 0:
              span:
                text parts.after
          else:
            span:
              text captured.text

  proc renderWebResultGroup(r: WebRenderer; vm: SearchResultsVM;
                            path: string;
                            rows: seq[SearchResultLine];
                            query: string): isonim_dom.Element =
    ui(r):
      tdiv(class = "search-results-file-group"):
        tdiv(class = "search-results-file-header"):
          span(class = "search-results-file-path"):
            text path
          span(class = "search-results-file-count"):
            text " (" & $rows.len & ")"
        for res in rows:
          renderWebMatchRow(r, vm, res, query)

  proc renderSearchResultsPanel*(r: WebRenderer;
                                 vm: SearchResultsVM): isonim_dom.Element =
    ## Render the Search Results panel for the real DOM.
    var bodyContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = panelClass(vm)):
        tdiv(class = "search-results-header"):
          span(class = "search-results-count"):
            text countText(vm)
        tdiv(class = "search-results-find-query"):
          input(`type` = "text",
                id = "search-results-find-input",
                placeholder = "Filter results...")
        tdiv(ref = bodyContainer,
             class = "search-results-body"):
          discard

    createRenderEffect proc() =
      let visible = vm.visibleResults.val
      let query = vm.query.val
      # Stable host slot for the result list; rebuilt from declarative
      # IsoNim nodes so grouping and row event handlers stay simple.
      r.clearChildren(bodyContainer)

      if visible.len == 0:
        let empty = ui(r):
          tdiv(class = "search-results-empty"):
            text "Run a search to see results here."
        r.appendChild(bodyContainer, empty)
        return

      let grouping = groupByPath(visible)
      for path in grouping.order:
        let rows = grouping.groups[path]
        r.appendChild(bodyContainer,
                      renderWebResultGroup(r, vm, path, rows, query))

    panel

  proc mountIsoNimSearchResults*(container: isonim_dom.Element;
                                 vm: SearchResultsVM) =
    ## Mount the IsoNim search results panel as a child of
    ## ``container``.  Reactive effects handle every subsequent update
    ## — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderSearchResultsPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
