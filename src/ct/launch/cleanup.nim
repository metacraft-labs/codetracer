import
  std/[osproc, os, strformat],
  ../../common/[types],
  ../globals

when not defined(windows):
  import std/posix

var onInterrupt: proc: void
proc cleanup*: void {.noconv.} =
  echo "codetracer: cleanup!"
  if not onInterrupt.isNil:
    onInterrupt()
  # important: signal handlers should be
  # signal-safe https://man7.org/linux/man-pages/man7/signal-safety.7.html

  # Franz found an issue
  # https://gitlab.com/metacraft-labs/code-tracer/CodeTracer/-/merge_requests/116#note_1360620095
  # which shows maybe we need to stop the electron process if not stopped too
  if electronPid != -1:
    when defined(windows):
      discard
    else:
      discard kill(electronPid.Pid, SIGKILL)

proc stop*(process: Process) =
  process.terminate()

# stop a process by its name: TODO we shouldn't need something like that
# especially if we support several codetracer instances in the same time
proc stopProcess*(processName: string, arg: string = "-SIGINT") =
  ensureExists("killall")
  discard execShellCmd(fmt"killall {arg} " & processName)

proc stopCoreProcess*(process: Process, recordCore: bool) =
  if not recordCore:
    discard
    echo "stop core process"
    # send SIGTERM so we can cleanup and stop task processes from core
    process.stop()

    echo "[codetracer PID]: ", getCurrentProcessId()
  else:
    # rr is probably `process`, but we want to stop only
    # the core process, not rr itself
    # so rr can finish the recording
    # of our core process correctly
    #
    # TODO: adapt for rr/gdb backend? here assuming db-backend
    # TODO: stops all db-backend processes
    # so it would break other running codetracer instances
    # stop only our one: getting the pid from process/output/file?
    echo ""
    echo "stopping dispatcher:"
    stopProcess("db-backend", arg="-SIGINT")
    echo ""
    echo "stopping dispatcher: might show an exception.."
    echo "(if it's not from dispatcher, then probably it's a codetracer bug)"
    echo "WAIT FOR \"record ready\" message"
    echo ""

when not defined(windows):
  onSignal(SIGINT):
    cleanup()
    quit(1)

  onSignal(SIGTERM):
    cleanup()
    quit(0)
