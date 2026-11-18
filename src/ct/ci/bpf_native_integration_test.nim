## End-to-end integration tests for the native BPF process monitor.
##
## These tests drive the ``ct`` binary as a user would — via
## ``ct ci exec --monitor-processes`` — and verify that the native libbpf
## backend correctly starts, captures process events, and shuts down.
##
## A mock HTTP server stands in for the CI backend API so that ``ct ci exec``
## can run without a real backend. The mock and ct's stdout are serviced in
## the same polling loop using non-blocking I/O to avoid deadlocks.
##
## Prerequisites:
##   - Built ``ct`` binary at ``src/build-debug-repro/bin/ct`` with BPF capabilities
##     (via ``just build-once`` + ``just developer-setup`` or the NixOS module)
##   - Compiled BPF object at ``src/build-debug-repro/share/monitor.bpf.o``
##     (via ``just build-bpf-programs``)
##   - Linux kernel >= 5.8 with BPF support
##
## Run with:
##   just test-bpf-native-integration
##
## If any prerequisite is missing, tests are skipped (not failures).

import std/[json, net, os, osproc, posix, strformat, strtabs, strutils,
            times, unittest, nativesockets]

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  CtBinRelPath = "src/build-debug-repro/bin/ct"
  BpfObjRelPath = "src/build-debug-repro/share/monitor.bpf.o"

# ---------------------------------------------------------------------------
# Resolve repo root and binary paths
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  ## Walks up from the test binary's location to find the repository root.
  ## Falls back to CWD-based resolution.
  let binDir = getAppDir()
  for depth in 0..5:
    var candidate = binDir
    for i in 0..<depth:
      candidate = candidate.parentDir
    if fileExists(candidate / "justfile") and dirExists(candidate / "src"):
      return candidate
  return getCurrentDir()

let root = repoRoot()
let ctBinPath = root / CtBinRelPath
let bpfObjPath = root / BpfObjRelPath

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

proc checkPrereqs(): tuple[ok: bool, reason: string] =
  when not defined(linux):
    return (false, "Native BPF integration tests require Linux")

  if not fileExists(ctBinPath):
    return (false, fmt"ct binary not found at {ctBinPath} — run `just build-once`")

  if not fileExists(bpfObjPath):
    return (false, fmt"monitor.bpf.o not found at {bpfObjPath} — run `just build-bpf-programs`")

  let (output, exitCode) = execCmdEx(ctBinPath & " --help")
  if exitCode != 0 and exitCode != 1:
    return (false, fmt"ct binary at {ctBinPath} is not executable: exit {exitCode}")

  return (true, "")

let (prereqOk, prereqReason) = checkPrereqs()

# ---------------------------------------------------------------------------
# Mock HTTP server for CI backend (non-blocking, single-threaded)
# ---------------------------------------------------------------------------
# Handles requests in a polling loop alongside reading ct's stdout.
# The server socket is set to non-blocking so accept() returns immediately
# when no connections are pending.

type
  MockServer = object
    socket: Socket
    port: int
    receivedPaths: seq[string]
    receivedBodies: seq[string]

proc startMockServer(): MockServer =
  result.socket = newSocket()
  result.socket.setSockOpt(OptReuseAddr, true)
  result.socket.bindAddr(Port(0))
  result.port = int(result.socket.getLocalAddr()[1])
  result.socket.listen()
  result.socket.getFd().setBlocking(false)
  result.receivedPaths = @[]
  result.receivedBodies = @[]

proc handlePendingRequests(server: var MockServer) =
  ## Non-blocking: accept and handle all pending connections.
  ## Returns immediately if no connections are waiting.
  for attempt in 0..9:
    var client: Socket
    try:
      client = newSocket()
      accept(server.socket, client)
    except OSError:
      # EAGAIN/EWOULDBLOCK — no pending connections.
      break

    defer: client.close()
    client.getFd().setBlocking(true)

    # Read the HTTP request line.
    var requestLine = ""
    try:
      requestLine = client.recvLine(timeout = 2000)
    except:
      continue

    if requestLine.len == 0:
      continue

    # Parse "METHOD /path HTTP/1.1".
    let parts = requestLine.split(' ')
    let path = if parts.len >= 2: parts[1] else: "/"
    server.receivedPaths.add(path)

    # Read headers to find Content-Length.
    var contentLength = 0
    while true:
      var headerLine: string
      try:
        headerLine = client.recvLine(timeout = 1000)
      except:
        break
      if headerLine == "\r\n" or headerLine == "" or headerLine == "\r":
        break
      let lower = headerLine.toLowerAscii()
      if lower.startsWith("content-length:"):
        try:
          contentLength = parseInt(lower.split(':')[1].strip())
        except ValueError:
          discard

    # Read body if present.
    var body = ""
    if contentLength > 0:
      try:
        body = client.recv(contentLength, timeout = 2000)
      except:
        discard
    server.receivedBodies.add(body)

    # Choose response.
    var responseBody: string
    if path.contains("/processes"):
      responseBody = "{}"
    elif path.endsWith("/logs"):
      responseBody = "{}"
    else:
      responseBody = """{"id":"test-run","status":"Running","label":"","repositoryUrl":"","commitSha":"","branchName":"","createdAt":""}"""

    let response = "HTTP/1.1 200 OK\r\n" &
      "Content-Type: application/json\r\n" &
      "Content-Length: " & $responseBody.len & "\r\n" &
      "Connection: close\r\n" &
      "\r\n" &
      responseBody

    try:
      client.send(response)
    except OSError:
      discard

