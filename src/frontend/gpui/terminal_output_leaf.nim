## gpui/terminal_output_leaf.nim — PLAT-52. The GPUI window's **Terminal
## Output** pane: what the recorded program wrote, from the shared model the
## desktop and the terminal draw too (`viewmodels/terminal_output_model`).
## Until PLAT-52 the window drew it as a report leaf (`PaneAcceptedExceptions`).
##
## Spec: `codetracer-specs/spec/GUI/Core-Panes/Terminal-Output-Pane.md`.
##
##  * the LINE view — each line as styled TEXT RUNS, one per fragment: its
##    SGR colours through the desktop's palette, bold, italic; the future ones
##    at the desktop's `.future` (white, half opacity); a native SCROLLBAR
##    SCRUBBER on the right over EVERY line of the output
##    (Scrollbar-Scrubbers.md §4: a filled thumb rect, a tick for the current
##    position);
##  * the SCREEN view, offered when the output drives a screen — the shared
##    emulator's cell grid as text runs, SCALED to the pane (never re-wrapped:
##    the font shrinks or grows so the recorded 80x24 fits), with its built-in
##    scrubber along the bottom (a slider over the writes, the marks of clears
##    and alternate-screen switches under it) — REAL-TIME: dragging it moves
##    the debugger to each write it crosses (the user, 2026-10-06).
##
## The geometry is computed here, in window pixels, from the pane's body —
## and the press handlers in `main` hit-test through the SAME function
## (`terminalLayout`), so a press and the drawing cannot disagree. Rows have a
## fixed pitch, as the call trace's do.
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-terminal-*`): the view, the first row and row count, the total,
## each fragment's write, tense and attributes, the thumb's pixels.

import std/[math, strutils, unicode]

import isonim_gpui/renderer

import codetracer_embed
import ./window_geometry
import ./chrome
import ./app/leaves
from ../../common/view_vocabulary/layout_questions import trEditorCode
import ../styles/generated/design_tokens

type
  GTerminalDrag* = enum
    gtdNone, gtdLineThumb, gtdScreen

  GTerminalPane* = object
    ## The window's own state for the pane: where the reader scrolled, and a
    ## scrubber held by the pointer.
    scrollTop*: int
    follow*: bool
    drag*: GTerminalDrag
    focused*: bool
      ## The last press was in this pane: its keys (Left / Right, `v`) are
      ## its own.
    scrubSent*: int
      ## The write a held screen scrubber last moved the debugger to.

  TerminalLayout* = object
    body*: PxRect
    toggle*: PxRect
      ## The view toggle's row (zero height when the screen is not offered).
    linesButton*, screenButton*: PxRect
    content*: PxRect
      ## The lines (or the screen) area.
    rows*: int
      ## How many line rows fit.
    track*: PxRect
      ## The line view's scrubber track (zero width in the screen view).
    screenTrack*, marks*: PxRect
      ## The screen's scrubber and its marks (zero in the line view).
    scale*: float
      ## The screen view's scale.

const
  TerminalRowPx* = 22
  TerminalToggleRowPx* = 26
  TerminalTrackPx* = 12
  TerminalMinThumbPx* = 20
  TerminalMarkPx* = 3
  ScreenTrackPx* = 14
  ScreenMarksPx* = 10
  ScreenBaseFontPx* = 16.0
    ## The font size `EditorColumnPx` and `TerminalRowPx` were read at: the
    ## screen view scales from it.
  TerminalViewAttribute* = "data-ct-terminal-view"
  TerminalAttribute* = "data-ct-terminal"
  TerminalLineAttribute* = "data-ct-terminal-line"
  TerminalWriteAttribute* = "data-ct-terminal-write"
  TerminalTenseAttribute* = "data-ct-terminal-tense"
  TerminalStyleAttribute* = "data-ct-terminal-style"
  TerminalTrackAttribute* = "data-ct-terminal-track"
  TerminalMarkAttribute* = "data-ct-terminal-mark"
  TerminalScreenRowAttribute* = "data-ct-terminal-screen-row"
  TerminalTextColour* = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  TerminalFutureColour* = "#ffffff"
    ## The desktop's `.future { color: white; opacity: 0.5 }`.
  TerminalThumbColour* = "#79797966"
    ## The window's scrollbar thumb (`leaves.EditorScrollbarThumbColour`).
  TerminalMarkColour* = DesignTokenHex[dtColorsEditorActionSecondary][dmDark]
    ## The execution pointer's colour (the terminal's `srScrubberMark`).
  TerminalToggleActive* =
    DesignTokenHex[dtColorsUiSurfacePrimarySecondaryHover][dmDark]
  TerminalMarkColours*: array[ScreenMarkKind, string] = [
    DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark],
    DesignTokenHex[dtColorsUiTextInformationPrimary][dmDark],
    DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark]]

proc initGTerminalPane*(): GTerminalPane =
  GTerminalPane(follow: true, scrubSent: -1)

proc screenShown*(vm: TerminalOutputVM): bool =
  not vm.isNil and vm.screenOffered.val and vm.view.val == tvScreen and
    not vm.screen.isNil

proc terminalLayout*(body: PxRect; vm: TerminalOutputVM): TerminalLayout =
  ## The pane's parts, in window pixels, inside `body` (its padding off).
  result.body = body
  let inner = PxRect(x: body.x + ChromePaddingPx, y: body.y + ChromePaddingPx,
                     w: max(0, body.w - 2 * ChromePaddingPx),
                     h: max(0, body.h - 2 * ChromePaddingPx))
  var top = inner.y
  if not vm.isNil and vm.screenOffered.val:
    result.toggle = PxRect(x: inner.x, y: top, w: inner.w,
                           h: TerminalToggleRowPx)
    result.linesButton = PxRect(x: inner.x, y: top, w: 70,
                                h: TerminalToggleRowPx)
    result.screenButton = PxRect(x: inner.x + 74, y: top, w: 80,
                                 h: TerminalToggleRowPx)
    top += TerminalToggleRowPx
  let rest = max(0, inner.y + inner.h - top)
  if vm.screenShown:
    let trackH = ScreenTrackPx + ScreenMarksPx
    result.content = PxRect(x: inner.x, y: top, w: inner.w,
                            h: max(0, rest - trackH - 4))
    result.screenTrack = PxRect(x: inner.x, y: top + result.content.h + 2,
                                w: inner.w, h: ScreenTrackPx)
    result.marks = PxRect(x: inner.x, y: result.screenTrack.y + ScreenTrackPx,
                          w: inner.w, h: ScreenMarksPx)
    let cols = vm.screen.cols
    let rows = vm.screen.rows
    if cols > 0 and rows > 0:
      result.scale = min(float(result.content.w) / (float(cols) *
                                                    EditorColumnPx),
                         float(result.content.h) / float(rows * TerminalRowPx))
      result.scale = max(0.2, result.scale)
  else:
    result.content = PxRect(x: inner.x, y: top,
                            w: max(0, inner.w - TerminalTrackPx), h: rest)
    result.rows = max(0, rest div TerminalRowPx)
    result.track = PxRect(x: inner.x + inner.w - TerminalTrackPx, y: top,
                          w: TerminalTrackPx,
                          h: result.rows * TerminalRowPx)

proc visibleTop*(vm: TerminalOutputVM; st: GTerminalPane; rows: int): int =
  ## The first line shown: the reader's position, or — following — the
  ## current line at the bottom (the top before the first write).
  let total = vm.lines.val.len
  let maxTop = max(0, total - rows)
  if st.follow:
    let current = vm.currentLine()
    if current < 0: 0 else: max(0, min(maxTop, current - rows + 1))
  else:
    max(0, min(maxTop, st.scrollTop))

proc scrubberFor*(vm: TerminalOutputVM; st: GTerminalPane;
                  rows: int): ScrubberModel =
  ## The line view's scrubber: the WHOLE output.
  scrubberModel(vm.lines.val.len, vm.visibleTop(st, rows), rows,
                vm.currentLine())

proc screenThumbX*(vm: TerminalOutputVM; track: PxRect): int =
  ## The screen scrubber's thumb's left edge, for the shown write.
  let n = vm.screen.writeCount
  let w = vm.shownWrite.val
  if n <= 1 or w < 0: track.x
  else: track.x + int(round(fractionOfWrite(n, w) *
                            float(max(0, track.w - TerminalTrackPx))))

proc styleRun(r: GpuiRenderer; el: GpuiElement; a: TermAttrs;
              future: bool; scale = 1.0) =
  let (fgColour, bgColour) = drawnColours(a)
  var fg = termHex(fgColour)
  let bg = termHex(bgColour)
  if future and fg.len == 0:
    fg = TerminalFutureColour
  r.setStyle(el, "color", if fg.len > 0: fg else: TerminalTextColour)
  if bg.len > 0:
    r.setStyle(el, "background", bg)
  if a.bold:
    r.setStyle(el, "font-weight", "bold")
  if a.italic:
    r.setStyle(el, "font-style", "italic")
  if future:
    r.setStyle(el, "opacity", "0.5")
  elif a.faint:
    r.setStyle(el, "opacity", "0.7")
  r.setStyle(el, "flex-shrink", "0")
  r.setStyle(el, "white-space", "pre")
  r.setAttribute(el, TerminalStyleAttribute, describe(a))

proc rowElement(r: GpuiRenderer; heightPx: int): GpuiElement =
  result = r.createElement("div")
  for (k, v) in [("display", "flex"), ("white-space", "nowrap"),
                 ("overflow", "hidden"), ("flex-shrink", "0")]:
    r.setStyle(result, k, v)
  r.setStyle(result, "height", $heightPx & "px")
  r.setStyle(result, "items", "center")
  # Monospaced, as every terminal draws it (`main.applyTextFaces`).
  r.setAttribute(result, TextMetricAttribute, gpuiMetricFor(trEditorCode))

proc absoluteBox(r: GpuiRenderer; rect, body: PxRect; colour: string):
    GpuiElement =
  ## An absolutely placed rectangle, `rect` in window pixels, relative to the
  ## pane's box (whose top-left is `body`'s).
  result = r.createElement("div")
  r.setStyle(result, "position", "absolute")
  r.setStyle(result, "left", $(rect.x - body.x) & "px")
  r.setStyle(result, "top", $(rect.y - body.y) & "px")
  r.setStyle(result, "width", $rect.w & "px")
  r.setStyle(result, "height", $rect.h & "px")
  if colour.len > 0:
    r.setStyle(result, "background", colour)

proc drawToggle(r: GpuiRenderer; pane: GpuiElement; lay: TerminalLayout;
                vm: TerminalOutputVM) =
  if lay.toggle.h <= 0:
    return
  let row = r.createElement("div")
  for (k, v) in [("display", "flex"), ("flex-shrink", "0"),
                 ("items", "center"), ("gap", "4px")]:
    r.setStyle(row, k, v)
  r.setStyle(row, "height", $TerminalToggleRowPx & "px")
  for (view, label, rect) in [(tvLines, "Lines", lay.linesButton),
                              (tvScreen, "Screen", lay.screenButton)]:
    let b = r.createElement("div")
    r.setAttribute(b, TerminalViewAttribute, $view)
    r.setAttribute(b, "data-ct-active", $(vm.view.val == view))
    r.setStyle(b, "width", $rect.w & "px")
    r.setStyle(b, "height", $(TerminalToggleRowPx - 4) & "px")
    r.setStyle(b, "items", "center")
    r.setStyle(b, "justify", "center")
    r.setStyle(b, "display", "flex")
    r.setStyle(b, "rounded", "3px")
    r.setStyle(b, "color", TerminalTextColour)
    if vm.view.val == view:
      r.setStyle(b, "background", TerminalToggleActive)
    r.appendChild(b, r.createTextNode(label))
    r.appendChild(row, b)
  let info = r.createElement("div")
  r.setStyle(info, "color", TerminalFutureColour)
  r.setStyle(info, "opacity", "0.6")
  r.setStyle(info, "padding-left", "12px")
  let n = vm.events.val.len
  let w = vm.shownWrite.val
  r.appendChild(info, r.createTextNode(
    if vm.screenShown:
      (if w < 0: "before the first write"
       else: "write " & $(w + 1) & " / " & $n & " · tick " &
             $vm.events.val[w].rrTicks) &
      (if vm.scrubPreview.val >= 0: " · scrubbing" else: "")
    else: $vm.lines.val.len & " lines"))
  r.appendChild(row, info)
  r.appendChild(pane, row)

proc drawLines(r: GpuiRenderer; pane: GpuiElement; lay: TerminalLayout;
               vm: TerminalOutputVM; st: GTerminalPane) =
  let lines = vm.lines.val
  let top = vm.visibleTop(st, lay.rows)
  let current = vm.currentRRTicks.val
  r.setAttribute(pane, "data-ct-terminal-top", $top)
  r.setAttribute(pane, "data-ct-terminal-rows", $lay.rows)
  r.setAttribute(pane, "data-ct-terminal-total", $lines.len)
  for i in 0 ..< lay.rows:
    let li = top + i
    if li >= lines.len: break
    let row = rowElement(r, TerminalRowPx)
    r.setAttribute(row, TerminalLineAttribute, $li)
    r.setStyle(row, "width", $lay.content.w & "px")
    for f in lines[li].fragments:
      if f.text.len == 0: continue
      let span = r.createElement("span")
      r.setAttribute(span, TerminalWriteAttribute, $f.eventIndex)
      let tense: TerminalTense = fragmentTense(current, f.rrTicks)
      r.setAttribute(span, TerminalTenseAttribute, $tense)
      styleRun(r, span, f.style, tense == ttFuture)
      r.appendChild(span, r.createTextNode(f.text))
      r.appendChild(row, span)
    r.appendChild(pane, row)
  # The scrollbar SCRUBBER over every line.
  if lay.track.h > 0:
    let sm = vm.scrubberFor(st, lay.rows)
    let span = sm.thumbSpan(lay.track.h, TerminalMinThumbPx)
    let track = absoluteBox(r, lay.track, lay.body, "")
    r.setAttribute(track, TerminalTrackAttribute, "lines")
    r.setAttribute(track, "data-ct-thumb-top", $span.start)
    r.setAttribute(track, "data-ct-thumb-px", $span.length)
    r.setStyle(track, "display", "flex")
    r.setStyle(track, "flex-direction", "column")
    r.setStyle(track, "padding-top", $span.start & "px")
    let thumb = r.createElement("div")
    r.setStyle(thumb, "width", $TerminalTrackPx & "px")
    r.setStyle(thumb, "height", $span.length & "px")
    r.setStyle(thumb, "flex-shrink", "0")
    r.setStyle(thumb, "background", TerminalThumbColour)
    r.setStyle(thumb, "rounded", "3px")
    r.appendChild(track, thumb)
    r.appendChild(pane, track)
    let f = sm.currentFraction
    if f >= 0.0:
      let y = lay.track.y + min(lay.track.h - TerminalMarkPx,
                                int(f * float(lay.track.h)))
      let mark = absoluteBox(r, PxRect(x: lay.track.x, y: y, w: TerminalTrackPx,
                                       h: TerminalMarkPx), lay.body,
                             TerminalMarkColour)
      r.setAttribute(mark, TerminalMarkAttribute, "current")
      r.setAttribute(mark, "data-ct-mark-line", $sm.current)
      r.appendChild(pane, mark)

proc drawScreen(r: GpuiRenderer; pane: GpuiElement; lay: TerminalLayout;
                vm: TerminalOutputVM) =
  let screen = vm.shownScreen()
  let rowPx = max(1, int(round(float(TerminalRowPx) * lay.scale)))
  let fontPx = ScreenBaseFontPx * lay.scale
  r.setAttribute(pane, "data-ct-terminal-scale",
                 formatFloat(lay.scale, ffDecimal, 3))
  r.setAttribute(pane, "data-ct-terminal-write", $vm.shownWrite.val)
  r.setAttribute(pane, "data-ct-terminal-cols", $screen.cols)
  r.setAttribute(pane, "data-ct-terminal-rows", $screen.rows)
  for row in 0 ..< screen.rows:
    let el = rowElement(r, rowPx)
    r.setAttribute(el, TerminalScreenRowAttribute, $row)
    r.setStyle(el, "font-size", formatFloat(fontPx, ffDecimal, 2) & "px")
    for run in screen.screenRowRuns(row):
      let span = r.createElement("span")
      styleRun(r, span, run.attrs, false)
      r.appendChild(span, r.createTextNode(run.text))
      r.appendChild(el, span)
    r.appendChild(pane, el)
  # The built-in scrubber: a slider over the writes, the marks under it.
  let track = absoluteBox(r, lay.screenTrack, lay.body,
                          DesignTokenHex[dtColorsUiDividerSecondary][dmDark])
  r.setAttribute(track, TerminalTrackAttribute, "screen")
  let thumbX = vm.screenThumbX(lay.screenTrack)
  r.setAttribute(track, "data-ct-thumb-left", $(thumbX - lay.screenTrack.x))
  r.setStyle(track, "rounded", "3px")
  r.appendChild(pane, track)
  let thumb = absoluteBox(r, PxRect(x: thumbX, y: lay.screenTrack.y,
                                    w: TerminalTrackPx, h: ScreenTrackPx),
                          lay.body, TerminalTextColour)
  r.setStyle(thumb, "rounded", "3px")
  r.setAttribute(thumb, "data-ct-terminal-thumb", "screen")
  r.appendChild(pane, thumb)
  let n = vm.screen.writeCount
  for m in vm.screen.marks:
    let x = lay.marks.x + int(round(fractionOfWrite(n, m.write) *
                                    float(max(0, lay.marks.w - 3))))
    let mark = absoluteBox(r, PxRect(x: x, y: lay.marks.y, w: 3,
                                     h: ScreenMarksPx), lay.body,
                           TerminalMarkColours[m.kind])
    r.setAttribute(mark, TerminalMarkAttribute, $m.kind)
    r.setAttribute(mark, "data-ct-mark-write", $m.write)
    r.appendChild(pane, mark)

proc drawTerminalOutput*(r: GpuiRenderer; pane: GpuiElement;
                         vm: TerminalOutputVM; st: GTerminalPane;
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
  let lay = terminalLayout(body, vm)
  r.setAttribute(pane, TerminalAttribute,
                 (if vm.screenShown: $tvScreen else: $tvLines))
  drawToggle(r, pane, lay, vm)
  if vm.lines.val.len == 0 and not vm.screenShown:
    let note = r.createElement("div")
    r.setStyle(note, "color", TerminalFutureColour)
    r.setStyle(note, "opacity", "0.6")
    r.appendChild(note, r.createTextNode(
      if vm.initialLoad.val: "Loading record output..."
      else: "The current record does not print anything to the terminal."))
    r.appendChild(pane, note)
    return true
  if vm.screenShown:
    drawScreen(r, pane, lay, vm)
  else:
    drawLines(r, pane, lay, vm, st)
  true

# ---------------------------------------------------------------------------
# Hit testing, through the same layout
# ---------------------------------------------------------------------------

type
  GTerminalHitKind* = enum
    ghNone, ghViewLines, ghViewScreen, ghWrite, ghLineTrack, ghLineThumb,
    ghScreenTrack, ghScreen

  GTerminalHit* = object
    kind*: GTerminalHitKind
    write*: int
    fraction*: float

proc lineFragmentAt*(line: TerminalLine; column: int): int =
  ## The fragment drawn over `column`; past the text, the line's last one.
  if line.fragments.len == 0:
    return -1
  var c = 0
  for i, f in line.fragments:
    let w = f.text.runeLen
    if column >= c and column < c + w:
      return i
    c += w
  line.fragments.len - 1

proc terminalHitAt*(vm: TerminalOutputVM; st: GTerminalPane; body: PxRect;
                    x, y: int): GTerminalHit =
  ## What a press at window pixel `(x, y)` is on.
  result = GTerminalHit(kind: ghNone, write: -1)
  if vm.isNil or not body.contains(x, y):
    return
  let lay = terminalLayout(body, vm)
  if lay.linesButton.contains(x, y):
    return GTerminalHit(kind: ghViewLines, write: -1)
  if lay.screenButton.contains(x, y):
    return GTerminalHit(kind: ghViewScreen, write: -1)
  if vm.screenShown:
    if lay.screenTrack.contains(x, y) or lay.marks.contains(x, y):
      return GTerminalHit(kind: ghScreenTrack, write: -1,
        fraction: max(0.0, min(1.0, float(x - lay.screenTrack.x) /
                                    float(max(1, lay.screenTrack.w)))))
    if lay.content.contains(x, y):
      return GTerminalHit(kind: ghScreen, write: -1)
    return
  if lay.track.contains(x, y):
    let sm = vm.scrubberFor(st, lay.rows)
    let span = sm.thumbSpan(lay.track.h, TerminalMinThumbPx)
    let f = fractionAt(y - lay.track.y, lay.track.h)
    let local = y - lay.track.y
    if local >= span.start and local < span.start + span.length:
      return GTerminalHit(kind: ghLineThumb, write: -1, fraction: f)
    return GTerminalHit(kind: ghLineTrack, write: -1, fraction: f)
  if not lay.content.contains(x, y):
    return
  let li = vm.visibleTop(st, lay.rows) + (y - lay.content.y) div TerminalRowPx
  let lines = vm.lines.val
  if li < 0 or li >= lines.len:
    return
  let column = int(float(x - lay.content.x) / EditorColumnPx)
  let fi = lineFragmentAt(lines[li], column)
  if fi < 0:
    return
  result = GTerminalHit(kind: ghWrite,
                        write: lines[li].fragments[fi].eventIndex)
