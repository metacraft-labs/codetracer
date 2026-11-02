## gpui/list_scrubber.nim — PLAT-51: a list pane's scrollbar SCRUBBER in the
## GPUI window (Scrollbar-Scrubbers.md §4, "GPUI": a native scrollbar element
## of the pane, a filled-rect thumb, a tick for the current position), for the
## Event Log and the Call Trace — and (M71, codetracer#838) the ordinary
## scrollbar of the Files and VCS panes, whose rows are in hand (§2: the same
## track, the same §3 press and drag). The model is the shared
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
  NarrowTrackPx* = 10
    ## The desktop's list scrollbar (`.ct-list-scrubber`), its thumb 6 px
    ## inside it on `rgba(121, 121, 121, 0.4)`.
  NarrowThumbColour = "#79797966"
  EventChromeAbovePx* = 30 + 25
    ## The event log's toolbar and header (`leaves.EventToolbarPx`,
    ## `EventHeaderPx`).
  EventChromeBelowPx* = 33
    ## Its pager (`leaves.EventFooterPx`).
  CallChromeAbovePx* = 26
    ## The call trace's search field (`leaves.CallSearchPx`): the desktop's
    ## track starts at its foot.
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

proc listTrackRect*(body: PxRect; pane = ""): PxRect =
  ## The track: the pane body's right edge inside its padding, its full
  ## height.
  # The desktop's list panes (measured 2026-10-17): a 10 px track along the
  # pane's right edge, under the pane's own chrome — the event log's toolbar
  # and header, the call trace's search field — and above the event log's
  # pager.
  case pane
  of "eventLog":
    let top = 8 + EventChromeAbovePx
    return PxRect(x: body.x + body.w - NarrowTrackPx, y: body.y + top,
                  w: NarrowTrackPx, h: max(0, body.h - top - EventChromeBelowPx))
  of "calltrace":
    let top = 8 + CallChromeAbovePx
    return PxRect(x: body.x + body.w - NarrowTrackPx, y: body.y + top,
                  w: NarrowTrackPx, h: max(0, body.h - top))
  of "fileTree":
    # M71 (#838): the Files pane's rows reach its sides under the desktop's
    # 8 px `.lm_content` top (`window_geometry.paneInsetOf`): the narrow
    # list track along its right edge, beside every row.
    return PxRect(x: body.x + body.w - NarrowTrackPx, y: body.y + 8,
                  w: NarrowTrackPx, h: max(0, body.h - 8))
  else: discard
  PxRect(x: body.x + body.w - ChromePaddingPx - ListTrackPx,
         y: body.y + ChromePaddingPx, w: ListTrackPx,
         h: max(0, body.h - 2 * ChromePaddingPx))

proc box(r: GpuiRenderer; rect, body: PxRect; colour: string): GpuiElement =
  result = r.createElement("div")
  r.setStyle(result, "position", "absolute")
  r.setStyle(result, "left", $(rect.x - body.x) & "px")
  r.setStyle(result, "top", $(rect.y - body.y) & "px")
  r.setStyle(result, "width", $max(1, rect.w) & "px")
  r.setStyle(result, "height", $max(1, rect.h) & "px")
  if colour.len > 0:
    r.setStyle(result, "background", colour)

proc clearListScrubber*(r: GpuiRenderer; pane: GpuiElement) =
  ## Remove the track and mark drawn in `pane` before — a redraw replaces
  ## them rather than stacking a second, and (M71) a pane whose rows now fit
  ## keeps none.
  if pane.isNil:
    return
  var i = childCount(pane) - 1
  while i >= 0:
    let c = nthChild(pane, i)
    if getAttribute(c, ListTrackAttribute).len > 0 or
       getAttribute(c, ListMarkAttribute).len > 0:
      r.removeChild(pane, c)
    dec i

