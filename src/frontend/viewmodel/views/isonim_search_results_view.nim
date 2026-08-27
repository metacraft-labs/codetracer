## views/isonim_search_results_view.nim
##
## IsoNim DOM-rendering view for the Find in Files panel.
##
## Renders a live, reactive DOM tree driven by ``SearchResultsVM``
## signals.  Replaces the legacy Karax ``method render`` in
## ``frontend/ui/search_results.nim`` (the IsoNim view is the single
## source of truth for the panel's DOM).
##
## Panel structure (matching Figma design):
##
##   div.fif-panel.search-results
##     div.fif-search-bar
##       input#fif-input.fif-input          query input (Enter → vm.onSearch)
##       span.fif-badge                     "Find in Files"
##       span.fif-clear-btn                 × — wipes the input and results
##     div.fif-body                        reactive body:
##       -- state A: no active search --
##       div.fif-empty
##         div.fif-recent-label  "Recent searches"  (if any)
##         div.fif-recent-item*  (click → re-run)
##         div.fif-empty-prompt  (when there are no recent searches)
##       -- state B: loading shimmer --
##       div.fif-shimmer-block* (×``ShimmerBlockCount``)
##       -- state C: results --
##       div.fif-file-group*
##         div.fif-file-header   shortPath · N matches
##         div.fif-match-row*    :line  text [highlighted]
##
## There is deliberately no panel header row and no panel-wide result
## count badge: the panel owns the query input, so it must stay visible
## before a search has run (which is also why the root no longer carries
## the ``search-results-non-active`` display:none modifier), and the
## per-file-group badge is the only count the Figma design shows.
##
## Implementation notes:
## - Match rows and file groups are appended **imperatively** (outside the
##   ``ui(r):`` macro block) to avoid the "proc-call results inside ``ui``
##   are silently discarded" pitfall documented in the workspace MEMORY.
## - ``for`` loops inside ``ui()`` only run once at construction time and
##   are therefore only used for static content that does not need to update
##   reactively.  Dynamic lists are built imperatively inside
##   ``createRenderEffect``.
## - A ``ref = varName`` DSL attribute captures an inner element so that
##   imperative post-construction mutations (like appending highlight spans)
##   can target the right node without ``childAt`` (which does not exist in
##   ``isonim/web/dom_api``).
## - The legacy class ``search-results`` is applied on the root so existing
##   GoldenLayout / auto-hide wiring that looks up the component by CSS
##   class keeps working.  Individual result rows carry
##   ``search-results-match-row`` for Playwright E2E compatibility.

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
# Shared helpers
# ---------------------------------------------------------------------------

proc groupByPath(rows: seq[SearchResultLine]):
    tuple[order: seq[string]; groups: Table[string, seq[SearchResultLine]]] =
  ## Group rows by ``path``, preserving the order each path first appears.
  for r in rows:
    let key = if r.path.len == 0: "<unknown>" else: r.path
    if not result.groups.hasKey(key):
      result.groups[key] = @[]
      result.order.add(key)
    result.groups[key].add(r)

proc shortPath(path: string): string =
  ## Return the last two path components so file headers don't overflow
  ## on deep directory trees.
  let parts = path.replace("\\", "/").split("/")
  if parts.len >= 2:
    parts[^2] & "/" & parts[^1]
  elif parts.len == 1:
    parts[0]
  else:
    path

const ShimmerBlockCount = 6
  ## Placeholder rows the loading state draws while a search is in flight.
  ##
  ## Shared by both renderers for the same reason ``countLabel`` is: the two
  ## had each hard-coded their own literal and had already drifted apart (the
  ## mock DOM drew five blocks, the production DOM six), so a headless test
  ## could not have told the difference between the two skeletons.

proc countLabel(n: int; singular, plural: string): string =
  ## Render ``"<n> <noun>"`` with the noun agreeing in number.
  ##
  ## The pre-redesign panel header rendered ``"1 result"`` / ``"N results"``
  ## and never emitted a mismatched noun.  When the header was replaced by
  ## the per-file-group badge the agreement was dropped and a single hit
  ## read ``"1 matches"``.  Both renderer overloads go through this proc so
  ## the mock DOM the tests assert against and the production DOM cannot
  ## disagree about the copy.
  $n & " " & (if n == 1: singular else: plural)

