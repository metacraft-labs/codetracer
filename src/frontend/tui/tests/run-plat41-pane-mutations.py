#!/usr/bin/env python3
"""PLAT-41 — the mutation harness for the eight panes that had no view.

Each arm plants ONE defect in how a newly expressed pane is FED, DECIDED or
DRAWN, and requires the PLAT-41 suites to go RED with the failure the first
run recorded (`plat41-pane-mutation-because.json`, `--derive`). The gate's own
words set them: *"a pane that draws an empty list is not a pane that draws"* —
each fed pane has an arm that empties it without removing its structure:

  * the debug controls collapsed again, so the buttons are not drawn (X1);
  * the flow window's steps dropped (X2);
  * the timeline's extent not following the event log (X3);
  * the replay file tree never filled (X4), refused by the replay slot (X5),
    rooted at the wrong folder (X6), or drawn with its folders shut (X7);

and one declared behaviour-preserving survivor (N1).

The discipline is PLAT-40's harness's: committed control digests over subjects
AND suites (§16c); the needle scan gates re-recording (§39a); `because`
derived from a run; rc 124 is a hang (§1); per-arm restore verification.
The native window's drawing (the timeline's native view, a pane's clipping,
the accepted exception's leaf) is graded by the window lane re-measuring —
its record is a measurement a source mutation cannot move.

Usage:
    run-plat41-pane-mutations.py [--only X1,X4] [--derive]
    run-plat41-pane-mutations.py --needle-scan
    run-plat41-pane-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat41-pane-mutation-control.sha256"
BECAUSE = HERE / "plat41-pane-mutation-because.json"
NIMCACHE = Path(os.environ.get("TMPDIR", "/tmp")) / "plat41-mutations"
SHIM = REPO.parent / "isonim-gpui/rust/target/debug"
TIMEOUT = 3600

VIEWS = "src/frontend/view_vocabulary/pane_views.nim"
FLOWVM = "src/frontend/viewmodel/viewmodels/flow_vm.nim"
STORE = "src/frontend/viewmodel/store/replay_data_store.nim"
HOST = "src/frontend/tui/host/native_host.nim"
APP = "src/frontend/headless_app/headless_app.nim"
PATHS = "src/common/trace_source_paths.nim"

PARITY = "src/frontend/tui/tests/test_plat41_parity.nim"
COVERAGE = "src/frontend/tui/tests/test_plat41_pane_coverage.nim"

SUBJECTS = [VIEWS, FLOWVM, STORE, HOST, APP, PATHS]
SUITES = [PARITY, COVERAGE]

ARMS = [
    ("X1", VIEWS,
     '  result.root = viewTreeNode("debugControls", "Debug controls", children,\n'
     '                             expanded = true)',
     '  result.root = viewTreeNode("debugControls", "Debug controls", children,\n'
     '                             expanded = false)',
     [PARITY], "the debug controls collapse again: a heading and no buttons"),
    ("X2", FLOWVM, "  vm.steps.val = flowStepEntriesOf(view)", "  discard",
     [PARITY], "the flow window's steps are dropped again"),
    ("X3", STORE, "  if maxTicks > store.timeline.val.maxRRTicks:",
     "  if false:", [PARITY],
     "the timeline's extent stops following the event log"),
    ("X4", HOST, "    files.setRoot(recordingFileTree(s.tracePath))",
     "    discard", [PARITY], "the replay file tree is never filled"),
    ("X5", APP, "    ViewModel(s.fileTreeVM)", "    nil", [PARITY],
     "a replay slot refuses the file tree again"),
    ("X6", PATHS, "    let root = if slash <= 0: path else: path[0 ..< slash]",
     "    let root = path", [COVERAGE],
     "a recorded FILE taken for its own source folder"),
    ("X7", VIEWS, "  viewTreeNode(path, e.text, kids, expanded = kids.len > 0)",
     "  viewTreeNode(path, e.text, kids, expanded = false)", [COVERAGE],
     "the file tree drawn with every folder shut"),
    ("N1", FLOWVM, "  let base = file[file.rfind('/') + 1 .. ^1]",
     "  let base = file[(file.rfind('/') + 1) .. ^1]", [PARITY],
     "behaviour-preserving: the DECLARED SURVIVOR"),
]
DECLARED_SURVIVORS = {"N1"}


def sha(rel):
    return hashlib.sha256((REPO / rel).read_bytes()).hexdigest()


def lane_flags(lane):
    return subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
                       f"test_lane_extra_flags {lane}"],
        cwd=REPO, capture_output=True, text=True, check=True).stdout.split()


def suite_flags(suite):
    """The owning lane's flags, read rather than spelled (§30)."""
    if suite.startswith("src/frontend/tui/"):
        return lane_flags("tui")
    if suite.startswith("src/frontend/gpui/"):
        return lane_flags("gpui-shell")
    return ["--path:src/frontend/viewmodel"]


