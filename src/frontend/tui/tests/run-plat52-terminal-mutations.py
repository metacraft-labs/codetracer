#!/usr/bin/env python3
"""PLAT-52 — the mutation harness for the Terminal Output pane on the
terminal and GPUI front-ends (and the desktop it shares its model with): the
shared model's SGR data and screen emulator, the line view's scrollbar
scrubber, the screen's REAL-TIME built-in scrubber, the terminal's pane and
its routes, the GPUI window's pane, and the desktop's view.

    python3 src/frontend/tui/tests/run-plat52-terminal-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=M1,T2

Run from the repository root, inside the dev shell, with `REPLAY_SERVER_BIN`
exported (the session suites, the real-PTY suites and the GPUI plan suite open
the real `terminal_colours` and `terminal_screen` recordings). The GPUI suite
loads `libgpui_nim_shim` from `$ISONIM_GPUI_SHIM_DIR` (else
`../isonim-gpui/rust/target/debug`). No arm edits the engine, so the
`replay-server` `REPLAY_SERVER_BIN` names is never rebuilt; it must be the
build of this checkout's `src/db-backend` (the cargo target the PLAT-50
harness rebuilds into). DE1 runs the REAL Electron app
(`scripts/plat52-capture-electron.sh`, which compiles this checkout's desktop
JavaScript into a prefix); it needs Xvfb (started when no display is set).

ONE ARM PER CLAIM, each naming the case (or the gate) that must die — the
milestone's own five first:

  | claim | arms |
  |---|---|
  | fragment attributes dropped | M1 (the line builder keeps no SGR), M4 (a 256-colour SGR ignored), T6 (the terminal paints no literal colour), G1 (GPUI draws every run in the text colour), V1 (the desktop's span loses its style) |
  | future / past swapped | M2 (`fragmentTense` inverted), T4 (the terminal draws the future as written) |
  | screen replayed from byte 0 per move | M3 (no snapshot and no cache: every move from write 0) |
  | a scrub that does not move the debugger (real-time, the user 2026-10-06) | V2 (the desktop's drag sends no jump), V6 (the desktop's drag queues a move per write crossed instead of one behind the move in flight), V7 (the write reached during a move never sent), T2 (the terminal's drag jumps only on release), P2 (the same, on a real PTY), G2 (GPUI's drag jumps only on release) |
  | the scrubber over the loaded lines only | T1 (the terminal's track over the rows on screen), G3 (GPUI's track over the rows drawn) |
  | the emulator | M5 (a line feed without its carriage return), M6 (the alternate screen entered unerased), M7 (erase in the default colours), M8 (the scroll region ignored), M9 (a clear unmarked), M10 (tabs left in), M11 (the scanner forgets a split sequence), M12 (delete line does nothing — graded by libvterm), M13 (fragments name the next write — graded by the desktop's lines) |
  | the scrollbar scrubber model | S1 (a track click pages instead of jumping), S2 (the thumb may leave the track) |
  | the terminal's pane and routes | T3 (a track click moves the debugger), T5 (the view choice not remembered), T7 (the report leaf back), T8 (no current-position mark), T9 (a click lands on the write after), P1 (the palette's red shifted — graded against the desktop's measured colour on a real PTY) |
  | the vocabulary and the producer | PV1 (the vocabulary view reports instead of listing), SO1 (the producer hands over no writes) |
  | GPUI | G4 (a press lands on the next write), G5 (the toggle does nothing), G6 (the screen's marks not drawn) |
  | the desktop | V3 (a full-screen program opens on its lines), V4 (ArrowRight steps nowhere), V5 (every fragment goes to one write), DE1 (the desktop pane loads no output — the real Electron app) |

THREE VERDICTS (Verification-Harness-Traps §1): `killed` (the named case
reported [FAILED], or the named gate failed), `SURVIVED` (the case [OK] / the
gate green), `HARNESS-FAILURE` (the needle was not unique, the suite did not
compile, the mutated binary did not build, or the run printed no result
lines). A run that prints nothing is never a kill.

Every Nim suite is run FILTERED to its killer case, so an arm costs one case;
the control runs each suite filtered to its NAMED cases (a lane suite may hold
an unrelated known failure — `isonim_views_test`'s `loadStepLinesFor`) and must
see every killer [OK].

THE BINARY IS PART OF THE SUBJECT: an arm graded by a real-PTY suite rebuilds
`build/bin/codetracer-tui` with the defect (`just build-tui`), one graded by
the GPUI plan suite `build/bin/codetracer-gpui` (`just build-gpui`); the
restored tree's binaries are rebuilt before the harness exits.

RESTORATION is from an in-memory snapshot, and every touched file's SHA-256
is compared with the pre-run baseline after each arm (§32). The full run
refuses unless the needle scan is clean AND every touched file matches
`plat52-terminal-mutation-control.sha256`.

NO DECLARED SURVIVORS.

No mocks: every suite graded here runs the product's own model, the
product's own runtime and shell over a real session, a real PTY with real
recordings, libvterm, the shipped GPUI binary's window plan, and the real
Electron app. The desktop view's Tier-1 cases use the ViewModel layer's mock
backend as the one stand-in, recording the requests a gesture sends (their
file header says why).
"""

from __future__ import annotations

import hashlib
import os
import re
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]            # .../codetracer

# --- subjects ---------------------------------------------------------------
MODEL = "src/frontend/viewmodel/viewmodels/terminal_output_model.nim"
SCRUB = "src/frontend/viewmodel/viewmodels/scrollbar_scrubber.nim"
TVM = "src/frontend/viewmodel/viewmodels/terminal_output_vm.nim"
DVIEW = "src/frontend/viewmodel/views/isonim_terminal_output_view.nim"
DESK = "src/frontend/ui/terminal_output.nim"
TPANE = "src/frontend/tui/app/views/terminal_output_pane.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
TSESSION = "src/frontend/tui/host/tui_session.nim"
PROFILE = "src/frontend/tui/app/layout/profile.nim"
GLEAF = "src/frontend/gpui/terminal_output_leaf.nim"
GMAIN = "src/frontend/gpui/main.nim"
PVIEWS = "src/frontend/view_vocabulary/pane_views.nim"
SOURCE = "src/frontend/viewmodel/host/terminal_output_source.nim"
ISONIM_GPUI_DIR = Path(os.environ.get(
    "ISONIM_GPUI_DIR", str(ROOT.parent / "isonim-gpui")))
