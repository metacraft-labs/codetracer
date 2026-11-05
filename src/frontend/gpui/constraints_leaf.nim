## gpui/constraints_leaf.nim — PLAT-62. The GPUI window's **Constraints**
## pane, drawn natively from the window's `ConstraintsVM` (the model the
## desktop's panel and the terminal's pane draw), which the window's
## `NativeConstraintsHost` fills by running `nargo info --json` in the
## project.
##
## What the desktop's panel draws, in its order and words
## (`viewmodel/views/isonim_constraints_view.nim`): the headline — the
## circuit's ACIR and unconstrained opcode counts, `(stale)` when the sources
## changed since — a notice when the report has counts and no printed rows,
## one row per function the compiler named (its name, its kind, its count and
## the line that declares it), each function's printed opcodes under it when
## there is a listing, and how the counts were obtained; with no report, why
## there is none. Every word is the ViewModel's (`ConstraintsVM.rows`,
## `headline`, `listingNoticeFor`). The rows have a fixed pitch so a press and
## the drawing go through one layout (`constraintsLayout`); the list scrolls
## (the wheel) and its scrollbar is the shared list scrubber, moving the VIEW.
## The selected row — the cursor a press, the keys and the row menu share — is
## drawn on the desktop's selected-row ground.
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-constraints-*`, `data-ct-constraint-*`).


import isonim_gpui/renderer
import isonim/core/[signals, computation]

import codetracer_embed
import ./window_geometry
import ./chrome
import ./app/leaves
import ./list_scrubber
import ../viewmodel/viewmodels/constraints_vm
from ../viewmodel/viewmodels/table_overflow import nil
from ../../common/view_vocabulary/layout_questions import trEditorCode
import ../styles/generated/design_tokens

type
  GConstraintsPane* = object
    ## The window's own state for the pane: where the reader scrolled and a
    ## held scrubber thumb. The selection is the ViewModel's.
    scrollTop*: int
    dragging*: bool

  ConstraintsLayout* = object
    body*: PxRect
    headline*: PxRect
    notice*: PxRect
      ## Zero height when there is no notice.
    list*: PxRect
    provenance*: PxRect
      ## Zero height when there is no provenance line.
    rows*: int
    overflow*: bool
    total*: int
      ## How many rows the list has.
    fit*: TableFit
      ## A function row's parts, in pixels from `list.x`.

  GConstraintsHitKind* = enum
    gcNone, gcRow, gcTrack, gcThumb, gcText

  GConstraintsHit* = object
    kind*: GConstraintsHitKind
    index*: int
      ## gcRow: the row's index in the ViewModel's rows.
    fraction*: float

const
  ConstraintsRowPx* = 22
  ConstraintsLinePx* = 22
    ## The headline, the notice and the provenance line.
  ConstraintsGapPx = 6
    ## The desktop row's `column-gap: 6px`.
  ConstraintsIndentPx = 16
    ## An opcode row's `padding-left: 1em`.
  ConstraintsAttribute* = "data-ct-constraints"
    ## On the pane: its headline.
  ConstraintRowAttribute* = "data-ct-constraint-row"
    ## On a row: its index in the ViewModel's rows, with `data-ct-constraint-*`.
  ConstraintsTextColour* = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  ConstraintsCaptionColour* = "#8b949e"
    ## The desktop's dimmed parts (kind, where, provenance) at their opacity.
  ConstraintsSelectedGround* =
    DesignTokenHex[dtColorsUiSurfacePrimarySecondaryHover][dmDark]
    ## `.constraints-row.selected` — the Test Results row's selected ground.

proc initGConstraintsPane*(): GConstraintsPane = GConstraintsPane()

proc pxOf(text: string): int =
  int(float(table_overflow.runeMeasure(text)) * EditorColumnPx)

proc cellsOf(px: int): int = int(float(px) / EditorColumnPx)

proc constraintsLayout*(vm: ConstraintsVM; body: PxRect): ConstraintsLayout =
  ## The pane's parts, in window pixels, inside `body` (its padding off).
  result.body = body
  let inner = PxRect(x: body.x + ChromePaddingPx, y: body.y + ChromePaddingPx,
                     w: max(0, body.w - 2 * ChromePaddingPx),
                     h: max(0, body.h - 2 * ChromePaddingPx))
  let report = vm.report.val
  var y = inner.y
  result.headline = PxRect(x: inner.x, y: y, w: inner.w, h: ConstraintsLinePx)
  y += ConstraintsLinePx
  if listingNoticeFor(report).len > 0:
    result.notice = PxRect(x: inner.x, y: y, w: inner.w, h: ConstraintsLinePx)
    y += ConstraintsLinePx
  var bottom = inner.y + inner.h
  let provenanceShown = report.absence.len == 0 and
                        report.provenance.len > 0 and
                        bottom - y >= 2 * ConstraintsLinePx
  if provenanceShown:
    bottom -= ConstraintsLinePx
    result.provenance = PxRect(x: inner.x, y: bottom, w: inner.w,
                               h: ConstraintsLinePx)
  let rows = vm.rows.val
  result.total = rows.len
  result.rows = max(0, (bottom - y) div ConstraintsRowPx)
  result.overflow = result.total > result.rows
  var width = inner.w
  if result.overflow:
    width = max(0, inner.w - ListTrackPx - 2)
  result.list = PxRect(x: inner.x, y: y, w: width,
                       h: result.rows * ConstraintsRowPx)
  var name, kind, count, where = 0
  for r in rows:
    if r.kind != crkFunction:
      continue
    name = max(name, pxOf(r.name))
    kind = max(kind, pxOf(r.kindLabel))
    count = max(count, pxOf(r.count))
    where = max(where, pxOf(whereText(r.source)))
  result.fit = constraintsFit(name, kind, count, where, width,
                              unit = int(EditorColumnPx), gap = ConstraintsGapPx)

proc listBody(lay: ConstraintsLayout): PxRect =
  PxRect(x: lay.body.x, y: lay.list.y - ChromePaddingPx, w: lay.body.w,
         h: lay.list.h + 2 * ChromePaddingPx)

proc visibleTop*(st: GConstraintsPane; total, rows: int): int =
  max(0, min(st.scrollTop, total - max(1, rows)))

proc scrubberOf*(st: GConstraintsPane; total, rows: int): ScrubberModel =
  scrubberModel(total, st.visibleTop(total, rows), rows)

proc revealIndex*(st: var GConstraintsPane; vm: ConstraintsVM; body: PxRect;
                  index: int) =
  ## Keep row `index` in view.
  let lay = constraintsLayout(vm, body)
  if index < 0 or index >= lay.total or lay.rows <= 0:
    return
  let top = st.visibleTop(lay.total, lay.rows)
  if index < top: st.scrollTop = index
  elif index >= top + lay.rows: st.scrollTop = index - lay.rows + 1

proc scrollBy*(st: var GConstraintsPane; vm: ConstraintsVM; body: PxRect;
               delta: int) =
  let lay = constraintsLayout(vm, body)
  st.scrollTop = max(0, min(st.visibleTop(lay.total, lay.rows) + delta,
                            lay.total - max(1, lay.rows)))

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

proc lineElement(r: GpuiRenderer; widthPx, heightPx: int): GpuiElement =
  result = r.createElement("div")
  for (k, v) in [("display", "flex"), ("white-space", "nowrap"),
                 ("overflow", "hidden"), ("flex-shrink", "0"),
                 ("items", "center")]:
    r.setStyle(result, k, v)
  r.setStyle(result, "height", $heightPx & "px")
  r.setStyle(result, "width", $widthPx & "px")
  r.setAttribute(result, TextMetricAttribute, gpuiMetricFor(trEditorCode))

proc cut(text: string; px: int): string =
  ## `text` in a column `px` wide, ending in `…` when cut.
  fitCell(text, cellsOf(px)).text

proc drawConstraints*(r: GpuiRenderer; pane: GpuiElement; vm: ConstraintsVM;
                      st: GConstraintsPane; body: PxRect): bool =
  ## Draw the pane into `pane` (its children replaced), its body at `body` in
  ## window pixels. False when there is nothing to draw it from.
  if pane.isNil or vm.isNil:
    return false
  while childCount(pane) > 0:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  r.setStyle(pane, "position", "relative")
  r.setStyle(pane, "display", "flex")
  r.setStyle(pane, "flex-direction", "column")
  let lay = constraintsLayout(vm, body)
  let report = vm.report.val
  let stale = report.stale and report.absence.len == 0
  r.setAttribute(pane, ConstraintsAttribute, vm.headline.val)
  r.setAttribute(pane, "data-ct-constraints-stale", $stale)
  # The headline — dimmed with the rows while stale (its `(stale)` says why).
  let head = lineElement(r, lay.headline.w, ConstraintsLinePx)
  r.setAttribute(head, "data-ct-constraints-headline", vm.headline.val)
  r.appendChild(head, textRun(r, cut(vm.headline.val, lay.headline.w),
                              if stale: ConstraintsCaptionColour
                              else: ConstraintsTextColour))
  r.appendChild(pane, head)
  if report.absence.len > 0:
    let el = r.createElement("div")
    r.setAttribute(el, "data-ct-constraints-absence", report.absence)
    r.setStyle(el, "color", ConstraintsCaptionColour)
    r.setStyle(el, "white-space", "normal")
    r.appendChild(el, r.createTextNode(report.absence))
    r.appendChild(pane, el)
    return true
  let notice = listingNoticeFor(report)
  if lay.notice.h > 0:
    let el = lineElement(r, lay.notice.w, ConstraintsLinePx)
    r.setAttribute(el, "data-ct-constraints-notice", notice)
    r.appendChild(el, textRun(r, cut(notice, lay.notice.w),
                              ConstraintsCaptionColour))
    r.appendChild(pane, el)
  let rows = vm.rows.val
  let top = st.visibleTop(lay.total, lay.rows)
  r.setAttribute(pane, "data-ct-constraints-top", $top)
  r.setAttribute(pane, "data-ct-constraints-rows", $lay.rows)
  r.setAttribute(pane, "data-ct-constraints-total", $lay.total)
  let f = lay.fit
  for k in 0 ..< lay.rows:
    let i = top + k
    if i >= rows.len:
      break
    let row = rows[i]
    let el = lineElement(r, lay.list.w, ConstraintsRowPx)
    r.setAttribute(el, ConstraintRowAttribute, $i)
    r.setAttribute(el, "data-ct-constraint-kind", $row.kind)
    r.setAttribute(el, "data-ct-constraint-name", row.name)
    r.setAttribute(el, "data-ct-constraint-where", whereText(row.source))
    r.setAttribute(el, "data-ct-constraint-linked", $row.source.linked)
    r.setAttribute(el, "data-ct-constraint-title", rowTitle(row))
    if i == vm.selected.val:
      r.setAttribute(el, "data-ct-selected", "true")
      r.setStyle(el, "background", ConstraintsSelectedGround)
    let dim = stale or not row.source.linked or
              row.kindLabel == kindLabelOf(cfkUnconstrained)
    let main = if dim: ConstraintsCaptionColour else: ConstraintsTextColour
    case row.kind
    of crkFunction:
      r.setStyle(el, "gap", $ConstraintsGapPx & "px")
      let name = textRun(r, cut(row.name, f.widths[0]), main, f.widths[0])
      r.setAttribute(name, "data-ct-constraint-part", "name")
      r.appendChild(el, name)
      let kind = textRun(r, row.kindLabel, ConstraintsCaptionColour,
                         f.widths[1])
      r.setAttribute(kind, "data-ct-constraint-part", "kind")
      r.appendChild(el, kind)
      let count = textRun(r, row.count,
                          if stale: ConstraintsCaptionColour
                          else: ConstraintsTextColour, f.widths[2])
      r.setStyle(count, "text-align", "right")
      r.setAttribute(count, "data-ct-constraint-part", "count")
      r.appendChild(el, count)
      let where = textRun(r, cut(whereText(row.source), f.widths[3]),
                          ConstraintsCaptionColour, f.widths[3])
      r.setAttribute(where, "data-ct-constraint-part", "where")
      r.appendChild(el, where)
    of crkOpcode:
      r.setStyle(el, "padding-left", $ConstraintsIndentPx & "px")
      let text = row.count & " " & row.name &
                 (if row.args.len > 0: " " & row.args else: "")
      r.setAttribute(el, "data-ct-constraint-text", text)
      r.appendChild(el, textRun(r, cut(text, lay.list.w - ConstraintsIndentPx),
                                main))
    r.appendChild(pane, el)
  if lay.provenance.h > 0:
    let el = lineElement(r, lay.provenance.w, ConstraintsLinePx)
    r.setAttribute(el, "data-ct-constraints-provenance", report.provenance)
    r.setStyle(el, "position", "absolute")
    r.setStyle(el, "top", $(lay.provenance.y - body.y) & "px")
    r.appendChild(el, textRun(r, cut(report.provenance, lay.provenance.w),
                              ConstraintsCaptionColour))
    r.appendChild(pane, el)
  if lay.overflow:
    drawListScrubber(r, pane, lay.listBody,
                     st.scrubberOf(lay.total, lay.rows), "constraints")
  true

proc constraintsHitAt*(vm: ConstraintsVM; st: GConstraintsPane; body: PxRect;
                       x, y: int): GConstraintsHit =
  ## What a press at window pixel `(x, y)` is on, by the drawing's layout.
  result = GConstraintsHit(kind: gcNone, index: -1)
  if vm.isNil or not body.contains(x, y):
    return
  let lay = constraintsLayout(vm, body)
  if lay.overflow:
    let hit = listScrubHit(lay.listBody, st.scrubberOf(lay.total, lay.rows),
                           x, y)
    if hit.onTrack:
      return GConstraintsHit(kind: (if hit.onThumb: gcThumb else: gcTrack),
                             index: -1, fraction: hit.fraction)
  if not lay.list.contains(x, y):
    return GConstraintsHit(kind: gcText, index: -1)
  let i = st.visibleTop(lay.total, lay.rows) +
          (y - lay.list.y) div ConstraintsRowPx
  if i < 0 or i >= lay.total:
    return
  result = GConstraintsHit(kind: gcRow, index: i)

proc scrubConstraints*(st: var GConstraintsPane; vm: ConstraintsVM;
                       body: PxRect; y: int; dragging: bool) =
  ## The scrubber pressed (a jump) or its thumb held (the view follows).
  let lay = constraintsLayout(vm, body)
  if not lay.overflow:
    return
  let track = listTrackRect(lay.listBody)
  let sm = st.scrubberOf(lay.total, lay.rows)
  st.scrollTop = sm.scrubTop(trackFractionAt(y - track.y, track.h), dragging)

proc rowCentre*(lay: ConstraintsLayout; st: GConstraintsPane;
                index: int): tuple[ok: bool, x, y: int] =
  ## Where row `index` is drawn (its name's start), for a press aimed at it.
  let top = st.visibleTop(lay.total, lay.rows)
  if index < top or index >= top + lay.rows:
    return (false, 0, 0)
  (true, lay.list.x + 4,
   lay.list.y + (index - top) * ConstraintsRowPx + ConstraintsRowPx div 2)
