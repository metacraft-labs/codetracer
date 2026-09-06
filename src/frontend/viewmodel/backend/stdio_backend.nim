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
## ## CTUI-14: THE READS ARE BOUNDABLE, AND BY DEFAULT THEY ARE NOT BOUND
##
## Until CTUI-14 every read here was a blocking read with a message budget and
## no clock, and that is a defect a terminal front-end cannot survive.  CTUI-11
## measured the first half of it and closed it: ``replay-server`` exits 2 and
## writes no DAP at all for a folder it cannot open, so
## ``src/frontend/tui/host/native_host.traceFolderProblem`` now ``stat``s for
## the three trace shapes BEFORE the tty is claimed.  CTUI-14 measured the other
## half, on a folder that passes every one of those ``stat``s:
##
##   $ head -c 4096 /dev/urandom > wedge/trace.bin
##   $ codetracer-tui wedge
##
## ``replay-server`` answers ``initialize``, ``configurationDone`` and
## ``launch`` **in full** (``Content-Length: 102``, all 102 bytes,
## ``success: true``) and then **never sends the ``stopped`` event the handshake
## is waiting for, and never exits**.  The old ``readDapMessage`` blocked inside
## the header read for ever, behind an alternate screen the driver had already
## claimed, with ``ISIG`` cleared by ``cfmakeraw`` and no input loop yet running
## — so ``Ctrl+c`` did nothing and the user's only recovery was a kill from
## another terminal.  Reproduced, and the reproduction is
## ``src/frontend/tui/tests/real_terminal/test_real_pty_lifecycle.nim``.
##
## Note where that stall lands: at a MESSAGE BOUNDARY.  ``broken`` below is the
## guard for the other case — a stall part way through a body — which is
## reachable and is not what this folder produces.
##
## ``DapReadBound`` is the fix, and it has two independent halves because
## neither alone closes the hole:
##
##   * a **real clock** (``timeoutMs``), so an UNATTENDED session — a CI job, a
##     pane nobody is watching — eventually fails by name instead of hanging;
##   * an **escape hatch** (``interruptFd`` + ``onInterrupt``), so an ATTENDED
##     one does not have to wait out the clock.  The fd is selected on beside
##     the child's pipe, so the user's keystroke wakes the same ``select`` the
##     engine's answer would have.
##
## **The default is ``DapReadBound()``: ``timeoutMs = 0``, ``interruptFd = -1``,
## no callback — which is byte-for-byte the behaviour every caller had before.**
## That is deliberate.  Twenty-five suites share this module and their reads are
## the same blocking reads they always were; the front-end that owns a terminal
## is the caller that asks for a bound, because it is the caller that has
## something to lose.
##
## ## WHY THIS MODULE READS THE FILE DESCRIPTOR AND NOT ``outputStream``
##
## **``osproc.outputStream`` is BUFFERED on POSIX**, and that fact is what makes
## the obvious implementation of the bound silently wrong.  ``osproc``'s POSIX
## branch builds it with ``createStream(p.outHandle, fmRead)``, which is
## ``open(f, handle, fmRead)`` followed by ``newFileStream(f)`` — a C ``FILE*``
## with ordinary stdio buffering (``nim/lib/pure/osproc.nim:1435-1451``).  Ask it
## for 295 bytes and ``fread`` pulls a whole ``BUFSIZ`` off the pipe and hands
## back the 295; the rest sits in a userspace buffer that ``select`` cannot see
## and ``FIONREAD`` reports as zero.
##
## The first version of this change put a ``select`` in front of the same stream
## reads and it wedged the ordinary case: after the ``initialize`` response the
## kernel pipe was genuinely empty, the ``initialized`` event was already in the
## ``FILE*``, and the clock expired against a peer that had answered.  MEASURED
## rather than reasoned about — ``ioctl(FIONREAD)`` returned 0 on the pipe while
## a blocking read on the same descriptor returned instantly.  (The unbuffered
## ``FileHandleStream`` in ``nim/lib/pure/streams.nim`` is real, and it is the
## **Windows** branch of ``osproc``; reading the wrong ``when`` arm is how the
## first version came to be written.)
##
## So the reads below own their buffer: one ``posix.read`` on
## ``process.outputHandle`` into ``readBuf``, and every header byte and body
## byte served out of it.  ``select`` is then exact, because the only place a
## byte can be hiding is a buffer this module can look in.  ``outputStream`` is
## never touched for reading, which is what keeps the two buffers from becoming
## two.
##
## The change is invisible to the twenty-five suites that share this module,
## with one exception that is a fix rather than a difference: the body read is
## now a LOOP.  A pipe hands over at most one buffer at a time, so a DAP message
## larger than the pipe's capacity used to arrive short at the single
## ``readData`` and be reported as a malformed message.
##
## Reference:
##   DAP wire format: https://microsoft.github.io/debug-adapter-protocol/overview#base-protocol

