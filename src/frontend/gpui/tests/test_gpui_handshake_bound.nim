## test_gpui_handshake_bound.nim — **the shipped `codetracer-gpui` gives up on
## a replay engine that acknowledged `launch` and then went silent, exits with
## a named code and says so on stderr, instead of waiting for ever with both
## streams empty.**
##
## Run (needs `just build-gpui`, `python3` on `PATH`, the `calc` recording
## under `test-logs/tui-fixtures/` and `REPLAY_SERVER_BIN` naming a built
## `replay-server`):
##   nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_gpui_handshake_bound.nim
##
## `codetracer-pm/issues/2026-10-02-codetracer-gpui-hangs-for-ever-on-a-replay-server-that-never-reports-a-stop.md`
## measured `codetracer-gpui --report-plan <trace>` killed by `timeout` at
## 100 s with 0 bytes on stdout and on stderr: `replay-server` had answered
## `initialize`, `initialized`, `configurationDone` and `launch` (`success:
## true`) and then never sent `stopped`, and `gpui_host.openGpuiTrace` opened
## the recording with no `DapReadBound`, so the handshake's read never
## returned. The terminal front-end had had the clock (`native_host
## .DefaultHandshakeMs`) for a milestone. This suite runs the REAL binary and
## asserts the contract that replaces the hang:
##
##   * an engine that goes quiet after acknowledging `launch` ends the run with
##     `ExitEngineStalled` (4) inside the budget `CODETRACER_GPUI_HANDSHAKE_MS`
##     sets, and stderr names the folder and the stall — under a watchdog, so
##     the pre-fix behaviour FAILS here rather than hanging the lane;
##   * a stall AFTER the open (the engine reached its first stop, then went
##     quiet on a pane request) is the same exit 4, worded as such and
##     WITHOUT the open's "re-record it" advice, which cannot help a recording
##     the engine has read — and the engine, which in that case ignores its
##     stdin closing as a busy engine does, is killed rather than left behind;
##   * with no override the shipped default budget applies (it is a clock, not
##     an opt-in);
##   * the engine is reaped: the stalled child does not outlive the front-end;
##   * an engine that says WHY (`ct/launch-failed`) is still reported as that
##     refusal, verbatim, with `ExitUnreadableRecording` (5) — the bound must
##     not swallow the stated reason into a stall;
##   * the NEGATIVE TWIN: the same binary, the same budget override and the
##     real `replay-server` on the real `calc` recording still opens and prints
##     a plan, so the bound refuses a silent engine and not a working one.
##   * the clock covers the OPEN and not the window: a session
##     `openGpuiTrace` returns carries the override's budget, and
##     `liftOpenBound` — what the window calls before it takes input — leaves
##     it unbounded, so an operation that is silent by design (a tracepoint
##     sweep over a large recording) is not reported as a stall. This one case
##     runs in-process, because the featureless shim this lane links refuses
##     the window before the binary would reach that line.
##
## ## The one stand-in, and why it is justified
##
## The stalled and refusing engines are a FAKE `replay-server`: a ~40-line
## Python DAP peer this suite writes to a scratch directory and hands to the
## binary through `REPLAY_SERVER_BIN`, the same discovery override every
## headless suite uses. A real engine cannot be used for these two cases:
##
##   * "acknowledges `launch`, then sends nothing" is the FAILURE SHAPE under
##     test, and the real `replay-server` reaches it only through a host- or
##     recording-specific defect (the issue's two triggers — a stale reader and
##     a `meta.dat` v3 container — have each since been FIXED to produce a
##     `ct/launch-failed` instead). A test that depended on one would stop
##     testing the bound the day that defect was fixed, and pass vacuously.
##   * The front-end's contract is with the DAP STREAM, not with the engine's
##     internals: the bound must hold for ANY peer that goes quiet at a message
##     boundary. The fake reproduces exactly the byte sequence the issue
##     transcribed (four `success: true` responses and an `initialized` event,
##     then silence) and nothing more.
##
## Everything else is real: the shipped binary, its real argument parsing,
## its real `openGpuiTrace` → `openLocalTrace` → `newHeadlessDebugSession`
## path, real pipes, and — in the negative twin — the real engine on a real
## recording. The fake records each command it acknowledged, and the stall case
## asserts it saw `launch`, so a pass cannot come from failing EARLIER than the
## shape the issue describes (a spawn failure, a refused folder).

import std/[os, osproc, strtabs, strutils, tempfiles, times, unittest]

