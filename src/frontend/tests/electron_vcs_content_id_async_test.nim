## electron_vcs_content_id_async_test.nim
##
## THE ELECTRON RENDERER'S CONTENT IDS DO NOT BLOCK ITS MAIN THREAD.
##
## The status bar's test-certificate indicator asks the Electron
## instantiation's `vcs.contentId` for W, H and S, and `vcs.repositoryRoot` for
## the repository, on every refresh. Both used to run git through node's
## `spawnSync` / `execFileSync`, so each refresh froze the renderer — input and
## redraw — for the whole git round trip: 170 ms to 1.2 s per revalidation
## (codetracer-pm issue
## `2026-10-21-certificate-indicator-runs-git-synchronously-on-the-renderer-main-thread`).
## Status-Bar.md, "A refresh never stalls the window": the git processes are
## launched asynchronously and the indicator updates when the computation
## completes.
##
## ## The claims
##
##   1. **Neither call settles synchronously.** The future each returns is
##      still pending after `drainPlatformCallbacks()`, which is exactly the
##      drain `awaitSync` relies on — so a caller that had not been converted
##      would see it, and so would this suite. Against `spawnSync` the future
##      is a `newCompletedFuture`, settled before the call returns.
##   2. **The event loop runs while git does.** A `setImmediate` scheduled
##      right after the call runs before the future settles, and an interval
##      timer keeps ticking while it is pending. Against `spawnSync` the
##      interval cannot tick at all: the thread is inside the call.
##   3. **The answers are the synchronous recipe's.** Every state the
##      indicator meets — W, H and S, a scoped id, `git-tree-sha256` in a SHA-1
##      repository (cannot compute), `manifest-v1-sha256` over a BINARY blob
##      (byte-exact Buffer conversion: a UTF-8 decode changes the digest), an
##      assume-unchanged entry (no content id, paths named), a directory
##      outside any repository (a failure) and git missing from `PATH`
##      (cannot compute) — is compared with `contentIdOver(nodeContentIdHost(),
##      ...)`, the same recipe through `spawnSync`.
##   4. **Nothing the user owns moved.** The repository's index is
##      byte-identical afterwards, and no `ct-content-id-*` directory is left
##      under the host's temporary root.
##
## ## Why `electronVcs` is called directly
##
## `newDesktopElectronPlatform` checks `require('electron')` and, under plain
## node, falls back to the web profile — the right behaviour for a browser tab,
## and the reason this lane cannot reach the Electron instantiation through
## it. `electronVcs` is exported for this suite; it is the facade the shipped
## window installs, with nothing replaced.
##
## ## What is real, and the one stand-in
##
## REAL: `git` itself over repositories this suite creates; node's
## `child_process.spawn`; the content-id recipe; the facade.
##
## THE ONE STAND-IN is a `git` wrapper script used by claim 2 only: a
## `/bin/sh` script that sleeps 0.2 s and then `exec`s the real git with the
## same arguments. A git that answers in two milliseconds makes "the event
## loop ran while git was running" a race between the loop and the child; a
## git that takes a fifth of a second per call makes it a certainty, without
## changing a byte of what git does or answers.
##
## Every path is under one `mkdtemp` directory, git's global and system
## configuration are pointed at a file that does not exist, and the
## directory is removed at the end.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, run under
## node.

import std/[asyncjs, jsffi, strutils]

import ../viewmodel/platform/outcome
import ../viewmodel/platform/vcs
import ../viewmodel/host/electron_profile
import ../viewmodel/host/node_certificate_host
import ../viewmodel/host/desktop_electron

var checks = 0
var failedChecks = 0

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

proc exitProcess(code: int) {.importjs: "process.exit(#)".}

# ---------------------------------------------------------------------------
# node, for the suite's own setup
# ---------------------------------------------------------------------------

proc nodeRequire(module: cstring): JsObject {.importjs: "require(#)".}
proc setEnv(name, value: cstring) {.importjs: "process.env[#] = #".}
proc getEnv(name: cstring): cstring {.importjs: "(process.env[#] || '')".}
proc setImmediate(callback: proc()) {.importjs: "setImmediate(#)".}
proc setInterval(callback: proc(); ms: int): JsObject {.importjs: "setInterval(#, #)".}
proc clearInterval(handle: JsObject) {.importjs: "clearInterval(#)".}
proc execGitRaw(args: seq[cstring]; cwd: cstring): cstring
  {.importjs: "require('child_process').execFileSync('git', #, {cwd: #, encoding: 'utf8'})".}
