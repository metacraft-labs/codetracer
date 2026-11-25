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

template BadgeEvent*(r: ZguiRenderer): typedesc = ZguiDomEvent

template KeyEvent*(r: ZguiRenderer): typedesc = ZguiDomEvent
  ## The event a key listener takes (`views/isonim_terminal_output_view`).

proc eventKey*(ev: ZguiDomEvent): string = ev.event.key

proc fieldValueOf*(r: ZguiRenderer; n: ZguiNode): string =
  ## What an `input` holds (`views/isonim_repl_view` reads it on submit).
  n.fieldValue

proc setFieldValue*(r: ZguiRenderer; n: ZguiNode; value: string) =
  r.setAttribute(n, "value", value)

proc isNil*(ev: ZguiDomEvent): bool {.inline.} = system.isNil(ev)
