#!/usr/bin/env python3
"""PLAT-68 Phase A — the mutation harness for the base keymaps.

Each arm plants ONE defect in a decoder, the resolver, the selector, the
`when` evaluator, the CUA data, the CUA specification, or the terminal
restore; REBUILDS the shipped `codetracer-tui` when the defect is compiled
into it and an arm is graded through it; runs the suites that must catch it;
and requires RED — with the failure the first run recorded
(`plat68-keymaps-mutation-because.json`, derived with `--derive`).

The discipline is PLAT-43's and PLAT-44's harnesses', clause for clause:
committed control digests over subjects AND suites (§16c), a needle scan that
gates re-recording (§39a), `because` derived from a run, rc 124 is a hang
(§1), per-arm restore verification, one declared behaviour-preserving
survivor, and `ci/lib/harness_guard.py`'s argument rule before anything is
touched.

THREE THINGS PARTICULAR TO THIS MILESTONE:

  * **SUBJECTS OUTSIDE THIS REPOSITORY.** The CUA specification lives in the
    specification checkout (`$CT_SPECS_DIR`, else `../codetracer-specs`), and
    the restore the terminal relies on lives in `nim-termctl`
    (`$NIM_TERMCTL_SRC`, else `../nim-termctl/src`). Both are named by a
    prefix (`specs:`, `nim-termctl:`) in the control file, mutated and
    restored like any other subject.
  * **AN ARM MAY EDIT TWO FILES.** O2 changes a CUA chord in the data AND in
    CUA-Keymap.md, so the oracle — which compares the two — stays GREEN and
    only the VS Code extractor can kill it. O2 REQUIRES the oracle green: an
    O2 killed by the oracle would be an arm aimed at the wrong gate.
  * **AN ARM MAY BE GRADED BY ONE TEST.** The milestone asks that a decoder
    dropping `Shift` from `Ctrl+Shift+K` die *on the document* (it then
    deletes nothing and inserts nothing). The pty suite checks the key
    synthesiser first, so D1 is graded by the sequence test alone, through
    Nim's unittest filter — the `because` it records is the document's.

Usage:
    run-plat68-keymaps-mutations.py [--only D1,O2] [--derive]
    run-plat68-keymaps-mutations.py --needle-scan
    run-plat68-keymaps-mutations.py --record-control-hashes
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[5]
HERE = Path(__file__).resolve().parent
CONTROL = HERE / "plat68-keymaps-mutation-control.sha256"
BECAUSE = HERE / "plat68-keymaps-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat68-mutations"
BIN = REPO / "build/bin/codetracer-tui"
TIMEOUT = 3600

ROOTS = {
    "": REPO,
    "specs:": Path(os.environ.get("CT_SPECS_DIR") or
                   REPO.parent / "codetracer-specs"),
    "nim-termctl:": Path(os.environ.get("NIM_TERMCTL_SRC") or
                         REPO.parent / "nim-termctl/src"),
}

NAMES = "src/common/key_names.nim"
KEYMAP = "src/frontend/viewmodel/keymap/editing_keymap.nim"
SELECTION = "src/frontend/viewmodel/keymap/keymap_selection.nim"
WHEN = "src/frontend/viewmodel/keymap/when_expr.nim"
CUA = "src/frontend/viewmodel/keymap/cua_keymap.nim"
CUA_SPEC = "specs:spec/GUI/CUA-Keymap.md"
RESTORE = "nim-termctl:nim_termctl/posix_backend.nim"

DECODING = "src/frontend/viewmodel/tests/unit/test_plat68_key_decoding.nim"
BASES = "src/frontend/viewmodel/tests/unit/test_plat68_base_keymaps.nim"
ORACLE = "src/frontend/viewmodel/tests/unit/test_plat68_cua_oracle.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat68_keymaps_pty.nim"
EXTRACTOR = "ci/test/cua-keymap-extractor.sh"

SUBJECTS = [NAMES, KEYMAP, SELECTION, WHEN, CUA, CUA_SPEC, RESTORE]
SUITES = [DECODING, BASES, ORACLE, PTY, EXTRACTOR, "tools/cua-keymap-extractor.py"]

SEQUENCE = "*::the milestone's sequence, Ctrl+S, and the file on disk"
RESTORED = "*::the pop or the reset is written on SIGTERM, SIGHUP and a crash"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
# A suite listed with `GREEN` as its filter must stay green (O2's oracle).
ARMS = [
    ("D1", [(NAMES, "  if (bits and 1) != 0: result.incl kmodShift", "  discard")],
     [(PTY, SEQUENCE)],
     "the decoder drops Shift: Ctrl+Shift+K deletes nothing, inserts nothing"),
    ("D2", [(NAMES, "              of 1, 7: \"Home\"", "              of 7: \"Home\"")],
     [(DECODING, None)],
     "Home's `CSI 1 ~` spelling decodes as \"\" again"),
    ("D3", [(NAMES, "    if c == eraseByte: decoded({}, \"Backspace\")",
             "    if c == '\\x7f': decoded({}, \"Backspace\")")],
     [(DECODING, None)],
     "VERASE is ignored: a ^H terminal's Backspace reads as Ctrl+Backspace"),
    ("R1", [(RESTORE, "    writeAllSafe(STDOUT_FILENO, kittyPopSeqLocal)",
             "    discard")],
     [(PTY, RESTORED)],
     "the terminal's restore omits the Kitty pop"),
    ("T1", [(KEYMAP, "  of bkCua, bkEmacs: NoPendingTimeout",
             "  of bkCua: EditingPendingTimeoutMs\n  of bkEmacs: NoPendingTimeout")],
     [(BASES, None)],
     "CUA given Vim's 1000 ms timeout"),
    ("M1", [(SELECTION, "  if name == RetiredDefaultName:", "  if false:")],
     [(BASES, None)],
     "the stored `default` is not migrated"),
    ("W1", [(WHEN, "  of wkNot: not evalWhen(e.operand, c)",
             "  of wkNot: evalWhen(e.operand, c)")],
     [(BASES, None)],
     "a `when` negation is ignored"),
    ("O1", [(CUA, "    BaseRow(chords: \"Ctrl+Shift+K\", operation: \"editor.delete-line\", whenText: Writable),",
             "    BaseRow(chords: \"Ctrl+Shift+J\", operation: \"editor.delete-line\", whenText: Writable),")],
     [(ORACLE, None)],
     "a CUA chord edited in the data and not in CUA-Keymap.md"),
    ("O2", [(CUA, "    BaseRow(chords: \"Ctrl+Shift+K\", operation: \"editor.delete-line\", whenText: Writable),",
             "    BaseRow(chords: \"Ctrl+Shift+J\", operation: \"editor.delete-line\", whenText: Writable),"),
            (CUA_SPEC, "| `Ctrl+Shift+K` | E | `editor.delete-line` |",
             "| `Ctrl+Shift+J` | E | `editor.delete-line` |"),
            (CUA_SPEC, "| `editor.delete-line` | `Ctrl+Shift+K` |",
             "| `editor.delete-line` | `Ctrl+Shift+J` |")],
     [(ORACLE, "GREEN"), (EXTRACTOR, None)],
     "a CUA chord edited in the data AND in CUA-Keymap.md: VS Code disagrees"),
    ("N1", [(WHEN, "  of wkNot: not evalWhen(e.operand, c)",
             "  of wkNot: not(evalWhen(e.operand, c))")],
     [(BASES, None)],
     "behaviour-preserving: the DECLARED SURVIVOR"),
]
DECLARED_SURVIVORS = {"N1"}
IN_BINARY = {NAMES, KEYMAP, SELECTION, WHEN, CUA, RESTORE}


def path_of(rel):
    for prefix in sorted(ROOTS, key=len, reverse=True):
        if prefix and rel.startswith(prefix):
            return ROOTS[prefix] / rel[len(prefix):]
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
    if suite == PTY:
        return lane_flags("tui-real-terminal")
    return ["--path:src/frontend/viewmodel"]


def needle_scan():
    ok = True
    for arm_id, edits, *_ in ARMS:
        for rel, find, _ in edits:
            text = path_of(rel).read_text()
            n = text.count(find)
            if n != 1:
                print(f"  NEEDLE FAIL {arm_id}: {n} occurrence(s) in {rel}")
                ok = False
                continue
            end = text.index(find) + len(find)
            if end < len(text) and text[end] not in "\r\n" and \
                    not rel.endswith(".md"):
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
        f.write("# Control digests for run-plat68-keymaps-mutations.py — the\n"
                "# subjects AND the suites the arms are graded by (§16c).\n"
                "# `specs:` is $CT_SPECS_DIR, `nim-termctl:` is\n"
                "# $NIM_TERMCTL_SRC. Refreshed with --record-control-hashes,\n"
                "# gated by the needle scan (§39a).\n")
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
    p = subprocess.run(["just", "build-tui"], cwd=REPO, capture_output=True,
                       text=True, timeout=TIMEOUT)
    if p.returncode != 0:
        print((p.stdout + p.stderr)[-2000:])
    return p.returncode == 0


def run_suite(suite, test_filter):
    if suite == EXTRACTOR:
        try:
            p = subprocess.run(["bash", EXTRACTOR], cwd=REPO,
                               capture_output=True, text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return "HUNG", []
        out = (p.stdout or "") + (p.stderr or "")
        failures = [ln.strip() for ln in out.splitlines()
                    if ln.startswith(("NOT REPRODUCED:", "NOT IN"))]
        if p.returncode == 0:
            return "GREEN", failures
        return ("RED", failures) if failures else ("DID-NOT-RUN", [])
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}", f"-o:{NIMCACHE}/{stem}.out"] + \
        suite_flags(suite) + [suite]
    if test_filter and test_filter != "GREEN":
        cmd.append(test_filter)
    env = dict(os.environ, CODETRACER_REPO_ROOT=str(REPO))
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
        ran = out.count("[OK]")
        return ("GREEN", failures) if ran > 0 else ("RAN-NOTHING", [])
    # A base that does not hold together does not LOAD (`base_rows
    # .definitionOf` raises at module init): the suite dies before its first
    # case, on the loader's own diagnostic. That is a kill — by the product's
    # check rather than the suite's — and is graded as one, on that line.
    refused = [ln.strip() for ln in out.splitlines()
               if "BaseRowError" in ln and "unhandled exception" in ln.lower()]
    if refused:
        return "RED", refused[:1]
    if not failures and "Error:" in out and "[FAILED]" not in out:
        return "DID-NOT-COMPILE", failures
    if not failures:
        failures = [ln.strip() for ln in out.splitlines()
                    if "[FAILED]" in ln or "Unhandled exception" in ln][:1]
    return "RED", failures


def grade(suites):
    """RED if a graded suite is red (and every `GREEN` suite is green); the
    first failure line across them."""
    first, verdict = "", "GREEN"
    for s, flt in suites:
        v, f = run_suite(s, flt)
        if v in ("HUNG", "DID-NOT-COMPILE", "DID-NOT-RUN", "RAN-NOTHING"):
            return v, ""
        if flt == "GREEN":
            if v != "GREEN":
                return "MISAIMED", f"{Path(s).name} went red: " + \
                    (f[0] if f else "")
            continue
        if v == "RED":
            verdict = "RED"
            if not first and f:
                first = f[0]
    return verdict, first


sys.path.insert(0, str(REPO / "ci" / "lib"))
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
    only = set(filter(None, a.only.split(",")))
    selected = [arm for arm in ARMS if not only or arm[0] in only]
    needs_binary = any(s == PTY for arm in selected for s, _ in arm[2])
    binary_digest = None
    if needs_binary:
        if not build_binary():
            print("ABORT: the unmutated binary does not build.")
            return 1
        binary_digest = sha_path(BIN)
    graded = sorted({s for arm in selected for s, _ in arm[2]})
    for s in graded:
        v, f = run_suite(s, None)
        if v != "GREEN":
            print(f"ABORT: the baseline of {s} is {v}: {f[:1]}")
            return 1
    print(f"baseline GREEN ({len(graded)} suite(s))")
    because = json.loads(BECAUSE.read_text()) if BECAUSE.exists() else {}
    digests = {rel: sha(rel) for rel in SUBJECTS}
    derived, bad = {}, []
    for arm_id, edits, suites, what in selected:
        files = sorted({rel for rel, _, _ in edits})
        backups = {}
        for rel in files:
            path = path_of(rel)
            backups[rel] = path.with_name(path.name + ".plat68bak")
            shutil.copy2(path, backups[rel])
        try:
            for rel, find, replace in edits:
                path = path_of(rel)
                path.write_text(path.read_text().replace(find, replace, 1))
            through_pty = any(s == PTY for s, _ in suites)
            if through_pty and any(r in IN_BINARY for r in files) and \
                    not build_binary():
                verdict, first = "DID-NOT-COMPILE", ""
            else:
                verdict, first = grade(suites)
        finally:
            for rel in files:
                shutil.move(backups[rel], path_of(rel))
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
            if verdict == "MISAIMED":
                mark += f" ({first})"
        print(f"  {arm_id:<4} {mark:<30} {what}")
        if a.derive or not ok:
            print(f"       because: {first!r}")
        if not ok:
            bad.append(arm_id)
    if a.derive:
        merged = dict(because)
        merged.update({k: v for k, v in derived.items()
                       if k not in DECLARED_SURVIVORS})
        BECAUSE.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        print(f"derived {len(derived)} because line(s)")
    if binary_digest is not None:
        if not build_binary() or sha_path(BIN) != binary_digest:
            print("FAIL: the binary rebuilt from the restored tree differs "
                  "from the one the run started with.")
            return 1
    for rel in SUBJECTS:
        if sha(rel) != digests[rel]:
            print(f"FAIL: {rel} does not match its digest at exit.")
            return 1
    print(f"RESULT: {len(bad)} arm(s) not as required: {', '.join(bad) or '-'}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
