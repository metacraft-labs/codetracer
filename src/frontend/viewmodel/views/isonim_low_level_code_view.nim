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
##       div.low-level-code-notice[.notice-…|.hidden]
##     div.low-level-code-instructions                                one keyed row per item:
##       div.low-level-code-source-line[.active-source-line]          a source line, before its rows
##         span.low-level-code-source-line-number   text "<line>"
##         span.low-level-code-source-line-text     text "<source line>"   (TEXT, never markup)
##       div.low-level-code-instruction[.active-instruction]          click = go to its source line
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
## A SOURCE LINE IS TEXT. It is a line of the recorded program's own source —
## markup by construction for HTML, JSX, Vue, PHP or template files — and the
## DSL's `text` makes it a text node. The desktop's earlier Monaco view zone
## for the same line set `textContent` for the same reason.

import std/[strutils, tables]

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/low_level_code_vm

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

proc sourceRowClass*(active: bool): string =
  if active:
    "low-level-code-source-line active-source-line"
  else:
    "low-level-code-source-line"

proc addressText*(address: int): string =
  "Originating address: 0x" & toHex(address)

proc sourceCrossRef*(instr: LowLevelInstruction): string =
  if instr.highLevelLine <= 0 or instr.highLevelPath.len == 0:
    ""
  else:
    instr.highLevelPath & ":" & $instr.highLevelLine

# ---------------------------------------------------------------------------
# Anchoring, rendered (Generated-Code-Listing.md): the per-row fidelity, the
# sync toggle and the notice that says why a listing is not kept in step.
# ---------------------------------------------------------------------------

proc fidelityClass*(f: MappingFidelity): string =
  "low-level-code-instruction-fidelity fidelity-" & label(f).replace(" ", "-")

proc syncToggleLabel*(enabled: bool): string =
  if enabled: "sync on" else: "sync off"

proc syncToggleClass*(enabled: bool): string =
  "low-level-code-sync " & (if enabled: "sync-on" else: "sync-off")

proc mappingNotice*(vm: LowLevelCodeVM): string =
  if not vm.syncSettings.val.enabled:
    return "source syncing is off"
  if vm.anchorsRejected.val:
    return "the source mapping here could not be used, so these panes " &
      "are not kept in step"
  if not vm.hasAnchors.val and vm.instructions.val.len > 0:
    return "there is no source mapping here, so these panes are not kept " &
      "in step"
  ""

proc noticeClass*(vm: LowLevelCodeVM): string =
  if not vm.syncSettings.val.enabled:
    "low-level-code-notice notice-disabled"
  elif vm.anchorsRejected.val:
    "low-level-code-notice notice-refused"
  elif not vm.hasAnchors.val and vm.instructions.val.len > 0:
    "low-level-code-notice notice-suspended"
  else:
    "low-level-code-notice hidden"

# ---------------------------------------------------------------------------
# The rows
# ---------------------------------------------------------------------------

type
  LowLevelRowKind* = enum
    lrkSource       ## a source line, before the instructions generated from it
    lrkInstruction  ## one instruction

  LowLevelRowView* = object
    ## Everything one row shows. `forEachKeyed` compares items whole, so a row
    ## whose view is unchanged keeps its node.
    kind*: LowLevelRowKind
    key*: string
    active*: bool
    # lrkSource
    line*: int
    text*: string
    # lrkInstruction
    index*: int
      ## The instruction's position in `LowLevelCodeVM.instructions`.
    offsetText*, name*, args*, other*, crossRef*: string
    fidelityText*, fidelityCls*, countText*: string

