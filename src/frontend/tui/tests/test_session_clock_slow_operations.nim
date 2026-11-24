## The terminal's session-long read clock must tell a SLOW engine from a
## STOPPED one, and must never read a late answer as the answer to a later
## request.
##
## ## The defect
##
## The terminal keeps a per-message clock (`native_host.DefaultHandshakeMs`,
## 30 s, `CODETRACER_TUI_HANDSHAKE_MS`) on its engine channel for the whole
## session. Two engine operations send NOTHING until they are finished:
##
##   * `ct/run-tracepoints` — `Handler::run_tracepoints`
##     (`src/db-backend/src/dap_handler.rs`) sweeps the whole recording and only
##     then sends `ct/updated-trace` and `ct/tracepoint-results`;
##   * a step or a `continue` — `Handler::step` moves, then `complete_move`
##     sends `stopped` and `ct/complete-move`, then it responds.
##
## So a sweep or a `continue` over a large recording was reported as a stall,
## and the answer — which still arrived — sat in the event queue to be read as
## the answer to the NEXT sweep. Separately, an engine that went quiet after
## the open cost the terminal one whole budget per pane request in
## `learnExtent` (each stall swallowed as a pane that did not load) before
## anything said so, and then in the open's words, which tell the user to
## re-record a recording the engine had read. The contract is codetracer-pm
## `spec/CLI/ct/ui-selection.md` §8b.
##
## What this suite asserts:
##
##   1. In an INTERACTIVE terminal session (the open, then
##      `tui_session.allowSlowOperations`, as `main.nim` does), a sweep and a
##      `continue` that are each silent for several budgets return their own
##      answers instead of `DapStalledError`.
##   2. In an UNATTENDED session (`--headless`: the clock stays on everything),
##      the slow sweep is a stall — and the sweep after it does NOT return the
##      stalled sweep's late hits.
##   3. A sweep whose wait ran out of MESSAGE budget leaves its answer in the
##      stream; the next sweep discards it (each sweep carries its own id) and
##      returns its own hits.
##   4. `runHeadless` against an engine that reaches its first stop and then
##      answers nothing exits `ExitEngineStalled` after ONE budget, worded as a
##      stall after the open and without the open's "re-record it" advice.
##   5. A sweep the engine REFUSES ends its wait in an interactive session —
##      the session with no clock on a sweep and no interrupt — with
##      `DapRequestRefusedError` carrying the engine's own sentence, and the
##      session still answers the next request (codetracer#880, codetracer-pm
##      `issues/2026-11-15-tui-a-refused-tracepoint-sweep-hangs-the-terminal-
##      with-no-way-out.md`). `Handler::run_tracepoints` returns at the first
##      `?` in `handle_trace_steps`, before `ct/tracepoint-results` is sent,
##      and `dap_server.rs`'s `send_failed_response` answers the REQUEST
##      `success: false` with that error's text as `message`: no event, ever.
##      A wait for the event alone was a wait with nothing to end it, and in
##      the terminal that froze the screen with no key answered.
##   6. The terminal's `:tracepoint` line over that refusal leaves the
##      sentence on the §3.3.6 notification line, and the runtime answers the
##      next command.
##
## Cases 5 and 6 run under a WATCHDOG (`posix.alarm`): the defect is a wait
## that never ends, so the unfixed code fails as a named `FAIL` line and a
## non-zero exit within the watchdog's seconds, not as a lane that hangs.
##
## ## The mock, and what it is a mock OF
##
## The peer, and only the peer: a ~120-line Python DAP server standing in for
## `replay-server`, handed to the front-end through `REPLAY_SERVER_BIN`, the
## discovery override every headless suite uses. Everything on this side of
## the pipe is production code: `openTuiSession`, `openLocalTrace`,
## `newHeadlessDebugSession`, `DebugControlsVM`, `runTracepoints`, the real DAP
## framing in `stdio_backend`, `learnExtent` and `runHeadless`'s exit decision.
##
## A real engine cannot produce these shapes deterministically. "Silent for
## longer than the budget, then answers" needs a recording whose sweep or
## `continue` takes longer than the budget on whatever host runs the lane, and
## a budget short enough for a test makes that a race against host load in
## both directions. "Reaches its first stop, then answers nothing" is reached
## by the real engine only through a defect, and a test that depended on one
## would stop testing the front-end the day that defect was fixed. The
## front-end's contract is with the DAP STREAM: the timings below hold for any
## peer, and the fake sends the message shapes and the ORDER the engine's
## handlers send (cited above). The refusal is the same kind of shape: the
## real engine refuses a sweep only when replaying the recording fails or a
## handler panics — a defect in the engine or in the recording — and a test
## that needed one would stop testing the front-end the day it was fixed. The
## fake answers the way `send_failed_response` does (`success: false`, the
## error's `Display` text as `message`, an empty body, no event), with a
## sentence `db.rs`'s `load_location` raises, which `handle_trace_steps`
## propagates with `?`. The same technique and justification as
## `test_container_version_refusal.nim` and the GPUI suite
## `test_gpui_handshake_bound.nim`.

