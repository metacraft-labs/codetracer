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
## the requests it makes and the events it is given. For the editor's "Add to
## Scratchpad" the stand-in answers `ct/load-locals` with the wire shapes the
## replay's watch evaluator writes (`db-backend/src/db.rs`: a value marked
## `isWatch`, or `watch_expression::refusal_value`'s `Error` value), because
## what is asserted is how the host reads those answers, not the evaluator.
##
## JS only (`-d:nodejs`).

import std/[asyncjs, importutils, json, jsffi, options, strutils]

import isonim/core/[owner, signals]

import ../../../entries/vscode_host
import ../../session_vm
import ../../store/[replay_data_store, types]
import ../../sync/[mirror_session, transport, webview_transport]
import ../../viewmodels/[calltrace_vm, filesystem_vm, flow_line_values,
                         scratchpad_vm, state_vm, trace_log_vm]
import ../../sync/sync_host

proc sessionView(host: VsCodeHost; id: string): SessionViewModel =
  ## Debug session `id`'s ViewModels once it is hosted (its first stop); nil
  ## before, and after it ended. The suite reads the host's private session
  ## registry: the extension asks the host for actions, never for a session.
  privateAccess(VsCodeHost)
  host.sync.primary(id)

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

proc refusingRequest(log: cstring; refused: cstring): JsObject {.importjs: """
  (function (name, refused) {
    globalThis[name] = [];
    return function (command, args) {
      globalThis[name].push({ command: command, args: args });
      return command === refused
        ? Promise.reject(new Error('refused')) : Promise.resolve({});
    };
  })(#, #)""".}
  ## A `customRequest` that records every request and REJECTS `refused`, as
  ## VS Code does when the adapter answers it with an error response.

proc watchAnsweringRequest(log: cstring): JsObject {.importjs: """
  (function (name) {
    globalThis[name] = [];
    return function (command, args) {
      globalThis[name].push({ command: command, args: args });
      if (command !== 'ct/load-locals') { return Promise.resolve({}); }
      var w = (args && args.watchExpressions) || [];
      if (w.length !== 1) { return Promise.resolve({}); }
      var e = w[0];
      if (e === 'p.x') {
        return Promise.resolve({ locals: [
          { expression: 'p', value: { kind: 7, i: '1' } },
          { expression: e, value: { kind: 7, i: '43', isWatch: true } }] });
      }
      if (e === 'q.z') {
        return Promise.resolve({ locals: [{ expression: e, value: {
          kind: 24, msg: 'no variable named `q` was recorded at this step',
          isWatch: true } }] });
      }
      if (e === 'silent') { return Promise.resolve({ locals: [] }); }
      return Promise.reject(new Error('refused'));
    };
  })(#)""".}
  ## A `customRequest` that records every request and answers a one-watch
  ## `ct/load-locals` as the replay's watch evaluator would: `p.x` has a
  ## value, `q.z` is refused, `silent` gets no row, anything else fails.

