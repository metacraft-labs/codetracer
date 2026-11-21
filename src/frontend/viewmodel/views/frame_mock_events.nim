## frame_mock_events.nim — `MockEvent` handlers on the command-frame renderer.
##
## Several views attach their renderer-generic listeners with a
## `proc(ev: MockEvent)` handler — the event shape they read `key` and the
## modifiers from, and call `preventDefault` on, in their headless arm. Under
## the WebAssembly core (`-d:ctWasmCore`, `src/frontend/web_core`) that arm
## is the frame renderer's, whose events are `FrameEvent`s. This overload is
## the one adapter: the event the host sent is handed to the handler as a
## `MockEvent` carrying the same fields, and the flags the handler sets go
## back to the host on the `FrameEvent`. Imported by the views under
## `-d:ctWasmCore`, beside `isonim/web/frame_renderer`.

import isonim/testing/mock_dom
import isonim/web/frame_renderer

proc addEventListener*(r: FrameRenderer; node: FrameNode; event: string;
                       handler: proc(ev: MockEvent)) =
  r.addEventListener(node, event, proc(ev: FrameEvent) =
    let m = MockEvent(`type`: ev.`type`, key: ev.key,
                      shiftKey: fmShift in ev.modifiers,
                      ctrlKey: fmCtrl in ev.modifiers,
                      altKey: fmAlt in ev.modifiers,
                      metaKey: fmMeta in ev.modifiers)
    handler(m)
    if m.defaultPrevented: ev.preventDefault()
    if m.propagationStopped: ev.stopPropagation())
