## views/isonim_search_view.nim
##
## IsoNim DOM-rendering view for the Search / Command Palette panel.
##
## Renders a live, reactive DOM tree driven by `SearchVM` signals. ONE generic
## view (Shared-DOM-Front-Ends D3), `renderSearchPanel[R, N]`, rendered under
## `MockRenderer` in the headless tests and `WebRenderer` in the storybook.
##
## Structure:
##   div.search-component
##     div.search-mode-selector
##       button.mode-{command|file|find-in-files|find-symbol}[.active]
##     div.search-input-row
##       input.search-query-input              value reactive
##     div.search-results                      display reactive
##       span.search-selected-indicator        text + class reactive

import std/options

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/search_vm

# The generic procs expand the DSL at their instantiation site.
export signals, computation, components

# ---------------------------------------------------------------------------
# Static labels and class names
# ---------------------------------------------------------------------------

proc modeLabel(mode: SearchMode): string =
  case mode
  of smCommand:     "Command"
  of smFile:        "File"
  of smFindInFiles: "Find in Files"
  of smFindSymbol:  "Find Symbol"

proc modeCssClass(mode: SearchMode): string =
  case mode
  of smCommand:     "mode-command"
  of smFile:        "mode-file"
  of smFindInFiles: "mode-find-in-files"
  of smFindSymbol:  "mode-find-symbol"

# ---------------------------------------------------------------------------
# Reactive expressions used inside DSL attributes
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc modeButtonClass(vm: SearchVM; mode: SearchMode): string =
  let cls = modeCssClass(mode)
  if vm.mode.val == mode: cls & " active" else: cls

proc selectedIndicatorClass(vm: SearchVM): string =
  if vm.selectedResult.val.isSome:
    "search-selected-indicator active"
  else:
    "search-selected-indicator"

proc selectedIndicatorText(vm: SearchVM): string =
  let sel = vm.selectedResult.val
  if sel.isSome: "Selected: " & $sel.get else: ""

proc searchResultClass(vm: SearchVM; index: int): string =
  if vm.selectedResult.val.isSome and vm.selectedResult.val.get == index:
    "search-result-row selected"
  else:
    "search-result-row"

proc onResultClick(vm: SearchVM; index: int): proc() =
  let captured = index
  result = proc() = vm.selectResult(some(captured))

proc onSetMode(vm: SearchVM; mode: SearchMode): proc() =
  let m = mode
  result = proc() = vm.setMode(m)

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc renderSearchResultRow[R, N](r: R; vm: SearchVM;
                                 entry: proc(): SearchPanelResultEntry;
                                 index: int): N =
  ## One result row. `indexEach` reuses it as the results change, so its
  ## text reads `entry()`.
  ui(r):
    tdiv(class = searchResultClass(vm, index),
         onclick = onResultClick(vm, index)):
      span(class = "search-result-label"):
        text entry().label
      span(class = "search-result-detail"):
        text entry().detail
      span(class = "search-result-shortcut"):
        text entry().shortcut

proc renderSearchPanel*[R, N](r: R; vm: SearchVM): N =
  ## The Search / Command Palette panel (see the module header).
  var rowsHost: N
  let panel = ui(r):
    tdiv(class = "search-component isonim-search"):
      tdiv(class = "search-mode-selector"):
        button(class = modeButtonClass(vm, smCommand),
               onclick = onSetMode(vm, smCommand)):
          text modeLabel(smCommand)
        button(class = modeButtonClass(vm, smFile),
               onclick = onSetMode(vm, smFile)):
          text modeLabel(smFile)
        button(class = modeButtonClass(vm, smFindInFiles),
               onclick = onSetMode(vm, smFindInFiles)):
          text modeLabel(smFindInFiles)
        button(class = modeButtonClass(vm, smFindSymbol),
               onclick = onSetMode(vm, smFindSymbol)):
          text modeLabel(smFindSymbol)
      tdiv(class = "search-input-row"):
        input(class = "search-query-input",
              placeholder = "Search...",
              value = vm.query.val)
      tdiv(class = "search-results",
           display = displayIf(vm.resultsVisible.val)):
        tdiv(ref = rowsHost, class = "search-result-rows"):
          discard
        span(class = selectedIndicatorClass(vm)):
          text selectedIndicatorText(vm)
  indexEach[SearchPanelResultEntry, R, N](r, rowsHost,
    proc(): seq[SearchPanelResultEntry] = vm.results.val,
    proc(entry: proc(): SearchPanelResultEntry; index: int): N =
      renderSearchResultRow[R, N](r, vm, entry, index))
  panel
