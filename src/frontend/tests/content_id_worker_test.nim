## content_id_worker_test.nim
##
## THE CERTIFICATE FACTS ARE COMPUTED IN A WORKER THREAD OF THE MAIN PROCESS.
##
## The status bar's certificate indicator reads three content ids (W, H, S)
## and the declared scopes on every refresh. The Electron renderer used to
## compute them itself through a resumable driver that replays the whole
## recipe once per git answer: seconds of renderer work per refresh on a
## large repository. They are now computed by
## `index/content_id_service.nim` in a node `worker_thread`
## (`index/content_id_worker.nim`), once, through the synchronous recipe.
##
## ## The claims
##
##   1. **The worker's answers are the synchronous recipe's.** W, H and S of a
##      repository whose three states differ, a scoped W, a directory outside
##      any repository (a failure) and the declared scopes, each compared with
##      `contentIdOver` / `declaredScopesOver` over `nodeContentIdHost` in
##      this thread.
##   2. **Main's event loop runs while the worker computes.** With a git that
##      takes 0.3 s per call, a timer scheduled right after the request fires
##      before the answer, and an interval keeps ticking. Computed on this
##      thread (the recipe through `spawnSync`), neither could happen.
##   3. **One worker serves every request, and a worker that cannot run
##      answers instead of hanging.** A service over a missing script answers
##      each request with a failure.
##   4. **The IPC handlers answer the request they were sent.**
##      `onContentId` answers on `CODETRACER::content-id-received` with the
##      request's `id` and the worker's outcome.
##
## ## What is real, and the stand-ins
##
## REAL: `git` over repositories this suite creates, node's `worker_threads`,
## the recipe, the service and the worker module.
##
## THE WORKER'S SCRIPT is this suite's own bundle: the lane compiles one file,
## so there is no `content_id_worker.js` beside it. Started as a worker, the
## bundle runs `serveContentIdRequests` — the shipped worker's whole body —
## and nothing else (the last line of this file).
##
## THE SEND PATH, `electron_vars.mainWindow`, is a recorder: the window
## routing that delivers an answer to the window that asked is
## `desktop_window_routing_test.nim`'s subject, not this suite's.
##
## THE SLOW GIT of claim 2 is a `/bin/sh` script that sleeps 0.3 s and `exec`s
## the real git, so "the loop ran while git did" is not a race.
##
## Every path is under one `mkdtemp` directory, git's global and system
## configuration point at a file that does not exist, and the directory is
## removed at the end.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, run under
## node.

import std/[asyncjs, jsffi, json, strutils]

import ../viewmodel/platform/outcome
import ../viewmodel/platform/vcs
import ../viewmodel/platform/capabilities
import ../viewmodel/host/electron_profile
import ../viewmodel/host/node_certificate_host
import ../viewmodel/host/main_process_wire
import ../index/electron_vars
import ../index/content_id_worker
import ../index/content_id_service

proc isMainThread(): bool {.importjs: "require('worker_threads').isMainThread".}
proc thisBundle(): cstring {.importjs: "(__filename)@".}
proc exitProcess(code: int) {.importjs: "process.exit(#)".}
proc nodeRequire(module: cstring): JsObject {.importjs: "require(#)".}
proc setEnv(name, value: cstring) {.importjs: "process.env[#] = #".}
proc getEnv(name: cstring): cstring {.importjs: "(process.env[#] || '')".}
proc setTimeout(callback: proc(); ms: int) {.importjs: "setTimeout(#, #)".}
proc setInterval(callback: proc(); ms: int): JsObject {.importjs: "setInterval(#, #)".}
proc clearInterval(handle: JsObject) {.importjs: "clearInterval(#)".}
proc execGitRaw(args: seq[cstring]; cwd: cstring): cstring
  {.importjs: "require('child_process').execFileSync('git', #, {cwd: #, encoding: 'utf8'})".}
proc sleepMs(ms: int): Future[void] {.importjs:
  "new Promise(function (resolve) { setTimeout(resolve, #); })".}

const ExpectedChecks = 19

var checks = 0
var failedChecks = 0

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

var workspace = ""

proc git(cwd: string; args: varargs[string]): string =
  var jsArgs: seq[cstring] = @[]
  for a in args: jsArgs.add cstring(a)
  result = $execGitRaw(jsArgs, cstring(cwd))
  result.stripLineEnd()

proc writeText(path, text: string) =
  discard nodeRequire("fs").writeFileSync(cstring(path), cstring(text))

proc makeDir(path: string) =
  discard nodeRequire("fs").mkdirSync(cstring(path), JsObject{recursive: true})

proc sameAnswer(a, b: PlatformOutcome[VcsContentId]): bool =
  if a.ok != b.ok: return false
  if not a.ok:
    return a.error.kind == b.error.kind and a.error.message == b.error.message
  a.value.kind == b.value.kind and a.value.id == b.value.id and
    a.value.algorithm == b.value.algorithm and a.value.reason == b.value.reason

