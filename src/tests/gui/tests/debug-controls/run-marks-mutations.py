#!/usr/bin/env python3
"""The mutation harness for the debugger toolbar's transport marks.

`debug_control_marks_test.nim` asserts the marks' GRAMMAR: every reverse mark is
its forward mark mirrored, step in points down at its dot and step out up away
from it, forward marks point right and reverse marks left, and run-to-entry is
two triangles pointing at a bar. Each arm below breaks ONE of those properties
in the mark table and requires the suite to go RED.

The discipline is `run-plat39-oracle-mutations.py`'s: control hashes recorded
before any arm and verified after each, a needle scan (exactly one occurrence,
ending at a line end) before anything is patched, a hang is not a kill, and
every `because` is taken from the arm's own failing run.
"""
import hashlib
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", ".."))
MARKS = "src/frontend/viewmodel/views/debug_control_marks.nim"
SUITE = "src/tests/gui/tests/debug-controls/debug_control_marks_test.nim"

CONTROL_HASHES = {MARKS: None}

TIMEOUT = 900


def sha(path):
    with open(os.path.join(ROOT, path), "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


# Each arm: (id, property, file, needle, replacement, because)
ARMS = [
    (
        "G1", "reverse = forward mirrored",
        MARKS,
        '  ReverseNextArcPath = "M13 9.5C13 3.5 3 3.5 3 9.5"',
        '  ReverseNextArcPath = "M3 9.5C3 3.5 13 3.5 13 9.5"',
        "reverse-next's arc runs left to right like next's; the arc alone is its own mirror as a point set, so the mirror case cannot see it, and 'forward marks point right, reverse marks left' fails on the arc's start.",
    ),
    (
        "G2", "step out points up",
        MARKS,
        '  StepOutHeadPath = "M8.75 5.75L11 3.5L13.25 5.75"',
        '  StepOutHeadPath = "M8.75 1.25L11 3.5L13.25 1.25"',
        "step out's head points down; it is no longer the mirror of reverse step out's, so 'every reverse mark is its forward mark mirrored about x = 8' fails, and 'the step marks say in or out by where the arrow points' fails on the head.",
    ),
    (
        "G3", "a pair is not its own mirror",
        MARKS,
        '  ContinueTrianglePath = "M6.5 3L13.5 8L6.5 13Z"',
        '  ContinueTrianglePath = "M5 3L11 3L11 13L5 13Z"',
        "continue's triangle becomes a box that reverse-continue's triangle no longer mirrors; 'every reverse mark is its forward mark mirrored about x = 8' fails.",
    ),
    (
        "G4", "run-to-entry is skip-to-start",
        MARKS,
        '  RunToEntryTrianglePaths = ["M8.5 3L3.5 8L8.5 13Z", "M14 3L9 8L14 13Z"]',
        '  RunToEntryTrianglePaths = ["M3.5 3L8.5 8L3.5 13Z", "M9 3L14 8L9 13Z"]',
        "run-to-entry's triangles point right, away from the bar; 'run-to-entry is skip-to-start: two triangles pointing at a bar' fails.",
    ),
]

DECLARED_SURVIVORS = set()


def run_suite():
    """Returns (verdict, tail). verdict in {GREEN, RED, HUNG}."""
    cmd = [
        "nim", "c", "-r", "--hints:off", "--warnings:off",
        "--path:src/frontend/viewmodel",
        "--nimcache:nimcache/marks-mut",
        "-o:build/debug_control_marks_mut",
        SUITE,
    ]
    try:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", "timed out after %ds" % TIMEOUT
    out = (p.stdout or "") + (p.stderr or "")
    tail = "\n".join(out.strip().splitlines()[-4:])
    # rc 124 is a hang and is NOT a kill.
    if p.returncode == 124:
        return "HUNG", tail
    return ("GREEN" if p.returncode == 0 else "RED"), tail


def scan_needles():
    """Every needle occurs EXACTLY ONCE and ends at a line end."""
    ok = True
    for arm_id, _, path, needle, _, _ in ARMS:
        with open(os.path.join(ROOT, path)) as f:
            text = f.read()
        n = text.count(needle)
        if n != 1:
            print(f"  NEEDLE FAIL {arm_id}: {n} occurrences in {path} (want 1)")
            print(f"    A needle a later repair MOVED leaves this arm silently")
            print(f"    unkillable — PLAT-33's refactor did this to PLAT-30's M4.")
            ok = False
            continue
        idx = text.index(needle)
        end = idx + len(needle)
        if end < len(text) and text[end] not in "\n\r":
            print(f"  NEEDLE FAIL {arm_id}: does not end at a line end in {path}")
            ok = False
    return ok


def main():
    # THIS HARNESS TAKES NO ARGUMENT, and refuses one rather than ignoring it:
    # an ignored flag (`--needle-scan`, `--only=…`) used to start a full,
    # file-mutating grading run.
    if sys.argv[1:]:
        print(f"unknown argument(s): {sys.argv[1:]}; this harness takes none")
        return 2
    os.chdir(ROOT)
    print("=== transport marks mutation harness ===\n")

    for path in CONTROL_HASHES:
        CONTROL_HASHES[path] = sha(path)
    print(f"control hashes recorded for {len(CONTROL_HASHES)} subjects")

    print("\n--- needle scan (BEFORE any patching) ---")
    if not scan_needles():
        print("\nABORT: the needle scan failed. Arms would be silently unkillable.")
        return 1
    print(f"  OK: all {len(ARMS)} needles unique and line-terminated")

    print("\n--- baseline ---")
    verdict, tail = run_suite()
    if verdict != "GREEN":
        print(f"ABORT: the unmutated suite is {verdict}, not GREEN.\n{tail}")
        return 1
    print("  baseline GREEN")

    killed, survived, hung, misdirected = [], [], [], []
    for arm_id, law, path, needle, repl, because in ARMS:
        full = os.path.join(ROOT, path)
        backup = full + ".marksbak"
        shutil.copy2(full, backup)
        try:
            with open(full) as f:
                text = f.read()
            with open(full, "w") as f:
                f.write(text.replace(needle, repl, 1))
            verdict, tail = run_suite()
        finally:
            shutil.move(backup, full)
            # PER-ARM restore verification. A failed restore poisons every
            # later arm, so it aborts rather than continuing.
            if sha(path) != CONTROL_HASHES[path]:
                print(f"\nABORT: restore of {path} did not reproduce its hash "
                      f"after arm {arm_id}. The tree is poisoned; stopping.")
                return 1

        expect_survive = arm_id in DECLARED_SURVIVORS
        if verdict == "HUNG":
            hung.append(arm_id)
            mark = "HUNG"
        elif verdict == "RED" and not expect_survive:
            killed.append(arm_id)
            mark = "KILLED"
        elif verdict == "GREEN" and expect_survive:
            survived.append(arm_id)
            mark = "SURVIVED (declared)"
        elif verdict == "GREEN":
            survived.append(arm_id)
            mark = "SURVIVED — THE LAW IS NOT ENFORCED"
        else:
            misdirected.append(arm_id)
            mark = "MISDIRECTED (declared survivor went red)"
        print(f"  {arm_id:<9} {law:<22} {mark}")
        if mark.startswith("SURVIVED — "):
            print(f"      because: {because}")

    print("\n=== RESULT ===")
    expected_kills = len(ARMS) - len(DECLARED_SURVIVORS)
    print(f"{len(killed)} of {expected_kills} KILLED; "
          f"{len(survived)} survived ({len(DECLARED_SURVIVORS)} declared); "
          f"{len(hung)} hung; {len(misdirected)} misdirected")

    for path in CONTROL_HASHES:
        if sha(path) != CONTROL_HASHES[path]:
            print(f"FAIL: {path} does not match its control hash at exit.")
            return 1
    print("all control hashes match at exit")

    return 0 if (len(killed) == expected_kills and not hung and not misdirected) else 1


if __name__ == "__main__":
    sys.exit(main())
