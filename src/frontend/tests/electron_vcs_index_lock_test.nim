## electron_vcs_index_lock_test.nim
##
## THE ELECTRON RENDERER'S VCS READS NEVER TAKE THE INDEX LOCK.
##
## The desktop's VCS panel re-reads the repository every few seconds through
## the Electron instantiation's facade (`host/desktop_electron.electronVcs`):
## `status`, and `diff` for the file the user is looking at. A plain
## `git status` or `git diff` refreshes the index's stat cache and writes the
## index back, which means creating `.git/index.lock` first. A window closed —
## or a GUI test harness tearing the app down — while git held that lock left
## it behind, and every later git command in the user's checkout failed with
## `Unable to create '.../.git/index.lock': File exists` (codetracer-pm issue
## `2026-10-21-gui-test-runs-leave-a-stale-git-index-lock-in-the-codetracer-checkout`).
## VCS-Panel.md, "Reading the repository never takes the index lock".
##
## ## The claim, and how it is observed
##
## Each read runs against a repository whose index has a STALE STAT CACHE:
## `tracked.txt` is committed, then its mtime is moved with its content
## unchanged. That is the state in which git refreshes and rewrites the index.
## git writes an index only by creating `index.lock` and renaming it over
## `index`, so the index's INODE changes exactly when the index was written —
## and a read that leaves the inode alone took no lock. No `index.lock` may be
## left either.
##
## Each read gets its own repository, so one read's refresh cannot hide
## another's write. Each repository then gets the CONTROL: a plain
## `git status`, which must rewrite the index. That proves the repository
## really was stale, so a pass cannot come from a fixture in which git had
## nothing to refresh.
##
## ## Why `electronVcs` is called directly
##
## As in `electron_vcs_content_id_async_test.nim`: under plain node
## `newDesktopElectronPlatform` finds no `require('electron')` and falls back
## to the web profile, so the facade the shipped window installs is reachable
## from a Nim lane only by name.
##
## ## What is real
##
## Everything: `git` itself over repositories this suite creates, node's
## `child_process`, the facade. Nothing is replaced. Every path is under one
## `mkdtemp` directory, git's global and system configuration are pointed at
## a file that does not exist, and the directory is removed at the end.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, run under
## node.

import std/[jsffi, strutils]

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
proc nodeRequire(module: cstring): JsObject {.importjs: "require(#)".}
proc setEnv(name, value: cstring) {.importjs: "process.env[#] = #".}
proc execFileRaw(program: cstring; args: seq[cstring]; cwd: cstring): cstring
  {.importjs: "require('child_process').execFileSync(#, #, {cwd: #, encoding: 'utf8'})".}

let nodeFs = nodeRequire("fs")
let nodeOs = nodeRequire("os")

let workspace = $(nodeFs.mkdtempSync(
  cstring($(nodeOs.tmpdir().to(cstring)) & "/ct-electron-index-lock-")).to(cstring))

# A git that sees only this suite's repositories: no developer configuration
# (a `core.hooksPath`, commit signing, a default branch name) and no search
# upwards past the workspace into whatever repository /tmp sits in.
setEnv(cstring"GIT_CONFIG_GLOBAL", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_SYSTEM", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")
setEnv(cstring"GIT_CEILING_DIRECTORIES", cstring(workspace))
for role in ["AUTHOR", "COMMITTER"]:
  setEnv(cstring("GIT_" & role & "_NAME"), cstring"Electron Index Lock Test")
  setEnv(cstring("GIT_" & role & "_EMAIL"), cstring"index-lock@test.invalid")

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

let facade = electronVcs(electronDesktopProfile(false))

proc leavesTheIndexAlone(label: string;
                         read: proc(repo: string): bool) =
  let repo = staleStatRepository(label.replace(' ', '-'))
  let before = indexInode(repo)
  ck read(repo), label & ": the read answers"
  ck indexInode(repo) == before, label & ": the index was not rewritten"
  ck not lockLeft(repo), label & ": no index.lock is left"
  # The control: a plain git in the same repository does rewrite it.
  discard git(repo, "status", "--porcelain")
  ck indexInode(repo) != before,
     label & ": control — a plain `git status` does rewrite this index"

proc runCases() =
  echo "[Suite] the Electron instantiation's VCS reads take no index lock"

  leavesTheIndexAlone("status") do (repo: string) -> bool:
    let res = awaitSync(facade.status(repo))
    res.ok and res.value.branch == "main" and res.value.changes.len == 0

  leavesTheIndexAlone("working tree diff") do (repo: string) -> bool:
    let res = awaitSync(facade.diff(repo, @[], false, 3))
    res.ok and res.value.len == 0

  leavesTheIndexAlone("working tree diff of one path") do (repo: string) -> bool:
    let res = awaitSync(facade.diff(repo, @["tracked.txt"], false, 3))
    res.ok and res.value.len == 0

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
  echo "  [FAILED] expected ", ExpectedChecks, " checks, ran ", checks
exitProcess(if failedChecks == 0 and checks == ExpectedChecks: 0 else: 1)
