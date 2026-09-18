## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI.
## See `host/native_host.nim`'s header.
##
## host/build_runner.nim — PLAT-16. The process behind `:build` and `:run`, and
## the two bounds that make it cancellable.
##
## ## WHY THIS IS A POLL AND NOT A BLOCKING WAIT
##
## CodeTracer-TUI-Edit-Mode.md §5: *"A recording takes time, and the TUI must
## stay responsive while it does. This is the one place Edit mode meets the
## campaign's hardest-won lesson: CTUI-14 found that a stalled DAP handshake
## hung **after** the alt screen was claimed, with `Ctrl+c` unable to break out
## because `cfmakeraw` had cleared `ISIG` before the input loop started. A build
## that hangs must be cancellable. `DapReadBound`'s clock-and-interrupt pattern
## is the precedent and the requirement."*
##
## A `waitForExit` would reproduce that defect exactly: the alternate screen is
## already claimed by the time `:build` is typed, `ISIG` is already cleared, and
## a blocked host cannot read the key that would cancel. So `startBuild` returns
## immediately and `pollBuild` is called from the SAME event loop that reads the
## keyboard — which means the cancel key is read while the compiler runs, and
## the clock is checked on every idle tick for the session nobody is watching.
##
## BOTH BOUNDS, not one, and for the two different users `build_session.nim`
## names: `BuildSession.deadlineMs` covers an unattended session and
## `BuildSession.cancelRequested` covers an attended one.
##
## ## THE PIPE IS READ AS A DESCRIPTOR, AND THAT IS WHAT MAKES THE SENTENCE
## ## ABOVE TRUE
##
## The first version of this module read the child through
## `osproc.outputStream` — a `Stream` — and bounded the read by COUNTING BYTES
## (`MaxBytesPerPoll`), with a docstring claiming it therefore did not block.
## **That claim was false, and PLAT-16's landing pass measured it:**
##
## ```
## --- a child SILENT for 3s, then printing one line and exiting ---
## verdict after start: running
##   poll 1: 3005 ms  changed=true  verdict=succeeded
## first poll took 3005 ms
## polls returning false while still running: 0
## ```
##
## On POSIX `osproc.outputStream` is a C `FILE*` (`createStream(p.outHandle,
## fmRead)`), `atEnd` is `feof` — false until a read has already hit EOF — and
## `readChar` is `fgetc`, which BLOCKS on an open pipe with nothing in it. A
## byte bound cannot fire when the first byte never arrives, so a build that
## was silent for N seconds froze the whole front-end for N seconds: no key
## read, no repaint, and `:cancel` unreachable — which is CTUI-14's defect
## reproduced inside the module whose header cites CTUI-14 as its reason to
## exist. `deadlineMs` could not save it either: it is only tested on RE-ENTRY
## to `pollBuild`, and the loop was inside the read.
##
## So the descriptor is read directly (`p.outputHandle`), with `O_NONBLOCK` set
## on it once at spawn, and **this module owns the buffer** — which is exactly
## the remedy `Verification-Harness-Traps.md` §8 states for the same standard
## library: *"read the descriptor directly and serve every consumer out of one
## buffer the module can look in; then 'the pipe is empty' and 'there is
## nothing to read' are the same statement."* `read(2)` on an `O_NONBLOCK`
## descriptor answers `EAGAIN` rather than sleeping, so "nothing to read right
## now" is a RETURN and not a wait.
##
## ONE MECHANISM AND NOT TWO. A `select()` in front of the read would be a
## second guard over the same property, and §32a prices that: two mechanisms
## guarding one property silently halve the mutation coverage unless each gets
## evidence only it can produce. `O_NONBLOCK` is the whole guarantee, it is one
## line, and `tests/test_build_runner_process.nim` kills the arm that removes
## it with a real child that says nothing for three seconds.
##
## ## WHAT IS AND IS NOT DECIDED HERE
##
## The VERDICT is `app/build_session.nim`'s: this module reports an exit code
## and `finish` decides what it means, so "cancelled" and "failed" are
## distinguished in one place. This module owns the process, the pipe and the
## kill.

import std/[osproc, posix, strutils, times]

import ../app/build_session
import ./native_host

export TuiHostError

