## Unit tests for ``recorder_version_probe``: the ``<recorder> --version``
## probe ``ct record`` runs, on its failure path only, to REPORT the version
## of a recorder that wrote a trace format version this ``ct`` refuses
## (GitHub #909, ``CLI/ct/record.md`` §"Corner Cases", "Recorder present but
## wrong version").
##
## The probe may never change the outcome and may never hold it up: the
## refusal is printed after it returns.  So these cases pin three things
## about it, each through a real child process (a ``/bin/sh`` script, the
## shape most recorder wrappers have):
##
## * the cap is a real bound on WALL time, including when the direct child
##   is a wrapper whose own child holds the output pipe -- and that child
##   does not outlive the probe;
## * a ``--version`` that exits non-zero is "no version", whatever it
##   printed (an error text is not a version);
## * a version line is the first non-empty line, stripped.
##
## Mocking justification (workspace policy on mock objects): none.  The
## scripts are real executables the probe really runs.
##
## Compile and run:
##   nim c -r src/ct/trace/recorder_version_probe_test.nim

when not defined(posix):
  {.fatal: "recorder_version_probe_test drives /bin/sh scripts: POSIX only".}

import std/[os, posix, strutils, times, unittest]
import recorder_version_probe

proc scratchDir(name: string): string =
  result = getTempDir() / "ct-recorder-version-probe-test" / name
  removeDir(result)
  createDir(result)

proc writeScript(dir, name, body: string): string =
  ## An executable ``/bin/sh`` script ``dir/name`` with ``body``.
  result = dir / name
  writeFile(result, "#!/bin/sh\n" & body)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc alive(pid: Pid): bool =
  ## ``kill(pid, 0)`` succeeds while ``pid`` exists (a zombie included).
  posix.kill(pid, 0) == 0

suite "recorder --version probe":

  test "a recorder that answers is reported by its first non-empty line":
    # The control for every "no version" case below: the same probe, a
    # script that answers, a version comes back.
    let dir = scratchDir("answers")
    let exe = writeScript(dir, "recorder",
      "echo\necho '  tool version = 1.2.3  '\necho second line\n")
    check recorderVersionLine(exe) == "tool version = 1.2.3"

  test "a --version that outlives the cap returns within the cap, and its wrapper's child does not survive (#909 review)":
    # The review's case: the direct child is a `/bin/sh` wrapper and the
    # process that holds the output pipe is ITS child.  Killing only the
    # direct child and then reading the pipe to EOF waits for the
    # grandchild: here 30 s, against a 300 ms cap.  The grandchild's own
    # 30 s is the watchdog -- a probe that waits for it still returns, and
    # this case then fails by name on the elapsed time instead of wedging.
    let dir = scratchDir("hangs")
    let pidFile = dir / "grandchild.pid"
    let exe = writeScript(dir, "recorder",
      "/bin/sleep 30 &\n" &
      "echo $! > " & quoteShell(pidFile) & "\n" &
      "wait\n" &
      "echo late\n")
    const capMs = 300
    let started = epochTime()
    let line = recorderVersionLine(exe, timeoutMs = capMs)
    let elapsed = epochTime() - started
    checkpoint("probe returned " & line.escape & " after " &
               formatFloat(elapsed, ffDecimal, 2) & " s")
    check line == ""
    # The cap, plus the probe's grace between SIGTERM and SIGKILL, plus
    # slack for a loaded host: far below the grandchild's 30 s.
    check elapsed < capMs / 1000 + 4.0

    # And the grandchild was taken down with its wrapper rather than left
    # running with the pipe.  It is reparented and reaped once killed, so
    # give that a moment before calling it a survivor.
    require fileExists(pidFile)
    let grandchild = Pid(parseInt(readFile(pidFile).strip()))
    let deadline = epochTime() + 3.0
    while alive(grandchild) and epochTime() < deadline:
      sleep(50)
    let survived = alive(grandchild)
    if survived:
      discard posix.kill(grandchild, SIGKILL)   # do not leave it behind
    check not survived

  test "a --version that exits non-zero is reported as no version (#909 review)":
    # An error text is not a version: "reports: error: unknown option"
    # would put the recorder's complaint where its version belongs.
    let dir = scratchDir("fails")
    let exe = writeScript(dir, "recorder",
      "echo 'error: unrecognized option --version' >&2\nexit 2\n")
    check recorderVersionLine(exe) == ""

  test "a file that is not executable is not run":
    let dir = scratchDir("not-executable")
    let path = dir / "recorder"
    writeFile(path, "#!/bin/sh\necho should-not-run\n")
    setFilePermissions(path, {fpUserRead, fpUserWrite})
    check recorderVersionLine(path) == ""
    check recorderVersionLine(dir / "absent") == ""
    check recorderVersionLine("") == ""
