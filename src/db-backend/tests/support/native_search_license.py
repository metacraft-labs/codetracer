"""Real unlicensed native replay/DAP control; no mocks or guard exemptions."""

import json
import os
from pathlib import Path
import queue
import signal
import shutil
import subprocess
import sys
import tempfile
import threading

native, core, source = map(Path, sys.argv[1:4])
recorder = sys.argv[4] if len(sys.argv) > 4 else "rr"
scratch = Path(tempfile.mkdtemp(prefix="native-search-free-control-"))
env = os.environ.copy()
for key in ("CODETRACER_LICENSE_FILE", "CODETRACER_IN_UI_TEST"):
    env.pop(key, None)
# Recording has its own home so it cannot affect the replay admission control.
env["CODETRACER_HOME"] = str(scratch / "record-home")
binary, trace = scratch / "program", scratch / "trace"
for args in (["build", str(source), str(binary)], ["record", "--backend", recorder, "-o", str(trace), str(binary)]):
    result = subprocess.run([str(native), *args], env=env, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)

if recorder == "mcr":
    trace = trace.with_suffix(".ct")

env["CODETRACER_HOME"] = str(scratch / "replay-home")
(scratch / "replay-home" / "tmp").mkdir(parents=True)
log = open(scratch / "replay-server-stderr.log", "w")
process = subprocess.Popen(
    [str(core), "dap-server", "--stdio"],
    env=env,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=log,
    start_new_session=True,
)
messages = queue.Queue()


def read_messages():
    try:
        while True:
            line = process.stdout.readline()
            if not line:
                raise EOFError("DAP server EOF")
            if not line.lower().startswith(b"content-length:"):
                continue
            length = int(line.split(b":", 1)[1])
            while process.stdout.readline().strip():
                pass
            messages.put(json.loads(process.stdout.read(length)))
    except BaseException as error:
        messages.put(error)


threading.Thread(target=read_messages, daemon=True).start()
sequence = 0


def send(command, arguments):
    global sequence
    sequence += 1
    body = json.dumps(dict(seq=sequence, type="request", command=command, arguments=arguments)).encode()
    process.stdin.write(b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
    process.stdin.flush()
    return sequence


def receive():
    message = messages.get()
    if isinstance(message, BaseException):
        raise message
    return message


def response(request):
    while True:
        message = receive()
        if message.get("type") == "response" and message["request_seq"] == request:
            return message


def replay_count():
    usage = subprocess.run([str(native), "license", "usage"], env=env, capture_output=True, text=True, check=True)
    print(usage.stdout, flush=True)
    return int(usage.stdout.split("Today's replays: ", 1)[1].splitlines()[0])


succeeded = False
try:
    print("scratch", scratch, flush=True)
    initialized = response(send("initialize", {"adapterID": "codetracer", "linesStartAt1": True, "columnsStartAt1": True}))
    assert initialized["success"], initialized
    launch = response(send("launch", {"traceFolder": str(trace), "ctRRWorkerExe": str(native)}))
    assert launch["success"], launch
    request = send("configurationDone", {})
    done = stopped = False
    while not (done and stopped):
        message = receive()
        if message.get("type") == "response" and message["request_seq"] == request:
            assert message["success"], message
            done = True
        stopped = stopped or message.get("event") == "stopped"
    assert replay_count() == 1, "the initial browsing replay must consume its normal admission"
    for index in range(6):
        result = response(send("ct/search-calltrace", {"value": "^calculate_sum$"}))
        print(
            "search", index + 1, "success", result["success"], "message", result.get("message"),
            "total", result.get("body", {}).get("total"), flush=True,
        )
        assert result["success"], "repeated search consumed replay admission: " + str(result.get("message"))
        assert result["body"]["total"] == 1, result
    assert replay_count() == 1, "call search must not consume extra replay admissions"
    succeeded = True
finally:
    try:
        send("disconnect", {})
    except (BrokenPipeError, OSError):
        pass
    # Bound cleanup of this driver's own process group, including failed runs.
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait()
    log.close()
    if succeeded:
        shutil.rmtree(scratch)