proc watchesRequested(log: cstring): cstring {.importjs: """
  JSON.stringify((globalThis[#] || []).filter(function (r) {
    return r.command === 'ct/load-locals'; }).map(function (r) {
    return r.args.watchExpressions; }))""".}

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
  host.openSession("s1", "/trace", watchAnsweringRequest("s1Requests"))
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
  mirror.session.stateVM.selectPath("w")
  ck await eventually(proc(): bool =
    mirror.session.stateVM.selectedPath.val == "w"),
    "a row selected in the panel is the session's, and comes back to it"

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
  host.onFlowLines(proc(path: string; lines: seq[FlowLineValue];
                        loops: seq[FlowLoopLine]) =
    inc flowCalls)
  ck flowCalls >= 1, "the flow listener is told the active session's flow"

  # ---- "Add to scratchpad" in the editor reaches the session's scratchpad
  let s1 = host.sessionView("s1")
  s1.store.locals.locals.val = @[makeVariable(name = "x", value = "42",
                                              typeName = "int")]
  var outcomes: seq[(ScratchpadAddOutcome, string)] = @[]
  let note = proc(o: ScratchpadAddOutcome; detail: string) =
    outcomes.add((o, detail))
  clearRequests("s1Requests")
  host.addToScratchpad("x", note)
  ck outcomes.len == 1 and outcomes[0][0] == saAdded,
    "a local of the stop is added"
  ck not requested("s1Requests", "ct/load-locals"),
    "a local is added as the State pane shows it, with no request"
  ck s1.scratchpadVM.entries.val.len == 1 and
    s1.scratchpadVM.entries.val[0].valueText == "42",
    "a local added in the editor is pinned in the session's scratchpad"
  ck await eventually(proc(): bool =
    mirror.session.scratchpadVM.entries.val.len == 1),
    "and the panel shows it"

  # ---- a selection that is not a local is EVALUATED through the watch path
  # (Scratchpad-Pane.md § Adding Values, "An editor selection (VS Code)")
  let watchesBefore = s1.stateVM.watchExpressions.val
  outcomes = @[]
  host.addToScratchpad("p.x", note)
  ck await eventually(proc(): bool = outcomes.len == 1),
    "an expression's evaluation settles"
  ck outcomes.len == 1 and outcomes[0][0] == saEvaluated,
    "an expression the replay evaluates is reported as evaluated"
  ck $watchesRequested("s1Requests") == """[["p.x"]]""",
    "it is evaluated by one ct/load-locals carrying it as the only watch"
  ck s1.scratchpadVM.entries.val.len == 2 and
    s1.scratchpadVM.entries.val[1].expression == "p.x" and
    s1.scratchpadVM.entries.val[1].valueText == "43" and
    not s1.scratchpadVM.entries.val[1].isError,
    "its watch answer is the value pinned in the scratchpad"
  ck s1.stateVM.watchExpressions.val == watchesBefore,
    "the State pane's watch list is not changed"
  ck s1.store.locals.locals.val.len == 1 and
    s1.store.locals.locals.val[0].name == "x",
    "the evaluation's locals are not applied to the stop"

  # ---- an evaluation that fails is an error value, not a dropped add
  for (expr, why) in [("q.z", "no variable named `q`"),
                      ("silent", "no value for it"),
                      ("boom", "could not evaluate")]:
    outcomes = @[]
    let before = s1.scratchpadVM.entries.val.len
    host.addToScratchpad(expr, note)
    ck await eventually(proc(): bool = outcomes.len == 1),
      "'" & expr & "': the evaluation settles"
    ck outcomes.len == 1 and outcomes[0][0] == saError and
      why in outcomes[0][1],
      "'" & expr & "': reported as an error saying why (" & why & ")"
    let entries = s1.scratchpadVM.entries.val
    ck entries.len == before + 1 and entries[^1].expression == expr and
      entries[^1].isError and why in entries[^1].valueText,
      "'" & expr & "': the scratchpad shows an error value saying why"
  ck await eventually(proc(): bool =
    mirror.session.scratchpadVM.entries.val.len == 5 and
      mirror.session.scratchpadVM.entries.val[4].isError),
    "the panel shows the evaluated and the error values"

  # ---- the debug toolbar's history back / forward jump through the session
  clearRequests("s1Requests")
  host.moveInHistory(back = true)
  ck await eventually(proc(): bool =
    requested("s1Requests", "ct/history-jump")),
    "history back jumps to the session's previous stop"

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
  ck await eventually(proc(): bool =
    host.sessionView("s1").traceLogVM.entries.val.len == 1 and
      host.sessionView("s1").traceLogVM.entries.val[0].rrTicks == 15),
    "the sweep's hit is a Trace Log row: the panel the extension opens for it"
  ck await eventually(proc(): bool =
    mirror.session.traceLogVM.entries.val.len == 1 and
      mirror.session.traceLogVM.entries.val[0].line == 5),
    "and the Trace Log panel shows it"
  ck host.sessionView("s1").store.pointList.rows.val.len == 1 and
    host.sessionView("s1").store.pointList.rows.val[0].resolution == "swept",
    "a run the replay took is not reported as refused"

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

  # ---- a tracepoint run the replay refuses is said on its row, and the
  # ---- hits of the earlier sweep stay
  host.openSession("s3", "/third",
                   refusingRequest("s3Requests", "ct/run-tracepoints"))
  host.deliverEvent("s3", completeMove(7, 2))
  host.activate("s3")
  let s3 = host.sessionView("s3")
  s3.store.pointList.tracepointHits.val = @[TracepointSweepHit(
    tracepointId: 9, rrTicks: 3, path: "/src/a.rs", line: 1)]
  host.runTracepoint("/src/main.rs", 4, "y")
  ck await eventually(proc(): bool =
    s3.store.pointList.rows.val.len == 1 and
      s3.store.pointList.rows.val[0].detail.startsWith(TracepointRunRefused)),
    "a refused run says so on the tracepoint's row"
  ck s3.store.pointList.tracepointHits.val.len == 1 and
    s3.store.pointList.tracepointHits.val[0].rrTicks == 3,
    "a refused run leaves the hits it did not answer"
  host.closeSession("s3")
  host.activate("s1")

  # ---- a debug session that ends is no longer hosted
  host.closeSession("s1")
  ck host.sessionView("s1").isNil, "the ended session is gone"
  ck await eventually(proc(): bool =
    mirror.session.store.debugger.val.rrTicks == 500),
    "the panel moves to the session still running"

  # ---- before any session is hosted nothing is evaluated and nothing added
  let idle = newVsCodeHost()
  var idleOutcome: seq[ScratchpadAddOutcome] = @[]
  idle.addToScratchpad("x", proc(o: ScratchpadAddOutcome; detail: string) =
    idleOutcome.add o)
  ck idleOutcome == @[saNoSession],
    "with no hosted session the add says so and adds nothing"
  idle.dispose()

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
