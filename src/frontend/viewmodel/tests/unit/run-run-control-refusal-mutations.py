#!/usr/bin/env python3
"""Mutation arms for `test_run_control_refusal_is_shown.nim`.

Run:
    direnv exec . python3 \
      src/frontend/viewmodel/tests/unit/run-run-control-refusal-mutations.py

WHAT THIS PROVES
================

The suite it drives asserts that a click on a LIVE run control ends in
something a user can see. Every one of its arms is green today, so the control
run is fully green and any failure after a mutation is signal — the simple
shape, unlike `run-edit-mode-toolbar-mutations.py`, whose subject is partly
unbuilt and which therefore has to subtract a known-red baseline.

Each arm reintroduces one half of the defect the suite was written for and must
redden THE ASSERTION WRITTEN FOR IT. An arm that leaves the suite green has
shown that the assertion is not measuring what its name claims, which is worth
more than the arm passing.

THE ARM THAT FAILED FIRST, AND WHAT IT TAUGHT
=============================================

The original second arm removed only `noteRunRefusal`'s `if message.len == 0:
return` and expected the over-firing guard to go red. **It did not.** The suite
stayed green, and the reason is a real property of the code rather than a hole
in the test: `runFailureLines` skips diagnostics whose message is empty, so an
empty diagnostic filed into the summary is filtered one layer down and the pane
paints nothing either way.

So that arm was WRONG, not the assertion. It is replaced by two:

  * **M2a** expresses the over-firing defect the guard is actually about — a
    `startRun` that files a sentence on every click, including the accepted
    ones — and it reddens three arms.
  * **M2b** removes BOTH empty-message filters at once, which is what it takes
    to make an empty refusal reach the screen, and reddens the guard alone.

Recording this rather than quietly deleting the arm is the point: the pair now
says out loud that the two guards are redundant with each other, so a future
reader removing either one will find out from M2b which of them was load
bearing.
"""
import os
import subprocess
import sys
import tempfile

REPO = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                      capture_output=True, text=True,
                      check=True).stdout.strip()
VM = os.path.join(
    REPO, "src/frontend/viewmodel/viewmodels/test_results_vm.nim")
TEST = "src/frontend/viewmodel/tests/unit/test_run_control_refusal_is_shown.nim"
OUT = os.path.join(tempfile.mkdtemp(prefix="run-control-mut-"), "suite")

# name, anchor, replacement, file, [second (anchor, replacement)]
MUTATIONS = [
    (
        "M1 the runner's answer is discarded (THE DEFECT AS IT SHIPPED)",
        "  vm.noteRunRefusal(runner())",
        "  discard runner()",
        VM,
    ),
    (
        "M2a startRun files a sentence on EVERY click (over-firing)",
        "  vm.noteRunRefusal(runner())",
        "  discard runner()\n  vm.noteRunRefusal(\"could not start\")",
        VM,
    ),
    (
        "M2b BOTH empty-message guards removed "
        "(noteRunRefusal AND runFailureLines)",
        "  if message.len == 0:\n    return\n  var current = vm.summary.val",
        "  var current = vm.summary.val",
        VM,
        ("    if diagnostic.message.len > 0:\n"
         "      result.add diagnostic.message",
         "    result.add diagnostic.message"),
    ),
    (
        "M3 the refusal is filed as a deployment absence instead",
        "  let runner = vm.runTests.val\n  vm.noteRunRefusal(runner())",
        "  let runner = vm.runTests.val\n  vm.setRunAbsence(runner())",
        VM,
    ),
    (
        "M4 startRun stops guarding on canRun",
        "  ## something a user can see.\n  if not vm.canRun():\n    return",
        "  ## something a user can see.\n  if false:\n    return",
        VM,
    ),
]

# Which arm each mutation must redden. A mutation that reddens something else
# INSTEAD is misdirected and is reported as a failure, because it would then be
# scoring a kill it did not earn.
KILLS = {
    "M1": "a host that declines the run says so ON THE PANE",
    "M2a": "a run the host ACCEPTS leaves no failure line",
    "M2b": "a run the host ACCEPTS leaves no failure line",
    "M3": "the refusal is transient",
    "M4": "a control the pane itself knows is dead is not pressed",
}


def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                          cwd=REPO)


def measure():
    compiled = run(
        f"nim c --hints:off --warnings:off -o:{OUT} {TEST}")
    if compiled.returncode != 0:
        return "COMPILE-FAILED", compiled.stdout + compiled.stderr
    ran = run(OUT)
    return ("GREEN" if ran.returncode == 0 else "RED"), ran.stdout


def failing_arms(output):
    return [line.strip()[9:] for line in output.splitlines()
            if line.strip().startswith("[FAILED]")]


def main() -> int:
    print("=== BASELINE (the tree as committed) ===")
    verdict, out = measure()
    print(f"  {verdict}")
    for line in out.splitlines():
        if line.strip().startswith(("[OK]", "[FAILED]", "[Suite]")):
            print("   ", line.strip())
    if verdict != "GREEN":
        print("baseline is not green; nothing below would mean anything")
        return 1

    problems = 0
    for mutation in MUTATIONS:
        name, anchor, replacement, path = mutation[:4]
        second = mutation[4] if len(mutation) > 4 else None
        arm = name.split()[0]

        source = open(path).read()
        if source.count(anchor) != 1:
            print(f"\n!!! {name}: anchor matched "
                  f"{source.count(anchor)} times, not 1")
            problems += 1
            continue
        mutated = source.replace(anchor, replacement)
        if second is not None:
            if mutated.count(second[0]) != 1:
                print(f"\n!!! {name}: second anchor matched "
                      f"{mutated.count(second[0])} times, not 1")
                problems += 1
                continue
            mutated = mutated.replace(second[0], second[1])

        open(path, "w").write(mutated)
        try:
            verdict, out = measure()
        finally:
            # RESTORED WHETHER OR NOT THE MEASUREMENT SUCCEEDED. A harness that
            # leaves a mutation on disk after an exception has edited the
            # product and told nobody.
            run(f"git checkout -- {path}")

        reds = failing_arms(out)
        print(f"\n=== {name} ===")
        print(f"  {verdict}")
        for red in reds:
            print(f"    RED: {red}")
        if verdict == "GREEN":
            print("  !!! this mutation changed nothing the suite can see")
            problems += 1
        elif not any(KILLS[arm] in red for red in reds):
            print(f"  !!! MISDIRECTED: expected an arm naming "
                  f"'{KILLS[arm]}'")
            problems += 1

    print(f"\nRESULT: {len(MUTATIONS) - problems}/{len(MUTATIONS)} arms "
          f"killed their own assertion")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
