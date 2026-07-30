## views/isonim_scratchpad_view.nim
##
## IsoNim DOM-rendering view for the Scratchpad panel.
##
## Renders a live, reactive DOM tree driven by ``ScratchpadVM`` signals.
## Replaces the legacy Karax ``method render`` in
## ``frontend/ui/scratchpad.nim`` (the IsoNim view is the single source
## of truth for the panel's DOM).
##
## The legacy panel renders each value via the rich
## ``ValueComponent`` Karax sub-tree (expandable trees, charts, inline /
## verbose toggles).  ``ScratchpadValueEntry`` only carries a flattened
## value preview, so this view restores the stable outer ``value-*`` DOM
## that the legacy ``ValueComponent`` produced for collapsed atom/error
## values.  True expandable children and history charts still require
## the original backend ``Value`` tree and remain outside this VM shape.
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure mirroring the legacy ``componentContainerClass(
## "active-state")`` layout::
##
##   div#scratchpadComponent-0.component-container.active-state
##     div.value-components-container
##       div.scratchpad-value-view (one per entry)
##         button#close-element.ct-button-image-sm-secondary.ct-mr-2
##         div.value-expanded.border-value-0.value-expanded-name
##           div.value-expanded-atom-parent
##             div.value-name-container
##               span.value-name
##             div > span.value-view > div/span.value-expanded-text
##       div.empty-overlay
##         text "You can add values from other components by ..."
##
## Reactive surface:
## - One ``createRenderEffect`` rebuilds the value list whenever
##   ``entries`` changes and toggles the empty-state placeholder.
##   Mirrors the trace_log / request_panel pattern (DSL builds the
##   static shell, imperative renderer ops inside the effect handle
##   the row list).

import std/sets
import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/scratchpad_vm
import ../viewmodels/origin_chain_types

# Re-export so callers can `import isonim_scratchpad_view` and reach
# the helpers exercised by the headless tests.
export origin_chain_types

const ScratchpadContainerClass* = "component-container active-state"
  ## Verbatim string the legacy ``componentContainerClass(
  ## "active-state")`` template produced.  Exposed for headless tests
  ## so they assert against the exact class string.

const ScratchpadEmptyStateText* =
  "You can add values from other components by right clicking on them " &
  "and then click on 'Add value to scratchpad'."
  ## Placeholder copy rendered when no values have been pinned yet.
  ## Verbatim from the legacy ``method render`` so the wording the
  ## user sees stays unchanged.

const CloseButtonClass* =
  "ct-button-image-sm-secondary ct-mr-2 scratchpad-value-close"
  ## Class string the legacy panel attached to the per-row close
  ## button, plus the existing page-object hook for the clickable icon.
  ## Kept as a constant so the view + tests share one source.

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

type
  ScratchpadRowView* = object
    expression*: string
    path*: string
    valueText*: string
    typeName*: string
    isExpanded*: bool
    hasChildren*: bool
    depth*: int
    isError*: bool
    isLiteral*: bool
    entryIndex*: int

proc flattenScratchpadEntry(
    name: string;
    valueText: string;
    typeName: string;
    isError: bool;
    isLiteral: bool;
    hasChildren: bool;
    children: seq[Variable];
    expandedPaths: HashSet[string];
    depth: int;
    path: string;
    entryIndex: int;
    result: var seq[ScratchpadRowView]) =

  let expanded = path in expandedPaths
  result.add(ScratchpadRowView(
    expression: name,
    path: path,
    valueText: valueText,
    typeName: typeName,
    isExpanded: expanded,
    hasChildren: hasChildren,
    depth: depth,
    isError: isError,
    isLiteral: isLiteral,
    entryIndex: entryIndex
  ))

  if expanded and hasChildren:
    for child in children:
      let childPath = path & "." & child.name
      flattenScratchpadEntry(
        child.name,
        child.value,
        child.typeName,
        isError = false,
        isLiteral = false,
        child.hasChildren,
        child.children,
        expandedPaths,
        depth + 1,
        childPath,
        entryIndex,
        result
      )

proc getScratchpadRowViews*(vm: ScratchpadVM): seq[ScratchpadRowView] =
  let entries = vm.entries.val
  let expandedPaths = vm.expandedPaths.val
  for i, entry in entries:
    flattenScratchpadEntry(
      entry.expression,
      entry.valueText,
      entry.typeName,
      entry.isError,
      entry.isLiteral,
      entry.hasChildren,
      entry.children,
      expandedPaths,
      depth = 0,
      path = $i,
      entryIndex = i,
      result
    )

proc rowClass*(isError: bool): string =
  if isError:
    "scratchpad-value-view scratchpad-value-error"
  else:
    "scratchpad-value-view"

proc rowClass*(row: ScratchpadRowView): string =
  rowClass(row.isError)

proc cellText*(entry: ScratchpadValueEntry): string =
  if entry.isError:
    "<error: " & entry.valueText & ">"
  else:
    entry.valueText

proc cellText*(row: ScratchpadRowView): string =
  if row.isError:
    "<error: " & row.valueText & ">"
  else:
    row.valueText

proc valueExpandedClass*(): string =
  "value-expanded border-value-0 value-expanded-name"

proc valueExpandedClass*(row: ScratchpadRowView): string =
  "value-expanded border-value-" & $row.depth & " value-expanded-name"

proc rowPaddingLeft*(row: ScratchpadRowView; pxPerLevel: int): string =
  let depth = row.depth
  if depth > 0: $(depth * pxPerLevel) & "px" else: "0px"

proc valueAtomClass*(entry: ScratchpadValueEntry; index: int): string =
  let parity = if index mod 2 == 0: "atom-even" else: "atom-odd"
  if entry.isError:
    "value-error value-expanded-text"
  else:
    "value-expanded-atom atom-string " & parity & " value-expanded-default"

proc valueAtomClass*(row: ScratchpadRowView; index: int): string =
  let parity = if index mod 2 == 0: "atom-even" else: "atom-odd"
  if row.isError:
    "value-error value-expanded-text"
  else:
    "value-expanded-atom atom-string " & parity & " value-expanded-default"

proc caretClass*(row: ScratchpadRowView): string =
  if row.isExpanded: "caret-expand" else: "caret-collapse"

proc atomOrCompoundClass*(row: ScratchpadRowView): string =
  if row.hasChildren and row.isExpanded:
    "value-expanded-compound-parent"
  else:
    "value-expanded-atom-parent"

proc onCloseClick(vm: ScratchpadVM; index: int): proc() =
  let captured = index
  result = proc() = vm.removeValue(captured)

proc onToggleExpand(vm: ScratchpadVM; path: string): proc() =
  let captured = path
  result = proc() = vm.toggleExpand(captured)

# ---------------------------------------------------------------------------
# Origin-chain entry rendering (M4 deliverable §3.5 + spec §8.1
# "Scratchpad data model (new entry kind)") — folded card per chain.
# ---------------------------------------------------------------------------

const ScratchpadChainRowClass* = "scratchpad-chain-view"
  ## Outer wrapper class for a pinned-chain card.  Distinct from the
  ## value-row class so CSS can give the card its own visual
  ## treatment (spec §8.1 calls for a folded card with side-by-side
  ## chain-diff support).
const ScratchpadChainTerminatorClass* = "scratchpad-chain-terminator"
const ScratchpadChainHopSummaryClass* = "scratchpad-chain-hop-summary"
const ScratchpadChainCloseClass* =
  "ct-button-image-sm-secondary ct-mr-2 scratchpad-chain-close"

proc chainCardLabel*(entry: ScratchpadChainEntry): string =
  ## Heading text for a chain card: `<queryVariable>: <hopCount> hops →
  ## <terminator.expression>`.  Exposed as a pure helper so headless
  ## tests can assert against the exact string the view emits.
  let hops = entry.chain.hops.len
  let suffix =
    if entry.chain.terminator.expression.len > 0:
      " → " & entry.chain.terminator.expression
    else: ""
  entry.chain.queryVariable & ": " & $hops & " hops" & suffix

proc chainTerminatorIconClass*(entry: ScratchpadChainEntry): string =
  ## Convenience accessor used by the view + tests.  Returns the same
  ## CSS class the inline badge / side-panel terminator row attach so
  ## the chain card visually identifies the terminator kind.
  iconClassForTerminator(entry.chain.terminator.kind)

proc onRemoveChainClick(vm: ScratchpadVM; index: int): proc() =
  let captured = index
  result = proc() = vm.removeChain(captured)

# ---------------------------------------------------------------------------
# Side-by-side chain diff (M4 deliverable §3.5 "side-by-side chain-diff
# support" + spec §8.1 "Scratchpad data model").  Compares two chains
# hop-by-hop and emits a diff row pairing each chain's hop, marking
# mismatches so CSS can highlight them.  The diff algorithm is
# intentionally naive — index-aligned comparison covers the common
# "two recordings of the same code path with one altered intermediate"
# scenario the spec calls out.  A future M5 pass can replace this with
# a real LCS-style diff if telemetry shows the index-aligned variant
# misses real-world cases.
# ---------------------------------------------------------------------------

const
  ScratchpadChainDiffClass* = "scratchpad-chain-diff"
  ScratchpadChainDiffColumnLeftClass* = "scratchpad-chain-diff-left"
  ScratchpadChainDiffColumnRightClass* = "scratchpad-chain-diff-right"
  ScratchpadChainDiffRowClass* = "scratchpad-chain-diff-row"
  ScratchpadChainDiffChangedClass* = "scratchpad-chain-diff-changed"
  ScratchpadChainDiffEmptyHopText* = "—"
    ## Placeholder text rendered in the column whose chain has no hop
    ## at the diff row's index (i.e. the chains have unequal lengths).

type
  ChainDiffRow* = object
    ## One row in the side-by-side diff.  ``leftHop`` /``rightHop`` are
    ## the textual previews of each chain's hop at this index — the
    ## sentinel ``ScratchpadChainDiffEmptyHopText`` marks a missing
    ## hop.  ``changed`` is true when the rendered previews differ.
    leftHop*: string
    rightHop*: string
    changed*: bool

proc chainHopSummaryText*(hop: OriginHop): string =
  ## Textual hop preview used inside the diff cell — kept symmetric
  ## with the folded-card "first/last" preview so the diff stays
  ## readable next to the folded summary.
  hop.targetExpr & " = " & hop.sourceExpr

proc chainDiffRows*(left, right: ScratchpadChainEntry): seq[ChainDiffRow] =
  ## Index-align ``left`` and ``right`` and emit one diff row per hop
  ## index.  Mismatched hops are flagged with ``changed = true``; a
  ## missing hop (one chain shorter than the other) is rendered with
  ## the placeholder ``—`` text in the empty column and is also
  ## flagged as changed.  The terminator row is always appended so
  ## callers can see where each chain bottomed out.
  let maxHops = max(left.chain.hops.len, right.chain.hops.len)
  for i in 0 ..< maxHops:
    let leftText =
      if i < left.chain.hops.len: chainHopSummaryText(left.chain.hops[i])
      else: ScratchpadChainDiffEmptyHopText
    let rightText =
      if i < right.chain.hops.len: chainHopSummaryText(right.chain.hops[i])
      else: ScratchpadChainDiffEmptyHopText
    result.add(ChainDiffRow(
      leftHop: leftText,
      rightHop: rightText,
      changed: leftText != rightText,
    ))
  # Terminator row.  Always rendered so the user can see the final
  # classification side-by-side.  Marked as ``changed`` when the
  # terminator expressions differ.
  let leftTerm = left.chain.terminator.expression
  let rightTerm = right.chain.terminator.expression
  result.add(ChainDiffRow(
    leftHop: "[terminator] " & leftTerm,
    rightHop: "[terminator] " & rightTerm,
    changed: leftTerm != rightTerm,
  ))

proc diffRowClass*(row: ChainDiffRow): string =
  ## CSS class for a single diff row — adds the ``changed`` modifier
  ## when the two hops differ so CSS can highlight the row.
  if row.changed: ScratchpadChainDiffRowClass & " " &
    ScratchpadChainDiffChangedClass
  else: ScratchpadChainDiffRowClass

proc diffHeading*(left, right: ScratchpadChainEntry): string =
  ## One-line caption rendered above the diff table so the user knows
  ## which two chains are being compared.
  left.chain.queryVariable & " ↔ " & right.chain.queryVariable

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderRowMock(r: MockRenderer; vm: ScratchpadVM;
                   row: ScratchpadRowView; index: int): MockNode =
  ## Render a single scratchpad row.  The close button maps onto
  ## ``vm.removeValue``; the value body keeps the collapsed legacy
  ## ``ValueComponent`` class surface around the flattened preview.
  let onClick = onCloseClick(vm, row.entryIndex)
  let onToggle = onToggleExpand(vm, row.path)
  let cell = cellText(row)
  let itemRow = ui(r):
    tdiv(class = rowClass(row)):
      if row.depth == 0:
        button(class = CloseButtonClass, id = "close-element",
               onclick = onClick):
          discard
      tdiv(class = valueExpandedClass(row),
           padding_left = rowPaddingLeft(row, 16)):
        tdiv(class = atomOrCompoundClass(row)):
          tdiv(class = "value-name-container"):
            if row.hasChildren:
              span(class = "value-expand-button", onclick = onToggle):
                tdiv(class = caretClass(row)):
                  discard
            span(class = "value-name"):
              text row.expression & (if row.depth == 0: ": " else: "")
          tdiv:
            span(class = "value-view"):
              if row.isError:
                tdiv(class = valueAtomClass(row, index)):
                  text cell
              else:
                tdiv(class = valueAtomClass(row, index)):
                  span(class = "value-expanded-text"):
                    text cell
                  if row.typeName.len > 0:
                    span(class = "value-type"):
                      text row.typeName
  itemRow

proc renderChainDiffMock(r: MockRenderer; left, right: ScratchpadChainEntry;
                         pairIndex: int): MockNode =
  ## Render one side-by-side diff between ``left`` and ``right``.
  ## ``pairIndex`` is recorded as the ``data-pair-index`` attribute so
  ## the headless tests can identify the i-th diff block deterministically.
  ##
  ## The ``rows`` seq is indexed (rather than iterated with ``for row in
  ## rows``) so the DSL closure captures the index — capturing the lent
  ## row directly would violate memory safety on the native test backend.
  let rows = chainDiffRows(left, right)
  let dataPair = $pairIndex
  let card = ui(r):
    tdiv(class = ScratchpadChainDiffClass,
         `data-pair-index` = dataPair):
      tdiv(class = "scratchpad-chain-diff-heading"):
        text diffHeading(left, right)
      tdiv(class = "scratchpad-chain-diff-table"):
        tdiv(class = ScratchpadChainDiffColumnLeftClass):
          for idx in 0 ..< rows.len:
            tdiv(class = diffRowClass(rows[idx])):
              text rows[idx].leftHop
        tdiv(class = ScratchpadChainDiffColumnRightClass):
          for idx in 0 ..< rows.len:
            tdiv(class = diffRowClass(rows[idx])):
              text rows[idx].rightHop
  card

proc renderChainRowMock(r: MockRenderer; vm: ScratchpadVM;
                        entry: ScratchpadChainEntry; index: int): MockNode =
  ## Folded chain card.  Layout (spec §8.1):
  ##   div.scratchpad-chain-view
  ##     button.scratchpad-chain-close
  ##     div.scratchpad-chain-terminator
  ##       span.{terminator-icon-class}
  ##       span : "{queryVariable}: N hops → {terminator.expression}"
  ##     div.scratchpad-chain-hop-summary  (one line per first/last hop)
  let onClick = onRemoveChainClick(vm, index)
  let card = ui(r):
    tdiv(class = ScratchpadChainRowClass):
      button(class = ScratchpadChainCloseClass, id = "chain-close-element",
             onclick = onClick):
        discard
      tdiv(class = ScratchpadChainTerminatorClass):
        span(class = chainTerminatorIconClass(entry)):
          discard
        span(class = "scratchpad-chain-label"):
          text chainCardLabel(entry)
      tdiv(class = ScratchpadChainHopSummaryClass):
        if entry.chain.hops.len > 0:
          let first = entry.chain.hops[0]
          span(class = "scratchpad-chain-hop"):
            text "first: " & first.targetExpr & " = " & first.sourceExpr
        if entry.chain.hops.len > 1:
          let last = entry.chain.hops[^1]
          span(class = "scratchpad-chain-hop"):
            text "last: " & last.targetExpr & " = " & last.sourceExpr
  card

proc renderScratchpadPanel*(r: MockRenderer; vm: ScratchpadVM): MockNode =
  ## Render the Scratchpad panel for the Mock renderer.
  ##
  ## The static shell (outer container + value-components-container +
  ## empty-overlay) is built once via the DSL.  A single outer
  ## ``createRenderEffect`` rebuilds the row list whenever ``entries``
  ## changes and also toggles the empty-state placeholder.
  var listContainer: MockNode
  var chainListContainer: MockNode
  var diffContainer: MockNode
  var emptyContainer: MockNode

  let panel = ui(r):
    tdiv(class = ScratchpadContainerClass, id = "scratchpadComponent-0"):
      tdiv(ref = listContainer, class = "value-components-container"):
        discard
      tdiv(ref = chainListContainer, class = "chain-components-container"):
        discard
      tdiv(ref = diffContainer, class = "chain-diffs-container"):
        discard
      tdiv(ref = emptyContainer, class = "empty-overlay"):
        text ScratchpadEmptyStateText

  createRenderEffect proc() =
    let rowViews = getScratchpadRowViews(vm)
    let chains = vm.chainEntries.val
    r.clearChildren(listContainer)
    for i, row in rowViews:
      let itemRow = renderRowMock(r, vm, row, i)
      r.appendChild(listContainer, itemRow)
    r.clearChildren(chainListContainer)
    for i, entry in chains:
      let card = renderChainRowMock(r, vm, entry, i)
      r.appendChild(chainListContainer, card)

    # M4 deliverable §3.5 + Gap 5: render side-by-side diffs between
    # every adjacent pair of pinned chains.  N chains produce N-1
    # diff blocks; chain[i] (left) vs chain[i+1] (right).  A single
    # chain produces no diff (nothing to compare against).
    r.clearChildren(diffContainer)
    if chains.len >= 2:
      for i in 0 ..< chains.len - 1:
        let diff = renderChainDiffMock(r, chains[i], chains[i + 1], i)
        r.appendChild(diffContainer, diff)

    # Toggle the empty-overlay via a class instead of remove/insert so
    # the held ``emptyContainer`` reference stays stable across
    # reactive updates (matches the trace_log / request_panel
    # placeholder pattern).  The overlay hides as soon as EITHER list
    # has rows so a pinned chain alone is enough to hide it.
    if rowViews.len == 0 and chains.len == 0:
      r.setAttribute(emptyContainer, "class", "empty-overlay")
    else:
      r.setAttribute(emptyContainer, "class", "empty-overlay hidden")

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc createWebElement(tag: string; cssClass: string = "";
                        elemId: string = ""): isonim_dom.Element =
    ## Helper: create a DOM element with optional class + id
    ## attributes.
    let n = isonim_dom.createElement(isonim_dom.document, cstring(tag))
    if cssClass.len > 0:
      isonim_dom.setAttribute(n, cstring"class", cstring(cssClass))
    if elemId.len > 0:
      isonim_dom.setAttribute(n, cstring"id", cstring(elemId))
    n

  proc appendWebText(node: isonim_dom.Element; textValue: string) =
    let t = isonim_dom.createTextNode(isonim_dom.document, cstring(textValue))
    isonim_dom.appendChild(isonim_dom.Node(node), t)

  proc clearWebChildren(node: isonim_dom.Element) =
    let asNode = isonim_dom.Node(node)
    while not isonim_dom.isNodeNil(asNode.firstChild):
      discard isonim_dom.removeChild(asNode, asNode.firstChild)

  proc renderRowWeb(vm: ScratchpadVM; row: ScratchpadRowView;
                    index: int): isonim_dom.Element =
    ## Build a scratchpad row in the real DOM.  Same shape as the Mock
    ## variant; click handler is wired imperatively via
    ## ``addEventListener``.
    let elementRow = createWebElement("div", rowClass(row))

    if row.depth == 0:
      let closeBtn = createWebElement("button", CloseButtonClass,
                                      "close-element")
      let onClick = onCloseClick(vm, row.entryIndex)
      isonim_dom.addEventListener(isonim_dom.Node(closeBtn), cstring"click",
                                  proc(ev: isonim_dom.Event) = onClick())
      isonim_dom.appendChild(isonim_dom.Node(elementRow), isonim_dom.Node(closeBtn))

    let valueRoot = createWebElement("div", valueExpandedClass(row))
    if row.depth > 0:
      isonim_dom.setAttribute(valueRoot, cstring"style", cstring("padding-left: " & rowPaddingLeft(row, 16)))

    let parent = createWebElement("div", atomOrCompoundClass(row))
    let nameContainer = createWebElement("div", "value-name-container")
    if row.hasChildren:
      let expandBtn = createWebElement("span", "value-expand-button")
      let caret = createWebElement("div", caretClass(row))
      let onToggle = onToggleExpand(vm, row.path)
      isonim_dom.addEventListener(isonim_dom.Node(expandBtn), cstring"click",
                                  proc(ev: isonim_dom.Event) = onToggle())
      isonim_dom.appendChild(isonim_dom.Node(expandBtn), isonim_dom.Node(caret))
      isonim_dom.appendChild(isonim_dom.Node(nameContainer), isonim_dom.Node(expandBtn))

    let nameSpan = createWebElement("span", "value-name")
    appendWebText(nameSpan, row.expression & (if row.depth == 0: ": " else: ""))
    isonim_dom.appendChild(isonim_dom.Node(nameContainer),
                           isonim_dom.Node(nameSpan))
    isonim_dom.appendChild(isonim_dom.Node(parent),
                           isonim_dom.Node(nameContainer))

    let valueLine = createWebElement("div")
    let valueView = createWebElement("span", "value-view")
    let valueAtom = createWebElement("div", valueAtomClass(row, index))
    if row.isError:
      appendWebText(valueAtom, cellText(row))
    else:
      let valueText = createWebElement("span", "value-expanded-text")
      appendWebText(valueText, cellText(row))
      isonim_dom.appendChild(isonim_dom.Node(valueAtom),
                             isonim_dom.Node(valueText))
      if row.typeName.len > 0:
        let typeSpan = createWebElement("span", "value-type")
        appendWebText(typeSpan, row.typeName)
        isonim_dom.appendChild(isonim_dom.Node(valueAtom),
                               isonim_dom.Node(typeSpan))

    isonim_dom.appendChild(isonim_dom.Node(valueView),
                           isonim_dom.Node(valueAtom))
    isonim_dom.appendChild(isonim_dom.Node(valueLine),
                           isonim_dom.Node(valueView))
    isonim_dom.appendChild(isonim_dom.Node(parent),
                           isonim_dom.Node(valueLine))
    isonim_dom.appendChild(isonim_dom.Node(valueRoot),
                           isonim_dom.Node(parent))
    isonim_dom.appendChild(isonim_dom.Node(elementRow), isonim_dom.Node(valueRoot))
    elementRow

  proc renderChainDiffWeb(left, right: ScratchpadChainEntry;
                          pairIndex: int): isonim_dom.Element =
    ## Web-DOM counterpart of ``renderChainDiffMock``.  Same shape.
    let rows = chainDiffRows(left, right)
    let card = createWebElement("div", ScratchpadChainDiffClass)
    isonim_dom.setAttribute(card, cstring"data-pair-index",
                            cstring($pairIndex))
    let heading = createWebElement("div", "scratchpad-chain-diff-heading")
    appendWebText(heading, diffHeading(left, right))
    isonim_dom.appendChild(isonim_dom.Node(card), isonim_dom.Node(heading))

    let table = createWebElement("div", "scratchpad-chain-diff-table")
    let leftCol = createWebElement("div", ScratchpadChainDiffColumnLeftClass)
    let rightCol = createWebElement("div", ScratchpadChainDiffColumnRightClass)
    for row in rows:
      let leftRow = createWebElement("div", diffRowClass(row))
      appendWebText(leftRow, row.leftHop)
      isonim_dom.appendChild(isonim_dom.Node(leftCol),
                             isonim_dom.Node(leftRow))
      let rightRow = createWebElement("div", diffRowClass(row))
      appendWebText(rightRow, row.rightHop)
      isonim_dom.appendChild(isonim_dom.Node(rightCol),
                             isonim_dom.Node(rightRow))
    isonim_dom.appendChild(isonim_dom.Node(table), isonim_dom.Node(leftCol))
    isonim_dom.appendChild(isonim_dom.Node(table), isonim_dom.Node(rightCol))
    isonim_dom.appendChild(isonim_dom.Node(card), isonim_dom.Node(table))
    card

  proc renderChainRowWeb(vm: ScratchpadVM; entry: ScratchpadChainEntry;
                         index: int): isonim_dom.Element =
    ## DOM version of `renderChainRowMock`.  Same shape; close handler
    ## wired via `addEventListener`.
    let card = createWebElement("div", ScratchpadChainRowClass)

    let closeBtn = createWebElement("button", ScratchpadChainCloseClass,
                                    "chain-close-element")
    let onClick = onRemoveChainClick(vm, index)
    isonim_dom.addEventListener(isonim_dom.Node(closeBtn), cstring"click",
                                proc(ev: isonim_dom.Event) = onClick())
    isonim_dom.appendChild(isonim_dom.Node(card), isonim_dom.Node(closeBtn))

    let term = createWebElement("div", ScratchpadChainTerminatorClass)
    let icon = createWebElement("span", chainTerminatorIconClass(entry))
    isonim_dom.appendChild(isonim_dom.Node(term), isonim_dom.Node(icon))
    let label = createWebElement("span", "scratchpad-chain-label")
    appendWebText(label, chainCardLabel(entry))
    isonim_dom.appendChild(isonim_dom.Node(term), isonim_dom.Node(label))
    isonim_dom.appendChild(isonim_dom.Node(card), isonim_dom.Node(term))

    let summary = createWebElement("div", ScratchpadChainHopSummaryClass)
    if entry.chain.hops.len > 0:
      let first = entry.chain.hops[0]
      let firstSpan = createWebElement("span", "scratchpad-chain-hop")
      appendWebText(firstSpan,
        "first: " & first.targetExpr & " = " & first.sourceExpr)
      isonim_dom.appendChild(isonim_dom.Node(summary),
                             isonim_dom.Node(firstSpan))
    if entry.chain.hops.len > 1:
      let last = entry.chain.hops[^1]
      let lastSpan = createWebElement("span", "scratchpad-chain-hop")
      appendWebText(lastSpan,
        "last: " & last.targetExpr & " = " & last.sourceExpr)
      isonim_dom.appendChild(isonim_dom.Node(summary),
                             isonim_dom.Node(lastSpan))
    isonim_dom.appendChild(isonim_dom.Node(card), isonim_dom.Node(summary))
    card

  proc renderScratchpadPanel*(r: WebRenderer;
                              vm: ScratchpadVM): isonim_dom.Element =
    ## Render the Scratchpad panel for the real DOM.  Same dispatch
    ## shape as the Mock variant — outer wrapper plus a render-effect
    ## that rebuilds the list and toggles the empty-state placeholder.
    var listContainer: isonim_dom.Element
    var chainListContainer: isonim_dom.Element
    var diffContainer: isonim_dom.Element
    var emptyContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = ScratchpadContainerClass, id = "scratchpadComponent-0"):
        tdiv(ref = listContainer, class = "value-components-container"):
          discard
        tdiv(ref = chainListContainer, class = "chain-components-container"):
          discard
        tdiv(ref = diffContainer, class = "chain-diffs-container"):
          discard
        tdiv(ref = emptyContainer, class = "empty-overlay"):
          text ScratchpadEmptyStateText

    createRenderEffect proc() =
      let rowViews = getScratchpadRowViews(vm)
      let chains = vm.chainEntries.val
      clearWebChildren(listContainer)
      for i, row in rowViews:
        let itemRow = renderRowWeb(vm, row, i)
        isonim_dom.appendChild(isonim_dom.Node(listContainer),
                               isonim_dom.Node(itemRow))
      clearWebChildren(chainListContainer)
      for i, entry in chains:
        let card = renderChainRowWeb(vm, entry, i)
        isonim_dom.appendChild(isonim_dom.Node(chainListContainer),
                               isonim_dom.Node(card))

      clearWebChildren(diffContainer)
      if chains.len >= 2:
        for i in 0 ..< chains.len - 1:
          let diff = renderChainDiffWeb(chains[i], chains[i + 1], i)
          isonim_dom.appendChild(isonim_dom.Node(diffContainer),
                                 isonim_dom.Node(diff))

      if rowViews.len == 0 and chains.len == 0:
        isonim_dom.setAttribute(emptyContainer, cstring"class",
                                cstring"empty-overlay")
      else:
        isonim_dom.setAttribute(emptyContainer, cstring"class",
                                cstring"empty-overlay hidden")

    panel

  proc mountIsoNimScratchpadPanel*(container: isonim_dom.Element;
                                   vm: ScratchpadVM) =
    ## Mount the IsoNim Scratchpad panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderScratchpadPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
