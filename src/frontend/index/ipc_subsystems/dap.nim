import
  std / [ async, jsffi, json, strformat, strutils, tables ],
  ../../[ types, config ],
  ../../lib/[ jslib ],
  ../../../common/ct_logging,
  ../electron_vars

type
  RawDapMessage* = ref object
    raw*: cstring

var backendManagerSocket*: JsObject = nil
var replayStartHandler*: proc(body: JsObject) = nil

# --- M9: DAP multiplexing state ---
#
# The Backend Manager serves one "selected" replay at a time.  When the
# main process forwards a DAP request, it must first tell the BM to select
# the request's replay via `ct/select-replay`.  Responses are then tagged
# with the originating sessionId so the renderer can route them to the
# correct ReplaySession.
#
# TWO NUMBERS, KEPT APART. A request names the renderer TAB it comes from
# (`sessionId`, the tab's `ReplaySession.id`) and, on the desktop, the REPLAY
# that tab talks to (`replayId`, stamped by the renderer's
# `dap.stampReplay`). The replay is what `ct/select-replay` takes; the tab is
# who the answer and the events are for. They are different counters: the
# Backend Manager numbers replays in the order it starts them and never
# reuses one (`backend_manager.rs` `start_replay_raw`; a refused start
# consumes one too), and the window numbers its tabs. Selecting by the tab's
# id — which this router did — ran a tab's requests on another tab's replay
# as soon as the two parted: after Stop and a new run in one tab, a refused
# start, or a "+" tab left on the Welcome Screen while a later one loaded
# (codetracer-pm
# `issues/2026-10-23-a-tab-opened-after-closing-a-middle-tab-reuses-a-live-tabs-session-id.md`,
# `GUI/Multi-Window-Tab-Management.md` §Tab Behavior rule 8). In `ct host`'s
# server a session IS its replay (`ServerSessionRouting` below), so there the
# two are one number by construction.

var selectedReplay = 0
  ## The replay the Backend Manager is serving, as exactly as this process
  ## can know it: set by every `ct/select-replay` written — by `selectReplay`
  ## and by the trace loader (`noteReplaySelected`) — and `-1` after a
  ## `ct/stop-replay` (`noteReplayStopped`), which leaves it serving none.
  ## 0 at start: the Backend Manager's own initial selection.

var servedSession = 0
  ## The session of the last request forwarded: who an event that names no
  ## replay of a known owner is attributed to (`resolveSessionId`).

var replayOwners: Table[int, int] = initTable[int, int]()
  ## Desktop: replay id -> the tab that owns it, learned from the requests
  ## that name it (a tab names only its own replay) and forgotten when the
  ## replay is stopped. Says which tab an event of a replay is for.

type
  PendingDapRequest = object
    ## A request forwarded to the Backend Manager and not yet answered: the
    ## session that issued it and the `seq` that session numbered it with.
    sessionId: int
    seq: int

var pendingRequests: Table[int, PendingDapRequest] =
    initTable[int, PendingDapRequest]()
  ## Every forwarded request, keyed by the WIRE `seq` this process gave it
  ## (`nextWireSeq`), holding the `(sessionId, seq)` pair that names it.
  ## Populated when forwarding a request; consumed when the matching
  ## response arrives (keyed by its `request_seq`, which the backend echoes).
  ##
  ## The key is the wire `seq` and NOT the renderer's own, because each
  ## session's `DapApi` numbers its requests from zero: two sessions with a
  ## request of the same `seq` in flight are routine, and the backend's
  ## answer carries nothing but that number. A table keyed by the renderer's
  ## `seq` alone let the second request overwrite the first's entry, so one
  ## answer was tagged with the other session and the other fell through to
  ## whichever session the Backend Manager happened to be serving. Giving
  ## every forwarded request a number unique across sessions makes the
  ## answer name its `(sessionId, seq)` pair exactly; the renderer's `seq`
  ## is written back into `request_seq` before the answer is delivered, so
  ## the renderer sees the number it sent.

var wireSeqCounter = 100_000
  ## The wire `seq` of every request this process writes to the Backend
  ## Manager — the forwarded ones and its own `ct/select-replay`. One
  ## counter, so no two requests in flight share a number.

