## electron_vcs_refresh_async_test.nim
##
## THE ELECTRON RENDERER'S STATUS AND LOG READS DO NOT BLOCK ITS MAIN THREAD.
##
## The VCS pane decides whether anything changed — every 5 s and on window
## focus — by reading the working tree's status and the recent commit ids.
## Both reads ran git through node's `execFileSync`, so every tick froze the
## renderer — input, hover styles and redraw — for 150-185 ms (codetracer-pm
## issue
## `2026-10-21-vcs-auto-refresh-runs-git-synchronously-on-the-renderer-main-thread`).
## VCS-Panel.md, "Normal Development Mode", "An auto-refresh never stalls the
## window": the two git processes are launched asynchronously and the panel
## applies the result when both have answered. The pane reads them through
## the Electron instantiation's `vcs.status` and `vcs.log`, which this suite
## drives.
##
## ## The claims
##
##   1. **Neither call settles synchronously.** The future each returns is
##      still pending after `drainPlatformCallbacks()` — the drain
##      `ctAwaitSync` relies on — and a `setImmediate` scheduled right after
##      the call runs before it settles. Against `execFileSync` the future is
##      a `newCompletedFuture`, settled before the call returns.
##   2. **The event loop runs while git does.** With a git that takes 0.2 s
##      per call, an interval timer keeps ticking while each future is
##      pending. Against `execFileSync` it cannot tick at all: the thread is
##      inside the call.
##   3. **The answers are the ones the pane needs.** Every state the refresh
##      meets — a clean tree, a modified file, an untracked file, a staged
##      addition and modification, a path with spaces, an unmerged (conflicted)
##      path, a detached HEAD, a repository with no commits, a directory
##      outside any repository (a failure) and git missing from `PATH` (a
##      failure) — is compared field by field with what git itself reports,
##      read synchronously by this suite through `execFileSync` and the shared
##      `parsePorcelainV2` reader, and with facts stated independently of
##      either (the file's expected state letters, `git rev-list`'s ids).
##   4. **Nothing the user owns moved.** A `status` over a repository with a
##      stale stat cache leaves the index's inode alone and no `index.lock`
##      behind (VCS-Panel.md, "Reading the repository never takes the index
##      lock"); a plain `git status` over the same repository is the control
##      that proves the cache was stale.
##
## ## Why `electronVcs` is called directly
##
## `newDesktopElectronPlatform` checks `require('electron')` and, under plain
## node, falls back to the web profile — the right behaviour for a browser
## tab, and the reason this lane cannot reach the Electron instantiation
## through it. `electronVcs` is exported for these suites; it is the facade
## the shipped window installs, with nothing replaced.
##
## ## What is real, and the one stand-in
##
## REAL: `git` itself over repositories this suite creates; node's
## `child_process.spawn`; the facade.
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
proc spawnGitStatus(args: seq[cstring]; cwd: cstring): int
  {.importjs: "(require('child_process').spawnSync('git', #, {cwd: #}).status)".}

let nodeFs = nodeRequire("fs")
let nodeOs = nodeRequire("os")

let workspace = $(nodeFs.mkdtempSync(
  cstring($(nodeOs.tmpdir().to(cstring)) & "/ct-electron-vcs-refresh-")).to(cstring))

# A git that sees only this suite's repositories: no developer configuration
# and no search upwards past the workspace into whatever repository /tmp
# sits in.
setEnv(cstring"GIT_CONFIG_GLOBAL", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_SYSTEM", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")
setEnv(cstring"GIT_CEILING_DIRECTORIES", cstring(workspace))
for role in ["AUTHOR", "COMMITTER"]:
  setEnv(cstring("GIT_" & role & "_NAME"), cstring"Electron Vcs Refresh Test")
  setEnv(cstring("GIT_" & role & "_EMAIL"), cstring"vcs-refresh@test.invalid")

proc git(cwd: string; args: varargs[string]): string =
  var jsArgs: seq[cstring] = @[]
  for a in args: jsArgs.add cstring(a)
  result = $execGitRaw(jsArgs, cstring(cwd))
  result.stripLineEnd()

