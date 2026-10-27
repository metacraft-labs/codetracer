## test_ct_host_manifest_opens_the_named_slice.nim
##
## `ct host --manifest` given a codetracer-ci recording manifest of kind
## `mcr_slices` opens the slice its `replayStart` names (`sliceKey`) or, when it
## names none, the slice `CODETRACER_START_SLICE_KEY` in its environment names;
## refuses a manifest whose named slice it does not list; and without either
## opens the first slice (`CLI/ct/host.md`, "The start position"; `src/ct/trace/host.nim`,
## `selectMcrSlice`).
##
## ## Why the claim matters
##
## Recording-manifest slices carry no geid range, so `ct host` has nothing of
## its own to find the slice holding the start geid by. It used to import the
## first slice whatever the start said, and a start geid in any later slice was
## then refused by the replay (before the slice's first event): the session
## opened at the wrong slice's entry with an error notification (codetracer-pm
## issue `2026-10-17-ct-host-opens-the-first-slice-of-a-recording-manifest-
## whatever-its-start-geid.md`). The replay agent now names the slice the
## Monolith's debug-session lookup resolved (`CODETRACER_START_SLICE_KEY`,
## written into the manifest's `replayStart.sliceKey` by the runner image's
## entrypoint).
##
## ## What runs
##
## The real `ct host --manifest` (default: `src/build-debug/bin/ct`, or
## `CODETRACER_CT_BIN`), which starts the real `node server_index.js`. The two
## slices are two different recordings checked into this repository, each
## recorded in a directory named after it:
##
## - slice 0: `src/db-backend/tests/fixtures/gdscript/gf_values/` (made in `.../gf_values/trace`)
## - slice 1: `src/db-backend/tests/fixtures/gdscript/gf_coroutine/` (made in `.../gf_coroutine/trace`)
##
## copied into a scratch storage root under the object keys a recording
## manifest names (`traces/slice_000N/gdscript_trace.ct`), beside the manifest
## at `traces/manifest.json`, as the replay agent's local storage lays them out.
## Which slice the session serves is read from what the hosted session sends a
## client over its real socket (socket.io's own client under node, admitted with
## the session secret from the page's origin): the `CODETRACER::trace-loaded`
## the index sends after `CODETRACER::init`, whose `trace.workdir` is the
## recording's own metadata (`meta.dat`) and names the fixture. That is the
## trace an operator's page opens, and the unfixed `ct host` sends it too, so
## the test does not depend on the `selected mcr slice` line it also checks.
##
## No mocks. The manifest is hand-written in the shape codetracer-ci's
## `RecordingManifest` serializes to (and the entrypoint generates); the slice
## files are real recordings, not slices cut from one recording, because which
## one is served is the property, and the slices of one recording would share
## their metadata.
##
## ## The arms
##
## - The manifest names the second slice: the session serves the `gf_coroutine`
##   recording and not the `gf_values` one. (Red on the unfixed `ct host`,
##   which serves the first slice.)
## - The manifest names no slice (the control): the session serves the first,
##   `gf_values`, and not `gf_coroutine`. This is also the vacuity guard:
##   the observable tells the two recordings apart.
## - The manifest names no slice and `ct host`'s environment carries
##   `CODETRACER_START_SLICE_KEY` naming the second: the session serves
##   `gf_coroutine`. This is the stored recording manifest the entrypoint hands
##   over through `CODETRACER_LOCAL_MANIFEST_PATH` as recorded, with the replay
##   agent's variable beside it. (Red without the fallback, which serves the
##   first slice.)
## - The manifest names the first slice and the variable the second: the
##   manifest wins, and the session serves `gf_values`.
## - The manifest names a slice it does not list: `ct host` exits non-zero,
##   naming the key and that the replay start named it, without serving
##   either slice.
## - The manifest names no slice and the variable names one it does not list:
##   refused the same way, the error naming the variable as the key's source.
##
## Lane: `ct-host-manifest` (`just test-ct-host-manifest`).

import std/[httpclient, json, net, os, osproc, posix, streams, strtabs, strutils,
            times, unittest]

# The scratch directory under `/tmp`, and the check that its `CODETRACER_HOME`
# leaves room for the session manager's Unix sockets (`sun_path`): shared with
# the `ct-host-admission` suites.
import ../ct_host/ct_host_scratch

