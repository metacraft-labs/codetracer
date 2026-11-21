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
##
## ## ON THE JAVASCRIPT BACKEND (the desktop's main process, `ct host`)
##
## The same `ProcessLink`, over Node's `child_process.spawn`: `detached: true`
## puts the child in a process group of its own (`setsid`), stdin/stdout are
## the protocol pipes and stderr is captured. Node delivers bytes in its event
## loop, between the front-end's ticks; they are fed to the same
## `protocol.FrameReader` as they arrive, and `readMessages` hands out the
## whole frames. Writes keep the same queue: a frame goes to the pipe only
## while Node's own buffer is under its high-water mark, so a child that stops
## reading leaves the bytes HERE, `queuedBytes` grows past `MaxQueuedBytes`,
## and the supervisor treats it as the hang it is. Exit is reported once Node
## has delivered every byte the child wrote (`close`), so a crash record on
## stderr is read before the exit is judged; `signalGroup` is
## `process.kill(-pid, sig)`. An executable that cannot be started reads as an
## exit with status 127, as `execve` failing in the forked child does.
##
## Node cannot set `PR_SET_PDEATHSIG`. What stands in for it:
##
## * every live link is registered, and the main process's `exit` event (which
##   every orderly end reaches, `process.exit` included) and its `SIGTERM`,
##   `SIGINT` and `SIGHUP` kill each registered group with SIGKILL; a signal
##   handler that finds no other listener re-raises the signal afterwards, so
##   installing it does not change how the main process ends;
## * on Linux, when `setpriv` (util-linux) is on `PATH`, the child is started
##   through `setpriv --pdeathsig KILL`, which sets `PR_SET_PDEATHSIG` before
##   it execs the plugin: then even a SIGKILLed main process takes its plugins
##   with it, as on the C backend.
##
## What remains when the main process is SIGKILLed and `setpriv` is absent:
## the plugin's stdin closes, and an SDK plugin's reader sees end-of-file and
## the process exits (`codetracer_plugin_sdk.run`). A plugin whose main thread
## is stuck in a handler at that moment never returns to its loop and outlives
## the main process, as do any processes the plugin started itself.

import std/[json, strutils]
when defined(js):
  import std/jsffi
else:
  import std/[os, posix]

import ./protocol

const
  MaxQueuedBytes* = 16 * 1024 * 1024
  MaxStderrKeep* = 256 * 1024
    ## The tail of a process's stderr the host keeps in memory, for the crash
    ## record and the fault message; the whole stream goes to the plugin log.

when defined(js):
  type Pid* = int
  const
    SIGHUP* = cint(1)
    SIGINT* = cint(2)
    SIGABRT* = cint(6)
    SIGKILL* = cint(9)
    SIGSEGV* = cint(11)
    SIGTERM* = cint(15)
      ## The numbers Linux and macOS share; on the C backend they are
      ## `std/posix`'s.
    ExitCloseGraceMs = 500
      ## How long after `exit` a link waits for Node's `close` (every byte
      ## of stdout and stderr delivered) before reporting the exit anyway: a
      ## grandchild holding the pipes open must not hide the exit forever.
else:
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
    when defined(js):
      child: JsObject
        ## The `ChildProcess`; nil once every handle is closed.
      stdinOpen: bool
      writeBlocked: bool
        ## Node's stdin buffer is past its high-water mark: wait for `drain`.
      exitSeen: bool
      exitSeenAtMs: float
      closed: bool
      pendingExit: tuple[signalled: bool, code: int]
    else:
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