proc writeBinary(path: cstring)
  {.importjs: """(function(p) {
    var bytes = [];
    for (var i = 0; i < 256; i++) bytes.push(i);
    // Invalid UTF-8 on purpose: a lone continuation byte, an overlong form
    // and a truncated sequence. A decoder would replace each with U+FFFD.
    bytes.push(0x80, 0xc0, 0xaf, 0xe2, 0x82, 0x00, 0xff, 0xfe);
    require('fs').writeFileSync(p, Buffer.from(bytes));
  })(#)""".}
proc indexBytes(path: cstring): cstring
  {.importjs: "(function(p) { return require('fs').existsSync(p) ? require('fs').readFileSync(p).toString('base64') : '<no index>'; })(#)".}

let nodeFs = nodeRequire("fs")
let nodeOs = nodeRequire("os")

let workspace = $(nodeFs.mkdtempSync(
  cstring($(nodeOs.tmpdir().to(cstring)) & "/ct-electron-content-id-")).to(cstring))

# A git that sees only this suite's repositories: no developer configuration
# (an `autocrlf`, a default object format, commit signing) and no search
# upwards past the workspace into whatever repository /tmp sits in.
setEnv(cstring"GIT_CONFIG_GLOBAL", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_SYSTEM", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")
setEnv(cstring"GIT_CEILING_DIRECTORIES", cstring(workspace))
for role in ["AUTHOR", "COMMITTER"]:
  setEnv(cstring("GIT_" & role & "_NAME"), cstring"Electron Content Id Test")
  setEnv(cstring("GIT_" & role & "_EMAIL"), cstring"content-id@test.invalid")

# Both hosts make their temporary indexes under `os.tmpdir()`, which reads
# TMPDIR on every call. Pointing it at a directory of the suite's own is what
# lets claim 4 say "nothing was left behind" rather than "nothing we can see".
let hostTemp = workspace & "/host-tmp"
discard nodeFs.mkdirSync(cstring(hostTemp))
setEnv(cstring"TMPDIR", cstring(hostTemp))

proc git(cwd: string; args: varargs[string]): string =
  var jsArgs: seq[cstring] = @[]
  for a in args: jsArgs.add cstring(a)
  result = $execGitRaw(jsArgs, cstring(cwd))
  result.stripLineEnd()

proc writeText(path, text: string) =
  discard nodeFs.writeFileSync(cstring(path), cstring(text))

proc makeDir(path: string) =
  discard nodeFs.mkdirSync(cstring(path), js{recursive: true})

proc leftovers(): seq[string] =
  for name in nodeFs.readdirSync(cstring(hostTemp)).to(seq[cstring]):
    if ($name).startsWith("ct-content-id-"):
      result.add $name

# ---------------------------------------------------------------------------
# Observing a facade future
# ---------------------------------------------------------------------------

type
  Observed[T] = ref object
    settledInline: bool
      ## Settled before `observe` returned control: during the call itself
      ## or in the `drainPlatformCallbacks()` right after it.
    immediateFirst: bool
      ## The `setImmediate` scheduled right after the call ran before the
      ## future settled.
    ticks: int
      ## Interval ticks while the future was pending.
    outcome: PlatformOutcome[T]
    resolve: proc(value: Observed[T])

proc observe[T](future: PlatformFuture[PlatformOutcome[T]]): Future[Observed[T]] =
  ## Watch `future` settle and record what the event loop did meanwhile.
  let obs = Observed[T]()
  var settled = false
  var immediateRan = false
  var timer: JsObject = nil
  proc finish(outcome: PlatformOutcome[T]) =
    if settled: return
    settled = true
    obs.outcome = outcome
    obs.immediateFirst = immediateRan
    if not timer.isNil: clearInterval(timer)
    if not obs.resolve.isNil: obs.resolve(obs)
  future.onComplete(
    proc(value: PlatformOutcome[T]) = finish(value),
    proc(message: string) =
      finish(failed[T](pkTransport, "the future rejected", message)))
  drainPlatformCallbacks()
  obs.settledInline = settled
  if settled:
    return newPromise(proc(resolve: proc(value: Observed[T])) = resolve(obs))
  setImmediate(proc() = immediateRan = true)
  timer = setInterval(proc() = (inc obs.ticks), 5)
  newPromise(proc(resolve: proc(value: Observed[T])) = obs.resolve = resolve)

