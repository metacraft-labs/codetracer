## test_real_backend_json.nim
##
## `RealBackendService` converts an event's body to a JsonNode once for all
## of its `onEvent` subscribers, not once per subscriber.
##
## Why: each subscriber is its own DapApi handler, and each used to convert
## the body itself (`parseJson(JSON.stringify(body))`), although each looks at
## the kind first and most ignore the event. A Pascal loop's 2.7 MB flow
## update took about 3 s per conversion, so the renderer's four subscribers
## held it for 12 s, over 30 s on a loaded host -- long enough for the
## scenario driver's page queries to give up ("backend 'node' did not answer
## within 30000 ms", 2026-11-19).
##
## The DapApi here is a stand-in that calls its handlers in turn with one
## body, as `DapApi.receive` does; the body is a real flow update (the one
## `libs/ct-flow-wire` tests with), 300 times over.
##
##   nim js -d:nodejs -r --path:src/frontend/viewmodel src/frontend/viewmodel/tests/unit/test_real_backend_json.nim

import std/[json, jsffi, monotimes, times, unittest]
import isonim/core/async_compat
import backend/[backend_service, real_backend]

proc jsonParse(s: cstring): JsObject {.importjs: "JSON.parse(#)".}
proc jsonStringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc repeated(times: int; o: JsObject): JsObject {.importjs: "({ steps: Array(#).fill(#) })".}

const flowUpdate = staticRead("../../../../../libs/ct-flow-wire/tests/fixtures/flow-update.full.json")

type Handlers = ref object
  list: seq[proc(kind: string, raw: JsObject)]

proc noAnswer(command: string, argsJs: JsObject): BackendFuture[JsObject] =
  newPromise proc(resolve: proc(r: JsObject)) =
    resolve(nil)

proc service(handlers: Handlers): BackendService =
  let subscribe = proc(handler: proc(kind: string, raw: JsObject)) =
    handlers.list.add handler
  newRealBackendService(sendCommand = noAnswer, onBackendEvent = subscribe)

proc deliver(handlers: Handlers; kind: string; raw: JsObject) =
  for handler in handlers.list: handler(kind, raw)

suite "RealBackendService event bodies":
  test "one event's body is converted once for all its subscribers":
    let handlers = Handlers()
    let svc = service(handlers)
    var seen: seq[JsonNode]
    for _ in 0 ..< 4:
      svc.onEvent proc(event: JsonNode) = seen.add event
    let body = jsonParse(cstring(flowUpdate))
    let before = eventBodyConversions
    handlers.deliver("CtUpdatedFlow", body)
    check eventBodyConversions - before == 1
    check seen.len == 4
    let expected = parseJson($jsonStringify(body))
    for event in seen:
      check event["kind"].getStr == "CtUpdatedFlow"
      check event["data"] == expected

  test "another event, even an equal one, is converted again":
    let handlers = Handlers()
    let svc = service(handlers)
    var data: seq[JsonNode]
    svc.onEvent proc(event: JsonNode) = data.add event["data"]
    let before = eventBodyConversions
    handlers.deliver("CtUpdatedFlow", jsonParse(cstring(flowUpdate)))
    handlers.deliver("CtUpdatedFlow", jsonParse(cstring(flowUpdate)))
    check eventBodyConversions - before == 2
    check data.len == 2
    check data[0] == data[1]
    # Two events, two nodes: an edit of one does not show in the other.
    data[0]["edited"] = %true
    check not data[1].hasKey("edited")

  test "a large event costs one conversion with four subscribers":
    let handlers = Handlers()
    let svc = service(handlers)
    var count = 0
    for _ in 0 ..< 4:
      svc.onEvent proc(event: JsonNode) = inc count
    let body = repeated(300, jsonParse(cstring(flowUpdate)))
    let size = jsonStringify(body).len
    check size > 2_000_000
    let before = eventBodyConversions
    let start = getMonoTime()
    handlers.deliver("CtUpdatedFlow", body)
    let ms = (getMonoTime() - start).inMilliseconds
    echo "  ", size, " bytes to four subscribers: ", ms, " ms"
    check count == 4
    check eventBodyConversions - before == 1