if os.environ.get("ISONIM_GPUI_SRC"):
    ISONIM_GPUI_DIR = Path(os.environ["ISONIM_GPUI_SRC"]).parent
ENGINE_DIR = ROOT / "src" / "db-backend"

# --- suites and gates ---------------------------------------------------------
VMU = "src/frontend/viewmodel/tests/unit/test_plat52_terminal_output_model.nim"
VNAT = "src/tests/gui/tests/views/isonim_views_test.nim"
T1S = "src/frontend/tui/tests/test_plat52_terminal_output.nim"
REF = "src/frontend/tui/tests/test_plat52_desktop_reference.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat52_terminal_output_pty.nim"
REFT = "src/frontend/tui/tests/real_terminal/test_plat52_screen_reference.nim"
GPLAN = "src/frontend/gpui/tests/test_plat52_gpui_plan.nim"
DESKTOP_GATE = "scripts/plat52-capture-electron.sh"
SPEC = "src/tests/gui/tests/visual/plat52-terminal-capture.spec.ts"

SUBJECTS = [MODEL, SCRUB, TVM, DVIEW, DESK, TPANE, RUNTIME, TSESSION, PROFILE,
            GLEAF, GMAIN, PVIEWS, SOURCE]
SUITES = [VMU, VNAT, T1S, REF, PTY, REFT, GPLAN, DESKTOP_GATE]


def suite_file(path: str) -> str:
    """The file a suite key names (a gate's `#<grep>` suffix dropped)."""
    return path.split("#", 1)[0]


TOUCHED = list(dict.fromkeys(SUBJECTS + [suite_file(p) for p in SUITES] +
                             [SPEC]))

# How each suite is run: (backend, lane whose `--path`s it needs).
SUITE_KIND = {
    VMU: ("c", "vm-unit"),
    VNAT: ("c", "vm-native"),
    T1S: ("c", "tui"),
    REF: ("c", "tui"),
    PTY: ("c", "tui-real-terminal"),
    REFT: ("c", "tui-real-terminal"),
    GPLAN: ("c", "gpui-shell"),
    # The real desktop: both cases of the capture spec.
    DESKTOP_GATE: ("electron", ""),
}
BINARY_SUITES = {PTY}
  # graded against a REBUILT codetracer-tui
GPUI_BINARY_SUITES = {GPLAN}
  # read the WINDOW's render plan of a REBUILT codetracer-gpui
ENGINE_SUBJECTS: set = set()
  # no arm edits the engine
UNISOLATED_SUITES: set = set()
UNFILTERED_CONTROL: set = {DESKTOP_GATE}
  # the gate has no cases to filter by

CONTROL_HASHES = HERE / "plat52-terminal-mutation-control.sha256"
ANSWER_FILES = [ROOT / "src/tests/visual/answers" / "plat52-terminal.electron.json"]
  # what the desktop gate writes; restored after every run (`run_electron`)
SUITE_TIMEOUT = int(os.environ.get("CT_P52_SUITE_TIMEOUT", "3600"))
SHIM = Path(os.environ.get("ISONIM_GPUI_SHIM_DIR",
                           str(ISONIM_GPUI_DIR / "rust/target/debug")))
RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*\s*(.*?)\s*$")

# --- the killer cases, spelled once ------------------------------------------
U_SGR = "the sixteen colours, bright, 256 and direct, and the resets"
U_TENSE = "past, active, future and the current line"
U_TABS = "non-SGR sequences are dropped; tabs go to the next stop"
U_SPLIT = "a sequence split across two writes is still one sequence"
U_ALT = "the alternate screen: entered blank, left with the main screen back"
U_ONLCR = "a written line feed is CR LF (the terminal device's ONLCR)"
U_CSS = "the desktop's palette and its CSS"
U_ERASE = "erased cells take the pen's colours (libvterm's rule)"
U_REGION = "a scroll region scrolls only its rows; reverse index at its top"
U_COST = "a move replays at most one snapshot interval, never from byte 0"
U_MARKS = "the marks: the alternate screen entered and left, a clear"
U_SWEEP = "swept: the thumb stays on the track; a click names its row"
N_SPAN = "a fragment is a span styled from its SGR data, its text a text node"
N_REALTIME = "the scrubber is REAL-TIME: each input moves the debugger"
N_OPENS = "a full-screen program opens on its screen, with the scrubber's marks"
N_ARROW = "ArrowRight on the screen steps to the next write"
N_EACH = "each fragment's click goes to ITS write, not the last one's"
T_LEAF = "the report leaf is gone: the terminal's capability draws it"
T_DATA = "the fragments carry the recorded SGR attributes, as data"
T_PAINT = "the pane paints each run in its attributes; the future is muted"
T_CLICK = "a click on a fragment goes to its write; source, stack, variables agree"
T_SCRUB = "the scrollbar scrubs the WHOLE output and never moves the debugger"
T_MARK = "the current line is marked on the track"
T_VOCAB = "the vocabulary view lists the lines, the current one highlighted"
T_REALTIME = "the screen's scrubber is REAL-TIME: a drag moves the debugger live"
T_REMEMBER = "the view chosen is remembered for the recording"
R_LINES = "the desktop's lines and fragments are the shared model's"
P_COLOURS = "the desktop's colours, a click landing at the desktop's tick"
P_REALTIME = "the screen's scrubber is REAL-TIME, and the screen is the desktop's"
L_AGREE = "the shared model and libvterm agree cell for cell"
G_RUNS = "every line is a row of runs carrying its write, tense and attributes"
G_CLICK = "a press on a run goes to its write; the pane follows"
G_SCRUB = "GPUI's scrollbar scrubs the WHOLE output and never moves the debugger"
G_SCREEN = "the screen view: the recorded screen, scaled, with its marks"
G_REALTIME = "the screen's scrubber is REAL-TIME: a held drag moves the debugger"
G_TOGGLE = "Right steps a write; the toggle shows the lines"
D_DESKTOP = "gate:" + DESKTOP_GATE

