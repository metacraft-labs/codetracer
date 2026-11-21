#!/usr/bin/env python3
"""Plugins run out of process (Extensibility-Model.md §11) — the mutation
harness for the plugin protocol, the native plugin process and its SDK, the
supervisor's attribution and supervision, and the input defences of §11.7.

Each arm plants ONE defect the milestone names (PLAT-81's and PLAT-82's
"Mutations" bullets, and the invariants beside them) and must be killed by the
case that asserts it, in `test_plugin_process_host.nim`, which drives REAL
plugin processes. The engine — committed control digests over subjects AND
suites, the needle scan gating a re-record, `because` derived from a run and
then required, rc 124 a hang, per-arm restore verification — is
`plat71_mutation_engine.py`.

A subject compiled into the PLUGIN EXECUTABLE (the SDK, the protocol) is
rebuilt by the suite itself: `plugin_process_fixture.buildPackageExecutable`
rebuilds whenever a source is newer than the binary, which a mutation is. A
subject compiled into the TERMINAL (`IN_BINARY`) makes the engine rebuild
`codetracer-tui` before the real-PTY suite grades the arm.

TWO SUITES NEED THEIR LANE'S FLAGS, which the engine does not know: the TLS
suite (`-d:ssl`, OpenSSL on the loader's path at run time) and `ct`'s
(`ct-cli-units`). `suite_flags` is extended for them below, from the lanes
themselves, and `LD_LIBRARY_PATH` gets `CT_LD_LIBRARY_PATH` (the dev shell's
OpenSSL) for the run.

Usage:
    run-plat81-plugin-process-mutations.py [--only ID,ID] [--derive]
    run-plat81-plugin-process-mutations.py --needle-scan
    run-plat81-plugin-process-mutations.py --record-control-hashes
"""
import sys
from pathlib import Path

import os  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import plat71_mutation_engine as engine  # noqa: E402
from plat71_mutation_engine import Harness  # noqa: E402

_engine_flags = engine.suite_flags


def _suite_flags(suite):
    if suite.endswith("/test_plugin_tls.nim"):
        return engine.lane_flags("plugin-tls")
    if suite.startswith("src/ct/"):
        return engine.lane_flags("ct-cli-units")
    return _engine_flags(suite)


engine.suite_flags = _suite_flags
if os.environ.get("CT_LD_LIBRARY_PATH"):
    os.environ["LD_LIBRARY_PATH"] = os.environ["CT_LD_LIBRARY_PATH"] + \
        (":" + os.environ["LD_LIBRARY_PATH"]
         if os.environ.get("LD_LIBRARY_PATH") else "")

SUP = "src/frontend/viewmodel/plugin_host/supervisor.nim"
LINK = "src/frontend/viewmodel/plugin_host/process_link.nim"
SDK = "src/plugin_sdk/codetracer_plugin_sdk.nim"
PKG = "src/common/plugin_model/package.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
SERVICE = "src/frontend/tui/host/plugin_service.nim"
MAIN = "src/frontend/tui/main.nim"
IO = "src/frontend/viewmodel/plugin_host/plugin_io.nim"
CLI = "src/ct/plugins_cli.nim"
KEYS = "src/common/key_names.nim"

HOST = "src/frontend/viewmodel/tests/unit/test_plugin_process_host.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat81_plugin_processes_pty.nim"
TLS = "src/frontend/viewmodel/tests/unit/test_plugin_tls.nim"
CLITEST = "src/ct/plugins_cli_test.nim"
MOVES = "src/frontend/tui/tests/test_plugin_relayed_moves.nim"

SUBJECTS = [SUP, LINK, SDK, PKG, RUNTIME, SERVICE, MAIN, IO, CLI, KEYS]
SUITES = [HOST, PTY, TLS, CLITEST, MOVES]
IN_BINARY = {RUNTIME, SERVICE, MAIN}