proc gitMayFail(cwd: string; args: varargs[string]): int =
  ## For the one command that is SUPPOSED to fail here — a conflicting merge.
  var jsArgs: seq[cstring] = @[]
  for a in args: jsArgs.add cstring(a)
  spawnGitStatus(jsArgs, cstring(cwd))

proc writeText(path, text: string) =
  discard nodeFs.writeFileSync(cstring(path), cstring(text))

proc makeDir(path: string) =
  discard nodeFs.mkdirSync(cstring(path), js{recursive: true})

proc newRepository(name: string): string =
  result = workspace & "/" & name
  makeDir(result)
  discard git(result, "-c", "init.defaultBranch=main", "init", "-q", ".")

proc commitAll(repo, subject: string) =
  discard git(repo, "add", "-A")
  discard git(repo, "commit", "-q", "-m", subject)

proc gitStatusNow(repo: string): VcsStatus =
  ## What git reports right now, read the way the pane's synchronous path
  ## read it — `execFileSync` — through the one shared porcelain-v2 reader.
  parsePorcelainV2(git(repo, "--no-optional-locks", "status",
                       "--porcelain=v2", "--branch"))

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

proc sameStatus(a, b: VcsStatus): bool =
  if a.branch != b.branch or a.upstream != b.upstream or
     a.detached != b.detached or a.ahead != b.ahead or a.behind != b.behind or
     a.changes.len != b.changes.len:
    return false
  for i in 0 ..< a.changes.len:
    if a.changes[i] != b.changes[i]:
      return false
  true

proc describe(s: VcsStatus): string =
  result = "branch=" & s.branch & " detached=" & $s.detached
  for c in s.changes:
    result.add " [" & c.path & " " & $c.indexStatus & "/" & $c.workingTreeStatus & "]"

proc changeOf(s: VcsStatus; path: string): VcsFileChange =
  for c in s.changes:
    if c.path == path: return c
  VcsFileChange(path: "<absent>")

let profile = electronDesktopProfile(false)
let facade = electronVcs(profile)

proc checkStatus(label, repo: string): Future[VcsStatus] {.async.} =
  ## Claims 1 and 3 for one `status`: not settled synchronously, the loop
  ## ran first, and the answer is git's own. Returns the answer, for the
  ## caller's independent facts.
  let obs = await observe(facade.status(repo))
  ck not obs.settledInline, label & ": status is not settled synchronously"
  ck obs.immediateFirst, label & ": a setImmediate scheduled after status runs first"
  ck obs.outcome.ok, label & ": status succeeds"
  let expected = gitStatusNow(repo)
  if obs.outcome.ok and not sameStatus(obs.outcome.value, expected):
    echo "    async: ", describe(obs.outcome.value)
    echo "    git:   ", describe(expected)
  ck obs.outcome.ok and sameStatus(obs.outcome.value, expected),
     label & ": status is what git reports"
  result = if obs.outcome.ok: obs.outcome.value else: VcsStatus()

proc checkFailure[T](label: string; future: PlatformFuture[PlatformOutcome[T]];
                     detailHas: string): Future[void] {.async.} =
  let obs = await observe(future)
  ck not obs.settledInline, label & ": not settled synchronously"
  ck not obs.outcome.ok and obs.outcome.error.kind == pkFailed,
     label & ": a pkFailed outcome"
  if not obs.outcome.ok and detailHas notin obs.outcome.error.detail:
    echo "    error: ", $obs.outcome.error
  ck not obs.outcome.ok and detailHas in obs.outcome.error.detail,
     label & ": git's diagnostic (" & detailHas & ") is carried"