CASE_SUITE = {
    U_SGR: VMU, U_TENSE: VMU, U_TABS: VMU, U_SPLIT: VMU, U_ALT: VMU,
    U_ONLCR: VMU, U_CSS: VMU,
    U_ERASE: VMU, U_REGION: VMU, U_COST: VMU, U_MARKS: VMU, U_SWEEP: VMU,
    N_SPAN: VNAT, N_REALTIME: VNAT, N_OPENS: VNAT, N_ARROW: VNAT, N_EACH: VNAT,
    T_LEAF: T1S, T_DATA: T1S, T_PAINT: T1S, T_CLICK: T1S, T_SCRUB: T1S,
    T_MARK: T1S, T_VOCAB: T1S, T_REALTIME: T1S, T_REMEMBER: T1S,
    R_LINES: REF,
    P_COLOURS: PTY, P_REALTIME: PTY,
    L_AGREE: REFT,
    G_RUNS: GPLAN, G_CLICK: GPLAN, G_SCRUB: GPLAN, G_SCREEN: GPLAN,
    G_REALTIME: GPLAN, G_TOGGLE: GPLAN,
    D_DESKTOP: DESKTOP_GATE,
}
NAMED_CASES = list(CASE_SUITE)


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str
    also: tuple = ()

    def edits(self):
        return [(self.path, self.find, self.replace), *self.also]


