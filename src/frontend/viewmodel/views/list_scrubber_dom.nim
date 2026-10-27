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
##
## PLAT-70 (Horizontal-Overflow.md §4): the text panes' overflow-only
## HORIZONTAL bar is this module's too (`attachHorizontalScrubber`) — the
## same model on the column axis (`viewmodels/horizontal_scroll`), drawn as
## the vertical track is, along the container's bottom, only while its
## content is wider than it; a press centres, a held thumb follows, and the
## square where it meets a vertical track belongs to neither. The browser's
## own wheel, Shift + wheel and touchpad swipe scroll the container, and the
## bar follows them.

import std/math
from isonim/core/owner import onCleanup

import ../viewmodels/scrollbar_scrubber
import ../viewmodels/horizontal_scroll

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
    MinThumbPx = 20
    MarkPx = 3
    TrackPx = 8
      ## A track's thickness: the app-wide scrollbar's (`PANEL_SCROLLBAR_SIZE`,
      ## 0.5rem — `shared_widgets.styl`), which `list_scrubber.styl` gives the
      ## vertical track and the horizontal bar. Read here where a bar is laid
      ## out beside the other: the vertical track's row lost to the bar, the
      ## corner square neither takes.

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
  proc setIntervalJs(handler: proc(); ms: int): int {.importjs: "setInterval(#, #)".}
  proc clearIntervalJs(id: int) {.importjs: "clearInterval(#)".}

  proc everyMs(handler: proc(); ms: int) =
    ## Run `handler` every `ms` for as long as the reactive root the scrubber
    ## was attached in lives. A pane's view is rendered inside a root its host
    ## disposes when the pane goes (`ui/panel_host.nim`: a GoldenLayout
    ## container destroyed, a pane rendered again over another tab's
    ## session); without the cleanup each of those left an interval running
    ## for the life of the page, refreshing a detached track from the
    ## ViewModel of a pane that no longer exists. Attached outside any root,
    ## the interval runs for the page's life, as it always did.
    let id = setIntervalJs(handler, ms)
    onCleanup(proc() = clearIntervalJs(id))
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

  proc hbarShown(el: JsObject): bool {.importjs:
    "(#.getAttribute('data-ct-hbar') === '1')".}

  proc trackHeight(s: ListScrubberDom): int =
    let full = max(1, int(s.container.clientHeightOf()))
    # PLAT-70 (HO-7): a horizontal bar along the bottom keeps its row; the
    # corner square is neither track's.
    let bar = if s.container.hbarShown: TrackPx else: 0
    if s.visibleHeight.isNil: max(1, full - bar)
    else: max(1, min(full - bar, s.visibleHeight()))

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
    # Nothing to scroll — every row is in view — shows no thumb, as the
    # app-wide scrollbar shows none; the track stays for the "now" mark.
    let fits = m.totalKnown and m.visible >= m.total
    s.thumb.setStyleJs("display", if fits: cstring"none" else: cstring"block")
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
      # THE END IS THE END of the scroll range, not `firstRow` rows down. A
      # view that is not a whole number of rows tall counts as the ROUNDED
      # number of rows (see `model`), so `maxFirstVisible * rowH` can stop a
      # fraction of a row short of the range's end, the last row cut off
      # (measured on the Terminal Output: 613 px over 24 px rows counted as
      # 26, a press at the track's end stopped 11 px short, the output's
      # last line under the pane's bottom edge). Asked for the range's end,
      # the container clamps to exactly the offset that shows the last row.
      if firstRow > 0 and firstRow >= s.model().maxFirstVisible:
        s.container.setScrollTop(s.container.scrollHeightOf())
      else:
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
    # The track's width is the app-wide scrollbar's (`list_scrubber.styl`).
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


  # -------------------------------------------------------------------------
  # PLAT-70: a text pane's horizontal bar (Horizontal-Overflow.md §4)
  # -------------------------------------------------------------------------

  type
    HorizontalScrubberDom* = ref object
      container*: JsObject
        ## The element that scrolls sideways (`overflow-x: auto`, its own
        ## horizontal scrollbar hidden by `.ct-hscrubbed`).
      host*: JsObject
      track, thumb: JsObject
      grab: float
      dragging: bool
      verticalTrack*: bool
        ## A vertical scrubber shares the container's right edge: the bar
        ## stops short of it, leaving the corner square to neither.

  proc scrollLeftOf(el: JsObject): float {.importjs: "(#.scrollLeft || 0)".}
  proc setScrollLeft(el: JsObject; v: float) {.importjs: "#.scrollLeft = #".}
  proc scrollWidthOf(el: JsObject): float {.importjs: "(#.scrollWidth || 0)".}
  proc clientWidthOf(el: JsObject): float {.importjs: "(#.clientWidth || 0)".}
  proc offsetLeftIn(el, host: JsObject): float {.importjs:
    "(function(e,h){const a=e.getBoundingClientRect(),b=h.getBoundingClientRect();return a.left-b.left;})(#,#)".}
  proc trackLeftOf(el: JsObject): float {.importjs: "#.getBoundingClientRect().left".}
  proc clientXOf(ev: JsObject): float {.importjs: "(#.clientX || 0)".}
  proc removeAttrJs(el: JsObject; name: cstring) {.importjs: "#.removeAttribute(#)".}

  proc horizontalViewOf(container: JsObject): HorizontalView =
    ## A scroll container as the shared model sees it, in pixels: the
    ## content's width, the view's, how far it is scrolled.
    result = HorizontalView(contentCols: int(container.scrollWidthOf()),
                            leftCol: int(round(container.scrollLeftOf())))
    result.setViewport(int(container.clientWidthOf()))

  proc view(s: HorizontalScrubberDom): HorizontalView =
    s.container.horizontalViewOf()

  proc barWidth(s: HorizontalScrubberDom): int =
    max(1, int(s.container.clientWidthOf()) -
           (if s.verticalTrack: TrackPx else: 0))

  proc refresh*(s: HorizontalScrubberDom) =
    ## The bar exists only while the content is wider than the container
    ## (HO-1); the thumb where the model says; the attributes a reader of
    ## the DOM reads the model from.
    let v = s.view
    if not v.overflows or s.container.clientHeightOf() < 2.0:
      s.track.setStyleJs("display", "none")
      s.container.removeAttrJs("data-ct-hbar")
      return
    s.container.setAttrJs("data-ct-hbar", "1")
    s.track.setStyleJs("display", "block")
    let w = s.barWidth
    let top = s.container.offsetTopIn(s.host) + s.container.clientHeightOf() -
              float(TrackPx)
    s.track.setStyleJs("left", cstring($int(s.container.offsetLeftIn(s.host)) & "px"))
    s.track.setStyleJs("top", cstring($int(top) & "px"))
    s.track.setStyleJs("width", cstring($w & "px"))
    let span = v.barModel.thumbSpan(w, MinThumbPx)
    s.thumb.setStyleJs("left", cstring($span.start & "px"))
    s.thumb.setStyleJs("width", cstring($span.length & "px"))
    s.track.setAttrJs("data-ct-hscrub-content", cstring($v.contentCols))
    s.track.setAttrJs("data-ct-hscrub-viewport", cstring($v.viewportCols))
    s.track.setAttrJs("data-ct-hscrub-left", cstring($v.leftCol))
    s.thumb.setAttrJs("data-ct-thumb-left", cstring($span.start))
    s.thumb.setAttrJs("data-ct-thumb-px", cstring($span.length))

  proc moveTo(s: HorizontalScrubberDom; v: HorizontalView) =
    ## The VIEW to `v.leftCol` — the container's scroll, and nothing else
    ## (HO-4).
    s.container.setScrollLeft(float(v.leftCol))
    s.refresh()

  proc attachHorizontalScrubber*(container, host: JsObject; paneId = "";
                                 verticalTrack = false): HorizontalScrubberDom =
    ## Draw the overflow-only horizontal bar along `container`'s bottom
    ## inside `host`, and route its presses.
    let s = HorizontalScrubberDom(container: container, host: host,
                                  verticalTrack: verticalTrack)
    # The container's own HORIZONTAL bar is hidden (`.ct-hscrubbed`); its
    # vertical one stays unless a list scrubber also hides it.
    container.addClassJs("ct-hscrubbed")
    container.setStyleJs("overflow-x", "auto")
    host.setStyleJs("position", "relative")
    s.track = createDiv("ct-hscrubber")
    s.thumb = createDiv("ct-hscrubber-thumb")
    s.track.setAttrJs("data-ct-hscrubber", cstring(paneId))
    s.track.appendChildJs(s.thumb)
    host.appendChildJs(s.track)
    var onMove: proc(ev: JsObject)
    var onUp: proc(ev: JsObject)
    onMove = proc(ev: JsObject) =
      if not s.dragging:
        return
      let w = s.barWidth
      var v = s.view
      let x = int(ev.clientXOf() - s.track.trackLeftOf() - s.grab)
      # §4.2: the thumb follows the pointer — its start where the pointer
      # is, less where on the thumb it was grabbed.
      discard v.dragThumb(trackFractionAt(clamp(x, 0, w - 1), w))
      s.moveTo(v)
    onUp = proc(ev: JsObject) =
      s.dragging = false
      unlistenDoc("mousemove", onMove)
      unlistenDoc("mouseup", onUp)
    s.track.listen("mousedown", proc(ev: JsObject) =
      if ev.buttonOf() != 0:
        return
      ev.stopEv()
      let w = s.barWidth
      let x = ev.clientXOf() - s.track.trackLeftOf()
      var v = s.view
      let span = v.barModel.thumbSpan(w, MinThumbPx)
      if x >= float(span.start) and x < float(span.start + span.length):
        s.dragging = true
        s.grab = x - float(span.start)
        listenDoc("mousemove", onMove)
        listenDoc("mouseup", onUp)
      else:
        # §4.2: a press on the track centres the column under it.
        discard v.clickTrack(trackFractionAt(clamp(int(x), 0, w - 1), w))
        s.moveTo(v))
    container.listen("scroll", proc(ev: JsObject) = s.refresh())
    everyMs(proc() = s.refresh(), 250)
    s.refresh()
    s

  proc columnPxOf(el: JsObject): float {.importjs: """
    (function(e){
      const s = document.createElement('span');
      s.textContent = 'MMMMMMMMMM';
      s.style.visibility = 'hidden'; s.style.position = 'absolute';
      s.style.whiteSpace = 'pre';
      e.appendChild(s);
      const w = s.getBoundingClientRect().width / 10;
      e.removeChild(s);
      return w > 0 ? w : 8;
    })(#)""".}

  proc viewOperation*(container: JsObject; operation: string): bool =
    ## §4.4's `view.*` operations on a desktop output pane's scroll container
    ## — through the shared model, in pixels: `WheelColumns` of the pane's
    ## own monospaced column a step, half the view, or back to the start.
    ## Answers whether the view moved.
    var v = container.horizontalViewOf()
    let step = int(round(float(WheelColumns) * container.columnPxOf()))
    let moved =
      case operation
      of "view.scroll-left": v.scrollBy(-step)
      of "view.scroll-right": v.scrollBy(step)
      of "view.scroll-left-half": v.scrollHalf(right = false)
      of "view.scroll-right-half": v.scrollHalf(right = true)
      of "view.scroll-to-line-start": v.scrollToLineStart()
      else: false
    if moved:
      container.setScrollLeft(float(v.leftCol))
    moved
