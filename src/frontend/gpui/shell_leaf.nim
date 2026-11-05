## gpui/shell_leaf.nim — PLAT-61. The GPUI window's **Shell** pane: the
## interactive CodeTracer shell, drawn natively from the session's `ShellVM`
## (the model the desktop's Shell pane and the terminal's draw).
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7.5.
##
## What it draws, in the other front-ends' order and words: a header line —
## the model's state words and its last note — then the output, one row per
## line with a two-column gutter (the action's glyph on its first line, a bar
## on the rest, in its status's colour) and the line's styled runs; the cursor
## as a reversed cell; the scrollback's scrubber on the right. Rows have a
## fixed pitch, so a press and the drawing go through one layout
## (`shellLayout`), and the shell runs at the size that layout gives
## (`ShellLayout.cols` x `rows`).
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-shell-*`).

import std/[math, unicode]

import isonim_gpui/renderer

import codetracer_embed
import ./window_geometry
import ./chrome
import ./app/leaves
import ./list_scrubber
from ../../common/view_vocabulary/layout_questions import trEditorCode
import ../styles/generated/design_tokens

type
  ShellLayout* = object
    body*: PxRect
    header*: PxRect
    output*: PxRect
      ## The rows' area, the gutter included, the scrubber's column off.
    textX*: int
      ## Where a row's text starts (after the gutter).
    cols*, rows*: int
      ## The terminal size the shell runs at.

  GShellHitKind* = enum
    gshNone, gshGutter, gshText, gshTrack, gshHeader

  GShellHit* = object
    kind*: GShellHitKind
    line*: int
    action*: int
    fraction*: float

const
  ShellRowPx* = 22
  ShellHeaderPx* = 26
  ShellGutterCols* = 2
  ShellAttribute* = "data-ct-shell"
    ## On the pane: the session's state (`ShellSessionState`).
  ShellLineAttribute* = "data-ct-shell-line"
    ## On a row: its absolute line; `data-ct-shell-mark`, `data-ct-shell-tone`,
    ## `data-ct-shell-action`, `data-ct-shell-text` (the row's text).
  ShellTextColour* = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  ShellMutedColour* = DesignTokenHex[dtColorsUiTextPrimaryCaption][dmDark]
  ShellGround* = DesignTokenHex[dtColorsUiSurfaceBasePanel][dmDark]
  ShellToneColours*: array[ShellTone, string] = [
    DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark],
    DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark],
    DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark]]
    ## working, ok, error — the desktop's `.shell-row[data-tone]` colours.

proc colsIn(px: int): int = max(0, int(floor(float(px) / EditorColumnPx)))

proc shellLayout*(body: PxRect): ShellLayout =
  ## The pane's parts in window pixels, and the shell's size in cells.
  result.body = body
  result.header = PxRect(x: body.x + ChromePaddingPx, y: body.y,
                         w: max(0, body.w - 2 * ChromePaddingPx),
                         h: ShellHeaderPx)
  let top = body.y + ShellHeaderPx
  let trackW = ListTrackPx + ChromePaddingPx
  result.output = PxRect(x: body.x + ChromePaddingPx, y: top,
                         w: max(0, body.w - ChromePaddingPx - trackW),
                         h: max(0, body.y + body.h - top - ChromePaddingPx))
  result.textX = result.output.x + int(round(float(ShellGutterCols) *
                                             EditorColumnPx))
  result.cols = max(1, colsIn(result.output.w) - ShellGutterCols)
  result.rows = max(1, result.output.h div ShellRowPx)

proc rowElement(r: GpuiRenderer; widthPx: int): GpuiElement =
  result = r.createElement("div")
  for (k, v) in [("display", "flex"), ("white-space", "nowrap"),
                 ("overflow", "hidden"), ("flex-shrink", "0"),
                 ("items", "center")]:
    r.setStyle(result, k, v)
  r.setStyle(result, "height", $ShellRowPx & "px")
  r.setStyle(result, "width", $widthPx & "px")
  r.setAttribute(result, TextMetricAttribute, gpuiMetricFor(trEditorCode))

proc span(r: GpuiRenderer; text: string; a: TermAttrs; widthPx = -1;
          cursor = false): GpuiElement =
  result = r.createElement("span")
  let (fgColour, bgColour) = drawnColours(a)
  var fg = termHex(fgColour)
  var bg = termHex(bgColour)
  if fg.len == 0: fg = ShellTextColour
  if cursor:
    # The cursor's cell, reversed.
    bg = fg
    fg = ShellGround
  r.setStyle(result, "color", fg)
  if bg.len > 0:
    r.setStyle(result, "background", bg)
  if a.bold:
    r.setStyle(result, "font-weight", "bold")
  if a.italic:
    r.setStyle(result, "font-style", "italic")
  r.setStyle(result, "flex-shrink", "0")
  r.setStyle(result, "white-space", "pre")
  if widthPx >= 0:
    r.setStyle(result, "width", $widthPx & "px")
  if cursor:
    r.setAttribute(result, "data-ct-shell-cursor", "true")
  r.appendChild(result, r.createTextNode(text))

proc gutterText*(vm: ShellVM; row: ShellRow): string =
  ## The gutter of a row — the same call the desktop's view and the terminal
  ## make (`actionGlyph`, `actionBar`).
  case row.mark
  of srmNone: ""
  of srmStart: vm.actions[row.action].actionGlyph
  of srmRange: actionBar()

proc drawShell*(r: GpuiRenderer; pane: GpuiElement; vm: ShellVM;
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
  r.setStyle(pane, "background", ShellGround)
  let lay = shellLayout(body)
  r.setAttribute(pane, ShellAttribute, $vm.state.val)
  r.setAttribute(pane, "data-ct-shell-size", $vm.screen.cols & "x" &
                 $vm.screen.rows)
  let note = vm.note.val
  let header = rowElement(r, lay.header.w)
  r.setStyle(header, "height", $ShellHeaderPx & "px")
  r.setAttribute(header, "data-ct-shell-header", vm.statusWords)
  r.appendChild(header, span(r, "SHELL  " & vm.statusWords &
                            (if note.len > 0: " · " & note else: ""),
                            TermAttrs()))
  r.setStyle(header, "padding-left", $ChromePaddingPx & "px")
  r.setStyle(header, "color", ShellMutedColour)
  r.appendChild(pane, header)
  let gutterPx = lay.textX - lay.output.x
  let rows = vm.shellRows(vm.screen.rows)
  r.setAttribute(pane, "data-ct-shell-top", $vm.visibleTop(vm.screen.rows))
  r.setAttribute(pane, "data-ct-shell-lines", $vm.lineCount)
  for row in rows:
    let el = rowElement(r, lay.output.w)
    r.setAttribute(el, ShellLineAttribute, $row.line)
    r.setAttribute(el, "data-ct-shell-text", row.text)
    let g = r.createElement("span")
    r.setStyle(g, "width", $gutterPx & "px")
    r.setStyle(g, "flex-shrink", "0")
    r.setStyle(g, "white-space", "pre")
    if row.mark != srmNone:
      let a = vm.actions[row.action]
      r.setAttribute(el, "data-ct-shell-mark",
                     (if row.mark == srmStart: "start" else: "range"))
      r.setAttribute(el, "data-ct-shell-tone", $row.tone)
      r.setAttribute(el, "data-ct-shell-action", $row.action)
      r.setAttribute(g, "data-ct-shell-gutter", a.actionSummary)
      r.setStyle(g, "color", ShellToneColours[row.tone])
    r.appendChild(g, r.createTextNode(vm.gutterText(row)))
    r.appendChild(el, g)
    for run in row.runs:
      if run.col >= lay.cols: break
      if row.cursorCol >= run.col and row.cursorCol < run.col + run.cells:
        # The cursor's run, split around its cell.
        var before, at, after = ""
        var c = run.col
        for ch in run.text.runes:
          let s = $ch
          if c < row.cursorCol: before.add s
          elif c == row.cursorCol: at.add s
          else: after.add s
          c += max(1, runeCells(ch))
        if before.len > 0: r.appendChild(el, span(r, before, run.attrs))
        r.appendChild(el, span(r, (if at.len > 0: at else: " "), run.attrs,
                               cursor = true))
        if after.len > 0: r.appendChild(el, span(r, after, run.attrs))
      else:
        r.appendChild(el, span(r, run.text, run.attrs))
    r.appendChild(pane, el)
  drawListScrubber(r, pane, body, scrubberModel(vm.lineCount,
    vm.visibleTop(vm.screen.rows), vm.screen.rows), "shell")
  true

proc shellHitAt*(vm: ShellVM; body: PxRect; x, y: int): GShellHit =
  ## What a press at window pixel `(x, y)` is on, by the drawing's layout.
  result = GShellHit(kind: gshNone, line: -1, action: -1)
  if vm.isNil or not body.contains(x, y):
    return
  let lay = shellLayout(body)
  if lay.header.contains(x, y):
    return GShellHit(kind: gshHeader, line: -1, action: -1)
  let track = listTrackRect(body, "shell")
  if track.contains(x, y):
    result.kind = gshTrack
    result.fraction = if track.h <= 1: 0.0
                      else: clamp(float(y - track.y) / float(track.h - 1),
                                  0.0, 1.0)
    return
  if not lay.output.contains(x, y):
    return
  let i = (y - lay.output.y) div ShellRowPx
  let rows = vm.shellRows(vm.screen.rows)
  if i < 0 or i >= rows.len:
    return GShellHit(kind: gshText, line: -1, action: -1)
  let row = rows[i]
  if x < lay.textX and row.mark != srmNone:
    return GShellHit(kind: gshGutter, line: row.line, action: row.action)
  return GShellHit(kind: gshText, line: row.line, action: -1)