P_GRANT = "*::installing is not accepting; granted, one process runs both plugins and draws their panes"
P_SAFE = "*::--no-extensions starts no plugin process"
P_SWALLOW = "*::a plugin that swallows keys loses the keyboard; three Escapes recover"
T_NAME = "*::a trusted certificate for ANOTHER name is refused"
C_WAIT = "*::an undecided capability: waiting for consent, naming the command"

STALE = "*::an answer computed at the old position is never shown"
HANG = "*::a handler that loops forever is attributed by the watchdog"
REFUSE = "*::a native package whose plugin does not declare `process` is refused"
SWALLOW = "*::a plugin that swallows keys loses the keyboard: dropped, transparent, then open"
MODAL = "*::no plugin layer is consulted while a host modal is open"
RESERVED = "*::a plugin binding the palette key or the recovery chord is refused, by name"
CHORD = "*::three Escapes pop a layer that binds Escape, and open the recovery dialog"
LATCH = "*::half-open after the backoff; one strike reopens; the third opening latches until Re-enable"
SEGV = "*::a plugin that segfaults on activation: blamed by name, siblings restarted at most 3 times"
ECHO = "*::a plugin that writes to stdout does not break the protocol; what it wrote is in its log"
T_HANG = "*::a timer that loops forever is attributed by the watchdog"
T_RAISE = "*::a timer that raises is its plugin's error, and the process keeps running"
A_HANG = "*::an async continuation that loops forever is attributed by the watchdog"
A_RAISE = "*::an async continuation that raises is its plugin's error, and the process keeps running"
RUN = "*::a declared program runs to completion; an undeclared one is refused by name"
GROUP = "*::a program past its deadline is killed with its whole process group"
SWEEP = "*::a loopback listener and a connection; deactivation closes them and kills what it started"
PONG = "*::a pong never waits behind a frame the plugin is writing (measured)"
INFLIGHT = "*::the chord landing while a routine ping is in flight still probes the plugin"
COMPUTED = "*::a plugin computes answers for the values on screen; an answer for another stop is never shown"
HOOK = "*::a front-end's own route takes a relayed action, and its refusal is the plugin's, by name"

M_ROUTES = "*::steps, the call trace jump, the watch and the seek move the stop the screen shows"
M_TAB = "*::while another tab is shown only a plain step runs; the rest is refused"
M_CASE = "*::the modifiers' spelling is folded, the key's own case is not"
M_ALT = "*::an Alt chord a plugin binds reaches the plugin pass whole; `J` and `j` are two keys"
P_MOVES = "*::a plugin's relayed jump, watch and step out are shown at once, with no :next"
P_VIS = "*::a plugin's computed visualiser answers reach the Variables pane AND the editor's values"

