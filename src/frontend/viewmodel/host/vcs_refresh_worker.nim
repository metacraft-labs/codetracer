## viewmodel/host/vcs_refresh_worker.nim — the VCS pane's repository read, on a
## thread of its own.
##
## The native front-ends (the terminal, the GPUI window) refreshed their VCS
## pane on the input loop: `git status --porcelain=v2 --branch` and `git log`
## to completion, at open, every refresh interval and on every focus regain.
## Whatever git took, the front-end was frozen for — 70 s on a loaded machine
## in a large checkout, with every key typed in that time unread
## (codetracer-pm issue 2026-11-17, "The terminal front-end stops reading
## input while its VCS pane runs git").
##
## The read now runs here: `request` hands it a directory and a commit count,
## the thread runs git (`native_vcs.runGit`, no futures and no closures shared
## with the loop), and `take` gives the loop the finished read to apply with
## `vcs_vm.applyRefreshRead` — the same apply the synchronous
## `refreshFromFacade` runs, so the pane shows exactly what it did, later.
##
## ONE READ AT A TIME, THE LATEST WINS. A request made while a read is running
## is remembered and run when that one finishes; a second such request
## replaces the first. The loop applies only the newest finished read, so a
## burst of focus regains costs one extra read, not a queue of them.

import std/[posix, strutils]

import ./native_vcs
import ../viewmodels/vcs_vm

type
  RefreshJob = object
    stop: bool
    directory: string
    commitCount: int

  RefreshChannels = object
    jobs: Channel[RefreshJob]
    reads: Channel[VcsRefreshRead]
    wakeWrite: cint

  VcsRefreshWorker* = ref object
    chans: ptr RefreshChannels
    thread: Thread[ptr RefreshChannels]
    running: bool
    busy: bool
      ## A read has been handed to the thread and has not come back.
    pending: bool
    pendingJob: RefreshJob
      ## The newest request made while `busy`.

var detached: seq[VcsRefreshWorker]
  ## Workers stopped while a read ran (`stop`): kept here, never freed, so a
  ## thread still finishing its git never runs in freed memory. At most one per
  ## pane closed mid-read, for the life of the process.

proc readNative*(directory: string; commitCount: int): VcsRefreshRead =
  ## `vcs_vm.readRepository`'s read, with the system git called directly — the
  ## three commands the facade runs, in the same order, read by the same
  ## parsers (`parsePorcelainV2`, `parseGitLog`).
  result = VcsRefreshRead(directory: directory, commitCount: commitCount)
  if directory.len == 0:
    return
  let inside = runGit(directory, @["rev-parse", "--is-inside-work-tree"])
  result.repository = inside.ok and inside.value.strip() == "true"
  if not result.repository:
    return
  let status = runGit(directory, @["status", "--porcelain=v2", "--branch"])
  if not status.ok:
    result.status = failed[VcsStatus](status.error)
    return
  result.status = succeeded(parsePorcelainV2(status.value))
  let log = runGit(directory, @["log", "--max-count=" & $commitCount,
                                GitLogFormat])
  result.log =
    if log.ok: succeeded(parseGitLog(log.value))
    else: failed[seq[VcsCommit]](log.error)

proc refreshLoop(ch: ptr RefreshChannels) {.thread.} =
  while true:
    let job = ch.jobs.recv()
    if job.stop: break
    var read: VcsRefreshRead
    {.cast(gcsafe).}:
      read = readNative(job.directory, job.commitCount)
    ch.reads.send(read)
    if ch.wakeWrite >= 0:
      var one = 'v'
      discard posix.write(ch.wakeWrite, addr one, 1)

proc startVcsRefreshWorker*(wakeWrite: cint = -1): VcsRefreshWorker =
  ## `wakeWrite`, when given, is the write end of the loop's wake pipe: a byte
  ## is written there when a read finishes, so the loop applies it at once
  ## instead of on its next idle tick.
  result = VcsRefreshWorker(running: true)
  result.chans = cast[ptr RefreshChannels](allocShared0(sizeof(RefreshChannels)))
  result.chans.jobs.open()
  result.chans.reads.open()
  result.chans.wakeWrite = wakeWrite
  createThread(result.thread, refreshLoop, result.chans)

proc busy*(w: VcsRefreshWorker): bool =
  ## Whether a read is running or waiting to run.
  not w.isNil and (w.busy or w.pending)

proc request*(w: VcsRefreshWorker; directory: string; commitCount: int) =
  ## Read `directory` away from the caller. Never blocks.
  if w.isNil or not w.running: return
  let job = RefreshJob(directory: directory, commitCount: commitCount)
  if w.busy:
    w.pending = true
    w.pendingJob = job
  else:
    w.busy = true
    w.chans.jobs.send(job)

proc take*(w: VcsRefreshWorker; read: var VcsRefreshRead): bool =
  ## The newest finished read, if one has come back since the last call; a
  ## remembered request starts as the running one finishes. Never blocks.
  if w.isNil or not w.running: return false
  while true:
    let (got, r) = w.chans.reads.tryRecv()
    if not got: break
    read = r
    result = true
  if result:
    w.busy = false
    if w.pending:
      w.pending = false
      w.busy = true
      w.chans.jobs.send(w.pendingJob)

proc stop*(w: VcsRefreshWorker) =
  ## Stop the thread. Idempotent, and NEVER WAITS FOR GIT: quitting while a
  ## slow read runs must not freeze the front-end for as long as git takes,
  ## which is the defect this module exists for. With no read running the
  ## thread is joined and its channels freed; with one running it is told to
  ## stop after it and left to finish on its own, its channels kept for the
  ## read it will still send (the process is ending, or the pane closing).
  if w.isNil or not w.running: return
  w.running = false
  w.pending = false
  w.chans.jobs.send(RefreshJob(stop: true))
  if w.busy:
    # The thread outlives this call, so its `Thread` object and channels must
    # too: a worker dropped by its caller would otherwise be freed with the
    # thread still running in it (measured: a SIGSEGV when the read finished).
    detached.add w
    return
  joinThread(w.thread)
  w.chans.jobs.close()
  w.chans.reads.close()
  deallocShared(w.chans)
