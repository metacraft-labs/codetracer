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
##       input#fif-input.fif-input          query input (Enter → vm.search;
##                                          the scope path's `search-query`,
##                                          where Alt+C / Alt+W / Alt+R hold)
##       span.fif-options                   the three toggles:
##         span.fif-option.fif-option-case  Aa — Match Case
##         span.fif-option.fif-option-word  ab — Match Whole Word
##         span.fif-option.fif-option-regex .* — Use Regular Expression
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
##         div.fif-file-header   shortResultPath · N matches
##         div.fif-match-row*    :line  text [the runner's match highlighted]
##                               (.fif-match-row-selected on the selected row)
##
## The grouping, the captions, the highlight split and the empty-state words
## are the ViewModel's (``groups``, ``shortResultPath``, ``rowParts``,
## ``emptyText``) — the terminal's pane and GPUI's leaf draw the same ones.
##
## There is deliberately no panel header row and no panel-wide result
## count badge: the panel owns the query input, so it must stay visible
## before a search has run, and the per-file-group badge is the only
## count the Figma design shows.  The root's old
## ``search-results-active`` / ``search-results-non-active`` modifier
## (``display: flex`` / ``display: none``) went with the header for the
## same reason — hiding the panel before a search would hide the only
## way to start one — and the CSS rules behind it have since been
## deleted, so nothing emits or styles either class any more.
##
## There is also no ``Filter results...`` input.  The pre-redesign panel
## rendered one, but it was never wired to anything in any renderer; the
## VM-side ``filter`` / ``visibleResults`` machinery it was meant to
## drive has been retired with it, and this view renders ``vm.results``
## directly.  See the header of ``viewmodels/search_results_vm.nim``.
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


import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/search_results_vm
import ../keymap/scope_path   # the field's scope element

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

const ShimmerBlockCount = 6
  ## Placeholder rows the loading state draws while a search is in flight,
  ## shared by both renderers so a headless test sees the production
  ## skeleton.

proc matchRowClass(vm: SearchResultsVM; index: int): string =
  ## A row's classes; the selected one (``F4``, a click) is marked.
  "fif-match-row search-results-match-row" &
    (if vm.selected.val == index: " fif-match-row-selected" else: "")

proc optionClass(on: bool; which: SearchOption): string =
  "fif-option fif-option-" & $which & (if on: " fif-option-on" else: "")

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

const EmptyPrompt = "Type a query above and press Enter to search"

proc matchRowMock(r: MockRenderer; vm: SearchResultsVM; index: int;
                  row: SearchResultLine): MockNode =
  ## One match row. A proc of its own so its click captures ITS index: a
  ## closure built in a `for` body shares one binding on both backends.
  let parts = rowParts(row)
  result = ui(r):
    tdiv(class = matchRowClass(vm, index),
         onclick = proc() = discard vm.openResult(index)):
      span(class = "fif-line-number"): text $row.line
      span(class = "fif-match-text"): discard
  # Highlight children appended imperatively (the DSL discards proc-call
  # results inside `ui`).
  let textSpan = result.children[1]
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
    let pn = ui(r): span: text parts.before
    r.appendChild(textSpan, pn)

proc fileGroupMock(r: MockRenderer; vm: SearchResultsVM;
                   group: SearchResultGroup): MockNode =
  result = ui(r):
    tdiv(class = "fif-file-group"):
      tdiv(class = "fif-file-header"):
        span(class = "fif-file-path"): text shortResultPath(group.path)
        span(class = "fif-file-count"): text matchCountLabel(group.rows.len)
  for k in 0 ..< group.rows.len:
    r.appendChild(result, matchRowMock(r, vm, group.rows[k].index,
                                       group.rows[k].row))

proc recentItemMock(r: MockRenderer; vm: SearchResultsVM;
                    rec: RecentSearch): MockNode =
  ui(r):
    tdiv(class = "fif-recent-item",
         onclick = proc() = vm.search(rec.query)):
      span(class = "fif-recent-query"): text rec.query
      span(class = "fif-recent-count"):
        text resultCountLabel(rec.hitCount)