ARMS = [
    ("M1", [(SUP, "  if p.kind == pkQuery and not samePosition(e, sup.epoch):",
             "  if false:")],
     [(HOST, STALE)],
     "§11.4.5: the epoch check removed, a stale answer is shown"),
    ("M2", [(SDK, "          let busy = busyNow()",
             "          let busy = \"\"")],
     [(HOST, HANG)],
     "§11.6.2: the watchdog no longer names the busy plugin; the hang is unattributed"),
    ("M3", [(PKG, "      if not declared:",
             "      if false:")],
     [(HOST, REFUSE)],
     "§11.3: a native package whose plugin did not declare `process` loads"),
    ("M4", [(SUP, "        if s.suspect:",
             "        if false:")],
     [(HOST, SWALLOW)],
     "§11.7.4: a suspect plugin's layer is not transparent"),
    ("M5", [(SUP, "  ## (host modal layers rank above every plugin layer).\n"
                  "  if not sup.hostModalOpen.isNil and sup.hostModalOpen():",
             "  ## (host modal layers rank above every plugin layer).\n"
             "  if false:")],
     [(HOST, MODAL)],
     "§11.7.3: a plugin layer ranks above the palette and the prompt"),
    ("M6", [(SUP, "  for r in RecoveryChordSpellings: reserved.add bindingKeyName(r)",
             "  discard RecoveryChordSpellings")],
     [(HOST, RESERVED)],
     "§11.7.6: a plugin may bind the recovery chord"),
    ("M7", [(SUP, "  if kept.len < RecoveryChordCount:",
             "  if true:")],
     [(HOST, CHORD)],
     "§11.7.6: three Escapes within a second do not recover input"),
    ("M8", [(SUP, "  if s.openings >= sup.openingsToLatch:",
             "  if false:")],
     [(HOST, LATCH)],
     "§11.7.5: the third opening does not latch the breaker"),
    ("M9", [(SUP, "  sup.removePushed(s, \"breaker-open\", tellPlugin = true)",
             "  discard")],
     [(HOST, SWALLOW)],
     "§11.7.5: an open breaker leaves the plugin's layer in force"),
    ("M10", [(LINK, "  const Marker = \"ct-plugin-crash: \"",
              "  const Marker = \"ct-plugin-crash-never: \"")],
     [(HOST, SEGV)],
     "§11.6.1: the SDK's crash record is not read; a segfault is unattributed"),
    ("M11", [(RUNTIME, "      recovery = rt.plugins.observeEscape()",
              "      recovery = false")],
     [(PTY, P_SWALLOW)],
     "§11.7.6: the terminal's router no longer observes Escape for the recovery chord"),
    ("M12", [(SERVICE, "      queue[].add move",
              "      discard move")],
     [(PTY, P_GRANT)],
     "a plugin's relayed step is swallowed instead of run as the terminal's own move"),
    ("M13", [(MAIN, "  let extensionsOff = command.flags.noExtensions or",
              "  let extensionsOff = false and")],
     [(PTY, P_SAFE)],
     "§7: --no-extensions is parsed and no longer read by the binary"),
    ("M14", [(IO, "          if not sock.expectPeerName(host):",
              "          if false and not sock.expectPeerName(host):")],
     [(TLS, T_NAME)],
     "§8.1: TLS accepts a trusted certificate issued for another name"),
    ("M15", [(CLI, "        of gsUndecided: undecided.add $cap",
              "        of gsUndecided: discard")],
     [(CLITEST, C_WAIT)],
     "§11.6.5: ct plugins status reports a plugin waiting for consent as enabled"),
    ("M16", [(LINK, "  if msg{\"type\"}.getStr(\"\") == \"ping\" and p.hasLiveness:",
              "  if false:")],
     [(HOST, PONG)],
     "§11.4.1: a ping is queued behind the protocol's frames, not on the "
     "liveness descriptor"),
    ("M17", [(SDK, "          if c.pongLocked:", "          if true:")],
     [(HOST, PONG)],
     "§11.6.2: the pong waits for the frame lock the blocked main thread holds"),
    ("M18", [(LINK, "                 (errPipe[1], cint(1)), (errPipe[1], cint(2))]",
              "                 (outPipe[1], cint(1)), (errPipe[1], cint(2))]")],
     [(HOST, ECHO)],
     "§11.4.1: the child's stdout is the protocol; an echo is a protocol violation"),
    ("M19", [(SDK, "      p.attributed(\"\"):\n        t.cb(p)",
              "      t.cb(p)")],
     [(HOST, T_RAISE)],
     "§11.5: a timer is not attributed; its error ends the process"),
    ("M20", [(SDK, "      let owner = currentOwner",
              "      let owner: Plugin = nil")],
     [(HOST, A_HANG), (HOST, A_RAISE)],
     "§11.5: an async continuation runs with no owner: its hang and its "
     "error name no plugin"),
    ("M21", [(SDK, "    discard p.io.state.handles.closeAll(failures)",
              "    discard")],
     [(HOST, SWEEP)],
     "§8.1.1: deactivation leaves the plugin's processes and sockets open"),
    ("M22", [(SDK, "    closeProcess(child)      # SIGKILL to the group, reaped",
              "    discard")],
     [(HOST, GROUP)],
     "§8.1: a program past its deadline is reported and left running"),
    ("M23", [(SDK, "      if keep < r.data.len: run.truncated = true",
              "      if keep < r.data.len: run.truncated = true\n"
              "      run.output.setLen(0)")],
     [(HOST, RUN)],
     "§8.1: a program's output is not collected"),
    ("M24", [(SDK, "  for p in sdk.plugins.values:\n    if not p.active or p.timers.len == 0:",
              "  for p in sdk.plugins.values:\n    if true:")],
     [(HOST, T_HANG)],
     "§11.5: timers never run"),
    ("M30", [(SUP, "      if chordSuspect: min(sup.chordProbeMs, sup.pingBusyMs)\n"
                   "      elif waiting or inst.busy.len > 0: sup.pingBusyMs",
              "      if chordSuspect: sup.pingBusyMs\n"
                   "      elif waiting or inst.busy.len > 0: sup.pingBusyMs")],
     [(HOST, INFLIGHT)],
     "§11.7.6: a chord-suspect plugin is asked again only at the liveness "
     "interval; a healthy one stays not responding while a ping was in flight"),
    ("M40", [(SERVICE, "  of pmkOutcome, pmkRelayMove:\n    if move.session != shown:",
              "  of pmkOutcome, pmkRelayMove:\n    if false:")],
     [(MOVES, M_TAB)],
     "a plugin's jump classified against its session runs on whichever tab is shown"),
    ("M41", [(SUP, "        if not samePosition(held.epoch, sup.epoch) or held.answers.len == 0:",
              "        if held.answers.len == 0:")],
     [(HOST, COMPUTED)],
     "§11.4.5: a computed visualiser's answers from the previous stop are shown at the next"),
    ("M42", [(KEYS, "    if c >= '!' and c <= '~':\n      return $c",
              "    if c >= '!' and c <= '~':\n      return ($c).toLowerAscii")],
     [(MOVES, M_CASE)],
     "§11.7.2: a binding's bare letter is folded to lower case, so `J` takes `j`"),
    ("M43", [(RUNTIME, "      not rt.plugins.claimsKey(rt.lastKey)):",
              "      true):")],
     [(MOVES, M_ALT)],
     "an Alt chord only a plugin binds is read as the bare key (Ctrl+Alt+k arrives as Ctrl+k)"),
    ("M44", [(SUP, "  if sup.visualiseRequests.hasKey(id):",
              "  if false:")],
     [(HOST, COMPUTED)],
     "a computed visualiser's answer is queued for nobody and never presented"),
    ("M45", [(SUP, "    sup.sendVisualiseQueries()",
              "    discard")],
     [(HOST, COMPUTED)],
     "the values on screen are never asked of a computed visualiser"),
    ("M46", [(SERVICE, "      move.outcome.jumpsToCall = true",
              "      move.outcome.jumpsToCall = false")],
     [(MOVES, M_ROUTES)],
     "a relayed call trace jump is not the call trace pane's own jump"),
    ("M47", [(SUP, "      if refusal.len > 0:\n        sup.refuse(s, refusal)\n        return",
              "      if false:\n        sup.refuse(s, refusal)\n        return")],
     [(HOST, HOOK)],
     "an action the front-end refused is applied to the session behind it anyway"),
    ("M48", [(MAIN, "        session.applyOutcome(rt, moved)\n        owedRefresh = false",
              "        discard moved\n        owedRefresh = false")],
     [(PTY, P_MOVES)],
     "a relayed jump, watch or step out is taken and never carried out by the terminal's loop"),
    ("M49", [(MAIN, "        session.renderValuesAgain(rt)",
              "        discard rt")],
     [(PTY, P_VIS)],
     "a computed visualiser's answers arrive and the values on screen are not drawn again"),
]


HARNESS = Harness("plat81-plugin-process", Path(__file__).resolve().parent,
                  SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