proc nextWireSeq(): int =
  inc wireSeqCounter
  return wireSeqCounter

# --- Server-side DAP clients ---
#
# A server that owns a session for a remote page (`ct host`) talks to the
# Backend Manager itself, beside the page, over the same multiplexed
# connection. Its requests carry their own wire `seq`, and their answers go
# back to it alone: the page never asked them, and fanning them out would hand
# the page responses to questions it does not recognise. Events, which carry
# no request identity, go to the page AND to the session's local listeners.

type
  LocalDapResponseHandler* = proc(response: JsObject)
  LocalDapEventListener* = proc(event: JsObject)

var localResponseHandlers: Table[int, LocalDapResponseHandler] =
    initTable[int, LocalDapResponseHandler]()
  ## Keyed by the wire `seq` of a request a server-side client sent.

var localEventListeners: Table[int, seq[LocalDapEventListener]] =
    initTable[int, seq[LocalDapEventListener]]()
  ## Keyed by the session whose events the listener receives.

type
  ReplayStart* = object
    ## The Backend Manager's answer to one `ct/start-replay`.
    replayId*: int
      ## The replay it started; -1 when it started none.
    error*: cstring
      ## Why it started none (the answer's `message`: a socket path too long
      ## to bind, a command that could not run, the session limit), for the
      ## user; empty when it started one.

proc registerStartReplayHandler*(handler: proc(body: JsObject)) =
  replayStartHandler = handler

# --- Per-client routing in the server (`ct host`) ---
#
# `ct host` gives every connected client a replay of its own
# (`CLI/ct/host.md`, "Sessions are isolated"; `index/host_clients`). There a
# DAP session IS a replay — its id is the id `ct/start-replay` answered with —
# while a page numbers its sessions by its own tab ids (its first tab 0, each
# replay tab its own: Shared-DOM-Front-Ends D2). So the server decides two
# things the desktop's window table decides here: which replay a page tab's
# request is for, and which client and tab an answer or event of a replay
# goes to. The desktop installs nothing and keeps its routing.

type
  ServerSessionRouting* = ref object
    requestSession*: proc(pageSessionId: int): int
      ## The replay a page's request for its tab `pageSessionId` is for,
      ## decided for the client the request came from; negative drops the
      ## request (that tab has no replay).
    deliver*: proc(sessionId: int; channel: cstring; body: JsObject)
      ## Hand a replay's answer or event to the client and tab that own the
      ## replay.

var serverRouting: ServerSessionRouting = nil

const ReplayIdTag = cstring"ctReplayId"
  ## The field the Backend Manager adds to every message a replay sends,
  ## naming the replay (`backend_manager.rs`, `REPLAY_ID_TAG`).

proc installServerSessionRouting*(routing: ServerSessionRouting) =
  ## Route by replay, for the server's clients, from now on.
  serverRouting = routing

proc stringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc jsHasKey(obj: JsObject; key: cstring): bool {.importjs: "#.hasOwnProperty(#)".}
proc jsAssign(target, source: JsObject): JsObject {.importjs: "Object.assign(#, #)".}

proc wrapJsonForSending*(obj: JsObject): cstring =
    let stringified_packet = stringify(obj)
    let len = len(stringified_packet)
    let header = &"Content-Length: {len}\r\n\r\n"
    let res = header.cstring & stringified_packet
    # echo cstring"dap: ", res.cstring
    return res.cstring

proc getSessionId*(body: JsObject): int =
  ## Extract sessionId from an IPC message body.
  ## Returns 0 (default session) when the field is absent.
  ## This is the main-process counterpart used during M8 (session-scoped IPC).
  if jsHasKey(body, cstring"sessionId"):
    return body["sessionId"].to(int)
  return 0

proc getReplayId*(body: JsObject): int =
  ## The replay a request from the renderer names (`replayId`, stamped by
  ## `dap.stampReplay`), or -1 when it names none: its tab has no replay yet,
  ## or no longer has one.
  if jsHasKey(body, cstring"replayId"):
    let replayId = body["replayId"].to(int)
    return if replayId >= 0: replayId else: -1
  return -1

