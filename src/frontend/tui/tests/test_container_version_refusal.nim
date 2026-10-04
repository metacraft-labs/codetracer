## A recording the engine refuses must reach the USER, not the engine's log.
##
## ## The defect
##
## `replay-server` answers `launch` `success: true` before it opens anything,
## so a recording it turns out to be unable to read is reported afterwards,
## out of band, by `dap_server.send_launch_failure_notification`. The terminal
## front-end's handshake waited for `stopped` through `waitForEvent`, which
## BUFFERED that report like any other event and kept reading. So the open
## ended on the handshake clock and the user was told
##
##   `codetracer-tui: <folder>: the replay engine stopped answering (…)`
##
## about an engine that had answered, in a sentence naming the container
## version it found, the version it requires and that the remedy is
## re-recording. Before CTUI-14 put a clock on that wait, the user was told
## nothing at all and the panes stayed empty for as long as they cared to look
## — the symptom in
## `codetracer-specs/issues/2026-10-04-replay-server-goes-silent-on-a-container-v4-recording.md`.
##
## ## The mock, and what it is a mock OF
##
## The peer, and only the peer. `fakeRefusingServer` speaks the DAP exchange
## MEASURED from the real `replay-server` against a real container-version-4
## recording — the three responses, the `initialized` and `ct/listProcesses`
## events, the launch-failed report — and then goes silent exactly as the real
## one does. Everything on this side of
## the pipe is production code: `runHeadless`, `openTuiSession`,
## `openLocalTrace`, `newHeadlessDebugSession`, the real DAP framing in
## `stdio_backend`, and the real exit-code decision in `host/headless.nim`.
##
## Faking the peer is what makes the case DETERMINISTIC and buildable in the
## Tier-1 lane: the alternative needs a compiled `replay-server` and a
## committed container-v4 recording, which is the arm
## `src/db-backend/tests/container_version_refusal_reaches_the_client_test.rs`
## runs against the real binary. This one pins what the real binary's answer
## does to the TERMINAL, which that one cannot see. The same technique and the
## same justification as `tests/real_terminal/lifecycle_support.wedgeFolder`,
## which fakes the peer's SILENCE for the stalled case next door.
##
## The script's text is a copy of the engine's, so a reader can check it
## against `ContainerVersionRefusal`'s `Display` in `dap_server.rs`. If the
## engine's wording changes, this case keeps passing and the Rust arm is what
## goes red — which is the right division: that arm owns the wording, this one
## owns what the terminal does with it.

import std/[json, os, posix, strutils, unittest]

import ../app/cli
import ../app/theme/capabilities
import ../host/headless
import ../host/native_host   # `HandshakeEnvVar`, this case's own bound
import ../host/terminal_driver
import ../../viewmodel/backend/stdio_backend

const
  # The sentence the engine produces, copied from `ContainerVersionRefusal`'s
  # `Display` as measured against a real container-v4 recording.
  EngineRefusal = "/tmp/rec/trace.ct: this recording cannot be opened by " &
    "this build: CTFS container version 4 is not readable: this reader reads " &
    "versions 5 and 6. Re-record the trace, or regenerate the fixture with " &
    "its producer. The file itself is intact and there is nothing that can " &
    "be changed about it to make this build read it."

proc scratchDir(name: string): string =
  result = getTempDir() / "ct-container-version-refusal" / name
  removeDir(result)
  createDir(result)

proc refusingFolder(): string =
  ## A folder `traceFolderProblem` accepts — it holds a `.ct` — whose contents
  ## are never read, because the faked engine refuses before reading anything.
  result = scratchDir("recording")
  writeFile(result / "trace.ct", "not read by this case")

