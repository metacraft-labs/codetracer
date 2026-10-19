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
# main process forwards a DAP request from a particular session, it must
# first tell the BM to select the corresponding replay via
# `ct/select-replay`.  Responses are then tagged with the originating
# sessionId so the renderer can route them to the correct ReplaySession.

var currentDapSessionId = 0
  ## Which session the Backend Manager is currently serving.  Updated
  ## every time we send a `ct/select-replay` command.

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

proc registerStartReplayHandler*(handler: proc(body: JsObject)) =
  replayStartHandler = handler

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

proc selectSession(sessionId: int) =
  ## Point the Backend Manager at `sessionId`'s replay, when it is serving
  ## another one.
  ##
  ## The routing decision is keyed solely on the target sessionId vs the
  ## one the BM is currently serving. Earlier code special-cased
  ## `sessionId == 0` and skipped the switch, which mis-targeted the
  ## default session whenever a non-zero session had previously been
  ## selected on the BM (issue #327). The routing must be symmetric:
  ## session 0 needs the same switch logic as any other session.
  if sessionId != currentDapSessionId:
    backendManagerSocket.write(wrapJsonForSending(js{
      "type": cstring"request",
      "command": cstring"ct/select-replay",
      "arguments": sessionId,
      "seq": nextWireSeq()
    }))
    currentDapSessionId = sessionId

proc sendDapForSession*(sessionId: int, message: JsObject) =
  ## Forward a DAP request to the Backend Manager on behalf of
  ## `sessionId`.  If the BM is currently serving a different session,
  ## a `ct/select-replay` command is sent first to switch contexts.
  if backendManagerSocket.isNil:
    errorPrint "backend socket is nil, couldn't send DAP for session ",
      sessionId, ": ", message.toJs
    return

  selectSession(sessionId)

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

proc sendLocalDapRequest*(sessionId: int; command: cstring;
                          arguments: JsObject;
                          onResponse: LocalDapResponseHandler): bool =
  ## Send a DAP request for `sessionId` on behalf of a server-side client;
  ## `onResponse` receives the whole DAP response. `false` when there is no
  ## Backend Manager connection to send on.
  if backendManagerSocket.isNil:
    return false
  selectSession(sessionId)
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
  ## Extracts the sessionId attached by the renderer and delegates to
  ## `sendDapForSession` which handles BM session switching.
  let sessionId = getSessionId(response)
  sendDapForSession(sessionId, response)

proc resolveSessionId(body: JsObject): int =
  ## Determine which session a DAP message from the Backend Manager
  ## belongs to.
  ##
  ## * **Responses** carry a `request_seq` that maps back to the
  ##   originating request via `pendingRequests`; its `request_seq` is
  ##   rewritten to the `seq` that session sent.
  ## * **Events** have no such link; they belong to whichever session
  ##   the BM is currently serving (`currentDapSessionId`).
  ## * If the message already has a `sessionId` (future-proofing), we
  ##   honour it as-is.
  if jsHasKey(body, cstring"sessionId"):
    return body["sessionId"].to(int)

  if jsHasKey(body, cstring"request_seq"):
    let wireSeq = body["request_seq"].to(int)
    var request: PendingDapRequest
    if pendingRequests.pop(wireSeq, request):
      body["request_seq"] = request.seq
      return request.sessionId

  # Fallback: attribute to the currently selected session.
  return currentDapSessionId

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
    # M16: Fan out to all windows displaying this session.
    broadcastToSession(sessionId, "CODETRACER::dap-receive-response", body)

  elif msgtype == "event":
    # M9: Events belong to the currently active session in the BM.
    let sessionId = resolveSessionId(body)
    body["sessionId"] = sessionId
    # M16: Fan out to all windows displaying this session.
    broadcastToSession(sessionId, "CODETRACER::dap-receive-event", body)
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
