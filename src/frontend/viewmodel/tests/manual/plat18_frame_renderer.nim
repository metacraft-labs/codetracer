## plat18_frame_renderer.nim — PLAT-18's vertical slice: the renderer a WASM
## core would actually have.
##
## ## WHAT IT IS
##
## An IsoNim `RendererBackend` whose element handle is a **u32 index**, not a
## node. `codetracer-specs/Architecture/Uniform-WASM-Core.md` §3: "DOM nodes
## cannot be held by WASM. They live behind a handle table, so fine-grained
## updates that today hold a node reference become an index plus a lookup."
## This is that renderer. Every operation is appended to a flat byte frame in
## the module's own memory; the host reads the frame once per update and
## applies it to a real document.
##
## ## THE BOUNDARY ON THIS PATH IS WRITE-ONLY, AND THAT WAS MEASURED
##
## `plat18_marshalling_probe.nim` reports the per-operation breakdown of the
## variables pane over the 600-member fixture, on all four phases:
##
##   MOUNT     CreateElement 45  CreateTextNode 16  AppendChild 60
##             SetAttribute 54   SetTextContent 13  SetStyle 11
##             AddEventListener 10
##   EXPAND    CreateElement 9000  CreateTextNode 3000  AppendChild 12000
##             SetAttribute 11408  SetTextContent 2404  SetStyle 2405
##             AddEventListener 1800
##   STEP      SetAttribute 7  SetTextContent 4  SetStyle 5
##   COLLAPSE  RemoveChild 600  SetAttribute 8  SetTextContent 4  SetStyle 5
##
## **`firstChild`, `nextSibling`, `parentNode` and `getAttribute` are ZERO in
## every phase.** IsoNim's reconciler holds the node references it created
## rather than navigating back through the renderer, so nothing on this path
## has to be READ across the boundary — which means no synchronous round trip,
## and no shadow tree in linear memory. That is what makes a batched frame
## with one flush per update possible at all, and it is the single most
## load-bearing fact in this slice.
##
## It is also the thing that could stop being true, so the four read
## operations are not omitted here: they increment `readCrossings`, and the
## slice REFUSES to publish a timing when that counter is non-zero. A
## measurement of a write-only boundary taken over a stream that turned out to
## contain reads is a measurement of something else.
##
## ## THE WIRE
##
## Byte-for-byte the format `isonim/core/boundary_meter` counts, and the two
## are not allowed to drift: the slice renders the same fixture through
## `MockRenderer` with the meter on and through this renderer with the wire
## on, and requires `wireBytes() == meter.totalBytes()`. Two implementations
## of one format with a mechanical equality between them is the §14 remedy
## for the case where there genuinely have to be two.
##
## ## HANDLES
##
## Allocated by a counter, starting at 1, so 0 is available as "no node". The
## host allocates the matching slot in its own table when it applies a
## `CreateElement` / `CreateTextNode`, so the two tables agree by
## construction — the host never invents an index and this module never reads
## one back.

import isonim/core/boundary_meter

type
  FrameNode* = distinct int32
    ## A handle into the host's node table. `0` means "none".

  FrameRenderer* = object
    ## Stateless: the frame and the handle counter are module state, because
    ## there is exactly one boundary per module instance.

proc `==`*(a, b: FrameNode): bool {.borrow.}
proc `$`*(a: FrameNode): string {.borrow.}

const NoFrameNode* = FrameNode(0)

proc isNil*(n: FrameNode): bool {.inline.} = int32(n) == 0

# ---------------------------------------------------------------------------
# The frame
# ---------------------------------------------------------------------------

when defined(js):
  {.emit: """
var ctP18_enc = new TextEncoder();
var ctP18_buf = new Uint8Array(1 << 20);
var ctP18_len = 0;
function ctP18_ensure(n) {
  if (ctP18_len + n > ctP18_buf.length) {
    var grown = new Uint8Array(Math.max(ctP18_buf.length * 2, ctP18_len + n));
    grown.set(ctP18_buf);
    ctP18_buf = grown;
  }
}
function ctP18_reset() { ctP18_len = 0; }
function ctP18_flen() { return ctP18_len; }
function ctP18_u8(v) { ctP18_ensure(1); ctP18_buf[ctP18_len++] = v & 0xff; }
function ctP18_u32(v) {
  ctP18_ensure(4);
  ctP18_buf[ctP18_len++] = v & 0xff;
  ctP18_buf[ctP18_len++] = (v >>> 8) & 0xff;
  ctP18_buf[ctP18_len++] = (v >>> 16) & 0xff;
  ctP18_buf[ctP18_len++] = (v >>> 24) & 0xff;
}
function ctP18_str(s) {
  var bytes = ctP18_enc.encode(s);
  ctP18_u32(bytes.length);
  ctP18_ensure(bytes.length);
  ctP18_buf.set(bytes, ctP18_len);
  ctP18_len += bytes.length;
}
// The host reads the frame through this. On this backend the frame IS a
// JS Uint8Array, so there is no address to hand over and no copy to make —
// which is the asymmetry the slice's `js-crossing` arm exists to isolate.
if (typeof globalThis !== 'undefined') {
  globalThis.ctP18_frame = function() { return ctP18_buf.subarray(0, ctP18_len); };
}
""".}
  proc wireResetRaw() {.importjs: "ctP18_reset()".}
  proc wireBytes*(): int {.importjs: "ctP18_flen()".}
  proc wirePutU8*(v: int) {.importjs: "ctP18_u8(#)".}
  proc wirePutU32*(v: int) {.importjs: "ctP18_u32(#)".}
  proc wirePutStrRaw(s: cstring) {.importjs: "ctP18_str(#)".}
  proc wirePutStr*(s: string) {.inline.} = wirePutStrRaw(cstring(s))
  proc wireBase*(): int {.inline.} = 0
    ## No address: the frame is a JS array. See `globalThis.ctP18_frame`.