const
  MaxBytesPerPoll* = 64 * 1024
    ## How much output one ordinary poll moves into the session.
    ##
    ## A WORK BOUND, and it is no longer doing the job the first version asked
    ## of it. It is not what stops this module blocking — `O_NONBLOCK` is (see
    ## the module header) — it is what stops a compiler emitting megabytes from
    ## starving the keyboard inside a single tick. Bounding the WORK rather
    ## than the TIME is deliberate: a time bound would make the frame rate
    ## depend on how fast the compiler writes.

  MaxBytesAtExit* = 4 * 1024 * 1024
    ## The bound for the FINAL drain, after the child has exited.
    ##
    ## Larger than the per-poll bound because there is no keyboard to starve:
    ## the process is gone, everything it ever wrote is already in the pipe,
    ## and the loop ends at `EAGAIN` — so this bounds a pathological case
    ## rather than an ordinary one. Without a second, larger drain a build
    ## whose last act was to print more than `MaxBytesPerPoll` would have its
    ## tail dropped when `finish` closed the descriptor.

  ReadChunkBytes = 4096
    ## One `read(2)` at a time. Big enough that a chatty compiler is a few
    ## syscalls per tick, small enough that the buffer is not a pane's worth
    ## of memory per build.

type
  RunningBuild* = ref object
    ## A started process and the session it reports into.
    session*: BuildSession
    process: Process
    fd: cint
      ## The child's stdout/stderr pipe, as a DESCRIPTOR. See the module
      ## header: it is deliberately not an `osproc` `Stream`, because that is a
      ## `FILE*` whose reads block on an open pipe.
      ##
      ## `-1` once the pipe has been closed with the process. Never closed
      ## here: `osproc.close` owns it (`outputHandle`'s own warning), and this
      ## module reaching for it would be a double close.
    pending: string
      ## Bytes read but not yet terminated by a newline. Held so a line split
      ## across two reads is ONE line in the pane rather than two — the same
      ## framing problem `nim-libvterm`'s UTF-8 straddle was, one layer up.
    sawEof: bool
      ## Whether `read` has answered 0 — the write end is closed and there will
      ## never be another byte. Distinct from "nothing to read right now"
      ## (`EAGAIN`), which is the state a silent build is in for most of its
      ## life, and conflating the two is precisely what the `FILE*` did.
    killed: bool

proc shellCommandFor*(kind: BuildKind; command: string): (string, seq[string]) =
  ## The argv for `command`.
  ##
  ## RUN THROUGH `sh -c`, deliberately: a build command is a thing a user types
  ## and it contains pipes, `&&` and quoted arguments. Splitting it here would
  ## be a second, worse shell, and refusing those forms would refuse most real
  ## build commands. `kind` is carried for the caller's message and does not
  ## change the argv.
  discard kind
  ("/bin/sh", @["-c", command])

proc startBuild*(kind: BuildKind; command: string; workingDir: string;
                 nowMs: int64;
                 deadlineMs = DefaultBuildDeadlineMs): RunningBuild =
  ## Start `command` in `workingDir` and return immediately.
  ##
  ## `poParentStreams` is NOT used: the child's output must reach a PANE, and a
  ## child writing onto the inherited terminal would paint over the alternate
  ## screen the front-end owns — visibly, and in a way no repaint can undo
  ## because the front-end does not know it happened.
  let s = newBuildSession(kind, command, nowMs, deadlineMs)
  let (exe, args) = shellCommandFor(kind, command)
  var p: Process
  try:
    p = startProcess(exe, workingDir = workingDir, args = args,
                     options = {poStdErrToStdOut, poUsePath})
  except OSError as e:
    s.start(nowMs)
    s.appendLine("could not start: " & e.msg)
    s.finish(127)
    return RunningBuild(session: s, process: nil, fd: -1, pending: "",
                        sawEof: true, killed: false)
  s.start(nowMs)
  # `outputHandle` AND NOT `outputStream`, and the descriptor is put into
  # non-blocking mode HERE — once, at the only place that owns the process —
  # rather than in `drain`, which would re-`fcntl` on every idle tick. See the
  # module header for the measurement that made this the shape.
  #
  # A FAILED `fcntl` IS REPORTED AS OUTPUT rather than swallowed: the build
  # still runs and is still cancellable through the deadline, but a reader of
  # the pane has to be able to tell "this compiler is quiet" from "this
  # front-end is about to stall on it".
  let fd = p.outputHandle
  let flags = fcntl(fd, F_GETFL, 0)
  if flags == -1 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) == -1:
    s.appendLine("— could not make the output pipe non-blocking;" &
                 " this build may not be interruptible —")
  RunningBuild(session: s, process: p, fd: fd, pending: "", sawEof: false,
               killed: false)

proc kill(rb: RunningBuild) =
  if rb.isNil or rb.process.isNil or rb.killed:
    return
  rb.killed = true
  try:
    rb.process.terminate()
  except OSError:
    discard

proc absorb(rb: RunningBuild; chunk: string; count: int) =
  ## Split `count` bytes of `chunk` into lines, carrying a straddling one.
  for i in 0 ..< count:
    let c = chunk[i]
    if c == '\n':
      rb.session.appendLine(rb.pending.strip(leading = false, trailing = true))
      rb.pending = ""
    else:
      rb.pending.add c