proc sameAnswer(a, b: PlatformOutcome[VcsContentId]): bool =
  ## Field by field, so a difference names itself in the echo below.
  if a.ok != b.ok: return false
  if not a.ok:
    return a.error.kind == b.error.kind and a.error.message == b.error.message
  if a.value.kind != b.value.kind or a.value.id != b.value.id or
     a.value.algorithm != b.value.algorithm or a.value.reason != b.value.reason or
     a.value.conditions.len != b.value.conditions.len:
    return false
  for i in 0 ..< a.value.conditions.len:
    if a.value.conditions[i].condition != b.value.conditions[i].condition or
       a.value.conditions[i].paths != b.value.conditions[i].paths:
      return false
  true

proc describe(o: PlatformOutcome[VcsContentId]): string =
  if not o.ok: return "error " & $o.error
  $o.value.kind & " " & o.value.id & " " & o.value.reason

let profile = electronDesktopProfile(false)
let facade = electronVcs(profile)
let syncHost = nodeContentIdHost()

proc expectedOf(repository: string; state: VcsBlobSource; algorithm: string;
                scope: seq[string]): PlatformOutcome[VcsContentId] =
  ## The synchronous recipe through `spawnSync` — what the facade answered
  ## before this change, and what it must still answer.
  contentIdOver(syncHost, profile, repository, state, algorithm, scope)

proc checkContentId(label, repository: string; state: VcsBlobSource;
                    algorithm: string; scope: seq[string] = @[];
                    expectKind = vcikComputed; expectOk = true): Future[void] {.async.} =
  let obs = await observe(facade.contentId(repository, state, algorithm, scope))
  ck not obs.settledInline, label & ": the future is not settled synchronously"
  ck obs.immediateFirst, label & ": a setImmediate scheduled after the call runs first"
  let expected = expectedOf(repository, state, algorithm, scope)
  if not sameAnswer(obs.outcome, expected):
    echo "    async: ", describe(obs.outcome)
    echo "    sync:  ", describe(expected)
  ck sameAnswer(obs.outcome, expected), label & ": the answer is the synchronous recipe's"
  ck obs.outcome.ok == expectOk, label & ": ok is " & $expectOk
  if expectOk:
    ck obs.outcome.value.kind == expectKind, label & ": the kind is " & $expectKind

