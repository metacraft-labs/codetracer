#!/usr/bin/env python3
"""Mutation harness for PLAT-6's terminal layout binding.

Every case in `app/tests/test_layout_binding.nim` claims to detect something.
This script proves it, one case at a time: it patches a single line of the
SUBJECT (`app/layout/binding.nim`, `app/layout/tab_strip.nim`,
`app/input/mouse.nim`, or `headless_app/layout_model.nim` where the property is
one PLAT-4 owns and this binding depends on) and requires that the **named**
case fails. A mutation killed only by some other case is MISDIRECTED and is a
failure of this harness, not a pass.

THREE VERDICTS, NOT TWO (Verification-Harness-Traps §1). An arm that never ran
is not a kill:

  killed          the named case reported [FAILED]
  SURVIVED        the run produced result lines and the named case was [OK]
  HARNESS-FAILURE the mutation did not apply, did not compile, or the run
                  produced NO result lines at all

The last verdict is the one this file exists to keep distinct. A run that
prints nothing looks exactly like a run in which every case passed if the only
signal read is an exit status, and reporting it as "killed" credits an arm that
was never executed. **Verdicts are parsed from `[OK]` / `[FAILED]` lines and
never from an exit status**, because a compile error also exits non-zero.

DECLARED SURVIVORS ARE A DELIVERABLE. A harness that kills everything says as
little as one that kills nothing, so two arms below are behaviour-preserving
rewrites that MUST survive; an arm that starts being killed is reported as a
problem in its own right.

`test_layout_binding.nim`'s last case asserts a RUNTIME ASSERTION COUNT, so an
arm that changes how many `ck`s run reddens that case as well as its own. That
is expected and is reported as `(+N more)`; what is not tolerated is an arm
whose named case stays green.

RESTORATION IS FROM AN IN-MEMORY SNAPSHOT, never from `git checkout --`: the
original bytes are read before the mutation and written back after it, and the
SHA-256 of every touched file is compared against the control hash before the
next arm starts. The run aborts on a mismatch rather than continuing on a dirty
tree.

Usage (from the `codetracer` repository root):
  direnv exec . python3 src/frontend/tui/app/tests/run-plat6-mutations.py
"""

import hashlib
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]

SUITE = "src/frontend/tui/app/tests/test_layout_binding.nim"
BIND = "src/frontend/tui/app/layout/binding.nim"
TABS = "src/frontend/tui/app/layout/tab_strip.nim"
MOUSE = "src/frontend/tui/app/input/mouse.nim"
INTER = "src/frontend/headless_app/layout_interaction.nim"
MODEL = "src/frontend/headless_app/layout_model.nim"

TOUCHED = [SUITE, BIND, TABS, MOUSE, INTER, MODEL]

# The case names, spelled once. A typo here shows up as "the control did not
# run this case" rather than as a silently unkillable arm.
C_ZONES = ("the hit-test partitions the body: every cell resolves to exactly "
           "one zone")
C_ROUND = "cells -> pointer -> region -> cells is a round trip"
C_STRIP = "the painted tab strip and the hit-test agree, column by column"
C_KINDS = "every drop-target kind is reachable THROUGH the binding"
C_COLLAPSE = "the collapse rules fire through the binding, not only through apply"
C_DOCK = "a docked pane round-trips: dock, render, save, restore, undock"
C_GATE = "PLAT-4's handed-forward gate: a command sweep, then a PROJECTION"
C_DRAW = "the drag ghost, the drop target and the resize guide are on the screen"
C_CANCEL = "a cancelled gesture leaves the committed layout byte-identical"
C_KEYS = "every keyboard gesture has a spelling, and none of them is silent"
C_SGR = "SGR-1006 bytes drive a layout gesture end to end"
C_PROFILE = "a user-modified layout survives a resize; an untouched one re-flows"
C_NOREF = "the binding holds no LayoutNode reference, structurally"
C_COUNT = "assertion count"