proc drawListScrubber*(r: GpuiRenderer; pane: GpuiElement; body: PxRect;
                       sm: ScrubberModel; paneId: string) =
  ## The track, the thumb over the WHOLE population and the current-position
  ## mark, absolutely placed in `pane` (whose box starts at `body`).
  if pane.isNil:
    return
  # A redraw of the scrubber alone (the other pane's leaf was redrawn)
  # replaces the one drawn before rather than stacking a second.
  r.clearListScrubber(pane)
  if body.w <= ListTrackPx or listTrackRect(body, paneId).h <= 0:
    return
  r.setStyle(pane, "position", "relative")
  let track = listTrackRect(body, paneId)
  let narrow = paneId in ["eventLog", "calltrace", "fileTree"]
  let span = sm.thumbSpan(track.h, ListMinThumbPx)
  let t = box(r, track, body, "")
  r.setAttribute(t, ListTrackAttribute, paneId)
  r.setAttribute(t, "data-ct-thumb-top", $span.start)
  r.setAttribute(t, "data-ct-thumb-px", $span.length)
  r.setAttribute(t, "data-ct-scrub-total", $sm.total)
  r.setAttribute(t, "data-ct-scrub-first", $sm.firstVisible)
  # M71: how many rows the view shows, so a reader can say "the LAST rows"
  # (first + visible == total) of a pane whose body it does not measure.
  r.setAttribute(t, "data-ct-scrub-visible", $sm.visible)
  r.setAttribute(t, "data-ct-scrub-known", $sm.totalKnown)
  r.setStyle(t, "display", "flex")
  r.setStyle(t, "flex-direction", "column")
  r.setStyle(t, "padding-top", $span.start & "px")
  if narrow:
    r.setStyle(t, "padding-left", "2px")
  let thumb = r.createElement("div")
  r.setStyle(thumb, "width", $(if narrow: track.w - 4 else: ListTrackPx) & "px")
  r.setStyle(thumb, "height", $span.length & "px")
  r.setStyle(thumb, "flex-shrink", "0")
  r.setStyle(thumb, "background", if narrow: NarrowThumbColour
                                  else: TerminalThumbColour)
  r.setStyle(thumb, "rounded", "3px")
  r.appendChild(t, thumb)
  r.appendChild(pane, t)
  let f = sm.currentFraction
  if f >= 0.0:
    let y = track.y + min(track.h - ListMarkPx, int(f * float(track.h)))
    let mark = box(r, PxRect(x: track.x, y: y, w: track.w, h: ListMarkPx),
                   body, TerminalMarkColour)
    r.setAttribute(mark, ListMarkAttribute, $sm.current)
    r.appendChild(pane, mark)

proc listScrubHit*(body: PxRect; sm: ScrubberModel; x, y: int;
                   pane = ""): ListScrubHit =
  ## A press at `(x, y)`: on the track (a jump) or on its thumb (a drag), and
  ## the fraction the model takes — the track's ends at 0 and 1.
  let track = listTrackRect(body, pane)
  if track.h <= 0 or x < track.x or x >= track.x + track.w or
     y < track.y or y >= track.y + track.h:
    return
  let span = sm.thumbSpan(track.h, ListMinThumbPx)
  let local = y - track.y
  ListScrubHit(onTrack: true,
               onThumb: local >= span.start and local < span.start + span.length,
               fraction: trackFractionAt(local, track.h))

var barGrab*: tuple[held: bool, offset: float]
  ## PLAT-70 Part H (Scrollbar-Scrubbers.md §3.3, §7.6): where on the thumb
  ## the press that holds it took it — one at a time in the window, so one
  ## value serves every bar (the list scrubbers, the editor's two bars,
  ## Terminal Output's, the State pane's, Find in Files').

proc beginBarGrab*(sm: ScrubberModel; fraction: float) =
  ## A press on a thumb at track fraction `fraction`: the drag that follows
  ## keeps the thumb under the pointer by that point, as the desktop's
  ## Chromium and Monaco scrollbars do, instead of centring it.
  barGrab = (true, sm.grabOffset(fraction))

proc heldThumbStart*(sm: ScrubberModel; fraction: float): float =
  ## The thumb's start while it is held at `fraction`.
  fraction - (if barGrab.held: barGrab.offset else: sm.thumbLength / 2.0)

proc scrubTop*(sm: ScrubberModel; fraction: float; dragging: bool): int =
  ## The new first visible row: §3.2's click (centre the row at the
  ## fraction) or §3.3's held thumb (the thumb follows the pointer by the
  ## point it was taken by).
  if dragging: sm.dragTo(sm.heldThumbStart(fraction))
  else: sm.clickAt(fraction)
