#!/usr/bin/env python3
"""The mutation harness for the desktop's shared editor (codetracer-pm
Editor-ViewModel.md §3.2a; the parity table is docs/shared-editor-parity.md).

Each arm plants ONE defect in the shared editor — the frame
(`view_vocabulary/editor_dom_frame.nim`), the DOM renderer
(`ui/shared_editor.nim`), Monaco's API over it (`ui/shared_editor_facade.nim`)
or its language features (`ui/shared_editor_lsp.nim`) — and must be killed by
the check the parity table names for that row (the arm's description cites
the row). The discipline is the PLAT-71 engine's (`plat71_mutation_engine.py`,
which this harness reuses): committed control digests over subjects AND
suites, a needle scan that gates re-recording, `because` derived from a run
and then required, per-arm restore verification.

Two kinds of suite grade the arms: the ViewModel unit suite (`nim c -r`,
`vm-unit`'s flags) and the renderer's browser suites (`nim js` and headless
Chromium, the `renderer-chromium` lane's runner), where the filter names the
cases to run (`CT_CHROMIUM_ONLY`).

Usage:
    run-plat67-shared-editor-mutations.py [--only ID,ID] [--derive]
    run-plat67-shared-editor-mutations.py --needle-scan
    run-plat67-shared-editor-mutations.py --record-control-hashes
"""
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "tui" / "tests"))
import plat71_mutation_engine as engine  # noqa: E402

FRAME = "src/frontend/view_vocabulary/editor_dom_frame.nim"
EDITOR = "src/frontend/ui/shared_editor.nim"
FACADE = "src/frontend/ui/shared_editor_facade.nim"
LSP = "src/frontend/ui/shared_editor_lsp.nim"
DIFF = "src/frontend/ui/shared_diff_editor.nim"

UNIT = "src/frontend/viewmodel/tests/unit/test_editor_dom_frame.nim"
BROWSER = "src/frontend/tests/shared_editor_chromium_test.nim"
LSP_SUITE = "src/frontend/tests/shared_editor_lsp_chromium_test.nim"

SUBJECTS = [FRAME, EDITOR, FACADE, LSP, DIFF]
SUITES = [UNIT, BROWSER, LSP_SUITE]
IN_BINARY = set()

U_FOLLOW = "the moved index equals a rebuilt one, for edits anywhere"
U_COLUMNS = "two-byte and four-byte characters convert both ways"
U_DECO_FOLLOW = "a decoration follows its line through a keystroke"
U_MARGIN = "margin classes go on the range's first line only"
U_INJECT = "injected content goes at the range's end"
U_FOLD = "a fold hides the deeper lines and keeps the trailing blank one"
U_LAYOUT = "zones push lines down and folds take them out"
U_SPANS = "tokens cut at decoration edges, the text concatenates back"
U_BRACKETS = "the bracket at the caret and its partner"
U_DIFF = "removed, added and changed runs, and nothing for equal text"


def unit(test):
    return (UNIT, "*::" + test)


def browser(case):
    return (BROWSER, case)


def lsp(case):
    return (LSP_SUITE, case)


