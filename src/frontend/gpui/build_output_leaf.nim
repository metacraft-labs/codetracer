## gpui/build_output_leaf.nim — PLAT-56. The GPUI window's **Build Output**
## pane, drawn natively from the window's `BuildVM` (the model the desktop's
## BUILD panel and the terminal's pane draw), which the window's builds feed
## (`tui/host/build_problems`). Until PLAT-56 the window drew this pane as a
## report ("an edit-mode pane; a replay session does not build the working
## tree").
##
## What the desktop's panel draws, in its order and words
## (`viewmodel/views/isonim_build_view.nim`, Build-Output-Pane.md §3.13): a
## header — the shown build's verdict in its colour on the left, and on the
## right the history picker, Run ▶, Stop ■, Clear ✕, the auto-scroll toggle ↓
## and the duration — the picker's list under it when open, then the output,
## each line in its compiler's colours (`BuildOutputLine.runs`), stderr in the
## error colour and italic, a line that names a location in its severity's
## colour (a press opens it, K35); with no build, "No build has run.". Every
## word is the ViewModel's. The colours are the desktop's tokens (dark). The
## lines have a fixed pitch so a press and the drawing go through one layout
## (`buildLayout`); the output's scrollbar is the shared list scrubber (moving
## the VIEW) and a line wider than the pane is reached by the horizontal bar
## (PLAT-70, as the Terminal Output pane's).
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-build-*`).

import std/unicode

import isonim_gpui/renderer
import isonim/core/[signals, computation]

import codetracer_embed
import ./window_geometry
import ./chrome
import ./app/leaves
import ./list_scrubber
import ../viewmodel/viewmodels/build_vm
import ../viewmodel/viewmodels/terminal_output_model
from ../viewmodel/viewmodels/table_overflow import nil
import ../viewmodel/store/types
from ../../common/view_vocabulary/layout_questions import trEditorCode
import ../styles/generated/design_tokens

type
  GBuildPane* = object
    ## The window's own state for the pane: where the reader scrolled, the
    ## horizontal view, a held scrubber, whether the picker is open.
    scrollTop*: int
    dragging*: bool
    historyOpen*: bool
    hview*: HorizontalView
    widths*: ContentWidth
    lastShown*: (int, int, int)
      ## (number, shown index, line count) last drawn, for auto-scroll.

  GBuildControl* = enum
    gbHistory, gbRun, gbStop, gbClear, gbFollow

  BuildLayout* = object
    body*: PxRect
    header*: PxRect
    controls*: seq[(GBuildControl, PxRect)]
    menu*: PxRect
    menuRows*: int
    list*: PxRect
    rows*: int
    overflow*: bool
    hbar*: PxRect
    view*: HorizontalView

  GBuildHitKind* = enum
    gbhNone, gbhControl, gbhHistoryItem, gbhLine, gbhText, gbhTrack,
    gbhThumb, gbhHBar

  GBuildHit* = object
    kind*: GBuildHitKind
    control*: GBuildControl
    index*: int
    fraction*: float

const
  BuildRowPx* = 22
  BuildHeaderPx* = 26
  BuildButtonPx = 24
  BuildMinThumbPx = 20
  BuildControlIcons*: array[GBuildControl, string] =
    ["History ▾", "▶", "■", "✕", "↓"]
    ## The desktop's controls (`.build-history-btn` and the four
    ## `.build-ctrl-btn` icons), their titles `BuildControlTitles`.
  BuildAttribute* = "data-ct-build"
    ## On the pane: the shown build's header words.
  BuildLineAttribute* = "data-ct-build-line"
    ## On an output line: its index, with `data-ct-build-class`.
  BuildControlAttribute* = "data-ct-build-control"
  BuildTextColour* = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  BuildLabelColour* = DesignTokenHex[dtColorsUiTextPrimaryLabel][dmDark]
  BuildCaptionColour* = DesignTokenHex[dtColorsUiTextPrimaryCaption][dmDark]
  BuildSubtleColour* = DesignTokenHex[dtColorsUiTextPrimaryLabelSubtle][dmDark]
  BuildErrorColour* = DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark]
    ## `.build-stderr`, `.build-line-error`, `.build-header.build-failed`.
  BuildWarningColour* = DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark]
  BuildSuccessColour* = DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark]
  BuildStopColour* = DesignTokenHex[dtColorsUiIconErrorPrimary][dmDark]
  BuildThumbColour = "#79797966"

proc initGBuildPane*(): GBuildPane = GBuildPane(lastShown: (-1, -1, 0))

proc pxOf(text: string): int =
  int(float(table_overflow.runeMeasure(text)) * EditorColumnPx)

proc columnsOf(px: int): int = max(0, int(float(px) / EditorColumnPx))

proc headerColour*(status: BuildStatus): string =
  ## `.build-header` and its verdict modifiers.
  case status
  of bsFailed: BuildErrorColour
  of bsSucceeded: BuildSuccessColour
  else: BuildLabelColour

proc lineClassOf*(line: BuildOutputLine): string =
  ## The desktop's class for the line (`isonim_build_view.lineClass`).
  if line.located:
    case line.severity
    of blsError: "build-line-error"
    of blsWarning: "build-line-warning"
    of blsInfo: "build-line-info"
    of blsNone: "build-output-line"
  elif line.isStdout: "build-stdout"
  else: "build-stderr"

proc lineColour*(line: BuildOutputLine): string =
  if line.located:
    case line.severity
    of blsError: BuildErrorColour
    of blsWarning: BuildWarningColour
    of blsInfo, blsNone: BuildTextColour
  elif line.isStdout: BuildTextColour
  else: BuildErrorColour

proc measureContent*(st: var GBuildPane; vm: BuildVM) =
  ## PLAT-70 (§4.1): the widest line measured so far of the shown build.
  if vm.isNil:
    return
  let shown = vm.shownSnapshot()
  var lines: seq[string] = @[]
  for l in shown.output:
    lines.add l.text
  st.hview.setContent(st.widths.measureLines(shown.number * 31 +
                                             vm.shownIndex.val, lines,
    proc(s: string): int = s.runeLen))

proc buildLayout*(vm: BuildVM; st: GBuildPane; body: PxRect): BuildLayout =
  ## The pane's parts, in window pixels, inside `body` (its padding off).
  result.body = body
  let inner = PxRect(x: body.x + ChromePaddingPx, y: body.y + ChromePaddingPx,
                     w: max(0, body.w - 2 * ChromePaddingPx),
                     h: max(0, body.h - 2 * ChromePaddingPx))
  result.header = PxRect(x: inner.x, y: inner.y, w: inner.w, h: BuildHeaderPx)
  let shown = vm.shownSnapshot()
  let duration = shown.durationText(vm.clockMs.val)
  var x = inner.x + inner.w - (if duration.len > 0: pxOf(duration) + 4 else: 0)
  var placed: seq[(GBuildControl, PxRect)] = @[]
  for c in countdown(high(GBuildControl), low(GBuildControl)):
    if c == gbHistory and vm.history.val.len == 0:
      continue
    let w = if c == gbHistory: pxOf(BuildControlIcons[c]) + 12
            else: BuildButtonPx
    x -= w + 4
    placed.insert((c, PxRect(x: x, y: inner.y + 1, w: w, h: BuildButtonPx)), 0)
  result.controls = placed
  var top = inner.y + BuildHeaderPx + 2
  if st.historyOpen and vm.history.val.len > 0:
    let n = vm.history.val.len + 1
    result.menuRows = min(n, max(0, (inner.y + inner.h - top) div BuildRowPx - 1))
    result.menu = PxRect(x: inner.x, y: top, w: inner.w,
                         h: result.menuRows * BuildRowPx)
    top += result.menu.h + 4
  if shown.status == bsIdle and shown.output.len == 0:
    top += BuildRowPx
  var rest = max(0, inner.y + inner.h - top)
  result.view = st.hview
  var width = inner.w
  let total = shown.output.len
  result.rows = max(0, rest div BuildRowPx)
  result.overflow = total > result.rows
  if result.overflow:
    width = max(0, inner.w - ListTrackPx - 2)
  result.view.setViewport(columnsOf(width))
  if result.view.overflows and rest >= BuildRowPx + ListTrackPx:
    rest -= ListTrackPx
    result.rows = max(0, rest div BuildRowPx)
    result.overflow = total > result.rows
    result.hbar = PxRect(x: inner.x, y: top + rest, w: width, h: ListTrackPx)
  result.list = PxRect(x: inner.x, y: top, w: width,
                       h: result.rows * BuildRowPx)

proc listBody(lay: BuildLayout): PxRect =
  PxRect(x: lay.body.x, y: lay.list.y - ChromePaddingPx, w: lay.body.w,
         h: lay.list.h + 2 * ChromePaddingPx)

proc visibleTop*(st: GBuildPane; total, rows: int): int =
  max(0, min(st.scrollTop, total - max(1, rows)))

proc scrubberOf*(st: GBuildPane; total, rows: int): ScrubberModel =
  scrubberModel(total, st.visibleTop(total, rows), rows)

proc follow*(st: var GBuildPane; vm: BuildVM) =
  ## Auto-scroll: a shown build that grew (or a newly shown one), with the
  ## toggle on and the current build shown, is followed to its last line.
  if vm.isNil:
    return
  let shown = vm.shownSnapshot()
  let key = (shown.number, vm.shownIndex.val, shown.output.len)
  if key[0] != st.lastShown[0] or key[1] != st.lastShown[1]:
    st.scrollTop = (if vm.autoScroll.val and vm.showingLatest:
                      shown.output.len else: 0)
  elif vm.autoScroll.val and vm.showingLatest and key[2] > st.lastShown[2]:
    st.scrollTop = shown.output.len
  st.lastShown = key

proc scrollBy*(st: var GBuildPane; vm: BuildVM; body: PxRect; delta: int) =
  let lay = buildLayout(vm, st, body)
  let total = vm.shownSnapshot().output.len
  st.scrollTop = max(0, min(st.visibleTop(total, lay.rows) + delta,
                            total - max(1, lay.rows)))

proc textRun(r: GpuiRenderer; text, colour: string): GpuiElement =
  result = r.createElement("span")
  r.setStyle(result, "color", colour)
  r.setStyle(result, "white-space", "pre")
  r.setStyle(result, "flex-shrink", "0")
  r.appendChild(result, r.createTextNode(text))

proc rowElement(r: GpuiRenderer; widthPx: int): GpuiElement =
  result = r.createElement("div")
  for (k, v) in [("display", "flex"), ("white-space", "nowrap"),
                 ("overflow", "hidden"), ("flex-shrink", "0"),
                 ("items", "center")]:
    r.setStyle(result, k, v)
  r.setStyle(result, "height", $BuildRowPx & "px")
  r.setStyle(result, "width", $widthPx & "px")
  r.setAttribute(result, TextMetricAttribute, gpuiMetricFor(trEditorCode))

proc absoluteBox(r: GpuiRenderer; rect, body: PxRect; colour: string):
    GpuiElement =
  result = r.createElement("div")
  r.setStyle(result, "position", "absolute")
  r.setStyle(result, "left", $(rect.x - body.x) & "px")
  r.setStyle(result, "top", $(rect.y - body.y) & "px")
  r.setStyle(result, "width", $rect.w & "px")
  r.setStyle(result, "height", $rect.h & "px")
  if colour.len > 0:
    r.setStyle(result, "background", colour)

proc styleRun(r: GpuiRenderer; el: GpuiElement; line: BuildOutputLine;
              a: TermAttrs) =
  ## A run in the line's colour, under the colours and attributes the
  ## compiler wrote (`cssOf`'s declarations, which `ansi_up` wrote).
  let (fgColour, bgColour) = drawnColours(a)
  let fg = termHex(fgColour)
  let bg = termHex(bgColour)
  r.setStyle(el, "color", if fg.len > 0: fg else: lineColour(line))
  if bg.len > 0:
    r.setStyle(el, "background", bg)
  if a.bold:
    r.setStyle(el, "font-weight", "bold")
  if a.italic or (not line.isStdout and not line.located):
    r.setStyle(el, "font-style", "italic")
  if a.faint:
    r.setStyle(el, "opacity", "0.7")
  r.setStyle(el, "flex-shrink", "0")
  r.setStyle(el, "white-space", "pre")
  r.setAttribute(el, "data-ct-build-style", describe(a))
  r.setAttribute(el, "data-ct-colour",
                 if fg.len > 0: fg else: lineColour(line))

proc drawBuildOutput*(r: GpuiRenderer; pane: GpuiElement; vm: BuildVM;
                      st: GBuildPane; body: PxRect): bool =
  ## Draw the pane into `pane` (its children replaced), its body at `body` in
  ## window pixels. False when there is nothing to draw it from.
  if pane.isNil or vm.isNil:
    return false
  while childCount(pane) > 0:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  r.setStyle(pane, "position", "relative")
  r.setStyle(pane, "display", "flex")
  r.setStyle(pane, "flex-direction", "column")
  let lay = buildLayout(vm, st, body)
  let shown = vm.shownSnapshot()
  let headerWords = shown.headerText
  let duration = shown.durationText(vm.clockMs.val)
  r.setAttribute(pane, BuildAttribute, headerWords)
  r.setAttribute(pane, "data-ct-build-status", $shown.status)
  r.setAttribute(pane, "data-ct-build-duration", duration)
  r.setAttribute(pane, "data-ct-build-number", $shown.number)
  r.setAttribute(pane, "data-ct-build-history", $vm.history.val.len)
  r.setAttribute(pane, "data-ct-build-shown", $vm.shownIndex.val)
  # The header.
  let header = r.createElement("div")
  for (k, v) in [("display", "flex"), ("flex-shrink", "0"),
                 ("items", "center"), ("gap", "4px")]:
    r.setStyle(header, k, v)
  r.setStyle(header, "height", $BuildHeaderPx & "px")
  let label = textRun(r, headerWords, headerColour(shown.status))
  r.setAttribute(label, "data-ct-build-header", headerWords)
  r.setAttribute(label, "data-ct-colour", headerColour(shown.status))
  r.appendChild(header, label)
  let spacer = r.createElement("div")
  r.setStyle(spacer, "flex-grow", "1")
  r.appendChild(header, spacer)
  for (c, rect) in lay.controls:
    let colour =
      case c
      of gbStop: (if vm.isRunning.val: BuildStopColour else: BuildSubtleColour)
      of gbFollow: (if vm.autoScroll.val: BuildSuccessColour
                    else: BuildLabelColour)
      of gbHistory: (if not vm.showingLatest: BuildSuccessColour
                     else: BuildLabelColour)
      else: BuildLabelColour
    let b = textRun(r, BuildControlIcons[c], colour)
    r.setStyle(b, "width", $rect.w & "px")
    r.setStyle(b, "text-align", "center")
    r.setAttribute(b, BuildControlAttribute, $c)
    r.setAttribute(b, "data-ct-title",
                   if c == gbHistory: BuildHistoryLabel
                   else: BuildControlTitles[ord(c) - 1])
    r.setAttribute(b, "data-ct-colour", colour)
    r.appendChild(header, b)
  if duration.len > 0:
    let d = textRun(r, duration, BuildCaptionColour)
    r.setAttribute(d, "data-ct-build-duration", duration)
    r.appendChild(header, d)
  r.appendChild(pane, header)
  # The history picker, open.
  if lay.menuRows > 0:
    let labels = vm.historyLabels()
    let at = (if vm.showingLatest: 0 else: vm.shownIndex.val + 1)
    for k in 0 ..< lay.menuRows:
      let el = rowElement(r, lay.menu.w)
      r.setAttribute(el, "data-ct-build-history-item", $k)
      let t = textRun(r, labels[k], if k == at: BuildSuccessColour
                                    else: BuildTextColour)
      r.appendChild(el, t)
      r.appendChild(pane, el)
  if shown.status == bsIdle and shown.output.len == 0:
    let el = rowElement(r, lay.list.w)
    r.setAttribute(el, "data-ct-build-empty", BuildIdleText)
    r.appendChild(el, textRun(r, BuildIdleText, BuildLabelColour))
    r.appendChild(pane, el)
  # The output.
  let total = shown.output.len
  let top = st.visibleTop(total, lay.rows)
  r.setAttribute(pane, "data-ct-build-top", $top)
  r.setAttribute(pane, "data-ct-build-rows", $lay.rows)
  r.setAttribute(pane, "data-ct-build-lines", $total)
  let left = lay.view.leftCol
  let cols = lay.view.viewportCols
  for k in 0 ..< lay.rows:
    let i = top + k
    if i >= total:
      break
    let line = shown.output[i]
    let el = rowElement(r, lay.list.w)
    r.setAttribute(el, BuildLineAttribute, $i)
    r.setAttribute(el, "data-ct-build-class", lineClassOf(line))
    r.setAttribute(el, "data-ct-text", line.text)
    if line.located:
      r.setAttribute(el, "data-ct-build-location",
                     line.locationPath & ":" & $line.locationLine &
                     (if line.locationCol > 0: ":" & $line.locationCol
                      else: ""))
    var c = 0
    for run in line.runs:
      let w = run.text.runeLen
      let a = max(left, c)
      let b = min(left + cols, c + w)
      if b > a:
        let span = r.createElement("span")
        styleRun(r, span, line, run.style)
        r.appendChild(span, r.createTextNode(run.text.runeSubstr(a - c,
                                                                  b - a)))
        r.appendChild(el, span)
      c += w
    r.appendChild(pane, el)
  if lay.overflow:
    drawListScrubber(r, pane, lay.listBody, st.scrubberOf(total, lay.rows),
                     "buildOutput")
  if lay.hbar.h > 0:
    let bar = lay.view.barModel
    let span = bar.thumbSpan(lay.hbar.w, BuildMinThumbPx)
    let track = absoluteBox(r, lay.hbar, lay.body, "")
    r.setAttribute(track, "data-ct-build-hbar",
                   "content=" & $lay.view.contentCols & ";viewport=" &
                   $lay.view.viewportCols & ";left=" & $lay.view.leftCol)
    r.setStyle(track, "display", "flex")
    r.setStyle(track, "padding-left", $span.start & "px")
    let thumb = r.createElement("div")
    r.setStyle(thumb, "width", $span.length & "px")
    r.setStyle(thumb, "height", $ListTrackPx & "px")
    r.setStyle(thumb, "flex-shrink", "0")
    r.setStyle(thumb, "background", BuildThumbColour)
    r.setStyle(thumb, "rounded", "3px")
    r.appendChild(track, thumb)
    r.appendChild(pane, track)
  true

proc buildHitAt*(vm: BuildVM; st: GBuildPane; body: PxRect;
                 x, y: int): GBuildHit =
  ## What a press at window pixel `(x, y)` is on, by the drawing's layout.
  result = GBuildHit(kind: gbhNone, index: -1)
  if vm.isNil or not body.contains(x, y):
    return
  let lay = buildLayout(vm, st, body)
  for (c, rect) in lay.controls:
    if rect.contains(x, y):
      return GBuildHit(kind: gbhControl, control: c, index: -1)
  if lay.menuRows > 0 and lay.menu.contains(x, y):
    return GBuildHit(kind: gbhHistoryItem,
                     index: (y - lay.menu.y) div BuildRowPx)
  let total = vm.shownSnapshot().output.len
  if lay.hbar.h > 0 and lay.hbar.contains(x, y):
    return GBuildHit(kind: gbhHBar, index: -1,
                     fraction: trackFractionAt(x - lay.hbar.x, lay.hbar.w))
  if lay.overflow:
    let hit = listScrubHit(lay.listBody, st.scrubberOf(total, lay.rows), x, y)
    if hit.onTrack:
      return GBuildHit(kind: (if hit.onThumb: gbhThumb else: gbhTrack),
                       index: -1, fraction: hit.fraction)
  if not lay.list.contains(x, y):
    return
  let i = st.visibleTop(total, lay.rows) + (y - lay.list.y) div BuildRowPx
  if i < 0 or i >= total:
    return
  result = if vm.shownSnapshot().output[i].located:
             GBuildHit(kind: gbhLine, index: i)
           else:
             GBuildHit(kind: gbhText, index: i)

proc scrubBuild*(st: var GBuildPane; vm: BuildVM; body: PxRect; y: int;
                 dragging: bool) =
  ## The scrubber pressed (a jump) or its thumb held (the view follows).
  let lay = buildLayout(vm, st, body)
  if not lay.overflow:
    return
  let total = vm.shownSnapshot().output.len
  let track = listTrackRect(lay.listBody)
  let sm = st.scrubberOf(total, lay.rows)
  st.scrollTop = sm.scrubTop(trackFractionAt(y - track.y, track.h), dragging)

proc scrollColumns*(st: var GBuildPane; vm: BuildVM; body: PxRect;
                    fraction: float) =
  ## PLAT-70: a press on the horizontal bar centres the view there.
  let lay = buildLayout(vm, st, body)
  var v = lay.view
  discard v.scrollBy(int(fraction * float(v.contentCols)) - v.leftCol -
                     v.viewportCols div 2)
  st.hview = v

proc lineCentre*(vm: BuildVM; st: GBuildPane; body: PxRect;
                 index: int): tuple[ok: bool, x, y: int] =
  ## Where output line `index` is drawn, for a press aimed at it.
  let lay = buildLayout(vm, st, body)
  let total = vm.shownSnapshot().output.len
  let top = st.visibleTop(total, lay.rows)
  if index < top or index >= top + lay.rows:
    return (false, 0, 0)
  (true, lay.list.x + 8, lay.list.y + (index - top) * BuildRowPx +
                         BuildRowPx div 2)
