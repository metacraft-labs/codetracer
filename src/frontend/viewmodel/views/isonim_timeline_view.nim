## views/isonim_timeline_view.nim
##
## IsoNim DOM-rendering view for the Timeline panel.
##
## Renders a live, reactive DOM tree driven by `TimelineVM` signals.
## When the VM's signals change (current position, zoom level,
## hovered tick, bounds, markers), the DOM updates automatically via IsoNim's
## `createRenderEffect`.
##
## Both renderer overloads (Mock and Web) produce the same structure;
## the markup lives in a single template that is materialised into
## one concrete proc per renderer so the `ui()` macro can resolve
## element types at compile time.
##
## ## WHAT THIS PANE DRAWS, AND WHY IT IS THIS AND NOT MORE (issue #693)
##
## `Front-Ends/Electron-GUI.md:151-156` obliges four things and no more:
## *"Visual representation of execution extent / Current position indicator /
## Event markers (calls, returns, exceptions) / Drag to seek"*, and
## `Front-Ends/Front-Ends-Overview.md:16` adds *"allow seeking to arbitrary
## time coordinates"*. Every element below answers one of those.
##
## What is deliberately absent — bookmarks, tracepoint marks, a visible
## window that zoom actually narrows, multi-track lanes — is absent because
## no normative spec section obliges it and each is a design question rather
## than a rendering one. `viewStart` / `viewEnd` are still written by
## `TimelineVM.pan` and read by nobody; zoom changes LABEL DENSITY and not
## the rendered range, which `tickLabelCount`'s doc comment states.
##
## The markers this pane draws are a projection of the calltrace and
## event-log WINDOWS the session has loaded, not of the whole recording —
## see `viewmodels/timeline_vm.nim`'s header, point 4. The track says so in
## `data-markers-are-windowed`, so a reader of the DOM is not left to assume
## the marks are everything.

import std/options

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/timeline_vm

const
  MaxRenderedMarkers = 400
    ## The ceiling on marks placed in the DOM, and it is a property of the
    ## pane rather than of the data. A calltrace window is paged but a page
    ## can still be thousands of rows, and a track a few hundred pixels wide
    ## cannot show more marks than it has pixels — past this the DOM grows
    ## without the picture changing. The track reports the real total in
    ## `data-marker-count` so the truncation is visible rather than silent.
  EmptyTimelineNote* =
    "No execution timeline yet — the recording's extent arrives with the " &
    "event log."
    ## Shown when the extent is unknown. Says WHERE the missing number comes
    ## from, because that is the actionable half: PLAT-41 made
    ## `applyEventLogRows` the surface that teaches the store a completed
    ## replay's extent, so "no timeline" almost always means "the event log
    ## has not been read yet" rather than "this recording has no timeline".

# ---------------------------------------------------------------------------
# Reactive expression helpers
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc positionTicksText(vm: TimelineVM): string =
  "Tick: " & $vm.currentPosition.val

proc hasExtent(vm: TimelineVM): bool =
  ## Whether the recording's extent is known and is a real range.
  ##
  ## ONE PREDICATE, and every helper below calls it. It was written out five
  ## times as `marks.len < 2 or marks[1] <= marks[0]`, which is the shape
  ## `Verification-Harness-Traps.md` §30 is about: copies drift, and a pane
  ## that disagrees with itself about whether it has data draws half a
  ## timeline.
  let extent = vm.bounds.val
  extent.len >= 2 and extent[1] > extent[0]

proc timelineMinText(vm: TimelineVM): string =
  let extent = vm.bounds.val
  if extent.len >= 2: $extent[0] else: "0"

proc timelineMaxText(vm: TimelineVM): string =
  let extent = vm.bounds.val
  if extent.len >= 2: $extent[1] else: "0"

proc percentOf(vm: TimelineVM; tick: uint64): float =
  ## Where `tick` sits along the track, 0..100. The ONE tick-to-percent
  ## conversion: the playhead, every event marker and every tick label are
  ## placed by it, so a mark and the playhead cannot disagree about where
  ## the same tick is.
  if not vm.hasExtent(): return 0.0
  let extent = vm.bounds.val
  let minT = extent[0]
  let maxT = extent[1]
  if tick <= minT: return 0.0
  if tick >= maxT: return 100.0
  float(tick - minT) / float(maxT - minT) * 100.0

