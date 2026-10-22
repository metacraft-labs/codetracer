## index/host_clients.nim — the clients of one `ct host` server, each with a
## session of its own.
##
## `CLI/ct/host.md`, "High-Level Rules": "**Sessions are isolated.** Two
## clients replaying the same trace get independent backends and cannot
## observe each other's position." So the server keeps a CLIENT per id the
## page holds (`ct_client` in the socket handshake, kept in the tab's
## `sessionStorage`), and each client has:
##
## * its own replay process in the Backend Manager — the one the server
##   started on its first client, or one started for it (`startReplay`);
## * its own primary `DebuggerSession` on the server's `SyncHost`
##   (`hosted_primary`), which its page mirrors, pinned to it;
## * its own share of what the index says: an answer to a request goes to the
##   client that asked, a replay's answers and events go to the client that
##   owns the replay, and what the index says to no one in particular (the
##   startup's `init`, the trace it loaded) goes to every client;
## * its own reconnect bootstrap, so a reload of that tab resumes ITS replay
##   at ITS position (`bootstrap_cache`, ADR 0006).
##
## A second socket with the SAME id (a reload whose old socket has not closed
## yet, or a duplicated tab, which copies `sessionStorage`) takes the client
## over and the old one is told `superseded`. A socket with ANOTHER id is
## another client and supersedes no one.
##
## WHICH CLIENT IS ASKING. The index's IPC handlers answer through one send
## path (`mainWindow.webContents.send`), long after the request, across
## awaits. Each handler bound to a client's socket runs inside that client's
## context (`served_client`, Node's `AsyncLocalStorage`), which follows its
## promises, timers and the I/O it starts, so the send path knows whose
## answer it is carrying. A send made outside every client's context is for
## every client.
##
## That context also follows what a request STARTS, which is right for work
## done for the asker (a recording, a search, an upload) and wrong for two
## kinds of long-lived source, each handled where it lives:
##
## * a watch of something every client shares, started while serving one —
##   the keybindings file (`keybindings`), an open source file
##   (`config.notifySourceFileChanged`): it reports through
##   `forEveryClient`;
## * one connection serving several clients' sessions — the Backend Manager
##   (by replay: `deliverDap` below), the ACP agent (by ACP session:
##   `acp_ipc.runAsSessionOwner`): each message runs as the client that owns
##   its session.
##
## RELEASE. A client whose last socket closed keeps its replay and session for
## `releaseAfterMs` (`ct host`'s idle timeout), so a reload resumes it; after
## that its session is closed and its replays are stopped. A negative
## `releaseAfterMs` (`--idle-timeout never`) keeps it until the server exits.
##
## JS only: it runs in the `ct host` server process.

when not defined(js):
  {.error: "index/host_clients runs in the ct host server (JS).".}

import std/[asyncjs, jsffi, strutils, tables]

import base_handlers, bootstrap_cache, served_client, electron_vars,
  hosted_session
import ipc_subsystems/dap
import ../../common/ct_logging

const
  ClientIdParameter* = "ct_client"
    ## The socket handshake query parameter that names the page's client.
  MaxClientIdLength = 64
  PageSessionId = 0
    ## The DAP session number a page gives its replay: a page of `ct host`
    ## drives one replay and numbers it 0, as a single-replay page does.
  SelectionChannels = [cstring"CODETRACER::dap-replay-selected",
                       cstring"CODETRACER::dap-live-session-selected"]
    ## The messages that hand a page its replay: always one client's.
  DapEventChannel = cstring"CODETRACER::dap-receive-event"

type
  HostClient* = ref object
    id: string
    socket: WebSocket
      ## The socket serving it now; nil while it has none.
    replayId: int
      ## Its replay; -1 until it has one.
    replays: seq[int]
      ## Every replay started for it, stopped when it is released.
    allocating: bool
    primary: HostedPrimary
    bootstrap: seq[BootstrapPayload]
      ## What the index said to this client alone, for its next socket.
    goneSinceMs: float
      ## When its last socket closed; 0 while it has one.

  ReplayStarter* = proc(): Future[int]
    ## Start a replay process; resolves with its id, or -1.
  ReplayStopper* = proc(replayId: int)

  HostClients* = ref object
    ipc: FrontendIPC
    clients: OrderedTable[string, HostClient]
    owners: Table[int, HostClient]
      ## Which client each replay belongs to.
    shared: seq[BootstrapPayload]
      ## What the index said to every client, for every next socket.
    selection: JsObject
      ## The startup's replay selection (parsed), the template for every
      ## other client's: the trace this server serves. Nil until it was made.
    selectionChannel: cstring
    spareReplay: int
      ## The startup's replay while no client has taken it; -1 otherwise.
    sessions: HostedSessions
    startReplay*: ReplayStarter
    stopReplay*: ReplayStopper
    releaseAfterMs*: int

