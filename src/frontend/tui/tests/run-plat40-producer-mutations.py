#!/usr/bin/env python3
"""PLAT-40 — the mutation harness for the pane producers.

Each arm plants ONE defect in how a producer-fed pane is FED, DECODED or DRAWN,
and requires `test_plat40_producers.nim` to go RED with the failure the first
run recorded (`plat40-producer-mutation-because.json`, `--derive`). The arms
follow the milestone's gate:

  * a producer that RUNS AND LOADS NOTHING must fail by name (C1, E1, P1);
  * the ONE decoder's rules — the high-level name, the skipped callless entry
    (D1, D2);
  * the terminal's Points pane, painted and fed (T1, T2);
  * THE PRODUCER PARTITION: a new production writer that nobody declared (W1);

and one declared behaviour-preserving survivor (N1).

The discipline is PLAT-42's harness's: committed control digests over subjects
AND the suite (§16c); the needle scan gates re-recording (§39a); `because`
derived from a run; rc 124 is a hang (§1); per-arm restore verification.

The suite runs in-process against the real `calc` recording and a real
`replay-server`. Its DIFF-9 half reads the committed pixel record of the
native window and the desktop, which a source mutation cannot move; the
native-window table rows (`gpui_binding`) and the desktop's row copy
(`ui/event_log.dataTableRowOf`) are therefore graded by their capture lanes
re-measuring, not here.

Usage:
    run-plat40-producer-mutations.py [--only C1,W1] [--derive]
    run-plat40-producer-mutations.py --needle-scan
    run-plat40-producer-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat40-producer-mutation-control.sha256"
BECAUSE = HERE / "plat40-producer-mutation-because.json"
NIMCACHE = Path(os.environ.get("TMPDIR", "/tmp")) / "plat40-mutations"
SHIM = REPO.parent / "isonim-gpui/rust/target/debug"
TIMEOUT = 3600

SESSION = "src/frontend/viewmodel/headless_session.nim"
STORE = "src/frontend/viewmodel/store/replay_data_store.nim"
HOST = "src/frontend/tui/host/native_host.nim"
TUI = "src/frontend/tui/host/tui_session.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
POINTVM = "src/frontend/viewmodel/viewmodels/point_list_vm.nim"

PRODUCERS = "src/frontend/tui/tests/test_plat40_producers.nim"

SUBJECTS = [SESSION, STORE, HOST, TUI, SHELL, POINTVM]
SUITES = [PRODUCERS]

ARMS = [
    # --- a producer that runs and loads nothing ----------------------------
    ("C1", SESSION,
     '    if s.session.store.applyCalltraceResponse(resp.getOrDefault("body")) >= 0:',
     "    if false:", [PRODUCERS],
     "the call trace is requested and its answer dropped"),
    ("E1", HOST,
     "    discard s.requestAndLoadEventLog(start = 0, count = RecordingEventWindow)",
     "    discard", [PRODUCERS],
     "the recording's event log is never asked for"),
    ("P1", SESSION,
     "  s.session.store.applyVerifiedBreakpoints(path, verified)",
     "  discard verified", [PRODUCERS],
     "the engine's breakpoint verdict never reaches the store"),
    # --- the one decoder ---------------------------------------------------
    ("D1", STORE,
     "    if w.highLevelFunctionName.len > 0: w.highLevelFunctionName else: w.rawName",
     "    w.rawName", [PRODUCERS],
     "a row is named by the raw name again (the native decoder's old rule)"),
    ("D2", STORE,
     "  if call.isNil or call.kind != JObject: return none(CallLineWire)",
     "  if call.isNil or call.kind != JObject: return some(CallLineWire())",
     [PRODUCERS], "a callless entry becomes a nameless row"),
    # --- the terminal's Points pane ----------------------------------------
    ("T1", SHELL,
     "  elif region.pane == panePointList and model.points.loaded:",
     "  elif false:", [PRODUCERS],
     "the terminal paints the Points pane as a bare title again"),
    ("T2", TUI, "  rt.app.points = pointListPaneModelFor(s.points)", "  discard",
     [PRODUCERS], "the terminal's Points pane is never fed"),
    # --- the producer partition --------------------------------------------
    ("W1", POINTVM,
     "proc setPoints*(vm: PointListVM; points: openArray[PointListEntry]) =",
     "proc clearPointsQuietly*(vm: PointListVM) =\n"
     "  if not vm.store.isNil: vm.store.applyPointRows(@[])\n\n"
     "proc setPoints*(vm: PointListVM; points: openArray[PointListEntry]) =",
     [PRODUCERS], "an undeclared production writer of the point rows"),
    # --- the declared survivor ---------------------------------------------
    ("N1", STORE, "  let hasChildren = children > 0",
     "  let hasChildren = (children > 0)", [PRODUCERS],
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
        f.write("# Control digests for run-plat40-producer-mutations.py — the\n"
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
        backup = path.with_suffix(path.suffix + ".plat40bak")
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
