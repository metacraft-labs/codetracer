## tests/unit/in_memory_transport.nim
##
## Two connected `SyncChannel` ends in one process, for the mirroring suites.
## Test support, not product code: no host connects a primary to a mirror
## in-process (the real transports are the webview's `postMessage` and the
## page's WebSocket), so the pair lives with the suites that use it.
##
## Delivery is asynchronous in every real transport, so the pair QUEUES rather
## than calling the other side inline: a test that passes only because a reply
## arrived inside the sender's call would pass against no real transport.
## `flush` delivers what is queued, in order, until nothing is.

import std/json

import ../../sync/transport

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
