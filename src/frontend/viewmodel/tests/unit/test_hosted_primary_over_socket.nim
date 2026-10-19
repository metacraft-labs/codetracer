## test_hosted_primary_over_socket.nim
##
## A session a server owns (`sync/hosted_primary`) and the pages that mirror
## it, over a real WebSocket: a socket.io server and a socket.io client in one
## Node process, on a loopback port — the transport `ct host` uses.
##
## WHAT IS REAL: socket.io's server and client and the WebSocket between them;
## `socket_transport`'s channel; `hosted_primary` (the primary attaching on
## the replay's first stop and following its moves, `DebuggerSession`,
## `followBackendMoves`, `ReplayDataStore.applyCompleteMove`); `sync_host`,
## the publisher and its default (microtask) scheduler; `mirror_session`, its
## subscriber and its relay of view operations.
##
## THE ONE STAND-IN: `MockBackendService` behind the primary, in place of the
## index's connection to the Backend Manager. These suites are about what the
## server's session does with the replay's events and what crosses the socket;
## a move is scripted as the event the replay emits (`ct/complete-move`), and
## where an action must reach the replay (a step) the mock's recorded commands
## are the evidence it ran on the server.
##
## Node only (`vm-unit-js`): it opens sockets. Needs `socket.io` and
## `socket.io-client` on Node's module path.

import std/[asyncjs, json, jsffi, options]

import isonim/core/[owner, signals]

import ../../backend/mock_backend
import ../../session_vm
import ../../sdk/debugger_session
import ../../store/types
import ../../sync/[hosted_primary, mirror_session, socket_transport,
                   synced_signals]
import ../../viewmodels/state_vm

var checks = 0
var failures = 0
proc ck(cond: bool; what: string) =
  inc checks
  if not cond:
    inc failures
    echo "  FAILED: ", what

# ---------------------------------------------------------------------------
# Sockets
# ---------------------------------------------------------------------------

proc startServer(onConnection: proc(socket: JsObject)): Future[int] {.importjs: """
  new Promise(function (resolve) {
    const http = require('http').createServer();
    const { Server } = require('socket.io');
    const io = new Server(http);
    io.on('connection', function (s) { (#)(s); });
    http.listen(0, '127.0.0.1', function () {
      globalThis.__ctTestServers = (globalThis.__ctTestServers || []);
      globalThis.__ctTestServers.push({ http: http, io: io });
      resolve(http.address().port);
    });
  })""".}

proc connectClient(port: int): Future[JsObject] {.importjs: """
  new Promise(function (resolve) {
    const { io } = require('socket.io-client');
    const s = io('http://127.0.0.1:' + #, { transports: ['websocket'] });
    s.on('connect', function () { resolve(s); });
  })""".}

proc closeClient(socket: JsObject) {.importjs: "#.close()".}
proc stopServers() {.importjs: """
  (globalThis.__ctTestServers || []).forEach(function (s) {
    s.io.close(); s.http.close(); })""".}

proc sleep(ms: int): Future[void] {.importjs:
  "new Promise(function (r) { setTimeout(r, #); })".}

proc eventually(cond: proc(): bool; ms = 5000): Future[bool] {.async.} =
  ## Wait for `cond`, the event loop running, for at most `ms`.
  var waited = 0
  while not cond():
    if waited >= ms:
      return false
    await sleep(10)
    waited += 10
  return true

# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

proc completeMove(ticks: int; line: int): JsonNode =
  ## The replay's `ct/complete-move`, in the envelope a `BackendService`
  ## hands its subscribers.
  %*{"kind": "ct/complete-move",
     "data": {"location": {"path": "/src/main.rs", "line": line,
                           "rrTicks": ticks}}}

proc disagreement(primary, mirror: SessionViewModel): seq[string] =
  ## The mirrored keys whose values differ; empty when the two agree.
  let p = syncedSignalsOf(primary)
  let m = syncedSignalsOf(mirror)
  for s in p.signals:
    let other = m.find(s.key)
    if other.isNone or other.get.read() != s.read():
      result.add s.key

