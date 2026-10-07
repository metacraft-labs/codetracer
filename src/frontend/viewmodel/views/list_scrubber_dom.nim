## views/list_scrubber_dom.nim — PLAT-51: a list pane's scrollbar SCRUBBER on
## the desktop (Electron and the web build), over the pane's own scroll
## container (Scrollbar-Scrubbers.md §4, "Desktop": the pane's virtual-scroll
## container, sized from the total; pointer events on the track replacing the
## default page step; a tick for the current position).
##
## The model is the shared `viewmodels/scrollbar_scrubber.nim` — the same one
## the terminal and GPUI project onto cells and pixels. This module projects it
## onto a DOM track drawn over the container's right edge (the container's own
## scrollbar is hidden: `.ct-scrubbed`), and feeds a press's y back as the
## model's fraction. It moves the VIEW (the container's `scrollTop`); a click
## on a ROW is what moves the debugger.
##
## Used by the Event Log (`ui/event_log.nim`, over DataTables' Scroller body),
## the Call Trace (`views/isonim_calltrace_view.nim`) and the Terminal Output
## pane's line view (`views/isonim_terminal_output_view.nim`).
##
## For a Playwright reader the track carries its model as attributes:
## `data-ct-scrub-total`, `-first`, `-visible`, `-current`, and the thumb's
## `data-ct-thumb-top` / `-px`; `window.__ctScrubberJumps` counts the view
## moves the scrubber made (a test bounds a drag's fetches against them).

import std/math

import ../viewmodels/scrollbar_scrubber

