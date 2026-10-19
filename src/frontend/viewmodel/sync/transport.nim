## sync/transport.nim
##
## `SyncChannel` — one end of a two-way message channel between a primary
## session's host and a mirror (a VS Code webview, a browser page served by a
## server that owns the session).
##
## The channel carries JSON values. Each concrete transport decides how a
## value crosses: the in-memory pair below hands it over in-process; a VS Code
## webview transport is `webview.postMessage` / `onDidReceiveMessage` on the
## host side and `acquireVsCodeApi().postMessage` / `window` `message` events
## in the webview; a WebSocket transport is `send(JSON.stringify(v))` /
## `onmessage` with `JSON.parse`. None of them needs more than these two
## operations, which is why the interface is only these two.
##
## Delivery is asynchronous in every real transport, so the in-memory pair
## QUEUES rather than calling the other side inline: a test that passes only
## because a reply arrived inside the sender's call would pass against no real
## transport. `flush` delivers what is queued, in order, until nothing is.
##
## Works on both the C and JS backends.

import std/json

type
  MessageHandler* = proc(msg: JsonNode)

  SyncChannel* = ref object
    ## One end of a channel. A transport fills in `sendProc`, and calls
    ## `deliver` for every message that arrives from the other end.
    sendProc*: proc(msg: JsonNode)
    handler: MessageHandler
    closed*: bool

proc newSyncChannel*(send: proc(msg: JsonNode)): SyncChannel =
  ## A channel end whose outgoing messages go to `send`.
  SyncChannel(sendProc: send)

proc send*(ch: SyncChannel; msg: JsonNode) =
  ## Send `msg` to the other end. A closed channel sends nothing.
  if ch.isNil or ch.closed or ch.sendProc.isNil:
    return
  ch.sendProc(msg)

proc setHandler*(ch: SyncChannel; handler: MessageHandler) =
  ## Receive every message from the other end with `handler`. One handler per
  ## end: the end belongs to one mirror or one host.
  ch.handler = handler

proc deliver*(ch: SyncChannel; msg: JsonNode) =
  ## What a transport calls when a message arrives for this end.
  if ch.isNil or ch.closed or ch.handler.isNil:
    return
  ch.handler(msg)

proc close*(ch: SyncChannel) =
  ## Stop sending and receiving on this end.
  if not ch.isNil:
    ch.closed = true

# ---------------------------------------------------------------------------
# In-memory transport
# ---------------------------------------------------------------------------

type
  InMemoryLink* = ref object
    ## Both ends of an in-memory channel and the messages in flight.
    ##
    ## Messages are copied as they are queued, as a real transport serialises
    ## them: a receiver that mutated a message must not change what the
    ## sender holds, and a sender's later mutation must not change what was
    ## sent.
    a*, b*: SyncChannel
    queue: seq[tuple[toB: bool; msg: JsonNode]]
    delivered*: int
      ## How many messages `flush` has handed over, for tests that count.

proc newInMemoryLink*(): InMemoryLink =
  ## Two connected channel ends, `a` and `b`.
  let link = InMemoryLink()
  link.a = newSyncChannel(proc(msg: JsonNode) =
    link.queue.add((true, msg.copy)))
  link.b = newSyncChannel(proc(msg: JsonNode) =
    link.queue.add((false, msg.copy)))
  link

proc pending*(link: InMemoryLink): int =
  ## Messages queued and not yet delivered.
  link.queue.len

proc flush*(link: InMemoryLink) =
  ## Deliver every queued message, in order, including those sent while
  ## delivering (a reply, a batch an action caused), until none is left.
  while link.queue.len > 0:
    let (toB, msg) = link.queue[0]
    link.queue.delete(0)
    inc link.delivered
    if toB: link.b.deliver(msg) else: link.a.deliver(msg)
