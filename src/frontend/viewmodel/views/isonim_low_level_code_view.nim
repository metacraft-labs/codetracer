## views/isonim_low_level_code_view.nim
##
## The Low Level Code panel: the assembly / IR listing of the function the
## debugger is in, grouped under the source lines it was generated from
## (Shared-DOM-Front-Ends D7.2).
##
## ONE generic view (`renderLowLevelCodePanel[R, N]`): the headless tests
## render it under `MockRenderer`, the desktop and the web page under
## `WebRenderer`, mounted by the panel host (`ui/panel_host`) into the
## container GoldenLayout creates. The data is `LowLevelCodeVM`'s, loaded per
## stop by the session's stop loader while the pane is shown.
##
## Structure::
##
##   div.component-container.low-level-code
##     div.low-level-code-header
##       div.low-level-code-error-slot > div.low-level-code-error     (only when errorMessage != "")
##       div.low-level-code-address-slot > div.low-level-code-address (only when address > 0)
##       div.low-level-code-sync.sync-{on|off}                        click = toggle sync
##       div.low-level-code-stepping                                  text "steps by line" / "steps by instruction"
##       div.low-level-code-notice[.notice-…|.hidden]
##     div.low-level-code-empty-slot > div.low-level-code-empty       (only when nothing is listed)
##     div.low-level-code-instructions                                one keyed row per item:
##       div.low-level-code-source-line[.active-source-line][.cross-referenced]
##         span.low-level-code-source-line-number   text "<line>"
##         span.low-level-code-source-line-text     text "<source line>"   (TEXT, never markup)
##       div.low-level-code-instruction[.active-instruction][.execution-pointer][.cross-referenced][.selected-instruction]
##                                                  click = go to its source line; right-click = its menu
##         span.low-level-code-instruction-offset   text "<offset>" / "StepId(<offset>)"
##         span.low-level-code-instruction-name     text "<name>" / "<no instructions>"
##         span.low-level-code-instruction-args     text "<args>"
##         span.low-level-code-instruction-other    text "<other>"
##         span.low-level-code-instruction-fidelity.fidelity-<rung>
##         span.low-level-code-instruction-source   text "<path>:<line>"   (when known)
##         span.low-level-code-instruction-count    text "<count>"         (when measured)
##
## THE ROWS ARE A `forEachKeyed` LIST, keyed by offset. The engine gives every
## instruction of one step that step's id as its `offset`, so an offset alone
## repeats: a row's key is its offset and its ordinal among the rows that
## share it, and a source line's key is its path, line and ordinal. Each item
## carries everything its row shows, so a row whose item is unchanged keeps
## its node and a changed one is rebuilt.
##
## EVERY WORD AND EVERY MARK IS THE VIEWMODEL'S (PLAT-60): the rows, the
## execution pointer, the cross-reference to the source line the editor's
## cursor is on, the header's statements and the row menu are
## `low_level_code_vm`'s, which the terminal's and the GPUI window's panes
## draw too. This view only gives them classes.
##
## A SOURCE LINE IS TEXT. It is a line of the recorded program's own source —
## markup by construction for HTML, JSX, Vue, PHP or template files — and the
## DSL's `text` makes it a text node. The desktop's earlier Monaco view zone
## for the same line set `textContent` for the same reason.

import std/[strutils, tables]
when defined(js):
  # Enter and Space on a `role="button"` row are its click.
  import ./isonim_activation

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom
  import kdom
  from ./context_menu_bridge import showContextMenu
  from ../../context_menu_item import ContextMenuItem

import ../store/types
import ../viewmodels/low_level_code_vm

# PLAT-60: the rows and the words moved into the ViewModel; re-exported so
# every reader of this view keeps finding them here.
export low_level_code_vm.LowLevelRowKind, low_level_code_vm.LowLevelRowView,
  low_level_code_vm.addressText, low_level_code_vm.sourceCrossRef,
  low_level_code_vm.syncToggleLabel, low_level_code_vm.mappingNotice

# A generic view is instantiated where it is called, and the `ui` macro's
# expansion names `val=`, `createRenderEffect` and the control-flow components
# there.
export signals, computation, components

const LowLevelCodeContainerClass* = "component-container low-level-code"

# ---------------------------------------------------------------------------
# Labels and classes
# ---------------------------------------------------------------------------