ARMS = [
    # --- the shared model -----------------------------------------------------
    Arm("M1", MODEL,
        "    b.cur.add TerminalEventFragment(text: text, style: b.attrs,\n",
        "    b.cur.add TerminalEventFragment(text: text, style: TermAttrs(),\n",
        U_SGR, "the line builder keeps no SGR attributes on a fragment"),
    Arm("M2", MODEL,
        "  if fragmentTicks < currentTicks: ttPast\n",
        "  if fragmentTicks < currentTicks: ttFuture\n",
        U_TENSE, "a fragment written before the current tick is the future"),
    Arm("M3", MODEL,
        "  let j = (w + 1) div m.snapshotEvery\n",
        "  let j = 0\n",
        U_COST, "every move replays the stream from write 0",
        also=((MODEL, "  if m.cacheWrite >= start - 1 and m.cacheWrite <= w:\n",
               "  if false:\n"),)),
    Arm("M4", MODEL,
        "            colour = termIndexed(v(flat[i+2]) and 255); ok = true\n",
        "            colour = TermColor(); ok = true\n",
        U_SGR, "a 256-colour SGR decodes to no colour"),
    Arm("M5", MODEL,
        "    s.col = 0\n    s.lineFeed()\n  of '\\v', '\\f': s.lineFeed()\n",
        "    s.lineFeed()\n  of '\\v', '\\f': s.lineFeed()\n",
        U_ONLCR, "a line feed reaches the screen without the terminal's CR"),
    Arm("M6", MODEL,
        "  s.altActive = on\n  if on:\n    s.eraseRect(0, 0, s.rows - 1, s.cols)\n",
        "  s.altActive = on\n  if on:\n    discard\n",
        U_ALT, "the alternate screen is entered with its old contents"),
    Arm("M7", MODEL,
        "  TermCell(ch: 0, attr: s.table.idOf(TermAttrs(fg: s.pen.fg, bg: s.pen.bg)))\n",
        "  TermCell(ch: 0, attr: s.table.idOf(TermAttrs()))\n",
        U_ERASE, "an erased cell drops the pen's colours"),
    Arm("M8", MODEL,
        "  if s.row == s.bottom:\n    s.scrollUp(s.top, s.bottom, 1)\n",
        "  if s.row == s.bottom:\n    s.scrollUp(0, s.bottom, 1)\n",
        U_REGION, "a line feed at the region's bottom scrolls the rows above it"),
    Arm("M9", MODEL,
        "      s.eraseRect(0, 0, s.rows - 1, s.cols)\n      s.sawClear = true\n",
        "      s.eraseRect(0, 0, s.rows - 1, s.cols)\n",
        U_MARKS, "a full clear is not marked under the scrubber"),
    Arm("M10", MODEL,
        "        b.addText(ev, spaces(TermTabStop - (b.col mod TermTabStop)))\n",
        "        b.addText(ev, \"\\t\")\n",
        U_TABS, "a tab is left in the line instead of its stop's spaces"),
    Arm("M11", MODEL,
        "  for t in b.scanner.scanAnsi(ev.content):\n",
        "  b.scanner = AnsiScanner()\n  for t in b.scanner.scanAnsi(ev.content):\n",
        U_SPLIT, "a sequence split across two writes is lost"),
    Arm("M12", MODEL,
        "      s.scrollUp(s.row, s.bottom, n1)\n",
        "      discard n1\n",
        L_AGREE, "delete line does nothing (graded by libvterm)"),
    Arm("M13", MODEL,
        "      eventIndex: i,\n",
        "      eventIndex: i + 1,\n",
        R_LINES, "each write's fragments name the write after it (graded by the desktop's)"),
    # --- the scrollbar scrubber model -----------------------------------------
    Arm("S1", SCRUB,
        "  m.firstVisibleFor(m.rowAtFraction(fraction))\n",
        "  min(m.maxFirstVisible, m.firstVisible + m.visible)\n",
        U_SWEEP, "a track click pages by one view instead of jumping"),
    Arm("S2", SCRUB,
        "  start = max(0, min(trackUnits - length, start))\n",
        "  start = max(0, start)\n",
        U_SWEEP, "the thumb may run off the track's end"),
    # --- the desktop view (the shared VM's actions) ---------------------------
    Arm("V1", DVIEW,
        "  if css.len > 0:\n    r.setAttribute(result, \"style\", css)\n",
        "  if false:\n    r.setAttribute(result, \"style\", css)\n",
        N_SPAN, "the desktop's span carries no style"),
    Arm("V2", TVM,
        "  elif vm.scrubInFlight:\n    vm.scrubPending = w\n  else:\n    vm.sendScrub(w)\n",
        "  elif vm.scrubInFlight:\n    vm.scrubPending = w\n  else:\n    discard\n",
        N_REALTIME, "the desktop's drag moves no debugger until the release"),
    Arm("V6", TVM,
        "  elif vm.scrubInFlight:\n    vm.scrubPending = w\n",
        "  elif false:\n    vm.scrubPending = w\n",
        N_REALTIME, "the desktop's drag sends a move per write while one is in flight"),
    Arm("V7", TVM,
        "  if pending >= 0 and pending != vm.scrubSent:\n    vm.sendScrub(pending)\n",
        "  if false:\n    vm.sendScrub(pending)\n",
        N_REALTIME, "the write reached during a move is never sent when it lands"),
    Arm("V3", MODEL,
        "  if offered: tvScreen else: tvLines\n",
        "  tvLines\n",
        N_OPENS, "a full-screen program opens on its lines"),
    Arm("V4", DVIEW,
        "  of \"ArrowRight\":\n    discard vm.stepWrite(1)\n",
        "  of \"ArrowRight\":\n    discard vm.stepWrite(0)\n",
        N_ARROW, "ArrowRight steps nowhere"),
    Arm("V5", TVM,
        "  var ev = vm.eventOf(eventIndex)\n",
        "  var ev = vm.eventOf(vm.events.val.len - 1)\n",
        N_EACH, "every fragment goes to the last write"),
    # --- the terminal ---------------------------------------------------------
    Arm("T1", TPANE,
        "  scrubberModel(m.lines.len, m.visibleTop(rows), rows, m.currentLine)\n",
        "  scrubberModel(min(m.lines.len, rows), m.visibleTop(rows), rows,\n                m.currentLine)\n",
        T_SCRUB, "the terminal's scrubber spans the rows on screen"),
    Arm("T2", RUNTIME,
        "  if w != m.scrubSent:\n",
        "  if false:\n",
        T_REALTIME, "the terminal's screen drag moves no debugger while held"),
    Arm("T3", RUNTIME,
        "  of thLineTrack:\n    rt.scrubTerminalLines(area, event.row, click = true)\n",
        "  of thLineTrack:\n    discard rt.terminalWriteJump(0, outcome)\n    rt.scrubTerminalLines(area, event.row, click = true)\n",
        T_SCRUB, "a track click moves the debugger"),
    Arm("T4", TPANE,
        "  case fragmentTense(currentTicks, f.rrTicks)\n",
        "  case min(ttActive, fragmentTense(currentTicks, f.rrTicks))\n",
        T_PAINT, "the terminal draws the future as written"),
    Arm("T5", TVM,
        "    if not vm.onViewChosen.isNil:\n      vm.onViewChosen(vm.viewMemory)\n",
        "    if false:\n      vm.onViewChosen(vm.viewMemory)\n",
        T_REMEMBER, "the view chosen is not remembered"),
    Arm("T6", TPANE,
        "  result = CellStyle(fg: termHex(fg), bg: termHex(bg), bold: a.bold,\n",
        "  result = CellStyle(fg: \"\", bg: termHex(bg), bold: a.bold,\n",
        T_PAINT, "the terminal paints no program colour"),
    Arm("T7", PROFILE,
        "     paneTerminalOutput},\n",
        "     paneEditor},\n",
        T_LEAF, "the terminal reports the pane instead of drawing it"),
    Arm("T8", TPANE,
        "  if f >= 0.0:\n    let r = min(geo.contentRows - 1, int(floor(f * float(geo.contentRows))))\n",
        "  if false:\n    let r = min(geo.contentRows - 1, int(floor(f * float(geo.contentRows))))\n",
        T_MARK, "the current position is not marked on the track"),
    Arm("T9", RUNTIME,
        "  let ev = m.screen.writes[write]\n  outcome.requestClick(PaneClickRequest(\n",
        "  let ev = m.screen.writes[min(write + 1, m.screen.writes.high)]\n  outcome.requestClick(PaneClickRequest(\n",
        T_CLICK, "a click lands on the write after the clicked one"),
    Arm("P1", MODEL,
        "  (0, 0, 0), (187, 0, 0), (0, 187, 0), (187, 187, 0),\n",
        "  (0, 0, 0), (170, 0, 0), (0, 187, 0), (187, 187, 0),\n",
        P_COLOURS, "the palette's red is not the desktop's"),
    Arm("P2", RUNTIME,
        "    of tdScreen: rt.scrubTerminalScreen(area, event.col, outcome)\n",
        "    of tdScreen: outcome.repaint = true\n",
        P_REALTIME, "the terminal's screen drag ignores the pointer's motion"),
    Arm("TS1", TSESSION,
        "  s.refreshTerminalOutput(rt)\n  rt.app.location = ",
        "  rt.app.location = ",
        T_PAINT, "the host never hands the pane its model at a stop"),
    # --- the vocabulary and the producer --------------------------------------
    Arm("PV1", PVIEWS,
        "  let lines = vm.lines.val\n  if lines.len == 0:\n    result.report =\n",
        "  let lines = newSeq[TerminalLine]()\n  if lines.len == 0:\n    result.report =\n",
        T_VOCAB, "the vocabulary view reports instead of listing the lines"),
    Arm("SO1", SOURCE,
        "  if not vm.isNil:\n    vm.setEvents(events)\n",
        "  if not vm.isNil:\n    vm.setEvents(@[])\n",
        T_DATA, "the native producer hands the ViewModel no writes"),
    # --- the desktop's real app ----------------------------------------------
    Arm("DE1", DESK,
        "  terminalOutputVMInstance.setEvents(terminalOutputEventsOf(self.cachedEvents))\n",
        "  terminalOutputVMInstance.setEvents(@[])\n",
        D_DESKTOP, "the desktop's pane loads no output"),
    Arm("R1", MODEL,
        "  if a.bold: parts.add \"font-weight:bold\"\n",
        "  if a.bold: parts.add \"font-weight:normal\"\n",
        U_CSS, "the model's CSS draws bold runs at normal weight"),
    # --- GPUI ---------------------------------------------------------------
    Arm("G1", GLEAF,
        "  r.setStyle(el, \"color\", if fg.len > 0: fg else: TerminalTextColour)\n",
        "  r.setStyle(el, \"color\", TerminalTextColour)\n",
        G_RUNS, "GPUI draws every run in the text colour"),
    Arm("G2", GMAIN,
        "  if w != gTerminal.scrubSent:\n",
        "  if false:\n",
        G_REALTIME, "GPUI's screen drag moves no debugger while held"),
    Arm("G3", GLEAF,
        "  scrubberModel(vm.lines.val.len, vm.visibleTop(st, rows), rows,\n",
        "  scrubberModel(min(rows, vm.lines.val.len), vm.visibleTop(st, rows), rows,\n",
        G_SCRUB, "GPUI's scrubber spans the rows drawn"),
    Arm("G4", GMAIN,
        "  of ghWrite:\n    return terminalJump(r, hit.write)\n",
        "  of ghWrite:\n    return terminalJump(r, hit.write + 1)\n",
        G_CLICK, "a GPUI press lands on the next write"),
    Arm("G5", GMAIN,
        "  of ghViewLines, ghViewScreen:\n    vm.setView(if hit.kind == ghViewLines: tvLines else: tvScreen)\n",
        "  of ghViewLines, ghViewScreen:\n    discard\n",
        G_TOGGLE, "GPUI's toggle does nothing"),
    Arm("G6", GLEAF,
        "  for m in vm.screen.marks:\n    let x = lay.marks.x",
        "  for m in newSeq[ScreenMark]():\n    let x = lay.marks.x",
        G_SCREEN, "GPUI draws no marks under the screen's scrubber"),
]

