## The controlled child is this same executable, launched through the real
## startReplayServer boundary. A real engine cannot deliberately place a
## diagnostic between two body writes, so this fixture owns precisely that
## write ordering; process creation, pipes and DAP decoding are production code.
## No sleeps establish the corruption: flushes order all three writes even
## when stdout and stderr refer to the same pipe in the unfixed transport.
import std/[json, monotimes, os, osproc, strutils, tempfiles, times, unittest]
when defined(posix):
  import std/posix
import ../../viewmodel/backend/stdio_backend

const Body = "{\"type\":\"event\",\"event\":\"stopped\",\"body\":{\"text\":\"intact\"}}"
const Diagnostic = "engine diagnostic between body bytes\n"

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

proc start(mode: string; marker = ""): DapStdioBackend =
  let previousMode = getEnv("CT_STDIO_DIAGNOSTICS_MODE")
  let previousMarker = getEnv("CT_STDIO_DIAGNOSTICS_MARKER")
  putEnv("CT_STDIO_DIAGNOSTICS_MODE", mode)
  putEnv("CT_STDIO_DIAGNOSTICS_MARKER", marker)
  defer:
    putEnv("CT_STDIO_DIAGNOSTICS_MODE", previousMode)
    putEnv("CT_STDIO_DIAGNOSTICS_MARKER", previousMarker)
  startReplayServer(getAppFilename(),
    bound = DapReadBound(timeoutMs: 10000, interruptFd: -1))

suite "stdio DAP diagnostics":
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
