#!/usr/bin/env python3
"""Mutation harness for PLAT-5's transient interaction machine.

Every case in `test_layout_interaction.nim` claims to detect something. This
script proves it, one case at a time: it patches a single line of the SUBJECT
(`headless_app/layout_interaction.nim`, or `headless_app/layout_model.nim`
where the property is one PLAT-4 owns and PLAT-5 depends on), and requires that
the **named** case fails. A mutation killed only by some other case is
MISDIRECTED and is a failure of this harness, not a pass.

THREE VERDICTS, NOT TWO (Verification-Harness-Traps §1). An arm that never ran
is not a kill:

  killed          the named case reported [FAILED]
  SURVIVED        the run produced result lines and the named case was [OK]
  HARNESS-FAILURE the mutation did not apply, did not compile, or the run
                  produced NO result lines at all

The last verdict is the one this file exists to keep distinct. A run that
prints nothing looks exactly like a run in which every case passed if the only
signal read is an exit status, and reporting it as "killed" credits an arm that
was never executed.

RESTORATION IS FROM A VERIFIED SNAPSHOT, never from `git checkout --`: the
original bytes are read into memory before the mutation and written back after
it, and the SHA-256 of every touched file is compared against the control hash
before the next arm starts. `git checkout --` rejects a mixed tracked/untracked
argument list wholesale and can leave mutations accumulating in the tree.

Usage (from the repository root):
  direnv exec . python3 src/frontend/viewmodel/tests/unit/run-plat5-mutations.py
"""

import hashlib
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]

SUITE = "src/frontend/viewmodel/tests/unit/test_layout_interaction.nim"
INTER = "src/frontend/headless_app/layout_interaction.nim"
MODEL = "src/frontend/headless_app/layout_model.nim"

TOUCHED = [SUITE, INTER, MODEL]

# The case names, spelled once. A typo here shows up as "the control did not
# run this case" rather than as a silently unkillable arm.
T_FIELDS = "no persisted layout type carries a transient interaction field"
T_SOURCE = "layout_model names none of the transient types, and cannot"
T_BYTES = "a cancelled drag leaves the committed layout byte-identical"
T_CANCEL = "cancel has no layout to change"
T_REVEAL = "revealing a dock does not write revealed on the committed layout"
T_ORIGINS = "a drag records where it came from, for all three origins"
T_PTR_COMPILE = "a LayoutPointer cannot carry a measurement"
T_PTR_FIELDS = "no field of a pointer or a region is a measurement"
T_MEDIA = "a pixel hit-test and a cell hit-test agree, byte for byte"
T_LEGAL = "every candidate offered is a candidate apply accepts"
T_HOVER_MEMBER = "the hovered target is always one of the candidates"
T_KINDS = "every DropTarget kind is reachable, and each shape says which"
T_CONTAINER = "a pointer over a container, or over nothing, offers nothing"
T_PATHS = "paths round-trip against the model's own spelling"
T_ONLY_PANE = ("the only pane of a layout can be dragged nowhere, and each "
               "refusal says why")
T_DOCK_SPLIT = "a docked pane cannot be split into the tree in one command"
T_DOCK_SLOT0 = "a docked pane is never offered the first tab slot"
T_INDEX = ("moving a tab out of its own stack at an index that does not exist "
           "is refused")
T_WHOLE_REGION = "dropping a whole tabbed region into a tab is refused by kind"
T_BEGAN = "a drag ending where it began commits none, and pushes no undo entry"
T_SPLIT_NOOP = "a split-drop that reproduces the same tree commits none too"
T_AGREE = "commit's none and apply's loNoOp agree, over every candidate"
T_EVERY_KIND = "committing every DropTarget kind produces the command it names"
T_UNDO_LOG = "a committed drag is the only thing that reaches the undo log"
T_NOT_DRAGGING = "an interaction that is not dragging commits nothing"
T_RESIZE = "a resize proposes weights and commits one setWeight"
T_CLAMP = "a resize proposal is clamped, and never asks for a zero share"
T_NO_RESIZE = ("there is nothing to resize against a stack, a root, or an "
               "absent pane")

