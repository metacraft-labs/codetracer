"""PLAT-71 — the engine the four `run-plat71*-mutations.py` harnesses share
(CodeTracer-TUI-Terminal-Adaptation.md §13.5).

One harness per part of the milestone (A the glyph table and the width
function, B the profile and the round, C the report, D multiplexers and the
link); each declares its SUBJECTS, SUITES and ARMS and hands them here. The
discipline is PLAT-70 Part H's harness's (`run-plat70h-scrollbar-mutations.py`)
clause for clause: committed control digests over subjects AND suites, a needle
scan that gates re-recording, a `because` derived from a run and then required,
rc 124 is a hang, per-arm restore verification, the shipped binary rebuilt when
a mutated subject is compiled into it and a pty suite grades the arm, and
`ci/lib/harness_guard.py`'s argument rule before anything is touched.

Each arm plants ONE defect and must be killed by the check the spec names
(TA-2 … TA-14), which `because` records.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
BIN = REPO / "build/bin/codetracer-tui"
TIMEOUT = 3600

sys.path.insert(0, str(REPO / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def path_of(rel):
    return REPO / rel


def sha_path(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def sha(rel):
    return sha_path(path_of(rel))


def lane_flags(lane):
    return subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
                       f"test_lane_extra_flags {lane}"],
        cwd=REPO, capture_output=True, text=True, check=True).stdout.split()


def suite_flags(suite):
    if "/real_terminal/" in suite:
        return lane_flags("tui-real-terminal")
    if suite.startswith("src/frontend/tui/"):
        return lane_flags("tui")
    return ["--path:src/frontend/viewmodel"]


def portable_cause(line):
    head, sep, rest = line.partition("; status:")
    if not sep:
        return line
    tail = re.search(r" \[\w+\]$", rest)
    return head + (tail.group(0) if tail else "")


class Harness:
    def __init__(self, name, here, subjects, suites, arms, in_binary,
                 declared_survivors=()):
        self.name = name
        self.control = Path(here) / f"{name}-mutation-control.sha256"
        self.because_path = Path(here) / f"{name}-mutation-because.json"
        self.nimcache = Path(os.environ.get(
            "CT_NIM_CACHE_ROOT", os.environ.get("TMPDIR", "/tmp"))) / \
            f"{name}-mutations"
        self.subjects = subjects
        self.suites = suites
        self.arms = arms
        self.in_binary = set(in_binary)
        self.survivors = set(declared_survivors)

    # --- the gates -----------------------------------------------------------
    def needle_scan(self):
        ok = True
        for arm_id, edits, *_ in self.arms:
            for rel, find, _ in edits:
                text = path_of(rel).read_text()
                n = text.count(find)
                if n != 1:
                    print(f"  NEEDLE FAIL {arm_id}: {n} occurrence(s) in {rel}")
                    ok = False
                    continue
                end = text.index(find) + len(find)
                if end < len(text) and text[end] not in "\r\n":
                    print(f"  NEEDLE FAIL {arm_id}: does not end at a line end")
                    ok = False
        print(f"needle scan: {len(self.arms)} arm(s), "
              f"{'every find occurs exactly once' if ok else 'FAILED'}")
        return ok

    def record_controls(self):
        if not self.needle_scan():
            print("REFUSED: re-recording now would certify an unaimed arm.")
            return 1
        with open(self.control, "w") as f:
            f.write(f"# Control digests for run-{self.name}-mutations.py — the\n"
                    "# subjects AND the suites the arms are graded by.\n"
                    "# Refreshed with --record-control-hashes, gated by the\n"
                    "# needle scan.\n")
            for rel in self.subjects + self.suites:
                f.write(f"{sha(rel)}  {rel}\n")
        print(f"recorded {len(self.subjects) + len(self.suites)} control "
              "digests")
        return 0

    def controls_match(self):
        if not self.control.exists():
            print("NO CONTROL DIGESTS — run --record-control-hashes first.")
            return False
        ok = True
        for line in self.control.read_text().splitlines():
            if not line or line.startswith("#"):
                continue
            digest, rel = line.split("  ", 1)
            if sha(rel) != digest:
                print(f"CONTROL DIGEST MOVED: {rel}")
                ok = False
        return ok

    # --- building and grading ------------------------------------------------
    def build_binary(self):
        cmd = os.environ.get("PLAT71_BUILD_TUI")
        argv = ["bash", "-c", cmd] if cmd else ["just", "build-tui"]
        p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                           timeout=TIMEOUT)
        if p.returncode != 0:
            print((p.stdout + p.stderr)[-2000:])
        return p.returncode == 0

    def run_suite(self, suite, test_filter):
        self.nimcache.mkdir(parents=True, exist_ok=True)
        stem = Path(suite).stem
        env = dict(os.environ, CODETRACER_REPO_ROOT=str(REPO))
        cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
               f"--nimcache:{self.nimcache}/{stem}",
               f"-o:{self.nimcache}/{stem}.out"] + suite_flags(suite) + [suite]
        if test_filter:
            cmd.append(test_filter)
        try:
            p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                               timeout=TIMEOUT, env=env)
        except subprocess.TimeoutExpired:
            return "HUNG", []
        out = (p.stdout or "") + (p.stderr or "")
        if p.returncode == 124:
            return "HUNG", []
        failures = [portable_cause(ln.strip().split("Check failed: ", 1)[1])
                    for ln in out.splitlines() if "Check failed: " in ln]
        if p.returncode == 0:
            ran = out.count("[OK]")
            return ("GREEN", failures) if ran > 0 else ("RAN-NOTHING", [])
        if not failures and "Error:" in out and "[FAILED]" not in out:
            return "DID-NOT-COMPILE", failures
        if not failures:
            failures = [portable_cause(ln.strip()) for ln in out.splitlines()
                        if "[FAILED]" in ln or "Unhandled exception" in ln][:1]
        return "RED", failures

    def grade(self, suites):
        first, verdict = "", "GREEN"
        for s, flt in suites:
            v, f = self.run_suite(s, flt)
            if v in ("HUNG", "DID-NOT-COMPILE", "RAN-NOTHING"):
                return v, ""
            if v == "RED":
                verdict = "RED"
                if not first and f:
                    first = f[0]
        return verdict, first

    # --- the run -------------------------------------------------------------
    def main(self, argv, module_globals):
        refused = refuse_undeclared_arms(argv, module_globals)
        if refused:
            return refused
        ap = argparse.ArgumentParser()
        ap.add_argument("--only", default="")
        ap.add_argument("--needle-scan", action="store_true")
        ap.add_argument("--derive", action="store_true")
        ap.add_argument("--record-control-hashes", action="store_true")
        a = ap.parse_args(argv)
        os.chdir(REPO)
        if a.needle_scan:
            return 0 if self.needle_scan() else 1
        if a.record_control_hashes:
            return self.record_controls()
        if not self.needle_scan() or not self.controls_match():
            print("the tree is not at the control bytes; nothing was mutated.")
            return 3
        only = set(filter(None, a.only.split(",")))
        selected = [arm for arm in self.arms if not only or arm[0] in only]
        pty = lambda s: "/real_terminal/" in s  # noqa: E731
        needs_binary = any(pty(s) for arm in selected for s, _ in arm[2])
        binary_digest = None
        if needs_binary:
            if not self.build_binary():
                print("ABORT: the unmutated binary does not build.")
                return 1
            binary_digest = sha_path(BIN)
        graded = sorted({(s, flt or "") for arm in selected
                         for s, flt in arm[2]})
        for s, flt in graded:
            v, f = self.run_suite(s, flt or None)
            if v != "GREEN":
                print(f"ABORT: the baseline of {s} [{flt}] is {v}: {f[:1]}")
                return 1
        print(f"baseline GREEN ({len(graded)} suite run(s))")
        because = json.loads(self.because_path.read_text()) \
            if self.because_path.exists() else {}
        digests = {rel: sha(rel) for rel in self.subjects}
        derived, bad = {}, []
        for arm_id, edits, suites, what in selected:
            files = sorted({rel for rel, _, _ in edits})
            backups = {}
            for rel in files:
                path = path_of(rel)
                backups[rel] = path.with_name(path.name + ".plat71bak")
                shutil.copy2(path, backups[rel])
            try:
                for rel, find, replace in edits:
                    path = path_of(rel)
                    path.write_text(path.read_text().replace(find, replace, 1))
                built = True
                if any(pty(s) for s, _ in suites) and \
                        any(r in self.in_binary for r in files):
                    built = self.build_binary()
                verdict, first = self.grade(suites) if built \
                    else ("DID-NOT-COMPILE", "")
            finally:
                for rel in files:
                    shutil.move(backups[rel], path_of(rel))
                    if sha(rel) != digests[rel]:
                        print(f"ABORT: restore of {rel} failed after {arm_id}.")
                        return 1
            derived[arm_id] = first
            if arm_id in self.survivors:
                ok = verdict == "GREEN"
                mark = "SURVIVED (declared)" if ok \
                    else f"MISDIRECTED ({verdict})"
            elif verdict == "RED":
                want = because.get(arm_id)
                ok = a.derive or want is None or want == first
                mark = "KILLED" if ok \
                    else f"KILLED BY THE WRONG CHECK: {first!r}"
            else:
                ok = False
                mark = verdict if verdict != "GREEN" \
                    else "SURVIVED — NOT ENFORCED"
            print(f"  {arm_id:<4} {mark:<30} {what}", flush=True)
            if a.derive or not ok:
                print(f"       because: {first!r}")
            if not ok:
                bad.append(arm_id)
        if a.derive:
            merged = dict(because)
            merged.update({k: v for k, v in derived.items()
                           if k not in self.survivors})
            self.because_path.write_text(
                json.dumps(merged, indent=2, sort_keys=True) + "\n")
            print(f"derived {len(derived)} because line(s)")
        if binary_digest is not None:
            if not self.build_binary() or sha_path(BIN) != binary_digest:
                print("FAIL: the binary rebuilt from the restored tree "
                      "differs from the one the run started with.")
                return 1
        for rel in self.subjects:
            if sha(rel) != digests[rel]:
                print(f"FAIL: {rel} does not match its digest at exit.")
                return 1
        print(f"RESULT: {len(bad)} arm(s) not as required: "
              f"{', '.join(bad) or '-'}")
        return 0 if not bad else 1
