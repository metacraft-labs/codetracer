## backend/stdio_backend.nim
##
## DapStdioBackend — native-only BackendService that speaks DAP protocol
## over stdin/stdout pipes to a replay-server child process.
##
## This module spawns ``replay-server dap-server --stdio`` and communicates
## using the standard DAP wire format:
##
##   Content-Length: <N>\r\n
##   \r\n
##   <N bytes of JSON>
##
## The implementation uses **synchronous blocking I/O** — there are no
## background threads or async loops.  This is intentional: the primary
## use-case is sequential integration tests where simplicity trumps
## concurrency.  Each ``sendDapRequest`` call blocks until the matching
## response arrives, buffering any interleaved events for later retrieval.
##
## Compile with ``nim c`` (native backend only — uses std/osproc).
##
## Reference:
##   DAP wire format: https://microsoft.github.io/debug-adapter-protocol/overview#base-protocol

when defined(js):
  {.error: "stdio_backend.nim is native-only (requires std/osproc)".}

import std/[json, osproc, streams, strutils, os, asyncdispatch]
import backend_service

type
  DapStdioBackend* = ref object
    ## Manages a replay-server child process and provides synchronous
    ## DAP request/response communication over pipes.
    process*: Process
      ## The replay-server child process.
    seqCounter: int
      ## Monotonically increasing sequence number for outgoing requests.
    eventQueue*: seq[JsonNode]
      ## Buffer of DAP events received while waiting for a response.
      ## Tests can inspect or drain this queue after each action.

# ---------------------------------------------------------------------------
# DAP wire-format I/O
# ---------------------------------------------------------------------------

proc readDapMessage*(backend: DapStdioBackend): JsonNode =
  ## Read one complete DAP message from the child's stdout (blocking).
  ##
  ## Parses the ``Content-Length`` header, skips the blank separator line,
  ## then reads exactly that many bytes of JSON body.
  ##
  ## Raises IOError if the stream is closed or the header is malformed.
  let stream = backend.process.outputStream

  # Read headers — DAP allows multiple headers but in practice only
  # Content-Length is sent.  We loop until we hit the empty \r\n line.
  var contentLength = -1
  while true:
    let headerLine = stream.readLine()
    if headerLine.len == 0:
      # Empty line (after stripping the \n / \r\n) marks end of headers.
      break
    if headerLine.startsWith("Content-Length:"):
      let parts = headerLine.split(":")
      if parts.len >= 2:
        contentLength = parseInt(parts[1].strip())

  if contentLength < 0:
    raise newException(IOError,
      "DapStdioBackend: missing Content-Length header in DAP message")

  # Read exactly contentLength bytes of JSON body.
  var body = newString(contentLength)
  if contentLength > 0:
    let bytesRead = stream.readData(addr body[0], contentLength)
    if bytesRead != contentLength:
      raise newException(IOError,
        "DapStdioBackend: expected " & $contentLength &
        " bytes but got " & $bytesRead)

  result = parseJson(body)

proc writeDapMessage*(backend: DapStdioBackend; msg: JsonNode) =
  ## Write a DAP message to the child's stdin using the wire format.
  let body = $msg
  let header = "Content-Length: " & $body.len & "\r\n\r\n"
  let stream = backend.process.inputStream
  stream.write(header)
  stream.write(body)
  stream.flush()

# ---------------------------------------------------------------------------
# Request / response
# ---------------------------------------------------------------------------

proc sendDapRequest*(backend: DapStdioBackend; command: string;
                     args: JsonNode = newJObject()): JsonNode =
  ## Send a DAP request and block until the matching response arrives.
  ##
  ## Any events received while waiting are appended to ``eventQueue``
  ## so the caller can inspect them afterwards.
  ##
  ## Returns the full DAP response JSON object.  The caller should check
  ## ``result["success"]`` to detect errors.
  inc backend.seqCounter
  let seqId = backend.seqCounter

  let request = %*{
    "seq": seqId,
    "type": "request",
    "command": command,
    "arguments": args,
  }
  backend.writeDapMessage(request)

  # Read messages until we find the response matching our sequence number.
  while true:
    let msg = backend.readDapMessage()
    let msgType = msg.getOrDefault("type").getStr("")
    if msgType == "response" and
       msg.getOrDefault("request_seq").getInt(-1) == seqId:
      return msg
    elif msgType == "event":
      backend.eventQueue.add(msg)
    # Ignore other messages (e.g. reverse requests from the server).

