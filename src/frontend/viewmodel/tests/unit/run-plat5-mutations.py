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

THE CLOSING PASS (2026-09-27) closed PLAT-5's two recorded residuals and
extended this harness to cover them:

  * a DOCKED pane is offered every tab slot, the first included, and a bare
    pane's body — `lcMoveTab` / `lcMergeIntoStack` take a docked source (arms
    M1-M7 on the model, P16/P16B on the candidate list);
  * a DIVIDER drag (`beginResizeDivider` / `proposeDivider`) moves the two
    weights beside one divider and commits ONE `cmdSetDivider` (arms D1-D8 on
    the model, I1-I10 on the machine), and the terminal draws its resize guide
    for a divider between two stacks (arm B1) and its mouse picks a divider
    up and drops it (arms B2-B4) — all graded against
    `tui/app/tests/test_layout_binding.nim`.

It also gained what every harness since PLAT-7 carries and this one did not:
`--needle-scan`, a recorded control-digest file
(`plat5-interaction-mutation-control.sha256`) that the full run refuses to
start without, `--only=`, per-arm suites, and restore-on-signal.

EACH ARM RUNS THE SUITE ITS KILLER LIVES IN, and only that suite.

Usage (from the repository root, inside the dev shell, REPLAY_SERVER_BIN
exported — the binding suite's lane expects it):
  python3 src/frontend/viewmodel/tests/unit/run-plat5-mutations.py --needle-scan
  python3 ... --record-control-hashes
  python3 ...                       # grade every arm
  python3 ... --only=P16,D1
"""

import hashlib
import re
import signal
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]

SUITE = "src/frontend/viewmodel/tests/unit/test_layout_interaction.nim"
INTER = "src/frontend/headless_app/layout_interaction.nim"
MODEL = "src/frontend/headless_app/layout_model.nim"
BIND = "src/frontend/tui/app/layout/binding.nim"
BIND_SUITE = "src/frontend/tui/app/tests/test_layout_binding.nim"

TOUCHED = [SUITE, INTER, MODEL, BIND, BIND_SUITE]
SUITES = [SUITE, BIND_SUITE]
CONTROL_HASHES = HERE / "plat5-interaction-mutation-control.sha256"

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
T_DOCK_SPLIT = "a docked pane is split into the tree in one command"
T_DOCK_SLOT0 = "a docked pane is offered every tab slot, the first included"
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
T_DIV_TWO = "a divider drag moves the two weights beside it and no other"
T_DIV_CONTAINERS = ("a divider between stacks, or between whole containers, "
                    "is draggable")
T_DIV_SWEEP = ("every divider of every shape: cancelled untouched, committed "
               "as proposed")
T_NO_DIVIDER = "there is no divider in a stack, past either end, or at the root"
T_DIV_CONTRIB = ("a region holding only contributed panes is dragged from its "
                 "neighbour's side")
T_GUIDE = ("a divider drag between two tabbed regions draws its guide at the "
           "new edge")

PLAT5_CASES = [
    T_FIELDS, T_SOURCE, T_BYTES, T_CANCEL, T_REVEAL, T_ORIGINS, T_PTR_COMPILE,
    T_PTR_FIELDS, T_MEDIA, T_LEGAL, T_HOVER_MEMBER, T_KINDS, T_CONTAINER,
    T_PATHS, T_ONLY_PANE, T_DOCK_SPLIT, T_DOCK_SLOT0, T_INDEX, T_WHOLE_REGION,
    T_BEGAN, T_SPLIT_NOOP, T_AGREE, T_EVERY_KIND, T_UNDO_LOG, T_NOT_DRAGGING,
    T_RESIZE, T_CLAMP, T_NO_RESIZE, T_DIV_TWO, T_DIV_CONTAINERS, T_DIV_SWEEP,
    T_NO_DIVIDER, T_DIV_CONTRIB,
]
T_MOUSE_DIV = ("the mouse drags a divider between two stacks, and only that "
               "divider moves")
BINDING_CASES = [T_GUIDE, T_MOUSE_DIV]
NAMED_CASES = PLAT5_CASES + BINDING_CASES


def suite_of(case: str) -> str:
    return BIND_SUITE if case in BINDING_CASES else SUITE


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
        "    some(cmdSplitMove(target.splitTarget, source, target.axis, side))",
        "    some(cmdSplit(target.splitTarget, source, target.axis, side))",
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
        "    for slot in 0 .. parent.children.len:",
        "    for slot in 0 ..< parent.children.len:",
        T_INDEX,
    ),
    Mutation(
        "P16", INTER,
        "    if not parent.isNil and parent.kind == lnStack:\n"
        "      return some(cmdMoveTab(source, target.stackAnchor, target.index))\n"
        "    some(cmdMergeIntoStack(source, target.stackAnchor))",
        "    if layout.dockedIndex(source) >= 0:\n"
        "      return some(cmdRestoreDocked(source, some(target.stackAnchor)))\n"
        "    if not parent.isNil and parent.kind == lnStack:\n"
        "      return some(cmdMoveTab(source, target.stackAnchor, target.index))\n"
        "    some(cmdMergeIntoStack(source, target.stackAnchor))",
        T_DOCK_SLOT0,
        "RESPELLED 2026-09-27: restores the pre-closing ahRestore route for a "
        "docked source, which lands every slot after the anchor",
    ),
    Mutation(
        "P16B", INTER,
        "  # A bare pane: dropping onto its body turns it into a two-tab stack.\n"
        "  result.add(DropTarget(",
        "  if layout.dockedIndex(source) >= 0:\n"
        "    return\n"
        "  result.add(DropTarget(",
        T_DOCK_SLOT0,
        "a docked pane stops being offered a bare pane's body (the old absence)",
    ),
    Mutation(
        "P17", INTER,
        "    some(cmdSplitMove(target.splitTarget, source, target.axis, side))",
        "    if layout.dockedIndex(source) >= 0:\n"
        "      return none(LayoutCommand)\n"
        "    some(cmdSplitMove(target.splitTarget, source, target.axis, side))",
        T_DOCK_SPLIT,
        "RESPELLED 2026-09-26: the gesture used to be absent and this arm "
        "offered it; PLAT-4's closing pass made it present, so the arm now "
        "restores the absence (the pre-closing commandFor)",
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
    # --- CLOSING PASS: a docked source for lcMoveTab / lcMergeIntoStack ------
    Mutation(
        "M1", MODEL,
        "      destination.children.insert(pane(entry.pane, entry.title),\n"
        "                                  cmd.moveIndex)",
        "      destination.children.insert(pane(entry.pane, entry.title),\n"
        "                                  destination.children.len)",
        T_DOCK_SLOT0,
        "a docked pane lands last whatever slot was named",
    ),
    Mutation(
        "M2", MODEL,
        "      destination.children.insert(pane(entry.pane, entry.title),",
        "      destination.children.insert(pane(entry.pane),",
        T_DOCK_SLOT0,
        "the strip's title is lost on the way into the stack",
    ),
    Mutation(
        "M3", MODEL,
        "      next.docked.delete(dockedFrom)",
        "      discard dockedFrom",
        T_DOCK_SLOT0,
        "the pane stays on the strip as well: placed AND docked",
    ),
    Mutation(
        "M4", MODEL,
        "      if cmd.moveIndex < 0 or cmd.moveIndex > destination.children.len:\n"
        "        return refusedFor(lpIndexOutOfRange, cmd.movedPane)\n"
        "      let entry = next.docked[dockedFrom]\n"
        "      next.docked.delete(dockedFrom)\n"
        "      destination.children.insert(pane(entry.pane, entry.title),\n"
        "                                  cmd.moveIndex)",
        "      let entry = next.docked[dockedFrom]\n"
        "      next.docked.delete(dockedFrom)\n"
        "      destination.children.insert(pane(entry.pane, entry.title),\n"
        "        max(0, min(cmd.moveIndex, destination.children.len)))",
        T_DOCK_SLOT0,
        "an index past the end is clamped instead of refused by kind",
    ),
    Mutation(
        "M5", MODEL,
        "    if dockedFrom >= 0 and not source.isNil:",
        "    if false:",
        T_DOCK_SLOT0,
        "a pane both placed and docked is moved instead of refused",
    ),
    Mutation(
        "M6", MODEL,
        "      next.docked.delete(mergedFrom)",
        "      discard mergedFrom",
        T_DOCK_SLOT0,
        "a docked pane merged onto a bare pane stays on the strip too",
    ),
    Mutation(
        "M7", MODEL,
        "    if mergedFrom >= 0 and not source.isNil:",
        "    if false:",
        T_DOCK_SLOT0,
        "the merge stops refusing a pane that is in both places",
    ),
    # --- CLOSING PASS: the divider drag, in the model -----------------------
    Mutation(
        "D1", MODEL,
        "      sibling.weight = rest",
        "      discard rest",
        T_DIV_TWO,
        "the neighbour does not absorb the difference: the pair's sum moves",
    ),
    Mutation(
        "D2", MODEL,
        "      let across = if cmd.weightDivider.get == ssBefore: at - 1 else: at + 1",
        "      let across = if cmd.weightDivider.get == ssBefore: at + 1 else: at - 1",
        T_DIV_TWO,
        "the divider on the other side of the node moves",
    ),
    Mutation(
        "D3", MODEL,
        "      for _ in 0 ..< cmd.weightLevel:",
        "      for _ in 0 ..< 0:",
        T_DIV_CONTAINERS,
        "weightLevel is ignored, so no stack or container can be named",
    ),
    Mutation(
        "D4", MODEL,
        "      if parent.isNil or parent.kind == lnStack:\n"
        "        return refusedFor(lpNoDivider, cmd.weightTarget)",
        "      if parent.isNil:\n"
        "        return refusedFor(lpNoDivider, cmd.weightTarget)",
        T_NO_DIVIDER,
        "two tabs of a stack are given a divider",
    ),
    Mutation(
        "D5", MODEL,
        "      if rest <= 0.0:",
        "      if rest < 0.0:",
        T_NO_DIVIDER,
        "the neighbour may be squeezed to a zero weight",
    ),
    Mutation(
        "D6", MODEL,
        "      if effectiveWeight(node) == cmd.weightValue:\n"
        "        return noOp()\n",
        "",
        T_DIV_TWO,
        "a divider left where it was stops being loNoOp",
    ),
    Mutation(
        "D7", MODEL,
        "      if cmd.weightLevel < 0:",
        "      if false:",
        T_NO_DIVIDER,
        "a negative level is read as the leaf",
    ),
    Mutation(
        "D8", MODEL,
        "      if cmd.weightValue <= 0.0:",
        "      if cmd.weightValue < 0.0:",
        T_NO_DIVIDER,
        "a zero weight — one neutral share, not zero — is accepted",
    ),
    # --- CLOSING PASS: the divider drag, in the machine ---------------------
    Mutation(
        "I1", INTER,
        "  if container.isNil or container.kind notin {lnRow, lnColumn}:",
        "  if container.isNil or container.kind == lnPane:",
        T_NO_DIVIDER,
        "a stack is offered a divider drag",
    ),
    Mutation(
        "I2", INTER,
        "  if divider < 0 or divider + 1 >= container.children.len:",
        "  if divider < 0 or divider >= container.children.len:",
        T_NO_DIVIDER,
        "a divider past the last child is accepted",
    ),
    Mutation(
        "I3", INTER,
        "    if i < min(at, across):",
        "    if i <= min(at, across):",
        T_DIV_TWO,
        "the divider position is measured from the wrong child",
    ),
    Mutation(
        "I4", INTER,
        "  if mine < floor:\n"
        "    mine = floor\n",
        "",
        T_DIV_SWEEP,
        "a divider dragged past the container's start asks for a negative weight",
    ),
    Mutation(
        "I5", INTER,
        "  weights[across] = pair - mine",
        "  weights[across] = weights[across]",
        T_DIV_TWO,
        "the proposal changes one weight, not the pair",
    ),
    Mutation(
        "I6", INTER,
        "  let other = parent.children[across]\n"
        "  if builtInPaneBelow(other, 0, anchor, level):",
        "  let other = parent.children[across]\n"
        "  if false and builtInPaneBelow(other, 0, anchor, level):",
        T_DIV_CONTRIB,
        "a contributed-only region cannot be named from its neighbour",
    ),
    Mutation(
        "I7", INTER,
        "    if node.isContributed:\n"
        "      return false\n",
        "",
        T_DIV_CONTRIB,
        "a contributed leaf is taken as a built-in anchor",
    ),
    Mutation(
        "I8", INTER,
        "    if interaction.divider.isSome:\n"
        "      return dividerCommand(layout, interaction)\n",
        "",
        T_DIV_TWO,
        "a divider drag commits a plain one-node setWeight",
    ),
    Mutation(
        "I9", INTER,
        "                   proposed: weights, divider: some(ssAfter)))",
        "                   proposed: weights, divider: some(ssBefore)))",
        T_DIV_TWO,
        "beginResizeDivider names the divider on the wrong side of child i",
    ),
    Mutation(
        "I10", INTER,
        "    return proposeDividerWeight(interaction, parent, leaf, share * total)",
        "    discard total",
        T_DIV_TWO,
        "proposeShare on a divider drag falls through to the one-node resize",
    ),
    # --- CLOSING PASS: the terminal draws the guide for any node ------------
    Mutation(
        "B1", BIND,
        "  if info.isNone:\n"
        "    return CellArea()\n"
        "  let after = geometryOf(outcome.layout, geom.body, noInteraction(), policy)",
        "  if info.isNone or info.get.kind != lnPane:\n"
        "    return CellArea()\n"
        "  let after = geometryOf(outcome.layout, geom.body, noInteraction(), policy)",
        T_GUIDE,
        "the guide is drawn for panes only, so a divider between stacks has none",
    ),
    # --- CLOSING PASS: the terminal's mouse picks a divider up ---------------
    Mutation(
        "B2", BIND,
        "      let divider = b.dividerAt(geom, event.row, event.col)",
        "      let divider = none((string, int))",
        T_MOUSE_DIV,
        "a press on a divider cell is only a focus again",
    ),
    Mutation(
        "B3", BIND,
        "      if sameCell:\n"
        "        # A click on the divider cell is what it was before the divider was\n",
        "      if false:\n"
        "        # A click on the divider cell is what it was before the divider was\n",
        T_MOUSE_DIV,
        "a click on a divider cell is treated as a drop",
    ),
    Mutation(
        "B4", BIND,
        "  some(if info.get.kind == lnRow:\n"
        "         float(col - bounds.col + 1) / float(bounds.width)",
        "  some(if info.get.kind != lnRow:\n"
        "         float(col - bounds.col + 1) / float(bounds.width)",
        T_MOUSE_DIV,
        "the release is measured along the wrong axis",
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


_ACTIVE = None   # (path, original bytes) while an arm is applied


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def install_restore_on_signal() -> None:
    """An interrupted grade must not leave a mutation in the tree."""
    def handler(signum, _frame):
        if _ACTIVE is not None:
            path, original = _ACTIVE
            (ROOT / path).write_bytes(original)
            print(f"\nsignal {signum}: restored {path} before exiting")
        sys.exit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, handler)


def link_flags():
    """The `--passL:` flags the Tier-1 `tui` lane adds (PLAT-6's recipe)."""
    path = ROOT / "build" / "grammars" / "tui-link-flags.txt"
    if not path.is_file():
        return []
    return ["--passL:" + f for f in path.read_text().split()]


def run_suite(suite: str = SUITE) -> RunResult:
    stem = Path(suite).stem
    if suite == BIND_SUITE:
        archive = ROOT / "build" / "grammars" / "libcodetracer_tui_grammars.a"
        extra = [f"-d:isonimTuiGrammarArchive={archive}", *link_flags()]
    else:
        extra = []
    proc = subprocess.run(
        ["nim", "c", "-r", "--hints:off", "--path:src/frontend/viewmodel",
         *extra, f"--nimcache:build/nimcache/plat5-mutations-{stem}",
         f"-o:/tmp/plat5-mutation-{stem}", suite],
        cwd=ROOT, capture_output=True, text=True, errors="replace",
        timeout=3600,
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


COUNT_CONSTANT = re.compile(
    r"^[ \t]*(?:const[ \t]+)?(ExpectedAssertions)\*?[ \t]*=[ \t]*(\d+)", re.M)


def needle_scan() -> int:
    """Every needle occurs exactly once; every killer is a real case name in
    its suite; every named case is some arm's killer; no needle quotes an
    assertion-count constant (Verification-Harness-Traps §10.3); every
    subject carries an arm; ids and justifications are distinct."""
    problems = 0
    counts = {}
    for path in TOUCHED:
        for m in COUNT_CONSTANT.finditer((ROOT / path).read_text()):
            counts[m.group(2)] = f"{path}:{m.group(1)}"
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        text = mut.find + mut.replace
        if "ExpectedAssertions" in text or "CHECKS:" in text:
            print(f"{mut.id}: NEEDLE QUOTES A COUNT NAME — §10.3")
            problems += 1
        for digits in re.findall(r"\d\d+", text):
            if digits in counts:
                print(f"{mut.id}: NEEDLE QUOTES {counts[digits]} ({digits})")
                problems += 1
    armed = {m.path for m in MUTATIONS}
    unarmed = [p for p in (INTER, MODEL, BIND, SUITE) if p not in armed]
    if unarmed:
        print(f"SUBJECTS WITH NO ARM: {unarmed}")
        problems += 1
    ids = [m.id for m in MUTATIONS + DECLARED_SURVIVORS]
    if len(set(ids)) != len(ids):
        print("DUPLICATE ARM ID")
        problems += 1
    whys = {}
    for m in MUTATIONS + DECLARED_SURVIVORS:
        if not m.why:
            continue
        key = m.why[:60]
        if key in whys:
            print(f"{m.id}: DUPLICATE justification, shared with {whys[key]}")
            problems += 1
        whys[key] = m.id
    for m in MUTATIONS + DECLARED_SURVIVORS:
        n = (ROOT / m.path).read_text().count(m.find)
        status = "ok" if n == 1 else "LOST" if n == 0 else "AMBIGUOUS"
        if n != 1:
            problems += 1
        print(f"{m.id:<5} {status:<10} {n} occurrence(s) in {m.path}")
    for case in NAMED_CASES:
        src = (ROOT / suite_of(case)).read_text()
        if f'test "{case}"' not in src:
            print(f"KILLER NAME NOT IN {suite_of(case)}: {case!r}")
            problems += 1
    for m in MUTATIONS:
        if m.killer not in NAMED_CASES:
            print(f"{m.id}: killer {m.killer!r} is not a declared case name")
            problems += 1
    unused = [c for c in NAMED_CASES
              if c not in {m.killer for m in MUTATIONS}]
    if unused:
        print(f"NAMED CASES NO ARM KILLS: {unused}")
        problems += 1
    print(f"\n{len(MUTATIONS)} arms, {len(NAMED_CASES)} named cases; "
          f"{problems} problems")
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


sys.path.insert(0, str(Path(__file__).resolve().parents[5] / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def main() -> int:
    global _ACTIVE
    # AN UNDECLARED ARM ID, OR AN EMPTY `--only=`, IS REFUSED before anything
    # is touched (`ci/lib/harness_guard.py`).
    refused = refuse_undeclared_arms(sys.argv[1:], globals())
    if refused:
        return refused
    only = None
    for arg in sys.argv[1:]:
        if arg == "--needle-scan":
            return needle_scan()
        if arg == "--record-control-hashes":
            return record_control_hashes()
        if arg.startswith("--only="):
            only = set(arg[len("--only="):].split(","))
        else:
            print(f"unknown argument: {arg}")
            return 2

    if needle_scan() != 0:
        print("REFUSING TO RUN: the needle scan is not clean (§32)")
        return 1
    if not check_control_hashes():
        print("REFUSING TO RUN: a control digest moved or is absent (§32)")
        return 1

    baseline = {p: digest(p) for p in TOUCHED}
    install_restore_on_signal()
    wanted = [m for m in MUTATIONS + DECLARED_SURVIVORS
              if not only or m.id in only]
    if not wanted:
        print(f"no arm matches {sorted(only or [])}")
        return 1

    print("\n== control ==")
    for suite in SUITES:
        if not any(suite_of(m.killer) == suite for m in wanted):
            continue
        control = run_suite(suite)
        if control.failed or not control.ran or control.rc != 0:
            print(f"CONTROL IS NOT GREEN: {suite} rc={control.rc} "
                  f"failed={control.failed}")
            return 1
        missing = [c for c in NAMED_CASES
                   if suite_of(c) == suite and c not in control.passed]
        if missing:
            print(f"CONTROL DID NOT RUN {len(missing)} NAMED CASES in "
                  f"{suite}: {missing}")
            return 1
        print(f"control {suite}: {control.total} cases, 0 failures")

    problems = 0
    killed = 0
    for mut in wanted:
        path = ROOT / mut.path
        original = path.read_bytes()
        text = original.decode()
        occurrences = text.count(mut.find)
        if occurrences != 1:
            print(f"{mut.id:<5} HARNESS-FAILURE      pattern occurs "
                  f"{occurrences} times in {mut.path}, expected 1")
            problems += 1
            continue
        _ACTIVE = (mut.path, original)
        path.write_bytes(text.replace(mut.find, mut.replace).encode())
        try:
            res = run_suite(suite_of(mut.killer))
        finally:
            path.write_bytes(original)
            _ACTIVE = None
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
            killed += 1
        else:
            verdict, note = "MISDIRECTED", f"died in {res.failed}, not {mut.killer!r}"
            problems += 1
        print(f"{mut.id:<5} {verdict:<20} {note}", flush=True)

    print(f"\n{killed}/{len(wanted)} killed; declared survivors: "
          f"{len(DECLARED_SURVIVORS)}")
    print(f"{problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