proc positionPercent(vm: TimelineVM): float =
  ## Percentage through the recording, 0..100. Returns 0 when the extent is
  ## unknown.
  vm.percentOf(vm.currentPosition.val)

proc oneDecimal(value: float): string =
  ## `value` with one decimal place, without `std/strformat` — this module is
  ## compiled for the JS backend too and the pane already formatted its zoom
  ## level this way.
  let scaled = int(value * 10)
  $(scaled div 10) & "." & $(scaled mod 10)

proc positionPercentText(vm: TimelineVM): string =
  ## Format the percentage with one decimal place, or empty when the
  ## extent is unavailable.
  if not vm.hasExtent(): return ""
  oneDecimal(positionPercent(vm)) & "%"

proc playheadLeft(vm: TimelineVM): string =
  if not vm.hasExtent(): "0%"
  else: oneDecimal(positionPercent(vm)) & "%"

proc zoomLevelText(vm: TimelineVM): string =
  let levelInt = int(vm.zoomLevel.val * 10)
  $(levelInt div 10) & "." & $(levelInt mod 10) & "x"

proc markerKindClass*(kind: TimelineMarkerKind): string =
  ## The modifier class one mark carries. Exported because the stylesheet and
  ## the tests both need the same three words and neither should spell them
  ## independently.
  case kind
  of tmkCall: "timeline-marker-call"
  of tmkReturn: "timeline-marker-return"
  of tmkException: "timeline-marker-exception"

proc markerKindWord(kind: TimelineMarkerKind): string =
  case kind
  of tmkCall: "call"
  of tmkReturn: "return"
  of tmkException: "exception"

proc markerTitle(m: TimelineMarker): string =
  ## What a mark's `title` says: the kind, the tick, and the producer's own
  ## label when it gave one.
  result = markerKindWord(m.kind) & " @ tick " & $m.tick
  if m.label.len > 0:
    result.add " — " & m.label

proc renderedMarkers(vm: TimelineVM): seq[TimelineMarker] =
  ## The marks this pane actually places, capped at `MaxRenderedMarkers`.
  ##
  ## Over the cap the set is THINNED EVENLY rather than truncated. A prefix
  ## would be the obvious spelling and it is the wrong one: `markers` is
  ## ascending by tick, so taking the first N draws marks across the earliest
  ## part of the recording and leaves the rest of the track bare — which
  ## reads as "nothing happened after this point" rather than as "there are
  ## more marks than pixels". `data-marker-count` still reports the real
  ## total.
  let all = vm.markers.val
  if all.len <= MaxRenderedMarkers:
    return all
  let stride = (all.len + MaxRenderedMarkers - 1) div MaxRenderedMarkers
  result = @[]
  var i = 0
  while i < all.len:
    result.add all[i]
    i += stride
  # The LAST mark is kept whatever the stride lands on, so the drawn set spans
  # the same range as the real one.
  if result.len > 0 and result[^1].tick != all[^1].tick:
    result.add all[^1]

proc markerCountText(vm: TimelineVM): string =
  $vm.markers.val.len

proc emptyStateDisplay(vm: TimelineVM): string =
  displayIf(not vm.hasExtent())

proc trackDisplay(vm: TimelineVM): string =
  displayIf(vm.hasExtent())

proc hoverTooltipText(vm: TimelineVM): string =
  let hovered = vm.hoveredTick.val
  if hovered.isSome: "Tick: " & $hovered.get else: ""

proc hoverTooltipDisplay(vm: TimelineVM): string =
  if vm.hoveredTick.val.isSome: "block" else: "none"

proc timelineRootStyle(): string =
  "display: flex; flex-direction: column; width: 100%; height: 100%; " &
    "min-height: 112px; box-sizing: border-box;"

proc timelineTrackStyle(): string =
  # No side margin here: the track's inset is the panel inset, set by
  # `.timeline-track` in styles/components/timeline.styl (PANEL_INSET, 8px).
  # An inline `margin: 0 10px` outranked that rule and left the track 2px off
  # every other panel's edge.  The playhead and markers are placed in
  # percentages of the track, so its width is free to change.
  "position: relative; height: 42px; " &
    "flex: 0 0 auto; cursor: pointer;"

# ---------------------------------------------------------------------------
# Click handlers
# ---------------------------------------------------------------------------

proc onZoomIn(vm: TimelineVM): proc() =
  result = proc() = vm.zoom(vm.zoomLevel.val * 2.0)