when defined(js):
  {.error: "stdio_backend.nim is native-only (requires std/osproc)".}

import std/[json, monotimes, osproc, streams, strutils, os, times,
            asyncdispatch]
when defined(posix):
  import std/posix
import backend_service

type
  DapReadBound* = object
    ## What ends a read that the peer is not answering.
    ##
    ## A VALUE, so a caller states its whole policy in one place and a test can
    ## assert on it without a process.  The zero value is "no bound at all",
    ## which is what every caller had before CTUI-14 and what every caller that
    ## does not own a terminal still has.
    timeoutMs*: int
      ## How long a single message may take to arrive, in milliseconds.
      ## ``0`` means unbounded.
      ##
      ## PER MESSAGE AND NOT PER SESSION.  A step through a long recording is
      ## allowed to take as long as it takes; what this catches is a peer that
      ## has stopped answering entirely, which is a different fact from a peer
      ## that is slow.
    interruptFd*: cint
      ## A file descriptor watched alongside the child's pipe.  ``-1`` for
      ## none.  In the TUI it is ``STDIN_FILENO``: the terminal is already in
      ## raw mode when the handshake runs, so the user's ``Ctrl+c`` arrives
      ## here as a readable byte rather than as a signal.
    onInterrupt*: proc(): bool {.closure.}
      ## Called when ``interruptFd`` becomes readable.  ``true`` abandons the
      ## read with ``DapInterruptedError``; ``false`` means "that byte was not
      ## an abort, keep waiting".
      ##
      ## THE CALLBACK CONSUMES THE BYTE.  This module must not: it does not
      ## know what an input token is, and a front-end that had its keystroke
      ## eaten by its debug adapter would be a worse defect than the one this
      ## exists to fix.

  DapStalledError* = object of CatchableError
    ## The peer stopped answering and the clock ran out.
    ##
    ## A DISTINCT TYPE rather than an ``IOError``, because "the adapter died",
    ## "the adapter refused" and "the adapter went quiet" are three different
    ## reports and only the last of them is this one.

  DapInterruptedError* = object of CatchableError
    ## The user asked for the read to stop.  Not a failure of the peer.

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
    bound*: DapReadBound
      ## CTUI-14.  Unbounded by default; see this module's header.
    broken: bool
      ## Set when a read was abandoned PART WAY THROUGH A MESSAGE.
      ##
      ## A `DapStalledError` or a `DapInterruptedError` can arrive after the
      ## header has been consumed and before the body has — an adapter that
      ## announces N bytes and sends fewer, or a user who interrupts between
      ## the two — so the stream is left at an offset that is not a message
      ## boundary. Every later read would then parse a message's tail as a
      ## header and report something that is true of nothing.
      ##
      ## THE WEDGE IN THIS MODULE'S HEADER DOES NOT DO THIS. That folder
      ## stalls at a message BOUNDARY (`launch` is answered in full and
      ## `stopped` never arrives), so `consumed` is false there and this flag
      ## stays clear. The guard is here because the interrupt half makes
      ## mid-message abandonment reachable, not because the reproduction
      ## demonstrates it.
      ##
      ## So the channel is declared dead instead. That is not a limitation of
      ## the mechanism, it is what abandoning a framed protocol MEANS, and the
      ## alternative — carrying on and reporting nonsense — is how a hang
      ## becomes a wrong answer. `main.nim` installs the interrupt half of the
      ## bound only for the handshake for this reason: there, the next thing
      ## that happens is that the session is thrown away.
    readBuf: string
    readPos: int
      ## THE ONLY PLACE A BYTE FROM THE CHILD CAN BE HIDING.  See this module's
      ## header: ``osproc.outputStream`` is a buffered C ``FILE*`` on POSIX, so
      ## a bound built on ``select`` in front of it would sleep on data it had
      ## already read.  Reading the descriptor into this buffer is what makes
      ## "the pipe is empty" and "there is nothing to read" the same statement.

