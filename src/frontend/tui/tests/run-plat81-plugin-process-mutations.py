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
rebuilds whenever a source is newer than the binary, which a mutation is.

Usage:
    run-plat81-plugin-process-mutations.py [--only ID,ID] [--derive]
    run-plat81-plugin-process-mutations.py --needle-scan
    run-plat81-plugin-process-mutations.py --record-control-hashes
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plat71_mutation_engine import Harness  # noqa: E402

SUP = "src/frontend/viewmodel/plugin_host/supervisor.nim"
LINK = "src/frontend/viewmodel/plugin_host/process_link.nim"
SDK = "src/plugin_sdk/codetracer_plugin_sdk.nim"
PKG = "src/common/plugin_model/package.nim"

HOST = "src/frontend/viewmodel/tests/unit/test_plugin_process_host.nim"

SUBJECTS = [SUP, LINK, SDK, PKG]
SUITES = [HOST]
IN_BINARY = set()

STALE = "*::an answer computed at the old position is never shown"
HANG = "*::a handler that loops forever is attributed by the watchdog"
REFUSE = "*::a native package whose plugin does not declare `process` is refused"
SWALLOW = "*::a plugin that swallows keys loses the keyboard: dropped, transparent, then open"
MODAL = "*::no plugin layer is consulted while a host modal is open"
RESERVED = "*::a plugin binding the palette key or the recovery chord is refused, by name"
CHORD = "*::three Escapes pop a layer that binds Escape, and open the recovery dialog"
LATCH = "*::half-open after the backoff; one strike reopens; the third opening latches until Re-enable"
SEGV = "*::a plugin that segfaults on activation: blamed by name, siblings restarted at most 3 times"

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
    ("M6", [(SUP, "  k in sup.reservedKeys or k in RecoveryChordSpellings",
             "  k in sup.reservedKeys")],
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
]


HARNESS = Harness("plat81-plugin-process", Path(__file__).resolve().parent,
                  SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