proc onZoomOut(vm: TimelineVM): proc() =
  result = proc() = vm.zoom(vm.zoomLevel.val / 2.0)

# ---------------------------------------------------------------------------
# Panel template — shared between Mock and Web renderers
# ---------------------------------------------------------------------------
#
# Structure:
#   div.timeline-component
#     div.timeline-position
#       span.position-ticks                  text reactive
#       span.position-percent                text reactive
#     div.timeline-zoom-controls
#       button.zoom-out                      onclick = halve zoom level
#       span.zoom-level                      text reactive
#       button.zoom-in                       onclick = double zoom level
#     div.timeline-empty                     display reactive; the empty state
#     div.timeline-track                     display reactive
#       div.timeline-marker …                one per loaded call/return/error
#       div.timeline-playhead                left % reactive
#     div.timeline-ticks                     display reactive
#       span.timeline-tick-label …           one per gradation
#     div.timeline-hover-tooltip             display + text reactive
#
# THE `for` LOOPS BELOW RUN ONCE PER RENDER, not once per change. isonim's
# `dsl/ui.processForStmt` expands a `for` into a plain loop at render time, so
# the marks and the labels present at render are the ones that node keeps —
# unlike the `text` nodes around them, which sit in their own render effects.
# `mountIsoNimTimeline` therefore re-renders the whole panel inside a
# `createEffect`, exactly as `isonim_point_list_view` had to after PLAT-40
# found the same defect there. A headless caller of `renderTimelinePanel` gets
# one snapshot and must re-render to see new marks; the suite says so by name.

template renderTimelinePanelImpl(r, vm, rootClass: untyped): untyped =
  # READ ONCE, INDEX BY POSITION. Two reasons, and the second is a hard
  # compile error rather than a preference:
  #
  #   * these two reads happen OUTSIDE the per-attribute render effects the
  #     DSL emits, so they are what `mountIsoNimTimeline`'s effect tracks —
  #     which is what makes a new mark redraw the panel;
  #   * `for m in someSeq` yields `lent T` on Nim 2.x, and the DSL wraps every
  #     dynamic attribute in a closure, so capturing the loop variable is
  #     rejected: *"is of type <lent TimelineMarker> which cannot be captured
  #     as it would violate memory safety"*. Indexing a captured `seq` is the
  #     spelling that compiles on both backends without `-d:nimNoLentIterators`
  #     (which the test lanes do not pass, whatever `src/Tuprules.tup` does).
  let marksToDraw = renderedMarkers(vm)
  let labelsToDraw = vm.tickLabels.val
  ui(r):
    tdiv(class = rootClass, style = timelineRootStyle()):
      tdiv(class = "timeline-position"):
        span(class = "position-ticks"):
          text positionTicksText(vm)
        span(class = "position-percent"):
          text positionPercentText(vm)
      tdiv(class = "timeline-zoom-controls"):
        button(class = "zoom-out", onclick = onZoomOut(vm)):
          text "-"
        span(class = "zoom-level"):
          text zoomLevelText(vm)
        button(class = "zoom-in", onclick = onZoomIn(vm)):
          text "+"
      tdiv(class = "timeline-empty",
           display = emptyStateDisplay(vm)):
        text EmptyTimelineNote
      # `style = …` MUST COME BEFORE `display = …`, and that is not cosmetic.
      # The DSL emits a `style` attribute as `setAttribute("style", …)` and a
      # recognised CSS property as `setStyle(prop, …)`, in the order the
      # arguments are written — and in a real DOM the `style` ATTRIBUTE is the
      # whole inline declaration, so setting it after `setStyle("display", …)`
      # wipes the display back out. The mock renderer keeps `attributes` and
      # `styles` in separate maps and cannot see that, so the headless suite
      # would stay green while the track was permanently visible in the
      # product. Written in the safe order instead of relying on a test that
      # cannot fail.
      tdiv(class = "timeline-track",
           style = timelineTrackStyle(),
           role = "slider",
           tabindex = "0",
           `aria-label` = "Timeline",
           `aria-valuemin` = timelineMinText(vm),
           `aria-valuemax` = timelineMaxText(vm),
           `aria-valuenow` = $vm.currentPosition.val,
           `data-min-rr-ticks` = timelineMinText(vm),
           `data-max-rr-ticks` = timelineMaxText(vm),
           `data-current-rr-ticks` = $vm.currentPosition.val,
           `data-marker-count` = markerCountText(vm),
           `data-markers-are-windowed` = "true",
           display = trackDisplay(vm)):
        for i in 0 ..< marksToDraw.len:
          tdiv(class = "timeline-marker " &
                 markerKindClass(marksToDraw[i].kind),
               `data-marker-kind` = markerKindWord(marksToDraw[i].kind),
               `data-marker-rr-ticks` = $marksToDraw[i].tick,
               title = markerTitle(marksToDraw[i]),
               left = oneDecimal(vm.percentOf(marksToDraw[i].tick)) & "%"):
            discard
        tdiv(class = "timeline-playhead",
             left = playheadLeft(vm)):
          discard
      tdiv(class = "timeline-ticks",
           display = trackDisplay(vm)):
        for i in 0 ..< labelsToDraw.len:
          span(class = "timeline-tick-label",
               `data-tick` = $labelsToDraw[i],
               left = oneDecimal(vm.percentOf(labelsToDraw[i])) & "%"):
            text $labelsToDraw[i]
      tdiv(class = "timeline-hover-tooltip",
           display = hoverTooltipDisplay(vm)):
        text hoverTooltipText(vm)

