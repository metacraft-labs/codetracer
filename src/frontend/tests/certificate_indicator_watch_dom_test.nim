## certificate_indicator_watch_dom_test.nim
##
## ON THE DESKTOP, THE CERTIFICATE INDICATOR REFRESHES WHEN A FACT MOVES, NOT
## ONLY ON ITS TIMER.
##
## ## The defect this pins
##
## The status bar's certificate indicator (`ui/certificate_indicator.nim`)
## refreshes on triggers: a watch on `<repository>/.git` (staging moves S, a
## commit or checkout moves H), one on the repository root (a top-level edit
## moves W) and ones on the certificate store's directories (Status-Bar.md).
## Every watch needs `capFilesystemWatch`, which the Electron desktop profile
## did not grant — the desktop's watchers live in the main process — so on the
## desktop NONE was armed, and a `git add` or a certificate arriving was seen
## only by the 15 s backstop timer. The renderer's `fs.watch` is now served by
## the main process (`index/renderer_fs_watch.nim`), and the profile grants
## the capability.
##
## ## What is asserted
##
##   0. The facade, first: the desktop profile grants `capFilesystemWatch`;
##      `fs.watch` of an existing directory sends `CODETRACER::fs-watch` and
##      answers a handle at once; main's event for that handle reaches the
##      callback and no other handle's does; `unwatch` sends
##      `CODETRACER::fs-unwatch`; a missing path is `pkNotFound` with no
##      request.
##   1. Once the first gather completes, the indicator has asked for a watch
##      on the repository's `.git`, on its root and on the store's root.
##   2. An event from the `.git` watch naming `index` refreshes the indicator
##      AT ONCE — in the same turn the event is delivered, so not by the timer
##      — with the staging trigger, `citIndexChanged`; one naming `HEAD`, with
##      `citCommitChanged`.
##   3. An event from the root's watch refreshes it with `citWorktreeChanged`,
##      and one from the store's with `citStoreChanged`.
##   4. The refresh an event starts completes: the indicator's gather answers
##      again.
##
## ## What is real, and the stand-in
##
## REAL: the indicator module as the status bar runs it, its ViewModel and
## gatherer, the Electron renderer's filesystem and VCS facades
## (`desktop_electron.electronFileSystem` / `electronVcs`) with the desktop
## profile, `git` over a repository this suite creates, and the content-id
## recipe.
##
## THE ONE STAND-IN is the main process, at `desktop_electron.rendererIpc`:
## Electron's IPC does not exist under node. It answers content-id and
## declared-scopes requests with the SAME recipe main's worker runs
## (`contentIdOver` / `declaredScopesOver` over `nodeContentIdHost`), on a
## later turn as main does, and it records watch requests rather than running
## node's `fs.watch`; the suite then delivers the events main would send.
## Main's own half — a real `fs.watch` firing on a real `git add` — is
## `content_id_worker_test.nim`'s, in the `main-process` lane.
##
## Every path is under one `mkdtemp` directory (the store too, through
## `TEST_CERTIFICATES_DIR`), git's global and system configuration point at a
## file that does not exist, and the directory is removed at the end.
##
## Lane: `renderer-dom` — the browser target (`nim js -d:ctRenderer`), run by
## `jsdom-run.mjs`, which provides node's `require`.

import std/[asyncjs, json, jsffi, strutils]

import ../viewmodel/platform/outcome
import ../viewmodel/platform/platform
import ../viewmodel/platform/capabilities
import ../viewmodel/platform/fs
import ../viewmodel/platform/vcs
import ../viewmodel/viewmodels/certificate_indicator_vm
import ../viewmodel/host/electron_profile
import ../viewmodel/host/node_certificate_host
import ../viewmodel/host/main_process_wire
import ../viewmodel/host/desktop_electron
import ../ui/certificate_indicator

const ExpectedChecks = 14

var checks = 0
var failedChecks = 0

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

proc exitProcess(code: int) {.importjs: "process.exit(#)".}
proc nodeRequire(module: cstring): JsObject {.importjs: "require(#)".}
proc setEnv(name, value: cstring) {.importjs: "process.env[#] = #".}
proc later(callback: proc()) {.importjs: "setTimeout(#, 0)".}
proc sleepMs(ms: int): Future[void] {.importjs:
  "new Promise(function (resolve) { setTimeout(resolve, #); })".}
proc execGitRaw(args: seq[cstring]; cwd: cstring): cstring
  {.importjs: "require('child_process').execFileSync('git', #, {cwd: #, encoding: 'utf8'})".}