when defined(js):
  # ---- Node bindings --------------------------------------------------------

  proc jsRequire(name: cstring): JsObject {.importjs: "require(#)".}
  proc jsNowMs(): float {.importjs: "Date.now()".}
  proc jsByteAt(b: JsObject; i: int): int {.importjs: "#[#]".}
  proc jsLen(b: JsObject): int {.importjs: "#.length".}
  proc jsNewBytes(n: int): JsObject {.importjs: "new Uint8Array(#)".}
  proc jsSetByte(a: JsObject; i, v: int) {.importjs: "#[#] = #".}
  proc jsIsNil(o: JsObject): bool {.importjs: "(# == null)".}

  proc toNimString(b: JsObject): string =
    let n = jsLen(b)
    result = newString(n)
    for i in 0 ..< n:
      result[i] = chr(jsByteAt(b, i))

  proc toBytes(s: string): JsObject =
    result = jsNewBytes(s.len)
    for i in 0 ..< s.len:
      jsSetByte(result, i, ord(s[i]))

  proc jsSpawn(cp: JsObject; cmd: cstring; args: seq[cstring]; cwd: cstring;
               env: JsObject): JsObject {.importjs: """
    (function (cp, cmd, args, cwd, env) {
      var opts = { detached: true, stdio: ['pipe', 'pipe', 'pipe'], env: env };
      if (cwd.length > 0) { opts.cwd = cwd; }
      return cp.spawn(cmd, args, opts);
    })(#, #, #, #, #)""".}

  proc jsEnvWith(keys, values: seq[cstring]): JsObject {.importjs: """
    (function (keys, values) {
      var env = Object.assign({}, process.env);
      for (var i = 0; i < keys.length; i++) { env[keys[i]] = values[i]; }
      return env;
    })(#, #)""".}

  proc jsSignalNumber(name: JsObject): int {.importjs: """
    (function (name) {
      var n = require('os').constants.signals[name];
      return typeof n === 'number' ? n : 0;
    })(#)""".}

  proc jsKillGroup(pid, sig: int) {.importjs: """
    (function (pid, sig) {
      try { process.kill(-pid, sig); } catch (e) { }
    })(#, #)""".}

  proc jsFindPdeathHelper(): cstring {.importjs: """
    (function () {
      if (process.platform !== 'linux') { return ''; }
      if (process.env.CODETRACER_PLUGIN_NO_SETPRIV) { return ''; }
      var fs = require('fs'), path = require('path');
      var dirs = (process.env.PATH || '').split(path.delimiter);
      for (var i = 0; i < dirs.length; i++) {
        if (dirs[i].length === 0) { continue; }
        var candidate = path.join(dirs[i], 'setpriv');
        try { fs.accessSync(candidate, fs.constants.X_OK); return candidate; }
        catch (e) { }
      }
      return '';
    })()""".}

  proc jsInstallExitGuards(killAll: proc()) {.importjs: """
    (function (killAll) {
      process.on('exit', function () { killAll(); });
      ['SIGTERM', 'SIGINT', 'SIGHUP'].forEach(function (sig) {
        var handler = function () {
          killAll();
          process.removeListener(sig, handler);
          if (process.listenerCount(sig) === 0) { process.kill(process.pid, sig); }
        };
        process.on(sig, handler);
      });
    })(#)""".}

  proc jsOn(emitter: JsObject; event: cstring; cb: proc()) {.importjs: "#.on(#, #)".}
  proc jsOnData(emitter: JsObject; event: cstring; cb: proc(data: JsObject)) {.
    importjs: "#.on(#, #)".}
  proc jsOnExit(emitter: JsObject; event: cstring;
                cb: proc(code, signal: JsObject)) {.importjs: "#.on(#, #)".}
  proc jsWrite(stream: JsObject; data: JsObject): bool {.importjs: "#.write(#)".}
  proc jsDestroy(stream: JsObject) {.importjs:
    "(function (s) { if (s) { s.destroy(); } })(#)".}
  proc jsWritableLength(stream: JsObject): int {.importjs:
    "(function (s) { return (s && s.writableLength) || 0; })(#)".}
  proc jsPid(child: JsObject): int {.importjs: "(#.pid || 0)".}
  proc jsField(o: JsObject; name: cstring): JsObject {.importjs: "#[#]".}
  proc jsIsNumber(o: JsObject): bool {.importjs: "(typeof # === 'number')".}
  proc jsToInt(o: JsObject): int {.importjs: "(#)".}
  proc jsToCstring(o: JsObject): cstring {.importjs: "String(#)".}

  # ---- the registry that stands in for PR_SET_PDEATHSIG ----------------------

  var liveLinks: seq[ProcessLink]
  var guardsInstalled = false
  var pdeathHelper: cstring

  proc killEveryGroup() =
    ## SIGKILL every running plugin group: the main process is ending.
    for l in liveLinks:
      if l.exit == esRunning and not l.exitSeen and l.pid > 0:
        jsKillGroup(l.pid, int(SIGKILL))

  proc liveProcessGroups*(): seq[int] =
    ## The groups `killEveryGroup` would kill now (for the suites).
    for l in liveLinks:
      if l.exit == esRunning and not l.exitSeen and l.pid > 0:
        result.add l.pid

  proc forget(p: ProcessLink) =
    var kept: seq[ProcessLink]
    for l in liveLinks:
      if l != p: kept.add l
    liveLinks = kept

  proc usesPdeathHelper*(): bool =
    ## True when a child started now starts through `setpriv --pdeathsig
    ## KILL`. Looked up at every start (a handful of `access` calls), so
    ## `PATH` and `CODETRACER_PLUGIN_NO_SETPRIV` are read as they are then.
    pdeathHelper = jsFindPdeathHelper()
    pdeathHelper.len > 0

  proc spawnPluginProcess*(executable: string; args: seq[string] = @[];
                           env: seq[(string, string)] = @[];
                           workingDir = "";
                           addressSpaceLimit: int64 = 0): ProcessLink =
    ## As on the C backend: `executable` in a new process group, stdin/stdout
    ## the protocol channel, stderr captured. A start that fails reads as an
    ## exit with status 127.
    if not guardsInstalled:
      guardsInstalled = true
      jsInstallExitGuards(killEveryGroup)
    var cmd = executable
    var argv = args
    if addressSpaceLimit > 0:
      # `setrlimit` between fork and exec is not Node's to make; the shell's
      # `ulimit` is, and `exec` keeps the pid the plugin's.
      argv = @["-c", "ulimit -v " & $(addressSpaceLimit div 1024) &
                 " && exec \"$0\" \"$@\"", cmd] & argv
      cmd = "/bin/sh"
    if usesPdeathHelper():
      argv = @["--pdeathsig", "KILL", "--", cmd] & argv
      cmd = $pdeathHelper
    var cargs: seq[cstring]
    for a in argv: cargs.add cstring(a)
    var keys, values: seq[cstring]
    for (k, v) in env:
      keys.add cstring(k)
      values.add cstring(v)
    let link = ProcessLink(executable: executable, stdinOpen: true)
    var child: JsObject
    try:
      child = jsSpawn(jsRequire("child_process"), cstring(cmd), cargs,
                      cstring(workingDir), jsEnvWith(keys, values))
    except CatchableError as e:
      raise newException(OSError, "spawn for plugin process " & executable &
                         ": " & e.msg)
    link.child = child
    link.pid = jsPid(child)
    let stdinStream = jsField(child, "stdin")
    let stdoutStream = jsField(child, "stdout")
    let stderrStream = jsField(child, "stderr")
    jsOnData(stdoutStream, "data", proc(d: JsObject) =
      link.reader.feed(toNimString(d)))
    jsOn(stdoutStream, "end", proc() = link.readEof = true)
    jsOnData(stderrStream, "data", proc(d: JsObject) =
      let data = toNimString(d)
      if not link.stderrSink.isNil: link.stderrSink(data)
      link.stderrTail.add data
      if link.stderrTail.len > MaxStderrKeep:
        link.stderrTail = link.stderrTail[^MaxStderrKeep .. ^1])
    jsOn(stdinStream, "drain", proc() = link.writeBlocked = false)
    jsOnData(stdinStream, "error", proc(e: JsObject) =
      # EPIPE: the child closed its stdin or ended.
      link.writeFailed = true
      link.stdinOpen = false
      link.outQueue.setLen(0))
    let recordExit = proc(code, signal: JsObject) =
      if link.exitSeen: return
      link.exitSeen = true
      link.exitSeenAtMs = jsNowMs()
      if link.pid == 0:
        # Never started: Node reports the spawn's errno as a negative code.
        link.pendingExit = (signalled: false, code: 127)
      elif not jsIsNil(signal):
        link.pendingExit = (signalled: true, code: jsSignalNumber(signal))
      elif jsIsNumber(code):
        link.pendingExit = (signalled: false, code: jsToInt(code))
      else:
        link.pendingExit = (signalled: false, code: 0)
    jsOnExit(child, "exit", recordExit)
    jsOnExit(child, "close", proc(code, signal: JsObject) =
      recordExit(code, signal)
      link.closed = true)
    jsOnData(child, "error", proc(e: JsObject) =
      if link.pid == 0 and not link.exitSeen:
        # Never started (ENOENT, EACCES): `execve` failing in the child.
        link.stderrTail.add "could not start " & executable & ": " &
          $jsToCstring(e) & "\n"
        link.exitSeen = true
        link.closed = true
        link.exitSeenAtMs = jsNowMs()
        link.pendingExit = (signalled: false, code: 127))
    liveLinks.add link
    link

  proc canWrite(p: ProcessLink): bool = p.stdinOpen and not p.child.isNil

  proc queuedBytes*(p: ProcessLink): int =
    ## The bytes the child has not taken: the link's queue plus what Node
    ## holds for the pipe.
    if p.child.isNil: return p.outQueue.len
    p.outQueue.len + jsWritableLength(jsField(p.child, "stdin"))

  proc flushWrites*(p: ProcessLink) =
    if p.outQueue.len == 0 or not p.canWrite or p.writeBlocked:
      return
    let ok = jsWrite(jsField(p.child, "stdin"), toBytes(p.outQueue))
    p.outQueue.setLen(0)
    if not ok:
      p.writeBlocked = true

  proc readMessages*(p: ProcessLink; maxFrames = 4096): seq[string] =
    ## Every whole frame Node has delivered so far (at most `maxFrames`; the
    ## rest stay buffered for the next call). Stderr was taken as it came.
    if p.isNil:
      return
    var frame: string
    while result.len < maxFrames:
      case p.reader.next(frame)
      of fsFrame: result.add frame
      of fsIncomplete: break
      of fsOversize:
        p.oversize = true
        break

  proc pollExit*(p: ProcessLink): bool =
    ## True once the child has ended and Node has delivered what it wrote
    ## (or `ExitCloseGraceMs` passed since it ended).
    if p.isNil:
      return true
    if p.exit != esRunning:
      return true
    if p.exitSeen and (p.closed or jsNowMs() - p.exitSeenAtMs >= ExitCloseGraceMs):
      if p.pendingExit.signalled:
        p.exit = esSignalled
      else:
        p.exit = esExited
      p.exitCode = p.pendingExit.code
      p.forget()
      return true
    false

  proc signalGroup*(p: ProcessLink; sig: cint) =
    ## Signal the plugin's whole process group.
    if p.isNil or p.exit != esRunning or p.exitSeen or p.pid <= 0:
      return
    jsKillGroup(p.pid, int(sig))

  proc closeStdin*(p: ProcessLink) =
    if p.canWrite:
      jsDestroy(jsField(p.child, "stdin"))
      p.stdinOpen = false

  proc closeAll*(p: ProcessLink) =
    if p.isNil or p.child.isNil: return
    p.closeStdin()
    jsDestroy(jsField(p.child, "stdout"))
    jsDestroy(jsField(p.child, "stderr"))
    if p.exit != esRunning:
      p.forget()
      p.child = nil

else:
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

  proc canWrite(p: ProcessLink): bool = p.toChild >= 0

  proc queuedBytes*(p: ProcessLink): int = p.outQueue.len

proc send*(p: ProcessLink; msg: JsonNode): bool {.discardable.} =
  ## Queue `msg` for the child. False when the frame is over the cap or the
  ## queue is already past `MaxQueuedBytes` (the child is not reading).
  if p.isNil or not p.canWrite:
    return false
  let frame = encodeMessage(msg)
  if frame.len == 0:
    return false
  if p.queuedBytes > MaxQueuedBytes:
    return false
  p.outQueue.add frame
  true

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
