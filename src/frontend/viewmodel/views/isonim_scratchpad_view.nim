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

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/scratchpad_vm

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

proc rowClass*(isError: bool): string =
  ## ``.scratchpad-value-view`` row modifier — the legacy CSS expects
  ## the bare class plus an ``error-trace`` modifier when the captured
  ## value was a backend error.  Mirrors the
  ## ``error-trace`` span the legacy ``localsToText`` emitted (see
  ## trace_log §1.69 for the parallel rule).
  if isError:
    "scratchpad-value-view scratchpad-value-error"
  else:
    "scratchpad-value-view"

proc cellText*(entry: ScratchpadValueEntry): string =
  ## Single-line preview text for tests and literal fallback display.
  if entry.isError:
    "<error: " & entry.valueText & ">"
  else:
    entry.valueText

proc valueExpandedClass*(): string =
  ## Root class restored from the legacy ValueComponent collapsed row.
  ## The Scratchpad VM has no depth/type tree, so every flattened entry
  ## renders at depth 0.
  "value-expanded border-value-0 value-expanded-name"

proc valueAtomClass*(entry: ScratchpadValueEntry; index: int): string =
  ## Atom row class restored from ``ValueComponent.atomValueView``.  The
  ## legacy component alternated atom-even / atom-odd as rows were
  ## rendered; keep that visual rhythm for multiple pinned values.
  let parity = if index mod 2 == 0: "atom-even" else: "atom-odd"
  if entry.isError:
    "value-error value-expanded-text"
  else:
    "value-expanded-atom atom-string " & parity & " value-expanded-default"

proc onCloseClick(vm: ScratchpadVM; index: int): proc() =
  ## Closure factory that captures the row's index so each row's
  ## close-button handler refers to its own value.  Without the
  ## per-row capture every row's closure would observe the loop
  ## variable's final value (same closure-capture concern as the
  ## trace_log / request_panel views).
  let captured = index
  result = proc() = vm.removeValue(captured)

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderRowMock(r: MockRenderer; vm: ScratchpadVM;
                   entry: ScratchpadValueEntry; index: int): MockNode =
  ## Render a single scratchpad row.  The close button maps onto
  ## ``vm.removeValue``; the value body keeps the collapsed legacy
  ## ``ValueComponent`` class surface around the flattened preview.
  let onClick = onCloseClick(vm, index)
  let cell = cellText(entry)
  let row = ui(r):
    tdiv(class = rowClass(entry.isError)):
      button(class = CloseButtonClass, id = "close-element",
             onclick = onClick):
        discard
      tdiv(class = valueExpandedClass()):
        tdiv(class = "value-expanded-atom-parent"):
          tdiv(class = "value-name-container"):
            span(class = "value-name"):
              text entry.expression & ": "
          tdiv:
            span(class = "value-view"):
              if entry.isError:
                tdiv(class = valueAtomClass(entry, index)):
                  text cell
              else:
                tdiv(class = valueAtomClass(entry, index)):
                  span(class = "value-expanded-text"):
                    text cell
  row

proc renderScratchpadPanel*(r: MockRenderer; vm: ScratchpadVM): MockNode =
  ## Render the Scratchpad panel for the Mock renderer.
  ##
  ## The static shell (outer container + value-components-container +
  ## empty-overlay) is built once via the DSL.  A single outer
  ## ``createRenderEffect`` rebuilds the row list whenever ``entries``
  ## changes and also toggles the empty-state placeholder.
  var listContainer: MockNode
  var emptyContainer: MockNode

  let panel = ui(r):
    tdiv(class = ScratchpadContainerClass, id = "scratchpadComponent-0"):
      tdiv(ref = listContainer, class = "value-components-container"):
        discard
      tdiv(ref = emptyContainer, class = "empty-overlay"):
        text ScratchpadEmptyStateText

  createRenderEffect proc() =
    let entries = vm.entries.val
    r.clearChildren(listContainer)
    for i, entry in entries:
      let row = renderRowMock(r, vm, entry, i)
      r.appendChild(listContainer, row)

    # Toggle the empty-overlay via a class instead of remove/insert so
    # the held ``emptyContainer`` reference stays stable across
    # reactive updates (matches the trace_log / request_panel
    # placeholder pattern).
    if entries.len == 0:
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

  proc renderRowWeb(vm: ScratchpadVM; entry: ScratchpadValueEntry;
                    index: int): isonim_dom.Element =
    ## Build a scratchpad row in the real DOM.  Same shape as the Mock
    ## variant; click handler is wired imperatively via
    ## ``addEventListener``.
    let row = createWebElement("div", rowClass(entry.isError))

    let closeBtn = createWebElement("button", CloseButtonClass,
                                    "close-element")
    let onClick = onCloseClick(vm, index)
    isonim_dom.addEventListener(isonim_dom.Node(closeBtn), cstring"click",
                                proc(ev: isonim_dom.Event) = onClick())
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(closeBtn))

    let valueRoot = createWebElement("div", valueExpandedClass())
    let parent = createWebElement("div", "value-expanded-atom-parent")
    let nameContainer = createWebElement("div", "value-name-container")
    let nameSpan = createWebElement("span", "value-name")
    appendWebText(nameSpan, entry.expression & ": ")
    isonim_dom.appendChild(isonim_dom.Node(nameContainer),
                           isonim_dom.Node(nameSpan))
    isonim_dom.appendChild(isonim_dom.Node(parent),
                           isonim_dom.Node(nameContainer))

    let valueLine = createWebElement("div")
    let valueView = createWebElement("span", "value-view")
    let valueAtom = createWebElement("div", valueAtomClass(entry, index))
    if entry.isError:
      appendWebText(valueAtom, cellText(entry))
    else:
      let valueText = createWebElement("span", "value-expanded-text")
      appendWebText(valueText, cellText(entry))
      isonim_dom.appendChild(isonim_dom.Node(valueAtom),
                             isonim_dom.Node(valueText))
    isonim_dom.appendChild(isonim_dom.Node(valueView),
                           isonim_dom.Node(valueAtom))
    isonim_dom.appendChild(isonim_dom.Node(valueLine),
                           isonim_dom.Node(valueView))
    isonim_dom.appendChild(isonim_dom.Node(parent),
                           isonim_dom.Node(valueLine))
    isonim_dom.appendChild(isonim_dom.Node(valueRoot),
                           isonim_dom.Node(parent))
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(valueRoot))
    row

  proc renderScratchpadPanel*(r: WebRenderer;
                              vm: ScratchpadVM): isonim_dom.Element =
    ## Render the Scratchpad panel for the real DOM.  Same dispatch
    ## shape as the Mock variant — outer wrapper plus a render-effect
    ## that rebuilds the list and toggles the empty-state placeholder.
    var listContainer: isonim_dom.Element
    var emptyContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = ScratchpadContainerClass, id = "scratchpadComponent-0"):
        tdiv(ref = listContainer, class = "value-components-container"):
          discard
        tdiv(ref = emptyContainer, class = "empty-overlay"):
          text ScratchpadEmptyStateText

    createRenderEffect proc() =
      let entries = vm.entries.val
      clearWebChildren(listContainer)
      for i, entry in entries:
        let row = renderRowWeb(vm, entry, i)
        isonim_dom.appendChild(isonim_dom.Node(listContainer),
                               isonim_dom.Node(row))

      if entries.len == 0:
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
