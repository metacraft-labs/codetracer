#!/usr/bin/env python3
"""The mutation harness for the jobs the Embed SDK does for an embedding host.

    python3 src/frontend/viewmodel/tests/unit/run-hsf-sdk-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=J,R

Run from the repository root, inside the dev shell. Every suite is a pure
SessionViewModel / model suite over `MockBackendService`, so no replay-server,
browser or terminal is needed; each one is compiled and run on BOTH backends
(`nim c` and `nim js -d:nodejs`), because the web host runs the JS one.

WHY THIS HARNESS EXISTS
=======================
An embedding web host (BlockTracer) used to decode the engine's answers, mark
changed values and ask for the landing stop's locals in its own code, and it
proved its journeys could see each of those defects with its own mutation
arms. Since it draws its panes from the SDK's DebuggerSession, that code is
gone and the jobs are done here. The host's arms had nothing left to mutate,
so each claim moved to the code that now does the job. Every arm below names
the host arm it replaces.

ONE ARM PER CLAIM, each naming the case that must die:

  | arm | the defect | killer |
  |---|---|---|
  | J   | the `ct/load-locals` answer is thrown away | test_stop_loader: "one stop issues the locals once; …" |
  | R   | the stop the session lands on is never asked about | "a loader that starts following at a stop asks about that stop" |
  | F2  | the engine's flow window is refused, so no live values are drawn | test_stop_loader: "one stop asks for its flow window once, …" |
  | L   | an Int is decoded without its value | "an Int local is drawn with its value" |
  | F1  | a recorded string is drawn blank on its line | "a recorded string is drawn with its text" |
  | VD1 | "changed" is taken from the selection, not from the values | "the changed mark follows the value, not the selection" |
  | VD2 | every value present at the anchor is marked changed | "an unchanged value is not marked changed" |
  | VD3 | a name new in scope is recorded as modified, not added | "a name new in scope is recorded as added, not modified" |
  | FL2 | a move empties the values before its answer arrives | "a move keeps the values on screen until its answer arrives" |
  | G   | a call-trace row's click seeks one tick past the row | "a call-trace row's click jumps to that row's own tick" |
  | H   | an event-log row's click seeks nowhere | "an event-log row's click jumps to that event" |
  | CT1 | every call-trace row is given the same call key | "every call-trace row carries its own call key" |

VD3 GUARDS THE MODEL, NOT THE DRAWING. Every front-end draws an added binding
and a modified one alike, in the changed-value style
(`value_changes.isModified`), and that is the intended design. The model keeps
the distinction (`changeFor` answers `vchAdded`) so a caller that wants to draw
them differently can; the arm is what keeps it.

THREE VERDICTS, from the parsed `[OK]` / `[FAILED]` lines and never from an
exit code (`nim c -r` exits non-zero for a compile error too):

  * `killed`           — the NAMED case failed, on both backends;
  * `SURVIVED`         — it passed on a backend, or nothing failed at all;
  * `HARNESS-FAILURE`  — the needle was not unique, a suite printed no result
                         lines (it did not compile), or a subject did not
                         restore to its control bytes.

A mutation killed only by some other case is MISDIRECTED, and counts as a
problem: an arm proves the case written for it bites.

The rules the other comparator harnesses follow (Verification-Harness-Traps
§32, §32f, §32h, §39) apply unchanged:

  * `--needle-scan` refuses to run when a needle is absent or ambiguous, and the
    full run refuses unless the scan is clean;
  * every read and write is BYTES;
  * SIGTERM/SIGINT/SIGHUP restore the subject before exiting;
  * `hsf-sdk-mutation-control.sha256` records the digest of every subject and
    suite, a run refuses while one has moved, and
    `ci/test/mutation-control-drift.sh` reports an edit to any of them.
    Re-record only after `--needle-scan` is clean and the arms are re-graded.
"""

import argparse
import hashlib
import re
import signal
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]            # .../codetracer

