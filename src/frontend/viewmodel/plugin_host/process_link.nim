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
## SIGKILL and runs no cleanup. So this is `fork`, the `dup2`s that lay out
## the channel, and `execve`.
##
## ## THE CHANNEL IS NOT THE STANDARD STREAMS (§11.4.1)
##
## The protocol runs on the child's descriptors 3 (to it) and 4 (from it), and
## liveness on 5 (`ping`) and 6 (`pong`); `CODETRACER_PLUGIN_CHANNEL` names
## them. The child's stdin is `/dev/null` and its stdout and stderr both go to
## the plugin log. Two faults this removes: a stray `echo` in a plugin, or a
## child it starts with inherited stdio, writing into the protocol and being
## judged a protocol violation; and a `pong` waiting behind a frame the
## plugin's main thread is writing into a full pipe, which made a healthy
## plugin look hung at high load. A `ping` is queued apart from every other
## frame too, so it never waits behind a signal batch the child is slow to
## read.
##
## ## WHY THE WRITES ARE QUEUED
##
## A hung plugin does not read its channel. A pipe holds 64 KiB, and the host
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
## puts the child in a process group of its own (`setsid`), descriptors 3 to 6
## are the channel's pipes and stdout and stderr are captured. Node delivers bytes in its event
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
## * on Linux, when `setpriv` (util-linux) is on `PATH` AND can run here, the
##   child is started through `setpriv --pdeathsig KILL`, which sets
##   `PR_SET_PDEATHSIG` before it execs the plugin: then even a SIGKILLed main
##   process takes its plugins with it, as on the C backend.
##
## "Can run here" is measured, not assumed. Under `NoNewPrivs` with an empty
## capability bounding set (an agent sandbox, a locked-down container)
## util-linux `setpriv` exits 1 before it execs anything ("keep process
## capabilities failed: Operation not permitted"), and a launcher that took it
## on trust started EVERY plugin into that exit: each failed to start and was
## struck for a fault that was the host's. So each `setpriv` found is probed
## once, by running `setpriv --pdeathsig KILL -- setpriv --version`, and one
## whose probe fails is not used: plugins start unhelped, as when `setpriv` is
## absent. Why the helper is not used is `ProcessLink.launchNote`, which the
## supervisor writes to its log at every start.
##
## What remains when the main process is SIGKILLed and `setpriv` is absent or
## cannot run:
## the plugin's channel closes, and an SDK plugin's reader sees end-of-file and
## the process exits (`codetracer_plugin_sdk.run`). A plugin whose main thread
## is stuck in a handler at that moment never returns to its loop and outlives
## the main process, as do any processes the plugin started itself.

import std/[json, strutils]
when defined(js):
  import std/jsffi
else:
  import std/[os, posix]

import ./protocol
import ./byte_append