import gpui/host/gpui_host

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  ExitEngineStalled = 4
    ## The terminal front-end's `cli.ExitEngineStalled`, restated: this suite
    ## asserts the number the CONTRACT publishes (`codetracer-pm/spec/CLI/ct/
    ## ui-selection.md` §8b), so importing the constant under test would let
    ## the two move together.
  ExitUnreadableRecording = 5
    ## `cli.ExitUnreadableRecording`, restated for the same reason.
  HandshakeEnv = "CODETRACER_GPUI_HANDSHAKE_MS"
    ## The GPUI front-end's override, spelled again rather than imported for
    ## the same reason: a rename must fail here.
  BudgetMs = 10_000
    ## Short enough that the stall fires in seconds, long enough that the real
    ## engine opening `calc` on a loaded host never runs into it in the twin
    ## (measured well under a second per message there).
  DefaultBudgetMs = 30_000
    ## `native_host.DefaultHandshakeMs`, restated.
  WatchdogSeconds = 120.0
    ## Finite, and well past every budget above: the pre-fix behaviour was
    ## "never returns", and the lane must not inherit it.
  RefusalText =
    "trace container version 3 is not supported by this build; re-record it"
    ## What the fake engine says in its `ct/launch-failed`. The front-end must
    ## carry it through verbatim.

  FakeEngine = """
#!/usr/bin/env python3
# A DAP peer standing in for `replay-server` in a GPUI suite; see the header
# of test_gpui_handshake_bound.nim for why a fake is justified here.
#
# FAKE_ENGINE_MODE=stall  -- answer initialize / configurationDone / launch
#                            with success, send `initialized`, then go silent.
# FAKE_ENGINE_MODE=refuse -- the same, then a `ct/launch-failed` event.
# FAKE_ENGINE_MODE=settle -- the same as stall, but reach the first stop
#                            (`stopped` + `ct/complete-move`) and THEN go
#                            silent: every later request is read and never
#                            answered, and its stdin closing is ignored.
#
# stdout is the DAP channel and the front-end merges stderr into it, so this
# script writes NOTHING to stderr. It records each command it acknowledged
# (and its pid) in $FAKE_ENGINE_LOG.
import json, os, sys, time

mode = os.environ.get("FAKE_ENGINE_MODE", "stall")
log_path = os.environ["FAKE_ENGINE_LOG"]
seq = 0

def note(line):
    with open(log_path, "a") as f:
        f.write(line + "\n")

def send(obj):
    global seq
    seq += 1
    obj["seq"] = seq
    body = json.dumps(obj).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()

def read():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            if mode == "settle":
                # A post-open stall is an engine busy elsewhere: it does not
                # notice its stdin closing, so only the front-end killing it
                # ends it. The case asserts that it does.
                time.sleep(600)
            sys.exit(0)          # the front-end closed the pipe: we are done
        line = line.strip()
        if not line:
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
    return json.loads(sys.stdin.buffer.read(length))

HANDSHAKE = ("initialize", "configurationDone", "launch")

note("pid %d" % os.getpid())
while True:
    msg = read()
    cmd = msg.get("command")
    if mode == "settle" and cmd not in HANDSHAKE:
        note("ignored " + str(cmd))
        continue
    send({"type": "response", "request_seq": msg["seq"], "success": True,
          "command": cmd, "body": {}})
    note("ack " + str(cmd))
    if cmd == "initialize":
        send({"type": "event", "event": "initialized", "body": {}})
    if cmd == "launch" and mode == "refuse":
        send({"type": "event", "event": "ct/launch-failed",
              "body": {"message": os.environ["FAKE_ENGINE_TEXT"]}})
    if cmd == "launch" and mode == "settle":
        send({"type": "event", "event": "stopped",
              "body": {"reason": "entry", "threadId": 1}})
        send({"type": "event", "event": "ct/complete-move",
              "body": {"location": {"path": os.environ["FAKE_ENGINE_SOURCE"],
                                    "line": 1}}})
"""

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let calc = repo / CalcFixture

proc requirePrereq(ok: bool; what: string) =
  ## **A MISSING PREREQUISITE FAILS BY NAME. It does not skip.**
  if not ok:
    raise newException(IOError, "prerequisite missing: " & what)

type Run = object
  rc: int
  stdout, stderr: string
  seconds: float
  killed: bool

proc runBinary(args: seq[string]; env: StringTableRef): Run =
  ## One run of the shipped binary under the watchdog, both streams to files
  ## (a pipe nobody drains while the watchdog polls can fill and block the
  ## child, which would read as the very hang this suite looks for).
  let errFile = genTempPath("gpui-handshake-", ".err")
  let outFile = genTempPath("gpui-handshake-", ".out")
  let started = epochTime()
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" >" & quoteShell(outFile) & " 2>" &
             quoteShell(errFile), bin] & args,
    env = env, options = {})
  while p.running and epochTime() - started < WatchdogSeconds:
    sleep(50)
  if p.running:
    result.killed = true
    p.kill()
  result.rc = p.waitForExit()
  result.seconds = epochTime() - started
  p.close()
  result.stdout = if fileExists(outFile): readFile(outFile) else: ""
  result.stderr = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(outFile)
  removeFile(errFile)

