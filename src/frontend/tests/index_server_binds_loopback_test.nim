## index_server_binds_loopback_test.nim
##
## `ct host` SERVES LOOPBACK ONLY UNLESS TOLD OTHERWISE — asserted by trying
## to connect, from this host's own routable address, to the server the
## Electron main process actually starts.
##
## ## The defect this pins
##
## `CLI/ct/host.md` requires the default to be loopback, and gives the reason:
## "a trace contains the recorded program's memory and I/O". The main process
## called Node's `server.listen(port, cb)`, whose two-argument form binds
## `0.0.0.0`, and then printed "listening on localhost". So `ct host` served
## every interface on the machine — the LAN, the container bridges, the
## overlay network — while its log said it did not. There was no way to
## express the rule from Nim at all: `ExpressServer.listen` had no host
## parameter.
##
## ## Why it connects instead of reading the flag
##
## Reading `data.startOptions.address` back, or scanning the argv `ct host`
## builds, would have passed on the broken code too: the field held
## "127.0.0.1" all along and was simply never handed to `listen`. The only
## observation that can tell the two apart is whether a TCP connection from a
## non-loopback address is accepted, so that is what this suite makes.
##
## ## The two controls, and why the suite is not self-fulfilling
##
## A refused connection proves nothing by itself — an address that is not
## reachable refuses everything, and a server that failed to start refuses
## everything too. Two cases rule both out:
##
##   1. Before anything else, a bare `http` server binds `0.0.0.0` on the SAME
##      address the subject cases probe, and the connection must be ACCEPTED.
##      If it is not, the suite stops there and says the refusals below would
##      be vacuous, rather than reporting them green.
##   2. After the default is measured, `--bind 0.0.0.0` goes through the real
##      `parseArgs` and a second `setupServer` on fresh ports must ACCEPT on
##      that same address. This is what makes the default case a statement
##      about the VALUE rather than about the machinery: the identical code
##      path, given a different argument, opens the interface.
##
## The default cases never assign `address`. They run `setupServer()` with the
## shipped default from `index/config.nim`, which is the whole claim: the
## DEFAULT is loopback. Setting it there would test the plumbing and not the
## default.
##
## ## What is real
##
## REAL: `index/server_config.nim`'s `setupServer` — the express app, its
## `listen`, the socket.io server and the backend `http` server — over the
## real `data.startOptions` from `index/config.nim`, and the real
## `index/args.nim` `parseArgs` for the `--bind` case. Nothing is substituted.
## In the default cases only the two ports are assigned, because a test cannot
## probe a port it cannot name, and the port is not what is under test; the
## `--bind` case assigns nothing at all and arrives entirely through argv.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, the defines
## `server_index.js` is built with, run under node.

import std/[jsffi, strutils]

import lib/src_relative_require
import ../index/config
import ../index/server_config
import ../index/args

var checks = 0
var failedChecks = 0

proc ck(cond: bool, name: string) =
  inc checks
  if cond:
    echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

# ---------------------------------------------------------------------------
# node primitives
# ---------------------------------------------------------------------------

proc nodeRequire(m: cstring): JsObject {.importjs: "require(#)".}
proc exitProcess(code: int) {.importjs: "process.exit(#)".}

## The first routable IPv4 this host owns, or "" when it owns none.
proc routableIPv4(): cstring {.importjs: """(function () {
  var ifaces = require('os').networkInterfaces();
  for (var name in ifaces) {
    var addrs = ifaces[name] || [];
    for (var i = 0; i < addrs.length; i++) {
      var a = addrs[i];
      if (a.family === 'IPv4' && !a.internal) return a.address;
    }
  }
  return '';
})()""".}

## One free TCP port, taken by binding port 0 on loopback and closing.
## Racy in principle; the window is microseconds and nothing else on a test
## host is scanning for ports.
proc freePort(cb: proc(port: int)) {.importjs: """(function (cb) {
  var srv = require('net').createServer();
  srv.listen(0, '127.0.0.1', function () {
    var p = srv.address().port;
    srv.close(function () { cb(p); });
  });
})(#)""".}

## "open", "refused", "timeout", or "error:<code>".
proc probe(host: cstring, port: int, cb: proc(outcome: cstring)) {.importjs: """(function (host, port, cb) {
  var done = false;
  var finish = function (r) { if (!done) { done = true; cb(r); } };
  var s = require('net').connect({ host: host, port: port });
  s.setTimeout(3000);
  s.on('connect', function () { s.destroy(); finish('open'); });
  s.on('timeout', function () { s.destroy(); finish('timeout'); });
  s.on('error', function (e) {
    s.destroy();
    finish(e.code === 'ECONNREFUSED' ? 'refused' : 'error:' + e.code);
  });
})(#, #, #)""".}

