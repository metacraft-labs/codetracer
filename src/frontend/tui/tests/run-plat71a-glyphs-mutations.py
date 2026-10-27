#!/usr/bin/env python3
"""PLAT-71 Part A — the mutation harness for the glyph table and the width function
(CodeTracer-TUI-Terminal-Adaptation.md §13.5).

Each arm plants ONE defect in the glyph table (`glyph_table.nim`, `scrollbar_styles.nim`), the width function (`styled_row.nim`), the colour pass (`degradation.nim`) or a view that draws chrome and must be killed by the check the
spec names for it (the arm's description cites the invariant). The engine —
control digests over subjects AND suites, the needle scan, `because` derived
from a run and then required, the rebuild of the shipped binary for a pty
suite, per-arm restore — is `plat71_mutation_engine.py`.

Usage:
    run-plat71a-glyphs-mutations.py [--only ID,ID] [--derive]
    run-plat71a-glyphs-mutations.py --needle-scan
    run-plat71a-glyphs-mutations.py --record-control-hashes
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plat71_mutation_engine import Harness  # noqa: E402

TABLE = "src/frontend/tui/app/views/glyph_table.nim"
STYLES = "src/frontend/tui/app/views/scrollbar_styles.nim"
ROW = "src/frontend/tui/app/views/styled_row.nim"
DEGRADE = "src/frontend/tui/app/theme/degradation.nim"
GUTTER = "src/frontend/tui/app/views/gutter.nim"
TRACE = "src/frontend/tui/app/views/call_trace.nim"
TOPBAR = "src/frontend/tui/app/views/top_bar.nim"

PROFILE = "src/frontend/tui/app/tests/test_plat71_terminal_profile.nim"
GLYPHS = "src/frontend/tui/tests/test_plat71_glyph_table.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat71_terminal_pty.nim"

SUBJECTS = [TABLE, STYLES, ROW, DEGRADE, GUTTER, TRACE, TOPBAR]
SUITES = [PROFILE, GLYPHS, PTY]
IN_BINARY = set(SUBJECTS)

TA8 = "*::TA-8: no one-cell role is an East Asian Width A glyph when wide"
SCREENS = "*::every profile's full screen on a real recording"
TA7 = "*::TA-7: content is never transliterated on the ASCII tier"
WIDTH = "*::§6.6: one width function, under an explicit policy"
MODERN = "*::modern-unicode resolved on draws the Legacy Computing thumb"
P_TA7 = "*::TA-7: on the ASCII tier the program's text is drawn as recorded"

ARMS = [
    ("A1", [(TABLE, '    grDividerV:            ["▏",      "│",    "|",   "|"],',
             '    grDividerV:            ["▏",      "│",    "|",   "▏"],')],
     [(PROFILE, TA8), (GLYPHS, SCREENS)],
     "TA-8: the ambiguous-wide column skipped for one role (the vertical divider)"),
    ("A2", [(DEGRADE, "    result.add StyledSpan(text: span.text, style: degradeStyle(span.style, caps))",
             "    result.add StyledSpan(text: (if caps.borders == bmAscii: asciiProse(span.text) else: span.text), style: degradeStyle(span.style, caps))")],
     [(PTY, P_TA7)],
     "TA-7: content transliterated on the ASCII tier (the frame-wide pass back)"),
    ("A3", [(GUTTER, "  of gmBreakpoint: glyphs.glyph(grBreakpoint)",
             "  of gmBreakpoint: BreakpointGlyph")],
     [(GLYPHS, TA7)],
     "§6.3: the gutter's breakpoint drawn without the table (Unicode on the ASCII tier)"),
    ("A4", [(TRACE, "           else: g.glyphText(grCallLeaf))",
             "           else: seg.text)")],
     [(GLYPHS, SCREENS)],
     "TA-6/§6.3: the call trace's leaf toggle drawn from the shared row, not the table"),
    ("A5", [(TOPBAR, "  if m.glyphs.tier == tierAscii:",
             "  if false:")],
     [(GLYPHS, SCREENS)],
     "§6.1: the transport icons drawn as Unicode on the ASCII tier"),
    ("A6", [(ROW, "  for r in runes(s):\n    result += cellsOfRune(r, ambiguous)\n\nproc cellWidthOf*(s: string): int =",
             "  for r in runes(s):\n    result += max(1, cellsOfRune(r, ambiguous))\n\nproc cellWidthOf*(s: string): int =")],
     [(GLYPHS, WIDTH)],
     "§6.6: a combining mark counted as a cell of its own"),
    ("A7", [(ROW, "    let w = cellsOfRune(r, g.ambiguous)",
             "    let w = cellsOfRune(r, awNarrow)")],
     [(GLYPHS, WIDTH)],
     "§6.6: the grid paints narrow whatever the terminal measured"),
    ("A8", [(STYLES, "  elif p.ambiguousWide:",
             "  elif false:")],
     [(GLYPHS, MODERN)],
     "§6.4: the scrollbars never take the ambiguous-wide columns"),
]


HARNESS = Harness("plat71a-glyphs", Path(__file__).resolve().parent,
                  SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
