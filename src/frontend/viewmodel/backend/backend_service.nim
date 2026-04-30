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
