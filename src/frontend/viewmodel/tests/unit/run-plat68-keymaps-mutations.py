#!/usr/bin/env python3
"""PLAT-68 Phase A — the mutation harness for the base keymaps.

Each arm plants ONE defect in a decoder, the resolver, the selector, the
`when` evaluator, the CUA data, the CUA specification, or the terminal
restore; REBUILDS the shipped `codetracer-tui` when the defect is compiled
into it and an arm is graded through it; runs the suites that must catch it;
and requires RED — with the failure the first run recorded
(`plat68-keymaps-mutation-because.json`, derived with `--derive`).

The discipline is PLAT-43's and PLAT-44's harnesses', clause for clause:
committed control digests over subjects AND suites (§16c), a needle scan that
gates re-recording (§39a), `because` derived from a run, rc 124 is a hang
(§1), per-arm restore verification, one declared behaviour-preserving
survivor, and `ci/lib/harness_guard.py`'s argument rule before anything is
touched.

THREE THINGS PARTICULAR TO THIS MILESTONE:

  * **SUBJECTS OUTSIDE THIS REPOSITORY.** The CUA specification lives in the
    specification checkout (`$CT_SPECS_DIR`, else `../codetracer-specs`), and
    the restore the terminal relies on lives in `nim-termctl`
    (`$NIM_TERMCTL_SRC`, else `../nim-termctl/src`). Both are named by a
    prefix (`specs:`, `nim-termctl:`) in the control file, mutated and
    restored like any other subject.
  * **AN ARM MAY EDIT TWO FILES.** O2 changes a CUA chord in the data AND in
    CUA-Keymap.md, so the oracle — which compares the two — stays GREEN and
    only the VS Code extractor can kill it. O2 REQUIRES the oracle green: an
    O2 killed by the oracle would be an arm aimed at the wrong gate.
  * **AN ARM MAY BE GRADED BY ONE TEST.** The milestone asks that a decoder
    dropping `Shift` from `Ctrl+Shift+K` die *on the document* (it then
    deletes nothing and inserts nothing). The pty suite checks the key
    synthesiser first, so D1 is graded by the sequence test alone, through
    Nim's unittest filter — the `because` it records is the document's.

PHASE B (the `B*` arms) adds the router, the layer stack, the three front
ends' scope paths and the coordinator's additions, graded through the suites
that hold them: the ViewModel's own (`test_plat68_layers`), the terminal's
real pty (`test_plat68b_pty`, which REBUILDS `codetracer-tui`), GPUI's window
plan (`test_plat68_gpui_keys_plan`, which REBUILDS `codetracer-gui`), the
cross-front-end differential (`test_plat68_diff13`), the desktop's editing
table under node, and `isonim-tui`'s propagation suite (`isonim-tui:` is
`$ISONIM_TUI_SRC`, else `../isonim-tui/src`). The builds run
`$PLAT68_BUILD_TUI` / `$PLAT68_BUILD_GPUI` when set (a worktree whose
submodules `just build-tui` refuses), else the `just` recipes.

Usage:
    run-plat68-keymaps-mutations.py [--only D1,O2] [--derive]
    run-plat68-keymaps-mutations.py --needle-scan
    run-plat68-keymaps-mutations.py --record-control-hashes
"""
import argparse
import re
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[5]
HERE = Path(__file__).resolve().parent
CONTROL = HERE / "plat68-keymaps-mutation-control.sha256"
BECAUSE = HERE / "plat68-keymaps-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat68-mutations"
BIN = REPO / "build/bin/codetracer-tui"
TIMEOUT = 3600

GPUI_BIN = REPO / "build/bin/codetracer-gpui"

ROOTS = {
    "": REPO,
    "isonim-tui:": Path(os.environ.get("ISONIM_TUI_SRC") or
                        REPO.parent / "isonim-tui/src"),
    "specs:": Path(os.environ.get("CT_SPECS_DIR") or
                   REPO.parent / "codetracer-specs"),
    "nim-termctl:": Path(os.environ.get("NIM_TERMCTL_SRC") or
                         REPO.parent / "nim-termctl/src"),
}

NAMES = "src/common/key_names.nim"
KEYMAP = "src/frontend/viewmodel/keymap/editing_keymap.nim"
SELECTION = "src/frontend/viewmodel/keymap/keymap_selection.nim"
WHEN = "src/frontend/viewmodel/keymap/when_expr.nim"
CUA = "src/frontend/viewmodel/keymap/cua_keymap.nim"
CUA_SPEC = "specs:spec/GUI/CUA-Keymap.md"
RESTORE = "nim-termctl:nim_termctl/posix_backend.nim"

DECODING = "src/frontend/viewmodel/tests/unit/test_plat68_key_decoding.nim"
BASES = "src/frontend/viewmodel/tests/unit/test_plat68_base_keymaps.nim"
ORACLE = "src/frontend/viewmodel/tests/unit/test_plat68_cua_oracle.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat68_keymaps_pty.nim"
EXTRACTOR = "ci/test/cua-keymap-extractor.sh"