PLAT6_CASES = [
    C_ZONES, C_ROUND, C_STRIP, C_KINDS, C_COLLAPSE, C_DOCK, C_GATE, C_DRAW,
    C_CANCEL, C_KEYS, C_SGR, C_PROFILE, C_NOREF, C_COUNT,
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
    # --- the hit-test is total, and every zone is reachable ----------------
    Mutation(
        "M1", BIND,
        '    return some(LayoutPointer(path: "", zone: zone))',
        "    return none(LayoutPointer)",
        C_ZONES,
        "a cell on a dock strip resolves to nothing",
    ),
    Mutation(
        "M2", BIND,
        "  if dt < bandV and dt < best:\n"
        "    best = dt\n"
        "    zone = dzTopEdge",
        "  if false:\n"
        "    best = dt\n"
        "    zone = dzTopEdge",
        C_ZONES,
        "the top edge band is unreachable, so dzTopEdge is never produced",
    ),
    # --- the two directions of the hit-test are one table ------------------
    Mutation(
        "M3", BIND,
        "  of drNodeStrip:\n"
        "    stripOf(geom.dropAreaOfPath(region.path), region.side)",
        "  of drNodeStrip:\n"
        "    stripOf(geom.boundsOfPath(region.path), region.side)",
        C_ROUND,
        "the inverse direction stops excluding the tab strip; the forward one "
        "still does",
    ),
    Mutation(
        "M4", BIND,
        "  of leRight:\n"
        "    let w = edgeBandCells(area.width)\n"
        "    CellArea(col: area.col + area.width - w, row: area.row, width: w,\n"
        "             height: area.height)",
        "  of leRight:\n"
        "    let w = edgeBandCells(area.width)\n"
        "    CellArea(col: area.col, row: area.row, width: w,\n"
        "             height: area.height)",
        C_ROUND,
        "the right-hand strip is drawn on the left",
    ),
    # --- the painter and the hit-test read one tab-strip answer ------------
    Mutation(
        "M5", TABS,
        "      line.add repeat(' ', TabGapCells)",
        "      line.add repeat(' ', TabGapCells + 1)",
        C_STRIP,
        "the paint's gap widens; `tabSpans`, which the hit-test reads, does not",
    ),
    Mutation(
        "M6", TABS,
        "    line.add tabLabel(t, i == active)",
        "    line.add tabLabel(t, false)",
        C_STRIP,
        "the active tab is painted without its brackets",
    ),
    # --- every drop-target kind, through the binding -----------------------
    Mutation(
        "M7", BIND,
        "    let sameCell = event.row == b.pressRow and event.col == b.pressCol",
        "    let sameCell = true",
        C_KINDS,
        "every release is treated as a click, so no drop ever commits",
    ),
    Mutation(
        "M8", BIND,
        "      if region.activeTab < 0 and event.row == region.area.row:",
        "      if false and event.row == region.area.row:",
        C_KINDS,
        "a pane with no tab strip can no longer be picked up at all",
    ),
    # --- the collapse rules, reached BY A GESTURE --------------------------
    Mutation(
        "M9", MODEL,
        "  if node.kind == lnStack:\n"
        "    # A stack with one tab is an ordinary arrangement, not a hole: rule 1 does\n"
        "    # not apply to it. Collapsing it would delete the tab strip the user is\n"
        "    # about to drop a second tab onto.\n"
        "    if node.activeIndex < 0:",
        "  if node.kind == lnStack and kept.len > 1:\n"
        "    if node.activeIndex < 0:",
        C_COLLAPSE,
        "§2.4 rule 1's STACK EXEMPTION is removed, so a one-tab stack collapses",
    ),
    Mutation(
        "M10", MODEL,
        "  if kept.len == 0:\n"
        "    return false                                  # rule 2: emptied, drop me",
        "  if kept.len == 0:\n"
        "    return true",
        C_COLLAPSE,
        "rule 2 stops removing an emptied container",
    ),
    # --- the docked round trip ---------------------------------------------
    Mutation(
        "M11", BIND,
        "    let restored = restoreLayoutDocument(doc)\n"
        "    b.history = newLayoutHistory(restored)",
        "    let restored = restoreLayoutDocument(doc)\n"
        "    discard restored",
        C_DOCK,
        "a restore reports success without adopting anything",
    ),
    Mutation(
        "M12", BIND,
        "  saveLayout(b.layout)",
        "  saveLayout(b.layout.tree)",
        C_DOCK,
        "the save drops the docked panes, keeping only the tree",
    ),
    # --- PLAT-4's handed-forward projection-composition gate ---------------
    Mutation(
        "M13", BIND,
        "  result.projection = projectLayout(layout.tree, result.inner, policy)",
        "  result.projection = projectLayout(layout.tree, body, policy)",
        C_GATE,
        "the tree is projected over the whole body, so it overlaps the strips",
    ),
    Mutation(
        "M14", BIND,
        "  result.inner = CellArea(col: body.col + left, row: body.row + top,\n"
        "                          width: max(0, body.width - left - rightW),\n"
        "                          height: max(0, body.height - top - bottom))",
        "  result.inner = CellArea(col: body.col + left, row: body.row + top,\n"
        "                          width: max(0, body.width - left - rightW),\n"
        "                          height: max(0, body.height - top - bottom + 1))",
        C_GATE,
        "the inner area claims one row the bottom strip also claims",
    ),
    # --- drawing the transient state ---------------------------------------
    Mutation(
        "M15", BIND,
        "    if not ghost.isEmptyArea:\n"
        "      result.add LayoutDecoration(kind: ldDragGhost, area: ghost,",
        "    if false:\n"
        "      result.add LayoutDecoration(kind: ldDragGhost, area: ghost,",
        C_DRAW,
        "the drag ghost is never drawn",
    ),
    Mutation(
        "M16", BIND,
        "  if now.width != before.width:",
        "  if false:",
        C_DRAW,
        "a horizontal resize draws no guide",
    ),
    # --- a cancelled gesture cannot have changed the layout ----------------
    Mutation(
        "M17", BIND,
        "  b.interaction = b.interaction.cancel()\n"
        "  action(lasCancelled, \"gesture cancelled\")",
        "  discard b.dropDrag()\n"
        "  b.interaction = b.interaction.cancel()\n"
        "  action(lasCancelled, \"gesture cancelled\")",
        C_CANCEL,
        "cancelling commits the drag first",
    ),
    # --- the keyboard surface ----------------------------------------------
    Mutation(
        # THE FIRST SPELLING OF THIS ARM SURVIVED, AND IT WAS A NO-OP, NOT A
        # SURVIVING PROPERTY (Verification-Harness-Traps §1's sibling problem;
        # PLAT-5's audit hit the same shape). It changed only the `toEnd`
        # expression to `count`, and the very next line —
        # `if slot > count - 1: slot = count - 1` — clamped it straight back.
        # Re-run as a mutation that reaches the observable behaviour, it kills
        # its named case. An arm that cannot change the output is not evidence
        # about the suite.
        "M18", BIND,
        "  var slot =\n"
        "    if toEnd: (if delta < 0: 0 else: count - 1)\n"
        "    else: index + delta\n"
        "  if slot < 0: slot = 0\n"
        "  if slot > count - 1: slot = count - 1",
        "  var slot =\n"
        "    if toEnd: (if delta < 0: 0 else: count)\n"
        "    else: index + delta\n"
        "  if slot < 0: slot = 0\n"
        "  if slot > count: slot = count",
        C_KEYS,
        "the same-stack slot bound goes back to `count`, which lcMoveTab "
        "refuses — the real defect this arm was written from",
    ),
    Mutation(
        "M19", BIND,
        "    return action(lasUnknownCommand,\n"
        "                  \"'\" & words[0] & \"' is not a layout command\")",
        "    return action(lasUnknownCommand, \"\")",
        C_KEYS,
        "an unknown command reports nothing at all",
    ),
    # --- the mouse ----------------------------------------------------------
    Mutation(
        "M20", BIND,
        "    let delta = if event.button == mbWheelDown: 1 else: -1",
        "    let delta = if event.button == mbWheelDown: -1 else: 1",
        C_SGR,
        "the wheel scrolls the tab strip the wrong way",
    ),
    Mutation(
        "M21", MOUSE,
        "  event.row = row - 1\n"
        "  event.col = col - 1",
        "  event.row = row\n"
        "  event.col = col",
        C_SGR,
        "SGR's one-based wire coordinates are read as zero-based",
    ),
    # --- the responsive-profile decision -----------------------------------
    Mutation(
        "M22", BIND,
        "  if b.userModified:\n"
        "    return false\n"
        "  b.history = newLayoutHistory(initLayout(profileLayout(selected)))",
        "  b.history = newLayoutHistory(initLayout(profileLayout(selected)))",
        C_PROFILE,
        "a resize re-flows a layout the user has modified",
    ),
    Mutation(
        "M23", BIND,
        "  b.userModified = false\n"
        "  action(lasApplied, \"layout reset to the \" & $b.profile & \" profile\")",
        "  action(lasApplied, \"layout reset to the \" & $b.profile & \" profile\")",
        C_PROFILE,
        "`:reset-layout` does not un-freeze the profile",
    ),
    # --- the binding holds no node reference -------------------------------
    Mutation(
        "M24", BIND,
        "  let outcome = b.history.dispatch(cmd)",
        "  let outcome = b.history.dispatch(cmd)\n"
        "  discard nodeAtPath(b.history.value.tree, \"\")",
        C_NOREF,
        "the binding reaches for the ref-returning door",
    ),
    Mutation(
        "M25", INTER,
        "    activeIndex*: int\n"
        "      ## The stack's active child, or -1 for every other kind.",
        "    activeIndex*: int\n"
        "      ## The stack's active child, or -1 for every other kind.\n"
        "    node*: LayoutNode",
        C_NOREF,
        "NodeInfo grows a way back to the tree",
    ),
]

