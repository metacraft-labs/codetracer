#!/usr/bin/env python3
"""PLAT-34's mutation harness: the arms that grade `DIFF-1`'s two halves, the
wiring they are about, and the suites themselves.

    python3 src/frontend/viewmodel/tests/unit/run-plat34-front-end-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --enumerate-touched
    python3 ... --only=M1,U2

=============================================================================
WHY THIS HARNESS MATTERS MORE THAN USUAL, AND IT IS §30a
=============================================================================

`DIFF-1`'s first half — *the two front-ends' model states agree* — is TRUE BY
CONSTRUCTION once this milestone lands, and PLAT-34's own deliverable says so.
Thirty green cells are therefore not evidence about the wiring; they are
thirty reads of one value. What IS evidence is everything beside them: the
provenance scans, the mutable-buffer scan with its positive control, the
observed-output half read from a run, and the renderer-less control. Those are
what these arms are aimed at.

PLAT-31's `DIFF-4` ran 82 cells green against a feature no shipped key could
reach, for exactly this reason. PLAT-33's `G4` reproduced it deliberately: a
CORRECT re-derivation of the oracle is invisible to every assertion about
either side's ANSWER. `U2` below is this milestone's instance — it makes the
source scan read comments, at which point `edit_binding.nim`'s own header
(which quotes every retired widget spelling by name, because it explains what
was retired) satisfies the scan it is supposed to fail.

=============================================================================
THE ORDER IS §16's AND IT IS ENFORCED RATHER THAN DOCUMENTED
=============================================================================

edit the tree -> `--needle-scan` -> review -> `--record-control-hashes`.

Re-recording is exactly the moment an arm's needle has just been moved, so a
full run REFUSES to start when a needle is lost or ambiguous, and REFUSES
again when a control digest has moved without a scan. Both refusals are acted
on rather than printed.

=============================================================================
TWO SUITES, TWO COMPILE CONFIGURATIONS, AND THE SECOND IS NOT OPTIONAL
=============================================================================

`test_editor_front_end_differential.nim` compiles with the `vm-unit` lane's
one flag. `test_editor_front_end_observed.nim` links `isonim_tui` AND
`isonim_gpui` and needs the `tui` lane's tree-sitter archive and two `-L`
flags — which are READ from `ci/lib/test-lane-files.sh` rather than spelled
here, for §30's reason: a second copy of those flags is a second place for
them to drift. **If that read fails this harness refuses**, because a second
suite silently dropped from the run would take four arms with it, and a
harness that quietly grades half its subjects reports a number about a
population nobody declared.

=============================================================================
§10.3 — NO ARM MAY QUOTE A COUNT
=============================================================================

A count changes on every commit that adds a test, so an arm whose needle
contains one is an arm that is silently unkillable by the next commit. The
scan rejects an arm quoting a count constant's NAME or its VALUE, and refuses
outright if it can find no count constants at all.
"""

import argparse
import hashlib
import os
import re
import signal
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]

# -- subjects ---------------------------------------------------------------
#
# FIVE PRODUCT MODULES AND FOUR PIECES OF EVIDENCE. The product is the core,
# the two front-ends' entry points into it, the keymap layer that carries the
# clock, and the surface derivation both media go through. The evidence is the
# sequence corpus and the two suites.
CORE = "src/frontend/viewmodel/editing_core.nim"
BINDING = "src/frontend/tui/app/edit_binding.nim"
KEYMAP = "src/frontend/viewmodel/keymap/editing_keymap.nim"
SURFACE = "src/frontend/view_vocabulary/editor_surface.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
CORPUS = "src/frontend/viewmodel/tests/generators/operation_sequence_corpus.nim"
DIFF = "src/frontend/viewmodel/tests/unit/test_editor_front_end_differential.nim"
OBS = "src/frontend/tui/tests/test_editor_front_end_observed.nim"

