## The controlled child is this same executable, launched through the real
## startReplayServer boundary. A real engine cannot deliberately place a
## diagnostic between two body writes, so this fixture owns precisely that
## write ordering; process creation, pipes and DAP decoding are production code.
## No sleeps establish the corruption: flushes order all three writes even
## when stdout and stderr refer to the same pipe in the unfixed transport.
## The capability peer below controls startup/navigation capability changes:
## a real replay engine cannot deliberately toggle this flag at chosen reads.
## The HeadlessDebugSession, pipes, decoder and subscriber delivery are real;
## the real RR producer was separately observed advertising true while this
## constructor returned false before any pane request.
import std/[json, monotimes, os, osproc, strutils, tempfiles, times, unittest]
when defined(posix):
  import std/posix
import ../../viewmodel/backend/stdio_backend
import ../../viewmodel/backend/backend_service
import ../../viewmodel/headless_session
import ../../viewmodel/store/replay_data_store
import isonim/core/signals

const Body = "{\"type\":\"event\",\"event\":\"stopped\",\"body\":{\"text\":\"intact\"}}"
const Diagnostic = "engine diagnostic between body bytes\n"

proc handoffLog(direction: string; message: JsonNode) =
  let path = getEnv("CT_STDIO_HANDOFF_LOG")
  if path.len > 0:
    var output = open(path, fmAppend)
    defer: output.close()
    output.writeLine(direction & " " & $message)

proc readPeerRequest(): JsonNode =
  var length = -1
  while true:
    let line = stdin.readLine().strip()
    if line.len == 0: break
    if line.startsWith("Content-Length:"):
      length = parseInt(line["Content-Length:".len .. ^1].strip())
  doAssert length > 0, "the client must send a framed DAP request"
  var body = newString(length)
  var received = 0
  while received < length:
    let count = stdin.readBuffer(addr body[received], length - received)
    if count <= 0: raise newException(EOFError, "incomplete peer request")
    received += count
  result = parseJson(body)
  handoffLog("REQUEST", result)

proc capabilityPeer(initial: bool) =
  var sequence = 0
  var position = 1
  var supports = initial
  proc write(message: JsonNode) =
    inc sequence
    message["seq"] = %sequence
    handoffLog("SENT", message)
    let body = $message
    stdout.write("Content-Length: " & $body.len & "\r\n\r\n" & body)
    stdout.flushFile()
  proc response(request: JsonNode; body: JsonNode = newJObject()) =
    write(%*{"type": "response", "request_seq": request["seq"],
      "command": request["command"], "success": true, "body": body})
  proc move() =
    write(%*{"type": "event", "event": "capabilities", "body": {
      "capabilities": {"supportsSteppingGranularity": supports}}})
    write(%*{"type": "event", "event": "stopped", "body": {"reason": "step"}})
    write(%*{"type": "event", "event": "ct/complete-move", "body": {
      "main": position == 1, "location": {"path": "/controlled/main.c",
      "line": position, "rrTicks": position, "functionName": "main", "key": "1"}}})
  while true:
    var request: JsonNode
    try: request = readPeerRequest()
    except EOFError: return
    case request["command"].getStr()
    of "initialize":
      response(request, %*{"supportsStepBack": true, "supportsSteppingGranularity": false})
      write(%*{"type": "event", "event": "initialized", "body": {}})
    of "launch":
      response(request)
      move()
    of "next":
      inc position
      supports = not supports
      move()
      response(request)
    of "threads":
      write(%*{"type": "event", "event": "ct/handoff-followup", "body": {}})
      response(request)
    of "disconnect":
      response(request)
      return
    else: response(request)

proc sendBody() =
  stdout.write("Content-Length: " & $Body.len & "\r\n\r\n" & Body)
  stdout.flushFile()

proc flood() =
  for _ in 0 ..< 256:
    stderr.write(repeat('x', 8192))
  stderr.write("\nlast engine diagnostic\n")
  stderr.flushFile()

