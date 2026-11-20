## plugin_host/process_link.nim — one plugin-host process, as the host sees
## it: started in its own process group, tied to its parent's life, and spoken
## to over non-blocking pipes (Extensibility-Model.md §11.2.1, §11.8).
##
## ## WHY NOT `std/osproc`
##
## `startProcess` cannot put the child in a process group of its own or set
## `PR_SET_PDEATHSIG`, and §11.8 requires both: the stop sequence signals the
## GROUP (so a plugin's own children go too), and a plugin process must never
## outlive the session that started it, even when that session is killed with
## SIGKILL and runs no cleanup. So this is `fork`, three `dup2`s and `execvp`.
##
## ## WHY THE WRITES ARE QUEUED
##
## A hung plugin does not read its stdin. A pipe holds 64 KiB, and the host
## keeps writing — pings, signal batches — so a blocking write would block the
## FRONT-END on a plugin, which is the one thing §11.7.1 forbids. Writes go to
## a queue drained with non-blocking writes on every poll, and a queue past
## `MaxQueuedBytes` is reported to the supervisor, which treats it as the hang
## it is.
##
## POSIX only. On Windows the supervisor reports that native plugin processes
## are not available on this platform (a job-object implementation is §11.8's
## Windows half, not built here).

import std/[json, os, posix, strutils]

import ./protocol

const
  MaxQueuedBytes* = 16 * 1024 * 1024
  MaxStderrKeep* = 256 * 1024
    ## The tail of a process's stderr the host keeps in memory, for the crash
    ## record and the fault message; the whole stream goes to the plugin log.

var RLIMIT_AS {.importc, header: "<sys/resource.h>".}: cint

when defined(linux):
  const PR_SET_PDEATHSIG = cint(1)
  proc prctl(option: cint; arg2: culong): cint {.importc, header: "<sys/prctl.h>", varargs.}

type
  ExitState* = enum
    esRunning
    esExited
    esSignalled

  ProcessLink* = ref object
    pid*: Pid
    executable*: string
    toChild: cint
    fromChild: cint
    errFromChild: cint
    reader: FrameReader
    outQueue: string
    exit*: ExitState
    exitCode*: int
      ## The exit status, or the signal number when `exit == esSignalled`.
    stderrTail*: string
    stderrSink*: proc(data: string)
      ## Every byte of stderr, for the plugin log. May be nil.
    readEof*: bool
    oversize*: bool
      ## The process sent a frame larger than the cap.
    writeFailed*: bool

proc setNonBlocking(fd: cint) =
  let flags = fcntl(fd, F_GETFL)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

proc setCloexec(fd: cint) =
  discard fcntl(fd, F_SETFD, FD_CLOEXEC)

proc spawnPluginProcess*(executable: string; args: seq[string] = @[];
                         env: seq[(string, string)] = @[];
                         workingDir = "";
                         addressSpaceLimit: int64 = 0): ProcessLink =
  ## Start `executable` in a new process group, with stdin/stdout as the
  ## protocol channel and stderr captured. Raises `OSError` when the pipes or
  ## the fork fail; an exec failure shows up as an exit with status 127.
  var inPipe, outPipe, errPipe: array[2, cint]
  if pipe(inPipe) != 0 or pipe(outPipe) != 0 or pipe(errPipe) != 0:
    raiseOSError(osLastError(), "pipe for plugin process " & executable)
  # Everything the child needs is built BEFORE fork: after fork only
  # async-signal-safe calls are allowed in the child.
  var argv = allocCStringArray(@[executable] & args)
  var envStrings: seq[string]
  for k, v in envPairs():
    var overridden = false
    for (ek, _) in env:
      if ek == k: overridden = true
    if not overridden:
      envStrings.add k & "=" & v
  for (k, v) in env:
    envStrings.add k & "=" & v
  var envp = allocCStringArray(envStrings)
  let cwd = workingDir
  let parentPid = getpid()
  let pid = fork()
  if pid < 0:
    deallocCStringArray(argv)
    deallocCStringArray(envp)
    raiseOSError(osLastError(), "fork for plugin process " & executable)
  if pid == 0:
    # ---- the child --------------------------------------------------------
    discard setpgid(0, 0)
    when defined(linux):
      discard prctl(PR_SET_PDEATHSIG, culong(SIGKILL))
      # The parent may have died between fork and prctl.
      if getppid() != parentPid:
        exitnow(1)
    if addressSpaceLimit > 0:
      var lim: RLimit
      lim.rlim_cur = addressSpaceLimit
      lim.rlim_max = addressSpaceLimit
      discard setrlimit(RLIMIT_AS, lim)
    discard dup2(inPipe[0], 0)
    discard dup2(outPipe[1], 1)
    discard dup2(errPipe[1], 2)
    for fd in [inPipe[0], inPipe[1], outPipe[0], outPipe[1], errPipe[0],
               errPipe[1]]:
      if fd > 2: discard close(fd)
    if cwd.len > 0:
      discard chdir(cwd.cstring)
    discard execve(argv[0], argv, envp)
    exitnow(127)
  # ---- the parent ---------------------------------------------------------
  deallocCStringArray(argv)
  deallocCStringArray(envp)
  discard close(inPipe[0])
  discard close(outPipe[1])
  discard close(errPipe[1])
  for fd in [inPipe[1], outPipe[0], errPipe[0]]:
    setNonBlocking(fd)
    setCloexec(fd)
  ProcessLink(pid: pid, executable: executable, toChild: inPipe[1],
              fromChild: outPipe[0], errFromChild: errPipe[0])

