## views/isonim_scratchpad_view.nim
##
## IsoNim DOM-rendering view for the Scratchpad panel.
##
## Renders a live, reactive DOM tree driven by `ScratchpadVM` signals.
## Both renderer overloads (Mock and Web) produce the same structure,
## hoisted into a single template that is materialised into one
## concrete proc per renderer.
##
## Structure:
##   div.scratchpad-component
##     div.scratchpad-header
##       span.scratchpad-title              "Scratchpad"
##     div.scratchpad-items                  reactive item list (placeholder)
##       span.scratchpad-selected-indicator  text + class reactive
##     button.comparison-toggle              text + class reactive

import std/options

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/scratchpad_vm

# ---------------------------------------------------------------------------
# Reactive expressions used inside DSL attributes
# ---------------------------------------------------------------------------

proc selectedIndicatorText(vm: ScratchpadVM): string =
  let sel = vm.selectedItem.val
  if sel.isSome: "Selected: " & $sel.get else: ""

proc selectedIndicatorClass(vm: ScratchpadVM): string =
  if vm.selectedItem.val.isSome:
    "scratchpad-selected-indicator active"
  else:
    "scratchpad-selected-indicator"

proc comparisonToggleText(vm: ScratchpadVM): string =
  if vm.comparisonMode.val: "Exit Compare" else: "Compare"

proc comparisonToggleClass(vm: ScratchpadVM): string =
  if vm.comparisonMode.val: "comparison-toggle active" else: "comparison-toggle"

# ---------------------------------------------------------------------------
# Panel template
# ---------------------------------------------------------------------------

template renderScratchpadPanelImpl(r, vm, rootClass: untyped): untyped =
  ui(r):
    tdiv(class = rootClass):
      tdiv(class = "scratchpad-header"):
        span(class = "scratchpad-title"):
          text "Scratchpad"
      tdiv(class = "scratchpad-items"):
        span(class = selectedIndicatorClass(vm)):
          text selectedIndicatorText(vm)
      button(class = comparisonToggleClass(vm),
             onclick = proc() = vm.toggleComparisonMode()):
        text comparisonToggleText(vm)

# ---------------------------------------------------------------------------
# Renderer overloads
# ---------------------------------------------------------------------------

proc renderScratchpadPanel*(r: MockRenderer; vm: ScratchpadVM): MockNode =
  renderScratchpadPanelImpl(r, vm, "scratchpad-component")

when defined(js):
  proc renderScratchpadPanel*(r: WebRenderer;
                              vm: ScratchpadVM): isonim_dom.Element =
    renderScratchpadPanelImpl(r, vm, "scratchpad-component isonim-scratchpad")

  proc mountIsoNimScratchpad*(container: isonim_dom.Element;
                              vm: ScratchpadVM) =
    ## Mount the IsoNim Scratchpad panel as a child of `container`.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderScratchpadPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