proc runCases() {.async.} =
  echo "[Suite] the Electron instantiation's status and log run off the main thread"

  # -- status, over each working-tree state the refresh meets ---------------
  let repo = newRepository("repo")
  writeText(repo & "/a.txt", "alpha\n")
  writeText(repo & "/b.txt", "beta\n")
  commitAll(repo, "first")

  block:
    let s = await checkStatus("clean", repo)
    ck s.branch == "main" and not s.detached and s.changes.len == 0,
       "clean: branch main, attached, no changes"

  writeText(repo & "/a.txt", "alpha, edited\n")
  block:
    let s = await checkStatus("modified", repo)
    let c = s.changeOf("a.txt")
    ck c.indexStatus == vfsUnmodified and c.workingTreeStatus == vfsModified,
       "modified: a.txt is .M"

  writeText(repo & "/new file.txt", "spaced\n")
  block:
    let s = await checkStatus("untracked, with a space in its name", repo)
    ck s.changeOf("new file.txt").workingTreeStatus == vfsUntracked,
       "untracked: `new file.txt` is ?, its whole name kept"

  discard git(repo, "add", "new file.txt", "a.txt")
  writeText(repo & "/b.txt", "beta, edited\n")
  block:
    let s = await checkStatus("staged", repo)
    ck s.changeOf("new file.txt").indexStatus == vfsAdded,
       "staged: `new file.txt` is A. (the path with a space read whole)"
    ck s.changeOf("a.txt").indexStatus == vfsModified,
       "staged: a.txt is M."
    ck s.changeOf("b.txt").workingTreeStatus == vfsModified,
       "staged: b.txt is still .M"
  commitAll(repo, "second")

  # An unmerged path: both branches change the same line of c.txt.
  let conflict = newRepository("conflict")
  writeText(conflict & "/c.txt", "base\n")
  commitAll(conflict, "base")
  discard git(conflict, "checkout", "-q", "-b", "other")
  writeText(conflict & "/c.txt", "other side\n")
  commitAll(conflict, "other")
  discard git(conflict, "checkout", "-q", "main")
  writeText(conflict & "/c.txt", "main side\n")
  commitAll(conflict, "main")
  ck gitMayFail(conflict, "merge", "-q", "other") != 0,
     "control: the merge stops on a conflict"
  block:
    let s = await checkStatus("conflicted", conflict)
    let c = s.changeOf("c.txt")
    ck c.indexStatus == vfsConflicted and c.workingTreeStatus == vfsConflicted,
       "conflicted: c.txt is reported, as conflicted on both sides"

  # A detached HEAD.
  let detached = newRepository("detached")
  writeText(detached & "/d.txt", "one\n")
  commitAll(detached, "one")
  writeText(detached & "/d.txt", "two\n")
  commitAll(detached, "two")
  discard git(detached, "checkout", "-q", "--detach", "HEAD~1")
  block:
    let s = await checkStatus("detached", detached)
    ck s.detached, "detached: reported as detached"

  # A repository with no commits yet: status answers, log fails.
  let unborn = newRepository("unborn")
  writeText(unborn & "/u.txt", "u\n")
  block:
    let s = await checkStatus("no commits yet", unborn)
    ck s.branch == "main" and s.changeOf("u.txt").workingTreeStatus == vfsUntracked,
       "no commits yet: branch main, u.txt untracked"
  await checkFailure("log with no commits yet",
                     facade.log(unborn, 30, ""), "does not have any commits")

  # -- log --------------------------------------------------------------
  block:
    let obs = await observe(facade.log(repo, 30, ""))
    ck not obs.settledInline, "log: not settled synchronously"
    ck obs.immediateFirst, "log: a setImmediate scheduled after log runs first"
    let ids = git(repo, "rev-list", "--max-count=30", "HEAD").splitLines()
    var got: seq[string] = @[]
    if obs.outcome.ok:
      for c in obs.outcome.value: got.add c.id
    ck obs.outcome.ok and got == ids, "log: the ids are git rev-list's, newest first"
    ck obs.outcome.ok and obs.outcome.value.len == 2 and
       obs.outcome.value[0].subject == "second" and
       obs.outcome.value[1].subject == "first" and
       obs.outcome.value[0].parents == @[obs.outcome.value[1].id] and
       obs.outcome.value[1].parents.len == 0 and
       obs.outcome.value[0].shortId.len > 0 and
       obs.outcome.value[0].id.startsWith(obs.outcome.value[0].shortId) and
       obs.outcome.value[0].authorName == "Electron Vcs Refresh Test" and
       obs.outcome.value[0].authorEmail == "vcs-refresh@test.invalid" and
       obs.outcome.value[0].authoredAtMs ==
         parseBiggestInt(git(repo, "log", "-1", "--format=%at")) * 1000,
       "log: subjects, parents, short ids, author and time as committed"
  block:
    let obs = await observe(facade.log(repo, 1, ""))
    ck obs.outcome.ok and obs.outcome.value.len == 1 and
       obs.outcome.value[0].subject == "second",
       "log: maxCount bounds the answer"
    let scoped = await observe(facade.log(repo, 30, "b.txt"))
    ck scoped.outcome.ok and scoped.outcome.value.len == 2,
       "log: a path scope is passed to git (b.txt is in both commits)"
    let none = await observe(facade.log(repo, 30, "never-existed.txt"))
    ck none.outcome.ok and none.outcome.value.len == 0,
       "log: a path no commit touched answers no commits"

  # -- failures ---------------------------------------------------------
  let outside = workspace & "/not-a-repository"
  makeDir(outside)
  await checkFailure("status outside a repository", facade.status(outside),
                     "not a git repository")
  await checkFailure("log outside a repository", facade.log(outside, 30, ""),
                     "not a git repository")
  block:
    let savedPath = $getEnv(cstring"PATH")
    let emptyBin = workspace & "/empty-bin"
    makeDir(emptyBin)
    setEnv(cstring"PATH", cstring(emptyBin))
    let statusObs = await observe(facade.status(repo))
    let logObs = await observe(facade.log(repo, 30, ""))
    setEnv(cstring"PATH", cstring(savedPath))
    ck not statusObs.outcome.ok and statusObs.outcome.error.kind == pkFailed and
       "ENOENT" in statusObs.outcome.error.detail,
       "git missing: status is a pkFailed outcome naming ENOENT"
    ck not logObs.outcome.ok and logObs.outcome.error.kind == pkFailed and
       "ENOENT" in logObs.outcome.error.detail,
       "git missing: log is a pkFailed outcome naming ENOENT"

  # -- claim 2, made certain: a git that takes 0.2 s per call -----------
  block:
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
    let statusObs = await observe(facade.status(repo))
    let logObs = await observe(facade.log(repo, 30, ""))
    setEnv(cstring"PATH", cstring(savedPath))
    ck not statusObs.settledInline and statusObs.ticks >= 10,
       "a slow git: the event loop ticked while status ran (" & $statusObs.ticks & " ticks)"
    ck statusObs.outcome.ok and sameStatus(statusObs.outcome.value, gitStatusNow(repo)),
       "a slow git: status is still git's answer"
    ck not logObs.settledInline and logObs.ticks >= 10,
       "a slow git: the event loop ticked while log ran (" & $logObs.ticks & " ticks)"
    ck logObs.outcome.ok and logObs.outcome.value.len == 2,
       "a slow git: log is still git's answer"

  # -- claim 4: the index is not rewritten ------------------------------
  block:
    let stale = newRepository("stale")
    writeText(stale & "/tracked.txt", "one\n")
    commitAll(stale, "one")
    # 2001-09-09: years older than the index, so the entry's recorded stat
    # no longer matches and git must re-read the file to learn it is
    # unchanged — and, without the option, write the index back.
    discard nodeFs.utimesSync(cstring(stale & "/tracked.txt"),
                              1_000_000_000, 1_000_000_000)
    proc inode(): int = nodeFs.statSync(cstring(stale & "/.git/index")).ino.to(int)
    let before = inode()
    let obs = await observe(facade.status(stale))
    ck obs.outcome.ok and obs.outcome.value.changes.len == 0,
       "stale stat cache: status answers a clean tree"
    ck inode() == before, "stale stat cache: the index was not rewritten"
    ck not nodeFs.existsSync(cstring(stale & "/.git/index.lock")).to(bool),
       "stale stat cache: no index.lock is left"
    discard git(stale, "status", "--porcelain")
    ck inode() != before,
       "stale stat cache: control — a plain `git status` does rewrite this index"

const ExpectedChecks = 64

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
