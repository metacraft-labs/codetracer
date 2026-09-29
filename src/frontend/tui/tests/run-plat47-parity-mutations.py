#!/usr/bin/env python3
"""PLAT-47 (part A) — the mutation harness for the terminal and GPUI
front-ends at desktop parity: the shared default generated from the desktop's
Debug layout, one editor theme, the FILES and calltrace panes, tab strips
shaped by colour and weight, the closed focus outline, the Dark-only
auto-detection and the centred jump.

    python3 src/frontend/tui/tests/run-plat47-parity-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=T3,K2

Run from the repository root, inside the dev shell, with `REPLAY_SERVER_BIN`
exported (the call-trace suite and the real-PTY suites open the real `calc`
recording), after `just plat47-capture-electron` (the real-PTY suite compares
with the desktop's committed capture). The GPUI suite loads
`libgpui_nim_shim`; the harness puts the shim on `LD_LIBRARY_PATH` itself.

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
  | the call trace pages: the section around the rows shown is loaded | P1, P2, P3, P4 |
  | Python is tokenised as the desktop's Monaco tokenizer, character by character | Y1, Y2, Y3 |
  | the light editor colours are the desktop's MEASURED light ones | W1 |
  | the desktop's first run installs the Debug-mode default | E1 |

E1 IS GRADED BY THE REAL ELECTRON APP: `scripts/plat45-capture-electron.sh`
compiles this checkout's desktop JavaScript (the mutated `index/config.nim`
included) into a prefix and runs
`src/tests/gui/tests/layout/plat45-desktop-remembers-own.spec.ts`, filtered to
its first-run case. It needs Xvfb (started when no display is set) and the
built frontend `just build-once` leaves.

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
the restored tree afterwards.

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

# --- suites and gates ---------------------------------------------------------
VMJS = "src/frontend/viewmodel/tests/unit/test_shared_default_layout.nim"
THEME = "src/frontend/tui/tests/test_plat47_editor_theme.nim"
CALLS = "src/frontend/tui/tests/test_plat47_call_trace.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat47_desktop_parity.nim"
PTY45 = "src/frontend/tui/tests/real_terminal/test_real_plat45_layout.nim"
GPUIP = "src/frontend/gpui/tests/test_plat47_gpui_parity.nim"
RESOLUTION = "src/frontend/tui/app/tests/test_capability_resolution.nim"
SRCWIN = "src/frontend/viewmodel/tests/unit/test_source_vm_window.nim"
LAYOUT_GATE = "ci/test/default-layout-fresh.sh"
TOKENS_GATE = "ci/test/design-tokens-fresh.sh"
DESKTOP_GATE = "scripts/plat45-capture-electron.sh"

SUBJECTS = [DESK, FRONT, GENERATED, TOKENS, EMITTER, ROLES, EDTHEME, GUTTER,
            SESSION, NATIVE, SHELL, CTVIEW, PANEVIEWS, TABSTRIP, CHROME, CAPS,
            SOURCEVM, CELLS, SRCPANE, RUNTIME, LEXER, WHITE, DESKCONFIG]
SUITES = [VMJS, THEME, CALLS, PTY, PTY45, GPUIP, RESOLUTION, SRCWIN,
          LAYOUT_GATE, TOKENS_GATE, DESKTOP_GATE]
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
}
BINARY_SUITES = {PTY, PTY45}   # graded against a REBUILT codetracer-tui

CONTROL_HASHES = HERE / "plat47-parity-mutation-control.sha256"
SUITE_TIMEOUT = int(os.environ.get("CT_P47_SUITE_TIMEOUT", "2400"))
SHIM = ROOT.parent / "isonim-gpui/rust/target/debug"
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

CASE_SUITE = {
    C_DERIVE: VMJS, C_TOKENS: THEME, C_ROLES: THEME, C_COLOURS: PTY,
    C_SESSION: CALLS, C_LATER: CALLS, C_FALLBACK: CALLS, C_STRIP: PTY,
    C_MONO: PTY, C_RING: PTY, C_GCHROME: GPUIP, C_MODE: RESOLUTION,
    C_FOLLOW: SRCWIN, C_SIZES: PTY45,
    G_LAYOUT: LAYOUT_GATE, G_TOKENS: TOKENS_GATE, G_DESKTOP: DESKTOP_GATE,
    C_PAGES: CALLS, C_CHARS: THEME, C_MEASURED: THEME,
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
        "    srTabActive: fgbg(dgTab, dtColorsUiTextPrimaryLabel,",
        "    srTabActive: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,",
        C_STRIP,
        "the active tab painted in the inactive tabs' foreground"),
    Arm("B3", ROLES,
        "                      mono = {raBold, raReverse}, baseSurface = true),",
        "                      mono = {raBold}, baseSurface = true),",
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
        "     chromeOf(if focused: crFocusOutline else: crWindowBackground)),",
        "     chromeOf(if focused: crWindowBackground else: crWindowBackground)),",
        C_GCHROME,
        "GPUI's focused region framed in the window background: no outline"),
    Arm("K5", CHROME,
        '    @[("color", chromeOf(crTabActiveForeground)), ("font-weight", "bold")]',
        '    @[("color", chromeOf(crTabActiveForeground))]',
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
    Arm("P3", CTVIEW,
        '  let count = " " & $m.total & " call(s)"\n',
        '  let count = " " & $m.rows.len & " call(s)"\n',
        C_PAGES,
        "the title counts the loaded section instead of the whole trace"),
    Arm("P4", RUNTIME,
        "    let idx = geometry.regionIndexAt(event.row, event.col)\n"
        "    if idx >= 0 and geometry.projection.regions[idx].pane == paneCalltrace and\n",
        "    let idx = geometry.regionIndexAt(event.row, event.col)\n"
        "    if idx >= 0 and geometry.projection.regions[idx].pane == paneEditor and\n",
        C_PAGES,
        "the wheel over the call trace's body scrolls nothing"),
    # --- Python, tokenised as the desktop's Monaco tokenizer -------------------
    Arm("Y1", LEXER,
        "        emit(3, tcString)\n        push psDocDouble\n",
        "        emit(3, tcString)\n",
        C_CHARS,
        "a docstring is a string only on its first line (the generic "
        "scanner's defect)"),
    Arm("Y2", LEXER,
        "      elif c in {'[', ']'}:                              # @brackets: delimiter.bracket\n"
        "        emit(1, tcBracket)\n",
        "      elif c in {'[', ']'}:                              # @brackets: delimiter.bracket\n"
        "        emit(1, tcPunctuation)\n",
        C_CHARS,
        "square brackets painted as the other delimiters, where the desktop's "
        "dark theme lightens them"),
    Arm("Y3", LEXER,
        '    "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "print",\n',
        '    "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass",\n',
        C_CHARS,
        "`print` no longer a Monaco keyword: calc's output lines read otherwise"),
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


def record_control_hashes() -> int:
    lines = [f"{digest(p)}  {p}" for p in TOUCHED]
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
        if p not in recorded:
            print(f"CONTROL DIGEST ABSENT: {p}")
            ok = False
        elif recorded[p] != digest(p):
            print(f"CONTROL DIGEST MOVED: {p} — re-run --needle-scan BEFORE "
                  "--record-control-hashes (§32)")
            ok = False
    return ok


def main() -> int:
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
            if suite in BINARY_SUITES and not build_tui():
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
            if suite in BINARY_SUITES and not build_tui():
                print("the restored tree's terminal binary does not build")
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