proc send*(p: ProcessLink; msg: JsonNode): bool {.discardable.} =
  ## Queue `msg` for the child. False when the frame is over the cap or the
  ## queue is already past `MaxQueuedBytes` (the child is not reading).
  if p.isNil or p.toChild < 0:
    return false
  let frame = encodeMessage(msg)
  if frame.len == 0:
    return false
  if p.outQueue.len > MaxQueuedBytes:
    return false
  p.outQueue.add frame
  true

proc queuedBytes*(p: ProcessLink): int = p.outQueue.len

proc flushWrites*(p: ProcessLink) =
  while p.outQueue.len > 0 and p.toChild >= 0:
    let n = posix.write(p.toChild, p.outQueue[0].addr, p.outQueue.len)
    if n > 0:
      p.outQueue = p.outQueue[n .. ^1]
    elif n < 0 and (errno == EAGAIN or errno == EWOULDBLOCK):
      return
    elif n < 0 and errno == EINTR:
      continue
    else:
      p.writeFailed = true
      discard close(p.toChild)
      p.toChild = -1
      p.outQueue.setLen(0)
      return

proc drainFd(fd: var cint; sink: proc(data: string); eof: var bool) =
  var buf: array[65536, char]
  while fd >= 0:
    let n = posix.read(fd, buf[0].addr, buf.len)
    if n > 0:
      var s = newString(n)
      copyMem(s[0].addr, buf[0].addr, n)
      sink(s)
    elif n == 0:
      eof = true
      discard close(fd)
      fd = -1
      return
    elif errno == EINTR:
      continue
    else:
      return

proc readMessages*(p: ProcessLink; maxFrames = 4096): seq[string] =
  ## Every whole frame the child has written so far (at most `maxFrames`;
  ## the rest stay buffered for the next call). Also drains stderr.
  if p.isNil:
    return
  var errEof = false
  let link = p
  drainFd(p.errFromChild, proc(d: string) =
    if not link.stderrSink.isNil: link.stderrSink(d)
    link.stderrTail.add d
    if link.stderrTail.len > MaxStderrKeep:
      link.stderrTail = link.stderrTail[^MaxStderrKeep .. ^1], errEof)
  var eof = false
  drainFd(p.fromChild, proc(d: string) = link.reader.feed(d), eof)
  if eof: p.readEof = true
  var frame: string
  while result.len < maxFrames:
    case p.reader.next(frame)
    of fsFrame: result.add frame
    of fsIncomplete: break
    of fsOversize:
      p.oversize = true
      break

proc pollExit*(p: ProcessLink): bool =
  ## Reap the child if it has ended. True once it has.
  if p.isNil:
    return true
  if p.exit != esRunning:
    return true
  var status: cint
  let r = waitpid(p.pid, status, WNOHANG)
  if r == p.pid:
    if WIFSIGNALED(status):
      p.exit = esSignalled
      p.exitCode = WTERMSIG(status)
    else:
      p.exit = esExited
      p.exitCode = WEXITSTATUS(status)
    return true
  false

proc signalGroup*(p: ProcessLink; sig: cint) =
  ## Signal the plugin's whole process group.
  if p.isNil or p.exit != esRunning:
    return
  discard kill(Pid(-p.pid), sig)

proc closeStdin*(p: ProcessLink) =
  if p.toChild >= 0:
    discard close(p.toChild)
    p.toChild = -1

proc closeAll*(p: ProcessLink) =
  if p.isNil: return
  p.closeStdin()
  if p.fromChild >= 0:
    discard close(p.fromChild)
    p.fromChild = -1
  if p.errFromChild >= 0:
    discard close(p.errFromChild)
    p.errFromChild = -1

proc describeExit*(p: ProcessLink): string =
  case p.exit
  of esRunning: "running"
  of esExited: "exited with status " & $p.exitCode
  of esSignalled: "was killed by signal " & $p.exitCode &
    (if p.exitCode == SIGSEGV: " (SIGSEGV)"
     elif p.exitCode == SIGKILL: " (SIGKILL)"
     elif p.exitCode == SIGABRT: " (SIGABRT)" else: "")

proc crashRecordPlugin*(stderrTail: string): string =
  ## The SDK writes `ct-plugin-crash: <plugin>` to stderr before a handler
  ## that is about to end the process (an unhandled `Defect`); the last such
  ## line names the plugin to blame (§11.6.1).
  const Marker = "ct-plugin-crash: "
  let at = stderrTail.rfind(Marker)
  if at < 0:
    return ""
  var e = stderrTail.find('\n', at)
  if e < 0: e = stderrTail.len
  stderrTail[at + Marker.len ..< e].strip
