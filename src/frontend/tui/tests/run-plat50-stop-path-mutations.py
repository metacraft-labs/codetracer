#!/usr/bin/env python3
"""The mutation harness for a stop whose recorded path has a `..` component
(the user, 2026-10-12, on `multi_root`: clicking `add` or `scale` in the call
trace did not show the call's file's source, under "No verified source for this
revision").

    python3 src/frontend/tui/tests/run-plat50-stop-path-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=SP1,PT1

Run from the repository root, inside the dev shell, with `REPLAY_SERVER_BIN`
exported (the real-PTY suite and the GPUI plan suite open the real `multi_root`
recording and move it) and `ISONIM_GPUI_SHIM_DIR` naming the shim the GPUI
binary loads. EN1-EN3 are graded by the engine's unit tests (`cargo test --lib
resolve_bundled_source`), built in `$CT_STOP_PATH_ENGINE_DIR` (default
`src/db-backend`; a sandbox whose `src` IS this checkout's, carrying the
trace-format siblings at the revisions `repro.lock` pins) into the target
directory `REPLAY_SERVER_BIN` was built in.

ONE ARM PER CLAIM, each naming the case that must die:

  | claim | arms |
  |---|---|
  | a `..` path reads the entry it names (the provider, TUI and GPUI share it) | SP1 (the path used as given), PT1 (the same, in the shipped terminal), GP1 (the same, in the shipped GPUI window) |
  | `..` folds into the component before it, and only that | SP2 (`a/../b` read as `a/b`), SP3 (an escaping `..` dropped rather than kept) |
  | the new file's window is not clamped to the previous file's length | VM1 (the length kept), PT2 (the same, in the terminal). GPUI's host serves the window until it is complete, so the defect never showed there and no GPUI arm claims it; the GPUI case still asserts extra.py's last line |
  | the engine answers the same path the same way | EN1 (the path used as given), EN2 (`a/../b` read as `a/b`), EN3 (an escaping `..` dropped) |
  | a file the recording lacks is named, not drawn as loading | AB1 (GPUI says "No verified source" again), AB2 (the terminal says it again), AB3 (the terminal draws `⋯ loading` rows again), AB4 (GPUI draws rows again), AB5 (the terminal cuts the message instead of wrapping it) |

THREE VERDICTS: `killed` (the named case reported [FAILED] / `FAILED`),
`SURVIVED` (it passed), `HARNESS-FAILURE` (the needle was not unique, the suite
did not compile, the mutated binary did not build, or the run printed no result
lines). A run that prints nothing is never a kill.

Every suite is run FILTERED to its killer case; the control run is unfiltered
and must name every killer as passing.

THE BINARY IS PART OF THE SUBJECT: an arm graded by the real-PTY suite rebuilds
`build/bin/codetracer-tui` with the defect (`just build-tui`), one graded by the
GPUI plan suite rebuilds `build/bin/codetracer-gpui` (`just build-gpui`). The
restored tree's binaries are rebuilt before the harness exits.

RESTORATION is from an in-memory snapshot, and every touched file's SHA-256 is
compared with the pre-run baseline after each arm. The full run refuses unless
the needle scan is clean AND every touched file matches
`plat50-stop-path-mutation-control.sha256`.

NO DECLARED SURVIVORS.

No mocks: every suite graded here runs the product's own provider and
ViewModels over real files, the shipped terminal in a real PTY on the real
`multi_root` recording, the shipped GPUI binary's window plan, and the engine's
own resolver over real files.
"""

from __future__ import annotations

import hashlib
import os
import re
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]            # .../codetracer

# --- subjects ---------------------------------------------------------------
PROVIDER = "src/frontend/viewmodel/sdk/source_provider.nim"
SOURCEVM = "src/frontend/viewmodel/viewmodels/source_vm.nim"
EXPRLOADER = "src/db-backend/src/expr_loader.rs"
SURFACE = "src/frontend/view_vocabulary/editor_surface.nim"
BINDING = "src/frontend/tui/app/source_binding.nim"
PANE = "src/frontend/tui/app/views/source_pane.nim"
ENGINE_DIR = Path(os.environ.get("CT_STOP_PATH_ENGINE_DIR",
                                 str(ROOT / "src" / "db-backend")))

