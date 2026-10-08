#!/usr/bin/env python3
"""PLAT-51 Part A — the mutation harness for the user's 2026-10-04/05
decisions on the desktop, the terminal and GPUI: the Timeline panel removed
(and a saved layout that held it migrated), list-pane scrollbars as
scrubbers over the whole population, the `[MOD]` badge replaced by the
desktop's changed-value accent, every value feature in the native front-ends,
the read-only editor's caret, the context menus' escape hatch, the omnibox on
the editor's colours, the `▸` current-line mark, and the frame viewer's own
scrubber.

    python3 src/frontend/tui/tests/run-plat51-parity-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=L1,T2

Run from the repository root, inside the dev shell, with `REPLAY_SERVER_BIN`
exported: it must be the replay-server in the cargo target the harness
rebuilds into (`<target>/debug/replay-server`), built from `ENGINE_DIR` —
`$CT_P50_ENGINE_DIR` when set (a sandbox whose `src` points at THIS tree),
else this checkout's `src/db-backend`. The ONE engine arm (E1) edits this
tree's `dap_handler.rs` and rebuilds that replay-server; the restored tree's
is rebuilt before the harness exits. GPUI suites load `libgpui_nim_shim` from
`$ISONIM_GPUI_SHIM_DIR`. The desktop gates run the REAL Electron app
(`scripts/plat51-capture-electron.sh`, which compiles this checkout's
desktop JavaScript and stylesheets into a prefix), filtered to one case; the
answers file the capture writes is restored after every run.

ONE ARM PER CLAIM, each naming the case that must die:

  | claim | arms |
  |---|---|
  | the Timeline removed; a saved layout migrates | L1 (v5 leaf not dropped), L2 (the active tab not remapped), L3 (a one-child row left), L4 (a docked pane keeps `beside: timeline`), PM1 (View > Timeline back), D2 (the desktop keeps a saved Timeline tab), K1 (`4` selects the call stack) |
  | list scrollbars scrub the WHOLE population | S1 (a track's end short of the last row), T1 (the event log's track over the held rows), T2 (a track press pages a screen), T3 (the call trace's track over the loaded section), T4 (no current-position mark), P1 (a real-PTY press on the track routed nowhere), G1 (GPUI's call row takes the track press), G2 (GPUI's track reads a press at half its place), D1 (the desktop's event-log track press moves nothing), E1 (the engine reports the page as the total), R1 (the terminal reader keeps the scrubber in the text) |
  | no `[MOD]`; the desktop's accent | V1 (the anchor is the current stop), V2 (an added binding unmarked), T5 (the terminal paints no accent), G4 (GPUI paints no accent), D3 (the desktop's `.value-changed` gone) |
  | every value feature | T6 (a history entry's click does not seek), TS1 (the host seeks it to half its tick), T7 (a watch edit reaches one StateVM), G5 (GPUI's history never opens) |
  | the caret | T8 (Alt+t / Ctrl+Enter open nothing), T14 (a real terminal's Alt+T framed as a bare `t`), T15 (an unbound Alt+<char> swallowed), G6 (GPUI's click places no caret) |
  | menus and the escape hatch | T9 (Shift reports routed), T10 (no hint row), G7 (GPUI's menu gains a hint row) |
  | the omnibox on the editor's colours | T11 (the field on the input surface), G8 (GPUI's field on the input surface) |
  | the current-line mark | T12 (`▶` is the mark), T13 (no ASCII `>` for it), G3 (GPUI draws a glyph, not the desktop's mark) |
  | the frame viewer's own scrubber | F1 (the pane has no scrubber row), F2 (the release is not sent) |

THREE VERDICTS (Verification-Harness-Traps §1): `killed` (the named case
reported [FAILED], or the named gate failed), `SURVIVED`, `HARNESS-FAILURE`
(the needle not unique, the suite did not compile, the mutated binary did not
build, or no result lines). A run that prints nothing is never a kill.

Every Nim suite is run FILTERED to its killer case; the control runs each
suite filtered to its NAMED cases and must see every killer [OK].

THE BINARY IS PART OF THE SUBJECT: an arm graded by a real-PTY suite rebuilds
`build/bin/codetracer-tui` (`just build-tui`), one graded by the GPUI plan
suite `build/bin/codetracer-gpui` (`just build-gpui`), one on the engine the
replay-server; the restored tree's binaries are rebuilt before exiting.

RESTORATION is from an in-memory snapshot, and every touched file's SHA-256 is
compared with the pre-run baseline after each arm (§32). The full run refuses
unless the needle scan is clean AND every touched file matches
`plat51-parity-mutation-control.sha256`.

NO DECLARED SURVIVORS.

No mocks: the shared models, the product's runtime and shell over a real
session, a real PTY, the shipped GPUI binary's window plan, the real Electron
app.
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
LAYOUT = "src/frontend/headless_app/layout_model.nim"
PMENU = "src/frontend/viewmodel/viewmodels/product_menu.nim"
SCRUB = "src/frontend/viewmodel/viewmodels/scrollbar_scrubber.nim"
VCH = "src/frontend/viewmodel/viewmodels/value_changes.nim"
KEYMAP = "src/frontend/tui/app/input/keymap.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
TSESSION = "src/frontend/tui/host/tui_session.nim"
TEVENT = "src/frontend/tui/app/views/event_log.nim"
TCALL = "src/frontend/tui/app/views/call_trace.nim"
TTRACK = "src/frontend/tui/app/views/scrubber_track.nim"
TTREE = "src/frontend/tui/app/views/tree_node.nim"
TGUTTER = "src/frontend/tui/app/views/gutter.nim"
TBORDERS = "src/frontend/tui/app/views/borders.nim"
TTOPBAR = "src/frontend/tui/app/views/top_bar.nim"
TCTX = "src/frontend/tui/app/views/context_menu.nim"
TFRAME = "src/frontend/tui/app/views/frame_viewer.nim"
TDRIVER = "src/frontend/tui/host/terminal_driver.nim"
READER = "src/tests/visual/screen_oracle/terminal_reading.nim"
GMAIN = "src/frontend/gpui/main.nim"
GLEAVES = "src/frontend/gpui/app/leaves.nim"
GLIST = "src/frontend/gpui/list_scrubber.nim"
DEVLOG = "src/frontend/ui/event_log.nim"
DCONFIG = "src/frontend/index/config.nim"
DSTATE = "src/frontend/viewmodel/views/isonim_state_view.nim"
ENGINE = "src/db-backend/src/dap_handler.rs"
ISONIM_GPUI_DIR = Path(os.environ.get(
    "ISONIM_GPUI_DIR", str(ROOT.parent / "isonim-gpui")))
if os.environ.get("ISONIM_GPUI_SRC"):
    ISONIM_GPUI_DIR = Path(os.environ["ISONIM_GPUI_SRC"]).parent
ENGINE_DIR = Path(os.environ.get("CT_P50_ENGINE_DIR",
                                 str(ROOT / "src" / "db-backend")))

# --- suites and gates ---------------------------------------------------------
LAYU = "src/frontend/viewmodel/tests/unit/test_shared_default_layout.nim"
MODELU = "src/frontend/viewmodel/tests/unit/test_plat51_shared_models.nim"
SCRUBT = "src/frontend/tui/tests/test_plat51_scrubbers.nim"
PARITY = "src/frontend/tui/tests/test_plat51_parity.nim"
PRODUCERS = "src/frontend/tui/tests/test_plat40_producers.nim"
FRAMEV = "src/frontend/tui/app/tests/test_frame_viewer_pane.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat51_pty.nim"
GPLAN = "src/frontend/gpui/tests/test_plat51_gpui_plan.nim"
CAPTURE = "scripts/plat51-capture-electron.sh"
SPEC = "src/tests/gui/tests/visual/plat51-desktop-capture.spec.ts"
DE_EVENTLOG = CAPTURE + "#scrubber.spans.the.whole.log"
DE_SAVED = CAPTURE + "#Timeline.tab.is.dropped.on.load"
DE_CHANGED = CAPTURE + "#carries..value-changed.in.the.accent"

SUBJECTS = [LAYOUT, PMENU, SCRUB, VCH, KEYMAP, RUNTIME, TSESSION, TEVENT,
            TCALL, TTRACK, TTREE, TGUTTER, TBORDERS, TTOPBAR, TCTX, TFRAME,
            TDRIVER,
            READER, GMAIN, GLEAVES, GLIST, DEVLOG, DCONFIG, DSTATE, ENGINE]
SUITES = [LAYU, MODELU, SCRUBT, PARITY, PRODUCERS, FRAMEV, PTY, GPLAN,
          DE_EVENTLOG, DE_SAVED, DE_CHANGED]


def suite_file(path: str) -> str:
    """The file a suite key names (a gate's `#<grep>` suffix dropped)."""
    return path.split("#", 1)[0]


TOUCHED = list(dict.fromkeys(SUBJECTS + [suite_file(p) for p in SUITES] +
                             [SPEC]))

# How each suite is run: (backend, lane whose `--path`s it needs / the grep).
# A desktop gate's grep is a REGEX WITHOUT SPACES OR QUOTES: `just test-e2e`
# interpolates its arguments unquoted (`{{args}}`), so "Call Trace" would reach
# Playwright as two file filters and load every spec.
SUITE_KIND = {
    LAYU: ("c", "vm-unit"),
    MODELU: ("c", "vm-unit"),
    SCRUBT: ("c", "tui"),
    PARITY: ("c", "tui"),
    PRODUCERS: ("c", "tui"),
    FRAMEV: ("c", "tui"),
    PTY: ("c", "tui-real-terminal"),
    GPLAN: ("c", "gpui-shell"),
    DE_EVENTLOG: ("electron", "scrubber.spans.the.whole.log"),
    DE_SAVED: ("electron", "Timeline.tab.is.dropped.on.load"),
    DE_CHANGED: ("electron", "carries..value-changed.in.the.accent"),
}
BINARY_SUITES = {PTY}
GPUI_BINARY_SUITES = {GPLAN}
ENGINE_SUBJECTS = {ENGINE}
UNISOLATED_SUITES: set = set()
UNFILTERED_CONTROL: set = {DE_EVENTLOG, DE_SAVED, DE_CHANGED}

CONTROL_HASHES = HERE / "plat51-parity-mutation-control.sha256"
ANSWER_FILES = [ROOT / "src/tests/visual/answers" / "plat51-desktop.electron.json"]
SUITE_TIMEOUT = int(os.environ.get("CT_P51_SUITE_TIMEOUT", "3600"))
SHIM = Path(os.environ.get("ISONIM_GPUI_SHIM_DIR",
                           str(ISONIM_GPUI_DIR / "rust/target/debug")))
RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*\s*(.*?)\s*$")

# --- the killer cases, spelled once ------------------------------------------
U_V5 = "the v5 shared default (Event Log | Timeline | Terminal Output) opens without the tab"
U_ACTIVE = "the ACTIVE Timeline tab hands its place to the tab that slid into it"
U_ALONE = "a container the Timeline alone filled is removed, and its siblings keep the space"
U_DOCKED = "a docked Timeline is dropped; a pane docked beside it keeps its edge"
M_ENDS = "the track's ends are the population's ends, at every size"
M_ANCHOR = "the anchor is the recording's predecessor; the first stop marks nothing"
M_ADDED = "an added binding is marked; a removed one has no row to mark"
S_EVENTS = "the track spans every event; its end shows the LAST event, its start the first"
S_MARK = "the current-position mark is on the debugger's event; a row click moves the debugger"
S_CALLS = "its end shows the LAST call of the whole trace; the debugger does not move"
P_TIMELINE = "no Timeline on the screen or in the View menu; 4 focuses the Event Log"
P_POINTER = "the execution pointer is ▸ (ASCII >), never --> or ▶"
P_CARET = "a click on the text places the caret; keys move it; Alt+t opens the tracepoint editor there"
P_MOD = "no [MOD]: a changed value takes the accent on its value; nothing at the entry"
P_HISTORY = "value history opens under its row and its entry goes to its tick"
P_WATCH = "watches are added, edited and removed, in the Watches group"
P_MENU = "every menu ends in an inert Shift + right-click row; Shift reports are the terminal's"
P_OMNIBOX = "the omnibox: the editor's ground and foreground, idle, open, typed, results"
R_DIFF9 = "DIFF-9 — the event log, on the terminal"
F_ROW = "the bottom row is a slider over EVERY frame, marking scene boundaries"
F_DRAG = "a press jumps there, a drag follows, the release settles"
Y_TRACK = "no Timeline; a press at the track's end shows the last of 70 events"
Y_ASCII = "the pointer is ▸ (> under --ascii-borders), never -->"
Y_CARET = "a click places the caret; Alt+T, as a terminal sends it, opens the tracepoint editor there"
G_EVENTS = "the Event Log's track spans all 70 events; its end shows the last"
G_CALLS = "the Call Trace's track spans all 603 calls; the press is not a jump"
G_CHANGED = "a changed value takes the desktop's accent; nothing at the entry"
G_HISTORY = "the value history opens under its row; its entries are navigation rows"
G_CARET = "a click in the code places the caret, apart from the pointer"
G_MENU = "Shift + right-click opens the same menu, with no hint row"
G_OMNIBOX = "the omnibox is on the editor's ground and foreground in every state"
G_POINTER = "the execution pointer is the desktop's arrow, never ▶"
D_EVENTLOG = "gate:" + DE_EVENTLOG
D_SAVED = "gate:" + DE_SAVED
D_CHANGED = "gate:" + DE_CHANGED

CASE_SUITE = {
    U_V5: LAYU, U_ACTIVE: LAYU, U_ALONE: LAYU, U_DOCKED: LAYU,
    M_ENDS: MODELU, M_ANCHOR: MODELU, M_ADDED: MODELU,
    S_EVENTS: SCRUBT, S_MARK: SCRUBT, S_CALLS: SCRUBT,
    P_TIMELINE: PARITY, P_POINTER: PARITY, P_CARET: PARITY, P_MOD: PARITY,
    P_HISTORY: PARITY, P_WATCH: PARITY, P_MENU: PARITY, P_OMNIBOX: PARITY,
    R_DIFF9: PRODUCERS,
    F_ROW: FRAMEV, F_DRAG: FRAMEV,
    Y_TRACK: PTY, Y_ASCII: PTY, Y_CARET: PTY,
    G_EVENTS: GPLAN, G_CALLS: GPLAN, G_CHANGED: GPLAN, G_HISTORY: GPLAN,
    G_CARET: GPLAN, G_MENU: GPLAN, G_OMNIBOX: GPLAN, G_POINTER: GPLAN,
    D_EVENTLOG: DE_EVENTLOG, D_SAVED: DE_SAVED, D_CHANGED: DE_CHANGED,
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
    # --- the layout model: the Timeline removed, a saved layout migrated -----
    Arm("L1", LAYOUT,
        "  if node.hasKey(\"pane\") and node[\"pane\"].kind == JString and\n      node[\"pane\"].getStr in RetiredPaneSpellings:\n    return nil\n",
        "  if false:\n    return nil\n",
        U_V5, "a v5 document's Timeline leaf is decoded, not dropped"),
    Arm("L2", LAYOUT,
        "    var mapped = survivors.find(old)\n",
        "    var mapped = 0\n",
        U_ACTIVE, "the stack's active tab falls on its first tab, not the one that slid in"),
    Arm("L3", LAYOUT,
        "      node[\"kind\"].getStr in [\"row\", \"column\"] and kept.len == 1 and\n",
        "      false and kept.len == 1 and\n",
        U_ALONE, "a row or column left with one child is kept as such"),
    Arm("L4", LAYOUT,
        "        d.delete(\"beside\")\n",
        "        discard\n",
        U_DOCKED, "a docked pane keeps a `beside` naming the retired Timeline"),
    Arm("PM1", PMENU,
        "      item(\"Event Log\", \"aEventLog\"),\n",
        "      item(\"Event Log\", \"aEventLog\"),\n      item(\"Timeline\", \"aEventLog\"),\n",
        P_TIMELINE, "the View menu lists a Timeline again"),
    Arm("K1", KEYMAP,
        "  r.add b(mmNormal, \"4\", kaSelectEventLog)\n",
        "  r.add b(mmNormal, \"4\", kaSelectCallStack)\n",
        P_TIMELINE, "`4` selects another pane than the Event Log"),
    # --- the shared models --------------------------------------------------
    Arm("S1", SCRUB,
        "  else: max(0.0, min(1.0, float(pos) / float(trackUnits - 1)))\n",
        "  else: max(0.0, min(1.0, (float(pos) + 0.5) / float(trackUnits)))\n",
        M_ENDS, "a press on the track's last unit names a row short of the last"),
    Arm("V1", VCH,
        "    if snap.tick < tick:\n",
        "    if snap.tick <= tick:\n",
        M_ANCHOR, "a stop is its own anchor, so nothing ever changed"),
    Arm("V2", VCH,
        "  diff.changeFor(path) in {vchModified, vchAdded}\n",
        "  diff.changeFor(path) in {vchModified}\n",
        M_ADDED, "a binding the step created is not marked changed"),
    # --- the terminal ---------------------------------------------------------
    Arm("T1", TEVENT,
        "  scrubberModel(max(0, model.knownTotal), model.scrollTop, bodyHeight,\n",
        "  scrubberModel(max(0, bodyHeight), model.scrollTop, bodyHeight,\n",
        S_EVENTS, "the event log's track spans the rows on screen, not the log"),
    Arm("T2", RUNTIME,
        "  let top = sm.scrubTo(hit, dragging)\n  let before = rt.app.eventLog.fetchCount\n",
        "  let top = (if dragging: sm.scrubTo(hit, dragging) else: min(sm.maxFirstVisible, sm.firstVisible + sm.visible))\n  let before = rt.app.eventLog.fetchCount\n",
        S_EVENTS, "a press on the event log's track pages by one screen"),
    Arm("T3", TCALL,
        "  scrubberModel(m.total, m.visibleTop(bodyRows), bodyRows, m.currentTraceIndex)\n",
        "  scrubberModel(m.rows.len, m.visibleTop(bodyRows), bodyRows, m.currentTraceIndex)\n",
        S_CALLS, "the call trace's track spans the loaded section"),
    Arm("T4", TTRACK,
        "    g.paint(markRow, col, ThumbFullGlyph, MarkStyle)\n",
        "    discard markRow\n",
        S_MARK, "the current position is not marked on the track"),
    Arm("T5", TTREE,
        "  elif spec.modified: ChangedValueStyle\n",
        "  elif false: ChangedValueStyle\n",
        P_MOD, "a changed value is painted in its class colour, unmarked"),
    Arm("T6", RUNTIME,
        "          outcome.requestClick(PaneClickRequest(kind: pcSeek,\n                                                tick: prow.ticks))\n",
        "          rt.note(\"history entry\")\n",
        P_HISTORY, "a click on a history entry goes nowhere"),
    Arm("T7", TSESSION,
        "    for vm in [session.session.stateVM, s.state]:\n",
        "    for vm in [session.session.stateVM]:\n",
        P_WATCH, "a watch reaches the engine's StateVM and not the pane's"),
    Arm("TS1", TSESSION,
        "      session.gotoTick(c.tick)\n",
        "      session.gotoTick(c.tick div 2)\n",
        P_HISTORY, "the host seeks a history entry to half its tick"),
    Arm("T8", RUNTIME,
        "  if name in [\"Alt+t\", \"Ctrl+Enter\"]:\n",
        "  if false:\n",
        P_CARET, "Alt+t and Ctrl+Enter do not open the tracepoint editor"),
    Arm("T14", TDRIVER,
        "      if b > ' ' and b <= '~':\n        let alt = Esc & $b\n",
        "      if false:\n        let alt = Esc & $b\n",
        Y_CARET, "the framer drops Alt's ESC: a real terminal's Alt+T is a bare t"),
    Arm("T15", RUNTIME,
        "     not rt.caretTakesAltChord(rt.lastKey):\n    return rt.handleToken(token[1 .. 1], nowMs)\n",
        "     false:\n    return rt.handleToken(token[1 .. 1], nowMs)\n",
        P_CARET, "an unbound Alt+<char> is swallowed instead of being the character"),
    Arm("T9", RUNTIME,
        "    if isMouse and event.shift:\n",
        "    if false:\n",
        P_MENU, "a Shift-modified report is routed like a plain one"),
    Arm("T10", TCTX,
        "  if hintRow < area.row + area.height - f:\n",
        "  if false:\n",
        P_MENU, "the menus carry no inert hint row"),
    Arm("T11", TTOPBAR,
        "  OmnibarGround* = srSurfaceEditor\n",
        "  OmnibarGround* = srSurfaceField\n",
        P_OMNIBOX, "the omnibox field is on the input surface"),
    Arm("T12", TGUTTER,
        "  ExecutionPointerMark = \"▸\"\n",
        "  ExecutionPointerMark = \"▶\"\n",
        P_POINTER, "the current-line mark is the emoji-prone ▶"),
    Arm("T13", TBORDERS,
        "(\"▸\", \">\")",
        "(\"▸\", \"-\")",
        Y_ASCII, "the ASCII tier does not draw the mark as >"),
    Arm("P1", RUNTIME,
        "  if screen.trackCol < 0 or screen.trackRows <= 0:\n    return false\n  let sm = rt.app.eventLog.scrubberOf(screen.trackRows)\n",
        "  if true:\n    return false\n  let sm = rt.app.eventLog.scrubberOf(screen.trackRows)\n",
        Y_TRACK, "a press on the shipped binary's event-log track is routed nowhere"),
    Arm("R1", READER,
        "    let line = raw.withoutScrubber(pane.width)\n",
        "    let line = raw\n",
        R_DIFF9, "the terminal reader reads the scrubber's glyph as event text"),
    Arm("F1", TFRAME,
        "  model.frameCount > 1 and area.width >= 2 and area.height >= 3\n",
        "  false and area.width >= 2 and area.height >= 3\n",
        F_ROW, "the frame viewer has no scrubber of its own"),
    Arm("F2", RUNTIME,
        "      rt.scrubFrameViewer(event.col, \"release\", outcome)\n",
        "      outcome.repaint = true\n",
        F_DRAG, "the frame scrubber's release settles nowhere"),
    # --- GPUI ------------------------------------------------------------------
    Arm("G1", GMAIN,
        "    if pressListScrubber(r, x, y):\n      return\n    if clickCalltrace(r, x, y):\n      return\n",
        "    if clickCalltrace(r, x, y):\n      return\n    if pressListScrubber(r, x, y):\n      return\n",
        G_CALLS, "a press on GPUI's call-trace track jumps to the call row under it"),
    Arm("G2", GLIST,
        "               fraction: trackFractionAt(local, track.h))\n",
        "               fraction: trackFractionAt(local, track.h * 2))\n",
        G_EVENTS, "GPUI's track reads a press at half its place"),
    Arm("G3", GLEAVES,
        "      r.setAttribute(lane, PointerMarkAttribute, \"highlight_line_arrow.svg\")\n",
        "      r.setAttribute(lane, PointerMarkAttribute, \"▶\")\n",
        G_POINTER, "GPUI marks the current line with a glyph"),
    Arm("G4", GLEAVES,
        "                                (if changed: StateChangedColour\n",
        "                                (if false: StateChangedColour\n",
        G_CHANGED, "GPUI paints a changed value in the plain value colour"),
    Arm("G5", GMAIN,
        "  if path in open:\n    open.excl path\n  else:\n    try:\n      discard gSession.loadValueHistory(path, gpuiRowBudget())\n",
        "  if true:\n    open.excl path\n  else:\n    try:\n      discard gSession.loadValueHistory(path, gpuiRowBudget())\n",
        G_HISTORY, "GPUI's history control never opens the history"),
    Arm("G6", GMAIN,
        "      placeCaret(r, path, c.line, column)\n",
        "      discard column\n",
        G_CARET, "a click in GPUI's code places no caret"),
    Arm("G7", GMAIN,
        "  gCtxMenu.openAt(menu, y, x)\n",
        "  var hinted = menu\n  hinted.entries.add ContextMenuEntry(label: \"Terminal menu: Shift + right-click\")\n  gCtxMenu.openAt(hinted, y, x)\n",
        G_MENU, "GPUI's menus gain the terminal's hint row"),
    Arm("G8", GMAIN,
        "      let b = absBox(r, sg.rect, EditorGround)\n",
        "      let b = absBox(r, sg.rect, chromeOf(crInputBackground))\n",
        G_OMNIBOX, "GPUI's omnibox field is on the input surface"),
    # --- the desktop, the real Electron app --------------------------------
    Arm("D1", DEVLOG,
        "        setScrollTopJs(body, float(max(0, min(row, rows))) / float(rows) *\n",
        "        discard (body, float(max(0, min(row, rows))) / float(rows) *\n",
        D_EVENTLOG, "the desktop's event-log track press moves nothing"),
    Arm("D2", DCONFIG,
        "  sanitizeLayoutConfig(config, -1, retiredContentIds())\n",
        "  sanitizeLayoutConfig(config, -1, @[])\n",
        D_SAVED, "the desktop keeps a saved layout's Timeline tab"),
    Arm("D3", DSTATE,
        "  if vm.isChanged(item().path): \"value-expanded-text value-changed\"\n",
        "  if false: \"value-expanded-text value-changed\"\n",
        D_CHANGED, "the desktop draws no changed value"),
    # --- the engine ------------------------------------------------------------
    Arm("E1", ENGINE,
        "                \"markers\": marker_rows,\n                \"total\": total,\n",
        "                \"markers\": marker_rows,\n                \"total\": page_events.len(),\n",
        S_EVENTS, "the engine reports the page it sent as the log's size"),
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
    state = Path(tempfile.gettempdir()) / f"plat51-mutation-state-{os.getuid()}"
    state.mkdir(parents=True, exist_ok=True)
    env["CODETRACER_TUI_LAYOUT_DIR"] = str(state)
    env["XDG_STATE_HOME"] = str(state)
    return env


def artefacts_for(path: str) -> tuple:
    stem = Path(path).stem
    base = Path(tempfile.gettempdir()) / f"plat51-mutation-{os.getuid()}"
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
                env["HOME"] = tempfile.mkdtemp(prefix="plat51-s1-home-")
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
    if arm is not None and \
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
            if any(path in ENGINE_SUBJECTS for path, _f, _r in arm.edits()):
                _DIRTY.add("engine")
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
