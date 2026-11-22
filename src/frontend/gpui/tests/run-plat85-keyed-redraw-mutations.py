#!/usr/bin/env python3
"""The mutation harness for the GPUI window's keyed, in-place redraws.

Each arm plants ONE defect in the element pools (`element_reuse.nim`), the
panes' digests (`app/leaves.nim`), the window's wiring of a kept row's
listeners (`window_clicks.nim`), or the window's draw of the editor
(`main.nim`), REBUILDS the shipped binary when the defect lives in it, runs
the suites, and requires RED — with the failure the first run recorded
(`plat85-keyed-redraw-mutation-because.json`, derived with `--derive`).

The discipline is PLAT-44's harness's, clause for clause: committed control
digests over subjects AND suites (§16c), a needle scan that gates
re-recording (§39a), `because` derived from a run, rc 124 is a hang (§1),
per-arm restore verification, one declared behaviour-preserving survivor,
and the binary is part of the subject: `test_gpui_keyed_redraw.nim` runs
`build/bin/codetracer-gpui`, so an arm compiled into it is graded against a
binary rebuilt with the defect.

`ISONIM_GPUI_SHIM_DIR` names the shim the suites load, as the suites read it;
`GPUI_SHIM_FILE` pins the binary and the suites to one shim file.

Usage:
    run-plat85-keyed-redraw-mutations.py [--only E1,C1] [--derive]
    run-plat85-keyed-redraw-mutations.py --needle-scan
    run-plat85-keyed-redraw-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat85-keyed-redraw-mutation-control.sha256"
BECAUSE = HERE / "plat85-keyed-redraw-mutation-because.json"
NIMCACHE = Path(os.environ.get("TMPDIR", "/tmp")) / "plat85-mutations"
BIN = REPO / "build/bin/codetracer-gpui"
SHIM = Path(os.environ.get("ISONIM_GPUI_SHIM_DIR",
                           str(REPO.parent / "isonim-gpui/rust/target/debug")))
TIMEOUT = 3600

POOLS = "src/frontend/gpui/element_reuse.nim"
LEAVES = "src/frontend/gpui/app/leaves.nim"
CLICKS = "src/frontend/gpui/window_clicks.nim"
MAIN = "src/frontend/gpui/main.nim"

SUITE_UNIT = "src/frontend/gpui/tests/test_gpui_element_reuse.nim"
SUITE_WINDOW = "src/frontend/gpui/tests/test_gpui_keyed_redraw.nim"

SUBJECTS = [POOLS, LEAVES, CLICKS, MAIN]
SUITES = [SUITE_UNIT, SUITE_WINDOW]

# (id, subject, find, replace, suites, what it breaks)
ARMS = [
    ("E1", POOLS, "    if d.digest == digest and not d.el.isNil:",
     "    if not d.el.isNil:", [SUITE_UNIT, SUITE_WINDOW],
     "a piece drawn from other inputs is handed back: a stale row stays"),
    ("E2", POOLS, "  if fullRedraw or not p.open or key in p.cur:",
     "  if true:", [SUITE_UNIT, SUITE_WINDOW],
     "nothing is ever kept: every step rebuilds every element"),
    ("E3", POOLS,
     "      gpui_destroy_tree(d.el)\n  p.prev = initTable[string, Drawn]()\n"
     "  p.open = false",
     "      discard\n  p.prev = initTable[string, Drawn]()\n  p.open = false",
     [SUITE_UNIT], "a piece the draw did not take is left alive"),
    ("E4", POOLS, "  if p.open and key notin p.cur:",
     "  if p.open:", [SUITE_UNIT],
     "a second piece under one key replaces the first in the pool"),
    ("C1", CLICKS, "    var click = liveClickOf(r, live)",
     "    var click = c", [SUITE_UNIT],
     "a kept row's listener reports the row as it was wired"),
    ("L1", LEAVES,
     "    let digest = hash((row, runs[i], widest, scroll.leftCols, caretColumn,",
     "    let digest = hash((runs[i], widest, scroll.leftCols, caretColumn,",
     [SUITE_WINDOW], "an editor row's digest leaves out the row itself"),
    ("L2", LEAVES,
     "    let digest = hash((ev, isCurrent, isFuture, shown, drawnWidths, widths,",
     "    let digest = hash((ev, isCurrent, shown, drawnWidths, widths,",
     [SUITE_WINDOW], "an event row's digest leaves out whether it is still ahead"),
    ("L3", LEAVES, "    r.setAttributeOnce(row, \"data-row-index\", $i)",
     "    discard", [SUITE_WINDOW],
     "an event row loses its position: no press reaches it"),
    ("L4", LEAVES,
     "                       selectedRow, changed, paneW, fitted.text,",
     "                       selectedRow, paneW, fitted.text,",
     [SUITE_WINDOW], "a value row's digest leaves out whether the step changed it"),
    ("M1", MAIN,
     "  drawEditorBody(r, editor, sticky, firstRowInsetPx = editorTopInsetPx())",
     "  drawEditorBody(r, editor, sticky)", [SUITE_WINDOW],
     "a row scrolled above the editor's top is no longer pulled up"),
    ("N1", POOLS, "  inc p.built", "  p.built += 1", [SUITE_UNIT],
     "behaviour-preserving: the DECLARED SURVIVOR"),
]
DECLARED_SURVIVORS = {"N1"}
IN_BINARY = {POOLS, LEAVES, CLICKS, MAIN}


def sha_path(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def sha(rel):
    return sha_path(REPO / rel)


def suite_flags(suite):
    shim_file = os.environ.get("GPUI_SHIM_FILE", "")
    return ["--path:src/frontend/viewmodel"] + \
        ([f"-d:gpuiShimPath={shim_file}"] if shim_file else [])


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
        f.write("# Control digests for run-plat85-keyed-redraw-mutations.py — the\n"
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
    """`just build-gpui`, or — with `GPUI_SHIM_FILE` set — the same compile
    with the binary pinned to that shim (`-d:gpuiShimPath`), for a tree whose
    sibling isonim-gpui holds a stale shim of its own."""
    shim_file = os.environ.get("GPUI_SHIM_FILE", "")
    if shim_file:
        cmd = ["nim", "c", "--hints:off", "--warnings:off", "--mm:orc",
               "-d:release", "--path:src/frontend/viewmodel",
               f"-d:gpuiShimPath={shim_file}",
               "--nimcache:build/nimcache/codetracer-gpui",
               "-o:build/bin/codetracer-gpui", "src/frontend/gpui/main.nim"]
    else:
        cmd = ["just", "build-gpui"]
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                       timeout=TIMEOUT)
    return p.returncode == 0


def run_suite(suite):
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}", f"-o:{NIMCACHE}/{stem}.out"] + \
        suite_flags(suite) + [suite]
    env = dict(os.environ, LD_LIBRARY_PATH=str(SHIM) + ":" +
               os.environ.get("LD_LIBRARY_PATH", ""),
               CODETRACER_REPO_ROOT=str(REPO), ISONIM_GPUI_SHIM_DIR=str(SHIM))
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
        backup = path.with_suffix(path.suffix + ".plat85bak")
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
