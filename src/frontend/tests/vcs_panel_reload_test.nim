## vcs_panel_reload_test.nim
##
## THE VCS PANEL'S RELOAD NEVER WAITS FOR GIT.
##
## When the desktop VCS panel's change check (`git_cli.requestRefreshCheck`)
## finds that the repository moved, the panel reloads: the branch, the
## working tree, the branch list, the first page of commits and the files of
## every expanded commit. Each of those used to be a `gitExec` — node's
## `execFileSync` on the renderer's main thread — so the window froze once
## per git process on every tick on which the repository moved (codetracer-pm
## issue `2026-10-23-vcs-reload-after-a-detected-change-runs-git-synchronously`).
## The reload now goes through `ui/vcs_reload` (`readPanelReload`,
## `panelStateOf`, `applyPanelState`, `requestPanelReload`) over
## `git_cli.gitReadLater` and the process facade's `runLater`. VCS-Panel.md,
## "An auto-refresh never stalls the window", is what this suite holds them
## to.
##
## ## The claims
##
##   1. **The reads answer later, and the loop runs meanwhile.**
##      `readPanelReload`'s `done` has not run when the call returns, a
##      `setImmediate` scheduled right after it runs first, and with a git
##      that takes 0.2 s per call an interval timer keeps ticking until it
##      answers — for about one git call per ROUND (the reads of a round run
##      side by side), not one per read. The Electron process facade's
##      `runLater` and `git_cli.gitReadLater` are held to the same, and to
##      reporting what the child did.
##   2. **The gathered state is the synchronous load's.** For a clean,
##      modified, staged, untracked, conflicted and detached repository, one
##      with several branches and commits, one with an expanded commit, one
##      with no commits, a directory outside any repository and a git missing
##      from `PATH`, the reads equal what `gitExec` answers for the same
##      commands, the state built from them equals the state built from the
##      reads the synchronous reload made (the same commands, made only when
##      that reload made them), and both write the same values into a panel.
##      Literal expectations anchor the parsing to the repository.
##   3. **Apply is atomic; stale answers are discarded; nothing starves.** The
##      panel shows what it showed until every read has answered — also
##      between the two rounds — and then changes in one call. Requests during
##      a reload produce exactly one more reload, after the one in flight is
##      applied, so requests that keep arriving faster than a reload answers
##      still let the panel move; an answer read for a working directory or an
##      expanded set the panel no longer shows is discarded and read again; one that arrives after the session became
##      folderless is discarded and not read again; one the caller released
##      (`releaseInFlight`, because it wrote the panel's state itself) is
##      discarded with the follow-up queued before the release, while a
##      request made after it still runs.
##   4. **A folderless session runs no git**, including the follow-up queued
##      during a reload (VCS-Panel.md, "A session with no project folder"). A
##      `git` wrapper that logs each invocation counts what ran.
##   5. **The panel reloads through this path.** `ui/vcs.nim`'s
##      `refreshVCSData` calls `requestPanelReload` and runs no `gitExec`
##      itself — a source contract, because `ui/vcs.nim` needs a whole window
##      session to run (GoldenLayout, the isonim web renderer).
##
## ## What is real, and the stand-ins
##
## REAL: `ui/vcs_reload` and `ui/git_cli` as the renderer runs them, the
## Electron renderer's process and VCS facades
## (`host/desktop_electron.electronProcess` / `electronVcs`: node's
## `child_process.spawn` for `runLater`, `execFileSync` for `run`, which the
## synchronous reference reads through), `git` itself over repositories this
## suite creates, and a real `VCSComponent` written by `applyPanelState`.
##
## THE WIRING: under node `newDesktopElectronPlatform` finds no
## `require('electron')` and installs the web profile, which cannot run
## programs, so every read would answer "" without running git. The suite
## installs a platform with the Electron desktop profile and the Electron
## process and VCS facades — what the shipped window installs for those
## fields — with every other facade refusing.
##
## THE STAND-INS are two `git` wrappers: a `/bin/sh` script that sleeps 0.2 s
## and then `exec`s the real git with the same arguments, so "the loop ran
## while git did" is a certainty rather than a race; and one that appends a
## line per invocation to a log before `exec`ing it, so "no git ran" is
## counted rather than inferred. Neither changes what git answers.
##
## Claim 3's and 4's target and folderless procs are the suite's own
## closures over variables: they are the inputs `requestPanelReload` reads,
## and the panel's (`VCSComponent.getWorkingDirectory`,
## `selectedCommitIndices`, `hasNoProjectFolder`) need a window session.
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
from ../platform_host import ctPlatform
import ../lib/jslib
import ../types
import ../ui/git_cli
import ../ui/vcs_reload

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
  cstring($(nodeOs.tmpdir().to(cstring)) & "/ct-vcs-panel-reload-")).to(cstring))