# Phase B subjects.
ROUTER = "src/frontend/viewmodel/keymap/keymap_router.nim"
STACK = "src/frontend/viewmodel/keymap/layer_stack.nim"
IMPORTERS = "src/frontend/viewmodel/keymap/keymap_importers.nim"
CORE = "src/frontend/viewmodel/editing_core.nim"
ROLES = "src/frontend/tui/app/theme/roles.nim"
CHROME = "src/frontend/gpui/chrome.nim"
TUI_MAIN = "src/frontend/tui/main.nim"
DRIVER = "src/frontend/tui/host/terminal_driver.nim"
MOTIONS = "src/frontend/tui/app/input/motions.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
MONACO = "src/frontend/ui/monaco_operations.nim"
DISPATCH = "isonim-tui:isonim_tui/event_dispatch.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
ALT_TAP = "src/frontend/viewmodel/keymap/alt_tap.nim"
PRODUCT_MENU = "src/frontend/viewmodel/viewmodels/product_menu.nim"
TOP_BAR = "src/frontend/tui/app/views/top_bar.nim"
OPERATIONS = "src/frontend/viewmodel/editor/operations.nim"
NAVIGATION = "src/frontend/viewmodel/keymap/navigation_keymap.nim"
EMACS = "src/frontend/viewmodel/keymap/emacs_keymap.nim"
CAPS = "src/frontend/tui/app/theme/capabilities.nim"
USER_KEYMAP = "src/frontend/viewmodel/keymap/user_keymap.nim"

# Phase B suites.
LAYERS = "src/frontend/viewmodel/tests/unit/test_plat68_layers.nim"
PTYB = "src/frontend/tui/tests/real_terminal/test_plat68b_pty.nim"
GPUIK = "src/frontend/gpui/tests/test_plat68_gpui_keys_plan.nim"
DIFF13 = "src/frontend/tui/tests/test_plat68_diff13.nim"
PARITY = "src/frontend/tui/tests/test_plat51b_parity.nim"
PLAT28 = "src/frontend/tui/tests/test_plat28_edit_breakpoints.nim"
NOCONF = "src/frontend/tui/app/tests/test_keymap_no_conflicts.nim"
MONACO_T = "src/frontend/tests/monaco_operations_test.nim"
PROPAGATION = "isonim-tui:../tests/test_event_propagation.nim"
MENU = "src/frontend/viewmodel/tests/unit/test_plat68_menu_access.nim"

SUBJECTS = [NAMES, KEYMAP, SELECTION, WHEN, CUA, CUA_SPEC, RESTORE,
            ROUTER, STACK, IMPORTERS, CORE, ROLES, CHROME, TUI_MAIN, DRIVER,
            MOTIONS, GPUI_MAIN, MONACO, DISPATCH, RUNTIME, ALT_TAP,
            PRODUCT_MENU, TOP_BAR, OPERATIONS, NAVIGATION, EMACS, CAPS,
            USER_KEYMAP]
SUITES = [DECODING, BASES, ORACLE, PTY, EXTRACTOR, "tools/cua-keymap-extractor.py",
          LAYERS, PTYB, GPUIK, DIFF13, PARITY, PLAT28, NOCONF, MONACO_T,
          PROPAGATION, MENU]

