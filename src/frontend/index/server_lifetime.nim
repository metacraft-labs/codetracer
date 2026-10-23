## The `ct host` server's lifetime: it ends when `ct host` ends.
##
## `CLI/ct/host.md`, "Corner Cases" ("`ct host` is stopped or killed"): `ct
## host` and every process it started end together, however `ct host` ends.
## Two halves make that hold:
##
## * `ct host` hands SIGTERM, SIGINT and SIGHUP on to this server
##   (`src/ct/trace/host.nim`, `forwardTerminationSignals`), and the handlers
##   installed here stop the session-manager — and with it the replays — before
##   the server exits. Without a handler node's default action for these
##   signals ends the process without running the `exit` hooks, so the
##   session-manager was left behind even when the signal did arrive.
## * SIGKILL cannot be handed on, and neither can a signal when node runs
##   behind a wrapper that forks it (`CODETRACER_NODE_EXE_PATH`). The server
##   notices instead that `ct host` (its `--caller-pid`) has gone: it no longer
##   runs, is a zombie, or, when it was our direct parent, we were
##   re-parented. That is checked once a second; it stands in for Linux's
##   `PR_SET_PDEATHSIG`, which node cannot set on itself and which would not
##   reach past a wrapper anyway.
##
## Only the server build (`-d:server`, `server_index.js`) installs these; the
## Electron index has its own handlers in `src/frontend/index.nim`.

import
  std / [ jsffi ],
  electron_vars, window,
  ../lib/[ electron_lib ],
  ../../common/ct_logging

const ParentCheckIntervalMs = 1_000
  ## How often the server looks for `ct host`. The cost is one small `/proc`
  ## read; the bound is how long a server outlives a SIGKILLed `ct host`.

proc currentPpid(): int {.importjs: "(process.ppid)".}

proc processStartTime(pid: int): cstring {.importjs: """
  (function (pid) {
    if (process.platform !== 'linux') { return ''; }
    try {
      var stat = require('fs').readFileSync('/proc/' + pid + '/stat', 'utf8');
      return stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19] || '';
    } catch (e) { return ''; }
  })(#)""".}
  ## Field 22 of `/proc/<pid>/stat` (proc(5)): with the pid, it names one
  ## process, so a recycled pid does not read as the owner. Empty off Linux.

proc processGone(pid: int; startTime: cstring): bool {.importjs: """
  (function (pid, start) {
    if (process.platform === 'linux') {
      var stat;
      try { stat = require('fs').readFileSync('/proc/' + pid + '/stat', 'utf8'); }
      catch (e) { return true; }
      var fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
      if (fields[0] === 'Z' || fields[0] === 'X') { return true; }
      return start !== '' && fields[19] !== start;
    }
    try { process.kill(pid, 0); return false; }
    catch (e) { return e.code !== 'EPERM'; }
  })(#, #)""".}
  ## Whether the process is no longer running. On Linux a ZOMBIE counts as
  ## gone: a SIGKILLed `ct host` stays one until whatever started it reaps it,
  ## and signal 0 still succeeds on a zombie. Elsewhere signal 0 is the test;
  ## EPERM means the process exists but belongs to someone else.

proc unrefInterval(callback: proc(), delayMs: int) {.importjs: """
  (function (cb, ms) { var t = setInterval(cb, ms); if (t.unref) { t.unref(); } })(#, #)""".}
  ## `unref` so the watch never by itself keeps the server alive.

var shuttingDown = false

proc shutDown(reason: string; code: int) =
  if shuttingDown:
    return
  shuttingDown = true
  infoPrint "ct host server: ", reason, "; stopping the session-manager and exiting"
  stopBackendManager()
  nodeProcess.exit(code)

proc installServerLifetime*() =
  ## Install the signal handlers and the parent watch. Call once, at startup,
  ## after the arguments are parsed (`callerProcessPid` comes from
  ## `--caller-pid`).
  # 128 + the signal number: the status a shell reports for a process the
  # signal ended, so a supervisor reading it sees the same thing it would have
  # seen without the handler.
  for (name, number) in [("SIGTERM", 15), ("SIGINT", 2), ("SIGHUP", 1)]:
    let signalName = name
    let status = 128 + number
    nodeProcess.on(cstring(signalName)) do ():
      shutDown("received " & signalName, status)

  # Whatever else ends the server (the idle timeout, an error) still stops the
  # session-manager. `stopBackendManager` runs once however often it is called.
  nodeProcess.on(cstring"exit") do (code: int):
    stopBackendManager()

  # The owner is the caller that started us (`ct host` passes its own pid as
  # `--caller-pid`); a server started by hand, or with `--caller-pid 0` as the
  # integration tests do, has none whose death should end it.
  #
  # The owner is watched directly, not only through `process.ppid`: when
  # `CODETRACER_NODE_EXE_PATH` names a wrapper that forks node rather than
  # exec'ing it, our parent is the wrapper, which may outlive `ct host` or die
  # without telling us. The ppid check stays for the direct case off Linux,
  # where an unreaped zombie still answers signal 0.
  let owner = callerProcessPid
  let ownerStart = processStartTime(owner)
  let parentAtStart = currentPpid()
  if owner > 0 and not processGone(owner, ownerStart):
    unrefInterval(proc() =
      if (parentAtStart == owner and currentPpid() != parentAtStart) or
          processGone(owner, ownerStart):
        shutDown("ct host (pid " & $owner & ") is gone", 0)
    , ParentCheckIntervalMs)