proc describe(o: PlatformOutcome[VcsContentId]): string =
  if not o.ok: return "error " & $o.error
  $o.value.kind & " " & o.value.id & " " & o.value.reason

proc settle[T](future: PlatformFuture[PlatformOutcome[T]]): Future[PlatformOutcome[T]] =
  newPromise(proc(resolve: proc(value: PlatformOutcome[T])) =
    future.onComplete(
      proc(value: PlatformOutcome[T]) = resolve(value),
      proc(message: string) =
        resolve(failed[T](pkTransport, "the future rejected", message)))
    # An already-settled future (a refusal) delivers through the platform's
    # own callback queue, which only this drain runs.
    drainPlatformCallbacks())

# A recorder in place of the window the answers go to.
var sent: seq[tuple[channel: string; payload: JsObject]] = @[]

proc installRecorder() =
  mainWindow = JsObject{webContents: JsObject{}}
  mainWindow.webContents.send = proc(channel: cstring; payload: JsObject) =
    sent.add (channel: $channel, payload: payload)

proc waitFor(pred: proc(): bool; ms: int): Future[bool] {.async.} =
  var waited = 0
  while not pred() and waited < ms:
    await sleepMs(20)
    waited += 20
  return pred()

proc runCases() {.async.} =
  let profile = electronDesktopProfile(false)
  let syncHost = nodeContentIdHost()
  let service = newContentIdService($thisBundle())

  echo "[Suite] the content ids are the worker's, computed off main's thread"

  let repo = workspace & "/repo"
  makeDir(repo & "/src")
  discard git(repo, "init", "-q", "--object-format=sha1", ".")
  writeText(repo & "/a.txt", "alpha\n")
  writeText(repo & "/src/b.nim", "echo 1\n")
  discard git(repo, "add", "-A")
  discard git(repo, "commit", "-q", "-m", "initial")
  writeText(repo & "/src/b.nim", "echo 2\n")
  discard git(repo, "add", "src/b.nim")
  writeText(repo & "/a.txt", "alpha, edited\n")

  proc expected(state: VcsBlobSource; scope: seq[string] = @[];
                at = repo): PlatformOutcome[VcsContentId] =
    contentIdOver(syncHost, profile, at, state, "git-tree-sha1", scope)

  for (label, state) in [("W", vbsWorkingTree), ("H", vbsHead), ("S", vbsIndex)]:
    let got = await settle(service.contentId(profile, repo, state,
                                             "git-tree-sha1", @[]))
    let want = expected(state)
    if not sameAnswer(got, want):
      echo "    worker: ", describe(got)
      echo "    sync:   ", describe(want)
    ck got.ok and got.value.kind == vcikComputed and sameAnswer(got, want),
       label & ": the worker's id is the synchronous recipe's"
  let w = expected(vbsWorkingTree)
  let h = expected(vbsHead)
  let s = expected(vbsIndex)
  ck w.value.id != h.value.id and s.value.id != h.value.id and
     w.value.id != s.value.id, "control: W, H and S are three different ids"

  block:
    let got = await settle(service.contentId(profile, repo, vbsWorkingTree,
                                             "git-tree-sha1", @["src"]))
    ck sameAnswer(got, expected(vbsWorkingTree, @["src"])) and
       got.value.id != w.value.id,
       "W scoped to src: the synchronous recipe's, and not the whole tree's"

  block:
    let outside = workspace & "/not-a-repository"
    makeDir(outside)
    let got = await settle(service.contentId(profile, outside, vbsWorkingTree,
                                             "git-tree-sha1", @[]))
    ck not got.ok and sameAnswer(got, expected(vbsWorkingTree, at = outside)),
       "outside any repository: the same failure as the synchronous recipe"

  block:
    discard git(repo, "config", "--add", "testCertificatesScope.lib.path", "src")
    let got = await settle(service.declaredScopes(profile, repo))
    let want = declaredScopesOver(syncHost, profile, repo)
    ck got.ok and want.ok and got.value.scopes == want.value.scopes and
       got.value.scopes == @[@["src"]],
       "declaredScopes: the synchronous reader's answer"
    discard git(repo, "config", "--remove-section", "testCertificatesScope.lib")

  block:
    var refused = profile
    refused.capabilities.excl capVcsRead
    let got = await settle(service.contentId(refused, repo, vbsHead,
                                             "git-tree-sha1", @[]))
    ck not got.ok and got.error.kind == pkNotSupported,
       "a profile without capVcsRead is refused"

  echo "[Suite] main's event loop runs while the worker computes"
  block:
    let gitPath = ($nodeRequire("child_process").execFileSync(
      cstring"/bin/sh", @[cstring"-c", cstring"command -v git"],
      JsObject{encoding: cstring"utf8"}).to(cstring)).strip()
    let slowBin = workspace & "/slow-bin"
    makeDir(slowBin)
    writeText(slowBin & "/git", "#!/bin/sh\nsleep 0.3\nexec '" & gitPath & "' \"$@\"\n")
    discard nodeRequire("fs").chmodSync(cstring(slowBin & "/git"), 0o755)
    let savedPath = $getEnv(cstring"PATH")
    setEnv(cstring"PATH", cstring(slowBin & ":" & savedPath))
    var timerFired = false
    var timerBeforeAnswer = false
    var ticks = 0
    var answered = false
    let pending = settle(service.contentId(profile, repo, vbsWorkingTree,
                                           "git-tree-sha1", @[]))
    setTimeout(proc() =
      timerFired = true
      timerBeforeAnswer = not answered, 10)
    let interval = setInterval(proc() = (inc ticks), 5)
    let got = await pending
    answered = true
    clearInterval(interval)
    setEnv(cstring"PATH", cstring(savedPath))
    ck timerFired and timerBeforeAnswer,
       "a timer scheduled after the request fires before the answer"
    ck ticks > 0, "an interval ticked while the worker computed (" & $ticks & " ticks)"
    ck sameAnswer(got, w), "a slow git: W is still the synchronous recipe's"

  ck service.started == 1, "one worker served every request (" &
     $service.started & " started)"

  echo "[Suite] a worker that cannot run answers instead of hanging"
  block:
    let broken = newContentIdService(workspace & "/no-such-worker.js")
    let first = await settle(broken.contentId(profile, repo, vbsHead,
                                              "git-tree-sha1", @[]))
    ck not first.ok and first.error.kind == pkFailed and
       "content-id worker" in first.error.message,
       "a missing worker script: a failure naming the worker (" &
       (if first.ok: "ok" else: first.error.message & " / " & first.error.detail) & ")"
    let scopes = await settle(broken.declaredScopes(profile, repo))
    ck not scopes.ok and broken.started == 2,
       "the next request starts a new worker, and fails the same way"

  echo "[Suite] the IPC handlers answer the request they were sent"
  installRecorder()
  processWorkerScript = $thisBundle()
  block:
    let request = $encodeRequest(ContentIdRequest(op: OpContentId,
      repository: repo, state: vbsHead, algorithm: "git-tree-sha1"))
    await onContentId(nil, JsObject{id: 7, request: cstring(request), tab: 2})
    let arrived = await waitFor(proc(): bool = sent.len > 0, 10_000)
    ck arrived and sent[0].channel == ContentIdReceivedChannel,
       "onContentId answers on " & ContentIdReceivedChannel
    if arrived:
      let payload = sent[0].payload
      ck payload[cstring"id"].to(int) == 7, "the answer carries the request's id"
      ck payload[cstring"tab"].to(int) == 2, "the answer carries the request's tab"
      ck sameAnswer(decodeContentIdOutcome($payload[cstring"outcome"].to(cstring)), h),
         "the answer is H, the synchronous recipe's"
    else:
      ck false, "the answer carries the request's id"
      ck false, "the answer carries the request's tab"
      ck false, "the answer is H, the synchronous recipe's"
  block:
    sent = @[]
    await onDeclaredScopes(nil, JsObject{id: 8, request: cstring"{not json"})
    let arrived = await waitFor(proc(): bool = sent.len > 0, 10_000)
    ck arrived and sent[0].channel == DeclaredScopesReceivedChannel and
       not decodeDeclaredScopesOutcome($sent[0].payload[cstring"outcome"].to(cstring)).ok,
       "a request that cannot be read is answered with a failure"


