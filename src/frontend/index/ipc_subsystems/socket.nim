import
  std / [ async, jsffi, json, strformat, strutils ],
  ../../[ lib ],
  ../../../common/ct_logging

let net* = require("net")

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
