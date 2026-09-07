## test_webui_equivalence.nim — PLAT-1 §7.2, asserted against a running server.
##
## Specification: `codetracer-specs/CLI/ct/ui-selection.md` §7.2 and §7.3.
## Milestone: PLAT-1 — "`ct host <trace>` and `ct replay --ui=webui <trace>`
## produce the same served behaviour, asserted against the same fixture."
##
## ## NO MOCKS, AND NO HTTP STUB
##
## Both arms start the REAL `ct` on the REAL `calc` recording, which spawns the
## REAL `node server_index.js`, and both are read over a REAL HTTP socket with
## `std/httpclient`. The only thing this file supplies is the fixture, and the
## fixture is a recording `ct record` produced.
##
## ## WHY BYTE EQUALITY AND NOT "BOTH RETURNED 200"
##
## §7.3: "`--ui=webui` must not become a *second* implementation of hosting. If
## the two ever disagree, one of them is wrong; there is one code path and two
## spellings of its entry." A status-code comparison is satisfied by two
## different servers that both work, which is exactly the state §7.3 forbids —
## so the assertion is on the BYTES, per path, and it includes a path that is
## NOT served: a 404 body is as much a property of the routing as a 200 is, and
## two implementations would be most likely to disagree there.
##
## ## THE TWO ARMS RUN ON DIFFERENT PORTS, SEQUENTIALLY
##
## Not concurrently: `ct host` binds a fixed socket.io port as well as the HTTP
## one (`DEFAULT_SOCKET_PORT`), so two live servers would collide on it and the
## loser's failure would be read as a difference in behaviour. Different HTTP
## ports because a just-killed listener can sit in TIME_WAIT, and a second bind
## failing on the same port would likewise be read as a disagreement.
##
## THE PORT IS THEREFORE NOT PART OF THE COMPARISON, and the served HTML does
## not contain it — measured, not assumed: `assertNoPortInBody` below fails the
## run if it ever does, rather than silently comparing two documents that differ
## for a reason this file created.

import std/[httpclient, os, osproc, streams, strtabs, strutils, times,
            unittest]

import ../../frontend/tui/tests/fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 34

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  CtRecipe = "just build-once"

  HostPort = 8911
  WebuiPort = 8912
    ## See the header. Chosen high and adjacent so a developer reading a
    ## `netstat` can tell what they belong to.

  IdleTimeout = "45s"
    ## A BACKSTOP, not the teardown. `stopServer` kills both processes; this is
    ## what stops a server surviving a suite that crashed between starting one
    ## and stopping it, which would make the NEXT run's bind fail and be read as
    ## a behavioural difference.

  Paths: array[4, string] = [
    "/",
    "/public/third_party/nouislider.css",
    "/public/resources/shared/codetracer_welcome_logo.svg",
    "/index.js"]
    ## Four requests, and the fourth is the interesting one. The first three are
    ## the document and two assets it references (read out of the served HTML,
    ## not invented); `/index.js` is NOT served — it is the Electron main
    ## process's entry point, which has no business on the web front-end — so it
    ## answers 404, and its body is part of the equivalence.

  StartupTimeoutMs = 120_000
    ## `ct host` imports the recording before it binds, and on a cold page cache
    ## that is seconds rather than milliseconds.

type
  Served = object
    status: string
    body: string

  Server = object
    process: Process
    port: int

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
  ctBinary = root / "src" / "build-debug" / "bin" / "ct"

var
  tracePath = ""
  hostResults: seq[Served] = @[]
  webuiResults: seq[Served] = @[]

proc fetch(port: int; path: string; timeoutMs = 5000): Served =
  ## One request, as a (status, body) pair. A connection refused is a RESULT
  ## rather than an exception, because "nothing answered" is a served behaviour
  ## the two arms have to agree about too.
  var client = newHttpClient(timeout = timeoutMs)
  try:
    let response = client.request("http://127.0.0.1:" & $port & path,
                                  httpMethod = HttpGet)
    result.status = response.status
    result.body = response.body
  except CatchableError as e:
    result.status = "ERROR " & $e.name
    result.body = ""
  finally:
    client.close()

proc startServer(args: seq[string]; port: int): Server =
  ## Start one arm and wait until it answers, or raise naming what it printed.
  ##
  ## The wait is on the SOCKET, not on a sleep: a fixed delay is how a suite
  ## comes to compare a served document with a connection refusal on a slower
  ## machine.
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key == "CODETRACER_UI":
      continue
    env[key] = value
  let logPath = getTempDir() / ("plat1-webui-" & $port & ".log")
  # `poStdErrToStdOut` into a FILE the failure arm can quote: `ct host`'s
  # diagnostics ("no valid port", "error importing trace") are the only thing
  # that distinguishes a slow start from a refusal to start at all.
  let wrapper = "exec >\"$CT_TEST_LOG\" 2>&1; exec \"$@\""
  env["CT_TEST_LOG"] = logPath
  var argv = @["bash", "-c", wrapper, "bash", ctBinary]
  argv.add args
  result.process = startProcess("/usr/bin/env", args = argv, env = env,
                                workingDir = root, options = {})
  result.port = port

  let deadline = epochTime() + float(StartupTimeoutMs) / 1000.0
  while epochTime() < deadline:
    let probe = fetch(port, "/", timeoutMs = 2000)
    if not probe.status.startsWith("ERROR"):
      return
    if not result.process.running:
      let log = try: readFile(logPath) except CatchableError: "(no log)"
      raise newException(IOError,
        "`ct " & args.join(" ") & "` exited before it served anything:\n" & log)
    sleep(250)
  let log = try: readFile(logPath) except CatchableError: "(no log)"
  raise newException(IOError,
    "`ct " & args.join(" ") & "` did not answer on port " & $port &
    " within " & $StartupTimeoutMs & " ms:\n" & log)

