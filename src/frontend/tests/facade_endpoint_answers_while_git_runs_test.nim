## facade_endpoint_answers_while_git_runs_test.nim
##
## `ct host` KEEPS ANSWERING WHILE A FACADE VERB'S CHILD PROCESS RUNS.
##
## ## The defect this pins
##
## The page's VCS pane refreshes `vcs.status` every 5 s and its certificate
## indicator computes `vcs.contentId` every 15 s. Under `ct host` both are
## facade verbs served by the index process, which ran every one of them
## through `child_process.spawnSync` on the one event loop that also carries
## the page's IPC and every other client's. On a loaded host a `git status`
## took 2.4-3.0 s and a content-id cycle 3.5 s; the loop was blocked 4-13 s at
## a time, and a 3 KB `tab-load` answer arrived 4-27 s late (codetracer-pm
## issue
## `2026-11-11-ct-host-runs-the-pages-periodic-git-reads-synchronously-on-the-server-event-loop`).
## `CLI/ct/host.md`, "A facade verb never holds the server's event loop", is
## the rule this suite holds the server to.
##
## ## The claims
##
## For each of the three kinds of verb that runs a child process —
## `vcs.status` (one git run), `vcs.contentId` (a recipe of several) and
## `process.run` — client A sends the slow call and client B, a second
## connection to the same server, then sends `fs.readText`:
##
##   1. **B is answered while A's child is still running.** B's reply arrives
##      before A's, and within `BSendDelayMs + PromptMs` of A's call — sooner
##      than one slow git run. Against the synchronous dispatcher B's frame is
##      not even read until A's verb has returned, so it arrives after A's
##      reply, never before.
##
##      The latency is measured from A's call, not from B's: the clients live
##      in the server's own process, so the timer that sends B is held up by a
##      blocked loop exactly as the server is, and a clock started when B was
##      finally sent would excuse the very wait this suite exists to catch.
##   2. **The server's event loop turns while A's call is outstanding.** An
##      interval timer in the server's own process (this one) ticks while the
##      call is pending. Against `spawnSync` it cannot tick at all.
##   3. **A's answer is still the right one.** The status names the branch the
##      repository is on, the content id is `git rev-parse HEAD^{tree}`, and
##      the process's stdout is what the script printed.
##
## ## What is real, and the one stand-in
##
## REAL: the index's own `setupServer` (`index/server_config.nim`) — its
## socket.io server and the facade endpoint it attaches, over the shipped
## defaults with only the two ports assigned; two socket.io clients over TCP;
## `git` itself, over a repository this suite creates.
##
## THE ONE STAND-IN is the `git` the SERVER finds on `PATH`: a `/bin/sh`
## script that sleeps `SlowGitSeconds` and then `exec`s the real git with the
## same arguments. That is the loaded host of the issue, made deterministic: a
## git that answers in two milliseconds makes "B was answered while A's git
## ran" a race between two sockets; one that takes most of a second per run
## makes it a certainty, and leaves git's answers unchanged. The suite's own
## setup calls the real git by its absolute path, so the delay is paid only
## where it is being measured.
##
## THE CONTENT-ID WORKER runs this suite's own bundle. The server computes
## `vcs.contentId` in the content-id service's worker thread
## (`index/content_id_service.nim`), whose shipped script
## (`content_id_worker.js`) does not sit beside a suite the lane compiled on
## its own. Started as that worker, this bundle serves content-id requests
## (`content_id_worker.serveContentIdRequests`, the shipped worker's whole
## body) and runs none of the suite: its statements are behind
## `isMainThread()`, because the worker shares this process's environment.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`.

import std/[json, jsffi, strutils]

import lib/src_relative_require
import ../index/config
import ../index/server_config
import ../index/content_id_service
import ../index/content_id_worker
import ../viewmodel/platform/vcs
import ../viewmodel/platform/process
import ../viewmodel/platform/endpoint_protocol
import ../viewmodel/platform/endpoint_codec

