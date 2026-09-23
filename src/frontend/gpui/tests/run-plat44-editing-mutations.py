#!/usr/bin/env python3
"""PLAT-44 — the mutation harness for the GPUI editing arm.

Each arm plants ONE defect in the GPUI key decoder, the edit arm, or the
host's key route, REBUILDS the shipped binary when the defect lives in it, runs
the PLAT-44 suites, and requires RED — with the failure the first run recorded
(`plat44-editing-mutation-because.json`, derived with `--derive`).

The discipline is PLAT-43's harness's, clause for clause: committed control
digests over subjects AND suites (§16c), a needle scan that gates
re-recording (§39a), `because` derived from a run, rc 124 is a hang (§1),
per-arm restore verification, one declared behaviour-preserving survivor.

ONE ADDITION: **THE BINARY IS PART OF THE SUBJECT.** Three suites run
`build/bin/codetracer-gpui`, so an arm whose defect is compiled into it is
graded against a binary REBUILT with the defect — otherwise the shipped-binary
cases grade the unmutated binary and every such arm survives for a reason
that has nothing to do with the assertions (§4a). The binary is rebuilt from
the restored tree at the end, and its digest compared with the one it had
before the run.

Usage:
    run-plat44-editing-mutations.py [--only K1,A2] [--derive]
    run-plat44-editing-mutations.py --needle-scan
    run-plat44-editing-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat44-editing-mutation-control.sha256"
BECAUSE = HERE / "plat44-editing-mutation-because.json"
NIMCACHE = Path(os.environ.get("TMPDIR", "/tmp")) / "plat44-mutations"
BIN = REPO / "build/bin/codetracer-gpui"
SHIM = REPO.parent / "isonim-gpui/rust/target/debug"
TIMEOUT = 3600

KEYS = "src/frontend/gpui/app/gpui_keys.nim"
ARM = "src/frontend/gpui/app/edit_arm.nim"
MAIN = "src/frontend/gpui/main.nim"

SUITE_ARM = "src/frontend/gpui/tests/test_gpui_edit_arm.nim"
SUITE_SHIPPED = "src/frontend/gpui/tests/test_plat44_shipped_writes.nim"
SUITE_BOTH = "src/frontend/tui/tests/test_plat44_both_arms_write.nim"

SUBJECTS = [KEYS, ARM, MAIN]
SUITES = [SUITE_ARM, SUITE_SHIPPED, SUITE_BOTH]

# (id, subject, find, replace, suites, what it breaks)
ARMS = [
    ("K1", KEYS, "      return $base[0].toUpperAscii", "      return base",
     [SUITE_ARM], "a shifted letter decodes as the unshifted one"),
    ("K2", KEYS, "      return ModifierNames[m] & \"+\" & base",
     "      return base", [SUITE_ARM], "Ctrl+s decodes as `s`: saving types an s"),
    ("A1", ARM,
     "  let applied = arm.doc.applyKey(editScopeOf(arm.doc), name, nowMs)",
     "  let applied = arm.doc.applyKey(EditingScope(model: arm.doc.model, "
     "product: pmEdit, pane: epEditor, mode: arm.doc.state.mode, "
     "textEntry: true), name, nowMs)",
     [SUITE_ARM], "the GPUI arm's own scope: every printable key is text"),
    ("A2", ARM, "    result.saved = arm.save()", "    result.saved = true",
     [SUITE_ARM, SUITE_SHIPPED], "save is reported and not performed"),
    ("A3", ARM, "  inc arm.keys",
     "  inc arm.keys\n  arm.doc.state.filters = @[]",
     [SUITE_ARM], "the arm strips the transaction filters: read-only accepts"),
    ("A4", ARM, "    d = arm.doc, medium = GpuiMedium, mutableHere = true,",
     "    d = arm.doc, medium = GpuiMedium, mutableHere = false,",
     [SUITE_ARM, SUITE_SHIPPED],
     "the surface is read-only again and carries the notice"),
    ("M1", MAIN, "      redrawEditor()", "      discard",
     [SUITE_SHIPPED], "an edit is never redrawn in the pane"),
    ("M2", MAIN, "    armEditorPane(r)", "    discard",
     [SUITE_SHIPPED], "the headless keys reach no focused element"),
    ("N1", ARM,
     "proc isDirty*(arm: GpuiEditArm): bool = arm.text != arm.loadedText",
     "proc isDirty*(arm: GpuiEditArm): bool = not (arm.text == arm.loadedText)",
     [SUITE_ARM], "behaviour-preserving: the DECLARED SURVIVOR"),
]
DECLARED_SURVIVORS = {"N1"}
IN_BINARY = {KEYS, ARM, MAIN}


def sha_path(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def sha(rel):
    return sha_path(REPO / rel)


def lane_flags(lane):
    return subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
                       f"test_lane_extra_flags {lane}"],
        cwd=REPO, capture_output=True, text=True, check=True).stdout.split()


def suite_flags(suite):
    if suite == SUITE_BOTH:
        return lane_flags("tui")
    return ["--path:src/frontend/viewmodel"]


def needle_scan():
    ok = True
    for arm_id, rel, find, *_ in ARMS:
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
    print(f"needle scan: {len(ARMS)} arm(s), "
          f"{'every find occurs exactly once' if ok else 'FAILED'}")
    return ok


def record_controls():
    if not needle_scan():
        print("REFUSED: re-recording now would certify an unaimed arm (§39a).")
        return 1
    with open(CONTROL, "w") as f:
        f.write("# Control digests for run-plat44-editing-mutations.py — the\n"
                "# subjects AND the suites the arms are graded by (§16c).\n"
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


def build_binary():
    p = subprocess.run(["just", "build-gpui"], cwd=REPO, capture_output=True,
                       text=True, timeout=TIMEOUT)
    return p.returncode == 0


def run_suite(suite):
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}", f"-o:{NIMCACHE}/{stem}.out"] + \
        suite_flags(suite) + [suite]
    env = dict(os.environ, LD_LIBRARY_PATH=str(SHIM) + ":" +
               os.environ.get("LD_LIBRARY_PATH", ""),
               CODETRACER_REPO_ROOT=str(REPO))
    try:
        p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                           timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 124:
        return "HUNG", []
    failures = [ln.strip().split("Check failed: ", 1)[1]
                for ln in out.splitlines() if "Check failed: " in ln]
    if p.returncode == 0:
        return "GREEN", failures
    if not failures and "Error:" in out:
        return "DID-NOT-COMPILE", failures
    return "RED", failures


def grade(suites):
    """RED if any suite is red; the first failure line across them."""
    first, verdict = "", "GREEN"
    for s in suites:
        v, f = run_suite(s)
        if v in ("HUNG", "DID-NOT-COMPILE"):
            return v, ""
        if v == "RED":
            verdict = "RED"
            if not first and f:
                first = f[0]
    return verdict, first


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
    if not build_binary():
        print("ABORT: the unmutated binary does not build.")
        return 1
    binary_digest = sha_path(BIN)
    v, _ = grade(SUITES)
    if v != "GREEN":
        print(f"ABORT: the baseline is {v}.")
        return 1
    print("baseline GREEN")
    because = json.loads(BECAUSE.read_text()) if BECAUSE.exists() else {}
    only = set(filter(None, a.only.split(",")))
    digests = {rel: sha(rel) for rel in SUBJECTS}
    derived, bad = {}, []
    for arm_id, rel, find, replace, suites, what in ARMS:
        if only and arm_id not in only:
            continue
        path = REPO / rel
        backup = path.with_suffix(path.suffix + ".plat44bak")
        shutil.copy2(path, backup)
        try:
            path.write_text(path.read_text().replace(find, replace, 1))
            if rel in IN_BINARY and not build_binary():
                verdict, first = "DID-NOT-COMPILE", ""
            else:
                verdict, first = grade(suites)
        finally:
            shutil.move(backup, path)
            if sha(rel) != digests[rel]:
                print(f"ABORT: restore of {rel} failed after {arm_id}.")
                return 1
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
        print(f"derived {len(derived)} because line(s)")
    if not build_binary() or sha_path(BIN) != binary_digest:
        print("FAIL: the binary rebuilt from the restored tree differs from "
              "the one the run started with.")
        return 1
    for rel in SUBJECTS:
        if sha(rel) != digests[rel]:
            print(f"FAIL: {rel} does not match its digest at exit.")
            return 1
    print(f"RESULT: {len(bad)} arm(s) not as required: {', '.join(bad) or '-'}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
