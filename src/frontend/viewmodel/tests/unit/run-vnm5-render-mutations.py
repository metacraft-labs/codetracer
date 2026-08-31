#!/usr/bin/env python3
"""Mutation harness for VN-M5's *rendering* checks.

Sibling of `run-vnm5-mutations.py`, which covers the same milestone's supply
half. That one patches the decoder and requires a decode check to notice; this
one patches the **renderer** -- the session ViewModel, the two views, and the
flow panel's loop arithmetic -- and requires the named rendering check to
notice.

Same rules, for the same reasons:

* A mutation killed by some check other than the one named is **MISDIRECTED**
  and fails the harness. It means the check that was supposed to catch it does
  not, and the green is somebody else's.
* The verdict comes from the parsed `[OK]` / `[FAILED]` lines that `unittest`
  prints, **never** from the exit code (`codetracer-specs`
  `Testing/Verification-Harness-Traps.md`, trap 1). `nim c -r` exits non-zero
  for a *compile* error too, and a compile error is not a kill: it is a
  mutation that never ran.
* A run producing no result lines at all is a harness error, not a pass.
* The control arm runs first and must be green, and must have run **every**
  named check -- a mutation harness whose control skipped a check reports
  kills for a suite that is not there.

## The two mutations worth reading before the rest

`R4` gives every position-less step a **real-looking line 1**. That is the
failure this milestone's renderer exists to prevent, and it is not
hypothetical: a sibling milestone caught a producer resolving a span at byte 0
against an empty line table and getting line 1 of a file whose text was absent.
A real file's line 1 exists and looks plausible.

`R6` is its opposite -- `positionOf` returns *unknown* for everything -- and it
exists to prove the pairing is load-bearing. R6 leaves the "every step renders
as unknown" check **green**, because that check is a universal quantification a
blind renderer satisfies. It is caught only by the control arm over
`not_proved_with_model.json`, the one document whose steps are mixed. Trap 4a:
"a 'must not contain' check paired with a 'must contain' over the same scanner
is self-controlling".

Usage (from the repository root):
  direnv exec . python3 \\
    src/frontend/viewmodel/tests/unit/run-vnm5-render-mutations.py
"""

import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
SUITE = "src/frontend/viewmodel/tests/unit/test_counterexample_session.nim"
VM = "src/frontend/viewmodel/viewmodels/counterexample_session_vm.nim"
PANEL = "src/frontend/viewmodel/viewmodels/verification_vm.nim"
PANEL_VIEW = "src/frontend/viewmodel/views/isonim_verification_view.nim"
LOOP_MATH = "src/frontend/ui/flow_loop_math.nim"

OPENS = "one action turns a failed obligation into a session on its first step"
REFUSES = "nothing is offered where there is nothing to walk, and the refusal says so"
WALKS = "the session walks with the debugger's ordinary controls, and end-stops"
UNKNOWN = "a step with no source position renders as words, with no digits in them"
KNOWN = "a position that IS there renders as itself — the control arm"
DEMOTE = "a location whose line is not a line number is demoted, not trusted"
ANCHOR = "anchors are the editor's own marker type, and only where a position exists"
LOOP = "the loop control moves the session, and its arithmetic is flow_loop_math's"
NOLOOP = "no producer emits a loop step, so the real payloads render no slider"
PROVENANCE = "the provenance travels with the panel and with every row"
PAIRED = "the text tier still offers nothing, and the same renderer offers when it may"

VNM5_CHECKS = [OPENS, REFUSES, WALKS, UNKNOWN, KNOWN, DEMOTE, ANCHOR, LOOP,
               NOLOOP, PROVENANCE, PAIRED]


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""


