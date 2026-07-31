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

type
  BreadcrumbChip* = object
    ## M29 §14.8 — pure-data descriptor for one breadcrumb chip
    ## rendered in the Origin Chain side panel's `<nav>` strip. Each
    ## `CrossProcessSpan` in the active chain becomes exactly one
    ## chip; clicking the chip flips the SessionVM's active
    ## recording and seeks the editor to the span's first hop.
    recordingId*: string
    role*: string
    label*: string
    hopIndex*: int
    isPlaceholder*: bool
      ## True when the span owns no hops of its own. The composer emits
      ## such a span when the walk asked a recording to continue and it
      ## had nothing to say — see the fixture's `ANSWERS.md`, "The
      ## trailing `frontend-js` span is the walk noticing that the
      ## WebAssembly frame was itself entered across the realm boundary
      ## and asking the JavaScript side to continue. It has nothing
      ## further to say". Such a chip names a real recording, so it is
      ## rendered, but it has no hop to seek to and is therefore inert.
      ## Tracked as M36b.

proc isPlaceholderSpan*(span: CrossProcessSpan): bool =
  ## Hop-range-only placeholder test: an inverted range.
  ##
  ## This is NOT the shape the db-backend composer emits. See
  ## `cross_process_origin.rs::compose_cross_process_chain` step 4: a
  ## sibling that contributed no hops gets its range deliberately
  ## *collapsed* to `first == last == chain.hops.len()` rather than
  ## left inverted, "because any renderer that slices
  ## `hops[first..=last]` to draw the span would either panic or
  ## silently show the wrong hops". Detecting that shape needs the
  ## chain's hop count, so prefer the two-argument overload below;
  ## this one only guards against a future wire that does invert.
  span.firstHopIndex > span.lastHopIndex

proc isPlaceholderSpan*(chain: OriginChain; span: CrossProcessSpan): bool =
  ## A span that owns no hop of the chain, in either encoding the wire
  ## can carry: an inverted range, or — the shape the composer actually
  ## produces — a range starting one past the last hop.
  isPlaceholderSpan(span) or int(span.firstHopIndex) >= chain.hops.len

proc chainBreadcrumbChips*(chain: OriginChain): seq[BreadcrumbChip] =
  ## Derive one breadcrumb chip per `CrossProcessSpan` in
  ## `chain.crossProcessSpans`, in chain-traversal order (spec §14.8).
  ## The chip label uses the span's `role` field (e.g. `frontend-js`,
  ## `backend`); the `recordingId` is the fallback when `role` is
  ## empty so the chip still has a stable user-visible identity. The
  ## `hopIndex` cursor records the first hop owned by the span — that
  ## is the seek target the click handler dispatches.
  ##
  ## Returns an empty seq for single-process chains. The renderer
  ## falls back to the legacy `breadcrumbStack` strip in that case so
  ## pre-M29 single-recording flows keep their navigation UI.
  result = @[]
  for span in chain.crossProcessSpans:
    let label =
      if span.role.len > 0: span.role
      else: span.recordingId
    result.add(BreadcrumbChip(
      recordingId: span.recordingId,
      role: span.role,
      label: label,
      hopIndex: int(span.firstHopIndex),
      isPlaceholder: isPlaceholderSpan(chain, span),
    ))

proc substantiveBreadcrumbChips*(chips: openArray[BreadcrumbChip]): int =
  ## How many chips correspond to a recording the chain genuinely
  ## walked hops in. The user-visible claim "this value is explained by
  ## all three recordings" rests on this count, not on the raw chip
  ## count, which a zero-hop placeholder span would otherwise inflate.
  result = 0
  for chip in chips:
    if not chip.isPlaceholder:
      result += 1

proc isCrossProcessHop*(hop: OriginHop): bool =
  ## M29 §14.8 — a hop is "cross-process" when the composer attached a
  ## `CorrelationTransition` to it, i.e. the walk left the recording it
  ## was in through a correlation-marker boundary at this hop. Every
  ## other hop stays inside its recording.
  hop.correlationTransition.isSome