# --- suites -------------------------------------------------------------------
PROVT = "src/frontend/viewmodel/tests/unit/test_source_provider_revisions.nim"
WINT = "src/frontend/viewmodel/tests/unit/test_source_vm_window.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_stop_path_parent_component.nim"
GPLAN = "src/frontend/gpui/tests/test_stop_path_parent_component_gpui_plan.nim"
ENGT = EXPRLOADER + "#resolve_bundled_source"
ABSENT = "src/frontend/tui/tests/test_absent_source_pane.nim"

SUBJECTS = [PROVIDER, SOURCEVM, EXPRLOADER, SURFACE, BINDING, PANE]
SUITES = [PROVT, WINT, PTY, GPLAN, ENGT, ABSENT]


def suite_file(path: str) -> str:
    """The file a suite key names (a cargo filter's `#<filter>` dropped)."""
    return path.split("#", 1)[0]


TOUCHED = list(dict.fromkeys(SUBJECTS + [suite_file(p) for p in SUITES]))

# How each suite is run: (backend, lane whose `--path`s it needs / filter).
SUITE_KIND = {
    PROVT: ("c", "vm-unit"),
    WINT: ("c", "vm-unit"),
    PTY: ("c", "tui-real-terminal"),
    GPLAN: ("c", "gpui-shell"),
    ENGT: ("cargo-engine", "resolve_bundled_source"),
    ABSENT: ("c", "tui"),
}
BINARY_SUITES = {PTY}
GPUI_BINARY_SUITES = {GPLAN}

CONTROL_HASHES = HERE / "plat50-stop-path-mutation-control.sha256"
SUITE_TIMEOUT = int(os.environ.get("CT_STOP_PATH_SUITE_TIMEOUT", "3600"))
SHIM = Path(os.environ.get("ISONIM_GPUI_SHIM_DIR",
                           str(ROOT.parent / "isonim-gpui/rust/target/debug")))
RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*\s*(.*?)\s*$")
CARGO_LINE = re.compile(r"^test (\S+) \.\.\. (ok|FAILED)\s*$")

# --- the killer cases, spelled once ------------------------------------------
U_DOTDOT = "`a/../b` reads the payload entry stored as `b`"
U_FOLD = "resolveDotSegments keeps the root, the separator and an escaping `..`"
U_WINDOW = ("moving from a short file to a longer one asks for the longer "
            "file's whole window")
P_ADD = "clicking `add` in the call trace shows helpers.py's source"
P_SEQ = "add, then scale, then add again: each click shows its call's file"
G_ADD = "clicking `add` in the call trace shows helpers.py's source"
P_WIDE = "add, then scale, wide enough that neither file overflows the editor"
E_SAME = "resolve_bundled_source_resolves_a_parent_component_to_the_same_file"
P_MISSING = "a stop in a file the recording lacks says so, naming the path"
G_MISSING = P_MISSING
A_WRAP = "the message names the file, wrapped whole over a narrow pane"


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    suite: str
    killer: str
    why: str

    def edits(self):
        return [(self.path, self.find, self.replace)]


FOLD_NIM = """      if parts.len > 0 and parts[^1] != "..":
        parts.setLen(parts.len - 1)"""
KEEP_NIM = """      else:
        parts.add(current)
    elif current.len > 0:"""
NOWINDOW = """    if not vm.heldRevision.val.isEmpty:
      vm.heldRevision.val = SourceRevision()
      vm.totalLineCount.val = 0"""
FOLD_RS = """                if parts.last().is_some_and(|last| *last != "..") {
                    parts.pop();"""
KEEP_RS = """                } else {
                    parts.push("..");"""
GIVEN_RS = "    let resolved = resolve_dot_segments(&source_path.to_string_lossy());"

