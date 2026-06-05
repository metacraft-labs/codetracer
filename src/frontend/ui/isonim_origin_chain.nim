## ui/isonim_origin_chain.nim
##
## Origin Chain side-panel component (spec §3.2.2 "Show in side
## panel" affordance + §8.1 "The Origin Chain Panel is a new IsoNim
## component"). Renders the full chain with semantic HTML and ARIA
## labels (spec §13.0):
##
##   <section aria-label="Value origin chain">
##     <nav aria-label="Origin breadcrumbs"> … </nav>
##     <ol>
##       <li aria-label="hop 1: trivial copy at step 478">
##         <button>…</button>
##         <details><summary>Operands</summary> … </details>
##       </li>
##       …
##     </ol>
##     <footer> Show in scratchpad | Copy as markdown </footer>
##   </section>
##
## Subscribes to `OriginChainVM.activeChain`. Keyboard navigation
## (spec §13.0):
## - ↑/↓ move between hops (`focusNextHop` / `focusPrevHop`),
## - Enter seeks to the hop's step (`OriginChainVM.onSeekToHop`),
## - → expands operand panels, ← collapses them,
## - Esc dismisses the side panel.
##
## Default keybinding `Ctrl+Shift+O` (Linux/Windows) / `Cmd+Shift+O`
## (macOS) registers the `CodeTracer: Show Value Origin` command
## (see `command_palette_vm` for the registration entry).
##
## This module ships the pure-Nim view model (`OriginChainPanel`) plus
## the JS-only DOM bridge. The pure logic (`hopAriaLabel`,
## `selectNextHop`, etc.) is independently testable.

import std/[options, sequtils, strformat, strutils]

import isonim/core/signals

import ../viewmodel/viewmodels/[origin_chain_types, origin_chain_vm]
import origin_badge

type
  OriginChainPanel* = object
    ## Local view state held by the side-panel component. Mirrors a
    ## subset of `OriginChainVM` so the side-panel can manage focus
    ## without round-tripping through reactive signals on every key
    ## press.
    focusedHop*: int                  ## -1 = nothing focused
    expandedOperands*: seq[int]       ## indices of hops whose operand
                                      ## panel is open
    visible*: bool                    ## side panel open / closed

proc newOriginChainPanel*(): OriginChainPanel =
  OriginChainPanel(
    focusedHop: -1,
    expandedOperands: @[],
    visible: false,
  )

proc hopAriaLabel*(hop: OriginHop; index: int): string =
  ## ARIA label for a hop row. Concrete spec example:
  ##   "hop 1: trivial copy at step 478"
  let kindLabel =
    case hop.kind
    of okTrivialCopy:     "trivial copy"
    of okFieldAccess:     "field access"
    of okIndexAccess:     "index access"
    of okComputational:   "computational expression"
    of okFunctionCall:    "function call"
    of okLiteral:         "literal"
    of okReturnCapture, okFunctionReturn: "return capture"
    of okParameterPass:   "parameter pass"
    of okCrossThreadCopy: "cross-thread copy"
    of okUnknown:         "unknown"
  fmt"hop {index + 1}: {kindLabel} at step {hop.stepId}"

proc focusNextHop*(panel: var OriginChainPanel; chain: OriginChain) =
  ## ↓ key. Wraps from the last hop back to 0.
  if chain.hops.len == 0:
    panel.focusedHop = -1
    return
  let next = panel.focusedHop + 1
  if next >= chain.hops.len:
    panel.focusedHop = 0
  else:
    panel.focusedHop = next

proc focusPrevHop*(panel: var OriginChainPanel; chain: OriginChain) =
  ## ↑ key. Wraps from 0 back to the last hop.
  if chain.hops.len == 0:
    panel.focusedHop = -1
    return
  let prev = panel.focusedHop - 1
  if prev < 0:
    panel.focusedHop = chain.hops.len - 1
  else:
    panel.focusedHop = prev

proc enterHop*(panel: OriginChainPanel; chain: OriginChain;
               vm: OriginChainVM) =
  ## Enter key — seeks to the focused hop via the VM bridge.
  if panel.focusedHop < 0 or panel.focusedHop >= chain.hops.len:
    return
  vm.onSeekToHop(chain.hops[panel.focusedHop])

