## `vcs_refresh_worker`: the VCS pane's repository read, away from the caller.
##
## codetracer-pm issue 2026-11-17, "The terminal front-end stops reading input
## while its VCS pane runs git". Deterministic, with no timing: a `git` first
## on `PATH` holds `status` and `log` until the case creates a release file,
## so "the caller was not held" is shown by the caller getting control back
## while git provably has not answered, not by a measured duration.
##
## No mocks of the product: the shipped worker, a
## real repository, the real git behind a gate.

import std/[monotimes, os, osproc, strutils, tempfiles, times, unittest]

import ../../viewmodel/host/vcs_refresh_worker
import ../../viewmodel/viewmodels/vcs_vm

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 14

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while not fileExists(dir / "justfile"):
    dir = dir.parentDir
  dir

proc fixtureRepo(): string =
  result = createTempDir("vcs-worker-", "") / "repo"
  let (output, code) = execCmdEx("bash " &
    quoteShell(repoRoot() / "scripts" / "plat47-vcs-fixture.sh") & " " &
    quoteShell(result))
  if code != 0:
    checkpoint(output)
  doAssert code == 0

proc gateGit(dir, release: string) =
  ## `git` held on `status` and `log` until `release` exists, first on PATH.
  let real = findExe("git")
  doAssert real.len > 0, "git is not on PATH"
  createDir(dir)
  writeFile(dir / "git", "#!/bin/sh\n" &
    "case \" $* \" in\n" &
    "  *\" status \"*|*\" log \"*)\n" &
    "    while [ ! -e " & quoteShell(release) & " ]; do sleep 0.05; done ;;\n" &
    "esac\n" &
    "exec " & quoteShell(real) & " \"$@\"\n")
  setFilePermissions(dir / "git", {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("PATH", dir & ":" & getEnv("PATH"))

proc takeWithin(w: VcsRefreshWorker; read: var VcsRefreshRead;
                timeoutMs = 60000): bool =
  ## A STATE's ceiling, generous for a loaded host.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if w.take(read):
      return true
    sleep(20)
  false

let repo = fixtureRepo()
let scratch = repo.parentDir
let release = scratch / "release-git"
gateGit(scratch / "bin", release)

suite "the VCS read runs away from its caller":

  test "request returns while git is held; the read arrives when git answers":
    let w = startVcsRefreshWorker()
    w.request(repo, 10)
    # Back here with git held: the request did not wait for it.
    ck not fileExists(release)
    ck w.busy
    var read: VcsRefreshRead
    ck not w.take(read)
    writeFile(release, "")
    ck w.takeWithin(read)
    ck read.directory == repo
    ck read.repository
    ck read.status.ok
    ck read.log.ok and read.log.value.len > 0
    ck not w.busy
    w.stop()
    removeFile(release)

  test "requests made while a read runs come to one more read, the newest":
    let w = startVcsRefreshWorker()
    w.request(repo, 1)
    w.request(repo, 2)
    w.request(repo, 3)
    writeFile(release, "")
    var first, second: VcsRefreshRead
    ck w.takeWithin(first)
    ck first.commitCount == 1
    ck w.takeWithin(second)
    ck second.commitCount == 3
    w.stop()
    removeFile(release)

  test "stop does not wait for a held git":
    let w = startVcsRefreshWorker()
    w.request(repo, 10)
    w.stop()
    # Back here with git still held: `stop` did not join a running read.
    ck not fileExists(release)
    writeFile(release, "")

  test "assertion count":
    check countedAssertions == ExpectedAssertions
    removeDir(scratch)