proc rowClass*(active: bool): string =
  if active:
    "low-level-code-instruction active-instruction"
  else:
    "low-level-code-instruction"

proc rowClass*(row: LowLevelRowView): string =
  ## An instruction row's classes: the debugger's line, the execution
  ## pointer, the cross-reference, the listing's cursor.
  result = rowClass(row.active)
  if row.executing: result.add " execution-pointer"
  if row.linked: result.add " cross-referenced"
  if row.selected: result.add " selected-instruction"

proc sourceRowClass*(active: bool): string =
  if active:
    "low-level-code-source-line active-source-line"
  else:
    "low-level-code-source-line"

proc sourceRowClass*(row: LowLevelRowView): string =
  result = sourceRowClass(row.active)
  if row.linked: result.add " cross-referenced"

# ---------------------------------------------------------------------------
# Anchoring, rendered (Generated-Code-Listing.md): the per-row fidelity, the
# sync toggle and the notice that says why a listing is not kept in step.
# ---------------------------------------------------------------------------

proc fidelityClass*(f: MappingFidelity): string =
  "low-level-code-instruction-fidelity fidelity-" & label(f).replace(" ", "-")

proc syncToggleClass*(enabled: bool): string =
  "low-level-code-sync " & (if enabled: "sync-on" else: "sync-off")

proc noticeClass*(vm: LowLevelCodeVM): string =
  case vm.noticeKind
  of lnkDisabled: "low-level-code-notice notice-disabled"
  of lnkRefused: "low-level-code-notice notice-refused"
  of lnkSuspended: "low-level-code-notice notice-suspended"
  of lnkNone: "low-level-code-notice hidden"

# ---------------------------------------------------------------------------
# The rows
# ---------------------------------------------------------------------------

proc lowLevelRows*(vm: LowLevelCodeVM): seq[LowLevelRowView] =
  ## The listing as rows — the ViewModel's (`displayRows`).
  vm.displayRows()

proc onRowClick(vm: LowLevelCodeVM; index: int): proc() =
  ## A row's click: go to the source line its instruction was generated
  ## from. A factory, so each row's closure owns its index.
  result = proc() =
    let rows = vm.instructions.val
    if index >= 0 and index < rows.len:
      vm.jumpToInstruction(rows[index])

proc onSyncToggle(vm: LowLevelCodeVM): proc() =
  result = proc() = vm.setSyncEnabled(not vm.syncSettings.val.enabled)

when defined(js):
  proc preventMenuDefault(ev: isonim_dom.Event) {.importjs: "#.preventDefault()".}
  proc stopMenuPropagation(ev: isonim_dom.Event) {.importjs: "#.stopPropagation()".}
  proc eventClientX(ev: isonim_dom.Event): int {.importjs: "(#.clientX || 0)".}
  proc eventClientY(ev: isonim_dom.Event): int {.importjs: "(#.clientY || 0)".}
  proc writeClipboard(text: cstring) {.importjs: """
    (function(t){ try { navigator.clipboard.writeText(t); } catch (e) {} })(#)""".}

  proc rowMenuHandler(vm: LowLevelCodeVM; index: int;
                      action: LowLevelMenuAction): proc(ev: kdom.Event) =
    ## A row menu's entry, done by the ViewModel (`runRowMenu`); copied text
    ## goes to the clipboard.
    result = proc(ev: kdom.Event) =
      let outcome = vm.runRowMenu(index, action)
      if outcome.copied.len > 0:
        writeClipboard(cstring(outcome.copied))

  proc rowMenuItems(vm: LowLevelCodeVM; index: int): seq[ContextMenuItem] =
    ## PLAT-60: an instruction's context menu, the ViewModel's entries
    ## (`LowLevelCodeVM.rowMenu`) — the same the terminal's and GPUI's panes
    ## open.
    for e in vm.rowMenu(index):
      result.add ContextMenuItem(name: cstring(e.label), hint: cstring"",
        disabled: not e.enabled, disabledReason: cstring(e.reason),
        handler: rowMenuHandler(vm, index, e.action))

  proc wireRowMenu(row: isonim_dom.Element; vm: LowLevelCodeVM; index: int) =
    ## A right press selects the instruction and opens its menu.
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"contextmenu",
      proc(ev: isonim_dom.Event) =
        ev.preventMenuDefault()
        ev.stopMenuPropagation()
        vm.selectInstruction(index)
        showContextMenu(rowMenuItems(vm, index), ev.eventClientX(),
                        ev.eventClientY()))