proc lowLevelRows*(vm: LowLevelCodeVM): seq[LowLevelRowView] =
  ## The listing as rows: each run of instructions generated from one source
  ## line is preceded by that line. Reads the signals it depends on, so a list
  ## built over it follows them.
  let instructions = vm.instructions.val
  let activeLine = vm.activeLine.val
  let activePath = vm.activePath.val
  let activeOffset = vm.activeOffset.val
  let noir = vm.noirProject.val
  let anchors = vm.anchors.val
  let sources = vm.sourceText.val
  var offsetSeen = initTable[int, int]()
  var lineSeen = initTable[string, int]()
  var groupPath = ""
  var groupLine = 0
  for i, instr in instructions:
    let hasSource = instr.highLevelPath.len > 0 and instr.highLevelLine > 0
    if hasSource and (instr.highLevelPath != groupPath or
                      instr.highLevelLine != groupLine):
      groupPath = instr.highLevelPath
      groupLine = instr.highLevelLine
      let lineKey = sourceKey(groupPath, groupLine)
      let ordinal = lineSeen.getOrDefault(lineKey, 0)
      lineSeen[lineKey] = ordinal + 1
      result.add LowLevelRowView(
        kind: lrkSource,
        key: "src:" & lineKey & "#" & $ordinal,
        active: activeLine > 0 and groupLine == activeLine and
                (activePath.len == 0 or groupPath == activePath),
        line: groupLine,
        text: sources.getOrDefault(lineKey, ""))
    elif not hasSource:
      groupPath = ""
      groupLine = 0
    let ordinal = offsetSeen.getOrDefault(instr.offset, 0)
    offsetSeen[instr.offset] = ordinal + 1
    # ROW INDEX, not offset, for the anchors: they are ranges of
    # generated-row indices (`Generated-Code-Listing.md` GCL-D6).
    let fidelity = vm.fidelityAtRow(i)
    var count = ExecutedCount(value: 0, provenance: cpNone)
    let at = anchorIndexAtRow(anchors, i)
    if at != NoAnchor:
      count = anchors[at].count
    result.add LowLevelRowView(
      kind: lrkInstruction,
      key: "op:" & $instr.offset & "#" & $ordinal,
      active: isActiveInstruction(instr, activeLine, activePath, activeOffset),
      index: i,
      offsetText: formatOffset(instr, noir),
      name: displayName(instr),
      args: instr.args,
      other: instr.other,
      crossRef: sourceCrossRef(instr),
      fidelityText: label(fidelity),
      fidelityCls: fidelityClass(fidelity),
      # No count for `cpNone`: a rendered `0` would read as "never ran", a
      # measurement the pane did not make (GCL-D3).
      countText: countLabel(count))

proc onRowClick(vm: LowLevelCodeVM; index: int): proc() =
  ## A row's click: go to the source line its instruction was generated
  ## from. A factory, so each row's closure owns its index.
  result = proc() =
    let rows = vm.instructions.val
    if index >= 0 and index < rows.len:
      vm.jumpToInstruction(rows[index])

proc onSyncToggle(vm: LowLevelCodeVM): proc() =
  result = proc() = vm.setSyncEnabled(not vm.syncSettings.val.enabled)

proc renderLowLevelRow*[R, N](r: R; vm: LowLevelCodeVM;
                              row: LowLevelRowView): N =
  ## One row of the listing (see the structure above).
  case row.kind
  of lrkSource:
    result = ui(r):
      tdiv(class = sourceRowClass(row.active)):
        span(class = "low-level-code-source-line-number"):
          text $row.line
        span(class = "low-level-code-source-line-text"):
          text row.text
  of lrkInstruction:
    var item: N
    result = ui(r):
      tdiv(ref = item, class = rowClass(row.active),
           onclick = onRowClick(vm, row.index)):
        span(class = "low-level-code-instruction-offset"):
          text row.offsetText
        span(class = "low-level-code-instruction-name"):
          text row.name
        span(class = "low-level-code-instruction-args"):
          text row.args
        span(class = "low-level-code-instruction-other"):
          text row.other
        span(class = row.fidelityCls):
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

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc renderLowLevelCodePanel*[R, N](r: R; vm: LowLevelCodeVM): N =
  ## The Low Level Code panel (see the structure above).
  var errorSlot, addressSlot, listContainer: N
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
        tdiv(class = noticeClass(vm)):
          text mappingNotice(vm)
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