# The subjects: the code each arm mutates.
STOPLOADER = "src/frontend/viewmodel/sdk/stop_loader.nim"
FLOWVM = "src/frontend/viewmodel/viewmodels/flow_vm.nim"
ADAPTER = "src/common/value_presentation/json_adapter.nim"
CHANGES = "src/frontend/viewmodel/viewmodels/value_changes.nim"
STATEVM = "src/frontend/viewmodel/viewmodels/state_vm.nim"
CALLTRACEVM = "src/frontend/viewmodel/viewmodels/calltrace_vm.nim"
EVENTLOGVM = "src/frontend/viewmodel/viewmodels/event_log_vm.nim"
STORE = "src/frontend/viewmodel/store/replay_data_store.nim"

# The suites that grade them.
T_LOADER = "src/frontend/viewmodel/tests/unit/test_stop_loader.nim"
T_JOBS = "src/frontend/viewmodel/tests/unit/test_hsf_sdk_jobs.nim"
SUITES = [T_LOADER, T_JOBS]
BACKENDS = ["c", "js"]

TOUCHED = [STOPLOADER, FLOWVM, ADAPTER, CHANGES, STATEVM, CALLTRACEVM,
           EVENTLOGVM, STORE, T_LOADER, T_JOBS]
CONTROL_HASHES = HERE / "hsf-sdk-mutation-control.sha256"

SUITE_TIMEOUT = 2400
OUT_DIR = Path("/tmp") / "hsf-sdk-mutations"
NIM_FLAGS = ["--hints:off", "--warnings:off", "--path:src/frontend/viewmodel"]

RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")

# The case names, spelled ONCE.
K_LOCALS = "one stop issues the locals once; a closed pane's load is not issued"
K_FLOW = "one stop asks for its flow window once, and the window is adopted"
K_LANDING = "a loader that starts following at a stop asks about that stop"
K_INT = "an Int local is drawn with its value"
K_STRING = "a recorded string is drawn with its text"
K_SELECTION = "the changed mark follows the value, not the selection"
K_UNCHANGED = "an unchanged value is not marked changed"
K_ADDED = "a name new in scope is recorded as added, not modified"
K_KEPT = "a move keeps the values on screen until its answer arrives"
K_CALLJUMP = "a call-trace row's click jumps to that row's own tick"
K_EVENTJUMP = "an event-log row's click jumps to that event"
K_CALLKEY = "every call-trace row carries its own call key"

NAMED_CASES = {
    K_LOCALS: T_LOADER, K_FLOW: T_LOADER,
    K_LANDING: T_JOBS, K_INT: T_JOBS, K_STRING: T_JOBS,
    K_SELECTION: T_JOBS, K_UNCHANGED: T_JOBS, K_ADDED: T_JOBS,
    K_KEPT: T_JOBS, K_CALLJUMP: T_JOBS, K_EVENTJUMP: T_JOBS,
    K_CALLKEY: T_JOBS,
}

BT_SELFTEST = "BlockTracer tools/journeys/selftest.mjs"


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""
    replaces: str = ""   # the host arm whose claim this one carries