DECLARED_SURVIVORS = [
    Mutation(
        "S1", BIND,
        "proc isEmptyArea*(a: CellArea): bool =\n"
        "  a.width <= 0 or a.height <= 0",
        "proc isEmptyArea*(a: CellArea): bool =\n"
        "  not (a.width > 0 and a.height > 0)",
        "",
        "De Morgan on the emptiness test — the same predicate, spelled the "
        "other way. It MUST survive: a suite that reddens on any edit is as "
        "useless as one that reddens on none.",
    ),
    Mutation(
        "S2", BIND,
        "  if slot < 0: slot = 0\n"
        "  if slot > count - 1: slot = count - 1",
        "  slot = max(0, min(slot, count - 1))",
        "",
        "The same clamp as one expression. Behaviour-preserving for every "
        "`count >= 1`, and `tabPositionOf` cannot answer with a smaller one.",
    ),
]

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


def link_flags():
    """The `--passL:` flags the Tier-1 lane adds, read from the same file."""
    path = ROOT / "build" / "grammars" / "tui-link-flags.txt"
    if not path.is_file():
        return []
    return ["--passL:" + f for f in path.read_text().split()]


def run_suite() -> RunResult:
    archive = ROOT / "build" / "grammars" / "libcodetracer_tui_grammars.a"
    cmd = ["nim", "c", "-r", "--hints:off", "--path:src/frontend/viewmodel",
           f"-d:isonimTuiGrammarArchive={archive}",
           *link_flags(),
           "--nimcache:build/nimcache/plat6-mutations",
           "-o:/tmp/plat6-mutation-suite", SUITE]
    # `errors="replace"`, NOT the default strict decode. A mutated suite is a
    # suite printing diagnostics about bytes it did not expect, and this one
    # slices painted rows — which contain U+2500 — at cell offsets, so a
    # mismatch message can carry a PARTIAL RUNE. With the default,
    # `subprocess.run` raises `UnicodeDecodeError` and the arm ends in a Python
    # traceback instead of in one of this file's three verdicts, which is
    # exactly the "no verdict at all" failure the three-verdict rule exists to
    # keep visible (Verification-Harness-Traps §1). Found by an arm that
    # widened `tabSpans`' gap.
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                          errors="replace", timeout=3600)
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
    # An optional arm filter, so a re-run after fixing ONE arm costs one
    # compile rather than twenty-seven. The control still runs: an arm graded
    # against a suite nobody checked is not graded.
    only = set(sys.argv[1:])
    baseline = {p: digest(p) for p in TOUCHED}

    print("== control ==")
    control = run_suite()
    if control.failed or not control.ran:
        print(f"CONTROL IS NOT GREEN: rc={control.rc} failed={control.failed}")
        return 1
    missing = [c for c in PLAT6_CASES if c not in control.passed]
    if missing:
        print(f"CONTROL DID NOT RUN {len(missing)} NAMED CASES: {missing}")
        return 1
    print(f"control: {control.total} cases, all {len(PLAT6_CASES)} named ones "
          f"ran, 0 failures\n", flush=True)

    problems = 0
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        if only and mut.id not in only:
            continue
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
        print(f"{mut.id:<5} {verdict:<20} {note}", flush=True)

    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
