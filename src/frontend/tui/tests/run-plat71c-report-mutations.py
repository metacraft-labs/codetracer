#!/usr/bin/env python3
"""PLAT-71 Part C — the mutation harness for the report, the card and :terminal-info
(CodeTracer-TUI-Terminal-Adaptation.md §13.5).

Each arm plants ONE defect in the report (`terminal_report.nim`) or `:terminal-info` (`runtime.nim`) and must be killed by the check the
spec names for it (the arm's description cites the invariant). The engine —
control digests over subjects AND suites, the needle scan, `because` derived
from a run and then required, the rebuild of the shipped binary for a pty
suite, per-arm restore — is `plat71_mutation_engine.py`.

Usage:
    run-plat71c-report-mutations.py [--only ID,ID] [--derive]
    run-plat71c-report-mutations.py --needle-scan
    run-plat71c-report-mutations.py --record-control-hashes
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plat71_mutation_engine import Harness  # noqa: E402

REPORT = "src/frontend/tui/app/theme/terminal_report.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"

PROFILE = "src/frontend/tui/app/tests/test_plat71_terminal_profile.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat71_terminal_pty.nim"

SUBJECTS = [REPORT, RUNTIME]
SUITES = [PROFILE, PTY]
IN_BINARY = {REPORT, RUNTIME}

TA13 = "*::TA-13: the report's JSON names a source for every axis"
CARD = "*::§10.3: the glyph test card"
P_INFO = "*:::terminal-info: the live report, the card, and y for this terminal"

ARMS = [
    ("C1", [(REPORT, '  result = %*{"value": value, "from": $source}',
             '  result = %*{"value": value}')],
     [(PROFILE, TA13)],
     "TA-13: an axis reported without the source that decided it"),
    ("C2", [(REPORT, '    ("legacy", "[🮇] [🮂] [🭰] [🭻]"),',
             '    ("legacy", ""),')],
     [(PROFILE, CARD)],
     "§10.3: the card without its Legacy Computing row"),
    ("C3", [(RUNTIME, "      else: service.setForThisTerminal(lsModernUnicode, value)",
             "      else: rt.applyLayoutSetting(lsModernUnicode, value)")],
     [(PTY, P_INFO)],
     "OQ-T6: the card's y sets modern-unicode for every terminal, not this one"),
    ("C4", [(RUNTIME, "  rt.terminalInfo.lastKey = name",
             "  discard name")],
     [(PTY, P_INFO)],
     "§10.1: :terminal-info does not show the key it was given"),
]


HARNESS = Harness("plat71c-report", Path(__file__).resolve().parent,
                  SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