ARMS = [
    Arm(
        "J", STOPLOADER,
        "      if not store.applyLocalsResponse(answer.rows, answer.requestedAt):\n",
        "      if true:\n",
        K_LOCALS,
        "**THE LOCALS ANSWER IS THROWN AWAY.** The request is sent and "
        "answered, and the pane keeps whatever it last showed: every step "
        "moves the position and the values never change",
        "J/the-locals-reply-is-discarded-again",
    ),
    Arm(
        "R", STOPLOADER,
        "  l.following = true\n  let loader = l\n",
        "  l.following = true\n  l.sentFor[spLocals] = l.stopKey(spLocals)\n"
        "  let loader = l\n",
        K_LANDING,
        "**THE LANDING STOP IS TAKEN AS ALREADY LOADED.** Every later stop is "
        "asked about; the position the session opens at shows no locals",
        "R/the-landing-position-is-never-asked-about",
    ),
    Arm(
        "F2", FLOWVM,
        "  if viewUpdates.isNil or viewUpdates.kind != JArray or "
        "viewUpdates.len == 0:\n",
        "  if true:\n",
        K_FLOW,
        "**EVERY FLOW WINDOW IS REFUSED.** The loader still asks and the "
        "engine still answers, and no line ever carries a live value",
        "F2/the-engine-window-never-reaches-the-pane",
    ),
    Arm(
        "L", ADAPTER,
        '  of tkInt: scalarOf(pvkInt, "i")\n',
        '  of tkInt: scalarOf(pvkInt, "int")\n',
        K_INT,
        "**AN INT IS READ FROM THE WRONG FIELD.** Its row keeps its name and "
        "type and loses its value, which no row count can see",
        "L/the-value-kind-is-misread",
    ),
    Arm(
        "F1", FLOWVM,
        "  result.text = presented.root.text\n",
        '  result.text = (if value{"text"}.isNil: presented.root.text '
        'else: "")\n',
        K_STRING,
        "**A RECORDED STRING IS DRAWN BLANK.** The overlay keeps its labels, "
        "on the right lines, and says nothing about the strings",
        "F1/an-overlay-of-names-with-no-values",
    ),
    Arm(
        "VD1", STATEVM,
        "  not vm.isNil and vm.valueChanges.val.isModified(path)\n",
        "  not vm.isNil and vm.selectedPath.val == path\n",
        K_SELECTION,
        "**THE MARK FOLLOWS THE SELECTION.** A class is present on a row at "
        "every position, and it is on the wrong row",
        "VD1/the-mark-follows-the-selection-again",
    ),
    Arm(
        "VD2", CHANGES,
        "    elif before[path] != value:\n",
        "    else:\n",
        K_UNCHANGED,
        "**EVERY VALUE IN SCOPE AT THE ANCHOR IS MARKED.** A blanket mark "
        "passes 'a marked row is on screen' at every step",
        "VD2/every-value-is-marked-changed",
    ),
    Arm(
        "VD3", CHANGES,
        "      result.changes[path] = vchAdded\n",
        "      result.changes[path] = vchModified\n",
        K_ADDED,
        "**AN ARRIVAL IS RECORDED AS A CHANGE.** Drawn alike by design; the "
        "model's distinction is what a caller that draws them apart reads",
        "VD3/an-arrival-reads-as-a-change",
    ),
]

ARMS += [
    Arm(
        "FL2", STOPLOADER,
        "  store.locals.loadingState.val = lsLoading\n",
        "  store.locals.loadingState.val = lsLoading\n"
        "  store.locals.locals.val = @[]\n",
        K_KEPT,
        "**A MOVE EMPTIES THE VALUES BEFORE ITS ANSWER.** Between the move and "
        "the engine's reply the pane shows nothing, at a position that has "
        "values — the frame the host's journey samples for",
        "FL2/the-panes-move-before-the-values-arrive",
    ),
    Arm(
        "G", CALLTRACEVM,
        "      calltraceJumpArgs(line.location, line.rrTicks, line.codeGeneration))",
        "      calltraceJumpArgs(line.location, line.rrTicks + 1, line.codeGeneration))",
        K_CALLJUMP,
        "**THE CALL-TRACE SEEK LANDS ONE TICK PAST THE ROW.** The click still "
        "moves the session, so the move looks like it worked; it is at the "
        "wrong step",
        "G/the-seek-lands-somewhere-else",
    ),
    Arm(
        "H", EVENTLOGVM,
        "    if event.noPosition:\n      return\n",
        "    if true:\n      return\n",
        K_EVENTJUMP,
        "**AN EVENT-LOG ROW'S CLICK SEEKS NOWHERE.** The row is selected and "
        "the session stays where it was",
        "H/the-event-log-rows-are-not-bound",
    ),
    Arm(
        "CT1", STORE,
        '    callKey: call.getOrDefault("key").getStr(""))',
        '    callKey: "")',
        K_CALLKEY,
        "**TWO FRAMES ANSWER TO ONE IDENTITY.** Every row is drawn, named and "
        "placed, and a link to a frame can no longer say which row it means",
        "CT1/two-frames-answer-to-one-identity",
    ),
]

DECLARED_SURVIVORS: list = []


@dataclass
class RunResult:
    passed: list = field(default_factory=list)
    failed: list = field(default_factory=list)
    ran: bool = True
    hung: bool = False

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


# Every read and every write is BYTES (§32f).
def read_source(path: str) -> str:
    return (ROOT / path).read_bytes().decode("utf-8", errors="surrogateescape")


