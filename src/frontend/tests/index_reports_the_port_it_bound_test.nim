## `ct host` REPORTS THE PORT IT ACTUALLY BOUND, which with auto-assign is not
## the port it was asked for.
##
## ## The defect this pins
##
## `--port` was mandatory, so the URL was always derivable from the argument and
## nothing ever had to read it back. `CLI/ct/host.md` §Options had said
## `auto-assign` all along, and WD2 is the case that needs it: a
## substrate-allocated session's port is the allocator's to choose, not the
## operator's. With `--port 0` the kernel picks, and the listen argument is then
## `0` while the server is on some real port — so a supervisor told to connect
## to the argument is told to connect to port 0.
##
## §High-Level Rules requires the URL on stdout **"in a form a supervising
## process can parse before the first client connects"**. Printing the argument
## satisfies the letter of that and none of its purpose.
##
## ## What is asserted, and why reading the log is the only way
##
## The number cannot be checked against the input, because with auto-assign
## there is no input to check it against. So the suite does what a supervisor
## does: it reads the `CODETRACER_HOST_URL=` line, takes the port out of it, and
## then CONNECTS to that port. A wrong number fails at the connection rather
## than at a comparison — which is the only check that could not be satisfied by
## echoing the argument back.
##
## The control is the explicit case: with a named port the same line must carry
## that port. Without it, a suite that only ever auto-assigned would pass
## against an implementation that ignored `--port` entirely.
##
## ## What is real
##
## `index/server_config.nim`'s `setupServer`, its express app and its real
## `listen` — including the `listen(0)` path. The line is captured by replacing
## `console.log`'s sink for the duration, not by parsing a file, because the
## claim is about what reaches stdout.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`.

import std/[strutils]

import lib/src_relative_require
import ../index/config
import ../index/server_config

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

## Capture everything written through `console.log` from now on. `echo` on the
## JS backend goes through `console.log`, so this is the sink the product's own
## line reaches.
##
## INSTALLED AND LEFT INSTALLED, rather than wrapped around a call. The line is
## printed from the `listen` CALLBACK, which fires after `setupServer` returns —
## a capture that restored the sink when the call returned would capture
## everything except the one line under test.
proc startCapture() {.importjs: """(function () {
  globalThis.__ctCaptured = [];
  globalThis.__ctOriginalLog = console.log;
  console.log = function () {
    globalThis.__ctCaptured.push(Array.prototype.join.call(arguments, ' '));
  };
})()""".}

proc capturedSoFar(): cstring {.importjs:
  "globalThis.__ctCaptured.join(String.fromCharCode(10))".}
  ## `String.fromCharCode(10)` and not a `'\n'` literal: a backslash-n inside
  ## this Nim string is a REAL newline by the time the pragma is read, so the
  ## emitted JS would carry an unterminated string literal and node would refuse
  ## the whole bundle with `SyntaxError: Invalid or unexpected token`.

proc stopCapture() {.importjs:
  "(console.log = globalThis.__ctOriginalLog)".}

proc probe(port: int; cb: proc(outcome: cstring)) {.importjs: """(function (port, cb) {
  var done = false;
  var finish = function (r) { if (!done) { done = true; cb(r); } };
  var s = require('net').connect({ host: '127.0.0.1', port: port });
  s.setTimeout(3000);
  s.on('connect', function () { s.destroy(); finish('open'); });
  s.on('timeout', function () { s.destroy(); finish('timeout'); });
  s.on('error', function (e) { s.destroy(); finish('error:' + e.code); });
})(#, #)""".}

proc laterCall(cb: proc(); ms: int) {.importjs: "setTimeout(#, #)".}

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

proc urlPortIn(text: string): int =
  ## The port out of the `CODETRACER_HOST_URL=` line, or -1.
  for line in text.splitLines():
    let marker = "CODETRACER_HOST_URL="
    let at = line.find(marker)
    if at < 0: continue
    let url = line[at + marker.len .. ^1].strip()
    let colon = url.rfind(':')
    if colon < 0: continue
    try: return parseInt(url[colon + 1 .. ^1])
    except ValueError: return -1
  -1

proc runNamedCase(namedPort, socketPort: int) =
  # THE CONTROL. Without it a suite that only auto-assigned would pass against
  # an implementation that ignored `--port` and always let the kernel choose.
  data.startOptions.port = namedPort
  data.startOptions.backendSocket.port = socketPort
  startCapture()
  setupServer()
  laterCall(proc() =
    let text = $capturedSoFar()
    stopCapture()
    let reported = urlPortIn(text)
    ck reported == namedPort,
      "CONTROL: with `--port " & $namedPort & "` the reported URL names that " &
        "port (got " & $reported & ")"
    finish(), 400)

proc afterAutoListen(namedPort, namedSocketPort: int) =
  let text = $capturedSoFar()
  stopCapture()
  let reported = urlPortIn(text)
  ck text.contains("CODETRACER_HOST_URL="),
    "a machine-readable URL line reaches stdout"
  ck reported > 0,
    "and it carries a port (got " & $reported & ")"
  ck reported != 0,
    "which is NOT the `0` it was asked to listen on — the argument was echoed " &
      "back if it is"
  if reported <= 0:
    finish()
    return
  # THE CHECK THAT CANNOT BE SATISFIED BY ECHOING: connect to the number.
  probe(reported, proc(outcome: cstring) =
    ck $outcome == "open",
      "and a client can connect to it (got " & $outcome & ")"
    runNamedCase(namedPort, namedSocketPort))

proc start(socketPort, namedPort, namedSocketPort: int) =
  # `0` is `ct host`'s auto-assign, which is what `resolveHostPort` hands the
  # index when nobody named a port.
  data.startOptions.port = 0
  data.startOptions.backendSocket.port = socketPort
  startCapture()
  setupServer()
  laterCall(proc() =
    ck data.startOptions.port != 0,
      "the bound port is written back into startOptions, so everything " &
        "downstream names the real one"
    ck data.startOptions.port > 0,
      "and it is a real port (got " & $data.startOptions.port & ")"
    afterAutoListen(namedPort, namedSocketPort), 400)

echo "index_reports_the_port_it_bound_test"

freePort(proc(p1: int) =
  freePort(proc(p2: int) =
    freePort(proc(p3: int) =
      start(p1, p2, p3))))