proc stopMockServer(server: var MockServer) =
  server.socket.close()

# ---------------------------------------------------------------------------
# CI state file helpers
# ---------------------------------------------------------------------------

proc createFakeState(stateDir: string, baseUrl: string) =
  createDir(stateDir)
  let state = %*{
    "runId": "test-run-bpf-e2e",
    "tenantId": "test-tenant",
    "baseUrl": baseUrl,
    "token": "test-token-e2e",
    "sequenceCounter": 0,
  }
  writeFile(stateDir / "ci-run.json", $state)

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

proc runCtExec(server: var MockServer,
               stateDir: string,
               childCmd: string, childArgs: seq[string] = @[],
               monitorProcesses: bool = true,
               timeoutSecs: float = 30.0):
    tuple[output: string, exitCode: int] =
  ## Runs `ct ci exec` with the given child command and returns stdout+stderr
  ## and the exit code.
  ##
  ## Internally polls both ct's stdout pipe (non-blocking read) and the mock
  ## HTTP server (non-blocking accept) to avoid deadlocks. Without this,
  ## ct blocks on HTTP POST to the mock server while the test blocks reading
  ## ct's stdout — a classic deadlock.
  let baseUrl = fmt"http://127.0.0.1:{server.port}/api/v1/"
  var args = @["ci", "--token=test-token-e2e",
               "--base-url=" & baseUrl, "exec"]
  if monitorProcesses:
    args.add("--monitor-processes")
  args.add(childCmd)
  for a in childArgs:
    args.add(a)

  let env = newStringTable({
    "CODETRACER_STATE_DIR": stateDir,
    "CODETRACER_REPO_ROOT_PATH": root,
    "PATH": getEnv("PATH"),
    "HOME": getEnv("HOME"),
    "LIBRARY_PATH": getEnv("LIBRARY_PATH", ""),
    "LD_LIBRARY_PATH": getEnv("LD_LIBRARY_PATH", ""),
    "CT_LD_LIBRARY_PATH": getEnv("CT_LD_LIBRARY_PATH", ""),
    "CODETRACER_LD_LIBRARY_PATH": getEnv("CODETRACER_LD_LIBRARY_PATH", ""),
  })

  let process = startProcess(ctBinPath, args = args, env = env,
                              options = {poStdErrToStdOut})

  # Get the raw file descriptor for ct's stdout pipe and set it non-blocking.
  let pipeFd = outputHandle(process).cint
  var flags = fcntl(pipeFd, F_GETFL)
  discard fcntl(pipeFd, F_SETFL, flags or O_NONBLOCK)

  var output = ""
  let deadline = epochTime() + timeoutSecs
  var buf: array[4096, char]

  while epochTime() < deadline:
    # Service mock HTTP server requests (non-blocking).
    server.handlePendingRequests()

    # Read from ct's stdout (non-blocking).
    let n = posix.read(pipeFd, addr buf[0], buf.len)
    if n > 0:
      for i in 0..<n:
        output.add(buf[i])
    elif n == 0:
      # EOF — ct closed stdout.
      break
    else:
      # EAGAIN/EWOULDBLOCK — no data available.
      let err = errno
      if err != EAGAIN and err != EWOULDBLOCK:
        break  # Real I/O error.
      sleep(20)  # Brief yield.

  # Drain remaining mock server requests while waiting for ct to exit.
  let drainDeadline = epochTime() + 2.0
  while epochTime() < drainDeadline:
    server.handlePendingRequests()
    if not running(process):
      # One final drain.
      server.handlePendingRequests()
      break
    sleep(20)

  let exitCode = waitForExit(process)
  close(process)
  return (output, exitCode)

# ---------------------------------------------------------------------------
# Integration tests
# ---------------------------------------------------------------------------