# One line: `ci/lib/run-nim-test-lane.sh` reads this spelling as the runtime
# assertion count.
const ExpectedAssertions = 32

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  StartupTimeoutMs = 180_000
  SessionTimeoutMs = 60_000
  FirstFixtureRelDir = "src/db-backend/tests/fixtures/gdscript/gf_values"
  SecondFixtureRelDir = "src/db-backend/tests/fixtures/gdscript/gf_coroutine"
  FirstSource = "gf_values.gd"
  SecondSource = "gf_coroutine.gd"
  # The tail of the directory each fixture was recorded in.
  FirstWorkdirTail = "/gf_values/trace"
  SecondWorkdirTail = "/gf_coroutine/trace"
  ManifestKey = "traces/manifest.json"
  FirstSliceKey = "traces/slice_0000/gdscript_trace.ct"
  SecondSliceKey = "traces/slice_0001/gdscript_trace.ct"
  UnknownSliceKey = "traces/slice_0007/gdscript_trace.ct"

proc repoRoot(): string =
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
  root = repoRoot()
  ctBinary = getEnv("CODETRACER_CT_BIN", root / "src" / "build-debug" / "bin" / "ct")
  prefixModules = ctBinary.parentDir.parentDir / "node_modules"
  nodeModules =
    if dirExists(prefixModules / "socket.io-client"): prefixModules
    else: root / "node_modules"

type
  Host = object
    process: Process
    logPath: string
    pageOrigin: string
    secret: string
    socketPort: int

proc freePort(): int =
  let probe = newSocket()
  try:
    probe.bindAddr(Port(0), "127.0.0.1")
    result = int(probe.getLocalAddr()[1])
  finally:
    probe.close()

proc answers(url: string): bool =
  var client = newHttpClient(timeout = 5_000, maxRedirects = 0)
  try:
    discard client.request(url, httpMethod = HttpGet)
    result = true
  except CatchableError:
    result = false
  finally:
    client.close()

proc readLog(path: string): string =
  try: readFile(path) except CatchableError: ""

proc writeStore(scratch: string; replayStart: JsonNode): string =
  ## A local storage root holding the two slices under their object keys and
  ## the recording manifest that lists them; returns the manifest's path.
  let store = scratch / "store"
  for (key, fixture) in [(FirstSliceKey, FirstFixtureRelDir),
                         (SecondSliceKey, SecondFixtureRelDir)]:
    copyDir(root / fixture, store / key.parentDir)
    moveFile(store / key.parentDir / "gdscript_trace.ct", store / key)
  let manifest = %*{
    "kind": "mcr_slices",
    "uploadCompletionState": "complete",
    "retentionStatus": "available",
    "manifestS3Key": ManifestKey,
    "mcrSlices": [
      {"sliceIndex": 0, "sliceKey": FirstSliceKey,
       "uploadCompletionState": "complete", "retentionStatus": "available"},
      {"sliceIndex": 1, "sliceKey": SecondSliceKey,
       "uploadCompletionState": "complete", "retentionStatus": "available"}
    ],
    "shardedMcrSegments": [],
    "materializedTraceArtifacts": [],
    "replayStart": replayStart
  }
  result = store / ManifestKey
  writeFile(result, $manifest)

proc launchHost(scratch, manifestPath: string;
                startSliceKeyEnv = ""): Host =
  ## `ct host --manifest` in its own session (so stopping it stops the node
  ## index it starts), its output in a file. A non-empty `startSliceKeyEnv` is
  ## exported as `CODETRACER_START_SLICE_KEY`, as the replay agent does.
  let ctHome = scratch / HomeDirName
  requireSocketPathsFit(ctHome)
  result.socketPort = freePort()
  result.logPath = scratch / "ct-host.log"
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key in ["CODETRACER_HOST_SESSION_SECRET", "CODETRACER_HOST_ALLOWED_ORIGINS",
               "CODETRACER_RECORDING_ID", "CODETRACER_PREFIX", "NODE_PATH",
               "CODETRACER_LOCAL_MANIFEST_PATH", "CODETRACER_LOCAL_STORAGE_ROOT"] or
        key.startsWith("CODETRACER_START_"):
      continue
    env[key] = value
  env["CODETRACER_HOME"] = ctHome
  env["XDG_DATA_HOME"] = scratch / "xdg-data"
  env["XDG_CONFIG_HOME"] = scratch / "xdg-config"
  env["TMPDIR"] = scratch
  env["CODETRACER_IN_UI_TEST"] = "1"
  env["CT_TEST_LOG"] = result.logPath
  if startSliceKeyEnv.len > 0:
    env["CODETRACER_START_SLICE_KEY"] = startSliceKeyEnv
  let wrapper = "exec >\"$CT_TEST_LOG\" 2>&1; exec \"$@\""
  result.process = startProcess("/usr/bin/env", workingDir = root, env = env,
    args = @["setsid", "bash", "-c", wrapper, "bash", ctBinary, "host",
             "--port", "0",
             "--backend-socket-port", $result.socketPort,
             "--frontend-socket", $result.socketPort,
             "--idle-timeout", "120s",
             "--manifest", manifestPath],
    options = {})

