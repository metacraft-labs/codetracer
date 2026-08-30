#!/usr/bin/env python3
"""Mutation harness for VN-M5's consumer-side checks.

The suite `VN-M5 the solver's model survives the producer boundary` in
`test_verification_payload.nim` reads a document Verno's emitter produced,
carrying a model a real z3 produced. This script proves each of its checks
detects something: it patches one line of the *consumer* -- the decoder or the
gate -- and requires that the **named** check fails. A mutation killed by some
other check is MISDIRECTED and counts as a failure of this harness.

Mutations no check can kill are listed in DECLARED_SURVIVORS with the reason at
the line, and it is an error if one starts dying.

Per `codetracer-specs/Testing/Verification-Harness-Traps.md` the verdict comes
from the parsed `[OK]` / `[FAILED]` lines that `unittest` prints, never from the
exit code. `nim c -r` exits non-zero for a *compile* error too, and a compile
error is not a kill: it is a mutation that never ran. A run producing no result
lines at all is reported as a harness error.

Usage (from the repository root):
  direnv exec . python3 src/frontend/viewmodel/tests/unit/run-vnm5-mutations.py
"""

import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
SUITE = "src/frontend/viewmodel/tests/unit/test_verification_payload.nim"
DECODER = "src/frontend/viewmodel/viewmodels/verification_payload.nim"

SHAPE = "it decodes, and it is the shape Verno emits"
GATE = "hasSteppableCounterexample answers true — VN-M5's gate opens"
VALUES = "the values are the values the failing execution computes"
NAMES = "the names are the developer's, not the encoding's"
ORDER = "the steps are in the order the program reaches them"
VIOLATION = "the first violated obligation is marked exactly once"
RECORDING = "a solver model is never presented as a recorded execution"
ENVELOPE = "the envelope says in its own contents that it is not a recording"
NOLOC = "a step with no location says nothing rather than guessing one"

VNM5_CHECKS = [SHAPE, GATE, VALUES, NAMES, ORDER, VIOLATION, RECORDING, ENVELOPE, NOLOC]


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""


MUTATIONS = [
    # --- the gate ----------------------------------------------------------
    Mutation(
        "N1", DECODER,
        "    if trace.steps.len > 0 and trace.model.status != pmsUnavailable:",
        "    if trace.steps.len >= 0:",
        GATE,
    ),
    Mutation(
        "N2", DECODER,
        "proc hasSteppableCounterexample*(payload: VerificationPayload): bool =",
        "proc hasSteppableCounterexample*(payload: VerificationPayload): bool =\n  if true: return false",
        GATE,
    ),
    # --- the values --------------------------------------------------------
    Mutation(
        "N3", DECODER,
        '      value: node.str("value"),',
        '      value: node.str("name"),',
        VALUES,
    ),
    Mutation(
        "N4", DECODER,
        '      name: node.str("name"),',
        '      name: node.str("type_name"),',
        NAMES,
    ),
    Mutation(
        "N5", DECODER,
        '      localId: node.optionalInt("local_id"),',
        '      localId: none(int),',
        NAMES,
    ),
    # --- the order ---------------------------------------------------------
    Mutation(
        "N6", DECODER,
        "      result.steps.add step",
        "      result.steps.insert(step, 0)",
        ORDER,
    ),
    # --- the violation -----------------------------------------------------
    Mutation(
        "N7", DECODER,
        '  result.violatedObligation.rawKind = obligation.str("raw_kind")',
        '  result.violatedObligation.rawKind = obligation.str("message") & "!"',
        VIOLATION,
    ),
    # --- honesty -----------------------------------------------------------
    Mutation(
        "N8", DECODER,
        '  result.isRecordedExecution = node.flag("is_recorded_execution", true)',
        "  result.isRecordedExecution = false",
        RECORDING,
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
        ["nim", "c", "-r", "--path:src/frontend/viewmodel", "--hints:off", SUITE],
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
            f"{mut.id}: pattern occurs {original.count(mut.find)} times in {mut.path}, "
            f"expected exactly 1. The mutation table has drifted from the source."
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
        print(f"CONTROL DID NOT RUN {len(missing)} VN-M5 CHECKS: {missing}")
        return 1
    print(f"control: {control.total} checks, {len(VNM5_CHECKS)} of them VN-M5's, 0 failures\n")

    problems = 0
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        original = apply(mut)
        try:
            res = run_suite()
        finally:
            (ROOT / mut.path).write_text(original)
        declared = mut in DECLARED_SURVIVORS
        if not res.compiled:
            # Not a kill. A mutation that does not compile never ran.
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

    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
