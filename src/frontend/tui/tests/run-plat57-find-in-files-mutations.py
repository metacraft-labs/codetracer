#!/usr/bin/env python3
"""PLAT-57 — the mutation harness for Find in Files on the three front-ends:
THE shared runner (`viewmodel/host/find_in_files`, `rg --json` or the
in-process walker), the shared matcher (`viewmodel/host/text_match`), the
one model (`SearchResultsVM`), the keymap rows of §5.3, the terminal's pane
and routes, the GPUI window's pane, and the desktop's panel over the runner in
Electron's main process.

    python3 src/frontend/tui/tests/run-plat57-find-in-files-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=R1,T2

Run from the repository root, inside the dev shell, with `REPLAY_SERVER_BIN`
exported (the real-PTY suite and the GPUI plan suite open the real
`multi_root` recording) and `rg` on `PATH` (FS-8 grades the walker against
it). The GPUI suite loads `libgpui_nim_shim` from `$ISONIM_GPUI_SHIM_DIR`
(else `../isonim-gpui/rust/target/debug`). The desktop arms run the REAL
Electron app on a prefix holding this checkout's desktop JavaScript and
stylesheets (`scripts/plat45-desktop-prefix.sh`, built into
`test-logs/plat57-desktop-prefix`), under an Xvfb started when no display is
set; the Playwright verdict decides.

ONE ARM PER CLAIM, each naming the case (or the gate) that must die:

  | claim | arms |
  |---|---|
  | `rg` is spawned with an argument vector and read as JSON | R1 (the pattern before `--`), R2 (the match position dropped), R3 (a base64 path left encoded), R4 (a CRLF line keeps its `\\r`) |
  | the walker visits what `rg` visits, in its order (FS-8) | R5 (the store's prefix kept), R6 (hidden entries read), R7 (a link followed), R8 (a binary file read), R9 (siblings in reverse order), R10 (a CRLF line's `\\r` kept), R18 (the JS walker reads binaries; a `Dirent` is `lstat`'s, so on node a link is never a file or a directory and no arm can plant "follows links" without adding code) |
  | the matcher is the expression `rg` builds (`-F`, `-i`, `-w`, or a regular expression) | R14 (case folded nowhere), R15 (no word boundary before), R20 (a literal's metacharacters read as an expression), R25 (an empty match one byte wide), R19 (`rg` given a regular expression as a fixed string), R24 (the walker searches a CRLF line without its `\\r`, which `rg` keeps) |
  | a pattern one engine would refuse is refused for both, with the reason | R21 (look-around, back-references, a line break let through), R22 (a pattern that does not compile run anyway) |
  | the scope is the desktop's rule | R16 (the store never preferred), R17 (a folder inside another searched twice) |
  | batches of 50; a new search cancels the old | R11 (no batching), R12 (the run in flight never cancelled), V1 (the ViewModel takes a stale run's batch) |
  | the one model | V2 (rows grouped under the wrong index), V3 (`next` stops at the end), V4 (the summary counts rows as files), V5 (the highlight split one byte long), V6 (a toggle does not search again), V7 (the search runs without the pane's options), V8 (`.*` flips whole word), V9 (the toggles' operations named in the wrong order) |
  | §5.3's rows and the field's toggle rows are data over named operations | K1 (CUA `F4` walks backward), K2 (Emacs `Alt+G N` walks backward), K3 (`Alt+R` in the field flips case), K4 (the pane-focus `Alt+C` holds in the field too), K5 (`searchInputFocus` never true), K6 (the palette on `:grep` is not the field) |
  | the terminal | T1 (a press on the revealed pane lands under it), T2 (`:grep <text>` only opens the field), T3 (`:cnext` walks backward), T4 (a press lands on the row below), T5 (the toggles swapped), T6 (the loop never repaints a streamed batch), T7 (the Edit menu's Find in Files does nothing), T8 (the host drops every batch), T9 (the match not painted), T10 (the omnibox on `:grep` is not the field in the scope path), T11 (every field key flips case), T12 (the `.*` toggle not drawn) |
  | GPUI | G1 (the match not drawn), G2 (a press lands on the row below), G3 (the Edit menu's Find in Files does nothing), G4 (`F4` walks backward), G5 (the toggles swapped), G6 (`:grep` never shows the pane), G7 (the omnibox on `:grep` is not the field in the scope path), G8 (every field key flips case), G9 (a toggle drawn off whatever it is) |
  | the desktop's view | N1 (the mock renderer's match not wrapped), N2 (the field is not Find in Files' query field in the scope path) |
  | the desktop, real Electron | D1 (`:grep foo` searches for `grep foo`), D2 (the main process drops the match position), D3 (the omnibox stays open), D4 (`F4` does nothing), D5 (the web renderer's match not wrapped), D6 (the web `Aa` toggles whole word), D7 (the main process passes no scope), D8 (the web field is not the search field in the scope path), D9 (every field key flips case), D10 (the main process drops the regular-expression option) |

THREE VERDICTS (Verification-Harness-Traps §1): `killed` (the named case
reported [FAILED], or the named gate failed), `SURVIVED` (the case [OK] / the
gate green), `HARNESS-FAILURE` (the needle was not unique, the suite did not
compile, the mutated binary did not build, or the run printed no result
lines). A run that prints nothing is never a kill.

Every Nim suite is run FILTERED to its killer case, so an arm costs one case;
the control runs each suite filtered to its NAMED cases (`isonim_views_test`
holds an unrelated known failure, `loadStepLinesFor`) and must see every
killer [OK].

THE BINARY IS PART OF THE SUBJECT: an arm graded by the real-PTY suite
rebuilds `build/bin/codetracer-tui` with the defect (`just build-tui`), one
graded by the GPUI plan suite `build/bin/codetracer-gpui` (`just build-gpui`);
a desktop arm rebuilds the prefix's `index.js` / `ui.js`. The restored tree's
binaries are rebuilt before the harness exits.

RESTORATION is from an in-memory snapshot, and every touched file's SHA-256
is compared with the pre-run baseline after each arm (§32). The full run
refuses unless the needle scan is clean AND every touched file matches
`plat57-find-in-files-mutation-control.sha256`.

NO DECLARED SURVIVORS.

No mocks: every suite graded here runs the product's own runner on a real
corpus on the real filesystem against the real `rg`, the product's own
runtime and shell on a real PTY with a real recording, the shipped GPUI
binary's window plan, and the real Electron app. The desktop view's Tier-1
cases record what the panel asks its host for in place of the main process
(their file says why).
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]            # .../codetracer

# --- subjects ---------------------------------------------------------------
RUNNER = "src/frontend/viewmodel/host/find_in_files.nim"
MATCH = "src/frontend/viewmodel/host/text_match.nim"
VM = "src/frontend/viewmodel/viewmodels/search_results_vm.nim"
CUA = "src/frontend/viewmodel/keymap/cua_keymap.nim"
EMACS = "src/frontend/viewmodel/keymap/emacs_keymap.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
TPANE = "src/frontend/tui/app/views/search_results_pane.nim"
TSESSION = "src/frontend/tui/host/tui_session.nim"
THOST = "src/frontend/tui/host/native_host.nim"
TMAIN = "src/frontend/tui/main.nim"
GLEAF = "src/frontend/gpui/search_results_leaf.nim"
GMAIN = "src/frontend/gpui/main.nim"
DVIEW = "src/frontend/viewmodel/views/isonim_search_results_view.nim"
DINTERP = "src/frontend/ui/command_interpreter.nim"
DCOMMAND = "src/frontend/ui/command.nim"
DPANEL = "src/frontend/ui/search_results.nim"
DMAIN = "src/frontend/index/ipc_utils.nim"
CONTEXT = "src/frontend/viewmodel/keymap/context_keys.nim"
OMNIBAR = "src/frontend/viewmodel/viewmodels/omnibar_vm.nim"

# --- suites and gates ---------------------------------------------------------
VMU = "src/frontend/viewmodel/tests/unit/test_plat57_find_in_files.nim"
VMUJS = VMU + "#js"
VNAT = "src/tests/gui/tests/views/isonim_views_test.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat57_find_in_files_pty.nim"
GPLAN = "src/frontend/gpui/tests/test_plat57_gpui_find_in_files.nim"
SPEC = "src/tests/gui/tests/search/find-in-files.spec.ts"
DESKTOP_GATE = SPEC + "#electron"

SUBJECTS = [RUNNER, MATCH, VM, CUA, EMACS, RUNTIME, TPANE, TSESSION, THOST,
            TMAIN, GLEAF, GMAIN, DVIEW, DINTERP, DCOMMAND, DPANEL, DMAIN,
            CONTEXT, OMNIBAR]
SUITES = [VMU, VMUJS, VNAT, PTY, GPLAN, DESKTOP_GATE]


def suite_file(path: str) -> str:
    """The file a suite key names (a backend's `#<tag>` suffix dropped)."""
    return path.split("#", 1)[0]


TOUCHED = list(dict.fromkeys(SUBJECTS + [suite_file(p) for p in SUITES]))

# How each suite is run: (backend, lane whose `--path`s it needs).
SUITE_KIND = {
    VMU: ("c", "vm-unit"),
    VMUJS: ("js", "vm-unit-js"),
    VNAT: ("c", "vm-native"),
    PTY: ("c", "tui-real-terminal"),
    GPLAN: ("c", "gpui-shell"),
    DESKTOP_GATE: ("electron", ""),
}
BINARY_SUITES = {PTY}
  # graded against a REBUILT codetracer-tui
GPUI_BINARY_SUITES = {GPLAN}
  # read the WINDOW's render plan of a REBUILT codetracer-gpui
UNFILTERED_CONTROL: set = {DESKTOP_GATE}
  # the gate has no cases to filter by

CONTROL_HASHES = HERE / "plat57-find-in-files-mutation-control.sha256"
SUITE_TIMEOUT = int(os.environ.get("CT_P57_SUITE_TIMEOUT", "3600"))
SHIM = Path(os.environ.get("ISONIM_GPUI_SHIM_DIR",
                           str(ROOT.parent / "isonim-gpui/rust/target/debug")))
PREFIX = ROOT / "test-logs" / "plat57-desktop-prefix"
RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*\s*(.*?)\s*$")

# --- the killer cases, spelled once ------------------------------------------
U_ARGV = "rg is given an argument vector, JSON output and the pattern after --"
U_JSON = "rg --json is read as JSON: a drive letter and a path:line: text survive"
U_MATCH = "the matcher: literal, case-folded rune by rune, whole words as rg -w"
U_SCOPE = "the scope: the store when it is preferred and present, else folders"
U_FS8 = "every pattern, every option, the same rows in the same order"
U_WHAT = ("what is searched: no hidden entry, no binary file, no link, the "
          "store's prefix gone")
U_BATCH = "batches of 50, the last one done"
U_CANCEL = "a second search leaves no row of the first, however late it streams"
U_GROUP = "rows grouped by file in arrival order; next and previous wrap"
U_KEYS = "F4 / Shift+F4 under CUA, Alt+G N / Alt+G P under Emacs, anywhere"
U_REGEX = ("the matcher: regular expressions, and whole words inside the "
           "expression")
U_REFUSE = ("a regular expression the two engines do not share is refused, "
            "with rg's reason")
U_FS8R = "regular expressions: every pattern, every toggle, the same rows"
U_REFUSED = "a refused pattern: rg refuses it too, and either engine says why"
U_FIELD = ("the field's toggles: Alt+C / Alt+W / Alt+R where Find in Files' "
           "field has the focus")
U_TOGGLE = "a toggle flips the option and runs the search again, regex included"
J_WHAT = U_WHAT + "#js"
N_HIGHLIGHT = "the runner's match is wrapped in a search-results-highlight span"
N_TOGGLE = "Aa, ab and .* toggle the options and run the search again"
N_BAR = "renders the search bar, the query input, and the body container"
P_ALL = (":grep shows the pane with the sources' rows; a click opens one, the "
         "tick stays; :cnext; Aa; the menu")
G_ROWS = ("`:grep` in the omnibox: the pane lists the oracle's rows, grouped, "
          "highlighted")
G_MENU = "the Edit menu's Find in Files, then the query: the same rows"
G_OPEN = "a press on a result opens its file at its line; the tick stays"
G_F4 = "F4 opens the first result, again the next; Shift+F4 the previous"
G_CASE = "Match Case runs the search again, case-sensitively"
G_KEYS = ("the field's keys: Alt+R makes the query a regular expression, "
          "Alt+C flips the case")
D_DESKTOP = "gate:" + DESKTOP_GATE

CASE_SUITE = {
    U_ARGV: VMU, U_JSON: VMU, U_MATCH: VMU, U_SCOPE: VMU, U_FS8: VMU,
    U_WHAT: VMU, U_BATCH: VMU, U_CANCEL: VMU, U_GROUP: VMU, U_KEYS: VMU,
    U_REGEX: VMU, U_REFUSE: VMU, U_FS8R: VMU, U_REFUSED: VMU, U_FIELD: VMU,
    U_TOGGLE: VMU,
    J_WHAT: VMUJS,
    N_HIGHLIGHT: VNAT, N_TOGGLE: VNAT, N_BAR: VNAT,
    P_ALL: PTY,
    G_ROWS: GPLAN, G_MENU: GPLAN, G_OPEN: GPLAN, G_F4: GPLAN, G_CASE: GPLAN,
    G_KEYS: GPLAN,
    D_DESKTOP: DESKTOP_GATE,
}
NAMED_CASES = list(CASE_SUITE)


def case_name(killer: str) -> str:
    """The case's name as the suite prints it (a backend tag dropped)."""
    return killer.split("#", 1)[0]


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
    # --- the runner: `rg` ------------------------------------------------------
    Arm("R1", RUNNER,
        '  result.add @["--no-ignore", "--no-messages", "--sort", "path", "--",\n'
        '               pattern]\n',
        '  result.add @["--no-ignore", "--no-messages", "--sort", "path",\n'
        '               pattern, "--"]\n',
        U_ARGV, "the pattern goes before `--`: a pattern starting with `-` is a flag"),
    Arm("R2", RUNNER,
        '    first = subs[0]{"start"}.getInt(-1)\n',
        '    discard\n',
        U_JSON, "rg's submatch is dropped: the row has no match position"),
    Arm("R3", RUNNER,
        '      return decode(node["bytes"].getStr)\n',
        '      return node["bytes"].getStr\n',
        U_JSON, "a path rg prints as base64 bytes is left encoded"),
    Arm("R4", RUNNER,
        '  if result.endsWith("\\r"):\n    result.setLen(result.len - 1)\n',
        '  if false:\n    result.setLen(result.len - 1)\n',
        U_JSON, "a CRLF line read from rg keeps its carriage return"),
    # --- the runner: the walker ------------------------------------------------
    Arm("R5", RUNNER,
        "  if scope.stripPrefix.len > 0 and path.startsWith(scope.stripPrefix) and\n",
        "  if false and path.startsWith(scope.stripPrefix) and\n",
        U_WHAT, "a row names the store's path, not the recording's source path"),
    Arm("R6", RUNNER,
        "        if name.len == 0 or name[0] == '.' or kind == wekOther:\n",
        "        if name.len == 0 or kind == wekOther:\n",
        U_WHAT, "the walker reads hidden entries rg skips"),
    Arm("R7", RUNNER,
        "          of pcLinkToFile, pcLinkToDir: wekOther\n",
        "          of pcLinkToFile, pcLinkToDir: wekFile\n",
        U_WHAT, "the walker follows a symbolic link rg does not"),
    Arm("R8", RUNNER,
        "      if text.find('\\0') >= 0:\n",
        "      if false:\n",
        U_WHAT, "the walker reads a binary file rg skips"),
    Arm("R9", RUNNER,
        "      children.sort(proc(a, b: (string, WalkEntryKind)): int = cmp(a[0], b[0]))\n",
        "      children.sort(proc(a, b: (string, WalkEntryKind)): int = cmp(b[0], a[0]))\n",
        U_FS8, "the walker visits siblings in the reverse of rg's path order"),
    Arm("R10", RUNNER,
        "  let stop = min(stop, result.text.len)\n",
        "  let stop = stop\n",
        U_WHAT, "a match reaching into a CRLF's carriage return is kept past "
                "the row's text"),
    Arm("R24", RUNNER,
        "    let line = content[start ..< stop]\n",
        "    let line = content[start ..< stop].strip(leading = false, "
        "chars = {'\\r'})\n",
        U_FS8R, "the walker searches a CRLF line without the `\\r` rg keeps "
                "(`\\s$` answers differently)"),
    Arm("R18", RUNNER,
        "      if buf.indexOf(0).to(int) >= 0:\n",
        "      if false:\n",
        J_WHAT, "the JS walker (Electron's main process) reads a binary file"),
    # --- the runner: streaming and cancellation --------------------------------
    Arm("R11", RUNNER,
        "  if run.pending.len >= FindInFilesBatchSize:\n",
        "  if false:\n",
        U_BATCH, "every row is held to the end: no batches stream"),
    Arm("R12", RUNNER,
        "  if not service.current.isNil:\n    service.current.cancel()\n",
        "  if not service.current.isNil:\n    discard\n",
        U_CANCEL, "a new search leaves the one in flight running"),
    # --- the matcher -----------------------------------------------------------
    Arm("R14", MATCH,
        "              else: {regexCaseless}\n",
        "              else: RegexFlags({})\n",
        U_MATCH, "the case-insensitive default compares runes exactly"),
    Arm("R15", MATCH,
        '    result = "(?<!\\\\w)(?:" & result & ")(?!\\\\w)"\n',
        '    result = "(?:" & result & ")(?!\\\\w)"\n',
        U_MATCH, "whole word ignores the character before the match"),
    Arm("R25", MATCH,
        "  (true, found.boundaries.a, found.boundaries.b + 1)\n",
        "  (true, found.boundaries.a, max(found.boundaries.a + 1, found.boundaries.b + 1))\n",
        U_REGEX, "an empty match is reported one byte wide"),
    Arm("R19", RUNNER,
        '  if not options.regex:\n    result.add "--fixed-strings"\n',
        '  if true:\n    result.add "--fixed-strings"\n',
        U_ARGV, "rg is given a regular expression as a fixed string"),
    Arm("R20", MATCH,
        "  result = if options.regex: pattern else: escapeRe(pattern)\n",
        "  result = pattern\n",
        U_MATCH, "a literal's metacharacters are read as an expression"),
    Arm("R21", MATCH,
        "    let refused = refusalOf(pattern)\n",
        '    let refused = ""\n',
        U_REFUSE, "look-around, back-references and a line break are let "
                  "through to nim-regex, which `rg` refuses"),
    Arm("R22", RUNNER,
        "  if not compiled.ok:\n    run.finish(note = compiled.error)\n    return\n",
        "  if false:\n    run.finish(note = compiled.error)\n    return\n",
        U_REFUSED, "a pattern that does not compile runs anyway: the walker "
                   "finds nothing and says nothing"),
    # --- the scope -------------------------------------------------------------
    Arm("R16", RUNNER,
        "  if preferStore and store.len > 0 and directoryExists(store):\n",
        "  if false:\n",
        U_SCOPE, "the materialised store is never searched"),
    Arm("R17", RUNNER,
        "    if not inside and r notin result:\n",
        "    if r notin result:\n",
        U_SCOPE, "a source folder inside another is searched twice"),
    # --- the one model -----------------------------------------------------------
    Arm("V1", VM,
        "  if runId != vm.runId:\n    return false\n",
        "  if false:\n    return false\n",
        U_CANCEL, "the ViewModel takes a batch of a search that is not its latest"),
    Arm("V2", VM,
        "    result[at[key]].rows.add (i, r)\n",
        "    result[at[key]].rows.add (result[at[key]].rows.len, r)\n",
        U_GROUP, "a grouped row carries its index in the group, not in results"),
    Arm("V3", VM,
        "  ((at + delta) mod n + n) mod n\n",
        "  clamp(at + delta, 0, n - 1)\n",
        U_GROUP, "the next result after the last is the last"),
    Arm("V4", VM,
        '    resultCountLabel(n) & " in " & countLabel(vm.groups.val.len, "file", "files")\n',
        '    resultCountLabel(n) & " in " & countLabel(n, "file", "files")\n',
        U_GROUP, "the summary counts a file per row"),
    Arm("V5", VM,
        "  (true, row.text[lead ..< a], row.text[a ..< b], row.text[b .. ^1])\n",
        "  (true, row.text[lead ..< a], row.text[a .. b], row.text[b + 1 .. ^1])\n",
        U_GROUP, "the highlighted run is a byte longer than the runner's match"),
    Arm("V6", VM,
        "  if vm.query.val.len > 0:\n    vm.search(vm.query.val)\n",
        "  if false:\n    vm.search(vm.query.val)\n",
        N_TOGGLE, "a toggle changes the option but not the rows"),
    Arm("V7", VM,
        "    vm.onSearch(id, query, vm.options.val)\n",
        "    vm.onSearch(id, query, TextMatchOptions())\n",
        N_TOGGLE, "the runner is asked without the pane's options"),
    Arm("V8", VM,
        "  of soRegex: o.regex = not o.regex\n",
        "  of soRegex: o.wholeWord = not o.wholeWord\n",
        U_TOGGLE, "`.*` flips whole word"),
    Arm("V9", VM,
        '    ["search.toggle-case", "search.toggle-whole-word", "search.toggle-regex"]\n',
        '    ["search.toggle-whole-word", "search.toggle-case", "search.toggle-regex"]\n',
        U_TOGGLE, "a toggle's operation names the other toggle"),
    # --- the keymaps -------------------------------------------------------------
    Arm("K1", CUA,
        '    BaseRow(chords: "F4", operation: "search.next-result", table: G),\n',
        '    BaseRow(chords: "F4", operation: "search.previous-result", table: G),\n',
        U_KEYS, "CUA's F4 walks the results backward"),
    Arm("K2", EMACS,
        '    BaseRow(chords: "Alt+G N", operation: "search.next-result", table: G),\n',
        '    BaseRow(chords: "Alt+G N", operation: "search.previous-result", table: G),\n',
        U_KEYS, "Emacs's Alt+G N walks the results backward"),
    Arm("K3", CUA,
        '    BaseRow(chords: "Alt+R", operation: "search.toggle-regex",\n',
        '    BaseRow(chords: "Alt+R", operation: "search.toggle-case",\n',
        U_FIELD, "CUA's Alt+R in the field flips case"),
    Arm("K4", CUA,
        '            whenText: "!findWidgetVisible && !searchInputFocus", table: G),\n',
        '            whenText: "!findWidgetVisible", table: G),\n',
        U_FIELD, "the pane-focus Alt+C holds in the field as well: two rows "
                 "for one key"),
    Arm("K5", CONTEXT,
        "  result.values[ckSearchInputFocus] = b(inputFocus and f.id == SearchQueryInput)\n",
        "  result.values[ckSearchInputFocus] = b(false)\n",
        U_FIELD, "`searchInputFocus` is never true"),
    Arm("K6", OMNIBAR,
        "  if classifyOmnibarQuery(query).mode == omProgram:\n"
        "    element(ekInput, SearchQueryInput)\n",
        "  if false:\n"
        "    element(ekInput, SearchQueryInput)\n",
        U_FIELD, "the palette on `:grep` is not Find in Files' field"),
    # --- the terminal ------------------------------------------------------------
    Arm("T1", RUNTIME,
        "  if geometry.revealing and geometry.reveal.contains(row, col):\n"
        "    return (true, PaneRegion(pane: geometry.revealPane, area: geometry.reveal,\n",
        "  if false:\n"
        "    return (true, PaneRegion(pane: geometry.revealPane, area: geometry.reveal,\n",
        P_ALL, "a press on the revealed pane lands on the pane under it"),
    Arm("T2", RUNTIME,
        "      rt.app.omnibar.close()\n      rt.runFindInFiles(needle, outcome)\n",
        "      rt.app.omnibar.close()\n      rt.openFindInFiles(outcome)\n",
        P_ALL, "`:grep <text>` in the omnibox opens the field and searches nothing"),
    Arm("T3", RUNTIME,
        '      rt.stepFindInFiles((if words[0] in ["cnext", "cn"]: 1 else: -1),\n',
        '      rt.stepFindInFiles((if words[0] in ["cnext", "cn"]: -1 else: 1),\n',
        P_ALL, "`:cnext` opens the previous result"),
    Arm("T4", TPANE,
        "  let i = model.clampScrollTop(model.scrollTop, screen.listRows) +\n"
        "          (row - screen.listTop)\n",
        "  let i = model.clampScrollTop(model.scrollTop, screen.listRows) +\n"
        "          (row - screen.listTop) + 1\n",
        P_ALL, "a press on a result lands on the row below it"),
    Arm("T5", TSESSION,
        "  vm.toggleOption(which)\n  s.refreshSearch(rt)\n",
        "  vm.toggleOption(if which == soCase: soWord else: which)\n"
        "  s.refreshSearch(rt)\n",
        P_ALL, "the terminal's Aa flips whole word"),
    Arm("T6", TMAIN,
        "      let searched = session.pumpFindInFiles(rt)\n",
        "      let searched = false\n      discard session.pumpFindInFiles(rt)\n",
        P_ALL, "a streamed batch never repaints the pane"),
    Arm("T7", RUNTIME,
        '  if action == "findInFiles":\n    rt.openFindInFiles(outcome)\n',
        '  if action == "findInFiles":\n    discard\n',
        P_ALL, "the Edit menu's Find in Files does nothing"),
    Arm("T8", THOST,
        "        discard vm.acceptBatch(b.runId, b.rows, b.done, b.note))\n",
        "        discard vm.acceptBatch(b.runId + 1, b.rows, b.done, b.note))\n",
        P_ALL, "the native host hands every batch to the wrong run"),
    Arm("T9", TPANE,
        "        StyledSpan(text: r.hit, style: SearchHitStyle),\n",
        "        StyledSpan(text: r.hit, style: SearchTextStyle),\n",
        P_ALL, "the terminal paints the match as plain text"),
    Arm("T10", RUNTIME,
        "                                 paletteFieldOf(rt.app.omnibar.query)],\n",
        '                                 element(ekInput, "palette-query")],\n',
        P_ALL, "the terminal's omnibox on `:grep` is not the field: its "
               "toggle keys do nothing"),
    Arm("T11", RUNTIME,
        "            else: rt.app.toggleSearchOption(res.operation))\n",
        '            else: rt.app.toggleSearchOption("search.toggle-case"))\n',
        P_ALL, "every one of the terminal's field keys flips case"),
    Arm("T12", TPANE,
        "    for i, o in model.options:\n",
        "    for i, o in model.options[0 ..< min(2, model.options.len)]:\n",
        P_ALL, "the terminal draws no `.*` toggle"),
    # --- GPUI --------------------------------------------------------------------
    Arm("G1", GLEAF,
        "      if d.hit.len > 0:\n        let hit = textRun(r, d.hit, SearchTextColour, SearchHitGround)\n",
        "      if false:\n        let hit = textRun(r, d.hit, SearchTextColour, SearchHitGround)\n",
        G_ROWS, "GPUI draws no match run"),
    Arm("G2", GLEAF,
        "  let i = st.visibleTop(rows.len, lay.rows) + (y - lay.list.y) div SearchRowPx\n",
        "  let i = st.visibleTop(rows.len, lay.rows) + (y - lay.list.y) div SearchRowPx + 1\n",
        G_OPEN, "GPUI's press lands on the row below"),
    Arm("G3", GMAIN,
        '  of "findInFiles": openFindInFiles(r)\n',
        '  of "findInFiles": discard\n',
        G_MENU, "GPUI's Edit menu Find in Files does nothing"),
    Arm("G4", GMAIN,
        '    stepSearchResult(r, (if res.operation == "search.next-result": 1 else: -1))\n',
        '    stepSearchResult(r, (if res.operation == "search.next-result": -1 else: 1))\n',
        G_F4, "GPUI's F4 opens the previous result"),
    Arm("G5", GMAIN,
        "  vm.toggleOption(which)\n  traceGesture(",
        "  vm.toggleOption(if which == soCase: soWord else: which)\n  traceGesture(",
        G_CASE, "GPUI's Aa flips whole word"),
    Arm("G6", GMAIN,
        "  traceGesture(\"find in files '\" & pattern & \"'\")\n"
        "  showPaneFromMenu(r, paneSearch)\n",
        "  traceGesture(\"find in files '\" & pattern & \"'\")\n",
        G_ROWS, "GPUI's `:grep` searches but never shows the pane"),
    Arm("G7", GMAIN,
        "             paletteFieldOf(gOmnibar.query)]\n",
        '             element(ekInput, "palette-query")]\n',
        G_KEYS, "GPUI's omnibox on `:grep` is not the field: its toggle keys "
                "do nothing"),
    Arm("G8", GMAIN,
        "    toggleSearchOption(r, searchOptionOf(res.operation).option)\n",
        "    toggleSearchOption(r, soCase)\n",
        G_KEYS, "every one of GPUI's field keys flips case"),
    Arm("G9", GLEAF,
        '    r.setAttribute(b, "data-ct-active", $on)\n',
        '    r.setAttribute(b, "data-ct-active", $false)\n',
        G_KEYS, "GPUI draws every toggle off"),
    # --- the desktop's view (mock renderer) --------------------------------------
    Arm("N1", DVIEW,
        "  let textSpan = result.children[1]\n  if parts.matched:\n",
        "  let textSpan = result.children[1]\n  if false:\n",
        N_HIGHLIGHT, "the mock renderer's row wraps no match"),
    Arm("N2", DVIEW,
        "  r.setAttribute(inputEl, ScopeIdAttribute, SearchQueryInput)\n",
        "  r.setAttribute(inputEl, ScopeIdAttribute, PaletteQueryInput)\n",
        N_BAR, "the mock panel's field is not Find in Files' query field"),
    # --- the desktop, real Electron ----------------------------------------------
    Arm("D1", DINTERP,
        "    SearchQuery(kind: ProgramQuery, value: cstring(classified.needle))\n",
        "    SearchQuery(kind: ProgramQuery, value: cstring(($query)[1 .. ^1]))\n",
        D_DESKTOP, "the desktop's `:grep foo` searches for `grep foo`"),
    Arm("D2", DMAIN,
        "                matchStart: r.matchStart, matchLength: r.matchLength}\n",
        "                matchStart: 0, matchLength: 0}\n",
        D_DESKTOP, "the main process sends rows without the runner's match"),
    Arm("D3", DCOMMAND,
        "    self.interpreter.searchProgram(self.query.value)\n    self.resetCommandPalette()\n",
        "    self.interpreter.searchProgram(self.query.value)\n",
        D_DESKTOP, "the omnibox stays open, its query in it, after `:grep`"),
    Arm("D4", DPANEL,
        "  if i >= 0:\n    discard vm.openResult(i)\n",
        "  if i >= 0:\n    discard i\n",
        D_DESKTOP, "the desktop's F4 neither selects nor opens a result"),
    Arm("D5", DVIEW,
        "    let parts = rowParts(row)\n    if parts.matched:\n",
        "    let parts = rowParts(row)\n    if false:\n",
        D_DESKTOP, "the web renderer's row wraps no match"),
    Arm("D6", DVIEW,
        "      span(class = optionClass(false, which), title = SearchOptionTitles[which],\n"
        "           onclick = proc() = vm.toggleOption(which)):\n",
        "      span(class = optionClass(false, which), title = SearchOptionTitles[which],\n"
        "           onclick = proc() = vm.toggleOption(if which == soCase: soWord else: which)):\n",
        D_DESKTOP, "the web panel's Aa flips whole word"),
    Arm("D7", DMAIN,
        "  let scope = findInFilesScope(store, imported, folders)\n",
        "  let scope = findInFilesScope(\"\", false, newSeq[string]())\n",
        D_DESKTOP, "the main process hands the runner none of the trace's scope"),
    Arm("D8", DVIEW,
        "                                                cstring(SearchQueryInput))\n",
        "                                                cstring(PaletteQueryInput))\n",
        D_DESKTOP, "the web panel's field is not the search field: Alt+C "
                   "focuses the call trace"),
    Arm("D9", DPANEL,
        "  if known:\n    searchResultsVMInstance.toggleOption(which)\n",
        "  if known:\n    searchResultsVMInstance.toggleOption("
        "searchOptionOf(\"search.toggle-case\").option)\n",
        D_DESKTOP, "every one of the desktop's field keys flips case"),
    Arm("D10", DMAIN,
        "    regex: request.regex.to(bool))\n",
        "    regex: false)\n",
        D_DESKTOP, "the main process searches every pattern literally"),
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
    # Never the user's own remembered layout.
    state = Path(tempfile.gettempdir()) / f"plat57-mutation-state-{os.getuid()}"
    state.mkdir(parents=True, exist_ok=True)
    env["CODETRACER_TUI_LAYOUT_DIR"] = str(state)
    env["XDG_STATE_HOME"] = str(state)
    return env


def artefacts_for(path: str) -> tuple:
    stem = Path(suite_file(path)).stem + ("-js" if path.endswith("#js") else "")
    base = Path(tempfile.gettempdir()) / f"plat57-mutation-{os.getuid()}"
    base.mkdir(parents=True, exist_ok=True)
    return str(base / stem), str(base / f"nc-{stem}")


def print_tail(path: str, out: str, n: int, why: str) -> None:
    print(f"      ---- {path}: {why}; last {n} lines ----")
    for line in [l for l in out.splitlines()
                 if "keysym" not in l and "xkbcomp" not in l][-n:]:
        print("      " + line)


def build_prefix() -> tuple:
    """This checkout's desktop JavaScript as a prefix, its stylesheets
    compiled from this checkout's `.styl` (the built variant's are not)."""
    if PREFIX.exists() or PREFIX.is_symlink():
        shutil.rmtree(PREFIX, ignore_errors=True)
    shutil.rmtree(str(PREFIX) + ".build", ignore_errors=True)
    p = subprocess.run(["bash", "scripts/plat45-desktop-prefix.sh", str(PREFIX),
                        "src/config/default_layout.json"], cwd=ROOT,
                       capture_output=True, text=True, timeout=SUITE_TIMEOUT)
    if p.returncode != 0:
        return False, p.stdout + p.stderr
    frontend = PREFIX / "frontend"
    built = frontend.resolve()
    frontend.unlink()
    (frontend / "styles").mkdir(parents=True)
    for e in built.iterdir():
        if e.name != "styles":
            (frontend / e.name).symlink_to(e.resolve())
    for e in (built / "styles").iterdir():
        (frontend / "styles" / e.name).symlink_to(e.resolve())
    stylus = ROOT / "node_modules" / ".bin" / "stylus"
    for theme in ("default_dark_theme_electron", "default_white_theme_electron"):
        (frontend / "styles" / f"{theme}.css").unlink(missing_ok=True)
        s = subprocess.run([str(stylus), f"src/frontend/styles/{theme}.styl",
                            "-o", str(frontend / "styles") + "/"], cwd=ROOT,
                           capture_output=True, text=True, timeout=600)
        if s.returncode != 0:
            return False, s.stdout + s.stderr
    return True, ""


def run_electron(path: str) -> RunResult:
    """The real desktop: this checkout's desktop JavaScript in a prefix, the
    Playwright spec run against it. Playwright's own summary decides: `1
    passed` is green, `1 failed` a kill, anything else (no test ran, the
    prefix did not build) is not a verdict."""
    ok, why = build_prefix()
    if not ok:
        print_tail(path, why, 15, "the desktop prefix did not build")
        return RunResult(rc=1, ran=False)
    env = suite_env()
    env["CODETRACER_REPO_ROOT_PATH"] = str(ROOT)
    env["CODETRACER_TEST_PREFIX"] = str(PREFIX)
    env.setdefault("CODETRACER_ELECTRON_ARGS",
                   "--no-sandbox --no-zygote --disable-gpu "
                   "--disable-gpu-compositing --disable-dev-shm-usage")
    xvfb = None
    try:
        if not env.get("DISPLAY") and sys.platform.startswith("linux"):
            n = 99
            while Path(f"/tmp/.X{n}-lock").exists():
                n += 1
            xvfb = subprocess.Popen(["Xvfb", f":{n}", "-screen", "0",
                                     "2560x1440x24", "-dpi", "96",
                                     "-nolisten", "tcp"],
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
            import time
            time.sleep(1)
            env["DISPLAY"] = f":{n}"
        spec = os.path.relpath(ROOT / suite_file(path), ROOT / "src/tests/gui")
        proc = subprocess.run(["npx", "playwright", "test", spec],
                              cwd=ROOT / "src/tests/gui", capture_output=True,
                              text=True, timeout=SUITE_TIMEOUT,
                              encoding="utf-8", errors="replace", env=env)
    except subprocess.TimeoutExpired:
        return RunResult(rc=1, ran=False, hung=True)
    finally:
        if xvfb is not None:
            xvfb.kill()
            xvfb.wait()
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode, output=out)
    name = "gate:" + path
    if re.search(r"^\s*\d+ passed", out, re.M) and proc.returncode == 0:
        res.passed.append(name)
    elif re.search(r"^\s*\d+ failed", out, re.M):
        res.failed.append(name)
    else:
        res.ran = False
        print_tail(path, out, 15, "no Playwright verdict")
    return res


def run_one(path: str, case=None) -> RunResult:
    backend, lane = SUITE_KIND[path]
    if backend == "electron":
        return run_electron(path)
    binary, nimcache = artefacts_for(path)
    flags = ["--hints:off", "--warnings:off", *lane_flags(lane),
             "--nimcache:" + nimcache]
    names = case if isinstance(case, list) else ([case] if case else [])
    filt = [case_name(c) for c in names]
    source = suite_file(path)
    try:
        if backend == "js":
            out_js = binary + ".js"
            comp = subprocess.run(
                ["nim", "js", "-d:nodejs", *flags, "-o:" + out_js, source],
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
                ["nim", "c", "-r", *flags, "-o:" + binary, source, *filt],
                cwd=ROOT, capture_output=True, text=True,
                timeout=SUITE_TIMEOUT, encoding="utf-8", errors="replace",
                env=suite_env())
    except subprocess.TimeoutExpired:
        print(f"      ---- {path}: NO RESULT AFTER {SUITE_TIMEOUT}s ----")
        return RunResult(rc=1, ran=False, hung=True)
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode, output=out)
    tag = "#js" if path.endswith("#js") else ""
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(
                m.group(2) + tag)
    if res.total == 0:
        res.ran = False
        print_tail(path, out, 20, "no result lines")
    return res