const
  InterruptPollMs = 50
    ## How long a bounded wait sleeps at a time when it has an ``interruptFd``.
    ##
    ## Not a latency: ``select`` returns the instant either fd is readable, so
    ## this only bounds how often the deadline itself is re-examined. It exists
    ## so a bound with no interrupt fd and a bound with one take the same code
    ## path.

# ---------------------------------------------------------------------------
# DAP wire-format I/O
# ---------------------------------------------------------------------------

proc watchesInterrupt*(b: DapReadBound): bool =
  ## Whether the interrupt half of this bound is fully specified.
  ##
  ## AN FD WITHOUT A CALLBACK IS NOT A HALF-FEATURE, it is a spin: `select`
  ## reports a readable fd on every turn until somebody reads the byte, and
  ## this module deliberately does not (see `onInterrupt`). So the fd is
  ## watched only when there is something to consume it.
  b.interruptFd >= 0 and b.onInterrupt != nil

proc isBounded*(b: DapReadBound): bool =
  ## Whether this bound does anything at all. ``DapReadBound()`` does not.
  b.timeoutMs > 0 or b.watchesInterrupt

proc awaitReadable(backend: DapStdioBackend; deadline: MonoTime) =
  ## Block until the child's stdout has something on it, the deadline passes,
  ## or the interrupt fd says the user gave up.
  ##
  ## Returns normally on "there is a byte to read"; every other outcome is an
  ## exception, because a reader that got a "nothing happened" answer would
  ## have to invent what to do with it.
  ##
  ## A NO-OP WHEN THE BOUND IS THE ZERO VALUE, and that is the whole
  ## compatibility story: the caller then goes straight to the same blocking
  ## stream read it always did.
  if not backend.bound.isBounded:
    return
  when not defined(posix):
    # No `select` here. The bound is accepted and not honoured rather than
    # refused, because the alternative is a platform that cannot construct the
    # object at all; the TUI that needs it is POSIX-only by construction (it
    # owns a termios).
    return
  else:
    let fd = backend.process.outputHandle
    while true:
      var rs: TFdSet
      FD_ZERO(rs)
      FD_SET(fd, rs)
      var maxFd = fd
      if backend.bound.watchesInterrupt:
        FD_SET(backend.bound.interruptFd, rs)
        if backend.bound.interruptFd > maxFd:
          maxFd = backend.bound.interruptFd
      var sliceMs = InterruptPollMs
      if backend.bound.timeoutMs > 0:
        let left = (deadline - getMonoTime()).inMilliseconds
        if left <= 0:
          raise newException(DapStalledError,
            "DapStdioBackend: the debug adapter sent nothing for " &
            $backend.bound.timeoutMs & " ms")
        if left < sliceMs:
          sliceMs = int(left)
      var tv: Timeval
      tv.tv_sec = posix.Time(sliceMs div 1000)
      tv.tv_usec = clong((sliceMs mod 1000) * 1000)
      let ready = posix.select(maxFd + 1, addr rs, nil, nil, addr tv)
      if ready < 0:
        if osLastError().cint == EINTR:
          # A signal arrived. Re-examine the deadline and go round; a `select`
          # that returned early is not a timeout.
          continue
        # ANYTHING ELSE HANDS THE READ BACK TO THE STREAM, which will report
        # the same fd's failure in the terms the caller already handles.
        # Spinning on a `select` that cannot succeed would turn a diagnosable
        # error into the hang this whole mechanism exists to remove.
        return
      if ready > 0 and FD_ISSET(fd, rs) != 0:
        return
      if ready > 0 and backend.bound.watchesInterrupt and
         FD_ISSET(backend.bound.interruptFd, rs) != 0:
        if backend.bound.onInterrupt():
          raise newException(DapInterruptedError,
            "DapStdioBackend: the read was interrupted by the user")
      # Nothing to read yet. The next turn re-examines the deadline, and an
      # unbounded-but-watched read simply goes round again.

