## ``<recorder> --version``, asked by ``ct record`` on ONE path only: the
## recorder exited 0 but wrote a trace format version this ``ct`` refuses
## (GitHub #909; ``CLI/ct/record.md`` §"Corner Cases", "Recorder present but
## wrong version": "Report both versions").  The answer is quoted in
## ``recorder_dispatch.staleRecorderMessage``; it never changes the outcome,
## and it may not delay it either, because the refusal is printed after the
## probe returns.
##
## Why ``runquota_process`` and not ``std/osproc``.  The first version used
## ``startProcess`` + ``waitForExit(timeout)`` + ``outputStream.readAll()``.
## That cap was not a bound: on a timeout ``waitForExit`` kills the DIRECT
## child only (and reports its signal status, so a ``-1`` "still running"
## arm never ran), and ``readAll`` then reads the pipe to EOF -- which comes
## only when every process holding the write end has exited.  A recorder
## that is a ``#!/bin/sh`` wrapper, the usual shape, has its real work in a
## grandchild that holds that pipe, so ``sleep 20; echo late`` held the
## refusal for 20 s against a 5 s cap.  ``runquota_process`` starts the
## child in its own process group, polls the pipes against a deadline, and
## on a timeout signals the whole GROUP (SIGTERM, then SIGKILL after 1 s;
## a Job Object on Windows), draining only what is already there.  It is
## the runner ``ct test``'s providers already use (``ct_test/process_exec``).

import std/[ os, strutils ]
import runquota_process

const
  RecorderVersionProbeTimeoutMs* = 5_000
    ## How long ``--version`` gets.  The probe returns within this plus the
    ## runner's 1 s SIGTERM-to-SIGKILL grace, whatever the recorder's
    ## children do.
  RecorderVersionCaptureLimit = 64 * 1024
    ## A version is one line; the bound only keeps a chatty recorder from
    ## filling memory.

proc recorderVersionLine*(exe: string,
                          timeoutMs = RecorderVersionProbeTimeoutMs): string =
  ## The first non-empty line, stripped, that ``<exe> --version`` prints
  ## when it exits 0 within ``timeoutMs``; "" otherwise -- when ``exe`` is
  ## not an executable file, cannot be started, does not answer in time
  ## (it is killed with its process group), is killed by a signal, or exits
  ## non-zero (what a failing ``--version`` prints is an error, not a
  ## version), or prints nothing.  Never raises.
  if exe.len == 0 or not fileExists(exe):
    return ""
  try:
    if fpUserExec notin getFilePermissions(exe):
      return ""
    var child = launchProcess(commandSpec(
      argv = [exe, "--version"],
      stdoutLimit = RecorderVersionCaptureLimit,
      stderrLimit = RecorderVersionCaptureLimit,
      createProcessGroup = true))
    defer: child.close()
    let done = waitForCompletion(child, timeoutMs)
    if done.timedOut or not done.exited or done.exitCode != 0:
      return ""
    # POSIX launches merge stderr into stdout; a backend that keeps them
    # apart still has its version looked for in both, stdout first.
    for line in (done.stdout & "\n" & done.stderr).splitLines():
      if line.strip().len > 0:
        return line.strip()
  except CatchableError:
    discard
  ""
