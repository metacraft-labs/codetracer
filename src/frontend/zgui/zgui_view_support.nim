## zgui_view_support.nim — what the production IsoNim views ask of a renderer
## by an open symbol (`mixin`), answered for `ZguiRenderer`.
##
## A view that a host instantiates for its renderer resolves these where the
## host instantiates it, so a zgui host imports this module beside the views:
##
##   * `BadgeEvent` (`views/isonim_state_view`): the event type the State
##     pane's origin badge handler takes — `ZguiDomEvent`, isonim-zgui's
##     DOM-shaped event (`preventDefault`, `stopPropagation`);
##   * `fieldValueOf` / `setFieldValue` (`views/isonim_repl_view`): an
##     input's value, read and cleared on submit.

import isonim_zgui/renderer

import ../viewmodel/views/list_scrubber_native

template BadgeEvent*(r: ZguiRenderer): typedesc = ZguiDomEvent

proc drawsInlineSvg*(r: ZguiRenderer): bool =
  ## zgui draws an inline `<svg>` built element by element (isonim-zgui records
  ## the attributes of `svg`, `line`, `path`, … and rewrites the vector's
  ## document), so views draw their SVG layers here as the browser does: the
  ## Call Trace's guide lines (`isonim_calltrace_view.attachNativeCallGuides`).
  true

template KeyEvent*(r: ZguiRenderer): typedesc = ZguiDomEvent
  ## The event a key listener takes (`views/isonim_terminal_output_view`).

proc eventKey*(ev: ZguiDomEvent): string = ev.event.key

proc fieldValueOf*(r: ZguiRenderer; n: ZguiNode): string =
  ## What an `input` holds (`views/isonim_repl_view` reads it on submit).
  n.fieldValue

proc setFieldValue*(r: ZguiRenderer; n: ZguiNode; value: string) =
  r.setAttribute(n, "value", value)

proc isNil*(ev: ZguiDomEvent): bool {.inline.} = system.isNil(ev)

# ---------------------------------------------------------------------------
# The list scrubber (`views/list_scrubber_native`)
# ---------------------------------------------------------------------------

var scrubbers: seq[NativeScrubber[ZguiNode]]
  ## Every scrubber a view attached, placed by `refreshScrubbers` once laid out.

proc attachNativeListScrubber*(r: ZguiRenderer; container, host: ZguiNode;
                               total, current: proc(): int;
                               rowHeight: proc(): float; paneId: string) =
  ## The Event Log's and the Call Trace's scrubber, as the browser draws it.
  scrubbers.add attachScrubber(r, container, host, total, current, rowHeight, paneId)

proc refreshScrubbers*(scale: float) =
  ## Places every attached scrubber from the laid-out boxes (border boxes are
  ## device pixels; the scrubber works in CSS pixels).
  let r = ZguiRenderer()
  proc measure(n: ZguiNode): Box =
    let b = borderBox(n)
    (float(b.x) / scale, float(b.y) / scale, float(b.w) / scale, float(b.h) / scale)
  # A scrubber whose elements are gone (its pane was closed, its window
  # shut) is forgotten.
  var live: seq[NativeScrubber[ZguiNode]]
  for s in scrubbers:
    if s.container.isLive and s.track.isLive: live.add s
  scrubbers = live
  for s in scrubbers:
    var content = 0.0
    for i in 0 ..< s.container.childCount:
      content += measure(s.container.nthChild(i)).h
    refresh(r, s, measure, content)