proc expandFocusedOperands*(panel: var OriginChainPanel; chain: OriginChain) =
  ## → key. Reveals the operand panel for the focused Computational
  ## hop (spec §3.2.2). Idempotent.
  if panel.focusedHop < 0 or panel.focusedHop >= chain.hops.len:
    return
  if panel.focusedHop notin panel.expandedOperands:
    panel.expandedOperands.add(panel.focusedHop)

proc collapseFocusedOperands*(panel: var OriginChainPanel) =
  ## ← key. Collapses the operand panel for the focused hop.
  let target = panel.focusedHop
  panel.expandedOperands = panel.expandedOperands.filterIt(it != target)

proc dismissPanel*(panel: var OriginChainPanel) =
  ## Esc key. Hides the side panel without modifying the underlying
  ## VM state — re-opening restores the same chain.
  panel.visible = false

proc showPanel*(panel: var OriginChainPanel) =
  panel.visible = true
  panel.focusedHop = 0

iterator items*(panel: OriginChainPanel): int =
  for i in panel.expandedOperands:
    yield i

# ---------------------------------------------------------------------------
# DOM rendering (JS-only)
# ---------------------------------------------------------------------------

when defined(js):
  import std/dom

  proc renderPanelDom*(parent: Node;
                       vm: OriginChainVM;
                       panel: var OriginChainPanel) {.discardable.} =
    ## Render the side panel into `parent`. Walks the active chain
    ## from `OriginChainVM.activeChain` and emits the semantic HTML
    ## described in the module docstring.
    while not parent.firstChild.isNil:
      parent.removeChild(parent.firstChild)
    if vm.activeChain.val.isNone:
      let placeholder = document.createElement(cstring"p")
      placeholder.setAttribute(cstring"class", cstring"ct-origin-side-empty")
      placeholder.innerText = cstring"Select a value to see its origin."
      parent.appendChild(placeholder)
      return
    let chain = vm.activeChain.val.get
    let section = document.createElement(cstring"section")
    section.setAttribute(cstring"aria-label", cstring"Value origin chain")
    parent.appendChild(section)

    # Breadcrumb nav
    let nav = document.createElement(cstring"nav")
    nav.setAttribute(cstring"aria-label", cstring"Origin breadcrumbs")
    for entry in vm.breadcrumbStack.val:
      let crumb = document.createElement(cstring"button")
      crumb.innerText = cstring(entry.variableName & "@" & $entry.stepId)
      nav.appendChild(crumb)
    section.appendChild(nav)

    let ol = document.createElement(cstring"ol")
    section.appendChild(ol)
    for i, hop in chain.hops:
      let li = document.createElement(cstring"li")
      li.setAttribute(cstring"aria-label", cstring(hopAriaLabel(hop, i)))
      let button = document.createElement(cstring"button")
      button.innerText = cstring(fmt"{hop.location.path}:{hop.location.line}")
      li.appendChild(button)
      if hop.operandSnapshots.len > 0:
        let details = document.createElement(cstring"details")
        let summary = document.createElement(cstring"summary")
        summary.innerText = cstring(fmt"{hop.operandSnapshots.len} operand snapshots")
        details.appendChild(summary)
        for op in hop.operandSnapshots:
          let dt = document.createElement(cstring"div")
          dt.innerText = cstring(op.name & " = " & op.value)
          details.appendChild(dt)
        li.appendChild(details)
      ol.appendChild(li)

    # Terminator row (final SVG icon + expression, no footer per
    # spec §3.2.2).
    let termLi = document.createElement(cstring"li")
    termLi.setAttribute(cstring"class", cstring"ct-origin-terminator-row")
    let icon = document.createElement(cstring"span")
    icon.setAttribute(cstring"class",
                      cstring(iconClassForTerminator(chain.terminator.kind)))
    termLi.appendChild(icon)
    let exprNode = document.createElement(cstring"span")
    exprNode.innerText = cstring(chain.terminator.expression)
    termLi.appendChild(exprNode)
    ol.appendChild(termLi)

    let footer = document.createElement(cstring"footer")
    let pinBtn = document.createElement(cstring"button")
    pinBtn.innerText = cstring"Pin to scratchpad"
    let pinHandler = proc(_: Event) =
      vm.onPinChain(chain)
    pinBtn.addEventListener(cstring"click", pinHandler)
    footer.appendChild(pinBtn)
    section.appendChild(footer)
