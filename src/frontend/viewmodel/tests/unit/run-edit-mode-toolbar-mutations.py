#!/usr/bin/env python3
"""Mutation arms for the Edit-mode-toolbar ViewModel suites.

Run:
    direnv exec . python3 \
      src/frontend/viewmodel/tests/unit/run-edit-mode-toolbar-mutations.py

WHAT THIS HARNESS IS FOR, AND WHY IT IS NOT THE USUAL SHAPE
===========================================================

The three suites it drives state behaviour that is **not built**. Most of their
checks are red on purpose and are waiting for
`viewmodels/edit_mode_toolbar.nim`. **A red check cannot be killed by a
mutation** — it is already failing, so a mutation that "kills" it has
demonstrated nothing. Pretending otherwise would manufacture a kill count out of
checks that never passed, which is the `success: true` chain in another costume
(Verification-Harness-Traps.md §2).

So this harness targets **only the checks that are GREEN today** — the controls.
Those are the assertions that stop the red ones being vacuous: the derived scan
over `detectFolderLang`, the `Lang` cardinality contract, the `smart-*`
exclusion mechanism, the wasm registry's subcommand refusal, the capability
split, the four location parsers, and the recorded `nargo` transcript. If any of
those is not actually asserting what it claims, every conclusion drawn from the
red checks around it is unsupported.

**THE BASELINE IS A SET, NOT AN ASSUMPTION.** The usual runner
(`run-vnm5-render-mutations.py`) treats *any* failure as a signal because its
control run is fully green. Here the control run is deliberately PARTLY red, so
a mutation's effect is measured as the set of checks that are failing **after**
the mutation and were passing **before** it:

    newly_failed = failed(mutated) - failed(control)

A kill is `killer in newly_failed`. A misdirection is `newly_failed` containing
anything else, or being empty. Without the subtraction, all 27 known-red checks
would be counted as collateral on every single arm and every arm would report
MISDIRECTED — the harness would be measuring its own subject's unbuiltness.

**EACH ARM RESOLVES TO EXACTLY ONE ASSERTION, MECHANICALLY.** Arm-to-check
matching is exact list membership over whole `unittest` check names parsed off
the output — never `in` on a string, never a substring. A substring matcher is
how an arm becomes ambiguous and silently never-run, which is a trap this
campaign has already hit once. `verify_arms_are_unambiguous()` below asserts,
before anything runs, that every `killer` is a whole-string member of the
control's passing set and that no two arms name the same check.

CLASSIFICATION (Verification-Harness-Traps.md §1)
-------------------------------------------------
  DID-NOT-COMPILE   no result lines at all -> the mutation never ran. NOT a
                    kill: `nim c -r` exits non-zero for a compile error too.
  SURVIVED          nothing newly failed -> no check noticed. A problem.
  MISDIRECTED       something newly failed, but not the named killer.
  killed            the named killer, and only it, newly failed.
"""

from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
SUITE_DIR = "src/frontend/viewmodel/tests/unit"

SUITES = [
    f"{SUITE_DIR}/test_noir_build_diagnostics.nim",
    f"{SUITE_DIR}/test_edit_mode_toolbar_languages.nim",
    f"{SUITE_DIR}/test_edit_mode_toolbar_model.nim",
]

# Exact `unittest` check names. Written out in full so that an arm names a
# whole check and never a fragment of one.
TRANSCRIPT = "the recorded transcript is the one this suite claims to be about"
PARSERS = "the four families that DO parse still parse — no regression twin"
CLI_CHAIN = "the CLI's own chain already answers Noir here — the derived control"
CMAKE = "one CMake project fires three cpp providers — arbitration is required"
LANG_SET = "the Lang enum is the closed set, and it has 41 members"
LIBTEST = "EMT-A22 a provider's DECLARED capability is not its availability"
NOIR_REC = "EMT-A21 Noir refuses test RECORDING, in the provider's own words"
NO_MODE = "the topbar has no mode parameter today, and no command slots"
NO_RUN_KIND = "EMT-A11 no `run` group kind exists, and none may be added"
GROUPS = "EMT-A9/A10 both group spellings read, and an unknown kind is silent"
MALFORMED = "EMT-A13 a malformed tasks.json is reported, never silently dropped"
PROFILES = "the four profiles disagree about running programs — the control"
WASM = "the wasm registry refuses by SUBCOMMAND — the control for A34"

