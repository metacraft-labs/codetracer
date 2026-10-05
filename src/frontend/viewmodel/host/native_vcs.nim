## native_vcs.nim — the VCS facade over the system `git`, for a NATIVE
## process: the desktop's native instantiation (`desktop_native.nim`) and the
## terminal's and GPUI's VCS panes (PLAT-47 deliverable 4), which need this one
## facade and nothing else of the desktop's.
##
## Moved out of `desktop_native.nim` unchanged (its `ProcessFacade` parameter
## was never read), so a front-end can link git without linking the whole
## desktop platform — the terminal measured 346 KB for the latter.
##
## Synchronous internally, which is honest: the desktop's git IS a synchronous
## subprocess. The facade's async signature is preserved by the callers.

import std/[os, osproc, streams, strutils]

import ../platform/outcome
import ../platform/capabilities
import ../platform/vcs

export vcs

const NativeVcsProfile* = PlatformProfile(
  kind: pkDesktop,
  displayName: "native git",
  capabilities: {capVcsRead, capVcsWrite, capVcsRemote})
  ## A profile for a front-end that uses this facade on its own.

proc nativeVcs*(profile: PlatformProfile): VcsFacade =
  ## The VCS facade over the system `git`, for every native process.
  result = unavailableVcs(profile)

  proc git(repository: string; args: seq[string]): PlatformOutcome[string] =
    ## Synchronous internally, which is honest: the desktop's git IS a
    ## synchronous subprocess. The facade's async signature is preserved by the
    ## callers below, which is where the contract lives.
    try:
      let child = startProcess("git", workingDir = repository, args = args,
                               options = {poUsePath})
      # READ BEFORE WAITING. A child that writes more than a pipe holds (64 KiB
      # on Linux) blocks until someone reads, so `waitForExit` first never
      # returns: `git log --max-count=50` with commit bodies is well past that
      # on an ordinary repository, and a front-end opened in one hung at
      # start. stdout is drained to EOF first (git's stderr is a few lines),
      # then stderr, then the exit code.
      let output = child.outputStream.readAll()
      let errText = child.errorStream.readAll()
      let code = child.waitForExit()
      child.close()
      if code != 0:
        failed[string](pkFailed, "git " & args.join(" ") & " failed", errText)
      else:
        succeeded(output)
    except CatchableError as err:
      failed[string](pkNotFound, "git is not available", err.msg)

  result.isRepository = proc(path: string): PlatformFuture[PlatformOutcome[bool]] =
    let res = git(path, @["rev-parse", "--is-inside-work-tree"])
    resolvedOk(res.ok and res.value.strip() == "true")

  result.repositoryRoot = proc(path: string): PlatformFuture[PlatformOutcome[string]] =
    let res = git(path, @["rev-parse", "--show-toplevel"])
    if res.ok: resolvedOk(res.value.strip())
    else: resolved(failed[string](res.error))

  result.status = proc(repository: string): PlatformFuture[PlatformOutcome[VcsStatus]] =
    let res = git(repository, @["status", "--porcelain=v2", "--branch"])
    if not res.ok:
      return resolved(failed[VcsStatus](res.error))
    resolvedOk(parsePorcelainV2(res.value))

  result.log = proc(repository: string; maxCount: int;
                    path: string): PlatformFuture[PlatformOutcome[seq[VcsCommit]]] =
    var args = @["log", "--max-count=" & $maxCount,
                 "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b%x1e"]
    if path.len > 0:
      args.add "--"
      args.add path
    let res = git(repository, args)
    if not res.ok:
      return resolved(failed[seq[VcsCommit]](res.error))
    var commits: seq[VcsCommit] = @[]
    for record in res.value.split('\x1e'):
      let trimmed = record.strip()
      if trimmed.len == 0: continue
      let f = trimmed.split('\x1f')
      if f.len < 8: continue
      var authoredAt: int64 = 0
      try: authoredAt = parseBiggestInt(f[5]) * 1000
      except ValueError: discard
      commits.add VcsCommit(
        id: f[0], shortId: f[1],
        parents: if f[2].len > 0: f[2].split(' ') else: @[],
        authorName: f[3], authorEmail: f[4], authoredAtMs: authoredAt,
        subject: f[6], body: f[7])
    resolvedOk(commits)

  result.readBlob = proc(repository, path: string;
                         source: VcsBlobSource): PlatformFuture[PlatformOutcome[string]] =
    case source
    of vbsWorkingTree:
      try: resolvedOk(readFile(repository / path))
      except CatchableError as err:
        resolvedErr[string](pkNotFound, "no working-tree copy of " & path, err.msg)
    of vbsIndex:
      let res = git(repository, @["show", ":" & path])
      if res.ok: resolvedOk(res.value) else: resolved(failed[string](res.error))
    of vbsHead:
      let res = git(repository, @["show", "HEAD:" & path])
      if res.ok: resolvedOk(res.value) else: resolved(failed[string](res.error))

  result.readBlobAt = proc(repository, path,
                           revision: string): PlatformFuture[PlatformOutcome[string]] =
    let res = git(repository, @["show", revision & ":" & path])
    if res.ok: resolvedOk(res.value) else: resolved(failed[string](res.error))

  result.diff = proc(repository: string; paths: seq[string]; staged: bool;
                     contextLines: int): PlatformFuture[PlatformOutcome[string]] =
    var args = @["diff", "--unified=" & $contextLines]
    if staged: args.add "--cached"
    if paths.len > 0:
      args.add "--"
      for p in paths: args.add p
    let res = git(repository, args)
    if res.ok: resolvedOk(res.value) else: resolved(failed[string](res.error))

  result.stage = proc(repository: string;
                      paths: seq[string]): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(repository, @["add", "--"] & paths)
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))

  result.unstage = proc(repository: string;
                        paths: seq[string]): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(repository, @["restore", "--staged", "--"] & paths)
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))

  result.discardChanges = proc(repository: string;
                               paths: seq[string]): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(repository, @["restore", "--"] & paths)
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))

  result.applyPatch = proc(repository, patch: string;
                           reverse: bool): PlatformFuture[PlatformOutcome[Nothing]] =
    try:
      var args = @["apply"]
      if reverse: args.add "--reverse"
      args.add "-"
      let child = startProcess("git", workingDir = repository, args = args,
                               options = {poUsePath})
      child.inputStream.write(patch)
      child.inputStream.close()
      # Drained before waiting, for the reason `git` above gives.
      discard child.outputStream.readAll()
      let errText = child.errorStream.readAll()
      let code = child.waitForExit()
      child.close()
      if code == 0: resolvedOk()
      else: resolvedErr[Nothing](pkConflict, "the patch did not apply", errText)
    except CatchableError as err:
      resolvedErr[Nothing](pkFailed, "applying the patch failed", err.msg)

  result.commit = proc(repository, message, authorName,
                       authorEmail: string): PlatformFuture[PlatformOutcome[VcsCommit]] =
    var args = @["commit", "-m", message]
    if authorName.len > 0 and authorEmail.len > 0:
      args.add "--author=" & authorName & " <" & authorEmail & ">"
    let res = git(repository, args)
    if not res.ok:
      return resolved(failed[VcsCommit](res.error))
    let head = git(repository, @["rev-parse", "HEAD"])
    if not head.ok:
      return resolved(failed[VcsCommit](head.error))
    resolvedOk(VcsCommit(id: head.value.strip(), subject: message))

  result.initRepository = proc(path: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(path, @["init", "-q"])
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))

  result.fetch = proc(repository, remote: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(repository, @["fetch", remote])
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))

  result.push = proc(repository, remote,
                     refspec: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(repository, @["push", remote, refspec])
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))
