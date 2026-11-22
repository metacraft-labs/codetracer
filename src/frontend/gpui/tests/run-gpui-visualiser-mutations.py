#!/usr/bin/env python3
"""The mutation harness for the GPUI Variables pane's project visualisers.

The window renders the Variables pane through the open checkout's project
definitions (`.codetracer/visualisers.toml`, the recorded program's own
visualiser function, the project's granted sandboxed visualiser), read per
session by `tui/host/project_definitions_host` — the module the terminal
session reads them through. Each arm plants ONE defect in the window's wiring
or in the pane's presenters, REBUILDS the shipped binary (every subject is
compiled into it), runs `test_gpui_project_visualisers.nim`, and requires RED
with the failure the first run recorded (`gpui-visualiser-mutation-because.json`,
derived with `--derive`).

The machinery is `run-plat44-editing-mutations.py`'s, copied with its subjects,
arms and file names changed and nothing else: committed control digests over
subjects AND suites (§16c), a needle scan that gates re-recording (§39a),
`because` derived from a run, rc 124 is a hang (§1), per-arm restore
verification, one declared behaviour-preserving survivor, and the binary
rebuilt from the restored tree at the end and compared with the one the run
started with.

Usage:
    run-gpui-visualiser-mutations.py [--only V1,V2] [--derive]
    run-gpui-visualiser-mutations.py --needle-scan
    run-gpui-visualiser-mutations.py --record-control-hashes
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
CONTROL = HERE / "gpui-visualiser-mutation-control.sha256"
BECAUSE = HERE / "gpui-visualiser-mutation-because.json"
NIMCACHE = Path(os.environ.get("TMPDIR", "/tmp")) / "gpui-visualiser-mutations"
BIN = REPO / "build/bin/codetracer-gpui"
SHIM = Path(os.environ.get("ISONIM_GPUI_SHIM_DIR",
                           REPO.parent / "isonim-gpui/rust/target/debug"))
TIMEOUT = 3600

LEAVES = "src/frontend/gpui/app/leaves.nim"
MAIN = "src/frontend/gpui/main.nim"
DEFS = "src/frontend/tui/host/project_definitions_host.nim"

SUITE = "src/frontend/gpui/tests/test_gpui_project_visualisers.nim"

SUBJECTS = [LEAVES, MAIN, DEFS]
SUITES = [SUITE]

# (id, subject, find, replace, suites, what it breaks)
ARMS = [
    ("V1", LEAVES, "  withVisualisers(stateVisualisers)",
     "  withVisualisers(@[])", [SUITE],
     "the pane's presenters drop the checkout's tier: built-ins only"),
    ("V2", MAIN, "    stateVisualisersOf = visualisersOnScreen", "    discard",
     [SUITE], "the window never asks for the session's visualisers"),
    ("V3", MAIN,
     "      sd.visualisersFor(valuesOnScreen(vm.currentVariables.val)))",
     "      @[])", [SUITE],
     "the definitions are read and their visualisers thrown away"),
    ("V4", LEAVES, "    stateVisualisers = stateVisualisersOf(vm)",
     "    discard stateVisualisersOf(vm)", [SUITE],
     "the tier is computed and never reaches the rows"),
    ("V5", DEFS, "  result.add sd.defs.visualisers",
     "  discard sd.defs.visualisers", [SUITE],
     "the declared visualisers are left out of every session's tier"),
    ("N1", MAIN,
     "  if gSession.isNil or vm.isNil or vm != gSession.session.stateVM:",
     "  if vm.isNil or gSession.isNil or vm != gSession.session.stateVM:",
     [SUITE], "behaviour-preserving: the DECLARED SURVIVOR"),
]
DECLARED_SURVIVORS = {"N1"}
IN_BINARY = {LEAVES, MAIN, DEFS}


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
    return lane_flags("gpui-shell")


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
        f.write("# Control digests for run-gpui-visualiser-mutations.py — the\n"
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


sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def main():
    # AN UNDECLARED ARM ID, OR AN EMPTY `--only=`, IS REFUSED before anything
    # is touched (`ci/lib/harness_guard.py`).
    refused = refuse_undeclared_arms(sys.argv[1:], globals())
    if refused:
        return refused
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
        backup = path.with_suffix(path.suffix + ".gvisbak")
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