def write_source(path: str, text: str) -> None:
    (ROOT / path).write_bytes(text.encode("utf-8", errors="surrogateescape"))


def suite_cmd(path: str, backend: str) -> list:
    out = OUT_DIR / f"{Path(path).stem}.{backend}"
    if backend == "js":
        return ["nim", "js", "-d:nodejs", "-r", *NIM_FLAGS,
                f"--nimcache:{out}.nimcache", f"-o:{out}.js", path]
    return ["nim", "c", "-r", *NIM_FLAGS, f"--nimcache:{out}.nimcache",
            f"-o:{out}", path]


def run_one(path: str, backend: str) -> RunResult:
    """One suite on one backend. A run that prints no result lines did not
    run, whatever its exit code says."""
    res = RunResult()
    try:
        proc = subprocess.run(
            suite_cmd(path, backend), cwd=ROOT, capture_output=True,
            text=True, timeout=SUITE_TIMEOUT, encoding="utf-8",
            errors="replace")
    except subprocess.TimeoutExpired:
        res.hung, res.ran = True, False
        print(f"      ---- {path} [{backend}]: NO RESULT AFTER "
              f"{SUITE_TIMEOUT}s ----")
        return res
    out = proc.stdout + proc.stderr
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(
                m.group(2))
    if res.total == 0:
        res.ran = False
        print(f"      ---- {path} [{backend}]: no result lines; "
              f"last 20 lines ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)
    return res


def run_suites(paths: list) -> dict:
    """{backend: RunResult} over `paths`, merged per backend."""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    merged = {}
    for backend in BACKENDS:
        total = RunResult()
        for path in paths:
            r = run_one(path, backend)
            total.passed += r.passed
            total.failed += r.failed
            total.ran = total.ran and r.ran
            total.hung = total.hung or r.hung
        merged[backend] = total
    return merged


# §32h: `finally` covers an exception and does NOT cover a signal.
_ACTIVE: tuple | None = None


def install_restore_on_signal() -> None:
    def handler(signum, _frame):
        if _ACTIVE is not None:
            path, original = _ACTIVE
            write_source(path, original)
            print(f"\nsignal {signum}: restored {path} before exiting")
        sys.exit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, handler)


def needle_scan() -> int:
    """Every arm's needle occurs exactly once, every subject and suite is in
    the control set, and every killer is a case the suites spell. No
    toolchain."""
    problems = 0
    for arm in ARMS + DECLARED_SURVIVORS:
        n = read_source(arm.path).count(arm.find)
        status = "ok" if n == 1 else "LOST" if n == 0 else "AMBIGUOUS"
        if n != 1:
            problems += 1
        print(f"{arm.id:<4} {status:<10} {n} occurrence(s) in {arm.path}")
        if arm.path not in TOUCHED:
            print(f"{arm.id}: subject {arm.path} is not in TOUCHED")
            problems += 1
        if arm.killer not in NAMED_CASES:
            print(f"{arm.id}: killer {arm.killer!r} is not a named case")
            problems += 1
        if not arm.replaces:
            print(f"{arm.id}: names no host arm it replaces")
            problems += 1
    # A named case that its suite does not spell is a typo, and an arm graded
    # by it would read as MISDIRECTED for the wrong reason.
    for case, suite in NAMED_CASES.items():
        if f'test "{case}"' not in read_source(suite):
            print(f"NAMED CASE NOT IN {suite}: {case!r}")
            problems += 1
    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


def record_control_hashes() -> int:
    if needle_scan() != 0:
        print("REFUSING TO RECORD: the needle scan is not clean (§32)")
        return 1
    lines = [f"{digest(p)}  {p}" for p in TOUCHED]
    CONTROL_HASHES.write_text("\n".join(lines) + "\n")
    print(f"recorded {len(lines)} digests in {CONTROL_HASHES}")
    return 0