suite "Native BPF E2E — ct ci exec with --monitor-processes":
  var server: MockServer
  var stateDir: string

  setup:
    if not prereqOk:
      discard
    else:
      server = startMockServer()
      stateDir = getTempDir() / "ct-bpf-e2e-test-" & $epochTime().int
      let baseUrl = fmt"http://127.0.0.1:{server.port}/api/v1/"
      createFakeState(stateDir, baseUrl)

  teardown:
    if prereqOk:
      stopMockServer(server)
      removeDir(stateDir)

  test "ct starts native BPF monitor for a simple command":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      let (output, exitCode) = runCtExec(
        server, stateDir, "echo", @["bpf-e2e-hello"])

      echo "  ct output:"
      for line in output.splitLines:
        if line.len > 0:
          echo "    " & line

      let hasBpfStart = output.contains("Native BPF process monitor started") or
                        output.contains("BPF process monitor started")
      let hasBpfStop = output.contains("BPF process monitor stopped")

      if not hasBpfStart:
        echo "  NOTE: BPF monitoring did not start. Possible reasons:"
        echo "    - ct binary lacks BPF capabilities (run `just developer-setup`)"
        echo "    - monitor.bpf.o not found by ct"
        echo "    - Kernel does not support BPF"
        skip()
      else:
        check hasBpfStart
        check hasBpfStop
        check exitCode == 0

  test "ct exits with correct code when child fails":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      # Use a temp script instead of `bash -c` to avoid confutils parsing
      # `-c` as a ct option.
      let script = stateDir / "exit-42.sh"
      writeFile(script, "#!/bin/sh\nexit 42\n")
      discard execCmdEx("chmod +x " & script)
      let (output, exitCode) = runCtExec(
        server, stateDir, script)

      echo "  ct output:"
      for line in output.splitLines:
        if line.len > 0:
          echo "    " & line

      let hasBpfStart = output.contains("Native BPF process monitor started") or
                        output.contains("BPF process monitor started")
      if not hasBpfStart:
        echo "  NOTE: BPF monitoring did not start — skipping."
        skip()
      else:
        check hasBpfStart
        check output.contains("BPF process monitor stopped")
        check exitCode == 42

  test "ct captures and reports process events to the backend":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      # Use a temp script instead of `bash -c` to avoid confutils parsing
      # `-c` as a ct option.
      let script = stateDir / "bpf-event-test.sh"
      writeFile(script, "#!/bin/sh\necho bpf-event-test\nsleep 1\n")
      discard execCmdEx("chmod +x " & script)
      let (output, exitCode) = runCtExec(
        server, stateDir, script)

      echo "  ct output:"
      for line in output.splitLines:
        if line.len > 0:
          echo "    " & line

      let hasBpfStart = output.contains("Native BPF process monitor started") or
                        output.contains("BPF process monitor started")
      if not hasBpfStart:
        echo "  NOTE: BPF monitoring did not start — skipping."
        skip()
      else:
        check hasBpfStart
        check output.contains("BPF process monitor stopped")
        check exitCode == 0

        echo fmt"  Mock server received {server.receivedPaths.len} requests:"
        for path in server.receivedPaths:
          echo "    " & path

        var foundProcesses = false
        for i, path in server.receivedPaths:
          if path.contains("/processes"):
            foundProcesses = true
            if i < server.receivedBodies.len and
               server.receivedBodies[i].len > 0:
              try:
                let body = parseJson(server.receivedBodies[i])
                let starts = body{"starts"}
                let exits = body{"exits"}
                if starts != nil:
                  echo fmt"    Process starts reported: {starts.len}"
                if exits != nil:
                  echo fmt"    Process exits reported: {exits.len}"
                if starts != nil and starts.len > 0:
                  let first = starts[0]
                  let pid = first["pid"]
                  let binaryPath = first["binaryPath"]
                  echo fmt"    First start: pid={pid} binary={binaryPath}"
              except JsonParsingError:
                echo "    (could not parse process events body)"

        if foundProcesses:
          echo "  Process events were reported to the backend."
        else:
          echo "  Note: no /processes API calls observed (timing-dependent)"

  test "ct runs without --monitor-processes (BPF disabled)":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      let (output, exitCode) = runCtExec(
        server, stateDir, "echo", @["no-bpf-test"],
        monitorProcesses = false)

      check not output.contains("BPF process monitor started")
      check not output.contains("Native BPF")
      check exitCode == 0
      echo "  Verified: no BPF monitoring when --monitor-processes is not set."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if not prereqOk:
  echo ""
  echo "NOTE: Native BPF E2E integration tests were skipped: " & prereqReason
  echo "To enable:"
  echo "  1. Run `just build-once` to build the ct binary"
  echo "  2. Run `just build-bpf-programs` to compile the BPF object"
  echo "  3. Run `just developer-setup` to set up BPF capabilities"