ARMS = [
    Arm("SP1", PROVIDER,
        "    let resolvedPath = resolveDotSegments(recordedPath)",
        "    let resolvedPath = recordedPath",
        PROVT, U_DOTDOT,
        "the provider looks a `..` path up as given: the stop's file is never "
        "found (the user's `⋯ loading` under the banner)"),
    Arm("SP2", PROVIDER, FOLD_NIM,
        FOLD_NIM.replace("parts.setLen(parts.len - 1)", "discard"),
        PROVT, U_FOLD,
        "a `..` is dropped instead of folded: `a/../b` becomes `a/b`, a "
        "different file"),
    Arm("SP3", PROVIDER, KEEP_NIM,
        KEEP_NIM.replace("parts.add(current)", "discard"),
        PROVT, U_FOLD,
        "an escaping `..` (nothing before it) is dropped, so `/../x` is "
        "reinterpreted as `/x` instead of refused"),
    Arm("VM1", SOURCEVM, NOWINDOW,
        NOWINDOW.replace("vm.totalLineCount.val = 0", "discard"),
        WINT, U_WINDOW,
        "the previous file's length clamps the next file's window, so its "
        "later lines are never asked for"),
    Arm("PT1", PROVIDER,
        "    let resolvedPath = resolveDotSegments(recordedPath)",
        "    let resolvedPath = recordedPath",
        PTY, P_ADD,
        "the shipped terminal, clicking `add` on multi_root, built with the "
        "provider looking the `..` path up as given"),
    # RE-AIMED 2026-10-16, PLAT-70 Part A: at the suite's 200 columns
    # extra.py overflows the editor and helpers.py does not, so between `add`
    # and `scale` the editor's horizontal bar comes, the source window is
    # re-sized and asked for again, and that hides a window that kept the
    # previous file's line count. The suite's wide case, where neither file
    # overflows, is where the claim is observed. (GPUI's plan never killed
    # this arm, on `agents` either.)
    Arm("PT2", SOURCEVM, NOWINDOW,
        NOWINDOW.replace("vm.totalLineCount.val = 0", "discard"),
        PTY, P_WIDE,
        "the shipped terminal, `add` then `scale`: extra.py's sixth line "
        "stays `⋯ loading`"),
    Arm("GP1", PROVIDER,
        "    let resolvedPath = resolveDotSegments(recordedPath)",
        "    let resolvedPath = recordedPath",
        GPLAN, G_ADD,
        "the shipped GPUI window, a press on `add`, built with the provider "
        "looking the `..` path up as given"),
    Arm("EN1", EXPRLOADER, GIVEN_RS,
        "    let resolved = source_path.to_string_lossy().to_string();",
        ENGT, E_SAME,
        "the engine looks a `..` path up as given, and DAP `source` answers "
        "nothing for the stop's file"),
    Arm("EN2", EXPRLOADER, FOLD_RS,
        FOLD_RS.replace("parts.pop();", "{}"),
        ENGT, E_SAME,
        "the engine drops a `..` instead of folding it: `a/../b` read as `a/b`"),
    Arm("EN3", EXPRLOADER, KEEP_RS,
        KEEP_RS.replace('parts.push("..");', "{}"),
        ENGT, E_SAME,
        "the engine drops an escaping `..`, reinterpreting `/../x` as `/x`"),
]

ARMS += [
    Arm("AB1", SURFACE, "      absentSourceMessageFor(result.path)",
        "      degradedMessageFor(editor.degradedState.val)",
        GPLAN, G_MISSING,
        "GPUI answers a missing file with the old banner, which names no file"),
    Arm("AB2", BINDING, "      if availability == savAbsent: absentSourceMessageFor(path)",
        "      if availability == savAbsent: degradedMessageFor(vm.degradedState.val)",
        PTY, P_MISSING,
        "the terminal answers a missing file with the old banner, naming none"),
    Arm("AB3", PANE,
        "    if model.provenance == gpAbsent and model.heldLines.len == 0: 0",
        "    if false: 0",
        ABSENT, A_WRAP,
        "the terminal draws an absent file's rows as `⋯ loading` that never "
        "arrive"),
    Arm("AB4", SURFACE,
        "  if reads.len == 0 or availability == savAbsent:",
        "  if reads.len == 0:",
        GPLAN, G_MISSING,
        "GPUI draws an absent file's rows, as if their text were coming"),
    Arm("AB5", PANE, "        rest = rest[piece.len .. ^1]",
        "        break",
        ABSENT, A_WRAP,
        "a narrow pane cuts the message after one row, losing the file's name"),
]