PLAT5_CASES = [
    T_FIELDS, T_SOURCE, T_BYTES, T_CANCEL, T_REVEAL, T_ORIGINS, T_PTR_COMPILE,
    T_PTR_FIELDS, T_MEDIA, T_LEGAL, T_HOVER_MEMBER, T_KINDS, T_CONTAINER,
    T_PATHS, T_ONLY_PANE, T_DOCK_SPLIT, T_DOCK_SLOT0, T_INDEX, T_WHOLE_REGION,
    T_BEGAN, T_SPLIT_NOOP, T_AGREE, T_EVERY_KIND, T_UNDO_LOG, T_NOT_DRAGGING,
    T_RESIZE, T_CLAMP, T_NO_RESIZE,
]


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""


MUTATIONS = [
    # --- the structural check that keeps Interaction out of Layout ---------
    Mutation(
        "P1", MODEL,
        "    tree*: LayoutNode\n"
        "    docked*: seq[DockedPane]\n"
        "    version*: int",
        "    tree*: LayoutNode\n"
        "    docked*: seq[DockedPane]\n"
        "    version*: int\n"
        "    hover*: string",
        T_FIELDS,
        "the planted leak: a transient field on the persisted type",
    ),
    Mutation(
        "P2", MODEL,
        "  Layout* = object",
        "  ## Interaction\n  Layout* = object",
        T_SOURCE,
        "the leak that names the transient type in the persisted module",
    ),
    # --- never touching the committed layout -------------------------------
    Mutation(
        "P3", INTER,
        "  if interaction.kind != ikDraggingTab:\n"
        "    return interaction\n"
        "  Interaction(kind: ikDraggingTab, source: interaction.source,",
        "  if interaction.kind != ikDraggingTab:\n"
        "    return interaction\n"
        '  layout.tree.title = layout.tree.title & "!"\n'
        "  Interaction(kind: ikDraggingTab, source: interaction.source,",
        T_BYTES,
        "hovering writes through the tree ref it was handed",
    ),
    Mutation(
        "P4", INTER,
        "  ## because this routine has no layout to change.\n"
        "  Interaction(kind: ikNone)",
        "  ## because this routine has no layout to change.\n"
        "  interaction",
        T_CANCEL,
    ),
    Mutation(
        "P5", INTER,
        "  some(Interaction(kind: ikRevealingDock, edge: layout.docked[at].edge,",
        '  layout.tree.title = layout.tree.title & "!"\n'
        "  some(Interaction(kind: ikRevealingDock, edge: layout.docked[at].edge,",
        T_REVEAL,
    ),
    Mutation(
        "P6", INTER,
        "    return some(DragOrigin(kind: doStack, stackPath: stackPath.get,",
        '    return some(DragOrigin(kind: doStack, stackPath: "",',
        T_ORIGINS,
    ),
    # --- the pointer carries no measurement --------------------------------
    Mutation(
        "P7", INTER,
        "    zone*: DropZone\n\n  DropRegionKind* = enum",
        "    zone*: DropZone\n    x*: int\n\n  DropRegionKind* = enum",
        T_PTR_COMPILE,
    ),
    Mutation(
        "P8", INTER,
        "    of drWholeNode:\n      discard",
        "    of drWholeNode:\n      extent*: float",
        T_PTR_FIELDS,
    ),
    Mutation(
        "P9", SUITE,
        "                zone: zoneFromFractions(c.col / CellColumns,",
        "                zone: zoneFromFractions(c.col / (CellColumns * 3),",
        T_MEDIA,
        "the two media stop agreeing; the byte comparison must notice",
    ),
    # --- the candidate list ------------------------------------------------
    Mutation(
        "P10", INTER,
        "  apply(layout, cmd.get).kind != loRefused",
        "  true",
        T_LEGAL,
    ),
    Mutation(
        "P11", INTER,
        "  let wanted = regionForZone(layout, pointer)\n"
        "  if wanted.isNone:\n"
        "    return none(DropTarget)",
        "  let wanted = regionForZone(layout, pointer)\n"
        "  if wanted.isNone:\n"
        "    return some(DropTarget(kind: dtDockEdge, edge: leLeft,\n"
        '      region: DropRegion(kind: drWholeNode, path: "zzz")))',
        T_HOVER_MEMBER,
    ),
    Mutation(
        "P12", INTER,
        "      return some(cmdSplitMove(target.splitTarget, source, target.axis, side))",
        "      return some(cmdSplit(target.splitTarget, source, target.axis, side))",
        T_KINDS,
        "a split that cannot move a placed pane loses two kinds outright",
    ),
    Mutation(
        "P13", INTER,
        "  if node.isNil or node.kind != lnPane:\n"
        "    return\n"
        "  for candidate in intoStackCandidates",
        "  if node.isNil:\n"
        "    return\n"
        "  for candidate in intoStackCandidates",
        T_CONTAINER,
    ),
    Mutation(
        "P14", INTER,
        "  if path.len == 0:\n    return root",
        "  if path.len >= 0:\n    return root",
        T_PATHS,
    ),
    Mutation(
        "P15", INTER,
        "      for slot in 0 .. parent.children.len:",
        "      for slot in 0 ..< parent.children.len:",
        T_INDEX,
    ),
    Mutation(
        "P16", INTER,
        "          kind: dtIntoStack, stackAnchor: parent.children[slot - 1].pane,\n"
        "          index: slot,",
        "          kind: dtIntoStack, stackAnchor: parent.children[slot - 1].pane,\n"
        "          index: slot - 1,",
        T_DOCK_SLOT0,
    ),
    Mutation(
        "P17", INTER,
        "    # restoring it first would make this layer sequence two commands — which\n"
        "    # §4.3 does not allow. Restore it, then drag it.\n"
        "    none(LayoutCommand)",
        "    some(cmdSplit(target.splitTarget, source, target.axis, side))",
        T_DOCK_SPLIT,
    ),
    Mutation(
        "P18", INTER,
        "  @[DropTarget(kind: dtSplitBefore, splitTarget: leaf.pane, axis: saRow,\n"
        "               region: DropRegion(kind: drNodeStrip, path: leafPath,\n"
        "                                  side: leLeft)),",
        "  @[DropTarget(kind: dtSplitBefore, splitTarget: leaf.pane, axis: saColumn,\n"
        "               region: DropRegion(kind: drNodeStrip, path: leafPath,\n"
        "                                  side: leLeft)),",
        T_EVERY_KIND,
        "the left strip splits on the wrong axis",
    ),
    # --- refusals PLAT-4 owns and this milestone depends on -----------------
    Mutation(
        "P19", MODEL,
        "      if allPanes(tree).len <= 1:\n"
        "        # Docking the last placed pane would empty the root — §2.4 rule 3\n"
        "        # again, reached from the other direction.\n"
        "        return refusedFor(lpEmptyRoot, cmd.autoHidePane)",
        "      if false:\n"
        "        return refusedFor(lpEmptyRoot, cmd.autoHidePane)",
        T_ONLY_PANE,
    ),
    Mutation(
        "P20", MODEL,
        "    if cmd.mergeWholeRegion:",
        "    if false:",
        T_WHOLE_REGION,
    ),
    Mutation(
        "P21", MODEL,
        "      let at = indexIn(destination, source)\n"
        "      if at == cmd.moveIndex:",
        "      let at = indexIn(destination, source)\n"
        "      if false:",
        T_BEGAN,
        "the same-index move stops being a no-op",
    ),
    Mutation(
        "P22", MODEL,
        "    if cmd.splitMovesPane and equalTrees(tree, layout.tree):",
        "    if false and equalTrees(tree, layout.tree):",
        T_SPLIT_NOOP,
    ),
    # --- commit -------------------------------------------------------------
    Mutation(
        "P23", INTER,
        "  if apply(layout, cmd.get).kind != loApplied:\n"
        "    return none(LayoutCommand)\n"
        "  cmd",
        "  cmd",
        T_AGREE,
        "commit stops asking apply, and the two ideas of 'nothing happened' part",
    ),
    Mutation(
        "P24", INTER,
        "  let cmd = pendingCommand(layout, interaction)\n"
        "  if cmd.isNone:\n"
        "    return none(LayoutCommand)",
        "  let cmd = pendingCommand(layout, interaction)\n"
        "  if true:\n"
        "    return none(LayoutCommand)",
        T_UNDO_LOG,
        "commit produces nothing, so nothing ever reaches the log",
    ),
    Mutation(
        "P25", INTER,
        "  some(Interaction(kind: ikDraggingTab, source: source, origin: origin.get,\n"
        "                   hover: none(DropTarget)))",
        "  some(Interaction(kind: ikDraggingTab, source: source, origin: origin.get,\n"
        "                   hover: some(DropTarget(kind: dtDockEdge, edge: leLeft,\n"
        "                     region: DropRegion(kind: drLayoutStrip, path: \"\",\n"
        "                                        side: leLeft)))))",
        T_NOT_DRAGGING,
        "a drag that has hovered nothing claims to be over something",
    ),
    # --- resize -------------------------------------------------------------
    Mutation(
        "P26", INTER,
        "  weights[at] = clamped / (1.0 - clamped) * others",
        "  weights[at] = effectiveWeight(leaf)",
        T_RESIZE,
    ),
    Mutation(
        "P27", INTER,
        "  if clamped < MinResizeShare:\n"
        "    clamped = MinResizeShare\n"
        "  if clamped > 1.0 - MinResizeShare:\n"
        "    clamped = 1.0 - MinResizeShare",
        "  discard MinResizeShare",
        T_CLAMP,
    ),
    Mutation(
        "P28", INTER,
        "  if parent.isNil or parent.kind == lnStack or parent.children.len < 2:",
        "  if parent.isNil or parent.children.len < 2:",
        T_NO_RESIZE,
    ),
]

