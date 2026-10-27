## acp_git_visible_changes_test.nim
##
## THE AGENT PANE'S CHANGE DETECTION LISTS EXACTLY THE FILES WHOSE CONTENT
## CHANGED, AND NEVER TAKES THE INDEX LOCK.
##
## At the start and end of every prompt the agent pane asks git which files
## differ from HEAD and which are untracked (`acp_ipc.gitVisibleChanges`), and
## reads a file's committed content (`gitFileAtHead`). Those reads run in the
## user's checkout, so they must not write its index: a CodeTracer killed
## while git held `.git/index.lock` left every later git command there
## failing with `Unable to create '.../.git/index.lock': File exists`.
##
## The reads therefore run with `--no-optional-locks -c
## diff.autoRefreshIndex=false`. With the index refresh off, `git diff
## --name-only` would also list a file whose stat changed but whose content
## did not, so the names are read from `git diff --numstat -z`, which compares
## the content. This suite holds both halves:
##
##   1. the listed set is exactly the files whose content changed (edited,
##      deleted, binary, renamed — the new name, as `--name-only` lists it —
##      and names with a space, a tab and a newline, which `-z` keeps
##      verbatim), plus untracked files that are not ignored; a file whose
##      mtime alone moved is NOT listed;
##   2. neither read rewrites the index nor leaves `index.lock`, and the
##      CONTROL — a plain `git status` in the same repository — does rewrite
##      it, so the repository really had a stale stat cache to refresh.
##
## Plus the edges the callers rely on: a committed file's content at HEAD, ""
## for an untracked one, and an empty list outside a repository.
##
## ## What is real
##
## Everything: `git` itself over repositories this suite creates, node's
## `child_process`, and the production procs, reached with `include` because
## they are private to the module (as `acp_notification_test.nim` does).
## Every path is under one `mkdtemp` directory, git's global and system
## configuration are pointed at a file that does not exist, and the directory
## is removed at the end.
##
## Run by `just test-acp-notifications` (`nim js -d:nodejs -d:server`), listed
## in the `frontend-js` lane.

include ../index/ipc_subsystems/acp_ipc

import std/[algorithm, sequtils]

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
proc chdir(path: cstring) {.importjs: "process.chdir(#)".}
proc currentDir(): cstring {.importjs: "process.cwd()".}
proc execFileRaw(program: cstring; args: seq[cstring]; cwd: cstring): cstring
  {.importjs: "require('child_process').execFileSync(#, #, {cwd: #, encoding: 'utf8'})".}

let nodeFs = nodeRequire("fs")
let nodeOs = nodeRequire("os")

let workspace = $(nodeFs.realpathSync(nodeFs.mkdtempSync(
  cstring($(nodeOs.tmpdir().to(cstring)) & "/ct-acp-git-"))).to(cstring))

setEnv(cstring"GIT_CONFIG_GLOBAL", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_SYSTEM", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")
setEnv(cstring"GIT_CEILING_DIRECTORIES", cstring(workspace))
for role in ["AUTHOR", "COMMITTER"]:
  setEnv(cstring("GIT_" & role & "_NAME"), cstring"ACP Git Test")
  setEnv(cstring("GIT_" & role & "_EMAIL"), cstring"acp-git@test.invalid")

proc git(cwd: string; args: varargs[string]): string =
  ## The suite's own git, for setup and the control — plain, deliberately:
  ## the control has to be a git that DOES refresh the index.
  var jsArgs: seq[cstring] = @[]
  for a in args: jsArgs.add cstring(a)
  $execFileRaw(cstring"git", jsArgs, cstring(cwd))

proc write(repo, name, content: string) =
  discard nodeFs.writeFileSync(cstring(repo & "/" & name), cstring(content))

proc indexInode(repo: string): int =
  nodeFs.statSync(cstring(repo & "/.git/index")).ino.to(int)

proc lockLeft(repo: string): bool =
  nodeFs.existsSync(cstring(repo & "/.git/index.lock")).to(bool)

const
  TabNewline = "tab\tand\nnewline.txt"

proc changedRepository(): string =
  ## A repository holding one file in each state the detection must tell
  ## apart, with its index's stat cache stale for `unchanged.txt`.
  result = workspace & "/repo"
  discard nodeFs.mkdirSync(cstring(result))
  discard git(result, "-c", "init.defaultBranch=main", "init", "-q", ".")
  write(result, ".gitignore", "*.log\n")
  write(result, "unchanged.txt", "same\n")
  write(result, "edited.txt", "before\n")
  write(result, "deleted.txt", "gone soon\n")
  write(result, "binary.dat", "\x00\x01binary")
  write(result, "old name.txt", "renamed\ncontent\nkept\nwhole\n")
  write(result, TabNewline, "odd name\n")
  discard git(result, "add", "-A")
  discard git(result, "commit", "-q", "-m", "one")
  # The stale stat cache: content unchanged, mtime years older than the
  # index (2001-09-09), so git must re-read the file to learn it is equal.
  discard nodeFs.utimesSync(cstring(result & "/unchanged.txt"),
                            1_000_000_000, 1_000_000_000)
  write(result, "edited.txt", "after\n")
  discard nodeFs.unlinkSync(cstring(result & "/deleted.txt"))
  write(result, "binary.dat", "\x00\x02binary")
  write(result, TabNewline, "odd name, edited\n")
  # A staged rename: `git diff HEAD` pairs the two paths.
  discard git(result, "mv", "old name.txt", "new name.txt")
  write(result, "fresh.txt", "untracked\n")
  write(result, "noise.log", "ignored\n")

proc runCases() =
  echo "[Suite] the agent pane's git change detection"
  let repo = changedRepository()
  let before = indexInode(repo)
  let outside = workspace & "/not-a-repository"
  discard nodeFs.mkdirSync(cstring(outside))
  let original = currentDir()
  chdir(cstring(repo))
  var listed: seq[string]
  try:
    listed = gitVisibleChanges().mapIt($it).sorted()
    let expected = @[
      "binary.dat", "deleted.txt", "edited.txt", "fresh.txt",
      "new name.txt", TabNewline].mapIt(repo & "/" & it).sorted()
    ck listed == expected,
       "lists exactly the changed and untracked files: " & $listed
    ck (repo & "/unchanged.txt") notin listed,
       "a file whose mtime alone moved is not listed"
    ck $gitFileAtHead(cstring(repo & "/edited.txt")) == "before\n",
       "gitFileAtHead reads the committed content"
    ck $gitFileAtHead(cstring(repo & "/fresh.txt")) == "",
       "gitFileAtHead of an untracked file is empty"
    ck indexInode(repo) == before, "the reads did not rewrite the index"
    ck not lockLeft(repo), "the reads left no index.lock"
    chdir(cstring(outside))
    ck gitVisibleChanges().len == 0, "outside a repository nothing is listed"
  finally:
    chdir(original)
  # The control: a plain git in the same repository does rewrite the index,
  # so it really was stale and the reads above had something to refresh.
  discard git(repo, "status", "--porcelain")
  ck indexInode(repo) != before,
     "control: a plain `git status` does rewrite this index"

const ExpectedChecks = 8

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