const
  SlowGitSeconds = 2.0
    ## How long every git run the SERVER makes takes, at least. Two seconds
    ## rather than 0.8 (2026-11-25): at host load ~100 B's file read alone
    ## took 577 ms, over the 500 ms half of a 0.8 s run, while B still came
    ## back well before A. A longer slow run widens the margin the latency
    ## claim needs without weakening it: B must still answer within half of
    ## one slow git run.
  BSendDelayMs = 100
    ## How long after A's call B asks: a socket round trip later, so A's verb
    ## has certainly started, and well inside one slow git run.
  PromptMs = 900
    ## B must be answered within `BSendDelayMs + PromptMs` of A's call — half
    ## of one slow git run.
    ## B's own verb is a file read; the margin is for a loaded CI host.

var checks = 0
var failedChecks = 0

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

# ---------------------------------------------------------------------------
# node primitives
# ---------------------------------------------------------------------------

proc exitProcess(code: int) {.importjs: "process.exit(#)".}
proc setEnv(key, value: cstring) {.importjs: "process.env[#] = #".}
proc getEnv(key: cstring): cstring {.importjs: "(process.env[#] || '')".}
proc nowMs(): float {.importjs: "Number(process.hrtime.bigint() / 1000000n)".}
proc setInterval(callback: proc(); ms: int): JsObject {.importjs: "setInterval(#, #)".}
proc clearInterval(handle: JsObject) {.importjs: "clearInterval(#)".}
proc laterCall(cb: proc(); ms: int) {.importjs: "setTimeout(#, #)".}

proc makeTempDir(prefix: cstring): cstring {.importjs:
  "require('fs').mkdtempSync(require('path').join(require('os').tmpdir(), #))".}
proc removeTree(path: cstring) {.importjs:
  "require('fs').rmSync(#, { recursive: true, force: true })".}
proc writeFile(path, text: cstring) {.importjs: "require('fs').writeFileSync(#, #)".}
proc writeExecutable(path, text: cstring) {.importjs:
  "require('fs').writeFileSync(#, #, { mode: 0o755 })".}
proc makeDir(path: cstring) {.importjs:
  "require('fs').mkdirSync(#, { recursive: true })".}

proc whichGit(): cstring {.importjs: """(function () {
  return require('child_process').execFileSync('sh', ['-c', 'command -v git'],
    { encoding: 'utf8' }).trim();
})()""".}

proc runSync(program: cstring; args: seq[cstring]; cwd: cstring): cstring
  {.importjs: """require('child_process').execFileSync(#, #,
    { cwd: #, encoding: 'utf8' })""".}

proc freePort(cb: proc(port: int)) {.importjs: """(function (cb) {
  var srv = require('net').createServer();
  srv.listen(0, '127.0.0.1', function () {
    var p = srv.address().port;
    srv.close(function () { cb(p); });
  });
})(#)""".}

## socket.io's own client. `forceNew` gives each call its own connection — a
## second client of the server, not a second namespace over the first.
proc connectClient(port: int; slot: int; onFrame: proc(frame: cstring);
                   onReady: proc(); onFailure: proc(reason: cstring))
    {.importjs: """(function (port, slot, onFrame, onReady, onFailure) {
  var io = require('socket.io-client');
  var sock = io('http://127.0.0.1:' + port, {
    transports: ['websocket'], reconnection: false, timeout: 5000,
    forceNew: true,
    query: { ct_session: process.env.CT_TEST_SESSION_SECRET } });
  globalThis.__ctFacadeSockets = globalThis.__ctFacadeSockets || [];
  globalThis.__ctFacadeSockets[slot] = sock;
  sock.on('CODETRACER::facade', function (frame) { onFrame(frame); });
  sock.on('connect', function () { onReady(); });
  sock.on('connect_error', function (e) { onFailure('' + (e && e.message)); });
})(#, #, #, #, #)""".}

proc sendFrame(slot: int; frame: cstring) {.importjs:
  "globalThis.__ctFacadeSockets[#].emit('CODETRACER::facade', #)".}

# ---------------------------------------------------------------------------
# The two clients, and what each received.
# ---------------------------------------------------------------------------

type Arrival = object
  reply: ReplyFrame
  atMs: float

const
  ClientA = 0
  ClientB = 1

var scratch = ""
var repository = ""
var realGit = ""
var expectedChecks = -1
var nextId = 1
var connected = 0
var waiting: array[2, proc(arrival: Arrival)]

