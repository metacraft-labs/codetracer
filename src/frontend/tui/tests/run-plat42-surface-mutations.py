#!/usr/bin/env python3
"""PLAT-42 — the mutation harness for the four editor surfaces.

Each arm plants ONE defect in how a surface is DERIVED or DRAWN and requires
the PLAT-42 suites to go RED with the failure the first run recorded
(`plat42-surface-mutation-because.json`, `--derive`). The gate's own words set
the arms: *"a surface that draws on every row must fail"* — each surface has a
draw-everywhere arm — plus the two law killers (LAW-E1: a degraded surface
rendered as absent; LAW-E2: the inline value drawn as an overlay that does not
reflow), the two media's flow painting, the terminal host's inline-value
wiring, the event delivery the flow window rides on, the execution band and
one-line rows the window reading depends on, and the shipped terminal's
per-line status (`:break` through the engine, and the `:` path that must not
pump after it).

The discipline is PLAT-43's harness's: committed control digests over subjects
AND suites (§16c); the needle scan gates re-recording (§39a); `because` derived
from a run; rc 124 is a hang (§1); per-arm restore verification; one declared
behaviour-preserving survivor.

The suites graded here run in-process against real recordings (`calc`,
`noir_space_ship`) and a real `replay-server`; the committed-record suites
(`test_plat42_surfaces`, `test_plat42_window`, `test_plat42_frame_budget`)
read measurements of the shipped binary and cannot see a source mutation, so
they are not graders — they are re-measured by their lanes.

Usage:
    run-plat42-surface-mutations.py [--only P1,F2] [--derive]
    run-plat42-surface-mutations.py --needle-scan
    run-plat42-surface-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat42-surface-mutation-control.sha256"
BECAUSE = HERE / "plat42-surface-mutation-because.json"
NIMCACHE = Path(os.environ.get("TMPDIR", "/tmp")) / "plat42-mutations"
SHIM = REPO.parent / "isonim-gpui/rust/target/debug"
TIMEOUT = 3600

SURFACE = "src/frontend/view_vocabulary/editor_surface.nim"
LEAVES = "src/frontend/gpui/app/leaves.nim"
PANE = "src/frontend/tui/app/views/source_pane.nim"
HOST = "src/frontend/tui/host/tui_session.nim"
STDIO = "src/frontend/viewmodel/backend/stdio_backend.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
RULE = "src/common/flow_line_rule.nim"
FLOWVM = "src/frontend/viewmodel/viewmodels/flow_vm.nim"

LAWS = "src/frontend/tui/tests/test_plat42_laws.nim"
FLOW_TERM = "src/frontend/tui/tests/test_plat42_flow_overlay_terminal.nim"
VALUES_TERM = "src/frontend/tui/tests/test_plat42_inline_values_terminal.nim"
FACTS = "src/frontend/viewmodel/tests/unit/test_flow_line_facts.nim"
EDITING = "src/frontend/gpui/tests/test_gpui_editing_surface.nim"
LINE_TERM = "src/frontend/tui/tests/test_plat42_line_status_terminal.nim"

SUBJECTS = [SURFACE, LEAVES, PANE, HOST, STDIO, RULE, FLOWVM, RUNTIME]
SUITES = [LAWS, FLOW_TERM, VALUES_TERM, FACTS, EDITING, LINE_TERM]

ARMS = [
    # --- a surface drawn on EVERY row -------------------------------------
    ("P1", SURFACE, "    if row.held and row.pointer == eptExecution:",
     "    if row.held:", [EDITING],
     "inline values drawn on every held row, not only the execution line"),
    ("B1", LEAVES,
     "  if row.pointer == eptExecution:\n    r.setStyle(el, \"background\", ExecutionRowBand)",
     "  if true:\n    r.setStyle(el, \"background\", ExecutionRowBand)",
     [LAWS], "the execution band drawn on every row"),
    ("F1", RULE, "      return true\n", "      return true\n  return true\n",
     [FACTS], "every line of the function dimmed as a declined arm"),
    # --- LAW-E1's killer: degraded rendered as absent ----------------------
    ("E1", SURFACE,
     "    result.support[ecLineStatus] = esDegraded\n"
     "  if contract.mutable and not mutableHere:",
     "    result.support[ecLineStatus] = esAbsent\n"
     "  if contract.mutable and not mutableHere:",
     [LAWS], "a producerless gutter reported as absent instead of degraded"),
    # --- LAW-E2's killer: the inline value as an overlay -------------------
    ("E2", PANE,
     "          g.paint(row, codeCol + shown + AnnotationGap, span.text, span.style)",
     "          g.paint(row, codeCol, span.text, span.style)",
     [LAWS], "the terminal paints the value at a fixed column over the code"),
    ("E3", LEAVES, "    r.appendChild(el, ann)",
     "    r.setStyle(ann, \"position\", \"absolute\")\n    r.appendChild(el, ann)",
     [LAWS], "GPUI draws the value absolutely positioned: no reflow"),
    ("W1", LEAVES, '  r.setStyle(el, "white-space", "nowrap")', "  discard",
     [LAWS], "GPUI rows soft-wrap again: one line takes the rows below it"),
    # --- per-line status on the shipped terminal ---------------------------
    ("L1", HOST, "    points = s.points,\n", "", [LINE_TERM],
     "the host passes no breakpoints to the pane again"),
    ("L2", HOST, "  for l in lines:\n", "  for l in [line]:\n", [LINE_TERM],
     "a toggle sends only its own line: setBreakpoints clears the others"),
    ("L3", RUNTIME,
     "    outcome.awaitsMove = movesTheDebugger(outcome.action)",
     "    outcome.awaitsMove = true", [LINE_TERM],
     "the `:` path pumps for a move after :break"),
    # --- the flow overlay's two paintings ----------------------------------
    ("F2", LEAVES, "    r.setStyle(code, \"opacity\", FlowNotTakenOpacity)",
     "    discard", [LAWS], "GPUI does not dim a not-taken line"),
    ("F3", PANE, "      if line in model.notTakenLines and shown > 0:",
     "      if false:", [FLOW_TERM], "the terminal does not dim a not-taken line"),
    ("F4", FLOWVM, "  vm.styledLines.val = flowLineFacts(view)",
     "  vm.styledLines.val = @[]", [FACTS, FLOW_TERM],
     "the flow window's per-line facts are discarded again (PLAT22-PG2)"),
    ("S1", STDIO, "    deliver()", "    discard", [FLOW_TERM],
     "the native transport stops delivering events: no flow window arrives"),
    # --- PG3: the terminal host's inline values ----------------------------
    ("V1", HOST,
     "    inlineValues = inlineValuesOf(s.state, tuiRowBudget(max(1, rt.width), false)))",
     "    inlineValues = @[])", [VALUES_TERM],
     "the shipped terminal draws no inline value again"),
    # --- the declared survivor ---------------------------------------------
    ("N1", RULE, "      return true\n", "      return (true)\n", [FACTS],
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
        if len(ids) > 1 and not set(ids) <= ({"F1", "N1"}):
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
        f.write("# Control digests for run-plat42-surface-mutations.py — the\n"
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
        backup = path.with_suffix(path.suffix + ".plat42bak")
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