proc jsonStringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc jsonParse(s: cstring): JsObject {.importjs: "JSON.parse(#)".}
proc jsAssign(target, source: JsObject): JsObject {.importjs: "Object.assign(#, #)".}
proc randomUuid(): cstring {.importjs: "require('crypto').randomUUID()".}
proc nowMs(): float {.importjs: "Date.now()".}

proc newHostClients*(ipc: FrontendIPC; releaseAfterMs: int): HostClients =
  HostClients(ipc: ipc,
              clients: initOrderedTable[string, HostClient](),
              owners: initTable[int, HostClient](),
              spareReplay: -1, sessions: newHostedSessions(),
              releaseAfterMs: releaseAfterMs)

proc normalizeClientId(raw: string): string =
  ## The client id a page presented, or "" when it is not one: 1 to 64 of
  ## `[A-Za-z0-9_-]`. An id is not a credential (every admitted client holds
  ## the session secret); the bound keeps a hostile value out of the table
  ## and the logs.
  if raw.len == 0 or raw.len > MaxClientIdLength:
    return ""
  for ch in raw:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}:
      return ""
  raw

proc current(hc: HostClients): HostClient =
  ## The client whose request the running code is serving, or nil.
  let store = currentClient()
  if store.isNil: nil else: cast[HostClient](store)

proc attachedCount*(hc: HostClients): int =
  ## How many clients have a socket now.
  for c in hc.clients.values:
    if not c.socket.isNil:
      inc result

proc emitConnectionDisconnection(target: WebSocket; reason: cstring;
                                  message: cstring) =
  ## Tell the page on `target` why its connection is no longer served
  ## (`CODETRACER::connection-disconnected`, ADR 0007).
  if target.isNil:
    return
  var payload = newJsObject()
  payload["reason"] = reason
  if message.len > 0:
    payload["message"] = message
  target.emit(cstring"CODETRACER::connection-disconnected", jsonStringify(payload))

proc disconnectAll*(hc: HostClients; reason: cstring; message: cstring) =
  ## Tell every client's page the server is going away.
  for c in hc.clients.values:
    emitConnectionDisconnection(c.socket, reason, message)

proc cacheable(id: cstring; key: cstring): bool =
  id in bootstrapEvents or (id == DapEventChannel and key.len > 0)

proc remember(cache: var seq[BootstrapPayload]; id, key, payload: cstring) =
  if cacheable(id, key):
    upsertBootstrap(cache, BootstrapPayload(id: id, key: key, payload: payload))

proc forget(cache: var seq[BootstrapPayload]; id: cstring) =
  for i in countdown(cache.high, 0):
    if cache[i].id == id:
      cache.delete(i)

proc primaryIdFor(replayId: int): string =
  ## The id of the server's session over `replayId` on the shared host.
  ## Named by the replay, not the client, so a page learns nothing about
  ## other clients from the ids it is told.
  "ct-host/replay-" & $replayId

proc closePrimary(c: HostClient) =
  if not c.primary.isNil:
    c.primary.close()
    c.primary = nil

proc bindReplay(hc: HostClients; c: HostClient; replayId: int;
                channel: cstring; selection: JsObject) =
  ## `replayId` is `c`'s replay from now on: its page is told so, its
  ## requests go there, and the server's session for it follows that replay.
  let previous = c.replayId
  c.replayId = replayId
  if replayId notin c.replays:
    c.replays.add replayId
  hc.owners[replayId] = c
  selection["replayId"] = replayId
  let serialized = jsonStringify(selection)
  if previous != replayId:
    # A cached move of the replay it held is not a position of this one.
    c.bootstrap.forget(DapEventChannel)
  for other in SelectionChannels:
    c.bootstrap.forget(other)
  c.bootstrap.remember(channel, cstring"", serialized)
  if not c.socket.isNil:
    c.socket.emit(channel, serialized)
  # The server's own session over the replay, which the page mirrors.
  if previous != replayId or c.primary.isNil:
    c.closePrimary()
    let trace = selection["trace"]
    let folder =
      if trace.isNil or trace.isUndefined or trace["outputFolder"].isUndefined or
         trace["outputFolder"].isNil: ""
      else: $trace["outputFolder"].to(cstring)
    if folder.len > 0:
      c.primary = openHostedSession(hc.sessions, primaryIdFor(replayId),
                                    replayId, folder)
      if not c.socket.isNil:
        c.primary.connectPage(c.socket.toJs)
  infoPrint "ct host: client ", c.id, " replays ", $replayId

