## desktop_main_process_requests_dom_test.nim
##
## THE DESKTOP RENDERER ASKS THE MAIN PROCESS FOR ITS CONTENT IDS,
## AND RUNS NO GIT FOR THEM ITSELF.
##
## ## The defect this pins
##
## The status bar's certificate indicator computes three content ids (W, H,
## S) and reads the declared scopes on every refresh. The Electron renderer's
## VCS facade computed them itself, through `vcs.contentIdOverAsync`: git in
## child processes, but the recipe driven by a resumable runner that replays
## the whole computation once per git answer, copying, splitting and parsing
## the full index listing again each time. On a 25,000-entry index a profile
## measured about 2.5 s of synchronous renderer time per refresh, landing on
## whatever the user was doing. The facade now sends `CODETRACER::content-id`
## / `CODETRACER::declared-scopes` to the main process, which computes them in
## a worker thread (`index/content_id_service.nim`, held by
## `content_id_worker_test.nim` in the `main-process` lane).
##
## ## What is asserted
##
##   1. `contentId` sends one `CODETRACER::content-id` request naming the
##      repository, state, algorithm and scope; the future is pending until
##      the answer for ITS id arrives, and then settles with that answer. An
##      answer for another id does not settle it.
##   2. `declaredScopes` does the same on its channel.
##   3. Neither starts a child process in the renderer.
##   4. A profile without `capVcsRead` is refused without a request.
##
## ## The stand-ins, and why they are not mocks
##
## THE IPC is a recorder installed at `desktop_electron.rendererIpc`, the seam
## the facade reads Electron's `ipcRenderer` through: what is under test is
## what the renderer SENDS and how it settles on what it RECEIVES. Main's side
## of these channels is `content_id_worker_test.nim`'s subject, over real git.
##
## THE SPAWN SEAM is node's `child_process` module object, whose launching
## functions (`spawn`, `spawnSync`, `execFile`, `execFileSync`, `exec`,
## `execSync`, `fork`) are wrapped with a counter that then calls the
## original. Counting at the module every renderer git read goes through is
## the only way to observe "no process was started" — a facade that spawned
## git would still settle, and its answer would look the same.
##
## Lane: `renderer-dom`, compiled as the renderer is (`nim js -d:ctRenderer`,
## browser target) and run by `jsdom-run.mjs`, which provides node's
## `require`. Without `-d:nodejs` `std/unittest` cannot set the exit status,
## so this suite sets it.

import std/[asyncjs, json, jsffi, strutils]

import ../viewmodel/platform/outcome
import ../viewmodel/platform/capabilities
import ../viewmodel/platform/vcs
import ../viewmodel/host/electron_profile
import ../viewmodel/host/main_process_wire
import ../viewmodel/host/desktop_electron

const ExpectedChecks = 12

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

# The spawn seam: every launching function of `child_process`, counted.
var spawned = 0
proc countSpawns(counter: proc()) {.importjs: """
  (function (counter) {
    var cp = require('child_process');
    ['spawn', 'spawnSync', 'execFile', 'execFileSync', 'exec', 'execSync',
     'fork'].forEach(function (name) {
      var original = cp[name];
      cp[name] = function () { counter(); return original.apply(this, arguments); };
    });
  })(#)""".}
countSpawns(proc() = inc spawned)

# The IPC recorder.
var sentMessages: seq[tuple[channel: string; payload: JsObject]] = @[]
var listeners: seq[tuple[channel: string; handler: proc(payload: JsObject)]] = @[]

desktop_electron.rendererIpc = RendererIpc(
  send: proc(channel: cstring; payload: JsObject) =
    sentMessages.add((channel: $channel, payload: payload)),
  listen: proc(channel: cstring; handler: proc(payload: JsObject)) =
    listeners.add((channel: $channel, handler: handler)))

proc deliver(channel: string; payload: JsObject) =
  for entry in listeners:
    if entry.channel == channel:
      entry.handler(payload)

proc sentOn(channel: string): seq[JsObject] =
  for entry in sentMessages:
    if entry.channel == channel:
      result.add entry.payload

type Watched[T] = ref object
  settled: bool
  outcome: PlatformOutcome[T]

proc watch[T](future: PlatformFuture[PlatformOutcome[T]]): Watched[T] =
  let w = Watched[T]()
  future.onComplete(
    proc(value: PlatformOutcome[T]) =
      w.settled = true
      w.outcome = value,
    proc(message: string) =
      w.settled = true
      w.outcome = failed[T](pkTransport, "rejected", message))
  drainPlatformCallbacks()
  w

proc turn(): Future[void] {.importjs:
  "new Promise(function (resolve) { setTimeout(resolve, 0); })".}