proc selectReplay(replayId: int) =
  ## Point the Backend Manager at replay `replayId`, when it is serving
  ## another one (or none).
  ##
  ## The decision is keyed solely on the target replay vs the one the BM is
  ## serving. Earlier code special-cased session 0 and skipped the switch,
  ## which mis-targeted the default session whenever another had been
  ## selected (issue #327): the routing is symmetric. And it is keyed on the
  ## REPLAY, never on the tab a request came from (see the state above).
  if replayId != selectedReplay:
    backendManagerSocket.write(wrapJsonForSending(js{
      "type": cstring"request",
      "command": cstring"ct/select-replay",
      "arguments": replayId,
      "seq": nextWireSeq()
    }))
    selectedReplay = replayId

proc noteReplaySelected*(replayId: int) =
  ## A `ct/select-replay` for `replayId` was written to the Backend Manager
  ## OUTSIDE `selectReplay` (`traces.startReplayForTrace`,
  ## `prepareForLiveTrace`).
  ##
  ## The router must know the Backend Manager now serves `replayId`: left
  ## stale, the next request of the replay it believed selected skips its
  ## switch and runs on this one — another tab's, or in the server another
  ## client's. Recorded on the desktop too: it once was not, on the grounds
  ## that the window's tab 0 "talks to whichever replay was selected last",
  ## and then tab 0's next request after a later tab's replay started ran on
  ## that later tab's replay.
  selectedReplay = replayId

proc noteReplayStopped*(replayId: int) =
  ## `replayId` was stopped (`ct/stop-replay`); the Backend Manager then
  ## serves no replay, WHICHEVER replay it was serving: its `stop_replay`
  ## clears the selection unconditionally (`backend_manager.rs`). So the next
  ## request of any replay must select it again — left at the replay it
  ## believed selected, the router would skip that switch when another
  ## replay is stopped (a tab closed, a client released) and the request
  ## would reach no replay. Its id is never served again (the Backend Manager
  ## does not reuse one), so it has no owner any more.
  selectedReplay = -1
  replayOwners.del(replayId)

proc forwardRequest(sessionId: int; replayId: int; message: JsObject) =
  ## Forward `message`, a request of `sessionId`, to the Backend Manager,
  ## having selected `replayId` first (`selectReplay`).
  selectReplay(replayId)
  servedSession = sessionId

  # Track which session owns this request so the response can be tagged:
  # the frame goes out under a wire `seq` unique across sessions, recorded
  # with the `(sessionId, seq)` pair it stands for (see `pendingRequests`).
  var frame = message
  if jsHasKey(message, cstring"seq"):
    let wireSeq = nextWireSeq()
    pendingRequests[wireSeq] = PendingDapRequest(
      sessionId: sessionId, seq: message["seq"].to(int))
    frame = jsAssign(newJsObject(), message)
    frame["seq"] = wireSeq

  backendManagerSocket.write(wrapJsonForSending(frame))

proc sendDapForSession*(sessionId: int; replayId: int; message: JsObject) =
  ## Forward a DAP request of `sessionId` to the Backend Manager, on replay
  ## `replayId`.  If the BM is currently serving a different replay, a
  ## `ct/select-replay` command is sent first to switch contexts.
  if backendManagerSocket.isNil:
    errorPrint "backend socket is nil, couldn't send DAP for session ",
      sessionId, ": ", message.toJs
    return
  forwardRequest(sessionId, replayId, message)

proc sendLocalDapRequest*(sessionId: int; command: cstring;
                          arguments: JsObject;
                          onResponse: LocalDapResponseHandler): bool =
  ## Send a DAP request for `sessionId` on behalf of a server-side client;
  ## `onResponse` receives the whole DAP response. `false` when there is no
  ## Backend Manager connection to send on. Server-side only, where a
  ## session is its replay: `sessionId` is the replay selected.
  if backendManagerSocket.isNil:
    return false
  selectReplay(sessionId)
  let wireSeq = nextWireSeq()
  localResponseHandlers[wireSeq] = onResponse
  backendManagerSocket.write(wrapJsonForSending(js{
    "type": cstring"request",
    "command": command,
    "arguments": arguments,
    "seq": wireSeq
  }))
  true

