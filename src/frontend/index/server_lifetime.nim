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
## * SIGKILL cannot be handed on. The server notices instead that its parent
##   has gone: an orphan is re-parented, so `process.ppid` changes. That is
##   checked once a second; the check is the portable spelling of Linux's
##   `PR_SET_PDEATHSIG`, which node cannot set on itself.
##
## Only the server build (`-d:server`, `server_index.js`) installs these; the
## Electron index has its own handlers in `src/frontend/index.nim`.

import
  std / [ jsffi ],
  electron_vars, window,
  ../lib/[ electron_lib ],
  ../../common/ct_logging

const ParentCheckIntervalMs = 1_000
  ## How often the server looks for its parent. The cost is one `getppid(2)`;
  ## the bound is how long a server outlives a SIGKILLed `ct host`.

proc currentPpid(): int {.importjs: "(process.ppid)".}

proc processAlive(pid: int): bool {.importjs: """
  (function (pid) {
    try { process.kill(pid, 0); return true; }
    catch (e) { return e.code === 'EPERM'; }
  })(#)""".}
  ## Signal 0 checks for the process without signalling it. EPERM means it
  ## exists but belongs to someone else, which is still "alive".

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

  # The watch is armed only when the parent is the caller that started us
  # (`ct host` passes its own pid as `--caller-pid`): a server started by hand,
  # or with `--caller-pid 0` as the integration tests do, has no owner whose
  # death should end it.
  let owner = callerProcessPid
  let parentAtStart = currentPpid()
  if owner > 0 and parentAtStart == owner:
    unrefInterval(proc() =
      if currentPpid() != parentAtStart or not processAlive(owner):
        shutDown("ct host (pid " & $owner & ") is gone", 0)
    , ParentCheckIntervalMs)