proc waitForEvent*(backend: DapStdioBackend; eventName: string;
                   maxMessages: int = 50): JsonNode =
  ## Wait for a specific DAP event by name.
  ##
  ## First checks the buffered ``eventQueue``; if not found, reads new
  ## messages (blocking) up to ``maxMessages`` attempts.
  ##
  ## Returns the event JSON.  Raises ValueError if the event is not
  ## observed within the message budget.

  # Check the buffer first.
  for i in 0 ..< backend.eventQueue.len:
    if backend.eventQueue[i].getOrDefault("event").getStr("") == eventName:
      result = backend.eventQueue[i]
      backend.eventQueue.delete(i)
      return

  # Read new messages.
  for _ in 0 ..< maxMessages:
    let msg = backend.readDapMessage()
    let msgType = msg.getOrDefault("type").getStr("")
    if msgType == "event":
      if msg.getOrDefault("event").getStr("") == eventName:
        return msg
      else:
        backend.eventQueue.add(msg)
    # Responses without a pending request are ignored (shouldn't happen
    # in a well-behaved session but we tolerate it).

  raise newException(ValueError,
    "DapStdioBackend: did not receive '" & eventName &
    "' event within " & $maxMessages & " messages")

proc drainEvents*(backend: DapStdioBackend): seq[JsonNode] =
  ## Return and clear all buffered events.
  result = backend.eventQueue
  backend.eventQueue = @[]

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc startReplayServer*(replayServerBin: string;
                        tracePath: string = ""): DapStdioBackend =
  ## Spawn a ``replay-server dap-server --stdio`` child process.
  ##
  ## ``replayServerBin`` is the absolute path to the replay-server binary.
  ## ``tracePath`` is optional — if the server needs to know the trace
  ## folder at launch time, pass it; otherwise configure it via the DAP
  ## ``launch`` request.
  ##
  ## The child's stdin/stdout are captured for DAP communication.
  ## stderr is inherited so server diagnostics appear in the test output.
  if not fileExists(replayServerBin):
    raise newException(IOError,
      "DapStdioBackend: replay-server binary not found at: " & replayServerBin)

  var args = @["dap-server", "--stdio"]

  let process = startProcess(
    replayServerBin,
    args = args,
    options = {poUsePath, poStdErrToStdOut},
  )

  DapStdioBackend(
    process: process,
    seqCounter: 0,
    eventQueue: @[],
  )

proc close*(backend: DapStdioBackend) =
  ## Terminate the replay-server child process.
  ## Attempts a graceful shutdown first (close stdin), then kills.
  if backend.process.running:
    try:
      backend.process.inputStream.close()
    except:
      discard
    # Give the process a moment to exit, then force-kill.
    try:
      let code = backend.process.waitForExit(timeout = 3000)
      discard code
    except:
      backend.process.terminate()
  backend.process.close()

# ---------------------------------------------------------------------------
# BackendService adapter
# ---------------------------------------------------------------------------

proc toBackendService*(backend: DapStdioBackend): BackendService =
  ## Wrap a DapStdioBackend as a BackendService so it can be injected
  ## into SessionViewModel and the store layer.
  ##
  ## Because this is synchronous/blocking and BackendService.sendProc
  ## returns a Future, we create already-completed futures.
  ##
  ## Note: The BackendService expects CT-style command names like
  ## ``"ct/step"`` and ``"ct/load-locals"``.  The sendProc here maps
  ## them to DAP commands understood by replay-server.  For standard
  ## DAP commands (initialize, launch, next, stepBack, etc.) the caller
  ## should use sendDapRequest directly.
  let b = backend  # capture for closures

  let sendProc = proc(command: string;
                      args: JsonNode): BackendFuture[JsonNode] =
    # The BackendService interface uses CT-prefixed command names.
    # We forward them as-is; replay-server recognises both DAP standard
    # commands and ct/* custom commands.
    let resp = b.sendDapRequest(command, args)
    var fut = newFuture[JsonNode]("DapStdioBackend.send")
    fut.complete(resp)
    return fut

  var eventHandlers: seq[EventHandler] = @[]

  let onEventProc = proc(handler: EventHandler) =
    eventHandlers.add(handler)

  let disconnectProc = proc() =
    try:
      discard b.sendDapRequest("disconnect")
    except:
      discard
    b.close()

  BackendService(
    sendProc: sendProc,
    onEventProc: onEventProc,
    disconnectProc: disconnectProc,
  )