CONTROLS = [
    TRANSCRIPT, PARSERS, CLI_CHAIN, CMAKE, LANG_SET, LIBTEST, NOIR_REC,
    NO_MODE, NO_RUN_KIND, GROUPS, MALFORMED, PROFILES, WASM,
]


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""
    backends: tuple[str, ...] = ("c", "js")
    #: Which backend this arm is meaningful on. Almost every arm is meaningful
    #: on both. M12 is not, and the reason is the point of the arm.


MUTATIONS: list[Mutation] = [
    # --- the derived anti-drift scan (EMT-A40's mechanism) -----------------
    Mutation(
        "M1",
        "src/ct/utilities/language_detection.nim",
        'if fileExists(folder / "Nargo.toml"):\n    LangNoir',
        'if fileExists(folder / "Cargo.toml"):\n    LangRust',
        CLI_CHAIN,
        "Promote Cargo above Nargo — the EXACT drift EMT-D9 is about, and the "
        "answer the native backend already gives. The derived-precedence "
        "assertion must notice; if it does not, EMT-A40 is transcription rather "
        "than derivation and the anti-drift claim is decorative. "
        "NOTE: the first spelling of this arm reordered Nargo against SCARB, "
        "which the check does not constrain, and it survived. The arm was wrong, "
        "not the check — recorded because a surviving arm that is simply "
        "mis-aimed is indistinguishable from a weak assertion until you read it.",
    ),
    Mutation(
        "M2",
        "src/ct/utilities/language_detection.nim",
        "  for kind, path in walkDir(folder):",
        "  for kind, path in walkDir(folder.parentDir):",
        CLI_CHAIN,
        "Introduce a walk-up. EMT-D9's whole decision is 'nearest marker, no "
        "walk-up', and the check asserts `parentDir` appears nowhere in the "
        "module. A second arm on the same killer is legitimate: the guard forbids "
        "a killer that resolves to more than one CHECK, not two arms probing "
        "different properties of one check.",
    ),
    # --- the Lang cardinality contract ------------------------------------
    Mutation(
        "M3",
        "src/common/common_lang.nim",
        "    LangGdScript  # 40",
        "    LangGdScriptRenamed  # 40",
        LANG_SET,
        "Drop the 41st member's name. A cardinality check that counts by a loose "
        "pattern would still reach 41 and survive.",
    ),
    # --- provider capability-vs-installed-proc (EMT-A22) -------------------
    Mutation(
        "M4",
        "src/ct_test/frameworks/rust_libtest.nim",
        "  provider.run = notImplementedRun",
        "  provider.run = notImplementedRecord",
        LIBTEST,
        "Change which stub is installed as `run`. The check must be reading the "
        "INSTALLED proc, not merely the presence of the word `notImplementedRun` "
        "somewhere in the file.",
    ),
    Mutation(
        "M5",
        "src/ct_test/frameworks/rust_libtest.nim",
        "    canRunProject: true,",
        "    canRunProject: false,",
        LIBTEST,
        "Remove the overclaim itself. If the check survives, it is not actually "
        "pinning the contradiction that makes rust-libtest a trap.",
    ),
    # --- Noir's refusal to record (EMT-A21 / EMT-F6) -----------------------
    Mutation(
        "M6",
        "src/ct_test/frameworks/noir_nargo.nim",
        "  provider.record = recordUnsupported",
        "  provider.record = runNoir",
        NOIR_REC,
        "Make Noir claim test recording. This is the one that must never regress "
        "silently: the acceptance journey depends on Noir reaching replay through "
        "Run rather than Record Tests.",
    ),
    Mutation(
        "M7",
        "src/ct_test/frameworks/noir_nargo.nim",
        "a trace of one event and zero steps",
        "a trace of some events and some steps",
        NOIR_REC,
        "Alter the provider's stated reason. §5 says a cpProvider button carries "
        "the provider's OWN words; a check that tolerates any words is not "
        "asserting that.",
    ),
    # --- the cpp detection collision --------------------------------------
    Mutation(
        "M8",
        "src/ct_test/frameworks/cpp_common.nim",
        "proc hasCatch2Project*(projectRoot: string): bool =",
        "proc hasCatch2ProjectRenamed*(projectRoot: string): bool =",
        CMAKE,
        "Remove one of the three colliding detectors. If the check survives, it is "
        "not establishing that three providers fire on one CMake project.",
    ),
    # --- the topbar's starting state --------------------------------------
    Mutation(
        "M9",
        "src/frontend/viewmodel/viewmodels/topbar_actions.nim",
        "{tbaDebuggerControls, tbaOmnibar,\n                                    tbaSessionTabs}",
        "{tbaOmnibar,\n                                    tbaSessionTabs}",
        NO_MODE,
        "Drop the stepping buttons from the base set — the exact edit the feature "
        "will make, minus the mode parameter that should gate it. The "
        "starting-state check MUST go red here: that is what makes it a check "
        "with an EXPIRY rather than a permanent assertion that the feature was "
        "never built. "
        "NOTE: the first spelling of this arm APPENDED `tbaBuild` to the enum "
        "instead. That broke one suite's compilation, which the harness then "
        "mis-scored — see `run_suites`. The arm was replaced with one that "
        "compiles, because a mutation that cannot compile can never be a kill.",
    ),
    # --- the group vocabulary guard (EMT-A11) ------------------------------
    Mutation(
        "M10",
        "src/frontend/viewmodel/viewmodels/project_actions.nim",
        '    pagTest = "test"',
        '    pagTest = "test"\n    pagRun = "run"',
        NO_RUN_KIND,
        "Reintroduce the superseded `pagRun` kind (EMT-D4). This arm is the whole "
        "reason EMT-A11 exists, and it must be the check that catches it.",
    ),
    # --- the two group spellings (EMT-A9/A10) ------------------------------
    Mutation(
        "M11",
        "src/frontend/viewmodel/viewmodels/project_actions.nim",
        '    if node.hasKey("kind") and node["kind"].kind == JString:',
        "    if false:",
        GROUPS,
        "Break the OBJECT spelling, leaving the bare string working. VS Code "
        "writes both forms — `{\"kind\":\"build\",\"isDefault\":true}` is what its "
        "own task-generation emits — and a reader that handles only one loses "
        "every tasks.json written the other way. The check reads both spellings "
        "from ONE fixture, so this arm must redden it.",
    ),
    # --- the foreign-exception guard (EMT-A13) -----------------------------
    Mutation(
        "M12",
        "src/frontend/viewmodel/viewmodels/project_actions.nim",
        '  except:\n    return what & " is not valid JSON"\n',
        "",
        MALFORMED,
        "Delete the bare handler, leaving only `except CatchableError`. This is "
        "the SHIPPED defect §4.1 records: on JS, `parseJson` delegates to "
        "`JSON.parse`, whose throw is a FOREIGN exception that no typed Nim "
        "handler catches, so a malformed tasks.json took down the renderer. "
        "JS-ONLY BY CONSTRUCTION: on the C backend `JsonParsingError` IS a "
        "`CatchableError`, so this arm cannot fail there and running it on C "
        "would score a survival that means nothing. That asymmetry is not a "
        "limitation of the arm — it is the whole argument for the `vm-unit-js` "
        "lane existing, and this is the arm that demonstrates it. "
        "NOTE: the first spelling narrowed the bare `except:` to `except "
        "CatchableError:` instead, which duplicated the handler above it and "
        "did not compile.",
        ("js",),
    ),
    # --- the capability split ----------------------------------------------
    Mutation(
        "M13",
        "src/frontend/viewmodel/platform/capabilities.nim",
        "  capProcessSpawn, capProcessSignal,",
        "  capProcessSpawn, capProcessArbitraryPrograms, capProcessSignal,",
        PROFILES,
        "Give the WEB profile arbitrary-program capability. The browser tier's "
        "whole expressibility rests on `capProcessSpawn` and "
        "`capProcessArbitraryPrograms` genuinely differing there — collapse them "
        "and §8.1's rule has nothing to branch on.",
    ),
    # --- the wasm registry's subcommand granularity ------------------------
    Mutation(
        "M14",
        "src/frontend/viewmodel/platform/wasm_registry.nim",
        "  if module.subcommands.len == 0:",
        "  if true:",
        WASM,
        "Make every module claim every subcommand. This is exactly the failure "
        "§8.1 forbids: a deployment carrying the compiler but not the tracer must "
        "refuse `nargo trace` by name, and this arm makes it accept it.",
    ),
    # --- the recorded transcript -------------------------------------------
    Mutation(
        "M15",
        "test-programs/noir_build_error/recorded-nargo-compile.stderr",
        "┌─ src/main.nr:3:19",
        "--> src/main.nr:3:19",
        TRANSCRIPT,
        "Rewrite the box-drawing rule into the Rust arrow the spec ASSUMED. If the "
        "transcript check survives, the suite is not actually pinning the "
        "observation that settles §13.1's highest-risk unknown.",
    ),
    Mutation(
        "M16",
        "test-programs/noir_build_error/recorded-nargo-compile.stderr",
        "error: Expected type bool, found type Field",
        "note: Expected type bool, found type Field",
        TRANSCRIPT,
        "Turn the one error into a note, so the fixture is all-warnings. The "
        "severity claim below rests on the fixture being two warnings AND one "
        "error; a check that does not notice cannot support it.",
    ),
    # --- the four location parsers -----------------------------------------
    Mutation(
        "M17",
        "src/frontend/ui/build_location_parser.nim",
        'if not stripped.startsWith("-->"):',
        'if not stripped.startsWith("==>"):',
        PARSERS,
        "Break the Rust matcher. The regression twin exists so that the Noir "
        "assertions are not green over a parser that stopped matching anything.",
    ),
    Mutation(
        "M18",
        "src/frontend/ui/build_location_parser.nim",
        '  if "warning" in lower:',
        '  if "wrning" in lower:',
        PARSERS,
        "Break severity inference. Kills via the GCC line, which carries "
        "`error:`; a parser that answered SevError unconditionally would already "
        "pass, so this arm is really a check on the check.",
    ),
]

RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")


@dataclass
class RunResult:
    passed: list[str] = field(default_factory=list)
    failed: list[str] = field(default_factory=list)
    compiled: bool = True
    output: str = ""
    silent_suites: list[str] = field(default_factory=list)

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def run_suites(backend: str) -> RunResult:
    """Run all three suites. `compiled` is FALSE if ANY suite produced no
    result lines.

    Per-suite, not aggregate. The first spelling of this harness set
    `compiled = False` only when the total across all three was zero, and arm
    M9 walked straight through the gap: adding a `TopbarAction` member broke
    ONE suite's compilation, so its 13 checks vanished from the output
    entirely. Two of them had been green, so nothing was "newly failed" and the
    arm was scored SURVIVED — while twelve known-red checks appeared to have
    turned green, because a check that does not run cannot fail. That is trap 1
    exactly ("the mutation never ran" is not a kill), and it was invisible at
    aggregate granularity.
    """
    res = RunResult()
    chunks = []
    suites_with_results = 0
    for suite in SUITES:
        if backend == "c":
            cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
                   "-f", "--path:src/frontend/viewmodel",
                   "-o:/tmp/emt_mut_bin", suite]
        else:
            cmd = ["nim", "js", "-d:nodejs", "--hints:off", "--warnings:off",
                   "-f", "--path:src/frontend/viewmodel",
                   "-o:/tmp/emt_mut.js", suite]
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        out = proc.stdout + proc.stderr
        if backend == "js" and "Error:" not in out:
            node = subprocess.run(["node", "/tmp/emt_mut.js"], cwd=ROOT,
                                  capture_output=True, text=True)
            out += node.stdout + node.stderr
        chunks.append(out)
        # A compile error also exits non-zero, so the exit code cannot
        # distinguish "the mutation was caught" from "the mutation never ran".
        # Result lines can, and they must be counted PER SUITE.
        if any(RESULT_LINE.match(line) for line in out.splitlines()):
            suites_with_results += 1
        else:
            res.silent_suites.append(suite)
    res.output = "\n".join(chunks)
    for line in res.output.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    res.compiled = suites_with_results == len(SUITES)
    return res


