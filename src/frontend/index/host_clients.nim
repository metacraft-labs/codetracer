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
## * a replay and a session of their own for each further replay tab of its
##   page (below);
## * its own share of what the index says: an answer to a request goes to the
##   client that asked, a replay's answers and events go to the client that
##   owns the replay, and what the index says to no one in particular (the
##   startup's `init`, the trace it loaded) goes to every client;
## * its own reconnect bootstrap, so a reload of that tab resumes ITS replay
##   at ITS position (`bootstrap_cache`, ADR 0006).
##
## ONE SESSION PER REPLAY TAB (Shared-DOM-Front-Ends D2, owner decision
## 2026-10-30). A page's session tabs are independent sessions, so each of a
## client's replay tabs (`HostTab`) has its own replay and its own server
## session, all over the client's one socket. They are told apart by the tab
## id the page already puts on its messages: a DAP request's `sessionId` names
## the tab whose replay it runs on (`requestSession`), a replay's answers and
## events go back stamped with the tab that owns the replay (`deliverDap`), a
## replay selection names the tab that asked for it (`tab`, `onSelection`),
## and each tab's mirror has its own channel on the socket
## (`socket_transport.sessionSyncEventFor`). The page's first tab, id 0
## (`FirstTab`), holds the client's startup replay; a later tab gets a replay
## when a trace is opened in it. Closing a tab stops its replay
## (`CODETRACER::close-replay-session`), which closes its session
## (`forgetStoppedReplay`).
##
## Only the first tab's messages are kept for the client's next socket: a
## reloaded page rebuilds its first tab alone, so another tab's selection or
## position would be replayed into a tab that no longer exists. For the same
## reason a reload releases the client's other tabs. The page names its
## document in the handshake (`ct_page`, one random id per page load): a known
## client presenting another document has reloaded, and its tabs other than
## the first are released; the same document is a reconnect of the same page
## (a network blip), which keeps them all.
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
  PageIdParameter* = "ct_page"
    ## The socket handshake query parameter that names the page document
    ## (one per page load), which tells a reload from a reconnect.
  MaxClientIdLength = 64
  FirstTab = 0
    ## The tab id of a page's first tab (`types.allocateSessionId`): the tab
    ## that holds the client's startup replay and that a reload rebuilds.
  SelectionChannels = [cstring"CODETRACER::dap-replay-selected",
                       cstring"CODETRACER::dap-live-session-selected"]
    ## The messages that hand a page its replay: always one client's.
  DapEventChannel = cstring"CODETRACER::dap-receive-event"
  TraceLoadErrorChannel = cstring"CODETRACER::trace-load-error"
    ## How a page learns its session could not be opened.
  TraceLoadedChannel = cstring"CODETRACER::trace-loaded"

type
  HostTab = ref object
    ## One replay tab of a client's page and the server session behind it.
    tab: int
      ## The page's id for the tab (`DapApi.sessionId`, the `tab` of its
      ## loads).
    replayId: int
      ## Its current replay; -1 while it has none.
    primary: HostedPrimary
      ## The server's session over `replayId`, which the tab mirrors.

  HostClient* = ref object
    id: string
    socket: WebSocket
      ## The socket serving it now; nil while it has none.
    pageId: string
      ## The page document its last socket named (`ct_page`); "" when none
      ## did.
    tabs: seq[HostTab]
      ## Its page's replay tabs, each added when it first gets a replay.
    replays: seq[int]
      ## Every replay started for it, stopped when it is released.
    allocating: bool
    bootstrap: seq[BootstrapPayload]
      ## What the index said to this client alone, for its next socket.
    goneSinceMs: float
      ## When its last socket closed; 0 while it has one.

  ReplayStarter* = proc(): Future[ReplayStart]
    ## Start a replay process; resolves with its id, or -1 and why not.
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
proc jsTypeOf(o: JsObject): cstring {.importjs: "(typeof #)".}
proc jsAssign(target, source: JsObject): JsObject {.importjs: "Object.assign(#, #)".}
proc randomUuid(): cstring {.importjs: "require('crypto').randomUUID()".}
proc nowMs(): float {.importjs: "Date.now()".}

