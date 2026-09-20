#!/usr/bin/env python3
"""PLAT-21 mutation harness — the GPUI vocabulary binding, the pane views, the
shared fact reader and the filed-gap register.

WHAT THIS IS
------------
Each arm applies ONE textual mutation to ONE source file, runs the suite that
grades it, and requires a NAMED case to go red for the arm's OWN reason. Every
arm is reverted and the revert is verified by digest.

THE DISCIPLINE, AND WHERE EACH RULE COMES FROM
----------------------------------------------
`codetracer-specs/Testing/Verification-Harness-Traps.md`, and the machinery is
`run-plat20-mutations.py`'s, deliberately: a second implementation of a harness
is §14's defect one level up, so this file differs from that one in its ARMS,
its subjects and its per-suite environment and nowhere else.

* **Five verdicts, not two** (§1a). `KILLED`, `SURVIVED`, `DID-NOT-COMPILE`,
  `MIS-ATTRIBUTED`, `NO-VERDICT-FOR-KILLER`.
* **`because` is DERIVED, never typed** (§17, §17a, §17b).
* **Two arms may not derive the same `because`** (§17a's closing rule).
* **The needle scan GATES the re-record** (§16).
* **`flock` before any digest** (§14d's corollary).
* **A named behaviour-preserving CONTROL per arm** (§4a, §14).
* **`TOUCHED` names every file an arm's verdict depends on** (§16b, §16c) — the
  seven subjects AND the three suites the arms are graded against.

ONE THING THIS HARNESS NEEDS THAT PLAT-20'S DID NOT
---------------------------------------------------
`test_cross_renderer_panes.nim` opens a REAL recording through a real
`replay-server` child process, and on this host that child cannot load
`libmcr_emulator.so` unless `LD_LIBRARY_PATH` names the directory the Rust
build put it in. PLAT-20 recorded the same fact as its residue 8 and
demonstrated it rather than asserting it. `suite_env` below resolves the
directory by GLOB rather than by a hard-coded hash, and REFUSES to grade that
suite when it cannot find one — a harness that silently graded a suite whose
every case fails for an environmental reason would score every arm `KILLED`
for free, which is the most expensive false green on the page.

USAGE
-----
    run-plat21-mutations.py --needle-scan
    run-plat21-mutations.py --record-control-hashes   # refuses if the scan fails
    run-plat21-mutations.py --derive                  # re-derive every `because`
    run-plat21-mutations.py                           # the graded run
    run-plat21-mutations.py --only G3,U1
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HARNESS_DIR = Path(__file__).resolve().parent

# --- subjects ---------------------------------------------------------------
GB = "src/frontend/view_vocabulary/gpui_binding.nim"
FR = "src/frontend/view_vocabulary/fact_reader.nim"
PV = "src/frontend/view_vocabulary/pane_views.nim"
GAPS = "src/common/view_vocabulary/gpui_gaps.nim"
MAP = "src/common/view_vocabulary/mappings.nim"
SURF = "src/common/value_presentation/surfaces.nim"
TB = "src/frontend/view_vocabulary/terminal_binding.nim"

# --- the suites the arms are graded against (§16c) ---------------------------
SUITE_GPUI = "src/frontend/gpui/tests/test_gpui_vocabulary_binding.nim"
SUITE_CROSS = "src/frontend/tui/tests/test_cross_renderer_panes.nim"
SUITE_VOCAB = "src/common/view_vocabulary_test.nim"

TOUCHED = [GB, FR, PV, GAPS, MAP, SURF, TB,
           SUITE_GPUI, SUITE_CROSS, SUITE_VOCAB]

CONTROL_HASHES = HARNESS_DIR / "plat21-mutation-control.sha256"
BECAUSE_FILE = HARNESS_DIR / "plat21-mutation-because.json"
LOCK_FILE = REPO / "build" / "plat21-mutations.lock"
NIMCACHE = REPO / "build" / "plat21mut"

GRAMMAR_ARCHIVE = REPO / "build" / "grammars" / "libcodetracer_tui_grammars.a"
TUI_LINK_FLAGS = REPO / "build" / "grammars" / "tui-link-flags.txt"


def tui_flags() -> list[str]:
    """The `tui` lane's own flags, READ rather than restated.

    `ci/lib/test-lane-files.sh` builds them from the same two files; copying
    the strings here would be §14's second copy of a predicate, so the archive
    path and the link flags come from the artefacts the lane reads.
    """
    flags = ["--path:src/frontend/viewmodel",
             f"-d:isonimTuiGrammarArchive={GRAMMAR_ARCHIVE}"]
    if TUI_LINK_FLAGS.is_file():
        for piece in TUI_LINK_FLAGS.read_text().split():
            flags.append(f"--passL:{piece}")
    return flags


SUITE_CMD = {
    SUITE_GPUI: ["--path:src/frontend/viewmodel"],
    SUITE_VOCAB: ["--path:src/frontend/viewmodel"],
    SUITE_CROSS: None,   # resolved at run time by `tui_flags()`
}


def emulator_dir() -> str | None:
    """Where `replay-server` finds `libmcr_emulator.so`, by GLOB.

    The directory name carries cargo's own metadata hash, so a literal path
    would be a measurement of one build. Returns None when nothing matches,
    and the caller REFUSES rather than grading a suite that cannot start.
    """
    for base in ("debug", "release"):
        root = REPO / "src" / "db-backend" / "target" / base / "build"
        if not root.is_dir():
            continue
        for d in sorted(root.glob("replay-server-*/out")):
            if (d / "libmcr_emulator.so").is_file():
                return str(d)
    return None


def suite_env(suite: str) -> dict:
    env = dict(os.environ)
    if suite == SUITE_CROSS:
        d = emulator_dir()
        if d:
            prev = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = d + (":" + prev if prev else "")
    return env


@dataclass
class Arm:
    name: str
    path: str
    find: str
    replace: str
    suite: str
    kills: str
    control_find: str
    control_replace: str
    note: str
    because: str = ""


ARMS = [
    # ------------------------------------------------------------------
    # The GPUI binding: tags, escapes, attributes, key transport.
    # ------------------------------------------------------------------
    Arm("G1", GB,
        '  of pkTabs: "nav"\n  of pkCollapsible: "details"',
        '  of pkTabs: "div"\n  of pkCollapsible: "details"',
        SUITE_GPUI,
        "the GPUI tags are NOT the web binding's tags",
        "func gpuiTagFor*(k: ViewKind): string =",
        "func gpuiTagFor*(k: ViewKind): string = ## ctl",
        "The third column emits the SECOND column's tag. If every tag agreed "
        "with the web binding's, this front-end would be the web front-end "
        "pointed at a different backend and the cross-renderer suite would be "
        "comparing one function with itself (§14). Note what does NOT catch "
        "it: `gpuiMapping(pkTabs).target` is `nav -> div, button -> div`, so "
        "the mapping-table case is satisfied by the substring `div`."),

    Arm("G2", GB,
        "      b.recordEscape(gekDisabledAttribute, v,",
        "      discard (gekDisabledAttribute, v,",
        SUITE_GPUI,
        "every entry needing an escape is a filed gap, and every filed gap is taken",
        "  for f in nodeFacts(v):",
        "  for f in nodeFacts(v):  # ctl",
        "A SILENT ESCAPE — the exact state PLAT-21's gate exists against. The "
        "binding still takes the escape; it just stops saying so. Note that "
        "the ENTRY census does not move (the same twelve entries are named by "
        "the key-transport gap), which is why the gate case asserts the set of "
        "escape KINDS as well as the set of entries."),

    Arm("G3", GB,
        "    b.renderer.setAttribute(el, factAttributeName(f.field), f.value)",
        "    b.renderer.setAttribute(el, f.field, f.value)",
        SUITE_GPUI,
        "the `disabled` attribute is destroyed by the renderer — PLAT21-VG2",
        "  for f in nodeFacts(v):",
        "  for f in nodeFacts(v):  ## ctl",
        "THE DEFECT ITSELF, re-planted. Writing the plain field names hands "
        "`disabled` to a renderer that rewrites it to `enabled` and folds its "
        "value to the literal `false`. This is the arm that makes "
        "`gpui_gaps.PLAT21-VG2` a measurement rather than a sentence."),

    Arm("G4", GB,
        "  for k in Key:\n    if k != kChar and k != kNone and gpuiKeyName(k) == name:\n      return press(k)",
        "  for k in Key:\n    if k != kChar and k != kNone:\n      return press(k)",
        SUITE_GPUI,
        "motion skips an unavailable option, on this medium too",
        "func keyFromGpuiEvent*(event: string): KeyPress =",
        "func keyFromGpuiEvent*(event: string): KeyPress = ## ctl",
        "The event name stops being READ. Every dispatched key becomes the "
        "first member of `Key` that is not `kChar`/`kNone`, so the round trip "
        "through Rust arrives at the wrong `KeyPress`. Without this arm the "
        "name in the event would be decoration."),

    Arm("G5", GB,
        "    let event = gpuiKeyEvent(binding.key)",
        "    let event = gpuiKeyEvent(kEnter)",
        SUITE_GPUI,
        "the render plan reports each entry's contract as event_names",
        "  let contract = keyContract(v.kind)",
        "  let contract = keyContract(v.kind)  # ctl",
        "EVERY LISTENER UNDER ONE NAME. The plan's `event_names` then reports "
        "one name per entry instead of the entry's contract — which is the "
        "one thing this tier can say about the keyboard contract from the "
        "RUST side."),

    Arm("G6", GB,
        "    fireEvent(b.nodes[id], gpuiKeyEvent(k))",
        "    for n in walk(b.model):\n      if n.id == id:\n        b.lastOutcome = applyKey(n, press(k))\n        break",
        SUITE_GPUI,
        "a handled key CROSSED the FFI boundary, and an unclaimed one did not",
        "  b.lastOutcome = ignored()",
        "  b.lastOutcome = ignored()  # ctl",
        "THE DISPATCH STOPS GOING THROUGH THE SHIM. The binding calls "
        "`applyKey` directly instead of `gpui_dispatch_event`.\n\n"
        "**IT SURVIVED ON ITS FIRST RUN, AND THE ARM WAS RIGHT AND THE CASE "
        "WAS WRONG.** It was aimed at 'a key in the contract acts, and a key "
        "outside it does nothing' — which is TRUE of a binding that never "
        "dispatches at all, because `behaviour.applyKey` declines an "
        "unclaimed key by itself. The case meant to prove the transport was "
        "proving something the vocabulary already guarantees "
        "(Verification-Harness-Traps §7a). `GpuiBinding.dispatchCount` is "
        "incremented inside the handler Rust calls back into, and is the one "
        "number only the real path can move; the arm is re-aimed at the case "
        "that reads it."),

    # ------------------------------------------------------------------
    # The shared fact reader. §14's remedy needs its own evidence.
    # ------------------------------------------------------------------
    Arm("G7", FR,
        "              acc.add fact(id, f.field,\n                           r.getAttribute(el, factAttributeName(f.field)))",
        "              acc.add fact(id, f.field,\n                           r.getAttribute(el, f.field))",
        SUITE_GPUI,
        "motion skips an unavailable option, on this medium too",
        "  proc visit(r: R; el: N; acc: var seq[StateFact]) =",
        "  proc visit(r: R; el: N; acc: var seq[StateFact]) =  # ctl",
        "The reader stops using the shared attribute spelling, so every fact "
        "reads back empty while the ids still resolve. A projection that "
        "answers \"\" to everything is §4a's emptied subject: the SET is the "
        "same size and the variety inside it is gone."),

    Arm("G8", FR,
        "      var child = r.firstChild(el)\n      while not child.isNil:\n        visit(r, child, acc)\n        child = r.nextSibling(child)",
        "      var child = r.firstChild(el)\n      while false:\n        visit(r, child, acc)\n        child = r.nextSibling(child)",
        SUITE_GPUI,
        "all sixteen entries render, and the shim builds a valid render plan",
        "proc readAttributeFacts*[R, N](r: R; root: N): seq[StateFact] =",
        "proc readAttributeFacts*[R, N](r: R; root: N): seq[StateFact] = ## ctl",
        "The reader stops descending. One fact comes back instead of "
        "twenty-nine, which is why the first case asserts the COUNT and the "
        "id list rather than 'some facts came back' (§4b)."),

    # ------------------------------------------------------------------
    # The pane views: PLAT-2's pipeline, the option grammar, the escape.
    # ------------------------------------------------------------------
    Arm("G9", PV,
        "    if v.presented.isNil: v.value\n    else: presentText(v.presented, budget)",
        "    v.value",
        SUITE_CROSS,
        "one recorded value renders to the SAME BYTES on all three media",
        "proc variableRow(v: store_types.Variable; path: string;",
        "proc variableRow(v: store_types.Variable; path: string;  ## ctl",
        "**THE PLAT-2 ARM.** The pane stops asking the presenter and uses the "
        "rendering somebody else already made at somebody else's budget — "
        "which is the 'each surface truncating' defect PLAT-2 removed, "
        "arriving in a pane written after it. Note that the three media still "
        "AGREE with each other under this mutation: what catches it is the "
        "assertion that the label is the PRESENTER's answer at this budget."),

    Arm("G10", PV,
        "      disabled: p.line == 0)",
        "      disabled: false)",
        SUITE_CROSS,
        "List: motion skips the tracepoint that could not be located",
        "  let points = vm.points.val",
        "  let points = vm.points.val  # ctl",
        "An unlocatable point becomes choosable. `point_list_vm`'s own comment "
        "says a pane 'must not offer it as a jump target'; the vocabulary's "
        "word for that is `ViewOption.disabled`, and losing it makes GPUI, the "
        "web AND the terminal all agree on the wrong motion."),

    Arm("G11", PV,
        '  result.root = nativeEscape("source", medium, "editor")',
        '  result.root = viewText("source", "editor for " & medium)',
        SUITE_CROSS,
        "four panes are expressible in the vocabulary and the source pane is not",
        "proc sourcePaneView*(medium: string): PaneView =",
        "proc sourcePaneView*(medium: string): PaneView =  ## ctl",
        "The source pane stops declaring itself native and becomes a portable "
        "`Text`. That is the lowest-common-denominator drift PLAT-3's risk "
        "note is written against — a milestone claiming the vocabulary covers "
        "an editor — and it is invisible to every assertion about the four "
        "panes that ARE expressible."),

    # ------------------------------------------------------------------
    # The register and the corrected mapping.
    # ------------------------------------------------------------------
    Arm("G12", GAPS,
        '      entries: @[pkImage],\n      subject: gsVocabulary,',
        '      entries: @[],\n      subject: gsVocabulary,',
        SUITE_VOCAB,
        "every filed gap names entries and carries its measurement",
        "  FiledGpuiGaps*: seq[GpuiGap] = @[",
        "  FiledGpuiGaps*: seq[GpuiGap] = @[  ## ctl",
        "A GAP THAT NAMES NO ENTRY. The gate counts ENTRIES, so a register row "
        "with an empty `entries` list satisfies 'each is a named, filed "
        "defect' for free — §4's empty set, inside the instrument that "
        "answers the milestone's verification gate."),

    Arm("G13", MAP,
        '  of pkTable: m(msPartial, "table / tr / td — none is in tagMap, and each " &',
        '  of pkTable: m(msAbsent, "table / tr / td — none is in tagMap, and each " &',
        SUITE_VOCAB,
        "GPUI is absent on exactly ONE entry, and it is named",
        "func gpuiMapping*(k: ViewKind): Mapping =",
        "func gpuiMapping*(k: ViewKind): Mapping = ## ctl",
        "PLAT-3's status restored. The measurement PLAT-21 took says a tag "
        "outside `tagMap` classifies as `Div` exactly as `button` does, so "
        "`Table` is `msPartial`; this arm puts the old, falsified status back "
        "and requires the suite to notice."),

    Arm("G14", SURF,
        '    cells: 0,          ## SEE THE NOTE BELOW — a GPU surface has no cells',
        '    cells: 40,         ## SEE THE NOTE BELOW — a GPU surface has no cells',
        SUITE_GPUI,
        "gpui-panel is a declared surface, and it is not a borrowed one",
        "  GpuiPanelBudget* = Budget(",
        "  GpuiPanelBudget* = Budget(  ## ctl",
        "The GPUI surface invents a cell count. A GPU surface's line capacity "
        "is a pixel width divided by a font metric it resolves at paint time, "
        "so a constant here truncates every value against a number with no "
        "provenance."),

    # ------------------------------------------------------------------
    # UNDECLARED ARMS — planted against this milestone's own evidence rather
    # than derived from the deliverable list. PLAT-20's U3 is why: on six
    # milestones an undeclared arm was the only thing that found the real
    # defect.
    # ------------------------------------------------------------------
    Arm("U1", GB,
        "  let first = nthChild(b.nodes[id], 0)\n  if first.isNil: return \"\"\n  textContent(first)",
        "  if b.nodes[id].isNil: return \"\"\n  textContent(b.nodes[id])",
        SUITE_CROSS,
        "…and on a row that HAS children rendered under it",
        "proc ownTextOf*(b: GpuiBinding; id: string): string =",
        "proc ownTextOf*(b: GpuiBinding; id: string): string =  ## ctl",
        "UNDECLARED, AND IT SURVIVED ON ITS FIRST RUN — the prediction in this "
        "note was right. `textContent` on an element CONCATENATES its "
        "descendants, so a `Tree` row with children rendered under it answers "
        "its own label followed by all of theirs. The purity case compared "
        "twelve variable rows and every one of them was a LEAF, so the two "
        "readings were the same string: §4a's emptied subject, with the count "
        "never moving and the VARIETY inside the set missing.\n\n"
        "The repair is in the SUITE, not in the reader. A new case expands a "
        "variable that really has children — through `StateVM.expandedPaths`, "
        "the signal both other front-ends read — and compares that row, with a "
        "§4 floor asserting such a variable exists in the recording at all."),

    Arm("U2", FR,
        "        let kindName = r.getAttribute(el, ViewKindAttribute)",
        '        let kindName = r.getAttribute(el, "data-kind")',
        SUITE_CROSS,
        "the state pane renders the same state on all three media",
        "      let id = r.getAttribute(el, ViewIdAttribute)",
        "      let id = r.getAttribute(el, ViewIdAttribute)  # ctl",
        "UNDECLARED, and it is §14's cost measured rather than argued. The "
        "READER is shared by two of the three arms, so this breaks the web "
        "column and the GPUI column IDENTICALLY — a pairwise comparison of "
        "those two would stay green. The terminal arm reads isonim-tui's "
        "widget objects and cannot move, which is the whole reason the "
        "comparison is three-way. Note the mutation is on the READER's use of "
        "the constant and not on the constant: changing the constant moves the "
        "WRITER too and is invisible, which is the trap this arm is shaped "
        "around."),

    Arm("U3", PV,
        "  let selected = vm.selectedPath.val\n  var cursor = 0",
        "  let selected = \"\"\n  var cursor = 0",
        SUITE_CROSS,
        "the state pane's cursor comes from StateVM.selectedPath",
        "  let tabs = viewTabs(\"state.tabs\", stateTabOptions(), "
        "selected = ord(tab))",
        "  let tabs = viewTabs(\"state.tabs\", stateTabOptions(), "
        "selected = ord(tab))  # ctl",
        "UNDECLARED, AND IT SURVIVED ON ITS FIRST RUN — the prediction in this "
        "note was right. The state pane stops deriving its cursor from "
        "`StateVM.selectedPath` — the signal the terminal's "
        "`variables_binding.publishSelection` writes and the desktop's state "
        "view reads — and takes 0 always. Every case in the suite started from "
        "a session whose `selectedPath` IS empty, so all of them stayed green: "
        "§7a exactly, a deliberate derivation argued in a doc comment with "
        "nothing that could tell it from its opposite.\n\n"
        "The repair is in the SUITE. A new case publishes the THIRD "
        "variable's path into the signal and requires the cursor to be row 3 "
        "on all three media — the third rather than the first, so a cursor "
        "answering 0 or 1 for any reason is still wrong."),
]


# ---------------------------------------------------------------------------
# plumbing — PLAT-20's, unchanged except for the per-suite environment
# ---------------------------------------------------------------------------

def digest(rel: str) -> str:
    return hashlib.sha256((REPO / rel).read_bytes()).hexdigest()


def take_lock():
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    LOCK_FILE.touch(exist_ok=True)
    fh = open(LOCK_FILE, "r+")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("REFUSED: another run holds the lock. Nothing was mutated.")
        sys.exit(3)
    return fh


def needle_scan() -> list[str]:
    """Every arm whose needles are unaimed, or whose shape cannot be applied.

    TWO checks, and the second was added on 2026-09-16 after arm U3 scored
    CONTROL-HARNESS-FAILURE.

    1. **EXACTLY ONCE, not at least once** (§16). An arm whose needle occurs
       twice has two targets and hits neither.

    2. **A NEEDLE MUST END AT A LINE END.** Every control in this harness (and
       several arms in every harness in this repository) works by APPENDING a
       comment marker — `# ctl` — to the matched text. If the needle is a
       PREFIX of a longer line, appending a comment marker comments out the
       REST OF THAT LINE, and the "behaviour-preserving" control stops being
       behaviour-preserving. U3's control matched

           let tabs = viewTabs("state.tabs", stateTabOptions(),

       of a line that continues `selected = ord(tab))`, so the control produced
       an unterminated call, the suite did not compile, the killer case had no
       verdict, and the harness reported CONTROL-HARNESS-FAILURE — a line that
       reads like a flake and is a real defect in the instrument.

       The scan can see this statically, which is why it is here and not in a
       reviewer's head: if the matched text is not followed by a newline (or by
       whitespace then a newline), the arm is refused. Audited across all
       seventeen arms when it was written: **exactly one** was in that shape.
    """
    bad = []
    for arm in ARMS:
        text = (REPO / arm.path).read_text()
        for label, needle in (("find", arm.find),
                              ("control_find", arm.control_find)):
            n = text.count(needle)
            if n != 1:
                bad.append(f"{arm.name}: `{label}` occurs {n} times in "
                           f"{arm.path}, expected exactly 1")
                continue
            end = text.index(needle) + len(needle)
            nl = text.find("\n", end)
            rest = text[end:nl if nl >= 0 else len(text)]
            if rest.strip():
                bad.append(
                    f"{arm.name}: `{label}` is a PREFIX of a longer line in "
                    f"{arm.path} — the rest is {rest.strip()!r}. Appending a "
                    f"comment marker would comment it out, so the edit is not "
                    f"the edit the arm describes.")
    return bad


def report_needle_scan() -> int:
    bad = needle_scan()
    if bad:
        print("NEEDLE SCAN FAILED — these arms are unaimed and cannot be "
              "killed:")
        for b in bad:
            print("  " + b)
        return 1
    print(f"needle scan: {len(ARMS)} arm(s), every `find` and `control_find` "
          f"occurs exactly once")
    return 0


def check_control_hashes() -> bool:
    if not CONTROL_HASHES.exists():
        print("NO CONTROL DIGESTS — run --record-control-hashes first.")
        return False
    # **PARSE THE FILE FIRST, THEN COMPARE OVER THE UNION.** Walking the
    # recorded file's lines alone made this check one-sided: a path in
    # `TOUCHED` that had never been recorded was simply never visited, so a
    # newly added subject — or a newly added suite, which is the half of
    # `TOUCHED` that grows most often — passed the gate silently until somebody
    # happened to re-record. `write_control_hashes` writes exactly `TOUCHED`,
    # so the union of "what is recorded" and "what this harness compares" is
    # the set over which BOTH directions of a disagreement are visible: a
    # subject with no digest, and a digest for something that is no longer a
    # subject. Either one means the file and the harness have drifted apart,
    # and neither may pass.
    recorded = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        want, rel = line.split(None, 1)
        recorded[rel.strip()] = want
    subjects = set(TOUCHED)
    ok = True
    for rel in sorted(set(recorded) | subjects):
        if rel not in recorded:
            print(f"CONTROL DIGEST ABSENT: {rel} is compared by this harness "
                  f"but has no recorded digest — run --needle-scan, review, "
                  f"then --record-control-hashes (§16)")
            ok = False
            continue
        if rel not in subjects:
            print(f"CONTROL DIGEST STALE: {rel} is recorded but not compared "
                  f"by this harness — re-run --record-control-hashes (§16)")
            ok = False
            continue
        want = recorded[rel]
        have = digest(rel)
        if have != want:
            print("CONTROL DIGEST MOVED — the tree is not at the control "
                  "bytes; nothing was mutated.")
            print(f"  {rel}\n      recorded {want[:8]}…   on disk {have[:8]}…")
            ok = False
    return ok


CONTROL_HEADER = """\
# Control digests for run-plat21-mutations.py.
#
# The bytes every arm restores to, and the bytes every arm's verdict was taken
# against. BOTH HALVES OF `TOUCHED` are here — the seven mutation subjects AND
# the three suites the arms are graded by — which is
# Verification-Harness-Traps §16c's gap paid rather than inherited.
#
# Recorded AFTER running the pre-commit hooks over every file (§16e): a
# formatter that rewrites a file invalidates any digest recorded over it, so
# reading the files proves nothing and running the hooks is the evidence.
#
# Refreshed with --record-control-hashes, which the needle scan GATES (§16).
"""


def write_control_hashes():
    lines = [f"{digest(rel)}  {rel}" for rel in TOUCHED]
    CONTROL_HASHES.write_text(CONTROL_HEADER + "\n".join(lines) + "\n")
    print(f"recorded {len(lines)} control digest(s) to "
          f"{CONTROL_HASHES.relative_to(REPO)}")


def run_suite(suite: str) -> tuple[int, str]:
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    flags = SUITE_CMD[suite]
    if flags is None:
        flags = tui_flags()
    cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + flags + [suite]
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                       timeout=3600, env=suite_env(suite))
    return p.returncode, p.stdout + p.stderr


def failure_lines_for(out: str, case: str) -> list[str]:
    block: list[str] = []
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("[OK]") or s.startswith("[FAILED]"):
            name = s.split("] ", 1)[-1]
            if name == case:
                return block
            block = []
            continue
        block.append(s)
    return []


def verdict_for(out: str, case: str) -> str | None:
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("[OK] ") and s[5:] == case:
            return "OK"
        if s.startswith("[FAILED] ") and s[9:] == case:
            return "FAILED"
    return None


def apply_patch(rel: str, find: str, replace: str):
    path = REPO / rel
    text = path.read_text()
    assert text.count(find) == 1, f"needle not unique in {rel}"
    path.write_text(text.replace(find, replace, 1))


def restore(rel: str, original: str):
    (REPO / rel).write_text(original)


def load_because() -> dict:
    if BECAUSE_FILE.exists():
        return json.loads(BECAUSE_FILE.read_text())
    return {}


def derive(selected: list[Arm]) -> int:
    derived = {}
    for arm in selected:
        original = (REPO / arm.path).read_text()
        try:
            apply_patch(arm.path, arm.find, arm.replace)
            rc, out = run_suite(arm.suite)
        finally:
            restore(arm.path, original)
        lines = failure_lines_for(out, arm.kills)
        checks = [l[l.index("Check failed:"):] for l in lines
                  if "Check failed:" in l]
        if not checks:
            print(f"{arm.name}: NO `Check failed:` line for '{arm.kills}' — "
                  f"cannot derive a `because`.")
            print("   verdict was:", verdict_for(out, arm.kills))
            continue
        text = re.sub(r"\s+", " ", checks[0]).strip()
        derived[arm.name] = text
        print(f"{arm.name}: because = {text}")
    seen: dict[str, str] = {}
    clash = False
    for name, text in derived.items():
        if text in seen:
            print(f"REFUSED: {name} and {seen[text]} derived the same "
                  f"`because`; an arm must not be attributable to a case it "
                  f"did not break.")
            clash = True
        seen[text] = name
    if clash:
        return 2
    existing = load_because()
    existing.update(derived)
    BECAUSE_FILE.write_text(json.dumps(existing, indent=2, sort_keys=True)
                            + "\n")
    print(f"wrote {len(derived)} derived `because` string(s) to "
          f"{BECAUSE_FILE.relative_to(REPO)}")
    return 0


def grade(selected: list[Arm]) -> int:
    because = load_because()
    missing = [a.name for a in selected if a.name not in because]
    if missing:
        print(f"REFUSED: no derived `because` for {', '.join(missing)}. "
              f"Run --derive first; a typed one is a second copy of the code "
              f"(§17a).")
        return 2

    results = []
    for arm in selected:
        original = (REPO / arm.path).read_text()
        before = hashlib.sha256(original.encode()).hexdigest()

        try:
            apply_patch(arm.path, arm.find, arm.replace)
            rc, out = run_suite(arm.suite)
        finally:
            restore(arm.path, original)
        after = hashlib.sha256((REPO / arm.path).read_bytes()).hexdigest()
        if after != before:
            results.append((arm, "HARNESS-FAILURE",
                            "the revert did not restore the bytes"))
            continue

        if "Error: " in out and "[OK]" not in out and "[FAILED]" not in out:
            results.append((arm, "DID-NOT-COMPILE", ""))
            continue

        v = verdict_for(out, arm.kills)
        if v is None:
            results.append((arm, "NO-VERDICT-FOR-KILLER",
                            "the run told you nothing"))
            continue
        if v == "OK":
            results.append((arm, "SURVIVED", ""))
            continue

        raw = failure_lines_for(out, arm.kills)
        lines = " ".join(l[l.index("Check failed:"):] if "Check failed:" in l
                         else l for l in raw)
        lines = re.sub(r"\s+", " ", lines)
        if because[arm.name] not in lines:
            results.append((arm, "MIS-ATTRIBUTED",
                            f"expected: {because[arm.name]}"))
            continue

        try:
            apply_patch(arm.path, arm.control_find, arm.control_replace)
            crc, cout = run_suite(arm.suite)
        finally:
            restore(arm.path, original)
        cafter = hashlib.sha256((REPO / arm.path).read_bytes()).hexdigest()
        if cafter != before:
            results.append((arm, "HARNESS-FAILURE",
                            "the control revert did not restore the bytes"))
            continue
        if verdict_for(cout, arm.kills) != "OK":
            results.append((arm, "CONTROL-HARNESS-FAILURE",
                            "the behaviour-preserving control reddened the "
                            "killer case"))
            continue

        results.append((arm, "KILLED", ""))

    print()
    print("| arm | subject | verdict | note |")
    print("|-----|---------|---------|------|")
    for arm, verdict, note in results:
        print(f"| {arm.name} | {Path(arm.path).name} | **{verdict}** | "
              f"{note} |")
    killed = sum(1 for _, v, _ in results if v == "KILLED")
    print()
    print(f"{killed} of {len(results)} KILLED")
    return 0 if killed == len(results) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    ap.add_argument("--derive", action="store_true")
    ap.add_argument("--only", default="")
    args = ap.parse_args()

    fh = take_lock()

    if args.needle_scan:
        return report_needle_scan()

    if args.record_control_hashes:
        rc = report_needle_scan()
        if rc:
            return rc
        write_control_hashes()
        return 0

    rc = report_needle_scan()
    if rc:
        return rc
    if not check_control_hashes():
        return 3

    # REFUSE rather than grade a suite that cannot start. See the header: an
    # environment in which every case of `test_cross_renderer_panes.nim` fails
    # would score every arm graded against it KILLED for free.
    selected = ARMS
    if args.only:
        want = {s.strip() for s in args.only.split(",")}
        selected = [a for a in ARMS if a.name in want]
        if not selected:
            print(f"no arm matches {args.only}")
            return 2
    if any(a.suite == SUITE_CROSS for a in selected) and not emulator_dir():
        print("REFUSED: libmcr_emulator.so was not found under "
              "src/db-backend/target/*/build/replay-server-*/out, so "
              "replay-server cannot start and every case of the "
              "cross-renderer suite would fail for an environmental reason. "
              "Build the backend (`cd src/db-backend && cargo build`) or run "
              "with --only over the arms that do not need it.")
        return 4

    if args.derive:
        return derive(selected)
    return grade(selected)


if __name__ == "__main__":
    sys.exit(main())
