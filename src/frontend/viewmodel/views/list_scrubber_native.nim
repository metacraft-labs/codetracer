## views/list_scrubber_native.nim — a list pane's scrollbar scrubber for a
## native renderer: the same elements, classes and placement the browser's
## `list_scrubber_dom` draws, through any IsoNim renderer.
##
## The browser decorates a scrolled list with a track over its right edge
## (`.ct-list-scrubber`, the thumb and the "now" mark inside it) and hides the
## container's own bar (`.ct-scrubbed`). A native front-end that draws the
## same views under the same style sheet needs the same elements, or its
## class lists and its bars differ from the desktop's.
##
## Placement needs the laid-out boxes, which a native renderer has after a
## frame: `attachScrubber` builds the elements and records how to place
## them, and the host calls `refresh` once the frame is laid out, with a
## `Measure` that answers a node's border box. The thumb's span is the
## shared model's (`viewmodels/scrollbar_scrubber`), as in the browser.
##
## Presses on the track (the scrub) are the browser module's; a native
## front-end routes pointer input through its own procedures.

import std/math

import ../viewmodels/scrollbar_scrubber

const
  MinThumbPx = 20
  MarkPx = 3
    ## As `list_scrubber_dom`.

type
  Box* = tuple[x, y, w, h: float]
    ## A border box in CSS pixels.

  NativeScrubber*[N] = ref object
    container*, host*: N
    track*, thumb*, mark*: N
    total*, current*: proc(): int
    rowHeight*: proc(): float
    paneId*: string

proc attachScrubber*[R, N](r: R; container, host: N;
                           total, current: proc(): int;
                           rowHeight: proc(): float;
                           paneId: string): NativeScrubber[N] =
  ## The track, thumb and mark over `container`, inside `host`, as
  ## `list_scrubber_dom.attachListScrubber` builds them.
  mixin createElement, setAttribute, getAttribute, setStyle, appendChild
  let classes = r.getAttribute(container, "class")
  r.setAttribute(container, "class",
                 (if classes.len > 0: classes & " " else: "") & "ct-scrubbed")
  r.setStyle(host, "position", "relative")
  result = NativeScrubber[N](container: container, host: host, total: total,
                             current: current, rowHeight: rowHeight,
                             paneId: paneId)
  result.track = r.createElement("div")
  r.setAttribute(result.track, "class", "ct-list-scrubber")
  result.thumb = r.createElement("div")
  r.setAttribute(result.thumb, "class", "ct-list-scrubber-thumb")
  result.mark = r.createElement("div")
  r.setAttribute(result.mark, "class", "ct-list-scrubber-mark")
  r.setAttribute(result.track, "data-ct-list-scrubber", paneId)
  r.setStyle(result.mark, "height", $MarkPx & "px")
  r.appendChild(result.track, result.thumb)
  r.appendChild(result.track, result.mark)
  r.appendChild(host, result.track)

proc refresh*[R, N](r: R; s: NativeScrubber[N];
                    measure: proc(n: N): Box;
                    contentHeight: float) =
  ## Places the track, thumb and mark from the laid-out boxes, as
  ## `list_scrubber_dom.refresh` does from the browser's: the view at its
  ## top (a native view opens unscrolled), `contentHeight` the scrolled
  ## content's height.
  mixin setStyle, setAttribute
  let c = measure(s.container)
  let h0 = measure(s.host)
  if c.h < 2.0:
    r.setStyle(s.track, "display", "none")
    return
  r.setStyle(s.track, "display", "block")
  let rowH = max(1.0, s.rowHeight())
  let total = s.total()
  let visible = max(1, int(round(c.h / rowH)))
  let m = scrubberModel(total, 0, visible, s.current())
  let h = max(1, int(c.h))
  r.setStyle(s.track, "top", $int(c.y - h0.y) & "px")
  r.setStyle(s.track, "height", $h & "px")
  # A last row cut by the container's edge is still clipped: project the
  # excess in pixels, as the browser's `projection` does.
  let projected =
    if m.totalKnown and m.total > 0 and m.visible >= m.total and contentHeight > c.h:
      scrubberModel(max(1, int(ceil(contentHeight))), 0, max(1, int(c.h)))
    else: m
  let span = projected.thumbSpan(h, MinThumbPx)
  let fits = projected.totalKnown and projected.visible >= projected.total
  r.setStyle(s.thumb, "display", if fits: "none" else: "block")
  r.setStyle(s.thumb, "top", $span.start & "px")
  r.setStyle(s.thumb, "height", $span.length & "px")
  r.setAttribute(s.track, "data-ct-scrub-total", $m.total)
  r.setAttribute(s.track, "data-ct-scrub-first", $m.firstVisible)
  r.setAttribute(s.track, "data-ct-scrub-visible", $m.visible)
  r.setAttribute(s.track, "data-ct-scrub-current", $m.current)
  r.setAttribute(s.track, "data-ct-scrub-known", $m.totalKnown)
  r.setAttribute(s.thumb, "data-ct-thumb-top", $span.start)
  r.setAttribute(s.thumb, "data-ct-thumb-px", $span.length)
  let f = m.currentFraction
  if f < 0.0:
    r.setStyle(s.mark, "display", "none")
  else:
    r.setStyle(s.mark, "display", "block")
    r.setStyle(s.mark, "top", $min(h - MarkPx, int(f * float(h))) & "px")