proc newHostClients*(ipc: FrontendIPC; releaseAfterMs: int): HostClients =
  HostClients(ipc: ipc,
              clients: initOrderedTable[string, HostClient](),
              owners: initTable[int, HostClient](),
              spareReplay: -1, sessions: newHostedSessions(),
              releaseAfterMs: releaseAfterMs)

proc tabOf(c: HostClient; tab: int): HostTab =
  ## `c`'s tab `tab`, or nil when it has none.
  for t in c.tabs:
    if t.tab == tab:
      return t
  nil

proc ensureTab(c: HostClient; tab: int): HostTab =
  ## `c`'s tab `tab`, created without a replay when it has none.
  result = c.tabOf(tab)
  if result.isNil:
    result = HostTab(tab: tab, replayId: -1)
    c.tabs.add result

proc tabOfReplay(c: HostClient; replayId: int): HostTab =
  ## The tab of `c` whose CURRENT replay is `replayId`, or nil.
  if replayId < 0:
    return nil
  for t in c.tabs:
    if t.replayId == replayId:
      return t
  nil

proc firstReplay(c: HostClient): int =
  ## The replay of `c`'s first tab; -1 while it has none.
  let t = c.tabOf(FirstTab)
  if t.isNil: -1 else: t.replayId

proc tabIdOf(payload: JsObject): int =
  ## The tab a message names (`tab`, or a DAP message's `sessionId`), or
  ## `FirstTab` when it names none: a message no tab claims is the
  ## single-tab page's.
  if payload.isNil or payload.isUndefined or payload.isNull:
    return FirstTab
  for field in [cstring"tab", cstring"sessionId"]:
    let value = payload[field]
    if not value.isNil and not value.isUndefined and not value.isNull and
       jsTypeOf(value) == cstring"number":
      return value.to(int)
  FirstTab

proc forFirstTab(payload: cstring): bool =
  ## Whether the serialized message `payload` is for the page's first tab
  ## (or names none). One that does not parse is taken to be: it is kept as
  ## it always was.
  var parsed: JsObject
  try:
    parsed = jsonParse(payload)
  except:
    # Bare `except:`: `JSON.parse` throws V8's own `SyntaxError`.
    return true
  tabIdOf(parsed) == FirstTab

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

proc forget(cache: var seq[BootstrapPayload]; id: cstring) =
  for i in countdown(cache.high, 0):
    if cache[i].id == id:
      cache.delete(i)

proc remember(cache: var seq[BootstrapPayload]; id, key, payload: cstring) =
  if cacheable(id, key):
    # A trace that loaded supersedes the error of a load that did not: a
    # reconnecting page must not be told its working session failed.
    if id == TraceLoadedChannel:
      cache.forget(TraceLoadErrorChannel)
    upsertBootstrap(cache, BootstrapPayload(id: id, key: key, payload: payload))

proc primaryIdFor(replayId: int): string =
  ## The id of the server's session over `replayId` on the shared host.
  ## Named by the replay, not the client, so a page learns nothing about
  ## other clients from the ids it is told.
  "ct-host/replay-" & $replayId

proc closePrimary(t: HostTab) =
  if not t.primary.isNil:
    t.primary.close()
    t.primary = nil

proc bindReplay(hc: HostClients; c: HostClient; tab: int; replayId: int;
                channel: cstring; selection: JsObject) =
  ## `replayId` is the replay of `c`'s tab `tab` from now on: its page is told
  ## so, the tab's requests go there, and the server's session for the tab
  ## follows that replay.
  let t = c.ensureTab(tab)
  let previous = t.replayId
  t.replayId = replayId
  if replayId notin c.replays:
    c.replays.add replayId
  hc.owners[replayId] = c
  selection["replayId"] = replayId
  let serialized = jsonStringify(selection)
  if tab == FirstTab:
    # Kept for the client's next socket: a reload rebuilds this tab.
    if previous != replayId:
      # A cached move of the replay it held is not a position of this one.
      c.bootstrap.forget(DapEventChannel)
    for other in SelectionChannels:
      c.bootstrap.forget(other)
    c.bootstrap.remember(channel, cstring"", serialized)
  if not c.socket.isNil:
    c.socket.emit(channel, serialized)
  # The server's own session over the replay, which the tab mirrors.
  if previous != replayId or t.primary.isNil:
    t.closePrimary()
    let trace = selection["trace"]
    let folder =
      if trace.isNil or trace.isUndefined or trace["outputFolder"].isUndefined or
         trace["outputFolder"].isNil: ""
      else: $trace["outputFolder"].to(cstring)
    if folder.len > 0:
      t.primary = openHostedSession(hc.sessions, primaryIdFor(replayId),
                                    replayId, folder)
      if not c.socket.isNil:
        t.primary.connectPage(c.socket.toJs, tab)
  infoPrint "ct host: client ", c.id, " tab ", $tab, " replays ", $replayId