DECLARED_SURVIVORS: list = []


@dataclass
class RunResult:
    rc: int
    passed: list = None
    failed: list = None
    ran: bool = True
    hung: bool = False
    output: str = ""

    def __post_init__(self):
        if self.passed is None:
            self.passed = []
        if self.failed is None:
            self.failed = []

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def read_source(path: str) -> str:
    return (ROOT / path).read_bytes().decode("utf-8", errors="surrogateescape")


def write_source(path: str, text: str) -> None:
    (ROOT / path).write_bytes(text.encode("utf-8", errors="surrogateescape"))


def lane_flags(lane: str) -> list:
    """The lane's extra flags, read from `ci/lib/test-lane-files.sh` rather
    than spelled here (Verification-Harness-Traps §14)."""
    return subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
         f"test_lane_extra_flags {lane}"],
        cwd=ROOT, capture_output=True, text=True).stdout.split()


def suite_env() -> dict:
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = str(SHIM) + ":" + env.get("LD_LIBRARY_PATH", "")
    env["CODETRACER_REPO_ROOT"] = str(ROOT)
    # Never the user's own remembered layout (a remembered arrangement from
    # would be read by every suite that spawns the product).
    state = Path(tempfile.gettempdir()) / f"plat52-mutation-state-{os.getuid()}"
    state.mkdir(parents=True, exist_ok=True)
    env["CODETRACER_TUI_LAYOUT_DIR"] = str(state)
    env["XDG_STATE_HOME"] = str(state)
    return env


def artefacts_for(path: str) -> tuple:
    stem = Path(path).stem
    base = Path(tempfile.gettempdir()) / f"plat52-mutation-{os.getuid()}"
    base.mkdir(parents=True, exist_ok=True)
    return str(base / stem), str(base / f"nc-{stem}")


def run_gate(path: str, marker: str) -> RunResult:
    try:
        proc = subprocess.run(["bash", path], cwd=ROOT, capture_output=True,
                              text=True, timeout=SUITE_TIMEOUT,
                              encoding="utf-8", errors="replace",
                              env=suite_env())
    except subprocess.TimeoutExpired:
        return RunResult(rc=1, ran=False, hung=True)
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode, output=out)
    name = "gate:" + path
    if proc.returncode == 0:
        res.passed.append(name)
    elif marker in out:
        res.failed.append(name)
    else:
        # Red for another reason (it did not build, a download failed): not
        # the gate's verdict on the subject, so not a kill.
        res.ran = False
        print(f"      ---- {path}: red without its marker {marker!r} ----")
        for line in out.splitlines()[-15:]:
            print("      " + line)
    return res


def run_electron(path: str, grep: str) -> RunResult:
    """The real desktop: the capture script builds this checkout's desktop
    JavaScript into a prefix and runs the Playwright spec filtered to `grep`.
    Playwright's own summary decides: `1 passed` is green, `1 failed` a kill,
    anything else (no test ran, the prefix did not build) is not a verdict."""
    env = suite_env()
    # `just test-e2e` runs Playwright from `$CODETRACER_REPO_ROOT_PATH`, which
    # the dev shell points at the MAIN checkout: pin it to this one.
    env["CODETRACER_REPO_ROOT_PATH"] = str(ROOT)
    # THE CAPTURE WRITES ITS ANSWERS FILES, and a run of a MUTATED desktop
    # writes the mutant's answers: put every one back as it was, so a graded
    # arm can never leave the committed reference describing the mutant (a
    # whole grade once left the event log's location column visible in
    # a PLAT-49 answers file, and the reference suite read it).
    saved = {a: a.read_bytes() for a in ANSWER_FILES if a.exists()}
    try:
        proc = subprocess.run(["bash", suite_file(path),
                               *(["-g", grep] if grep else [])], cwd=ROOT,
                              capture_output=True, text=True,
                              timeout=SUITE_TIMEOUT, encoding="utf-8",
                              errors="replace", env=env)
    except subprocess.TimeoutExpired:
        return RunResult(rc=1, ran=False, hung=True)
    finally:
        for a in ANSWER_FILES:
            if a in saved:
                a.write_bytes(saved[a])
            elif a.exists():
                a.unlink()
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode, output=out)
    name = "gate:" + path
    if re.search(r"^\s*\d+ passed", out, re.M) and proc.returncode == 0:
        res.passed.append(name)
    elif re.search(r"^\s*\d+ failed", out, re.M):
        res.failed.append(name)
    else:
        res.ran = False
        print(f"      ---- {path}: no Playwright verdict; last 15 lines ----")
        for line in [l for l in out.splitlines()
                     if "keysym" not in l and "xkbcomp" not in l][-15:]:
            print("      " + line)
    return res


def parse_results(proc_out: str, rc: int, path: str) -> RunResult:
    res = RunResult(rc=rc, output=proc_out)
    for line in proc_out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        res.ran = False
        print(f"      ---- {path}: no result lines; last 20 lines ----")
        for line in proc_out.splitlines()[-20:]:
            print("      " + line)
    return res