# (id, [(subject, find, replace), ...], [(suite, filter), ...], the row)
ARMS = [
    # --- the frame -------------------------------------------------------------
    ("F1", [(FRAME, "    if ix.starts[mid] <= off: lo = mid",
             "    if ix.starts[mid] < off: lo = mid")],
     [unit("line starts, ends and the line of an offset")],
     "huge files: the line of an offset is off by one at a line start"),
    ("F2", [(FRAME, "    result += (if n == 4: 2 else: 1)",
             "    result += 1")],
     [unit(U_COLUMNS)],
     "IME / text entry: a four-byte character counts as one UTF-16 unit"),
    ("F3", [(FRAME, "    result.starts.add old.starts[i] + delta",
             "    result.starts.add old.starts[i]")],
     [unit(U_FOLLOW)],
     "huge files: the moved line index forgets the length change"),
    ("F4", [(FRAME, "      if line0 == la:",
             "      if true:")],
     [unit(U_MARGIN)],
     "breakpoints: a glyph is drawn on every line of its range"),
    ("F5", [(FRAME, "    t.mapThrough(d.timeline.delta(t.version), now)",
             "    t.version = now")],
     [unit(U_DECO_FOLLOW)],
     "decorations: a line's decoration stays put when a line is typed above"),
    ("F6", [(FRAME, "      if w <= own: break",
             "      if w <= own + 4: break")],
     [unit(U_FOLD)],
     "folding: a fold hides less than its block"),
    ("F7", [(FRAME, "    if z.afterLine >= line1: break",
             "    if z.afterLine >= line1 or true: break")],
     [unit(U_LAYOUT)],
     "view zones: the lines below a zone are not pushed down"),
    ("F8", [(FRAME, "    injectAfter(a, result)",
             "    discard a")],
     [unit(U_SPANS)],
     "inline values: the injected value chip is dropped"),
    ("F9", [(FRAME, "        if depth == 0: return (true, at, i)",
             "        if depth == 0: return (false, at, i)")],
     [unit(U_BRACKETS)],
     "editing: bracket matching from an opening bracket finds nothing"),
    ("F10", [(FRAME, "      dp[i][j] = if a[i] == b[j]: dp[i + 1][j + 1] + 1",
              "      dp[i][j] = if a[i] == b[j]: dp[i + 1][j + 1]")],
     [unit(U_DIFF)],
     "the unified diff: equal lines are not matched, every line reads changed"),
    # --- the renderer ----------------------------------------------------------
    ("R1", [(EDITOR, '        discard ed.insertText($ev.data.to(cstring), "keyboard")',
             '        discard ev')],
     [browser("caseTypingReachesTheCore")],
     "text entry: the text area's input never reaches the core"),
    ("R2", [(EDITOR, '      discard ed.insertText(committed, "ime")',
             '      discard committed')],
     [browser("caseImeComposition")],
     "IME: a composition's commit is dropped"),
    ("R3", [(EDITOR, "  ed.textarea.value = cstring(lt)",
             "  ed.textarea.value = cstring\"\"")],
     [browser("caseScreenReader")],
     "accessibility: the screen reader reads no line"),
    ("R4", [(EDITOR, '  ta.setAttr("tabindex", "0")',
             '  ta.setAttr("tabindex", "-1")')],
     [browser("caseFocusOrder")],
     "accessibility: the editor is out of the focus order"),
    ("R5", [(EDITOR, "  .ct-shared-editor .selected-text, .ct-shared-editor.focused .selected-text { background: Highlight !important; }",
             "  .ct-shared-editor .unused { background: Highlight !important; }")],
     [browser("caseHighContrast")],
     "accessibility: a forced-colours theme keeps the theme's selection"),
    ("R6", [(EDITOR, "    action = ed.pointer.pressEditor(d, press)",
             "    discard press")],
     [browser("caseClicksAndDrags")],
     "editing: a press does not place the caret or select"),
    ("R7", [(EDITOR, "    for c in deco.lineClasses:",
             "    for c in newSeq[string]():")],
     [browser("caseDecorationsAndZones")],
     "decorations: a whole-line class (the execution line) is not drawn"),
    ("R8", [(EDITOR, "    let zt = lay.zoneTop(ZoneSpec(id: z.id, afterLine: z.afterLine,",
             "    let zt = 0 + 0 * lay.zoneTop(ZoneSpec(id: z.id, afterLine: z.afterLine,")],
     [browser("caseDecorationsAndZones")],
     "view zones: a zone is drawn at the top, not under its line"),
    ("R9", [(EDITOR, "        ed.doc.state.folded.add line0",
             "        discard line0")],
     [browser("caseFolding")],
     "folding: the chevron does not fold"),
    ("R10", [(EDITOR, "    ed.doc.offerClipboard(t)",
              "    discard t")],
     [browser("caseMultipleCursorsAndClipboard")],
     "clipboard: a paste inserts the core's register, not the clipboard"),
    ("R11", [(EDITOR, "      r = ed.find.setQuery(d, value)",
              "      discard value")],
     [browser("caseFindAndReplace")],
     "find: typing into the field does not search"),
    ("R12", [(EDITOR, "    edits.add Edit(fromPos: m.a, toPos: m.b, insert: replacement)",
              "    discard m")],
     [browser("caseFindAndReplace")],
     "replace: Replace All replaces nothing"),
    ("R13", [(EDITOR, "  ed.setScroll(ed.scrollTop + int(dy), ed.scrollLeft + int(dx))",
              "  discard dy")],
     [browser("caseBracketsAndWheel")],
     "huge files: the wheel does not scroll"),
    ("R14", [(EDITOR, "  ed.doc = initEditingDocument(path, text, model, delivery = DesktopDelivery)\n  ed.doc.setReadOnly(readOnly)",
              "  ed.doc = initEditingDocument(path, text, model, delivery = DesktopDelivery)")],
     [browser("caseReadOnlyRefusesText")],
     "read-only mode: a read-only editor takes text"),
    ("R15", [(EDITOR, "  DesignTokenHex[t][if ed.darkTheme: dmDark else: dmLight]",
              "  DesignTokenHex[t][if ed.darkTheme: dmLight else: dmDark]")],
     [browser("caseRendersTheDocument")],
     "highlighting / theming: the tokens are painted in the other mode's colours"),
    ("R16", [(EDITOR, "    let sameLines = ed.index.lineCount == oldIx.lineCount",
              "    let sameLines = true")],
     [browser("caseRendersTheDocument"), browser("caseDecorationsAndZones")],
     "highlighting: a line-splitting edit keeps the stale tokens below it"),
    ("R19", [(EDITOR, "    ed.glyphLayer.appendChild(ed.glyphCell(line1, top, deco))",
              "    discard ed.glyphCell(line1, top, deco)")],
     [browser("caseDecorationsAndZones")],
     "decorations: the glyph decorations are not in Monaco's glyph layer"),
    ("R20", [(EDITOR, '  discard ed.findWidget.classList.add(cstring"visible")',
              '  discard ed.findWidget')],
     [browser("caseFindAndReplace")],
     "find: the open widget lacks Monaco's `visible` class"),
    ("R21", [(EDITOR, "  if beyond: max(0, ed.contentHeight - ed.lineHeight)",
              "  if beyond: max(0, ed.contentHeight - ed.textViewportHeight)")],
     [browser("caseScrollRangeAndViewState")],
     "scrolling: `scrollBeyondLastLine` is ignored"),
    ("A2", [(FACADE, "        ranges.add spanRange(clamp(int(jsNum(pair[0])), 0, size),\n                             clamp(int(jsNum(pair[1])), 0, size))",
             "        discard pair")],
     [browser("caseScrollRangeAndViewState")],
     "view state: a restored view state drops the selections"),
    ("R22", [(EDITOR, "            if b > a and xr >= (a + b) / 2 - 1.0: byteCol = nextCol",
              "            if b > a and xr >= b: byteCol = nextCol")],
     [browser("caseClicksAndDrags")],
     "pointer: a press on a character's middle leaves the caret before it"),
    ("R23", [(EDITOR, "    else:\n      w.node.setStyle(\"top\", cstring($w.top & \"px\"))\n      w.node.setStyle(\"transform\", \"none\")",
              "    else:\n      w.node.setStyle(\"top\", cstring($(w.top + ed.lineHeight) & \"px\"))\n      w.node.setStyle(\"transform\", \"none\")")],
     [browser("caseDecorationsAndZones")],
     "content widgets: an EXACT widget is drawn under its line"),
    ("R24", [(EDITOR, '      w.node.setStyle("visibility", "hidden")',
              '      discard 0')],
     [browser("caseDecorationsAndZones")],
     "content widgets: a widget off the view stays shown"),
    ("R17", [(DIFF, "      d.zoneIds.add d.modified.addZone(spec)",
              "      discard spec")],
     [browser("caseUnifiedDiff")],
     "the unified diff: the removed lines are not drawn"),
    ("R18", [(DIFF, '      o["className"] = cstring"line-insert"',
              '      o["className"] = cstring""')],
     [browser("caseUnifiedDiff")],
     "the unified diff: the added lines are not marked"),
    # --- Monaco's API over the core ---------------------------------------------
    ("A1", [(FACADE, '        """, markers, """(model, owner, all); return; }',
             '        return; }')],
     [lsp("caseDiagnostics")],
     "LSP diagnostics: the router's markers never reach the shared editor"),
    # --- the language features --------------------------------------------------
    ("L1", [(LSP, "        if t.len > 0: parts.add t",
             "        discard t")],
     [lsp("caseHover")],
     "LSP hover: the server's hover is not shown"),
    ("L2", [(LSP, "  if targetUri == uri:\n    let off = st.ed.offsetOfLsp(rng[\"start\"])",
             "  if targetUri == uri:\n    let off = st.ed.doc.state.primaryHead")],
     [lsp("caseDefinition")],
     "LSP go to definition: the caret does not move"),
    ("L3", [(LSP, "    if prefix.len > 0 and not label.toLowerAscii.startsWith(prefix.toLowerAscii):",
             "    if prefix.len > 0 and label.toLowerAscii.startsWith(prefix.toLowerAscii):")],
     [lsp("caseCompletion")],
     "LSP completion: the items matching the typed prefix are dropped"),
    ("L5", [(LSP, "    discard st.goToDefinition(at)))",
             "    discard at))")],
     [lsp("caseCtrlClickDefinition")],
     "LSP go to definition: Ctrl+click on a symbol does nothing"),
    ("L4", [(LSP, "      start += ds",
             "      start = ds")],
     [lsp("caseSemanticTokens")],
     "Nim semantic tokens: a token's start is decoded absolute, not relative"),
    ("L6", [(LSP, "  if not semanticEnabled(ed): return",
             "  discard semanticEnabled(ed)")],
     [lsp("caseSemanticTokens")],
     "semantic tokens are asked for although Monaco's option is off"),
]