proc baseEnv(): StringTableRef =
  ## This process's environment minus every override the cases set, so each
  ## case states its own.
  result = newStringTable()
  for k, v in envPairs():
    if k notin [HandshakeEnv, "REPLAY_SERVER_BIN", "FAKE_ENGINE_MODE",
                "FAKE_ENGINE_LOG", "FAKE_ENGINE_TEXT",
                "FAKE_ENGINE_SOURCE"]:
      result[k] = v

let scratch = createTempDir("gpui-handshake-", "")
let fakeEngine = scratch / "fake-replay-server"
let shapedFolder = scratch / "recording"
  ## A folder `traceFolderProblem` accepts — it holds a `.ct` container — so
  ## the run reaches the engine, which is where the issue's hang is.

proc fakeEnv(mode: string; log: string; budgetMs: int): StringTableRef =
  result = baseEnv()
  result["REPLAY_SERVER_BIN"] = fakeEngine
  result["FAKE_ENGINE_MODE"] = mode
  result["FAKE_ENGINE_LOG"] = log
  result["FAKE_ENGINE_TEXT"] = RefusalText
  result["FAKE_ENGINE_SOURCE"] = shapedFolder / "main.py"
  if budgetMs > 0:
    result[HandshakeEnv] = $budgetMs

proc engineLog(log: string): seq[string] =
  if fileExists(log): readFile(log).strip().splitLines() else: @[]

proc enginePid(lines: seq[string]): int =
  for l in lines:
    if l.startsWith("pid "):
      return parseInt(l[4 .. ^1])
  -1

proc alive(pid: int): bool =
  ## `kill -0`: is a process with this pid still there.
  pid > 0 and execCmd("kill -0 " & $pid & " 2>/dev/null") == 0

proc waitGone(pid: int): bool =
  ## The front-end's `close` terminates the child; give the kernel a moment to
  ## reap it rather than racing the exit.
  for _ in 0 ..< 100:
    if not alive(pid): return true
    sleep(50)
  not alive(pid)