SEQUENCE = "*::the milestone's sequence, Ctrl+S, and the file on disk"
RESTORED = "*::the pop or the reset is written on SIGTERM, SIGHUP and a crash"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
# A suite listed with `GREEN` as its filter must stay green (O2's oracle).
ARMS = [
    ("D1", [(NAMES, "  if (bits and 1) != 0: result.incl kmodShift", "  discard")],
     [(PTY, SEQUENCE)],
     "the decoder drops Shift: Ctrl+Shift+K deletes nothing, inserts nothing"),
    ("D2", [(NAMES, "              of 1, 7: \"Home\"", "              of 7: \"Home\"")],
     [(DECODING, None)],
     "Home's `CSI 1 ~` spelling decodes as \"\" again"),
    ("D3", [(NAMES, "    if c == eraseByte: decoded({}, \"Backspace\")",
             "    if c == '\\x7f': decoded({}, \"Backspace\")")],
     [(DECODING, None)],
     "VERASE is ignored: a ^H terminal's Backspace reads as Ctrl+Backspace"),
    ("R1", [(RESTORE, "    writeAllSafe(STDOUT_FILENO, kittyPopSeqLocal)",
             "    discard")],
     [(PTY, RESTORED)],
     "the terminal's restore omits the Kitty pop"),
    ("T1", [(KEYMAP, "  of bkCua, bkEmacs: NoPendingTimeout",
             "  of bkCua: EditingPendingTimeoutMs\n  of bkEmacs: NoPendingTimeout")],
     [(BASES, None)],
     "CUA given Vim's 1000 ms timeout"),
    ("M1", [(SELECTION, "  if name == RetiredDefaultName:", "  if false:")],
     [(BASES, None)],
     "the stored `default` is not migrated"),
    ("W1", [(WHEN, "  of wkNot: not evalWhen(e.operand, c)",
             "  of wkNot: evalWhen(e.operand, c)")],
     [(BASES, None)],
     "a `when` negation is ignored"),
    ("O1", [(CUA, "    BaseRow(chords: \"Ctrl+Shift+K\", operation: \"editor.delete-line\", whenText: Writable),",
             "    BaseRow(chords: \"Ctrl+Shift+J\", operation: \"editor.delete-line\", whenText: Writable),")],
     [(ORACLE, None)],
     "a CUA chord edited in the data and not in CUA-Keymap.md"),
    ("O2", [(CUA, "    BaseRow(chords: \"Ctrl+Shift+K\", operation: \"editor.delete-line\", whenText: Writable),",
             "    BaseRow(chords: \"Ctrl+Shift+J\", operation: \"editor.delete-line\", whenText: Writable),"),
            (CUA_SPEC, "| `Ctrl+Shift+K` | E | `editor.delete-line` |",
             "| `Ctrl+Shift+J` | E | `editor.delete-line` |"),
            (CUA_SPEC, "| `editor.delete-line` | `Ctrl+Shift+K` |",
             "| `editor.delete-line` | `Ctrl+Shift+J` |")],
     [(ORACLE, "GREEN"), (EXTRACTOR, None)],
     "a CUA chord edited in the data AND in CUA-Keymap.md: VS Code disagrees"),
    ("N1", [(WHEN, "  of wkNot: not evalWhen(e.operand, c)",
             "  of wkNot: not(evalWhen(e.operand, c))")],
     [(BASES, None)],
     "behaviour-preserving: the DECLARED SURVIVOR"),

    # ---- Phase B: the router, the layer stack, the front ends ------------
    ("B1", [(ROUTER, "  for source in [lsUser, lsBase]:",
             "  for source in [lsBase, lsUser]:")],
     [(LAYERS, None)],
     "KL-11: the base answers before the user's rows"),
    ("B2", [(STACK, "  if s.layers.len > 0 and s.layers[^1].token == token:",
             "  if s.layers.len > 0:")],
     [(LAYERS, None)],
     "KL-5: a pop takes the top layer whatever token it is given"),
    ("B3", [(ROUTER, "  if router.base.isModal: ($navMode).toUpperAscii",
             "  if true: ($navMode).toUpperAscii")],
     [(PTYB, "*::CUA shows its name, never NORMAL*")],
     "the status line says NORMAL under CUA"),
    ("B4", [(CUA, "    BaseRow(chords: \"Enter\", operation: \"editor.toggle-tracepoint\",",
             "    BaseRow(chords: \"Ctrl+Alt+Enter\", operation: \"editor.toggle-tracepoint\",")],
     [(PTYB, "*::Enter opens the tracepoint editor*"),
      (GPUIK, "*::Enter opens the tracepoint editor*")],
     "Enter in the read-only editor no longer opens the tracepoint editor"),
    ("B5", [(ROLES, "                             dtColorsUiSurfacePrimaryDefault, attrs = {raBold},",
             "                             dtColorsUiBorderSecondary, attrs = {raBold},")],
     [(PTYB, "*::the selected tab's ground*")],
     "the focused strip's selected tab back on the strip's own ground"),
    # RE-AIMED 2026-10-19: since the window's redesign its strips draw the
    # selected tab's ground inline (`main.nim`) rather than through
    # `chrome.tabStyle`, so the arm's old line no longer reached the window
    # and it survived on `agents`. Aimed at the line that draws it; the claim
    # and the mutation are unchanged.
    ("B6", [(GPUI_MAIN, "          r.setStyle(tab, \"background-color\", chromeOf(crTabStripBackground))",
             "          r.setStyle(tab, \"background-color\", chromeOf(crFocusOutline))")],
     [(GPUIK, "*::its ground differs*")],
     "GPUI: the focused strip's selected tab back on the focus colour"),
    ("B7", [(CUA, "    BaseRow(chords: \"Home\", operation: \"editor.move-line-start-smart\", whenText: \"editorTextFocus\"),",
             "    BaseRow(chords: \"Home\", operation: \"editor.move-line-start\", whenText: \"editorTextFocus\"),")],
     [(PTYB, "*::Smart Home*"), (GPUIK, "*::Home is smart*")],
     "Home is not smart"),
    ("B8", [(CUA, "    BaseRow(chords: \"Shift+Down\", operation: \"editor.extend-line-down\", whenText: \"editorTextFocus\"),",
             "    BaseRow(chords: \"Shift+Down\", operation: \"editor.extend-line-down\", whenText: Writable),")],
     [(GPUIK, "*::Shift+Down selects*")],
     "selection refused in the read-only editor"),
    ("B9", [(CORE, "  d.state.selection = singleSelection(d.state.selection.mainRange.anchor,",
             "  d.state.selection = singleSelection(d.offsetAt(line, column),")],
     [(PTYB, "*::a pointer drag*"), (GPUIK, "*::a pointer drag*")],
     "a pointer drag moves the caret and selects nothing"),
    ("B10", [(TUI_MAIN, "    epilogue.add osc52Copy(rt.app.clipboard)",
              "    discard")],
     [(PTYB, "*::Shift+End selects to the line's end*")],
     "a copy never reaches the terminal's clipboard (no OSC 52)"),
    ("B11", [(TUI_MAIN, "    epilogue.add ClipboardQuery",
              "    discard")],
     [(PTYB, "*::paste asks the terminal*")],
     "a paste never asks the terminal for its clipboard"),
    ("B12", [(GPUI_MAIN, "      copyToClipboard(copied, $copied.countLines & \" line(s)\")",
              "      discard copied")],
     [(GPUIK, "*::Shift+Down selects*")],
     "GPUI: a copy never reaches the window's clipboard"),
    ("B13", [(ROUTER, "        if removes(r, b): inc router.removed",
              "        if false: inc router.removed")],
     [(LAYERS, None)],
     "a user's `-command` row removes nothing"),
    ("B14", [(GPUI_MAIN, "    result.add element(ekEditor, \"editor:\" & path)",
              "    discard path")],
     [(DIFF13, None)],
     "GPUI's scope path loses the editor element (DIFF-13)"),
    ("B15", [(MOTIONS, "  pf.heldPane = if atWindow: pf.focusedIndex() else: -1",
              "  pf.heldPane = -1")],
     [(DIFF13, "*::closing the palette hands the focus back*")],
     "a closed overlay hands the focus to the first pane, not back"),
    ("B16", [(DRIVER, "    nextTerminalNodeId = kept",
              "    discard kept")],
     [(PTYB, "*::Enter opens the tracepoint editor*")],
     "a frame resets the node ids under the long-lived focus tree"),
    ("B17", [(IMPORTERS, "      if removed: inc result.translated",
              "      if removed: discard")],
     [(NOCONF, None)],
     "the .cttui-keys import miscounts its removal rows"),
    ("B18", [(MONACO, "    \"clipboard-copy\": \"editor.action.clipboardCopyAction\",",
              "    \"clipboard-copy\": \"editor.action.clipboardCutAction\",")],
     [(MONACO_T, None)],
     "the desktop's Ctrl+C is Monaco's cut"),
    ("B19", [(DISPATCH, "    runListeners(path[i], ev, capture = true)",
              "    discard")],
     [(PROPAGATION, None)],
     "isonim-tui: no capture phase"),
    ("B20", [(STACK, "  if active.len > 0: active[0].label else: \"\"",
              "  \"\"")],
     [(PTYB, "*::CUA shows its name, never NORMAL*")],
     "an open palette does not name itself on the status line"),
    ("B21", [(RUNTIME, "  if mode == omCommand and",
              "  if false and")],
     [(PTY, "*::`--keymap` holds for one session and is not stored")],
     "the palette fuzzy-picks an entry for a typed `:` command line"),

    # ---- The program menu from the keyboard (CUA-Keymap.md §3.8) ----------
    ("B22", [(PRODUCT_MENU, "    folder(\"Debug\", mnemonic = 'd', children = @[",
              "    folder(\"Debug\", mnemonic = 'g', children = @[")],
     [(MENU, "*::Alt+<mnemonic> opens that folder*")],
     "the menu underlines a letter the keymap does not bind"),
    ("B23", [(ALT_TAP, "  t.armed = false  # a chord now, or a click: no tap on the release",
              "  discard")],
     [(MENU, "*::a key, a second modifier or a pointer press*"),
      (GPUIK, "*::Alt+D opens Debug*")],
     "Alt held through a chord still opens the menu on release"),
    ("B24", [(TOP_BAR, "                CellStyle(role: role, bold: it.active, underline: true))",
              "                CellStyle(role: role, bold: it.active))")],
     [(PTYB, "*::Alt+` opens the menu*")],
     "the terminal's menu does not underline its access keys"),
    ("B25", [(GPUI_MAIN, "        r.setStyle(key, \"text-decoration\", \"underline\")",
              "        discard key")],
     [(GPUIK, "*::Alt pressed and released alone*")],
     "GPUI's menu does not underline its access keys"),
    ("B26", [(GPUI_MAIN, "  if gAltTap.modifiersChanged(keyModifiersOfGpui(mods)):",
              "  if false:")],
     [(GPUIK, "*::Alt pressed and released alone*")],
     "GPUI never recognises Alt pressed and released alone"),
    ("B27", [(RUNTIME, "  if res.kind == erOperation and res.operation in MenuOperations:",
              "  if false:")],
     [(PTYB, "*::Alt+` opens the menu*")],
     "the open terminal menu swallows `` Alt+` `` instead of closing"),
    ("B28", [(ROUTER, "      result.reason = nrDisabled",
              "      discard")],
     [(LAYERS, None)],
     "a key inert in this product mode does not say so (Mode-Transitions §8.1)"),

    # ---- The user's two remaining reports, on their own logic -------------
    ("B29", [(OPERATIONS, "  landing(if r.head == firstNonBlank: a else: firstNonBlank)",
              "  landing(firstNonBlank)")],
     [(PTYB, "*::Smart Home*"), (GPUIK, "*::Home is smart*")],
     "Home always lands on the first non-blank: no alternation with column 1"),
    ("B30", [(CUA, "    BaseRow(chords: \"n\", operation: \"debugger.step-over\", whenText: RoDl, table: G),",
              "    BaseRow(chords: \"n\", operation: \"debugger.step-over\", whenText: Dl, table: G),")],
     [(LAYERS, "*::letters step in the read-only editor*"),
      (PTYB, "*::F10 steps; with the read-only editor focused*"),
      (GPUIK, "*::a letter steps while the read-only editor*")],
     "under CUA a letter no longer steps in the read-only editor"),
    ("B31", [(NAVIGATION, "    BaseRow(chords: \"Enter\", operation: \"editor.toggle-tracepoint\", table: G,",
              "    BaseRow(chords: \"Ctrl+Alt+Enter\", operation: \"editor.toggle-tracepoint\", table: G,")],
     [(LAYERS, "*::Enter opens the tracepoint editor under every base*")],
     "Vim / Kakoune: Enter in the read-only editor expands a tree node"),
    ("B32", [(EMACS, "    BaseRow(chords: \"Enter\", operation: \"editor.toggle-tracepoint\",",
              "    BaseRow(chords: \"Ctrl+Alt+Enter\", operation: \"editor.toggle-tracepoint\",")],
     [(LAYERS, "*::Enter opens the tracepoint editor under every base*")],
     "Emacs: Enter in the read-only editor does nothing"),
    # --- parent: the OSC 52 read on real terminals (measured 2026-10-24) ---
    ("H1", [(DRIVER, "  d.framer.altChordsAsCsiU = want == 1",
             "  d.framer.altChordsAsCsiU = false")],
     [(PTYB, "*::a LATE clipboard answer is not typed into the document*")],
     "a late OSC 52 answer is typed into the document as text"),
    ("H2", [(CAPS, "  if env.term in ClipboardReadPromptTerms or",
             "  if false and env.term in ClipboardReadPromptTerms or")],
     [(PTYB, "*::kitty's TERM: a paste does not ask*")],
     "kitty and Ghostty are asked, and their permission prompt takes the keys"),
    ("H3", [(RUNTIME, "  if not rt.caps.clipboardRead or not rt.clipboardRead.asks or",
             "  if not rt.clipboardRead.asks or")],
     [(PTYB, "*::kitty's TERM: a paste does not ask*")],
     "the paste ignores the terminal's clipboard-read capability"),

    # --- k4: precedence, the stack, the shadow and the loader ---------------
    # The milestone's own list of arms that Phase B did not carry: each is
    # aimed at the one case that holds it, so its `because` is that case's.
    ("G1", [(ROUTER, "  for i in countdown(path.len - 1, 0):",
             "  for i in 0 .. path.len - 1:")],
     [(LAYERS, "*::inside a base the inner scope goes first")],
     "§5.1: within the base, the outer scope answers before the inner"),
    ("G2", [(ROUTER, "  for source in [lsUser, lsBase]:\n"
                     "    for (table, atFocus) in router.tablesInOrder(path):",
             "  for (table, atFocus) in router.tablesInOrder(path):\n"
                     "    for source in [lsUser, lsBase]:")],
     [(LAYERS, None)],
     "the withdrawn draft: scope compared before source (B1's case, its "
     "cross-scope line rather than B1's same-table line)"),
    ("G3", [(ROUTER, "      let trie = trieFor(km, scope, table, laterFirst = source == lsUser)",
             "      let trie = trieFor(km, scope, table, laterFirst = false)")],
     [(LAYERS, "*::two user rows for one chord in one scope*")],
     "KL-11: of two user rows for one chord, the EARLIER fires"),
    ("G4", [(ROUTER, "        router.shadows.add Shadow(\n"
                     "          keyText: userRows[i].keyText, userIndex: userRows[i].index,\n"
                     "          shadowedSource: lsBase, shadowedOperation: b.operation,",
             "        discard Shadow(\n"
             "          keyText: userRows[i].keyText, userIndex: userRows[i].index,\n"
             "          shadowedSource: lsBase, shadowedOperation: b.operation,")],
     [(LAYERS, None)],
     "§5.6: a user row's shadow of a base row resolves but is not in the "
     "load report"),
    ("G5", [(STACK, "    else: next.layers.add l", "    next.layers.add l")],
     [(LAYERS, "*::closing the owner pops its layer")],
     "KL-5: an owner's unmount leaves its layer on the stack"),
    ("G6", [(KEYMAP, "      if node >= 0 and shadowDefeatedAt(layer, node):",
             "      if false:")],
     [(LAYERS, "*::a focused field's own row with a true `when` takes its character")],
     "§5.6: the text-entry shadow answers before the focused layer's true "
     "`when` (a find field's bound letter types itself)"),
    ("G7", [(USER_KEYMAP, "    fail(ueMalformedKey, \"'\" & keyNode.getStr & \"' names no key\")",
             "    return")],
     [(LAYERS, "*::one planted row per kind*")],
     "KL-7: the loader skips a malformed key instead of reporting it"),
]
DECLARED_SURVIVORS = {"N1"}
IN_BINARY = {NAMES, KEYMAP, SELECTION, WHEN, CUA, RESTORE, ROUTER, STACK,
             CORE, ROLES, TUI_MAIN, DRIVER, MOTIONS, RUNTIME, PRODUCT_MENU,
             TOP_BAR, OPERATIONS, CAPS}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {NAMES, KEYMAP, SELECTION, WHEN, CUA, ROUTER, STACK, CORE, CHROME,
           GPUI_MAIN, ALT_TAP, PRODUCT_MENU, OPERATIONS}
  # Subjects compiled into `codetracer-gpui`.
