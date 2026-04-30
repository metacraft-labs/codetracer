## views/isonim_shell_view.nim
##
## IsoNim DOM-rendering view for the Shell / REPL panel.
##
## Renders a live, reactive DOM tree driven by `ShellVM` signals.
## Both renderer overloads (Mock and Web) produce the same structure,
## hoisted into a single template that is materialised into one
## concrete proc per renderer.
##
## Structure:
##   div.shell-component
##     div.shell-output
##       span.shell-scroll-indicator     text + display reactive
##     div.shell-input-row
##       span.shell-prompt               "> "
##       input.shell-input               value reactive
##     span.shell-history-indicator      text + display reactive

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/shell_vm

# ---------------------------------------------------------------------------
# Reactive expressions used inside DSL attributes
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  if cond: "inline" else: "none"

proc scrollIndicatorText(vm: ShellVM): string =
  let pos = vm.scrollPosition.val
  if pos > 0: "Scroll: " & $pos else: ""

proc scrollIndicatorVisible(vm: ShellVM): bool =
  vm.scrollPosition.val > 0

proc historyIndicatorText(vm: ShellVM): string =
  let idx = vm.historyIndex.val
  let history = vm.inputHistory.val
  if idx >= 0 and history.len > 0:
    "History: " & $(idx + 1) & "/" & $history.len
  else:
    ""

proc historyIndicatorVisible(vm: ShellVM): bool =
  vm.historyIndex.val >= 0 and vm.inputHistory.val.len > 0

# ---------------------------------------------------------------------------
# Panel template
# ---------------------------------------------------------------------------

template renderShellPanelImpl(r, vm, rootClass: untyped): untyped =
  ui(r):
    tdiv(class = rootClass):
      tdiv(class = "shell-output"):
        span(class = "shell-scroll-indicator",
             display = displayIf(scrollIndicatorVisible(vm))):
          text scrollIndicatorText(vm)
      tdiv(class = "shell-input-row"):
        span(class = "shell-prompt"):
          text "> "
        input(class = "shell-input",
              placeholder = "Enter command...",
              value = vm.inputBuffer.val)
      span(class = "shell-history-indicator",
           display = displayIf(historyIndicatorVisible(vm))):
        text historyIndicatorText(vm)

# ---------------------------------------------------------------------------
# Renderer overloads
# ---------------------------------------------------------------------------

proc renderShellPanel*(r: MockRenderer; vm: ShellVM): MockNode =
  renderShellPanelImpl(r, vm, "shell-component")

when defined(js):
  proc renderShellPanel*(r: WebRenderer; vm: ShellVM): isonim_dom.Element =
    renderShellPanelImpl(r, vm, "shell-component isonim-shell")

  proc mountIsoNimShell*(container: isonim_dom.Element; vm: ShellVM) =
    ## Mount the IsoNim Shell panel as a child of `container`. Reactive
    ## effects handle every subsequent update — no manual redraw is
    ## needed.
    let r = WebRenderer()
    let panel = renderShellPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