proc allocate(hc: HostClients; c: HostClient) =
  ## Give `c` a replay of its own, once the trace is known.
  if c.replayId >= 0 or c.allocating or hc.selection.isNil:
    return
  let selectionCopy = jsonParse(jsonStringify(hc.selection))
  if hc.spareReplay >= 0:
    let replayId = hc.spareReplay
    hc.spareReplay = -1
    hc.bindReplay(c, replayId, hc.selectionChannel, selectionCopy)
    return
  if hc.startReplay.isNil:
    warnPrint "ct host: no way to start a replay for client ", c.id
    return
  c.allocating = true
  let start = hc.startReplay
  proc run() {.async.} =
    let replayId = await start()
    c.allocating = false
    if replayId < 0:
      errorPrint "ct host: could not start a replay for client ", c.id
      return
    if hc.clients.getOrDefault(c.id) != c:
      # Released while its replay was starting.
      if not hc.stopReplay.isNil:
        hc.stopReplay(replayId)
      return
    hc.bindReplay(c, replayId, hc.selectionChannel, selectionCopy)
  discard run()

proc onSelection(hc: HostClients; c: HostClient; channel: cstring;
                 payload: cstring) =
  let selection = jsonParse(payload)
  let replayIdNode = selection["replayId"]
  if replayIdNode.isNil or replayIdNode.isUndefined:
    warnPrint "ct host: a replay selection without a replay id: ", payload
    return
  let replayId = replayIdNode.to(int)
  if not c.isNil:
    # A client's own request opened a replay (a trace it loaded, a restart).
    hc.bindReplay(c, replayId, channel, selection)
    return
  # The server's startup opened the trace it serves: the first client waiting
  # takes that replay, and every other one waiting gets its own.
  hc.selection = jsonParse(payload)
  hc.selectionChannel = channel
  var taker: HostClient = nil
  for waiting in hc.clients.values:
    if waiting.replayId < 0 and not waiting.allocating and
       not waiting.socket.isNil:
      taker = waiting
      break
  if taker.isNil:
    hc.spareReplay = replayId
  else:
    hc.bindReplay(taker, replayId, channel, selection)
  for waiting in hc.clients.values:
    if not waiting.socket.isNil:
      hc.allocate(waiting)

proc deliver(hc: HostClients; id: cstring; key: cstring; payload: cstring) =
  ## Send what the index says (`ipc.route`): to the client being served, or,
  ## outside every client's context, to every client.
  let c = hc.current()
  if id in SelectionChannels:
    hc.onSelection(c, id, payload)
    return
  if c.isNil:
    hc.shared.remember(id, key, payload)
    for each in hc.clients.values:
      if not each.socket.isNil:
        each.socket.emit(id, payload)
  else:
    c.bootstrap.remember(id, key, payload)
    if not c.socket.isNil:
      c.socket.emit(id, payload)

proc deliverDap(hc: HostClients; replayId: int; channel: cstring;
                body: JsObject) =
  ## A replay's answer or event, to the client that owns the replay, under
  ## the session number its page uses.
  let owner = hc.owners.getOrDefault(replayId)
  if owner.isNil:
    debugPrint "ct host: dropped a message of replay ", $replayId,
      ", which is no client's"
    return
  if owner.replayId != replayId:
    # A replay the client held before (it loaded another trace since): its
    # page numbers only its CURRENT replay, 0, so this would be shown as that
    # one's. The replay itself is kept until the client is released.
    debugPrint "ct host: dropped a message of replay ", $replayId,
      ", no longer client ", owner.id, "'s current one"
    return
  let forPage = jsAssign(newJsObject(), body)
  forPage["sessionId"] = PageSessionId
  runAsClient(owner.toJs, proc() =
    mainWindow.webContents.send(channel, forPage))

proc requestSession(hc: HostClients; pageSessionId: int): int =
  let c = hc.current()
  if c.isNil:
    # Not a page's request: the server's own code names the replay itself.
    pageSessionId
  else:
    c.replayId