proc main() {.async.} =
  var root: proc()
  createRoot proc(dispose: proc()) = root = dispose

  let mock = newMockBackendService(autoRespond = true)
  let hosted = openHostedPrimary(mock.toBackendService(), "/trace")
  let primary = hosted.debugger.session
  var serverSockets: seq[JsObject]
  let port = await startServer(proc(socket: JsObject) =
    serverSockets.add socket
    hosted.connectPage(socket))

  # ---- the server's session attaches on the replay's first stop
  ck hosted.debugger.phase.val != dspReady, "not attached before a stop"
  mock.emitEvent(completeMove(10, 3))
  ck hosted.debugger.phase.val == dspReady, "attached on the first stop"
  ck primary.store.debugger.val.rrTicks == 10, "the stop's position adopted"

  # ---- a page mirrors it, over the socket
  let page = await connectClient(port)
  let mirror = createMirrorSession(newSocketSyncChannel(page))
  ck await eventually(proc(): bool =
    mirror.session.store.debugger.val.rrTicks == 10), "the page sees the stop"
  ck hosted.pageCount == 1, "one page served"

  # ---- a scripted sequence of moves: the two agree after it
  for (ticks, line) in [(20, 5), (30, 9), (25, 7)]:
    mock.emitEvent(completeMove(ticks, line))
  ck await eventually(proc(): bool =
    mirror.session.store.debugger.val.rrTicks == 25), "the page follows"
  ck await eventually(proc(): bool =
    disagreement(primary, mirror.session).len == 0),
    "primary and mirror agree on every mirrored signal"
  ck hosted.debugger.history.val.len == 4, "each move is in the history"

  # ---- an action on the mirror runs on the server
  mock.clearReceivedCommands()
  mirror.relay("debugControls", "stepForward")
  ck await eventually(proc(): bool = mock.findCommand("next").isSome),
    "a step relayed by the page reaches the server's backend"

  # ---- a view operation in the page's pane is the server's view state
  mirror.session.stateVM.selectTab(stGlobals)
  ck await eventually(proc(): bool =
    primary.stateVM.activeTab.val == stGlobals),
    "a tab chosen in the page is chosen on the server"
  ck await eventually(proc(): bool =
    mirror.session.stateVM.activeTab.val == stGlobals),
    "and stays chosen in the page after the server's next batch"

  # ---- a reloaded page resumes the session where it was
  mirror.dispose()
  closeClient(page)
  # What the server's `disconnect` handler does (`index/server_config`).
  hosted.disconnectPage(serverSockets[0])
  ck hosted.pageCount == 0, "the page that went away is no longer served"
  let reloaded = await connectClient(port)
  let again = createMirrorSession(newSocketSyncChannel(reloaded))
  ck await eventually(proc(): bool =
    again.session.store.debugger.val.rrTicks == 25 and
    again.session.stateVM.activeTab.val == stGlobals),
    "a reloaded page receives the session's position and view state"
  ck await eventually(proc(): bool =
    disagreement(primary, again.session).len == 0),
    "and agrees with it on every mirrored signal"

  # ---- two servers own two independent sessions
  let otherMock = newMockBackendService(autoRespond = true)
  let other = openHostedPrimary(otherMock.toBackendService(), "/other")
  discard await startServer(proc(socket: JsObject) = other.connectPage(socket))
  otherMock.emitEvent(completeMove(500, 1))
  ck other.debugger.session.store.debugger.val.rrTicks == 500,
    "the second server's session moved"
  ck primary.store.debugger.val.rrTicks == 25,
    "the first server's session did not"
  ck other.debugger.history.val.len == 1, "and their histories are their own"

  again.dispose()
  closeClient(reloaded)
  hosted.close()
  other.close()
  stopServers()
  root()
  echo "CHECKS: ", checks
  if failures > 0:
    echo "[FAILED] hosted primary over a socket (", failures, " of ", checks, ")"
    {.emit: "process.exitCode = 1;".}
  else:
    echo "[OK] hosted primary over a socket"

discard main()