def verify_arms_are_unambiguous(control: RunResult) -> int:
    """Every killer must name exactly one check, and that check must be green.

    This runs BEFORE any mutation. An arm whose killer does not resolve to a
    whole-string member of the control's PASSING set is an arm that can never
    legitimately be killed, and it would otherwise sit in the table looking
    like coverage.
    """
    problems = 0
    for name in CONTROLS:
        matches = [c for c in control.passed if c == name]
        if len(matches) != 1:
            print(f"AMBIGUOUS OR MISSING CONTROL: {name!r} resolves to "
                  f"{len(matches)} passing checks, expected exactly 1")
            problems += 1
    for mut in MUTATIONS:
        if mut.killer not in CONTROLS:
            print(f"{mut.id}: killer {mut.killer!r} is not a declared control")
            problems += 1
        elif mut.killer not in control.passed:
            print(f"{mut.id}: killer {mut.killer!r} is not GREEN in the control "
                  f"run, so a kill would prove nothing")
            problems += 1
    return problems


def apply(mut: Mutation) -> str:
    path = ROOT / mut.path
    original = path.read_text()
    occurrences = original.count(mut.find)
    if occurrences != 1:
        raise SystemExit(
            f"{mut.id}: pattern occurs {occurrences} times in {mut.path}, "
            f"expected exactly 1. The mutation table has drifted from the source."
        )
    path.write_text(original.replace(mut.find, mut.replace))
    return original


