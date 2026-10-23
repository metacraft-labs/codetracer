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
  ## read on Linux and a signal 0 elsewhere, plus one `ps` spawn off Linux when
  ## node runs behind a wrapper (`zombieOffLinux`); the bound is how long a
  ## server outlives a SIGKILLed `ct host`.

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

proc zombieOffLinux(pid: int): bool {.importjs: """
  (function (pid) {
    if (process.platform === 'linux' || process.platform === 'win32') { return false; }
    try {
      var out = require('child_process').execFileSync('ps', ['-o', 'stat=', '-p', String(pid)],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 2000 });
      return out.trim().charAt(0) === 'Z';
    } catch (e) { return false; }
  })(#)""".}
  ## Whether a process that still answers signal 0 is a zombie, where there is
  ## no `/proc` to say so: `ps -o stat=` prints the state, `Z` for a zombie
  ## (https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ps.html; the
  ## `stat` keyword is the BSD and procps spelling of it). It costs a process
  ## spawn, so it is asked only when nothing cheaper can tell: off Linux, with
  ## node behind a wrapper (our parent is not the owner, so re-parenting says
  ## nothing). A `ps` that fails answers "not a zombie", which leaves the
  ## server as it was rather than ending it on a guess.

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
  # without telling us. Off Linux an unreaped zombie still answers signal 0,
  # so the direct case relies on re-parenting and the wrapper case on `ps`.
  let owner = callerProcessPid
  # `not (owner > 0)` rather than `owner <= 0`: a `--caller-pid` (or
  # `CODETRACER_CALLER_PID`) that does not parse is NaN here, and NaN compares
  # false both ways. It names no owner, so it must not read as one already gone.
  if not (owner > 0):
    return
  let ownerStart = processStartTime(owner)
  let parentAtStart = currentPpid()
  # An owner already gone is the same event caught early: `ct host` died while
  # node was starting, before any watch could see it go. Serving on would
  # leave exactly the orphan the watch exists to prevent.
  if processGone(owner, ownerStart):
    shutDown("ct host (pid " & $owner & ") was gone before the server started", 0)
  else:
    unrefInterval(proc() =
      if (parentAtStart == owner and currentPpid() != parentAtStart) or
          processGone(owner, ownerStart) or
          (parentAtStart != owner and zombieOffLinux(owner)):
        shutDown("ct host (pid " & $owner & ") is gone", 0)
    , ParentCheckIntervalMs)