proc finish() =
  echo "CHECKS: ", checks
  if checks != expectedChecks:
    inc failedChecks
    echo "  [FAILED] the suite ran ", checks, " of ", expectedChecks,
      " checks; the callback chain was cut short"
  if scratch.len > 0: removeTree(scratch.cstring)
  echo ""
  echo checks, " check(s): ", checks - failedChecks, " OK, ", failedChecks, " FAILED"
  exitProcess(if failedChecks == 0: 0 else: 1)

proc onFrameFor(slot: int): proc(frame: cstring) =
  result = proc(frame: cstring) =
    let text = $frame
    if frameKind(text) != FrameReply: return
    let arrival = Arrival(reply: decodeReply(text), atMs: nowMs())
    let handler = waiting[slot]
    if handler != nil:
      waiting[slot] = nil
      handler(arrival)

proc call(slot: int; verb: string; args: JsonNode;
          then: proc(arrival: Arrival)) =
  waiting[slot] = then
  let id = nextId
  inc nextId
  sendFrame(slot, encodeCall(CallFrame(id: id, verb: verb, args: args)).cstring)

# ---------------------------------------------------------------------------
# One race: A's slow verb against B's file read.
# ---------------------------------------------------------------------------

type Race = object
  label: string
  verb: string
  args: JsonNode
  check: proc(reply: ReplyFrame): (bool, string)
    ## Claim 3: whether A's answer is the right one, and what it was.

const ChecksPerRace = 5

proc runRace(race: Race; next: proc()) =
  var aArrival, bArrival: Arrival
  var aDone, bDone = false
  var ticks = 0
  var ticksWhilePending = -1
  let timer = setInterval(proc() = (inc ticks), 10)
  var sentA = 0.0

  proc settle() =
    if not (aDone and bDone): return
    clearInterval(timer)
    ck aArrival.reply.ok and race.check(aArrival.reply)[0],
      race.label & ": A's " & race.verb & " is answered, correctly (" &
        (if aArrival.reply.ok: race.check(aArrival.reply)[1]
         else: $aArrival.reply.errorKind & ": " & aArrival.reply.errorMessage) & ")"
    ck bArrival.reply.ok and decodeText(bArrival.reply.payload) == "b's file\n",
      race.label & ": B's fs.readText is answered with the file it named (" &
        (if bArrival.reply.ok: $bArrival.reply.payload
         else: $bArrival.reply.errorKind & ": " & bArrival.reply.errorMessage) & ")"
    ck bArrival.atMs < aArrival.atMs,
      race.label & ": B is answered BEFORE A's " & race.verb &
        " (B at +" & $int(bArrival.atMs - sentA) & " ms, A at +" &
        $int(aArrival.atMs - sentA) & " ms after A's call)"
    ck bArrival.atMs - sentA < float(BSendDelayMs + PromptMs),
      race.label & ": B is answered within " & $(BSendDelayMs + PromptMs) &
        " ms of A's call, sooner than one slow git run (" &
        $int(bArrival.atMs - sentA) & " ms)"
    ck ticksWhilePending >= 20,
      race.label & ": the server's event loop turned while A's call was " &
        "outstanding (" & $ticksWhilePending & " ticks of a 10 ms timer)"
    next()

  sentA = nowMs()
  call(ClientA, race.verb, race.args, proc(arrival: Arrival) =
    ticksWhilePending = ticks
    aArrival = arrival
    aDone = true
    settle())
  laterCall(proc() =
    call(ClientB, "fs.readText", %*{"path": scratch & "/b.txt"},
      proc(arrival: Arrival) =
        bArrival = arrival
        bDone = true
        settle()), BSendDelayMs)

