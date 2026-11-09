## test_native_record_job_poll.nim — Tier 1: `pollRecordJob` returns at once.
##
## The welcome tab's *Record new trace* and the top bar's run-tests poll their
## `ct record` / `ct record-test` child from the loop that reads input. The
## poll used `osproc.hasData`, which on POSIX is a `select` with NO timeout:
## it waited until the child wrote, so a recording that printed nothing for a
## while froze the window for that long.
##
## No mocks: a real child (`/bin/sh`) and a real pipe, wired into a real
## `NativeRecordJob` the way `startRecordJob` does. Only the child's
## behaviour (silence, then output) is arranged; it is the subject. The count
## of polls that returned while the child was silent is the load-bearing
## assertion (it is 0 with the blocking poll), the clock only corroborates.

import std/[monotimes, os, osproc, strutils, times, unittest]

import ../host/native_host

const
  SilenceMs = 2000
  TickMs = 20
  MinPollsWhileSilent = 20

proc jobRunning(script: string; log: string): NativeRecordJob =
  writeFile(log, "")
  NativeRecordJob(
    program: "probe", logPath: log,
    process: startProcess("/bin/sh", args = @["-c", script],
                          options = {poStdErrToStdOut}))

suite "pollRecordJob never blocks on a quiet child":
  test "a child silent for two seconds does not hold the loop":
    let log = getTempDir() / ("native-record-poll-" & $getCurrentProcessId())
    let job = jobRunning("sleep 2; echo first; printf tail-no-newline", log)
    defer: removeFile(log)
    var polls, whileRunning, worstMs = 0
    let start = getMonoTime()
    while (getMonoTime() - start).inMilliseconds < SilenceMs * 5:
      let before = getMonoTime()
      let finished = pollRecordJob(job)
      worstMs = max(worstMs, int((getMonoTime() - before).inMilliseconds))
      inc polls
      if finished:
        break
      inc whileRunning
      sleep(TickMs)
    checkpoint "polls=" & $polls & " whileRunning=" & $whileRunning &
               " worstMs=" & $worstMs
    check job.done
    check whileRunning >= MinPollsWhileSilent
    check worstMs < SilenceMs div 3
    # Non-blocking must not be lossy: the whole output reached the log,
    # including the unterminated tail.
    check readFile(log) == "first\ntail-no-newline"

  test "a quiet `ct record-test` run is polled to its recording id":
    # The whole run-tests path (`startRecordTestJob` -> `findCtBinary` ->
    # `pollRecordJob`), with `CT_BIN` naming a stand-in for `ct`: a script
    # that is quiet, then prints the marker `recordingId:` line the host
    # reads back from the log. The stand-in only supplies the child's
    # behaviour; the job, the pipe and the log are the real ones.
    let dir = getTempDir() / ("native-record-test-job-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    let fakeCt = dir / "ct"
    writeFile(fakeCt, "#!/bin/sh\nsleep 2\necho recordingId: abc123\n")
    setFilePermissions(fakeCt, {fpUserRead, fpUserWrite, fpUserExec})
    let prior = getEnv("CT_BIN")
    putEnv("CT_BIN", fakeCt)
    defer:
      if prior.len > 0: putEnv("CT_BIN", prior) else: delEnv("CT_BIN")
    let job = startRecordTestJob(dir / "some_test.nim")
    defer: removeFile(job.logPath)
    check job.process != nil
    var whileRunning, worstMs = 0
    let start = getMonoTime()
    while (getMonoTime() - start).inMilliseconds < SilenceMs * 5:
      let before = getMonoTime()
      let finished = pollRecordJob(job)
      worstMs = max(worstMs, int((getMonoTime() - before).inMilliseconds))
      if finished:
        break
      inc whileRunning
      sleep(TickMs)
    checkpoint "whileRunning=" & $whileRunning & " worstMs=" & $worstMs
    check job.done
    check job.ok
    check job.recordingId == "abc123"
    check whileRunning >= MinPollsWhileSilent
    check worstMs < SilenceMs div 3
