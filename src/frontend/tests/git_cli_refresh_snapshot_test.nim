## git_cli_refresh_snapshot_test.nim
##
## THE VCS PANEL'S CHANGE CHECK NEVER WAITS FOR GIT.
##
## Every 5 s and on window focus the desktop VCS panel (`ui/vcs.nim`) asks
## whether the repository changed. It used to read `git status` and `git log`
## through `gitExec` — node's `execFileSync` on the renderer's main thread —
## and every tick froze the window for 150-185 ms (codetracer-pm issue
## `2026-10-21-vcs-auto-refresh-runs-git-synchronously-on-the-renderer-main-thread`).
## It now asks `ui/git_cli.requestRefreshCheck`, which reads through
## `readRefreshSnapshot`. VCS-Panel.md, "An auto-refresh never stalls the
## window", is what this suite holds them to.
##
## ## The claims
##
##   1. **The answer comes later, and the loop runs meanwhile.**
##      `readRefreshSnapshot`'s `done` has not run when the call returns, a
##      `setImmediate` scheduled right after it runs first, and with a git
##      that takes 0.2 s per call an interval timer keeps ticking until it
##      answers — and ticks for about ONE git call, not two, because the two
##      reads run side by side.
##   2. **The snapshot says whether anything changed.** Read twice over an
##      unchanged repository it is the same string; it differs after an edit,
##      after staging, after a commit and after a branch switch, and an
##      unmerged path appears in it as conflicted.
##   3. **A failed read is an empty part.** A directory outside any
##      repository and a git missing from `PATH` answer
##      `EmptyRefreshSnapshot`; a repository with no commits answers its
##      status and an empty log part; a platform without `capVcsRead` answers
##      `EmptyRefreshSnapshot` without running git.
##   4. **Triggers coalesce; stale answers are marked.** Three requests while
##      a check is in flight produce exactly one more check, not three and not
##      none. An answer that arrives after the working directory changed, or
##      after the session became folderless, comes with `current = false`.
##      A check that would start in a folderless session — including the
##      follow-up queued during a check — runs no git and answers at once
##      (VCS-Panel.md, "A session with no project folder"); a `git` wrapper
##      that logs each invocation counts what ran, and the real git runs
##      behind it.
##
## ## What is real, and the stand-ins
##
## REAL: `ui/git_cli` as the renderer runs it, the Electron renderer's VCS
## facade (`host/desktop_electron.electronVcs`, node's `child_process.spawn`),
## and `git` itself over repositories this suite creates.
##
## THE WIRING: under node `newDesktopElectronPlatform` finds no
## `require('electron')` and installs the web profile, which has no
## `capVcsRead`, so the reader would answer the empty snapshot without
## running git. The suite installs a platform with the Electron desktop
## profile and the Electron VCS facade — what the shipped window installs for
## these two fields — with every other facade refusing. For claim 3's last
## case it installs the same platform with `capVcsRead` removed from the
## profile, the one thing the guard reads.
##
## THE ONE STAND-IN is the `git` wrapper of claim 1: a `/bin/sh` script that
## sleeps 0.2 s and then `exec`s the real git with the same arguments, so
## "the loop ran while git did" is a certainty rather than a race, without
## changing what git answers.
##
## Claim 4's working-directory and folderless procs are the suite's own
## closures over two variables: they are the inputs `requestRefreshCheck`
## reads, and the panel's (`VCSComponent.getWorkingDirectory`,
## `hasNoProjectFolder`) need a whole window session to exist.
##
## Every path is under one `mkdtemp` directory, git's global and system
## configuration are pointed at a file that does not exist, and the directory
## is removed at the end.
##
## Lane: `renderer-dom` — the browser target (`nim js -d:ctRenderer`, no
## `-d:nodejs`), run by `jsdom-run.mjs`, which loads the suite with node's
## `require`, so `child_process` is reachable. Without `-d:nodejs`
## `std/unittest` cannot set the exit status, so this suite sets it.

import std/[asyncjs, jsffi, strutils]