def run_isonim_gpui(path: str, case: str | None) -> RunResult:
    """isonim-gpui's own suite, compiled in its checkout (its `nim.cfg`
    carries the paths) against the shim the harness puts on the library
    path."""
    binary, nimcache = artefacts_for(path)
    try:
        proc = subprocess.run(
            ["nim", "c", "-r", "--hints:off", "--warnings:off",
             "--nimcache:" + nimcache, "-o:" + binary, path,
             *([case] if case else [])],
            cwd=ISONIM_GPUI_DIR, capture_output=True, text=True,
            timeout=SUITE_TIMEOUT, encoding="utf-8", errors="replace",
            env=suite_env())
    except subprocess.TimeoutExpired:
        return RunResult(rc=1, ran=False, hung=True)
    return parse_results(proc.stdout + proc.stderr, proc.returncode, path)


CARGO_LINE = re.compile(r"^test (\S+) \.\.\. (ok|FAILED)\s*$")


def parse_cargo(out: str, rc: int, path: str) -> RunResult:
    """`cargo test`'s per-test lines: `test <path>::<name> ... ok|FAILED`,
    named by the function (the last path segment)."""
    res = RunResult(rc=rc, output=out)
    for line in out.splitlines():
        m = CARGO_LINE.match(line.strip())
        if m:
            name = m.group(1).rsplit("::", 1)[-1]
            (res.passed if m.group(2) == "ok" else res.failed).append(name)
    if res.total == 0:
        res.ran = False
        print(f"      ---- {path}: no cargo test lines; last 20 lines ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)
    return res


def engine_target_dir() -> Path:
    """The cargo target directory `REPLAY_SERVER_BIN` was built into
    (`<target>/<profile>/replay-server`)."""
    return Path(os.environ["REPLAY_SERVER_BIN"]).resolve().parents[1]


def run_cargo_engine(path: str, filt: str, case: str | None) -> RunResult:
    """The engine's own unit tests (`cargo test --lib <module>`), in
    `ENGINE_DIR`, into the replay-server's target directory."""
    env = suite_env()
    env["CARGO_TARGET_DIR"] = str(engine_target_dir())
    try:
        proc = subprocess.run(
            ["cargo", "test", "--lib", case or filt],
            cwd=ENGINE_DIR, capture_output=True, text=True,
            timeout=SUITE_TIMEOUT, encoding="utf-8", errors="replace", env=env)
    except subprocess.TimeoutExpired:
        return RunResult(rc=1, ran=False, hung=True)
    return parse_cargo(proc.stdout + proc.stderr, proc.returncode, path)


def run_cargo_shim(path: str, which: str, case: str | None) -> RunResult:
    """isonim-gpui's shim tests, in ITS dev shell (the windowed suite needs
    the X11 / Wayland libraries the codetracer shell does not carry), into a
    target directory of their own (`CT_P50_SHIM_TARGET`) so the windowed build
    never replaces the shim the Nim suites load."""
    target = os.environ.get(
        "CT_P50_SHIM_TARGET",
        str(ISONIM_GPUI_DIR / "rust" / "target" / "plat50-windowed"))
    cmd = (f"cd rust && CARGO_TARGET_DIR={target} cargo test -p gpui-nim-shim "
           f"--features gpui-backend {which} {case or ''}")
    try:
        proc = subprocess.run(
            ["nix", "develop", str(ISONIM_GPUI_DIR), "-c", "bash", "-c", cmd],
            cwd=ISONIM_GPUI_DIR, capture_output=True, text=True,
            timeout=SUITE_TIMEOUT, encoding="utf-8", errors="replace",
            env=suite_env())
    except subprocess.TimeoutExpired:
        return RunResult(rc=1, ran=False, hung=True)
    return parse_cargo(proc.stdout + proc.stderr, proc.returncode, path)


def run_one(path: str, case=None) -> RunResult:
    backend, lane = SUITE_KIND[path]
    if backend == "cargo-engine":
        return run_cargo_engine(path, lane, case)
    if backend == "cargo-shim":
        return run_cargo_shim(path, lane, case)
    if backend == "gate":
        return run_gate(path, lane)
    if backend == "electron":
        return run_electron(path, lane)
    if backend == "isonim-gpui":
        return run_isonim_gpui(path, case)
    binary, nimcache = artefacts_for(path)
    flags = ["--hints:off", "--warnings:off", *lane_flags(lane),
             "--nimcache:" + nimcache]
    filt = (case if isinstance(case, list) else [case]) if case else []
    try:
        if backend == "js":
            out_js = binary + ".js"
            comp = subprocess.run(
                ["nim", "js", "-d:nodejs", *flags, "-o:" + out_js, path],
                cwd=ROOT, capture_output=True, text=True,
                timeout=SUITE_TIMEOUT, encoding="utf-8", errors="replace",
                env=suite_env())
            if comp.returncode != 0:
                proc = comp
            else:
                proc = subprocess.run(
                    ["node", out_js, *filt], cwd=ROOT, capture_output=True,
                    text=True, timeout=SUITE_TIMEOUT, encoding="utf-8",
                    errors="replace", env=suite_env())
        elif path in UNISOLATED_SUITES:
            # Compiled in the ordinary environment, RUN with the harness's own
            # isolation removed and HOME a throwaway: the forced import is then
            # the only thing isolating the suite (S1), and a regression writes
            # into the throwaway home, never the developer's.
            comp = subprocess.run(
                ["nim", "c", *flags, "-o:" + binary, path],
                cwd=ROOT, capture_output=True, text=True,
                timeout=SUITE_TIMEOUT, encoding="utf-8", errors="replace",
                env=suite_env())
            if comp.returncode != 0:
                proc = comp
            else:
                env = suite_env()
                env.pop("XDG_STATE_HOME", None)
                env.pop("CODETRACER_TUI_LAYOUT_DIR", None)
                env["HOME"] = tempfile.mkdtemp(prefix="plat52-s1-home-")
                proc = subprocess.run(
                    [binary, *filt], cwd=ROOT, capture_output=True, text=True,
                    timeout=SUITE_TIMEOUT, encoding="utf-8", errors="replace",
                    env=env)
        else:
            proc = subprocess.run(
                ["nim", "c", "-r", *flags, "-o:" + binary, path, *filt],
                cwd=ROOT, capture_output=True, text=True,
                timeout=SUITE_TIMEOUT, encoding="utf-8", errors="replace",
                env=suite_env())
    except subprocess.TimeoutExpired:
        print(f"      ---- {path}: NO RESULT AFTER {SUITE_TIMEOUT}s ----")
        return RunResult(rc=1, ran=False, hung=True)
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode, output=out)
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        res.ran = False
        print(f"      ---- {path}: no result lines; last 20 lines ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)
    return res


def build_tui() -> bool:
    p = subprocess.run(["just", "build-tui"], cwd=ROOT, capture_output=True,
                       text=True, timeout=SUITE_TIMEOUT)
    if p.returncode != 0:
        print("      ---- just build-tui failed; last 15 lines ----")
        for line in (p.stdout + p.stderr).splitlines()[-15:]:
            print("      " + line)
    return p.returncode == 0


def build_gpui() -> bool:
    p = subprocess.run(["just", "build-gpui"], cwd=ROOT, capture_output=True,
                       text=True, timeout=SUITE_TIMEOUT)
    if p.returncode != 0:
        print("      ---- just build-gpui failed; last 15 lines ----")
        for line in (p.stdout + p.stderr).splitlines()[-15:]:
            print("      " + line)
    return p.returncode == 0


def build_engine() -> bool:
    """The replay-server `REPLAY_SERVER_BIN` names, rebuilt from
    `ENGINE_DIR` (an arm on the engine graded by a suite that runs it)."""
    env = dict(os.environ)
    env["CARGO_TARGET_DIR"] = str(engine_target_dir())
    p = subprocess.run(["cargo", "build", "--bin", "replay-server"],
                       cwd=ENGINE_DIR, capture_output=True, text=True,
                       timeout=SUITE_TIMEOUT, env=env)
    if p.returncode != 0:
        print("      ---- cargo build --bin replay-server failed; last 15 lines ----")
        for line in (p.stdout + p.stderr).splitlines()[-15:]:
            print("      " + line)
    return p.returncode == 0


def build_for(suite: str, arm=None) -> bool:
    """Rebuild the binary a suite grades, if it grades one — and the engine,
    when the arm is on it and the suite runs it."""
    if arm is not None and suite in BINARY_SUITES | GPUI_BINARY_SUITES and \
       any(path in ENGINE_SUBJECTS for path, _f, _r in arm.edits()):
        _DIRTY.add("engine")
        if not build_engine():
            return False
    if suite in BINARY_SUITES:
        return build_tui()
    if suite in GPUI_BINARY_SUITES:
        return build_gpui()
    return True


_ACTIVE: list | None = None
_DIRTY: set = set()
  # binaries last built from a MUTATED tree ("tui", "gpui")


def rebuild_restored() -> bool:
    """Rebuild every binary a mutant left behind, from the restored tree."""
    ok = True
    if "tui" in _DIRTY:
        ok = build_tui() and ok
    if "gpui" in _DIRTY:
        ok = build_gpui() and ok
    if "engine" in _DIRTY:
        ok = build_engine() and ok
    _DIRTY.clear()
    if not ok:
        print("the restored tree's binary does not build")
    return ok


def install_restore_on_signal() -> None:
    def handler(signum, _frame):
        if _ACTIVE is not None:
            for path, original in _ACTIVE:
                write_source(path, original)
                print(f"\nsignal {signum}: restored {path} before exiting")
        sys.exit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, handler)


