## sync/transport.nim
##
## `SyncChannel` — one end of a two-way message channel between a primary
## session's host and a mirror (a VS Code webview, a browser page served by a
## server that owns the session).
##
## The channel carries JSON values. Each concrete transport decides how a
## value crosses: the suites' in-memory pair (`tests/unit/in_memory_transport`)
## hands it over in-process; a VS Code
## webview transport is `webview.postMessage` / `onDidReceiveMessage` on the
## host side and `acquireVsCodeApi().postMessage` / `window` `message` events
## in the webview; a WebSocket transport is `send(JSON.stringify(v))` /
## `onmessage` with `JSON.parse`. None of them needs more than these two
## operations, which is why the interface is only these two.
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