proc runCases() {.async.} =
  let profile = electronDesktopProfile(false)
  let facade = electronVcs(profile)
  let repo = "/repositories/example"

  echo "[Suite] content ids and declared scopes are asked of the main process"
  block:
    let pending = watch(facade.contentId(repo, vbsIndex, "git-tree-sha256",
                                         @["src", "docs/a.md"]))
    let sent = sentOn(ContentIdChannel)
    ck sent.len == 1, "contentId sends one " & ContentIdChannel & " request"
    # Guarded, so a facade that sent nothing reports every check below
    # rather than stopping at the first index.
    let request = if sent.len > 0: decodeRequest(parseJson(
                    $sent[0][cstring"request"].to(cstring)))
                  else: ContentIdRequest()
    ck request.op == OpContentId and request.repository == repo and
       request.state == vbsIndex and request.algorithm == "git-tree-sha256" and
       request.scope == @["src", "docs/a.md"],
       "the request names the repository, S, the algorithm and the scope"
    await turn()
    ck not pending.settled, "the future waits for main's answer"
    let id = if sent.len > 0: sent[0][cstring"id"].to(int) else: -1
    deliver(ContentIdReceivedChannel, JsObject{id: id + 1000,
      outcome: cstring(encodeContentIdOutcome(succeeded(VcsContentId(
        kind: vcikComputed, id: "git-tree-sha256:" & repeat("1", 64),
        algorithm: "git-tree-sha256"))))})
    ck not pending.settled, "an answer for another request does not settle it"
    let answer = VcsContentId(kind: vcikComputed,
      id: "git-tree-sha256:" & repeat("a", 64), algorithm: "git-tree-sha256")
    deliver(ContentIdReceivedChannel, JsObject{id: id,
      outcome: cstring(encodeContentIdOutcome(succeeded(answer)))})
    await turn()
    ck pending.settled and pending.outcome.ok and
       pending.outcome.value.id == answer.id,
       "the answer for its id settles it with main's id"

  block:
    let pending = watch(facade.contentId(repo, vbsWorkingTree, "git-tree-sha1", @[]))
    let sent = sentOn(ContentIdChannel)
    deliver(ContentIdReceivedChannel, JsObject{
      id: (if sent.len > 0: sent[^1][cstring"id"].to(int) else: -1),
      outcome: cstring(encodeContentIdOutcome(failed[VcsContentId](pkFailed,
        "git status failed", "not a git repository")))})
    await turn()
    ck pending.settled and not pending.outcome.ok and
       pending.outcome.error.kind == pkFailed and
       pending.outcome.error.detail == "not a git repository",
       "a failure main reports arrives as that failure"

  block:
    let pending = watch(facade.declaredScopes(repo))
    let sent = sentOn(DeclaredScopesChannel)
    ck sent.len == 1, "declaredScopes sends one " & DeclaredScopesChannel & " request"
    ck sent.len > 0 and decodeRequest(parseJson(
         $sent[0][cstring"request"].to(cstring))).op == OpDeclaredScopes,
       "the request is a declared-scopes read"
    await turn()
    ck not pending.settled, "the future waits for main's answer"
    deliver(DeclaredScopesReceivedChannel, JsObject{
      id: (if sent.len > 0: sent[0][cstring"id"].to(int) else: -1),
      outcome: cstring(encodeDeclaredScopesOutcome(succeeded(VcsDeclaredScopes(
        scopes: @[@["src"]]))))})
    await turn()
    ck pending.settled and pending.outcome.ok and
       pending.outcome.value.scopes == @[@["src"]],
       "the answer settles it with main's scopes"

  ck spawned == 0, "no child process was started in the renderer (" &
     $spawned & " started)"

  block:
    var refused = profile
    refused.capabilities.excl capVcsRead
    let before = sentMessages.len
    let pending = watch(electronVcs(refused).contentId(repo, vbsHead,
                                                       "git-tree-sha1", @[]))
    ck pending.settled and not pending.outcome.ok and
       pending.outcome.error.kind == pkNotSupported and
       sentMessages.len == before,
       "a profile without capVcsRead is refused without a request"

proc main() {.async.} =
  try:
    await runCases()
  except:
    inc failedChecks
    echo "  [FAILED] the suite itself raised: ", getCurrentExceptionMsg()
  echo "CHECKS: ", checks, " FAILED: ", failedChecks
  if checks != ExpectedChecks:
    echo "  [FAILED] expected ", ExpectedChecks, " checks, ran ", checks
  exitProcess(if failedChecks == 0 and checks == ExpectedChecks: 0 else: 1)

discard main()
