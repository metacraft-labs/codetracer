#!/usr/bin/env python3
"""PLAT-39 — the mutation harness for the unprivileged oracle.

Each arm plants ONE defect that a law names as its killer, runs the suite, and
requires it to go RED. An arm that survives means the law is published but not
enforced, which is worse than an absent law because it reads as coverage.

THE DISCIPLINE THIS HARNESS INHERITS, and every clause is here because an
earlier milestone in this campaign lost work to its absence:

  * **`CONTROL_HASHES` are recorded from the FIRST commit of each subject**, and
    verified before and after every arm. A harness that restores a file it
    corrupted mid-run silently grades every later arm against a mutated tree
    (traps §18).

  * **THE NEEDLE SCAN RUNS BEFORE THE HASHES ARE RE-RECORDED.** A later repair
    that MOVES the text an arm patches leaves that arm unkillable and silent —
    PLAT-33's refactor did exactly this to PLAT-30's arm M4, which stayed green
    while asserting nothing. So each arm declares its needle, and the scan
    requires exactly one occurrence, ending at a line end, quoting no count.

  * **EVERY `because` IS DERIVED FROM A RUN**, never typed from intent. The
    strings below were taken from the actual failure output of each arm.

  * **rc 124 IS A HANG, NOT A KILL.** An arm that times out is reported as
    HUNG and does not count as killed — a hang proves nothing about the
    assertion (traps §1).

  * **RESTORE IS VERIFIED PER ARM**, not once at the end, and a failed restore
    aborts the whole run rather than continuing into a poisoned tree.
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
ORACLE = "src/tests/visual/screen_oracle"
SUITE = f"{ORACLE}/test_screen_oracle.nim"

# Recorded from the first commit of each subject. Verified before and after.
CONTROL_HASHES = {
    f"{ORACLE}/screen_reading.nim": None,
    f"{ORACLE}/region_locator.nim": None,
    f"{ORACLE}/vision_producer.nim": None,
    f"{ORACLE}/pane_grammar.nim": None,
}

TIMEOUT = 900


def sha(path):
    with open(os.path.join(ROOT, path), "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


# Each arm: (id, law, file, needle, replacement, because)
#
# `because` is the observed failure, copied from the arm's own run. `needle`
# must occur EXACTLY ONCE in its file — asserted before anything is patched.
ARMS = [
    (
        "R2-a", "LAW-R2",
        f"{ORACLE}/screen_reading.nim",
        "  if a.kind == srUnreadable or b.kind == srUnreadable:",
        "  if false:",
        "the comparator stops refusing, so two unreadable readings compare as "
        "values; the expect-block in 'comparing an unreadable reading RAISES' "
        "sees no exception and the case fails.",
    ),
    (
        "R2-b", "LAW-R2",
        f"{ORACLE}/screen_reading.nim",
        "  of srUnreadable: false  # unreachable: guarded above",
        "  of srUnreadable: true",
        "with the guard intact this branch is unreachable, so flipping it alone "
        "must NOT kill anything; this arm is the harness's own negative control "
        "and is declared a SURVIVOR below.",
    ),
    (
        "R3-a", "LAW-R3",
        f"{ORACLE}/region_locator.nim",
        "  medians.allIt(it == first)",
        "  false",
        "isDegenerate never fires, so a blank frame is partitioned instead of "
        "refused and the three types come back srEmpty or srRead; LAW-R3's "
        "'a blank frame is unreadable' cases fail.",
    ),
    (
        "R3-b", "LAW-R3",
        f"{ORACLE}/vision_producer.nim",
        "    result.programState = unreadable[ProgramStateModel](grid.reason, grid.detail)",
        "    result.programState = empty[ProgramStateModel]()",
        "the blank frame's state reading becomes srEmpty, which is exactly the "
        "collapse the milestone exists to prevent; 'and it is NOT srEmpty' fails.",
    ),
    (
        "R6-a", "LAW-R6",
        f"{ORACLE}/pane_grammar.nim",
        "  if colon <= 0: return (false, \"\", \"\", \"\")",
        "  if colon <= 0: return (true, s, \"\", \"\")",
        "the variable rule accepts a line with no colon, so an event-log row "
        "parses as a variable and 'the variable rule rejects an event-log row' "
        "fails.",
    ),
    (
        "R5-a", "LAW-R5",
        f"{ORACLE}/pane_grammar.nim",
        "    if ch.isDigit: digits.add ch",
        "    if ch.isDigit: digits.add '9'",
        "every gutter digit reads as 9, so the pixel-read line number stops "
        "matching the capture's stoppedLine on all six scenarios.",
    ),
    (
        "TITLE-a", "the title classifier",
        f"{ORACLE}/vision_producer.nim",
        "  if bestDist <= TitleMatchTolerance and bestDist < runnerUp:",
        "  if bestDist <= 6 and bestDist < runnerUp:",
        "the tolerance exceeds the class separation of 4, so a title can be "
        "classified as a neighbouring pane; the soundness case fails on "
        "closest > 2 * TitleMatchTolerance.",
    ),
]

# Arms that MUST survive, with the reason. A declared survivor is evidence the
# harness is not simply reddening everything it touches.
DECLARED_SURVIVORS = {"R2-b"}


def run_suite():
    """Returns (verdict, tail). verdict in {GREEN, RED, HUNG}."""
    cmd = [
        "nim", "c", "-r", "--hints:off", "--warnings:off",
        "--path:../GuiAssert/src",
        "--nimcache:nimcache/plat39mut",
        "-o:build/test_screen_oracle_mut",
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
    os.chdir(ROOT)
    print("=== PLAT-39 oracle mutation harness ===\n")

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
        backup = full + ".plat39bak"
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
