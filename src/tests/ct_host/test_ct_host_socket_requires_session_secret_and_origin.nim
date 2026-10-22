## test_ct_host_socket_requires_session_secret_and_origin.nim
##
## `ct host` admits a client only with its session secret and only from its
## own page's origin (`CLI/ct/host.md`, "Admission";
## `src/frontend/index/host_session_guard.nim`).
##
## ## Why the claim matters
##
## The socket `ct host` serves carries the index IPC surface: filesystem reads
## and writes, searches, process starts. Before this rule its socket.io server
## allowed every origin and asked for nothing, so any local user, and any web
## page the operator's browser opened, could drive that surface by connecting
## to `127.0.0.1`.
##
## ## What runs
##
## The real `ct host --trace-path` (default: `src/build-debug/bin/ct`, or
## `CODETRACER_CT_BIN`), on a recording checked into this repository
## (`src/db-backend/tests/fixtures/gdscript/gf_values/gdscript_trace.ct`), which
## starts the real `node server_index.js`. The page port is auto-assigned and
## read back from the `CODETRACER_HOST_URL=` line, which is also where the
## generated secret comes from, as it would for an operator. Requests are made
## over real TCP: the page server and the engine.io polling handshake with
## `std/httpclient`, the WebSocket handshake with socket.io's own client under
## node (`NODE_PATH`: the prefix's `node_modules`, else the checkout's).
##
## No mocks. The foreign origin `http://evil.example` is only a header value;
## nothing is served from it.
##
## ## The arms
##
## Refused, each before any session exists: a polling handshake without the
## secret, with a wrong secret of the right length, and with the secret from a
## foreign origin and from the opaque origin `null`; a WebSocket handshake with
## the secret from a foreign origin and one from the page's origin without the
## secret; the page server's descriptor without the secret, and with it from a
## foreign origin; the entry page without the secret.
##
## Admitted (the negative control and the vacuity guard): the descriptor with
## the secret as a header and as the query parameter; a polling handshake with
## the secret from the page's origin as `127.0.0.1` and as `localhost`, each
## answered with that origin in `Access-Control-Allow-Origin`; and a WebSocket
## session from the page's origin that receives the index's bootstrap
## (`CODETRACER::started`, answered, then `CODETRACER::init`) and reads a file
## through the facade's `fs.readText`, the call the refused clients were
## refused before reaching. The secret appears once in everything `ct host`
## printed: the URL line.
##
## Lane: `ct-host-admission` (`just test-ct-host-admission`).

import std/[json, os, strutils, tempfiles, unittest]

import ct_host_harness

# One line: `ci/lib/run-nim-test-lane.sh` reads this spelling as the runtime
# assertion count.
const ExpectedAssertions = 30

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  ForeignOrigin = "http://evil.example"
  ReadMarker = "ct-host-admission: the file the facade read"

proc pollUrl(host: Host; secret: string): string =
  result = "http://127.0.0.1:" & $host.socketPort & "/socket.io/?EIO=4&transport=polling"
  if secret.len > 0:
    result.add "&ct_session=" & secret

proc wrongSecret(secret: string): string =
  ## The same length, one character different.
  result = secret
  result[0] = if secret[0] == 'A': 'B' else: 'A'

const WebSocketClient = """
'use strict';
// Three WebSocket handshakes, one after another, reported as one JSON line.
const io = require('socket.io-client');
const port = process.env.CT_TEST_SOCKET_PORT;
const pageOrigin = process.env.CT_TEST_PAGE_ORIGIN;
const secret = process.env.CT_TEST_SECRET;
const readPath = process.env.CT_TEST_READ_PATH;

function attempt(origin, withSecret, session) {
  return new Promise((resolve) => {
    const out = { connected: false, error: null, events: [], init: false, welcome: false, read: null };
    const socket = io('http://127.0.0.1:' + port, {
      transports: ['websocket'], forceNew: true, reconnection: false, timeout: 5000,
      query: withSecret ? { ct_session: secret } : {},
      extraHeaders: { Origin: origin },
    });
    const done = () => { socket.close(); resolve(out); };
    const timer = setTimeout(() => { out.error = out.error || 'timeout'; done(); }, 20000);
    socket.on('connect_error', (e) => { out.error = String(e && e.message); clearTimeout(timer); done(); });
    socket.onAny((name) => out.events.push(name));
    socket.on('connect', () => {
      out.connected = true;
      if (!session) { clearTimeout(timer); done(); }
    });
    if (!session) return;
    socket.on('CODETRACER::started', () => socket.emit('CODETRACER::started', {}));
    socket.on('CODETRACER::init', () => {
      out.init = true;
      socket.emit('CODETRACER::facade', JSON.stringify({ kind: 'hello', contractVersion: 1 }));
    });
    socket.on('CODETRACER::facade', (frame) => {
      const f = JSON.parse(frame);
      if (f.kind === 'welcome') {
        out.welcome = true;
        socket.emit('CODETRACER::facade', JSON.stringify(
          { kind: 'call', id: 1, verb: 'fs.readText', args: { path: readPath } }));
      } else if (f.kind === 'reply' && f.id === 1) {
        out.read = f;
        clearTimeout(timer);
        done();
      }
    });
  });
}

(async () => {
  const result = {};
  result.foreign = await attempt('http://evil.example', true, false);
  result.noSecret = await attempt(pageOrigin, false, false);
  result.admitted = await attempt(pageOrigin, true, true);
  process.stdout.write(JSON.stringify(result) + '\n');
  process.exit(0);
})();
"""