proc fakeRefusingServer(dir: string): string =
  ## A `replay-server` that answers the whole handshake and then refuses the
  ## recording, exactly as the real one does.
  ##
  ## Python rather than `sh`, and the reason is a measurement: `Content-Length`
  ## counts BYTES, the refusal carries `—` and `§`, and `sh`'s `${#s}` counts
  ## characters — so a shell version of this frames every message two bytes
  ## short of its body and the front-end reports a malformed stream instead of
  ## the refusal. `python3` is already a prerequisite of this repository's test
  ## tooling (`src/frontend/tui/tests/run-plat*-mutations.py`).
  ##
  ## The replies and their ORDER are the ones measured from the real engine:
  ## `initialize` + `initialized`, `configurationDone`, then `launch`
  ## acknowledged `success: true` BEFORE anything is opened, a
  ## `ct/listProcesses` snapshot, the refusal, and then silence.
  result = dir / "fake-replay-server"
  let refusal = $(%*{
    "seq": 0, "type": "event", "event": LaunchFailedEvent,
    "body": {"message": EngineRefusal}})
  let script = """#!/usr/bin/env python3
import json, sys, time

OUT = sys.stdout.buffer
IN = sys.stdin.buffer
REFUSAL = REFUSAL_JSON


def emit(obj):
    body = json.dumps(obj).encode("utf8")
    OUT.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    OUT.flush()


def read_message():
    length = None
    while True:
        line = IN.readline()
        if not line:
            return None
        line = line.rstrip(b"\r\n")
        if not line:
            break
        if line.startswith(b"Content-Length:"):
            length = int(line.split(b":", 1)[1].strip())
    if length is None:
        return None
    body = b""
    while len(body) < length:
        chunk = IN.read(length - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body)


seq = 0


def nxt():
    global seq
    seq += 1
    return seq


while True:
    msg = read_message()
    if msg is None:
        break
    command = msg.get("command", "")
    request_seq = msg.get("seq", 0)
    emit({"seq": nxt(), "type": "response", "request_seq": request_seq,
          "success": True, "command": command,
          "body": {"supportsConfigurationDoneRequest": True}
                  if command == "initialize" else {}})
    if command == "initialize":
        emit({"seq": nxt(), "type": "event", "event": "initialized", "body": {}})
    elif command == "launch":
        emit({"seq": nxt(), "type": "event", "event": "ct/listProcesses",
              "body": {"processes": []}})
        refusal = dict(REFUSAL)
        refusal["seq"] = nxt()
        emit(refusal)
        # AND THEN SILENCE. No `stopped` is coming, ever — which is exactly
        # what the real engine does after refusing a recording.
        while True:
            time.sleep(60)
"""
  writeFile(result, script.replace("REFUSAL_JSON", refusal))
  discard chmod(result.cstring, 0o755)

proc captureStderr(body: proc(): int): tuple[code: int, text: string] =
  ## Run `body` with stderr redirected to a file, and give back both.
  ##
  ## The user-facing text IS the deliverable here, so the case reads the same
  ## bytes the user would see rather than a value the code happens to also
  ## return.
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

