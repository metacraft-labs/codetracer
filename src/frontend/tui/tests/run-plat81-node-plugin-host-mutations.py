#!/usr/bin/env python3
"""Plugins run out of process on the JavaScript backend (Extensibility-Model.md
§11.2.1, §11.7.1, §11.8) — the mutation harness for `process_link.nim`'s Node
arm (`child_process.spawn`) and the supervisor's JavaScript spellings (the J
arms), and for the desktop main process's and `ct host`'s wiring of them
(`index/plugin_sessions.nim`, `plugin_host/key_snapshot.nim`: the K arms).

Each arm plants ONE defect and must be killed by the section of the suite that
asserts it, against REAL plugin processes started by Node:
`test_plugin_process_host_node.nim` (vm-unit-js) for the link,
`plugin_sessions_test.nim` (main-process) for the wiring. The C half is
`run-plat81-plugin-process-mutations.py`'s; no J arm touches a line the C
backend compiles.

The engine is `plat71_mutation_engine.py` — committed control digests over
subjects AND suites, the needle scan gating a re-record, `because` derived from
a run and then required, rc 124 a hang, per-arm restore verification. Its
suite runner is `nim c -r`; this harness runs a suite the way `vm-unit-js`
does instead (`nim js -d:nodejs`, then `node`), and a suite's filter is the
`--only=` section tag it takes.

Usage:
    run-plat81-node-plugin-host-mutations.py [--only ID,ID] [--derive]
    run-plat81-node-plugin-host-mutations.py --needle-scan
    run-plat81-node-plugin-host-mutations.py --record-control-hashes
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plat71_mutation_engine import (  # noqa: E402
    Harness, TIMEOUT, lane_flags, portable_cause)

SUP = "src/frontend/viewmodel/plugin_host/supervisor.nim"
LINK = "src/frontend/viewmodel/plugin_host/process_link.nim"
SNAP = "src/frontend/viewmodel/plugin_host/key_snapshot.nim"
SESS = "src/frontend/index/plugin_sessions.nim"

NODE = "src/frontend/viewmodel/tests/unit/test_plugin_process_host_node.nim"
WIRING = "src/frontend/tests/plugin_sessions_test.nim"

SUBJECTS = [SUP, LINK, SNAP, SESS]
SUITES = [NODE, WIRING]
IN_BINARY = set()

ARMS = [
    ("J1", [(LINK, "        link.pendingExit = (signalled: true, code: jsSignalNumber(signal))",
             "        link.pendingExit = (signalled: true, code: 0)")],
     [(NODE, "segfault")],
     "§11.6.1: Node's signal name is not read back; a segfault is not SIGSEGV"),
    ("J2", [(LINK, "      p.writeBlocked = true", "      discard"),
            (LINK, "    p.outQueue.len + jsWritableLength(p.toChild)",
             "    p.outQueue.len")],
     [(NODE, "write-queue")],
     "§11.7.1: the write queue hands every byte to Node; a child that stops "
     "reading is never noticed"),
    ("J3", [(LINK, "      var opts = { detached: true, env: env,",
             "      var opts = { detached: false, env: env,")],
     [(NODE, "stop")],
     "§11.8: the child shares the main process's group; the stop sequence's "
     "signals to the group reach nothing"),
    ("J4", [(LINK, "      jsInstallExitGuards(killEveryGroup)", "      discard")],
     [(NODE, "main-ends")],
     "§11.8: no exit guard; a stuck plugin outlives a main process that is "
     "terminated"),
    ("J5", [(LINK, "    if helped:", "    if false:")],
     [(NODE, "main-ends")],
     "§11.8: setpriv is not used; a stuck plugin outlives a SIGKILLed main "
     "process"),
    ("J6", [(SUP, "    sup.poll()\n    if sup.processIds.len == 0:",
             "    sup.poll()\n    if true:")],
     [(NODE, "handshake")],
     "§11.8: shutdown on Node does not wait for the graceful stop; every "
     "process is SIGKILLed at once"),
    ("J7", [(LINK, "        # Never started: Node reports the spawn's errno as a negative code.\n"
                   "        link.pendingExit = (signalled: false, code: 127)",
             "        # Never started: Node reports the spawn's errno as a negative code.\n"
             "        link.pendingExit = (signalled: false, code: 0)"),
            (LINK, "        link.pendingExit = (signalled: false, code: 127))",
             "        link.pendingExit = (signalled: false, code: 0))")],
     [(NODE, "start-failure")],
     "an executable that cannot be started reads as a clean exit, not "
     "`execve`'s 127"),
    # Re-aimed 2026-11-26: f480b952f changed the Node link's stderr keep from
    # `link.stderrTail.add data` to `link.stderrTail.appendBytes data` (a pipe
    # chunk, `byte_append`); same decision, new spelling.
    ("J8", [(LINK, "      link.stderrTail.appendBytes data"
             "   # a pipe chunk (`byte_append`)", "      discard")],
     [(NODE, "segfault")],
     "§11.6.1: Node's stderr is not kept; the SDK's crash record is never "
     "read and a segfault is unattributed"),
    ("J9", [(LINK, "    if probeFailure.len > 0:", "    if false:")],
     [(NODE, "setpriv-probe")],
     "§11.8: a setpriv that cannot run here is used anyway; every plugin "
     "exits 1 before its hello and is struck for the host's fault"),
    ("J10", [(LINK, "    for fd in [1, 2]:", "    for fd in [2]:")],
     [(NODE, "echo")],
     "§11.4.1: the child's stdout is not read into the plugin log; what a "
     "plugin echoes is lost"),
    ("J11", [(LINK, "      discard jsWrite(p.pingTo, toBytes(p.livenessQueue))",
              "      discard")],
     [(NODE, "hang")],
     "§11.6.2: pings are never written to the liveness descriptor; no pong "
     "names the busy plugin"),
    ("J12", [(LINK, "        link.bytesRead += s.len\n"
                    "        link.reader.feed(s))",
              "        link.bytesRead += s.len\n"
              "        discard)")],
     [(NODE, "protocol")],
     "§11.4.1: descriptor 4 is not read; a frame of garbage on it is never "
     "judged"),
    ("K1", [(SNAP, "        if l{\"suspect\"}.getBool(false):", "        if false:")],
     [(WIRING, "keys")],
     "§11.7.4: the renderer's snapshot keeps a suspect plugin's layer opaque"),
    ("K2", [(SESS, "    m.relay(msg{\"vm\"}.getStr(\"\"), msg{\"action\"}.getStr(\"\"),",
             "    discard (msg{\"vm\"}.getStr(\"\"), msg{\"action\"}.getStr(\"\"),")],
     [(WIRING, "desktop")],
     "§11.4: a desktop plugin's relayed step never reaches the renderer's "
     "session"),
    ("K3", [(SESS, "    ps.mirror.channel.deliver(msg)", "    discard msg")],
     [(WIRING, "desktop")],
     "§11.2.1: the desktop's mirror is never fed; the plugins see no session"),
    ("K4", [(SESS, "  discard ps.plugins.sup.resolveLayerKey(key, focusedSurface)",
             "  discard")],
     [(WIRING, "keys")],
     "§11.7.4: a key that passed a suspect layer in the renderer is no strike"),
    ("K5", [(SESS, "  if ps.plugins.sup.observeEscape(arrivedMs):", "  if false:")],
     [(WIRING, "keys")],
     "§11.7.6: the renderer's Escapes are not observed; the chord never "
     "recovers input"),
]


class NodeHarness(Harness):
    """`run_suite` for Node suites: compiled as `vm-unit-js` compiles them."""

    def run_suite(self, suite, test_filter):
        self.nimcache.mkdir(parents=True, exist_ok=True)
        stem = Path(suite).stem
        cache = self.nimcache / stem
        out_js = cache / f"{stem}.js"
        # The suite's lane's defines: `main-process` compiles the index's
        # modules with `-d:ctIndex -d:server` (`test_lane_extra_flags`).
        lane = "main-process" if suite.startswith("src/frontend/tests/") \
            else "vm-unit-js"
        build = ["nim", "js", "-d:nodejs", "--hints:off", "--warnings:off"] + \
            lane_flags(lane) + [f"--nimcache:{cache}", f"-o:{out_js}", suite]
        try:
            b = subprocess.run(build, capture_output=True, text=True,
                               timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return "HUNG", []
        if b.returncode != 0:
            return "DID-NOT-COMPILE", []
        run = ["timeout", str(TIMEOUT), "node", str(out_js)]
        if test_filter:
            run.append(f"--only={test_filter}")
        try:
            p = subprocess.run(run, capture_output=True, text=True,
                               timeout=TIMEOUT + 60)
        except subprocess.TimeoutExpired:
            return "HUNG", []
        if p.returncode == 124:
            return "HUNG", []
        out = (p.stdout or "") + (p.stderr or "")
        failures = [portable_cause(ln.strip().split("FAILED: ", 1)[1])
                    for ln in out.splitlines() if ln.strip().startswith("FAILED: ")]
        if p.returncode == 0 and not failures:
            return ("GREEN", []) if "[OK]" in out else ("RAN-NOTHING", [])
        if not failures:
            failures = [ln.strip() for ln in out.splitlines()
                        if "[FAILED]" in ln or "Error" in ln][:1]
        return "RED", failures


HARNESS = NodeHarness("plat81-node-plugin-host", Path(__file__).resolve().parent,
                      SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
