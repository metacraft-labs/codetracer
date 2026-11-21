## plugin_sdk/wasm_io.nim — §8.1's I/O primitives for a WebAssembly plugin
## (Extensibility-Model.md §11.9).
##
## A plugin compiled to wasm32 has no file, socket or process of its own. Each
## call here is one `ct.io` request to `ct-plugin-host`, which runs the same
## `plugin_io.nim` primitive a native host would — `capabilities.decide`
## first, under the grants the user gave this plugin — and answers later with
## an `io-result` frame. So every call returns a `Future`, as natively: there
## is no synchronous form, and a refusal is a value (`ioRefused`, with the
## policy's own sentence), not an exception.

import std/[asyncfutures, json, strutils]
import ./codetracer_plugin_sdk
import ../frontend/viewmodel/plugin_host/plugin_io

export asyncfutures, plugin_io.IoStatus, plugin_io.ReadOutcome,
       plugin_io.WriteOutcome

when not defined(wasm32):
  {.error: "wasm_io is the wasm32 arm; a native plugin uses plugin_io directly".}

type
  RunOutcome* = object
    ## A program run to its end: its exit and everything it wrote.
    status*: IoStatus
    code*: int
    signalled*: bool
    stdout*, stderr*: string
    message*: string

  StreamOutcome* = object
    status*: IoStatus
    stream*: int
      ## The host's handle for the connection; `read`, `write`, `close` take it.
    message*: string

proc statusOf(r: JsonNode): IoStatus =
  try: parseEnum[IoStatus](r{"status"}.getStr("ioFailed"))
  except ValueError: ioFailed

proc readPath*(p: Plugin; path: string): Future[ReadOutcome] =
  ## `fs:read`, over the paths the manifest declares.
  let f = newFuture[ReadOutcome]("wasm_io.readPath")
  ioRequest(%*{"op": "readPath", "path": path}, proc(r: JsonNode) =
    f.complete(ReadOutcome(status: statusOf(r), data: r{"data"}.getStr(""),
                           message: r{"message"}.getStr(""))))
  f

proc writePath*(p: Plugin; path, data: string): Future[WriteOutcome] =
  ## `fs:write`, over the paths the manifest declares.
  let f = newFuture[WriteOutcome]("wasm_io.writePath")
  ioRequest(%*{"op": "writePath", "path": path, "data": data}, proc(r: JsonNode) =
    f.complete(WriteOutcome(status: statusOf(r), written: r{"written"}.getInt(0),
                            message: r{"message"}.getStr(""))))
  f

proc runProcess*(p: Plugin; name: string; args: seq[string] = @[];
                 workingDir = ""): Future[RunOutcome] =
  ## `process`: a declared program, by NAME, with an argv list (§8.1.1), run
  ## to its end.
  let f = newFuture[RunOutcome]("wasm_io.runProcess")
  ioRequest(%*{"op": "runProcess", "name": name, "args": args,
               "workingDir": workingDir}, proc(r: JsonNode) =
    f.complete(RunOutcome(status: statusOf(r), code: r{"code"}.getInt(0),
                          signalled: r{"signalled"}.getBool(false),
                          stdout: r{"stdout"}.getStr(""),
                          stderr: r{"stderr"}.getStr(""),
                          message: r{"message"}.getStr(""))))
  f

proc connect(op: string; req: JsonNode): Future[StreamOutcome] =
  let f = newFuture[StreamOutcome]("wasm_io." & op)
  var q = req
  q["op"] = %op
  ioRequest(q, proc(r: JsonNode) =
    f.complete(StreamOutcome(status: statusOf(r), stream: r{"stream"}.getInt(0),
                             message: r{"message"}.getStr(""))))
  f

proc connectTcp*(p: Plugin; host: string; port: int): Future[StreamOutcome] =
  ## `socket:local` / `socket:remote`, by the same two-pass decision.
  connect("connectTcp", %*{"host": host, "port": port})

proc connectUnixSocket*(p: Plugin; path: string): Future[StreamOutcome] =
  connect("connectUnix", %*{"path": path})

proc read*(p: Plugin; stream: int; maxBytes = DefaultReadChunk): Future[ReadOutcome] =
  let f = newFuture[ReadOutcome]("wasm_io.read")
  ioRequest(%*{"op": "streamRead", "stream": stream, "maxBytes": maxBytes},
    proc(r: JsonNode) =
      f.complete(ReadOutcome(status: statusOf(r), data: r{"data"}.getStr(""),
                             message: r{"message"}.getStr(""))))
  f

proc write*(p: Plugin; stream: int; data: string): Future[WriteOutcome] =
  let f = newFuture[WriteOutcome]("wasm_io.write")
  ioRequest(%*{"op": "streamWrite", "stream": stream, "data": data},
    proc(r: JsonNode) =
      f.complete(WriteOutcome(status: statusOf(r), written: r{"written"}.getInt(0),
                              message: r{"message"}.getStr(""))))
  f

proc close*(p: Plugin; stream: int) =
  ioRequest(%*{"op": "streamClose", "stream": stream}, proc(r: JsonNode) = discard)
