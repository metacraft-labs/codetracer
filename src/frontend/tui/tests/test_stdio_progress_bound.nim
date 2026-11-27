## A read bound that counts the engine's stderr as progress
## (`DapReadBound.progressCapMs`).
##
## Opening a native rr recording through the pane server took 32.6 s once on
## a loaded host (2026-11-26), its rr worker logging all the while, and the
## open was refused at the 30 s per-message budget; the next runs took 9.9 s
## and 5.9 s. A real replay cannot be made deliberately slow, so the child is
## this same executable, launched through the real `startReplayServer`
## boundary, writing to stderr on a schedule this test owns: THE ONE STAND-IN,
## and not a mock — process creation, the pipes, the stderr capture, the
## bound and the DAP decoding are production code. The budgets are
## a few seconds and the engine logs every 50 ms, so no case turns on
## scheduling: a child descheduled for well over a second between two lines
## still logs again inside the 3 s budget.

import std/[json, monotimes, os, strutils, times, unittest]
import ../../viewmodel/backend/stdio_backend

const Event = "{\"type\":\"event\",\"event\":\"initialized\",\"seq\":1}"

proc logLines(forMs, everyMs: int) =
  let start = getMonoTime()
  var n = 0
  while forMs < 0 or (getMonoTime() - start).inMilliseconds < forMs:
    inc n
    stderr.write("[rr-worker] still opening " & $n & "\n")
    stderr.flushFile()
    sleep(everyMs)

if paramCount() >= 1 and paramStr(1) == "dap-server":
  case getEnv("CT_PROGRESS_BOUND_MODE")
  of "logs-then-answers":
    # logs for 8 s, well past the 3 s budget, then answers
    logLines(8000, 50)
    stdout.write("Content-Length: " & $Event.len & "\r\n\r\n" & Event)
    stdout.flushFile()
  of "logs-for-ever":
    logLines(-1, 50)
  of "silent":
    discard
  else: discard
  sleep(60_000)
  quit(0)

proc start(mode: string; bound: DapReadBound): DapStdioBackend =
  putEnv("CT_PROGRESS_BOUND_MODE", mode)
  defer: delEnv("CT_PROGRESS_BOUND_MODE")
  startReplayServer(getAppFilename(), bound = bound)

proc firstMessage(mode: string; bound: DapReadBound):
    tuple[message: JsonNode; stalled: string; ms: int64] =
  let backend = start(mode, bound)
  defer: backend.close()
  let at = getMonoTime()
  try:
    result.message = backend.readDapMessage()
  except DapStalledError as e:
    result.stalled = e.msg
  result.ms = (getMonoTime() - at).inMilliseconds

suite "a read bound that counts the engine's stderr as progress":
  test "an engine logging past the budget is waited for, and its answer read":
    let got = firstMessage("logs-then-answers",
      DapReadBound(timeoutMs: 3000, interruptFd: -1, progressCapMs: 60_000))
    checkpoint("stalled: " & got.stalled)
    check got.stalled == ""
    check not got.message.isNil and got.message{"event"}.getStr == "initialized"
    check got.ms >= 7000

  test "the plain per-message budget refuses the same engine (the defect)":
    let got = firstMessage("logs-then-answers",
      DapReadBound(timeoutMs: 3000, interruptFd: -1))
    check "sent nothing for 3000 ms" in got.stalled
    check got.ms < 7000

  test "an engine that logs for ever and never answers is refused at the cap":
    let got = firstMessage("logs-for-ever",
      DapReadBound(timeoutMs: 3000, interruptFd: -1, progressCapMs: 16_000))
    check "though it kept logging" in got.stalled
    check got.ms >= 15_900 and got.ms < 40_000

  test "a silent engine is still refused at the budget":
    let got = firstMessage("silent",
      DapReadBound(timeoutMs: 3000, interruptFd: -1, progressCapMs: 60_000))
    check "sent nothing for 3000 ms" in got.stalled
    check got.ms < 15_000
