import
  std / [ async, jsffi, json, strformat, strutils ],
  ../../lib/jslib,
  ../../../common/ct_logging

let net* = require("net")
let fs = require("fs")

proc startSocket*(path: cstring, expectPossibleFail: bool = false): Future[JsObject] =
  var future = newPromise() do (resolve: proc(response: JsObject)):
    var connections: seq[JsObject] = @[nil.toJs]
    connections[0] = net.createConnection(js{path: path, encoding: cstring"utf8"}, proc =
      debugPrint "index: connected succesfully socket for ", path #  for receiving from core and task processes"
      resolve(connections[0]))

    connections[0].on(cstring"error") do (error: js):
      # in some cases, we expect a socket might not be connected
      # e.g. for "instance client": this is not expected to work
      # if not started from the `shell-ui` feature, which is not really working now
      # (at least in thsi version)
      # we only log an error for the other cases,
      # and just a debug print for the expected possible fails
      if not expectPossibleFail:
        errorPrint "socket ipc error: ", error
      else:
        debugPrint "socket ipc error(but expected possible fail): ", error
      resolve(nil.toJs)
  return future

proc startTcpSocket*(host: cstring, port: int, expectPossibleFail: bool = false): Future[JsObject] =
  ## Connects to a TCP socket on host:port (used on Windows instead of Unix sockets).
  var future = newPromise() do (resolve: proc(response: JsObject)):
    var connections: seq[JsObject] = @[nil.toJs]
    connections[0] = net.createConnection(js{host: host, port: port, encoding: cstring"utf8"}, proc =
      debugPrint "index: connected succesfully TCP socket to ", host, ":", $port
      resolve(connections[0]))

    connections[0].on(cstring"error") do (error: js):
      if not expectPossibleFail:
        errorPrint "TCP socket ipc error: ", error
      else:
        debugPrint "TCP socket ipc error(but expected possible fail): ", error
      resolve(nil.toJs)
  return future

proc readPortFile*(path: cstring): Future[cstring] =
  ## Reads a port number from a file. Returns empty string on failure.
  var future = newPromise() do (resolve: proc(response: cstring)):
    fs.readFile(path, cstring"utf8", proc(err: JsObject, data: cstring) =
      if not err.isNil:
        resolve(cstring"")
      else:
        resolve(data))
  return future

proc parseInt*(s: cstring): int {.importjs: "parseInt(#, 10)".}