proc allocate(hc: HostClients; c: HostClient) =
  ## Give `c`'s first tab a replay of its own, once the trace is known.
  if c.firstReplay >= 0 or c.allocating or hc.selection.isNil:
    return
  let selectionCopy = jsonParse(jsonStringify(hc.selection))
  if hc.spareReplay >= 0:
    let replayId = hc.spareReplay
    hc.spareReplay = -1
    hc.bindReplay(c, FirstTab, replayId, hc.selectionChannel, selectionCopy)
    return
  if hc.startReplay.isNil:
    warnPrint "ct host: no way to start a replay for client ", c.id
    return
  c.allocating = true
  let start = hc.startReplay
  proc run() {.async.} =
    let started = await start()
    let replayId = started.replayId
    c.allocating = false
    if replayId < 0:
      # The page is waiting for its replay: tell it why there is none, as a
      # failed load (`CODETRACER::trace-load-error`), and keep that for its
      # next socket, rather than leave it drawing panes over no backend.
      errorPrint "ct host: could not start a replay for client ", c.id, ": ",
        started.error
      var payload = newJsObject()
      payload["error"] = cstring("Could not start a replay: " & $started.error)
      let serialized = jsonStringify(payload)
      c.bootstrap.remember(TraceLoadErrorChannel, cstring"", serialized)
      if not c.socket.isNil:
        c.socket.emit(TraceLoadErrorChannel, serialized)
      return
    if hc.clients.getOrDefault(c.id) != c:
      # Released while its replay was starting.
      if not hc.stopReplay.isNil:
        hc.stopReplay(replayId)
      return
    hc.bindReplay(c, FirstTab, replayId, hc.selectionChannel, selectionCopy)
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
    # A client's own request opened a replay (a trace it loaded, a restart),
    # for the tab that asked: a "+" tab's load gives THAT tab a replay and a
    # session of its own, beside the others.
    hc.bindReplay(c, tabIdOf(selection), replayId, channel, selection)
    return
  # The server's startup opened the trace it serves: the first client waiting
  # takes that replay, and every other one waiting gets its own.
  hc.selection = jsonParse(payload)
  hc.selectionChannel = channel
  var taker: HostClient = nil
  for waiting in hc.clients.values:
    if waiting.firstReplay < 0 and not waiting.allocating and
       not waiting.socket.isNil:
      taker = waiting
      break
  if taker.isNil:
    hc.spareReplay = replayId
  else:
    hc.bindReplay(taker, FirstTab, replayId, channel, selection)
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
    # Only the first tab's are kept for the next socket: a reloaded page has
    # no other tab to give them to (module doc).
    if cacheable(id, key) and forFirstTab(payload):
      c.bootstrap.remember(id, key, payload)
    if not c.socket.isNil:
      c.socket.emit(id, payload)

proc deliverDap(hc: HostClients; replayId: int; channel: cstring;
                body: JsObject) =
  ## A replay's answer or event, to the client that owns the replay, under
  ## the tab id of the page's tab whose replay it is.
  let owner = hc.owners.getOrDefault(replayId)
  if owner.isNil:
    debugPrint "ct host: dropped a message of replay ", $replayId,
      ", which is no client's"
    return
  let t = owner.tabOfReplay(replayId)
  if t.isNil:
    # A replay a tab held before (it loaded another trace since): the page
    # knows a tab only by its CURRENT replay, so this would be shown as that
    # one's. The replay itself is kept until the client is released.
    debugPrint "ct host: dropped a message of replay ", $replayId,
      ", no tab of client ", owner.id, " holds it now"
    return
  let forPage = jsAssign(newJsObject(), body)
  forPage["sessionId"] = t.tab
  runAsClient(owner.toJs, proc() =
    mainWindow.webContents.send(channel, forPage))