GPUI_SUITES = {GPUIK, DIFF13}
  # Suites that run the GPUI binary.


def path_of(rel):
    for prefix in sorted(ROOTS, key=len, reverse=True):
        if prefix and rel.startswith(prefix):
            return ROOTS[prefix] / rel[len(prefix):]
    return REPO / rel


def sha_path(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def sha(rel):
    return sha_path(path_of(rel))


def lane_flags(lane):
    return subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
                       f"test_lane_extra_flags {lane}"],
        cwd=REPO, capture_output=True, text=True, check=True).stdout.split()


def suite_flags(suite):
    if suite in (PTY, PTYB):
        return lane_flags("tui-real-terminal")
    if suite.startswith("src/frontend/tui/"):
        return lane_flags("tui")
    if suite.startswith("src/frontend/gpui/"):
        return lane_flags("gpui-shell") + ["--path:src/frontend/viewmodel"]
    return ["--path:src/frontend/viewmodel"]


def needle_scan():
    ok = True
    for arm_id, edits, *_ in ARMS:
        for rel, find, _ in edits:
            text = path_of(rel).read_text()
            n = text.count(find)
            if n != 1:
                print(f"  NEEDLE FAIL {arm_id}: {n} occurrence(s) in {rel}")
                ok = False
                continue
            end = text.index(find) + len(find)
            if end < len(text) and text[end] not in "\r\n" and \
                    not rel.endswith(".md"):
                print(f"  NEEDLE FAIL {arm_id}: does not end at a line end")
                ok = False
    print(f"needle scan: {len(ARMS)} arm(s), "
          f"{'every find occurs exactly once' if ok else 'FAILED'}")
    return ok


