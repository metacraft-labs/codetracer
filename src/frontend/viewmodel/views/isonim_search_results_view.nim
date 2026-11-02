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
## ONE generic view (Shared-DOM-Front-Ends D3): ``renderSearchResultsPanel[R,
## N]`` renders under ``MockRenderer`` in the headless tests and under
## ``WebRenderer`` in the desktop and the web page, mounted by the panel host
## (``ui/panel_host``). The browser's own behaviour — Enter in the field, the
## clear button's visibility, the field following the held query — is
## decoration applied when ``N`` is the DOM element.
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
when defined(js):
  # Enter and Space on a `role="button"` row are its click.
  import ./isonim_activation
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/search_results_vm
import ../keymap/scope_path   # the field's scope element

# The generic procs expand the DSL at their instantiation site.
export signals, computation, components

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

const ShimmerBlockCount = 6
  ## Placeholder rows the loading state draws while a search is in flight,
  ## shared by every renderer so a headless test sees the production
  ## skeleton.

const EmptyPrompt = "Type a query above and press Enter to search"

proc matchRowClass(vm: SearchResultsVM; index: int): string =
  ## A row's classes; the selected one (``F4``, a click) is marked.
  "fif-match-row search-results-match-row" &
    (if vm.selected.val == index: " fif-match-row-selected" else: "")

proc optionClass(on: bool; which: SearchOption): string =
  "fif-option fif-option-" & $which & (if on: " fif-option-on" else: "")

proc openResultHandler(vm: SearchResultsVM; index: int): proc() =
  ## A row's click. A factory, so each row's closure owns its index (Nim
  ## closures capture variables by reference:
  ## https://nim-lang.org/docs/manual.html#procedures-closures).
  result = proc() = discard vm.openResult(index)

proc toggleOptionHandler(vm: SearchResultsVM; which: SearchOption): proc() =
  result = proc() = vm.toggleOption(which)

proc searchAgainHandler(vm: SearchResultsVM; query: string): proc() =
  result = proc() = vm.search(query)

proc matchRow[R, N](r: R; vm: SearchResultsVM; index: int;
                    row: SearchResultLine): N =
  ## One match row: ":line  text", the runner's match highlighted.
  var textSpan: N
  result = ui(r):
    tdiv(role = "button", tabindex = "0", class = matchRowClass(vm, index),
         onclick = openResultHandler(vm, index)):
      span(class = "fif-line-number"): text $row.line
      span(ref = textSpan, class = "fif-match-text"): discard
  # Highlight children appended imperatively (the DSL discards proc-call
  # results inside `ui`).
  let parts = rowParts(row)
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

proc fileGroup[R, N](r: R; vm: SearchResultsVM;
                     group: SearchResultGroup): N =
  result = ui(r):
    tdiv(class = "fif-file-group"):
      tdiv(class = "fif-file-header", title = group.path):
        span(class = "fif-file-path"): text shortResultPath(group.path)
        span(class = "fif-file-count"): text matchCountLabel(group.rows.len)
  for k in 0 ..< group.rows.len:
    r.appendChild(result, matchRow[R, N](r, vm, group.rows[k].index,
                                         group.rows[k].row))

proc recentItem[R, N](r: R; vm: SearchResultsVM; rec: RecentSearch): N =
  ## One recent search; a click runs it again.
  ui(r):
    tdiv(role = "button", tabindex = "0", class = "fif-recent-item",
         onclick = searchAgainHandler(vm, rec.query)):
      span(class = "fif-recent-query"): text rec.query
      span(class = "fif-recent-count"):
        text resultCountLabel(rec.hitCount)

proc optionToggle[R, N](r: R; vm: SearchResultsVM; which: SearchOption): N =
  ui(r):
    span(class = optionClass(false, which), title = SearchOptionTitles[which],
         onclick = toggleOptionHandler(vm, which)):
      text SearchOptionLabels[which]

