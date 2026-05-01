## views/isonim_no_source_view.nim
##
## IsoNim DOM-rendering view for the "no source" placeholder panel.
##
## Renders a live, reactive DOM tree driven by ``NoSourceVM`` signals.
## Replaces the legacy Karax ``method render`` in
## ``frontend/ui/no_source.nim`` (the IsoNim view is the single source
## of truth for the panel's DOM).
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure, mirroring the legacy view's class hooks so any CSS
## styling and DOM-based tests keep working::
##
##   div.unknown-location
##     div.unknown-location-header           text "Whoops!"
##     div.unknown-location-content
##       div.unknown-border                  shown when message != ""
##         p.unknown-location-message        text vm.message
##       div.unknown-border
##         p   text "- Function: '<name>'"
##         p   text "- Path: '<path>'"       shown when path.len > 0
##         p   text "- Line: '<n>'"          shown when line >= 0
##       div.unknown-border                  shown when hasHistory and action != ""
##         p   text "We were in '<prev>' and ended up here ..."
##       div.unknown-border                  same gating as above
##         div.unknown-location-buttons
##           p   text "You can still use all of the actions ..."
##           button.jump-back-button         click → vm.jumpBack
##             text "Jump back"
##     p   text "Originating address: <hex>" shown when address.len > 0
##     p   text "Signal received: <signal>"  shown when stopSignalText != ""
##
## The panel deliberately omits the legacy assembly-instructions list
## (the ``unknown-location-asm`` block).  That sub-tree depends on a
## Karax-driven lifecycle (``getAsmCode`` async load + per-row
## highlight wired to the live debugger frame info) and is reachable
## today only via the same Karax fallback as ``method render``;
## migrating it is tracked separately in the handoff doc.
##
## Reactive surface:
## - ``message`` flips the existence of the first ``unknown-border``
##   block via a render-effect that adds/removes the message node.
## - ``location`` recomputes the function / path / line text inside
##   the second ``unknown-border``.
## - ``history`` toggles the optional history-context blocks (and
##   the Jump-back button) entirely.
## - ``originatingAddress`` and ``stopSignalText`` toggle their own
##   trailing ``<p>`` rows.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/no_source_vm

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc functionRowText(loc: NoSourceLocationInfo): string =
  ## "- Function: '<name>'" — emitted unconditionally to mirror the
  ## legacy view (which always printed the row, possibly with an
  ## empty function name).
  "- Function: '" & loc.functionName & "'"

proc pathRowText(loc: NoSourceLocationInfo): string =
  ## "- Path: '<path>'" — only used when ``loc.path`` is non-empty
  ## (matching the legacy ``NO_PATH = ""`` guard).
  "- Path: '" & loc.path & "'"

proc lineRowText(loc: NoSourceLocationInfo): string =
  ## "- Line: '<n>'" — only used when ``loc.line >= 0``
  ## (matching the legacy ``NO_CODE = -1`` guard).
  "- Line: '" & $loc.line & "'"

proc historyContextText(history: NoSourceHistoryInfo): string =
  ## "We were in '<prev>' and ended up here because of an operation:
  ## '<action>'" — same wording the legacy view used.
  "We were in '" & history.previousPath &
    "' and ended up here because of an operation: '" & history.action & "'"

proc originatingAddressText(address: string): string =
  ## "Originating address: <hex>" — the legacy view formatted the
  ## ``Instructions.address`` int as ``0x{toHex(address)}`` in Nim
  ## before rendering; the VM caller does that conversion so the view
  ## just emits the prepared string.
  "Originating address: " & address