def record_controls():
    if not needle_scan():
        print("REFUSED: re-recording now would certify an unaimed arm (§39a).")
        return 1
    with open(CONTROL, "w") as f:
        f.write("# Control digests for run-plat68-keymaps-mutations.py — the\n"
                "# subjects AND the suites the arms are graded by (§16c).\n"
                "# `specs:` is $CT_SPECS_DIR, `nim-termctl:` is\n"
                "# $NIM_TERMCTL_SRC. Refreshed with --record-control-hashes,\n"
                "# gated by the needle scan (§39a).\n")
        for rel in SUBJECTS + SUITES:
            f.write(f"{sha(rel)}  {rel}\n")
    print(f"recorded {len(SUBJECTS) + len(SUITES)} control digests")
    return 0


def controls_match():
    if not CONTROL.exists():
        print("NO CONTROL DIGESTS — run --record-control-hashes first.")
        return False
    ok = True
    for line in CONTROL.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        digest, rel = line.split("  ", 1)
        if sha(rel) != digest:
            print(f"CONTROL DIGEST MOVED: {rel}")
            ok = False
    return ok


BUILD_REFUSALS = ["below the tab-contrast floor"]
  # A build the PRODUCT refuses on its own check, by its diagnostic: the
  # `roles.nim` compile-time assertion that the focused strip's selected tab
  # stands apart by the contrast floor. Graded as a kill on that line, as the
  # loader's `BaseRowError` is — the defect cannot reach a binary at all.


