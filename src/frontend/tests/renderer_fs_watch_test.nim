## renderer_fs_watch_test.nim
##
## THE MAIN PROCESS RUNS THE RENDERER'S WATCHES, AND THEY FIRE ON REAL
## CHANGES.
##
## The Electron renderer registers no filesystem watch of its own: the
## desktop's watchers live in the main process. The renderer's `fs.watch`
## therefore asks main (`CODETRACER::fs-watch`), and
## `index/renderer_fs_watch.nim` runs node's `fs.watch` and sends each change
## back (`CODETRACER::fs-watch-event`). The status bar's certificate indicator
## is the first consumer: its `.git` watch is how staging (`citIndexChanged`)
## and a commit (`citCommitChanged`) refresh it without waiting for its 15 s
## timer.
##
## ## The claims
##
##   1. `onFsWatch` on a repository's `.git` opens one watch, and `git add`
##      produces an event for that handle naming `index` (or git's
##      `index.lock`) — what `gitDirTrigger` reads as `citIndexChanged`.
##   2. `git commit` produces an event the trigger reads as a commit
##      (`citCommitChanged`: `HEAD`, a ref, `ORIG_HEAD`, `COMMIT_EDITMSG` and
##      the like).
##   3. A watch of the repository root reports a top-level file created there
##      as `fwkCreated`, with its full path.
##   4. Watching the same handle again replaces the watch rather than adding
##      a second one, and `onFsUnwatch` closes it: no event after.
##
## ## What is real, and the stand-in
##
## REAL: node's `fs.watch` over a repository this suite creates and `git`.
##
## THE SEND PATH, `electron_vars.mainWindow`, is a recorder: delivering to the
## window that asked is `window_routing`'s, held by
## `desktop_window_routing_test.nim`. Outside every window's context (as here)
## the relay sends through `mainWindow`.
##
## Every path is under one `mkdtemp` directory, git's global and system
## configuration point at a file that does not exist, and the directory is
## removed at the end.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, run under
## node.

import std/[asyncjs, jsffi]

import ../viewmodel/viewmodels/certificate_indicator_vm
import ../viewmodel/host/main_process_wire
import ../index/electron_vars
import ../index/renderer_fs_watch

proc exitProcess(code: int) {.importjs: "process.exit(#)".}
proc nodeRequire(module: cstring): JsObject {.importjs: "require(#)".}
proc setEnv(name, value: cstring) {.importjs: "process.env[#] = #".}
proc execGitRaw(args: seq[cstring]; cwd: cstring): cstring
  {.importjs: "require('child_process').execFileSync('git', #, {cwd: #, encoding: 'utf8'})".}
proc sleepMs(ms: int): Future[void] {.importjs:
  "new Promise(function (resolve) { setTimeout(resolve, #); })".}

const ExpectedChecks = 7

var checks = 0
var failedChecks = 0

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

var workspace = ""
var sent: seq[tuple[channel: string; payload: JsObject]] = @[]

proc git(cwd: string; args: varargs[string]) =
  var jsArgs: seq[cstring] = @[]
  for a in args: jsArgs.add cstring(a)
  discard execGitRaw(jsArgs, cstring(cwd))

proc writeText(path, text: string) =
  discard nodeRequire("fs").writeFileSync(cstring(path), cstring(text))

proc waitFor(pred: proc(): bool; ms: int): Future[bool] {.async.} =
  var waited = 0
  while not pred() and waited < ms:
    await sleepMs(20)
    waited += 20
  return pred()

proc eventFor(handle: string; matches: proc(path, kind: string): bool): bool =
  for entry in sent:
    if entry.channel == FsWatchEventChannel and
       $entry.payload[cstring"handle"].to(cstring) == handle and
       matches($entry.payload[cstring"path"].to(cstring),
               $entry.payload[cstring"kind"].to(cstring)):
      return true
  false

proc runCases() {.async.} =
  mainWindow = JsObject{webContents: JsObject{}}
  mainWindow.webContents.send = proc(channel: cstring; payload: JsObject) =
    sent.add((channel: $channel, payload: payload))

  let repo = $nodeRequire("fs").realpathSync(cstring(workspace)).to(cstring) & "/repo"
  discard nodeRequire("fs").mkdirSync(cstring(repo))
  git(repo, "init", "-q", ".")
  writeText(repo & "/a.txt", "alpha\n")
  git(repo, "add", "-A")
  git(repo, "commit", "-q", "-m", "initial")

  echo "[Suite] the renderer's .git watch fires on staging and on a commit"
  await onFsWatch(nil, JsObject{handle: cstring"h-git",
                                path: cstring(repo & "/.git"), recursive: false})
  ck activeRendererWatches() == 1, "onFsWatch opened one watch"
  writeText(repo & "/b.txt", "beta\n")
  git(repo, "add", "b.txt")
  ck await waitFor(proc(): bool = eventFor("h-git",
       proc(path, kind: string): bool = gitDirTrigger(path) == citIndexChanged),
       5_000),
     "git add: an event naming the index arrived for the handle (citIndexChanged)"
  sent = @[]
  git(repo, "commit", "-q", "-m", "second")
  ck await waitFor(proc(): bool = eventFor("h-git",
       proc(path, kind: string): bool = gitDirTrigger(path) == citCommitChanged),
       5_000),
     "git commit: an event the trigger reads as a commit (citCommitChanged)"

  echo "[Suite] the root's watch reports a created file; a handle is one watch"
  await onFsWatch(nil, JsObject{handle: cstring"h-root",
                                path: cstring(repo), recursive: false})
  await onFsWatch(nil, JsObject{handle: cstring"h-root",
                                path: cstring(repo), recursive: false})
  ck activeRendererWatches() == 2, "watching a handle again replaces its watch"
  sent = @[]
  writeText(repo & "/c.txt", "gamma\n")
  ck await waitFor(proc(): bool = eventFor("h-root",
       proc(path, kind: string): bool =
         path == repo & "/c.txt" and kind == "fwkCreated"), 5_000),
     "a top-level file created: fwkCreated, with its full path"

  await onFsUnwatch(nil, JsObject{handle: cstring"h-git"})
  await onFsUnwatch(nil, JsObject{handle: cstring"h-root"})
  ck activeRendererWatches() == 0, "onFsUnwatch closed both"
  sent = @[]
  writeText(repo & "/d.txt", "delta\n")
  git(repo, "add", "d.txt")
  await sleepMs(300)
  ck sent.len == 0, "no event after the watches were stopped"

proc main() {.async.} =
  workspace = $(nodeRequire("fs").mkdtempSync(cstring(
    $(nodeRequire("os").tmpdir().to(cstring)) & "/ct-renderer-fs-watch-")).to(cstring))
  setEnv(cstring"GIT_CONFIG_GLOBAL", cstring(workspace & "/absent-gitconfig"))
  setEnv(cstring"GIT_CONFIG_SYSTEM", cstring(workspace & "/absent-gitconfig"))
  setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")
  setEnv(cstring"GIT_CEILING_DIRECTORIES", cstring(workspace))
  for role in ["AUTHOR", "COMMITTER"]:
    setEnv(cstring("GIT_" & role & "_NAME"), cstring"Renderer Watch Test")
    setEnv(cstring("GIT_" & role & "_EMAIL"), cstring"watch@test.invalid")
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

discard main()
