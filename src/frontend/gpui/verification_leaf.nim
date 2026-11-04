## gpui/verification_leaf.nim — PLAT-63. The GPUI window's **Verification**
## pane, drawn natively from the window's `VerificationVM` (the model the
## desktop's View › Verification and the terminal's pane draw), which the
## window's native host fills (`viewmodel/host/native_verification_host`).
##
## What the desktop's view draws, in its order and words
## (`viewmodel/views/isonim_verification_view.nim`): the run's status and its
## command line, Stop while a run is in flight, the notes, the counterexample
## offers, the findings BY KIND under their kinds' headings, and an open
## counterexample's steps — every line `VerificationVM.panelModel(...).lines`.
## The Run control is the host's (`canRun`). The rows have a fixed pitch so
## a press and the drawing go through one layout (`verificationLayout`), as
## Problems' do; the list scrolls (the wheel) and its scrollbar is the shared
## list scrubber, moving the VIEW. The cursor's line is drawn on the
## desktop's selected-row ground with its accent edge; a failed obligation's
## kind on the error colour, a limitation's on the warning colour.
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-verification-*`).

import isonim_gpui/renderer

import codetracer_embed
import ./window_geometry
import ./chrome
import ./app/leaves
import ./list_scrubber
from ../viewmodel/viewmodels/table_overflow import nil
from ../../common/view_vocabulary/layout_questions import trEditorCode
import ../styles/generated/design_tokens

type
  GVerificationPane* = object
    ## The window's own state for the pane: where the reader scrolled and a
    ## held scrubber thumb. The cursor is the ViewModel's.
    scrollTop*: int
    dragging*: bool

  VerificationLayout* = object
    body*: PxRect
    header*: PxRect
    run*, stop*: PxRect
      ## The header's controls; zero-width when not drawn.
    command*: PxRect
      ## The command line's row; zero-height when there is none.
    list*: PxRect
    rows*: int
    overflow*: bool
    model*: VerificationPanelModel
    lines*: seq[VerificationLine]

  GVerificationHitKind* = enum
    gvNone, gvRun, gvStop, gvHeader, gvLine, gvTrack, gvThumb

  GVerificationHit* = object
    kind*: GVerificationHitKind
    key*: string
      ## gvLine: the line's key ("" for a line the cursor skips).
    line*: int
    fraction*: float

const
  VerificationRowPx* = 22
  VerificationHeaderPx* = 26
  VerificationIndentPx = 16
  VerificationGapPx = 12
  VerificationButtonPadPx = 8
  VerificationAttribute* = "data-ct-verification-pane"
    ## On the pane: the run's status.
  VerificationLineAttribute* = "data-ct-verification-line"
    ## On a line: its list index, with `data-ct-verification-*`.
  VerificationControlAttribute* = "data-ct-verification-control"
    ## On a header control: `run` / `stop`.
  VerificationTextColour = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  VerificationCaptionColour* = "#8b949e"
    ## The desktop's muted caption colour (the Problems pane's, dark).
  VerificationFailureColour* = "#f85149"
    ## A failed obligation (the desktop's error colour).
  VerificationLimitationColour* = "#d29922"
    ## A limitation (the desktop's warning colour).
  VerificationOtherColour* = "#58a6ff"
    ## Any other kind (the desktop's information colour).
  VerificationOfferColour* =
    DesignTokenHex[dtColorsEditorActionPrimary][dmDark]
  VerificationSelectedGround* =
    DesignTokenHex[dtColorsUiSurfacePrimarySecondaryHover][dmDark]
  VerificationSelectedEdge =
    DesignTokenHex[dtColorsUiSurfaceActionPrimary][dmDark]
  VerificationControlGround =
    DesignTokenHex[dtColorsUiSurfaceInputDefault][dmDark]
  VerificationStopLabel* = "Stop"
  VerificationRunGlyph* = "▶ "

proc initGVerificationPane*(): GVerificationPane = GVerificationPane()

proc pxOf(text: string): int =
  int(float(table_overflow.runeMeasure(text)) * EditorColumnPx)

proc cellsOf(px: int): int = int(float(px) / EditorColumnPx)

proc kindColour*(kind: VerificationFindingKind): string =
  case kind
  of vfkFailedObligation: VerificationFailureColour
  of vfkLimitation: VerificationLimitationColour
  else: VerificationOtherColour

proc verificationLayout*(vm: VerificationVM; session: CounterexampleSessionVM;
                         body: PxRect): VerificationLayout =
  ## The pane's parts, in window pixels, inside `body` (its padding off).
  result.body = body
  result.model = vm.panelModel(session)
  result.lines = result.model.lines
  let inner = PxRect(x: body.x + ChromePaddingPx, y: body.y + ChromePaddingPx,
                     w: max(0, body.w - 2 * ChromePaddingPx),
                     h: max(0, body.h - 2 * ChromePaddingPx))
  result.header = PxRect(x: inner.x, y: inner.y, w: inner.w,
                         h: VerificationHeaderPx)
  var right = inner.x + inner.w
  if result.model.cancellable:
    let w = pxOf(VerificationStopLabel) + 2 * VerificationButtonPadPx
    right -= w
    result.stop = PxRect(x: right, y: inner.y, w: w, h: VerificationHeaderPx)
    right -= 4
  if result.model.canRun:
    let w = pxOf(VerificationRunGlyph & result.model.runLabel) +
            2 * VerificationButtonPadPx
    right -= w
    result.run = PxRect(x: right, y: inner.y, w: w, h: VerificationHeaderPx)
  var top = inner.y + VerificationHeaderPx
  if result.model.commandLine.len > 0:
    result.command = PxRect(x: inner.x, y: top, w: inner.w,
                            h: VerificationRowPx)
    top += VerificationRowPx
  top += 2
  let rest = max(0, inner.y + inner.h - top)
  result.rows = max(0, rest div VerificationRowPx)
  result.overflow = result.lines.len > result.rows
  var width = inner.w
  if result.overflow:
    width = max(0, inner.w - ListTrackPx - 2)
  result.list = PxRect(x: inner.x, y: top, w: width,
                       h: result.rows * VerificationRowPx)

proc listBody(lay: VerificationLayout): PxRect =
  PxRect(x: lay.body.x, y: lay.list.y - ChromePaddingPx, w: lay.body.w,
         h: lay.list.h + 2 * ChromePaddingPx)

proc visibleTop*(st: GVerificationPane; total, rows: int): int =
  max(0, min(st.scrollTop, total - max(1, rows)))

proc scrubberOf*(st: GVerificationPane; total, rows: int): ScrubberModel =
  scrubberModel(total, st.visibleTop(total, rows), rows)

proc revealKey*(st: var GVerificationPane; vm: VerificationVM;
                session: CounterexampleSessionVM; body: PxRect; key: string) =
  ## Keep the line `key` names in view.
  let lay = verificationLayout(vm, session, body)
  let at = lineOfKey(lay.lines, key)
  if at < 0 or lay.rows <= 0:
    return
  let top = st.visibleTop(lay.lines.len, lay.rows)
  if at < top: st.scrollTop = at
  elif at >= top + lay.rows: st.scrollTop = at - lay.rows + 1

proc scrollBy*(st: var GVerificationPane; vm: VerificationVM;
               session: CounterexampleSessionVM; body: PxRect; delta: int) =
  let lay = verificationLayout(vm, session, body)
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
  r.setStyle(result, "height", $VerificationRowPx & "px")
  r.setStyle(result, "width", $widthPx & "px")
  r.setAttribute(result, TextMetricAttribute, gpuiMetricFor(trEditorCode))

proc cut(text: string; px: int): string =
  ## `text` in a column `px` wide, ending in `…` when cut.
  fitCell(text, cellsOf(px)).text

proc appendParts(r: GpuiRenderer; el: GpuiElement; widthPx: int;
                 parts: openArray[tuple[attr, text, colour: string]]) =
  ## The line's parts left to right, each cut to the room left.
  ## A part with no room left is still emitted, zero wide, so the plan
  ## carries every word the line has (the desktop's row does, and cuts it
  ## with CSS).
  var used = 0
  for p in parts:
    if p.text.len == 0:
      continue
    let w = max(0, min(pxOf(p.text), widthPx - used))
    let run = textRun(r, cut(p.text, w), p.colour, w)
    r.setAttribute(run, "data-ct-verification-" & p.attr, p.text)
    r.appendChild(el, run)
    used += w + VerificationGapPx

proc control(r: GpuiRenderer; text, which: string; rect: PxRect): GpuiElement =
  result = textRun(r, text, VerificationTextColour, rect.w)
  r.setAttribute(result, VerificationControlAttribute, which)
  r.setStyle(result, "text-align", "center")
  r.setStyle(result, "background", VerificationControlGround)

proc drawVerification*(r: GpuiRenderer; pane: GpuiElement; vm: VerificationVM;
                       session: CounterexampleSessionVM; st: GVerificationPane;
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
  let lay = verificationLayout(vm, session, body)
  let m = lay.model
  r.setAttribute(pane, VerificationAttribute, m.statusText)
  r.setAttribute(pane, "data-ct-verification-phase", $m.phase)
  # The header: the status, the controls.
  let header = r.createElement("div")
  for (k, v) in [("display", "flex"), ("flex-shrink", "0"),
                 ("items", "center"), ("gap", "4px")]:
    r.setStyle(header, k, v)
  r.setStyle(header, "height", $VerificationHeaderPx & "px")
  let statusPx = max(0, (if m.canRun: lay.run.x
                         elif m.cancellable: lay.stop.x
                         else: lay.header.x + lay.header.w) - lay.header.x - 4)
  let status = textRun(r, cut(m.statusText, statusPx), VerificationTextColour,
                       statusPx)
  r.setAttribute(status, "data-ct-verification-status", m.statusText)
  r.appendChild(header, status)
  if m.canRun:
    r.appendChild(header, control(r, VerificationRunGlyph & m.runLabel, "run",
                                  lay.run))
  if m.cancellable:
    r.appendChild(header, control(r, VerificationStopLabel, "stop", lay.stop))
  r.appendChild(pane, header)
  if lay.command.h > 0:
    let row = rowElement(r, lay.command.w)
    let command = textRun(r, cut(m.commandLine, lay.command.w),
                          VerificationCaptionColour, lay.command.w)
    r.setAttribute(command, "data-ct-verification-command", m.commandLine)
    r.appendChild(row, command)
    r.appendChild(pane, row)
  # The list.
  let top = st.visibleTop(lay.lines.len, lay.rows)
  r.setAttribute(pane, "data-ct-verification-top", $top)
  r.setAttribute(pane, "data-ct-verification-rows", $lay.rows)
  r.setAttribute(pane, "data-ct-verification-total-lines", $lay.lines.len)
  for k in 0 ..< lay.rows:
    let i = top + k
    if i >= lay.lines.len:
      break
    let line = lay.lines[i]
    let el = rowElement(r, lay.list.w)
    r.setAttribute(el, VerificationLineAttribute, $i)
    r.setAttribute(el, "data-ct-verification-line-kind", $line.kind)
    if line.key.len > 0:
      r.setAttribute(el, "data-ct-verification-key", line.key)
    if line.key.len > 0 and line.key == m.selectedKey:
      r.setAttribute(el, "data-ct-selected", "true")
      r.setStyle(el, "background", VerificationSelectedGround)
      r.setStyle(el, "border-left", "3px solid " & VerificationSelectedEdge)
    case line.kind
    of vlNote:
      appendParts(r, el, lay.list.w,
                  [("text", line.text, VerificationCaptionColour)])
    of vlGroup, vlCounterexample:
      appendParts(r, el, lay.list.w,
                  [("text", line.text, VerificationCaptionColour)])
      r.setStyle(el, "font-weight", "600")
    of vlOffer:
      appendParts(r, el, lay.list.w,
                  [("title", "▸ " & line.title, VerificationOfferColour),
                   ("message", line.message, VerificationTextColour),
                   ("location", line.location, VerificationCaptionColour)])
    of vlFinding:
      let indent = r.createElement("span")
      r.setStyle(indent, "width", $VerificationIndentPx & "px")
      r.setStyle(indent, "flex-shrink", "0")
      r.appendChild(el, indent)
      appendParts(r, el, max(0, lay.list.w - VerificationIndentPx),
                  [("kind-label", line.kindLabel, kindColour(line.findingKind)),
                   ("title", line.title, VerificationCaptionColour),
                   ("message", line.message, VerificationTextColour)])
      r.setAttribute(el, "data-ct-verification-location", line.location)
    of vlStep:
      if line.isCurrent:
        r.setAttribute(el, "data-ct-current", "true")
      appendParts(r, el, lay.list.w,
                  [("marker", (if line.isCurrent: "▶" else: " "),
                    VerificationOfferColour),
                   ("title", $(line.row + 1) & ". " & line.title,
                    (if line.isFailure: VerificationFailureColour
                     else: VerificationCaptionColour)),
                   ("message", line.message, VerificationTextColour),
                   ("location", line.location, VerificationCaptionColour)])
    r.appendChild(pane, el)
  if lay.overflow:
    drawListScrubber(r, pane, lay.listBody,
                     st.scrubberOf(lay.lines.len, lay.rows), "verification")
  true

proc verificationHitAt*(vm: VerificationVM; session: CounterexampleSessionVM;
                        st: GVerificationPane; body: PxRect;
                        x, y: int): GVerificationHit =
  ## What a press at window pixel `(x, y)` is on, by the drawing's layout.
  result = GVerificationHit(kind: gvNone, line: -1)
  if vm.isNil or not body.contains(x, y):
    return
  let lay = verificationLayout(vm, session, body)
  if lay.run.w > 0 and lay.run.contains(x, y):
    return GVerificationHit(kind: gvRun, line: -1)
  if lay.stop.w > 0 and lay.stop.contains(x, y):
    return GVerificationHit(kind: gvStop, line: -1)
  if lay.overflow:
    let hit = listScrubHit(lay.listBody, st.scrubberOf(lay.lines.len,
                                                       lay.rows), x, y)
    if hit.onTrack:
      return GVerificationHit(kind: (if hit.onThumb: gvThumb else: gvTrack),
                              line: -1, fraction: hit.fraction)
  if not lay.list.contains(x, y):
    return GVerificationHit(kind: (if y < lay.list.y: gvHeader else: gvNone),
                            line: -1)
  let i = st.visibleTop(lay.lines.len, lay.rows) +
          (y - lay.list.y) div VerificationRowPx
  if i < 0 or i >= lay.lines.len:
    return
  result = GVerificationHit(kind: gvLine, key: lay.lines[i].key, line: i)

proc scrubVerification*(st: var GVerificationPane; vm: VerificationVM;
                        session: CounterexampleSessionVM; body: PxRect;
                        y: int; dragging: bool) =
  ## The scrubber pressed (a jump) or its thumb held (the view follows).
  let lay = verificationLayout(vm, session, body)
  if not lay.overflow:
    return
  let track = listTrackRect(lay.listBody)
  let sm = st.scrubberOf(lay.lines.len, lay.rows)
  st.scrollTop = sm.scrubTop(trackFractionAt(y - track.y, track.h), dragging)

proc lineCentre*(lay: VerificationLayout; st: GVerificationPane;
                 line: int): tuple[ok: bool, x, y: int] =
  ## Where list line `line` is drawn (past its indent), for a press aimed at
  ## it.
  let top = st.visibleTop(lay.lines.len, lay.rows)
  if line < top or line >= top + lay.rows:
    return (false, 0, 0)
  (true, lay.list.x + VerificationIndentPx + 8,
   lay.list.y + (line - top) * VerificationRowPx + VerificationRowPx div 2)