import std/[json, monotimes, os, posix, strutils, times, unittest]

import ../app/cli
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../host/headless
import ../host/native_host   # `HandshakeEnvVar`
import ../host/session_driver   # `runDebugControl`, the terminal's controls
import ../host/terminal_driver
import ../host/tui_session
import ../../viewmodel/backend/stdio_backend
import ../../viewmodel/headless_session

const
  BudgetMs = 1_000
    ## The per-message clock every case opens with. Short, so the red path is
    ## seconds; a fake answers an ordinary request in milliseconds, so the
    ## green path never comes near it.
  SlowMs = 3_500
    ## How long the fake's sweep and `continue` stay silent: several budgets,
    ## so a front-end that still timed them cannot pass by luck.
  RefusalSentence = "load_location: unexpected negative call_key -2 (not NO_KEY)"
    ## What the refusing fake says. A sentence the engine really raises
    ## (`db.rs`'s `load_location`), which `handle_trace_steps` propagates with
    ## `?` and `send_failed_response` sends as the refusal's `message`.
  WatchdogSeconds = 20
    ## How long a refusal case may take before the watchdog fails it by name.
    ## The refusal arrives after `SlowMs`; an unfixed wait never ends, so any
    ## bound well above `SlowMs` separates the two.

  FakeEngine = """
#!/usr/bin/env python3
# A DAP peer standing in for `replay-server`; see the header of
# test_session_clock_slow_operations.nim for why a fake is justified here.
#
# FAKE_ENGINE_MODE=slow   -- complete the handshake to the first stop; answer
#                            every request at once, except that
#                            `ct/run-tracepoints` and `continue` stay silent
#                            for FAKE_ENGINE_SLOW_MS and then answer in the
#                            order the engine's handlers do.
# FAKE_ENGINE_MODE=refuse -- as `slow`, except that `ct/run-tracepoints`,
#                            after FAKE_ENGINE_SLOW_MS, is REFUSED as
#                            `dap_server.rs`'s `send_failed_response` refuses
#                            it: `success: false`, the error as `message`, an
#                            empty body, and no event.
# FAKE_ENGINE_MODE=settle -- complete the handshake to the first stop, then
#                            read every request and answer nothing, except
#                            the commands listed (comma-separated) in
#                            FAKE_ENGINE_ANSWERED.
#
# This fixture tests operation clocks; stderr interleaving and draining are
# covered by test_stdio_diagnostics.nim. Commands go to $FAKE_ENGINE_LOG.
import json, os, sys, time

mode = os.environ.get("FAKE_ENGINE_MODE", "slow")
slow = int(os.environ.get("FAKE_ENGINE_SLOW_MS", "0")) / 1000.0
log_path = os.environ["FAKE_ENGINE_LOG"]
source = os.environ["FAKE_ENGINE_SOURCE"]
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
            sys.exit(0)          # the front-end closed the pipe: we are done
        line = line.strip()
        if not line:
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
    return json.loads(sys.stdin.buffer.read(length))

def respond(msg, body=None):
    send({"type": "response", "request_seq": msg["seq"], "success": True,
          "command": msg.get("command"), "body": body or {}})

def move(line, ticks):
    send({"type": "event", "event": "stopped",
          "body": {"reason": "step", "threadId": 1}})
    send({"type": "event", "event": "ct/complete-move",
          "body": {"location": {"path": source, "line": line,
                                "rrTicks": ticks}}})

HANDSHAKE = ("initialize", "configurationDone", "launch")
ANSWERED = [c for c in os.environ.get("FAKE_ENGINE_ANSWERED", "").split(",") if c]

while True:
    msg = read()
    cmd = msg.get("command")
    if mode == "settle" and cmd not in HANDSHAKE and cmd not in ANSWERED:
        note("ignored " + str(cmd))
        continue
    note("got " + str(cmd))
    if cmd == "ct/run-tracepoints" and mode == "refuse":
        # `handle_trace_steps` returned an `Err` at its first `?`: no
        # `ct/updated-trace`, no `ct/tracepoint-results`; the request answered
        # as refused, with the error's text.
        time.sleep(slow)
        send({"type": "response", "request_seq": msg["seq"],
              "success": False, "command": cmd,
              "message": os.environ["FAKE_ENGINE_REFUSAL"], "body": {}})
        note("refused sweep " + str(msg["arguments"]["session"]["id"]))
        continue
    if cmd == "ct/run-tracepoints":
        # `Handler::run_tracepoints`: the sweep first, in silence; then one
        # `ct/updated-trace` per tracepoint, then the aggregate, which echoes
        # the request's `session.id`. No response.
        time.sleep(slow)
        session = msg["arguments"]["session"]
        hits = []
        for tp in session["tracepoints"]:
            send({"type": "event", "event": "ct/updated-trace",
                  "body": {"sessionID": session["id"],
                           "updateID": tp["tracepointId"]}})
            hits.append({"tracepointId": tp["tracepointId"],
                         "rrTicks": 100 + tp["line"],
                         "path": tp["name"], "line": tp["line"],
                         "errorMessage": ""})
        send({"type": "event", "event": "ct/tracepoint-results",
              "body": {"sessionId": session["id"], "results": hits,
                       "errors": {}}})
        note("answered sweep " + str(session["id"]))
        continue
    if cmd == "continue":
        # `Handler::step`: the move first, in silence; then `complete_move`'s
        # `stopped` + `ct/complete-move`; then the response.
        time.sleep(slow)
        move(7, 700)
        respond(msg)
        continue
    respond(msg, {"supportsConfigurationDoneRequest": True}
                 if cmd == "initialize" else None)
    if cmd == "initialize":
        send({"type": "event", "event": "initialized", "body": {}})
    if cmd == "launch":
        move(1, 1)
"""

