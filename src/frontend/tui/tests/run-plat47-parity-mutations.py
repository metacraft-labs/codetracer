#!/usr/bin/env python3
"""PLAT-47 (parts A and B) — the mutation harness for the terminal and GPUI
front-ends at desktop parity: the shared default generated from the desktop's
Debug layout, one editor theme, the FILES and calltrace panes, tab strips
shaped by colour and weight, the closed focus outline, the Dark-only
auto-detection and the centred jump (part A); the VCS pane, the divider drag,
the drop indication, GPUI's editor colours, border, weight and call-trace
paging, the Monaco tokenizers, and test state isolation (part B).

    python3 src/frontend/tui/tests/run-plat47-parity-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=T3,K2

Run from the repository root, inside the dev shell, with `REPLAY_SERVER_BIN`
exported (the call-trace suite and the real-PTY suites open the real `calc`
recording), after `just plat47-capture-electron` (the real-PTY suite compares
with the desktop's committed capture). The GPUI suite loads
`libgpui_nim_shim`; the harness puts the shim on `LD_LIBRARY_PATH` itself.

=============================================================================
OWED: A RE-GRADE AND A RE-RECORD, 2026-10-02 (PLAT-35), RE-MEASURED AT
`6fa0bdd89`. **BOTH PRE-EXISTING STALE ROWS WERE FIXED UPSTREAM; THIS
HARNESS NOW REFUSES ON PLAT-35'S TWO ROWS AND NOTHING ELSE.**
=============================================================================
This harness digests `src/frontend/gpui/chrome.nim` and
`src/frontend/gpui/main.nim`, both of which PLAT-35 edited. The digest is
deliberately NOT re-recorded here.

  HARNESS   run-plat47-parity-mutations.py
  ENTRIES OWED BY PLAT-35 — and, at this base, the ONLY two rows the
  comparator reports (measured: `--only=` prints exactly
  `CONTROL DIGEST MOVED` for these two and `0 problems` for every needle):
            src/frontend/gpui/chrome.nim   (the per-platform mono face)
            src/frontend/gpui/main.nim     (the `--pixels-out` capture path)
  THE TWO ROWS THAT WERE STALE AT `d34c6e087` ARE NOT STALE HERE, and the
  earlier note's claim that this harness *"ALREADY refused on this host, on
  those two rows alone, before PLAT-35 touched anything"* no longer describes
  the tree. Upstream fixed both in `f4afb504b`:
            src/frontend/index/config.nim
              — matched neither HEAD nor the working tree at the old base; it
                matches at `6fa0bdd89`.
            the overlay row
              — was recorded as `/home/zahary/m/codetracer-gui/
                isonim-tui-plat47b/src/isonim_tui/overlay.nim`, an ABSOLUTE
                path on another host, so the gate reported `CONTROL DIGEST
                ABSENT` for the local spelling. It is now recorded as the
                relative `isonim-tui/src/isonim_tui/overlay.nim` and resolves.
            **SO PLAT-35 NO LONGER ADDS ROWS TO AN ALREADY-REFUSING
            COMPARATOR; IT IS THE WHOLE REASON THIS ONE REFUSES.** That makes
            the re-grade PLAT-35's to owe rather than somebody else's to
            unblock, and it is owed, not waived.
  HOST THAT CAN GRADE IT
            a Linux host with `$ISONIM_TUI_SRC` resolving and `just build-tui`
            compiling. Still NOT aarch64-darwin: this harness's control step
            is `build_tui()` for every arm whose killer is a binary suite, and
            `just build-tui` does not compile here — see
            run-plat45-layout-mutations.py's note for the two errors measured
            at this base (`terminal_driver.nim(263, 21)` against Darwin's
            `Suseconds = int32`, behind a stale sibling checkout that stops the
            build even earlier).
  COMMAND   REPLAY_SERVER_BIN=<path> ISONIM_TUI_SRC=<path> python3 \
              src/frontend/tui/tests/run-plat47-parity-mutations.py
            # every arm must kill, and only then:
            python3 ... --record-control-hashes

**DO NOT CLEAR THE TWO PLAT-35 ROWS WITH `--record-control-hashes`.** That
flag rewrites EVERY row, and on this host not one arm can be graded first, so
it would convert *"these two rows moved"* into *"these bytes are reviewed"*
without a single verdict behind it — Verification-Harness-Traps §39a's named
prohibition, arrived at from the same direction as its `plat17` example.

ONE ARM PER CLAIM, each naming the case (or the gate) that must die:

  | claim | arms |
  |---|---|
  | the shared default is GENERATED from the desktop's Debug-mode derivation | G1 (inverse translation), G2 (TESTS' home dropped), G3 (CONSTRAINTS omission dropped), G4 (generated file hand-edited) |
  | the terminal's editor tokens ARE the Monaco theme files | T1 (a generated hex edited), T4 (the emitter's scope resolution) |
  | every editor role paints an editor-theme token | T2 |
  | the class -> scope table, read back off a real terminal against the desktop | T3 |
  | the active line number is the desktop's | L1 |
  | FILES is filled on the interactive path (the D3 root cause) | F1 |
  | the calltrace pane lists the TRACE, marks the call the debugger is in | C1, C4 |
  | GPUI's calltrace rows read `name #index`, as the desktop's `.call-text` | C3 |
  | the fallback is the stack, and it says so, in both front-ends | C2 (terminal caption), C5 (GPUI's stack) |
  | no brackets, no rule, colour and weight; reverse+bold in monochrome | B1, B2, B4, B3 |
  | the focused pane's ring: the desktop's colour, closed on every edge | K1, K2, K3 |
  | GPUI's outline colour and active-tab weight | K4, K5 |
  | auto-detection never selects Light | A1 |
  | a jump centres the execution line | V1 |
  | TESTS is captioned as the desktop's | N1 |
  | the execution band is Monaco's: the whole code column, not the gutter | X1, X2 |
  | the terminal's call trace pages: the section around the rows shown is loaded | P1, P2, P4 |
  | every language is tokenised by the desktop's Monaco tokenizer, character by character | Y1 (spans cut short), M1 (a state never popped), M2 (negated classes), M3 (a language mapped to another tokenizer), M4 (the generated definitions edited) |
  | a window opening inside a string starts in the state the file leaves | M5 (the contexts dropped), M6 (the VM's contexts misaligned) |
  | a test run never touches the user's state | S1 |
  | the VCS pane: branch and changed files, the desktop's rows, in both front-ends | Q1 (untracked lines unread), Q2 (a staged state not preferred), Q3 (GPUI's rows lose their state), Q4 (the terminal's rows lose their state), Q5 (the terminal never reads the repository) |
  | the drop indication: exactly the region the drop would take | O1 (the model's split side), O2 (the terminal's half), O3 (the terminal's overlay rectangle), O4 (isonim-tui's overlay rows), O5 (GPUI's half), O6 (GPUI's Esc), O7 (GPUI's edge bands) |
  | GPUI's divider drag, live and committed | R1 (the pointer's fraction), R2 (no live preview), R3 (the divider not hit-tested) |
  | GPUI's editor from the one editor theme (B1) | H1 (every class plain), H2 (the band under the gutter), H3 (the window's entry state ignored), H4 (the active line number) |
  | GPUI's 1px border (B2) | K6, with K4/K5 |
  | GPUI's call trace pages (B3) | P5 (never a second section), P6 (always the head), P7 (the title's count) |
  | the light editor colours are the desktop's MEASURED light ones | W1 |
  | the desktop's first run installs the Debug-mode default | E1 |
  | the VCS pane re-reads its repository on the desktop's interval and redraws when it moved | U1 (the pane's value blind to the working tree), U2 (GPUI's re-read reads nothing) |
  | a pane docked in GPUI stays on screen: its strip, its reveal, its dismissal | D1 (no strips), D2 (a click reveals nothing), D3 (a press outside keeps it) |
  | GPUI's editor rows are whole lines: the window holds the rows its pane shows | D4 (the rows counted from the window's height again) |
  | the desktop's editor opens every lexed file in its Monaco language | E2 (the recording language's name only), E3 (TOML read as `ini`) |

E1 IS GRADED BY THE REAL ELECTRON APP: `scripts/plat45-capture-electron.sh`
compiles this checkout's desktop JavaScript (the mutated `index/config.nim`
included) into a prefix and runs
`src/tests/gui/tests/layout/plat45-desktop-remembers-own.spec.ts`, filtered to
its first-run case. It needs Xvfb (started when no display is set) and the
built frontend `just build-once` leaves.

WHAT NO ARM GRADES, AND WHAT DOES INSTEAD: the GPUI window's own drawing in
`gpui/main.nim` — the strips and the revealed pane placed where the geometry
says, the VCS tick armed at `VCSRefreshIntervalMs` — needs a compositor, which
a harness arm cannot start per mutation. Those are read off a real window by
`just plat47-gpui-window` into the committed `plat47-gpui-window.json`, which
`test_plat47_gpui_window.nim` asserts (the `vcs-refresh`, `dock-*` and `base`
frames); the arms above grade every decision the drawing reads (D1–D4, U2).

W1 is a TWO-FILE arm: the light theme's block and the generated tokens are
edited together, to the value the pre-measurement version COMPOSED, so the
freshness gate and the block-equals-token case both stay green and only the
comparison with the Electron capture can see it.

THREE VERDICTS (Verification-Harness-Traps §1): `killed` (the named case
reported [FAILED], or the named gate exited non-zero printing its marker),
`SURVIVED` (the case [OK] / the gate green), `HARNESS-FAILURE` (the needle was
not unique, the suite did not compile, the mutated binary did not build, or
the run printed no result lines). A run that prints nothing is never a kill.

Every Nim suite is run FILTERED to its killer case (std/unittest's own name
argument), so an arm costs one case rather than a suite; the control run is
unfiltered and must name every killer as [OK].

THE BINARY IS PART OF THE SUBJECT: an arm graded by a real-PTY suite rebuilds
`build/bin/codetracer-tui` with the defect (`just build-tui`), and again from
the restored tree afterwards. O4's subject is in the SIBLING `isonim-tui`
(`$ISONIM_TUI_SRC`, else `../isonim-tui/src`) — the binary links it.

S1 IS GRADED WITHOUT THE HARNESS'S OWN ISOLATION: its suite runs with
`XDG_STATE_HOME` and `CODETRACER_TUI_LAYOUT_DIR` unset and `HOME` pointed at
a throwaway directory, so the forced import is the only thing isolating it —
and a mutated import that isolates nothing writes into the throwaway home,
never the developer's.

RESTORATION is from an in-memory snapshot, and every touched file's SHA-256
is compared with the pre-run baseline after each arm (§32). The full run
refuses unless the needle scan is clean AND every touched file matches
`plat47-parity-mutation-control.sha256`.

NO DECLARED SURVIVORS.
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
DESK = "src/frontend/headless_app/desktop_panes.nim"
FRONT = "src/common/common_types/codetracer_features/frontend.nim"
GENERATED = "src/frontend/headless_app/shared_default_layout.generated.json"
TOKENS = "src/frontend/styles/generated/design_tokens.nim"
EMITTER = "scripts/tokens-to-styl.sh"
ROLES = "src/frontend/tui/app/theme/roles.nim"
EDTHEME = "src/frontend/tui/app/theme/editor_theme.nim"
GUTTER = "src/frontend/tui/app/views/gutter.nim"
SESSION = "src/frontend/tui/host/tui_session.nim"
NATIVE = "src/frontend/tui/host/native_host.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
CTVIEW = "src/frontend/tui/app/views/call_trace.nim"
SRCPANE = "src/frontend/tui/app/views/source_pane.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
LEXER = "src/frontend/tui/app/syntax/highlighter.nim"
WHITE = "src/public/third_party/monaco-themes/themes/customThemes/json/codetracerWhite.json"
DESKCONFIG = "src/frontend/index/config.nim"
PANEVIEWS = "src/frontend/view_vocabulary/pane_views.nim"
TABSTRIP = "src/frontend/tui/app/layout/tab_strip.nim"
CHROME = "src/frontend/gpui/chrome.nim"
CAPS = "src/frontend/tui/app/theme/capabilities.nim"
SOURCEVM = "src/frontend/viewmodel/viewmodels/source_vm.nim"
CELLS = "src/frontend/tui/app/layout/cells.nim"
# part B
LEXICAL = "src/frontend/tui/app/syntax/lexical.nim"
MONARCH = "src/frontend/tui/app/syntax/monarch.nim"
JSREGEX = "src/frontend/tui/app/syntax/js_regex.nim"
MONARCH_JSON = "src/frontend/tui/app/syntax/monarch_languages.json"
ISOLATION = "src/frontend/test_support/state_isolation.nim"
VCSPARSE = "src/frontend/viewmodel/platform/vcs.nim"
VCSVM = "src/frontend/viewmodel/viewmodels/vcs_vm.nim"
VCSPANE = "src/frontend/tui/app/views/vcs_pane.nim"
VCSSOURCE = "src/frontend/tui/host/vcs_source.nim"
INTERACTION = "src/frontend/headless_app/layout_interaction.nim"
BINDING = "src/frontend/tui/app/layout/binding.nim"
FRAMEOVERLAY = "src/frontend/tui/app/views/frame_overlay.nim"
ISONIM_TUI_SRC_DIR = Path(os.environ.get(
    "ISONIM_TUI_SRC", str(ROOT.parent / "isonim-tui" / "src")))
ISONIM_TUI_OVERLAY = str(ISONIM_TUI_SRC_DIR / "isonim_tui" / "overlay.nim")
WINGEOM = "src/frontend/gpui/window_geometry.nim"
WINGEST = "src/frontend/gpui/window_gestures.nim"
LEAVES = "src/frontend/gpui/app/leaves.nim"
GPUIHOST = "src/frontend/gpui/host/gpui_host.nim"
GPUIMAIN = "src/frontend/gpui/main.nim"
DIFFDOC = "src/frontend/viewmodel/viewmodels/diff_document.nim"

# --- suites and gates ---------------------------------------------------------
VMJS = "src/frontend/viewmodel/tests/unit/test_shared_default_layout.nim"
THEME = "src/frontend/tui/tests/test_plat47_editor_theme.nim"
CALLS = "src/frontend/tui/tests/test_plat47_call_trace.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat47_desktop_parity.nim"
PTY45 = "src/frontend/tui/tests/real_terminal/test_real_plat45_layout.nim"
GPUIP = "src/frontend/gpui/tests/test_plat47_gpui_parity.nim"
RESOLUTION = "src/frontend/tui/app/tests/test_capability_resolution.nim"
SRCWIN = "src/frontend/viewmodel/tests/unit/test_source_vm_window.nim"
# part B
LEXERS = "src/frontend/tui/tests/test_plat47_monaco_lexers.nim"
ISOLATE = "src/frontend/tui/tests/real_terminal/test_state_isolation.nim"
VCSUNIT = "src/frontend/viewmodel/tests/unit/test_vcs_working_tree.nim"
VCSPTY = "src/frontend/tui/tests/real_terminal/test_plat47_vcs_pane.nim"
INTERACT = "src/frontend/viewmodel/tests/unit/test_layout_interaction.nim"
DROPPTY = "src/frontend/tui/tests/real_terminal/test_plat47_drop_overlay.nim"
GESTURES = "src/frontend/gpui/tests/test_plat47_window_gestures.nim"
GEDITOR = "src/frontend/gpui/tests/test_plat47_gpui_editor.nim"
GCALLS = "src/frontend/gpui/tests/test_plat47_gpui_calltrace.nim"
GVCSR = "src/frontend/gpui/tests/test_plat47_gpui_vcs_refresh.nim"
MONARCH_GATE = "ci/test/monarch-languages-fresh.sh"
LAYOUT_GATE = "ci/test/default-layout-fresh.sh"
TOKENS_GATE = "ci/test/design-tokens-fresh.sh"
DESKTOP_GATE = "scripts/plat45-capture-electron.sh"

SUBJECTS = [DESK, FRONT, GENERATED, TOKENS, EMITTER, ROLES, EDTHEME, GUTTER,
            SESSION, NATIVE, SHELL, CTVIEW, PANEVIEWS, TABSTRIP, CHROME, CAPS,
            SOURCEVM, CELLS, SRCPANE, RUNTIME, LEXER, WHITE, DESKCONFIG,
            LEXICAL, MONARCH, JSREGEX, MONARCH_JSON, ISOLATION, VCSPARSE,
            VCSVM, VCSPANE, VCSSOURCE, INTERACTION, BINDING, FRAMEOVERLAY,
            ISONIM_TUI_OVERLAY, WINGEOM, WINGEST, LEAVES, GPUIHOST, GPUIMAIN,
            DIFFDOC]
SUITES = [VMJS, THEME, CALLS, PTY, PTY45, GPUIP, RESOLUTION, SRCWIN,
          LAYOUT_GATE, TOKENS_GATE, DESKTOP_GATE,
          LEXERS, ISOLATE, VCSUNIT, VCSPTY, INTERACT, DROPPTY, GESTURES,
          GEDITOR, GCALLS, MONARCH_GATE, GVCSR]
TOUCHED = SUBJECTS + SUITES

# How each suite is run: (backend, lane whose `--path`s it needs).
SUITE_KIND = {
    VMJS: ("js", "vm-unit-js"),
    THEME: ("c", "tui"),
    CALLS: ("c", "tui"),
    PTY: ("c", "tui-real-terminal"),
    PTY45: ("c", "tui-real-terminal"),
    GPUIP: ("c", "gpui-shell"),
    RESOLUTION: ("c", "tui"),
    SRCWIN: ("c", "vm-unit"),
    LAYOUT_GATE: ("gate", "remedy: just generate-default-layout"),
    TOKENS_GATE: ("gate", "STALE:"),
    # The real desktop, filtered to the first-run case (a regex without
    # spaces: `just` word-splits the arguments it forwards to Playwright).
    DESKTOP_GATE: ("electron", "first.run.opens.the.shared.default"),
    LEXERS: ("c", "tui"),
    ISOLATE: ("c", "tui-real-terminal"),
    VCSUNIT: ("c", "vm-unit"),
    VCSPTY: ("c", "tui-real-terminal"),
    INTERACT: ("c", "vm-unit"),
    DROPPTY: ("c", "tui-real-terminal"),
    GESTURES: ("c", "gpui-shell"),
    GEDITOR: ("c", "gpui-shell"),
    GCALLS: ("c", "gpui-shell"),
    GVCSR: ("c", "gpui-shell"),
    MONARCH_GATE: ("gate", "is not what scripts/monarch-languages.mjs generates"),
}
BINARY_SUITES = {PTY, PTY45, ISOLATE, VCSPTY, DROPPTY}
  # graded against a REBUILT codetracer-tui
GPUI_BINARY_SUITES = {GPUIP}
  # read the plan of a REBUILT codetracer-gpui (`just build-gpui`)
UNISOLATED_SUITES = {ISOLATE}
  # run WITHOUT the harness's state variables, HOME a throwaway (see S1)

CONTROL_HASHES = HERE / "plat47-parity-mutation-control.sha256"
SUITE_TIMEOUT = int(os.environ.get("CT_P47_SUITE_TIMEOUT", "2400"))
SHIM = Path(os.environ.get("ISONIM_GPUI_SHIM_DIR", str(ROOT.parent / "isonim-gpui/rust/target/debug")))
RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*\s*(.*?)\s*$")

# --- the killer cases, spelled once ------------------------------------------
C_DERIVE = "the desktop's Debug-mode derivation generates the committed default"
C_TOKENS = "every generated rule token is the theme file's rule, per mode"
C_ROLES = "every syntax and editor role paints a generated editor-theme token"
C_COLOURS = "the editor's colours equal the desktop's"
C_SESSION = ("a real session: the trace's calls, the current call marked, "
             "FILES filled")
C_LATER = "at a later stop the current call is the one the debugger is in"
C_FALLBACK = ("no call trace: the pane shows the call stack and says so, in "
              "both front-ends")
C_STRIP = "no rule, no brackets; the active tab differs by colour and weight"
C_MONO = "in monochrome the active tab is reverse video and bold, and unique"
C_RING = ("every pane in turn, at the three sizes: a closed ring in the "
          "desktop's colour")
C_GCHROME = "the tab strip and the focus outline are the desktop's"
C_MODE = "PLAT-46: the mode comes from --theme, then OSC 11, then COLORFGBG"
C_FOLLOW = "the execution pointer is NOT the caret, and has its own follow"
C_SIZES = "the three old §3.2 sizes: the shared default, folded only at 80x24"
G_LAYOUT = "gate:" + LAYOUT_GATE
G_TOKENS = "gate:" + TOKENS_GATE
G_DESKTOP = "gate:" + DESKTOP_GATE
C_PAGES = "a trace longer than any section: scrolling loads the rest"
C_CHARS = "every character of calc has the desktop's colour, in both themes"
C_MEASURED = ("the generated editor colours are the desktop's MEASURED ones, "
              "in both themes")

# part B
C_LEX_TYPES = "every character has the desktop's token type"
C_LEX_LANGS = ("the capture covers one sample per language, each tokenised "
               "in its Monaco language")
C_DOCWINDOW = ("a calc window that starts inside the module docstring is "
               "coloured as the desktop colours it")
C_CONTEXTS = ("each held line keeps the context it was fetched with, through "
              "scrolls both ways")
C_ISOLATED = "this process was isolated before any suite code ran"
C_VCS_READS = "the reader handles every kind of line git emits"
C_VCS_PTY = "the VCS pane lists the desktop's rows for a real repository"
C_GVCS = ("deliverable 4: the VCS pane over a real repository equals the "
          "desktop's VCS panel")
C_INDICATION = ("every hovered drop maps to the region it would occupy, with "
                "no measurement")
C_DROP_PTY = ("each drop kind tints exactly its region, glyphs kept; release "
              "commits, Esc cancels")
C_G_SPLIT = "a split: the half of the target pane on the drop's side"
C_G_ESC = ("Esc cancels: nothing is indicated and the committed layout is the "
           "start")
C_G_HIT = ("the hit-test: a tab, the strip past the tabs, the four bands, the "
           "centre, the margins")
C_G_DIVIDER = ("a divider dragged 80 px moves its pane's edge 80 px, live and "
               "committed")
C_G_B1 = "B1: the editor's colours are the desktop's Monaco colours, class by class"
C_G_DOC = "a window opening inside the docstring colours it as a string"
C_G_PAGES = ("scrolled to the end the last call is listed; back at the top, "
             "the first")
C_G_TITLE = "B3: the call trace's title counts the whole trace"
G_MONARCH = "gate:" + MONARCH_GATE
C_VCS_REFRESH = ("a periodic re-read moves the pane's value exactly when the "
                 "repository moved")
C_G_VCS_REFRESH = ("a re-read picks up another program's changes and reports "
                   "them once")
C_G_DOCKED = "the docked pane leaves the tree and gets a label in the left strip"
C_G_REVEAL = ("a click on the label reveals the pane over the tree; a second "
              "click hides it")
C_G_DISMISS = ("Esc, or a press outside the revealed pane, hides it; the layout "
               "never moved")
C_G_ROWS = ("the editor's fetch window is the rows its pane shows at the row "
            "pitch")
C_EDITOR_LANG = ("the desktop's editor opens every sample in the language the "
                 "terminal lexes it as")

CASE_SUITE = {
    C_DERIVE: VMJS, C_TOKENS: THEME, C_ROLES: THEME, C_COLOURS: PTY,
    C_SESSION: CALLS, C_LATER: CALLS, C_FALLBACK: CALLS, C_STRIP: PTY,
    C_MONO: PTY, C_RING: PTY, C_GCHROME: GPUIP, C_MODE: RESOLUTION,
    C_FOLLOW: SRCWIN, C_SIZES: PTY45,
    G_LAYOUT: LAYOUT_GATE, G_TOKENS: TOKENS_GATE, G_DESKTOP: DESKTOP_GATE,
    C_PAGES: CALLS, C_CHARS: THEME, C_MEASURED: THEME,
    # part B
    C_LEX_TYPES: LEXERS, C_LEX_LANGS: LEXERS, C_DOCWINDOW: THEME,
    C_CONTEXTS: SRCWIN, C_ISOLATED: ISOLATE, C_VCS_READS: VCSUNIT,
    C_VCS_PTY: VCSPTY, C_GVCS: GPUIP,
    C_INDICATION: INTERACT, C_DROP_PTY: DROPPTY, C_G_SPLIT: GESTURES,
    C_G_ESC: GESTURES, C_G_HIT: GESTURES, C_G_DIVIDER: GESTURES,
    C_G_B1: GPUIP, C_G_DOC: GEDITOR, C_G_PAGES: GCALLS, C_G_TITLE: GPUIP,
    G_MONARCH: MONARCH_GATE,
    C_VCS_REFRESH: VCSUNIT, C_G_VCS_REFRESH: GVCSR, C_G_DOCKED: GESTURES,
    C_G_REVEAL: GESTURES, C_G_DISMISS: GESTURES, C_G_ROWS: GESTURES,
    C_EDITOR_LANG: LEXERS,
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
      # Further (path, find, replace) edits made WITH this one — an arm whose
      # defect spans two files (W1).

    def edits(self):
        return [(self.path, self.find, self.replace), *self.also]


ARMS = [
    # --- the shared default is the desktop's Debug layout ----------------------
    Arm("G1", DESK,
        "    if free > 0.0 and free < 100.0: round(free)\n",
        "    if free > 0.0 and free < 100.0: round(free) + 5.0\n",
        G_LAYOUT,
        "the inverse translation gives the editor another share than the "
        "desktop's runtime: the committed shared default is stale"),
    Arm("G2", FRONT,
        "  of DebugMode, CalltraceLayoutMode:\n    @[\n"
        "      @[ord(Content.TestResults), ord(Content.Filesystem)]\n    ]",
        "  of DebugMode, CalltraceLayoutMode:\n    @[]",
        C_DERIVE,
        "the desktop's Debug layout no longer nests TESTS into FILES: the "
        "shared default no longer is what the desktop derives"),
    Arm("G3", FRONT,
        "    @[ord(Content.Constraints)]\n  of EditMode",
        "    @[]\n  of EditMode",
        C_DERIVE,
        "the Debug default places CONSTRAINTS again: the derivation and the "
        "committed shared default part"),
    Arm("G4", GENERATED,
        '      "weight": 20.0,\n',
        '      "weight": 30.0,\n',
        G_LAYOUT,
        "the generated shared default edited by hand"),
    # --- one editor theme ----------------------------------------------------
    Arm("T1", TOKENS,
        '    dtEditorThemeRuleKeyword: ["#5a9dd4", "#56a3e8"],',
        '    dtEditorThemeRuleKeyword: ["#ff79c6", "#56a3e8"],',
        C_TOKENS,
        "a generated editor token no longer the theme file's rule (Dracula's "
        "keyword back)"),
    Arm("T2", ROLES,
        "    srSurfaceEditor: fgbg(dgSurface, dtEditorThemeRuleDefault,\n"
        "                          dtEditorThemeGround, baseSurface = true),",
        "    srSurfaceEditor: fgbg(dgSurface, dtEditorThemeRuleDefault,\n"
        "                          dtColorsUiSurfaceBaseCanvas, baseSurface = true),",
        C_ROLES,
        "the editor surface bound to a design-system token instead of the "
        "editor theme's ground"),
    Arm("T3", EDTHEME,
        '    tcKeyword: "keyword",\n',
        '    tcKeyword: "type",\n',
        C_COLOURS,
        "the class -> scope table maps keywords to another Monaco scope: the "
        "real terminal's keyword is not the desktop's"),
    Arm("T4", EMITTER,
        "        if key in rules:\n            return rules[key]\n",
        "        if key in rules:\n            return rules[\"\"]\n",
        G_TOKENS,
        "the emitter resolves every scope to the default rule: the committed "
        "tokens are no longer what it generates"),
    Arm("L1", GUTTER,
        "      # lifted to the label tier, as Monaco's `.active-line-number` is.\n"
        "      ActiveLineNumberStyle\n",
        "      # lifted to the label tier, as Monaco's `.active-line-number` is.\n"
        "      lineNumberStyle(spec.provenance)\n",
        C_COLOURS,
        "the stop's line number painted as a resting one"),
    # --- FILES and the call trace ---------------------------------------------
    Arm("F1", SESSION,
        "    rt.app.fileTree = s.files\n",
        "    discard s.files\n",
        C_SESSION,
        "the interactive path never fills FILES (the pane was empty before)"),
    Arm("C1", SESSION,
        "  initCallTraceModel(rows, s.session.getCurrentRRTicks(), s.callTraceStack,",
        "  initCallTraceModel(@[], s.session.getCurrentRRTicks(), s.callTraceStack,",
        C_SESSION,
        "the calltrace pane is never handed the trace: it shows the stack"),
    Arm("C4", CTVIEW,
        "    if stack.len > 0 and r.name == stack[0] and r.depth == stack.len - 1:\n"
        "      result.current = i\n",
        "    discard\n",
        C_LATER,
        "the current call ignores the stack: no row is marked at a stop "
        "inside a call"),
    Arm("C3", PANEVIEWS,
        '      " #" & $line.index\n',
        '      ""\n',
        C_SESSION,
        "GPUI's calltrace rows lose the desktop's `#index`"),
    Arm("C2", SHELL,
        "        paintFallbackCaption(g, content)\n",
        "        discard content\n",
        C_FALLBACK,
        "the terminal's stack fallback no longer says it is one"),
    Arm("C5", NATIVE,
        "  vm.fallbackStack.val = names\n",
        "  vm.fallbackStack.val = newSeq[string]()\n",
        C_FALLBACK,
        "GPUI's calltrace VM is never handed the stack when there is no trace"),
    # --- tab strips -----------------------------------------------------------
    Arm("B1", TABSTRIP,
        '  ActiveTabOpen* = " "\n  ActiveTabClose* = " "\n',
        '  ActiveTabOpen* = "["\n  ActiveTabClose* = "]"\n',
        C_STRIP,
        "the active tab bracketed again"),
    Arm("B2", TABSTRIP,
        "  fitCells(line, width)\n",
        "  while line.len < width * 3:\n    line.add PaneRuleGlyph\n"
        "  fitCells(line, width)\n",
        C_STRIP,
        "a rule drawn through the strip again"),
    Arm("B4", ROLES,
        "    srTabActive: fgbg(dgTab, dtColorsUiTextPrimaryHeadings,",
        "    srTabActive: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,",
        C_STRIP,
        "the active tab painted in the inactive tabs' foreground"),
    Arm("B3", ROLES,
        "                      mono = {raBold, raReverse}),\n    srTabInactive:",
        "                      mono = {raBold}),\n    srTabInactive:",
        C_MONO,
        "in monochrome the active tab loses its reverse video"),
    # --- focus -----------------------------------------------------------------
    Arm("K1", ROLES,
        "    srBorderFocused: fgOnly(dgBorder, dtColorsUiBorderPrimary,",
        "    srBorderFocused: fgOnly(dgBorder, dtColorsUiBorderFocus,",
        C_RING,
        "the focus ring back on the design system's `border/focus` instead of "
        "the desktop's measured outline"),
    Arm("K2", SHELL,
        "  for col in left .. right:\n    result.incl (top, col)\n"
        "    result.incl (bottom, col)\n",
        "  for col in left .. right:\n    result.incl (bottom, col)\n",
        C_RING,
        "the ring leaves out the edge a neighbour draws (the reported defect)"),
    Arm("K3", SHELL,
        "    rightDivider: right, bottomDivider: bottom)",
        "    rightDivider: right, bottomDivider: false)",
        C_RING,
        "no divider row under a pane: the ring cannot close at the bottom"),
    Arm("K4", CHROME,
        "     chromeOf(if focused: crFocusOutline else: crWindowBackground))]",
        "     chromeOf(if focused: crWindowBackground else: crWindowBackground))]",
        C_GCHROME,
        "GPUI's focused region bordered in the window background: no outline"),
    Arm("K5", CHROME,
        '    @[("color", chromeOf(crTabActiveForeground)), ("font-weight", "bold"),\n',
        '    @[("color", chromeOf(crTabActiveForeground)),\n',
        C_GCHROME,
        "GPUI's active tab loses its weight"),
    # --- the user's two decisions ----------------------------------------------
    Arm("A1", CAPS,
        "const AutoDetectSelectsLight* = false",
        "const AutoDetectSelectsLight* = true",
        C_MODE,
        "a light terminal background selects Light again"),
    Arm("V1", SOURCEVM,
        "    clampTop(line - (viewportHeight - 1) div 2, viewportHeight,",
        "    clampTop(line - (viewportHeight - 1), viewportHeight,",
        C_FOLLOW,
        "a jump scrolls the least it can: the stop lands on the last row"),
    Arm("N1", CELLS,
        '  of paneTestResults: "Tests"\n',
        '  of paneTestResults: "Test Results"\n',
        C_SIZES,
        "TESTS captioned otherwise than the desktop's"),
]

ARMS += [
    # --- the execution band ------------------------------------------------------
    Arm("X1", SRCPANE,
        "      g.restyle(row, codeCol, area.col + area.width - codeCol,\n",
        "      g.restyle(row, codeCol, min(12, area.col + area.width - codeCol),\n",
        C_COLOURS,
        "the execution band ends a few cells in, as CTUI-5's text-length band "
        "did, instead of reaching the pane's right edge like Monaco's"),
    Arm("X2", SRCPANE,
        "      g.restyle(row, codeCol, area.col + area.width - codeCol,\n",
        "      g.restyle(row, area.col, area.width,\n",
        C_COLOURS,
        "the band covers the gutter too, where the desktop draws none"),
    # --- the call trace pages ----------------------------------------------------
    Arm("P1", SESSION,
        "  if top >= first and last <= first + model.rows.len:\n    return\n",
        "  if true:\n    return\n",
        C_PAGES,
        "the pane never loads a section past the first: the trace ends where "
        "the open-time section ended"),
    Arm("P2", SESSION,
        "      startIndex = start.int64, height = body + 2 * CallTraceBuffer,\n",
        "      startIndex = 0'i64, height = body + 2 * CallTraceBuffer,\n",
        C_PAGES,
        "a page request always reads the trace's head, not the rows scrolled to"),
    # P3 (the title counts the whole trace, not the loaded section) retired
    # by PLAT-49: a pane has no title row in the terminal any more — the tab
    # strip names it, as the desktop's GoldenLayout header does — so the
    # count is drawn nowhere a user can read it. Nor does the desktop draw
    # one: its call trace uses `totalCallsCount` only to size the scroll
    # extent (`isonim_calltrace_view`, `.local-calltrace` at count x row
    # height), never as text, so there is no place on the desktop for the
    # terminal's count to match. The whole-trace count still drives the
    # paging P1, P2 and P4 grade.
    Arm("P4", RUNTIME,
        "    let idx = geometry.regionIndexAt(event.row, event.col)\n"
        "    if idx >= 0 and geometry.projection.regions[idx].pane == paneCalltrace and\n",
        "    let idx = geometry.regionIndexAt(event.row, event.col)\n"
        "    if idx >= 0 and geometry.projection.regions[idx].pane == paneEditor and\n",
        C_PAGES,
        "the wheel over the call trace's body scrolls nothing"),
    # --- every language, tokenised as the desktop's Monaco tokenizer ----------
    Arm("Y1", LEXER,
        "                       endCell: cellOffsetAtByte(line, min(stop, line.len)),\n",
        "                       endCell: cellOffsetAtByte(line, t.start + 1),\n",
        C_CHARS,
        "a token's span ends after its first character: the rest of every "
        "token is drawn in the default colour"),
    Arm("M1", MONARCH,
        "          stack.setLen(stack.len - 1)\n        of \"@popall\":",
        "          discard\n        of \"@popall\":",
        C_LEX_TYPES,
        "the tokenizer never pops a state: a string or a comment never ends"),
    Arm("M2", JSREGEX,
        "    hit xor n.negated\n",
        "    hit\n",
        C_LEX_TYPES,
        "a negated character class matches what it excludes"),
    Arm("M3", LEXICAL,
        '  (".ts", lxTypeScript),',
        '  (".ts", lxJavaScript),',
        C_LEX_LANGS,
        "TypeScript lexed by the JavaScript tokenizer, where the desktop uses "
        "Monaco's typescript definition"),
    Arm("M4", MONARCH_JSON,
        '"pass","print","raise"',
        '"pass","raise"',
        G_MONARCH,
        "the generated Monarch definitions edited by hand (Python's `print` "
        "no longer a keyword)"),
    Arm("M5", LEXICAL,
        "    if i >= firstLine:\n      result.add context\n",
        "    if i >= firstLine:\n      result.add initialContext(lexer)\n",
        C_DOCWINDOW,
        "every window line starts in the tokenizer's initial state: a window "
        "opening inside a docstring colours it as code"),
    Arm("M6", SOURCEVM,
        "    vm.heldLineContexts.val = @[]\n    vm.heldFirstLine.val = 1\n",
        "    vm.heldFirstLine.val = 1\n",
        C_CONTEXTS,
        "a discarded window keeps its line contexts: the next window's lines "
        "are coloured from another window's states"),
    # --- tests never touch the user's state -----------------------------------
    Arm("S1", ISOLATION,
        "  isolate()\n  addExitProc(cleanup)\n",
        "  addExitProc(cleanup)\n",
        C_ISOLATED,
        "the forced import isolates nothing: a suite run outside the lane "
        "runner writes into the user's own state directory"),
    # --- the VCS pane ------------------------------------------------------------
    Arm("Q1", VCSPARSE,
        '    elif line.startsWith("? "):\n',
        '    elif line.startsWith("?? "):\n',
        C_VCS_READS,
        "untracked files are never read out of git's status"),
    Arm("Q2", VCSVM,
        "  let staged = letter(change.indexStatus)\n"
        "  if staged.len > 0: staged else: letter(change.workingTreeStatus)\n",
        "  let staged = letter(change.indexStatus)\n"
        "  let unstaged = letter(change.workingTreeStatus)\n"
        "  if unstaged.len > 0: unstaged else: staged\n",
        C_VCS_READS,
        "an added file edited after staging shows as modified, not added"),
    Arm("Q3", PANEVIEWS,
        'label: f.status & " " & f.path)',
        'label: f.path)',
        C_GVCS,
        "GPUI's VCS rows lose their state letters"),
    Arm("Q4", VCSPANE,
        "           StyledSpan(text: f.status, style: statusStyle(f.status)),",
        "           StyledSpan(text: \" \", style: statusStyle(f.status)),",
        C_VCS_PTY,
        "the terminal's VCS rows lose their state letters"),
    Arm("Q5", VCSSOURCE,
        "  s.vm.refreshFromFacade(s.facade, s.directory)\n",
        "  discard s.directory\n",
        C_VCS_PTY,
        "the terminal never reads the repository: the pane stays empty"),
    # --- the drop indication ----------------------------------------------------
    Arm("O1", INTERACTION,
        "      of saRow: (if t.kind == dtSplitBefore: leLeft else: leRight)\n",
        "      of saRow: (if t.kind == dtSplitBefore: leRight else: leLeft)\n",
        C_INDICATION,
        "the model names the wrong half: a split right indicates the left"),
    Arm("O2", BINDING,
        "    (tint: halfOf(geom.dropAreaOfPath(ind.path), ind.side), caret: CellArea())\n",
        "    (tint: geom.dropAreaOfPath(ind.path), caret: CellArea())\n",
        C_DROP_PTY,
        "the terminal tints the whole pane for a split, not the half it takes"),
    Arm("O3", FRAMEOVERLAY,
        "  OverlaySpec(top: o.row, left: o.col, width: o.width, height: o.height,\n",
        "  OverlaySpec(top: o.row, left: o.col, width: o.width + 1, height: o.height,\n",
        C_DROP_PTY,
        "the terminal's overlay rectangle one cell wider than the region"),
    Arm("O4", ISONIM_TUI_OVERLAY,
        "  let bottom = min(buf.rowsCount, spec.top + max(0, spec.height))\n",
        "  let bottom = min(buf.rowsCount, spec.top + max(0, spec.height) div 2)\n",
        C_DROP_PTY,
        "isonim-tui's overlay re-colours only the upper half of its rectangle"),
    Arm("O5", WINGEOM,
        "    (tint: halfOf(g.dropAreaOf(ind.path), ind.side), caret: PxRect())\n",
        "    (tint: g.dropAreaOf(ind.path), caret: PxRect())\n",
        C_G_SPLIT,
        "GPUI tints the whole pane for a split"),
    Arm("O6", WINGEST,
        "  g.interaction = cancel(g.interaction)\n  g = g.idleKeepingReveal()\n",
        "  discard\n",
        C_G_ESC,
        "Esc leaves GPUI's drag in flight, its drop still indicated"),
    Arm("O7", WINGEOM,
        "    best = dl\n    zone = dzLeftEdge\n",
        "    best = dl\n    zone = dzRightEdge\n",
        C_G_HIT,
        "GPUI's left edge band hit-tests as the right one"),
    # --- GPUI's divider drag ----------------------------------------------------
    Arm("R1", WINGEOM,
        "  let content = axisPos - d.start - d.index * ChromeGapPx\n",
        "  let content = axisPos - d.start - d.index * ChromeGapPx + ChromeGapPx\n",
        C_G_DIVIDER,
        "the pointer's fraction measured a gap off: the divider lands 8 px "
        "from where it was dropped"),
    Arm("R2", WINGEST,
        "  if g.kind != gkResize:\n    return layout\n",
        "  if true:\n    return layout\n",
        C_G_DIVIDER,
        "no live preview: the window shows the old split until the release"),
    Arm("R3", WINGEST,
        "  let d = geom.dividerAt(x, y)\n",
        "  let d = -1\n",
        C_G_DIVIDER,
        "a press on a divider is not hit-tested as one: nothing resizes"),
    # --- GPUI's editor (B1) -----------------------------------------------------
    Arm("H1", LEAVES,
        "  DesignTokenHex[tokenClassToken(cls)][dmDark]\n",
        "  DesignTokenHex[tokenClassToken(tcPlain)][dmDark]\n",
        C_G_B1,
        "every GPUI code run painted the default colour"),
    Arm("H2", LEAVES,
        "    r.setStyle(column, \"background\", ExecutionRowBand)\n",
        "    r.setStyle(el, \"background\", ExecutionRowBand)\n",
        C_G_B1,
        "GPUI's band under the whole row, gutter included (the old `.on` band)"),
    Arm("H3", LEAVES,
        "  var context = if surface.entryContext.len > 0: surface.entryContext\n"
        "                else: initialContext(lexer)\n",
        "  var context = initialContext(lexer)\n",
        C_G_DOC,
        "GPUI ignores the window's entry state: a window inside a docstring "
        "is coloured as code"),
    Arm("H4", LEAVES,
        "             if row.pointer == eptExecution: EditorActiveLineNumberColour\n"
        "             else: EditorLineNumberColour)\n",
        "             EditorLineNumberColour)\n",
        C_G_B1,
        "GPUI's execution line number painted as a resting one"),
    # --- GPUI's border (B2) -----------------------------------------------------
    Arm("K6", CHROME,
        '  @[("border-width", $FocusOutlinePx & "px"),\n',
        '  @[("border-width", "0px"),\n',
        C_GCHROME,
        "GPUI's panes carry no border: the outline is not drawn at all"),
    # --- GPUI's call trace (B3) --------------------------------------------------
    Arm("P5", GPUIHOST,
        "  if result.top >= first and last <= first + held:\n    return\n",
        "  if true:\n    return\n",
        C_G_PAGES,
        "GPUI never reads a section past the first"),
    Arm("P6", GPUIHOST,
        "    session.requestAndLoadCalltrace(startIndex = int64(start),\n",
        "    session.requestAndLoadCalltrace(startIndex = 0'i64,\n",
        C_G_PAGES,
        "GPUI's page request always reads the trace's head"),
    Arm("P7", GPUIMAIN,
        '    (if total > 0: " " & $total & " call(s)" else: "")\n',
        '    ""\n',
        C_G_TITLE,
        "GPUI's call-trace title does not count the trace"),
    # --- the light theme, measured ----------------------------------------------
    Arm("W1", WHITE,
        '    "executionLine": "#c5ca88",\n',
        '    "executionLine": "#c5ca87",\n',
        C_MEASURED,
        "the light execution line back to the value COMPOSED from the theme's "
        "rules, not the one the desktop renders",
        also=((TOKENS,
               '    dtEditorThemeExecutionLine: ["#404040", "#c5ca88"],\n',
               '    dtEditorThemeExecutionLine: ["#404040", "#c5ca87"],\n'),)),
    # --- the VCS pane refreshes --------------------------------------------------
    Arm("U1", VCSVM,
        '  for f in vm.workingTreeFiles.val:\n    result.add "\\x1e" & f.status & " " & f.path\n',
        '  discard\n',
        C_VCS_REFRESH,
        "the pane's value is blind to the working tree: a file another "
        "program writes never redraws the pane"),
    Arm("U2", GPUIHOST,
        "  vm.refreshFromFacade(nativeVcs(NativeVcsProfile), directory)\n"
        "  vm.workingStateKey() != before\n",
        "  discard directory\n"
        "  vm.workingStateKey() != before\n",
        C_G_VCS_REFRESH,
        "GPUI's tick re-reads nothing: the pane keeps the state it opened with"),
    # --- a pane docked in GPUI stays on screen ------------------------------------
    Arm("D1", WINGEOM,
        "    has[edge] = layout.dockedAt(edge).len > 0\n",
        "    has[edge] = false\n",
        C_G_DOCKED,
        "GPUI draws no strips: a pane docked by a drop disappears"),
    Arm("D2", WINGEST,
        "        let shown = beginReveal(layout, was.source)\n",
        "        let shown = none(Interaction)\n",
        C_G_REVEAL,
        "a click on a docked pane's label reveals nothing"),
    Arm("D3", WINGEST,
        "    g.reveal = noInteraction()\n    dismissed = true\n",
        "    dismissed = true\n",
        C_G_DISMISS,
        "a press outside the revealed pane leaves it over the tree"),
    # --- GPUI's editor rows are whole lines ---------------------------------------
    Arm("D4", WINGEOM,
        "  max(1, (h - 2 * ChromePaddingPx - EditorLinesAbovePx) div GpuiEditorRowPx)\n",
        "  max(1, g.viewport.h div 20)\n",
        C_G_ROWS,
        "the fetch window counted from the WINDOW's height at a nominal 20 px "
        "again: more rows than the pane shows, each squeezed"),
    # --- the desktop's editor languages -------------------------------------------
    Arm("E2", DIFFDOC,
        "  if extension.len > 0 and extension notin EditorPlainExtensions:\n",
        "  if false:\n",
        C_EDITOR_LANG,
        "the desktop's editor takes the recording language's name only: "
        "`.ts`, `.java`, `.sh`, `.json` and `.yaml` open uncoloured"),
    Arm("E3", DIFFDOC,
        "  if extension.len > 0 and extension notin EditorPlainExtensions:\n",
        "  if extension.len > 0:\n",
        C_EDITOR_LANG,
        "the desktop's editor colours TOML with the `ini` approximation the "
        "terminal and GPUI do not draw"),
    # --- the desktop's first run ---------------------------------------------------
    Arm("E1", DESKCONFIG,
        "    else:\n      modeDefaultLayout(bundled, mode)\n",
        "    else:\n      bundled\n",
        G_DESKTOP,
        "the desktop's first run installs the raw bundled tree (a TEST "
        "RESULTS / CONSTRAINTS column no mode draws) instead of the Debug-mode "
        "default"),
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
    # before PLAT-47 would be read by every suite that spawns the product).
    state = Path(tempfile.gettempdir()) / f"plat47-mutation-state-{os.getuid()}"
    state.mkdir(parents=True, exist_ok=True)
    env["CODETRACER_TUI_LAYOUT_DIR"] = str(state)
    env["XDG_STATE_HOME"] = str(state)
    return env


def artefacts_for(path: str) -> tuple:
    stem = Path(path).stem
    base = Path(tempfile.gettempdir()) / f"plat47-mutation-{os.getuid()}"
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
    try:
        proc = subprocess.run(["bash", path, "-g", grep], cwd=ROOT,
                              capture_output=True, text=True,
                              timeout=SUITE_TIMEOUT, encoding="utf-8",
                              errors="replace", env=env)
    except subprocess.TimeoutExpired:
        return RunResult(rc=1, ran=False, hung=True)
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


def run_one(path: str, case: str | None = None) -> RunResult:
    backend, lane = SUITE_KIND[path]
    if backend == "gate":
        return run_gate(path, lane)
    if backend == "electron":
        return run_electron(path, lane)
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
                env["HOME"] = tempfile.mkdtemp(prefix="plat47-s1-home-")
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


def build_for(suite: str) -> bool:
    """Rebuild the binary a suite grades, if it grades one."""
    if suite in BINARY_SUITES:
        return build_tui()
    if suite in GPUI_BINARY_SUITES:
        return build_gpui()
    return True


_ACTIVE: list | None = None


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
            if not (ROOT / where).is_file():
                print(f"GATE ABSENT: {where}")
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
    `isonim-tui` subject lives wherever `$ISONIM_TUI_SRC` points (a pin
    worktree, a plain `../isonim-tui` checkout, CI's clone), so it is named
    relative to that source root, `isonim-tui/src/...`: an absolute path
    would make the committed control unreadable on every other checkout,
    while the digest still pins the exact bytes graded."""
    p = Path(path)
    if p.is_absolute():
        try:
            return "isonim-tui/src/" + p.relative_to(ISONIM_TUI_SRC_DIR).as_posix()
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
            print(f"CONTROL DIGEST MOVED: {p} — re-run --needle-scan BEFORE "
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
            if not build_for(suite):
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
                    return 2
            if not build_for(suite):
                print("the restored tree's binary does not build")
                return 2
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

    print(f"\n{killed}/{len(wanted)} killed, {problems} problem(s)")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
