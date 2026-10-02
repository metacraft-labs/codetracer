#!/usr/bin/env python3
"""PLAT-48 — the mutation harness for the top bar and the auto-hide panels on
every front-end: the shared Menu ViewModel (and the desktop's menu drawn from
it), the omnibar, the debugger controls in their four renderings, the session
tabs, the shared default's docked footer panels, the terminal's and GPUI's
dock strips, reveal overlays and pin / unpin, and GPUI's top dock edge.

    python3 src/frontend/tui/tests/run-plat48-topbar-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=MV1,IC2

Run from the repository root, inside the dev shell, with `REPLAY_SERVER_BIN`
exported (the real-PTY suite opens the real `calc` recording and steps it).
The GPUI suite loads `libgpui_nim_shim`; the harness puts the shim on
`LD_LIBRARY_PATH` itself. DM1 runs the REAL Electron app
(`scripts/plat48-capture-electron.sh`, which compiles this checkout's desktop
JavaScript into a prefix); it needs Xvfb (started when no display is set) and
the built frontend `just build-once` leaves.

ONE ARM PER CLAIM, each naming the case (or the gate) that must die:

  | claim | arms |
  |---|---|
  | the Menu ViewModel: highlight, activation, the active keymap's chords | MV1 (hidden items selectable), MV2 (every item "on the path"), MV3 (a disabled item runs), MV4 (the keymap ignored) |
  | the desktop's menu IS the shared Menu ViewModel, drawn | DM1 (the desktop's menu reads a MenuVM of its own) |
  | the product tree hides the macOS-only entries off macOS | PM1 |
  | the omnibar: the desktop's query modes, ranked results | OB1 (the tick mode lost), OB2 (the ranking reversed), OS1 (commands not spelled as the menu's path) |
  | the four renderings of the controls; never nerd by default | IC1 (a wrong Codicon), IC2 (unicode draws nerd), IC3 (text draws the label), DF1 (the default assumes Nerd Fonts), PS2 (text's priority budget), PS1 (the bar never degrades) |
  | graphics: the desktop's marks, rasterised, placed on the control's cells | PR1 (the fill rule), IC4 (every control the same mark), KB1 (the placement's cell count) |
  | session tabs step round | ST1 |
  | the shared default docks the desktop's footer panels, in every front-end | SD1 (REQUESTS dropped), SD2 (the terminal's default without them), DM2 (the unbound terminal without them) |
  | the reveal is an overlay of the pane itself, where the strip is | RV1 (the bottom reveal at the top), RV2 (the pane not painted) |
  | a side strip's label reads down, one character per row | VL1 (every character on one row), VL2 (a one-row slot) |
  | pin / unpin round-trip to where the pane was | PN1 (the anchor forgotten), PN2 (a stack's first tab comes back last), DO1 (a redock to a populated edge collides) |
  | the terminal's menu: the keymap's chords, the bar's keys | TM1 (no chord shown), TM2 (Right walks left) |
  | the top bar acts on the recording | TO1 (a tick query goes to tick 0), TC1 (a control click does nothing), TF1 (the frame after a click never drawn), DR1 (a queued mouse report split into keys) |
  | GPUI: the top dock edge, the popovers, the desktop keymap | GT1 (top dock refused), GT2 (the top strip misplaced), GT3 (the top margin not a dock zone), GM1 (a nested popover over its parent), GK1 (no bindings read) |
  | session tabs from the keyboard: `g t` / `g T` / `Ctrl+Tab` (terminal), `Ctrl+Alt+PageDown` / `PageUp` (GPUI) | TK1 (`g t` steps back), TK2 (`CSI u` Ctrl+Tab not a key), GS1 (the window's key does nothing) |
  | GPUI's DRAWING, read from the window's own render plan (`--report-window-plan`) | GW1 (every control the first mark), GW2 (enabled drawn in the disabled ink), GW3 (titles without names), GW4 (the popover under the pin buttons), GW5 (a hover label without its chord), GW6 (the reveal an empty box), GW7 (no Unpin), GW8 (the revealed label not marked), GW9 (pins through a top reveal), GP1 (the rule that hides them), GW10 (pin docks to the wrong edge) |

GPUI'S DRAWING IS GRADED FROM THE WINDOW'S OWN RENDER PLAN. `gpui/main.nim`'s
drawing — the band, the desktop's SVG marks through `img`, the popovers and
their paint order over the pin buttons, the hover label, the reveal overlay
holding the pane itself, Unpin, the strips' active label — runs in the
shipped `codetracer-gpui --report-window-plan`: the window's own root builder
over a detached root, the `--window-ops` events dispatched through the
window's own pointer and key handlers, the resulting shadow tree printed.
`test_plat48_gpui_plan.nim` asserts over it, and the GW arms rebuild the
binary (`just build-gpui`) with each defect. What that tree cannot show —
pixels, fonts, the compositor's pointer — is read off a real window by `just
plat48-gpui-window` into `plat48-gpui-window.json` (`test_plat48_gpui_window
.nim`), which CI re-takes on every run (`gpui-window-captures`).

THREE VERDICTS (Verification-Harness-Traps §1): `killed` (the named case
reported [FAILED], or the named gate exited non-zero printing its marker),
`SURVIVED` (the case [OK] / the gate green), `HARNESS-FAILURE` (the needle was
not unique, the suite did not compile, the mutated binary did not build, or
the run printed no result lines). A run that prints nothing is never a kill.

Every Nim suite is run FILTERED to its killer case (std/unittest's own name
argument), so an arm costs one case rather than a suite; the control run is
unfiltered and must name every killer as [OK].

THE BINARY IS PART OF THE SUBJECT: an arm graded by the real-PTY suite
rebuilds `build/bin/codetracer-tui` with the defect (`just build-tui`), and
again from the restored tree afterwards.

RESTORATION is from an in-memory snapshot, and every touched file's SHA-256
is compared with the pre-run baseline after each arm (§32). The full run
refuses unless the needle scan is clean AND every touched file matches
`plat48-topbar-mutation-control.sha256`.

NO DECLARED SURVIVORS.

No mocks: every suite graded here runs the product's own ViewModels, the
product's own runtime, a real PTY with the real `calc` recording, and the real
Electron app.
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
MENUVM = "src/frontend/viewmodel/viewmodels/menu_vm.nim"
PRODMENU = "src/frontend/viewmodel/viewmodels/product_menu.nim"
OMNIVM = "src/frontend/viewmodel/viewmodels/omnibar_vm.nim"
OMNISRC = "src/frontend/viewmodel/viewmodels/omnibar_sources.nim"
ICONS = "src/frontend/viewmodel/viewmodels/transport_icons.nim"
RASTER = "src/common/terminal_graphics/path_raster.nim"
LAYOUTMODEL = "src/frontend/headless_app/layout_model.nim"
TABS = "src/frontend/headless_app/session_tabs.nim"
TOPBAR = "src/frontend/tui/app/views/top_bar.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
BINDING = "src/frontend/tui/app/layout/binding.nim"
PROFILE = "src/frontend/tui/app/layout/profile.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
CTLICONS = "src/frontend/tui/host/control_icons.nim"
TUIMAIN = "src/frontend/tui/main.nim"
DRIVER = "src/frontend/tui/host/terminal_driver.nim"
DOCKPROJ = "src/frontend/gpui/app/dock_projection.nim"
WINGEOM = "src/frontend/gpui/window_geometry.nim"
WINTOP = "src/frontend/gpui/window_top_bar.nim"
DESKMENU = "src/frontend/ui/menu.nim"
GPUIMAIN = "src/frontend/gpui/main.nim"
KEYMAP = "src/frontend/tui/app/input/keymap.nim"
KEYNAMES = "src/common/key_names.nim"

# --- suites and gates ---------------------------------------------------------
VMU = "src/frontend/viewmodel/tests/unit/test_plat48_topbar_models.nim"
T1 = "src/frontend/tui/tests/test_plat48_top_bar.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat48_top_bar.nim"
GTB = "src/frontend/gpui/tests/test_plat48_gpui_top_bar.nim"
BIND = "src/frontend/tui/app/tests/test_layout_binding.nim"
ROUTE = "src/frontend/tui/app/tests/test_layout_command_routing.nim"
ESCD = "src/frontend/tui/tests/test_esc_delay.nim"
GPLAN = "src/frontend/gpui/tests/test_plat48_gpui_plan.nim"
DESKTOP_GATE = "scripts/plat48-capture-electron.sh"

SUBJECTS = [MENUVM, PRODMENU, OMNIVM, OMNISRC, ICONS, RASTER, LAYOUTMODEL,
            TABS, TOPBAR, SHELL, BINDING, PROFILE, RUNTIME, CTLICONS, TUIMAIN,
            DOCKPROJ, WINGEOM, WINTOP, DESKMENU, DRIVER, GPUIMAIN, KEYMAP,
            KEYNAMES]
SUITES = [VMU, T1, PTY, GTB, GPLAN, BIND, ROUTE, ESCD, DESKTOP_GATE]
TOUCHED = SUBJECTS + SUITES

# How each suite is run: (backend, lane whose `--path`s it needs).
SUITE_KIND = {
    VMU: ("c", "vm-unit"),
    T1: ("c", "tui"),
    PTY: ("c", "tui-real-terminal"),
    GTB: ("c", "gpui-shell"),
    GPLAN: ("c", "gpui-shell"),
    BIND: ("c", "tui"),
    ROUTE: ("c", "tui"),
    ESCD: ("c", "tui"),
    # The real desktop, filtered to its one case (a regex without spaces:
    # `just` word-splits the arguments it forwards to Playwright).
    DESKTOP_GATE: ("electron", "drawn.from.the.shared.Menu.ViewModel"),
}
BINARY_SUITES = {PTY}
  # graded against a REBUILT codetracer-tui
GPUI_BINARY_SUITES = {GPLAN}
  # read the WINDOW's render plan of a REBUILT codetracer-gpui
  # (`just build-gpui`, `--report-window-plan`)
UNISOLATED_SUITES: set = set()

CONTROL_HASHES = HERE / "plat48-topbar-mutation-control.sha256"
SUITE_TIMEOUT = int(os.environ.get("CT_P48_SUITE_TIMEOUT", "3600"))
SHIM = Path(os.environ.get("ISONIM_GPUI_SHIM_DIR", str(ROOT.parent / "isonim-gpui/rust/target/debug")))
RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*\s*(.*?)\s*$")

# --- the killer cases, spelled once ------------------------------------------
C_TREE = "the tree is the product's, with macOS entries hidden off macOS"
C_KEYS = "open, walk into a folder, back out, close — the keyboard's operations"
C_DISABLED = "a disabled item does nothing; setEnabled marks a front-end's gaps"
C_POINTER = "pointer: hover opens folders and highlights items; click runs"
C_CHORDS = "the shortcut shown is the active keymap's, and switching changes it"
C_MODES = "the query decides the mode, the desktop's rule"
C_RANKED = "results are ranked, and the order is total"
C_NERD = "nerd glyphs are Codicons, reverse actions included"
C_FOUR = "the four modes differ, and graphics draws no glyph"
C_DEFAULT = "the default never assumes a font"
C_PRIORITY = "text mode keeps exactly a priority prefix, in toolbar order"
C_FOOTER = "the desktop's four footer panels, docked at the bottom, in order"
C_TABS = "activate, step, reorder and close"
C_SQUARE = "a filled square covers exactly its area"
T_NARROW = ("at 80 columns: the menu collapses to ≡, the omnibar to ⌕, "
            "controls by priority")
T_GLYPHS = "each icons mode draws its own glyph set"
T_F12 = ("F12 opens it; keys walk the bar and into a folder; the chords are "
         "the keymap's")
T_REBIND = "switching the keymap changes the chord the menu shows"
T_COMMAND = "a command query lists the menu's commands and runs one"
T_STRIP = "the shared default's footer panels are the bottom strip's labels"
T_LEFT = ("a left-docked pane's label reads top to bottom, one character per "
          "row")
T_REVEAL = ("Ctrl+o reveals the docked pane ITSELF over the body, Esc restores "
            "every cell")
T_PIN = "pin / unpin round-trip through the saved document"
T_MARKS = ("each control is the desktop's mark, transmitted once and placed "
           "on its cells")
P_TICK = ("Ctrl+p, a tick, Enter: the debugger is there; a :sym query lists "
          "functions")
P_CLICK = "a click on each control performs it on the recording"
G_TOP = ("a top-docked layout projects, lays out a top strip, and the top "
         "margin docks")
G_POPOVER = ("an open folder drops below its title; a nested one opens to its "
             "right")
G_BINDINGS = "the desktop's default bindings, spelled as its menu spells them"
B_VERBS = "every keyboard gesture has a spelling, and none of them is silent"
R_UNBOUND = "enabling it changes NOTHING on screen, compared as rendered rows"
R_EDGES = "which dock edges a real drag can reach, measured rather than argued"
E_LATE = ("a sequence already waiting behind its ESC is one token, however "
          "late the reader")
T_TABKEYS = ("g t / g T and Ctrl+Tab / Ctrl+Shift+Tab step the tabs, "
             "wrapping (§3.3.1)")
G_TABKEYS = ("the session tabs' keys: Ctrl+Alt+PageDown / PageUp, no desktop "
             "chord reused")
G_PINSHOWN = "a pin button under a revealed pane is not drawn, and not pressable"
W_BAND = ("the band: the shared menu's titles, the desktop's nine marks, the "
          "omnibar")
W_POPOVER = "an open menu's popover is drawn over every pane's pin button"
W_HOVER = "the pointer on a control: its tooltip and the desktop's chord, below it"
W_REVEAL = "Ctrl+O reveals the first docked pane ITSELF over the tree, with Unpin"
W_TOP = ("the TOP edge: a tab dragged to the top margin docks there and "
         "reveals from it")
W_PIN = "pin docks a pane to the footer; Unpin puts it back beside where it was"
G_DESKTOP = "gate:" + DESKTOP_GATE

CASE_SUITE = {
    C_TREE: VMU, C_KEYS: VMU, C_DISABLED: VMU, C_POINTER: VMU, C_CHORDS: VMU,
    C_MODES: VMU, C_RANKED: VMU, C_NERD: VMU, C_FOUR: VMU, C_DEFAULT: VMU,
    C_PRIORITY: VMU, C_FOOTER: VMU, C_TABS: VMU, C_SQUARE: VMU,
    T_NARROW: T1, T_GLYPHS: T1, T_F12: T1, T_REBIND: T1, T_COMMAND: T1,
    T_STRIP: T1, T_LEFT: T1, T_REVEAL: T1, T_MARKS: T1, T_PIN: T1,
    P_TICK: PTY, P_CLICK: PTY,
    G_TOP: GTB, G_POPOVER: GTB, G_BINDINGS: GTB, G_TABKEYS: GTB,
    G_PINSHOWN: GTB, T_TABKEYS: T1,
    W_BAND: GPLAN, W_POPOVER: GPLAN, W_HOVER: GPLAN, W_REVEAL: GPLAN,
    W_TOP: GPLAN, W_PIN: GPLAN,
    B_VERBS: BIND, R_UNBOUND: ROUTE, R_EDGES: ROUTE, E_LATE: ESCD,
    G_DESKTOP: DESKTOP_GATE,
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
    # --- the Menu ViewModel ------------------------------------------------------
    Arm("MV1", MENUVM,
        "    if it.selectable:\n      return i\n",
        "    if true:\n      return i\n",
        C_KEYS,
        "opening a menu highlights the hidden macOS folder: the keyboard lands "
        "on an item no front-end draws"),
    Arm("MV2", MENUVM,
        "    return path[^1] == vm.highlight\n",
        "    return true\n",
        C_POINTER,
        "every item under the open folder reads as highlighted: the one "
        "active mark a renderer draws is no longer the ViewModel's"),
    Arm("MV3", MENUVM,
        "  if it.hidden or not it.enabled or it.action.len == 0:\n    return\n"
        "  result = MenuActivation",
        "  if it.hidden or it.action.len == 0:\n    return\n"
        "  result = MenuActivation",
        C_DISABLED,
        "a disabled item runs its action when activated"),
    Arm("MV4", MENUVM,
        "  vm.shortcuts = shortcuts\n",
        "  discard shortcuts\n",
        C_CHORDS,
        "the menu ignores the active keymap: no chord is shown, and a rebind "
        "changes nothing"),
    Arm("DM1", DESKMENU,
        "    if self.vm.isOnPath(path): \"menu-active-node\" else: \"\"\n",
        "    if newMenuVM(self.vm.root).isOnPath(path): \"menu-active-node\" "
        "else: \"\"\n",
        G_DESKTOP,
        "the desktop's menu draws its highlight from a MenuVM of its own, "
        "not the shared one the other front-ends and the gate drive"),
    Arm("PM1", PRODMENU,
        "    (os and OsHost) != 0 or (os and OsMac) != 0\n  else:",
        "    (os and OsHost) != 0\n  else:",
        C_TREE,
        "the macOS-only entries (the application folder) show in the "
        "terminal's and GPUI's menus"),
    # --- the omnibar -------------------------------------------------------------
    Arm("OB1", OMNIVM,
        "    if digits:\n      return (omTick,",
        "    if false:\n      return (omTick,",
        C_MODES,
        "`#42` is a file query: the omnibar's tick mode is lost"),
    Arm("OB2", OMNIVM,
        "    return cmp(b.score, a.score)\n",
        "    return cmp(a.score, b.score)\n",
        C_RANKED,
        "the omnibar lists its worst matches first"),
    Arm("OS1", OMNISRC,
        "    result.add OmnibarEntry(kind: omCommand, label: labels.join(\" › \"),",
        "    result.add OmnibarEntry(kind: omCommand, label: labels.join(\" / \"),",
        T_COMMAND,
        "a command result is not spelled as the menu's own path"),
    # --- the controls' four renderings -------------------------------------------
    Arm("IC1", ICONS,
        "nerd: \"\\u{EAD6}\", unicode: \"↷\"",
        "nerd: \"\\u{EAD4}\", unicode: \"↷\"",
        C_NERD,
        "Next draws the wrong Codicon in nerd mode"),
    Arm("IC2", ICONS,
        "  of imUnicode: c.unicode\n",
        "  of imUnicode: c.nerd\n",
        C_FOUR,
        "unicode mode draws Private Use Area glyphs a terminal without a "
        "Nerd Font shows as boxes"),
    Arm("DF1", ICONS,
        "  if graphicsDrawn: imGraphics else: imUnicode\n",
        "  if graphicsDrawn: imGraphics else: imNerd\n",
        C_DEFAULT,
        "the default silently assumes a Nerd Font"),
    Arm("PS2", ICONS,
        "    if used + w > budget:\n",
        "    if used + w > budget + 20:\n",
        C_PRIORITY,
        "text mode keeps controls past the width it was given"),
    Arm("IC3", TOPBAR,
        "        of imText: \" \" & c.text & \" \"\n",
        "        of imText: \" \" & c.label & \" \"\n",
        T_GLYPHS,
        "text mode paints the long labels, not the short words it budgets for"),
    Arm("PS1", TOPBAR,
        "  if total <= budget:\n",
        "  if true:\n",
        T_NARROW,
        "the bar never degrades: at 80 columns it overflows instead of "
        "collapsing the menu and the omnibar"),
    # --- graphics ------------------------------------------------------------------
    Arm("PR1", RASTER,
        "            elif winding(polys, ux, uy) != 0:\n",
        "            elif winding(polys, ux, uy) == 0:\n",
        C_SQUARE,
        "the non-zero fill rule inverted: a mark fills its outside"),
    Arm("IC4", CTLICONS,
        "      let img = markImage(TransportControls[controlIndex].id,\n",
        "      let img = markImage(TransportControls[0].id,\n",
        T_MARKS,
        "every control is transmitted as the first control's mark"),
    Arm("KB1", CTLICONS,
        ",p=1,c=2,r=1,C=1,q=2",
        ",p=1,c=1,r=1,C=1,q=2",
        T_MARKS,
        "the picture is placed on one cell, not the control's two"),
    # --- session tabs -------------------------------------------------------------
    Arm("ST1", TABS,
        "  app.activateTab((at + delta + tabs.len) mod tabs.len)\n",
        "  app.activateTab(at + delta)\n",
        C_TABS,
        "stepping past the last session tab does not wrap"),
    # --- the shared default's footer ------------------------------------------------
    Arm("SD1", LAYOUTMODEL,
        "               order: 2),\n    DockedPane(pane: paneRequests, "
        "title: \"REQUESTS\", edge: leBottom,\n               order: 3)]\n",
        "               order: 2)]\n",
        C_FOOTER,
        "the shared default drops the desktop's REQUESTS footer panel"),
    Arm("SD2", PROFILE,
        "  initLayout(profileLayout(profile), sharedDefaultLayout().docked)\n",
        "  initLayout(profileLayout(profile))\n",
        T_STRIP,
        "the terminal's default arrangement loses the footer panels"),
    Arm("DM2", PROFILE,
        "  of pmDebug: sharedDefaultLayout().docked\n",
        "  of pmDebug: @[]\n",
        R_UNBOUND,
        "a terminal with no layout binding paints no footer strip, so "
        "enabling the binding changes the screen"),
    # --- reveal overlay --------------------------------------------------------------
    Arm("RV1", BINDING,
        "    CellArea(col: inner.col, row: inner.row + inner.height - h,\n",
        "    CellArea(col: inner.col, row: inner.row,\n",
        T_REVEAL,
        "a pane revealed from the bottom strip is drawn against the top"),
    Arm("RV2", SHELL,
        "  paintPane(g, region, model, a)\n",
        "  discard (region, a)\n",
        T_REVEAL,
        "the reveal overlay is an empty box, not the pane itself"),
    # --- vertical labels ---------------------------------------------------------------
    Arm("VL1", SHELL,
        "                  CellStyle(role: role, bold: shown))\n          inc r\n",
        "                  CellStyle(role: role, bold: shown))\n",
        T_LEFT,
        "a side strip's label is painted over itself on one row"),
    Arm("VL2", BINDING,
        "  else: title.runeLen + 1\n",
        "  else: 1\n",
        T_LEFT,
        "a side strip's slot is one row, so the label is cut to its first "
        "character"),
    # --- pin / unpin -------------------------------------------------------------------
    Arm("PN1", LAYOUTMODEL,
        "                       entry.beside.isSome and tree.contains(entry.beside.get)\n",
        "                       false\n",
        B_VERBS,
        "unpin forgets where the pane was pinned from and appends it to the "
        "root"),
    Arm("PN2", LAYOUTMODEL,
        "                          before = remembered and entry.besideBefore):\n",
        "                          before = false):\n",
        T_PIN,
        "unpin puts a stack's FIRST tab back behind the tab that followed it "
        "(Call Trace | Agent Activity came back as Agent Activity | Call "
        "Trace)"),
    Arm("DO1", LAYOUTMODEL,
        "          else: maxOrderAt(next, cmd.autoHideEdge) + 1\n",
        "          else: d.order\n",
        R_EDGES,
        "a pane redocked onto an edge that already has panes keeps its old "
        "order and collides"),
    # --- the terminal's menu -----------------------------------------------------------
    Arm("TM1", RUNTIME,
        "      return bnd.spelling\n",
        "      return \"\"\n",
        T_REBIND,
        "the terminal's menu shows no chord for any item"),
    Arm("TM2", RUNTIME,
        "    if bar and vm.path.len == 0: vm.moveHighlight(1)\n",
        "    if bar and vm.path.len == 0: vm.moveHighlight(-1)\n",
        T_F12,
        "Right walks the menu bar leftwards"),
    # --- acting on the recording -------------------------------------------------------
    Arm("TO1", RUNTIME,
        "    rt.runPromptLine(\":goto \" & entry.target, outcome)\n",
        "    rt.runPromptLine(\":goto 0\", outcome)\n",
        P_TICK,
        "the omnibar's tick result goes to the start, not the tick asked for"),
    Arm("TC1", RUNTIME,
        "    else:\n      rt.performAction(ka, outcome)\n  of thOmnibar:",
        "    else:\n      discard ka\n  of thOmnibar:",
        P_CLICK,
        "a click on an enabled control does nothing"),
    Arm("TF1", TUIMAIN,
        "          if driver.holdFrame(journal.pendingReplay > 0):\n"
        "            frameOwed = true\n",
        "          if driver.holdFrame(journal.pendingReplay > 0):\n"
        "            discard\n",
        P_CLICK,
        "the frame held for a click's release half is never drawn: the step "
        "happened and the screen keeps the old tick"),
    Arm("DR1", DRIVER,
        "  while not complete and d.framer.pending.len > 0:\n",
        "  while false:\n",
        E_LATE,
        "a sequence's bytes are read one per call again: a mouse report queued "
        "behind a debugger step is split into Esc and keys"),
    # --- GPUI ------------------------------------------------------------------------
    Arm("GT1", DOCKPROJ,
        "  let topDocked = dockGroupsOf(layout, leTop).len > 0\n",
        "  if dockGroupsOf(layout, leTop).len > 0:\n"
        "    return DockProjection(status: dpsRefused)\n"
        "  let topDocked = false\n",
        G_TOP,
        "a layout with a top-docked pane is refused by the GPUI window again"),
    Arm("GT2", WINGEOM,
        "      of leTop: PxRect(x: area.x + lw, y: area.y, w: max(1, area.w - lw - rw),\n",
        "      of leTop: PxRect(x: area.x + lw, y: area.y + 40, w: max(1, area.w - lw - rw),\n",
        G_TOP,
        "the top strip is drawn inside the tree, not above it"),
    Arm("GT3", WINGEOM,
        "    if dt < best:\n      best = dt\n      zone = dzOutsideTop\n",
        "    if false:\n      best = dt\n      zone = dzOutsideTop\n",
        G_TOP,
        "the margin above the layout never names the top dock: a drag cannot "
        "reach it"),
    Arm("GM1", WINTOP,
        "      x = px + w\n",
        "      x = px\n",
        G_POPOVER,
        "a nested menu popover opens over its parent instead of to its right"),
    Arm("GK1", WINTOP,
        "      inBindings = raw.startsWith(\"bindings:\")\n",
        "      inBindings = raw.startsWith(\"binding:\")\n",
        G_BINDINGS,
        "the window reads no binding from the desktop's config: no chord "
        "works, none is shown"),
    Arm("GP1", WINTOP,
        "    if pin.overlaps(c):\n      return false\n",
        "    if false:\n      return false\n",
        G_PINSHOWN,
        "a pane's pin button is drawn over (and pressed through) the pane "
        "revealed on top of it, or a drag's drop tint"),
    Arm("GS1", WINTOP,
        "  of \"pagedown\": 1\n",
        "  of \"pagedown\": 0\n",
        G_TABKEYS,
        "the window's next-session-tab key does nothing"),
    # --- session tabs from the terminal's keyboard (§3.3.1) ----------------------
    Arm("TK1", KEYMAP,
        "  r.add b(mmNormal, \"g t\", @[\"g\", \"t\"], kaNextSessionTab)\n",
        "  r.add b(mmNormal, \"g t\", @[\"g\", \"t\"], kaPrevSessionTab)\n",
        T_TABKEYS,
        "`g t` steps to the PREVIOUS session tab"),
    Arm("TK2", KEYNAMES,
        "    if parts.len == 2 and parts[0] == \"9\":\n",
        "    if false:\n",
        T_TABKEYS,
        "the `CSI u` spelling of Ctrl+Tab is not a key: the terminals that "
        "report Ctrl+Tab that way cannot step the tabs"),
    # --- GPUI's drawing, read from the window's own render plan ------------------
    Arm("GW1", GPUIMAIN,
        "    var svg = svgMarkup(markFor(c.id)).replace(\"currentColor\", ink)\n",
        "    var svg = svgMarkup(markFor(TransportControls[0].id)).replace(\"currentColor\", ink)\n",
        W_BAND,
        "every debugger control in the window draws the first control's mark"),
    Arm("GW2", GPUIMAIN,
        "      r.setAttribute(icon, \"src\", markSvgPath(sg.index, on))\n",
        "      r.setAttribute(icon, \"src\", markSvgPath(sg.index, false))\n",
        W_BAND,
        "an enabled control is drawn in the disabled ink"),
    Arm("GW3", GPUIMAIN,
        "      r.appendChild(b, r.createTextNode(gMenu.root.children[sg.index].label))\n",
        "      r.appendChild(b, r.createTextNode(\"\"))\n",
        W_BAND,
        "the band's menu titles are drawn without their names"),
    Arm("GW4", GPUIMAIN,
        "    r.setAttribute(box, \"data-ct-menu-popover\", $p.folderPath)\n"
        "    r.setStyle(box, \"rounded\", \"6px\")\n"
        "    for (k, v) in paneOutlineStyle(true): r.setStyle(box, k, v)\n"
        "    gTopEls.add box\n",
        "    r.setAttribute(box, \"data-ct-menu-popover\", $p.folderPath)\n"
        "    r.setStyle(box, \"rounded\", \"6px\")\n"
        "    for (k, v) in paneOutlineStyle(true): r.setStyle(box, k, v)\n"
        "    gTopEls.insert(box, 0)\n",
        W_POPOVER,
        "the menu's popover is painted under the panes' pin buttons: a ⇲ "
        "shows through its rows"),
    Arm("GW5", GPUIMAIN,
        "                               gMenu.shortcutFor(\n"
        "                                 TransportControls[gHoverControl].clientAction))\n",
        "                               \"\")\n",
        W_HOVER,
        "a hovered control's label names it without the chord that runs it"),
    Arm("GW6", GPUIMAIN,
        "      r.appendChild(box, pane)\n      gOverlay.add box\n",
        "      discard pane\n      gOverlay.add box\n",
        W_REVEAL,
        "the window's reveal overlay is an empty box, not the docked pane"),
    Arm("GW7", GPUIMAIN,
        "  # UNPIN on a revealed pane (the PIN buttons are drawn before the\n"
        "  # popovers, below).\n  if gGestures.revealing:\n",
        "  # UNPIN on a revealed pane (the PIN buttons are drawn before the\n"
        "  # popovers, below).\n  if false:\n",
        W_REVEAL,
        "a revealed pane has no Unpin button: it cannot be placed back from "
        "the reveal"),
    Arm("GW8", GPUIMAIN,
        "    let shown = revealed.isSome and $revealed.get == sl.pane\n",
        "    let shown = false\n",
        W_REVEAL,
        "the strip does not mark which docked pane is revealed"),
    Arm("GW9", GPUIMAIN,
        "    if not pinButtonShown(pr, covers):\n"
        "      continue\n",
        "    discard covers\n",
        W_TOP,
        "the window draws the tree's pin buttons over a pane revealed from "
        "the top strip"),
    Arm("GW10", GPUIMAIN,
        "          applyGestureCommand(r, cmdDock(k, leBottom))\n",
        "          applyGestureCommand(r, cmdDock(k, leRight))\n",
        W_PIN,
        "the pin button docks the pane to the right edge, not the footer"),
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
    state = Path(tempfile.gettempdir()) / f"plat48-mutation-state-{os.getuid()}"
    state.mkdir(parents=True, exist_ok=True)
    env["CODETRACER_TUI_LAYOUT_DIR"] = str(state)
    env["XDG_STATE_HOME"] = str(state)
    return env


def artefacts_for(path: str) -> tuple:
    stem = Path(path).stem
    base = Path(tempfile.gettempdir()) / f"plat48-mutation-{os.getuid()}"
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
                env["HOME"] = tempfile.mkdtemp(prefix="plat48-s1-home-")
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