## Replace this process's argv, so `parseArgs` reads the command line the
## `--bind` case is about. `parseArgs` slices `argv[2 .. ^1]`, exactly as it
## does under Electron.
proc setArgv(a: cstring, b: cstring, c: cstring, d: cstring, e: cstring, f: cstring)
    {.importjs: "process.argv = [process.argv[0], process.argv[1], #, #, #, #, #, #]".}

## A bare `http` server on an explicit host — the first control's subject, with
## no CodeTracer code in it at all.
proc listenPlain(port: int, host: cstring, cb: proc()) {.importjs: """(function (port, host, cb) {
  require('http').createServer().listen(port, host, function () { cb(); });
})(#, #, #)""".}

# ---------------------------------------------------------------------------

let routable = routableIPv4()

# The lane counts `[OK]` lines, and a case that asserts nothing prints one.
# `ExpectedChecks` is what makes a case deleted from the chain below — every
# one of which is a callback the next case is nested inside, so dropping one
# drops its successors silently — a red run rather than a quieter green one.
const ExpectedChecks = 8

proc finish() =
  echo "CHECKS: ", checks
  if checks != ExpectedChecks:
    inc failedChecks
    echo "  [FAILED] the suite ran ", checks, " of ", ExpectedChecks,
      " cases; the callback chain was cut short"
  echo ""
  echo checks, " check(s): ", checks - failedChecks, " OK, ", failedChecks, " FAILED"
  exitProcess(if failedChecks == 0: 0 else: 1)

proc runBindFlag(httpPort: int, socketPort: int) =
  # CONTROL 2, and the `--bind` feature at the same time. Nothing here assigns
  # a field: the ports and the address all arrive through the real argv parser,
  # which is the only way to show the flag is not inert.
  setArgv(cstring"--bind", cstring"0.0.0.0",
          cstring"--port", cstring($httpPort),
          cstring"--backend-socket-port", cstring($socketPort))
  parseArgs()
  ck($data.startOptions.address == "0.0.0.0",
    "`--bind` reaches startOptions.address through parseArgs")
  setupServer()

  probe(routable, httpPort, proc(a: cstring) =
    ck($a == "open",
      "CONTROL: with `--bind 0.0.0.0` the UI server ACCEPTS " & $routable &
      " (got " & $a & ")")
    probe(routable, socketPort, proc(b: cstring) =
      ck($b == "open",
        "CONTROL: with `--bind 0.0.0.0` the socket.io server ACCEPTS " &
        $routable & " (got " & $b & ")")
      finish()))

proc runSubject(httpPort: int, socketPort: int, bindHttpPort: int, bindSocketPort: int) =
  # NOTHING ASSIGNS `address`. The default under test comes from
  # `index/config.nim`; assigning it here would make every case below true of
  # the plumbing rather than of the default.
  data.startOptions.port = httpPort
  data.startOptions.backendSocket.port = socketPort
  setupServer()

  probe(cstring"127.0.0.1", httpPort, proc(a: cstring) =
    ck($a == "open", "the UI server accepts a connection on loopback")
    probe(routable, httpPort, proc(b: cstring) =
      ck($b == "refused",
        "the UI server refuses " & $routable & " by default (got " & $b & ")")
      probe(cstring"127.0.0.1", socketPort, proc(c: cstring) =
        ck($c == "open", "the socket.io server accepts a connection on loopback")
        probe(routable, socketPort, proc(d: cstring) =
          ck($d == "refused",
            "the socket.io server refuses " & $routable & " by default (got " & $d & ")")
          runBindFlag(bindHttpPort, bindSocketPort)))))

proc runControl(controlPort: int, httpPort: int, socketPort: int,
                bindHttpPort: int, bindSocketPort: int) =
  listenPlain(controlPort, cstring"0.0.0.0", proc() =
    probe(routable, controlPort, proc(outcome: cstring) =
      ck($outcome == "open",
        "CONTROL: " & $routable & " accepts a connection when something binds 0.0.0.0")
      if $outcome != "open":
        # Without this the two "refused" cases below would pass for the wrong
        # reason, so stop rather than report them.
        echo "  the probe cannot reach this host's own address; the refusals below would be vacuous"
        finish()
      else:
        runSubject(httpPort, socketPort, bindHttpPort, bindSocketPort)))

echo "index_server_binds_loopback_test"

if $routable == "":
  # Deliberately a failure and not a skip: every runner this lane runs on has
  # a routable IPv4, and a silent skip here would retire the only case that
  # can observe the defect.
  echo "  [FAILED] this host has no non-loopback IPv4; the suite cannot observe the binding"
  echo "  remedy: run the lane on a host with a routable interface, or attach one to the container"
  inc checks
  inc failedChecks
  finish()
else:
  freePort(proc(p1: int) =
    freePort(proc(p2: int) =
      freePort(proc(p3: int) =
        freePort(proc(p4: int) =
          freePort(proc(p5: int) =
            runControl(p1, p2, p3, p4, p5))))))
