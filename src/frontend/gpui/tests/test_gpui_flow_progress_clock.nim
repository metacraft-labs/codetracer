## A flow that reports progress keeps the window's per-message clock running.
##
## codetracer-pm `spec/CLI/ct/ui-selection.md` §8b: the GPUI window keeps a
## 30 s clock on every message it waits for before it takes input, its first
## pane loads included, and the flow window is one of them. A native flow can
## take longer than that on a loaded host (one stepped by rr, a step at a
## time): the engine is working, not stopped. So while it computes a flow the
## engine sends progress (`ct/flow-progress` events, about every 2 s), and the
## clock, which is per message, starts again on each one.
##
## The fake engine answers `ct/load-flow` after several budgets, in two modes:
## `progress` sends an event every 300 ms meanwhile, and the request is
## answered; `silent` sends nothing, and the read fails as a stall after one
## budget. The silent case is this suite's control: a clock that did not run
## at all would pass the progress case for the wrong reason.

import std/[json, monotimes, os, times, unittest]

import ../../viewmodel/backend/stdio_backend

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 5
  BudgetMs = 1_000
    ## The per-message clock: short, so the silent case fails in a second.
  FlowMs = 3_500
    ## How long the fake's flow takes: several budgets.
  FakeEngine = """
#!/usr/bin/env python3
# A DAP peer standing in for `replay-server` while it computes a flow; see
# test_gpui_flow_progress_clock.nim. FAKE_FLOW_MODE=progress|silent.
import json, os, sys, time

mode = os.environ.get("FAKE_FLOW_MODE", "progress")
flow = int(os.environ.get("FAKE_FLOW_MS", "0")) / 1000.0
seq = 0

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
            sys.exit(0)
        line = line.strip()
        if not line:
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
    return json.loads(sys.stdin.buffer.read(length))

while True:
    msg = read()
    if msg.get("command") == "ct/load-flow":
        start = time.time()
        step = 0
        while time.time() - start < flow:
            time.sleep(0.3)
            step += 1
            if mode == "progress":
                send({"type": "event", "event": "ct/flow-progress",
                      "body": {"steps": step}})
        send({"type": "response", "request_seq": msg["seq"], "success": True,
              "command": "ct/load-flow", "body": {}})
    else:
        send({"type": "response", "request_seq": msg["seq"], "success": True,
              "command": msg.get("command"), "body": {}})
"""

let root = getTempDir() / "ct-gpui-flow-progress-clock"
removeDir(root)
createDir(root)
let server = root / "fake-replay-server"
writeFile(server, FakeEngine)
setFilePermissions(server, {fpUserRead, fpUserWrite, fpUserExec})

proc engine(mode: string): DapStdioBackend =
  putEnv("FAKE_FLOW_MODE", mode)
  putEnv("FAKE_FLOW_MS", $FlowMs)
  startReplayServer(server, bound = DapReadBound(timeoutMs: BudgetMs,
                                                 interruptFd: -1))

suite "GPUI: a flow that reports progress keeps the per-message clock":

  test "progress every 300 ms: the flow is answered after several budgets":
    let b = engine("progress")
    defer: b.close()
    let t0 = getMonoTime()
    let resp = b.sendDapRequest("ct/load-flow", %*{"flowMode": "call"})
    let took = (getMonoTime() - t0).inMilliseconds
    ck resp{"success"}.getBool
    # It really did outlast the budget, several times over.
    ck took >= FlowMs - 200
    # The progress the engine sent is kept as events, for a reader of them.
    var progress = 0
    for e in b.eventQueue:
      if e{"event"}.getStr == "ct/flow-progress": inc progress
    ck progress >= 5

  test "control: a silent flow is a stall after one budget":
    let b = engine("silent")
    defer: b.close()
    let t0 = getMonoTime()
    var stalled = false
    try:
      discard b.sendDapRequest("ct/load-flow", %*{"flowMode": "call"})
    except DapStalledError:
      stalled = true
    let took = (getMonoTime() - t0).inMilliseconds
    ck stalled
    ck took < FlowMs

  test "every assertion ran":
    check CHECKS == ExpectedAssertions