proc crossProcessBadgeLabel*(hop: OriginHop): string =
  ## Short badge text for a cross-process hop: the boundary the chain
  ## crossed. Falls back to the direction, then to a generic label, so
  ## the badge never renders empty on a partially-populated transition.
  if hop.correlationTransition.isNone:
    return ""
  let t = hop.correlationTransition.get
  if t.boundaryId.len > 0:
    return t.boundaryId
  if t.direction.len > 0:
    return t.direction
  "cross-process"

proc crossProcessBadgeTitle*(hop: OriginHop): string =
  ## Hover text spelling out both halves of the crossing: which
  ## boundary was walked and which recording the chain continues in.
  if hop.correlationTransition.isNone:
    return ""
  let t = hop.correlationTransition.get
  var parts = "Crosses the " & crossProcessBadgeLabel(hop) & " boundary"
  if t.correlatedRecordingId.len > 0:
    parts &= " into recording " & t.correlatedRecordingId
  if t.matchKeyValue.len > 0:
    parts &= " (key " & t.matchKeyValue & ")"
  parts

proc spanOwningHop*(chain: OriginChain; hopIndex: int):
    Option[CrossProcessSpan] =
  ## The `CrossProcessSpan` whose hop range contains `hopIndex`.
  ##
  ## Zero-hop spans — the composer emits one for a recording it asked
  ## to continue the walk in but which had nothing further to say — are
  ## skipped in both wire encodings (inverted range, or a range that
  ## starts one past the last hop); neither describes a real hop, and
  ## an empty range must never claim ownership of one.
  for span in chain.crossProcessSpans:
    if isPlaceholderSpan(chain, span):
      continue
    if hopIndex >= int(span.firstHopIndex) and
       hopIndex <= int(span.lastHopIndex):
      return some(span)
  none(CrossProcessSpan)