let nodeFs = nodeRequire("fs")
let workspace = $(nodeFs.mkdtempSync(cstring(
  $(nodeRequire("os").tmpdir().to(cstring)) & "/ct-indicator-watch-")).to(cstring))
setEnv(cstring"GIT_CONFIG_GLOBAL", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_SYSTEM", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")
setEnv(cstring"GIT_CEILING_DIRECTORIES", cstring(workspace))
for role in ["AUTHOR", "COMMITTER"]:
  setEnv(cstring("GIT_" & role & "_NAME"), cstring"Indicator Watch Test")
  setEnv(cstring("GIT_" & role & "_EMAIL"), cstring"indicator@test.invalid")
let store = workspace & "/store"
discard nodeFs.mkdirSync(cstring(store))
setEnv(cstring"TEST_CERTIFICATES_DIR", cstring(store))

proc git(cwd: string; args: varargs[string]) =
  var jsArgs: seq[cstring] = @[]
  for a in args: jsArgs.add cstring(a)
  discard execGitRaw(jsArgs, cstring(cwd))

# The main process, as far as this renderer can see it.
let profile = electronDesktopProfile(false)
let recipe = nodeContentIdHost()
var listeners: seq[tuple[channel: string; handler: proc(payload: JsObject)]] = @[]
var watchRequests: seq[tuple[handle, path: string]] = @[]
var unwatchRequests: seq[string] = @[]
var requestCount = 0
var answered = 0

proc deliver(channel: string; payload: JsObject) =
  for entry in listeners:
    if entry.channel == channel:
      entry.handler(payload)

proc answerLater(channel: string; id: JsObject; outcome: string) =
  later(proc() =
    inc answered
    deliver(channel, JsObject{id: id, outcome: cstring(outcome)}))

desktop_electron.rendererIpc = RendererIpc(
  send: proc(channel: cstring; payload: JsObject) =
    inc requestCount
    case $channel
    of ContentIdChannel:
      let r = decodeRequest(parseJson($payload[cstring"request"].to(cstring)))
      answerLater(ContentIdReceivedChannel, payload[cstring"id"],
        encodeContentIdOutcome(contentIdOver(recipe, profile, r.repository,
                                             r.state, r.algorithm, r.scope)))
    of DeclaredScopesChannel:
      let r = decodeRequest(parseJson($payload[cstring"request"].to(cstring)))
      answerLater(DeclaredScopesReceivedChannel, payload[cstring"id"],
        encodeDeclaredScopesOutcome(declaredScopesOver(recipe, profile,
                                                       r.repository)))
    of FsWatchChannel:
      watchRequests.add((handle: $payload[cstring"handle"].to(cstring),
                         path: $payload[cstring"path"].to(cstring)))
    of FsUnwatchChannel:
      unwatchRequests.add $payload[cstring"handle"].to(cstring)
    else: discard,
  listen: proc(channel: cstring; handler: proc(payload: JsObject)) =
    listeners.add((channel: $channel, handler: handler)))

var desktop = newPlatform(profile)
desktop.fs = electronFileSystem(profile)
desktop.vcs = electronVcs(profile)
installPlatform(desktop)

proc handleFor(path: string): string =
  for request in watchRequests:
    if request.path == path:
      return request.handle
  ""

proc event(handle, path: string) =
  deliver(FsWatchEventChannel, JsObject{handle: cstring(handle),
    kind: cstring"fwkModified", path: cstring(path)})

proc waitFor(pred: proc(): bool; ms: int): Future[bool] {.async.} =
  var waited = 0
  while not pred() and waited < ms:
    await sleepMs(20)
    waited += 20
  return pred()

