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
proc edgeCases(): JsObject {.importjs: """
  ({ int: 7, float: 1.5, negZero: -0, past53: 9007199254740992, expo: 1e21,
     nan: NaN, inf: -Infinity, gone: undefined, fn: function () {},
     list: [undefined, function () {}, NaN, 2, "x", null, true, [], {}],
     when: new Date(0), text: "flow \u00fc \u2028 \u{1F600}", nil: null,
     nested: { a: [{ b: { c: [1, 2.25, "3"] } }] } })""".}

const flowUpdate = staticRead("../../../../../libs/ct-flow-wire/tests/fixtures/flow-update.full.json")
const elidedFlowUpdate = staticRead("../../../../../libs/ct-flow-wire/tests/fixtures/flow-update.elided.json")

proc roundTrip(o: JsObject): JsonNode = parseJson($jsonStringify(o))

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

suite "jsonFromJs":
  test "a flow update converts to what the string round trip gives":
    for text in [flowUpdate, elidedFlowUpdate]:
      let o = jsonParse(cstring(text))
      check jsonFromJs(o) == roundTrip(o)
      check $jsonFromJs(o) == $roundTrip(o)

  test "JSON.stringify's own cases convert as the round trip does":
    let o = edgeCases()
    let walked = jsonFromJs(o)
    let expected = roundTrip(o)
    check walked == expected
    check $walked == $expected
    check not walked.hasKey("gone")
    check walked["list"].len == 9
    check walked["float"].kind == JFloat
    check walked["int"].kind == JInt
    check walked["when"].kind == JString

  test "a large flow update converts faster than the round trip":
    # About 7.5 MB of JSON: the elided flow update's steps, 450 times over.
    let o = repeated(450, jsonParse(cstring(elidedFlowUpdate)))
    var start = getMonoTime()
    let walked = jsonFromJs(o)
    let walkMs = (getMonoTime() - start).inMilliseconds
    start = getMonoTime()
    let expected = roundTrip(o)
    let roundTripMs = (getMonoTime() - start).inMilliseconds
    echo "  ", jsonStringify(o).len, " bytes: walk ", walkMs, " ms, round trip ", roundTripMs, " ms"
    check walked == expected
    check walkMs < roundTripMs
