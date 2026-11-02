## `ct host` SERVES THE DESIGN SYSTEM'S TYPEFACES AT THE URLS ITS CSS NAMES
##
## ## The defect this pins
##
## `styles/generated/fonts.styl` names the Space Grotesk / Space Mono / Fira
## Mono faces relative to the stylesheet
## (`../../../../libs/codetracer-design-system/…`). The desktop resolves that
## on the filesystem; a page `ct host` serves resolves it to
## `/libs/codetracer-design-system/…`, which nothing mounted, so every served
## page fell back to the browser's default fonts (codetracer-pm
## issues/2026-10-21-ct-host-does-not-serve-the-design-system-fonts-its-css-names.md).
##
## ## What is real
##
## `index/server_config.nim`'s `setupServer` over the shipped defaults and real
## HTTP requests to the port it bound. The URLs are the ones the stylesheet
## produces: read from the checkout's generated `fonts.styl` (the lane runs
## from the checkout root) and resolved the way a browser resolves them, so a
## regenerated stylesheet that moved the faces is followed rather than missed.
## The font files are the checkout's own (`libs/codetracer-design-system`, a
## submodule). The server serves them from `codetracerInstallDir`, which in a
## lane is derived from the nimcache the suite runs from, so each face missing
## there is copied in first and removed afterwards — only what this suite
## created, so a run in a built tree leaves the build alone.
## The CONTROL is a URL under the same mount that names no file: it must be a
## 404, so a server that answered everything with 200 cannot pass.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`.

import std/[jsffi, strutils]

import lib/src_relative_require
import ../index/config
import ../index/server_config
from ../../common/paths import codetracerInstallDir

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

## `<status>\x1f<content-type>`.
proc fetchHead(port: int; path: cstring;
               cb: proc(answer: cstring)) {.importjs: """(function (port, path, cb) {
  var req = require('http').request(
    { host: '127.0.0.1', port: port, path: path, method: 'GET' },
    function (res) {
      res.resume();
      cb('' + res.statusCode + '\x1f' + (res.headers['content-type'] || ''));
    });
  req.on('error', function (e) { cb('0\x1f' + e.code); });
  req.end();
})(#, #, #)""".}

proc nodeRead(path: cstring): cstring {.importjs:
  "require('fs').readFileSync(#, 'utf8')".}
proc nodeCwd(): cstring {.importjs: "process.cwd()".}
proc nodeExists(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}
proc nodeMkdirp(path: cstring): cstring {.importjs: """(function (p) {
  var r = require('fs').mkdirSync(p, { recursive: true });
  return r === undefined ? '' : r;
})(#)""".}
proc nodeCopy(src, dst: cstring) {.importjs: "require('fs').copyFileSync(#, #)".}
proc nodeRemove(path: cstring) {.importjs:
  "require('fs').rmSync(#, { force: true, recursive: true })".}

var created: seq[string] = @[]

proc placeFonts(urls: seq[string]) =
  ## Make each face exist where the server will look for it.
  for url in urls:
    let base = $codetracerInstallDir
    if base.len == 0: continue   # the server serves the checkout's own files
    let dst = base & url
    if nodeExists(dst.cstring): continue
    let src = $nodeCwd() & url
    if not nodeExists(src.cstring): continue
    let slash = dst.rfind('/')
    let made = $nodeMkdirp(dst[0 ..< slash].cstring)
    if made.len > 0: created.add made
    nodeCopy(src.cstring, dst.cstring)
    created.add dst

proc removeFonts() =
  for i in countdown(created.len - 1, 0):
    nodeRemove(created[i].cstring)

proc fontUrls(): seq[string] =
  ## Every `url('…')` in the generated font stylesheet, resolved against the
  ## served stylesheet directory `/frontend/styles/generated/` — four `..`
  ## climb to the site root.
  let css = $nodeRead(cstring($nodeCwd() &
    "/src/frontend/styles/generated/fonts.styl"))
  var at = 0
  while true:
    let start = css.find("url('", at)
    if start < 0: break
    let stop = css.find("')", start)
    if stop < 0: break
    var rel = css[start + 5 ..< stop]
    while rel.startsWith("../"): rel = rel[3 .. ^1]
    let url = "/" & rel
    if url notin result: result.add url
    at = stop

const ExpectedChecks = 3

proc finish() =
  removeFonts()
  echo "CHECKS: ", checks
  if checks != ExpectedChecks:
    inc failedChecks
    echo "  [FAILED] the suite ran ", checks, " of ", ExpectedChecks,
      " cases; the callback chain was cut short"
  echo checks, " check(s): ", checks - failedChecks, " OK, ", failedChecks, " FAILED"
  exitProcess(if failedChecks == 0: 0 else: 1)

proc run(port: int) =
  let urls = fontUrls()
  placeFonts(urls)
  ck urls.len >= 6 and urls[0].startsWith("/libs/codetracer-design-system/"),
    "the generated stylesheet names its faces under " &
      "/libs/codetracer-design-system/ (" & $urls.len & " urls)"
  var missing: seq[string] = @[]
  var remaining = urls.len
  proc afterAll() =
    ck missing.len == 0,
      "every face the stylesheet names is served (missing: " &
        missing.join(", ") & ")"
    fetchHead(port, cstring"/libs/codetracer-design-system/no-such-font.woff2",
      proc(answer: cstring) =
        ck ($answer).split('\x1f')[0] == "404",
          "CONTROL: a name under the mount that is no file is a 404"
        finish())
  if remaining == 0:
    afterAll()
    return
  # A factory, so each callback owns its url (Nim closures capture a loop's
  # variables by reference: https://nim-lang.org/docs/manual.html#procedures-closures).
  proc onAnswer(u: string): proc(answer: cstring) =
    result = proc(answer: cstring) =
      if ($answer).split('\x1f')[0] != "200":
        missing.add u & " (" & ($answer).replace("\x1f", " ") & ")"
      dec remaining
      if remaining == 0: afterAll()
  for url in urls:
    fetchHead(port, url.cstring, onAnswer(url))

proc start(httpPort, socketPort: int) =
  data.startOptions.port = httpPort
  data.startOptions.backendSocket.port = socketPort
  setupServer()
  run(httpPort)

echo "index_serves_design_system_fonts_test"

freePort(proc(p1: int) =
  freePort(proc(p2: int) =
    start(p1, p2)))
