## `ct host` SERVES THE BUNDLE UNDER THE PAGES DEPLOYMENT'S OWN CACHE CLASSES
## — WD1c, measured as headers on the wire.
##
## ## The defect this pins
##
## `ct host` served everything through bare `express.static`, whose default is
## `Cache-Control: public, max-age=0`. The Pages deployment serves the same
## bytes under `web_deployment.cacheClassFor`. So opening a second trace from
## `ct host` re-downloaded the whole UI, every time, while the deployment it is
## supposed to be byte-identical to did not.
##
## ## Why it asks the server rather than reading the code
##
## Reading `cacheClassFor` back would have passed against the broken code: the
## function was right all along and nothing under `src/frontend/index/` called
## it — `git log --all -S'asset' -- src/frontend/index/` returns **zero
## commits**, which is the measurement WD1c opens with. The only observation
## that separates "the class is right" from "the class is right and nobody
## applies it" is the header on a real response.
##
## ## The expectation is DERIVED, and the two probes are in different classes
##
## Each case asserts the served header equals `headerFor(cacheClassFor(url))` —
## the same two functions that generate the Pages `_headers` file. A literal
## here would have to be edited whenever the deployment's table changed, which
## is how two halves drift.
##
## Derivation alone is not enough: a server that hard-coded ONE header would
## satisfy every derived comparison whose probes happened to share a class. So
## the two probes are deliberately in different ones — `frontend/styles/
## loader.css` is one of `bundledAssetPaths`' four and lands in
## `ccMutableAsset`; the other name is in no table and lands in
## `ccEntryDocument`. A hard-coded header, including express's own
## `public, max-age=0`, fails one of the two.
##
## ## What is real
##
## `index/server_config.nim`'s `setupServer` over the shipped defaults, its
## express app, and real HTTP requests to the port it bound. The probe FILES
## are created by this suite under whichever directory `codetracerExeDir`
## resolves to, because they are build outputs and a bare checkout has neither;
## each is removed afterwards, along with any directory the suite had to make
## and only those, so a run in a built tree leaves the build alone.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`.

import std/[jsffi, strutils]

import lib/src_relative_require
import ../index/config
import ../index/server_config
from ../viewmodel/platform/web_deployment import cacheClassFor, headerFor,
  CacheClass, ccImmutable
from ../../common/paths import codetracerExeDir

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

## `<status>\x1f<cache-control>`, so one callback carries both and a 404 is
## reported as a 404 rather than as a missing header.
proc fetchHead(port: int; path: cstring;
               cb: proc(answer: cstring)) {.importjs: """(function (port, path, cb) {
  var req = require('http').request(
    { host: '127.0.0.1', port: port, path: path, method: 'GET' },
    function (res) {
      res.resume();
      cb('' + res.statusCode + '\x1f' + (res.headers['cache-control'] || ''));
    });
  req.on('error', function (e) { cb('0\x1f' + e.code); });
  req.end();
})(#, #, #)""".}

proc nodeMkdirp(path: cstring): bool {.importjs: """(function (p) {
  return require('fs').mkdirSync(p, { recursive: true }) !== undefined;
})(#)""".}
proc nodeWrite(path, content: cstring) {.importjs:
  "require('fs').writeFileSync(#, #)".}
proc nodeRemove(path: cstring) {.importjs:
  "require('fs').rmSync(#, { force: true, recursive: true })".}
proc nodeExists(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}

const Probes = [
  # (url asked for, path relative to `codetracerExeDir`)
  ("/frontend/styles/loader.css", "frontend/styles/loader.css"),
  ("/public/ct-cache-probe.css", "public/ct-cache-probe.css")]

var created: seq[string] = @[]

proc placeProbeFiles() =
  for probe in Probes:
    let full = (if codetracerExeDir.len > 0: codetracerExeDir & "/" else: "") &
               probe[1]
    let slash = full.rfind('/')
    let directory = if slash >= 0: full[0 ..< slash] else: "."
    if not nodeExists(directory.cstring):
      # `mkdirSync(recursive)` answers the FIRST directory it had to create and
      # `undefined` when there was nothing to do; that is exactly what has to
      # go afterwards, and nothing above it.
      if nodeMkdirp(directory.cstring):
        created.add directory
    nodeWrite(full.cstring, cstring"/* cache-class probe */")
    created.add full

proc removeProbeFiles() =
  # Reverse order: the files before the directories holding them.
  for i in countdown(created.len - 1, 0):
    nodeRemove(created[i].cstring)

const ExpectedChecks = 4

proc finish() =
  removeProbeFiles()
  echo "CHECKS: ", checks
  if checks != ExpectedChecks:
    inc failedChecks
    echo "  [FAILED] the suite ran ", checks, " of ", ExpectedChecks,
      " cases; the callback chain was cut short"
  echo ""
  echo checks, " check(s): ", checks - failedChecks, " OK, ", failedChecks, " FAILED"
  exitProcess(if failedChecks == 0: 0 else: 1)

proc runProbes(port: int; index: int) =
  if index >= Probes.len:
    # THE CONTROL that the two probes above are not one class in disguise.
    ck headerFor(cacheClassFor(Probes[0][0])) !=
       headerFor(cacheClassFor(Probes[1][0])),
      "CONTROL: the deployment gives the two probed URLs DIFFERENT headers, " &
        "so a hard-coded one could not have satisfied both"
    ck headerFor(ccImmutable).contains("immutable"),
      "CONTROL: and the table it is read from is the deployment's real one " &
        "(its immutable class says `immutable`)"
    finish()
    return

  let path = Probes[index][0]
  fetchHead(port, path.cstring, proc(answer: cstring) =
    let parts = ($answer).split('\x1f')
    let status = parts[0]
    let served = if parts.len > 1: parts[1] else: ""
    let expected = headerFor(cacheClassFor(path))
    if status != "200":
      # Not a skip. A mount that served nothing would make the header
      # assertion vacuous, which is what this suite exists to avoid.
      ck false, path & " is served by `ct host` (got " & status & ")"
    else:
      ck served == expected,
        path & " carries the deployment's own class: expected `" & expected &
          "`, got `" & served & "`"
    runProbes(port, index + 1))

proc start(httpPort, socketPort: int) =
  placeProbeFiles()
  data.startOptions.port = httpPort
  data.startOptions.backendSocket.port = socketPort
  setupServer()
  runProbes(httpPort, 0)

echo "index_serves_deployment_cache_classes_test"

freePort(proc(p1: int) =
  freePort(proc(p2: int) =
    start(p1, p2)))
