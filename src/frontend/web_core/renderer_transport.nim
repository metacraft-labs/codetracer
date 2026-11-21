## renderer_transport.nim — the WebAssembly core's transport, over the
## renderer's own `DapApi` (`-d:ctWasmPanes`).
##
## The wasm core (`web_core.nim`) speaks DAP text through
## `WorkerBackendService`: out, `{seq, type: "request", command, arguments}`;
## in, a DAP response (`request_seq`, `success`, `body`) or a DAP event
## (`event`, `body`). A page that already runs a session — the desktop
## renderer over Electron IPC, the web build over its socket — has one
## connection to the engine, and that connection is its `DapApi`. This module
## makes that `DapApi` the core's transport, so the core's panes share the
## page's engine and its replay instead of opening another:
##
##   * a request goes out through `DapApi.asyncSendCtRequest` — the one send
##     path every renderer request takes, so it is routed to this tab's
##     replay and tracked like any other — and its answer comes back as a
##     DAP response carrying the core's own `seq`;
##   * every event kind the store subscribes to (`EVENT_KIND_TO_DAP_MAPPING`)
##     is forwarded as a DAP event under its DAP name, exactly what the
##     engine sent.
##
## `newWasmPaneTransport(dap)` returns `{send(text), onMessage(cb)}`, the
## shape `web_core_host.js`'s `startWebCore` takes.

import std/[asyncjs, jsffi]

import ../../common/ct_event
import ../types
import ../dap

proc jsonParse(s: cstring): JsObject {.importjs: "JSON.parse(#)".}
proc jsonStringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc isUndef(o: JsObject): bool {.importjs: "(# == null)".}

proc forwardKind(dap: DapApi; k: CtEventKind; eventName: cstring;
                 deliver: proc(text: cstring)) =
  ## A proc per kind, so each handler closes over its own name: a closure
  ## made in a loop body shares that body's variables in Nim.
  dap.handlers[k].add(proc(kind: CtEventKind; raw: JsObject) =
    let ev = JsObject{}
    ev["type"] = cstring"event"
    ev["event"] = eventName
    ev["body"] = if raw.isUndef: JsObject{} else: raw
    deliver(jsonStringify(ev)))

proc newWasmPaneTransport*(dap: DapApi): JsObject =
  var listeners: seq[proc(text: cstring)] = @[]
  let deliver = proc(text: cstring) =
    for l in listeners: l(text)

  # The same subscription `dap_backend.newDapBackendService` makes for the
  # renderer's own store: every kind with a DAP name.
  for k in CtEventKind:
    if EVENT_KIND_TO_DAP_MAPPING[k].len > 0:
      forwardKind(dap, k, EVENT_KIND_TO_DAP_MAPPING[k], deliver)

  let transport = JsObject{}
  transport["send"] = proc(text: cstring) =
    let msg = jsonParse(text)
    let command = msg["command"].to(cstring)
    let requestSeq = msg["seq"].to(int)
    let args = if msg["arguments"].isUndef: JsObject{} else: msg["arguments"]
    let kind = dapCommandToEventKind(command)
    discard dap.asyncSendCtRequest(kind, args).then(proc(body: JsObject) =
      let resp = JsObject{}
      resp["type"] = cstring"response"
      resp["seq"] = 0
      resp["request_seq"] = requestSeq
      resp["command"] = command
      # `asyncSendCtRequest` resolves with the body alone and with `{}` when
      # nothing came back; the body-only envelope is what
      # `backend_service.responseBody` reads either way.
      resp["success"] = not body.isUndef
      resp["body"] = if body.isUndef: JsObject{} else: body
      deliver(jsonStringify(resp)))
  transport["onMessage"] = proc(cb: proc(text: cstring)) =
    listeners.add cb
  transport

when defined(ctWasmPanes):
  proc installWasmPaneTransport*(dap: DapApi) =
    ## Publish this tab's transport for the wasm panes' host
    ## (`globalThis.ctwRendererTransport`).
    {.emit: ["globalThis.ctwRendererTransport = ", newWasmPaneTransport(dap), ";"].}

  # The panes' host and the core load beside `ui.js`, from `wasm-panes/`
  # (`just build-wasm-panes`). A mount the panel host asks for before they
  # have loaded is queued and replayed once `web_core_panels.js` is in.
  {.emit: """
(function () {
  if (typeof document === 'undefined') return;
  var queued = [];
  globalThis.ctwPanels = { mount: function (n, e) { queued.push([n, e]); } };
  var files = ['frame_applier.js', 'web_core_host.js', 'decorations.js',
               'core_wasm.js', 'web_core_panels.js'];
  var i = 0;
  var next = function () {
    if (i >= files.length) {
      queued.forEach(function (q) { globalThis.ctwPanels.mount(q[0], q[1]); });
      return;
    }
    var s = document.createElement('script');
    s.src = 'wasm-panes/' + files[i++];
    s.onload = next;
    s.onerror = function () { globalThis.ctwPanelsError = 'could not load ' + s.src; };
    document.head.appendChild(s);
  };
  next();
})();
""".}