proc scratchDir(name: string): string =
  result = getTempDir() / "ct-session-clock-slow-operations" / name
  removeDir(result)
  createDir(result)

let root = scratchDir("")
let server = root / "fake-replay-server"
writeFile(server, FakeEngine.strip(trailing = false))
setFilePermissions(server, {fpUserRead, fpUserWrite, fpUserExec})

proc recordingFolder(name: string): string =
  ## A folder `traceFolderProblem` accepts — it holds a `.ct` — whose contents
  ## the fake engine never reads.
  result = scratchDir(name)
  writeFile(result / "trace.ct", "not read by this case")
  writeFile(result / "main.py", "x = 1\n")

proc useEngine(mode: string; slowMs: int; folder: string): string =
  ## Point the front-end at the fake, in `mode`. Returns the fake's log path.
  result = folder / "engine.log"
  putEnv("REPLAY_SERVER_BIN", server)
  putEnv("FAKE_ENGINE_MODE", mode)
  putEnv("FAKE_ENGINE_SLOW_MS", $slowMs)
  putEnv("FAKE_ENGINE_LOG", result)
  putEnv("FAKE_ENGINE_SOURCE", folder / "main.py")
  putEnv("FAKE_ENGINE_REFUSAL", RefusalSentence)

var watchdogCase: cstring = ""
  ## The case the armed watchdog fails, for its `FAIL` line. A `cstring` to a
  ## string literal, so the signal handler reads it without touching the GC.