def check_control_hashes() -> bool:
    if not CONTROL_HASHES.exists():
        print(f"CONTROL DIGESTS ABSENT: {CONTROL_HASHES.name} — run "
              f"--needle-scan, review, then --record-control-hashes")
        return False
    recorded = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            h, p = line.split(None, 1)
            recorded[p.strip()] = h
    ok = True
    # A subject that is not in the file at all is a refusal, not a skip.
    for p in TOUCHED:
        if p not in recorded:
            print(f"CONTROL DIGEST ABSENT: {p}")
            ok = False
        elif recorded[p] != digest(p):
            print(f"CONTROL DIGEST MOVED: {p} — re-run --needle-scan BEFORE "
                  f"--record-control-hashes (§32)")
            ok = False
    return ok


sys.path.insert(0, str(ROOT / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def main() -> int:
    # THE ARGUMENT RULE FIRST, before anything is compiled or mutated
    # (`ci/lib/harness_guard.py`, `ci/test/harness-argument-refusal.sh`).
    refused = refuse_undeclared_arms(sys.argv[1:], globals())
    if refused:
        return refused
    parser = argparse.ArgumentParser(
        prog=Path(__file__).name, description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--needle-scan", action="store_true")
    mode.add_argument("--record-control-hashes", action="store_true")
    mode.add_argument("--only", default=None)
    args = parser.parse_args(sys.argv[1:])
    if args.needle_scan:
        return needle_scan()
    if args.record_control_hashes:
        return record_control_hashes()
    only = set(args.only.split(",")) if args.only else None

    if needle_scan() != 0:
        print("REFUSING TO RUN: a needle is lost or ambiguous (§32)")
        return 1
    # The verdict is acted on: `baseline` is snapshotted from the CURRENT tree,
    # so a run started on an already-mutated file would restore TO it.
    if not check_control_hashes():
        print("REFUSING TO RUN: a control digest moved (§32)")
        return 1

    baseline = {p: digest(p) for p in TOUCHED}
    install_restore_on_signal()

    print("\n== control ==")
    control = run_suites(SUITES)
    for backend, res in control.items():
        if res.failed or not res.ran:
            print(f"CONTROL IS NOT GREEN [{backend}]: failed={res.failed}")
            return 1
        missing = [c for c in NAMED_CASES if c not in res.passed]
        if missing:
            print(f"CONTROL [{backend}] DID NOT RUN {len(missing)} NAMED "
                  f"CASES: {missing}")
            return 1
        print(f"control [{backend}]: {res.total} cases, all "
              f"{len(NAMED_CASES)} named ones ran, 0 failures")
    print()

    problems = 0
    global _ACTIVE
    for arm in ARMS + DECLARED_SURVIVORS:
        if only and arm.id not in only:
            continue
        original = read_source(arm.path)
        if original.count(arm.find) != 1:
            print(f"{arm.id:<4} HARNESS-FAILURE      needle occurs "
                  f"{original.count(arm.find)} times in {arm.path}")
            problems += 1
            continue
        _ACTIVE = (arm.path, original)
        write_source(arm.path, original.replace(arm.find, arm.replace))
        try:
            results = run_suites([NAMED_CASES[arm.killer]])
        finally:
            write_source(arm.path, original)
            _ACTIVE = None
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{arm.id:<4} HARNESS-FAILURE      {p} did not "
                          f"restore to its control bytes")
                    return 2
        declared = arm in DECLARED_SURVIVORS
        verdicts = []
        for backend, res in results.items():
            if res.hung or not res.ran:
                verdicts.append((backend, "HARNESS-FAILURE",
                                 "the mutation never ran"))
            elif declared:
                verdicts.append((backend, "NO-LONGER-A-SURVIVOR"
                                 if res.failed else "survived (declared)",
                                 str(res.failed)))
            elif not res.failed:
                verdicts.append((backend, "SURVIVED", "no case noticed"))
            elif arm.killer in res.failed:
                others = [f for f in res.failed if f != arm.killer]
                verdicts.append((backend, "killed", arm.killer + (
                    f"  (+{len(others)} more)" if others else "")))
            else:
                verdicts.append((backend, "MISDIRECTED",
                                 f"died in {res.failed[:3]}"))
        for backend, verdict, note in verdicts:
            if verdict not in ("killed", "survived (declared)"):
                problems += 1
            print(f"{arm.id:<4} [{backend:<2}] {verdict:<20} {note}")

    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