proc runCases() {.async.} =
  let repo = workspace & "/repo"
  discard nodeFs.mkdirSync(cstring(repo))
  git(repo, "init", "-q", ".")
  discard nodeFs.writeFileSync(cstring(repo & "/a.txt"), cstring"alpha\n")
  git(repo, "add", "-A")
  git(repo, "commit", "-q", "-m", "initial")
  # The repository's real path: `rev-parse --show-toplevel` resolves links
  # (a temporary directory under a linked /tmp), and the watches are armed
  # on the root it names.
  let root = $nodeFs.realpathSync(cstring(repo)).to(cstring)

  echo "[Suite] the desktop renderer's fs.watch is asked of the main process"
  ck profile.has(capFilesystemWatch), "the desktop profile grants capFilesystemWatch"
  block:
    let files = desktop.fs
    var events: seq[FsWatchEvent] = @[]
    var armedHandle = ""
    var armedOk = false
    files.watch(workspace, false,
      proc(event: FsWatchEvent) = events.add event).onComplete(
      proc(outcome: PlatformOutcome[FsWatchHandle]) =
        armedOk = outcome.ok
        if outcome.ok: armedHandle = string(outcome.value),
      proc(message: string) = discard)
    drainPlatformCallbacks()
    ck armedOk, "watch answers a handle at once"
    ck watchRequests.len == 1 and watchRequests[0].path == workspace and
       watchRequests[0].handle == armedHandle,
       "watch sends " & FsWatchChannel & " for the path, with that handle"
    event("another-handle", workspace & "/other")
    event(armedHandle, workspace & "/index")
    ck events.len == 1 and events[0].kind == fwkModified and
       events[0].path == workspace & "/index",
       "main's event for the handle reaches the callback, and no other does"
    files.unwatch(FsWatchHandle(armedHandle)).onComplete(
      proc(outcome: PlatformOutcome[Nothing]) = discard,
      proc(message: string) = discard)
    drainPlatformCallbacks()
    ck unwatchRequests == @[armedHandle],
       "unwatch sends " & FsUnwatchChannel & " for the handle"
    let before = requestCount
    var missingKind = pkNone
    files.watch(workspace & "/ct-no-such-directory-here", false,
      proc(event: FsWatchEvent) = discard).onComplete(
      proc(outcome: PlatformOutcome[FsWatchHandle]) =
        missingKind = (if outcome.ok: pkNone else: outcome.error.kind),
      proc(message: string) = discard)
    drainPlatformCallbacks()
    ck missingKind == pkNotFound and requestCount == before,
       "a missing path is pkNotFound, with no request"
    watchRequests = @[]

  echo "[Suite] the desktop indicator arms its watches through the main process"
  ensureCertificateIndicator(repo, proc() = discard)
  let indicator = certificateIndicator()
  let armed = await waitFor(proc(): bool = handleFor(root & "/.git").len > 0,
                            30_000)
  ck armed, "after the first gather, a watch on .git was asked for"
  ck handleFor(root).len > 0, "and one on the repository root"
  ck handleFor(store).len > 0, "and one on the certificate store's root"

  echo "[Suite] a watch event refreshes the indicator at once"
  # Let the first gather settle, so a trigger starts a gather of its own
  # rather than queueing behind one.
  discard await waitFor(proc(): bool = answered > 0 and not indicator.isNil, 5_000)
  await sleepMs(200)
  block:
    let before = indicator.refreshes
    event(handleFor(root & "/.git"), root & "/.git/index")
    ck indicator.refreshes == before + 1 and
       indicator.lastTrigger == citIndexChanged,
       "an index write refreshes it in the same turn, as citIndexChanged"
    let answeredBefore = answered
    ck await waitFor(proc(): bool = answered > answeredBefore, 10_000),
       "the refresh it started gathers again"
  await sleepMs(200)
  block:
    let before = indicator.refreshes
    event(handleFor(root & "/.git"), root & "/.git/HEAD")
    ck indicator.refreshes == before + 1 and
       indicator.lastTrigger == citCommitChanged,
       "a HEAD write refreshes it as citCommitChanged"
  await sleepMs(500)
  block:
    let before = indicator.refreshes
    event(handleFor(root), root & "/a.txt")
    ck indicator.refreshes == before + 1 and
       indicator.lastTrigger == citWorktreeChanged,
       "a top-level edit refreshes it as citWorktreeChanged"
  await sleepMs(500)
  block:
    let before = indicator.refreshes
    event(handleFor(store), store & "/git-tree-sha1")
    ck indicator.refreshes == before + 1 and
       indicator.lastTrigger == citStoreChanged,
       "a store change refreshes it as citStoreChanged"

proc main() {.async.} =
  try:
    await runCases()
  except:
    inc failedChecks
    echo "  [FAILED] the suite itself raised: ", getCurrentExceptionMsg()
  try:
    discard nodeFs.rmSync(cstring(workspace), JsObject{recursive: true, force: true})
  except:
    discard
  echo "CHECKS: ", checks, " FAILED: ", failedChecks
  if checks != ExpectedChecks:
    echo "  [FAILED] expected ", ExpectedChecks, " checks, ran ", checks
  # Exits explicitly: the indicator's backstop timer would keep node alive.
  exitProcess(if failedChecks == 0 and checks == ExpectedChecks: 0 else: 1)

discard main()