proc matchCountLabel(n: int): string =
  ## Count badge shown on a file group header ("3 matches", "1 match").
  countLabel(n, "match", "matches")

proc resultCountLabel(n: int): string =
  ## Count shown against a recent search ("3 results", "1 result").
  countLabel(n, "result", "results")

proc matchParts(textValue, query: string):
    tuple[matched: bool; before, hit, after: string] =
  ## Split ``textValue`` around the first case-insensitive occurrence of
  ## ``query``.  Returns ``matched = false`` when the query is empty or
  ## not found.
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

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderSearchResultsPanel*(r: MockRenderer;
                               vm: SearchResultsVM): MockNode =
  ## Mock renderer: produces the same class/id structure as the Web
  ## renderer so Playwright / headless tests can assert against it.
  var bodyContainer: MockNode

  let panel = ui(r):
    tdiv(class = "fif-panel search-results"):
      tdiv(class = "fif-search-bar"):
        input(`type` = "text",
              id = "fif-input",
              class = "fif-input ct-input-panel ct-input-search-image",
              placeholder = "Search in files...")
        span(class = "fif-badge"): text "Find in Files"
        span(class = "fif-clear-btn"): text "×"
      tdiv(ref = bodyContainer,
           class = "fif-body"):
        discard

  createRenderEffect proc() =
    let loading = vm.loading.val
    let visible = vm.visibleResults.val
    let query = vm.query.val
    let recents = vm.recentSearches.val
    r.clearChildren(bodyContainer)

    if loading:
      for i in 0 ..< ShimmerBlockCount:
        let shimRow = ui(r):
          tdiv(class = "fif-shimmer-block"): discard
        r.appendChild(bodyContainer, shimRow)
      return

    if visible.len == 0:
      let emptyNode = ui(r):
        tdiv(class = "fif-empty"): discard
      r.appendChild(bodyContainer, emptyNode)

      if recents.len > 0:
        let label = ui(r):
          tdiv(class = "fif-recent-label"): text "Recent searches"
        r.appendChild(emptyNode, label)
        for rec in recents:
          let captured = rec
          let recNode = ui(r):
            tdiv(class = "fif-recent-item",
                 onclick = proc() =
                   if not vm.onSearch.isNil:
                     vm.onSearch(captured.query)):
              span(class = "fif-recent-query"): text captured.query
              span(class = "fif-recent-count"):
                text resultCountLabel(captured.hitCount)
          r.appendChild(emptyNode, recNode)
      else:
        let prompt = ui(r):
          tdiv(class = "fif-empty-prompt"):
            text "Type a query above and press Enter to search"
        r.appendChild(emptyNode, prompt)
      return

    let grouping = groupByPath(visible)
    for path in grouping.order:
      let pathStr = path
      let rows = grouping.groups[pathStr]
      let groupNode = ui(r):
        tdiv(class = "fif-file-group"):
          tdiv(class = "fif-file-header"):
            span(class = "fif-file-path"): text shortPath(pathStr)
            span(class = "fif-file-count"): text matchCountLabel(rows.len)
      r.appendChild(bodyContainer, groupNode)

      for res in rows:
        let captured = res
        let onClick = proc() = vm.jumpToResult(captured)
        let parts = matchParts(captured.text, query)
        let rowNode = ui(r):
          tdiv(class = "fif-match-row search-results-match-row",
               onclick = onClick):
            span(class = "fif-line-number"): text $captured.line
            span(class = "fif-match-text"): discard
        # Append highlight children imperatively to the text span so
        # the DSL "proc-call return silently discarded" rule is avoided.
        let textSpan = rowNode.children[1]
        if parts.matched:
          if parts.before.len > 0:
            let bn = ui(r): span: text parts.before
            r.appendChild(textSpan, bn)
          let hn = ui(r):
            span(class = "fif-highlight search-results-highlight"):
              text parts.hit
          r.appendChild(textSpan, hn)
          if parts.after.len > 0:
            let an = ui(r): span: text parts.after
            r.appendChild(textSpan, an)
        else:
          let pn = ui(r): span: text captured.text
          r.appendChild(textSpan, pn)
        r.appendChild(groupNode, rowNode)

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc eventKeyCode(ev: isonim_dom.Event): int {.importjs: "(#.keyCode || 0)".}
    ## Extract ``keyCode`` from a DOM event without needing a full
    ## ``KeyboardEvent`` type.  Mirrors the pattern in
    ## ``isonim_calltrace_view.nim``.

  proc inputNodeValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
    ## Read the ``value`` property of a DOM input node.

  proc setInputNodeValue(node: isonim_dom.Node; value: cstring) {.importjs: "#.value = #".}
    ## Write the ``value`` property of a DOM input node.

  proc appendTextSpanChildren(r: WebRenderer;
                              textEl: isonim_dom.Element;
                              textValue, query: string) =
    ## Append pre-highlight-post text children into ``textEl``.
    ## Called imperatively after the row element is built so we can
    ## target the captured ``ref`` element directly without ``childAt``.
    let parts = matchParts(textValue, query)
    if parts.matched:
      if parts.before.len > 0:
        let bn = ui(r): span: text parts.before
        isonim_dom.appendChild(isonim_dom.Node(textEl),
                               isonim_dom.Node(bn))
      let hn = ui(r):
        span(class = "fif-highlight search-results-highlight"):
          text parts.hit
      isonim_dom.appendChild(isonim_dom.Node(textEl),
                             isonim_dom.Node(hn))
      if parts.after.len > 0:
        let an = ui(r): span: text parts.after
        isonim_dom.appendChild(isonim_dom.Node(textEl),
                               isonim_dom.Node(an))
    else:
      let pn = ui(r): span: text textValue
      isonim_dom.appendChild(isonim_dom.Node(textEl),
                             isonim_dom.Node(pn))

  proc renderMatchRowWeb(r: WebRenderer;
                         vm: SearchResultsVM;
                         res: SearchResultLine;
                         query: string): isonim_dom.Element =
    ## Build a single match row.  The text span is captured via ``ref``
    ## so that highlight children can be appended imperatively after the
    ## ``ui()`` block — avoiding the "proc-call return silently discarded
    ## inside ui" pitfall.
    let captured = res
    let onClick = proc() = vm.jumpToResult(captured)
    var textSpanEl: isonim_dom.Element
    let row = ui(r):
      tdiv(class = "fif-match-row search-results-match-row",
           onclick = onClick):
        span(class = "fif-line-number"):
          text $captured.line
        span(ref = textSpanEl, class = "fif-match-text"):
          discard
    appendTextSpanChildren(r, textSpanEl, captured.text, query)
    row

  proc renderFileGroupWeb(r: WebRenderer; vm: SearchResultsVM;
                          path: string;
                          rows: seq[SearchResultLine];
                          query: string): isonim_dom.Element =
    ## Build a file group (header + match rows).  Match rows are appended
    ## **outside** the ``ui()`` block to avoid the silent-discard rule.
    let groupEl = ui(r):
      tdiv(class = "fif-file-group"):
        tdiv(class = "fif-file-header"):
          span(class = "fif-file-path"):
            text shortPath(path)
          span(class = "fif-file-count"):
            text matchCountLabel(rows.len)
    for res in rows:
      let rowEl = renderMatchRowWeb(r, vm, res, query)
      isonim_dom.appendChild(isonim_dom.Node(groupEl),
                             isonim_dom.Node(rowEl))
    groupEl

  proc setNodeDisplay(node: isonim_dom.Node; display: cstring)
      {.importjs: "#.style.display = #".}

  proc renderSearchResultsPanel*(r: WebRenderer;
                                 vm: SearchResultsVM): isonim_dom.Element =
    ## Render the Find in Files panel for the real DOM.
    ##
    ## Search bar structure — the same one the mock renderer above builds,
    ## and the one the module header documents:
    ##   div.fif-search-bar
    ##     input#fif-input.fif-input  the query input (Enter → vm.onSearch)
    ##     span.fif-badge             "Find in Files" label badge
    ##     span.fif-clear-btn         × clear, hidden when the input is empty
    var bodyContainer: isonim_dom.Element
    var inputEl: isonim_dom.Element
    var clearBtnEl: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = "fif-panel search-results"):
        tdiv(class = "fif-search-bar"):
          input(ref = inputEl,
                `type` = "text",
                id = "fif-input",
                class = "fif-input ct-input-panel ct-input-search-image",
                placeholder = "Search in files...")
          span(class = "fif-badge"):
            text "Find in Files"
          span(ref = clearBtnEl,
               class = "fif-clear-btn"):
            text "×"
        tdiv(ref = bodyContainer,
             class = "fif-body"):
          discard

    # Wire the search input:
    #   Enter      → vm.onSearch (owns all state transitions)
    #   oninput    → show/hide the clear button based on value presence
    if not inputEl.isNil:
      isonim_dom.addEventListener(isonim_dom.Node(inputEl), cstring"keydown",
        proc(ev: isonim_dom.Event) =
          if ev.eventKeyCode() == 13:
            let qs = $isonim_dom.Node(inputEl).inputNodeValue()
            if qs.len > 0 and not vm.onSearch.isNil:
              vm.onSearch(qs)
          else:
            vm.setActive(true))
      isonim_dom.addEventListener(isonim_dom.Node(inputEl), cstring"input",
        proc(ev: isonim_dom.Event) =
          let hasValue = isonim_dom.Node(inputEl).inputNodeValue().len > 0
          if not clearBtnEl.isNil:
            isonim_dom.Node(clearBtnEl).setNodeDisplay(
              if hasValue: cstring"flex" else: cstring"none"))

    # Wire the clear button: wipe the input, reset VM state.
    if not clearBtnEl.isNil:
      isonim_dom.addEventListener(isonim_dom.Node(clearBtnEl), cstring"click",
        proc(ev: isonim_dom.Event) =
          if not inputEl.isNil:
            isonim_dom.Node(inputEl).setInputNodeValue(cstring"")
          isonim_dom.Node(clearBtnEl).setNodeDisplay(cstring"none")
          vm.setLoading(false)
          vm.clearResults())

    # Reactive body: rebuilt from scratch whenever signals change.
    createRenderEffect proc() =
      let loading = vm.loading.val
      let visible = vm.visibleResults.val
      let query = vm.query.val
      let recents = vm.recentSearches.val
      r.clearChildren(bodyContainer)

      if loading:
        for i in 0 ..< ShimmerBlockCount:
          let shimEl = ui(r):
            tdiv(class = "fif-shimmer-block"): discard
          isonim_dom.appendChild(isonim_dom.Node(bodyContainer),
                                 isonim_dom.Node(shimEl))
        return

      if visible.len == 0:
        let emptyEl = ui(r):
          tdiv(class = "fif-empty"): discard
        isonim_dom.appendChild(isonim_dom.Node(bodyContainer),
                               isonim_dom.Node(emptyEl))

        if recents.len > 0:
          let labelEl = ui(r):
            tdiv(class = "fif-recent-label"): text "Recent searches"
          isonim_dom.appendChild(isonim_dom.Node(emptyEl),
                                 isonim_dom.Node(labelEl))
          for rec in recents:
            let captured = rec
            let recEl = ui(r):
              tdiv(class = "fif-recent-item",
                   onclick = proc() =
                     if not vm.onSearch.isNil:
                       if not inputEl.isNil:
                         isonim_dom.Node(inputEl).setInputNodeValue(
                           cstring(captured.query))
                       vm.onSearch(captured.query)):
                span(class = "fif-recent-query"): text captured.query
                span(class = "fif-recent-count"):
                  text resultCountLabel(captured.hitCount)
            isonim_dom.appendChild(isonim_dom.Node(emptyEl),
                                   isonim_dom.Node(recEl))
        else:
          let promptEl = ui(r):
            tdiv(class = "fif-empty-prompt"):
              text "Type a query above and press Enter to search"
          isonim_dom.appendChild(isonim_dom.Node(emptyEl),
                                 isonim_dom.Node(promptEl))
        return

      let grouping = groupByPath(visible)
      for path in grouping.order:
        let rows = grouping.groups[path]
        let grpEl = renderFileGroupWeb(r, vm, path, rows, query)
        isonim_dom.appendChild(isonim_dom.Node(bodyContainer),
                               isonim_dom.Node(grpEl))

    panel

  proc mountIsoNimSearchResults*(container: isonim_dom.Element;
                                 vm: SearchResultsVM) =
    ## Mount the IsoNim Find in Files panel as a child of ``container``.
    ## Reactive effects handle every subsequent update.
    let r = WebRenderer()
    let panel = renderSearchResultsPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