suite "codetracer-gpui bounds the replay engine's handshake":

  test "the prerequisites are here":
    requirePrereq(fileExists(bin), bin & " (just build-gpui)")
    requirePrereq(findExe("python3").len > 0,
                  "python3 on PATH (it runs this suite's fake engine)")
    requirePrereq(dirExists(calc), calc & " (run 'just test-tui' once)")
    requirePrereq(existsEnv("REPLAY_SERVER_BIN") and
                  fileExists(getEnv("REPLAY_SERVER_BIN")),
                  "REPLAY_SERVER_BIN naming a built replay-server")
    writeFile(fakeEngine, FakeEngine.strip(trailing = false))
    setFilePermissions(fakeEngine, {fpUserRead, fpUserWrite, fpUserExec})
    createDir(shapedFolder)
    writeFile(shapedFolder / "main.ct", "")
    ck fileExists(fakeEngine)

  test "an engine that acknowledges launch and goes quiet: exit 4, named":
    let log = scratch / "stall.log"
    let r = runBinary(@["--report-plan", shapedFolder],
                      fakeEnv("stall", log, BudgetMs))
    let lines = engineLog(log)
    checkpoint("rc " & $r.rc & " in " & $r.seconds & " s; killed: " &
               $r.killed & "; stderr: " & r.stderr & "; engine: " &
               lines.join(" | "))
    # The failure the issue describes is reached, not an earlier one.
    ck "ack launch" in lines
    ck not r.killed
    ck r.rc == ExitEngineStalled
    # Inside the budget plus spawn and exit slack, not at the watchdog.
    ck r.seconds >= BudgetMs / 1000 - 0.5
    ck r.seconds < BudgetMs / 1000 + 20
    ck "codetracer-gpui: " in r.stderr
    ck shapedFolder in r.stderr
    ck "the replay engine stopped answering" in r.stderr
    ck ($BudgetMs & " ms") in r.stderr
    ck "after the recording opened" notin r.stderr
    ck "re-record" in r.stderr
    ck r.stdout.strip().len == 0
    # The stalled engine does not outlive the front-end.
    let pid = enginePid(lines)
    ck pid > 0
    ck waitGone(pid)

  test "with no override the shipped default budget still applies":
    let log = scratch / "default.log"
    let r = runBinary(@["--report-plan", shapedFolder],
                      fakeEnv("stall", log, 0))
    checkpoint("rc " & $r.rc & " in " & $r.seconds & " s; killed: " &
               $r.killed & "; stderr: " & r.stderr)
    ck "ack launch" in engineLog(log)
    ck not r.killed
    ck r.rc == ExitEngineStalled
    ck ($DefaultBudgetMs & " ms") in r.stderr

  test "an override that does not parse falls back to the default, not off":
    var env = fakeEnv("stall", scratch / "garbage.log", 0)
    env[HandshakeEnv] = "soon"
    let r = runBinary(@["--report-plan", shapedFolder], env)
    checkpoint("rc " & $r.rc & " in " & $r.seconds & " s; killed: " &
               $r.killed & "; stderr: " & r.stderr)
    ck not r.killed
    ck r.rc == ExitEngineStalled
    ck ($DefaultBudgetMs & " ms") in r.stderr

  test "a stall AFTER the open is exit 4 too, without the re-record advice":
    # The engine reached its first stop, so it read the recording; it then
    # went quiet on the first pane request `--report-plan` sent. That is the
    # same exit code, and a different sentence: telling this user to
    # re-record a recording that opened sends them to redo work that cannot
    # help.
    let log = scratch / "settle.log"
    let r = runBinary(@["--report-plan", shapedFolder],
                      fakeEnv("settle", log, BudgetMs))
    let lines = engineLog(log)
    checkpoint("rc " & $r.rc & " in " & $r.seconds & " s; killed: " &
               $r.killed & "; stderr: " & r.stderr & "; engine: " &
               lines.join(" | "))
    ck "ack launch" in lines
    # The run went past the open and was refused an answer, so the stall
    # really is the post-open one.
    # And it was refused exactly ONE answer: the first unanswered request ends
    # the run. Before the loader stopped swallowing a stall, each of its
    # requests waited out a budget of its own (measured 40 s on this 10 s
    # budget), which is the defect this case pins.
    var ignored = 0
    for l in lines:
      if l.startsWith("ignored "): inc ignored
    ck ignored == 1
    ck not r.killed
    ck r.rc == ExitEngineStalled
    ck r.seconds >= BudgetMs / 1000 - 0.5
    ck r.seconds < BudgetMs / 1000 + 20
    ck "stopped answering after the recording opened" in r.stderr
    ck ($BudgetMs & " ms") in r.stderr
    ck "re-record" notin r.stderr
    let pid = enginePid(lines)
    ck pid > 0
    let gone = waitGone(pid)
    ck gone
    if not gone:
      # This engine ignores its stdin closing (`settle`), so a front-end that
      # failed to end it leaves it running for ten minutes: end it here, so
      # a failing run does not leak it.
      discard execCmd("kill -9 " & $pid & " 2>/dev/null")

  test "an engine that says why is reported verbatim, exit 5, not a stall":
    let log = scratch / "refuse.log"
    let r = runBinary(@["--report-plan", shapedFolder],
                      fakeEnv("refuse", log, BudgetMs))
    checkpoint("rc " & $r.rc & " in " & $r.seconds & " s; killed: " &
               $r.killed & "; stderr: " & r.stderr)
    ck "ack launch" in engineLog(log)
    ck not r.killed
    ck r.rc == ExitUnreadableRecording
    ck RefusalText in r.stderr
    ck "stopped answering" notin r.stderr
    # A stated refusal is answered at once, not after the budget ran out.
    ck r.seconds < BudgetMs / 1000

  test "the negative twin: the real engine on calc still opens, same budget":
    var env = baseEnv()
    env["REPLAY_SERVER_BIN"] = getEnv("REPLAY_SERVER_BIN")
    env[HandshakeEnv] = $BudgetMs
    let r = runBinary(@["--report-plan", calc], env)
    checkpoint("rc " & $r.rc & " in " & $r.seconds & " s; killed: " &
               $r.killed & "; stderr: " & r.stderr)
    ck not r.killed
    ck r.rc == 0
    ck "stopped answering" notin r.stderr
    ck r.stdout.strip().startsWith("{")

  test "the open is bounded and the window's session is not":
    # The same entry points the binary uses, in-process, on the real engine
    # and the real `calc` recording.
    putEnv(HandshakeEnv, $BudgetMs)
    let session = openGpuiTrace(calc)
    try:
      ck session.backend.bound.timeoutMs == BudgetMs
      liftOpenBound(session)
      ck session.backend.bound.timeoutMs == 0
      ck session.backend.bound.interruptFd == -1
      # Still a working channel afterwards: the lift changes the clock only.
      var answered = true
      try:
        session.requestAndLoadLocals()
      except CatchableError as e:
        checkpoint("ct/load-locals after the lift: " & e.msg)
        answered = false
      ck answered
    finally:
      session.close()
      delEnv(HandshakeEnv)

suite "codetracer-gpui handshake bound: the tally":
  test "every assertion above ran":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
    removeDir(scratch)