const
  ReadChunkBytes = 8192
    ## How much is taken off the pipe in one `read(2)`.
    ##
    ## Larger than a typical DAP message and smaller than a pipe's 64 KB
    ## capacity, so a chatty answer costs a handful of syscalls rather than one
    ## per byte — which is what the old `Stream.readLine` header parse did.

proc fillBuffer(backend: DapStdioBackend; deadline: MonoTime): bool =
  ## Take whatever the pipe has into `readBuf`. `false` means end of stream.
  ##
  ## THE ONE PLACE THIS PROCESS READS THE CHILD. `osproc.outputStream` is
  ## deliberately never used for reading (this module's header says why), so
  ## `awaitReadable`'s `select` and this buffer between them account for every
  ## byte the child has sent.
  awaitReadable(backend, deadline)
  if backend.readPos > 0 and backend.readPos == backend.readBuf.len:
    backend.readBuf.setLen(0)
    backend.readPos = 0
  var chunk = newString(ReadChunkBytes)
  when defined(posix):
    let got = posix.read(backend.process.outputHandle,
                         addr chunk[0], ReadChunkBytes)
  else:
    # No `select` on this platform either, so the stream's own buffering costs
    # nothing that is not already lost. See `awaitReadable`.
    let got = backend.process.outputStream.readData(addr chunk[0],
                                                    ReadChunkBytes)
  if got <= 0:
    return false
  chunk.setLen(got)
  backend.readBuf.add chunk
  true

proc nextByte(backend: DapStdioBackend; deadline: MonoTime): (bool, char) =
  ## One byte, from the buffer or from the pipe. `(false, _)` at end of stream.
  while backend.readPos >= backend.readBuf.len:
    if not backend.fillBuffer(deadline):
      return (false, '\0')
  let c = backend.readBuf[backend.readPos]
  inc backend.readPos
  (true, c)

proc readHeaderLine(backend: DapStdioBackend; deadline: MonoTime;
                    consumed: var bool): string =
  ## One ``\n``-terminated header line, with the ``\r`` stripped.
  ##
  ## Replaces ``Stream.readLine``, whose contract this reproduces exactly: the
  ## line terminator is consumed and not returned, a trailing ``\r`` is dropped,
  ## and a line of length zero is the blank separator that ends the headers.
  ## What it does NOT reproduce is one ``read(2)`` per character, and that is a
  ## side benefit rather than the reason — the reason is that a bounded read has
  ## to be able to see the bytes it is waiting for.
  result = ""
  while true:
    let (ok, c) = backend.nextByte(deadline)
    consumed = true
    if not ok:
      raise newException(IOError,
        "DapStdioBackend: the debug adapter closed its output stream" &
        " mid-header (partial line: " & escape(result) & ")")
    if c == '\n':
      break
    result.add c
  if result.len > 0 and result[^1] == '\r':
    result.setLen(result.len - 1)

proc readBody(backend: DapStdioBackend; length: int;
              deadline: MonoTime; consumed: var bool): string =
  ## Exactly `length` bytes of message body.
  ##
  ## LOOPED, which is a fix in its own right: a pipe hands over at most one
  ## buffer at a time, so a body larger than the pipe's capacity reached the old
  ## single `readData` short and was reported as a malformed message rather than
  ## being completed.
  result = newString(length)
  var have = 0
  while have < length:
    while backend.readPos >= backend.readBuf.len:
      if not backend.fillBuffer(deadline):
        raise newException(IOError,
          "DapStdioBackend: expected " & $length &
          " bytes but the stream ended after " & $have)
    let available = backend.readBuf.len - backend.readPos
    let take = min(available, length - have)
    copyMem(addr result[have], addr backend.readBuf[backend.readPos], take)
    inc backend.readPos, take
    inc have, take
    consumed = true

proc readOneMessage(backend: DapStdioBackend; deadline: MonoTime;
                    consumed: var bool): JsonNode =
  ## The body of `readDapMessage`, with `consumed` saying whether any byte of
  ## this message has been taken off the stream yet.
  ##
  ## Split out so the caller can tell "the peer went quiet BEFORE a message"
  ## from "the peer went quiet HALFWAY THROUGH one". The first is recoverable;
  ## the second is what `DapStdioBackend.broken` is about.
  var contentLength = -1
  # Read headers — DAP allows multiple headers but in practice only
  # Content-Length is sent.  We loop until we hit the empty \r\n line.
  # `replay-server` runs with `poStdErrToStdOut`, so its diagnostics arrive on
  # this stream as lines that are neither `Content-Length:` nor empty; they are
  # skipped here exactly as they always were.
  while true:
    let headerLine = backend.readHeaderLine(deadline, consumed)
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

  parseJson(backend.readBody(contentLength, deadline, consumed))