proc races(): seq[Race] =
  let tree = ($runSync(realGit.cstring, @[cstring"rev-parse", cstring"HEAD^{tree}"],
                       repository.cstring)).strip()
  @[
    Race(label: "vcs.status (the VCS pane's refresh)", verb: "vcs.status",
         args: %*{"repository": repository},
         check: proc(reply: ReplyFrame): (bool, string) =
           let status = decodeVcsStatus(reply.payload)
           (status.branch == "main", "branch " & status.branch)),
    Race(label: "vcs.contentId (the certificate indicator)", verb: "vcs.contentId",
         args: %*{"repository": repository, "state": "vbsHead",
                  "algorithm": "git-tree-sha1", "scope": []},
         check: proc(reply: ReplyFrame): (bool, string) =
           let id = decodeVcsContentId(reply.payload)
           (id.kind == vcikComputed and id.id == "git-tree-sha1:" & tree,
            $id.kind & " " & id.id & ", expected git-tree-sha1:" & tree)),
    Race(label: "process.run", verb: "process.run",
         args: %*{"spec": {"command": "sh",
                           "args": ["-c", "sleep " & $SlowGitSeconds & "; printf ran"],
                           "workingDir": scratch, "clearEnv": false,
                           "stdinText": "", "timeoutMs": 0, "env": []}},
         check: proc(reply: ReplyFrame): (bool, string) =
           let ran = decodeProcessRunResult(reply.payload)
           (ran.stdout == "ran" and ran.exit.exitCode == 0,
            "stdout '" & ran.stdout & "', exit " & $ran.exit.exitCode))]

proc runRaces(list: seq[Race]; index: int) =
  if index >= list.len:
    finish()
    return
  runRace(list[index], proc() = runRaces(list, index + 1))

# ---------------------------------------------------------------------------

proc begin() =
  let list = races()
  expectedChecks = list.len * ChecksPerRace
  runRaces(list, 0)

proc start(httpPort, socketPort: int) =
  data.startOptions.port = httpPort
  data.startOptions.backendSocket.port = socketPort
  setupServer()
  for slot in [ClientA, ClientB]:
    connectClient(socketPort, slot, onFrameFor(slot),
      proc() =
        inc connected
        if connected == 2: begin(),
      proc(reason: cstring) =
        expectedChecks = 1
        ck false, "both socket.io clients connect to the index server (" &
          $reason & ")"
        finish())

proc isMainThread(): bool {.importjs: "require('worker_threads').isMainThread".}
proc thisBundle(): cstring {.importjs: "(__filename)@".}

if isMainThread():
  # The server's content-id worker runs this bundle (header).
  processWorkerScript = $thisBundle()
  echo "facade_endpoint_answers_while_git_runs_test"

  scratch = $makeTempDir(cstring"ct-facade-git-loop-")
  realGit = $whichGit()
  repository = scratch & "/repo"

  # A repository on `main` with one commit, made with the REAL git.
  makeDir(repository.cstring)
  writeFile(cstring(repository & "/a.txt"), cstring("one\n"))
  writeFile(cstring(scratch & "/b.txt"), cstring("b's file\n"))
  for args in [@["init", "-q"], @["symbolic-ref", "HEAD", "refs/heads/main"],
               @["add", "a.txt"],
               @["-c", "user.name=Suite", "-c", "user.email=suite@example.invalid",
                 "commit", "-q", "-m", "one"]]:
    var argv: seq[cstring] = @[]
    for a in args: argv.add a.cstring
    discard runSync(realGit.cstring, argv, repository.cstring)

  # The slow git, first on the PATH the server's children inherit.
  makeDir(cstring(scratch & "/slow-bin"))
  writeExecutable(cstring(scratch & "/slow-bin/git"), cstring(
    "#!/bin/sh\nsleep " & $SlowGitSeconds & "\nexec '" & realGit & "' \"$@\"\n"))
  setEnv(cstring"PATH", cstring(scratch & "/slow-bin:" & $getEnv(cstring"PATH")))

  # The settings root and the session secret, as `facade_endpoint_over_socket_test`
  # sets them and for its reasons: settings stay in `scratch`, and the server
  # admits only a client holding the secret (`index/host_session_guard.nim`).
  setEnv(cstring"CODETRACER_HOME", (scratch & "/ct-home").cstring)
  setEnv(cstring"XDG_CONFIG_HOME", (scratch & "/config").cstring)
  const TestSessionSecret = "facade-endpoint-answers-while-git-runs-secret"
  setEnv(cstring"CODETRACER_HOST_SESSION_SECRET", TestSessionSecret.cstring)
  setEnv(cstring"CT_TEST_SESSION_SECRET", TestSessionSecret.cstring)
  setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")

  freePort(proc(p1: int) =
    freePort(proc(p2: int) =
      start(p1, p2)))
else:
  serveContentIdRequests()