DECLARED_SURVIVORS: list = []


@dataclass
class RunResult:
    rc: int
    passed: list = None
    failed: list = None
    ran: bool = True
    hung: bool = False
    output: str = ""

    def __post_init__(self):
        if self.passed is None:
            self.passed = []
        if self.failed is None:
            self.failed = []

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def read_source(path: str) -> str:
    return (ROOT / path).read_bytes().decode("utf-8", errors="surrogateescape")


def write_source(path: str, text: str) -> None:
    (ROOT / path).write_bytes(text.encode("utf-8", errors="surrogateescape"))


def lane_flags(lane: str) -> list:
    """The lane's extra flags, read from `ci/lib/test-lane-files.sh` rather
    than spelled here."""
    return subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
         f"test_lane_extra_flags {lane}"],
        cwd=ROOT, capture_output=True, text=True).stdout.split()


def suite_env() -> dict:
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = str(SHIM) + ":" + env.get("LD_LIBRARY_PATH", "")
    env["CODETRACER_REPO_ROOT"] = str(ROOT)
    # Never the user's own remembered layout.
    state = Path(tempfile.gettempdir()) / f"stop-path-mutation-state-{os.getuid()}"
    state.mkdir(parents=True, exist_ok=True)
    env["CODETRACER_TUI_LAYOUT_DIR"] = str(state)
    env["XDG_STATE_HOME"] = str(state)
    return env


def artefacts_for(path: str) -> tuple:
    stem = Path(path).stem
    base = Path(tempfile.gettempdir()) / f"stop-path-mutation-{os.getuid()}"
    base.mkdir(parents=True, exist_ok=True)
    return str(base / stem), str(base / f"nc-{stem}")


def engine_target_dir() -> Path:
    """The cargo target directory `REPLAY_SERVER_BIN` was built into
    (`<target>/<profile>/replay-server`)."""
    return Path(os.environ["REPLAY_SERVER_BIN"]).resolve().parents[1]


def run_cargo_engine(path: str, filt: str, case: str | None) -> RunResult:
    env = suite_env()
    env["CARGO_TARGET_DIR"] = str(engine_target_dir())
    try:
        proc = subprocess.run(
            ["cargo", "test", "--lib", case or filt],
            cwd=ENGINE_DIR, capture_output=True, text=True,
            timeout=SUITE_TIMEOUT, encoding="utf-8", errors="replace", env=env)
    except subprocess.TimeoutExpired:
        return RunResult(rc=1, ran=False, hung=True)
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode, output=out)
    for line in out.splitlines():
        m = CARGO_LINE.match(line.strip())
        if m:
            name = m.group(1).rsplit("::", 1)[-1]
            (res.passed if m.group(2) == "ok" else res.failed).append(name)
    if res.total == 0:
        res.ran = False
        print(f"      ---- {path}: no cargo test lines; last 20 lines ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)
    return res


def run_one(path: str, case: str | None = None) -> RunResult:
    backend, lane = SUITE_KIND[path]
    if backend == "cargo-engine":
        return run_cargo_engine(path, lane, case)
    binary, nimcache = artefacts_for(path)
    flags = ["--hints:off", "--warnings:off", *lane_flags(lane),
             "--nimcache:" + nimcache]
    if lane == "gpui-shell" or lane == "vm-unit":
        flags.append("--path:src/frontend/viewmodel")
    try:
        proc = subprocess.run(
            ["nim", "c", "-r", *flags, "-o:" + binary, path,
             *([case] if case else [])],
            cwd=ROOT, capture_output=True, text=True, timeout=SUITE_TIMEOUT,
            encoding="utf-8", errors="replace", env=suite_env())
    except subprocess.TimeoutExpired:
        print(f"      ---- {path}: NO RESULT AFTER {SUITE_TIMEOUT}s ----")
        return RunResult(rc=1, ran=False, hung=True)
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode, output=out)
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        res.ran = False
        print(f"      ---- {path}: no result lines; last 20 lines ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)
    return res


def build(recipe: str) -> bool:
    p = subprocess.run(["just", recipe], cwd=ROOT, capture_output=True,
                       text=True, timeout=SUITE_TIMEOUT)
    if p.returncode != 0:
        print(f"      ---- just {recipe} failed; last 15 lines ----")
        for line in (p.stdout + p.stderr).splitlines()[-15:]:
            print("      " + line)
    return p.returncode == 0


def build_for(suite: str) -> bool:
    if suite in BINARY_SUITES:
        return build("build-tui")
    if suite in GPUI_BINARY_SUITES:
        return build("build-gpui")
    return True


_ACTIVE: list | None = None
_DIRTY: set = set()
  # binaries last built from a MUTATED tree ("build-tui", "build-gpui")


def rebuild_restored() -> bool:
    ok = True
    for recipe in sorted(_DIRTY):
        ok = build(recipe) and ok
    _DIRTY.clear()
    if not ok:
        print("the restored tree's binary does not build")
    return ok


def install_restore_on_signal() -> None:
    def handler(signum, _frame):
        if _ACTIVE is not None:
            for path, original in _ACTIVE:
                write_source(path, original)
                print(f"\nsignal {signum}: restored {path} before exiting")
        sys.exit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, handler)