const
  MaxQueuedBytes* = 16 * 1024 * 1024
  MaxLivenessQueuedBytes* = 64 * 1024
    ## `ping`s the child's watchdog has not read. Past this the watchdog is
    ## not reading at all, and the pong deadline is what judges it.
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
      toChild: JsObject
        ## The child's descriptor 3 (`ProtocolInFd`), as Node's stream.
      pingTo: JsObject
        ## The child's descriptor 5 (`LivenessInFd`).
      stdinOpen: bool
        ## The protocol stream to the child is open.
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
      pingTo: cint
      pongFrom: cint
    reader: FrameReader
    outQueue: string
    livenessReader: FrameReader
      ## The `pong`s, read from their own descriptor (§11.4.1).
    livenessQueue: string
      ## The `ping`s, queued apart from every other frame: a `ping` never
      ## waits behind a signal batch the child has not read yet.
    exit*: ExitState
    exitCode*: int
      ## The exit status, or the signal number when `exit == esSignalled`.
    stderrTail*: string
    stderrSink*: proc(data: string)
      ## Every byte of stderr, for the plugin log. May be nil.
    readEof*: bool
    bytesRead*: int
      ## Every protocol byte read from the child so far. The supervisor's
      ## liveness check reads it: a process that is still delivering a frame
      ## is answering, even when its `pong` is queued behind that frame.
    launchNote*: string
      ## How the start departed from §11.8, for the supervisor's log: on
      ## Node on Linux, why the child was started WITHOUT
      ## `PR_SET_PDEATHSIG` (`setpriv` absent, disabled, or unable to run
      ## here). Empty when nothing is missing, and always on the C backend,
      ## which sets it itself.
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
      var opts = { detached: true, env: env,
                   stdio: ['ignore', 'pipe', 'pipe', 'pipe', 'pipe', 'pipe', 'pipe'] };
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

  proc jsIsLinux(): bool {.importjs: "(process.platform === 'linux')".}
  proc jsSetprivDisabled(): bool {.importjs:
    "(!!process.env.CODETRACER_PLUGIN_NO_SETPRIV)".}

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

  proc jsProbePdeathHelper(helper: cstring): cstring {.importjs: """
    (function (helper) {
      // The helper sets PR_SET_PDEATHSIG and execs: here it execs ITSELF with
      // `--version`, which needs nothing else on PATH and does no privileged
      // work of its own, so a failure is the pdeathsig step's. '' = usable.
      var r;
      try {
        r = require('child_process').spawnSync(helper,
          ['--pdeathsig', 'KILL', '--', helper, '--version'],
          { stdio: ['ignore', 'ignore', 'pipe'], timeout: 10000 });
      } catch (e) { return 'could not be run: ' + e.message; }
      if (r.error) { return 'could not be run: ' + r.error.message; }
      if (r.status === 0 && !r.signal) { return ''; }
      var line = String(r.stderr || '').trim().split('\n')[0] || '';
      var how = r.signal ? 'was killed by ' + r.signal
                         : 'exited with status ' + r.status;
      return how + (line.length > 0 ? ' (' + line + ')' : '');
    })(#)""".}

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
  proc jsStdio(child: JsObject; fd: int): JsObject {.importjs:
    "(#.stdio[#] || null)".}
  proc jsIsNumber(o: JsObject): bool {.importjs: "(typeof # === 'number')".}
  proc jsToInt(o: JsObject): int {.importjs: "(#)".}
  proc jsToCstring(o: JsObject): cstring {.importjs: "String(#)".}

  # ---- the registry that stands in for PR_SET_PDEATHSIG ----------------------

  var liveLinks: seq[ProcessLink]
  var guardsInstalled = false
  var pdeathHelper: cstring
  var probedHelper = ""
    ## The `setpriv` the last probe ran, and what it found (`probeFailure`,
    ## empty when it works). A helper is probed once; another one found on a
    ## changed `PATH` is probed in its turn.
  var probeFailure = ""
  var pdeathNote = ""

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
    ## `PATH` and `CODETRACER_PLUGIN_NO_SETPRIV` are read as they are then;
    ## a `setpriv` found is used only when its probe (run once per helper,
    ## see the module header) shows it can run here. When it is not used,
    ## `pdeathHelperNote` says why.
    pdeathNote = ""
    if not jsIsLinux():
      pdeathHelper = ""
      return false
    if jsSetprivDisabled():
      pdeathHelper = ""
      pdeathNote = "started without PR_SET_PDEATHSIG: " &
        "CODETRACER_PLUGIN_NO_SETPRIV is set"
      return false
    let found = $jsFindPdeathHelper()
    if found.len == 0:
      pdeathHelper = ""
      pdeathNote = "started without PR_SET_PDEATHSIG: setpriv is not on PATH"
      return false
    if found != probedHelper:
      probedHelper = found
      probeFailure = $jsProbePdeathHelper(cstring(found))
    if probeFailure.len > 0:
      pdeathHelper = ""
      pdeathNote = "started without PR_SET_PDEATHSIG: " & found &
        " cannot run here: its probe `setpriv --pdeathsig KILL` " & probeFailure
      return false
    pdeathHelper = cstring(found)
    true

  proc pdeathHelperNote*(): string =
    ## Why the last `usesPdeathHelper` answered false on Linux; empty when it
    ## answered true, and on every other platform.
    pdeathNote

  proc spawnPluginProcess*(executable: string; args: seq[string] = @[];
                           env: seq[(string, string)] = @[];
                           workingDir = "";
                           addressSpaceLimit: int64 = 0): ProcessLink =
    ## As on the C backend: `executable` in a new process group, the channel
    ## on descriptors 3 to 6, stdout and stderr captured. A start that fails reads as an
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
    let helped = usesPdeathHelper()
    let note = pdeathHelperNote()
    if helped:
      argv = @["--pdeathsig", "KILL", "--", cmd] & argv
      cmd = $pdeathHelper
    var cargs: seq[cstring]
    for a in argv: cargs.add cstring(a)
    var keys, values: seq[cstring]
    for (k, v) in env:
      keys.add cstring(k)
      values.add cstring(v)
    keys.add cstring(ChannelEnv)
    values.add cstring(ChannelEnvValue)
    let link = ProcessLink(executable: executable, stdinOpen: true,
                           launchNote: note)
    var child: JsObject
    try:
      child = jsSpawn(jsRequire("child_process"), cstring(cmd), cargs,
                      cstring(workingDir), jsEnvWith(keys, values))
    except CatchableError as e:
      raise newException(OSError, "spawn for plugin process " & executable &
                         ": " & e.msg)
    link.child = child
    link.pid = jsPid(child)
    # §11.4.1: the protocol is on the child's descriptors 3 and 4, liveness
    # on 5 and 6; its stdout and stderr are both the plugin's log.
    let toChild = jsStdio(child, ProtocolInFd)
    let fromChild = jsStdio(child, ProtocolOutFd)
    let pingTo = jsStdio(child, LivenessInFd)
    let pongFrom = jsStdio(child, LivenessOutFd)
    link.toChild = toChild
    link.pingTo = pingTo
    let logged = proc(d: JsObject) =
      let data = toNimString(d)
      if not link.stderrSink.isNil: link.stderrSink(data)
      link.stderrTail.appendBytes data   # a pipe chunk (`byte_append`)
      if link.stderrTail.len > MaxStderrKeep:
        link.stderrTail = link.stderrTail[^MaxStderrKeep .. ^1]
    if not jsIsNil(fromChild):
      jsOnData(fromChild, "data", proc(d: JsObject) =
        let s = toNimString(d)
        link.bytesRead += s.len
        link.reader.feed(s))
      jsOn(fromChild, "end", proc() = link.readEof = true)
    if not jsIsNil(pongFrom):
      jsOnData(pongFrom, "data", proc(d: JsObject) =
        link.livenessReader.feed(toNimString(d)))
    for fd in [1, 2]:
      let s = jsStdio(child, fd)
      if not jsIsNil(s): jsOnData(s, "data", logged)
    if not jsIsNil(toChild):
      jsOn(toChild, "drain", proc() = link.writeBlocked = false)
      jsOnData(toChild, "error", proc(e: JsObject) =
        # EPIPE: the child closed its end or ended.
        link.writeFailed = true
        link.stdinOpen = false
        link.outQueue.setLen(0))
    if not jsIsNil(pingTo):
      jsOnData(pingTo, "error", proc(e: JsObject) =
        link.pingTo = nil
        link.livenessQueue.setLen(0))
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

  proc canWrite(p: ProcessLink): bool =
    p.stdinOpen and not p.child.isNil and not jsIsNil(p.toChild)

  proc hasLiveness(p: ProcessLink): bool =
    not p.child.isNil and not jsIsNil(p.pingTo)

  proc queuedBytes*(p: ProcessLink): int =
    ## The bytes the child has not taken: the link's queue plus what Node
    ## holds for the pipe.
    if p.child.isNil: return p.outQueue.len
    p.outQueue.len + jsWritableLength(p.toChild)

  proc flushWrites*(p: ProcessLink) =
    if p.livenessQueue.len > 0 and p.hasLiveness:
      discard jsWrite(p.pingTo, toBytes(p.livenessQueue))
      p.livenessQueue.setLen(0)
    if p.outQueue.len == 0 or not p.canWrite or p.writeBlocked:
      return
    let ok = jsWrite(p.toChild, toBytes(p.outQueue))
    p.outQueue.setLen(0)
    if not ok:
      p.writeBlocked = true

  proc readMessages*(p: ProcessLink; maxFrames = 4096): seq[string] =
    ## Every whole frame Node has delivered so far (at most `maxFrames`; the
    ## rest stay buffered for the next call). Stderr was taken as it came.
    if p.isNil:
      return
    var frame: string
    while true:
      case p.livenessReader.next(frame)
      of fsFrame: result.add frame
      of fsIncomplete: break
      of fsOversize:
        p.oversize = true
        break
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
    ## Close the host's side of the channel to the child (the protocol and
    ## the liveness streams): the SDK's reader sees end-of-file.
    if p.canWrite:
      jsDestroy(p.toChild)
      p.stdinOpen = false
    if p.hasLiveness:
      jsDestroy(p.pingTo)
      p.pingTo = nil

  proc closeAll*(p: ProcessLink) =
    if p.isNil or p.child.isNil: return
    p.closeStdin()
    for fd in [1, 2, ProtocolOutFd, LivenessOutFd]:
      jsDestroy(jsStdio(p.child, fd))
    if p.exit != esRunning:
      p.forget()
      p.child = nil

