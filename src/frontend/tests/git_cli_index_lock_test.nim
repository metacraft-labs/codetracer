## git_cli_index_lock_test.nim
##
## THE RENDERER'S OWN GIT CALLS NEVER TAKE THE INDEX LOCK.
##
## `ui/git_cli.nim` is the renderer's git command line: `ui/vcs.nim` (the
## desktop VCS panel, about twenty call sites, re-read on every refresh),
## `ui/unified_diff.nim` and `ui/agent_activity.nim` all run git through its
## `gitExec`. A plain `git status` or `git diff` refreshes the index's stat
## cache and writes the index back, creating `.git/index.lock` first; a window
## closed — or a GUI test harness tearing the app down — while git held it
## left the lock behind, and every later git command in the user's checkout
## failed until someone deleted it (codetracer-pm issue
## `2026-10-21-gui-test-runs-leave-a-stale-git-index-lock-in-the-codetracer-checkout`).
## VCS-Panel.md, "Reading the repository never takes the index lock".
##
## ## The claim, and how it is observed
##
## `gitExec` runs `status` and `diff` — the commands the panel's refresh
## sends — against repositories whose index has a STALE STAT CACHE:
## `tracked.txt` is committed, then its mtime is moved with its content
## unchanged. git writes an index only by creating `index.lock` and renaming
## it over `index`, so the index's inode changes exactly when the index was
## written; a call that leaves the inode alone took no lock, and none may be
## left. Each call gets its own repository, and each repository then gets the
## CONTROL: a plain `git status`, which must rewrite that index — proof the
## repository really was stale.
##
## ## What is real, and the one piece of wiring
##
## REAL: `ui/git_cli.gitExec` as the renderer runs it, the Electron
## renderer's process facade (`host/desktop_electron.electronProcess`, node's
## `execFileSync`), and `git` itself over repositories this suite creates.
##
## THE WIRING: under node `newDesktopElectronPlatform` finds no
## `require('electron')` and installs the web profile, which has no process
## spawn, so `gitExec` would answer "" without running git. The suite installs
## a platform with the Electron desktop profile and the Electron process
## facade — what the shipped window installs for these two fields — with
## every other facade refusing. Nothing under test is replaced.
##
## Every path is under one `mkdtemp` directory, git's global and system
## configuration are pointed at a file that does not exist, and the directory
## is removed at the end.
##
## Lane: `renderer-dom` — the browser target (`nim js -d:ctRenderer`, no
## `-d:nodejs`), run by `jsdom-run.mjs`, which loads the suite with node's
## `require`, so `child_process` is reachable. Without `-d:nodejs`
## `std/unittest` cannot set the exit status, so this suite sets it.

import std/[jsffi, strutils]

import ../viewmodel/platform/platform
import ../viewmodel/host/electron_profile
import ../viewmodel/host/desktop_electron
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
proc execFileRaw(program: cstring; args: seq[cstring]; cwd: cstring): cstring
  {.importjs: "require('child_process').execFileSync(#, #, {cwd: #, encoding: 'utf8'})".}

let nodeFs = nodeRequire("fs")
let nodeOs = nodeRequire("os")

let workspace = $(nodeFs.mkdtempSync(
  cstring($(nodeOs.tmpdir().to(cstring)) & "/ct-git-cli-index-lock-")).to(cstring))

setEnv(cstring"GIT_CONFIG_GLOBAL", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_SYSTEM", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")
setEnv(cstring"GIT_CEILING_DIRECTORIES", cstring(workspace))
for role in ["AUTHOR", "COMMITTER"]:
  setEnv(cstring("GIT_" & role & "_NAME"), cstring"git_cli Index Lock Test")
  setEnv(cstring("GIT_" & role & "_EMAIL"), cstring"index-lock@test.invalid")

let profile = electronDesktopProfile(false)
var desktop = newPlatform(profile)
desktop.process = electronProcess(profile)
installPlatform(desktop)

proc git(cwd: string; args: varargs[string]): string =
  ## The suite's own git, for setup and the control — plain, deliberately:
  ## the control has to be a git that DOES refresh the index.
  var jsArgs: seq[cstring] = @[]
  for a in args: jsArgs.add cstring(a)
  $execFileRaw(cstring"git", jsArgs, cstring(cwd))

proc staleStatRepository(name: string): string =
  result = workspace & "/" & name
  discard nodeFs.mkdirSync(cstring(result))
  discard git(result, "-c", "init.defaultBranch=main", "init", "-q", ".")
  discard nodeFs.writeFileSync(cstring(result & "/tracked.txt"), cstring"one\n")
  discard git(result, "add", "tracked.txt")
  discard git(result, "commit", "-q", "-m", "one")
  # 2001-09-09: years older than the index, so the entry's recorded stat no
  # longer matches and git must re-read the file to learn it is unchanged.
  discard nodeFs.utimesSync(cstring(result & "/tracked.txt"),
                            1_000_000_000, 1_000_000_000)

proc indexInode(repo: string): int =
  nodeFs.statSync(cstring(repo & "/.git/index")).ino.to(int)

proc lockLeft(repo: string): bool =
  nodeFs.existsSync(cstring(repo & "/.git/index.lock")).to(bool)

proc leavesTheIndexAlone(label: string; args: seq[cstring];
                         expected: proc(output: string): bool) =
  let repo = staleStatRepository(label.replace(' ', '-'))
  let before = indexInode(repo)
  let output = $gitExec(args, cstring(repo))
  ck expected(output), label & ": gitExec answers (" & output & ")"
  ck indexInode(repo) == before, label & ": the index was not rewritten"
  ck not lockLeft(repo), label & ": no index.lock is left"
  discard git(repo, "status", "--porcelain")
  ck indexInode(repo) != before,
     label & ": control — a plain `git status` does rewrite this index"

proc runCases() =
  echo "[Suite] ui/git_cli's git calls take no index lock"

  # The status the panel's refresh reads (`ui/vcs.loadWorkingTree`). The
  # answer must be non-empty — the branch header — so "" from a guard that
  # refused to run git cannot pass for a clean status.
  leavesTheIndexAlone("status",
      @[cstring"status", cstring"--porcelain=v2", cstring"--branch"]) do (
      output: string) -> bool:
    "# branch.head main" in output

  # The working tree's diff, whole and for one path. Empty is git's real
  # answer for a stale-but-unchanged file, so the control below (the index
  # was stale) and the status case (git really runs) carry the weight.
  leavesTheIndexAlone("diff", @[cstring"diff"]) do (output: string) -> bool:
    output == ""
  leavesTheIndexAlone("diff of one path",
      @[cstring"diff", cstring"--", cstring"tracked.txt"]) do (
      output: string) -> bool:
    output == ""

const ExpectedChecks = 12

try:
  runCases()
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