proc stopSignalLineText(signalText: string): string =
  ## "Signal received: <signal>" — empty signalText hides the line.
  "Signal received: " & signalText

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderNoSourcePanel*(r: MockRenderer; vm: NoSourceVM): MockNode =
  ## Render the no-source panel for the Mock renderer.
  ##
  ## The static shell (``.unknown-location`` + header + body wrapper)
  ## is built once via the DSL.  Three render-effects wire the
  ## conditional sub-trees: the message border, the location border,
  ## and the history-context block.  The trailing ``<p>`` rows update
  ## via DSL attribute expressions because the macro emits per-attribute
  ## ``createRenderEffect``s.
  var contentNode: MockNode
  var trailingNode: MockNode

  let panel = ui(r):
    tdiv(class = "unknown-location"):
      tdiv(class = "unknown-location-header"):
        text "Whoops!"
      tdiv(ref = contentNode,
           class = "unknown-location-content"):
        discard
      tdiv(ref = trailingNode):
        discard

  # Body content render-effect.  Rebuilds the message + location +
  # history blocks whenever any of the relevant signals change.  Uses
  # imperative MockRenderer ops because the conditional shape of the
  # tree (presence of the optional borders) is easier to express
  # imperatively than via the declarative DSL.
  createRenderEffect proc() =
    let message = vm.message.val
    let location = vm.location.val
    let history = vm.history.val
    r.clearChildren(contentNode)

    if message.len > 0:
      let msgBorder = ui(r):
        tdiv(class = "unknown-border"):
          p(class = "unknown-location-message"):
            text message
      r.appendChild(contentNode, msgBorder)

    let locBorder = ui(r):
      tdiv(class = "unknown-border"):
        p:
          text functionRowText(location)
    r.appendChild(contentNode, locBorder)
    if location.path.len > 0:
      let pathRow = ui(r):
        p:
          text pathRowText(location)
      r.appendChild(locBorder, pathRow)
    if location.line >= 0:
      let lineRow = ui(r):
        p:
          text lineRowText(location)
      r.appendChild(locBorder, lineRow)

    if history.hasHistory and history.action.len > 0:
      let contextBorder = ui(r):
        tdiv(class = "unknown-border"):
          p:
            text historyContextText(history)
      r.appendChild(contentNode, contextBorder)
      let buttonBorder = ui(r):
        tdiv(class = "unknown-border"):
          tdiv(class = "unknown-location-buttons"):
            p:
              text "You can still use all of the actions or you can go back"
            button(class = "jump-back-button",
                   onclick = proc() = vm.jumpBack()):
              text "Jump back"
      r.appendChild(contentNode, buttonBorder)

  # Trailing rows (originating address + stop-signal line).  Same
  # imperative render-effect — both rows are independent of the body
  # so we keep their layout outside ``unknown-location-content`` to
  # match the legacy structure.
  createRenderEffect proc() =
    let address = vm.originatingAddress.val
    let signalText = vm.stopSignalText.val
    r.clearChildren(trailingNode)

    if address.len > 0:
      let addrRow = ui(r):
        p(class = "unknown-location-address"):
          text originatingAddressText(address)
      r.appendChild(trailingNode, addrRow)
    if signalText.len > 0:
      let signalRow = ui(r):
        p(class = "unknown-location-signal"):
          text stopSignalLineText(signalText)
      r.appendChild(trailingNode, signalRow)

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc renderNoSourcePanel*(r: WebRenderer; vm: NoSourceVM): isonim_dom.Element =
    ## Render the panel for the real DOM.  The DOM ops mirror the
    ## Mock-renderer body so the resulting structure is identical
    ## across backends.
    var contentNode: isonim_dom.Element
    var trailingNode: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = "unknown-location"):
        tdiv(class = "unknown-location-header"):
          text "Whoops!"
        tdiv(ref = contentNode,
             class = "unknown-location-content"):
          discard
        tdiv(ref = trailingNode):
          discard

    proc clearChildren(node: isonim_dom.Element) =
      let asNode = isonim_dom.Node(node)
      while not isonim_dom.isNodeNil(asNode.firstChild):
        discard isonim_dom.removeChild(asNode, asNode.firstChild)

    proc createDiv(cssClass: string): isonim_dom.Element =
      let n = isonim_dom.createElement(isonim_dom.document, cstring"div")
      isonim_dom.setAttribute(n, cstring"class", cstring(cssClass))
      n

    proc createParagraph(text: string; cssClass: string = ""): isonim_dom.Element =
      let n = isonim_dom.createElement(isonim_dom.document, cstring"p")
      if cssClass.len > 0:
        isonim_dom.setAttribute(n, cstring"class", cstring(cssClass))
      let textNode = isonim_dom.createTextNode(isonim_dom.document, cstring(text))
      isonim_dom.appendChild(isonim_dom.Node(n), textNode)
      n

    createRenderEffect proc() =
      let message = vm.message.val
      let location = vm.location.val
      let history = vm.history.val
      clearChildren(contentNode)

      if message.len > 0:
        let border = createDiv("unknown-border")
        let msg = createParagraph(message, "unknown-location-message")
        isonim_dom.appendChild(isonim_dom.Node(border), isonim_dom.Node(msg))
        isonim_dom.appendChild(isonim_dom.Node(contentNode),
                               isonim_dom.Node(border))

      let locBorder = createDiv("unknown-border")
      let funcRow = createParagraph(functionRowText(location))
      isonim_dom.appendChild(isonim_dom.Node(locBorder),
                             isonim_dom.Node(funcRow))
      if location.path.len > 0:
        let pathRow = createParagraph(pathRowText(location))
        isonim_dom.appendChild(isonim_dom.Node(locBorder),
                               isonim_dom.Node(pathRow))
      if location.line >= 0:
        let lineRow = createParagraph(lineRowText(location))
        isonim_dom.appendChild(isonim_dom.Node(locBorder),
                               isonim_dom.Node(lineRow))
      isonim_dom.appendChild(isonim_dom.Node(contentNode),
                             isonim_dom.Node(locBorder))

      if history.hasHistory and history.action.len > 0:
        let contextBorder = createDiv("unknown-border")
        let contextRow = createParagraph(historyContextText(history))
        isonim_dom.appendChild(isonim_dom.Node(contextBorder),
                               isonim_dom.Node(contextRow))
        isonim_dom.appendChild(isonim_dom.Node(contentNode),
                               isonim_dom.Node(contextBorder))

        let buttonBorder = createDiv("unknown-border")
        let buttons = createDiv("unknown-location-buttons")
        let buttonsCopy = createParagraph(
          "You can still use all of the actions or you can go back")
        isonim_dom.appendChild(isonim_dom.Node(buttons),
                               isonim_dom.Node(buttonsCopy))

        let button = isonim_dom.createElement(
          isonim_dom.document, cstring"button")
        isonim_dom.setAttribute(button, cstring"class",
                                cstring"jump-back-button")
        let buttonText = isonim_dom.createTextNode(
          isonim_dom.document, cstring"Jump back")
        isonim_dom.appendChild(isonim_dom.Node(button), buttonText)
        isonim_dom.addEventListener(isonim_dom.Node(button), cstring"click",
                                    proc(ev: isonim_dom.Event) = vm.jumpBack())
        isonim_dom.appendChild(isonim_dom.Node(buttons),
                               isonim_dom.Node(button))

        isonim_dom.appendChild(isonim_dom.Node(buttonBorder),
                               isonim_dom.Node(buttons))
        isonim_dom.appendChild(isonim_dom.Node(contentNode),
                               isonim_dom.Node(buttonBorder))

    createRenderEffect proc() =
      let address = vm.originatingAddress.val
      let signalText = vm.stopSignalText.val
      clearChildren(trailingNode)

      if address.len > 0:
        let row = createParagraph(originatingAddressText(address),
                                  "unknown-location-address")
        isonim_dom.appendChild(isonim_dom.Node(trailingNode),
                               isonim_dom.Node(row))
      if signalText.len > 0:
        let row = createParagraph(stopSignalLineText(signalText),
                                  "unknown-location-signal")
        isonim_dom.appendChild(isonim_dom.Node(trailingNode),
                               isonim_dom.Node(row))

    panel

  proc mountIsoNimNoSource*(container: isonim_dom.Element;
                            vm: NoSourceVM) =
    ## Mount the IsoNim no-source panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderNoSourcePanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
