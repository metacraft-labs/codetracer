#!/usr/bin/env python3
"""PLAT-71 Part B — the mutation harness for the capability profile and the start-up round
(CodeTracer-TUI-Terminal-Adaptation.md §13.5).

Each arm plants ONE defect in the resolver (`capabilities.nim`), the round (`terminal_probe.nim`) or the driver's restore (`terminal_driver.nim`) and must be killed by the check the
spec names for it (the arm's description cites the invariant). The engine —
control digests over subjects AND suites, the needle scan, `because` derived
from a run and then required, the rebuild of the shipped binary for a pty
suite, per-arm restore — is `plat71_mutation_engine.py`.

Usage:
    run-plat71b-profile-mutations.py [--only ID,ID] [--derive]
    run-plat71b-profile-mutations.py --needle-scan
    run-plat71b-profile-mutations.py --record-control-hashes
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plat71_mutation_engine import Harness  # noqa: E402

CAPS = "src/frontend/tui/app/theme/capabilities.nim"
PROBE = "src/frontend/tui/host/terminal_probe.nim"
DRIVER = "src/frontend/tui/host/terminal_driver.nim"

PROFILE = "src/frontend/tui/app/tests/test_plat71_terminal_profile.nim"
ROUND = "src/frontend/tui/tests/test_plat71_terminal_round.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat71_terminal_pty.nim"

SUBJECTS = [CAPS, PROBE, DRIVER]
SUITES = [PROFILE, ROUND, PTY]
IN_BINARY = {CAPS, PROBE, DRIVER}

TA2 = "*::TA-2: §5.2's precedence, axis by axis, each adjacent pair"
TA9 = "*::TA-9: modern-unicode is never on by detection alone"
TA12 = "*::TA-12: the cache gives frame 0, and a live answer always beats it"
OQT8 = "*::OQ-T8: a C locale on a terminal that decodes UTF-8 uses Unicode"
ROUNDQ = "*::§4.2: the round asks every new question, the fence last"
F3 = "*::§4.3's F3 rule: a CSI 1;5R is a reply only while the probe waits"
P_PROFILE = "*::the profile per persona, every axis with its source"
P_WIDE = "*::TA-5, TA-8: a terminal measured ambiguous-WIDE gets the safe glyphs"
P_RESTORE = "*::TA-3, TA-10: an interactive session, its screen and its restore"
P_TYPED = "*::TA-4 and the F3 rule: typed-ahead keys survive, a late CSI 1;5R is a key"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    ("B1", [(PROBE, '  bytes.add "\\x1b[1;1H\\x1b[2K" & SyncOffBytes',
             '  bytes.add SyncOffBytes')],
     [(ROUND, ROUNDQ)],
     "TA-3: the width probe's row is not erased in the round's write"),
    ("B2", [(PROBE, "    probe.cprAnswers.add max(0, col - 1)",
             "    discard col")],
     [(PTY, P_WIDE), (ROUND, F3)],
     "TA-5: the cursor reports are ignored and narrow assumed"),
    ("B3", [(CAPS, "    return (explicit.value == acWide, explicit.source,",
             "    if widths.ambiguous == apUnknown: return (explicit.value == acWide, explicit.source,")],
     [(PROFILE, TA2)],
     "TA-2: detection ranked above a setting (ambiguous width)"),
    ("B4", [(CAPS, "    let depth = case explicit.value",
             "    if noColorRequested(env): return (cdMonochrome, csEnvironment)\n    let depth = case explicit.value")],
     [(PROFILE, TA2)],
     "TA-2: NO_COLOR ranked above a setting"),
    ("B5", [(CAPS, '    (false, mcOff, source, "off" & where &',
             '    (would and identity.endToEnd, mcOff, source, "off" & where &')],
     [(PROFILE, TA9), (PTY, P_PROFILE)],
     "TA-9: modern-unicode turned on by identity alone with the value off"),
    ("B6", [(CAPS, "  if model.measured:",
             "  if cache.isSome and widthModelOf(cache.get.widths, -1).measured:\n    return (widthModelOf(cache.get.widths, -1), csCache)\n  if model.measured:")],
     [(PROFILE, TA12)],
     "TA-12: the cache applied over a live answer"),
    ("B7", [(DRIVER, '  if d.graphemeOwned:\n    result.add "\\x1b[?2027l"',
             '  if false:\n    result.add "\\x1b[?2027l"')],
     [(PTY, P_RESTORE)],
     "TA-10: DEC 2027 set and not reset on exit or SIGTERM"),
    ("B8", [(PROBE, "      d.buffered.add token",
             "      discard token")],
     [(PTY, P_TYPED)],
     "TA-4: keys typed while the round waits are dropped"),
    ("B9", [(PROBE, "\n  result.add widthProbeBytes(cols)[0]\n  result.add Da1Query",
             "\n  result.add Da1Query\n  result.add widthProbeBytes(cols)[0]")],
     [(ROUND, ROUNDQ), (PTY, P_PROFILE)],
     "§4.2: the fence moved before the width probe (its answers lost)"),
    ("B10", [(CAPS, "    let on = probe.sync2026 in {1, 2, 3}",
              "    let on = probe.sync2026 in {1, 2, 3} or syncByIdentity(identity)")],
     [(PROFILE, TA2)],
     "§5.2: a negative DECRQM answer loses to the identity list"),
    ("B11", [(PROBE, "  probe.cprAnswers.len < probe.cprExpected",
              "  true")],
     [(ROUND, F3), (PTY, P_TYPED)],
     "§4.3's F3 rule: a CSI 1;5R after the probe is still taken as a reply"),
    ("B12", [(CAPS, "    if identity.known and (globMatch(scope.glob, identity.name) or",
              "    if false and (globMatch(scope.glob, identity.name) or")],
     [(PROFILE, TA2)],
     "TA-2: a [terminal \"<glob>\"] section never applies (OQ-T6)"),
    ("B13", [(PROBE, '  if env.term.toLowerAscii == "linux":',
              "  if false:")],
     [(ROUND, ROUNDQ), (PTY, P_PROFILE)],
     "§4.2: the Linux console is asked the whole round"),
    ("B14", [(CAPS, "  if widths.utf8 == knYes:",
              "  if false:")],
     [(PROFILE, OQT8)],
     "OQ-T8: a C locale on a terminal that decodes UTF-8 stays ASCII"),
]


HARNESS = Harness("plat71b-profile", Path(__file__).resolve().parent,
                  SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
