#!/usr/bin/env python3
"""PLAT-71 Part E — the mutation harness for the real-emulator lane, the persona
capture tool and the captured personas (CodeTracer-TUI-Terminal-Adaptation.md
§13.1, §13.4, §13.5).

Each arm plants ONE defect in the width probe's text (`terminal_profile.nim`),
the capture tool (`capture_terminal_persona.nim`), the personas' reading
(`personas.nim`), the persona peer (`persona_peer.nim`) or the lane's pixel
readings (`real_emulators/emulators.nim`), and must be killed by the check
named for it. The arms on the lane's readings are graded by the lane itself,
in the real emulator the filter names (`CT_REAL_EMULATORS_ONLY`); they need
`build/bin/codetracer-tui`, `build/bin/capture-terminal-persona` and
../GuiAssert, as `just test-tui-real-emulators` does. The engine — control
digests over subjects AND suites, the needle scan, `because` derived from a
run and then required, per-arm restore — is `plat71_mutation_engine.py`.

Usage:
    run-plat71e-emulators-mutations.py [--only ID,ID] [--derive]
    run-plat71e-emulators-mutations.py --needle-scan
    run-plat71e-emulators-mutations.py --record-control-hashes
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plat71_mutation_engine import Harness  # noqa: E402

PROFILE = "src/frontend/tui/app/theme/terminal_profile.nim"
CAPTURE = "tools/capture-terminal-persona/capture_terminal_persona.nim"
PERSONAS = "src/frontend/tui/app/tests/personas/personas.nim"
PEER = "src/frontend/tui/tests/real_terminal/persona_peer.nim"
READINGS = "src/frontend/tui/tests/real_emulators/emulators.nim"

ROUND = "src/frontend/tui/tests/test_plat71_terminal_round.nim"
CAPTURE_SUITE = "src/frontend/tui/tests/test_capture_terminal_persona.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat71_terminal_pty.nim"
LANE = "src/frontend/tui/tests/real_emulators/test_real_emulators.nim"

SUBJECTS = [PROFILE, CAPTURE, PERSONAS, PEER, READINGS]
SUITES = [ROUND, CAPTURE_SUITE, PTY, LANE]
IN_BINARY = {PROFILE}

R_ROUND = "*::§4.2: the round asks every new question, the fence last"
R_CAPTURED = ("*::the captured personas: their round is this round, and "
              "noteReply reads them as probeOf does")
C_REFILE = ("*::every committed persona: its replies re-split and re-filed "
            "as committed")
P_BYTES = "*::the peer answers each question with the bytes its terminal sent"

ARMS = [
    ("E1", [(PROFILE, '    "…", "▕", "\\u{1FB87}", "⏮", "中",',
             '    "…", "▕", "\\U0001FB87", "⏮", "中",')],
     [(ROUND, R_ROUND)],
     "§4.3: the P3 probe prints U+0001 and `FB87` instead of U+1FB87"),
    ("E2", [(PERSONAS, "      if ok: result.xtversion = text",
             "      if ok: discard text")],
     [(ROUND, R_CAPTURED)],
     "§13.1: a captured persona read without its XTVERSION answer"),
    ("E3", [(PEER, "    if a.len > 0: result.verbatim[query] = a",
             "    if a.len > 0: discard a")],
     [(PTY, P_BYTES)],
     "§13.2: the peer drops the captured OSC 11 / XTGETTCAP / DECRQSS / cell-size answers"),
    ("E4", [(CAPTURE,
             '  elif token.startsWith("\\x1b[>") and token.endsWith("c"): "da2"',
             '  elif token.startsWith("\\x1b[>") and token.endsWith("c"): "da1"')],
     [(CAPTURE_SUITE, C_REFILE)],
     "§13.1: the capture files DA2's answer as the fence"),
    ("E5", [(CAPTURE, "          j += 2", "          j += 1")],
     [(CAPTURE_SUITE, C_REFILE)],
     "§13.1: the capture cuts a DCS / OSC answer before its string terminator"),
    ("E6", [(READINGS, "  (ok, what)", "  (true, what)")],
     [(LANE, "xterm")],
     "§13.4: a block or Legacy Computing cell read as its shape whatever is drawn "
     "(xterm draws the Legacy Computing row from a font without it)"),
    ("E7", [(READINGS, "  1.0 - diff.float / total.float", "  1.0")],
     [(LANE, "kitty")],
     "§13.4: every cell read as a closing bracket in place"),
]


HARNESS = Harness("plat71e-emulators", Path(__file__).resolve().parent,
                  SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