proc drain(rb: RunningBuild; maxBytes = MaxBytesPerPoll): int =
  ## Move whatever the child has written SO FAR into the session, and return
  ## how many bytes that was.
  ##
  ## **This one really does not block**, and the reason is `O_NONBLOCK` on the
  ## descriptor rather than the byte bound — see the module header for what the
  ## byte-bounded `FILE*` version measured on a silent child. The three answers
  ## `read(2)` can give are three different facts and each is acted on
  ## separately:
  ##
  ##   `> 0`            bytes; keep going until the bound
  ##   `0`              EOF — the write end is closed, and there will never be
  ##                    another byte. `sawEof`, so `pollBuild` knows the output
  ##                    is complete rather than merely paused.
  ##   `-1` + `EAGAIN`  nothing right now. THE ORDINARY STATE OF A SILENT
  ##                    BUILD, and the one the old code turned into a sleep.
  ##   `-1` + `EINTR`   a signal arrived mid-call. Retried, because it is not a
  ##                    statement about the pipe at all.
  result = 0
  if rb.isNil or rb.fd < 0 or rb.sawEof:
    return
  var chunk = newString(ReadChunkBytes)
  while result < maxBytes:
    let want = min(ReadChunkBytes, maxBytes - result)
    let got = posix.read(rb.fd, addr chunk[0], want)
    if got > 0:
      rb.absorb(chunk, got)
      result += got
      continue
    if got == 0:
      rb.sawEof = true
      return
    # `posix.errno` rather than `osLastError()`: this is a raw `read(2)` and
    # the three codes below are read as `cint`s against `posix`'s own
    # constants, with no `OSErrorCode` round trip in between.
    let err = errno
    if err == EINTR:
      continue
    if err == EAGAIN or err == EWOULDBLOCK:
      return
    # Any other error is a pipe this module can no longer read. Treated as EOF
    # rather than raised: the build still has a verdict to reach, and a
    # front-end that died because a pipe misbehaved would be worse than one
    # that reports the output it got.
    rb.sawEof = true
    return

proc pollBuild*(rb: RunningBuild; nowMs: int64): bool =
  ## Advance the build. Returns whether anything changed that the screen shows.
  ##
  ## THE ORDER IS: honour a cancellation, honour the deadline, drain output,
  ## then look for an exit. Cancellation first because a user who asked to stop
  ## must not wait for one more read; the deadline second for the same reason
  ## about a session nobody is watching.
  if rb.isNil or rb.session.verdict != bvRunning:
    return false
  result = false
  if rb.session.cancelRequested and not rb.killed:
    rb.kill()
    rb.session.appendLine("— cancelled —")
    result = true
  if rb.session.expired(nowMs) and not rb.killed:
    # THE DEADLINE IS NOT A CANCELLATION, and the verdict says so: the user did
    # not stop this, a clock did. `requestCancel` is deliberately NOT called
    # here — that would report `bvCancelled` and tell the user they stopped a
    # build they did not.
    rb.kill()
    rb.session.appendLine("— exceeded the " &
      $(rb.session.deadlineMs div 1000) & "s budget —")
    result = true
  let before = rb.session.lines.len
  discard rb.drain()
  if rb.session.lines.len != before:
    result = true
  if rb.process.isNil:
    return result
  let code = rb.process.peekExitCode()
  if code != -1:
    # THE PIPE IS DRAINED AGAIN, AFTER THE EXIT, and the second drain is not
    # belt-and-braces. The child is gone, so everything it ever wrote is
    # already in the pipe; the first drain above stopped at `MaxBytesPerPoll`,
    # and closing the descriptor now would silently throw away the tail — for a
    # compiler, exactly the errors the user ran `:build` to read. It terminates
    # on `EAGAIN` (nothing left) or `0` (EOF), both of which a dead child
    # reaches immediately, and is bounded anyway.
    discard rb.drain(MaxBytesAtExit)
    if rb.pending.len > 0:
      rb.session.appendLine(rb.pending)
      rb.pending = ""
    rb.session.finish(code)
    try:
      rb.process.close()
    except OSError:
      discard
    rb.process = nil
    # THE DESCRIPTOR IS FORGOTTEN, NOT CLOSED. `osproc.close` closed it a line
    # ago; `outputHandle`'s own documentation says so, and closing it here
    # would be a double close whose second victim is whatever fd the runtime
    # opened next.
    rb.fd = -1
    result = true

proc nowMonoMs*(): int64 =
  ## Monotonic-enough milliseconds for the deadline. `epochTime` rather than a
  ## `monotimes` import, because `main.nim`'s loop already measures with the
  ## same clock and two clocks in one loop is how a budget becomes unreadable.
  int64(epochTime() * 1000)