proc mayStopReplay*(hc: HostClients; replayId: int): bool =
  ## A client may stop its own replays only; the server itself, any.
  let c = hc.current()
  c.isNil or replayId in c.replays

proc forgetStoppedReplay*(hc: HostClients; replayId: int) =
  ## `replayId` was stopped at a client's request (the toolbar's Stop).
  let owner = hc.owners.getOrDefault(replayId)
  if owner.isNil:
    return
  hc.owners.del(replayId)
  let i = owner.replays.find(replayId)
  if i >= 0:
    owner.replays.delete(i)
  if owner.replayId == replayId:
    owner.replayId = -1
    owner.closePrimary()
    for channel in SelectionChannels:
      owner.bootstrap.forget(channel)
    owner.bootstrap.forget(DapEventChannel)

proc installRouting*(hc: HostClients) =
  ## Route the index's sends and the replays' messages per client.
  let h = hc
  hc.ipc.route = proc(id: cstring; key: cstring; payload: cstring) =
    h.deliver(id, key, payload)
  installServerSessionRouting(ServerSessionRouting(
    requestSession: proc(pageSessionId: int): int =
      h.requestSession(pageSessionId),
    deliver: proc(sessionId: int; channel: cstring; body: JsObject) =
      h.deliverDap(sessionId, channel, body)))

proc dropSocket(hc: HostClients; c: HostClient; socket: WebSocket) =
  hc.ipc.removeClientSocket(socket)
  if not c.primary.isNil:
    c.primary.disconnectPage(socket.toJs)

proc connect*(hc: HostClients; socket: WebSocket; rawClientId: string): HostClient =
  ## Serve `socket` as the client its page names (`rawClientId`), or as a new
  ## client when it names none. Its page is sent what it missed: what the
  ## index said to every client and what it said to this one.
  var id = normalizeClientId(rawClientId)
  if id.len == 0:
    # Not resumable: the page did not name itself.
    id = "anonymous-" & $randomUuid()
  var c = hc.clients.getOrDefault(id)
  if c.isNil:
    c = HostClient(id: id, replayId: -1)
    hc.clients[id] = c
    infoPrint "ct host: client ", id, " connected (", $hc.clients.len, " clients)"
  elif not c.socket.isNil and c.socket != socket:
    emitConnectionDisconnection(c.socket, cstring"superseded",
      cstring"This session was opened in another tab.")
    hc.dropSocket(c, c.socket)
    infoPrint "ct host: client ", id, " reconnected; its previous socket is superseded"
  else:
    infoPrint "ct host: client ", id, " reconnected"
  c.socket = socket
  c.goneSinceMs = 0
  let store = c.toJs
  hc.ipc.addClientSocket(socket, proc(handler: JsObject): JsObject =
    wrapAsClient(store, handler))
  # What it missed: the shared messages, with its own in their place where
  # both carry one.
  var missed = hc.shared
  for own in c.bootstrap:
    upsertBootstrap(missed, own)
  replayBootstrap(missed, proc(event: cstring; payload: cstring) =
    socket.emit(event, payload))
  if not c.primary.isNil:
    c.primary.connectPage(socket.toJs)
  hc.allocate(c)
  c

proc disconnect*(hc: HostClients; socket: WebSocket) =
  ## `socket` closed. Its client keeps its replay and session for its next
  ## socket (`releaseGone`).
  for c in hc.clients.values:
    if c.socket == socket:
      c.socket = nil
      c.goneSinceMs = nowMs()
      hc.dropSocket(c, socket)
      infoPrint "ct host: client ", c.id, " disconnected"

proc release(hc: HostClients; c: HostClient) =
  c.closePrimary()
  for replayId in c.replays:
    hc.owners.del(replayId)
    if not hc.stopReplay.isNil:
      hc.stopReplay(replayId)
  c.replays = @[]
  c.replayId = -1
  hc.clients.del(c.id)
  infoPrint "ct host: released client ", c.id, " (", $hc.clients.len, " clients)"

proc releaseGone*(hc: HostClients; now: float) =
  ## Release every client that has had no socket for `releaseAfterMs`.
  if hc.releaseAfterMs < 0:
    return
  var gone: seq[HostClient] = @[]
  for c in hc.clients.values:
    if c.socket.isNil and c.goneSinceMs > 0 and
       now - c.goneSinceMs >= hc.releaseAfterMs.float:
      gone.add c
  for c in gone:
    hc.release(c)
