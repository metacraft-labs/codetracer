## zgui_view_support.nim — what the production IsoNim views ask of a renderer
## by an open symbol (`mixin`), answered for `ZguiRenderer`.
##
## A view that a host instantiates for its renderer resolves these where the
## host instantiates it, so a zgui host imports this module beside the views:
##
##   * `BadgeEvent` (`views/isonim_state_view`): the event type the State
##     pane's origin badge handler takes — `ZguiDomEvent`, isonim-zgui's
##     DOM-shaped event (`preventDefault`, `stopPropagation`).

import isonim_zgui/renderer

template BadgeEvent*(r: ZguiRenderer): typedesc = ZguiDomEvent

proc isNil*(ev: ZguiDomEvent): bool {.inline.} = system.isNil(ev)