COUNT_CONSTANT = re.compile(
    r"^[ \t]*(?:const[ \t]+)?(ExpectedAssertions)\*?[ \t]*=[ \t]*(\d+)", re.M)


def needle_scan() -> int:
    problems = 0
    counts = {}
    for path in TOUCHED:
        for m in COUNT_CONSTANT.finditer(read_source(path)):
            counts[m.group(2)] = f"{path}:{m.group(1)}"
    for arm in ARMS:
        text = arm.find + arm.replace
        if "ExpectedAssertions" in text or "CHECKS" in text:
            print(f"{arm.id}: NEEDLE QUOTES A COUNT NAME")
            problems += 1
        for digits in re.findall(r"\d\d+", text):
            if digits in counts:
                print(f"{arm.id}: NEEDLE QUOTES THE VALUE OF {counts[digits]}")
                problems += 1
    armed = {arm.path for arm in ARMS}
    unarmed = [p for p in SUBJECTS if p not in armed]
    if unarmed:
        print(f"SUBJECTS WITH NO ARM: {unarmed}")
        problems += 1
    whys = {}
    for arm in ARMS:
        key = arm.why[:60]
        if key in whys:
            print(f"{arm.id}: DUPLICATE justification, shared with {whys[key]}")
            problems += 1
        whys[key] = arm.id
    ids = [a.id for a in ARMS]
    if len(set(ids)) != len(ids):
        print("DUPLICATE ARM ID")
        problems += 1
    for arm in ARMS:
        n = read_source(arm.path).count(arm.find)
        status = "ok" if n == 1 else "LOST" if n == 0 else "AMBIGUOUS"
        if n != 1:
            problems += 1
        print(f"{arm.id:<4} {status:<10} {n} occurrence(s) in {arm.path}")
        source = read_source(suite_file(arm.suite))
        if SUITE_KIND[arm.suite][0] == "cargo-engine":
            present = f"fn {arm.killer}(" in source
        else:
            present = f'test "{arm.killer}"' in source
        if not present:
            print(f"{arm.id}: KILLER NAME NOT IN {arm.suite}: {arm.killer!r}")
            problems += 1
    for suite in SUITES:
        if not any(a.suite == suite for a in ARMS):
            print(f"SUITE NO ARM IS GRADED BY: {suite}")
            problems += 1
    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


def record_control_hashes() -> int:
    lines = [f"{digest(p)}  {p}" for p in TOUCHED]
    CONTROL_HASHES.write_text("\n".join(lines) + "\n")
    print(f"recorded {len(lines)} digests in {CONTROL_HASHES}")
    return 0


