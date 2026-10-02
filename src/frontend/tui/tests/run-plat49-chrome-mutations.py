#!/usr/bin/env python3
"""PLAT-49 part A — the mutation harness for the user's 2026-10-01 findings on
the terminal and GPUI front-ends' chrome: one root menu button with cascading
submenus (finding 1), a drag only from a tab moved past a threshold (2), no
title row inside a pane (3), tab strips on their own ground with a selected
tab of its own background and foreground (4), the debugger controls' tooltip
from `debug_controls_vm` (5), the omnibar's placeholder and caret from the
Omnibar ViewModel and a DECSCUSR caret in the terminal (6), no key hints on
the status line (10), variable rows tagged with their category instead of
separator rows (12), and dividers on the panes' own ground (13).

    python3 src/frontend/tui/tests/run-plat49-chrome-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=MN1,TC2

Run from the repository root, inside the dev shell, with `REPLAY_SERVER_BIN`
exported (the real-PTY suite and the GPUI plan suite open the real `calc`
recording and step it). The GPUI suites load `libgpui_nim_shim`; the harness
puts `$ISONIM_GPUI_SHIM_DIR` (else `../isonim-gpui/rust/target/debug`) on
`LD_LIBRARY_PATH`. CR1's subject is in the SIBLING `isonim-tui`
(`$ISONIM_TUI_SRC`, else `../isonim-tui/src`) — the terminal binary links it.
DT1 runs the REAL Electron app (`scripts/plat49-capture-electron.sh`, which
compiles this checkout's desktop JavaScript into a prefix); it needs Xvfb
(started when no display is set) and the built frontend `just build-once`
leaves.

ONE ARM PER CLAIM, each naming the case (or the gate) that must die:

  | finding | arms |
  |---|---|
  | 1 menu: one root button, cascades | MN1 (terminal submenu under, not beside), MN2 (terminal submenu not level with its folder), MN3 (terminal Right does not enter), GM1 (GPUI submenu not beside), GM2 (GPUI Right does not enter) |
  | 2 a click is a click | DG1 (no threshold), DG2 (a press picks the tab up), DG3 (a click's report on the status line), DG4 (a divider click resizes) |
  | 3 no title rows | TI1 (the call trace's heading under the strip), TI2 (no strip over a pane), TI3 (GPUI keeps the heading), TI4 (GPUI's bare pane without a strip), TI5 (GPUI's State view titles itself) |
  | 3 a lone editor's tab is its file | ET1 (the terminal's tab names the pane), ET2 (the dirty mark dropped from the shared label), ET3 (GPUI's tab names the pane), ET4 (GPUI's tab never follows the buffer) |
  | 4 tab strips | TC1 (the strip on the body's ground), TC2 (the selected tab on the strip's ground), TC3 (the selected tab in the inactive ink), TC4 (monochrome without reverse), TC5 (GPUI's selected tab without its background), TC6 (GPUI's strip without its ground) |
  | 5 tooltips | TT1 (the key dropped from the tooltip), TT2 (the label table off by one), TT3 (the terminal draws no label), TT4 (GPUI's popover not the ViewModel's) |
  | 6 omnibar | OB1 (another placeholder), OB2 (overwrite inserts), OB3 (the caret does not move), OB4 (the terminal's caret always a block), OB5 (the field on the bar's ground), OB6 (no drawn caret where shapes are unknown), OB7 (GPUI's caret glyphs swapped), CR1 (isonim-tui: the Linux console told it has shapes), DT1 (the desktop's palette words of its own) |
  | 10 key hints | KH1 (a hint strip back on the status line) |
  | 12 variables | VR1 (no tag), VR2 (the wrong category colour), VR3 (two categories one letter), VR4 (separator rows back) |
  | 13 dividers | DV1 (dividers on the canvas), DV2 (dividers in the text ink) |

THREE VERDICTS (Verification-Harness-Traps §1): `killed` (the named case
reported [FAILED], or the named gate failed), `SURVIVED` (the case [OK] / the
gate green), `HARNESS-FAILURE` (the needle was not unique, the suite did not
compile, the mutated binary did not build, or the run printed no result
lines). A run that prints nothing is never a kill.

Every Nim suite is run FILTERED to its killer case (std/unittest's own name
argument), so an arm costs one case rather than a suite; the control run is
unfiltered and must name every killer as [OK].

THE BINARY IS PART OF THE SUBJECT: an arm graded by the real-PTY suite
rebuilds `build/bin/codetracer-tui` with the defect (`just build-tui`), one
graded by the GPUI plan suite rebuilds `build/bin/codetracer-gpui`
(`just build-gpui`), and both again from the restored tree afterwards.

RESTORATION is from an in-memory snapshot, and every touched file's SHA-256
is compared with the pre-run baseline after each arm (§32). The full run
refuses unless the needle scan is clean AND every touched file matches
`plat49-chrome-mutation-control.sha256`. The sibling subject is recorded under
`isonim-tui/src/...`, relative to its source root, so the control reads the
same on every checkout.

NO DECLARED SURVIVORS.

No mocks: every suite graded here runs the product's own ViewModels, the
product's own runtime and shell, a real PTY with the real `calc` recording,
the shipped GPUI binary's window plan, and the real Electron app.
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
TOPBAR = "src/frontend/tui/app/views/top_bar.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
BINDING = "src/frontend/tui/app/layout/binding.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
ROLES = "src/frontend/tui/app/theme/roles.nim"
STATUS = "src/frontend/tui/app/views/status_bar.nim"
VARS = "src/frontend/tui/app/views/variables.nim"
TUIMAIN = "src/frontend/tui/main.nim"
DCVM = "src/frontend/viewmodel/viewmodels/debug_controls_vm.nim"
OMNIVM = "src/frontend/viewmodel/viewmodels/omnibar_vm.nim"
STATEVM = "src/frontend/viewmodel/viewmodels/state_vm.nim"
DESKPALETTE = "src/frontend/viewmodel/views/isonim_command_palette_view.nim"
WINTOP = "src/frontend/gpui/window_top_bar.nim"
WINGEOM = "src/frontend/gpui/window_geometry.nim"
CHROME = "src/frontend/gpui/chrome.nim"
GPUIMAIN = "src/frontend/gpui/main.nim"
PRODMODE = "src/frontend/viewmodel/viewmodels/product_mode.nim"
PANEVIEWS = "src/frontend/view_vocabulary/pane_views.nim"
ISONIM_TUI_SRC_DIR = Path(os.environ.get(
    "ISONIM_TUI_SRC", str(ROOT.parent / "isonim-tui" / "src")))
CARET = str(ISONIM_TUI_SRC_DIR / "isonim_tui" / "caret.nim")

# --- suites and gates ---------------------------------------------------------
VMU = "src/frontend/viewmodel/tests/unit/test_plat49_chrome_models.nim"
T1 = "src/frontend/tui/tests/test_plat49_chrome_shell.nim"
REF = "src/frontend/tui/tests/test_plat49_desktop_reference.nim"
PROF = "src/frontend/tui/app/tests/test_layout_profiles.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat49_chrome.nim"
GPLAN = "src/frontend/gpui/tests/test_plat49_gpui_plan.nim"
DESKTOP_GATE = "scripts/plat49-capture-electron.sh"

SUBJECTS = [TOPBAR, SHELL, BINDING, RUNTIME, ROLES, STATUS, VARS, TUIMAIN,
            DCVM, OMNIVM, STATEVM, DESKPALETTE, WINTOP, WINGEOM, CHROME,
            GPUIMAIN, PRODMODE, PANEVIEWS, CARET]
SUITES = [VMU, T1, REF, PROF, PTY, GPLAN, DESKTOP_GATE]
TOUCHED = SUBJECTS + SUITES

# How each suite is run: (backend, lane whose `--path`s it needs).
SUITE_KIND = {
    VMU: ("c", "vm-unit"),
    T1: ("c", "tui"),
    REF: ("c", "tui"),
    PROF: ("c", "tui"),
    PTY: ("c", "tui-real-terminal"),
    GPLAN: ("c", "gpui-shell"),
    # The real desktop, filtered to its one case (a regex without spaces:
    # `just` word-splits the arguments it forwards to Playwright).
    DESKTOP_GATE: ("electron", "root.menu"),
}
BINARY_SUITES = {PTY}
  # graded against a REBUILT codetracer-tui
GPUI_BINARY_SUITES = {GPLAN}
  # read the WINDOW's render plan of a REBUILT codetracer-gpui
UNISOLATED_SUITES: set = set()

CONTROL_HASHES = HERE / "plat49-chrome-mutation-control.sha256"
SUITE_TIMEOUT = int(os.environ.get("CT_P49_SUITE_TIMEOUT", "3600"))
SHIM = Path(os.environ.get("ISONIM_GPUI_SHIM_DIR",
                           str(ROOT.parent / "isonim-gpui/rust/target/debug")))
RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*\s*(.*?)\s*$")

# --- the killer cases, spelled once ------------------------------------------
V_TOOLTIP = "label and key, or the bare label; one table of labels"
V_PLACEHOLDER = "one placeholder, the desktop palette's words"
V_CARET = "insert at the caret; Left / Right / Home / End; Backspace and Delete"
V_OVERWRITE = ("overwrite replaces the character under the caret; at the end "
               "it appends")
V_CATEGORY = "six categories, six distinct one-letter tags"
S_CLICK = ("a click activates, a small move is still a click, past the "
           "threshold is a drag")
S_DIVIDER = "a divider released within the threshold resizes nothing"
S_STRIPS = "every pane's first row is a strip; no painter heading shows"
S_DIVSURFACE = "every divider cell sits on the panes' own surface"
S_TOOLTIP = "a hovered control's tooltip is drawn under it"
S_FIELD = ("the field shows the ViewModel's placeholder; open, the caret is at "
           "the ViewModel's cursor")
S_VARS = ("no scope rows; each row's first cell is its category tag in its "
          "colour")
R_TERMMENU = ("the terminal draws the same menu: one button, a first level "
              "below it, a cascade")
R_GPUIMENU = ("GPUI draws the same menu: one button, a first level below it, "
              "a cascade")
R_TOOLTIPS = ("every transport tooltip is the ViewModel's, over the desktop's "
              "binding")
H_NOHINTS = "the status bar carries no key-hint strip, at any profile or mode"
P_MENU = ("row 0 holds one root button; F12 drops the first level; Right "
          "cascades")
P_CLICKS = ("clicks never drag; a tab click activates; past the threshold is a "
            "drag")
P_STRIPS = ("no title rows; strips on their own ground; the selected tab its "
            "own bg and fg; dividers on the panes' ground")
P_MONO = ("monochrome: the selected tab is reverse + bold and the only "
          "reversed tab")
P_OMNIBAR = ("placeholder from the ViewModel on its own ground; the caret is "
             "the terminal's cursor")
P_DRAWN = "a terminal without cursor shapes gets the caret drawn into its cell"
P_VARS = ("no category rows, no lone first column: each row starts with its "
          "tag")
G_MENU = ("one root menu button; the first level below it; submenus cascade "
          "right")
G_HEADINGS = "no heading in any pane; every pane box has a strip naming it"
G_STRIPS = ("strips on their own ground; the selected tab its own background "
            "and foreground")
G_EDITORTAB = "a lone editor's tab is its file; an Edit window's marks it dirty"
G_TOOLTIP = "the pointer over a control: the ViewModel's tooltip"
G_OMNIBAR = "the omnibar: the ViewModel's placeholder; the query with its caret"
D_DESKTOP = "gate:" + DESKTOP_GATE

CASE_SUITE = {
    V_TOOLTIP: VMU, V_PLACEHOLDER: VMU, V_CARET: VMU, V_OVERWRITE: VMU,
    V_CATEGORY: VMU,
    S_CLICK: T1, S_DIVIDER: T1, S_STRIPS: T1, S_DIVSURFACE: T1,
    S_TOOLTIP: T1, S_FIELD: T1, S_VARS: T1,
    R_TERMMENU: REF, R_GPUIMENU: REF, R_TOOLTIPS: REF,
    H_NOHINTS: PROF,
    P_MENU: PTY, P_CLICKS: PTY, P_STRIPS: PTY, P_MONO: PTY, P_OMNIBAR: PTY,
    P_DRAWN: PTY, P_VARS: PTY,
    G_MENU: GPLAN, G_HEADINGS: GPLAN, G_STRIPS: GPLAN, G_TOOLTIP: GPLAN,
    G_EDITORTAB: GPLAN,
    G_OMNIBAR: GPLAN,
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
    # --- 1. the menu: one root button, cascading submenus --------------------
    Arm("MN1", TOPBAR,
        "    if depth < m.menu.path.len:\n      let entered = m.menu.path[depth]\n      for dr in kept:\n        if dr.item >= 0 and lv.items[dr.item].index == entered:\n          row = dr.row\n      col = c + w\n",
        "    if depth < m.menu.path.len:\n      let entered = m.menu.path[depth]\n      for dr in kept:\n        if dr.item >= 0 and lv.items[dr.item].index == entered:\n          row = dr.row\n      col = c\n",
        R_TERMMENU,
        "the terminal's submenu opens over its parent, not beside it"),
    Arm("MN2", TOPBAR,
        "        if dr.item >= 0 and lv.items[dr.item].index == entered:\n          row = dr.row\n      col = c + w\n",
        "        if dr.item >= 0 and lv.items[dr.item].index == entered:\n          row = 1\n      col = c + w\n",
        R_TERMMENU,
        "the terminal's submenu starts at the top, not level with its folder"),
    Arm("MN3", RUNTIME,
        '  of "Right": discard vm.enterFolder()\n',
        '  of "Right": vm.moveHighlight(1)\n',
        P_MENU,
        "Right on a folder moves the highlight instead of opening the submenu"),
    Arm("GM1", WINTOP,
        "          y = r.rect.y - 4\n      x = px + w\n",
        "          y = r.rect.y - 4\n      x = px\n",
        R_GPUIMENU,
        "GPUI's submenu popover opens over its parent"),
    Arm("GM2", GPUIMAIN,
        '    of "right": discard gMenu.enterFolder()\n',
        '    of "right": gMenu.moveHighlight(1)\n',
        G_MENU,
        "GPUI's Right key moves the highlight instead of opening the submenu"),

    # --- 2. a click is a click -------------------------------------------------
    Arm("DG1", BINDING,
        "    (abs(col - b.pressCol) >= DragThresholdCols or\n",
        "    (abs(col - b.pressCol) >= 0 or\n",
        S_CLICK,
        "no drag threshold: any press is past it"),
    Arm("DG2", BINDING,
        '        b.pendingPick = tab\n        return action(lasNoGesture, "pressed the " & $tab.get & " tab")\n',
        '        return b.beginDrag(tab.get)\n',
        S_CLICK,
        "a press on a tab picks it up at once (the old behaviour)"),
    Arm("DG3", RUNTIME,
        "  if acted.status != lasNoGesture:\n    rt.note(acted.message)\n",
        "  if true:\n    rt.note(acted.message)\n",
        P_CLICKS,
        "every layout report, a plain click's included, goes to the status line"),
    Arm("DG4", BINDING,
        "      if not past:\n        # A click on the divider (within the threshold) is what it was\n",
        "      if false:\n        # A click on the divider (within the threshold) is what it was\n",
        S_DIVIDER,
        "a divider released one cell over resizes the split"),

    # --- 3. no title rows ------------------------------------------------------
    Arm("TI1", SHELL,
        "      discard paintCallTrace(g, under, model.callTrace)\n",
        "      discard paintCallTrace(g, content, model.callTrace)\n",
        P_STRIPS,
        "the call trace's own heading shows under its strip"),
    Arm("TI2", SHELL,
        "  paintTabRow(g, a.row, a.col, stripTabs, stripActive, inner)\n",
        "  discard stripTabs\n",
        S_STRIPS,
        "no strip is painted over a pane: the painters' headings show"),
    Arm("TI3", GPUIMAIN,
        "    if id.len > 0 and id notin gPanes: gPanes[id] = pane\n    stripHeading(r, pane)\n",
        "    if id.len > 0 and id notin gPanes: gPanes[id] = pane\n",
        G_HEADINGS,
        "the GPUI window keeps every leaf's heading"),
    Arm("TI4", WINGEOM,
        "    if tabs.len >= 1:\n      node.strip = PxRect(",
        "    if tabs.len > 1:\n      node.strip = PxRect(",
        G_HEADINGS,
        "a bare pane in the GPUI window has no strip naming it"),

    Arm("TI5", PANEVIEWS,
        '  result.root = viewCollapsible("state", "", @[tabs, tree],\n',
        '  result.root = viewCollapsible("state", "State", @[tabs, tree],\n',
        G_HEADINGS,
        "GPUI's State pane titles itself again under its strip"),

    # --- 3. a lone editor's tab is its file ----------------------------------
    Arm("ET1", SHELL,
        "    if file.len > 0:\n      lone = file\n",
        "    if false:\n      lone = file\n",
        P_STRIPS,
        "the terminal's lone editor tab names the pane, not its file"),
    Arm("ET2", PRODMODE,
        '  name & (if dirty: " ●" else: "")\n',
        '  name\n',
        G_EDITORTAB,
        "the shared editor tab label drops the unsaved-changes mark"),
    Arm("ET3", GPUIMAIN,
        "                           @[($paneEditor, gEditorTab)])\n",
        "                           @[])\n",
        G_EDITORTAB,
        "GPUI's lone editor tab names the pane, not its file"),
    Arm("ET4", GPUIMAIN,
        "  gEditorTab = label\n  if windowDrawn():\n",
        "  gEditorTab = label\n  if false:\n",
        G_EDITORTAB,
        "GPUI's editor tab is not redrawn when the buffer turns dirty"),

    # --- 4. tab strips ---------------------------------------------------------
    Arm("TC1", ROLES,
        "    srTabBar: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,\n                   dtColorsUiSurfaceBaseRaised, baseSurface = true),\n",
        "    srTabBar: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,\n                   dtColorsUiSurfaceBasePanel, baseSurface = true),\n",
        P_STRIPS,
        "the tab strip on the pane body's ground"),
    Arm("TC2", ROLES,
        "    srTabActive: fgbg(dgTab, dtColorsUiTextPrimaryHeadings,\n                      dtColorsUiSurfacePrimaryTertiary,",
        "    srTabActive: fgbg(dgTab, dtColorsUiTextPrimaryHeadings,\n                      dtColorsUiSurfaceBaseRaised,",
        P_STRIPS,
        "the selected tab on the strip's own ground"),
    Arm("TC3", ROLES,
        "    srTabActive: fgbg(dgTab, dtColorsUiTextPrimaryHeadings,\n",
        "    srTabActive: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,\n",
        P_STRIPS,
        "the selected tab in the inactive tabs' ink"),
    Arm("TC4", ROLES,
        "                      mono = {raBold, raReverse}),\n    srTabInactive:",
        "                      mono = {raBold}),\n    srTabInactive:",
        P_MONO,
        "monochrome: the selected tab without reverse video"),
    Arm("TC5", CHROME,
        '      ("background-color", chromeOf(crTabActiveBackground))]\n',
        '      ("background-color", chromeOf(crTabStripBackground))]\n',
        G_STRIPS,
        "GPUI's selected tab on the strip's own ground"),
    Arm("TC6", GPUIMAIN,
        "      for (key, value) in stripStyle():\n        r.setStyle(strip, key, value)\n",
        "      discard stripStyle()\n",
        G_STRIPS,
        "GPUI's strip without its own ground"),

    # --- 5. tooltips -----------------------------------------------------------
    Arm("TT1", DCVM,
        '  if chord.len == 0: label else: label & " (" & chord & ")"\n',
        '  if chord.len == 0: label else: label\n',
        V_TOOLTIP,
        "the tooltip drops the key"),
    Arm("TT2", DCVM,
        "  for (id, label) in TransportActions:\n    if id == actionId:\n      return label\n",
        "  for (id, label) in TransportActions:\n    if id != actionId:\n      return label\n",
        R_TOOLTIPS,
        "a control's tooltip carries another control's label"),
    Arm("TT3", TOPBAR,
        "  let a = controlTooltipArea(m, lay, width)\n  if a.width <= 0:\n    return\n",
        "  let a = controlTooltipArea(m, lay, width)\n  if true:\n    return\n",
        S_TOOLTIP,
        "the terminal draws no tooltip under the hovered control"),
    Arm("TT4", WINTOP,
        "  transportTooltip(TransportControls[i].id, chord)\n",
        "  TransportControls[i].label\n",
        G_TOOLTIP,
        "GPUI's hover popover is not the ViewModel's tooltip"),

    # --- 6. the omnibar --------------------------------------------------------
    Arm("OB1", OMNIVM,
        '  OmnibarPlaceholder* = "Navigate to file or run a :command"\n',
        '  OmnibarPlaceholder* = "Search files, :commands, :sym, #tick"\n',
        V_PLACEHOLDER,
        "the omnibar's placeholder is not the desktop palette's words"),
    Arm("OB2", OMNIVM,
        "  let stop = if vm.overwrite and at < vm.query.len: nextBoundary(vm.query, at)\n",
        "  let stop = if false and at < vm.query.len: nextBoundary(vm.query, at)\n",
        V_OVERWRITE,
        "overwrite mode inserts"),
    Arm("OB3", OMNIVM,
        "  if at != vm.cursor:\n    vm.cursor = at\n    vm.changed()\n",
        "  if at != vm.cursor:\n    vm.changed()\n",
        V_CARET,
        "Left / Right never move the caret"),
    Arm("OB4", TUIMAIN,
        "                shape: (if caret.overwrite: ckBlock else: ckBar)),\n",
        "                shape: ckBlock),\n",
        P_OMNIBAR,
        "the terminal's caret is a block while inserting"),
    Arm("OB5", TOPBAR,
        "        g.fillSurface(0, s.col, s.width, 1, srSurfaceField)\n        g.paint(0, s.col, spaces(s.width),\n                CellStyle(role: srChromeText, surface: srSurfaceField))\n",
        "        g.fillSurface(0, s.col, s.width, 1, srSurfaceCard)\n        g.paint(0, s.col, spaces(s.width),\n                CellStyle(role: srChromeText, surface: srSurfaceCard))\n",
        S_FIELD,
        "the omnibar field on the bar's own card"),
    Arm("OB6", TOPBAR,
        "        if caret.shown and m.caretDrawn:\n",
        "        if false:\n",
        P_DRAWN,
        "no caret at all where the terminal does not shape its cursor"),
    Arm("OB7", GPUIMAIN,
        '            (if gOmnibar.overwrite: "█" else: "▏") &\n            gOmnibar.query[c .. ^1]\n',
        '            (if gOmnibar.overwrite: "▏" else: "█") &\n            gOmnibar.query[c .. ^1]\n',
        G_OMNIBAR,
        "GPUI's caret glyphs swapped between insert and overwrite"),
    Arm("CR1", CARET,
        '  NoShapeTerms* = ["linux", "dumb", ',
        '  NoShapeTerms* = ["dumb", ',
        P_DRAWN,
        "isonim-tui tells the Linux console it shapes its cursor"),
    Arm("DT1", DESKPALETTE,
        "variant above draws it.\n                  placeholder = OmnibarPlaceholder,\n",
        'variant above draws it.\n                  placeholder = "Search...",\n',
        D_DESKTOP,
        "the desktop's palette (the DOM renderer's input) keeps words of its own",
        also=((DESKPALETTE,
               "draw the same words.\n                placeholder = OmnibarPlaceholder,\n",
               'draw the same words.\n                placeholder = "Search...",\n'),)),

    # --- 10. key hints ---------------------------------------------------------
    Arm("KH1", STATUS,
        '      promptSigil(m.mode) & m.prompt\n    else:\n      ""\n',
        '      promptSigil(m.mode) & m.prompt\n    else:\n      "\'n\':step-over \'p\':rev-step"\n',
        H_NOHINTS,
        "a key-hint strip back on the status line"),

    # --- 12. the variables pane -----------------------------------------------
    Arm("VR1", VARS,
        "  let tag = categoryTag(category)\n",
        '  let tag = ""\n',
        S_VARS,
        "no category tag at the start of a row"),
    Arm("VR2", VARS,
        "  srCategoryLocal, srCategoryArgument, srCategoryGlobal,\n",
        "  srCategoryWatch, srCategoryArgument, srCategoryGlobal,\n",
        P_VARS,
        "a local's tag in the watches' colour"),
    Arm("VR3", STATEVM,
        '    ["L", "A", "G", "R", "X", "W"]\n',
        '    ["L", "A", "G", "R", "R", "W"]\n',
        V_CATEGORY,
        "two categories share one letter"),
    Arm("VR4", VARS,
        "  result = @[]\n  for scope in model.scopes:\n    let path = scopePath(scope.kind)\n    if scope.availability == savaUnsupported:\n",
        "  result = @[]\n  for scope in model.scopes:\n    let path = scopePath(scope.kind)\n    result.add VariablesRow(kind: vrkScope, scope: scope.kind, depth: 0,\n                            node: VarNode(path: path, name: $scope.kind))\n    if scope.availability == savaUnsupported:\n",
        S_VARS,
        "a separator row per category is back"),

    # --- 13. dividers ----------------------------------------------------------
    Arm("DV1", SHELL,
        "  DividerSurface* = srSurfacePanel\n",
        "  DividerSurface* = srSurfaceCanvas\n",
        S_DIVSURFACE,
        "dividers on the canvas, a ground of their own"),
    Arm("DV2", SHELL,
        "    let role = if cell in ring: srBorderFocused else: srBorderPane\n",
        "    let role = if cell in ring: srBorderFocused else: srChromeText\n",
        P_STRIPS,
        "unfocused dividers in the text ink, not the subtle border tier"),
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
    state = Path(tempfile.gettempdir()) / f"plat49-mutation-state-{os.getuid()}"
    state.mkdir(parents=True, exist_ok=True)
    env["CODETRACER_TUI_LAYOUT_DIR"] = str(state)
    env["XDG_STATE_HOME"] = str(state)
    return env


def artefacts_for(path: str) -> tuple:
    stem = Path(path).stem
    base = Path(tempfile.gettempdir()) / f"plat49-mutation-{os.getuid()}"
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
                env["HOME"] = tempfile.mkdtemp(prefix="plat49-s1-home-")
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
    `isonim-tui` subject lives wherever `$ISONIM_TUI_SRC` points (a worktree,
    a plain `../isonim-tui` checkout, CI's clone), so it is named relative to
    that source root, `isonim-tui/src/...`: an absolute path would make the
    committed control unreadable on every other checkout, while the digest
    still pins the exact bytes graded."""
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