def main() -> int:
    backend = sys.argv[1] if len(sys.argv) > 1 else "c"
    if backend not in ("c", "js"):
        raise SystemExit("usage: run-edit-mode-toolbar-mutations.py [c|js]")

    print(f"=== control run ({backend} backend) ===")
    control = run_suites(backend)
    if not control.compiled:
        print("CONTROL DID NOT COMPILE — nothing below would mean anything")
        print(control.output[-3000:])
        return 1

    print(f"control: {len(control.passed)} passing, {len(control.failed)} failing")
    print("The failing set is the SPECIFICATION of unbuilt behaviour and is the")
    print("baseline subtracted from every arm below:")
    for name in sorted(control.failed):
        print(f"  red (expected): {name}")

    problems = verify_arms_are_unambiguous(control)
    if problems:
        print(f"\n{problems} arm(s) do not resolve to exactly one green check")
        return 1

    baseline_failed = set(control.failed)
    print(f"\n=== {len(MUTATIONS)} mutation arms ===")
    verdicts: dict[str, int] = {}

    for mut in MUTATIONS:
        if backend not in mut.backends:
            print(f"{mut.id:<4} {'n/a on ' + backend:<20} "
                  f"meaningful only on: {', '.join(mut.backends)}")
            continue
        original = apply(mut)
        try:
            res = run_suites(backend)
        finally:
            (ROOT / mut.path).write_text(original)

        newly_failed = sorted(set(res.failed) - baseline_failed)
        recovered = sorted(baseline_failed - set(res.failed))

        if not res.compiled:
            verdict = "DID-NOT-COMPILE"
            note = ("the mutation never ran in: " +
                    ", ".join(Path(s).name for s in res.silent_suites))
        elif mut.killer in newly_failed and len(newly_failed) == 1:
            verdict, note = "killed", mut.killer
        elif mut.killer in newly_failed:
            others = [f for f in newly_failed if f != mut.killer]
            verdict = "killed (collateral)"
            note = f"{mut.killer} (+{len(others)} other: {others})"
        elif newly_failed:
            verdict, note = "MISDIRECTED", f"newly red: {newly_failed}"
        else:
            verdict, note = "SURVIVED", "no green check noticed"

        if recovered:
            note += f"  [!] arm turned {len(recovered)} known-red check(s) GREEN: {recovered}"

        verdicts[mut.id] = 0 if verdict.startswith("killed") else 1
        print(f"{mut.id:<4} {verdict:<20} {note}")
        if mut.why and not verdict.startswith("killed"):
            print(f"     why it matters: {mut.why}")

    bad = sum(verdicts.values())
    print(f"\n{len(MUTATIONS) - bad}/{len(MUTATIONS)} arms killed by their own check")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