COUNT_CONSTANT = re.compile(
    r"^[ \t]*(?:const[ \t]+)?(ExpectedAssertions|ExpectedRoleCount)\*?[ \t]*="
    r"[ \t]*(\d+)", re.M)


def declared_counts() -> dict:
    found = {}
    for path in TOUCHED:
        for m in COUNT_CONSTANT.finditer(read_source(path)):
            found[m.group(2)] = f"{path}:{m.group(1)}"
    return found


def check_killer_names(problems: int) -> int:
    for name in NAMED_CASES:
        where = CASE_SUITE[name]
        if name.startswith("gate:"):
            if not (ROOT / suite_file(where)).is_file():
                print(f"GATE ABSENT: {where}")
                problems += 1
            continue
        if SUITE_KIND[where][0].startswith("cargo"):
            if f"fn {name}(" not in read_source(suite_file(where)):
                print(f"KILLER NAME NOT IN {where}: {name!r}")
                problems += 1
            continue
        if f'test "{name}"' not in read_source(where):
            print(f"KILLER NAME NOT IN {where}: {name!r}")
            problems += 1
    for arm in ARMS:
        if arm.killer not in NAMED_CASES:
            print(f"{arm.id}: killer {arm.killer!r} is not a declared case name")
            problems += 1
    unused = [c for c in NAMED_CASES if c not in {a.killer for a in ARMS}]
    if unused:
        print(f"NAMED CASES NO ARM KILLS: {unused}")
        problems += 1
    return problems


def needle_scan() -> int:
    problems = 0
    counts = declared_counts()
    print("declared count constants in the touched files: "
          f"{', '.join(f'{v}={k}' for k, v in sorted(counts.items())) or 'none'}")
    for arm in ARMS + DECLARED_SURVIVORS:
        text = arm.find + arm.replace
        if "ExpectedAssertions" in text or "CHECKS:" in text:
            print(f"{arm.id}: NEEDLE QUOTES A COUNT NAME — §10.3")
            problems += 1
        for digits in re.findall(r"\d\d+", text):
            if digits in counts:
                print(f"{arm.id}: NEEDLE QUOTES THE VALUE OF "
                      f"{counts[digits]} ({digits}) — §10.3")
                problems += 1
    armed = {path for arm in ARMS for path, _f, _r in arm.edits()}
    unarmed = [p for p in SUBJECTS if p not in armed]
    if unarmed:
        print(f"SUBJECTS WITH NO ARM: {unarmed}")
        problems += 1
    whys = {}
    for arm in ARMS + DECLARED_SURVIVORS:
        key = arm.why[:60]
        if key in whys:
            print(f"{arm.id}: DUPLICATE justification, shared with {whys[key]}")
            problems += 1
        whys[key] = arm.id
    ids = [a.id for a in ARMS]
    if len(set(ids)) != len(ids):
        print("DUPLICATE ARM ID")
        problems += 1
    for arm in ARMS + DECLARED_SURVIVORS:
        for path, find, _replace in arm.edits():
            n = read_source(path).count(find)
            status = "ok" if n == 1 else "LOST" if n == 0 else "AMBIGUOUS"
            if n != 1:
                problems += 1
            print(f"{arm.id:<4} {status:<10} {n} occurrence(s) in {path}")
    problems = check_killer_names(problems)
    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