def check_control_hashes() -> bool:
    if not CONTROL_HASHES.exists():
        print(f"CONTROL DIGESTS ABSENT: {CONTROL_HASHES.name} — run "
              "--needle-scan, review the tree, then --record-control-hashes")
        return False
    recorded = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        if line.strip():
            h, p = line.split(None, 1)
            recorded[p.strip()] = h
    ok = True
    for p in TOUCHED:
        if p not in recorded:
            print(f"CONTROL DIGEST ABSENT: {p}")
            ok = False
        elif recorded[p] != digest(p):
            print(f"CONTROL DIGEST MOVED: {p} — re-run --needle-scan BEFORE "
                  "--record-control-hashes")
            ok = False
    return ok


sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def main() -> int:
    refused = refuse_undeclared_arms(sys.argv[1:], globals())
    if refused:
        return refused
    only = None
    for arg in sys.argv[1:]:
        if arg == "--needle-scan":
            return needle_scan()
        if arg == "--enumerate-touched":
            for p in TOUCHED:
                print(p)
            return 0
        if arg == "--record-control-hashes":
            return record_control_hashes()
        if arg.startswith("--only="):
            only = set(arg[len("--only="):].split(","))
        else:
            print(f"unknown argument: {arg}")
            return 2

    if needle_scan() != 0:
        print("REFUSING TO RUN: a needle is lost or ambiguous")
        return 1
    if not check_control_hashes():
        print("REFUSING TO RUN: a control digest moved or is absent")
        return 1
    if not os.environ.get("REPLAY_SERVER_BIN"):
        print("REFUSING TO RUN: REPLAY_SERVER_BIN is not exported")
        return 1

    baseline = {p: digest(p) for p in TOUCHED}
    install_restore_on_signal()

    wanted = [a for a in ARMS if not only or a.id in only]
    print("\n== control ==")
    if any(a.suite in BINARY_SUITES for a in wanted) and not build("build-tui"):
        print("CONTROL: the unmutated terminal binary does not build")
        return 1
    if any(a.suite in GPUI_BINARY_SUITES for a in wanted) and \
       not build("build-gpui"):
        print("CONTROL: the unmutated GPUI binary does not build")
        return 1
    for path in SUITES:
        killers = {a.killer for a in wanted if a.suite == path}
        if not killers:
            continue
        control = run_one(path)
        if control.failed or not control.ran or control.rc != 0:
            print(f"CONTROL IS NOT GREEN: {path} rc={control.rc} "
                  f"failed={control.failed}")
            return 1
        missing = [k for k in killers if k not in control.passed]
        if missing:
            print(f"CONTROL DID NOT RUN {missing} in {path}")
            return 1
        print(f"control {path}: {control.total} cases, 0 failures")

    problems = 0
    killed = 0
    global _ACTIVE
    for arm in wanted:
        original = read_source(arm.path)
        if original.count(arm.find) != 1:
            print(f"{arm.id:<4} HARNESS-FAILURE      needle is not unique")
            problems += 1
            continue
        _ACTIVE = [(arm.path, original)]
        write_source(arm.path, original.replace(arm.find, arm.replace))
        try:
            if not build_for(arm.suite):
                res = RunResult(rc=1, ran=False)
                print("      the mutated binary did not build")
            else:
                res = run_one(arm.suite, arm.killer)
        finally:
            write_source(arm.path, original)
            _ACTIVE = None
            if arm.suite in BINARY_SUITES:
                _DIRTY.add("build-tui")
            if arm.suite in GPUI_BINARY_SUITES:
                _DIRTY.add("build-gpui")
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{arm.id:<4} HARNESS-FAILURE      {p} did not "
                          "restore to its control bytes")
                    rebuild_restored()
                    return 2
        if res.hung:
            verdict, note = "HUNG", f"no result in {SUITE_TIMEOUT}s"
            problems += 1
        elif not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif arm.killer in res.failed:
            verdict, note = "killed", arm.killer
            killed += 1
        elif res.failed:
            verdict, note = "MISDIRECTED", f"died in {res.failed[0]!r}"
            problems += 1
        else:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        print(f"{arm.id:<4} {verdict:<16} {note}")
        sys.stdout.flush()

    if not rebuild_restored():
        problems += 1
    print(f"\n{killed}/{len(wanted)} killed, {problems} problem(s)")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