setEnv(cstring"GIT_CONFIG_GLOBAL", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_SYSTEM", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")
setEnv(cstring"GIT_CEILING_DIRECTORIES", cstring(workspace))
for role in ["AUTHOR", "COMMITTER"]:
  setEnv(cstring("GIT_" & role & "_NAME"), cstring"VCS Reload Test")
  setEnv(cstring("GIT_" & role & "_EMAIL"), cstring"reload@test.invalid")
  # Years in the past: the commit page carries a relative date (`%cr`), and
  # for commits made seconds ago two reads a second apart would differ
  # ("1 second ago" / "2 seconds ago") without anything having moved.
  setEnv(cstring("GIT_" & role & "_DATE"), cstring"2020-01-01T00:00:00Z")

let profile = electronDesktopProfile(false)

block:
  var desktop = newPlatform(profile)
  desktop.process = electronProcess(profile)
  desktop.vcs = electronVcs(profile)
  installPlatform(desktop)

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

proc pause(ms: int): Future[void] =
  newPromise(proc(resolve: proc()) =
    discard nodeRequire("timers").setTimeout(resolve, ms))

proc realGit(): string =
  let which = nodeRequire("child_process").execFileSync(
    cstring"/bin/sh", @[cstring"-c", cstring"command -v git"],
    js{encoding: cstring"utf8"}).to(cstring)
  ($which).strip()

proc wrapperBin(name, body: string): string =
  ## A directory holding one executable `git` with `body` as its script.
  result = workspace & "/" & name
  makeDir(result)
  writeText(result & "/git", "#!/bin/sh\n" & body)
  discard nodeFs.chmodSync(cstring(result & "/git"), 0o755)

# ---------------------------------------------------------------------------
# Observing one `readPanelReload`
# ---------------------------------------------------------------------------

type
  Gathered = ref object
    reads: VcsReloadReads
    answeredInline: bool
      ## `done` ran before `readPanelReload` returned.
    immediateFirst: bool
      ## A `setImmediate` scheduled right after the call ran before `done`.
    ticks: int
      ## 5 ms interval ticks before `done` ran.

proc gather(target: VcsReloadTarget): Future[Gathered] =
  let g = Gathered()
  var answered = false
  var immediateRan = false
  var timer: JsObject = nil
  var resolveIt: proc(value: Gathered) = nil
  readPanelReload(target, proc(reads: VcsReloadReads) =
    answered = true
    g.reads = reads
    g.immediateFirst = immediateRan
    if not timer.isNil: clearInterval(timer)
    if not resolveIt.isNil: resolveIt(g))
  g.answeredInline = answered
  if answered:
    return newPromise(proc(resolve: proc(value: Gathered)) = resolve(g))
  setImmediate(proc() = immediateRan = true)
  timer = setInterval(proc() = (inc g.ticks), 5)
  newPromise(proc(resolve: proc(value: Gathered)) = resolveIt = resolve)

proc targetFor(repo: string; expanded: seq[int] = @[]): VcsReloadTarget =
  VcsReloadTarget(workingDirectory: repo, expanded: expanded)

