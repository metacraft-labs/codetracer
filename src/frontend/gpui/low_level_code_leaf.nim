## gpui/low_level_code_leaf.nim — PLAT-60. The GPUI window's **Low Level
## Code** pane, drawn natively from the session's `LowLevelCodeVM` (the model
## the desktop's view and the terminal's pane draw).
##
## What the desktop's view draws, in its order and words
## (`viewmodel/views/isonim_low_level_code_view.nim`,
## Generated-Code-Listing.md §0): a header — the source-sync toggle, what a
## step does, an error the engine reported, the load address, why the
## listing is not kept in step — over the listing: each run of instructions
## after the source line it was generated from, every instruction its offset,
## its text and its source line. Every word and every mark is the
## ViewModel's (`displayRows`): the debugger's line, the EXECUTION POINTER
## (`▸` on the editor's execution-line ground), the CROSS-REFERENCE (the
## instructions generated from the editor's caret line, and the source line
## of the selected instruction, on the hover ground) and the listing's cursor
## (the selection ground). The rows have a fixed pitch so a press and the
## drawing go through one layout (`lowLevelLayout`); the list scrolls (the
## wheel) and its scrollbar is the shared list scrubber, moving the VIEW, its
## mark the execution pointer.
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-low-level-*`).

import isonim_gpui/renderer
import isonim/core/[signals, computation]

import codetracer_embed
import ./window_geometry
import ./chrome
import ./app/leaves
import ./list_scrubber
from ../viewmodel/viewmodels/table_overflow import nil
from ../../common/view_vocabulary/layout_questions import trEditorCode
import ../styles/generated/design_tokens

type
  GLowLevelPane* = object
    ## The window's own state for the pane: where the reader scrolled and a
    ## held scrubber thumb. The listing's cursor is the ViewModel's.
    scrollTop*: int
    dragging*: bool

  LowLevelLayout* = object
    body*: PxRect
    sync*: PxRect
      ## The header's `sync on` / `sync off` toggle.
    headerLines*: seq[tuple[text, colour, attr: string]]
      ## The header's rows after the controls: the error, the address, the
      ## notice.
    list*: PxRect
    rows*: int
    overflow*: bool
    lines*: seq[LowLevelRowView]
    offsetPx*: int
      ## The offset column's width.

  GLowLevelHitKind* = enum
    glNone, glSync, glHeader, glSource, glInstruction, glTrack, glThumb

  GLowLevelHit* = object
    kind*: GLowLevelHitKind
    index*: int
      ## glInstruction: the instruction's index in the ViewModel's listing.
    fraction*: float

const
  LowLevelRowPx* = 22
  LowLevelHeaderPx* = 26
  LowLevelGapPx = 8
  LowLevelPointerPx = 16
  LowLevelAttribute* = "data-ct-low-level"
    ## On the pane: how many instructions it lists.
  LowLevelRowAttribute* = "data-ct-low-level-index"
    ## On an instruction's row: its index, with `data-ct-low-level-*`.
  LowLevelLineAttribute* = "data-ct-low-level-line"
    ## On a source line's row: its line number.
  LowLevelTextColour = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  LowLevelCaptionColour* = "#8b949e"
  LowLevelErrorColour* = DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark]
  LowLevelNoticeColour* =
    DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark]
  LowLevelPointerColour* =
    DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark]
  LowLevelExecutingGround* = DesignTokenHex[dtEditorThemeExecutionLine][dmDark]
    ## The execution pointer's row: the editor's execution-line ground.
  LowLevelLinkedGround* =
    DesignTokenHex[dtColorsUiSurfacePrimarySecondaryHover][dmDark]
    ## A cross-referenced row: the hover ground.
  LowLevelSelectedGround* = DesignTokenHex[dtEditorThemeSelection][dmDark]
  LowLevelToggleGround =
    DesignTokenHex[dtColorsUiSurfaceInputDefault][dmDark]
  LowLevelPointerGlyph* = "▸"

proc initGLowLevelPane*(): GLowLevelPane = GLowLevelPane()

proc pxOf(text: string): int =
  int(float(table_overflow.runeMeasure(text)) * EditorColumnPx)

proc cellsOf(px: int): int = int(float(px) / EditorColumnPx)

proc instructionText*(row: LowLevelRowView): string =
  result = row.name
  if row.args.len > 0: result.add " " & row.args
  if row.other.len > 0: result.add " " & row.other

proc lowLevelLayout*(vm: LowLevelCodeVM; body: PxRect): LowLevelLayout =
  ## The pane's parts, in window pixels, inside `body` (its padding off).
  result.body = body
  let inner = PxRect(x: body.x + ChromePaddingPx, y: body.y + ChromePaddingPx,
                     w: max(0, body.w - 2 * ChromePaddingPx),
                     h: max(0, body.h - 2 * ChromePaddingPx))
  let label = syncToggleLabel(vm.syncSettings.val.enabled)
  result.sync = PxRect(x: inner.x, y: inner.y, w: pxOf(label) + 16,
                       h: LowLevelHeaderPx)
  if vm.errorMessage.val.len > 0:
    result.headerLines.add (vm.errorMessage.val, LowLevelErrorColour, "error")
  if vm.address.val > 0:
    result.headerLines.add (addressText(vm.address.val),
                            LowLevelCaptionColour, "address")
  let notice = vm.mappingNotice
  if notice.len > 0:
    result.headerLines.add (notice, LowLevelNoticeColour, "notice")
  let top = inner.y + LowLevelHeaderPx + result.headerLines.len *
            LowLevelRowPx + 2
  let rest = max(0, inner.y + inner.h - top)
  result.rows = max(0, rest div LowLevelRowPx)
  result.lines = vm.displayRows()
  result.overflow = result.lines.len > result.rows
  var width = inner.w
  if result.overflow:
    width = max(0, inner.w - ListTrackPx - 2)
  result.list = PxRect(x: inner.x, y: top, w: width,
                       h: result.rows * LowLevelRowPx)
  for l in result.lines:
    if l.kind == lrkInstruction:
      result.offsetPx = max(result.offsetPx, pxOf(l.offsetText))

proc listBody(lay: LowLevelLayout): PxRect =
  PxRect(x: lay.body.x, y: lay.list.y - ChromePaddingPx, w: lay.body.w,
         h: lay.list.h + 2 * ChromePaddingPx)

proc visibleTop*(st: GLowLevelPane; total, rows: int): int =
  max(0, min(st.scrollTop, total - max(1, rows)))

proc executionLineOf(lay: LowLevelLayout): int =
  for i, l in lay.lines:
    if l.kind == lrkInstruction and l.executing:
      return i
  -1

proc scrubberOf*(st: GLowLevelPane; lay: LowLevelLayout): ScrubberModel =
  scrubberModel(lay.lines.len, st.visibleTop(lay.lines.len, lay.rows),
                lay.rows, current = lay.executionLineOf)

proc revealLine*(st: var GLowLevelPane; vm: LowLevelCodeVM; body: PxRect;
                 line: int) =
  ## Keep display row `line` in view.
  let lay = lowLevelLayout(vm, body)
  if line < 0 or lay.rows <= 0:
    return
  let top = st.visibleTop(lay.lines.len, lay.rows)
  if line < top: st.scrollTop = line
  elif line >= top + lay.rows: st.scrollTop = line - lay.rows + 1

proc revealIndex*(st: var GLowLevelPane; vm: LowLevelCodeVM; body: PxRect;
                  index: int) =
  ## Keep instruction `index` in view.
  st.revealLine(vm, body, displayIndexOf(vm.displayRows(), index))

proc scrollBy*(st: var GLowLevelPane; vm: LowLevelCodeVM; body: PxRect;
               delta: int) =
  let lay = lowLevelLayout(vm, body)
  st.scrollTop = max(0, min(st.visibleTop(lay.lines.len, lay.rows) + delta,
                            lay.lines.len - max(1, lay.rows)))

proc textRun(r: GpuiRenderer; text, colour: string;
             widthPx = -1): GpuiElement =
  result = r.createElement("span")
  r.setStyle(result, "color", colour)
  r.setStyle(result, "white-space", "pre")
  r.setStyle(result, "flex-shrink", "0")
  if widthPx >= 0:
    r.setStyle(result, "width", $widthPx & "px")
    r.setStyle(result, "overflow", "hidden")
  r.appendChild(result, r.createTextNode(text))

proc rowElement(r: GpuiRenderer; widthPx: int): GpuiElement =
  result = r.createElement("div")
  for (k, v) in [("display", "flex"), ("white-space", "nowrap"),
                 ("overflow", "hidden"), ("flex-shrink", "0"),
                 ("items", "center")]:
    r.setStyle(result, k, v)
  r.setStyle(result, "height", $LowLevelRowPx & "px")
  r.setStyle(result, "width", $widthPx & "px")
  r.setStyle(result, "gap", $LowLevelGapPx & "px")
  r.setAttribute(result, TextMetricAttribute, gpuiMetricFor(trEditorCode))

proc cut(text: string; px: int): string =
  fitCell(text, cellsOf(px)).text

proc groundOf(l: LowLevelRowView): string =
  ## The row's ground: the cursor over the cross-reference over the pointer.
  if l.selected: LowLevelSelectedGround
  elif l.linked: LowLevelLinkedGround
  elif l.executing: LowLevelExecutingGround
  else: ""

proc drawLowLevelCode*(r: GpuiRenderer; pane: GpuiElement; vm: LowLevelCodeVM;
                       st: GLowLevelPane; body: PxRect): bool =
  ## Draw the pane into `pane` (its children replaced), its body at `body` in
  ## window pixels. False when there is nothing to draw it from.
  if pane.isNil or vm.isNil:
    return false
  while childCount(pane) > 0:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  r.setStyle(pane, "position", "relative")
  r.setStyle(pane, "display", "flex")
  r.setStyle(pane, "flex-direction", "column")
  let lay = lowLevelLayout(vm, body)
  r.setAttribute(pane, LowLevelAttribute, $vm.instructions.val.len)
  r.setAttribute(pane, "data-ct-low-level-stepping", vm.steppingText)
  # The controls: the sync toggle, what a step does.
  let header = r.createElement("div")
  for (k, v) in [("display", "flex"), ("flex-shrink", "0"),
                 ("items", "center"), ("gap", "12px")]:
    r.setStyle(header, k, v)
  r.setStyle(header, "height", $LowLevelHeaderPx & "px")
  let label = syncToggleLabel(vm.syncSettings.val.enabled)
  let toggle = textRun(r, label, LowLevelTextColour, lay.sync.w)
  r.setStyle(toggle, "background", LowLevelToggleGround)
  r.setStyle(toggle, "text-align", "center")
  r.setAttribute(toggle, "data-ct-low-level-sync", label)
  r.appendChild(header, toggle)
  let stepping = textRun(r, vm.steppingText, LowLevelCaptionColour)
  r.setAttribute(stepping, "data-ct-low-level-stepping", vm.steppingText)
  r.appendChild(header, stepping)
  r.appendChild(pane, header)
  for (text, colour, attr) in lay.headerLines:
    let el = rowElement(r, lay.list.w)
    let t = textRun(r, cut(text, lay.list.w), colour)
    r.setAttribute(t, "data-ct-low-level-" & attr, text)
    r.appendChild(el, t)
    r.appendChild(pane, el)
  # The listing.
  let top = st.visibleTop(lay.lines.len, lay.rows)
  r.setAttribute(pane, "data-ct-low-level-top", $top)
  r.setAttribute(pane, "data-ct-low-level-rows", $lay.rows)
  r.setAttribute(pane, "data-ct-low-level-total-lines", $lay.lines.len)
  if lay.lines.len == 0:
    let empty = vm.emptyText
    if empty.len > 0:
      let el = rowElement(r, lay.list.w)
      r.setAttribute(el, "data-ct-low-level-empty", empty)
      r.appendChild(el, textRun(r, empty, LowLevelCaptionColour))
      r.appendChild(pane, el)
  for k in 0 ..< lay.rows:
    let i = top + k
    if i >= lay.lines.len:
      break
    let l = lay.lines[i]
    let el = rowElement(r, lay.list.w)
    let ground = l.groundOf
    if ground.len > 0:
      r.setStyle(el, "background", ground)
    if l.linked: r.setAttribute(el, "data-ct-linked", "true")
    if l.active: r.setAttribute(el, "data-ct-active", "true")
    case l.kind
    of lrkSource:
      r.setAttribute(el, LowLevelLineAttribute, $l.line)
      r.setAttribute(el, "data-ct-path", l.path)
      r.appendChild(el, textRun(r, "", LowLevelTextColour, LowLevelPointerPx))
      let n = textRun(r, $l.line, LowLevelCaptionColour)
      r.appendChild(el, n)
      let t = textRun(r, l.text, LowLevelTextColour)
      r.setStyle(t, "font-weight", "600")
      r.setAttribute(t, "data-ct-text", l.text)
      r.appendChild(el, t)
    of lrkInstruction:
      r.setAttribute(el, LowLevelRowAttribute, $l.index)
      r.setAttribute(el, "data-ct-offset", l.offsetText)
      r.setAttribute(el, "data-ct-instruction", l.instructionText)
      r.setAttribute(el, "data-ct-source", l.crossRef)
      if l.executing: r.setAttribute(el, "data-ct-executing", "true")
      if l.selected: r.setAttribute(el, "data-ct-selected", "true")
      let mark = textRun(r, (if l.executing: LowLevelPointerGlyph else: ""),
                         LowLevelPointerColour, LowLevelPointerPx)
      r.appendChild(el, mark)
      r.appendChild(el, textRun(r, l.offsetText, LowLevelCaptionColour,
                                lay.offsetPx))
      let right = l.crossRef
      let rightPx = pxOf(right)
      let instrPx = max(0, lay.list.w - LowLevelPointerPx - lay.offsetPx -
                           rightPx - 4 * LowLevelGapPx)
      r.appendChild(el, textRun(r, cut(l.instructionText, instrPx),
                                LowLevelTextColour, instrPx))
      if right.len > 0:
        r.appendChild(el, textRun(r, right, LowLevelCaptionColour))
    r.appendChild(pane, el)
  if lay.overflow:
    drawListScrubber(r, pane, lay.listBody, st.scrubberOf(lay), "lowLevelCode")
  true

proc lowLevelHitAt*(vm: LowLevelCodeVM; st: GLowLevelPane; body: PxRect;
                    x, y: int): GLowLevelHit =
  ## What a press at window pixel `(x, y)` is on, by the drawing's layout.
  result = GLowLevelHit(kind: glNone, index: -1)
  if vm.isNil or not body.contains(x, y):
    return
  let lay = lowLevelLayout(vm, body)
  if lay.sync.contains(x, y):
    return GLowLevelHit(kind: glSync, index: -1)
  if y < lay.list.y:
    return GLowLevelHit(kind: glHeader, index: -1)
  if lay.overflow:
    let hit = listScrubHit(lay.listBody, st.scrubberOf(lay), x, y)
    if hit.onTrack:
      return GLowLevelHit(kind: (if hit.onThumb: glThumb else: glTrack),
                          index: -1, fraction: hit.fraction)
  if not lay.list.contains(x, y):
    return
  let i = st.visibleTop(lay.lines.len, lay.rows) +
          (y - lay.list.y) div LowLevelRowPx
  if i < 0 or i >= lay.lines.len:
    return
  let l = lay.lines[i]
  result = case l.kind
    of lrkSource: GLowLevelHit(kind: glSource, index: -1)
    of lrkInstruction: GLowLevelHit(kind: glInstruction, index: l.index)

proc scrubLowLevel*(st: var GLowLevelPane; vm: LowLevelCodeVM; body: PxRect;
                    y: int; dragging: bool) =
  ## The scrubber pressed (a jump) or its thumb held (the view follows).
  let lay = lowLevelLayout(vm, body)
  if not lay.overflow:
    return
  let track = listTrackRect(lay.listBody)
  st.scrollTop = st.scrubberOf(lay).scrubTop(
    trackFractionAt(y - track.y, track.h), dragging)

proc instructionCentre*(vm: LowLevelCodeVM; st: GLowLevelPane; body: PxRect;
                        index: int): tuple[ok: bool, x, y: int] =
  ## Where instruction `index`'s row is drawn (its text's start), for a press
  ## aimed at it.
  let lay = lowLevelLayout(vm, body)
  let at = displayIndexOf(lay.lines, index)
  let top = st.visibleTop(lay.lines.len, lay.rows)
  if at < 0 or at < top or at >= top + lay.rows:
    return (false, 0, 0)
  (true, lay.list.x + LowLevelPointerPx + lay.offsetPx + 3 * LowLevelGapPx,
   lay.list.y + (at - top) * LowLevelRowPx + LowLevelRowPx div 2)