proc main() {.async.} =
  let nodeOs = nodeRequire("os")
  workspace = $(nodeRequire("fs").mkdtempSync(
    cstring($(nodeOs.tmpdir().to(cstring)) & "/ct-content-id-worker-")).to(cstring))
  # A git that sees only this suite's repositories.
  setEnv(cstring"GIT_CONFIG_GLOBAL", cstring(workspace & "/absent-gitconfig"))
  setEnv(cstring"GIT_CONFIG_SYSTEM", cstring(workspace & "/absent-gitconfig"))
  setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")
  setEnv(cstring"GIT_CEILING_DIRECTORIES", cstring(workspace))
  for role in ["AUTHOR", "COMMITTER"]:
    setEnv(cstring("GIT_" & role & "_NAME"), cstring"Content Id Worker Test")
    setEnv(cstring("GIT_" & role & "_EMAIL"), cstring"content-id@test.invalid")
  try:
    await runCases()
  except:
    inc failedChecks
    echo "  [FAILED] the suite itself raised: ", getCurrentExceptionMsg()
  try:
    discard nodeRequire("fs").rmSync(cstring(workspace),
                                     JsObject{recursive: true, force: true})
  except:
    discard
  echo "CHECKS: ", checks, " FAILED: ", failedChecks
  if checks != ExpectedChecks:
    echo "  [FAILED] expected ", ExpectedChecks, " checks, ran ", checks
  exitProcess(if failedChecks == 0 and checks == ExpectedChecks: 0 else: 1)

if isMainThread():
  discard main()
else:
  serveContentIdRequests()