proc seekToHopInOwningProcess*(vm: OriginChainVM; chain: OriginChain;
                               hopIndex: int) =
  ## Spec §3.3 "Click a hop", extended for multi-process chains
  ## (§14.8). A chain that walked a recording boundary contains hops
  ## owned by recordings other than the active one; seeking to such a
  ## hop without first rotating the active recording would send the
  ## navigation to the wrong process. So: switch first (which re-points
  ## the host's request routing), then seek.
  if hopIndex < 0 or hopIndex >= chain.hops.len:
    return
  let span = spanOwningHop(chain, hopIndex)
  if span.isSome and span.get.recordingId.len > 0 and
     not vm.onSwitchProcessProc.isNil:
    vm.onSwitchProcessProc(span.get.recordingId)
  vm.onSeekToHop(chain.hops[hopIndex])

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

  # ---------------------------------------------------------------------
  # Per-row event handlers.
  #
  # These are built in dedicated procs on purpose. Building them inline
  # in the `for` loops below and relying on a `let` copy of the loop
  # variable does NOT give each iteration its own closure environment on
  # the JS backend: every handler ends up seeing the *last* iteration's
  # values. That is not hypothetical — it is why clicking any breadcrumb
  # chip used to switch to the chain's final span (the trailing zero-hop
  # `frontend-js` placeholder) instead of the chip the user clicked, and
  # then bail out of the seek because that span indexes no hop. A proc
  # call creates a real per-handler scope, so each closure keeps its own
  # values.
  # ---------------------------------------------------------------------

  proc breadcrumbChipHandler(vm: OriginChainVM;
                             chip: BreadcrumbChip): proc(ev: Event) =
    let recordingId = chip.recordingId
    let hopIndex = chip.hopIndex
    let isPlaceholder = chip.isPlaceholder
    result = proc(_: Event) =
      # A zero-hop span names a recording the walk reached but found
      # nothing in; there is no coordinate to jump to.
      if isPlaceholder:
        return
      let active = vm.activeChain.val
      if active.isNone:
        return
      for s in active.get.crossProcessSpans:
        if s.recordingId == recordingId and int(s.firstHopIndex) == hopIndex:
          vm.onSwitchToSpan(s)
          return

  proc hopSeekHandler(vm: OriginChainVM; index: int): proc(ev: Event) =
    let hopIndex = index
    result = proc(_: Event) =
      let active = vm.activeChain.val
      if active.isNone:
        return
      vm.seekToHopInOwningProcess(active.get, hopIndex)

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

    # Breadcrumb nav per spec §14.8: one chip per `CrossProcessSpan`
    # when the chain crosses processes. Single-process chains fall
    # back to the legacy `breadcrumbStack` strip so pre-§14.8 flows
    # keep their navigation UI.
    let nav = document.createElement(cstring"nav")
    nav.setAttribute(cstring"aria-label", cstring"Origin breadcrumbs")
    let chips = chainBreadcrumbChips(chain)
    if chips.len > 0:
      for chip in chips:
        let chipCopy = chip                  # capture by value for closure
        let crumb = document.createElement(cstring"button")
        if chipCopy.isPlaceholder:
          # Rendered, because the span names a recording the walk really
          # did reach; inert, because it owns no hop to seek to. Marked
          # so neither a user nor a test mistakes it for a walked span.
          crumb.setAttribute(
            cstring"class",
            cstring("breadcrumb-chip ct-origin-breadcrumb-chip " &
                    "ct-origin-breadcrumb-chip-placeholder"))
          crumb.setAttribute(cstring"data-placeholder", cstring"true")
          crumb.setAttribute(cstring"aria-disabled", cstring"true")
          crumb.setAttribute(
            cstring"title",
            cstring("The chain reached " & chipCopy.label &
                    " but found no further origin there"))
        else:
          crumb.setAttribute(cstring"class",
                             cstring"breadcrumb-chip ct-origin-breadcrumb-chip")
        crumb.setAttribute(cstring"data-recording-id",
                           cstring(chipCopy.recordingId))
        crumb.setAttribute(cstring"data-role", cstring(chipCopy.role))
        crumb.setAttribute(cstring"aria-label",
                           cstring("Switch to " & chipCopy.label))
        crumb.innerText = cstring(chipCopy.label)
        # The click handler re-derives the span at dispatch time so
        # the closure captures only plain-data values — cheaper on
        # Nim-on-JS than capturing the `CrossProcessSpan` object.
        crumb.addEventListener(cstring"click",
                               breadcrumbChipHandler(vm, chipCopy))
        nav.appendChild(crumb)
    else:
      for entry in vm.breadcrumbStack.val:
        let crumb = document.createElement(cstring"button")
        crumb.setAttribute(cstring"class",
                           cstring"breadcrumb-chip ct-origin-breadcrumb-entry")
        crumb.innerText = cstring(entry.variableName & "@" & $entry.stepId)
        nav.appendChild(crumb)
    section.appendChild(nav)

    let ol = document.createElement(cstring"ol")
    section.appendChild(ol)
    for i, hop in chain.hops:
      let li = document.createElement(cstring"li")
      li.setAttribute(cstring"aria-label", cstring(hopAriaLabel(hop, i)))
      # M42 §14.8 — "The Origin Chain Panel's hop rendering simply gains
      # a new badge shape for cross-process hops". A hop carrying a
      # populated `correlationTransition` is one the composer walked
      # across a recording boundary; the badge names the boundary and
      # the recording on the far side so the user can see *why* the
      # chain left the process they were looking at.
      let hopIndex = i
      if isCrossProcessHop(hop):
        li.setAttribute(cstring"class", cstring"ct-origin-hop ct-origin-hop-cross-process")
        let transition = hop.correlationTransition.get
        li.setAttribute(cstring"data-cross-process-boundary",
                        cstring(transition.boundaryId))
        li.setAttribute(cstring"data-cross-process-recording",
                        cstring(transition.correlatedRecordingId))
        let badge = document.createElement(cstring"span")
        badge.setAttribute(cstring"class", cstring"ct-origin-cross-process-badge")
        badge.setAttribute(cstring"title",
                           cstring(crossProcessBadgeTitle(hop)))
        badge.innerText = cstring(crossProcessBadgeLabel(hop))
        li.appendChild(badge)
      else:
        li.setAttribute(cstring"class", cstring"ct-origin-hop")
      let button = document.createElement(cstring"button")
      button.innerText = cstring(fmt"{hop.location.path}:{hop.location.line}")
      # Spec §3.3 "Click a hop" — seek the replay to the hop's step.
      # `seekToHopInOwningProcess` also rotates the active recording
      # when the hop lives in a sibling process, so a chain that walked
      # a boundary can be navigated back across it.
      button.addEventListener(cstring"click", hopSeekHandler(vm, hopIndex))
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