proc addLocalDapEventListener*(sessionId: int;
                               listener: LocalDapEventListener): proc() =
  ## Receive every DAP event of `sessionId`. Returns the proc that stops it.
  if not localEventListeners.hasKey(sessionId):
    localEventListeners[sessionId] = @[]
  localEventListeners[sessionId].add listener
  result = proc() =
    if localEventListeners.hasKey(sessionId):
      let i = localEventListeners[sessionId].find(listener)
      if i >= 0:
        localEventListeners[sessionId].delete(i)

proc onDapRawMessage*(sender: js, response: JsObject) {.async.} =
  ## IPC handler for "dap-raw-message" from the renderer.
  ## Decides the replay the request is for and delegates to
  ## `sendDapForSession`, which handles BM replay switching.
  var sessionId = getSessionId(response)
  if not serverRouting.isNil:
    # The page's session number is its tab's; the replay is that tab's in
    # its client — decided here, never taken from the page (a `replayId` it
    # stamps is not trusted: one client must not drive another's replay).
    sessionId = serverRouting.requestSession(sessionId)
    if sessionId < 0:
      warnPrint "dap: dropped a request from a client tab with no replay: ",
        response.toJs
      return
    sendDapForSession(sessionId, sessionId, response)
    return

  # The desktop: the tab names its replay (`dap.stampReplay`).
  let replayId = getReplayId(response)
  if replayId >= 0:
    # A tab names only its own replay, so this is who owns it — what an
    # event of the replay is attributed to (`resolveSessionId`).
    replayOwners[replayId] = sessionId
    sendDapForSession(sessionId, replayId, response)
    return

  # A TAB THAT NAMES NO REPLAY HAS NONE: a "+" tab on the Welcome Screen, a
  # tab after Stop, a window that opened on the Welcome Screen or in Edit
  # mode. Every tab with a replay is told it (`dap-replay-selected`, the
  # window's first tab included: `startup.init` announces the startup replay
  # once the renderer listens) and names it from then on. The request is
  # dropped, as the server drops a request from a client with no replay: run
  # on whatever replay is served, it would answer with another tab's data,
  # which is the defect this router's replay selection removes. Dropped, it is
  # what the renderer already takes such a request to be — sent into a
  # channel with no peer (`resetForNewSession`).
  warnPrint "dap: dropped a request from tab ", $sessionId,
    ", which has no replay: ", response.toJs

proc resolveSessionId(body: JsObject): int =
  ## Determine which session a DAP message from the Backend Manager
  ## belongs to.
  ##
  ## * **Responses** carry a `request_seq` that maps back to the
  ##   originating request via `pendingRequests`; its `request_seq` is
  ##   rewritten to the `seq` that session sent.
  ## * **Events** have no such link. On the desktop an event belongs to the
  ##   tab that owns the replay the Backend Manager names on it
  ##   (`ctReplayId`, `replayOwners`); an event of a replay no tab has named
  ##   yet (the window's first replay, before the renderer is told it), or
  ##   one without the tag, to the session of the last request forwarded
  ##   (`servedSession`).
  ## * If the message already has a `sessionId` (future-proofing), we
  ##   honour it as-is.
  ## * In the server (`installServerSessionRouting`), the replay the Backend
  ##   Manager names (`ctReplayId`) decides, for responses and events alike.
  if jsHasKey(body, cstring"sessionId"):
    return body["sessionId"].to(int)

  # In the server a session is its replay, and the Backend Manager names the
  # replay every message came from: exact where "the replay selected last"
  # is a guess that is wrong whenever two clients' replays run at once.
  if not serverRouting.isNil and jsHasKey(body, ReplayIdTag):
    let replayId = body[ReplayIdTag].to(int)
    if jsHasKey(body, cstring"request_seq"):
      var request: PendingDapRequest
      if pendingRequests.pop(body["request_seq"].to(int), request):
        body["request_seq"] = request.seq
    return replayId

  if jsHasKey(body, cstring"request_seq"):
    let wireSeq = body["request_seq"].to(int)
    var request: PendingDapRequest
    if pendingRequests.pop(wireSeq, request):
      body["request_seq"] = request.seq
      return request.sessionId

  # The desktop: the Backend Manager names the replay of every message it
  # relays, and a tab names only its own replay on its requests, so an event
  # of a replay a tab owns is that tab's — exactly, where "the session that
  # sent the last request" is wrong whenever another tab's replay is still
  # sending (a hidden tab's replay finishing a move).
  if jsHasKey(body, ReplayIdTag):
    let owner = replayOwners.getOrDefault(body[ReplayIdTag].to(int), -1)
    if owner >= 0:
      return owner

  # Fallback: attribute to the session the last request was forwarded for.
  return servedSession