def build_with(env_var, recipe):
    """`(built, refusal)`: whether it built, and the product check's own
    diagnostic when the build was refused by one (`BUILD_REFUSALS`)."""
    cmd = os.environ.get(env_var)
    argv = ["bash", "-c", cmd] if cmd else ["just", recipe]
    p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                       timeout=TIMEOUT)
    out = p.stdout + p.stderr
    if p.returncode != 0:
        print(out[-2000:])
        for ln in out.splitlines():
            if any(r in ln for r in BUILD_REFUSALS):
                return False, ln.strip()
    return p.returncode == 0, ""


def build_binary():
    return build_with("PLAT68_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT68_BUILD_GPUI", "build-gpui")


def run_suite(suite, test_filter):
    if suite == EXTRACTOR:
        try:
            p = subprocess.run(["bash", EXTRACTOR], cwd=REPO,
                               capture_output=True, text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return "HUNG", []
        out = (p.stdout or "") + (p.stderr or "")
        failures = [ln.strip() for ln in out.splitlines()
                    if ln.startswith(("NOT REPRODUCED:", "NOT IN"))]
        if p.returncode == 0:
            return "GREEN", failures
        return ("RED", failures) if failures else ("DID-NOT-RUN", [])
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    env = dict(os.environ, CODETRACER_REPO_ROOT=str(REPO))
    try:
        if suite == MONACO_T:
            # `frontend-js`: compiled to JavaScript, run under node.
            out = f"{NIMCACHE}/{stem}.js"
            c = subprocess.run(
                ["nim", "-d:nodejs", "-d:chronicles_enabled=off",
                 "-d:ctRenderer", "-d:ctInExtension", "--hints:off",
                 "--warnings:off", "--path:src/frontend/viewmodel",
                 f"--nimcache:{NIMCACHE}/{stem}", f"--out:{out}", "js",
                 suite], cwd=REPO, capture_output=True, text=True,
                timeout=TIMEOUT, env=env)
            if c.returncode != 0:
                return "DID-NOT-COMPILE", []
            p = subprocess.run(
                ["node", "-e", "globalThis.window = globalThis; "
                 "require(process.argv[1])", out], cwd=REPO,
                capture_output=True, text=True, timeout=TIMEOUT, env=env)
        elif suite == PROPAGATION:
            # `isonim-tui`'s own suite, in its own checkout.
            # Its Justfile's flags: ORC, threads, its siblings on the path.
            root = ROOTS["isonim-tui:"].parent
            ws = root.parent
            p = subprocess.run(
                ["nim", "c", "-r", "--hints:off", "--warnings:off",
                 "--mm:orc", "-d:release", "--threads:on", "--path:src",
                 "--path:tests", f"--path:{ws}/isonim/src",
                 f"--path:{ws}/isonim-examples",
                 f"--path:{ws}/isonim-render-serve/src",
                 f"--path:{ROOTS['nim-termctl:']}",
                 f"--path:{ws}/nim-pty/src", f"--path:{ws}/nim-faststreams",
                 f"--path:{ws}/nim-stew", f"--path:{ws}/nim-everywhere/src",
                 f"--nimcache:{NIMCACHE}/{stem}", f"-o:{NIMCACHE}/{stem}.out",
                 str(path_of(suite))], cwd=root, capture_output=True,
                text=True, timeout=TIMEOUT, env=env)
        else:
            cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
                   f"--nimcache:{NIMCACHE}/{stem}",
                   f"-o:{NIMCACHE}/{stem}.out"] + suite_flags(suite) + [suite]
            if test_filter and test_filter != "GREEN":
                cmd.append(test_filter)
            p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                               timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 124:
        return "HUNG", []
    failures = [ln.strip().split("Check failed: ", 1)[1]
                for ln in out.splitlines() if "Check failed: " in ln]
    if p.returncode == 0:
        ran = out.count("[OK]")
        return ("GREEN", failures) if ran > 0 else ("RAN-NOTHING", [])
    # A base that does not hold together does not LOAD (`base_rows
    # .definitionOf` raises at module init): the suite dies before its first
    # case, on the loader's own diagnostic. That is a kill — by the product's
    # check rather than the suite's — and is graded as one, on that line.
    refused = [ln.strip() for ln in out.splitlines()
               if "BaseRowError" in ln and "unhandled exception" in ln.lower()]
    if refused:
        return "RED", refused[:1]
    if not failures and "Error:" in out and "[FAILED]" not in out:
        return "DID-NOT-COMPILE", failures
    if not failures:
        failures = [portable_cause(ln.strip()) for ln in out.splitlines()
                    if "[FAILED]" in ln or "Unhandled exception" in ln][:1]
    return "RED", failures