# PLAT-33's SECOND RESIDUAL, CLOSED HERE AND THEREFORE ARMED HERE. The editor
# projection is the thing that makes a remote edit visible, and it is one
# function only because this milestone gave both front-ends one document to
# draw. A deliverable with no arm is a deliverable graded by whether it
# compiles.
PROJECTION = "src/frontend/viewmodel/collab/projection.nim"
PROJ_SUITE = "src/frontend/viewmodel/tests/unit/test_collab_editor_projection.nim"

TOUCHED = [CORE, BINDING, KEYMAP, SURFACE, GPUI_MAIN, CORPUS, DIFF, OBS,
           PROJECTION, PROJ_SUITE]

# **EVERYTHING THE SUITES READ THAT NO ARM MUTATES.** PLAT-33's rule, applied:
# a harness must digest everything its suites *read*, not only everything it
# mutates, or a file can move mid-arm and change what a suite compiles to with
# nothing able to see it. `test_editor_front_end_differential.nim`
# `staticRead`s four modules that are not subjects of any arm here, and the
# `tui` lane's flag script is read by this harness itself.
READ_ONLY_INPUTS = [
    "src/frontend/tui/app/tui_app.nim",
    "src/frontend/tui/app/runtime.nim",
    "src/frontend/tui/app/tests/test_edit_binding_vocabulary.nim",
    "src/frontend/tui/app/tests/test_edit_mode_source.nim",
    "ci/lib/test-lane-files.sh",
    "src/frontend/viewmodel/tests/generators/vocabulary_generator.nim",
]

CONTROL_HASHES = HERE / "plat34-front-end-mutation-control.sha256"

SUITE_TIMEOUT = int(os.environ.get("CT_P34_SUITE_TIMEOUT", "2400"))

SUITES = [DIFF, OBS, PROJ_SUITE]

BIN_DIR = os.environ.get("TMPDIR", "/tmp")


def suite_binary(rel):
    return os.path.join(BIN_DIR, "plat34-" + Path(rel).stem)