def control_key(path: str) -> str:
    """The name a touched file is recorded under in the control file.

    In-tree subjects are named by their repository-relative path. The sibling
    `isonim-gpui` subject and suite live wherever `$ISONIM_GPUI_SRC` /
    `$ISONIM_GPUI_DIR` point (a worktree, a plain `../isonim-gpui` checkout,
    CI's clone), so they are named relative to that checkout,
    `isonim-gpui/...`: an absolute path would make the
    committed control unreadable on every other checkout, while the digest
    still pins the exact bytes graded."""
    p = Path(path)
    if p.is_absolute():
        try:
            return "isonim-gpui/" + p.relative_to(ISONIM_GPUI_DIR).as_posix()
        except ValueError:
            return path
    return path


def record_control_hashes() -> int:
    lines = [f"{digest(p)}  {control_key(p)}" for p in TOUCHED]
    CONTROL_HASHES.write_text("\n".join(lines) + "\n")
    print(f"recorded {len(lines)} digests in {CONTROL_HASHES}")
    return 0


def check_control_hashes() -> bool:
    if not CONTROL_HASHES.exists():
        print(f"CONTROL DIGESTS ABSENT: {CONTROL_HASHES.name} — run "
              "--needle-scan, review the tree, then --record-control-hashes")
        return False
    recorded = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        if line.strip():
            h, p = line.split(None, 1)
            recorded[p.strip()] = h
    ok = True
    for p in TOUCHED:
        key = control_key(p)
        if key not in recorded:
            print(f"CONTROL DIGEST ABSENT: {key} ({p})")
            ok = False
        elif recorded[key] != digest(p):
            print(f"CONTROL DIGEST MOVED: {key} — re-run --needle-scan BEFORE "
                  "--record-control-hashes (§32)")
            ok = False
    return ok


sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def main() -> int:
    # AN UNDECLARED ARM ID, OR AN EMPTY `--only=`, IS REFUSED before anything
    # is touched (`ci/lib/harness_guard.py`).
    refused = refuse_undeclared_arms(sys.argv[1:], globals())
    if refused:
        return refused
    only = None
    for arg in sys.argv[1:]:
        if arg == "--needle-scan":
            return needle_scan()
        if arg == "--enumerate-touched":
            for p in TOUCHED:
                print(p)
            return 0
        if arg == "--record-control-hashes":
            return record_control_hashes()
        if arg.startswith("--only="):
            only = set(arg[len("--only="):].split(","))
        else:
            print(f"unknown argument: {arg}")
            return 2

    if needle_scan() != 0:
        print("REFUSING TO RUN: a needle is lost or ambiguous (§32)")
        return 1
    if not check_control_hashes():
        print("REFUSING TO RUN: a control digest moved or is absent (§32)")
        return 1
    if not os.environ.get("REPLAY_SERVER_BIN"):
        print("REFUSING TO RUN: REPLAY_SERVER_BIN is not exported")
        return 1

    baseline = {p: digest(p) for p in TOUCHED}
    install_restore_on_signal()

    wanted = [a for a in ARMS if not only or a.id in only]
    print("\n== control ==")
    if any(CASE_SUITE[a.killer] in BINARY_SUITES for a in wanted) and \
       not build_tui():
        print("CONTROL: the unmutated terminal binary does not build")
        return 1
    if any(CASE_SUITE[a.killer] in GPUI_BINARY_SUITES for a in wanted) and \
       not build_gpui():
        print("CONTROL: the unmutated GPUI binary does not build")
        return 1
    for path in SUITES:
        if not any(CASE_SUITE[a.killer] == path for a in wanted):
            continue
        named = [c for c in NAMED_CASES if CASE_SUITE[c] == path]
        control = run_one(path, None if path in UNFILTERED_CONTROL else
                          named)
        if control.failed or not control.ran or control.rc != 0:
            print(f"CONTROL IS NOT GREEN: {path} rc={control.rc} "
                  f"failed={control.failed}")
            return 1
        missing = [c for c in NAMED_CASES
                   if CASE_SUITE[c] == path and c not in control.passed]
        if missing:
            print(f"CONTROL DID NOT RUN {len(missing)} NAMED CASES in {path}: "
                  f"{missing}")
            return 1
        print(f"control {path}: {control.total} cases, 0 failures")

    problems = 0
    killed = 0
    global _ACTIVE
    for arm in wanted:
        originals = {path: read_source(path) for path, _f, _r in arm.edits()}
        if any(originals[path].count(find) != 1
               for path, find, _r in arm.edits()):
            print(f"{arm.id:<4} HARNESS-FAILURE      needle is not unique")
            problems += 1
            continue
        suite = CASE_SUITE[arm.killer]
        _ACTIVE = list(originals.items())
        for path, find, replace in arm.edits():
            write_source(path, read_source(path).replace(find, replace))
        try:
            if not build_for(suite, arm):
                res = RunResult(rc=1, ran=False)
                print("      the mutated binary did not build")
            else:
                case = None if arm.killer.startswith("gate:") else arm.killer
                res = run_one(suite, case)
        finally:
            for path, original in originals.items():
                write_source(path, original)
            _ACTIVE = None
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{arm.id:<4} HARNESS-FAILURE      {p} did not "
                          "restore to its control bytes")
                    rebuild_restored()
                    return 2
            # The restored tree's binary is rebuilt before the harness exits
            # (`rebuild_restored`), not after every arm: the next binary arm
            # rebuilds it with its own defect anyway.
            if suite in BINARY_SUITES or suite in GPUI_BINARY_SUITES:
                _DIRTY.add(suite in BINARY_SUITES and "tui" or "gpui")
        if res.hung:
            verdict, note = "HUNG", f"no result in {SUITE_TIMEOUT}s"
            problems += 1
        elif not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif arm.killer in res.failed:
            verdict, note = "killed", arm.killer
            killed += 1
        elif res.failed:
            verdict, note = "MISDIRECTED", f"died in {res.failed[0]!r}"
            problems += 1
        else:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        print(f"{arm.id:<4} {verdict:<16} {note}")
        sys.stdout.flush()

    if not rebuild_restored():
        problems += 1
    print(f"\n{killed}/{len(wanted)} killed, {problems} problem(s)")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
