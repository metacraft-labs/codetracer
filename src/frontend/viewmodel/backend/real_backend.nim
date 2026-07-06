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

import std/[json, jsffi, asyncjs]
import isonim/core/async_compat
import backend_service

# ---------------------------------------------------------------------------
# JSON <-> JsObject helpers
# ---------------------------------------------------------------------------

proc stringifyJs(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc parseJsonFromJs(o: JsObject): JsonNode =
  ## Convert a raw JsObject to a stdlib JsonNode. Nim's JS backend represents
  ## JsonNode with a tagged object shape; a direct JSON.parse result is only a
  ## plain JavaScript object and will fail JsonNode kind checks.
  parseJson($stringifyJs(o))

proc jsonParseJs(s: cstring): JsObject {.importjs: "JSON.parse(#)".}

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
        j["data"] = parseJsonFromJs(raw)
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
