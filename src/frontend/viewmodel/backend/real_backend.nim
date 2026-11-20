## real_backend.nim
##
## RealBackendService — production BackendService that bridges to the
## existing DapApi used by CodeTracer's Electron renderer.
##
## This module is JS-only because DapApi depends on the JS FFI
## (jsffi, asyncjs, Electron IPC).
##
## To avoid circular-import issues (dap.nim <-> types.nim), this
## module does NOT import dap.nim directly.  Instead it accepts
## adapter procs that the call site provides.  The call site (which
## already has DapApi in scope) wires the adapters once at
## initialisation time.
##
## Example wiring (in the renderer bootstrap):
##
##   import dap, viewmodel/backend/[backend_service, real_backend]
##
##   let svc = newRealBackendService(
##     sendCommand = proc(cmd: string, args: JsObject) =
##       dapApi.sendCtRequest(dapCommandToKind(cmd), args),
##     onBackendEvent = proc(handler: proc(kind: string, raw: JsObject)) =
##       for k in CtEventKind:
##         dapApi.on[:JsObject](k, proc(kind: CtEventKind, raw: JsObject) =
##           handler($kind, raw)),
##   )

when not defined(js):
  {.error: "real_backend.nim requires the JS backend (nim js)".}

import std/[json, jsffi, asyncjs, tables]
import isonim/core/async_compat
import backend_service

# ---------------------------------------------------------------------------
# JSON <-> JsObject helpers
# ---------------------------------------------------------------------------

