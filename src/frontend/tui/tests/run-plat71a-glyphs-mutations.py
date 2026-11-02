#!/usr/bin/env python3
"""PLAT-71 Part A — the mutation harness for the glyph table and the width function
(CodeTracer-TUI-Terminal-Adaptation.md §13.5).

Each arm plants ONE defect in the glyph table (`glyph_table.nim`, `scrollbar_styles.nim`), the width function (`styled_row.nim`), the colour pass (`degradation.nim`), a view that draws chrome, the width fences (`ssh_tuning.nim`, §6.5) or the cut by content kind (`table_overflow.nim` and its callers, §9.2) and must be killed by the check the
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
SSH = "src/frontend/tui/host/ssh_tuning.nim"
EVENTS = "src/frontend/tui/app/views/event_log.nim"
TREE = "src/frontend/tui/app/views/tree_node.nim"
FORMAT = "src/frontend/tui/app/formatters/type_formatters.nim"
OVERFLOW = "src/frontend/viewmodel/viewmodels/table_overflow.nim"

PROFILE = "src/frontend/tui/app/tests/test_plat71_terminal_profile.nim"
GLYPHS = "src/frontend/tui/tests/test_plat71_glyph_table.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat71_terminal_pty.nim"
VMU = "src/frontend/viewmodel/tests/unit/test_plat70b_table_overflow.nim"

SUBJECTS = [TABLE, STYLES, ROW, DEGRADE, GUTTER, TRACE, TOPBAR, SSH, EVENTS,
            TREE, FORMAT, OVERFLOW]
SUITES = [PROFILE, GLYPHS, PTY, VMU]
IN_BINARY = set(SUBJECTS)

TA8 = "*::TA-8: no one-cell role is an East Asian Width A glyph when wide"
SCREENS = "*::every profile's full screen on a real recording"
TA7 = "*::TA-7: content is never transliterated on the ASCII tier"
WIDTH = "*::§6.6: one width function, under an explicit policy"
MODERN = "*::modern-unicode resolved on draws the Legacy Computing thumb"
P_TA7 = "*::TA-7: on the ASCII tier the program's text is drawn as recorded"
CUT = "*::§9.2: a path loses its middle, a number is never cut silently"
P_FENCE = "*::§6.5, §6.6: content's zero-width runes are drawn; unmeasured widths are fenced"
V_PATH = "*::a path keeps its file name and loses its middle"

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
    # ---- §6.5 width fences, §6.6 a grapheme's zero-width runes, §9.2 cuts ----
    ("A9", [(SSH, "  let fences = widthFencesOf(e.caps)",
             "  let fences = WidthFences()")],
     [(PTY, P_FENCE)],
     "§6.5: no width fence — a cell the terminal left unmeasured is placed by its own advance"),
    ("A10", [(SSH, "    noClusters: w.clusters != knYes)",
              "    noClusters: false)")],
     [(PTY, P_FENCE)],
     "§6.5: a ZWJ sequence on a terminal that sums it is not fenced"),
    ("A11", [(ROW, "        g.cells[last].rune.add $r",
              "        discard r")],
     [(PTY, P_FENCE)],
     "§6.6: a combining mark or a joiner in program text is dropped from the grid"),
    ("A12", [(EVENTS, "                               cutKindOf(EventLogTablePane, $col),",
              "                               cutKindOf(\"\", $col),")],
     [(GLYPHS, CUT)],
     "§9.2: the Event Log's location is cut at its end (the line number lost)"),
    ("A13", [(TREE, "                     (if isNumberText(spec.value): ckNumber else: ckEnd),",
              "                     ckEnd,")],
     [(GLYPHS, CUT)],
     "§9.2: a number value is cut silently (a prefix of its digits)"),
    ("A14", [(FORMAT, "  if f.truncated and marker != Ellipsis and f.midMarker > 0 and",
              "  if false and f.midMarker > 0 and")],
     [(GLYPHS, CUT)],
     "§6.3/§9.2: a middle cut keeps `…` on the ASCII tier"),
    ("A15", [(OVERFLOW, "        return head & Ellipsis & tail",
              "        return ctx.clipToCells(line, cells).text")],
     [(VMU, V_PATH)],
     "§9.2: the shared presenter cuts a path at its end (the file name lost)"),
]


HARNESS = Harness("plat71a-glyphs", Path(__file__).resolve().parent,
                  SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