when defined(js):
  proc eventKeyCode(ev: isonim_dom.Event): int {.importjs: "(#.keyCode || 0)".}
  proc inputNodeValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc setInputNodeValue(node: isonim_dom.Node; value: cstring) {.importjs: "#.value = #".}
  proc setNodeDisplay(node: isonim_dom.Node; display: cstring)
      {.importjs: "#.style.display = #".}
  proc focusAndSelectSoon(node: isonim_dom.Node)
      {.importjs: "((n) => setTimeout(() => { n.focus(); n.select(); }, 0))(#)".}

  proc decorateSearchField(vm: SearchResultsVM;
                           inputEl, clearBtnEl: isonim_dom.Element) =
    ## The browser's half of the search bar: the field shows the query the
    ## pane holds (one started from the omnibar's `:grep` included), Enter
    ## runs a search, and the clear button shows only while there is text.
    let inputNode = isonim_dom.Node(inputEl)
    let clearNode = isonim_dom.Node(clearBtnEl)
    createRenderEffect proc() =
      let q = vm.query.val
      if $inputNode.inputNodeValue() != q:
        inputNode.setInputNodeValue(cstring(q))
      clearNode.setNodeDisplay(if q.len > 0: cstring"flex" else: cstring"none")
    # PLAT-70 Part D (§5.2): `Ctrl+Shift+F`, `:grep` alone — the field
    # focused on the request's seed, its text SELECTED so typing replaces it.
    # Each request once (`fieldHandled`), a panel mounted by the request
    # included.
    createRenderEffect proc() =
      let req = vm.fieldRequest.val
      if req.revision > vm.fieldHandled:
        vm.fieldHandled = req.revision
        inputNode.setInputNodeValue(cstring(req.seed))
        clearNode.setNodeDisplay(if req.seed.len > 0: cstring"flex"
                                 else: cstring"none")
        inputNode.focusAndSelectSoon()
    isonim_dom.addEventListener(inputNode, cstring"keydown",
      proc(ev: isonim_dom.Event) =
        if ev.eventKeyCode() == 13:
          let qs = $inputNode.inputNodeValue()
          if qs.len > 0:
            vm.search(qs)
        else:
          vm.setActive(true))
    isonim_dom.addEventListener(inputNode, cstring"input",
      proc(ev: isonim_dom.Event) =
        clearNode.setNodeDisplay(
          if inputNode.inputNodeValue().len > 0: cstring"flex"
          else: cstring"none"))
    isonim_dom.addEventListener(clearNode, cstring"click",
      proc(ev: isonim_dom.Event) =
        inputNode.setInputNodeValue(cstring""))

proc clearSearchHandler(vm: SearchResultsVM): proc() =
  result = proc() = discard vm.beginSearch("")

proc renderSearchResultsPanel*[R, N](r: R; vm: SearchResultsVM): N =
  ## The Find in Files panel (see the module header for its structure).
  var bodyContainer, inputEl, clearBtnEl, optionsEl: N
  var optionEls: array[SearchOption, N]

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
        span(ref = clearBtnEl, class = "fif-clear-btn",
             onclick = clearSearchHandler(vm)):
          text "×"
      tdiv(ref = bodyContainer, class = "fif-body"):
        discard

  # The field is Find in Files' query field in the scope path, where the
  # toggles' keys (`Alt+C` / `Alt+W` / `Alt+R`) hold.
  r.setAttribute(inputEl, ScopeKindAttribute, $ekInput)
  r.setAttribute(inputEl, ScopeIdAttribute, SearchQueryInput)
  for which in SearchOption:
    optionEls[which] = optionToggle[R, N](r, vm, which)
    r.appendChild(optionsEl, optionEls[which])

  createRenderEffect proc() =
    let o = vm.options.val
    for which in SearchOption:
      r.setAttribute(optionEls[which], "class",
                     optionClass(o.isOn(which), which))

  # The body is rebuilt whenever the search, its results or the recent
  # searches change: loading shimmer, results grouped by file, or the empty
  # state with the recent searches.
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
          r.appendChild(emptyNode, recentItem[R, N](r, vm, rec))
      else:
        let prompt = ui(r):
          tdiv(class = "fif-empty-prompt"):
            text emptyText(vm, EmptyPrompt)
        r.appendChild(emptyNode, prompt)
      return

    for gi in 0 ..< groups.len:
      r.appendChild(bodyContainer, fileGroup[R, N](r, vm, groups[gi]))

  when defined(js):
    when N is isonim_dom.Element:
      decorateSearchField(vm, inputEl, clearBtnEl)

  panel