suite "a recording this build cannot read is refused by name":

  test "launchRefusalText reads a launch-failed event and nothing else":
    # THE CLASSIFIER, both directions. Without the negatives, a classifier
    # that answered every event would satisfy the positive — and the handshake
    # would then abort on a recording that opened fine.
    let refusal = %*{
      "type": "event", "event": "ct/launch-failed",
      "body": {"message": "  container version 4 is not readable  "}}
    check launchRefusalText(refusal) == "container version 4 is not readable"

    # THE ONE THAT MATTERS MOST. `ct/notification` of kind 2 is also what the
    # engine sends for a recording that opened PERFECTLY WELL whose first step
    # carries a recorded error event. Ending the handshake on it would refuse
    # working recordings, so it must not classify.
    for kind in [0, 1, 2, 3]:
      let notification = %*{
        "type": "event", "event": "ct/notification",
        "body": {"kind": kind, "text": "recorded error on step #3: boom"}}
      check launchRefusalText(notification) == ""

    check launchRefusalText(%*{
      "type": "event", "event": "stopped", "body": {"reason": "entry"}}) == ""
    check launchRefusalText(%*{
      "type": "response", "command": "launch", "success": true}) == ""
    check launchRefusalText(%*{
      "type": "event", "event": "ct/launch-failed",
      "body": {"message": "   "}}) == ""
    check launchRefusalText(newJNull()) == ""

  test "a buffered refusal ends the wait instead of being waited past":
    # `waitForEvent` would have returned this notification to the eventQueue
    # and kept reading until the clock ran out. `waitForEventOrRefusal` raises
    # with the engine's own text.
    # `new` rather than an object constructor: the queue is all this case
    # touches, and `DapStdioBackend` has private fields a constructor
    # expression outside its own module cannot speak about. Nothing here
    # reaches the pipe — the refusal is already buffered, which is exactly the
    # state `waitForEvent` used to leave it in.
    var backend: DapStdioBackend
    new(backend)
    backend.eventQueue = @[%*{
      "type": "event", "event": "ct/launch-failed",
      "body": {"message": EngineRefusal}}]
    expect DapLaunchRefusedError:
      discard backend.waitForEventOrRefusal("stopped")

    try:
      discard backend.waitForEventOrRefusal("stopped")
      check false
    except DapLaunchRefusedError as err:
      check err.msg == EngineRefusal

  test "the awaited event still wins when it is already buffered":
    # The CONTROL for the case above: a wait that aborts on everything would
    # pass it. A `stopped` in the queue must be returned, refusal or no.
    var backend: DapStdioBackend
    new(backend)
    backend.eventQueue = @[
      %*{"type": "event", "event": "stopped", "body": {"reason": "entry"}},
      %*{"type": "event", "event": "ct/launch-failed",
         "body": {"message": EngineRefusal}}]
    let got = backend.waitForEventOrRefusal("stopped")
    check got.getOrDefault("event").getStr("") == "stopped"

  test "the terminal front-end prints the engine's sentence and exits 5":
    # END TO END THROUGH THE FRONT-END'S OWN OPEN PATH, with the peer faked and
    # nothing else. This is the arm that fails on an empty pane: at the
    # unmodified parent the notification is buffered, no `stopped` arrives, and
    # `runHeadless` reports `could not open <folder>: DapStdioBackend: did not
    # receive 'stopped' event within 50 messages` with exit 2 — a message that
    # names neither the version nor the remedy, about an engine that had named
    # both.
    let folder = refusingFolder()
    let server = fakeRefusingServer(scratchDir("bin"))
    putEnv("REPLAY_SERVER_BIN", server)
    defer: delEnv("REPLAY_SERVER_BIN")
    # A SHORT HANDSHAKE BUDGET, so this case has a bound of its own. The
    # refusal arrives in milliseconds, so it changes nothing about the green
    # path; what it bounds is the RED one. Reverting
    # `headless_session`'s `waitForEventOrRefusal` to `waitForEvent` makes this
    # case fail on `ExitEngineStalled` after three seconds instead of running
    # out the default thirty — and, before `runHeadless` carried a bound at
    # all, instead of never returning, which is the issue's "it stays so
    # indefinitely" reproduced exactly.
    putEnv(HandshakeEnvVar, "3000")
    defer: delEnv(HandshakeEnvVar)

    let framePath = scratchDir("frame") / "frame.txt"
    var frameSink = open(framePath, fmWrite)
    let outcome = captureStderr(proc(): int =
      runHeadless(folder, initCapabilityFlags(),
                  TerminalSize(cols: 120, rows: 40), frameSink))
    frameSink.close()

    check outcome.code == ExitUnreadableRecording
    # NOT the usage code and NOT the stall code. Each would send the user
    # somewhere there is nothing to find: `ExitUsage` to their command line,
    # `ExitEngineStalled` to run the engine by hand to see what it says.
    check outcome.code != ExitUsage
    check outcome.code != ExitEngineStalled

    # THE VERBATIM TEXT. Every fact the user is owed, asserted one at a time so
    # a failure says which one went missing.
    check "cannot open " & folder in outcome.text
    check "container version 4 is not readable" in outcome.text
    check "this reader reads versions 5 and 6" in outcome.text
    check "Re-record the trace" in outcome.text
    check "The file itself is intact" in outcome.text
    # A good older recording is not a broken one, and must never be called one.
    check "corrupt" notin outcome.text.toLowerAscii
    # The stall wording must be absent: the engine answered.
    check "stopped answering" notin outcome.text
