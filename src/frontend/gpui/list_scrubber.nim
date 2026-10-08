## gpui/list_scrubber.nim — PLAT-51: a list pane's scrollbar SCRUBBER in the
## GPUI window (Scrollbar-Scrubbers.md §4, "GPUI": a native scrollbar element
## of the pane, a filled-rect thumb, a tick for the current position), for the
## Event Log and the Call Trace. The model is the shared
## `viewmodels/scrollbar_scrubber.nim`; this module only places its fractions
## on pixels and turns a pointer's y back into a fraction ("no front-end
## computes a row from a pointer itself").
##
## The Terminal Output pane's line scrubber (PLAT-52, `terminal_output_leaf`)
## is the same drawing with the same colours; it predates this module and
## keeps its own layout because its pane has a view toggle above the lines.

import isonim_gpui/renderer

import codetracer_embed
import ./window_geometry
import ./chrome
import ./terminal_output_leaf

const
  ListTrackPx* = TerminalTrackPx
    ## The track's width: the Terminal Output scrubber's.
  ListMinThumbPx* = TerminalMinThumbPx
  ListMarkPx* = TerminalMarkPx
  ListTrackAttribute* = "data-ct-list-scrubber"
    ## On the track: the pane id it scrubs.
  ListMarkAttribute* = "data-ct-list-scrubber-mark"
    ## On the current-position mark: the row it marks.
  EventLogRowPx* = 21
    ## The event log's row pitch in the window (the vocabulary table's text
    ## line), for how many rows its body shows.

type
  ListScrubDrag* = object
    ## A press held on a list scrubber's thumb: the motion that follows moves
    ## the pane's VIEW until the release.
    active*: bool
    pane*: string

  ListScrubHit* = object
    onTrack*: bool
    onThumb*: bool
    fraction*: float

proc listTrackRect*(body: PxRect): PxRect =
  ## The track: the pane body's right edge inside its padding, its full
  ## height.
  PxRect(x: body.x + body.w - ChromePaddingPx - ListTrackPx,
         y: body.y + ChromePaddingPx, w: ListTrackPx,
         h: max(0, body.h - 2 * ChromePaddingPx))

proc listRowsOf*(body: PxRect; rowPx: int): int =
  ## How many rows a body shows at `rowPx`.
  max(1, (body.h - 2 * ChromePaddingPx) div max(1, rowPx))

proc box(r: GpuiRenderer; rect, body: PxRect; colour: string): GpuiElement =
  result = r.createElement("div")
  r.setStyle(result, "position", "absolute")
  r.setStyle(result, "left", $(rect.x - body.x) & "px")
  r.setStyle(result, "top", $(rect.y - body.y) & "px")
  r.setStyle(result, "width", $max(1, rect.w) & "px")
  r.setStyle(result, "height", $max(1, rect.h) & "px")
  if colour.len > 0:
    r.setStyle(result, "background", colour)

proc drawListScrubber*(r: GpuiRenderer; pane: GpuiElement; body: PxRect;
                       sm: ScrubberModel; paneId: string) =
  ## The track, the thumb over the WHOLE population and the current-position
  ## mark, absolutely placed in `pane` (whose box starts at `body`).
  if pane.isNil:
    return
  # A redraw of the scrubber alone (the other pane's leaf was redrawn)
  # replaces the one drawn before rather than stacking a second.
  var i = childCount(pane) - 1
  while i >= 0:
    let c = nthChild(pane, i)
    if getAttribute(c, ListTrackAttribute).len > 0 or
       getAttribute(c, ListMarkAttribute).len > 0:
      r.removeChild(pane, c)
    dec i
  if body.w <= ListTrackPx or body.h <= 2 * ChromePaddingPx:
    return
  r.setStyle(pane, "position", "relative")
  let track = listTrackRect(body)
  let span = sm.thumbSpan(track.h, ListMinThumbPx)
  let t = box(r, track, body, "")
  r.setAttribute(t, ListTrackAttribute, paneId)
  r.setAttribute(t, "data-ct-thumb-top", $span.start)
  r.setAttribute(t, "data-ct-thumb-px", $span.length)
  r.setAttribute(t, "data-ct-scrub-total", $sm.total)
  r.setAttribute(t, "data-ct-scrub-first", $sm.firstVisible)
  r.setAttribute(t, "data-ct-scrub-known", $sm.totalKnown)
  r.setStyle(t, "display", "flex")
  r.setStyle(t, "flex-direction", "column")
  r.setStyle(t, "padding-top", $span.start & "px")
  let thumb = r.createElement("div")
  r.setStyle(thumb, "width", $ListTrackPx & "px")
  r.setStyle(thumb, "height", $span.length & "px")
  r.setStyle(thumb, "flex-shrink", "0")
  r.setStyle(thumb, "background", TerminalThumbColour)
  r.setStyle(thumb, "rounded", "3px")
  r.appendChild(t, thumb)
  r.appendChild(pane, t)
  let f = sm.currentFraction
  if f >= 0.0:
    let y = track.y + min(track.h - ListMarkPx, int(f * float(track.h)))
    let mark = box(r, PxRect(x: track.x, y: y, w: ListTrackPx, h: ListMarkPx),
                   body, TerminalMarkColour)
    r.setAttribute(mark, ListMarkAttribute, $sm.current)
    r.appendChild(pane, mark)

proc listScrubHit*(body: PxRect; sm: ScrubberModel; x, y: int): ListScrubHit =
  ## A press at `(x, y)`: on the track (a jump) or on its thumb (a drag), and
  ## the fraction the model takes — the track's ends at 0 and 1.
  let track = listTrackRect(body)
  if track.h <= 0 or x < track.x or x >= track.x + track.w or
     y < track.y or y >= track.y + track.h:
    return
  let span = sm.thumbSpan(track.h, ListMinThumbPx)
  let local = y - track.y
  ListScrubHit(onTrack: true,
               onThumb: local >= span.start and local < span.start + span.length,
               fraction: trackFractionAt(local, track.h))

proc scrubTop*(sm: ScrubberModel; fraction: float; dragging: bool): int =
  ## The new first visible row: §3.2's click (centre the row at the
  ## fraction) or §3.3's held thumb (the thumb follows the pointer).
  if dragging: sm.dragTo(fraction - sm.thumbLength / 2.0)
  else: sm.clickAt(fraction)
