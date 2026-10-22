## test_vscode_host.nim — the VS Code extension host's sessions and the
## panels mirroring them (`entries/vscode_host`, Shared-DOM-Front-Ends D2).
##
## The host is driven exactly as the extension drives it: a debug session's
## `customRequest` is a JS function (here one that records each request and
## answers `{}`), the replay's events are DAP event messages handed to
## `deliverEvent`, and a panel's webview is a `postMessage` function plus
## `deliverFromWebview`. The panel side is the real mirror
## (`createMirrorSession`, `relayActions`) over a channel that crosses in the
## webview transport's envelope, asynchronously, as `postMessage` does.
##
## The one stand-in is the debug session: `customRequest` and the tracker are
## VS Code objects, and what this suite asserts is what the host does with
## the requests it makes and the events it is given.
##
## JS only (`-d:nodejs`).

import std/[asyncjs, json, jsffi, options]

import isonim/core/[owner, signals]

import ../../../entries/vscode_host
import ../../session_vm
import ../../store/types
import ../../sync/[mirror_session, transport, webview_transport]
import ../../viewmodels/[calltrace_vm, filesystem_vm, flow_line_values,
                         state_vm]

var checks = 0
var failures = 0
proc ck(cond: bool; what: string) =
  inc checks
  if not cond:
    inc failures
    echo "  FAILED: ", what

proc sleep(ms: int): Future[void] {.importjs:
  "new Promise(function (r) { setTimeout(r, #); })".}

proc eventually(cond: proc(): bool; ms = 5000): Future[bool] {.async.} =
  var waited = 0
  while not cond():
    if waited >= ms:
      return false
    await sleep(10)
    waited += 10
  return true

proc recordingRequest(log: cstring): JsObject {.importjs: """
  (function (name) {
    globalThis[name] = [];
    return function (command, args) {
      globalThis[name].push({ command: command, args: args });
      return Promise.resolve({});
    };
  })(#)""".}
  ## A `customRequest` that records every request in `globalThis[log]`.

proc requested(log: cstring; command: cstring): bool {.importjs:
  "(globalThis[#] || []).some(function (r) { return r.command === #; })".}
proc clearRequests(log: cstring) {.importjs: "globalThis[#] = []".}
proc later(fn: proc()) {.importjs: "setTimeout(#, 0)".}

proc dapEvent(event: string; body: JsonNode): JsonNode =
  ## A DAP event message, as the extension's tracker sees it.
  %*{"type": "event", "event": event, "body": body}

proc completeMove(ticks, line: int): JsonNode =
  dapEvent("ct/complete-move",
           %*{"location": {"path": "/src/main.rs", "line": line,
                           "rrTicks": ticks}})

proc envelopeOf(msg: JsonNode): JsObject =
  result = newJsObject()
  result[cstring(SyncEnvelopeKey)] = cstring($msg)

