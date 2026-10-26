## gpui/problems_leaf.nim — PLAT-55. The GPUI window's **Problems** pane, drawn
## natively from the window's `ErrorsVM` (the model the desktop's panel and
## the terminal's pane draw), which the window's builds feed
## (`tui/host/build_problems`).
##
## What the desktop's panel draws, in its order and words
## (`viewmodel/views/isonim_errors_view.nim`, Build-Output-Pane.md §3.3): a
## header — the error, warning and total counts, what navigation last
## announced, and the All / Errors / Warnings / Group by File buttons — over
## the diagnostics, each its severity icon, path, location and message,
## grouped under file headers when grouping by file, or "No problems
## detected.". Every word is the ViewModel's. The rows have a fixed pitch so a
## press and the drawing go through one layout (`problemsLayout`), as Test
## Results' do; the list scrolls (the wheel) and its scrollbar is the shared
## list scrubber, moving the VIEW. The selected diagnostic — the cursor a
## press, the keys and `next error` share — is drawn on the desktop's
## selected-row ground with its accent edge.
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-problems-*`, `data-ct-problem-*`).

import isonim_gpui/renderer
import isonim/core/[signals, computation]

import codetracer_embed
import ./window_geometry
import ./chrome
import ./app/leaves
import ./list_scrubber
import ../viewmodel/viewmodels/errors_vm
from ../viewmodel/viewmodels/table_overflow import nil
import ../viewmodel/store/types
from ../../common/view_vocabulary/layout_questions import trEditorCode
import ../styles/generated/design_tokens

type
  GProblemsPane* = object
    ## The window's own state for the pane: where the reader scrolled and a
    ## held scrubber thumb. The selection is the ViewModel's.
    scrollTop*: int
    dragging*: bool

  ProblemsLayout* = object
    body*: PxRect
    header*: PxRect
    buttons*: seq[PxRect]
      ## The filters in `ProblemFilterTag` order, then Group by File.
    list*: PxRect
    rows*: int
    overflow*: bool
    lines*: seq[ProblemsDisplayRow]
    fit*: TableFit
      ## The row's parts, in pixels from `list.x`.

  GProblemsHitKind* = enum
    gpNone, gpFilter, gpGroup, gpRow, gpHeader, gpTrack, gpThumb, gpText

  GProblemsHit* = object
    kind*: GProblemsHitKind
    index*: int
      ## gpFilter: the filter; gpRow: the diagnostic's master index.
    fraction*: float

const
  ProblemsRowPx* = 22
  ProblemsHeaderPx* = 26
  ProblemsIconPx = 16
    ## The desktop's `.problems-icon { width: 16px }`.
  ProblemsGapPx = 8
    ## The desktop row's `gap: 8px`.
  ProblemsButtonPadPx = 8
    ## `.problems-filter-btn { padding: 0 8px }`.
  ProblemsButtonGapPx = 4
    ## `.problems-controls { gap: 4px }`.
  ProblemsAttribute* = "data-ct-problems"
    ## On the pane: its total badge.
  ProblemRowAttribute* = "data-ct-problem-index"
    ## On a diagnostic's row: its master index, with `data-ct-problem-*`.
  ProblemButtonAttribute* = "data-ct-problems-button"
    ## On a header button: its label, `data-ct-active`.
  ProblemLineAttribute* = "data-ct-problems-line"
    ## On a file header or the empty state: `file` / `empty`.
  ProblemsTextColour = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  ProblemsCaptionColour* = "#8b949e"
    ## `.problems-path` / `.problems-location` / `.problems-file-header`, dark
    ## (`by-mode(#8b949e, …)`).
  ProblemsErrorColour* = "#f85149"
    ## `.problems-icon-error` / `.problems-count-error`.
  ProblemsWarningColour* = "#d29922"
    ## `.problems-icon-warning` / `.problems-count-warning`, dark.
  ProblemsInfoColour* = "#58a6ff"
    ## `.problems-icon-info`, dark.
  ProblemsSelectedGround* =
    DesignTokenHex[dtColorsUiSurfacePrimarySecondaryHover][dmDark]
    ## `.problems-row-selected`.
  ProblemsSelectedEdge =
    DesignTokenHex[dtColorsUiSurfaceActionPrimary][dmDark]
    ## Its `inset 0.1875em 0 0` accent.
  ProblemsActiveGround =
    DesignTokenHex[dtColorsUiSurfaceInputDefault][dmDark]
    ## `.problems-filter-btn.active`.

proc initGProblemsPane*(): GProblemsPane = GProblemsPane()

proc pxOf(text: string): int =
  int(float(table_overflow.runeMeasure(text)) * EditorColumnPx)

proc cellsOf(px: int): int = int(float(px) / EditorColumnPx)

proc severityColour*(severity: BuildLineSeverity): string =
  case severity
  of blsError: ProblemsErrorColour
  of blsWarning: ProblemsWarningColour
  of blsInfo, blsNone: ProblemsInfoColour

proc buttonLabels(vm: ErrorsVM): seq[string] =
  for tag in ProblemFilterTag:
    result.add ProblemFilterLabels[tag]
  result.add GroupByFileLabel

proc problemsLayout*(vm: ErrorsVM; body: PxRect): ProblemsLayout =
  ## The pane's parts, in window pixels, inside `body` (its padding off).
  result.body = body
  let inner = PxRect(x: body.x + ChromePaddingPx, y: body.y + ChromePaddingPx,
                     w: max(0, body.w - 2 * ChromePaddingPx),
                     h: max(0, body.h - 2 * ChromePaddingPx))
  result.header = PxRect(x: inner.x, y: inner.y, w: inner.w,
                         h: ProblemsHeaderPx)
  # The buttons right-aligned (`justify-content: space-between`).
  var widths: seq[int] = @[]
  var total = 0
  for label in vm.buttonLabels:
    let w = pxOf(label) + 2 * ProblemsButtonPadPx
    widths.add w
    total += w
  total += ProblemsButtonGapPx * max(0, widths.len - 1)
  var x = inner.x + inner.w - total
  for w in widths:
    result.buttons.add PxRect(x: x, y: inner.y, w: w, h: ProblemsHeaderPx)
    x += w + ProblemsButtonGapPx
  let top = inner.y + ProblemsHeaderPx + 2
  let rest = max(0, inner.y + inner.h - top)
  result.rows = max(0, rest div ProblemsRowPx)
  result.lines = vm.displayRows()
  result.overflow = result.lines.len > result.rows
  var width = inner.w
  if result.overflow:
    width = max(0, inner.w - ListTrackPx - 2)
  result.list = PxRect(x: inner.x, y: top, w: width,
                       h: result.rows * ProblemsRowPx)
  var path, location, message = 0
  for p in vm.problems.val:
    path = max(path, pxOf(p.path))
    location = max(location, pxOf(locationText(p)))
    message = max(message, pxOf(p.message))
  result.fit = problemsFit(ProblemsIconPx, path, location, message, width,
                           ProblemsGapPx)

proc listBody(lay: ProblemsLayout): PxRect =
  PxRect(x: lay.body.x, y: lay.list.y - ChromePaddingPx, w: lay.body.w,
         h: lay.list.h + 2 * ChromePaddingPx)

proc visibleTop*(st: GProblemsPane; total, rows: int): int =
  max(0, min(st.scrollTop, total - max(1, rows)))

proc scrubberOf*(st: GProblemsPane; total, rows: int): ScrubberModel =
  scrubberModel(total, st.visibleTop(total, rows), rows)

proc lineOfIndex*(lay: ProblemsLayout; index: int): int =
  for i, line in lay.lines:
    if line.kind == pdRow and line.index == index:
      return i
  -1

proc revealIndex*(st: var GProblemsPane; vm: ErrorsVM; body: PxRect;
                  index: int) =
  ## Keep diagnostic `index` (master) in view.
  let lay = problemsLayout(vm, body)
  let at = lay.lineOfIndex(index)
  if at < 0 or lay.rows <= 0:
    return
  let top = st.visibleTop(lay.lines.len, lay.rows)
  if at < top: st.scrollTop = at
  elif at >= top + lay.rows: st.scrollTop = at - lay.rows + 1

proc scrollBy*(st: var GProblemsPane; vm: ErrorsVM; body: PxRect;
               delta: int) =
  let lay = problemsLayout(vm, body)
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
  r.setStyle(result, "height", $ProblemsRowPx & "px")
  r.setStyle(result, "width", $widthPx & "px")
  r.setAttribute(result, TextMetricAttribute, gpuiMetricFor(trEditorCode))

proc cut(text: string; px: int): string =
  ## `text` in a column `px` wide, ending in `…` when cut.
  fitCell(text, cellsOf(px)).text

proc drawProblems*(r: GpuiRenderer; pane: GpuiElement; vm: ErrorsVM;
                   st: GProblemsPane; body: PxRect): bool =
  ## Draw the pane into `pane` (its children replaced), its body at `body` in
  ## window pixels. False when there is nothing to draw it from.
  if pane.isNil or vm.isNil:
    return false
  while childCount(pane) > 0:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  r.setStyle(pane, "position", "relative")
  r.setStyle(pane, "display", "flex")
  r.setStyle(pane, "flex-direction", "column")
  let lay = problemsLayout(vm, body)
  r.setAttribute(pane, ProblemsAttribute, vm.totalBadgeText)
  r.setAttribute(pane, "data-ct-problems-status", vm.statusMessage.val)
  # The header: the counts, the status, the buttons.
  let header = r.createElement("div")
  for (k, v) in [("display", "flex"), ("flex-shrink", "0"),
                 ("items", "center"), ("gap", "12px")]:
    r.setStyle(header, k, v)
  r.setStyle(header, "height", $ProblemsHeaderPx & "px")
  let countsPx = max(0, (if lay.buttons.len > 0: lay.buttons[0].x
                         else: lay.header.x + lay.header.w) - lay.header.x)
  var used = 0
  for (attr, text, colour) in [("errors", vm.errorBadgeText,
                                ProblemsErrorColour),
                               ("warnings", vm.warningBadgeText,
                                ProblemsWarningColour),
                               ("total", vm.totalBadgeText, ProblemsTextColour),
                               ("status", vm.statusMessage.val,
                                ProblemsCaptionColour)]:
    if text.len == 0:
      continue
    let w = min(pxOf(text), max(0, countsPx - used))
    let el = textRun(r, cut(text, w), colour, w)
    r.setAttribute(el, "data-ct-problems-" & attr, text)
    r.appendChild(header, el)
    used += w + 12
  let spacer = r.createElement("div")
  r.setStyle(spacer, "flex-grow", "1")
  r.appendChild(header, spacer)
  let labels = vm.buttonLabels
  for i, rect in lay.buttons:
    let active = if i < ord(high(ProblemFilterTag)) + 1:
                   vm.filter.val == ProblemFilterTag(i)
                 else: vm.groupByFile.val
    let b = textRun(r, labels[i], ProblemsTextColour, rect.w)
    r.setAttribute(b, ProblemButtonAttribute, labels[i])
    r.setAttribute(b, "data-ct-active", $active)
    r.setStyle(b, "text-align", "center")
    if active:
      r.setStyle(b, "background", ProblemsActiveGround)
      r.setStyle(b, "font-weight", "600")
    r.appendChild(header, b)
  r.appendChild(pane, header)
  # The list.
  let problems = vm.problems.val
  let top = st.visibleTop(lay.lines.len, lay.rows)
  r.setAttribute(pane, "data-ct-problems-top", $top)
  r.setAttribute(pane, "data-ct-problems-rows", $lay.rows)
  r.setAttribute(pane, "data-ct-problems-total-lines", $lay.lines.len)
  let f = lay.fit
  for k in 0 ..< lay.rows:
    let i = top + k
    if i >= lay.lines.len:
      break
    let line = lay.lines[i]
    let el = rowElement(r, lay.list.w)
    case line.kind
    of pdRow:
      let p = problems[line.index]
      r.setAttribute(el, ProblemRowAttribute, $line.index)
      r.setAttribute(el, "data-ct-problem-severity",
                     severityClassSuffix(p.severity))
      r.setStyle(el, "gap", $ProblemsGapPx & "px")
      if line.index == vm.selectedIndex.val:
        r.setAttribute(el, "data-ct-selected", "true")
        r.setStyle(el, "background", ProblemsSelectedGround)
        r.setStyle(el, "border-left", "3px solid " & ProblemsSelectedEdge)
      let icon = textRun(r, severityIcon(p.severity),
                         severityColour(p.severity), f.widths[0])
      r.setAttribute(icon, "data-ct-problem-icon", severityIcon(p.severity))
      r.setAttribute(icon, "data-ct-colour", severityColour(p.severity))
      r.appendChild(el, icon)
      let path = textRun(r, cut(p.path, f.widths[1]), ProblemsCaptionColour,
                         f.widths[1])
      r.setAttribute(path, "data-ct-problem-path", p.path)
      r.appendChild(el, path)
      let location = textRun(r, locationText(p), ProblemsCaptionColour,
                             f.widths[2])
      r.setAttribute(location, "data-ct-problem-location", locationText(p))
      r.appendChild(el, location)
      let message = textRun(r, cut(p.message, f.widths[3]),
                            ProblemsTextColour, f.widths[3])
      r.setAttribute(message, "data-ct-problem-message", p.message)
      r.appendChild(el, message)
    of pdFileHeader:
      r.setAttribute(el, ProblemLineAttribute, "file")
      r.setAttribute(el, "data-ct-text", line.text)
      let t = textRun(r, line.text, ProblemsCaptionColour)
      r.setStyle(t, "font-weight", "600")
      r.appendChild(el, t)
    of pdEmpty:
      r.setAttribute(el, ProblemLineAttribute, "empty")
      r.setAttribute(el, "data-ct-text", line.text)
      r.appendChild(el, textRun(r, line.text, ProblemsCaptionColour))
    r.appendChild(pane, el)
  if lay.overflow:
    drawListScrubber(r, pane, lay.listBody,
                     st.scrubberOf(lay.lines.len, lay.rows), "problems")
  true

proc problemsHitAt*(vm: ErrorsVM; st: GProblemsPane; body: PxRect;
                    x, y: int): GProblemsHit =
  ## What a press at window pixel `(x, y)` is on, by the drawing's layout.
  result = GProblemsHit(kind: gpNone, index: -1)
  if vm.isNil or not body.contains(x, y):
    return
  let lay = problemsLayout(vm, body)
  for i, rect in lay.buttons:
    if rect.contains(x, y):
      if i <= ord(high(ProblemFilterTag)):
        return GProblemsHit(kind: gpFilter, index: i)
      return GProblemsHit(kind: gpGroup, index: -1)
  if lay.overflow:
    let hit = listScrubHit(lay.listBody, st.scrubberOf(lay.lines.len,
                                                       lay.rows), x, y)
    if hit.onTrack:
      return GProblemsHit(kind: (if hit.onThumb: gpThumb else: gpTrack),
                          index: -1, fraction: hit.fraction)
  if not lay.list.contains(x, y):
    return
  let i = st.visibleTop(lay.lines.len, lay.rows) +
          (y - lay.list.y) div ProblemsRowPx
  if i < 0 or i >= lay.lines.len:
    return
  let line = lay.lines[i]
  result = case line.kind
    of pdRow: GProblemsHit(kind: gpRow, index: line.index)
    of pdFileHeader: GProblemsHit(kind: gpHeader, index: -1)
    of pdEmpty: GProblemsHit(kind: gpText, index: -1)

proc scrubProblems*(st: var GProblemsPane; vm: ErrorsVM; body: PxRect;
                    y: int; dragging: bool) =
  ## The scrubber pressed (a jump) or its thumb held (the view follows).
  let lay = problemsLayout(vm, body)
  if not lay.overflow:
    return
  let track = listTrackRect(lay.listBody)
  let sm = st.scrubberOf(lay.lines.len, lay.rows)
  st.scrollTop = sm.scrubTop(trackFractionAt(y - track.y, track.h), dragging)

proc rowCentre*(lay: ProblemsLayout; st: GProblemsPane;
                index: int): tuple[ok: bool, x, y: int] =
  ## Where diagnostic `index`'s row is drawn (its message's start), for a
  ## press aimed at it.
  let at = lay.lineOfIndex(index)
  let top = st.visibleTop(lay.lines.len, lay.rows)
  if at < top or at >= top + lay.rows:
    return (false, 0, 0)
  (true, lay.list.x + lay.fit.starts[min(3, lay.fit.starts.high)] + 4,
   lay.list.y + (at - top) * ProblemsRowPx + ProblemsRowPx div 2)