proc requestSession(hc: HostClients; pageSessionId: int): int =
  ## The replay a request of the page's tab `pageSessionId` runs on: that
  ## tab's own, or -1 (dropped) while it has none.
  let c = hc.current()
  if c.isNil:
    # Not a page's request: the server's own code names the replay itself.
    return pageSessionId
  let t = c.tabOf(pageSessionId)
  if t.isNil: -1 else: t.replayId

proc mayStopReplay*(hc: HostClients; replayId: int): bool =
  ## A client may stop its own replays only; the server itself, any.
  let c = hc.current()
  c.isNil or replayId in c.replays

proc forgetStoppedReplay*(hc: HostClients; replayId: int) =
  ## `replayId` was stopped at a client's request: the toolbar's Stop, or its
  ## tab was closed. The tab's session is closed with it; a tab other than
  ## the first is forgotten, and gets a new entry if it runs again.
  let owner = hc.owners.getOrDefault(replayId)
  if owner.isNil:
    return
  hc.owners.del(replayId)
  let i = owner.replays.find(replayId)
  if i >= 0:
    owner.replays.delete(i)
  let t = owner.tabOfReplay(replayId)
  if t.isNil:
    return
  t.replayId = -1
  t.closePrimary()
  infoPrint "ct host: client ", owner.id, " closed the session of tab ",
    $t.tab, " (replay ", $replayId, ")"
  if t.tab == FirstTab:
    for channel in SelectionChannels:
      owner.bootstrap.forget(channel)
    owner.bootstrap.forget(DapEventChannel)
  else:
    owner.tabs.delete(owner.tabs.find(t))

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
  for t in c.tabs:
    if not t.primary.isNil:
      t.primary.disconnectPage(socket.toJs)

proc releaseLaterTabs(hc: HostClients; c: HostClient) =
  ## Close the sessions of `c`'s tabs other than the first, and stop their
  ## replays: its page reloaded, and a reloaded page has its first tab only.
  var kept: seq[HostTab] = @[]
  for t in c.tabs:
    if t.tab == FirstTab:
      kept.add t
      continue
    t.closePrimary()
    if t.replayId >= 0:
      hc.owners.del(t.replayId)
      let i = c.replays.find(t.replayId)
      if i >= 0:
        c.replays.delete(i)
      if not hc.stopReplay.isNil:
        hc.stopReplay(t.replayId)
    infoPrint "ct host: client ", c.id, " reloaded; released the session of tab ",
      $t.tab, " (replay ", $t.replayId, ")"
  c.tabs = kept

proc connect*(hc: HostClients; socket: WebSocket; rawClientId: string;
              rawPageId = ""): HostClient =
  ## Serve `socket` as the client its page names (`rawClientId`), or as a new
  ## client when it names none. Its page is sent what it missed: what the
  ## index said to every client and what it said to this one. `rawPageId` is
  ## the page document the socket names (`ct_page`): another document than
  ## the client's last one is a reload, which keeps only the first tab.
  var id = normalizeClientId(rawClientId)
  let pageId = normalizeClientId(rawPageId)
  if id.len == 0:
    # Not resumable: the page did not name itself.
    id = "anonymous-" & $randomUuid()
  var c = hc.clients.getOrDefault(id)
  if c.isNil:
    c = HostClient(id: id)
    hc.clients[id] = c
    infoPrint "ct host: client ", id, " connected (", $hc.clients.len, " clients)"
  elif not c.socket.isNil and c.socket != socket:
    emitConnectionDisconnection(c.socket, cstring"superseded",
      cstring"This session was opened in another tab.")
    hc.dropSocket(c, c.socket)
    infoPrint "ct host: client ", id, " reconnected; its previous socket is superseded"
  else:
    infoPrint "ct host: client ", id, " reconnected"
  if pageId.len > 0:
    if c.pageId.len > 0 and c.pageId != pageId:
      hc.releaseLaterTabs(c)
    c.pageId = pageId
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
  for t in c.tabs:
    if not t.primary.isNil:
      t.primary.connectPage(socket.toJs, t.tab)
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
  for t in c.tabs:
    t.closePrimary()
  c.tabs = @[]
  for replayId in c.replays:
    hc.owners.del(replayId)
    if not hc.stopReplay.isNil:
      hc.stopReplay(replayId)
  c.replays = @[]
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