proc syncReloadReads(target: VcsReloadTarget): VcsReloadReads =
  ## The reads the synchronous reload made, through `gitExec`, in its order
  ## and only when it made them: nothing after a "not a work tree", HEAD's
  ## short id only on a detached HEAD, a commit's `--name-status` only when
  ## its `--numstat` named no file. The reference claim 2 compares with.
  let cwd = cstring(target.workingDirectory)
  result.target = target
  result.insideWorkTree = gitExec(insideWorkTreeArgs(), cwd)
  if result.insideWorkTree != cstring"true":
    return
  result.currentBranch = gitExec(currentBranchArgs(), cwd)
  if result.currentBranch.len == 0:
    result.shortHead = gitExec(shortHeadArgs(), cwd)
  result.workingTree = gitExec(workingTreeArgs(), cwd)
  result.branches = gitExec(branchListArgs(), cwd)
  result.commitPage = gitExec(commitPageArgs(0), cwd)
  let page = commitPageOf(result.commitPage)
  for index in target.expanded:
    if index < 0 or index >= page.len:
      continue
    var read = VcsCommitFilesRead(index: index)
    read.numstat = gitExec(commitNumstatArgs(page[index].hash), cwd)
    if numstatFilesOf(read.numstat).len == 0:
      read.nameStatus = gitExec(commitNameStatusArgs(page[index].hash), cwd)
    result.commitFiles.add read

proc everyReadNow(target: VcsReloadTarget): VcsReloadReads =
  ## Every command `readPanelReload` issues, through `gitExec`: what its
  ## answers must equal read by read.
  let cwd = cstring(target.workingDirectory)
  result.target = target
  result.insideWorkTree = gitExec(insideWorkTreeArgs(), cwd)
  result.currentBranch = gitExec(currentBranchArgs(), cwd)
  result.shortHead = gitExec(shortHeadArgs(), cwd)
  result.workingTree = gitExec(workingTreeArgs(), cwd)
  result.branches = gitExec(branchListArgs(), cwd)
  result.commitPage = gitExec(commitPageArgs(0), cwd)
  if result.insideWorkTree != cstring"true":
    return
  let page = commitPageOf(result.commitPage)
  for index in target.expanded:
    if index >= 0 and index < page.len:
      result.commitFiles.add VcsCommitFilesRead(index: index,
        numstat: gitExec(commitNumstatArgs(page[index].hash), cwd),
        nameStatus: gitExec(commitNameStatusArgs(page[index].hash), cwd))

proc panelOf(state: VcsPanelState): VCSComponent =
  result = VCSComponent()
  result.commitFilesCache = JsAssoc[int, seq[VCSChangedFile]]{}
  result.applyPanelState(state)

proc samePanel(a, b: VCSComponent): bool =
  ## Every field `applyPanelState` writes.
  if a.isGitRepo != b.isGitRepo or a.errorMessage != b.errorMessage or
     a.currentBranch != b.currentBranch or
     a.workingTreeChanges != b.workingTreeChanges or a.branches != b.branches or
     a.commits != b.commits or a.commitOffset != b.commitOffset or
     a.allCommitsLoaded != b.allCommitsLoaded or a.changedFiles != b.changedFiles:
    return false
  for index in 0 ..< 60:
    if a.commitFilesCache.hasKey(index) != b.commitFilesCache.hasKey(index):
      return false
    if a.commitFilesCache.hasKey(index) and
       a.commitFilesCache[index] != b.commitFilesCache[index]:
      return false
  true

proc equivalent(label: string; target: VcsReloadTarget): Future[VcsPanelState] {.async.} =
  ## Claim 2 for one repository state: three checks, and the state.
  let gathered = await gather(target)
  ck gathered.reads == everyReadNow(target),
     label & ": every read answers what gitExec answers for it"
  let state = panelStateOf(gathered.reads)
  let reference = panelStateOf(syncReloadReads(target))
  ck state == reference,
     label & ": the state is the synchronous reload's"
  ck samePanel(panelOf(state), panelOf(reference)),
     label & ": both write the same values into a panel"
  return state

