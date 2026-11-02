#!/usr/bin/env python3
"""PLAT-71 Part D — the mutation harness for multiplexers and the link
(CodeTracer-TUI-Terminal-Adaptation.md §13.5).

Each arm plants ONE defect in the tmux facts and the round's timing (`terminal_probe.nim`) or the link and identity rules (`capabilities.nim`) and must be killed by the check the
spec names for it (the arm's description cites the invariant). The engine —
control digests over subjects AND suites, the needle scan, `because` derived
from a run and then required, the rebuild of the shipped binary for a pty
suite, per-arm restore — is `plat71_mutation_engine.py`.

Usage:
    run-plat71d-mux-mutations.py [--only ID,ID] [--derive]
    run-plat71d-mux-mutations.py --needle-scan
    run-plat71d-mux-mutations.py --record-control-hashes
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plat71_mutation_engine import Harness  # noqa: E402

CAPS = "src/frontend/tui/app/theme/capabilities.nim"
PROBE = "src/frontend/tui/host/terminal_probe.nim"

PROFILE = "src/frontend/tui/app/tests/test_plat71_terminal_profile.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat71_terminal_pty.nim"

SUBJECTS = [CAPS, PROBE]
SUITES = [PROFILE, PTY]
IN_BINARY = {CAPS, PROBE}

TMUXID = "*::§3.3, §4.5: through tmux the outer terminal is tmux's client"
TA12 = "*::TA-12: the cache gives frame 0, and a live answer always beats it"
P_TA14 = "*::TA-14: under a real tmux, one display spawn and no passthrough"
P_TA11 = "*::TA-11: the tmux spawn runs beside the round, not before it"
P_SLOW = "*::a slow link is measured and makes the session link-conservative"
P_LATE = "*::late answers over a slow link are applied and make it conservative"

ARMS = [
    ("D1", [(PROBE, "    tmux = startTmuxQuery()",
             '    tmux = startTmuxQuery()\n    discard writeQueries(d.outFd, "\\x1bPtmux;\\x1b\\x1b[>q\\x1b\\\\")')],
     [(PTY, P_TA14)],
     "TA-14: a passthrough QUERY written under tmux"),
    ("D2", [(PROBE, "    tmux = startTmuxQuery()",
             "    tmux = startTmuxQuery()\n    finishTmuxQuery(tmux, result)")],
     [(PTY, P_TA11)],
     "TA-11: the tmux format spawn made sequential (the round waits for it)"),
    ("D3", [(CAPS, "  let conservative = rtt > LinkConservativeMs",
             "  let conservative = false")],
     [(PTY, P_SLOW), (PROFILE, TA12)],
     "§4.6: a slow link never makes the session link-conservative"),
    ("D4", [(PROBE, "      n.probe.rttMeasured = true\n      n.probe.rttMs = int(monoMs() - n.startedMs)",
             "      discard")],
     [(PTY, P_LATE)],
     "§4.6: a LATE fence's round trip is not measured"),
    ("D5", [(CAPS, "    if probe.tmuxClientTermType.len > 0:",
             "    if false:")],
     [(PROFILE, TMUXID)],
     "§4.5: tmux's client_termtype ignored: the outer terminal unknown"),
]


HARNESS = Harness("plat71d-mux", Path(__file__).resolve().parent,
                  SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
