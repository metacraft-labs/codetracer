## views/isonim_search_view.nim
##
## IsoNim DOM-rendering view for the Search / Command Palette panel.
##
## Renders a live, reactive DOM tree driven by `SearchVM` signals.
## Both renderer overloads (Mock and Web) produce the same structure,
## hoisted into a single template that is materialised into one
## concrete proc per renderer.
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
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/search_vm

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

proc onSetMode(vm: SearchVM; mode: SearchMode): proc() =
  let m = mode
  result = proc() = vm.setMode(m)

# ---------------------------------------------------------------------------
# Panel template
# ---------------------------------------------------------------------------

template renderSearchPanelImpl(r, vm, rootClass: untyped): untyped =
  ui(r):
    tdiv(class = rootClass):
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
        span(class = selectedIndicatorClass(vm)):
          text selectedIndicatorText(vm)

# ---------------------------------------------------------------------------
# Renderer overloads
# ---------------------------------------------------------------------------

proc renderSearchPanel*(r: MockRenderer; vm: SearchVM): MockNode =
  renderSearchPanelImpl(r, vm, "search-component")

when defined(js):
  proc renderSearchPanel*(r: WebRenderer; vm: SearchVM): isonim_dom.Element =
    renderSearchPanelImpl(r, vm, "search-component isonim-search")

  proc mountIsoNimSearch*(container: isonim_dom.Element; vm: SearchVM) =
    ## Mount the IsoNim Search panel as a child of `container`.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderSearchPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
