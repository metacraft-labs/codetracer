#!/usr/bin/env python3
"""The mutation harness for the shared editor's large-file keystroke and its
API reveals (docs/shared-editor-parity.md, the "Huge files" and "The
differential" rows).

Each arm plants ONE defect that makes a keystroke cost the document instead
of the edit — the tokenizer's cache dropped below an edit
(`ui/shared_editor.nim`), the whole document re-derived
(`viewmodel/editor/operations.nim`), every line above an edit re-wrapped
(`viewmodel/editor/wrap.nim`) — or that moves an API reveal off Monaco's
(`ui/shared_editor.nim`) or that resets a view zone's width every frame (the
tracepoint editor's Run button then falls outside the pane), and must be
killed by the browser suite's case the row names. The discipline is the
PLAT-71 engine's (`plat71_mutation_engine.py`):
committed control digests over subjects AND suites, a needle scan that gates
re-recording, `because` derived from a run and then required, per-arm
restore verification. The browser suite runs as
`run-plat67-shared-editor-mutations.py` runs it (`nim js` with the
renderer-chromium lane's flags, headless Chromium, `CT_CHROMIUM_ONLY`).

The large-file arms are killed by counts (lines re-tokenized and re-wrapped,
bytes re-derived), not by the case's timing ratio, so they grade the same at
any host load.

Usage:
    run-plat67-large-file-mutations.py [--only ID,ID] [--derive]
    run-plat67-large-file-mutations.py --needle-scan
    run-plat67-large-file-mutations.py --record-control-hashes
"""
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "tui" / "tests"))
import plat71_mutation_engine as engine  # noqa: E402

# The browser-suite runner is the shared-editor harness's own.
_spec = importlib.util.spec_from_file_location(
    "plat67_shared_editor", HERE / "run-plat67-shared-editor-mutations.py")
_plat67 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_plat67)

EDITOR = "src/frontend/ui/shared_editor.nim"
OPS = "src/frontend/viewmodel/editor/operations.nim"
WRAP = "src/frontend/viewmodel/editor/wrap.nim"

BROWSER = "src/frontend/tests/shared_editor_chromium_test.nim"

SUBJECTS = [EDITOR, OPS, WRAP]
SUITES = [BROWSER]
IN_BINARY = set()


def browser(case):
    return (BROWSER, case)


# (id, [(subject, find, replace), ...], [(suite, filter), ...], the row)
ARMS = [
    ("H1", [(EDITOR, "  if done and oldLast0 + 1 <= oldValid and ctx == ed.contexts[oldLast0 + 1]:",
             "  if false:")],
     [browser("caseHugeFile")],
     "huge files: an edit drops the tokenizer's cache below it"),
    ("H2", [(OPS, "      lastDerived = incrementalDerivation(lastDerived, doc, lastCommit)",
             "      lastDerived = fullDerivation(doc, settings)")],
     [browser("caseHugeFile")],
     "huge files: a keystroke re-derives the whole document"),
    ("H3", [(WRAP, "  let firstLine = max(0, c.lineStart.upperBound(loA) - 1)",
             "  let firstLine = 0")],
     [browser("caseHugeFile")],
     "huge files: a keystroke re-wraps every line above the edit"),
    ("V1", [(EDITOR, "  max(around, if sticky: stickyLines else: 0)",
             "  around")],
     [browser("caseRevealsAsMonaco")],
     "the differential: an API reveal ignores sticky scroll's padding"),
    ("V2", [(EDITOR, "  boxStart -= context * float(lh)",
             "  boxStart -= 0.0")],
     [browser("caseRevealsAsMonaco")],
     "the differential: an API reveal pads only below the line"),
    ("V3", [(EDITOR, '    z.domNode.setStyle("height", cstring($z.heightPx & "px"))',
             '    z.domNode.setStyle("height", cstring($z.heightPx & "px")); z.domNode.setStyle("width", "100%")')],
     [browser("caseDecorationsAndZones")],
     "the differential: every frame resets a zone's width, the tracepoint editor's toolbar overflows"),
]


class Harness(engine.Harness):
    def run_suite(self, suite, test_filter):
        if suite.endswith("_chromium_test.nim"):
            return _plat67.chromium_run(self, suite, test_filter)
        return super().run_suite(suite, test_filter)


HARNESS = Harness("plat67-large-file", HERE, SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))