proc deliverToSession(sessionId: int; channel: cstring; body: JsObject) =
  ## Hand a replay's answer or event to whoever displays its session: in the
  ## server, the client that owns the replay; on the desktop, every window
  ## showing the session (M16).
  if not serverRouting.isNil:
    serverRouting.deliver(sessionId, channel, body)
  else:
    broadcastToSession(sessionId, channel, body)

proc handleFrame(frame: string) =
  let body: JsObject = Json.parse(frame)
  let msgtype = body["type"].to(cstring)

  if msgtype == "response":
    if jsHasKey(body, cstring"command"):
      let command = body["command"].to(cstring)
      # Internal commands that are handled in the main process only.
      if command == cstring("ct/start-replay"):
        if not replayStartHandler.isNil:
          replayStartHandler(body)
        return
      # Responses to our own ct/select-replay requests are consumed
      # silently — the renderer does not need to see them.
      if command == cstring("ct/select-replay"):
        return

    # A server-side client's request: its answer is its own.
    if jsHasKey(body, cstring"request_seq"):
      var handler: LocalDapResponseHandler
      if localResponseHandlers.pop(body["request_seq"].to(int), handler):
        handler(body)
        return

    # M9: Tag the response with the session that issued the request.
    let sessionId = resolveSessionId(body)
    body["sessionId"] = sessionId
    deliverToSession(sessionId, "CODETRACER::dap-receive-response", body)

  elif msgtype == "event":
    # M9: An event belongs to the replay the Backend Manager names (in the
    # server) or to the session it is serving (`resolveSessionId`).
    let sessionId = resolveSessionId(body)
    body["sessionId"] = sessionId
    deliverToSession(sessionId, "CODETRACER::dap-receive-event", body)
    if localEventListeners.hasKey(sessionId):
      # A COPY: a listener may add another (the server's session attaches on
      # its first stop, and the ViewModels it builds subscribe).
      let listeners = localEventListeners[sessionId]
      for listener in listeners:
        listener(body)

  else:
    echo "unknown DAP message: ", body

var dapMessageBuffer = ""

proc setupProxyForDap*(socket: JsObject) =
  let lineBreakSize = 4

  socket.on(cstring"data", proc(data: cstring) =
    dapMessageBuffer.add $data

    while true:
      # Try and find the `Content-length` header's end
      let hdrEnd = dapMessageBuffer.find("\r\n\r\n")

      # We're still waiting on the header
      if hdrEnd < 0: break

      # We parse the header
      let header = dapMessageBuffer[0 ..< hdrEnd]
      var contentLen = -1
      for line in header.splitLines:
        if line.startsWith("Content-Length:"):
          contentLen = line.split(":")[1].strip.parseInt
          break
      if contentLen < 0:
        # Is this the right kind of exception ???
        raise newException(ValueError, "DAP header without Content-Length")

      # We try and parse the body
      let frameEnd = hdrEnd + lineBreakSize + contentLen  # 4 = len("\r\n\r\n")

      # We don't have the whole body yet
      if dapMessageBuffer.len < frameEnd: break

      # We handle the frame
      let body = dapMessageBuffer.substr(hdrEnd + lineBreakSize, frameEnd - 1)
      handleFrame(body)

      # We sanitize the buffer
      dapMessageBuffer = dapMessageBuffer.substr(frameEnd)
  )