proc runWebSocketClient(host: Host; scratch, readPath: string): JsonNode =
  let script = scratch / "ws_client.js"
  writeFile(script, WebSocketClient)
  let (output, _) = runNodeScript(host, script, {"CT_TEST_READ_PATH": readPath})
  for line in output.splitLines():
    if line.startsWith("{"):
      return parseJson(line)
  raise newException(IOError, "the WebSocket client printed no result:\n" & output)

var
  scratch = ""
  host: Host
  started = false

suite "ct host admits only its session secret from its own origin":

  test "the prerequisites are present":
    # Not skips: a missing prerequisite is a broken environment.
    if not fileExists(ctBinary):
      checkpoint("missing " & ctBinary & "; build it (`just build-once`) or " &
                 "set CODETRACER_CT_BIN")
    ck fileExists(ctBinary)
    ck findExe("node").len > 0
    ck dirExists(nodeModules / "socket.io-client")
    ck fileExists(root / FixtureRelPath)

  test "ct host starts and prints its URL with a generated secret":
    scratch = createTempDir("ct-host-admission-", "")
    host = startHost(scratch)
    started = host.secret.len > 0
    checkpoint("page " & host.pageOrigin & ", socket " & $host.socketPort)
    ck host.pageOrigin.startsWith("http://127.0.0.1:")
    # 32 random bytes in base64url.
    ck host.secret.len == 43

  test "the page server refuses the descriptor and the page without the secret":
    # Fails here, rather than on an empty address below, when ct host did not start.
    require started
    let base = host.pageOrigin
    ck request(base & "/deployment.json").status == 403
    ck request(base & "/").status == 403
    ck request(base & "/deployment.json",
               {"X-CodeTracer-Session": host.secret, "Origin": ForeignOrigin}).status == 403
    let byHeader = request(base & "/deployment.json", {"X-CodeTracer-Session": host.secret})
    ck byHeader.status == 200
    ck parseJson(byHeader.body){"connection", "backendSocketPort"}.getInt == host.socketPort
    ck request(base & "/deployment.json?ct_session=" & host.secret).status == 200

  test "a polling handshake is refused without the secret or from a foreign origin":
    # Fails here, rather than on an empty address below, when ct host did not start.
    require started
    let own = {"Origin": host.pageOrigin}
    let none = request(pollUrl(host, ""), own)
    checkpoint("no secret: " & $none.status & " " & none.body)
    ck none.status == 403
    ck request(pollUrl(host, wrongSecret(host.secret)), own).status == 403
    let foreign = request(pollUrl(host, host.secret), {"Origin": ForeignOrigin})
    checkpoint("foreign origin: " & $foreign.status & " " & foreign.body)
    ck foreign.status == 403
    ck request(pollUrl(host, host.secret), {"Origin": "null"}).status == 403

  test "a polling handshake with the secret from the page's origin is admitted":
    # Fails here, rather than on an empty address below, when ct host did not start.
    require started
    let port = host.pageOrigin.rsplit(':', 1)[1]
    for origin in [host.pageOrigin, "http://localhost:" & port]:
      let answer = request(pollUrl(host, host.secret), {"Origin": origin})
      checkpoint(origin & ": " & $answer.status & " " & answer.body)
      ck answer.status == 200 and answer.body.startsWith("0{\"sid\":")
      ck answer.allowOrigin == origin

  test "WebSocket: refused from a foreign origin and without the secret; admitted otherwise, and it reaches the IPC surface":
    # Fails here, rather than on an empty address below, when ct host did not start.
    require started
    let readPath = scratch / "read-me.txt"
    writeFile(readPath, ReadMarker)
    let seen = runWebSocketClient(host, scratch, readPath)
    checkpoint($seen)
    ck not seen["foreign"]["connected"].getBool
    ck seen["foreign"]["events"].len == 0
    ck not seen["noSecret"]["connected"].getBool
    let admitted = seen["admitted"]
    ck admitted["connected"].getBool
    ck admitted["init"].getBool
    ck admitted["welcome"].getBool
    ck admitted["read"]{"ok"}.getBool
    let payload = admitted{"read", "payload"}
    ck (not payload.isNil) and ($payload).contains(ReadMarker)

  test "the secret appears once in what ct host printed: the URL line":
    # Fails here, rather than on an empty address below, when ct host did not start.
    require started
    let log = readLog(host.logPath)
    ck log.count(host.secret) == 1
    ck log.contains("CODETRACER_HOST_URL=" & host.pageOrigin & "/?ct_session=" & host.secret)

  if started:
    stopHost(host)
  if scratch.len > 0:
    removeDir(scratch)

suite "assertion count":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