proc fileNamed(files: seq[VCSChangedFile]; name: string): VCSChangedFile =
  for file in files:
    if file.filename == cstring(name): return file
  VCSChangedFile()

proc runCases() {.async.} =
  echo "[Suite] ui/vcs_reload's reload never waits for git"

  let repo = newRepository("repo")
  writeText(repo & "/a.txt", "alpha\n")
  commitAll(repo, "first")
  writeText(repo & "/b.txt", "beta\n")
  commitAll(repo, "second")
  writeText(repo & "/a.txt", "alpha\nmore\n")
  writeText(repo & "/c.txt", "gamma\n")
  commitAll(repo, "third")
  discard git(repo, "branch", "feature")
  discard git(repo, "branch", "zeta")
  let gitPath = realGit()

  # -- claim 1 ----------------------------------------------------------
  let clean = await gather(targetFor(repo))
  ck not clean.answeredInline, "done is not called before readPanelReload returns"
  ck clean.immediateFirst, "a setImmediate scheduled after the call runs first"

  block:
    var inline = true
    var output = cstring"unset"
    gitReadLater(currentBranchArgs(), cstring(repo), proc(o: cstring) =
      output = o)
    inline = output != cstring"unset"
    ck not inline, "gitReadLater: the answer is not delivered before it returns"
    for _ in 0 ..< 200:
      if output != cstring"unset": break
      await pause(10)
    ck output == gitExec(currentBranchArgs(), cstring(repo)) and output == cstring"main",
       "gitReadLater: it answers what gitExec answers (" & $output & ")"

  block:
    let process = ctPlatform().process
    var settled = false
    var outcome: PlatformOutcome[ProcessRunResult]
    let future = process.runLater(ProcessSpec(
      command: "git", args: @["rev-parse", "--verify", "--quiet", "no-such-ref"],
      workingDir: repo))
    future.onComplete(
      proc(o: PlatformOutcome[ProcessRunResult]) =
        settled = true
        outcome = o,
      proc(message: string) = settled = true)
    drainPlatformCallbacks()
    ck not settled, "process.runLater: not settled when it returns"
    for _ in 0 ..< 200:
      if settled: break
      await pause(10)
    ck settled and outcome.ok and outcome.value.exit.exitCode == 1 and
       not outcome.value.exit.succeededExit,
       "process.runLater: a command that exits 1 reports exit 1"
    var missing = false
    var missingKind = pkNone
    process.runLater(ProcessSpec(command: workspace & "/no-such-program")).onComplete(
      proc(o: PlatformOutcome[ProcessRunResult]) =
        missing = true
        if not o.ok: missingKind = o.error.kind,
      proc(message: string) = missing = true)
    for _ in 0 ..< 200:
      if missing: break
      await pause(10)
    ck missingKind == pkFailed, "process.runLater: a program that cannot be launched is pkFailed"
    var stdinKind = pkNone
    process.runLater(ProcessSpec(command: "git", stdinText: "x")).onComplete(
      proc(o: PlatformOutcome[ProcessRunResult]) =
        if not o.ok: stdinKind = o.error.kind,
      proc(message: string) = discard)
    drainPlatformCallbacks()
    ck stdinKind == pkNotSupported, "process.runLater: stdin text is refused, not dropped"

  block:
    let slowBin = wrapperBin("slow-bin", "sleep 0.2\nexec '" & gitPath & "' \"$@\"\n")
    let savedPath = $getEnv(cstring"PATH")
    setEnv(cstring"PATH", cstring(slowBin & ":" & savedPath))
    let slow = await gather(targetFor(repo))
    let slowExpanded = await gather(targetFor(repo, @[0]))
    setEnv(cstring"PATH", cstring(savedPath))
    ck not slow.answeredInline and slow.ticks >= 10,
       "a slow git: the event loop ticked while the reload read (" & $slow.ticks & " ticks)"
    # Six 0.2 s reads one after the other would leave ~240 ticks; side by
    # side they leave ~40. 70 is the line, with slack for a busy host.
    ck slow.ticks < 70,
       "a slow git: the six reads of the first round ran side by side (" &
       $slow.ticks & " ticks)"
    # An expanded commit adds one round: ~80 ticks, where eight reads in
    # turn would leave ~320.
    ck slowExpanded.ticks >= 20 and slowExpanded.ticks < 140,
       "a slow git, one commit expanded: two rounds, not eight reads in turn (" &
       $slowExpanded.ticks & " ticks)"
    ck slow.reads == clean.reads, "a slow git: the same answers"

  # -- claim 2 ----------------------------------------------------------
  let cleanState = await equivalent("clean", targetFor(repo))
  ck cleanState.isGitRepo and cleanState.currentBranch == cstring"main" and
     cleanState.workingTreeChanges.len == 0,
     "clean: a repository on main with no changes"
  ck cleanState.branches == @[cstring"feature", cstring"main", cstring"zeta"],
     "several branches: all of them, in git's order"
  ck cleanState.commitPage.len == 3 and
     cleanState.commitPage[0].message == cstring"third" and
     cleanState.commitPage[2].message == cstring"first" and
     cleanState.commitPage[0].fullHash == cstring(git(repo, "rev-parse", "HEAD")) and
     cleanState.commitPage[0].parents == @[cstring(git(repo, "rev-parse", "HEAD~1"))] and
     cleanState.commitPage[2].parents.len == 0 and
     cleanState.commitPage[0].author == cstring"VCS Reload Test",
     "commits: newest first, with ids, parents and authors"

  block:
    let state = await equivalent("an expanded commit", targetFor(repo, @[0, 2, 7]))
    ck state.commitFiles.len == 2 and state.commitFiles[0].index == 0 and
       state.commitFiles[1].index == 2,
       "an expanded commit: the files of each index the page reaches, and no other"
    let third = if state.commitFiles.len > 0: state.commitFiles[0].files else: @[]
    ck fileNamed(third, "a.txt").additions == 1 and
       fileNamed(third, "a.txt").status == cstring"A" and
       fileNamed(third, "c.txt").status == cstring"A" and third.len == 2,
       "an expanded commit: its changed files with their line counts"
    ck third == commitFilesNow(cstring(repo), cleanState.commitPage[0].hash),
       "an expanded commit: the same files the user's expand reads (commitFilesNow)"

  writeText(repo & "/a.txt", "alpha, edited\n")
  let modified = await equivalent("modified", targetFor(repo))
  ck fileNamed(modified.workingTreeChanges, "a.txt").status == cstring"M",
     "modified: the file, as M"

  discard git(repo, "add", "a.txt")
  writeText(repo & "/new.txt", "new\n")
  discard git(repo, "add", "new.txt")
  let staged = await equivalent("staged", targetFor(repo))
  ck fileNamed(staged.workingTreeChanges, "new.txt").status == cstring"A" and
     fileNamed(staged.workingTreeChanges, "a.txt").status == cstring"M",
     "staged: an added file as A, a staged edit as M"

  writeText(repo & "/loose.txt", "loose\n")
  let untracked = await equivalent("untracked", targetFor(repo))
  ck fileNamed(untracked.workingTreeChanges, "loose.txt").status == cstring"?",
     "untracked: the file, as ?"
  discard git(repo, "reset", "-q", "--hard")
  discard git(repo, "clean", "-q", "-f")

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
    ck gitMayFail(conflict, "merge", "-q", "other") != 0,
       "control: the merge stops on a conflict"
    let state = await equivalent("conflicted", targetFor(conflict))
    ck fileNamed(state.workingTreeChanges, "c.txt").status == cstring"U",
       "conflicted: the unmerged path, as U"

  block:
    discard git(repo, "checkout", "-q", "--detach", "HEAD~1")
    let state = await equivalent("detached", targetFor(repo))
    ck state.currentBranch == cstring(git(repo, "rev-parse", "--short", "HEAD")),
       "detached: named by HEAD's short id"
    discard git(repo, "checkout", "-q", "main")

  block:
    let unborn = newRepository("unborn")
    writeText(unborn & "/u.txt", "u\n")
    let state = await equivalent("no commits yet", targetFor(unborn, @[0]))
    ck state.isGitRepo and state.currentBranch == cstring"main" and
       state.commitPage.len == 0 and state.commitFiles.len == 0 and
       fileNamed(state.workingTreeChanges, "u.txt").status == cstring"?",
       "no commits yet: a repository, its branch, its files, no commits"

  let outside = workspace & "/not-a-repository"
  makeDir(outside)
  block:
    let state = await equivalent("outside a repository", targetFor(outside))
    ck not state.isGitRepo and state.errorMessage == cstring(NotAGitRepositoryText),
       "outside a repository: not a git repository"

  block:
    let savedPath = $getEnv(cstring"PATH")
    let emptyBin = workspace & "/empty-bin"
    makeDir(emptyBin)
    setEnv(cstring"PATH", cstring(emptyBin))
    let gathered = await gather(targetFor(repo, @[0]))
    let reference = syncReloadReads(targetFor(repo, @[0]))
    setEnv(cstring"PATH", cstring(savedPath))
    let state = panelStateOf(gathered.reads)
    ck state == panelStateOf(reference) and not state.isGitRepo and
       state.errorMessage == cstring(NotAGitRepositoryText),
       "git missing from PATH: the synchronous reload's answer, not a git repository"

  # -- claim 3 ----------------------------------------------------------
  let other = newRepository("other")
  writeText(other & "/o.txt", "o\n")
  commitAll(other, "other's only commit")
  let countingBin = wrapperBin("counting-bin",
    "echo \"$1\" >> '" & workspace & "/git-invocations.log'\n" &
    "exec '" & gitPath & "' \"$@\"\n")
  let invocations = workspace & "/git-invocations.log"
  proc invoked(): int =
    if not nodeFs.existsSync(cstring(invocations)).to(bool): return 0
    let text = $(nodeFs.readFileSync(cstring(invocations), cstring"utf8").to(cstring))
    text.splitLines().len - 1
  proc resetInvocations() =
    if nodeFs.existsSync(cstring(invocations)).to(bool):
      discard nodeFs.rmSync(cstring(invocations))

  var cwd = repo
  var expanded: seq[int] = @[]
  var folderless = false
  var applied: seq[VcsReloadReads] = @[]
  let reload = VcsPanelReload()
  let tgt = proc(): VcsReloadTarget = targetFor(cwd, expanded)
  let fl = proc(): bool = folderless
  let panel = panelOf(cleanState)
  let apply = proc(reads: VcsReloadReads) =
    applied.add reads
    panel.applyPanelState(panelStateOf(reads))
  proc settle(): Future[void] {.async.} =
    for _ in 0 ..< 400:
      if not reload.inFlight and not reload.followUp: break
      await pause(10)
    await pause(50)

  let savedPath = $getEnv(cstring"PATH")
  block:
    # Atomic: with a slow git and one commit expanded, the panel is sampled
    # after the first round answered and before the second did.
    let slowBin = workspace & "/slow-bin"
    setEnv(cstring"PATH", cstring(slowBin & ":" & savedPath))
    discard git(repo, "checkout", "-q", "feature")
    writeText(repo & "/a.txt", "alpha, moved\n")
    expanded = @[0]
    requestPanelReload(reload, tgt, fl, apply)
    ck reload.inFlight and applied.len == 0 and
       panel.currentBranch == cstring"main" and panel.workingTreeChanges.len == 0,
       "a reload in flight: the panel shows what it showed"
    await pause(300)
    ck applied.len == 0 and panel.currentBranch == cstring"main" and
       panel.workingTreeChanges.len == 0 and not panel.commitFilesCache.hasKey(0),
       "between the two rounds: still nothing of the new state"
    await settle()
    setEnv(cstring"PATH", cstring(savedPath))
    ck applied.len == 1 and panel.currentBranch == cstring"feature" and
       fileNamed(panel.workingTreeChanges, "a.txt").status == cstring"M" and
       panel.commitFilesCache.hasKey(0),
       "when every read has answered: all of the new state, in one apply"
    discard git(repo, "checkout", "-q", "--", "a.txt")
    discard git(repo, "checkout", "-q", "main")
    expanded = @[]

  block:
    # NO STARVATION: requests that keep arriving faster than a reload
    # answers — a change check every 5 s against a repository that is
    # slower to reload than that — still let the panel move. With a 0.2 s git
    # a reload takes ~0.2 s, and a request arrives every 50 ms for 1.5 s, so
    # every reload has a newer request queued when it answers. Discarding a
    # superseded reload would apply nothing until the requests stopped.
    let slowBin = workspace & "/slow-bin"
    setEnv(cstring"PATH", cstring(slowBin & ":" & savedPath))
    applied = @[]
    requestPanelReload(reload, tgt, fl, apply)
    let stream = setInterval(proc() =
      requestPanelReload(reload, tgt, fl, apply), 50)
    await pause(1500)
    let appliedDuringStream = applied.len
    clearInterval(stream)
    await settle()
    setEnv(cstring"PATH", cstring(savedPath))
    ck appliedDuringStream >= 2,
       "requests arriving faster than a reload answers do not starve the panel (" &
       $appliedDuringStream & " applies while they arrived)"

  setEnv(cstring"PATH", cstring(countingBin & ":" & savedPath))
  block:
    resetInvocations()
    applied = @[]
    requestPanelReload(reload, tgt, fl, apply)
    requestPanelReload(reload, tgt, fl, apply)
    requestPanelReload(reload, tgt, fl, apply)
    requestPanelReload(reload, tgt, fl, apply)
    ck reload.inFlight and reload.followUp and applied.len == 0,
       "three requests during a reload are queued, not run"
    await settle()
    ck applied.len == 2 and invoked() == 12 and
       applied[0].target == applied[1].target,
       "they make exactly one more reload, and the superseded one is applied first (" &
       $applied.len & " applies, " & $invoked() & " git runs)"

  block:
    resetInvocations()
    applied = @[]
    requestPanelReload(reload, tgt, fl, apply)
    cwd = other
    await settle()
    ck applied.len == 1 and applied[0].target.workingDirectory == other and
       invoked() == 12 and panel.currentBranch == cstring"main" and
       panel.commits.len == 1,
       "an answer for a directory the panel left is discarded and read again"
    cwd = repo

  block:
    resetInvocations()
    applied = @[]
    requestPanelReload(reload, tgt, fl, apply)
    expanded = @[1]
    await settle()
    ck applied.len == 1 and applied[0].target.expanded == @[1] and
       panel.commitFilesCache.hasKey(1) and not panel.commitFilesCache.hasKey(0),
       "an answer for an expanded set the panel no longer shows is discarded and read again"
    expanded = @[]

  block:
    resetInvocations()
    applied = @[]
    requestPanelReload(reload, tgt, fl, apply)
    folderless = true
    await settle()
    ck applied.len == 0 and invoked() == 6,
       "an answer after the session became folderless is discarded, not read again (" &
       $invoked() & " git runs)"
    folderless = false

  block:
    # RELEASED: the caller wrote the panel's state itself while a reload read
    # (`agentic_session_launcher.syncVcs`, through
    # `VCSComponent.adoptExternalState`). Neither that reload's answer nor a
    # follow-up queued before the release replaces it.
    resetInvocations()
    applied = @[]
    requestPanelReload(reload, tgt, fl, apply)
    requestPanelReload(reload, tgt, fl, apply)
    reload.releaseInFlight()
    await settle()
    ck applied.len == 0 and invoked() == 6 and not reload.inFlight and
       not reload.followUp and not reload.released,
       "a released reload is not applied and its queued follow-up does not run (" &
       $invoked() & " git runs)"

    # A request made after the release is a new one: it follows the released
    # reload and is applied.
    resetInvocations()
    applied = @[]
    requestPanelReload(reload, tgt, fl, apply)
    reload.releaseInFlight()
    requestPanelReload(reload, tgt, fl, apply)
    await settle()
    ck applied.len == 1 and invoked() == 12,
       "a request after the release reads again and is applied (" &
       $applied.len & " applies, " & $invoked() & " git runs)"

    # With nothing in flight the release changes nothing, and the next
    # reload is applied as usual; a panel that never loaded has no reload.
    resetInvocations()
    applied = @[]
    reload.releaseInFlight()
    VcsPanelReload(nil).releaseInFlight()
    requestPanelReload(reload, tgt, fl, apply)
    await settle()
    ck applied.len == 1 and invoked() == 6 and not reload.released,
       "a release with nothing in flight is a no-op"

  # -- claim 4 ----------------------------------------------------------
  block:
    resetInvocations()
    applied = @[]
    folderless = true
    requestPanelReload(reload, tgt, fl, apply)
    ck not reload.inFlight and applied.len == 0,
       "folderless: the request starts nothing"
    await pause(100)
    ck invoked() == 0, "folderless: no git ran (" & $invoked() & " invocations)"

    resetInvocations()
    folderless = false
    requestPanelReload(reload, tgt, fl, apply)
    requestPanelReload(reload, tgt, fl, apply)
    folderless = true
    await settle()
    ck applied.len == 0 and invoked() == 6 and not reload.inFlight and
       not reload.followUp,
       "folderless before the follow-up: only the first reload's reads ran git (" &
       $invoked() & " invocations)"
    folderless = false
  setEnv(cstring"PATH", cstring(savedPath))

  # -- claim 5 ----------------------------------------------------------
  block:
    let source = $(nodeFs.readFileSync(cstring"src/frontend/ui/vcs.nim",
                                       cstring"utf8").to(cstring))
    let start = source.find("proc refreshVCSData*")
    let rest = if start >= 0: source[start .. ^1] else: ""
    let stop = rest.find("\nproc ", 1)
    let body = if stop >= 0: rest[0 ..< stop] else: rest
    ck start >= 0 and "requestPanelReload(" in body and
       "gitExec(" notin body and "isGitRepository(" notin body and
       "loadCommits(" notin body,
       "ui/vcs.refreshVCSData reloads through requestPanelReload and runs no git itself"

  block:
    # The agentic launcher writes the panel's state itself; it gives up the
    # load in flight before it does, so no answer read from git replaces it.
    let source = $(nodeFs.readFileSync(
      cstring"src/frontend/ui/agentic_session_launcher.nim", cstring"utf8").to(cstring))
    let start = source.find("proc syncVcs(")
    let rest = if start >= 0: source[start .. ^1] else: ""
    let stop = rest.find("\nproc ", 1)
    let body = if stop >= 0: rest[0 ..< stop] else: rest
    let adopt = body.find("comp.adoptExternalState()")
    let firstWrite = body.find("comp.currentBranch =")
    ck start >= 0 and adopt >= 0 and firstWrite > adopt,
       "agentic_session_launcher.syncVcs releases the panel's load before writing it"

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
    inc failedChecks
    echo "  [FAILED] expected ", ExpectedChecks, " checks, ran ", checks
  if failedChecks > 0:
    {.emit: "process.exitCode = 1;".}

discard main()
