#!/usr/bin/env python3
"""PLAT-50 — the mutation harness for the user's 2026-10-02 requests on the
terminal and GPUI front-ends: the desktop's CLICK BEHAVIOURS in the panes
(request 1, `headless_app/pane_clicks.ClickInventory`), SUBTLER COLOURS from
the design tokens (2), the omnibox CENTRED at the desktop's width (3), and
DIVIDERS AND TAB BARS — no rule row above a strip, the divider cell in a strip
row on the strip's ground, edge one-eighth blocks, two divider colours (4).

    python3 src/frontend/tui/tests/run-plat50-clicks-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=RT1,GM2

Run from the repository root, inside the dev shell, with `REPLAY_SERVER_BIN`
exported (the real-PTY suites and the GPUI plan suite open the real `calc` and
`multi_root` recordings and move them). The GPUI suites load
`libgpui_nim_shim`; the harness puts `$ISONIM_GPUI_SHIM_DIR` (else
`../isonim-gpui/rust/target/debug`) on `LD_LIBRARY_PATH`. IG1's subject is in
the SIBLING `isonim-gpui` (`$ISONIM_GPUI_SRC`, else `../isonim-gpui/src`) and
is graded by that repository's own `tests/test_input_focus.nim`, run in its
checkout; IG2-IG4 by its shim's cargo tests, in its own dev shell (`nix
develop <isonim-gpui>`: the windowed suite needs the X11 / Wayland libraries),
into `$CT_P50_SHIM_TARGET`. EN1-EN3 are graded by the engine's unit tests
(`cargo test --lib event_order_tests`) and EN4 by the real terminal against a
replay-server REBUILT with the defect: both build in `$CT_P50_ENGINE_DIR`
(default `src/db-backend`) into the target directory `REPLAY_SERVER_BIN` was
built in, and the restored engine is rebuilt before the harness exits. DE1 runs the REAL Electron app (`scripts/plat50-capture-electron.sh`,
which compiles this checkout's desktop JavaScript into a prefix); it needs
Xvfb (started when no display is set).

ONE ARM PER CLAIM, each naming the case (or the gate) that must die:

  | request | arms |
  |---|---|
  | 1 the shared menus | PC1 (the tab menu's order), PC2 (Run to Cursor without its key), PC3 (a disabled breakpoint offers "Disable"), PC4 (a leaf may expand), PC5 (a variable's entry disabled), PC6 (Up/Down land on disabled entries), PC7 (a disabled entry is chosen), PC8 (no Unpin on a dock label), PC9 (no word just past its end), PC10 (an ambiguous Rust path taken), PC11 ("Add all values" pins one), PC13 (a row dropped from the table), EV1 (a second header click keeps the direction) |
  | 1 the sweep's other rows, terminal | RT21 (Alt+click at column 1), RT22 (Ctrl+Alt read as Alt), RT23 (Copy copies nothing), RT24 (a tracepoint on the stop's line), RT25 (the close button inverted), RT26 (header clicks ignored), RT27 (the status line copies nothing), RT28 (a dock label opens the tab menu), RT29 (Unpin does nothing), RT31 (the View menu cannot add a pane), RT32 (the commit below opens), RT33 (`:origin` waits for a move: the freeze), RT34 (Ctrl+click pins nothing), RT35 (an argument opens the call's menu), RF1 (a Files menu again), TS7-TS11 (the host drops the column / the order / the removal / the origin answer / the tracepoint's line), VS1 (a commit only closes), VD1 (a commit's files named by their letter), EL1 (the header arrow reversed), SP1 (the close button a cell off) |
  | 1 the sweep's other rows, shared ops | HS5 / HS6 (a column breakpoint sent, or kept, without its column), HS7 (a call jump without its name), HS8 (the order always ascending), HS9 (history rows without values), HS10 (the origin chain dropped), HS11 (the scratchpad never written), HS12 (a disabled column breakpoint still sent) |
  | 1 the sweep's other rows, GPUI | GM14-GM25 (column, call jump, header order, close button, value pin, footer copy, dock label menu, View menu, adopted leaves, commit files, argument menu, the clipboard never written), GL2 (arguments unmarked) |
  | 1 the engine and the shim | EN1-EN3 (`event_db`: output sorted backwards, ties reversed, the column name's key), EN4 (`dap_handler` ignores the order — the shipped defect, graded on the real terminal against a rebuilt replay-server), IG2 / IG3 (the shim never listens for the right / middle button), IG4 (every frame writes the clipboard) |
  | 1 terminal routes | RT1 (tab menu on the middle button), RT2 (a folder opens as a file), RT3 (Files rows off by one), RT4 (gutter click does nothing), RT5 (gutter right-click inverted), RT6 (Ctrl+click ignored), RT7 (breakpoint line's menu as a plain line), RT8 (a leaf's menu enabled), RT9 (right-click on an event jumps), RT11 (a value click expands nothing), RT12 (the point above selected), RT13 (Close does nothing), RT14 (Run to Cursor runs backward), RT15 (Disable enables), RT16 (Delete ALL does nothing), RT17 (an entry chosen by the right button), RT18 (Esc keeps the content), RT19 (Down moves up), RT20 (no pane route at all) |
  | 1 terminal host | TS1 (collapsed folders still list their files), TS2 (an opened file never shown), TS3 (the status line does not say where), TS4 (the gutter right-click always enables), TS6 (Delete ALL deletes nothing) |
  | 1 shared ops | HS1 (a disabled breakpoint still sent), HS2 (Run to Cursor sent as backward), HS3 (clearing a file sends nothing), HS4 (a jump with no step that way hangs), SD1 (a disabled row stored enabled), NH1 (the tree opens collapsed), PV1 (the vocabulary tree ignores the VM's expansion) |
  | 1 terminal input | MO1 (Ctrl read from the Alt bit), FT1 (a collapsed folder's twisty), PL1 (the selected point not drawn), CM1 (menu rows off by the frame), CM2 (disabled entries not italic), CM3 (the menu far from the press), CM4 (the overlay shows the title for the text) |
  | 1 GPUI | GW1 (right button read as left), GW2 (ancestors act on the same press), GW3 (gutter and code swapped), GW4 (the menu's hit one entry low), GM1 (event right-click shows nothing), GM2 (gutter right-click inverted), GM3 (Ctrl+click ignored), GM4 (Run to Cursor backward), GM5 (collapse sends expand), GM6 (Close does nothing), GM8 (a value press expands nothing), GM9 (a file press opens nothing), GM13 (a press on the menu falls through), IG1 (isonim-gpui: the right button an unknown kind) |
  | 2 colours | RO1 (inactive tabs black), RO2 (the field the raised slab), RO3 (the menu on the card), RO4 (the strip divider in the border colour), RO6 (the strip on raised), RO7 (the top bar on the card), RO8 (the menu frame in the subtle border), SH4 (row 0 on the card), TB3 (controls filled), TB5 (no dropdown frame), GC1 (GPUI's window ground the old raised), GC2 (GPUI's menu on the card), GM11 (GPUI's band on the pane ground), GM12 (GPUI's omnibox border the menu's) |
  | 3 the omnibox | TB1 (not centred), TB2 (a third, not the desktop's share), TB4 (no field edge), GT1 (GPUI not centred), GT2 (GPUI a third wide) |
  | 4 dividers | BD1 (the strip is no divider), BD2 (a lone pane's whole strip is its label), SH1 (a strip-row divider on the panel), SH2 (body dividers in the subtle colour by default), SH3 (body dividers on the canvas), SH5 (a box-drawing line), RO5 (subtle is the strip colour), BO1 (the field edge degrades to `!`), CL1 (`--dividers` inverted), TM1 (the terminal never reads `--dividers`), TA1 (the shell never gets the choice), GM10 (GPUI never draws subtle lines) |
  | desktop defects | DE1 (the gutter right-click reads the marker's empty dataset), DE2 (a press with no text position throws), DE3 (the marker's right-click matched by a class it lacks), DL1 (the desktop's header never reverses), CV1 (an argument's parts misattributed) |

THREE VERDICTS (Verification-Harness-Traps §1): `killed` (the named case
reported [FAILED], or the named gate failed), `SURVIVED` (the case [OK] / the
gate green), `HARNESS-FAILURE` (the needle was not unique, the suite did not
compile, the mutated binary did not build, or the run printed no result
lines). A run that prints nothing is never a kill.

Every Nim suite is run FILTERED to its killer case (std/unittest's own name
argument), so an arm costs one case rather than a suite; the control run is
unfiltered and must name every killer as [OK].

THE BINARY IS PART OF THE SUBJECT: an arm graded by a real-PTY suite rebuilds
`build/bin/codetracer-tui` with the defect (`just build-tui`), one graded by
the GPUI plan suite rebuilds `build/bin/codetracer-gpui` (`just build-gpui`).
The restored tree's binaries are rebuilt before the next arm that runs a
binary unmutated would matter to — and always before the harness exits — so a
mutant binary never outlives its arm's grade.

RESTORATION is from an in-memory snapshot, and every touched file's SHA-256
is compared with the pre-run baseline after each arm (§32). The full run
refuses unless the needle scan is clean AND every touched file matches
`plat50-clicks-mutation-control.sha256`. The sibling subject is recorded under
`isonim-gpui/...`, relative to its checkout, so the control reads the same on
every checkout.

NO DECLARED SURVIVORS.

PLAT-51 retired RT10, RT30, GM7, GL1 and TS5 with the Timeline panel they
mutated (K30 / K45 and GPUI's track; a seek's host route is PLAT-51's TS1).

No mocks: every suite graded here runs the product's own models, the
product's own runtime and shell, a real PTY with real recordings, the shipped
GPUI binary's window plan, isonim-gpui's own event ABI, and the real Electron
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
PANECLICKS = "src/frontend/headless_app/pane_clicks.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
TUISESSION = "src/frontend/tui/host/tui_session.nim"
HSESSION = "src/frontend/viewmodel/headless_session.nim"
STORE = "src/frontend/viewmodel/store/replay_data_store.nim"
NATIVEHOST = "src/frontend/tui/host/native_host.nim"
PANEVIEWS = "src/frontend/view_vocabulary/pane_views.nim"
MOUSE = "src/frontend/tui/app/input/mouse.nim"
BINDING = "src/frontend/tui/app/layout/binding.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
ROLES = "src/frontend/tui/app/theme/roles.nim"
TOPBAR = "src/frontend/tui/app/views/top_bar.nim"
CTXMENU = "src/frontend/tui/app/views/context_menu.nim"
FILETREE = "src/frontend/tui/app/views/file_tree.nim"
POINTLIST = "src/frontend/tui/app/views/point_list.nim"
BORDERS = "src/frontend/tui/app/views/borders.nim"
CLI = "src/frontend/tui/app/cli.nim"
TUIAPP = "src/frontend/tui/app/tui_app.nim"
TUIMAIN = "src/frontend/tui/main.nim"
CHROME = "src/frontend/gpui/chrome.nim"
WINTOP = "src/frontend/gpui/window_top_bar.nim"
WINCLICKS = "src/frontend/gpui/window_clicks.nim"
GPUIMAIN = "src/frontend/gpui/main.nim"
GPUILEAVES = "src/frontend/gpui/app/leaves.nim"
DESKEDITOR = "src/frontend/ui/editor.nim"
DESKEVENTLOG = "src/frontend/ui/event_log.nim"
EVENTLOGVM = "src/frontend/viewmodel/viewmodels/event_log_vm.nim"
CALLTRACEVM = "src/frontend/viewmodel/viewmodels/calltrace_vm.nim"
VCSDETAILS = "src/frontend/viewmodel/host/native_vcs_details.nim"
VCSSOURCE = "src/frontend/tui/host/vcs_source.nim"
EVENTLOGVIEW = "src/frontend/tui/app/views/event_log.nim"
SCRATCHPANE = "src/frontend/tui/app/views/scratchpad_pane.nim"
EVENTDB = "src/db-backend/src/event_db.rs"
DAPHANDLER = "src/db-backend/src/dap_handler.rs"
ISONIM_GPUI_DIR = Path(os.environ.get(
    "ISONIM_GPUI_DIR", str(ROOT.parent / "isonim-gpui")))
if os.environ.get("ISONIM_GPUI_SRC"):
    ISONIM_GPUI_DIR = Path(os.environ["ISONIM_GPUI_SRC"]).parent
GRENDERER = str(ISONIM_GPUI_DIR / "src" / "isonim_gpui" / "renderer.nim")
SHIM_CRATE = ISONIM_GPUI_DIR / "rust" / "gpui-nim-shim"
SHIMAPP = str(SHIM_CRATE / "src" / "gpui_app.rs")
SHIMCLIP = str(SHIM_CRATE / "src" / "clipboard.rs")
# The engine's crate: this checkout's, unless `CT_P50_ENGINE_DIR` names a
# copy whose `src` is this checkout's (a sandbox carrying the trace-format
# siblings at the versions `repro.lock` pins, when the workspace's are not).
ENGINE_DIR = Path(os.environ.get("CT_P50_ENGINE_DIR",
                                 str(ROOT / "src" / "db-backend")))

# --- suites and gates ---------------------------------------------------------
VMU = "src/frontend/viewmodel/tests/unit/test_plat50_click_models.nim"
REF = "src/frontend/tui/tests/test_plat50_desktop_reference.nim"
T1 = "src/frontend/tui/tests/test_plat50_shell.nim"
PTYK = "src/frontend/tui/tests/real_terminal/test_plat50_clicks.nim"
PTYC = "src/frontend/tui/tests/real_terminal/test_plat50_chrome.nim"
GPLAN = "src/frontend/gpui/tests/test_plat50_gpui_plan.nim"
COLVM = "src/frontend/viewmodel/tests/unit/test_plat50_column_ops_vm.nim"
ENGT = EVENTDB + "#event_order_tests"
SHIMT = str(SHIM_CRATE / "tests" / "gpui_rendering.rs")
CLIPT = SHIMCLIP + "#tests"
IGT = str(ISONIM_GPUI_DIR / "tests" / "test_input_focus.nim")
DESKTOP_GATE = "scripts/plat50-capture-electron.sh"
SPEC = "src/tests/gui/tests/visual/plat50-desktop-capture.spec.ts"

SUBJECTS = [PANECLICKS, RUNTIME, TUISESSION, HSESSION, STORE, NATIVEHOST,
            PANEVIEWS, MOUSE, BINDING, SHELL, ROLES, TOPBAR, CTXMENU,
            FILETREE, POINTLIST, BORDERS, CLI, TUIAPP, TUIMAIN, CHROME,
            WINTOP, WINCLICKS, GPUIMAIN, GPUILEAVES, DESKEDITOR, GRENDERER,
            DESKEVENTLOG, EVENTLOGVM, CALLTRACEVM, VCSDETAILS, VCSSOURCE,
            EVENTLOGVIEW, SCRATCHPANE, EVENTDB, DAPHANDLER, SHIMAPP, SHIMCLIP]
SUITES = [VMU, COLVM, REF, T1, PTYK, PTYC, GPLAN, IGT, ENGT, SHIMT, CLIPT,
          DESKTOP_GATE]


def suite_file(path: str) -> str:
    """The file a suite key names (a gate's `#<grep>` suffix dropped)."""
    return path.split("#", 1)[0]


TOUCHED = list(dict.fromkeys(SUBJECTS + [suite_file(p) for p in SUITES] +
                             [SPEC]))

# How each suite is run: (backend, lane whose `--path`s it needs).
SUITE_KIND = {
    VMU: ("c", "vm-unit"),
    COLVM: ("c", "vm-recorder-gated"),
    # Rust: the engine's unit tests, and isonim-gpui's shim (its windowed
    # suite needs the shim's own dev shell: X11 / Wayland libraries).
    ENGT: ("cargo-engine", "event_order_tests"),
    SHIMT: ("cargo-shim", "--test gpui_rendering"),
    CLIPT: ("cargo-shim", "--lib"),
    REF: ("c", "tui"),
    T1: ("c", "tui"),
    PTYK: ("c", "tui-real-terminal"),
    PTYC: ("c", "tui-real-terminal"),
    GPLAN: ("c", "gpui-shell"),
    # isonim-gpui's own suite, compiled in ITS checkout with its `nim.cfg`.
    IGT: ("isonim-gpui", ""),
    # The real desktop, filtered to its one case (a regex without spaces).
    DESKTOP_GATE: ("electron", "PLAT-50"),
}
BINARY_SUITES = {PTYK, PTYC}
ENGINE_SUBJECTS = {EVENTDB, DAPHANDLER}
  # an arm on these graded by a binary suite rebuilds the replay-server
  # `REPLAY_SERVER_BIN` names, from `ENGINE_DIR`
  # graded against a REBUILT codetracer-tui
GPUI_BINARY_SUITES = {GPLAN}
  # read the WINDOW's render plan of a REBUILT codetracer-gpui
UNISOLATED_SUITES: set = set()
  # none: every suite here runs with the harness's own state isolation

CONTROL_HASHES = HERE / "plat50-clicks-mutation-control.sha256"
ANSWER_FILES = [ROOT / "src/tests/visual/answers" / "plat50-desktop.electron.json"]
  # what the desktop gate writes; restored after every run (`run_electron`)
SUITE_TIMEOUT = int(os.environ.get("CT_P50_SUITE_TIMEOUT", "3600"))
SHIM = Path(os.environ.get("ISONIM_GPUI_SHIM_DIR",
                           str(ISONIM_GPUI_DIR / "rust/target/debug")))
RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*\s*(.*?)\s*$")

# --- the killer cases, spelled once ------------------------------------------
V_TAB = "a tab's menu, and a docked pane's label's"
V_PLAIN = "the editor's menu on a plain line: every entry enabled"
V_BPLINE = "the editor's menu on a breakpoint's line"
V_CALL = "a call's menu: its children"
V_VALUES = "an argument's, a variable's and an inline value's menus"
V_ROWS = "the rows this milestone implements, by front-end"
V_WORD = "the word a column is in, or ends; none on a separator"
V_RUST = "Rust widens over `::` and refuses an ambiguous path"
V_HEADER = "a header click orders by its column; again reverses it"
COL_STOP = "it stops at the column; it replaces the line's; edits keep it"
COL_OFF = "a disabled column breakpoint does not stop the replay"
V_MOVE = "it opens on the first enabled entry; Up and Down skip disabled ones"
V_CHOOSE = ("choosing: a disabled entry keeps the menu, an enabled one closes "
            "it")
R_BAR = "the caption bar, its controls, the omnibox"
R_STRIP = "the strip, its tabs, the splitters, the pane"
R_MENU = "the open menu's surface and border"
R_OMNI = "24% of the bar, clamped; centred"
S_TABMENU = "right-click a tab: the desktop's menu; Down and Enter choose Close"
S_ESC = "Esc closes the menu, and an event's content overlay"
S_PRESS = "a press on an entry chooses THAT entry: Close, not its neighbour"
S_LONE = "a LONE pane's strip off its label is the divider above it too"
S_RESIZE = "a press on the lower pane's strip off its tabs resizes the split"
S_POINT = "a click on a point-list row selects it, on the selection ground"
S_ASCII = "the ASCII tier draws the edge lines as |"
S_FLAG = "--dividers=strip|subtle, strip by default, anything else refused"
K_FILES = "a file click opens it in the editor; a folder click collapses it"
K_FILEMENU = "a right-click on a node opens no menu (the desktop has none)"
K_GUTTER = ("a gutter click sets a breakpoint the replay stops at; a right "
            "click disables it")
K_CTRL = ("Ctrl+click and a middle click on a line go to it; the status line "
          "says where")
K_TEXTMENU = ("a right click in the text: the desktop's menu, and Run to "
              "Cursor runs there")
K_BPMENU = "the menu on a breakpoint's line: disable, delete, and delete them all"
K_EVENT = "a click on an event goes to it; a right click shows its whole content"
K_CALL = ("right-click a call: Collapse Call Children, and choosing it "
          "collapses")
K_TAB = "right-click a tab: pin, close, maximise; Close removes it"
K_VALUE = ("a click on a value expands it; a right click offers history and "
           "origin")
K_WHERE = ("after a click moves the debugger the status line says where it "
           "landed")
K_COLUMN = "Alt+click anchors a breakpoint at the column; the replay honours it"
K_CALLJUMP = "Ctrl+Alt+click on a call goes into it; the menu's call jumps too"
K_COPY = "Copy puts the line on the clipboard (OSC 52)"
K_TRACEPOINT = "Add tracepoint: the prompt, then the sweep's hits on that line"
K_SCRATCH = ("an argument and an inline value pinned; a close button removes "
             "one")
K_ORDER = "a header click orders the log by its column; again reverses it"
K_STATUS = "a click on the status line copies the location"
K_DOCK = "a right-click on a dock label: the desktop's strip menu; Unpin"
K_POINTS = "the menu opens the Points pane; a click selects a point"
K_VCS = "a changed file shows its diff; a commit lists its files"
K_OKEY = "`o` on the selected variable asks for its origin and answers"
C_BAR = ("the bar is the desktop's ground; controls have no fill; the omnibox "
         "is centred and bordered")
C_MENU = "the open menu stands apart: the dropdown surface inside a frame"
C_STRIPS = ("strips on the desktop's ground; no rule above a strip; strips "
            "connect across a divider")
C_BODY = ("body dividers: the strip's colour by default, ui/border/secondary "
          "with --dividers=subtle")
G_EVENT = "an event row goes to the event; a right click shows its content"
G_GUTTER = "the gutter sets a breakpoint; a right click disables it"
G_CTRL = "Ctrl+click and a middle click go to the line"
G_TEXTMENU = "the editor's menu is the desktop's, and Run to Cursor runs there"
G_CALL = "a call's menu: Collapse Call Children collapses it"
G_TAB = "a tab's menu: Close removes the tab"
G_VALUE = "a value expands; a variable's menu"
G_FILES = "a file opens in the editor; a folder collapses; a node's menu"
G_CHROME = "the desktop's grounds, a centred bordered omnibox"
G_DIVIDERS = ("--dividers=subtle draws a line in each gap between side-by-side "
              "panes")
I_POINTER = ("a pointer event decodes its window position, and a wheel its "
             "delta")
G_SCRATCH = "an argument pinned to the scratchpad; its close button removes it"
G_ORDER = "an event-log header orders the log; again reverses it"
G_COLUMN = ("Alt+click anchors a column breakpoint; Ctrl+Alt+click goes into "
            "a call")
G_FLOW = "an inline value's menu; Ctrl+click pins it"
G_SWEEP = "the Variables tabs, a point, the footer's location, a dock label"
G_VCS = "the VCS pane: a file's diff, a commit's files"
E_ORDER = "a_column_orders_the_log_and_ties_keep_the_recorded_order"
E_NAMES = "column_names_select_their_keys"
I_BUTTONS = "test_right_and_middle_buttons_reach_their_listeners"
I_CLIP = "write_keeps_the_text_and_one_pending_copy"
D_DESKTOP = "gate:" + DESKTOP_GATE

CASE_SUITE = {
    V_TAB: VMU, V_PLAIN: VMU, V_BPLINE: VMU, V_CALL: VMU, V_VALUES: VMU,
    V_MOVE: VMU, V_CHOOSE: VMU, V_ROWS: VMU, V_WORD: VMU, V_RUST: VMU,
    V_HEADER: VMU, COL_STOP: COLVM, COL_OFF: COLVM,
    R_BAR: REF, R_STRIP: REF, R_MENU: REF, R_OMNI: REF,
    S_TABMENU: T1, S_ESC: T1, S_RESIZE: T1, S_PRESS: T1, S_LONE: T1, S_POINT: T1, S_ASCII: T1,
    S_FLAG: T1,
    K_FILES: PTYK, K_FILEMENU: PTYK, K_GUTTER: PTYK, K_CTRL: PTYK,
    K_TEXTMENU: PTYK, K_BPMENU: PTYK, K_EVENT: PTYK, K_CALL: PTYK,
    K_TAB: PTYK, K_VALUE: PTYK, K_WHERE: PTYK,
    K_COLUMN: PTYK, K_CALLJUMP: PTYK, K_COPY: PTYK, K_TRACEPOINT: PTYK,
    K_SCRATCH: PTYK, K_ORDER: PTYK, K_STATUS: PTYK, K_DOCK: PTYK,
    K_POINTS: PTYK, K_VCS: PTYK, K_OKEY: PTYK,
    C_BAR: PTYC, C_MENU: PTYC, C_STRIPS: PTYC, C_BODY: PTYC,
    G_EVENT: GPLAN, G_GUTTER: GPLAN, G_CTRL: GPLAN, G_TEXTMENU: GPLAN,
    G_CALL: GPLAN, G_TAB: GPLAN, G_VALUE: GPLAN,
    G_FILES: GPLAN, G_CHROME: GPLAN, G_DIVIDERS: GPLAN,
    G_SCRATCH: GPLAN, G_ORDER: GPLAN, G_COLUMN: GPLAN, G_FLOW: GPLAN,
    G_SWEEP: GPLAN, G_VCS: GPLAN,
    I_POINTER: IGT,
    E_ORDER: ENGT, E_NAMES: ENGT, I_BUTTONS: SHIMT, I_CLIP: CLIPT,
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
    # --- 1. the shared menus (`headless_app/pane_clicks`) ---------------------
    Arm("PC1", PANECLICKS,
        '      entry(DesktopTabMenuLabels[0], caPinLeft),\n      entry(DesktopTabMenuLabels[1], caPinBottom),\n',
        '      entry(DesktopTabMenuLabels[1], caPinBottom),\n      entry(DesktopTabMenuLabels[0], caPinLeft),\n',
        V_TAB, "the tab menu's pins out of the desktop's order"),
    Arm("PC2", PANECLICKS,
        'entry("Run to Cursor", caRunToCursor, hint = "CTRL+F10"),',
        'entry("Run to Cursor", caRunToCursor),',
        V_PLAIN, "Run to Cursor loses the desktop's key hint"),
    Arm("PC3", PANECLICKS,
        'result.entries.add entry("Enable breakpoint", caEnableBreakpoint)',
        'result.entries.add entry("Disable breakpoint", caEnableBreakpoint)',
        V_BPLINE, "a disabled breakpoint's line offers Disable"),
    Arm("PC4", PANECLICKS,
        "            enabled = hasChildren,\n",
        "            enabled = true,\n",
        V_CALL, "a call with no children offers to expand them"),
    Arm("PC5", PANECLICKS,
        '      entry("Toggle value history", caToggleValueHistory),\n',
        '      entry("Toggle value history", caToggleValueHistory,\n            enabled = false),\n',
        V_VALUES, "a variable's history entry disabled, as the Files ones were"),
    Arm("PC6", PANECLICKS,
        "    i = (i + delta + n) mod n\n    if s.menu.entries[i].enabled:\n",
        "    i = (i + delta + n) mod n\n    if true:\n",
        V_MOVE, "Up / Down stop on disabled entries"),
    Arm("PC7", PANECLICKS,
        "  if not e.enabled:\n    return (false, caNone, s.menu.target)\n",
        "  if false:\n    return (false, caNone, s.menu.target)\n",
        V_CHOOSE, "a disabled entry is chosen and runs"),
    # --- 1. the terminal's routes (`runtime.routePaneClick` and friends) ------
    Arm("RT1", RUNTIME,
        "    if event.button != mbRight:\n      return false\n    let pane = rt.app.layoutBinding.stripPaneAt(",
        "    if event.button != mbMiddle:\n      return false\n    let pane = rt.app.layoutBinding.stripPaneAt(",
        S_TABMENU, "the tab menu opens on the middle button, not the right"),
    Arm("RT2", RUNTIME,
        "      kind: (if e.isFolder: pcToggleFolder else: pcOpenFile), path: e.path))",
        "      kind: pcOpenFile, path: e.path))",
        K_FILES, "a folder click is sent as opening a file"),
    Arm("RT3", RUNTIME,
        "    let i = tree.scrollTop + (event.row - under.row - 1)\n",
        "    let i = tree.scrollTop + (event.row - under.row - 2)\n",
        K_FILES, "a Files click lands on the row above"),
    Arm("RT4", RUNTIME,
        "    if event.button == mbLeft:\n      outcome.requestClick(PaneClickRequest(kind: pcToggleBreakpoint,\n                                            path: src.path, line: line))",
        "    if event.button == mbOther:\n      outcome.requestClick(PaneClickRequest(kind: pcToggleBreakpoint,\n                                            path: src.path, line: line))",
        K_GUTTER, "a gutter click sets no breakpoint"),
    Arm("RT5", RUNTIME,
        "          enabled: mark == gmBreakpointDisabled))",
        "          enabled: mark == gmBreakpoint))",
        K_GUTTER, "the gutter right-click enables an enabled breakpoint"),
    Arm("RT6", RUNTIME,
        "    elif event.ctrl:\n      outcome.requestClick(PaneClickRequest(kind: pcLineJump, path: src.path,",
        "    elif false:\n      outcome.requestClick(PaneClickRequest(kind: pcLineJump, path: src.path,",
        K_CTRL, "Ctrl+click on a line goes nowhere"),
    Arm("RT7", RUNTIME,
        "    of gmBreakpoint: lbEnabled\n",
        "    of gmBreakpoint: lbNone\n",
        K_BPMENU, "a breakpoint's line gets the plain line's menu"),
    Arm("RT8", RUNTIME,
        "rt.openContextMenu(callTraceContextMenu(hit.index, call.toggle != crtLeaf,",
        "rt.openContextMenu(callTraceContextMenu(hit.index, call.toggle == crtLeaf,",
        K_CALL, "a leaf call's menu offers expanding, a parent's does not"),
    Arm("RT9", RUNTIME,
        "  if event.button == mbRight:\n    rt.showContent(\"event #\"",
        "  if false:\n    rt.showContent(\"event #\"",
        K_EVENT, "a right-click on an event jumps instead of showing it"),
    Arm("RT11", RUNTIME,
        "      discard rt.app.variables.toggleNode(path)\n",
        "      discard path\n",
        K_VALUE, "a value click expands nothing"),
    Arm("RT12", RUNTIME,
        "    rt.app.points.selected = i\n",
        "    rt.app.points.selected = i - 1\n",
        S_POINT, "the point above the click is selected"),
    Arm("RT13", RUNTIME,
        "  of caClosePane: rt.layout(cmdRemovePane(target.pane))\n",
        "  of caClosePane: discard\n",
        S_TABMENU, "the tab menu's Close closes nothing"),
    Arm("RT14", RUNTIME,
        '                  of caRunToCursor: "forward"\n',
        '                  of caRunToCursor: "backward"\n',
        K_TEXTMENU, "the terminal's Run to Cursor runs backward"),
    Arm("RT15", RUNTIME,
        "      enabled: action == caEnableBreakpoint))\n",
        "      enabled: true))\n",
        K_BPMENU, "the menu's Disable breakpoint enables it"),
    Arm("RT16", RUNTIME,
        "  of caDeleteAllBreakpoints:\n    outcome.requestClick(PaneClickRequest(kind: pcDeleteBreakpoints))\n",
        "  of caDeleteAllBreakpoints:\n    outcome.repaint = true\n",
        K_BPMENU, "Delete ALL breakpoints deletes nothing"),
    Arm("RT17", RUNTIME,
        "        if index >= 0 and event.button == mbLeft:\n",
        "        if index >= 0 and event.button == mbRight:\n",
        K_TAB, "a menu entry is chosen only by the right button"),
    Arm("RT18", RUNTIME,
        '    of "Escape", "Esc", "Enter", "q":\n      rt.app.content = ContentOverlay()\n',
        '    of "Enter", "q":\n      rt.app.content = ContentOverlay()\n',
        S_ESC, "Esc leaves the event's content open"),
    Arm("RT19", RUNTIME,
        '  of "Down": rt.app.contextMenu.move(1)\n',
        '  of "Down": rt.app.contextMenu.move(-1)\n',
        S_TABMENU, "Down in a context menu moves up"),
    Arm("RT20", RUNTIME,
        "  if acted.status == lasNoGesture and not inGesture and\n     rt.routePaneClick(geometry, event, outcome):\n",
        "  if acted.status == lasNoGesture and not inGesture and false and\n     rt.routePaneClick(geometry, event, outcome):\n",
        S_POINT, "no press reaches a pane's own click route"),
    # --- 1. the terminal's host (`tui_session.applyPaneClick`) ----------------
    Arm("TS1", TUISESSION,
        "    let open = not n.isFolder or vm.isExpanded(n.path)\n",
        "    let open = true\n",
        K_FILES, "a collapsed folder still lists its files"),
    Arm("TS2", TUISESSION,
        "    rt.app.viewedFile = c.path\n    s.showViewedFile(rt)\n",
        "    rt.app.viewedFile = \"\"\n    s.showViewedFile(rt)\n",
        K_FILES, "a file opened from Files never reaches the editor"),
    Arm("TS3", TUISESSION,
        "  rt.app.notification = s.describe()\n",
        "  discard s.describe()\n",
        K_WHERE, "after a click's move the status line keeps the old note"),
    Arm("TS4", TUISESSION,
        "    if session.setBreakpointEnabled(c.path, c.line, c.enabled):\n",
        "    if session.setBreakpointEnabled(c.path, c.line, true):\n",
        K_GUTTER, "the host always enables, whatever the click asked"),
    Arm("TS6", TUISESSION,
        "         (c.path.len == 0 or r.path == c.path):\n",
        "         (c.path.len == 0 and r.path == c.path):\n",
        K_BPMENU, "Delete ALL breakpoints matches no file"),
    # --- 1. the shared operations ------------------------------------------
    Arm("HS1", HSESSION,
        "      if enabled: anchors.add a\n      else: disabled.add a\n",
        "      anchors.add a\n",
        K_GUTTER, "a disabled breakpoint is still sent to the engine"),
    Arm("HS2", HSESSION,
        '  of "forward": 1\n',
        '  of "forward": 2\n',
        K_TEXTMENU, "a forward line jump is sent as backward"),
    Arm("HS3", HSESSION,
        "  ## `setBreakpoints` with none, which also drops its disabled rows.\n  s.sendBreakpoints(path, @[])\n",
        "  ## `setBreakpoints` with none, which also drops its disabled rows.\n  true\n",
        K_BPMENU, "clearing a file's breakpoints sends nothing"),
    Arm("HS4", HSESSION,
        "  if not moved:\n    s.backend.bound = saved\n    raise newException(CatchableError, what)\n",
        "  if false:\n    s.backend.bound = saved\n    raise newException(CatchableError, what)\n",
        G_TEXTMENU, "a line jump that finds no step waits for a move forever"),
    Arm("SD1", STORE,
        "                              column: max(0, a.column), enabled: false,\n",
        "                              column: max(0, a.column), enabled: true,\n",
        K_GUTTER, "the store keeps a disabled breakpoint as an enabled row"),
    Arm("NH1", NATIVEHOST,
        "    expandAllFolders(files)\n",
        "    discard files\n",
        K_FILES, "the native tree opens with its folders collapsed"),
    Arm("PV1", PANEVIEWS,
        "               expanded = kids.len > 0 and vm.isExpanded(e.path))\n",
        "               expanded = kids.len > 0)\n",
        G_FILES, "the vocabulary tree ignores the VM's expansion"),
    # --- 1. terminal input and painters ------------------------------------
    Arm("MO1", MOUSE,
        "  event.ctrl = (code and 16) != 0\n",
        "  event.ctrl = (code and 8) != 0\n",
        K_CTRL, "Ctrl is read from SGR's Alt bit"),
    Arm("FT1", FILETREE,
        "     else: CollapsedFolderGlyph & \" \") & e.text\n",
        "     else: FolderGlyph & \" \") & e.text\n",
        K_FILES, "a collapsed folder keeps the open twisty"),
    Arm("PL1", POINTLIST,
        "      g.fillSurface(area.row + 1 + i, area.col, area.width, 1,\n                    srSurfaceSelection)\n",
        "      g.fillSurface(area.row + 1 + i, area.col, area.width, 1,\n                    srSurfacePanel)\n",
        S_POINT, "the selected point is drawn like the rest"),
    Arm("CM1", CTXMENU,
        "  let i = row - area.row - DropdownFrameCells\n",
        "  let i = row - area.row\n",
        S_PRESS, "a press on a menu row chooses the entry below it"),
    Arm("CM2", CTXMENU,
        "            CellStyle(role: role, bold: selected and e.enabled,\n                      italic: not e.enabled, surface: surface))\n",
        "            CellStyle(role: role, bold: selected and e.enabled,\n                      italic: false, surface: surface))\n",
        K_CALL, "a disabled entry is not set apart"),
    Arm("CM3", CTXMENU,
        "  let row = max(1, min(s.anchorRow + 1, height - h))\n",
        "  let row = max(1, min(s.anchorRow + 4, height - h))\n",
        S_TABMENU, "the menu opens away from the press"),
    Arm("CM4", CTXMENU,
        "  let lines = wrapLines(o.text, max(1, iw))\n",
        "  let lines = wrapLines(o.title, max(1, iw))\n",
        S_ESC, "the overlay shows its title where the content belongs"),
    # --- 1. GPUI ------------------------------------------------------------
    Arm("GW1", WINCLICKS,
        "  of gekContextMenu: gbRight\n",
        "  of gekContextMenu: gbLeft\n",
        G_TEXTMENU, "GPUI reads the right button as the left"),
    Arm("GW2", WINCLICKS,
        "  if d.armed and d.kind == ev.kind and d.key == ev.key:\n    return false\n",
        "  if false:\n    return false\n",
        G_FILES, "every ancestor row acts on the same press"),
    Arm("GW3", WINCLICKS,
        "                       gcpCode else: gcpGutter),\n",
        "                       gcpGutter else: gcpCode),\n",
        G_GUTTER, "GPUI's gutter and code column swapped"),
    Arm("GW4", WINCLICKS,
        "    if rr.contains(x, y):\n      return (true, i)\n",
        "    if rr.contains(x, y):\n      return (true, min(i + 1, s.menu.entries.len - 1))\n",
        G_TEXTMENU, "GPUI's menu hit is one entry low"),
    Arm("GM1", GPUIMAIN,
        "    if c.button == gbRight:\n      showContent(r, \"event #\"",
        "    if false:\n      showContent(r, \"event #\"",
        G_EVENT, "GPUI's event right-click shows nothing"),
    Arm("GM2", GPUIMAIN,
        "                                              mark == emBreakpointDisabled)\n",
        "                                              mark == emBreakpoint)\n",
        G_GUTTER, "GPUI's gutter right-click enables an enabled breakpoint"),
    Arm("GM3", GPUIMAIN,
        "    elif c.button == gbMiddle or (c.button == gbLeft and c.ctrl):\n",
        "    elif c.button == gbMiddle:\n",
        G_CTRL, "GPUI's Ctrl+click goes nowhere"),
    Arm("GM4", GPUIMAIN,
        '         of caRunToCursor: "forward"\n',
        '         of caRunToCursor: "backward"\n',
        G_TEXTMENU, "GPUI's Run to Cursor runs backward"),
    Arm("GM5", GPUIMAIN,
        '        (if line.isExpanded: "ct/collapse-calls" else: "ct/expand-calls"),\n',
        '        (if line.isExpanded: "ct/expand-calls" else: "ct/collapse-calls"),\n',
        G_CALL, "GPUI's Collapse Call Children sends expand"),
    Arm("GM6", GPUIMAIN,
        "  of caClosePane:\n    applyGestureCommand(r, cmdRemovePane(target.pane))\n",
        "  of caClosePane:\n    discard target\n",
        G_TAB, "GPUI's tab menu Close closes nothing"),
    Arm("GM8", GPUIMAIN,
        "      session.stateVM.toggleExpand(c.key)\n",
        "      discard c.key\n",
        G_VALUE, "GPUI's value press expands nothing"),
    Arm("GM9", GPUIMAIN,
        "      gViewedFile = e.path\n      if gViewedFile == gSession.getCurrentFile():\n",
        "      gViewedFile = \"\"\n      if gViewedFile == gSession.getCurrentFile():\n",
        G_FILES, "GPUI's file press opens nothing"),
    Arm("GM13", GPUIMAIN,
        "  if kind in {gekPointerDown, gekContextMenu, gekAuxDown} and\n     handlePopoverPress(r, kind, x, y):\n",
        "  if kind in {gekPointerDown, gekContextMenu, gekAuxDown} and false and\n     handlePopoverPress(r, kind, x, y):\n",
        G_TAB, "a press on GPUI's open menu falls through to the window"),
    Arm("IG1", GRENDERER,
        "  of GpuiEventPointerContext: gekContextMenu\n",
        "  of GpuiEventPointerContext: gekOther\n",
        I_POINTER, "isonim-gpui: the right button decodes to an unknown kind"),
    # --- 1. the sweep's other rows: the shared models ------------------------
    Arm("PC8", PANECLICKS,
        "  result.entries.add entry(UnpinLabel, caUnpin)\n",
        "  discard\n",
        V_TAB, "a dock label's menu has no Unpin"),
    Arm("PC9", PANECLICKS,
        "    if at > 0 and runes[at - 1].isWordRune:\n      dec at\n",
        "    if false:\n      dec at\n",
        V_WORD, "a press just past a word's end finds no word"),
    Arm("PC10", PANECLICKS,
        "  if rust and lineText.count(result.token) != 1:\n",
        "  if false:\n",
        V_RUST, "an ambiguous Rust path is taken, not refused"),
    Arm("PC11", PANECLICKS,
        "  of caAddAllValuesToScratchpad: target.values\n",
        "  of caAddAllValuesToScratchpad: target.values[0 ..< min(1, target.values.len)]\n",
        V_VALUES, "\"Add all values\" pins only the first"),
    Arm("PC13", PANECLICKS,
        '  k("K14", ',
        '  k("K14x", ',
        V_ROWS, "the column breakpoint's row dropped from the table"),
    Arm("EV1", EVENTLOGVM,
        "  if o.column == column: EventLogOrder(column: column, ascending: not o.ascending)\n",
        "  if o.column == column: EventLogOrder(column: column, ascending: o.ascending)\n",
        V_HEADER, "a second header click does not reverse the order"),
    Arm("CV1", CALLTRACEVM,
        "    result.add CallSegment(kind: csArgValue, text: a.value, arg: i + 1)\n",
        "    result.add CallSegment(kind: csArgValue, text: a.value, arg: i)\n",
        K_SCRATCH, "an argument's value belongs to the argument before it"),
    Arm("DL1", DESKEVENTLOG,
        '        let direction = if again and ascending: cstring"desc" else: cstring"asc"\n',
        '        let direction = cstring"asc"\n',
        D_DESKTOP, "the desktop's second header click does not reverse the order"),
    Arm("HS5", HSESSION,
        "  anchors.add (line, column)\n  s.sendBreakpoints(path, anchors, disabled)\n",
        "  anchors.add (line, 0)\n  s.sendBreakpoints(path, anchors, disabled)\n",
        COL_STOP, "a column breakpoint sent without its column"),
    Arm("HS6", HSESSION,
        "      if r.enabled: result.enabled.add (r.line, r.column)\n",
        "      if r.enabled: result.enabled.add (r.line, 0)\n",
        COL_STOP, "an edit elsewhere drops the column breakpoints' columns"),
    Arm("HS12", HSESSION,
        "      if enabled: anchors.add a\n      else: disabled.add a\n    elif a in held.enabled: anchors.add a\n",
        "      anchors.add a\n      if not enabled: disabled.add a\n    elif a in held.enabled: anchors.add a\n",
        COL_OFF, "a disabled column breakpoint is still sent, and also listed disabled"),
    Arm("HS7", HSESSION,
        '              %*{"path": path, "line": line, "token": token,',
        '              %*{"path": path, "line": line, "token": "",',
        K_CALLJUMP, "a call jump sent without the function's name"),
    Arm("HS8", HSESSION,
        '    args["sortAscending"] = %order.ascending\n',
        '    args["sortAscending"] = %true\n',
        K_ORDER, "the log's order always sent ascending"),
    Arm("HS9", HSESSION,
        '      valueText: presentedValueText(r{"value"}, budget))\n',
        '      valueText: "")\n',
        K_VALUE, "a value's history rows lose their values"),
    Arm("HS10", HSESSION,
        '  parseOriginChain(resp.getOrDefault("body"))\n',
        '  OriginChain()\n',
        K_VALUE, "the origin chain the engine answered is dropped"),
    Arm("HS11", HSESSION,
        "  vm.addValue(ScratchpadValueEntry(expression: expression, valueText: value))\n",
        "  discard vm\n",
        K_SCRATCH, "nothing reaches the scratchpad"),
    # --- 1. the sweep's other rows: the terminal ------------------------------
    Arm("RT21", RUNTIME,
        "        column: max(1, min(target.column, width))))\n",
        "        column: 1))\n",
        K_COLUMN, "Alt+click anchors at the line's first column"),
    Arm("RT22", RUNTIME,
        "    if event.ctrl and event.alt:\n      # K15",
        "    if false:\n      # K15",
        K_CALLJUMP, "Ctrl+Alt+click is read as Alt+click"),
    Arm("RT23", RUNTIME,
        '    rt.copyToClipboard(target.text & "\\n", "line " & $target.line)\n',
        '    rt.copyToClipboard("", "line " & $target.line)\n',
        K_COPY, "Copy copies nothing"),
    Arm("RT24", RUNTIME,
        "    rt.openTracepointEditorAt(target.path, target.line)\n",
        '    rt.openTracepointEditorAt("", 0)\n',
        K_TRACEPOINT, "the tracepoint lands on the stop's line, not the chosen one"),
    Arm("RT25", RUNTIME,
        "    if hit.row < 0 or not hit.close:\n",
        "    if hit.row < 0 or hit.close:\n",
        K_SCRATCH, "the close button does nothing, the value's text removes it"),
    Arm("RT26", RUNTIME,
        "    if onHeader and event.button == mbLeft:\n",
        "    if false:\n",
        K_ORDER, "a header click is ignored"),
    Arm("RT27", RUNTIME,
        "  if event.row == rt.height - 1 and event.button == mbLeft:\n",
        "  if false:\n",
        K_STATUS, "a click on the status line copies nothing"),
    Arm("RT28", RUNTIME,
        "  rt.openContextMenu(dockLabelContextMenu(strip.slots[i].pane, strip.edge),\n",
        "  rt.openContextMenu(tabContextMenu(strip.slots[i].pane, false),\n",
        K_DOCK, "a dock label opens the tab's menu"),
    Arm("RT29", RUNTIME,
        "  of caUnpin: rt.layout(cmdRestoreDocked(target.pane))\n",
        "  of caUnpin: discard\n",
        K_DOCK, "Unpin does nothing"),
    Arm("RT31", RUNTIME,
        "    let added = b.dispatch(cmdAddPane(pane, after = anchor))\n",
        "    let added = b.dispatch(cmdActivateTab(pane))\n",
        K_POINTS, "the View menu cannot open a pane the arrangement lacks"),
    Arm("RT32", RUNTIME,
        "      outcome.requestClick(PaneClickRequest(kind: pcVcsCommit,\n                                            index: t.index))\n",
        "      outcome.requestClick(PaneClickRequest(kind: pcVcsCommit,\n                                            index: t.index + 1))\n",
        K_VCS, "a commit click opens the commit below it"),
    Arm("RT33", RUNTIME,
        "      outcome.awaitsOrigin = true\n    else:\n      outcome.awaitsMove = true\n",
        "      outcome.awaitsMove = true\n    else:\n      outcome.awaitsMove = true\n",
        K_OKEY, "`o` waits for a move again (the freeze)"),
    Arm("RT37", RUNTIME,
        "    rt.context.selectedVariable = variablePathOf(path)\n",
        "    discard variablePathOf(path)\n",
        K_OKEY, "a selected Variables row is not what `o` acts on"),
    Arm("RT36", RUNTIME,
        "      outcome.awaitsMove = false\n      outcome.awaitsOrigin = true\n      outcome.originRetry = line\n",
        "      outcome.originRetry = line\n",
        K_VALUE, "`:origin` waits for a move again (the freeze)"),
    Arm("RT34", RUNTIME,
        "        outcome.requestClick(PaneClickRequest(kind: pcScratchpadAdd,\n                                              values: @[(v.name, v.value)]))\n",
        "        outcome.requestClick(PaneClickRequest(kind: pcScratchpadAdd,\n                                              values: @[]))\n",
        K_SCRATCH, "Ctrl+click on an inline value pins nothing"),
    Arm("RT35", RUNTIME,
        "    if hit.arg >= 0 and hit.arg < call.args.len:\n",
        "    if false:\n",
        K_SCRATCH, "an argument's right-click opens the call's menu"),
    Arm("RF1", RUNTIME,
        "    # K17 / K18 (K19: the desktop has no Files menu).\n    if event.button != mbLeft:\n",
        "    # K17 / K18 (K19: the desktop has no Files menu).\n    if event.button == mbRight:\n      rt.openContextMenu(tabContextMenu(paneFileTree, false), event.row,\n                         event.col, outcome)\n      return true\n    if event.button != mbLeft:\n",
        K_FILEMENU, "a Files node opens a menu again"),
    Arm("TS7", TUISESSION,
        "    if session.setColumnBreakpoint(c.path, c.line, c.column):\n",
        "    if session.setColumnBreakpoint(c.path, c.line, 1):\n",
        K_COLUMN, "the terminal's column breakpoint drops the column"),
    Arm("TS8", TUISESSION,
        "    rt.app.eventLog.reorder(c.order)\n",
        "    rt.app.eventLog.reorder(RecordedEventOrder)\n",
        K_ORDER, "the terminal's log keeps the recorded order"),
    Arm("TS9", TUISESSION,
        "      vm.removeValue(int(c.index))\n",
        "      discard vm\n",
        K_SCRATCH, "the terminal's close button removes nothing"),
    Arm("TS10", TUISESSION,
        "      event = s.session.backend.waitForEvent(OriginEventName)\n",
        "      event = nil\n",
        K_VALUE, "the origin query's answer never read"),
    Arm("TS11", TUISESSION,
        "    line: request.line, expression: request.expression)])\n",
        "    line: request.line + 1, expression: request.expression)])\n",
        K_TRACEPOINT, "the tracepoint swept on the line below"),
    Arm("VS1", VCSSOURCE,
        "  if selected == @[index]:\n",
        "  if true:\n",
        K_VCS, "a commit click only ever closes"),
    Arm("VD1", VCSDETAILS,
        "      result.add ($parts[0][0], parts[^1])\n",
        "      result.add ($parts[0][0], parts[0])\n",
        K_VCS, "a commit's files listed by their state letter"),
    Arm("EL1", EVENTLOGVIEW,
        '         (if model.order.ascending: " ▲" else: " ▼")',
        '         (if model.order.ascending: " ▼" else: " ▲")',
        K_ORDER, "the header's arrow points the other way"),
    Arm("SP1", SCRATCHPANE,
        "  result = ScratchpadHit(row: i, close: col == area.col)\n",
        "  result = ScratchpadHit(row: i, close: col == area.col + 1)\n",
        K_SCRATCH, "the close button's hit a cell off"),
    # --- 1. the sweep's other rows: GPUI --------------------------------------
    Arm("GM14", GPUIMAIN,
        "      if gSession.setColumnBreakpoint(path, c.line, col):\n",
        "      if gSession.setColumnBreakpoint(path, c.line, 1):\n",
        G_COLUMN, "GPUI's Alt+click anchors at the first column"),
    Arm("GM15", GPUIMAIN,
        "    elif c.button == gbLeft and c.ctrl and c.alt:\n",
        "    elif false:\n",
        G_COLUMN, "GPUI's Ctrl+Alt+click read as Alt+click"),
    Arm("GM16", GPUIMAIN,
        "    orderEventLog(r, session.eventLogVM.order.clickedHeader(shown[c.index]))\n",
        "    orderEventLog(r, RecordedEventOrder)\n",
        G_ORDER, "GPUI's header click keeps the recorded order"),
    Arm("GM17", GPUIMAIN,
        "    session.scratchpadVM.removeValue(int(c.index))\n",
        "    discard\n",
        G_SCRATCH, "GPUI's close button removes nothing"),
    Arm("GM18", GPUIMAIN,
        "    elif c.button == gbLeft and c.ctrl:\n      gSession.addToScratchpad(v.name, v.value)\n",
        "    elif c.button == gbLeft and c.ctrl:\n      discard\n",
        G_FLOW, "GPUI's Ctrl+click on a value pins nothing"),
    Arm("GM19", GPUIMAIN,
        '      copyToClipboard(gSession.getCurrentFile(), "the path")\n',
        '      copyToClipboard("", "the path")\n',
        G_SWEEP, "GPUI's footer copies nothing"),
    Arm("GM20", GPUIMAIN,
        "          openContextMenuAt(r, dockLabelContextMenu(k, strip.edge), x, y)\n",
        "          openContextMenuAt(r, tabContextMenu(k, false), x, y)\n",
        G_SWEEP, "GPUI's dock label opens the tab's menu"),
    Arm("GM21", GPUIMAIN,
        "    applyGestureCommand(r, cmdAddPane(pane,\n",
        "    applyGestureCommand(r, cmdActivateTab(pane))\n    discard (cmdAddPane(pane,\n",
        G_SWEEP, "GPUI's View menu cannot open a pane the arrangement lacks"),
    Arm("GM22", GPUIMAIN,
        "    gPanes[leaf.paneId] = node\n    gLeafSet.leaves.add leaf\n",
        "    discard node\n",
        G_SWEEP, "a pane added after open is never drawn"),
    Arm("GM23", GPUIMAIN,
        "    vm.setCommitFiles(index, rows)\n",
        "    vm.setCommitFiles(index, @[])\n",
        G_VCS, "GPUI's opened commit lists no files"),
    Arm("GM24", GPUIMAIN,
        "      if row.index == c.index and c.line >= 0 and c.line < row.args.len:\n",
        "      if false:\n",
        G_SCRATCH, "GPUI's argument right-click opens nothing"),
    Arm("GM25", GPUIMAIN,
        "  writeClipboard(text)\n",
        "  discard text\n",
        G_SWEEP, "GPUI never hands the text to the clipboard"),
    Arm("GL2", GPUILEAVES,
        "        r.setAttribute(piece, CallArgAttribute, $(seg.arg - 1))\n",
        "        discard piece\n",
        G_SCRATCH, "GPUI's arguments are not marked for their press"),
    # --- 1. the engine's order, and the shim's buttons ----------------------
    Arm("EN1", EVENTDB,
        "        EventOrderKey::Output => a.content.cmp(&b.content),\n",
        "        EventOrderKey::Output => b.content.cmp(&a.content),\n",
        E_ORDER, "the output column sorts backwards"),
    Arm("EN2", EVENTDB,
        "            .then(a.direct_location_rr_ticks.cmp(&b.direct_location_rr_ticks))\n",
        "            .then(b.direct_location_rr_ticks.cmp(&a.direct_location_rr_ticks))\n",
        E_ORDER, "ties reversed, not in the recorded order"),
    Arm("EN3", EVENTDB,
        '            "output" | "content" => Some(EventOrderKey::Output),\n',
        '            "output" | "content" => Some(EventOrderKey::Kind),\n',
        E_NAMES, "the output column's name selects the kind key"),
    Arm("EN4", DAPHANDLER,
        "            Some(order) => crate::event_db::ordered_event_positions(all_events.len(), |i| &all_events[i], order),\n",
        "            Some(_order) => (0..all_events.len()).collect::<Vec<usize>>(),\n",
        K_ORDER, "the engine ignores the log's order (the shipped defect)"),
    Arm("IG2", SHIMAPP,
        "        el = el.on_mouse_down(MouseButton::Right, move |event, _window, _cx| {\n",
        "        el = el.on_mouse_down(MouseButton::Navigate(gpui::NavigationDirection::Back), move |event, _window, _cx| {\n",
        I_BUTTONS, "the shim never listens for the right button"),
    Arm("IG3", SHIMAPP,
        "        el = el.on_mouse_down(MouseButton::Middle, move |event, _window, _cx| {\n",
        "        el = el.on_mouse_down(MouseButton::Navigate(gpui::NavigationDirection::Forward), move |event, _window, _cx| {\n",
        I_BUTTONS, "the shim never listens for the middle button"),
    Arm("IG4", SHIMCLIP,
        "    PENDING.lock().unwrap_or_else(|p| p.into_inner()).take()\n",
        "    PENDING.lock().unwrap_or_else(|p| p.into_inner()).clone()\n",
        I_CLIP, "every frame writes the clipboard again"),
    # --- 2. colours ---------------------------------------------------------
    Arm("RO1", ROLES,
        "    srTabInactive: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,\n                        dtColorsUiSurfacePrimaryDefault, baseSurface = true),\n",
        "    srTabInactive: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,\n                        dtColorsUiSurfaceBaseRaised, baseSurface = true),\n",
        R_STRIP, "inactive tabs back on the black raised ground"),
    Arm("RO2", ROLES,
        "                         dtColorsUiSurfaceInputDefault, mono = {raUnderline}),\n",
        "                         dtColorsUiSurfaceBaseRaised, mono = {raUnderline}),\n",
        R_BAR, "the omnibox back on the raised slab"),
    Arm("RO3", ROLES,
        "    srSurfaceMenu: fgbg(dgSurface, dtColorsUiTextPrimaryBody,\n                        dtColorsUiSurfacePrimaryDefault, mono = {raReverse}),\n",
        "    srSurfaceMenu: fgbg(dgSurface, dtColorsUiTextPrimaryBody,\n                        dtColorsUiSurfaceBaseCard, mono = {raReverse}),\n",
        R_MENU, "the dropdown on the card, not the desktop's surface"),
    Arm("RO4", ROLES,
        "    srDividerStrip: fgOnly(dgBorder, dtColorsUiSurfacePrimaryDefault),\n",
        "    srDividerStrip: fgOnly(dgBorder, dtColorsUiBorderSecondary),\n",
        R_STRIP, "the strip-coloured divider drawn in the border colour"),
    Arm("RO5", ROLES,
        "  of dcSubtle: srBorderPane\n",
        "  of dcSubtle: srDividerStrip\n",
        S_FLAG, "the subtle choice draws the strip colour"),
    Arm("RO6", ROLES,
        "    srTabBar: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,\n                   dtColorsUiSurfacePrimaryDefault, baseSurface = true),\n",
        "    srTabBar: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,\n                   dtColorsUiSurfaceBaseRaised, baseSurface = true),\n",
        R_STRIP, "the strip's ground back on raised"),
    Arm("RO7", ROLES,
        "    srSurfaceTopBar: fgbg(dgSurface, dtColorsUiTextPrimaryBody,\n                          dtColorsUiSurfacePrimaryDefault, baseSurface = true),\n",
        "    srSurfaceTopBar: fgbg(dgSurface, dtColorsUiTextPrimaryBody,\n                          dtColorsUiSurfaceBaseCard, baseSurface = true),\n",
        R_BAR, "the top bar on the card, not the caption bar's ground"),
    Arm("RO8", ROLES,
        "    srBorderMenu: fgOnly(dgBorder, dtColorsUiBorderPrimary),\n",
        "    srBorderMenu: fgOnly(dgBorder, dtColorsUiBorderSecondary),\n",
        R_MENU, "the dropdown frame in the subtle border"),
    Arm("SH4", SHELL,
        "  g.fillSurface(0, 0, width, HeaderRows, srSurfaceTopBar)\n",
        "  g.fillSurface(0, 0, width, HeaderRows, srSurfaceCard)\n",
        C_BAR, "row 0's empty cells on the card"),
    Arm("TB3", TOPBAR,
        "                    if hovered: srTabActive else: srSurfaceTopBar)\n",
        "                    if hovered: srTabActive else: srSurfaceCard)\n",
        C_BAR, "a transport control filled apart from the bar",
        also=((TOPBAR,
               "              CellStyle(role: role, bold: hovered,\n                        surface: (if hovered: srTabActive\n                                  else: srSurfaceTopBar)))\n",
               "              CellStyle(role: role, bold: hovered,\n                        surface: (if hovered: srTabActive\n                                  else: srSurfaceCard)))\n"),)),
    Arm("TB5", TOPBAR,
        "    paintDropdownFrame(g, a)\n    let ic = a.col + f\n",
        "    g.fillSurface(a.row, a.col, a.width, a.height, srSurfaceMenu)\n    let ic = a.col + f\n",
        C_MENU, "the menu's dropdown unframed"),
    Arm("GC1", CHROME,
        "    DesignTokenHex[dtColorsUiSurfacePrimaryDefault][dmDark],\n    DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark],\n",
        "    DesignTokenHex[dtColorsUiSurfaceBaseRaised][dmDark],\n    DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark],\n",
        G_CHROME, "GPUI's window ground off the desktop's"),
    Arm("GC2", CHROME,
        "    DesignTokenHex[dtColorsUiSurfacePrimaryDefault][dmDark],\n    DesignTokenHex[dtColorsUiBorderPrimary][dmDark],\n    DesignTokenHex[dtColorsUiBorderSecondary][dmDark],\n",
        "    DesignTokenHex[dtColorsUiSurfaceBaseCard][dmDark],\n    DesignTokenHex[dtColorsUiBorderPrimary][dmDark],\n    DesignTokenHex[dtColorsUiBorderSecondary][dmDark],\n",
        G_TEXTMENU, "GPUI's menu on the card"),
    Arm("GM11", GPUIMAIN,
        "  let band = absBox(r, gTopLayout.band, chromeOf(crWindowBackground))\n",
        "  let band = absBox(r, gTopLayout.band, chromeOf(crPaneBackground))\n",
        G_CHROME, "GPUI's top band on the pane ground"),
    Arm("GM12", GPUIMAIN,
        '      r.setStyle(b, "border-color", chromeOf(crFieldBorder))\n      r.setStyle(b, "white-space", "nowrap")\n',
        '      r.setStyle(b, "border-color", chromeOf(crMenuBorder))\n      r.setStyle(b, "white-space", "nowrap")\n',
        G_CHROME, "GPUI's omnibox border the menu's"),
    # --- 3. the omnibox -----------------------------------------------------
    Arm("TB1", TOPBAR,
        "    let at = max(col, min(centred, latest))\n",
        "    let at = max(col, min(col, latest))\n",
        C_BAR, "the terminal's omnibox left, not centred"),
    Arm("TB2", TOPBAR,
        "  clamp(int(float(width) * OmnibarDesktopShare + 0.5),\n",
        "  clamp(int(float(width) * 0.3 + 0.5),\n",
        R_OMNI, "the terminal's field wider than the desktop's share"),
    Arm("TB4", TOPBAR,
        '  FieldEdgeLeft* = "▕"\n',
        '  FieldEdgeLeft* = " "\n',
        C_BAR, "the field's left border not drawn"),
    Arm("GT1", WINTOP,
        "    x = max(x, min(centred, latest))\n",
        "    x = max(x, min(x, latest))\n",
        G_CHROME, "GPUI's omnibox left, not centred"),
    Arm("GT2", WINTOP,
        "  clamp(int(float(width) * OmnibarDesktopShare + 0.5), OmnibarDesktopFloorPx,\n",
        "  clamp(int(float(width) * 0.3 + 0.5), OmnibarDesktopFloorPx,\n",
        G_CHROME, "GPUI's field wider than the desktop's share"),
    # --- 4. dividers and tab bars --------------------------------------------
    Arm("BD1", BINDING,
        "  if row == area.row and row > 0 and not b.onStripLabel(geom, idx, col):\n",
        "  if false:\n",
        S_RESIZE, "the strip off its tabs is no divider"),
    Arm("BD2", BINDING,
        "  at >= 0 and at < label\n",
        "  at >= 0\n",
        S_LONE, "a lone pane's whole strip is its label, never the divider"),
    Arm("SH1", SHELL,
        "              CellStyle(role: srDividerStrip, surface: srTabBar))\n",
        "              CellStyle(role: srDividerStrip, surface: srSurfacePanel))\n",
        C_STRIPS, "a strip row's divider on the panel, breaking the bar"),
    Arm("SH2", SHELL,
        "    let role = if focusSide: srBorderFocused else: line\n",
        "    let role = if focusSide: srBorderFocused else: srBorderPane\n",
        C_BODY, "body dividers ignore the choice"),
    Arm("SH3", SHELL,
        "    let ground = if (row, col + 1) in strips: srTabBar\n"
        "                 else: groundOf(regions, row, col + 1)\n",
        "    let ground = if (row, col + 1) in strips: srTabBar\n"
        "                 else: srSurfaceCanvas\n",
        C_BODY, "body dividers on the canvas, not the pane's fill"),
    Arm("SH5", SHELL,
        '  DividerGlyph* = "▏"\n',
        '  DividerGlyph* = "│"\n',
        C_STRIPS, "the divider a centred box-drawing line"),
    Arm("BO1", BORDERS,
        '  ("▏", "|"), ("▕", "|"),\n',
        '  ("▏", "|"), ("▕", "!"),\n',
        S_ASCII, "the field's edge degrades to a glyph that is no line"),
    Arm("CL1", CLI,
        "              if $c == dividersName:\n",
        "              if $c != dividersName:\n",
        S_FLAG, "`--dividers` picks the other choice"),
    Arm("TM1", TUIMAIN,
        "  app.dividers = command.dividers\n",
        "  discard command.dividers\n",
        C_BODY, "the terminal never reads `--dividers`"),
    Arm("TA1", TUIAPP,
        "    dividers: app.dividers,\n",
        "    dividers: dcStrip,\n",
        C_BODY, "the shell never gets the divider choice"),
    Arm("GM10", GPUIMAIN,
        "  if gOpenCmd.subtleDividers:\n    for d in gGeom.dividers:\n",
        "  if false:\n    for d in gGeom.dividers:\n",
        G_DIVIDERS, "GPUI never draws the subtle lines"),
    # --- the desktop's own defect ------------------------------------------
    Arm("DE1", DESKEDITOR,
        "    element = element.parentNode\n    dataset = element.dataset\n  if not dataset.line.isNil:\n",
        "    element = element.parentNode\n  if not dataset.line.isNil:\n",
        D_DESKTOP, "the desktop's gutter right-click reads the marker's dataset"),
    Arm("DE2", DESKEDITOR,
        "    elif e.target.position.isNil or e.target.element.isNil:\n",
        "    elif false:\n",
        D_DESKTOP, "the desktop's press with no text position throws again"),
    Arm("DE3", DESKEDITOR,
        '         cstrutils.startsWith(element, cstring"gutter-breakpoint"):\n',
        '         element == cstring"gutter-breakpoint":\n',
        D_DESKTOP, "the desktop's marker right-click matched by a class it lacks"),
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
    state = Path(tempfile.gettempdir()) / f"plat50-mutation-state-{os.getuid()}"
    state.mkdir(parents=True, exist_ok=True)
    env["CODETRACER_TUI_LAYOUT_DIR"] = str(state)
    env["XDG_STATE_HOME"] = str(state)
    return env


def artefacts_for(path: str) -> tuple:
    stem = Path(path).stem
    base = Path(tempfile.gettempdir()) / f"plat50-mutation-{os.getuid()}"
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
        proc = subprocess.run(["bash", suite_file(path), "-g", grep], cwd=ROOT,
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
    if re.search(r"^\s*1 passed", out, re.M) and proc.returncode == 0:
        res.passed.append(name)
    elif re.search(r"^\s*1 failed", out, re.M):
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


def run_one(path: str, case: str | None = None) -> RunResult:
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
    filt = [case] if case else []
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
                env["HOME"] = tempfile.mkdtemp(prefix="plat50-s1-home-")
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
        control = run_one(path)
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