def needle_scan():
    ok = True
    seen = {}
    for arm_id, rel, find, *_ in ARMS:
        text = (REPO / rel).read_text()
        n = text.count(find)
        if n != 1:
            print(f"  NEEDLE FAIL {arm_id}: {n} occurrence(s) in {rel}")
            ok = False
            continue
        end = text.index(find) + len(find)
        if not find.endswith("\n") and end < len(text) and text[end] not in "\r\n":
            print(f"  NEEDLE FAIL {arm_id}: does not end at a line end")
            ok = False
        seen.setdefault((rel, find), []).append(arm_id)
    for key, ids in seen.items():
        if len(ids) > 1:
            print(f"  NEEDLE FAIL: arms {ids} share one needle")
            ok = False
    print(f"needle scan: {len(ARMS)} arm(s), "
          f"{'every find occurs exactly once' if ok else 'FAILED'}")
    return ok


def record_controls():
    if not needle_scan():
        print("REFUSED: re-recording now would certify an unaimed arm (§39a).")
        return 1
    with open(CONTROL, "w") as f:
        f.write("# Control digests for run-plat41-pane-mutations.py — the\n"
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
        return "HUNG", ""
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 124:
        return "HUNG", ""
    failures = [ln.strip().split("Check failed: ", 1)[1]
                for ln in out.splitlines() if "Check failed: " in ln]
    if p.returncode == 0:
        return "GREEN", ""
    if not failures and "Error:" in out and "[OK]" not in out:
        return "DID-NOT-COMPILE", out[-600:]
    return "RED", failures[0] if failures else ""


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
    for s in SUITES:
        v, detail = run_suite(s)
        if v != "GREEN":
            print(f"ABORT: baseline {s} is {v}: {detail}")
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
        backup = path.with_suffix(path.suffix + ".plat41bak")
        shutil.copy2(path, backup)
        verdict, first = "GREEN", ""
        try:
            path.write_text(path.read_text().replace(find, replace, 1))
            for s in suites:
                v, detail = run_suite(s)
                if v in ("HUNG", "DID-NOT-COMPILE"):
                    verdict, first = v, detail
                    break
                if v == "RED" and verdict == "GREEN":
                    verdict, first = "RED", detail
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
            if verdict == "DID-NOT-COMPILE":
                print(first)
        print(f"  {arm_id:<4} {mark:<30} {what}")
        if not ok:
            bad.append(arm_id)
    if a.derive:
        merged = dict(because)
        merged.update({k: v for k, v in derived.items()
                       if k not in DECLARED_SURVIVORS})
        BECAUSE.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        print(f"derived {len(derived)} because line(s)")
    for rel in SUBJECTS:
        if sha(rel) != digests[rel]:
            print(f"FAIL: {rel} does not match its digest at exit.")
            return 1
    print(f"RESULT: {len(bad)} arm(s) not as required: {', '.join(bad) or '-'}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
