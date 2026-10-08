## THE FACADE IS REACHABLE OVER A SOCKET, AND ITS `welcome` DESCRIBES THE
## ANSWERS IT ACTUALLY GIVES — WD1b step 4.
##
## ## The defect this pins
##
## `facade_endpoint_verbs_test.nim` drives the dispatcher directly, and
## `test_container_platform_verbs.nim` pairs it with the real client over an
## in-memory transport. Both were green while **nothing under
## `src/frontend/index/` imported `facade_endpoint` at all** — a running
## `ct host` served no facade, and every frame a page sent would have been
## dropped by the socket handler. Two suites proved the dispatcher answers
## correctly when called; neither could notice that nobody called it.
##
## So this suite refuses to call `handleFrame`. It starts the real server and
## reaches the dispatcher the way the page will: a socket.io connection to the
## port the index bound, frames on `CODETRACER::facade`.
##
## ## The claim
##
## §6.3 makes `welcome.profile` the thing a client branches on: a capability in
## it means the verbs that need only that capability will be attempted, and one
## absent means the client answers locally or degrades. That contract is a
## biconditional, and this suite asserts it as one, over EVERY verb in the
## table:
##
##   `verb.serves` ⊆ `welcome.profile.capabilities`  ⟺  the verb does not
##   answer `pkNotSupported`
##
## Both directions matter and they fail differently. A verb refused while its
## capability is advertised is a client that walks into a dead end it was told
## was open. A verb served while its capability is withdrawn is a client that
## reimplements locally something the deployment could have done — the silent
## half, and the one no error message reports.
##
## The three verbs with an empty `serves` (`process.start`, `process.isRunning`,
## `shell.windowState`) are outside the sweep: `{} ⊆ anything` holds vacuously,
## so the rule predicts nothing about them. They are evidence for no capability
## and a client has no profile bit to read before calling them.
##
## ## Why the sweep sends empty args
##
## `argText` and its siblings raise `ProtocolError` on a missing field, which
## `dispatch` answers `pkInvalidArgument` — before the handler touches
## anything. That is what makes an exhaustive sweep safe: fifty-eight calls
## including `fs.remove`, `vcs.commit` and `vcs.push` reach no filesystem and
## no remote. It is also sufficient, because the sweep's only question is
## whether the answer is `pkNotSupported`, and a refusal is decided before args
## are read at all.
##
## An exhaustive `pkInvalidArgument` sweep would pass against a dispatcher
## whose handlers were all stubs, so it is paired with positive probes that
## demand `ok` from one verb per served capability, with real arguments.
## Neither half is the claim on its own.
##
## ## What is real
##
## The index's own `setupServer` (`index/server_config.nim`) — its express
## app, its socket.io server, and the endpoint it attaches — over the shipped
## `data.startOptions` defaults, with only the two ports assigned. The client
## is socket.io's own, over TCP. `XDG_CONFIG_HOME` is pointed at a scratch
## directory before the server starts, so the settings verbs write where a
## test may write rather than into the developer's configuration; that is the
## one substitution, it is an environment variable the product already reads,
## and the endpoint is constructed from it by the product's own code.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`.

import std/[json, jsffi, strutils]

import lib/src_relative_require
import ../index/config
import ../index/server_config
import ../index/facade_endpoint
import ../viewmodel/platform/capabilities
import ../viewmodel/platform/outcome
import ../viewmodel/platform/endpoint_protocol

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

proc nodeRequire(m: cstring): JsObject {.importjs: "require(#)".}
proc exitProcess(code: int) {.importjs: "process.exit(#)".}
proc setEnv(key, value: cstring) {.importjs: "process.env[#] = #".}
proc makeTempDir(prefix: cstring): cstring {.importjs:
  "require('fs').mkdtempSync(require('path').join(require('os').tmpdir(), #))".}
proc removeTree(path: cstring) {.importjs:
  "require('fs').rmSync(#, { recursive: true, force: true })".}

proc freePort(cb: proc(port: int)) {.importjs: """(function (cb) {
  var srv = require('net').createServer();
  srv.listen(0, '127.0.0.1', function () {
    var p = srv.address().port;
    srv.close(function () { cb(p); });
  });
})(#)""".}

