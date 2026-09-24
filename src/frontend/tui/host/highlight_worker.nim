## host/highlight_worker.nim — PLAT-29: the thread the Edit pane's syntax
## parse runs on.
##
## Editor-ViewModel.md §11: tree-sitter re-parse and re-highlight *"sit
## outside, compute against a version, and are reconciled or discarded when
## stale"*. `app/syntax/highlight_producer` is the inside half — the request,
## the parse function, the reconciliation — and starts no thread, because
## `app/` is the SDK-consuming half of this front-end and owns no process
## resources. This is the outside half: ONE worker thread, a request channel,
## a result channel, and a self-pipe that wakes the input loop when an answer
## is ready.
##
## ## Coalescing
##
## The worker parses only the NEWEST request waiting when it becomes free.
## Every keystroke makes a request; a parse slower than the typing would
## otherwise fall further behind with each one, answering for versions the
## user left long ago. Skipping to the newest is what keeps it one parse
## behind at most — and the parses it does finish for older versions are the
## ones `reconcile` maps or drops, which is what makes reconciliation observed
## in a real session rather than simulated.
##
## ## No mocks
##
## `computeHighlight` is the shipped parse (`isonim_tui`'s tree-sitter over
## the vendored grammars, or the lexical fallback). Nothing here stubs it.

import std/posix

import ../app/syntax/highlight_producer

type
  WorkerMsg = object
    stop: bool
    req: HighlightRequest

  WorkerChannels = object
    requests: Channel[WorkerMsg]
    results: Channel[HighlightResult]
    wakeWrite: cint

  HighlightWorker* = ref object
    ## A running worker. `stop` it; a worker that is never stopped keeps a
    ## thread alive past the loop that owned it.
    chans: ptr WorkerChannels
    thread: Thread[ptr WorkerChannels]
    wakeRead*: cint
      ## Readable when at least one result is waiting. Hand it to
      ## `TerminalDriver.auxWakeFd`; `drain` empties it.
    running: bool
    submitted*: int
    delivered*: int

proc workerLoop(ch: ptr WorkerChannels) {.thread.} =
  while true:
    var msg = ch.requests.recv()
    # THE NEWEST REQUEST WINS — see the header.
    while not msg.stop:
      let (got, next) = ch.requests.tryRecv()
      if not got: break
      msg = next
    if msg.stop: break
    {.cast(gcsafe).}:
      let res = computeHighlight(msg.req)
    ch.results.send(res)
    var one = 'h'
    discard posix.write(ch.wakeWrite, addr one, 1)

proc startHighlightWorker*(): HighlightWorker =
  var fds: array[2, cint]
  if posix.pipe(fds) != 0:
    raise newException(OSError, "highlight worker: pipe() failed")
  # Non-blocking read end: `drain` empties it without waiting.
  discard fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) or O_NONBLOCK)
  result = HighlightWorker(wakeRead: fds[0], running: true)
  result.chans = cast[ptr WorkerChannels](allocShared0(sizeof(WorkerChannels)))
  result.chans.requests.open()
  result.chans.results.open()
  result.chans.wakeWrite = fds[1]
  createThread(result.thread, workerLoop, result.chans)

proc wakeWriteFd*(w: HighlightWorker): cint =
  ## The wake pipe's write end, for another worker to share
  ## (`host/file_worker`): one fd wakes the loop for both.
  w.chans.wakeWrite

proc submit*(w: HighlightWorker; req: HighlightRequest) =
  if w.isNil or not w.running: return
  inc w.submitted
  w.chans.requests.send(WorkerMsg(stop: false, req: req))

proc drain*(w: HighlightWorker): seq[HighlightResult] =
  ## Every result that has arrived, in arrival order, and the wake pipe
  ## emptied. Never blocks.
  if w.isNil or not w.running: return @[]
  var buf: array[64, char]
  while posix.read(w.wakeRead, addr buf[0], buf.len) > 0: discard
  while true:
    let (got, res) = w.chans.results.tryRecv()
    if not got: break
    inc w.delivered
    result.add res

proc stop*(w: HighlightWorker) =
  ## Stop the thread and release everything. Idempotent.
  if w.isNil or not w.running: return
  w.running = false
  w.chans.requests.send(WorkerMsg(stop: true))
  joinThread(w.thread)
  w.chans.requests.close()
  w.chans.results.close()
  discard posix.close(w.chans.wakeWrite)
  discard posix.close(w.wakeRead)
  deallocShared(w.chans)