else:
  proc setNonBlocking(fd: cint) =
    let flags = fcntl(fd, F_GETFL)
    discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

  proc setCloexec(fd: cint) =
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)

  const ChildFdBase = cint(64)
    ## Where the child parks its pipe ends before moving them onto the
    ## channel's descriptors: above every fd the move writes to, so no `dup2`
    ## overwrites a pipe end that has not been moved yet.

  proc spawnPluginProcess*(executable: string; args: seq[string] = @[];
                           env: seq[(string, string)] = @[];
                           workingDir = "";
                           addressSpaceLimit: int64 = 0): ProcessLink =
    ## Start `executable` in a new process group, with the protocol on
    ## descriptors 3 and 4, liveness on 5 and 6 (§11.4.1), stdin on
    ## `/dev/null`, and stdout and stderr both captured for the plugin log.
    ## Raises `OSError` when the pipes or the fork fail; an exec failure shows
    ## up as an exit with status 127.
    var inPipe, outPipe, errPipe, pingPipe, pongPipe: array[2, cint]
    if pipe(inPipe) != 0 or pipe(outPipe) != 0 or pipe(errPipe) != 0 or
       pipe(pingPipe) != 0 or pipe(pongPipe) != 0:
      raiseOSError(osLastError(), "pipe for plugin process " & executable)
    # Everything the child needs is built BEFORE fork: after fork only
    # async-signal-safe calls are allowed in the child.
    var argv = allocCStringArray(@[executable] & args)
    var envStrings: seq[string]
    for k, v in envPairs():
      var overridden = k == ChannelEnv
      for (ek, _) in env:
        if ek == k: overridden = true
      if not overridden:
        envStrings.add k & "=" & v
    for (k, v) in env:
      envStrings.add k & "=" & v
    envStrings.add ChannelEnv & "=" & ChannelEnvValue
    var envp = allocCStringArray(envStrings)
    let cwd = workingDir
    let parentPid = getpid()
    # (source in the child, the descriptor it becomes)
    let moves = [(inPipe[0], cint(ProtocolInFd)), (outPipe[1], cint(ProtocolOutFd)),
                 (pingPipe[0], cint(LivenessInFd)), (pongPipe[1], cint(LivenessOutFd)),
                 (errPipe[1], cint(1)), (errPipe[1], cint(2))]
    let allEnds = [inPipe[0], inPipe[1], outPipe[0], outPipe[1], errPipe[0],
                   errPipe[1], pingPipe[0], pingPipe[1], pongPipe[0], pongPipe[1]]
    let pid = fork()
    if pid < 0:
      deallocCStringArray(argv)
      deallocCStringArray(envp)
      for fd in allEnds: discard close(fd)
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
      # Park every source above the targets, then move each onto its target.
      var parked: array[6, cint]
      for i, (src, _) in moves:
        parked[i] = fcntl(src, F_DUPFD, ChildFdBase)
        if parked[i] < 0: exitnow(127)
      for fd in allEnds: discard close(fd)
      for i, (_, dst) in moves:
        if dup2(parked[i], dst) < 0: exitnow(127)
      for fd in parked: discard close(fd)
      let devNull = posix.open("/dev/null", O_RDONLY)
      if devNull >= 0 and devNull != 0:
        discard dup2(devNull, 0)
        discard close(devNull)
      if cwd.len > 0:
        discard chdir(cwd.cstring)
      discard execve(argv[0], argv, envp)
      exitnow(127)
    # ---- the parent ---------------------------------------------------------
    deallocCStringArray(argv)
    deallocCStringArray(envp)
    for fd in [inPipe[0], outPipe[1], errPipe[1], pingPipe[0], pongPipe[1]]:
      discard close(fd)
    for fd in [inPipe[1], outPipe[0], errPipe[0], pingPipe[1], pongPipe[0]]:
      setNonBlocking(fd)
      setCloexec(fd)
    ProcessLink(pid: pid, executable: executable, toChild: inPipe[1],
                fromChild: outPipe[0], errFromChild: errPipe[0],
                pingTo: pingPipe[1], pongFrom: pongPipe[0])

  proc flushQueue(fd: var cint; queue: var string; failed: var bool) =
    while queue.len > 0 and fd >= 0:
      let n = posix.write(fd, queue[0].addr, queue.len)
      if n > 0:
        queue = queue[n .. ^1]
      elif n < 0 and (errno == EAGAIN or errno == EWOULDBLOCK):
        return
      elif n < 0 and errno == EINTR:
        continue
      else:
        failed = true
        discard close(fd)
        fd = -1
        queue.setLen(0)
        return

  proc flushWrites*(p: ProcessLink) =
    var livenessFailed = false
    flushQueue(p.pingTo, p.livenessQueue, livenessFailed)
    flushQueue(p.toChild, p.outQueue, p.writeFailed)

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
    # The `pong`s first: they are what says the process is alive, and they
    # come on a descriptor of their own (§11.4.1).
    var pongEof = false
    drainFd(p.pongFrom, proc(d: string) = link.livenessReader.feed(d), pongEof)
    var frame: string
    while true:
      case p.livenessReader.next(frame)
      of fsFrame: result.add frame
      of fsIncomplete: break
      of fsOversize:
        p.oversize = true
        break
    var eof = false
    drainFd(p.fromChild, proc(d: string) =
      link.bytesRead += d.len
      link.reader.feed(d), eof)
    if eof: p.readEof = true
    while result.len < maxFrames:
      case p.reader.next(frame)
      of fsFrame: result.add frame
      of fsIncomplete: break
      of fsOversize:
        p.oversize = true
        break

  proc readPongs*(p: ProcessLink): seq[string] =
    ## Only the liveness descriptor's frames (the `pong`s), leaving the
    ## protocol's unread: what a suite uses to keep the protocol pipe full
    ## while it measures liveness.
    if p.isNil:
      return
    var eof = false
    let link = p
    drainFd(p.pongFrom, proc(d: string) = link.livenessReader.feed(d), eof)
    var frame: string
    while p.livenessReader.next(frame) == fsFrame:
      result.add frame

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
    ## Close the host's side of the channel to the child (the protocol and
    ## the liveness descriptors): the SDK's reader sees end-of-file.
    if p.toChild >= 0:
      discard close(p.toChild)
      p.toChild = -1
    if p.pingTo >= 0:
      discard close(p.pingTo)
      p.pingTo = -1

  proc closeAll*(p: ProcessLink) =
    if p.isNil: return
    p.closeStdin()
    if p.fromChild >= 0:
      discard close(p.fromChild)
      p.fromChild = -1
    if p.errFromChild >= 0:
      discard close(p.errFromChild)
      p.errFromChild = -1
    if p.pongFrom >= 0:
      discard close(p.pongFrom)
      p.pongFrom = -1

  proc canWrite(p: ProcessLink): bool = p.toChild >= 0

  proc hasLiveness(p: ProcessLink): bool = p.pingTo >= 0

  proc queuedBytes*(p: ProcessLink): int = p.outQueue.len

proc send*(p: ProcessLink; msg: JsonNode): bool {.discardable.} =
  ## Queue `msg` for the child. False when the frame is over the cap or the
  ## queue is already past `MaxQueuedBytes` (the child is not reading).
  if p.isNil or not p.canWrite:
    return false
  let frame = encodeMessage(msg)
  if frame.len == 0:
    return false
  if msg{"type"}.getStr("") == "ping" and p.hasLiveness:
    # §11.4.1: a `ping` goes on the liveness descriptor, never behind the
    # frames queued for a child that is slow to read them.
    if p.livenessQueue.len > MaxLivenessQueuedBytes:
      return false
    p.livenessQueue.appendBytes frame
    return true
  if p.queuedBytes > MaxQueuedBytes:
    return false
  # A frame of any size (`byte_append`): `add` throws on the JS backend.
  p.outQueue.appendBytes frame
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