else:
  var wireBuf: seq[byte] = newSeqOfCap[byte](1 shl 20)

  proc wireResetRaw() {.inline.} = wireBuf.setLen(0)
  proc wireBytes*(): int {.inline.} = wireBuf.len
  proc wirePutU8*(v: int) {.inline.} = wireBuf.add byte(v and 0xff)
  proc wirePutU32*(v: int) {.inline.} =
    wireBuf.add byte(v and 0xff)
    wireBuf.add byte((v shr 8) and 0xff)
    wireBuf.add byte((v shr 16) and 0xff)
    wireBuf.add byte((v shr 24) and 0xff)
  proc wirePutStr*(s: string) {.inline.} =
    wirePutU32(s.len)
    let at = wireBuf.len
    wireBuf.setLen(at + s.len)
    if s.len > 0:
      copyMem(addr wireBuf[at], unsafeAddr s[0], s.len)
  proc wireBase*(): int {.inline.} =
    ## The frame's address in linear memory. The host reads
    ## `HEAPU8.subarray(base, base + len)` — no copy, which is the whole
    ## reason a linear-memory target can be cheap to read FROM.
    ##
    ## Re-read on every flush rather than cached: `-sALLOW_MEMORY_GROWTH=1`
    ## can move the buffer, and a cached base after a growth is a read of
    ## somebody else's bytes.
    if wireBuf.len == 0: 0 else: cast[int](addr wireBuf[0])

var wireOps = 0
  ## Operations WRITTEN into the current frame, counted by the `op` template
  ## below — the single funnel every operation passes through.
  ##
  ## It exists so the host's applier can be checked against it. The host
  ## returns how many operations it APPLIED; this says how many the core PUT
  ## IN. Without the comparison, a frame the host stopped parsing halfway —
  ## because a `str()` read a wrong length and left the cursor inside a
  ## payload, say — applies a prefix, finishes early, and reports a fast
  ## timing over a partly-updated document. The row floor beside it does not
  ## catch that on its own: STEP and COLLAPSE leave the row COUNT at 602 and 2
  ## whatever happens to the attributes and the text.

proc wireReset*() {.inline.} =
  ## Empties the frame AND the operation count, so the two can never describe
  ## different frames. Both backends' raw resets are wrapped here rather than
  ## each zeroing the counter itself: two resets is two places to forget one.
  wireResetRaw()
  wireOps = 0

proc wireOpCount*(): int {.inline.} = wireOps

var nextHandle: int32 = 0
var readCrossings* = 0
  ## Operations that would have to be answered BACK across the boundary.
  ## Zero on the variables-pane path, measured; see this module's header.

proc resetFrameRenderer*() =
  wireReset()
  nextHandle = 0
  readCrossings = 0

proc allocHandle(): FrameNode {.inline.} =
  inc nextHandle
  FrameNode(nextHandle)

proc handleCount*(): int = int(nextHandle)

template op(kind: BoundaryOp; body: untyped) =
  inc wireOps
  wirePutU8(ord(kind))
  body

# ---------------------------------------------------------------------------
# RendererBackend — the write half
# ---------------------------------------------------------------------------

proc createElement*(r: FrameRenderer; tag: string): FrameNode =
  result = allocHandle()
  op(boCreateElement):
    wirePutU32(int(result))
    wirePutStr(tag)

proc createTextNode*(r: FrameRenderer; text: string): FrameNode =
  result = allocHandle()
  op(boCreateTextNode):
    wirePutU32(int(result))
    wirePutStr(text)

proc appendChild*(r: FrameRenderer; parent, child: FrameNode) =
  op(boAppendChild):
    wirePutU32(int(parent))
    wirePutU32(int(child))

proc insertBefore*(r: FrameRenderer; parent, child, reference: FrameNode) =
  op(boInsertBefore):
    wirePutU32(int(parent))
    wirePutU32(int(child))
    wirePutU32(int(reference))

proc removeChild*(r: FrameRenderer; parent, child: FrameNode) =
  op(boRemoveChild):
    wirePutU32(int(parent))
    wirePutU32(int(child))

proc setAttribute*(r: FrameRenderer; node: FrameNode; name, value: string) =
  op(boSetAttribute):
    wirePutU32(int(node))
    wirePutStr(name)
    wirePutStr(value)

