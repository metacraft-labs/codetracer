## host/file_worker.nim — PLAT-29: the thread file reads and writes run on.
##
## The outside half of `app/file_io_producer`: jobs in, answers out, and a
## byte on the shared wake pipe (`HighlightWorker.wakeWriteFd`) so the input
## loop draws an answer when it arrives.
##
## ## In order, and never dropped
##
## Unlike the highlighter's worker, this one does NOT coalesce: two `:w`s are
## two writes, and a reload after a write must read what the write left. Jobs
## run in submission order, and `stop` queues behind them — so a `:w` followed
## at once by a quit still reaches the disk before the thread is joined.
##
## ## No mocks
##
## The reads and writes are `host/edit_host`'s `readProjectFile` /
## `writeProjectFile`, with their containment and size rules, on real files.

import std/posix

import ../app/file_io_producer
import ./edit_host
import ./native_host

type
  FileMsg = object
    stop: bool
    job: FileJob

  FileChannels = object
    jobs: Channel[FileMsg]
    results: Channel[FileJobResult]
    wakeWrite: cint
    root: string

  FileWorker* = ref object
    chans: ptr FileChannels
    thread: Thread[ptr FileChannels]
    running: bool

proc fileLoop(ch: ptr FileChannels) {.thread.} =
  while true:
    let msg = ch.jobs.recv()
    if msg.stop: break
    var res = FileJobResult(job: msg.job)
    {.cast(gcsafe).}:
      try:
        case msg.job.kind
        of fjRead:
          res.text = readProjectFile(ch.root, msg.job.path)
        of fjWrite:
          writeProjectFile(ch.root, msg.job.path, msg.job.text)
        res.ok = true
      except TuiHostError as e:
        res.message = e.msg
    ch.results.send(res)
    var one = 'f'
    discard posix.write(ch.wakeWrite, addr one, 1)

proc startFileWorker*(root: string; wakeWrite: cint): FileWorker =
  ## `wakeWrite` is the write end of the loop's wake pipe — the highlight
  ## worker's (`HighlightWorker.wakeWriteFd`), so one fd wakes the loop for
  ## both.
  result = FileWorker(running: true)
  result.chans = cast[ptr FileChannels](allocShared0(sizeof(FileChannels)))
  result.chans.jobs.open()
  result.chans.results.open()
  result.chans.wakeWrite = wakeWrite
  result.chans.root = root
  createThread(result.thread, fileLoop, result.chans)

proc submit*(w: FileWorker; job: FileJob) =
  if w.isNil or not w.running: return
  w.chans.jobs.send(FileMsg(stop: false, job: job))

proc drain*(w: FileWorker): seq[FileJobResult] =
  ## Every answer that has arrived, in order. Never blocks. The wake pipe is
  ## emptied by the highlight worker's `drain`, which the loop calls too.
  if w.isNil or not w.running: return @[]
  while true:
    let (got, res) = w.chans.results.tryRecv()
    if not got: break
    result.add res

proc stop*(w: FileWorker) =
  ## Finish every job already submitted, then stop. Idempotent.
  if w.isNil or not w.running: return
  w.running = false
  w.chans.jobs.send(FileMsg(stop: true))
  joinThread(w.thread)
  w.chans.jobs.close()
  w.chans.results.close()
  w.chans.root = ""
  deallocShared(w.chans)