def tui_lane_flags():
    """The `tui` lane's extra flags, READ from the script that owns them.

    A second spelling here would be a second place for the tree-sitter
    archive path and the two `-L` flags to drift (§30). A failure to read
    them is a REFUSAL rather than an empty list, because an empty list
    compiles nothing and a suite that never ran is not a survivor.
    """
    proc = subprocess.run(
        ["bash", "-c",
         ". ci/lib/test-lane-files.sh && test_lane_extra_flags tui"],
        cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    flags = proc.stdout.split()
    return flags or None


def suite_flags(rel):
    if rel == OBS:
        return tui_lane_flags()
    return ["--path:src/frontend/viewmodel"]


COUNT_NAMES = ["ExpectedAssertions", "ExpectedCases", "CHECKS:",
               "OperationSequenceCardinality", "RetiredWidgetSpellingCount",
               "RawSplitSpellingCount", "ScannedKeymapModuleCount",
               "TxKindCount", "DefaultViewportRows", "GridCols", "GridRows"]


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""


ARMS = [
    # =====================================================================
    # THE PRODUCT — the wiring PLAT-34 is about
    # =====================================================================
    Arm(
        "M1", CORE,
        "    of kmProductDefault: emInsert\n",
        "    of kmProductDefault: emNormal\n",
        "DIFF-1: move-line-ladder",
        "**A PRODUCT DOCUMENT OPENS IN THE WRONG EDITING MODE AND THE "
        "TERMINAL'S KEYS STOP RESOLVING.** `product_keymap`'s thirteen rows "
        "are scoped to `{emInsert}` — `ProductDefaultModes`, whose reason is "
        "that the terminal's Edit mode has no modal editing at all — and "
        "`initEditorState` opens at `emNormal` because that is the right "
        "default for a modal model. The one line this arm changes is what "
        "reconciles the two. Under it `Down`, `Home`, `End`, `Ctrl+z` and "
        "`Enter` resolve to nothing, so the terminal arm of the differential "
        "acts on none of its steps while the GPUI arm (which has no keys and "
        "goes through `applyNamed`) acts on all of them. The cell whose every "
        "step is a bound key is where that is unmissable.",
    ),
    Arm(
        "M2", BINDING,
        "               mode: buf.doc.state.mode, textEntry: true)\n",
        "               mode: buf.doc.state.mode, textEntry: false)\n",
        "the terminal's SCOPE is the five values the differential drives",
        "**THE TERMINAL STOPS BEING A TEXT FIELD.** §4.3's text-entry "
        "dimension is what makes a printable key stand for itself, and Edit "
        "mode IS a text field — `CodeTracer-TUI-Edit-Mode.md` §1.2. With the "
        "flag false the character arm of the resolver is unreachable and "
        "typing goes to the debugger's keymap instead of into the buffer, "
        "which is the entire editing path. It is a SOURCE claim rather than "
        "an answer claim because this file's own suite cannot reach "
        "`tui/app/` — the `vm-unit` lane's file set forbids it — so what the "
        "differential can check is that the front-end's own scope builder "
        "names the five values the arms drive.",
    ),
    Arm(
        "M3", SURFACE,
        "  result.inspectionLine = if showCaret: d.caretLine else: 0\n",
        "  result.inspectionLine = 0\n",
        "DIFF-1: move-word-walk",
        "**THE READ-ONLY MEDIUM STOPS RE-RENDERING ON A MOTION.** PLAT-28's "
        "rule is that *a read-only editor that does not re-render is not a "
        "consumer*, and twenty-four of this corpus's thirty rows end in a "
        "motion — so a surface carrying only TEXT is byte-identical after "
        "every one of them and the GPUI arm becomes a consumer of nothing. "
        "The caret reaches the rows as the INSPECTION cursor, which is "
        "CTUI-6's second pointer rather than a new concept, and this arm "
        "removes it.",
    ),
    Arm(
        "M4", KEYMAP,
        "    let r = applyOperation(state, name, args, settings, viewportRows, nowMs)\n",
        "    let r = applyOperation(state, name, args, settings, viewportRows)\n",
        "the keymap layer threads the CLOCK into every operation it runs",
        "**PLAT-32's RESIDUAL, RESTORED.** Dropping the argument makes "
        "`applyOperation` take its own `nowMs: int64 = 0` default, so every "
        "operation the keymap layer runs is at time zero and "
        "`history.mayGroup`'s `nowMs - h.prevTime >= NewGroupDelayMs` is "
        "`0 - 0 >= 500` — false, group. Undo grouping then cannot break on "
        "any product keystroke, which is the state the terminal shipped in "
        "for two milestones. TWO cases die and they are the two halves this "
        "campaign asks for: the source fact, and the behaviour it produces.",
    ),
    Arm(
        "M5", GPUI_MAIN,
        "  editorSurfaceForDocument(\n    d = doc,\n",
        "  editorSurfaceForProject(\n    path = doc.path, text = doc.text,\n",
        "the GPUI front-end OPENS a document rather than passing bytes on",
        "**THE GPUI FRONT-END GOES BACK TO PASSING BYTES.** The two "
        "derivations agree today — `editorSurfaceForProject` is a two-line "
        "wrapper that opens a document — so NOTHING about the rendered "
        "answer changes under this arm. That is precisely §30a: a correct "
        "re-derivation is invisible to every assertion about the output, and "
        "the only thing that can see it is a claim about WHERE the surface "
        "comes from. The arm exists to prove that claim is checked, and its "
        "killer is a source scan for that reason rather than by preference.",
    ),

    # =====================================================================
    # THE POPULATION — §34
    # =====================================================================
    Arm(
        "G1", CORPUS,
        "    docIndex: 14, start: ssLine1Mid, steps: @[\n"
        "      st\"split-line\", st\"join-lines\"])\n",
        "    docIndex: 0, start: ssLine1Mid, steps: @[\n"
        "      st\"split-line\", st\"join-lines\"])\n",
        "the corpus is thirty sequences, six families, every class and every document",
        "**THE CORPUS LOSES A SCENARIO DOCUMENT.** Thirty sequences that "
        "converge on a few documents' clusters cannot distinguish a group "
        "motion that respects grapheme clusters from one that respects "
        "runes, and the cells stay green because both arms are wrong in the "
        "same way.\n\n"
        "**THE FIRST SPELLING OF THIS ARM SURVIVED AND THE REASON IS WORTH "
        "KEEPING.** It moved a row off document 6, and nine classes were "
        "still reached — because §5's eighteen documents are two per class "
        "and the sibling still carried it. A per-CLASS count is satisfied by "
        "a corpus that loses half its documents, which is §34's *\"assert "
        "what each draw REALISED, not merely that the population is "
        "non-empty\"* one level up. The case asserts the realised DOCUMENT "
        "set as well now, and the arm is aimed at a row whose document no "
        "other row uses.",
    ),
    Arm(
        "G2", CORPUS,
        "  result.add OperationSequence(id: \"edit-insert-then-move\", family: sfEdit,\n",
        "  result.add OperationSequence(id: \"edit-insert-then-move\", family: sfMove,\n",
        "the corpus is thirty sequences, six families, every class and every document",
        "**A FAMILY QUIETLY LOSES A ROW TO ANOTHER.** The cardinality stays "
        "thirty and every cell stays green; what moves is the per-family "
        "distribution, which is the thing §34 is about here — a corpus that "
        "drifts towards one family measures one path thirty times. The "
        "per-family counts are asserted as EQUALITIES rather than as floors "
        "for exactly this, and the needle names a row rather than a number "
        "(§10.3).",
    ),

    # =====================================================================
    # THE SUITES — an instrument that cannot fail is this campaign's
    # recurring defect, so both are armed like anything else
    # =====================================================================
    Arm(
        "U1", DIFF,
        "    \"TextAreaWidget\", \"newTextArea\", \"moveCursorTo\", \"w.insertText\",\n"
        "    \"w.backspace\", \"w.splitLine\", \"w.undo\", \"w.redo\"]\n",
        "    \"zzz-a-spelling-no-module-contains\"]\n",
        "the forbidden list is not empty, and its cardinality is declared",
        "**THE FORBIDDEN LIST IS EMPTIED.** §4, one level up from the scan it "
        "guards: an empty list iterates nothing and satisfies every "
        "\"must not contain\" written over it, so the mutable-buffer scan and "
        "the provenance scan both go green over any tree at all. The "
        "cardinality assertion is the only thing that can say so, and this "
        "arm is what proves it is there. It is the same instrument §30a's "
        "`LAW-D1` instance uses over its own oracle.",
    ),
    Arm(
        "U2", DIFF,
        "  for line in src.splitLines:\n"
        "    let stripped = line.strip()\n"
        "    if stripped.startsWith(\"#\"):\n"
        "      continue\n"
        "    let hash = line.find('#')\n"
        "    if hash >= 0 and line.count('\"') mod 2 == 0:\n"
        "      result.add line[0 ..< hash]\n"
        "    else:\n"
        "      result.add line\n"
        "    result.add '\\n'\n",
        "  result = src\n",
        "the terminal's dispatch reaches the core and no widget",
        "**THE SCAN STARTS READING COMMENTS, AND ITS SUBJECT'S OWN HEADER "
        "DEFEATS IT.** `edit_binding.nim`'s header explains what PLAT-34 "
        "retired and therefore quotes every forbidden spelling by name — "
        "`TextAreaWidget`, `moveCursorTo`, the lot. A scan that read prose "
        "would find all eight in a file that reaches none of them, which is "
        "§4d's *\"a scan that matches vocabulary rather than syntax is "
        "satisfied by prose that is ABOUT the thing\"*, arriving through the "
        "documentation written to explain the very change being scanned for. "
        "The arm reddens the scan rather than silencing it, which is the "
        "direction that proves `codeOnly` is load-bearing.",
    ),
    Arm(
        "U3", OBS,
        "  of txUndo:\n    discard d.applyNamed(\"insert-text\", OpArgs(text: \"Q\"), nowMs)\n"
        "  of txRedo:\n",
        "  of txUndo:\n    discard\n"
        "  of txRedo:\n",
        "a model change is drawn by BOTH front-ends: undo",
        "**THE UNDO CELL'S ARRANGEMENT IS REMOVED AND THE CELL MEASURES "
        "NOTHING.** With no edit before the snapshot, the undo has an empty "
        "history, the document ends where it started and both observed "
        "outputs are byte-identical. It is §34's shape read off a RED rather "
        "than a green — a cell whose two ends are the same state measures "
        "nothing, and which way it reports that is an accident of the "
        "assertion's sign. This suite's first run had exactly this defect and "
        "the arm is what keeps the repair.",
    ),
    Arm(
        "U4", OBS,
        "    textContent(parent)\n",
        "    d.text\n",
        "a model change is drawn by BOTH front-ends: insert a character",
        "**THE GPUI SIDE STOPS READING THE SHADOW TREE AND READS THE MODEL "
        "INSTEAD.** §4a, and it is the defect PLAT-21 found in fifteen "
        "pre-existing cases that reported `[OK]` against a shim with no "
        "renderer: every \"the output changed\" assertion is still satisfied, "
        "because the MODEL changed. What is not satisfied is the per-cell "
        "check that the observed output is not the model's string — the tree "
        "carries the source statement and the row glyphs — and that check "
        "exists because of this arm rather than the other way round.",
    ),

    # =====================================================================
    # THE EDITOR PROJECTION — PLAT-33's residual 2
    # =====================================================================
    Arm(
        "M6", PROJECTION,
        "  p.doc.state = p.session.receiveInto(p.doc.state, batch)\n",
        "  for entry in batch:\n"
        "    p.doc.state = applyRemoteChange(p.doc.state, entry.changes,\n"
        "                                    entry.producer)\n"
        "  p.session.version = log.len\n",
        "the remote edit does NOT become the user's next undo (§13.2)",
        "**THE PROJECTION STOPS REBASING PAST THE PEER'S OWN UNCONFIRMED "
        "WORK.** A committed change set is expressed against the AUTHORITY's "
        "document; a front-end that has typed since has a longer one. "
        "`receiveInto` is the routine that exists so a caller *\"cannot do the "
        "second without the first\"* — it rebases, THEN applies — and this arm "
        "does the second without the first, which is `LAW-X1`'s killing "
        "mutation arriving through a projection. It also stops recognising "
        "this peer's own updates coming back, so they apply twice instead of "
        "confirming.\n\n"
        "This is not a hypothetical shape: it is the FIRST VERSION of this "
        "function, and it raised by name on its own suite — *\"the change is "
        "over 44 bytes and the document is 45\"* — which is `applyRemoteChange`"
        " refusing rather than corrupting. The arm restores it.",
    ),
    Arm(
        "U5", PROJ_SUITE,
        "    counted not p.commitLocalChange(changeSet(BaseDoc.len, 0, 0, \"L\"),\n",
        "    counted p.commitLocalChange(changeSet(BaseDoc.len, 0, 0, \"L\"),\n",
        "a LOCAL FILTER does not refuse the authority's change (§12.2)",
        "**THE SUITE STOPS ASSERTING THAT THE LOCAL GUARD BIT.** §12.2's "
        "asymmetry has two halves — the local path consults `refusedBy` and "
        "the remote path does not call it at all — and a case that checked "
        "only the second would be green over a projection that consulted "
        "neither. That is not hypothetical either: `commitLocalChange`'s "
        "first version reached `operations.commitChange` directly, which is "
        "the document-moving primitive and does NOT check the filters "
        "(`applyTransaction` does, one layer up), so a read-only buffer "
        "accepted a keystroke. This half of the case is what caught it.",
    ),
]

DECLARED_SURVIVORS = []
"""No arm is declared a survivor. An arm that survives is a `problems += 1`."""

_ACTIVE = None


def read_source(rel):
    return (ROOT / rel).read_text()


def write_source(rel, text):
    (ROOT / rel).write_text(text)


def digest(rel):
    return hashlib.sha256((ROOT / rel).read_bytes()).hexdigest()


def declared_counts():
    """value -> constant name, over every subject."""
    out = {}
    # `\*?` BECAUSE AN EXPORTED CONST IS `Name* = 30` AND THE FIRST SPELLING
    # OF THIS PATTERN COULD NOT SEE ONE. PLAT-31 found the same gap from the
    # other side — its regex was anchored on the `const` keyword and so saw
    # neither of two constants that were MEMBERS of a `const` block — and the
    # cost is identical: an arm could quote the value and be silently
    # unkillable on the next commit that grew the set (§10.3's failure mode,
    # inside the check for it). Measured here: without the `\*?`,
    # `OperationSequenceCardinality* = 30` was absent from the declared set.
    pat = re.compile(r"\b(" + "|".join(re.escape(n) for n in COUNT_NAMES) +
                     r")\*?\s*[:=]?\s*=?\s*(\d+)")
    for rel in TOUCHED:
        for name, value in pat.findall(read_source(rel)):
            out[value] = name
    return out


def declared_case_names():
    names = set()
    for rel in SUITES:
        for m in re.finditer(r'^\s*test "([^"]+)"', read_source(rel),
                             re.MULTILINE):
            names.add(m.group(1))
        # `test "a " & $x & " b"` forms: keep the literal prefix so a killer
        # written against a generated name can still be matched by prefix.
        for m in re.finditer(r'^\s*test "([^"]+)" & ', read_source(rel),
                             re.MULTILINE):
            names.add(m.group(1))
    return names


def check_killer_names(problems):
    declared = declared_case_names()
    for arm in ARMS:
        if not arm.killer:
            print(f"{arm.id}: NO KILLER NAMED — an arm with no stated killer "
                  f"is not admitted")
            problems += 1
            continue
        if arm.killer in declared:
            continue
        if any(arm.killer.startswith(d) or d.startswith(arm.killer)
               for d in declared):
            continue
        print(f"{arm.id}: KILLER NAMES NO DECLARED CASE: {arm.killer!r}")
        problems += 1
    return problems


def needle_scan():
    """Every arm's needle occurs exactly once. No toolchain, about a second."""
    problems = 0

    counts = declared_counts()
    print("declared count constants in the subjects: " +
          (", ".join(f"{v}={k}" for k, v in sorted(counts.items())) or "none"))
    if not counts:
        print("REFUSING: no declared count constant was found in any subject, "
              "so §10.3's rule would pass vacuously")
        problems += 1
    for arm in ARMS + DECLARED_SURVIVORS:
        blob = arm.find + arm.replace
        for name in COUNT_NAMES:
            if name in blob:
                print(f"{arm.id}: NEEDLE QUOTES A COUNT NAME ({name}) — §10.3")
                problems += 1
        for digits in re.findall(r"\d+", blob):
            if digits in counts:
                print(f"{arm.id}: NEEDLE QUOTES THE VALUE OF "
                      f"{counts[digits]} ({digits}) — §10.3")
                problems += 1

    armed = {arm.path for arm in ARMS}
    unarmed = [p for p in TOUCHED if p not in armed]
    if unarmed:
        print(f"SUBJECTS WITH NO ARM: {unarmed}")
        problems += 1
    else:
        print(f"all {len(TOUCHED)} subjects carry at least one arm")

    for arm in ARMS + DECLARED_SURVIVORS:
        text = read_source(arm.path)
        n = text.count(arm.find)
        status = "ok" if n == 1 else "LOST" if n == 0 else "AMBIGUOUS"
        if n != 1:
            problems += 1
        print(f"{arm.id:<5} {status:<10} {n} occurrence(s) in {arm.path}")

    problems = check_killer_names(problems)
    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


def record_control_hashes():
    lines = [f"{digest(p)}  {p}" for p in TOUCHED + READ_ONLY_INPUTS]
    CONTROL_HASHES.write_text("\n".join(lines) + "\n")
    print(f"recorded {len(lines)} digests in {CONTROL_HASHES.name}")
    return 0


def check_control_hashes():
    if not CONTROL_HASHES.exists():
        print(f"NOTE: {CONTROL_HASHES.name} is absent — run "
              f"--record-control-hashes after reviewing the tree")
        return True
    recorded = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        if not line.strip():
            continue
        h, _, rel = line.partition("  ")
        recorded[rel] = h
    ok = True
    for p in TOUCHED + READ_ONLY_INPUTS:
        # **A PATH THAT IS NOT IN THE FILE AT ALL IS A REFUSAL, NOT A SKIP.**
        # `if p in recorded and …` let a newly added subject or read-only
        # input pass silently until somebody happened to re-record, which is
        # the same one-sided-check shape as the `rebase(` count in
        # `test_editor_change_algebra.nim`: absence and agreement were
        # indistinguishable. Adding the spec oracle to READ_ONLY_INPUTS is
        # exactly the case that would have been swallowed.
        if p not in recorded:
            print(f"CONTROL DIGEST ABSENT: {p} is compared by this harness "
                  f"but has no recorded digest — run --needle-scan, review, "
                  f"then --record-control-hashes (§32)")
            ok = False
        elif recorded[p] != digest(p):
            print(f"CONTROL DIGEST MOVED: {p} — re-run --needle-scan BEFORE "
                  f"--record-control-hashes (§32)")
            ok = False
    return ok


@dataclass
class RunResult:
    ran: bool = True
    hung: bool = False
    failed: list = field(default_factory=list)
    cases: int = 0


def run_suite(suites):
    result = RunResult()
    for rel in suites:
        flags = suite_flags(rel)
        if flags is None:
            # **A SUITE WHOSE FLAGS COULD NOT BE READ IS A REFUSAL, NOT A
            # SKIP.** The observed-output suite links two renderers and does
            # not build without the `tui` lane's flags; dropping it silently
            # would take four arms with it and report a number about a
            # population nobody declared.
            print("REFUSING: could not read the `tui` lane's extra flags out "
                  "of ci/lib/test-lane-files.sh, so "
                  f"{rel} cannot be compiled")
            result.ran = False
            return result
        cmd = (["nim", "c", "-r"] + flags + ["--hints:off",
               "-o:" + suite_binary(rel), rel])
        try:
            proc = subprocess.run(cmd, cwd=ROOT, capture_output=True,
                                  timeout=SUITE_TIMEOUT)
        except subprocess.TimeoutExpired:
            result.hung = True
            return result
        # **BYTES, THEN DECODE WITH `errors="replace"`, AND IT IS NOT
        # DEFENSIVENESS.** The corpus these suites run over contains
        # ILL-FORMED UTF-8 by design — class 7 is bare continuation bytes,
        # overlong encodings and unpaired surrogates — and a failing `check`
        # prints the document. With `text=True` Python decodes the child's
        # output strictly and raises `UnicodeDecodeError` *in the harness*,
        # mid-arm, which is a harness that dies on the arms that are working.
        # It happened: `M3` killed its case, the case printed the document,
        # and the run ended in a traceback with nine arms unexamined. The
        # `finally` restored the subject, which is the only reason this was a
        # lost run rather than a mutated tree.
        out = (proc.stdout + proc.stderr).decode("utf-8", errors="replace")
        oks = out.count("[OK]")
        fails = re.findall(r"\[FAILED\] (.+)", out)
        # **A SUITE THAT PRINTED NO RESULT LINE AT ALL DID NOT RUN**, and a
        # mutation that stops ONE of the two suites compiling while the other
        # still prints its cases would otherwise read as a clean survival.
        if oks == 0 and not fails:
            result.ran = False
            return result
        result.cases += oks
        result.failed.extend(f.strip() for f in fails)
    return result


def restore_active(signum, frame):
    global _ACTIVE
    if _ACTIVE is not None:
        rel, original = _ACTIVE
        write_source(rel, original)
        print(f"\nsignal {signum}: restored {rel}")
    sys.exit(128 + signum)


def install_restore_on_signal():
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, restore_active)