when defined(js):
  import std/jsffi

  type
    ListScrubberDom* = ref object
      container*: JsObject
        ## The element that scrolls.
      host*: JsObject
        ## The element the track is placed in (made `position: relative`).
      track, thumb, mark: JsObject
      total*: proc(): int
        ## The WHOLE population (never the rows the pane holds).
      current*: proc(): int
        ## The row of the current recording position, -1 for none.
      rowHeight*: proc(): float
        ## One row's height in px (measured; the scroll offset ÷ it is the
        ## first visible row).
      totalKnown*: proc(): bool
      firstVisible*: proc(): int
        ## Optional: the first row shown, for a container whose scroll offset
        ## is not `row * rowHeight` (DataTables' Scroller scales it).
      visibleRows*: proc(): int
        ## Optional, with `firstVisible`: how many rows show.
      jumpTo*: proc(row: int)
        ## Optional: bring `row` to the top of the view, for such a container.
      visibleHeight*: proc(): int
        ## Optional: how much of the container is not covered by the pane's
        ## own chrome (the event log's footer overlaps its body) — the track
        ## is that tall, so every pixel of it takes a press.
      dragging: bool

  const
    TrackPx = 10
    MinThumbPx = 20
    MarkPx = 3

  proc createDiv(cls: cstring): JsObject
    {.importjs: "(function(c){const d=document.createElement('div');d.className=c;return d;})(#)".}
  proc appendChildJs(parent, child: JsObject) {.importjs: "#.appendChild(#)".}
  proc setStyleJs(el: JsObject; name, value: cstring)
    {.importjs: "#.style.setProperty(#, #)".}
  proc setAttrJs(el: JsObject; name, value: cstring)
    {.importjs: "#.setAttribute(#, #)".}
  proc addClassJs(el: JsObject; cls: cstring) {.importjs: "#.classList.add(#)".}
  proc scrollTopOf(el: JsObject): float {.importjs: "(#.scrollTop || 0)".}
  proc setScrollTop(el: JsObject; v: float) {.importjs: "#.scrollTop = #".}
  proc clientHeightOf(el: JsObject): float {.importjs: "(#.clientHeight || 0)".}
  proc offsetTopIn(el, host: JsObject): float {.importjs:
    "(function(e,h){const a=e.getBoundingClientRect(),b=h.getBoundingClientRect();return a.top-b.top;})(#,#)".}
  proc trackTopOf(el: JsObject): float {.importjs: "#.getBoundingClientRect().top".}
  proc clientYOf(ev: JsObject): float {.importjs: "(#.clientY || 0)".}
  proc buttonOf(ev: JsObject): int {.importjs: "(#.button || 0)".}
  proc stopEv(ev: JsObject) {.importjs:
    "(function(e){e.preventDefault();e.stopPropagation();})(#)".}
  proc listen(el: JsObject; name: cstring; handler: proc(ev: JsObject))
    {.importjs: "#.addEventListener(#, #)".}
  proc listenDoc(name: cstring; handler: proc(ev: JsObject))
    {.importjs: "document.addEventListener(#, #)".}
  proc unlistenDoc(name: cstring; handler: proc(ev: JsObject))
    {.importjs: "document.removeEventListener(#, #)".}
  proc everyMs(handler: proc(); ms: int) {.importjs: "setInterval(#, #)".}
  proc countJump() {.importjs:
    "(window.__ctScrubberJumps = (window.__ctScrubberJumps || 0) + 1)".}

  proc scrollHeightOf(el: JsObject): float {.importjs: "(#.scrollHeight || 0)".}

  proc model(s: ListScrubberDom): ScrubberModel =
    let rowH = max(1.0, s.rowHeight())
    let total = s.total()
    # ROUNDED: a view 23.96 rows tall shows 24 rows' worth (measured: the
    # call trace's 599 px over 25 px rows, the last call fully in view when
    # the floor said 23 and left the thumb a row short of the track's end).
    let visible = if s.visibleRows.isNil:
                    max(1, int(round(s.container.clientHeightOf() / rowH)))
                  else: max(1, s.visibleRows())
    # A view scrolled to its END shows the population's last rows, though
    # its offset is a fraction of a row short of `(total - visible) * rowH`
    # when the view's height is not a whole number of rows: the first row
    # is then the one that puts the LAST row in view, not the floor of the
    # offset (which would leave the thumb a row short of the track's end).
    let c = s.container
    let atEnd = c.scrollHeightOf() > c.clientHeightOf() and
                c.scrollTopOf() + c.clientHeightOf() >= c.scrollHeightOf() - 1.0
    let first =
      if atEnd: max(0, total - visible)
      # ROUNDED, not floored: a jump to row `k` sets the offset to
      # `k * rowH`, which the container may hand back a fraction of a pixel
      # short (measured: the call trace read row 579 after a jump to 580).
      elif s.firstVisible.isNil: int(round(c.scrollTopOf() / rowH))
      else: s.firstVisible()
    scrubberModel(total, first, visible, s.current(),
                  totalKnown = s.totalKnown())

  proc trackHeight(s: ListScrubberDom): int =
    let full = max(1, int(s.container.clientHeightOf()))
    if s.visibleHeight.isNil: full
    else: max(1, min(full, s.visibleHeight()))

  proc refresh*(s: ListScrubberDom) =
    ## Place the track over the container, the thumb at the view, the mark
    ## at "now". A container that is not shown (another view of the pane)
    ## shows no track.
    if s.container.clientHeightOf() < 2.0:
      s.track.setStyleJs("display", "none")
      return
    s.track.setStyleJs("display", "block")
    let m = s.model()
    let h = s.trackHeight()
    s.track.setStyleJs("top", cstring($int(s.container.offsetTopIn(s.host)) & "px"))
    s.track.setStyleJs("height", cstring($h & "px"))
    let span = m.thumbSpan(h, MinThumbPx)
    s.thumb.setStyleJs("top", cstring($span.start & "px"))
    s.thumb.setStyleJs("height", cstring($span.length & "px"))
    s.track.setAttrJs("data-ct-scrub-total", cstring($m.total))
    s.track.setAttrJs("data-ct-scrub-first", cstring($m.firstVisible))
    s.track.setAttrJs("data-ct-scrub-visible", cstring($m.visible))
    s.track.setAttrJs("data-ct-scrub-current", cstring($m.current))
    s.track.setAttrJs("data-ct-scrub-known", cstring($m.totalKnown))
    s.thumb.setAttrJs("data-ct-thumb-top", cstring($span.start))
    s.thumb.setAttrJs("data-ct-thumb-px", cstring($span.length))
    let f = m.currentFraction
    if f < 0.0:
      s.mark.setStyleJs("display", "none")
    else:
      s.mark.setStyleJs("display", "block")
      s.mark.setStyleJs("top", cstring($min(h - MarkPx, int(f * float(h))) & "px"))

  proc moveViewTo(s: ListScrubberDom; firstRow: int) =
    ## The VIEW to `firstRow` — the container's scroll, which the pane's own
    ## scroll handling turns into a window fetch.
    countJump()
    if s.jumpTo.isNil:
      s.container.setScrollTop(float(firstRow) * max(1.0, s.rowHeight()))
    else:
      s.jumpTo(firstRow)
    s.refresh()

  proc attachListScrubber*(container, host: JsObject;
                           total, current: proc(): int;
                           rowHeight: proc(): float;
                           totalKnown: proc(): bool = nil;
                           paneId = "";
                           firstVisible: proc(): int = nil;
                           visibleRows: proc(): int = nil;
                           jumpTo: proc(row: int) = nil;
                           visibleHeight: proc(): int = nil): ListScrubberDom =
    ## Draw a scrubber over `container` inside `host`, and route its presses.
    let s = ListScrubberDom(container: container, host: host, total: total,
                            current: current, rowHeight: rowHeight,
                            totalKnown: (if totalKnown.isNil:
                                           proc(): bool = true
                                         else: totalKnown),
                            firstVisible: firstVisible,
                            visibleRows: visibleRows, jumpTo: jumpTo,
                            visibleHeight: visibleHeight)
    container.addClassJs("ct-scrubbed")
    host.setStyleJs("position", "relative")
    s.track = createDiv("ct-list-scrubber")
    s.thumb = createDiv("ct-list-scrubber-thumb")
    s.mark = createDiv("ct-list-scrubber-mark")
    s.track.setAttrJs("data-ct-list-scrubber", cstring(paneId))
    s.track.setStyleJs("width", cstring($TrackPx & "px"))
    s.mark.setStyleJs("height", cstring($MarkPx & "px"))
    s.track.appendChildJs(s.thumb)
    s.track.appendChildJs(s.mark)
    host.appendChildJs(s.track)
    var grab = 0.0
    var onMove: proc(ev: JsObject)
    var onUp: proc(ev: JsObject)
    onMove = proc(ev: JsObject) =
      if not s.dragging:
        return
      let h = s.trackHeight()
      let y = ev.clientYOf() - s.track.trackTopOf() - grab
      let m = s.model()
      # §3.3: the thumb follows the pointer — its start at the pointer less
      # where on the thumb it was grabbed.
      s.moveViewTo(m.dragTo(y / float(h)))
    onUp = proc(ev: JsObject) =
      s.dragging = false
      unlistenDoc("mousemove", onMove)
      unlistenDoc("mouseup", onUp)
    s.track.listen("mousedown", proc(ev: JsObject) =
      if ev.buttonOf() != 0:
        return
      ev.stopEv()
      let h = s.trackHeight()
      let y = ev.clientYOf() - s.track.trackTopOf()
      let m = s.model()
      let span = m.thumbSpan(h, MinThumbPx)
      if y >= float(span.start) and y < float(span.start + span.length):
        # §3.3: a drag of the thumb.
        s.dragging = true
        grab = y - float(span.start)
        listenDoc("mousemove", onMove)
        listenDoc("mouseup", onUp)
      else:
        # §3.2: a click on the track JUMPS there (the row at the fraction
        # centred), instead of the platform's page-by-page step.
        s.moveViewTo(m.clickAt(trackFractionAt(int(y), h))))
    container.listen("scroll", proc(ev: JsObject) = s.refresh())
    # The total and "now" change without a scroll (a filter, a move): the
    # track follows them.
    everyMs(proc() = s.refresh(), 250)
    s.refresh()
    s