proc renderLowLevelRow*[R, N](r: R; vm: LowLevelCodeVM;
                              row: LowLevelRowView): N =
  ## One row of the listing (see the structure above).
  case row.kind
  of lrkSource:
    result = ui(r):
      tdiv(class = sourceRowClass(row)):
        span(class = "low-level-code-source-line-number"):
          text $row.line
        span(class = "low-level-code-source-line-text"):
          text row.text
  of lrkInstruction:
    var item: N
    result = ui(r):
      tdiv(role = "button", tabindex = "0", ref = item, class = rowClass(row),
           onclick = onRowClick(vm, row.index)):
        span(class = "low-level-code-instruction-offset"):
          text row.offsetText
        span(class = "low-level-code-instruction-name"):
          text row.name
        span(class = "low-level-code-instruction-args"):
          text row.args
        span(class = "low-level-code-instruction-other"):
          text row.other
        span(class = fidelityClass(row.fidelity)):
          text row.fidelityText
    if row.crossRef.len > 0:
      let crossSpan = ui(r):
        span(class = "low-level-code-instruction-source"):
          text row.crossRef
      r.appendChild(item, crossSpan)
    if row.countText.len > 0:
      let countSpan = ui(r):
        span(class = "low-level-code-instruction-count"):
          text row.countText
      r.appendChild(item, countSpan)
    when defined(js):
      when N is isonim_dom.Element:
        wireRowMenu(item, vm, row.index)

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc renderLowLevelCodePanel*[R, N](r: R; vm: LowLevelCodeVM): N =
  ## The Low Level Code panel (see the structure above).
  var errorSlot, addressSlot, emptySlot, listContainer: N
  let panel = ui(r):
    tdiv(class = LowLevelCodeContainerClass):
      tdiv(class = "low-level-code-header"):
        tdiv(ref = errorSlot, class = "low-level-code-error-slot"):
          discard
        tdiv(ref = addressSlot, class = "low-level-code-address-slot"):
          discard
        tdiv(class = syncToggleClass(vm.syncSettings.val.enabled),
             onclick = onSyncToggle(vm)):
          text syncToggleLabel(vm.syncSettings.val.enabled)
        tdiv(class = "low-level-code-stepping"):
          text steppingText(vm)
        tdiv(class = noticeClass(vm)):
          text mappingNotice(vm)
      tdiv(ref = emptySlot, class = "low-level-code-empty-slot"):
        discard
      tdiv(ref = listContainer, class = "low-level-code-instructions"):
        discard

  # The error and the address are lists of zero or one item, keyed by their
  # text: a new message is a new node, so a shown overlay never keeps a stale
  # text, and none is in the DOM while there is nothing to say.
  forEachKeyed[string, R, N](r, errorSlot,
    proc(): seq[string] =
      let err = vm.errorMessage.val
      if err.len > 0: @[err] else: @[],
    proc(err: proc(): string; index: proc(): int): N =
      ui(r):
        tdiv(class = "low-level-code-error"):
          text err())
  forEachKeyed[string, R, N](r, addressSlot,
    proc(): seq[string] =
      let a = vm.address.val
      if a > 0: @[addressText(a)] else: @[],
    proc(label: proc(): string; index: proc(): int): N =
      ui(r):
        tdiv(class = "low-level-code-address"):
          text label())

  forEachKeyed[string, R, N](r, emptySlot,
    proc(): seq[string] =
      let t = emptyText(vm)
      if t.len > 0: @[t] else: @[],
    proc(t: proc(): string; index: proc(): int): N =
      ui(r):
        tdiv(class = "low-level-code-empty"):
          text t())

  forEachKeyed[LowLevelRowView, R, N](r, listContainer,
    proc(): seq[LowLevelRowView] = lowLevelRows(vm),
    proc(row: proc(): LowLevelRowView; index: proc(): int): N =
      renderLowLevelRow[R, N](r, vm, row()))

  panel

when defined(js):
  proc mountIsoNimLowLevelCode*(container: isonim_dom.Element;
                                vm: LowLevelCodeVM) =
    ## Append the panel to `container` — for a host that is not the panel
    ## host (the storybook).
    let panel = renderLowLevelCodePanel[WebRenderer, isonim_dom.Element](
      WebRenderer(), vm)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
