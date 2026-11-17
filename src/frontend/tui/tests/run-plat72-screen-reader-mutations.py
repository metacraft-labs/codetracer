#!/usr/bin/env python3
"""The mutation harness for the terminal front-end's screen-reader mode
(CodeTracer-TUI-Terminal-Adaptation.md §9.4, SR-D1 – SR-D7; §13.5), and for
the two report defects the real-emulator lane found beside it (§4.5: the
wrapped OSC 22 query through tmux and the pointer remedy; §10.1: the one-shot
report's wait).

Each arm plants ONE defect and must be killed by the check the spec names for
it (the arm's description cites the invariant: TA-13, TA-15 – TA-20). The
engine — control digests over subjects AND suites, the needle scan, `because`
derived from a run and then required, the rebuild of the shipped binary for a
pty suite, per-arm restore — is `plat71_mutation_engine.py`.

Usage:
    run-plat72-screen-reader-mutations.py [--only ID,ID] [--derive]
    run-plat72-screen-reader-mutations.py --needle-scan
    run-plat72-screen-reader-mutations.py --record-control-hashes
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plat71_mutation_engine import Harness  # noqa: E402

CAPS = "src/frontend/tui/app/theme/capabilities.nim"
GLYPHS = "src/frontend/tui/app/views/glyph_table.nim"
BARS = "src/frontend/tui/app/views/scrollbar_styles.nim"
LOCATOR = "src/frontend/tui/app/views/focus_locator.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
REPORT = "src/frontend/tui/app/theme/terminal_report.nim"
POINTER = "src/frontend/tui/app/theme/pointer_protocol.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
MAIN = "src/frontend/tui/main.nim"
PROBE = "src/frontend/tui/host/terminal_probe.nim"

TIER1 = "src/frontend/tui/tests/test_plat72_screen_reader.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat72_screen_reader_pty.nim"
DIAG = "src/frontend/tui/tests/real_terminal/test_terminal_diagnostics_pty.nim"
P70F = "src/frontend/tui/tests/real_terminal/test_plat70f_pointer_pty.nim"

SUBJECTS = [CAPS, GLYPHS, BARS, LOCATOR, SHELL, REPORT, POINTER, RUNTIME,
            MAIN, PROBE]
SUITES = [TIER1, PTY, DIAG, P70F]
IN_BINARY = set(SUBJECTS)

TA15 = "*::TA-15*"
FORCED = "*::SR-D3, SR-D4*"
QUIET = "*::TA-16: the quiet column*"
SCREEN = "*::TA-16, TA-19*"
LOCATE = "*::focus_locator*"
REPORTED = "*::TA-13*"
FOCUS = "*::TA-16 to TA-19*"
KEPT = "*::TA-18: a message*"
HOVER = "*::TA-20*"
WAITS = "*::--capabilities waits*"
TMUX = "*::inside tmux*"
REMEDY = "*::the remedy names allow-passthrough*"

ACCESSIBLE = '  if a.len > 0 and a.toLowerAscii notin ["0", "false", "no", "off"]:'

ARMS = [
    ("S1", [(CAPS, ACCESSIBLE, "  if false:")],
     [(TIER1, TA15)],
     "TA-15: ACCESSIBLE says nothing (SR-D2's hint ignored)"),
    ("S2", [(CAPS, ACCESSIBLE, "  if a.len > 0:")],
     [(TIER1, TA15)],
     "TA-15: ACCESSIBLE=0 / false / no / off read as a screen reader"),
    ("S3", [(CAPS, '  if env.term == "linux":', "  if true:")],
     [(TIER1, TA15)],
     "TA-15: Speakup's synthesizer believed off the Linux console"),
    ("S4", [(CAPS, '    (tier, tierFrom, tierNote) = (tierAscii, screenReaderFrom, '
                   '"screen-reader")', "    discard")],
     [(TIER1, FORCED)],
     "SR-D3: the mode leaves the glyph tier to the glyphs setting"),
    ("S5", [(CAPS, "    (reduceMotion, reduceMotionFrom) = (true, screenReaderFrom)",
             "    discard")],
     [(TIER1, FORCED)],
     "SR-D4: the mode leaves animations on"),
    ("S6", [(GLYPHS, '  if p.quiet and role in DecorativeRoles: " "',
             '  if p.quiet and role in DecorativeRoles - {grBoxVertical}: " "')],
     [(TIER1, QUIET)],
     "TA-16: one decorative role (the box's vertical) drawn in the quiet column"),
    ("S7", [(BARS, "  if g.glyphs.quiet:", "  if false:")],
     [(TIER1, QUIET)],
     "TA-16: the scrollbar's thumb and track drawn in the mode"),
    ("S8", [(MAIN, "  if rt.caps.screenReader and rt.focusSpot.found and not prompting and",
             "  if false and rt.caps.screenReader and rt.focusSpot.found and not prompting and")],
     [(PTY, FOCUS)],
     "TA-17: the terminal's cursor left hidden off the focused element"),
    ("S9", [(RUNTIME, '  rt.note(announcementOf(spot, entered, paneTitle(pane, "")))',
             '  discard announcementOf(spot, entered, paneTitle(pane, ""))')],
     [(PTY, FOCUS)],
     "TA-18: a focus change not announced on the status line"),
    ("S10", [(LOCATOR, '  if enteredPane: paneName & ": " & row else: row',
              '  paneName & ": " & row')],
     [(TIER1, LOCATE)],
     "TA-18: the pane named again on every row move"),
    ("S11", [(RUNTIME, "  if wrote:", "  if false:")],
     [(PTY, KEPT)],
     "TA-18: the keystroke's own message overwritten by the announcement"),
    ("S12", [(RUNTIME, "  if rt.hostingPane or not rt.caps.screenReader:",
              "  if true:")],
     [(TIER1, SCREEN)],
     "TA-19: side-by-side panes in the mode (not one pane following focus)"),
    ("S13", [(RUNTIME, "    if event.row == 0 and not rt.caps.screenReader:",
              "    if event.row == 0:")],
     [(PTY, HOVER)],
     "TA-20: a control's hover words on the status line in the mode"),
    ("S14", [(REPORT, '  result.add pad("Screen reader") &',
              '  discard pad("Screen reader") &')],
     [(TIER1, REPORTED)],
     "TA-13: the report without the screen-reader line"),
    ("S15", [(SHELL, "    if g.glyphs.quiet and status.notification.len > 0:",
              "    if false:")],
     [(PTY, FOCUS)],
     "SR-D7: the announcement right-aligned behind the bottom labels"),
    ("D1", [(MAIN, "        flags, prefs, timeoutMs = diagnosticProbeTimeoutMs(),",
             "        flags, prefs, timeoutMs = startupProbeTimeoutMs(),")],
     [(DIAG, WAITS)],
     "§10.1: --capabilities keeps the session's 10 ms bound"),
    ("D2", [(PROBE, "  d.holdKeyProtocol((n.probe.pointerWrappedAsked or",
             "  d.holdKeyProtocol(false and (n.probe.pointerWrappedAsked or")],
     [(DIAG, TMUX)],
     "§4.5: modifyOtherKeys on before the outer terminal's answer through tmux"),
    ("D3", [(POINTER, "    if passthroughOn(passthrough):", "    if false:")],
     [(P70F, REMEDY)],
     "§4.5: the allow-passthrough remedy given while tmux reports it on"),
    ("D4", [(PROBE, "     env.tmux.len == 0:", "     true:"),
            (PROBE, "    result.add pointerQuery(false)",
             "    result.add pointerQuery(env.tmux.len > 0)")],
     [(DIAG, TMUX)],
     "§4.5: the wrapped OSC 22 query written in the round, with the "
     "alternate-screen switch"),
    ("D5", [(PROBE, "  if not probe.pointerWrappedDue:", "  if true:")],
     [(DIAG, TMUX)],
     "§4.5: the wrapped OSC 22 query never written inside tmux"),
]


HARNESS = Harness("plat72-screen-reader", Path(__file__).resolve().parent,
                  SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