MUTATIONS = [
    # --- deliverable 1: the action, and its refusal -------------------------
    Mutation(
        "R1", VM,
        "  vm.trace.val = trace\n  vm.currentStep.val = 0",
        "  vm.trace.val = trace\n  vm.currentStep.val = trace.steps.len - 1",
        OPENS,
        "opens on the last step instead of the first",
    ),
    Mutation(
        "R2", VM,
        "  trace.isSome and trace.get.steps.len > 0 and\n"
        "    trace.get.model.status != pmsUnavailable",
        "  trace.isSome",
        REFUSES,
        "offers a walk over a counterexample with no values in it",
    ),
    Mutation(
        "R3", VM,
        "  vm.currentStep.val = max(0, min(index, last))",
        "  vm.currentStep.val = index",
        WALKS,
        "the stepping controls stop end-stopping",
    ),
    # --- the position rule --------------------------------------------------
    Mutation(
        "R4", VM,
        "  if not hasLocation:\n    return unknownPosition(absentReason)",
        "  if not hasLocation:\n"
        "    return StepPosition(knowledge: pkKnown, file: \"src/main.nr\",\n"
        "                        line: 1, column: 1)",
        UNKNOWN,
        "THE mutation: an unknown position renders as a real file's line 1",
    ),
    Mutation(
        "R5", VM,
        '  UnknownPositionText* = "position not recorded"',
        '  UnknownPositionText* = "?:1:1"',
        UNKNOWN,
        "the unknown label becomes a thing shaped like coordinates",
    ),
    Mutation(
        "R6", VM,
        "  if not hasLocation:\n    return unknownPosition(absentReason)",
        "  if true:\n    return unknownPosition(absentReason)",
        KNOWN,
        "a renderer that answers 'unknown' to everything -- which UNKNOWN "
        "passes, and only the control arm catches",
    ),
    Mutation(
        "R7", VM,
        "  if location.range.startLine < 1:",
        "  if false:",
        DEMOTE,
        "a fabricated line 0 is trusted instead of demoted",
    ),
    # --- deliverable 3 ------------------------------------------------------
    Mutation(
        "R8", VM,
        "    let position = positionOf(step.hasLocation, step.location)\n"
        "    if not position.isKnown:\n      continue",
        "    let position = positionOf(step.hasLocation, step.location)\n"
        "    if false:\n      continue",
        ANCHOR,
        "marks the gutter for steps that have no place to sit",
    ),
    # --- deliverable 4 ------------------------------------------------------
    Mutation(
        "R9", VM,
        "  activeIterationForTicks(loop.stepForIterations, step)",
        "  step - loop.firstStep",
        LOOP,
        "a second implementation of 'which iteration am I in'",
    ),
    Mutation(
        "R10", LOOP_MATH,
        "  min(max(current, FirstIteration) + 1, maxIteration)",
        "  min(max(current, FirstIteration) + 2, maxIteration)",
        LOOP,
        "the FLOW PANEL's own arithmetic, changed -- the counterexample's "
        "loop control moves with it, which is what 'not a parallel mechanism' "
        "means",
    ),
    Mutation(
        "R11", VM,
        "    if steps[index].kind != cskLoopIteration:\n"
        "      inc index\n"
        "      continue\n"
        "    var loop = CounterexampleLoop(firstStep: index, lastStep: index)\n"
        "    var lastIteration = low(int)\n"
        "    while index < steps.len and steps[index].kind == cskLoopIteration:",
        "    if steps[index].kind != cskAssignment:\n"
        "      inc index\n"
        "      continue\n"
        "    var loop = CounterexampleLoop(firstStep: index, lastStep: index)\n"
        "    var lastIteration = low(int)\n"
        "    while index < steps.len and steps[index].kind == cskAssignment:",
        NOLOOP,
        "an ordinary assignment counts as a loop iteration, so a slider "
        "appears over models that contain no loop. Both conditions are "
        "changed together on purpose: changing only the outer one makes "
        "`loopsOf` spin without advancing `index`, and a harness cannot tell "
        "a hang from a kill (Verification-Harness-Traps.md, trap 1)",
    ),
    # --- deliverable 5 ------------------------------------------------------
    Mutation(
        "R12", VM,
        "      isSolverDerived: true)",
        "      isSolverDerived: false)",
        PROVENANCE,
        "a row stops carrying its own provenance",
    ),
    Mutation(
        "R13", VM,
        "  result.isRecordedExecution = trace.isRecordedExecution",
        "  result.isRecordedExecution = true",
        PROVENANCE,
        "the panel says a solver's model is a recorded execution",
    ),
    # --- the offer, in the text tier's own panel ----------------------------
    Mutation(
        "R14", PANEL_VIEW,
        "      if model.counterexampleOffers.len > 0:",
        "      if true:",
        PAIRED,
        "the offer section renders over a run that has nothing to offer",
    ),
    Mutation(
        "R15", PANEL,
        "  if vm.payloadStatus.val != psAttached or vm.payload.val.isNone:\n"
        "    return @[]",
        "  if true:\n    return @[]",
        PAIRED,
        "the offer never renders -- the state the negative half of PAIRED is "
        "green over on its own",
    ),
]

DECLARED_SURVIVORS = []

RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")


@dataclass
class RunResult:
    rc: int
    passed: list = field(default_factory=list)
    failed: list = field(default_factory=list)
    compiled: bool = True

    @property
    def total(self):
        return len(self.passed) + len(self.failed)


def run_suite() -> RunResult:
    proc = subprocess.run(
        ["nim", "c", "-r", "--path:src/frontend/viewmodel", "--hints:off",
         "--nimcache:/tmp/nimcache-vnm5-render", "-o:/tmp/vnm5-render-suite",
         SUITE],
        cwd=ROOT, capture_output=True, text=True, timeout=3600,
    )
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode)
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        res.compiled = False
        print("---- no result lines; last 25 lines of output ----")
        print("\n".join(out.splitlines()[-25:]))
    return res


def apply(mut: Mutation) -> str:
    path = ROOT / mut.path
    original = path.read_text()
    if original.count(mut.find) != 1:
        raise SystemExit(
            f"{mut.id}: pattern occurs {original.count(mut.find)} times in "
            f"{mut.path}, expected exactly 1. The mutation table has drifted "
            f"from the source."
        )
    path.write_text(original.replace(mut.find, mut.replace))
    return original


def main() -> int:
    print("== control ==")
    control = run_suite()
    if control.failed or not control.compiled:
        print(f"CONTROL IS NOT GREEN: rc={control.rc} failed={control.failed}")
        return 1
    missing = [c for c in VNM5_CHECKS if c not in control.passed]
    if missing:
        print(f"CONTROL DID NOT RUN {len(missing)} CHECKS: {missing}")
        return 1
    print(f"control: {control.total} checks, {len(VNM5_CHECKS)} of them "
          f"VN-M5 rendering's, 0 failures\n")

    problems = 0
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        original = apply(mut)
        try:
            res = run_suite()
        finally:
            (ROOT / mut.path).write_text(original)
        declared = mut in DECLARED_SURVIVORS
        if not res.compiled:
            verdict, note = "DID-NOT-COMPILE", "the mutation never ran"
            problems += 1
        elif declared and res.failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"now killed by {res.failed}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", mut.why
        elif not res.failed:
            verdict, note = "SURVIVED", "no check noticed"
            problems += 1
        elif mut.killer in res.failed:
            others = [f for f in res.failed if f != mut.killer]
            verdict = "killed"
            note = mut.killer + (f" (+{len(others)} more)" if others else "")
        else:
            verdict, note = "MISDIRECTED", f"died in {res.failed}, not {mut.killer!r}"
            problems += 1
        print(f"{mut.id:<4} {verdict:<20} {note}")
        if mut.why:
            print(f"     ({mut.why})")

    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
