## ct_host_harness.nim
##
## The real `ct host`, started and stopped for the suites in this directory
## (lane `ct-host-admission`, `just test-ct-host-admission`). Not a suite: the
## lane runs `test_*.nim` only.
##
## `startHost` runs `ct host --trace-path` (default binary:
## `src/build-debug/bin/ct`, or `CODETRACER_CT_BIN`) on a recording checked
## into this repository, in its own process group so that stopping it stops
## the node index and the replay processes it starts, with a scratch
## `CODETRACER_HOME`. The page port is auto-assigned and read back from the
## `CODETRACER_HOST_URL=` line, which is also where the generated session
## secret comes from, as it would be for an operator.

import std/[httpclient, net, os, osproc, posix, streams, strtabs, strutils, times]

const
  StartupTimeoutMs* = 120_000
  FixtureRelPath* = "src/db-backend/tests/fixtures/gdscript/gf_values/gdscript_trace.ct"
    ## A materialized recording that every host can replay: no rr, no
    ## recorder, no network.

proc repoRoot*(): string =
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

let
  root* = repoRoot()
  ctBinary* = getEnv("CODETRACER_CT_BIN", root / "src" / "build-debug" / "bin" / "ct")
  prefixModules = ctBinary.parentDir.parentDir / "node_modules"
  # Where `socket.io-client` is: the prefix's `node_modules`, else the
  # checkout's.
  nodeModules* =
    if dirExists(prefixModules / "socket.io-client"): prefixModules
    else: root / "node_modules"

type
  Answer* = object
    status*: int
    body*: string
    allowOrigin*: string

  Host* = object
    process*: Process
    logPath*: string
    pageOrigin*: string
    secret*: string
    socketPort*: int

proc freePort*(): int =
  let probe = newSocket()
  try:
    probe.bindAddr(Port(0), "127.0.0.1")
    result = int(probe.getLocalAddr()[1])
  finally:
    probe.close()

proc request*(url: string; headers: openArray[(string, string)] = []): Answer =
  var client = newHttpClient(timeout = 10_000, maxRedirects = 0)
  try:
    client.headers = newHttpHeaders(@headers)
    let response = client.request(url, httpMethod = HttpGet)
    result.status = response.code.int
    result.body = response.body
    result.allowOrigin = response.headers.getOrDefault("access-control-allow-origin")
  except CatchableError as e:
    result.status = -1
    result.body = $e.name & ": " & e.msg
  finally:
    client.close()

proc readLog*(path: string): string =
  try: readFile(path) except CatchableError: ""

proc startHost*(scratch: string): Host =
  ## `ct host` in its own session (so stopping it stops the node index it
  ## starts), its output in a file, and the URL line read from that file.
  result.socketPort = freePort()
  result.logPath = scratch / "ct-host.log"
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key in ["CODETRACER_HOST_SESSION_SECRET", "CODETRACER_HOST_ALLOWED_ORIGINS",
               "CODETRACER_RECORDING_ID", "CODETRACER_PREFIX", "NODE_PATH"]:
      continue
    env[key] = value
  env["CODETRACER_HOME"] = scratch / "ct-home"
  env["XDG_DATA_HOME"] = scratch / "xdg-data"
  env["XDG_CONFIG_HOME"] = scratch / "xdg-config"
  env["TMPDIR"] = scratch
  env["CODETRACER_IN_UI_TEST"] = "1"
  env["CT_TEST_LOG"] = result.logPath
  let wrapper = "exec >\"$CT_TEST_LOG\" 2>&1; exec \"$@\""
  result.process = startProcess("/usr/bin/env", workingDir = root, env = env,
    args = @["setsid", "bash", "-c", wrapper, "bash", ctBinary, "host",
             "--port", "0",
             "--backend-socket-port", $result.socketPort,
             "--frontend-socket", $result.socketPort,
             "--idle-timeout", "120s",
             "--trace-path", root / FixtureRelPath],
    options = {})
  let deadline = epochTime() + StartupTimeoutMs / 1000
  while epochTime() < deadline:
    for line in readLog(result.logPath).splitLines():
      if line.startsWith("CODETRACER_HOST_URL="):
        let url = line["CODETRACER_HOST_URL=".len .. ^1].strip()
        let marker = "/?ct_session="
        let at = url.find(marker)
        if at > 0:
          result.pageOrigin = url[0 ..< at]
          result.secret = url[at + marker.len .. ^1]
    # The URL line comes from the page server's listen callback; the socket
    # listener starts in the same tick, so wait for it to answer too.
    if result.secret.len > 0 and
        request("http://127.0.0.1:" & $result.socketPort & "/socket.io/?EIO=4&transport=polling").status > 0:
      return
    if not result.process.running:
      break
    sleep(250)
  raise newException(IOError, "`ct host` printed no CODETRACER_HOST_URL with a " &
    "session secret, or its socket did not answer:\n" & readLog(result.logPath))

proc stopHost*(host: var Host) =
  if host.process.isNil:
    return
  let group = Pid(host.process.processID)
  discard posix.kill(-group, SIGTERM)
  let deadline = epochTime() + 10
  while host.process.running and epochTime() < deadline:
    sleep(100)
  discard posix.kill(-group, SIGKILL)
  discard host.process.waitForExit()
  host.process.close()
  host.process = nil

proc runNodeScript*(host: Host; script: string;
                    extraEnv: openArray[(string, string)] = []): tuple[output: string, exitCode: int] =
  ## Run `script` (a file) under node with `socket.io-client` on its module
  ## path and the host's coordinates in its environment
  ## (`CT_TEST_SOCKET_PORT`, `CT_TEST_PAGE_ORIGIN`, `CT_TEST_SECRET`).
  var env = newStringTable(modeCaseSensitive)
  env["PATH"] = getEnv("PATH")
  env["NODE_PATH"] = nodeModules
  env["CT_TEST_SOCKET_PORT"] = $host.socketPort
  env["CT_TEST_PAGE_ORIGIN"] = host.pageOrigin
  env["CT_TEST_SECRET"] = host.secret
  for (key, value) in extraEnv:
    env[key] = value
  let p = startProcess("node", args = @[script], env = env,
                       options = {poUsePath, poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.exitCode = p.waitForExit()
  p.close()