proc watchdogFired(sig: cint) {.noconv.} =
  ## SIGALRM: the case did not finish in `WatchdogSeconds`. Only
  ## async-signal-safe calls (`write`, `_exit`): the main thread is blocked
  ## inside a `poll` that nothing else will end.
  const head = "\nFAIL (watchdog): "
  const tail = " did not finish; the refused sweep's wait never ended\n"
  discard posix.write(2, head.cstring, head.len)
  discard posix.write(2, watchdogCase, watchdogCase.len)
  discard posix.write(2, tail.cstring, tail.len)
  exitnow(1)

proc armWatchdog(name: static string) =
  watchdogCase = name
  discard posix.signal(SIGALRM, watchdogFired)
  discard posix.alarm(WatchdogSeconds)

proc disarmWatchdog() =
  discard posix.alarm(0)

proc engineLog(path: string): seq[string] =
  if fileExists(path): readFile(path).strip().splitLines() else: @[]

proc openSession(folder: string): TuiSession =
  openTuiSession(folder, viewportHeight = 20,
                 bound = DapReadBound(timeoutMs: BudgetMs, interruptFd: -1))

proc specs(first: int; lines: openArray[int]; path: string):
    seq[TracepointSweepSpec] =
  for i, line in lines:
    result.add TracepointSweepSpec(tracepointId: first + i, path: path,
                                   line: line, expression: "x")

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc typeLine(rt: TuiRuntime; line: string): RuntimeOutcome =
  ## A `:` command typed key by key and submitted with `Enter`, as
  ## `test_move_in_flight_badge.nim` types one.
  result = rt.handleToken(":", 0'i64)
  for ch in line:
    result = rt.handleToken($ch, 0'i64)
  result = rt.handleToken("\r", 0'i64)

proc linesOf(hits: seq[TracepointSweepHit]): seq[int] =
  for h in hits:
    result.add h.line

proc elapsedMs(since: MonoTime): int64 =
  (getMonoTime() - since).inMilliseconds

proc captureStderr(body: proc(): int): tuple[code: int, text: string] =
  ## Run `body` with stderr redirected to a file, and give back both: the
  ## user-facing text is the deliverable.
  let path = scratchDir("stderr") / "stderr.txt"
  let saved = dup(2)
  doAssert saved >= 0
  let sink = open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o644)
  doAssert sink >= 0
  doAssert dup2(sink, 2) >= 0
  discard close(sink)
  var code = -1
  try:
    code = body()
  finally:
    stderr.flushFile()
    discard dup2(saved, 2)
    discard close(saved)
  (code, readFile(path))

suite "the terminal's session clock tells a slow engine from a stopped one":

  test "an interactive session waits out a silent sweep and a silent continue":
    let folder = recordingFolder("interactive")
    let log = useEngine("slow", SlowMs, folder)
    let s = openSession(folder)
    defer: s.close()
    check s.session.backend.bound.timeoutMs == BudgetMs
    s.allowSlowOperations()
    # THE CLOCK STAYS ON for ordinary requests: only the silent-by-design
    # operations are untimed.
    check s.session.backend.bound.timeoutMs == BudgetMs

    let path = folder / "main.py"
    var hits: seq[TracepointSweepHit] = @[]
    var failure = ""
    let started = getMonoTime()
    try:
      hits = s.session.runTracepoints(specs(1, [3, 4], path))
    except CatchableError as e:
      failure = $e.name & ": " & e.msg
    checkpoint("sweep: " & failure & " after " & $elapsedMs(started) &
               " ms; engine: " & engineLog(log).join(" | "))
    check failure == ""
    check linesOf(hits) == @[3, 4]
    # It really was silent for longer than the clock.
    check elapsedMs(started) >= SlowMs - 200

    # The `continue` the terminal's `c` sends: through `DebugControlsVM`, then
    # the move settled — `session_driver.runDebugControl`.
    check s.session.getCurrentLine() == 1
    var moved = false
    failure = ""
    try:
      moved = s.session.runDebugControl("continue")
    except CatchableError as e:
      failure = $e.name & ": " & e.msg
    checkpoint("continue: " & failure & "; engine: " &
               engineLog(log).join(" | "))
    check failure == ""
    check moved
    check s.session.getCurrentLine() == 7
    check s.session.getCurrentRRTicks() == 700'u64
    check "got continue" in engineLog(log)

  test "an unattended session stalls on the sweep and never reads its late answer":
    let folder = recordingFolder("unattended")
    let log = useEngine("slow", SlowMs, folder)
    let s = openSession(folder)
    defer: s.close()
    let path = folder / "main.py"
    # `--headless` keeps the clock on everything: the slow sweep is a stall.
    expect DapStalledError:
      discard s.session.runTracepoints(specs(1, [3], path))
    # Let the stalled sweep's answer reach the pipe, as it would in a session
    # that carried on.
    sleep(SlowMs)
    var hits: seq[TracepointSweepHit] = @[]
    var failure = ""
    try:
      hits = s.session.runTracepoints(specs(2, [9], path))
    except CatchableError as e:
      failure = $e.name & ": " & e.msg
    checkpoint("second sweep: " & failure & " hits " & $linesOf(hits) &
               "; engine: " & engineLog(log).join(" | "))
    # THE ASSERTION THAT PINS IT: the first sweep's line-3 hit is never the
    # second sweep's answer.
    check 3 notin linesOf(hits)
    check failure != ""

  test "a sweep's late answer after a message-budget failure is discarded":
    let folder = recordingFolder("stale")
    let log = useEngine("slow", 0, folder)
    let s = openSession(folder)
    defer: s.close()
    s.allowSlowOperations()
    let path = folder / "main.py"
    # Two tracepoints: two `ct/updated-trace` before the aggregate, so a
    # budget of ONE message runs out before the answer is read.
    expect ValueError:
      discard s.session.runTracepoints(specs(1, [3, 4], path), maxMessages = 1)
    var hits: seq[TracepointSweepHit] = @[]
    var failure = ""
    try:
      hits = s.session.runTracepoints(specs(3, [11], path))
    except CatchableError as e:
      failure = $e.name & ": " & e.msg
    checkpoint("second sweep: " & failure & " hits " & $linesOf(hits) &
               "; engine: " & engineLog(log).join(" | "))
    check failure == ""
    check linesOf(hits) == @[11]

  test "an interactive session ends a refused sweep with the engine's sentence and stays usable":
    let folder = recordingFolder("refused")
    let log = useEngine("refuse", SlowMs, folder)
    let s = openSession(folder)
    defer: s.close()
    s.allowSlowOperations()
    let path = folder / "main.py"
    var failure = ""
    var failureType = ""
    let started = getMonoTime()
    armWatchdog("runTracepoints over a refusing engine")
    try:
      discard s.session.runTracepoints(specs(1, [3], path))
    except CatchableError as e:
      failureType = $e.name
      failure = e.msg
    disarmWatchdog()
    let took = elapsedMs(started)
    checkpoint("sweep: " & failureType & ": " & failure & " after " & $took &
               " ms; engine: " & engineLog(log).join(" | "))
    check "refused sweep 1" in engineLog(log)
    # The refusal, by its own type and in the engine's own words — not a
    # stall, not a budget that ran out.
    check failureType == "DapRequestRefusedError"
    check failure == RefusalSentence
    # The wait ended ON the refusal: after the engine's silent work, and
    # nowhere near the watchdog.
    check took >= SlowMs - 200
    check took < SlowMs + 3 * BudgetMs
    # THE SESSION IS STILL USABLE: the next request is answered, as its own.
    let answer = s.session.backend.sendDapRequest("stackTrace",
                                                  %*{"threadId": 1})
    checkpoint("stackTrace: " & $answer)
    check answer{"success"}.getBool(false)
    check answer{"command"}.getStr("") == "stackTrace"

  test "the terminal's :tracepoint names the engine's refusal and keeps answering":
    let folder = recordingFolder("refused-terminal")
    let log = useEngine("refuse", SlowMs, folder)
    let s = openSession(folder)
    defer: s.close()
    s.allowSlowOperations()
    let rt = newTuiRuntime(newTuiApp(), caps(), 120, 40)
    s.setViewportHeight(rt.sourcePaneRows())
    s.refresh(rt)
    armWatchdog(":tracepoint log(s1) over a refusing engine")
    let swept = rt.typeLine("tracepoint log(s1)")
    s.applyOutcome(rt, swept)
    disarmWatchdog()
    checkpoint("notification: " & rt.app.notification & "; engine: " &
               engineLog(log).join(" | "))
    check "refused sweep 1" in engineLog(log)
    # §3.3.6: the notification line names the refusal, in the engine's words.
    check "refused" in rt.app.notification
    check RefusalSentence in rt.app.notification
    # The positive twin through the same line: the runtime answers the next
    # command, and it reaches the engine.
    let broke = rt.typeLine("break 3")
    s.applyOutcome(rt, broke)
    checkpoint("after: " & rt.app.notification & "; engine: " &
               engineLog(log).join(" | "))
    check rt.app.notification.contains("breakpoint at ")
    check "got setBreakpoints" in engineLog(log)

  proc settleHeadless(name, answered: string) =
    ## `runHeadless` against an engine that reaches its first stop and then
    ## answers nothing but `answered`: ONE unanswered request, exit 4 after
    ## one budget, worded as a stall after the open.
    let folder = recordingFolder(name)
    let log = useEngine("settle", 0, folder)
    putEnv("FAKE_ENGINE_ANSWERED", answered)
    putEnv(HandshakeEnvVar, $BudgetMs)
    defer:
      delEnv(HandshakeEnvVar)
      delEnv("FAKE_ENGINE_ANSWERED")
    let framePath = scratchDir("frame") / "frame.txt"
    var frameSink = open(framePath, fmWrite)
    let started = getMonoTime()
    let outcome = captureStderr(proc(): int =
      runHeadless(folder, initCapabilityFlags(),
                  TerminalSize(cols: 120, rows: 40), frameSink))
    frameSink.close()
    let took = elapsedMs(started)
    let lines = engineLog(log)
    var ignored = 0
    for l in lines:
      if l.startsWith("ignored "): inc ignored
    checkpoint("rc " & $outcome.code & " in " & $took & " ms; stderr: " &
               outcome.text & "; engine: " & lines.join(" | "))
    check "got launch" in lines
    check outcome.code == ExitEngineStalled
    # ONE request went unanswered, and it ended the run: before the pane
    # loader stopped swallowing a stall, each of its requests waited out a
    # budget of its own.
    check ignored == 1
    check took < 2 * BudgetMs + 1_500
    # The engine reached its first stop, so it READ the recording: the open's
    # "re-record it" would send the user to redo work that cannot help.
    check "stopped answering after the recording opened" in outcome.text
    check ($BudgetMs & " ms") in outcome.text
    check "re-record" notin outcome.text
    check HandshakeEnvVar in outcome.text

  test "a silent engine after the open is exit 4 in one budget, not one per pane request":
    # The engine answers the flow window's `ct/load-flow` (sent as the
    # session is built) and then nothing: the stall lands in `learnExtent`'s
    # pane loads. Before the fix each of them swallowed its own stall, and
    # the run then died on an unhandled `DapStalledError`.
    settleHeadless("settle-panes", "ct/load-flow")

  test "a silent engine on the first request after the handshake is a stall after the open":
    # The first request after the first stop is the flow window's
    # `ct/load-flow`, which `FlowVM` sends as the first position (a non-zero
    # tick, as every real engine reports) is applied — INSIDE the open
    # (`newHeadlessDebugSession`), but after the engine has read the
    # recording. Before the fix this was reported in the open's words.
    settleHeadless("settle-first", "")