if paramCount() >= 1 and paramStr(1) == "dap-server":
  case getEnv("CT_STDIO_DIAGNOSTICS_MODE", "fragment")
  of "capability-startup": capabilityPeer(true)
  of "capability-navigation": capabilityPeer(false)
  of "fragment":
    stdout.write("Content-Length: " & $Body.len & "\r\n\r\n")
    stdout.write(Body[0 .. 15])
    stdout.flushFile()
    stderr.write(Diagnostic)
    stderr.flushFile()
    stdout.write(Body[16 .. ^1])
    stdout.flushFile()
  of "flood":
    flood()
    sendBody()
  of "idle":
    sendBody()
    flood()
    writeFile(getEnv("CT_STDIO_DIAGNOSTICS_MARKER"), "drained")
  of "fatal":
    stderr.write("engine refused the trace: missing metadata\n")
    stderr.flushFile()
    quit(2)
  of "stall":
    stderr.write("engine is unable to finish loading\n")
    stderr.flushFile()
    writeFile(getEnv("CT_STDIO_DIAGNOSTICS_MARKER"), "ready")
    try:
      discard stdin.readLine()
    except EOFError:
      discard
  of "held":
    sendBody()
    stderr.write(Diagnostic)
    stderr.flushFile()
    when defined(posix):
      let child = fork()
      doAssert child >= 0
      if child == 0:
        let release = getEnv("CT_STDIO_DIAGNOSTICS_MARKER")
        let deadline = getMonoTime() + initDuration(seconds = 15)
        while not fileExists(release) and getMonoTime() < deadline:
          sleep(5)
        writeFile(release & ".done", "done")
        quit(0)
    else:
      raise newException(IOError, "held fixture requires POSIX fork")
  of "stubborn":
    # Closing stdin cannot end this child. The finite sleep is a fixture
    # backstop; close must force-kill and reap it first.
    sendBody()
    sleep(15000)
  else:
    raise newException(ValueError, "unknown fixture mode")
  quit(0)

proc start(mode: string; marker = ""; log = ""): DapStdioBackend =
  let previousMode = getEnv("CT_STDIO_DIAGNOSTICS_MODE")
  let previousMarker = getEnv("CT_STDIO_DIAGNOSTICS_MARKER")
  let previousLog = getEnv("CT_STDIO_HANDOFF_LOG")
  putEnv("CT_STDIO_DIAGNOSTICS_MODE", mode)
  putEnv("CT_STDIO_DIAGNOSTICS_MARKER", marker)
  putEnv("CT_STDIO_HANDOFF_LOG", log)
  defer:
    putEnv("CT_STDIO_DIAGNOSTICS_MODE", previousMode)
    putEnv("CT_STDIO_DIAGNOSTICS_MARKER", previousMarker)
    putEnv("CT_STDIO_HANDOFF_LOG", previousLog)
  startReplayServer(getAppFilename(),
    bound = DapReadBound(timeoutMs: 10000, interruptFd: -1))

proc headlessPeer(mode: string): (HeadlessDebugSession, string) =
  let (output, log) = createTempFile("ct-capability-handoff-", ".log")
  output.close()
  echo "capability protocol log: " & log
  let previousMode = getEnv("CT_STDIO_DIAGNOSTICS_MODE")
  let previousLog = getEnv("CT_STDIO_HANDOFF_LOG")
  putEnv("CT_STDIO_DIAGNOSTICS_MODE", mode)
  putEnv("CT_STDIO_HANDOFF_LOG", log)
  defer:
    putEnv("CT_STDIO_DIAGNOSTICS_MODE", previousMode)
    putEnv("CT_STDIO_HANDOFF_LOG", previousLog)
  (newHeadlessDebugSession("/controlled/trace", getAppFilename()), log)