## socket.io's own client, against the server this process started. The
## connection is the point of the suite, so it is not abstracted over.
proc connectClient(port: int; onFrame: proc(frame: cstring);
                   onReady: proc(); onFailure: proc(reason: cstring))
    {.importjs: """(function (port, onFrame, onReady, onFailure) {
  var io = require('socket.io-client');
  var sock = io('http://127.0.0.1:' + port, {
    transports: ['websocket'], reconnection: false, timeout: 5000 });
  globalThis.__ctFacadeSocket = sock;
  sock.on('CODETRACER::facade', function (frame) { onFrame(frame); });
  sock.on('connect', function () { onReady(); });
  sock.on('connect_error', function (e) { onFailure('' + (e && e.message)); });
})(#, #, #, #)""".}

proc sendFrame(frame: cstring) {.importjs:
  "globalThis.__ctFacadeSocket.emit('CODETRACER::facade', #)".}

proc laterCall(cb: proc(); ms: int) {.importjs: "setTimeout(#, #)".}

# ---------------------------------------------------------------------------
# The reply pump. One call outstanding at a time: §6.2 correlates a reply to
# its call by `id` and by nothing else, so a suite that kept several in flight
# would be asserting the correlation it is not here to test.
# ---------------------------------------------------------------------------

var scratch = ""
var pending: proc(reply: ReplyFrame) = nil
var welcomeSeen = false
var served: CapabilitySet = {}
var nextId = 1

proc finish(expected: int) =
  echo "CHECKS: ", checks
  if checks != expected:
    inc failedChecks
    echo "  [FAILED] the suite ran ", checks, " of ", expected,
      " cases; the callback chain was cut short"
  if scratch.len > 0: removeTree(scratch.cstring)
  echo ""
  echo checks, " check(s): ", checks - failedChecks, " OK, ", failedChecks, " FAILED"
  exitProcess(if failedChecks == 0: 0 else: 1)

## Filled once the sweep length is known; `finish` is reached from several
## places and every one of them owes the same total.
var expectedChecks = -1
proc done() = finish(expectedChecks)

proc call(verb: string; args: JsonNode; then: proc(reply: ReplyFrame)) =
  pending = then
  let id = nextId
  inc nextId
  sendFrame(encodeCall(CallFrame(id: id, verb: verb, args: args)).cstring)

proc onFrame(frame: cstring) =
  let text = $frame
  case frameKind(text)
  of FrameWelcome:
    welcomeSeen = true
    let w = decodeWelcome(text)
    served = w.profile.capabilities
    ck w.contractMin <= EndpointContractVersion and
       EndpointContractVersion <= w.contractMax,
      "the served contract range " & $w.contractMin & "-" & $w.contractMax &
        " contains the version this bundle speaks (" &
        $EndpointContractVersion & ")"
    ck w.unknownCapabilities.len == 0,
      "every capability name in the welcome is one this bundle knows (unknown: " &
        w.unknownCapabilities.join(", ") & ")"
    ck served.len > 0,
      "the server declares a non-empty capability set"
  of FrameReply:
    if pending != nil:
      let handler = pending
      pending = nil
      handler(decodeReply(text))
  else:
    # §6.1 shares this connection with the index IPC surface, so a frame that
    # is neither is somebody else's and is not an error here.
    discard

# ---------------------------------------------------------------------------
# Phase C — one verb per served capability, with real arguments, demanding
# `ok`. Written before the sweep because the sweep's continuation names it.
# ---------------------------------------------------------------------------

type Probe = object
  capability: PlatformCapability
  verb: string
  args: JsonNode
  why: string

proc positiveProbes(): seq[Probe] =
  @[
    Probe(capability: capFilesystemRead, verb: "fs.stat",
          args: %*{"path": scratch},
          why: "stats the scratch directory it was given"),
    Probe(capability: capFilesystemWrite, verb: "fs.writeText",
          args: %*{"path": scratch & "/written.txt", "content": "over the wire"},
          why: "writes a file"),
    Probe(capability: capFilesystemTemp, verb: "fs.makeTempDir",
          args: %*{"prefix": "ct-agreement-"},
          why: "makes a temporary directory"),
    Probe(capability: capProcessArbitraryPrograms, verb: "process.which",
          args: %*{"program": "sh"},
          why: "resolves `sh` on PATH"),
    Probe(capability: capProcessSpawn, verb: "process.run",
          args: %*{"spec": {"command": "sh", "arguments": ["-c", "exit 0"]}},
          why: "runs a real child process"),
    Probe(capability: capVcsRead, verb: "vcs.isRepository",
          args: %*{"path": scratch},
          why: "answers whether a directory is a repository"),
    Probe(capability: capSettingsWrite, verb: "settings.set",
          args: %*{"scope": "ssSession", "key": "agreement", "value": "1"},
          why: "writes a session setting"),
    Probe(capability: capSettingsRead, verb: "settings.get",
          args: %*{"scope": "ssSession", "key": "agreement"},
          why: "reads back the setting it just wrote")]

