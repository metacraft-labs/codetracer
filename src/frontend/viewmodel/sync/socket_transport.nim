## sync/socket_transport.nim
##
## A `SyncChannel` over a WebSocket — the transport between a server that owns
## a session (`ct host`) and the page that mirrors it.
##
## The connection is the one the page already has: socket.io, whose server
## and client sockets both expose `on(name, handler)` and `emit(name, data)`
## (https://socket.io/docs/v4/emitting-events/). The channel takes ONE event
## name on it, `SessionSyncEvent`, so the mirroring traffic shares the socket
## with the index IPC surface without either reading the other's messages.
##
## Each message crosses as JSON text: `$msg` on the way out, `parseJson` on the
## way in. A frame that does not parse is dropped rather than raised — it
## arrives from the network, and an exception here would end the session over
## one bad frame.
##
## JS only: a socket is a JavaScript object.

when not defined(js):
  {.error: "sync/socket_transport is a JS-only transport.".}

import std/[json, jsffi]

import transport

const
  SessionSyncEvent* = "CODETRACER::session-sync"
    ## The socket.io event every mirroring message travels on.

proc socketOn(socket: JsObject; name: cstring;
              handler: proc(frame: cstring)) {.importjs: "#.on(#, #)".}
proc socketEmit(socket: JsObject; name: cstring;
                frame: cstring) {.importjs: "#.emit(#, #)".}
proc socketOff(socket: JsObject; name: cstring) {.
  importjs: "#.removeAllListeners(#)".}
  ## Both socket.io sockets are event emitters with `removeAllListeners`.

proc newSocketSyncChannel*(socket: JsObject): SyncChannel =
  ## A channel end over `socket`, a socket.io socket on either side of the
  ## connection.
  let channel = newSyncChannel(proc(msg: JsonNode) =
    socketEmit(socket, SessionSyncEvent.cstring, cstring($msg)))
  socketOn(socket, SessionSyncEvent.cstring, proc(frame: cstring) =
    var msg: JsonNode
    try:
      msg = parseJson($frame)
    except:
      # Bare `except:`: on the JS backend `parseJson` throws V8's own
      # `SyntaxError`, which no Nim exception type matches.
      return
    channel.deliver(msg))
  channel

proc closeSocketSyncChannel*(channel: SyncChannel; socket: JsObject) =
  ## Stop the channel and stop listening on `socket`.
  channel.close()
  socketOff(socket, SessionSyncEvent.cstring)