def portable_cause(line):
    """A pty suite's wait names its condition and then snapshots the status
    line (`never: Home to 3; status: … main.py:1  tick 1 …`). The snapshot
    carries the recording's own source path and the session's tick, which
    differ between checkouts, so the recorded cause keeps the condition and
    drops the snapshot."""
    head, sep, rest = line.partition("; status:")
    if not sep:
        return line
    tail = re.search(r" \[\w+\]$", rest)
    return head + (tail.group(0) if tail else "")


def grade(suites):
    """RED if a graded suite is red (and every `GREEN` suite is green); the
    first failure line across them."""
    first, verdict = "", "GREEN"
    for s, flt in suites:
        v, f = run_suite(s, flt)
        if v in ("HUNG", "DID-NOT-COMPILE", "DID-NOT-RUN", "RAN-NOTHING"):
            return v, ""
        if flt == "GREEN":
            if v != "GREEN":
                return "MISAIMED", f"{Path(s).name} went red: " + \
                    (f[0] if f else "")
            continue
        if v == "RED":
            verdict = "RED"
            if not first and f:
                first = f[0]
    return verdict, first


sys.path.insert(0, str(REPO / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def main():
    # AN UNDECLARED ARM ID, OR AN EMPTY `--only=`, IS REFUSED before anything
    # is touched (`ci/lib/harness_guard.py`).
    refused = refuse_undeclared_arms(sys.argv[1:], globals())
    if refused:
        return refused
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--derive", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    a = ap.parse_args()
    os.chdir(REPO)
    if a.needle_scan:
        return 0 if needle_scan() else 1
    if a.record_control_hashes:
        return record_controls()
    if not needle_scan() or not controls_match():
        print("the tree is not at the control bytes; nothing was mutated.")
        return 3
    only = set(filter(None, a.only.split(",")))
    selected = [arm for arm in ARMS if not only or arm[0] in only]
    needs_binary = any(s in (PTY, PTYB) for arm in selected for s, _ in arm[2])
    needs_gpui = any(s in GPUI_SUITES for arm in selected for s, _ in arm[2])
    binary_digest = None
    gpui_digest = None
    if needs_binary:
        if not build_binary()[0]:
            print("ABORT: the unmutated binary does not build.")
            return 1
        binary_digest = sha_path(BIN)
    if needs_gpui:
        if not build_gpui()[0]:
            print("ABORT: the unmutated GPUI binary does not build.")
            return 1
        gpui_digest = sha_path(GPUI_BIN)
    graded = sorted({s for arm in selected for s, _ in arm[2]})
    for s in graded:
        v, f = run_suite(s, None)
        if v != "GREEN":
            print(f"ABORT: the baseline of {s} is {v}: {f[:1]}")
            return 1
    print(f"baseline GREEN ({len(graded)} suite(s))")
    because = json.loads(BECAUSE.read_text()) if BECAUSE.exists() else {}
    digests = {rel: sha(rel) for rel in SUBJECTS}
    derived, bad = {}, []
    for arm_id, edits, suites, what in selected:
        files = sorted({rel for rel, _, _ in edits})
        backups = {}
        for rel in files:
            path = path_of(rel)
            backups[rel] = path.with_name(path.name + ".plat68bak")
            shutil.copy2(path, backups[rel])
        try:
            for rel, find, replace in edits:
                path = path_of(rel)
                path.write_text(path.read_text().replace(find, replace, 1))
            through_pty = any(s in (PTY, PTYB) for s, _ in suites)
            through_gpui = any(s in GPUI_SUITES for s, _ in suites)
            built, refusal = True, ""
            if through_pty and any(r in IN_BINARY for r in files):
                built, refusal = build_binary()
            if built and through_gpui and any(r in IN_GPUI for r in files):
                built, refusal = build_gpui()
            if not built:
                verdict, first = ("RED", refusal) if refusal else \
                    ("DID-NOT-COMPILE", "")
            else:
                verdict, first = grade(suites)
        finally:
            for rel in files:
                shutil.move(backups[rel], path_of(rel))
                if sha(rel) != digests[rel]:
                    print(f"ABORT: restore of {rel} failed after {arm_id}.")
                    return 1
        derived[arm_id] = first
        if arm_id in DECLARED_SURVIVORS:
            ok = verdict == "GREEN"
            mark = "SURVIVED (declared)" if ok else f"MISDIRECTED ({verdict})"
        elif verdict == "RED":
            want = because.get(arm_id)
            ok = a.derive or want is None or want == first
            mark = "KILLED" if ok else f"KILLED BY THE WRONG CHECK: {first!r}"
        else:
            ok = False
            mark = verdict if verdict != "GREEN" else "SURVIVED — NOT ENFORCED"
            if verdict == "MISAIMED":
                mark += f" ({first})"
        print(f"  {arm_id:<4} {mark:<30} {what}")
        if a.derive or not ok:
            print(f"       because: {first!r}")
        if not ok:
            bad.append(arm_id)
    if a.derive:
        merged = dict(because)
        merged.update({k: v for k, v in derived.items()
                       if k not in DECLARED_SURVIVORS})
        BECAUSE.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        print(f"derived {len(derived)} because line(s)")
    if binary_digest is not None:
        if not build_binary()[0] or sha_path(BIN) != binary_digest:
            print("FAIL: the binary rebuilt from the restored tree differs "
                  "from the one the run started with.")
            return 1
    if gpui_digest is not None:
        if not build_gpui()[0] or sha_path(GPUI_BIN) != gpui_digest:
            print("FAIL: the GPUI binary rebuilt from the restored tree "
                  "differs from the one the run started with.")
            return 1
    for rel in SUBJECTS:
        if sha(rel) != digests[rel]:
            print(f"FAIL: {rel} does not match its digest at exit.")
            return 1
    print(f"RESULT: {len(bad)} arm(s) not as required: {', '.join(bad) or '-'}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