proc runCases() {.async.} =
  echo "[Suite] the Electron instantiation's content ids run off the main thread"

  # A SHA-1 repository whose three states differ: a committed tree, a staged
  # change to `src/b.nim`, an unstaged edit to `a.txt`, and a binary blob.
  let repo = workspace & "/repo"
  makeDir(repo & "/src")
  discard git(repo, "init", "-q", "--object-format=sha1", ".")
  writeText(repo & "/a.txt", "alpha\n")
  writeText(repo & "/src/b.nim", "echo 1\n")
  writeBinary(cstring(repo & "/blob.bin"))
  discard git(repo, "add", "-A")
  discard git(repo, "commit", "-q", "-m", "initial")
  writeText(repo & "/src/b.nim", "echo 2\n")
  discard git(repo, "add", "src/b.nim")
  writeText(repo & "/a.txt", "alpha, edited\n")
  let indexBefore = $indexBytes(cstring(repo & "/.git/index"))

  await checkContentId("W", repo, vbsWorkingTree, "git-tree-sha1")
  await checkContentId("H", repo, vbsHead, "git-tree-sha1")
  await checkContentId("S", repo, vbsIndex, "git-tree-sha1")
  await checkContentId("W scoped to src", repo, vbsWorkingTree, "git-tree-sha1", @["src"])
  await checkContentId("W from a subdirectory", repo & "/src", vbsWorkingTree, "git-tree-sha1")
  await checkContentId("git-tree-sha256 in a SHA-1 repository", repo, vbsWorkingTree,
                       "git-tree-sha256", expectKind = vcikCannotCompute)
  await checkContentId("manifest-v1-sha256 of H, binary blob", repo, vbsHead,
                       "manifest-v1-sha256")
  await checkContentId("manifest-v1-sha256 of W, binary blob", repo, vbsWorkingTree,
                       "manifest-v1-sha256")

  # The three states really are three, so the comparisons above compared
  # three different computations rather than one three times.
  let w = expectedOf(repo, vbsWorkingTree, "git-tree-sha1", @[])
  let h = expectedOf(repo, vbsHead, "git-tree-sha1", @[])
  let s = expectedOf(repo, vbsIndex, "git-tree-sha1", @[])
  ck w.ok and h.ok and s.ok and w.value.id != h.value.id and
     s.value.id != h.value.id and w.value.id != s.value.id,
     "control: W, H and S are three different ids"
  ck h.value.id == "git-tree-sha1:" & git(repo, "rev-parse", "HEAD^{tree}"),
     "control: H is git's own HEAD^{tree}"

  ck $indexBytes(cstring(repo & "/.git/index")) == indexBefore,
     "the user's index is byte-identical afterwards"

  # An assume-unchanged entry: no content id, and the path named.
  let assumed = workspace & "/assumed"
  makeDir(assumed)
  discard git(assumed, "init", "-q", ".")
  writeText(assumed & "/hidden.txt", "one\n")
  discard git(assumed, "add", "-A")
  discard git(assumed, "commit", "-q", "-m", "initial")
  discard git(assumed, "update-index", "--assume-unchanged", "hidden.txt")
  writeText(assumed & "/hidden.txt", "two\n")
  await checkContentId("an assume-unchanged entry", assumed, vbsWorkingTree,
                       "git-tree-sha1", expectKind = vcikNoContentId)
  let noId = expectedOf(assumed, vbsWorkingTree, "git-tree-sha1", @[])
  ck noId.ok and noId.value.conditions.len == 1 and
     noId.value.conditions[0].paths == @["hidden.txt"],
     "the assume-unchanged path is named"

  # Outside any repository: a failure, never an id.
  let outside = workspace & "/not-a-repository"
  makeDir(outside)
  await checkContentId("a directory outside any repository", outside,
                       vbsWorkingTree, "git-tree-sha1", expectOk = false)

  # The repository root, asynchronously too.
  block:
    let obs = await observe(facade.repositoryRoot(repo & "/src"))
    ck not obs.settledInline, "repositoryRoot: the future is not settled synchronously"
    ck obs.immediateFirst, "repositoryRoot: a setImmediate scheduled after the call runs first"
    ck obs.outcome.ok and obs.outcome.value == git(repo, "rev-parse", "--show-toplevel"),
       "repositoryRoot: the top level git names"
    let missing = await observe(facade.repositoryRoot(outside))
    ck not missing.settledInline, "repositoryRoot outside a repository: not settled synchronously"
    ck not missing.outcome.ok and missing.outcome.error.kind == pkFailed,
       "repositoryRoot outside a repository: a pkFailed outcome"

  # git missing from PATH: content ids cannot be computed (Content-Id §5's
  # unverifiable), and the root is a failure. The two hosts word node's
  # launch error differently (`spawnSync git ENOENT` / `spawn git ENOENT`),
  # so the kind and the reason's opening are compared, not the whole text.
  block:
    let savedPath = $getEnv(cstring"PATH")
    let emptyBin = workspace & "/empty-bin"
    makeDir(emptyBin)
    setEnv(cstring"PATH", cstring(emptyBin))
    let obs = await observe(facade.contentId(repo, vbsWorkingTree, "git-tree-sha1", @[]))
    let expected = expectedOf(repo, vbsWorkingTree, "git-tree-sha1", @[])
    let rootObs = await observe(facade.repositoryRoot(repo))
    setEnv(cstring"PATH", cstring(savedPath))
    ck not obs.settledInline, "git missing: the future is not settled synchronously"
    ck obs.outcome.ok and obs.outcome.value.kind == vcikCannotCompute,
       "git missing: the content id cannot be computed"
    ck expected.ok and expected.value.kind == vcikCannotCompute,
       "git missing: the synchronous recipe agrees"
    ck obs.outcome.ok and obs.outcome.value.reason.startsWith("git cannot be run on this host") and
       "ENOENT" in obs.outcome.value.reason,
       "git missing: the reason says git cannot be run, and why"
    ck not rootObs.outcome.ok and rootObs.outcome.error.kind == pkFailed,
       "git missing: repositoryRoot is a pkFailed outcome"

  # Claim 2, made certain: a git that takes 0.2 s per call. The interval
  # ticks every 5 ms while the computation is in flight; against spawnSync
  # it cannot tick once.
  block:
    let realGit = git(repo, "--exec-path") # proves git still runs here
    discard realGit
    let gitPath = block:
      let which = nodeRequire("child_process").execFileSync(
        cstring"/bin/sh", @[cstring"-c", cstring"command -v git"],
        js{encoding: cstring"utf8"}).to(cstring)
      ($which).strip()
    let slowBin = workspace & "/slow-bin"
    makeDir(slowBin)
    writeText(slowBin & "/git", "#!/bin/sh\nsleep 0.2\nexec '" & gitPath & "' \"$@\"\n")
    discard nodeFs.chmodSync(cstring(slowBin & "/git"), 0o755)
    let savedPath = $getEnv(cstring"PATH")
    setEnv(cstring"PATH", cstring(slowBin & ":" & savedPath))
    let obs = await observe(facade.contentId(repo, vbsWorkingTree, "git-tree-sha1", @[]))
    let rootObs = await observe(facade.repositoryRoot(repo))
    setEnv(cstring"PATH", cstring(savedPath))
    ck not obs.settledInline and obs.ticks >= 10,
       "a slow git: the event loop ticked while W was computed (" & $obs.ticks & " ticks)"
    ck sameAnswer(obs.outcome, w), "a slow git: W is still the synchronous recipe's"
    ck not rootObs.settledInline and rootObs.ticks >= 5,
       "a slow git: the event loop ticked while the root was resolved (" &
       $rootObs.ticks & " ticks)"

  # Output past the capture bound: the asynchronous runner kills the child
  # and marks the reply incomplete, which the recipe must report as a failure
  # — never digest a prefix — exactly as `spawnSync`'s ENOBUFS does. The
  # bound (64 KiB) is passed by one command only: `git cat-file` of a 256 KiB
  # blob while `manifest-v1-sha256` reads it. (A bound so small that the
  # facade's `git --version` probe overflows too is not a case either runner
  # can answer deterministically: whether a child killed past the bound
  # reports its exit status is a race in `spawnSync` as in `spawn`.)
  block:
    let big = workspace & "/big"
    makeDir(big)
    discard git(big, "init", "-q", ".")
    writeText(big & "/big.txt", repeat("0123456789abcdef", 16384))
    discard git(big, "add", "-A")
    discard git(big, "commit", "-q", "-m", "big")
    let tinyAsync = nodeAsyncContentIdHost(captureLimit = 65536)
    let tinySync = nodeContentIdHost(captureLimit = 65536)
    let obs = await observe(contentIdOverAsync(tinyAsync, profile, big,
                                               vbsHead, "manifest-v1-sha256", @[]))
    let expected = contentIdOver(tinySync, profile, big, vbsHead,
                                 "manifest-v1-sha256", @[])
    ck not obs.settledInline, "past the capture bound: not settled synchronously"
    if not sameAnswer(obs.outcome, expected):
      echo "    async: ", describe(obs.outcome)
      echo "    sync:  ", describe(expected)
    ck sameAnswer(obs.outcome, expected),
       "past the capture bound: the synchronous recipe's answer"
    ck not obs.outcome.ok and
       "more output than could be captured" in obs.outcome.error.message,
       "past the capture bound: a failure that says the output was cut"

  ck $indexBytes(cstring(repo & "/.git/index")) == indexBefore,
     "the user's index is still byte-identical at the end"
  ck leftovers().len == 0,
     "no ct-content-id-* directory is left under the host's temporary root"

const ExpectedChecks = 71

proc main() {.async.} =
  try:
    await runCases()
  except:
    inc failedChecks
    echo "  [FAILED] the suite itself raised: ", getCurrentExceptionMsg()
  try:
    discard nodeFs.rmSync(cstring(workspace), js{recursive: true, force: true})
  except:
    discard
  echo "CHECKS: ", checks, " FAILED: ", failedChecks
  if checks != ExpectedChecks:
    echo "  [FAILED] expected ", ExpectedChecks, " checks, ran ", checks
  exitProcess(if failedChecks == 0 and checks == ExpectedChecks: 0 else: 1)

discard main()