import ../viewmodel/platform/platform
import ../viewmodel/host/electron_profile
import ../viewmodel/host/desktop_electron
import ../types
import ../ui/git_cli

var checks = 0
var failedChecks = 0

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

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
  cstring($(nodeOs.tmpdir().to(cstring)) & "/ct-git-cli-refresh-")).to(cstring))

setEnv(cstring"GIT_CONFIG_GLOBAL", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_SYSTEM", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")
setEnv(cstring"GIT_CEILING_DIRECTORIES", cstring(workspace))
for role in ["AUTHOR", "COMMITTER"]:
  setEnv(cstring("GIT_" & role & "_NAME"), cstring"git_cli Refresh Test")
  setEnv(cstring("GIT_" & role & "_EMAIL"), cstring"refresh@test.invalid")

let profile = electronDesktopProfile(false)

proc installElectronVcs(profile: PlatformProfile) =
  var desktop = newPlatform(profile)
  desktop.vcs = electronVcs(profile)
  installPlatform(desktop)

installElectronVcs(profile)

proc git(cwd: string; args: varargs[string]): string =
  var jsArgs: seq[cstring] = @[]
  for a in args: jsArgs.add cstring(a)
  result = $execGitRaw(jsArgs, cstring(cwd))
  result.stripLineEnd()

proc gitMayFail(cwd: string; args: varargs[string]): int =
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

# ---------------------------------------------------------------------------
# Observing one `readRefreshSnapshot`
# ---------------------------------------------------------------------------

type
  Read = ref object
    snapshot: string
    answeredInline: bool
      ## `done` ran before `readRefreshSnapshot` returned.
    immediateFirst: bool
      ## A `setImmediate` scheduled right after the call ran before `done`.
    ticks: int
      ## 5 ms interval ticks before `done` ran.

proc read(cwd: string): Future[Read] =
  let r = Read()
  var answered = false
  var immediateRan = false
  var timer: JsObject = nil
  var resolveIt: proc(value: Read) = nil
  readRefreshSnapshot(cstring(cwd), proc(snapshot: string) =
    answered = true
    r.snapshot = snapshot
    r.immediateFirst = immediateRan
    if not timer.isNil: clearInterval(timer)
    if not resolveIt.isNil: resolveIt(r))
  r.answeredInline = answered
  if answered:
    return newPromise(proc(resolve: proc(value: Read)) = resolve(r))
  setImmediate(proc() = immediateRan = true)
  timer = setInterval(proc() = (inc r.ticks), 5)
  newPromise(proc(resolve: proc(value: Read)) = resolveIt = resolve)

proc pause(ms: int): Future[void] =
  newPromise(proc(resolve: proc()) =
    discard nodeRequire("timers").setTimeout(resolve, ms))

