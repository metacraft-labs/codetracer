#!/usr/bin/env python3
"""PLAT-43 — the mutation harness for the keymap selector.

Each arm plants ONE defect in the selector, the stored preference, the
runtime's `:keymap` and key-ownership, or the editing core's model switch, runs
the two PLAT-43 Tier-1 suites, and requires the suite to go RED **with the
failure it went red with the first time** (the `because`, derived from a run
and committed in `plat43-selector-mutation-because.json`).

THE DISCIPLINE, inherited clause by clause from the harnesses before it:

  * **CONTROL DIGESTS ARE COMMITTED** (`plat43-selector-mutation-control.sha256`)
    and cover the SUBJECTS **and** the SUITES the arms are graded by (§16c: a
    change to a suite invalidates every arm graded against it). A run whose
    tree does not match them mutates nothing.
  * **THE NEEDLE SCAN GATES RE-RECORDING** (§39a): `--record-control-hashes`
    refuses unless every `find` occurs exactly once and ends at a line end, so
    re-recording cannot certify an arm a later repair made unkillable.
  * **`because` IS DERIVED FROM A RUN** (`--derive`), never typed from intent.
  * **rc 124 IS A HANG, NOT A KILL** (§1).
  * **RESTORE IS VERIFIED PER ARM**; a failed restore aborts the run.
  * **ONE DECLARED SURVIVOR**, behaviour-preserving, so a harness that reddens
    everything it touches is visible.

Usage:
    run-plat43-selector-mutations.py                 # grade every arm
    run-plat43-selector-mutations.py --only S1,R2
    run-plat43-selector-mutations.py --needle-scan
    run-plat43-selector-mutations.py --derive
    run-plat43-selector-mutations.py --record-control-hashes
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
CONTROL = HERE / "plat43-selector-mutation-control.sha256"
BECAUSE = HERE / "plat43-selector-mutation-because.json"
NIMCACHE = Path(os.environ.get("TMPDIR", "/tmp")) / "plat43-mutations"
TIMEOUT = 2400

SELECTION = "src/frontend/viewmodel/keymap/keymap_selection.nim"
PREFERENCE = "src/frontend/viewmodel/host/keymap_preference.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
BINDING = "src/frontend/tui/app/edit_binding.nim"
CORE = "src/frontend/viewmodel/editing_core.nim"

SUITE_SELECTOR = "src/frontend/tui/tests/test_plat43_keymap_selector.nim"
SUITE_SOURCES = "src/frontend/tui/tests/test_plat43_selector_sources.nim"

SUBJECTS = [SELECTION, PREFERENCE, RUNTIME, BINDING, CORE]
SUITES = [SUITE_SELECTOR, SUITE_SOURCES]


def tui_flags():
    out = subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
                       "test_lane_extra_flags tui"],
        cwd=REPO, capture_output=True, text=True, check=True).stdout
    return out.split()


# (id, subject, find, replace, suite, what it breaks)
ARMS = [
    ("S1", SELECTION, "    if name == $m:",
     "    if name.toLowerAscii == $m:", SUITE_SELECTOR,
     "the selector normalises what was typed, so `Vim` selects Vim"),
    ("S2", SELECTION, "  KeymapSelection(ok: false, model: kmProductDefault,",
     "  KeymapSelection(ok: true, model: kmProductDefault,", SUITE_SELECTOR,
     "an unknown name silently selects the default"),
    ("S3", SELECTION,
     "    \"'; the accepted values are \" & acceptedKeymapNamesText()",
     "    \"'\"", SUITE_SELECTOR,
     "the refusal stops naming the accepted set"),
    ("S4", SELECTION, "  selectKeymap(text.strip(), KeymapSourceStored)",
     "  selectKeymap(text, KeymapSourceStored)", SUITE_SELECTOR,
     "a stored preference's own newline makes it unreadable"),
    ("P1", PREFERENCE, "  if selection.ok:", "  if true:", SUITE_SELECTOR,
     "a refused stored value is reported as loaded"),
    ("R1", RUNTIME, "            else: rt.editServices.saveKeymap(selection.model)",
     "            else: \"\"", SUITE_SELECTOR,
     "`:keymap` stops asking the host to remember the choice"),
    ("R2", RUNTIME, "  if name in EditorEscapeKeys:", "  if false:",
     SUITE_SELECTOR,
     "Tab stops being the escape hatch: the product default's indent takes it"),
    ("R3", RUNTIME, "    rt.app.editSession.activeBuffer().claimsEditKey(name, 0)",
     "    false", SUITE_SELECTOR,
     "a model's own non-printable keys stop reaching the buffer"),
    ("E1", BINDING, "    buf.doc.switchModel(model)", "    discard",
     SUITE_SELECTOR, "`:keymap` stops re-keying the OPEN buffer"),
    ("C1", CORE, "  d.state.mode = initialModeFor(model)", "  discard",
     SUITE_SELECTOR,
     "a re-keyed document keeps the old model's mode (insert under Vim)"),
    ("C2", CORE,
     "               mode: d.state.mode, textEntry: d.state.mode == emInsert)",
     "               mode: d.state.mode, textEntry: true)", SUITE_SELECTOR,
     "every printable key is text again, so Vim's `u` types a `u`"),
    ("N1", SELECTION, "  selectableKeymapNames().join(\", \")",
     "  join(selectableKeymapNames(), \", \")", SUITE_SELECTOR,
     "behaviour-preserving: the DECLARED SURVIVOR"),
]

UNGRADED: set = set()
DECLARED_SURVIVORS = {"N1"}


def sha(rel):
    return hashlib.sha256((REPO / rel).read_bytes()).hexdigest()


def graded():
    return [a for a in ARMS if a[0] not in UNGRADED]


def needle_scan():
    ok = True
    for arm_id, rel, find, _, _, _ in graded():
        text = (REPO / rel).read_text()
        n = text.count(find)
        if n != 1:
            print(f"  NEEDLE FAIL {arm_id}: {n} occurrence(s) in {rel}")
            ok = False
            continue
        end = text.index(find) + len(find)
        if end < len(text) and text[end] not in "\r\n":
            print(f"  NEEDLE FAIL {arm_id}: does not end at a line end")
            ok = False
    print(f"needle scan: {len(graded())} arm(s), "
          f"{'every find occurs exactly once' if ok else 'FAILED'}")
    return ok


def record_controls():
    if not needle_scan():
        print("REFUSED: re-recording now would certify an unaimed arm (§39a).")
        return 1
    with open(CONTROL, "w") as f:
        f.write("# Control digests for run-plat43-selector-mutations.py —\n"
                "# the subjects AND the suites the arms are graded by (§16c).\n"
                "# Refreshed with --record-control-hashes, gated by the needle\n"
                "# scan (§39a).\n")
        for rel in SUBJECTS + SUITES:
            f.write(f"{sha(rel)}  {rel}\n")
    print(f"recorded {len(SUBJECTS) + len(SUITES)} control digests")
    return 0


def controls_match():
    if not CONTROL.exists():
        print("NO CONTROL DIGESTS — run --record-control-hashes first.")
        return False
    ok = True
    for line in CONTROL.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        digest, rel = line.split("  ", 1)
        if sha(rel) != digest:
            print(f"CONTROL DIGEST MOVED: {rel}")
            ok = False
    return ok


def run_suite(suite):
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    flags = tui_flags() if suite == SUITE_SELECTOR else []
    cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}", f"-o:{NIMCACHE}/{stem}.out"] + \
        flags + [suite]
    try:
        p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 124:
        return "HUNG", []
    failures = [ln.strip().split("Check failed: ", 1)[1]
                for ln in out.splitlines() if "Check failed: " in ln]
    if p.returncode == 0:
        return "GREEN", failures
    if not failures:
        return "DID-NOT-COMPILE" if "Error:" in out else "RED", failures
    return "RED", failures


def apply(rel, find, replace):
    path = REPO / rel
    backup = path.with_suffix(path.suffix + ".plat43bak")
    shutil.copy2(path, backup)
    path.write_text(path.read_text().replace(find, replace, 1))
    return backup


def restore(rel, backup, digest):
    shutil.move(backup, REPO / rel)
    return sha(rel) == digest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--derive", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    a = ap.parse_args()
    os.chdir(REPO)
    if a.needle_scan:
        return 0 if needle_scan() else 1
    if a.record_control_hashes:
        return record_controls()
    if not needle_scan() or not controls_match():
        print("the tree is not at the control bytes; nothing was mutated.")
        return 3
    for suite in SUITES:
        verdict, _ = run_suite(suite)
        if verdict != "GREEN":
            print(f"ABORT: baseline {suite} is {verdict}.")
            return 1
    print("baseline GREEN")
    because = json.loads(BECAUSE.read_text()) if BECAUSE.exists() else {}
    only = set(filter(None, a.only.split(",")))
    digests = {rel: sha(rel) for rel in SUBJECTS}
    derived, bad = {}, []
    for arm_id, rel, find, replace, suite, what in graded():
        if only and arm_id not in only:
            continue
        backup = apply(rel, find, replace)
        try:
            verdict, failures = run_suite(suite)
        finally:
            if not restore(rel, backup, digests[rel]):
                print(f"ABORT: restore of {rel} failed after {arm_id}.")
                return 1
        first = failures[0] if failures else ""
        derived[arm_id] = first
        if arm_id in DECLARED_SURVIVORS:
            ok = verdict == "GREEN"
            mark = "SURVIVED (declared)" if ok else f"MISDIRECTED ({verdict})"
        elif verdict == "RED":
            want = because.get(arm_id)
            ok = a.derive or want is None or want == first
            mark = "KILLED" if ok else f"KILLED BY THE WRONG CHECK: {first!r}"
        else:
            ok = False
            mark = verdict if verdict != "GREEN" else "SURVIVED — NOT ENFORCED"
        print(f"  {arm_id:<4} {mark:<30} {what}")
        if not ok:
            bad.append(arm_id)
    if a.derive:
        merged = dict(because)
        merged.update({k: v for k, v in derived.items()
                       if k not in DECLARED_SURVIVORS})
        BECAUSE.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        print(f"derived {len(derived)} because line(s) into {BECAUSE.name}")
    for rel in SUBJECTS:
        if sha(rel) != digests[rel]:
            print(f"FAIL: {rel} does not match its digest at exit.")
            return 1
    print(f"RESULT: {len(bad)} arm(s) not as required: {', '.join(bad) or '-'}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