proc stringifyJs(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc jsKindTag(o: JsObject): int {.importjs: """((v) => {
  if (v === undefined) return 8;
  if (v === null) return 0;
  switch (typeof v) {
    case 'boolean': return 1;
    case 'number':
      if (Number.isSafeInteger(v)) return 2;
      return Number.isFinite(v) ? 9 : 0;
    case 'string': return 4;
    case 'bigint': return 9;
    case 'object':
      if (typeof v.toJSON === 'function') return 9;
      return Array.isArray(v) ? 5 : 6;
    default: return 7;
  }})(#)""".}
  ## What `jsonFromJs` does with a value, decided in one JavaScript call:
  ## 0 null (also a non-finite number), 1 bool, 2 safe integer, 4 string,
  ## 5 array, 6 plain object, 7 a function or symbol, 8 undefined, 9 a value
  ## converted through its JSON text: a number other than a safe integer (Nim's
  ## JSON reader decides what such a number's text becomes, a float or, past
  ## its integer range, a string), a BigInt, a Date or any `toJSON`.
proc jsLength(o: JsObject): int {.importjs: "#.length".}
proc jsItem(o: JsObject; i: int): JsObject {.importjs: "#[#]".}
proc jsOwnKeys(o: JsObject): seq[cstring] {.importjs: "Object.keys(#)".}
proc jsMember(o: JsObject; key: cstring): JsObject {.importjs: "#[#]".}
proc jsAsInt(o: JsObject): int {.importjs: "(#)".}
proc jsAsBool(o: JsObject): bool {.importjs: "(#)".}
proc jsAsCstring(o: JsObject): cstring {.importjs: "(#)".}

proc jsonFromJs*(o: JsObject): JsonNode =
  ## A decoded DAP message as a stdlib JsonNode: the node
  ## `parseJson(JSON.stringify(o))` gives, built by walking `o`.
  ##
  ## Nim's JS backend represents JsonNode with a tagged object shape, so a
  ## `JSON.parse` result cannot be used as one. The string round trip it
  ## replaces spent most of its time in Nim's JSON lexer: 8.2 s for a 7.5 MB
  ## flow update in node, against 3.7 s for this walk. A Pascal loop's 2.7 MB
  ## flow update converted on a renderer at load 175-290 held the page long
  ## enough for the scenario driver's queries to give up ("backend 'node' did
  ## not answer within 30000 ms", 2026-11-20).
  ##
  ## As `JSON.stringify`: an `undefined`, function or symbol member is left
  ## out of an object and is null in an array; a non-finite number is null; a
  ## BigInt, a Date or any value with `toJSON` goes through the round trip,
  ## and so does any number other than a safe integer (most of a flow's
  ## numbers are safe integers, which become integer nodes directly).
  case jsKindTag(o)
  of 1:
    result = newJBool(jsAsBool(o))
  of 2:
    result = newJInt(jsAsInt(o))
  of 4:
    result = newJString($jsAsCstring(o))
  of 5:
    let n = jsLength(o)
    result = JsonNode(kind: JArray, elems: newSeqOfCap[JsonNode](n))
    for i in 0 ..< n:
      result.elems.add jsonFromJs(jsItem(o, i))
  of 6:
    result = newJObject()
    for key in jsOwnKeys(o):
      let member = jsMember(o, key)
      let tag = jsKindTag(member)
      if tag != 7 and tag != 8:
        result.fields[$key] = jsonFromJs(member)
  of 9:
    result = parseJson($stringifyJs(o))
  else:
    result = newJNull()

proc parseJsonFromJs(o: JsObject): JsonNode =
  ## Convert a raw JsObject to a stdlib JsonNode (see `jsonFromJs`).
  jsonFromJs(o)

proc jsonParseJs(s: cstring): JsObject {.importjs: "JSON.parse(#)".}
proc jsSame(a, b: JsObject): bool {.importjs: "(# === #)".}

var
  lastEventBody: JsObject
  lastEventNode: JsonNode
  eventBodyConversions* = 0
    ## How many event bodies were converted to JsonNode (tests read it).

proc eventBodyNode(raw: JsObject): JsonNode =
  ## The JsonNode of an event body, converted once for all subscribers.
  ##
  ## Every `onEvent` subscriber is its own DapApi handler, and each handler
  ## converted the body itself: four conversions of every event, although
  ## each subscriber looks at the kind first and most ignore it. A Pascal
  ## loop's 2.7 MB flow update took about 3 s per conversion, so the four
  ## held the renderer busy for 12 s, over 30 s on a loaded host -- long
  ## enough for a test driver's page queries to time out ("backend 'node'
  ## did not answer within 30000 ms", 2026-11-19). The handlers of one event
  ## are called in turn with the same body, so the last conversion is kept
  ## and reused while the body is the same object.
  ##
  ## The subscribers share the node. The one that edits it (the flow
  ## ViewModel restores elided step values in place, `common/flow_wire`) does
  ## so idempotently, for the only kind it reads.
  if not lastEventBody.isNil and jsSame(raw, lastEventBody):
    return lastEventNode
  result = parseJsonFromJs(raw)
  inc eventBodyConversions
  lastEventBody = raw
  lastEventNode = result

proc toJsObject(j: JsonNode): JsObject =
  ## Convert a stdlib JsonNode to a raw JsObject for DapApi.
  ## Nim's JS backend represents JsonNode as an internal object with
  ## `kind`, `str`, `fields` etc. We must serialize to a JSON string
  ## first (via Nim's `$`), then parse it back with JavaScript's
  ## `JSON.parse` to get a plain JS object that DapApi expects.
  jsonParseJs(cstring($j))

# ---------------------------------------------------------------------------
# Adapter types
# ---------------------------------------------------------------------------

type
  SendCommandProc* = proc(command: string, argsJs: JsObject): BackendFuture[JsObject]
    ## Adapter that sends a command through DapApi.
    ## The call site translates the string command to a CtEventKind
    ## and calls DapApi.sendCtRequest.

  OnBackendEventProc* = proc(handler: proc(kind: string, raw: JsObject))
    ## Adapter that registers an event handler on DapApi.
    ## The call site iterates CtEventKind values and subscribes via
    ## DapApi.on, forwarding the kind name and raw JsObject payload.

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newRealBackendService*(
    sendCommand: SendCommandProc,
    onBackendEvent: OnBackendEventProc,
): BackendService =
  ## Create a BackendService backed by DapApi adapter procs.
  ##
  ## The returned service translates between the JSON-based
  ## BackendService interface and the JsObject-based DapApi protocol.

  let sendProc = proc(command: string,
                      args: JsonNode): BackendFuture[JsonNode] =
    let jsArgs = toJsObject(args)
    let future = sendCommand(command, jsArgs)
    return newPromise proc(resolve: proc(resp: JsonNode)) =
      onComplete(future,
        proc(raw: JsObject) =
          if raw.isNil:
            resolve(newJNull())
          else:
            resolve(parseJsonFromJs(raw)),
        proc(message: string) =
          resolve(newJNull()))

  let onEventProc = proc(handler: EventHandler) =
    onBackendEvent proc(kind: string, raw: JsObject) =
      var j = %*{"kind": kind}
      if not raw.isNil:
        j["data"] = eventBodyNode(raw)
      handler(j)

  let disconnectProc = proc() =
    # DapApi has no explicit disconnect — Electron manages the IPC
    # channel.  This is a no-op placeholder for now.
    discard

  BackendService(
    sendProc: sendProc,
    onEventProc: onEventProc,
    disconnectProc: disconnectProc,
  )
