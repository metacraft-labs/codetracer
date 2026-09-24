## dap_backend.nim — the ViewModel store's `BackendService` over a `DapApi`.
##
## The renderer's ONE construction of it (`ui_js.configureMiddleware`), in a
## module of its own so a test can build the very same service rather than a
## copy: every command the store sends goes through `DapApi.asyncSendCtRequest`
## — and so through `dap.dispatchCtRequest`, the send path request tracking
## (`dap.trackCtRequests`) observes — and every mapped DAP event is handed to
## the store's event handler.

import std/jsffi
import ../common/ct_event
import dap
import viewmodel/backend/[backend_service, real_backend]

proc newDapBackendService*(
    dapRef: DapApi;
    onSend: proc(command: cstring; args: JsObject) = nil): BackendService =
  ## `onSend` sees each command before it is sent (the renderer's test-mode
  ## request recorder); nil for none.
  newRealBackendService(
    sendCommand = proc(command: string, argsJs: JsObject): BackendFuture[JsObject] =
      if not onSend.isNil:
        onSend(cstring(command), argsJs)
      # Translate the BackendService string command to a CtEventKind and
      # forward it through the existing DapApi IPC channel.
      let kind = dapCommandToEventKind(cstring(command))
      dapRef.asyncSendCtRequest(kind, argsJs),
    onBackendEvent = proc(handler: proc(kind: string, raw: JsObject)) =
      # Subscribe to every event kind that has a DAP mapping so the
      # ViewModel store receives the same events as the legacy UI.
      for k in CtEventKind:
        if EVENT_KIND_TO_DAP_MAPPING[k] != "":
          dap.on[JsObject](dapRef, k, proc(kind: CtEventKind, raw: JsObject) =
            handler($kind, raw)),
  )
