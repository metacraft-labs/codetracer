## lens_tools.nim — running an external program from a native plugin without
## blocking the plugin's handlers.
##
## The plugin SDK runs every handler of the package on one thread, one at a
## time. A handler that waited for `git` to finish would hold every plugin of
## the package for as long as `git` takes, and past five seconds the host
## would call the process hung (Extensibility-Model.md §11.6.2). So a tool is
## STARTED in a handler and FINISHED in the SDK's idle loop: `ToolRunner.pump`
## is installed as an idle hook, reads whatever the child has written without
## blocking, and calls the run's `onDone` once the child has exited and its
## output is drained.
##
## The rules the SDK's in-process primitives (§8.1.1) enforce, kept here by
## hand because a native plugin has no host-owned handles to lean on:
##
## * argv is a list and no shell is involved, so nothing in a file name is
##   ever interpreted;
## * the child's stdin, stdout and stderr are pipes of its own: a child that
##   inherited the plugin's stdout would write into the protocol channel;
## * every run has a deadline after which the child is killed;
## * a run that is superseded (the debugger moved on) is cancelled and its
##   child killed, so stale work never piles up;
## * output is capped, so a runaway tool cannot grow the plugin without bound;
## * `stopAll` kills what is still running, for deactivation.

import std/[monotimes, osproc, posix, strutils, times]

type
  ToolRun* = ref object
    argv*: seq[string]
    output*: string
      ## stdout and stderr together, in the order the child wrote them.
    exitCode*: int
    timedOut*: bool
    truncated*: bool
    startError*: string
      ## Non-empty when the program could not be started at all (not found,
      ## not executable, a working directory that does not exist).
    owner*: string
      ## Who started it, for `stopOwnedBy`.
    process: Process
    fd: cint
    eof: bool
    finished: bool
    cancelled: bool
    deadline: MonoTime
    onDone: proc(r: ToolRun) {.closure.}

  ToolRunner* = ref object
    runs: seq[ToolRun]
    maxOutput*: int
    onError*: proc(owner, message: string) {.closure.}
      ## Called when an `onDone` raises: the idle loop is not attributed to a
      ## plugin by the SDK, so the runner reports the error itself instead of
      ## letting it end the process.

proc newToolRunner*(maxOutput = 1 shl 20): ToolRunner =
  ToolRunner(maxOutput: maxOutput)

proc running*(t: ToolRunner): int =
  for r in t.runs:
    if not r.finished: inc result

proc start*(t: ToolRunner; owner: string; argv: seq[string]; workingDir: string;
            timeoutMs: int; onDone: proc(r: ToolRun) {.closure.}): ToolRun =
  ## Start `argv` in `workingDir`. `onDone` runs from `pump`, never from here,
  ## even when the program could not be started, so a caller has one path.
  result = ToolRun(argv: argv, owner: owner, onDone: onDone, fd: -1,
                   deadline: getMonoTime() + initDuration(milliseconds = timeoutMs))
  if argv.len == 0:
    result.startError = "no program to run"
  else:
    try:
      result.process = startProcess(argv[0], workingDir = workingDir,
                                    args = argv[1 .. ^1],
                                    options = {poUsePath, poStdErrToStdOut})
      # Nothing is written to the tool: close its stdin so a program that
      # reads it sees end-of-file rather than waiting on the plugin.
      discard posix.close(result.process.inputHandle.cint)
      result.fd = result.process.outputHandle.cint
      let flags = fcntl(result.fd, F_GETFL)
      discard fcntl(result.fd, F_SETFL, flags or O_NONBLOCK)
    except CatchableError as e:
      result.startError = e.msg
      result.process = nil
  t.runs.add result

proc kill(r: ToolRun) =
  if not r.process.isNil and r.process.peekExitCode == -1:
    try: r.process.kill() except CatchableError: discard

proc cancel*(r: ToolRun) =
  ## Stop caring about `r`: its child is killed and its `onDone` never runs.
  if r.isNil or r.finished: return
  r.cancelled = true
  r.kill()

proc drain(t: ToolRunner; r: ToolRun) =
  if r.fd < 0 or r.eof: return
  var buf: array[16384, char]
  while true:
    let n = posix.read(r.fd, buf[0].addr, buf.len)
    if n > 0:
      if r.output.len < t.maxOutput:
        let keep = min(n, t.maxOutput - r.output.len)
        let at = r.output.len
        r.output.setLen(at + keep)
        copyMem(r.output[at].addr, buf[0].addr, keep)
        if keep < n: r.truncated = true
      else:
        r.truncated = true
    elif n == 0:
      r.eof = true
      return
    else:
      if errno == EINTR: continue
      if errno != EAGAIN and errno != EWOULDBLOCK:
        r.eof = true
      return

proc finish(t: ToolRunner; r: ToolRun) =
  r.finished = true
  if not r.process.isNil:
    r.exitCode = r.process.waitForExit()
    # The descriptors are closed here, once each: `osproc.close` would close
    # the merged stdout/stderr descriptor twice.
    if r.fd >= 0:
      discard posix.close(r.fd)
      r.fd = -1
    r.process = nil
  if r.cancelled or r.onDone.isNil: return
  try:
    r.onDone(r)
  except CatchableError as e:
    if not t.onError.isNil:
      t.onError(r.owner, "while handling the output of " & r.argv.join(" ") &
                ": " & e.msg)

proc pump*(t: ToolRunner) =
  ## One turn of the idle loop: read what is there, reap what has exited,
  ## kill what is past its deadline. Never blocks.
  if t.runs.len == 0: return
  let now = getMonoTime()
  for r in t.runs:
    if r.finished: continue
    if r.process.isNil:
      t.finish(r)
      continue
    t.drain(r)
    if r.process.peekExitCode != -1:
      # Exited: what it wrote is in the pipe already. A grandchild that
      # still holds the pipe open does not keep the run alive.
      t.drain(r)
      t.finish(r)
    elif now > r.deadline:
      r.timedOut = true
      r.kill()
  var kept: seq[ToolRun]
  for r in t.runs:
    if not r.finished: kept.add r
  t.runs = kept

proc stopOwnedBy*(t: ToolRunner; owner: string) =
  ## Kill and forget every run `owner` started (its plugin was deactivated).
  for r in t.runs:
    if r.owner == owner and not r.finished:
      r.cancel()