proc main() {.async.} =
  var root: proc()
  createRoot proc(dispose: proc()) = root = dispose

  let host = newVsCodeHost()
  host.openSession("s1", "/trace", recordingRequest("s1Requests"))
  host.activate("s1")

  # ---- a panel: the webview's mirror over postMessage-like delivery
  var hostEnd: SyncChannel
  var panelEnd: SyncChannel
  panelEnd = newSyncChannel(proc(msg: JsonNode) =
    let data = envelopeOf(msg)
    later(proc() = discard hostEnd.deliverFromWebview(data)))
  hostEnd = host.attachWebview(proc(message: JsObject) =
    let text = $message[cstring(SyncEnvelopeKey)].to(cstring)
    later(proc() = panelEnd.deliver(parseJson(text))))
  let mirror = createMirrorSession(panelEnd, relayActions = true)

  # ---- the session attaches on the replay's first stop; the panel sees it
  host.deliverEvent("s1", completeMove(10, 3))
  ck await eventually(proc(): bool =
    mirror.session.store.debugger.val.rrTicks == 10),
    "the panel shows the stop the replay reported"
  host.deliverEvent("s1", completeMove(20, 5))
  ck await eventually(proc(): bool =
    mirror.session.store.debugger.val.rrTicks == 20),
    "the panel follows the replay's moves"

  # ---- an action in the panel runs on the host, through customRequest
  clearRequests("s1Requests")
  mirror.session.stateVM.loadMore("xs")
  mirror.session.calltraceVM.setSearchQuery("main")
  ck await eventually(proc(): bool =
    requested("s1Requests", "ct/search-calltrace")),
    "a search typed in the panel is asked by the host's session"
  mirror.session.stateVM.selectTab(stWatches)
  ck await eventually(proc(): bool =
    mirror.session.stateVM.activeTab.val == stWatches),
    "a tab chosen in the panel is the session's, and comes back to it"

  # ---- the file tree: the recording's sources; "open" opens VS Code's editor
  host.setSourceFiles("s1", @["/src/main.rs", "/src/util/math.rs"])
  let tree = host.sessionView("s1").fileTreeVM.rootEntry.val
  ck tree.children.len == 1 and tree.children[0].text == "src",
    "the sources are listed under their folder"
  var opened: seq[string] = @[]
  host.onOpenFile(proc(path: string) = opened.add path)
  mirror.session.fileTreeVM.openFile("/src/main.rs")
  ck await eventually(proc(): bool = opened == @["/src/main.rs"]),
    "a file opened in the panel is opened in the editor"

  # ---- the editor's flow decorations are fed from the host's FlowVM
  var flowCalls = 0
  host.onFlowLines(proc(path: string; lines: seq[FlowLineValue]) =
    inc flowCalls)
  ck flowCalls >= 1, "the flow listener is told the active session's flow"

  # ---- a tracepoint sweep is asked for, and its answer applied
  clearRequests("s1Requests")
  host.runTracepoint("/src/main.rs", 5, "x")
  ck await eventually(proc(): bool =
    requested("s1Requests", "ct/run-tracepoints")),
    "a tracepoint is run over the recording"
  host.deliverEvent("s1", dapEvent("ct/tracepoint-results", %*{"results": [
    {"tracepointId": 0, "rrTicks": 15, "path": "/src/main.rs", "line": 5}]}))
  ck await eventually(proc(): bool =
    host.sessionView("s1").store.pointList.tracepointHits.val.len == 1),
    "the sweep's hit is the session's"

  # ---- a second debug session; VS Code's picker switches the panels to it
  host.openSession("s2", "/other", recordingRequest("s2Requests"))
  host.deliverEvent("s2", completeMove(500, 1))
  ck await eventually(proc(): bool =
    not host.sessionView("s2").isNil), "the second session is hosted"
  ck mirror.session.store.debugger.val.rrTicks == 20,
    "the panel stays on the active session"
  host.activate("s2")
  ck await eventually(proc(): bool =
    mirror.session.store.debugger.val.rrTicks == 500),
    "switching shows the second session"
  host.deliverEvent("s1", completeMove(30, 9))
  ck host.sessionView("s1").store.debugger.val.rrTicks == 30,
    "the session in the background keeps following its replay"
  host.activate("s1")
  ck await eventually(proc(): bool =
    mirror.session.store.debugger.val.rrTicks == 30),
    "switching back shows it where it is"

  # ---- a debug session that ends is no longer hosted
  host.closeSession("s1")
  ck host.sessionView("s1").isNil, "the ended session is gone"
  ck await eventually(proc(): bool =
    mirror.session.store.debugger.val.rrTicks == 500),
    "the panel moves to the session still running"

  host.detachWebview(hostEnd)
  mirror.dispose()
  host.dispose()
  root()
  echo "CHECKS: ", checks
  if failures > 0:
    echo "[FAILED] VS Code host (", failures, " of ", checks, ")"
    {.emit: "process.exitCode = 1;".}
  else:
    echo "[OK] VS Code host"

discard main()
