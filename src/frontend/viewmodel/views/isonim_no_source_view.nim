## views/isonim_no_source_view.nim
##
## IsoNim DOM-rendering view for the "no source" placeholder panel.
##
## Renders a live, reactive DOM tree driven by ``NoSourceVM`` signals.
## Replaces the legacy Karax ``method render`` in
## ``frontend/ui/no_source.nim`` (the IsoNim view is the single source
## of truth for the panel's DOM).
##
## One generic proc renders, under every renderer, the outer
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
import isonim/dsl/components
import isonim/testing/mock_dom

# The generic proc expands the DSL at its caller.
export signals, computation, components

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
# The panel, for every renderer
# ---------------------------------------------------------------------------

proc renderNoSourcePanel*[R, N](r: R; vm: NoSourceVM): N =
  ## The no-source panel, for every renderer.
  ##
  ## The static shell (``.unknown-location`` + header + body wrapper)
  ## is built once via the DSL.  Three render-effects wire the
  ## conditional sub-trees: the message border, the location border,
  ## and the history-context block.  The trailing ``<p>`` rows update
  ## via DSL attribute expressions because the macro emits per-attribute
  ## ``createRenderEffect``s.
  var contentNode: N
  var trailingNode: N

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
  # imperative renderer ops because the conditional shape of the
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

when defined(js):
  proc mountIsoNimNoSource*(container: isonim_dom.Element;
                            vm: NoSourceVM) =
    ## Mount the IsoNim no-source panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderNoSourcePanel[WebRenderer, isonim_dom.Element](r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