proc requests(log: string): seq[string] =
  for line in readFile(log).splitLines():
    if line.startsWith("REQUEST "):
      result.add(parseJson(line["REQUEST ".len .. ^1])["command"].getStr())

suite "stdio DAP diagnostics":
  test "explicit delivery preserves waiters and subscriber ownership across nested requests":
    let (output, log) = createTempFile("ct-explicit-delivery-", ".log")
    output.close()
    echo "delivery protocol log: " & log
    let backend = start("capability-navigation", log = log)
    defer: backend.close()
    discard backend.sendDapRequest("initialize")
    discard backend.waitForEvent("initialized")
    discard backend.sendDapRequest("configurationDone")
    discard backend.sendDapRequest("launch")
    discard backend.waitForEvent("stopped")
    discard backend.waitForEvent("ct/complete-move")
    let owed = backend.undelivered
    require owed.len > 0
    backend.deliverPendingEvents()
    check backend.undelivered == owed
    let service = backend.toBackendService()
    var first, second: seq[string]
    service.onEvent(proc(event: JsonNode) = first.add(event["kind"].getStr()))
    service.onEvent(proc(event: JsonNode) = second.add(event["kind"].getStr()))
    check first.len == 0 and second.len == 0
    backend.deliverPendingEvents()
    check first == @["initialized", "capabilities", "stopped", "ct/complete-move"]
    check second == first
    let rawCapability = backend.waitForEvent("capabilities")
    check not rawCapability{"body", "capabilities", "supportsSteppingGranularity"}.getBool(true)
    backend.deliverPendingEvents()
    check first.len == 4 and second.len == 4

    first = @[]
    second = @[]
    var nested = false
    service.onEvent(proc(event: JsonNode) =
      if event["kind"].getStr() == "capabilities" and not nested:
        nested = true
        discard service.send("threads", newJObject()))
    discard backend.sendDapRequest("next")
    discard backend.waitForEvent("stopped")
    discard backend.waitForEvent("ct/complete-move")
    check first.len == 0
    backend.deliverPendingEvents()
    check nested
    check first == @["capabilities", "stopped", "ct/complete-move", "ct/handoff-followup"]
    check second == first
    backend.deliverPendingEvents()
    check first.len == 4 and second.len == 4
    var failOnce = true
    service.onEvent(proc(event: JsonNode) =
      if event["kind"].getStr() == "capabilities" and failOnce:
        failOnce = false
        raise newException(IOError, "controlled subscriber refusal"))
    discard backend.sendDapRequest("next")
    try:
      backend.deliverPendingEvents()
      check false
    except IOError as error:
      check error.msg == "controlled subscriber refusal"
    check first.len == 5 and second.len == 5
    check backend.undelivered.len == 2
    backend.deliverPendingEvents()
    check first[4 .. ^1] == @["capabilities", "stopped", "ct/complete-move"]
    check second == first
    discard backend.sendDapRequest("next")
    backend.close()
    backend.deliverPendingEvents()
    check first.len == 7 and second.len == 7

  test "headless startup delivers capabilities before any pane request":
    let (session, log) = headlessPeer("capability-startup")
    defer: session.close()
    check session.session.store.session.val.supportsSteppingGranularity
    check session.session.store.session.val.supportsStepBack
    check requests(log) == @["initialize", "configurationDone", "launch"]

  test "raw headless navigation delivers capability changes without another RPC":
    let (session, log) = headlessPeer("capability-navigation")
    defer: session.close()
    check not session.session.store.session.val.supportsSteppingGranularity
    session.stepForward()
    check session.session.store.session.val.supportsSteppingGranularity
    check requests(log) == @["initialize", "configurationDone", "launch", "next"]
    session.stepForward()
    check not session.session.store.session.val.supportsSteppingGranularity
    check session.session.store.session.val.supportsStepBack
    check requests(log) == @["initialize", "configurationDone", "launch", "next", "next"]

  test "stderr between body bytes does not alter the DAP message":
    let backend = start("fragment")
    defer: backend.close()
    check backend.readDapMessage() == parseJson(Body)
    check backend.diagnosticTail() == Diagnostic

  test "stderr exceeding pipe capacity drains before a protocol response":
    let backend = start("flood")
    defer: backend.close()
    check backend.readDapMessage() == parseJson(Body)
    let tail = backend.diagnosticTail()
    check tail.startsWith("[stderr truncated; showing last 65536 bytes]\n")
    check tail.endsWith("\nlast engine diagnostic\n")
    check tail.len == 65536 + "[stderr truncated; showing last 65536 bytes]\n".len

  test "stderr drains while the caller does not read another DAP message":
    let root = createTempDir("ct-stderr-idle-", "")
    defer: removeDir(root)
    let marker = root / "finished"
    let backend = start("idle", marker)
    defer: backend.close()
    check backend.readDapMessage() == parseJson(Body)
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while not fileExists(marker) and getMonoTime() < deadline:
      sleep(5)
    check fileExists(marker)
    check backend.diagnosticTail().endsWith("\nlast engine diagnostic\n")

  test "fatal EOF reports the engine's own diagnostic without a scheduling race":
    # Repetition catches the race between stdout EOF and final stderr capture.
    for _ in 0 ..< 20:
      let backend = start("fatal")
      try:
        discard backend.readDapMessage()
        check false
      except IOError as error:
        check error.msg.contains("engine refused the trace: missing metadata")
      finally:
        backend.close()

  test "close is idempotent and retains diagnostic text":
    let backend = start("fragment")
    discard backend.readDapMessage()
    backend.close()
    backend.close()
    check backend.isClosed()
    check backend.diagnosticTail() == Diagnostic

  test "a stalled read retains the engine's available diagnostic":
    let root = createTempDir("ct-stderr-stall-", "")
    defer: removeDir(root)
    let marker = root / "ready"
    let backend = start("stall", marker)
    defer: backend.close()
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while not fileExists(marker) and getMonoTime() < deadline:
      sleep(5)
    require fileExists(marker)
    backend.bound.timeoutMs = 100
    try:
      discard backend.readDapMessage()
      check false
    except DapStalledError as error:
      check error.msg.contains("engine is unable to finish loading")

  when defined(posix):
    test "close kills and reaps a direct child that ignores stdin EOF":
      let backend = start("stubborn")
      let childPid = Pid(processID(backend.process))
      defer:
        backend.close()
        # waitpid returning zero establishes that a surviving child is still
        # ours before cleanup signals it. Never signal an unowned PID.
        var status: cint
        if waitpid(childPid, status, WNOHANG) == 0:
          discard posix.kill(childPid, SIGKILL)
          discard waitpid(childPid, status, 0)
      check backend.readDapMessage() == parseJson(Body)
      let before = getMonoTime()
      backend.close()
      check (getMonoTime() - before).inMilliseconds < 10000
      check posix.kill(childPid, 0) == -1
      check osLastError().cint == ESRCH
      var status: cint
      check waitpid(childPid, status, WNOHANG) == -1
      check osLastError().cint == ECHILD

    test "close stops the reader before a descendant closes the stderr pipe":
      let root = createTempDir("ct-stderr-held-", "")
      let marker = root / "release"
      let backend = start("held", marker)
      defer:
        writeFile(marker, "release")
        backend.close()
        let deadline = getMonoTime() + initDuration(seconds = 10)
        while not fileExists(marker & ".done") and getMonoTime() < deadline:
          sleep(5)
        doAssert fileExists(marker & ".done"), "descendant did not finish"
        removeDir(root)
      check backend.readDapMessage() == parseJson(Body)
      let before = getMonoTime()
      backend.close()
      check (getMonoTime() - before).inMilliseconds < 5000
      check backend.diagnosticTail() == Diagnostic