proc runProbes(list: seq[Probe]; index: int) =
  if index >= list.len:
    done()
    return
  let p = list[index]
  if p.capability notin served:
    # Not a skip: the sweep above has already asserted the boundary, so a
    # capability missing HERE means this list and the table disagree about
    # what the container serves, and the positive half would silently shrink.
    ck false, $p.capability & " is advertised, so " & p.verb &
      " has a positive probe (it is not in the welcome's profile at all)"
    runProbes(list, index + 1)
    return
  call(p.verb, p.args, proc(reply: ReplyFrame) =
    ck reply.ok,
      $p.capability & " is advertised and " & p.verb & " " & p.why &
        (if reply.ok: "" else: " — got " & $reply.errorKind & ": " &
          reply.errorMessage)
    runProbes(list, index + 1))

# ---------------------------------------------------------------------------
# Phase B — the biconditional, over every verb that is evidence for something.
# ---------------------------------------------------------------------------

proc sweepVerbs(list: seq[FacadeVerb]; index: int) =
  if index >= list.len:
    runProbes(positiveProbes(), 0)
    return
  let entry = list[index]
  let advertised = entry.serves <= served
  call(entry.verb, newJObject(), proc(reply: ReplyFrame) =
    let refused = (not reply.ok) and reply.errorKind == pkNotSupported
    if advertised:
      ck not refused,
        entry.verb & " is not refused: the welcome advertises every capability " &
          "it serves (got " & (if reply.ok: "ok" else: $reply.errorKind) & ")"
    else:
      ck refused,
        entry.verb & " refuses with pkNotSupported: the welcome withdraws a " &
          "capability it serves (got " &
          (if reply.ok: "ok" else: $reply.errorKind) & ")"
    sweepVerbs(list, index + 1))

# ---------------------------------------------------------------------------

proc begin() =
  var sweep: seq[FacadeVerb] = @[]
  for entry in facadeVerbs:
    if entry.serves.len > 0: sweep.add entry
  expectedChecks = 3 + sweep.len + positiveProbes().len
  ck sweep.len >= 50,
    "the sweep covers " & $sweep.len & " verbs (a table that shrank to a " &
      "handful would make every case below vacuous)"
  inc expectedChecks
  sweepVerbs(sweep, 0)

proc awaitWelcome(attempt: int) =
  if welcomeSeen:
    begin()
  elif attempt > 100:
    ck false, "the server answers `hello` with a `welcome` within 2s " &
      "(nothing arrived on " & FacadeChannel & " — the dispatcher is not " &
      "attached to the socket)"
    finish(checks)
  else:
    laterCall(proc() = awaitWelcome(attempt + 1), 20)

proc start(httpPort, socketPort: int) =
  data.startOptions.port = httpPort
  data.startOptions.backendSocket.port = socketPort
  setupServer()

  # The socket.io server is attached to `httpServer`, which listens on the
  # BACKEND socket port — `data.startOptions.port` serves the page, not the
  # frames. Connecting to the page port would time out and the suite would
  # report "the dispatcher is not attached" for the wrong reason.
  connectClient(socketPort, onFrame,
    proc() =
      sendFrame(encodeHello(
        HelloFrame(contractVersion: EndpointContractVersion)).cstring)
      awaitWelcome(0),
    proc(reason: cstring) =
      ck false, "the socket.io client connects to the index server (" &
        $reason & ")"
      finish(checks))

echo "facade_endpoint_over_socket_test"

scratch = $makeTempDir(cstring"ct-facade-socket-")
# Before `setupServer`, because the endpoint reads it when it is constructed.
setEnv(cstring"XDG_CONFIG_HOME", (scratch & "/config").cstring)

freePort(proc(p1: int) =
  freePort(proc(p2: int) =
    start(p1, p2)))