def main():
    global _ACTIVE
    ap = argparse.ArgumentParser()
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    ap.add_argument("--enumerate-touched", action="store_true")
    ap.add_argument("--only", default="")
    args = ap.parse_args()

    if args.enumerate_touched:
        for p in TOUCHED:
            print(p)
        return 0
    if args.needle_scan:
        return needle_scan()
    if args.record_control_hashes:
        if needle_scan() != 0:
            print("REFUSING TO RECORD: a needle is lost or ambiguous (§32). "
                  "The scan runs BEFORE the digests precisely because "
                  "re-recording is when a needle has just moved.")
            return 1
        return record_control_hashes()

    install_restore_on_signal()
    only = {s.strip() for s in args.only.split(",") if s.strip()}

    if needle_scan() != 0:
        print("REFUSING TO RUN: a needle is lost or ambiguous (§32)")
        return 1
    if not check_control_hashes():
        print("REFUSING TO RUN: a control digest moved (§32). Re-run "
              "--needle-scan, review the tree, then --record-control-hashes.")
        return 1

    baseline = {p: digest(p) for p in TOUCHED}

    print("\n=== control ===")
    control = run_suite(SUITES)
    if control.hung or not control.ran or control.failed:
        print(f"CONTROL IS NOT GREEN: hung={control.hung} ran={control.ran} "
              f"failed={control.failed}")
        return 1
    print(f"control: {control.cases} cases, 0 failed")

    print("\n=== arms ===")
    problems = 0
    kills = 0
    for arm in ARMS + DECLARED_SURVIVORS:
        if only and arm.id not in only:
            continue
        original = read_source(arm.path)
        occurrences = original.count(arm.find)
        if occurrences != 1:
            print(f"{arm.id:<5} HARNESS-FAILURE      needle occurs "
                  f"{occurrences} times in {arm.path}, expected 1")
            problems += 1
            continue
        _ACTIVE = (arm.path, original)
        write_source(arm.path, original.replace(arm.find, arm.replace))
        try:
            res = run_suite(SUITES)
        finally:
            write_source(arm.path, original)
            _ACTIVE = None
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{arm.id:<5} HARNESS-FAILURE      {p} did not "
                          f"restore to its control bytes")
                    return 2

        declared = arm in DECLARED_SURVIVORS
        if res.hung:
            verdict, note = "HUNG", (f"no result in {SUITE_TIMEOUT}s — repair "
                                     f"the arm, not the timeout")
            problems += 1
        elif not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif declared and res.failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"died in {res.failed[:2]}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", ""
        elif not res.failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif any(f == arm.killer or f.startswith(arm.killer)
                 for f in res.failed):
            verdict, note = "killed", f"{len(res.failed)} case(s) red"
            kills += 1
        else:
            verdict, note = "MISDIRECTED", f"died in {res.failed[:2]}"
            problems += 1
        print(f"{arm.id:<5} {verdict:<20} {note}")

    print(f"\n{len(ARMS)} arms, {kills} killed, "
          f"{len(DECLARED_SURVIVORS)} declared survivors, {problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
