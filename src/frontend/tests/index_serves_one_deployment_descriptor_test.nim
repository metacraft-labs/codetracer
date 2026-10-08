## ONE DESCRIPTOR, TWO DELIVERIES, AND THEY ARE THE SAME DOCUMENT — §7, WD1c.
##
## ## The defect this is about
##
## `views/server_index.ejs` interpolated `frontendSocketPort` and
## `frontendSocketParameters` into the page. Two values that change per session
## were compiled into the artefact that does not, which is exactly why the
## entry document could not be cached — and it is the thing §7 moves out.
##
## ## The claim, and why it is an EQUALITY rather than two shape checks
##
## §7: the descriptor "arrives differently per deployment and is the SAME
## document" — fetched by URL where the page has no socket yet, carried in
## `welcome` where it does, because a second round trip before first paint is a
## second round trip. Two deliveries of one value is a thing that can drift, so
## the suite compares the two documents to each other, byte for byte, rather
## than checking each against a shape. A shape check passes while the two
## disagree, which is the only failure this pairing exists to catch.
##
## It is also compared against `data.startOptions`, because two deliveries can
## agree with each other and both be wrong.
##
## ## What is real
##
## `index/server_config.nim`'s `setupServer`, its express app, its socket.io
## server and the endpoint attached to it, over the shipped defaults with only
## the two ports assigned. `GET /deployment.json` is a real HTTP request;
## `welcome` comes back over a real socket.io connection. The decoder is
## `platform/deployment_descriptor.nim`'s own, so a field this build cannot
## read fails here rather than being accepted as absent.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`.

import std/[json, jsffi]

import lib/src_relative_require
import ../index/config
import ../index/server_config
import ../viewmodel/platform/endpoint_protocol
import ../viewmodel/platform/deployment_descriptor

var checks = 0
var failedChecks = 0

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

proc exitProcess(code: int) {.importjs: "process.exit(#)".}

proc freePort(cb: proc(port: int)) {.importjs: """(function (cb) {
  var srv = require('net').createServer();
  srv.listen(0, '127.0.0.1', function () {
    var p = srv.address().port;
    srv.close(function () { cb(p); });
  });
})(#)""".}

proc fetchBody(port: int; path: cstring;
               cb: proc(status: int; body: cstring)) {.importjs: """(function (port, path, cb) {
  var req = require('http').request(
    { host: '127.0.0.1', port: port, path: path, method: 'GET' },
    function (res) {
      var chunks = '';
      res.setEncoding('utf8');
      res.on('data', function (d) { chunks += d; });
      res.on('end', function () { cb(res.statusCode, chunks); });
    });
  req.on('error', function () { cb(0, ''); });
  req.end();
})(#, #, #)""".}

proc connectClient(port: int; onFrame: proc(frame: cstring);
                   onReady: proc()) {.importjs: """(function (port, onFrame, onReady) {
  var io = require('socket.io-client');
  var sock = io('http://127.0.0.1:' + port, {
    transports: ['websocket'], reconnection: false, timeout: 5000 });
  globalThis.__ctDescriptorSocket = sock;
  sock.on('CODETRACER::facade', function (f) { onFrame(f); });
  sock.on('connect', function () { onReady(); });
})(#, #, #)""".}

proc sendFrame(frame: cstring) {.importjs:
  "globalThis.__ctDescriptorSocket.emit('CODETRACER::facade', #)".}

const ExpectedChecks = 7

proc finish() =
  echo "CHECKS: ", checks
  if checks != ExpectedChecks:
    inc failedChecks
    echo "  [FAILED] the suite ran ", checks, " of ", ExpectedChecks,
      " cases; the callback chain was cut short"
  echo ""
  echo checks, " check(s): ", checks - failedChecks, " OK, ", failedChecks, " FAILED"
  exitProcess(if failedChecks == 0: 0 else: 1)

var fetched: JsonNode = nil
var httpPortUsed = 0
var socketPortUsed = 0

proc onFrame(frame: cstring) =
  if frameKind($frame) != FrameWelcome: return
  let welcome = decodeWelcome($frame)
  ck not welcome.deployment.isNil and welcome.deployment.kind == JObject,
    "`welcome` carries a deployment object (§6.3's opaque half is filled)"
  ck welcome.deployment == fetched,
    "the `welcome`'s deployment IS the document `/deployment.json` serves — " &
      "not merely the same shape"
  # And the decoder reads it, so a field the endpoint writes and this build
  # cannot parse fails here rather than being silently absent.
  var readBack: SessionDescriptor
  var decoded = true
  try:
    readBack = decodeDescriptor($welcome.deployment)
  except DescriptorError:
    decoded = false
  ck decoded, "the descriptor in `welcome` decodes with the bundle's own decoder"
  if decoded:
    ck readBack.connection.frontendSocketPort ==
       data.startOptions.frontendSocket.port and
       readBack.connection.backendSocketPort == socketPortUsed,
      "and both deliveries agree with `data.startOptions` rather than only " &
        "with each other"
  else:
    ck false, "and both deliveries agree with `data.startOptions`"
  finish()

proc afterFetch(status: int; body: cstring) =
  ck status == 200, "`GET /deployment.json` is answered (got " & $status & ")"
  if status != 200:
    finish()
    return
  var parsed: JsonNode = nil
  try:
    parsed = parseJson($body)
  except CatchableError:
    parsed = nil
  ck not parsed.isNil, "and its body is JSON"
  if parsed.isNil:
    finish()
    return
  fetched = parsed

  var descriptor: SessionDescriptor
  var ok = true
  try:
    descriptor = decodeDescriptor($body)
  except DescriptorError:
    ok = false
  ck ok and descriptor.connection.backendSocketPort == socketPortUsed,
    "and it carries the connection parameters `server_index.ejs` used to " &
      "interpolate, read back with the bundle's own decoder"

  connectClient(socketPortUsed, onFrame, proc() =
    sendFrame(encodeHello(
      HelloFrame(contractVersion: EndpointContractVersion)).cstring))

proc start(httpPort, socketPort: int) =
  httpPortUsed = httpPort
  socketPortUsed = socketPort
  data.startOptions.port = httpPort
  data.startOptions.backendSocket.port = socketPort
  setupServer()
  fetchBody(httpPort, cstring"/deployment.json", afterFetch)

echo "index_serves_one_deployment_descriptor_test"

freePort(proc(p1: int) =
  freePort(proc(p2: int) =
    start(p1, p2)))