# ---------------------------------------------------------------------------
# Renderer overloads
# ---------------------------------------------------------------------------

proc renderTimelinePanel*(r: MockRenderer; vm: TimelineVM): MockNode =
  ## Render the full Timeline panel for headless tests.
  renderTimelinePanelImpl(r, vm, "timeline-component")

when defined(js):
  proc setTimelineTrackHandlers(
      container: isonim_dom.Element;
      onSeekFraction: proc(fraction: float) {.closure.};
      onHoverFraction: proc(fraction: float) {.closure.};
      onHoverEnd: proc() {.closure.})
      {.importjs: """
        (function(container, onSeekFraction, onHoverFraction, onHoverEnd) {
          // ATTACHED TO THE CONTAINER, NOT TO THE TRACK, AND EXACTLY ONCE.
          // The panel inside `container` is destroyed and rebuilt by the
          // render effect in `mountIsoNimTimeline` every time the marks or
          // the extent change, so a listener bound to the track would be
          // thrown away with it -- and the `window` listeners a drag needs
          // would NOT be, so each re-render would leave another pair behind.
          // The container outlives every render, so the track is resolved
          // lazily at event time instead.
          const trackOf = function(event) {
            const el = event.target;
            if (el && el.closest) {
              const hit = el.closest(".timeline-track");
              if (hit) return hit;
            }
            return null;
          };
          // The 0..1 position of a pointer event along `track`, or null when
          // the track has no width yet (a panel that is mounted but not laid
          // out). One function, so a click, a drag and a hover cannot
          // disagree about where the pointer is.
          const fractionAt = function(track, event) {
            const rect = track.getBoundingClientRect();
            if (!rect.width) return null;
            const x = Math.max(0, Math.min(rect.width, event.clientX - rect.left));
            return x / rect.width;
          };
          // DRAG TO SEEK -- Electron-GUI.md:156. The drag is remembered on
          // the track that started it, so a pointer that leaves the track
          // mid-drag keeps scrubbing along that same track, which is what a
          // scrubber does.
          //
          // IT SEEKS ON PRESS AND ON RELEASE, AND PREVIEWS IN BETWEEN -- it
          // does NOT seek on every intermediate move. A seek is
          // `ct/timeline-seek`, which the engine routes into `goto_ticks`: a
          // real replay operation, not a cursor update. Seeking per mousemove
          // would send one of those per PIXEL -- hundreds for one drag across
          // a panel -- and the cost of that on a real engine could not be
          // measured on the host this was written on (no Electron here), so it
          // is not what ships. The intermediate moves drive the hover tooltip
          // instead, so the user still sees the tick they are about to land
          // on. If a future measurement shows continuous seeking is cheap,
          // this is the one place to change.
          let draggingTrack = null;
          const seekOn = function(track, event) {
            const f = fractionAt(track, event);
            if (f !== null) onSeekFraction(f);
          };
          const previewOn = function(track, event) {
            const f = fractionAt(track, event);
            if (f !== null) onHoverFraction(f);
          };
          container.addEventListener("mousedown", function(event) {
            // Primary button only: a right-click opens a context menu and
            // must not move the debugger.
            if (event.button !== 0) return;
            const track = trackOf(event);
            if (!track) return;
            draggingTrack = track;
            // Suppress the text selection a press-and-drag would otherwise
            // start across the panel.
            event.preventDefault();
            seekOn(track, event);
          });
          window.addEventListener("mousemove", function(event) {
            if (draggingTrack) previewOn(draggingTrack, event);
          });
          window.addEventListener("mouseup", function(event) {
            if (!draggingTrack) return;
            const track = draggingTrack;
            draggingTrack = null;
            seekOn(track, event);
          });
          // CLICK is kept as well as mousedown, and is NOT redundant: a
          // keyboard-driven or SYNTHESISED `click` -- which is what a test
          // driver and an accessibility tool emit -- produces no mousedown at
          // all, and before drag support this handler was the only seek path.
          //
          // `event.detail` is what tells the two apart, and it is a fact about
          // the event rather than a flag this code has to keep in sync: a
          // click generated by a real pointer press carries the click COUNT
          // (>= 1) and has already been answered by `mousedown` above, while
          // `new MouseEvent("click", …)` and a keyboard activation carry 0. A
          // boolean "the press already seeked" would have been the obvious
          // spelling and is the wrong one -- it is left set when a drag ends
          // outside the window and no click follows, and then swallows the
          // next synthesised click.
          container.addEventListener("click", function(event) {
            if (event.detail > 0) return;
            if (draggingTrack) return;
            const track = trackOf(event);
            if (track) seekOn(track, event);
          });
          // HOVER -- the `.timeline-hover-tooltip` element and
          // `TimelineVM.hoveredTick` existed from the first version of this
          // pane and NOTHING in the renderer ever wrote the signal, so the
          // tooltip could not appear in the product.
          container.addEventListener("mousemove", function(event) {
            const track = trackOf(event);
            if (!track) { onHoverEnd(); return; }
            const f = fractionAt(track, event);
            if (f !== null) onHoverFraction(f);
          });
          container.addEventListener("mouseleave", function() { onHoverEnd(); });
        })(#, #, #, #);
      """.}

  proc renderTimelinePanel*(r: WebRenderer; vm: TimelineVM): isonim_dom.Element =
    ## Render the Timeline panel into real DOM elements.
    renderTimelinePanelImpl(r, vm, "timeline-component isonim-timeline")

  proc mountIsoNimTimeline*(container: isonim_dom.Element; vm: TimelineVM) =
    ## Mount the IsoNim Timeline panel as a child of `container`, and
    ## RE-RENDER it whenever the recording's extent, marks or labels change.
    ##
    ## **THE MARKS AND THE LABELS ARE `for` LOOPS IN THE `ui:` BLOCK, AND
    ## THOSE LOOPS RUN ONCE.** isonim expands a `for` into a plain loop at
    ## render time (`dsl/ui.processForStmt`), so before this effect the panel
    ## appended at mount was the panel for ever — and since a replay learns
    ## its extent only when the event log is read (PLAT-41), a mount-time
    ## render is a render of the EMPTY state in the common case. PLAT-40
    ## found exactly this in `isonim_point_list_view`, whose header carries
    ## the same warning; the fix is the same shape.
    ##
    ## The render runs inside an effect, so the signals it reads OUTSIDE the
    ## per-attribute render effects the DSL emits — the `for` iterables
    ## `markers` and `tickLabels`, and through the latter `bounds` and
    ## `zoomLevel` — are tracked, and a change redraws the panel. The rest
    ## (`currentPosition`, `hoveredTick`, every text and style) stays in its
    ## own fine-grained effect and updates without a redraw, which is what
    ## keeps a pointer hovering the track from tearing the track out from
    ## under itself.
    ##
    ## **The handlers are attached to `container` ONCE, before the effect.**
    ## Attaching them per render would re-register the `window`-level drag
    ## listeners on every redraw, and those are not removed with the panel.
    setTimelineTrackHandlers(
      container,
      proc(fraction: float) = vm.seekAtFraction(fraction),
      proc(fraction: float) = vm.hoverAtFraction(fraction),
      proc() = vm.hover(none(uint64)))
    createEffect proc() =
      let panel = renderTimelinePanel(WebRenderer(), vm)
      let containerNode = isonim_dom.Node(container)
      while not isonim_dom.isNodeNil(containerNode.firstChild):
        discard isonim_dom.removeChild(containerNode, containerNode.firstChild)
      isonim_dom.appendChild(containerNode, isonim_dom.Node(panel))