proc stopServer(server: var Server) =
  ## Kill the arm AND the `node server_index.js` it spawned.
  ##
  ## BOTH, because the child outlives its parent: it watches `--caller-pid` and
  ## an idle timeout rather than dying with it, so killing only `ct` leaves the
  ## port bound and the next arm's bind failing. Measured on this host —
  ## the listener was still answering 200 twenty seconds after `ct` was killed.
  if server.process.running:
    server.process.terminate()
  discard server.process.waitForExit()
  server.process.close()
  # Matched on the PORT, which is unique to this arm, so a developer's own
  # `ct host` on another port is not caught in it.
  let pattern = "server_index" & ".js .* --port " & $server.port
  let killer = startProcess("/usr/bin/env",
                            args = @["pkill", "-f", pattern],
                            options = {poStdErrToStdOut})
  discard killer.outputStream.readAll()
  discard killer.waitForExit()
  killer.close()
  # …and wait for the socket to actually go away, so the next arm's failure to
  # bind cannot be inherited from this one.
  let deadline = epochTime() + 20.0
  while epochTime() < deadline:
    if fetch(server.port, "/", timeoutMs = 1000).status.startsWith("ERROR"):
      return
    sleep(250)

proc collect(args: seq[string]; port: int): seq[Served] =
  var server = startServer(args, port)
  try:
    for path in Paths:
      result.add fetch(port, path)
  finally:
    stopServer(server)

suite "PLAT-1 §7.2: `ct host` and `ct replay --ui=webui` serve the same thing":

  test "the binary, node and the fixture are all present":
    # FIRST AND SEPARATELY. None of these is a skip: this suite's whole claim
    # needs a running server, and a missing prerequisite is a broken
    # environment rather than a partial one.
    if not fileExists(ctBinary):
      checkpoint("missing " & ctBinary & " — run `" & CtRecipe & "`")
    ck fileExists(ctBinary)
    let node = findExe("node")
    if node.len == 0:
      checkpoint("`node` is not on PATH — `ct host` spawns " &
                 "`node server_index.js`; enter the dev shell")
    ck node.len > 0

    let resolved = resolveFixture(FixtureName)
    if resolved.outcome != foRecorded:
      checkpoint("the `" & FixtureName & "` fixture is unavailable: " &
                 resolved.detail & " — `just test-tui` records and caches it")
    ck resolved.outcome == foRecorded
    tracePath = absolutePath(resolved.tracePath)
    ck dirExists(tracePath)

  test "`ct host --port P --trace-path F` serves the fixture":
    hostResults = collect(@["host", "--port", $HostPort,
                            "--idle-timeout", IdleTimeout,
                            "--trace-path", tracePath], HostPort)
    ck hostResults.len == Paths.len
    # A POSITIVE FACT ABOUT THE ARM, before it is compared with anything: two
    # arms that both failed identically would satisfy every equality below.
    checkpoint("host: " & hostResults[0].status & ", " &
               $hostResults[0].body.len & " bytes")
    ck hostResults[0].status.startsWith("200")
    ck hostResults[0].body.contains("<!doctype html>")
    ck hostResults[0].body.len > 1000

  test "`ct replay --ui=webui --port P --trace-path F` serves it too":
    webuiResults = collect(@["replay", "--ui=webui", "--port", $WebuiPort,
                             "--idle-timeout", IdleTimeout,
                             "--trace-path", tracePath], WebuiPort)
    ck webuiResults.len == Paths.len
    checkpoint("webui: " & webuiResults[0].status & ", " &
               $webuiResults[0].body.len & " bytes")
    ck webuiResults[0].status.startsWith("200")
    ck webuiResults[0].body.contains("<!doctype html>")
    ck webuiResults[0].body.len > 1000

  test "the port is not in any served body, so it is not in the comparison":
    # The one difference this suite CREATES. If a body ever embeds its own
    # port, the equality below would fail for a reason that is not a
    # disagreement between the two spellings — so it is checked rather than
    # assumed, and it fails loudly instead of being normalised away.
    var compared = 0
    for i, path in Paths:
      inc compared
      ck not hostResults[i].body.contains($HostPort)
      ck not webuiResults[i].body.contains($WebuiPort)
    ck compared == Paths.len

  test "every path answers with the SAME status and the SAME bytes":
    # §7.3's rule, as an assertion: one code path, two spellings of its entry.
    var compared = 0
    for i, path in Paths:
      inc compared
      checkpoint(path & ": host=" & hostResults[i].status & " (" &
                 $hostResults[i].body.len & " B)  webui=" &
                 webuiResults[i].status & " (" &
                 $webuiResults[i].body.len & " B)")
      ck hostResults[i].status == webuiResults[i].status
      ck hostResults[i].body == webuiResults[i].body
    ck compared == Paths.len
    ck compared == 4

  test "the fourth path is a 404, and the two agree about that too":
    # THE SWEEP ABOVE IS SATISFIED BY FOUR IDENTICAL 200s, so the shape of the
    # set it swept is asserted here: three served documents and one refusal.
    # Without this, a server that answered `/` for every path would pass.
    ck hostResults[3].status.startsWith("404")
    ck webuiResults[3].status.startsWith("404")
    var served = 0
    for i in 0 ..< 3:
      if hostResults[i].status.startsWith("200"):
        inc served
    ck served == 3

suite "assertion count":

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