proc readDapMessage*(backend: DapStdioBackend): JsonNode =
  ## Read one complete DAP message from the child's stdout (blocking).
  ##
  ## Parses the ``Content-Length`` header, skips the blank separator line,
  ## then reads exactly that many bytes of JSON body.
  ##
  ## Raises IOError if the stream is closed or the header is malformed,
  ## ``DapStalledError`` when ``bound.timeoutMs`` passes with nothing arriving,
  ## and ``DapInterruptedError`` when ``bound.onInterrupt`` says to stop.
  ##
  ## THE DEADLINE IS PER MESSAGE and starts here, so a session that is making
  ## progress never accumulates one.
  if backend.broken:
    raise newException(DapStalledError,
      "DapStdioBackend: this channel was abandoned part way through a" &
      " message and cannot be resynchronised")
  let deadline =
    if backend.bound.timeoutMs > 0:
      getMonoTime() + initDuration(milliseconds = backend.bound.timeoutMs)
    else:
      MonoTime()
  var consumed = false
  try:
    result = readOneMessage(backend, deadline, consumed)
  except CatchableError:
    # ABANDONED PART WAY THROUGH: the stream is no longer at a message
    # boundary, so nothing after this can be parsed. Say so once, here, rather
    # than letting every later read report a different piece of nonsense.
    if consumed:
      backend.broken = true
    raise

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

proc sendDapRequestNoResponse*(backend: DapStdioBackend; command: string;
                                args: JsonNode = newJObject()) =
  ## Send a DAP request and return without reading its reply.
  ##
  ## This does NOT mean the command is unanswered.  ``ct/calltrace-jump``,
  ## ``ct/event-jump`` and ``ct/trace-jump`` each end in ``respond_dap`` and
  ## do send a response; the earlier claim here that they "only send events"
  ## described a real defect in the engine that has since been fixed, and the
  ## note outlived it.
  ##
  ## What this proc is for is the caller that wants to synchronise on the
  ## ``stopped`` / ``ct/complete-move`` events rather than on the response.
  ## The response is left in the stream; ``waitForEvent`` skips non-event
  ## messages, so it is discarded harmlessly rather than desynchronising the
  ## next read.
  ##
  ## The caller should follow up with ``waitForEvent`` to consume the
  ## events emitted by the handler.
  inc backend.seqCounter
  let seqId = backend.seqCounter

  let request = %*{
    "seq": seqId,
    "type": "request",
    "command": command,
    "arguments": args,
  }
  backend.writeDapMessage(request)

proc waitForEvent*(backend: DapStdioBackend; eventName: string;
                   maxMessages: int = 50): JsonNode =
  ## Wait for a specific DAP event by name.
  ##
  ## First checks the buffered ``eventQueue``; if not found, reads new
  ## messages (blocking) up to ``maxMessages`` attempts.
  ##
  ## Returns the event JSON.  Raises ValueError if the event is not
  ## observed within the message budget.
  ##
  ## THE MESSAGE BUDGET IS NOT A CLOCK, and CTUI-14 did not turn it into one.
  ## It bounds how many messages this may skip, which is a bound on a peer that
  ## is CHATTY; the clock that bounds a peer that has gone QUIET is
  ## ``backend.bound.timeoutMs``, applied per message inside
  ## ``readDapMessage``.  Both are needed and neither implies the other: the
  ## wedge this module's header records had a budget of 50 and used none of it,
  ## because it never completed a single message.

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
                        tracePath: string = "";
                        bound: DapReadBound = DapReadBound(
                          interruptFd: -1)): DapStdioBackend =
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
    bound: bound,
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
  ## Note: The BackendService expects DAP-compatible command names like
  ## ``"next"``, ``"stepIn"``, ``"ct/load-locals"``.  The sendProc here
  ## maps them to DAP commands understood by replay-server.  Step
  ## commands use standard DAP names (next, stepBack, stepIn, stepOut,
  ## continue, reverseContinue) directly.
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