def chromium_run(self, suite, test_filter):
    """A browser suite: compiled with `nim js` and the renderer-chromium
    lane's flags, run in headless Chromium, `test_filter` naming its cases."""
    self.nimcache.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    js = self.nimcache / f"{stem}.js"
    flags = engine.lane_flags("renderer-chromium")
    p = subprocess.run(
        ["nim", "js", "--hints:off", "--warnings:off",
         f"--nimcache:{self.nimcache}/{stem}", f"-o:{js}"] + flags + [suite],
        cwd=engine.REPO, capture_output=True, text=True, timeout=engine.TIMEOUT)
    if p.returncode != 0:
        return "DID-NOT-COMPILE", []
    env = dict(os.environ, CT_CHROMIUM_ONLY=test_filter or "",
               CT_CHROMIUM_SUITE_TIMEOUT_MS="900000")
    try:
        p = subprocess.run(["node", "src/frontend/tests/chromium-run.mjs", str(js)],
                           cwd=engine.REPO, capture_output=True, text=True,
                           timeout=engine.TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    failures = [engine.portable_cause(ln.strip().split("Check failed: ", 1)[1])
                for ln in out.splitlines() if "Check failed: " in ln]
    if p.returncode == 0:
        return ("GREEN", failures) if out.count("[OK]") > 0 else ("RAN-NOTHING", [])
    if not failures:
        failures = [ln.strip() for ln in out.splitlines() if "[FAILED]" in ln][:1]
    return "RED", failures


class Harness(engine.Harness):
    def run_suite(self, suite, test_filter):
        if suite.endswith("_chromium_test.nim"):
            return chromium_run(self, suite, test_filter)
        return super().run_suite(suite, test_filter)


HARNESS = Harness("plat67-shared-editor", HERE, SUBJECTS, SUITES, ARMS,
                  IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