proc waitForUrl(host: var Host) =
  ## Reads the page origin and the generated secret from the URL line, and
  ## waits for the socket listener to answer.
  let deadline = epochTime() + StartupTimeoutMs / 1000
  while epochTime() < deadline:
    for line in readLog(host.logPath).splitLines():
      if line.startsWith("CODETRACER_HOST_URL="):
        let url = line["CODETRACER_HOST_URL=".len .. ^1].strip()
        let marker = "/?ct_session="
        let at = url.find(marker)
        if at > 0:
          host.pageOrigin = url[0 ..< at]
          host.secret = url[at + marker.len .. ^1]
    if host.secret.len > 0 and
        answers("http://127.0.0.1:" & $host.socketPort & "/socket.io/?EIO=4&transport=polling"):
      return
    if not host.process.running:
      break
    sleep(250)
  raise newException(IOError, "`ct host` printed no CODETRACER_HOST_URL with a " &
    "session secret, or its socket did not answer:\n" & readLog(host.logPath))

proc waitForExit(host: Host; timeoutMs: int): int =
  ## The exit code, or -1 when `ct host` was still running at the deadline.
  let deadline = epochTime() + timeoutMs / 1000
  while epochTime() < deadline:
    let code = host.process.peekExitCode()
    if code != -1:
      return code
    sleep(250)
  -1

proc stopHost(host: var Host) =
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

const SessionClient = """
'use strict';
// One admitted session: answer the index's bootstrap and report what it sends
// about the trace it loaded, as one JSON line. The index sends each payload as
// a JSON string.
const io = require('socket.io-client');
const out = { connected: false, error: null, init: false, trace: null };
const socket = io('http://127.0.0.1:' + process.env.CT_TEST_SOCKET_PORT, {
  transports: ['websocket'], forceNew: true, reconnection: false, timeout: 5000,
  query: { ct_session: process.env.CT_TEST_SECRET },
  extraHeaders: { Origin: process.env.CT_TEST_PAGE_ORIGIN },
});
const done = () => {
  socket.close();
  process.stdout.write(JSON.stringify(out) + '\n');
  process.exit(0);
};
const timer = setTimeout(() => { out.error = out.error || 'timeout'; done(); },
  Number(process.env.CT_TEST_SESSION_TIMEOUT_MS));
socket.on('connect_error', (e) => { out.error = String(e && e.message); clearTimeout(timer); done(); });
socket.on('connect', () => { out.connected = true; });
socket.on('CODETRACER::started', () => socket.emit('CODETRACER::started', {}));
socket.on('CODETRACER::init', () => { out.init = true; });
socket.on('CODETRACER::trace-loaded', (payload) => {
  const parsed = typeof payload === 'string' ? JSON.parse(payload) : payload;
  const trace = (parsed && parsed.trace) || {};
  out.trace = { recordingId: trace.recordingId, program: trace.program, workdir: trace.workdir };
  clearTimeout(timer);
  done();
});
"""