proc removeAttribute*(r: FrameRenderer; node: FrameNode; name: string) =
  op(boRemoveAttribute):
    wirePutU32(int(node))
    wirePutStr(name)

proc setTextContent*(r: FrameRenderer; node: FrameNode; text: string) =
  op(boSetTextContent):
    wirePutU32(int(node))
    wirePutStr(text)

proc setStyle*(r: FrameRenderer; node: FrameNode; prop, value: string) =
  op(boSetStyle):
    wirePutU32(int(node))
    wirePutStr(prop)
    wirePutStr(value)

proc setInnerHtml*(r: FrameRenderer; node: FrameNode; html: string) =
  op(boSetInnerHtml):
    wirePutU32(int(node))
    wirePutStr(html)

proc clearChildren*(r: FrameRenderer; node: FrameNode) =
  op(boClearChildren):
    wirePutU32(int(node))

proc clearEventListeners*(r: FrameRenderer; node: FrameNode) =
  op(boClearEventListeners):
    wirePutU32(int(node))

proc setInputValue*(r: FrameRenderer; node: FrameNode; value: string) =
  op(boSetInputValue):
    wirePutU32(int(node))
    wirePutStr(value)

proc focus*(r: FrameRenderer; node: FrameNode) =
  op(boFocus):
    wirePutU32(int(node))

# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------
#
# A handler is a CLOSURE INSIDE THE MODULE. It cannot cross, so what crosses
# is a callback id; the host dispatches by calling back in with that id. The
# table below is the module's half of that arrangement, and it is the reason
# `AddEventListener` charges TWO handles on the wire: the node and the
# callback.

var handlers: seq[proc()] = @[]

proc dispatchCallback*(id: int) =
  ## The host's way back in. Out of range is ignored rather than trapped: a
  ## stale id from a node the host has already dropped is an ordinary race at
  ## a real boundary, not a defect.
  if id >= 1 and id <= handlers.len:
    handlers[id - 1]()

proc addEventListener*(r: FrameRenderer; node: FrameNode; event: string;
                       handler: proc()) =
  handlers.add(handler)
  op(boAddEventListener):
    wirePutU32(int(node))
    wirePutU32(handlers.len)
    wirePutStr(event)

# ---------------------------------------------------------------------------
# RendererBackend — the read half, which this path never uses
# ---------------------------------------------------------------------------
#
# Present because the interface requires them, counted because their absence
# from the stream is a MEASUREMENT this slice depends on (see the header) and
# a measurement that stopped being true must be loud.

proc firstChild*(r: FrameRenderer; node: FrameNode): FrameNode =
  inc readCrossings
  NoFrameNode

proc nextSibling*(r: FrameRenderer; node: FrameNode): FrameNode =
  inc readCrossings
  NoFrameNode

proc parentNode*(r: FrameRenderer; node: FrameNode): FrameNode =
  inc readCrossings
  NoFrameNode

proc getAttribute*(r: FrameRenderer; node: FrameNode; name: string): string =
  inc readCrossings
  ""

proc inputValue*(r: FrameRenderer; node: FrameNode): string =
  inc readCrossings
  ""

# ---------------------------------------------------------------------------
# The event object, which does not cross either
# ---------------------------------------------------------------------------
#
# A row's badge handler takes an event and calls `preventDefault` /
# `stopPropagation` on it. Neither can be a browser `Event` here: the object
# lives in the host and a WASM module cannot hold it any more than it can hold
# a node. What a real implementation crosses is the FLAGS the handler set,
# on the way back out. This type is that: a record of what the handler asked
# for, which the host reads after `dispatchCallback` returns.
#
# It is not a stand-in for testing. `defaultPrevented` and `propagationStopped`
# are the two bits the product's own handler actually sets, and the host acts
# on them.

type
  FrameEvent* = ref object
    `type`*: string
    defaultPrevented*: bool
    propagationStopped*: bool

proc preventDefault*(ev: FrameEvent) =
  if not ev.isNil: ev.defaultPrevented = true

proc stopPropagation*(ev: FrameEvent) =
  if not ev.isNil: ev.propagationStopped = true

var eventHandlers: seq[proc(ev: FrameEvent)] = @[]
var lastEvent*: FrameEvent

proc dispatchEventCallback*(id: int; eventType: string) =
  ## The host's way back in for a handler that wants the event.
  if id >= 1 and id <= eventHandlers.len:
    lastEvent = FrameEvent(`type`: eventType)
    eventHandlers[id - 1](lastEvent)

proc addEventListener*(r: FrameRenderer; node: FrameNode; event: string;
                       handler: proc(ev: FrameEvent)) =
  eventHandlers.add(handler)
  op(boAddEventListener):
    wirePutU32(int(node))
    # Event-taking handlers are numbered in their OWN space, biased above the
    # no-arg ones so a host that mixed the two tables would produce a
    # detectable id rather than a silently wrong call.
    wirePutU32(1_000_000 + eventHandlers.len)
    wirePutStr(event)
