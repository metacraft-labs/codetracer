## gpui/search_results_leaf.nim — PLAT-57. The GPUI window's **Find in Files**
## pane, drawn natively from the shared `SearchResultsVM` (the model the
## desktop's panel and the terminal's pane draw).
##
## What the desktop's panel draws, in its order and words: the query field
## (here showing the query the omnibox's `:grep` searched for — the window's
## field is the omnibox, as the terminal's is), the Match Case (`Aa`), Match
## Whole Word (`ab`) and Use Regular Expression (`.*`) toggles, a line saying
## where the search is, then the
## results grouped by file — each group's header (`shortResultPath ·
## N matches`) and its matching lines (the line number, the text, the
## runner's match on the desktop's `.fif-highlight` colour). Rows have a fixed
## pitch, so a press and the drawing go through the same layout
## (`searchLayout`), as the Terminal Output's do; the list scrolls (the wheel)
## and its scrollbar is the shared scrubber (`list_scrubber`), moving the VIEW.
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-search-*`).

import isonim_gpui/renderer

import codetracer_embed
import ./window_geometry
import ./chrome
import ./app/leaves
import ./list_scrubber
import ../viewmodel/viewmodels/search_results_vm
from ../../common/view_vocabulary/layout_questions import trEditorCode
import ../styles/generated/design_tokens

type
  GSearchPane* = object
    ## The window's own state for the pane: where the reader scrolled, and a
    ## held scrubber thumb.
    scrollTop*: int
    dragging*: bool

  SearchLayout* = object
    body*: PxRect
    field*: PxRect
    optionBoxes*: array[SearchOption, PxRect]
      ## The three toggles, in the ViewModel's order.
    summary*: PxRect
    list*: PxRect
      ## The rows' area (the scrubber's column off when the list overflows).
    rows*: int
      ## How many rows fit.
    overflow*: bool

  GSearchHitKind* = enum
    gsNone, gsQuery, gsOption, gsFile, gsMatch, gsTrack, gsThumb

  GSearchHit* = object
    kind*: GSearchHitKind
    index*: int
      ## gsMatch: the result's index.
    option*: SearchOption
      ## gsOption: the toggle.
    fraction*: float

const
  SearchRowPx* = 22
  SearchFieldPx* = 26
  SearchOptionPx* = 26
  SearchSummaryPx* = 22
  SearchAttribute* = "data-ct-search"
  SearchRowAttribute* = "data-ct-search-row"
    ## A match row: its result index.
  SearchFileAttribute* = "data-ct-search-file"
    ## A file header: its path.
  SearchOptionAttribute* = "data-ct-search-option"
    ## A toggle: `case` / `word` / `regex`; `data-ct-active` says whether it
    ## is set.
  SearchTextColour = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  SearchMutedColour = DesignTokenHex[dtColorsUiTextPrimaryBodySubtle][dmDark]
  SearchHeaderGround = DesignTokenHex[dtColorsUiSurfacePrimaryTertiary][dmDark]
  SearchSelectedGround =
    DesignTokenHex[dtColorsUiSurfacePrimarySecondaryHover][dmDark]
  SearchFieldGround = DesignTokenHex[dtColorsUiSurfaceInputDefault][dmDark]
  SearchHitGround* = "#fb923c4d"
    ## The desktop's `.fif-highlight`: rgba(251, 146, 60, 0.30).
  SearchPlaceholder = "Search in files..."

proc initGSearchPane*(): GSearchPane = GSearchPane()

proc searchLayout*(body: PxRect; total: int): SearchLayout =
  ## The pane's parts, in window pixels, inside `body` (its padding off).
  result.body = body
  let inner = PxRect(x: body.x + ChromePaddingPx, y: body.y + ChromePaddingPx,
                     w: max(0, body.w - 2 * ChromePaddingPx),
                     h: max(0, body.h - 2 * ChromePaddingPx))
  let options = SearchOption.high.ord + 1
  result.field = PxRect(x: inner.x, y: inner.y,
                        w: max(0, inner.w - options * (SearchOptionPx + 4)),
                        h: SearchFieldPx)
  for o in SearchOption:
    result.optionBoxes[o] = PxRect(
      x: result.field.x + result.field.w + 4 + o.ord * (SearchOptionPx + 4),
      y: inner.y, w: SearchOptionPx, h: SearchFieldPx)
  result.summary = PxRect(x: inner.x, y: inner.y + SearchFieldPx + 2,
                          w: inner.w, h: SearchSummaryPx)
  let top = result.summary.y + SearchSummaryPx
  let rest = max(0, inner.y + inner.h - top)
  result.rows = max(0, rest div SearchRowPx)
  result.overflow = total > result.rows
  result.list = PxRect(x: inner.x, y: top,
                       w: max(0, inner.w - (if result.overflow: ListTrackPx + 2
                                            else: 0)),
                       h: result.rows * SearchRowPx)

proc listBody(lay: SearchLayout): PxRect =
  ## The rectangle the scrubber's track is placed in: the list's rows, at the
  ## pane's right edge (`list_scrubber.listTrackRect` takes off the padding).
  PxRect(x: lay.body.x, y: lay.list.y - ChromePaddingPx, w: lay.body.w,
         h: lay.list.h + 2 * ChromePaddingPx)

proc visibleTop*(st: GSearchPane; total, rows: int): int =
  max(0, min(st.scrollTop, total - max(1, rows)))

proc scrubberOf*(st: GSearchPane; total, rows: int): ScrubberModel =
  scrubberModel(total, st.visibleTop(total, rows), rows)

proc revealResult*(st: var GSearchPane; vm: SearchResultsVM; body: PxRect;
                   index: int) =
  ## Keep result `index`'s row in view (a click, `:cnext`).
  let rows = vm.displayRows()
  let at = rows.displayRowOf(index)
  let lay = searchLayout(body, rows.len)
  if at < 0 or lay.rows <= 0:
    return
  let top = st.visibleTop(rows.len, lay.rows)
  if at < top: st.scrollTop = at
  elif at >= top + lay.rows: st.scrollTop = at - lay.rows + 1

proc scrollBy*(st: var GSearchPane; vm: SearchResultsVM; body: PxRect;
               delta: int) =
  let total = vm.displayRows().len
  let lay = searchLayout(body, total)
  st.scrollTop = max(0, min(st.visibleTop(total, lay.rows) + delta,
                            total - max(1, lay.rows)))

proc textRun(r: GpuiRenderer; text, colour: string; ground = ""): GpuiElement =
  result = r.createElement("span")
  r.setStyle(result, "color", colour)
  r.setStyle(result, "white-space", "pre")
  r.setStyle(result, "flex-shrink", "0")
  if ground.len > 0:
    r.setStyle(result, "background", ground)
    r.setStyle(result, "rounded", "2px")
  r.appendChild(result, r.createTextNode(text))

proc rowElement(r: GpuiRenderer; widthPx: int; monospace: bool): GpuiElement =
  result = r.createElement("div")
  for (k, v) in [("display", "flex"), ("white-space", "nowrap"),
                 ("overflow", "hidden"), ("flex-shrink", "0"),
                 ("items", "center")]:
    r.setStyle(result, k, v)
  r.setStyle(result, "height", $SearchRowPx & "px")
  r.setStyle(result, "width", $widthPx & "px")
  if monospace:
    r.setAttribute(result, TextMetricAttribute, gpuiMetricFor(trEditorCode))

proc drawSearchResults*(r: GpuiRenderer; pane: GpuiElement;
                        vm: SearchResultsVM; st: GSearchPane;
                        body: PxRect): bool =
  ## Draw the pane into `pane` (its children replaced), its body at `body` in
  ## window pixels. False when there is nothing to draw it from.
  if pane.isNil or vm.isNil:
    return false
  while childCount(pane) > 0:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  r.setStyle(pane, "position", "relative")
  r.setStyle(pane, "display", "flex")
  r.setStyle(pane, "flex-direction", "column")
  let rows = vm.displayRows()
  let lay = searchLayout(body, rows.len)
  r.setAttribute(pane, SearchAttribute, vm.query.val)
  # The field, then the three toggles.
  let bar = r.createElement("div")
  for (k, v) in [("display", "flex"), ("flex-shrink", "0"), ("items", "center"),
                 ("gap", "4px")]:
    r.setStyle(bar, k, v)
  r.setStyle(bar, "height", $SearchFieldPx & "px")
  let field = r.createElement("div")
  r.setAttribute(field, "data-ct-search-field", "")
  r.setStyle(field, "width", $lay.field.w & "px")
  r.setStyle(field, "height", $(SearchFieldPx - 2) & "px")
  r.setStyle(field, "background", SearchFieldGround)
  r.setStyle(field, "rounded", "3px")
  r.setStyle(field, "padding-left", "6px")
  r.setStyle(field, "items", "center")
  r.setStyle(field, "display", "flex")
  let q = vm.query.val
  r.appendChild(field, textRun(r, (if q.len > 0: q else: SearchPlaceholder),
                               (if q.len > 0: SearchTextColour
                                else: SearchMutedColour)))
  r.appendChild(bar, field)
  let o = vm.options.val
  for which in SearchOption:
    let on = o.isOn(which)
    let b = r.createElement("div")
    r.setAttribute(b, SearchOptionAttribute, $which)
    r.setAttribute(b, "data-ct-active", $on)
    r.setStyle(b, "width", $SearchOptionPx & "px")
    r.setStyle(b, "height", $(SearchFieldPx - 4) & "px")
    r.setStyle(b, "display", "flex")
    r.setStyle(b, "items", "center")
    r.setStyle(b, "justify", "center")
    r.setStyle(b, "rounded", "3px")
    r.setStyle(b, "color", if on: SearchTextColour else: SearchMutedColour)
    if on:
      r.setStyle(b, "background", SearchSelectedGround)
    r.appendChild(b, r.createTextNode(SearchOptionLabels[which]))
    r.appendChild(bar, b)
  r.appendChild(pane, bar)
  # Where the search is, or what the empty pane says.
  let summary = vm.summaryText()
  let line = r.createElement("div")
  r.setAttribute(line, "data-ct-search-summary", "")
  r.setStyle(line, "height", $SearchSummaryPx & "px")
  r.setStyle(line, "flex-shrink", "0")
  r.setStyle(line, "color", SearchMutedColour)
  r.setStyle(line, "margin-top", "2px")
  r.appendChild(line, r.createTextNode(
    if summary.len > 0: summary else: vm.emptyText(NativeSearchPrompt)))
  r.appendChild(pane, line)
  # The rows.
  let top = st.visibleTop(rows.len, lay.rows)
  let selected = vm.selected.val
  r.setAttribute(pane, "data-ct-search-top", $top)
  r.setAttribute(pane, "data-ct-search-rows", $lay.rows)
  r.setAttribute(pane, "data-ct-search-total", $rows.len)
  for k in 0 ..< lay.rows:
    let i = top + k
    if i >= rows.len:
      break
    let d = rows[i]
    case d.kind
    of sdFile:
      let row = rowElement(r, lay.list.w, monospace = false)
      r.setAttribute(row, SearchFileAttribute, d.path)
      r.setStyle(row, "background", SearchHeaderGround)
      r.setStyle(row, "padding-left", "6px")
      r.setStyle(row, "gap", "8px")
      let caption = textRun(r, d.caption, SearchTextColour)
      r.setStyle(caption, "font-weight", "bold")
      r.appendChild(row, caption)
      r.appendChild(row, textRun(r, d.count, SearchMutedColour))
      r.appendChild(pane, row)
    of sdMatch:
      let row = rowElement(r, lay.list.w, monospace = true)
      r.setAttribute(row, SearchRowAttribute, $d.index)
      r.setAttribute(row, "data-ct-search-line", $d.line)
      r.setStyle(row, "padding-left", "18px")
      r.setStyle(row, "gap", "6px")
      if d.index == selected:
        r.setAttribute(row, "data-ct-selected", "true")
        r.setStyle(row, "background", SearchSelectedGround)
      let number = textRun(r, $d.line, SearchMutedColour)
      r.setStyle(number, "width", "36px")
      r.setStyle(number, "justify", "end")
      r.appendChild(row, number)
      let text = r.createElement("div")
      r.setStyle(text, "display", "flex")
      r.setStyle(text, "overflow", "hidden")
      if d.before.len > 0:
        r.appendChild(text, textRun(r, d.before, SearchTextColour))
      if d.hit.len > 0:
        let hit = textRun(r, d.hit, SearchTextColour, SearchHitGround)
        r.setAttribute(hit, "data-ct-search-hit", d.hit)
        r.appendChild(text, hit)
      if d.after.len > 0:
        r.appendChild(text, textRun(r, d.after, SearchTextColour))
      r.appendChild(row, text)
      r.appendChild(pane, row)
  if lay.overflow:
    drawListScrubber(r, pane, lay.listBody, st.scrubberOf(rows.len, lay.rows),
                     "search")
  true

proc searchHitAt*(vm: SearchResultsVM; st: GSearchPane; body: PxRect;
                  x, y: int): GSearchHit =
  ## What a press at window pixel `(x, y)` is on, by the drawing's layout.
  result = GSearchHit(kind: gsNone, index: -1)
  if vm.isNil or not body.contains(x, y):
    return
  let rows = vm.displayRows()
  let lay = searchLayout(body, rows.len)
  for o in SearchOption:
    if lay.optionBoxes[o].contains(x, y):
      return GSearchHit(kind: gsOption, index: -1, option: o)
  if lay.field.contains(x, y): return GSearchHit(kind: gsQuery, index: -1)
  if lay.overflow:
    let hit = listScrubHit(lay.listBody, st.scrubberOf(rows.len, lay.rows),
                           x, y)
    if hit.onTrack:
      return GSearchHit(kind: (if hit.onThumb: gsThumb else: gsTrack),
                        index: -1, fraction: hit.fraction)
  if not lay.list.contains(x, y):
    return
  let i = st.visibleTop(rows.len, lay.rows) + (y - lay.list.y) div SearchRowPx
  if i < 0 or i >= rows.len:
    return
  result = case rows[i].kind
           of sdFile: GSearchHit(kind: gsFile, index: -1)
           of sdMatch: GSearchHit(kind: gsMatch, index: rows[i].index)

proc scrubSearch*(st: var GSearchPane; vm: SearchResultsVM; body: PxRect;
                  y: int; dragging: bool) =
  ## The scrubber pressed (a jump) or its thumb held (the view follows).
  let total = vm.displayRows().len
  let lay = searchLayout(body, total)
  if not lay.overflow:
    return
  let track = listTrackRect(lay.listBody)
  let sm = st.scrubberOf(total, lay.rows)
  st.scrollTop = sm.scrubTop(trackFractionAt(y - track.y, track.h), dragging)