proc runSessionClient(host: Host; scratch: string): JsonNode =
  let script = scratch / "session_client.js"
  writeFile(script, SessionClient)
  var env = newStringTable(modeCaseSensitive)
  env["PATH"] = getEnv("PATH")
  env["NODE_PATH"] = nodeModules
  env["CT_TEST_SOCKET_PORT"] = $host.socketPort
  env["CT_TEST_PAGE_ORIGIN"] = host.pageOrigin
  env["CT_TEST_SECRET"] = host.secret
  env["CT_TEST_SESSION_TIMEOUT_MS"] = $SessionTimeoutMs
  let p = startProcess("node", args = @[script], env = env,
                       options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll()
  discard p.waitForExit()
  p.close()
  for line in output.splitLines():
    if line.startsWith("{"):
      return parseJson(line)
  raise newException(IOError, "the session client printed no result:\n" & output)

proc servedWorkdir(seen: JsonNode): string =
  ## The working directory the served recording was made in, as the session's
  ## `CODETRACER::trace-loaded` reports it. It is the recording's own metadata
  ## (`meta.dat`), and each fixture was recorded in a directory named after it.
  seen{"trace", "workdir"}.getStr

proc hostSession(replayStart: JsonNode; startSliceKeyEnv = ""):
    tuple[seen: JsonNode, log: string] =
  ## Hosts a manifest with `replayStart` (and `startSliceKeyEnv` in `ct host`'s
  ## environment), opens one session on it, and stops it.
  let scratch = createHostScratch("ct-host-manifest-")
  var host: Host
  try:
    host = launchHost(scratch, writeStore(scratch, replayStart), startSliceKeyEnv)
    waitForUrl(host)
    result.seen = runSessionClient(host, scratch)
    result.log = readLog(host.logPath)
  finally:
    stopHost(host)
    removeDir(scratch)

proc refusedHost(replayStart: JsonNode; startSliceKeyEnv = ""):
    tuple[code: int, log: string] =
  ## Hosts a manifest with `replayStart` (and `startSliceKeyEnv` in `ct host`'s
  ## environment) that `ct host` is expected to refuse: waits for it to exit,
  ## and returns its exit code (-1: still running at the deadline, i.e. it
  ## hosted something) and its output.
  let scratch = createHostScratch("ct-host-manifest-")
  var host: Host
  try:
    host = launchHost(scratch, writeStore(scratch, replayStart), startSliceKeyEnv)
    result.code = waitForExit(host, StartupTimeoutMs)
    result.log = readLog(host.logPath)
  finally:
    stopHost(host)
    removeDir(scratch)

template checkRefused(refused: tuple[code: int, log: string]; source: string) =
  ## `ct host` exited non-zero naming `UnknownSliceKey` and where the key came
  ## from (`source`), and announced no hosted session. A template, so each
  ## check counts against the test that runs it.
  let (code, log) = refused  # evaluated once: it runs `ct host`
  checkpoint("exit code " & $code)
  checkpoint(log)
  ck code > 0
  ck log.contains("ct host: error: failed to load local manifest:")
  ck log.contains("does not list the slice " & source & " names: " & UnknownSliceKey)
  ck not log.contains("CODETRACER_HOST_URL=")

suite "ct host --manifest opens the slice the replay start names":

  test "the prerequisites are present":
    # Not skips: a missing prerequisite is a broken environment.
    if not fileExists(ctBinary):
      checkpoint("missing " & ctBinary & "; build it (`just build-once`) or " &
                 "set CODETRACER_CT_BIN")
    ck fileExists(ctBinary)
    ck findExe("node").len > 0
    ck dirExists(nodeModules / "socket.io-client")
    ck fileExists(root / FirstFixtureRelDir / FirstSource) and
       fileExists(root / SecondFixtureRelDir / SecondSource)

  test "a replay start naming the second slice opens the second slice":
    let (seen, log) = hostSession(%*{"geid": "120045", "sliceKey": SecondSliceKey})
    checkpoint($seen)
    checkpoint(log)
    ck seen["connected"].getBool
    ck seen["init"].getBool
    let served = servedWorkdir(seen)
    ck served.endsWith(SecondWorkdirTail)
    ck not served.endsWith(FirstWorkdirTail)
    ck log.contains("ct host: selected mcr slice: " & SecondSliceKey)

  test "a replay start naming no slice opens the first slice":
    let (seen, log) = hostSession(%*{"geid": "120045"})
    checkpoint($seen)
    checkpoint(log)
    ck seen["connected"].getBool
    ck seen["init"].getBool
    let served = servedWorkdir(seen)
    ck served.endsWith(FirstWorkdirTail)
    ck not served.endsWith(SecondWorkdirTail)
    ck log.contains("ct host: selected mcr slice: " & FirstSliceKey)

  test "a replay start naming no slice opens the slice CODETRACER_START_SLICE_KEY names":
    let (seen, log) = hostSession(%*{"geid": "120045"}, startSliceKeyEnv = SecondSliceKey)
    checkpoint($seen)
    checkpoint(log)
    ck seen["connected"].getBool
    ck seen["init"].getBool
    let served = servedWorkdir(seen)
    ck served.endsWith(SecondWorkdirTail)
    ck not served.endsWith(FirstWorkdirTail)
    ck log.contains("ct host: selected mcr slice: " & SecondSliceKey)

  test "a replay start naming a slice outranks CODETRACER_START_SLICE_KEY":
    let (seen, log) = hostSession(%*{"geid": "120045", "sliceKey": FirstSliceKey},
                                  startSliceKeyEnv = SecondSliceKey)
    checkpoint($seen)
    checkpoint(log)
    ck seen["connected"].getBool
    ck seen["init"].getBool
    let served = servedWorkdir(seen)
    ck served.endsWith(FirstWorkdirTail)
    ck not served.endsWith(SecondWorkdirTail)
    ck log.contains("ct host: selected mcr slice: " & FirstSliceKey)

  test "a replay start naming a slice the manifest does not list is refused":
    checkRefused(refusedHost(%*{"geid": "120045", "sliceKey": UnknownSliceKey}),
                 "its replay start")

  test "a CODETRACER_START_SLICE_KEY naming a slice the manifest does not list is refused":
    checkRefused(refusedHost(%*{"geid": "120045"}, startSliceKeyEnv = UnknownSliceKey),
                 "CODETRACER_START_SLICE_KEY")

suite "assertion count":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