def build(recipe: str) -> bool:
    p = subprocess.run(["just", recipe], cwd=ROOT, capture_output=True,
                       text=True, timeout=SUITE_TIMEOUT)
    if p.returncode != 0:
        print_tail(recipe, p.stdout + p.stderr, 15, f"just {recipe} failed")
    return p.returncode == 0


def build_for(suite: str) -> bool:
    """Rebuild the binary a suite grades, if it grades one."""
    if suite in BINARY_SUITES:
        return build("build-tui")
    if suite in GPUI_BINARY_SUITES:
        return build("build-gpui")
    return True


_ACTIVE: list | None = None
_DIRTY: set = set()
  # binaries last built from a MUTATED tree ("tui", "gpui")


def rebuild_restored() -> bool:
    """Rebuild every binary a mutant left behind, from the restored tree."""
    ok = True
    if "tui" in _DIRTY:
        ok = build("build-tui") and ok
    if "gpui" in _DIRTY:
        ok = build("build-gpui") and ok
    _DIRTY.clear()
    shutil.rmtree(PREFIX, ignore_errors=True)
    shutil.rmtree(str(PREFIX) + ".build", ignore_errors=True)
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
        if f'test "{case_name(name)}"' not in read_source(suite_file(where)):
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
    if shutil.which("rg") is None:
        print("REFUSING TO RUN: `rg` is not on PATH (FS-8 grades the walker "
              "against it)")
        return 1

    baseline = {p: digest(p) for p in TOUCHED}
    install_restore_on_signal()

    wanted = [a for a in ARMS if not only or a.id in only]
    print("\n== control ==")
    if any(CASE_SUITE[a.killer] in BINARY_SUITES for a in wanted) and \
       not build("build-tui"):
        print("CONTROL: the unmutated terminal binary does not build")
        return 1
    if any(CASE_SUITE[a.killer] in GPUI_BINARY_SUITES for a in wanted) and \
       not build("build-gpui"):
        print("CONTROL: the unmutated GPUI binary does not build")
        return 1
    for path in SUITES:
        if not any(CASE_SUITE[a.killer] == path for a in wanted):
            continue
        named = [c for c in NAMED_CASES if CASE_SUITE[c] == path]
        control = run_one(path, None if path in UNFILTERED_CONTROL else named)
        if control.failed or not control.ran or control.rc != 0:
            print(f"CONTROL IS NOT GREEN: {path} rc={control.rc} "
                  f"failed={control.failed}")
            return 1
        missing = [c for c in named if c not in control.passed]
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
                    rebuild_restored()
                    return 2
            if suite in BINARY_SUITES:
                _DIRTY.add("tui")
            elif suite in GPUI_BINARY_SUITES:
                _DIRTY.add("gpui")
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