proc runCases() {.async.} =
  echo "[Suite] ui/git_cli's change check never waits for git"

  let repo = newRepository("repo")
  writeText(repo & "/a.txt", "alpha\n")
  commitAll(repo, "first")

  # -- claim 1 ----------------------------------------------------------
  let clean = await read(repo)
  ck not clean.answeredInline, "done is not called before readRefreshSnapshot returns"
  ck clean.immediateFirst, "a setImmediate scheduled after the call runs first"
  ck clean.snapshot.startsWith("branch main\n") and
     clean.snapshot.endsWith(git(repo, "rev-parse", "HEAD") & "\n"),
     "the snapshot names the branch and ends with HEAD's id"

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
    let slow = await read(repo)
    setEnv(cstring"PATH", cstring(savedPath))
    ck not slow.answeredInline and slow.ticks >= 10,
       "a slow git: the event loop ticked while the snapshot was read (" &
       $slow.ticks & " ticks)"
    # Two 0.2 s reads one after the other would leave ~80 ticks; side by
    # side they leave ~40. 70 is the line between, with slack for a busy
    # host on either side.
    ck slow.ticks < 70,
       "a slow git: the two reads ran side by side (" & $slow.ticks & " ticks)"
    ck slow.snapshot == clean.snapshot, "a slow git: the same snapshot"

  # -- claim 2 ----------------------------------------------------------
  let again = await read(repo)
  ck again.snapshot == clean.snapshot, "an unchanged repository reads the same snapshot"

  writeText(repo & "/a.txt", "alpha, edited\n")
  let edited = await read(repo)
  ck edited.snapshot != clean.snapshot, "an edit changes the snapshot"
  ck "vfsUnmodified vfsModified a.txt\n" in edited.snapshot,
     "the edit is named with its index and working-tree states"
  ck (await read(repo)).snapshot == edited.snapshot, "and is stable while nothing else moves"

  discard git(repo, "add", "a.txt")
  let staged = await read(repo)
  ck staged.snapshot != edited.snapshot, "staging changes the snapshot"

  discard git(repo, "commit", "-q", "-m", "second")
  let committed = await read(repo)
  ck committed.snapshot != staged.snapshot and committed.snapshot != clean.snapshot,
     "a commit changes the snapshot"
  ck committed.snapshot.endsWith(
       git(repo, "rev-list", "--max-count=30", "HEAD") & "\n"),
     "the log part is the newest commit ids, newest first"

  discard git(repo, "checkout", "-q", "-b", "topic")
  let switched = await read(repo)
  ck switched.snapshot != committed.snapshot and
     switched.snapshot.startsWith("branch topic\n"),
     "a branch switch changes the snapshot"

  block:
    let conflict = newRepository("conflict")
    writeText(conflict & "/c.txt", "base\n")
    commitAll(conflict, "base")
    discard git(conflict, "checkout", "-q", "-b", "other")
    writeText(conflict & "/c.txt", "other side\n")
    commitAll(conflict, "other")
    discard git(conflict, "checkout", "-q", "main")
    writeText(conflict & "/c.txt", "main side\n")
    commitAll(conflict, "main")
    let before = await read(conflict)
    ck gitMayFail(conflict, "merge", "-q", "other") != 0,
       "control: the merge stops on a conflict"
    let during = await read(conflict)
    ck "vfsConflicted vfsConflicted c.txt\n" in during.snapshot,
       "an unmerged path appears as conflicted"
    ck during.snapshot != before.snapshot, "a conflict starting changes the snapshot"

  # -- claim 3 ----------------------------------------------------------
  let outside = workspace & "/not-a-repository"
  makeDir(outside)
  ck (await read(outside)).snapshot == EmptyRefreshSnapshot,
     "outside a repository: the empty snapshot"

  block:
    let unborn = newRepository("unborn")
    writeText(unborn & "/u.txt", "u\n")
    let r = await read(unborn)
    ck r.snapshot.startsWith("branch main\n") and
       "vfsUnmodified vfsUntracked u.txt\n" in r.snapshot and
       r.snapshot.endsWith("\n---\n"),
     "no commits yet: the status part, and an empty log part"

  block:
    let savedPath = $getEnv(cstring"PATH")
    let emptyBin = workspace & "/empty-bin"
    makeDir(emptyBin)
    setEnv(cstring"PATH", cstring(emptyBin))
    let r = await read(repo)
    setEnv(cstring"PATH", cstring(savedPath))
    ck r.snapshot == EmptyRefreshSnapshot, "git missing from PATH: the empty snapshot"

  block:
    var blind = profile
    blind.capabilities.excl capVcsRead
    installElectronVcs(blind)
    let r = await read(repo)
    installElectronVcs(profile)
    ck r.snapshot == EmptyRefreshSnapshot,
       "a platform without capVcsRead: the empty snapshot"
    ck r.answeredInline, "a platform without capVcsRead: answered without running git"

  # -- claim 4 ----------------------------------------------------------
  block:
    var cwd = repo
    var folderless = false
    var answers: seq[(string, bool)] = @[]
    let check = VcsRefreshCheck()
    let wd = proc(): cstring = cstring(cwd)
    let fl = proc(): bool = folderless
    let done = proc(snapshot: string; current: bool) = answers.add (snapshot, current)
    requestRefreshCheck(check, wd, fl, done)
    ck check.inFlight, "a check is in flight after the first request"
    requestRefreshCheck(check, wd, fl, done)
    requestRefreshCheck(check, wd, fl, done)
    requestRefreshCheck(check, wd, fl, done)
    ck answers.len == 0 and check.followUp,
       "three requests during it are queued, not run, and nothing answered yet"
    for _ in 0 ..< 200:
      if answers.len >= 2 and not check.inFlight: break
      await pause(10)
    await pause(100)
    ck answers.len == 2,
       "exactly one more check follows the one in flight (" & $answers.len & " answers)"
    ck answers.len == 2 and answers[0][1] and answers[1][1] and
       answers[0][0] == switched.snapshot and answers[1][0] == switched.snapshot,
       "both answers are current and are the repository's snapshot"
    ck not check.inFlight and not check.followUp, "nothing is left in flight"

    answers = @[]
    requestRefreshCheck(check, wd, fl, done)
    cwd = outside
    for _ in 0 ..< 200:
      if answers.len >= 1: break
      await pause(10)
    ck answers.len == 1 and not answers[0][1],
       "an answer read for a working directory the panel left is not current"

    answers = @[]
    cwd = repo
    requestRefreshCheck(check, wd, fl, done)
    folderless = true
    for _ in 0 ..< 200:
      if answers.len >= 1: break
      await pause(10)
    ck answers.len == 1 and not answers[0][1],
       "an answer that arrives after the session became folderless is not current"

    # A folderless session runs no git, including the follow-up queued while
    # a check was in flight: that one starts inside `requestRefreshCheck`,
    # past the panel's own guard. A wrapper git that appends one line per
    # invocation to a log counts what ran.
    let gitPath = block:
      let which = nodeRequire("child_process").execFileSync(
        cstring"/bin/sh", @[cstring"-c", cstring"command -v git"],
        js{encoding: cstring"utf8"}).to(cstring)
      ($which).strip()
    let countingBin = workspace & "/counting-bin"
    let invocations = workspace & "/git-invocations.log"
    makeDir(countingBin)
    writeText(countingBin & "/git", "#!/bin/sh\necho \"$1\" >> '" & invocations &
              "'\nexec '" & gitPath & "' \"$@\"\n")
    discard nodeFs.chmodSync(cstring(countingBin & "/git"), 0o755)
    proc invoked(): int =
      if not nodeFs.existsSync(cstring(invocations)).to(bool): return 0
      let text = $(nodeFs.readFileSync(cstring(invocations),
                                       cstring"utf8").to(cstring))
      text.splitLines().len - 1
    let savedPath = $getEnv(cstring"PATH")
    setEnv(cstring"PATH", cstring(countingBin & ":" & savedPath))

    answers = @[]
    folderless = true
    requestRefreshCheck(check, wd, fl, done)
    ck answers.len == 1 and not answers[0][1] and
       answers[0][0] == EmptyRefreshSnapshot and not check.inFlight,
       "folderless: the request answers at once, not current, the empty snapshot"
    await pause(100)
    ck invoked() == 0, "folderless: no git ran (" & $invoked() & " invocations)"

    answers = @[]
    folderless = false
    requestRefreshCheck(check, wd, fl, done)
    requestRefreshCheck(check, wd, fl, done)
    folderless = true
    for _ in 0 ..< 200:
      if answers.len >= 2 and not check.inFlight: break
      await pause(10)
    await pause(100)
    setEnv(cstring"PATH", cstring(savedPath))
    ck answers.len == 2 and not answers[0][1] and not answers[1][1] and
       answers[1][0] == EmptyRefreshSnapshot,
       "folderless before the follow-up: both answers are not current (" &
       $answers.len & " answers)"
    ck invoked() == 2,
       "folderless before the follow-up: only the first check's two reads ran git (" &
       $invoked() & " invocations)"

const ExpectedChecks = 33

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
    inc failedChecks
    echo "  [FAILED] expected ", ExpectedChecks, " checks, ran ", checks
  if failedChecks > 0:
    {.emit: "process.exitCode = 1;".}

discard main()
