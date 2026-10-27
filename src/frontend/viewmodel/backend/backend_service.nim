## backend_service.nim
##
## BackendService — abstract interface for communicating with the
## CodeTracer debug backend (DAP-based or otherwise).
##
## Uses the IsoNim service-injection pattern: a plain object with
## proc fields.  Production code supplies a RealBackendService backed
## by DapApi; tests supply a MockBackendService that records calls and
## returns canned responses.
##
## Works on both JS (nim js — Electron renderer) and C backends.

import std/json
import isonim/core/async_compat

type BackendFuture*[T] = PlatformFuture[T]
  ## Backend-specific alias for PlatformFuture. Kept as a named type
  ## so that call sites remain self-documenting about their intent.

type
  EventHandler* = proc(event: JsonNode)
    ## Callback invoked when the backend emits an unsolicited event.

  BackendService* = ref object
    ## Abstract backend service.  Each field is a proc that concrete
    ## implementations fill in.
    sendProc*: proc(command: string, args: JsonNode): BackendFuture[JsonNode]
      ## Send a command to the backend and asynchronously receive a
      ## response.  `command` is the DAP/CT command name; `args` is
      ## the JSON payload.

    onEventProc*: proc(handler: EventHandler)
      ## Register a handler that will be called for every backend
      ## event (e.g. "stopped", "updated-calltrace").

    disconnectProc*: proc()
      ## Tear down the connection to the backend.

# ---------------------------------------------------------------------------
# Convenience wrappers — callers use these instead of touching the procs
# directly so that usage reads naturally and nil-safety is centralised.
# ---------------------------------------------------------------------------

proc send*(b: BackendService, command: string,
           args: JsonNode): BackendFuture[JsonNode] =
  ## Send a command and return the future response.
  assert b.sendProc != nil, "BackendService.sendProc is not set"
  b.sendProc(command, args)

proc onEvent*(b: BackendService, handler: EventHandler) =
  ## Register a backend event handler.
  assert b.onEventProc != nil, "BackendService.onEventProc is not set"
  b.onEventProc(handler)

proc disconnect*(b: BackendService) =
  ## Disconnect from the backend.
  if b.disconnectProc != nil:
    b.disconnectProc()

# ---------------------------------------------------------------------------
# Response envelopes
#
# The transports do not resolve `send` with the same shape. `DapApi`'s
# `asyncSendCtRequest`, under `RealBackendService`, resolves with the DAP
# response's `body` alone (and `{}`/`null` when the request failed), while the
# stdio and worker transports, and the mock, resolve with the whole response
# — `{"success": …, "body": …}`. Every decoder that reads an answer used to
# guess at the envelope on its own (`flow_vm`, `event_log_vm`, the store's
# event-log and event-index decoders); these two procs are the one place that
# guess is made.
# ---------------------------------------------------------------------------

func isResponseEnvelope*(resp: JsonNode): bool =
  ## A whole DAP response, as opposed to a bare body. DAP makes `success` a
  ## mandatory boolean on every response
  ## (https://microsoft.github.io/debug-adapter-protocol/specification#Base_Protocol_Response),
  ## and no `ct/*` body this front-end reads has a top-level `success`.
  if resp.isNil or resp.kind != JObject:
    return false
  let success = resp.getOrDefault("success")
  not success.isNil and success.kind == JBool

func responseSucceeded*(resp: JsonNode): bool =
  ## Whether `resp`, as any transport resolves it, is a successful answer. A
  ## bare body counts as one unless it is missing (`null`), which is how the
  ## body-only transport reports a failed or timed-out request.
  if isResponseEnvelope(resp):
    resp["success"].getBool
  else:
    not resp.isNil and resp.kind != JNull

func responseBody*(resp: JsonNode): JsonNode =
  ## The DAP `body` of `resp`, as any transport resolves it; an empty object
  ## when there is none, so a decoder can index it without nil checks.
  let body =
    if isResponseEnvelope(resp): resp.getOrDefault("body")
    else: resp
  if body.isNil or body.kind != JObject: newJObject() else: body