proc optionMock(r: MockRenderer; vm: SearchResultsVM;
                which: SearchOption): MockNode =
  ## One toggle; a proc of its own so its click captures ITS option.
  ui(r):
    span(class = optionClass(false, which), title = SearchOptionTitles[which],
         onclick = proc() = vm.toggleOption(which)):
      text SearchOptionLabels[which]

proc renderSearchResultsPanel*(r: MockRenderer;
                               vm: SearchResultsVM): MockNode =
  ## Mock renderer: produces the same class/id structure as the Web
  ## renderer so headless tests can assert against it.
  var bodyContainer: MockNode
  var inputEl: MockNode
  var optionsEl: MockNode
  var optionEls: array[SearchOption, MockNode]

  let panel = ui(r):
    tdiv(class = "fif-panel search-results"):
      tdiv(class = "fif-search-bar"):
        input(ref = inputEl,
              `type` = "text",
              id = "fif-input",
              class = "fif-input ct-input-panel ct-input-search-image",
              placeholder = "Search in files...")
        span(ref = optionsEl, class = "fif-options"): discard
        span(class = "fif-badge"): text "Find in Files"
        span(class = "fif-clear-btn"): text "×"
      tdiv(ref = bodyContainer,
           class = "fif-body"):
        discard

  r.setAttribute(inputEl, ScopeKindAttribute, $ekInput)
  r.setAttribute(inputEl, ScopeIdAttribute, SearchQueryInput)
  for which in SearchOption:
    optionEls[which] = optionMock(r, vm, which)
    r.appendChild(optionsEl, optionEls[which])

  createRenderEffect proc() =
    let o = vm.options.val
    for which in SearchOption:
      r.setAttribute(optionEls[which], "class", optionClass(o.isOn(which), which))

  createRenderEffect proc() =
    let loading = vm.loading.val
    let groups = vm.groups.val
    let recents = vm.recentSearches.val
    discard vm.selected.val
    r.clearChildren(bodyContainer)

    if loading:
      for i in 0 ..< ShimmerBlockCount:
        let shimRow = ui(r):
          tdiv(class = "fif-shimmer-block"): discard
        r.appendChild(bodyContainer, shimRow)
      return

    if groups.len == 0:
      let emptyNode = ui(r):
        tdiv(class = "fif-empty"): discard
      r.appendChild(bodyContainer, emptyNode)

      if recents.len > 0 and vm.query.val.len == 0:
        let label = ui(r):
          tdiv(class = "fif-recent-label"): text "Recent searches"
        r.appendChild(emptyNode, label)
        for rec in recents:
          r.appendChild(emptyNode, recentItemMock(r, vm, rec))
      else:
        let prompt = ui(r):
          tdiv(class = "fif-empty-prompt"):
            text emptyText(vm, EmptyPrompt)
        r.appendChild(emptyNode, prompt)
      return

    for gi in 0 ..< groups.len:
      r.appendChild(bodyContainer, fileGroupMock(r, vm, groups[gi]))

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

  proc setNodeClass(node: isonim_dom.Node; value: cstring)
      {.importjs: "#.className = #".}

  proc appendTextSpanChildren(r: WebRenderer;
                              textEl: isonim_dom.Element;
                              row: SearchResultLine) =
    ## Append pre-highlight-post text children into ``textEl``.
    let parts = rowParts(row)
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
      let pn = ui(r): span: text row.text
      isonim_dom.appendChild(isonim_dom.Node(textEl),
                             isonim_dom.Node(pn))

  proc renderMatchRowWeb(r: WebRenderer;
                         vm: SearchResultsVM;
                         index: int;
                         res: SearchResultLine): isonim_dom.Element =
    ## Build a single match row. A factory proc, so each row's click
    ## captures its own index (a closure built in a `for` body shares one
    ## binding under the JS backend).
    let captured = res
    let onClick = proc() = discard vm.openResult(index)
    var textSpanEl: isonim_dom.Element
    let row = ui(r):
      tdiv(class = matchRowClass(vm, index),
           onclick = onClick):
        span(class = "fif-line-number"):
          text $captured.line
        span(ref = textSpanEl, class = "fif-match-text"):
          discard
    appendTextSpanChildren(r, textSpanEl, captured)
    row

  proc renderFileGroupWeb(r: WebRenderer; vm: SearchResultsVM;
                          group: SearchResultGroup): isonim_dom.Element =
    ## Build a file group (header + match rows).  Match rows are appended
    ## **outside** the ``ui()`` block to avoid the silent-discard rule.
    let groupEl = ui(r):
      tdiv(class = "fif-file-group"):
        tdiv(class = "fif-file-header", title = group.path):
          span(class = "fif-file-path"):
            text shortResultPath(group.path)
          span(class = "fif-file-count"):
            text matchCountLabel(group.rows.len)
    for k in 0 ..< group.rows.len:
      let rowEl = renderMatchRowWeb(r, vm, group.rows[k].index,
                                    group.rows[k].row)
      isonim_dom.appendChild(isonim_dom.Node(groupEl),
                             isonim_dom.Node(rowEl))
    groupEl

  proc setNodeDisplay(node: isonim_dom.Node; display: cstring)
      {.importjs: "#.style.display = #".}

  proc setNodeAttribute(node: isonim_dom.Node; name, value: cstring)
      {.importjs: "#.setAttribute(#, #)".}

  proc optionWeb(r: WebRenderer; vm: SearchResultsVM;
                 which: SearchOption): isonim_dom.Element =
    ## One toggle; a factory, so its click captures ITS option.
    ui(r):
      span(class = optionClass(false, which), title = SearchOptionTitles[which],
           onclick = proc() = vm.toggleOption(which)):
        text SearchOptionLabels[which]

  proc recentItemWeb(r: WebRenderer; vm: SearchResultsVM;
                     inputEl: isonim_dom.Element;
                     rec: RecentSearch): isonim_dom.Element =
    ## One recent search; a factory for the closure's own capture.
    ui(r):
      tdiv(class = "fif-recent-item",
           onclick = proc() =
             if not inputEl.isNil:
               isonim_dom.Node(inputEl).setInputNodeValue(cstring(rec.query))
             vm.search(rec.query)):
        span(class = "fif-recent-query"): text rec.query
        span(class = "fif-recent-count"):
          text resultCountLabel(rec.hitCount)

  proc renderSearchResultsPanel*(r: WebRenderer;
                                 vm: SearchResultsVM): isonim_dom.Element =
    ## Render the Find in Files panel for the real DOM.
    ##
    ## Search bar structure — the same one the mock renderer above builds,
    ## and the one the module header documents:
    ##   div.fif-search-bar
    ##     input#fif-input.fif-input  the query input (Enter → vm.search)
    ##     span.fif-options           Aa / ab / .* — the three toggles
    ##     span.fif-badge             "Find in Files" label badge
    ##     span.fif-clear-btn         × clear, hidden when the input is empty
    var bodyContainer: isonim_dom.Element
    var inputEl: isonim_dom.Element
    var clearBtnEl: isonim_dom.Element
    var optionsEl: isonim_dom.Element
    var optionEls: array[SearchOption, isonim_dom.Element]

    let panel = ui(r):
      tdiv(class = "fif-panel search-results"):
        tdiv(class = "fif-search-bar"):
          input(ref = inputEl,
                `type` = "text",
                id = "fif-input",
                class = "fif-input ct-input-panel ct-input-search-image",
                placeholder = "Search in files...")
          span(ref = optionsEl, class = "fif-options"):
            discard
          span(class = "fif-badge"):
            text "Find in Files"
          span(ref = clearBtnEl,
               class = "fif-clear-btn"):
            text "×"
        tdiv(ref = bodyContainer,
             class = "fif-body"):
          discard

    # The field shows the query of the search the pane holds — one started
    # from the omnibar's `:grep` included.
    createRenderEffect proc() =
      let q = vm.query.val
      if not inputEl.isNil and $isonim_dom.Node(inputEl).inputNodeValue() != q:
        isonim_dom.Node(inputEl).setInputNodeValue(cstring(q))
        if not clearBtnEl.isNil:
          isonim_dom.Node(clearBtnEl).setNodeDisplay(
            if q.len > 0: cstring"flex" else: cstring"none")

    # The field is Find in Files' query field in the scope path, where the
    # toggles' keys (`Alt+C` / `Alt+W` / `Alt+R`) hold.
    if not inputEl.isNil:
      isonim_dom.Node(inputEl).setNodeAttribute(cstring(ScopeKindAttribute),
                                                cstring($ekInput))
      isonim_dom.Node(inputEl).setNodeAttribute(cstring(ScopeIdAttribute),
                                                cstring(SearchQueryInput))
    for which in SearchOption:
      optionEls[which] = optionWeb(r, vm, which)
      if not optionsEl.isNil:
        isonim_dom.appendChild(isonim_dom.Node(optionsEl),
                               isonim_dom.Node(optionEls[which]))

    createRenderEffect proc() =
      let o = vm.options.val
      for which in SearchOption:
        if not optionEls[which].isNil:
          isonim_dom.Node(optionEls[which]).setNodeClass(
            cstring(optionClass(o.isOn(which), which)))

    # Wire the search input:
    #   Enter      → vm.search (owns all state transitions)
    #   oninput    → show/hide the clear button based on value presence
    if not inputEl.isNil:
      isonim_dom.addEventListener(isonim_dom.Node(inputEl), cstring"keydown",
        proc(ev: isonim_dom.Event) =
          if ev.eventKeyCode() == 13:
            let qs = $isonim_dom.Node(inputEl).inputNodeValue()
            if qs.len > 0:
              vm.search(qs)
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
          discard vm.beginSearch(""))

    # Reactive body: rebuilt from scratch whenever signals change.
    createRenderEffect proc() =
      let loading = vm.loading.val
      let groups = vm.groups.val
      let recents = vm.recentSearches.val
      discard vm.selected.val
      r.clearChildren(bodyContainer)

      if loading:
        for i in 0 ..< ShimmerBlockCount:
          let shimEl = ui(r):
            tdiv(class = "fif-shimmer-block"): discard
          isonim_dom.appendChild(isonim_dom.Node(bodyContainer),
                                 isonim_dom.Node(shimEl))
        return

      if groups.len == 0:
        let emptyEl = ui(r):
          tdiv(class = "fif-empty"): discard
        isonim_dom.appendChild(isonim_dom.Node(bodyContainer),
                               isonim_dom.Node(emptyEl))

        if recents.len > 0 and vm.query.val.len == 0:
          let labelEl = ui(r):
            tdiv(class = "fif-recent-label"): text "Recent searches"
          isonim_dom.appendChild(isonim_dom.Node(emptyEl),
                                 isonim_dom.Node(labelEl))
          for i in 0 ..< recents.len:
            isonim_dom.appendChild(isonim_dom.Node(emptyEl),
                                   isonim_dom.Node(recentItemWeb(r, vm,
                                                                 inputEl,
                                                                 recents[i])))
        else:
          let promptEl = ui(r):
            tdiv(class = "fif-empty-prompt"):
              text emptyText(vm, EmptyPrompt)
          isonim_dom.appendChild(isonim_dom.Node(emptyEl),
                                 isonim_dom.Node(promptEl))
        return

      for gi in 0 ..< groups.len:
        let grpEl = renderFileGroupWeb(r, vm, groups[gi])
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
