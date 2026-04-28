## views/isonim_shell_view.nim
##
## IsoNim DOM-rendering view for the Shell / REPL panel.
##
## Renders a live, reactive DOM tree driven by ShellVM signals.
## When the VM's signals change (input buffer, history, scroll
## position), the DOM updates automatically via IsoNim's
## `createRenderEffect`.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderShellPanel(r, shellVM)
##   check findByClass(panel, "shell-input") != nil
##
## Usage (web):
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let panel = renderShellPanel(r, shellVM)
##   # panel is a dom_api.Element, append to any real DOM container

import isonim/core/[signals, computation]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/shell_vm

# ---------------------------------------------------------------------------
# Output display renderer
# ---------------------------------------------------------------------------

proc renderOutputDisplay*[R, N](r: R; parent: N; vm: ShellVM) =
  ## Render the output display area where command results are shown.
  ## Currently a placeholder — when shell output data is added to the
  ## store, this will use indexEach to render output lines.
  let outputArea = r.createElement("div")
  r.setAttribute(outputArea, "class", "shell-output")
  r.appendChild(parent, outputArea)

  # Reactive: show scroll position
  let scrollIndicator = r.createElement("span")
  r.setAttribute(scrollIndicator, "class", "shell-scroll-indicator")
  r.appendChild(outputArea, scrollIndicator)

  createRenderEffect proc() =
    let pos = vm.scrollPosition.val
    if pos > 0:
      r.setTextContent(scrollIndicator, "Scroll: " & $pos)
      r.setStyle(scrollIndicator, "display", "inline")
    else:
      r.setTextContent(scrollIndicator, "")
      r.setStyle(scrollIndicator, "display", "none")

# ---------------------------------------------------------------------------
# Input area renderer
# ---------------------------------------------------------------------------

proc renderInputArea*[R, N](r: R; parent: N; vm: ShellVM) =
  ## Render the command input area with the input field.
  let inputRow = r.createElement("div")
  r.setAttribute(inputRow, "class", "shell-input-row")
  r.appendChild(parent, inputRow)

  # Prompt indicator
  let prompt = r.createElement("span")
  r.setAttribute(prompt, "class", "shell-prompt")
  r.setTextContent(prompt, "> ")
  r.appendChild(inputRow, prompt)

  # Input field
  let input = r.createElement("input")
  r.setAttribute(input, "class", "shell-input")
  r.setAttribute(input, "placeholder", "Enter command...")
  r.appendChild(inputRow, input)

  # Reactive: reflect current input buffer
  createRenderEffect proc() =
    let text = vm.inputBuffer.val
    r.setAttribute(input, "value", text)

# ---------------------------------------------------------------------------
# History indicator renderer
# ---------------------------------------------------------------------------

proc renderHistoryIndicator*[R, N](r: R; parent: N; vm: ShellVM) =
  ## Render a reactive indicator showing the history navigation state.
  let indicator = r.createElement("span")
  r.setAttribute(indicator, "class", "shell-history-indicator")
  r.appendChild(parent, indicator)

  createRenderEffect proc() =
    let idx = vm.historyIndex.val
    let history = vm.inputHistory.val
    if idx >= 0 and history.len > 0:
      r.setTextContent(indicator, "History: " & $(idx + 1) & "/" & $history.len)
      r.setStyle(indicator, "display", "inline")
    else:
      r.setTextContent(indicator, "")
      r.setStyle(indicator, "display", "none")

# ---------------------------------------------------------------------------
# Main panel renderer — MockRenderer overload
# ---------------------------------------------------------------------------

proc renderShellPanel*(r: MockRenderer; vm: ShellVM): MockNode =
  ## Render the complete Shell panel.
  ##
  ## Structure:
  ##   div.shell-component
  ##     div.shell-output
  ##       span.shell-scroll-indicator  (hidden when at top)
  ##     div.shell-input-row
  ##       span.shell-prompt
  ##       input.shell-input
  ##     span.shell-history-indicator   (hidden when not navigating)
  ##
  ## All content is reactive: changing ShellVM signals automatically
  ## updates the DOM tree via createRenderEffect.
  let panel = r.createElement("div")
  r.setAttribute(panel, "class", "shell-component")

  # Output display
  renderOutputDisplay(r, panel, vm)

  # Input area
  renderInputArea(r, panel, vm)

  # History indicator
  renderHistoryIndicator(r, panel, vm)

  panel

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------

when defined(js):
  proc renderShellPanel*(r: WebRenderer;
                          vm: ShellVM): isonim_dom.Element =
    ## Render the complete Shell panel using real DOM elements.
    let panel = r.createElement("div")
    r.setAttribute(panel, "class", "shell-component isonim-shell")

    renderOutputDisplay(r, panel, vm)
    renderInputArea(r, panel, vm)
    renderHistoryIndicator(r, panel, vm)

    panel

  proc mountIsoNimShell*(container: isonim_dom.Element;
                          vm: ShellVM) =
    ## Mount the IsoNim shell view into a real DOM container.
    ##
    ## Creates the reactive DOM tree and appends it as a child of
    ## `container`. The IsoNim reactive effects handle all subsequent
    ## updates — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderShellPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