DECLARED_SURVIVORS = []

RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")


@dataclass
class RunResult:
    rc: int
    passed: list = field(default_factory=list)
    failed: list = field(default_factory=list)
    ran: bool = True

    @property
    def total(self):
        return len(self.passed) + len(self.failed)


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def run_suite() -> RunResult:
    proc = subprocess.run(
        ["nim", "c", "-r", "--hints:off", "--path:src/frontend/viewmodel",
         "-o:/tmp/plat5-mutation-suite", SUITE],
        cwd=ROOT, capture_output=True, text=True, timeout=3600,
    )
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode)
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        # NOT A KILL. A binary that produced no result lines did not run the
        # suite: it failed to compile, or died before the first case.
        res.ran = False
        print("      ---- no result lines; last 20 lines of output ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)
    return res


def main() -> int:
    baseline = {p: digest(p) for p in TOUCHED}

    print("== control ==")
    control = run_suite()
    if control.failed or not control.ran:
        print(f"CONTROL IS NOT GREEN: rc={control.rc} failed={control.failed}")
        return 1
    missing = [c for c in PLAT5_CASES if c not in control.passed]
    if missing:
        print(f"CONTROL DID NOT RUN {len(missing)} NAMED CASES: {missing}")
        return 1
    print(f"control: {control.total} cases, all {len(PLAT5_CASES)} named ones "
          f"ran, 0 failures\n")

    problems = 0
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        path = ROOT / mut.path
        original = path.read_text()
        occurrences = original.count(mut.find)
        if occurrences != 1:
            print(f"{mut.id:<5} HARNESS-FAILURE      pattern occurs "
                  f"{occurrences} times in {mut.path}, expected 1")
            problems += 1
            continue
        path.write_text(original.replace(mut.find, mut.replace))
        try:
            res = run_suite()
        finally:
            path.write_text(original)
            # Restoration is verified, not assumed.
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{mut.id:<5} HARNESS-FAILURE      {p} did not "
                          f"restore to its control bytes")
                    return 2
        declared = mut in DECLARED_SURVIVORS
        if not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif declared and res.failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"now killed by {res.failed}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", mut.why
        elif not res.failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif mut.killer in res.failed:
            others = [f for f in res.failed if f != mut.killer]
            verdict = "killed"
            note = mut.killer + (f"  (+{len(others)} more)" if others else "")
        else:
            verdict, note = "MISDIRECTED", f"died in {res.failed}, not {mut.killer!r}"
            problems += 1
        print(f"{mut.id:<5} {verdict:<20} {note}")

    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
