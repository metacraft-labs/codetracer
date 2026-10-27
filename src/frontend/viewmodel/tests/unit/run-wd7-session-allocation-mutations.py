#!/usr/bin/env python3
"""Mutation harness for WD7's allocation call.

WHAT THIS COVERS. `Hosted-Session-Allocation.md` §3.2's three prohibitions, as
`viewmodel/platform/session_allocation.nim` implements them, and §3.1's request
shape including the field that is deliberately ABSENT (`product_id`, D-S13).
Each arm plants the defect that would satisfy a weaker version of one property
and names, in advance, the single `test_session_allocation.nim` case that must
redden.

WHAT IT DOES NOT COVER, and the reason is a boundary rather than an omission:
§5's first and second verifications have an OBSERVATIONAL half — *"the
assertion that makes it mean anything is the SUBSTRATE'S view, not the
browser's"* — which needs a running api-server and `sessionctl list`. No arm
here can redden that, and an arm that claimed to would be the "evidence that
could not fail" shape this campaign has already struck. The construction half
of §5's second verification has its own gate instead:
`ci/test/wd7-loop-arm-allocates-nothing.sh`, which plants an import of the
allocation client into `web_main.nim` and requires the Noir Studio arm's
egress count to leave zero.

THREE VERDICTS, NOT TWO (Verification-Harness-Traps §1a). An arm that never ran
is not a kill:

  killed          the named case reported [FAILED]
  SURVIVED        the run produced result lines and the named case was green
  HARNESS-FAILURE the mutation did not apply, did not compile, or the run
                  produced NO result lines at all

`nim c -r` exits non-zero identically for a compile error, a failed assertion
and an OOM, so the verdict is read from the suite's RESULT LINES and never from
the exit status.

EVERY ARM CARRIES A NAMED BEHAVIOUR-PRESERVING CONTROL in the same file — a
renamed local, two reordered independent assignments — applied on its own, and
the suite must stay GREEN under it. Without that, a red arm proves only that
the file was touched: a mutation that broke compilation would score identically
to one that defeated the rule under test.

RESTORATION IS FROM A VERIFIED SNAPSHOT AND IS ATOMIC. The original bytes are
read before each edit, written back to a sibling temporary file and moved into
place with `os.replace` — one rename, so a run killed between the write and the
move leaves either the mutation or the original and never a half-written file.
Never `git checkout --`: this repository installs a post-checkout hook that
repairs worktree hooks as a side effect, so a test run must not go through git
to restore a file.

THE CONTROL DIGESTS ARE RECORDED ON DISK, NOT TAKEN AT START-UP. A baseline
taken at start-up cannot tell a clean tree from one a killed run left a
mutation in: it reads the mutation as the baseline, every restore then verifies
against the mutated bytes and agrees, and the only symptom is a red control
suite — which names a red suite rather than the debris that reddened it.
`--record-control-hashes` rewrites them, and is the deliberate step that
distinguishes "I changed the subject on purpose" from "a killed run left
debris".

ONLY ONE INSTANCE MAY RUN IN A WORKTREE, enforced with an exclusive `flock`
rather than asked for. Two instances each restore from their OWN in-memory
snapshot, so the loser's restore writes back bytes the winner had already
mutated and every verdict after that point grades a file nobody chose. The
recorded digests do not catch it: they are checked once, before the first
mutation, when both instances see a clean tree.

Usage (from the repository root):
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-wd7-session-allocation-mutations.py
"""

from __future__ import annotations

import fcntl
import hashlib
import os
import re
import signal
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]

SUBJECT = "src/frontend/viewmodel/platform/session_allocation.nim"
SUITE_PATH = "src/frontend/viewmodel/tests/unit/test_session_allocation.nim"

TOUCHED = [SUBJECT]

CONTROL_HASHES = HERE / "wd7-session-allocation-mutation-control.sha256"
LOCK_PATH = HERE / ".wd7-session-allocation-mutation.lock"

# --- the case names, spelled once ------------------------------------------
#
# A typo here shows up as "the control did not run this case" rather than as a
# silently unkillable arm.

C_STATIC = "a static project produces no request at all"
C_INVENTED = "a reason this build has never heard of survives byte for byte"
C_FLAVOUR = "an unknown flavour is still ASKED, not refused here"
C_TWICE = "two descriptors in a row both produce a request"
C_PRODUCT = "the body carries the runtime contract and NOT the product"
C_OK_DECIDES = "a refusal is decided by ok, not by the status number"
C_PRINCIPAL = "the login cookie travels, because the cookie IS the principal"
C_NO_PROJECT = "a session runtime with no project id is refused before it is sent"


@dataclass
class Mutation:
    id: str
    find: str
    replace: str
    killer: str
    why: str
    control_name: str
    control_find: str
    control_replace: str
    path: str = SUBJECT


# The two behaviour-preserving controls, each quoted once and shared by the arms
# that touch the same proc. A control must change the bytes and nothing else.
CTRL_RENAME = (
    "a renamed local in `allocationBodyFor`",
    '  let node = %*{"flavour": runtime.flavour, "image": runtime.imageRef}\n'
    "  $node",
    '  let payload = %*{"flavour": runtime.flavour, "image": runtime.imageRef}\n'
    "  $payload",
)
CTRL_REORDER = (
    "two reordered independent assignments in `readAllocationOutcome`",
    '  result.sessionId = str(node, "session_id")\n'
    '  result.instance = str(node, "instance")',
    '  result.instance = str(node, "instance")\n'
    '  result.sessionId = str(node, "session_id")',
)

GUARD = ("  if d.session.runtime.kind != prkSession:\n"
         "    return none(AllocationRequest)")
VERDICT = "  result.status = if ok.getBool: asAllocated else: asRefused"

MUTATIONS = [
    Mutation(
        id="A1",
        find=GUARD,
        replace=(
            "  if d.session.runtime.kind != prkSession:\n"
            "    return none(AllocationRequest)\n"
            "  if d.session.runtime.flavour notin [\"s1\", \"s2\", \"s4\", \"h2\", \"h4\"]:\n"
            "    return none(AllocationRequest)"),
        killer=C_FLAVOUR,
        why="A CodeTracer-side FLAVOUR ALLOW-LIST — the first of §3.2's three "
            "admission checks. `admit` is what refuses a flavour this "
            "principal is not entitled to; a list here refuses one the "
            "catalogue has simply grown since this bundle shipped.",
        control_name=CTRL_RENAME[0],
        control_find=CTRL_RENAME[1],
        control_replace=CTRL_RENAME[2],
    ),
    Mutation(
        id="A2",
        find=GUARD,
        replace=(
            "  if d.session.runtime.kind != prkSession:\n"
            "    return none(AllocationRequest)\n"
            "  var wd7qAsked {.global.} = 0\n"
            "  inc wd7qAsked\n"
            "  if wd7qAsked > 1000:\n"
            "    return none(AllocationRequest)"),
        killer=C_TWICE,
        why="A LOCAL CONCURRENCY COUNTER — the second of §3.2's three. It "
            "passes every single-request case in the suite, which is exactly "
            "why the suite asks repeatedly. `session.concurrent` is a "
            "capacity grant the substrate enforces per "
            "`(customer_id, product_id)`.\n"
            "    THE LIMIT IS 1000 FOR A MEASURED REASON. A lease counter is "
            "global state, so a limit of 1 trips on whichever case asks "
            "first — this arm was MISDIRECTED at that limit, grading "
            "`a static project produces no request at all` while claiming the "
            "repetition case. 1000 is above everything else in the suite and "
            "below the named case's 2000-iteration loop, so the arm is that "
            "case's and the suite may grow without re-tuning the arm.",
        control_name=CTRL_RENAME[0],
        control_find=CTRL_RENAME[1],
        control_replace=CTRL_RENAME[2],
    ),
    Mutation(
        id="A3",
        find=GUARD,
        replace=(
            "  if d.session.runtime.kind != prkSession and\n"
            "     d.session.runtime.kind != prkStatic:\n"
            "    return none(AllocationRequest)"),
        killer=C_STATIC,
        why="ALLOCATE FOR A STATIC PROJECT TOO. The whole corpus of projects "
            "written before the runtime fields existed decodes as "
            "`prkStatic`, so this is the deployment that *\"allocates for "
            "everyone and hides it\"* — the shape §5's second verification "
            "exists to rule out.",
        control_name=CTRL_RENAME[0],
        control_find=CTRL_RENAME[1],
        control_replace=CTRL_RENAME[2],
    ),
    Mutation(
        id="A4",
        find='  let node = %*{"flavour": runtime.flavour, "image": runtime.imageRef}',
        replace='  let node = %*{"flavour": runtime.flavour, '
                '"image": runtime.imageRef, "product_id": "codetracer"}',
        killer=C_PRODUCT,
        why="A CALLER-SUPPLIED `product_id`, which D-S13 refuses: admission is "
            "keyed on `(customer_id, product_id)` and the same meter can "
            "carry different rates, so a consumer naming its own product "
            "rate-shops between two products the customer legitimately holds.",
        control_name=CTRL_REORDER[0],
        control_find=CTRL_REORDER[1],
        control_replace=CTRL_REORDER[2],
    ),
    Mutation(
        id="A5",
        find=VERDICT,
        replace=(
            "  const wd7qKnown = [\"concurrency\", \"budget\",\n"
            "                     \"flavour_not_allowed\", \"snapshot_expired\",\n"
            "                     \"not_entitled\", \"unknown_image\"]\n"
            "  if not ok.getBool and result.reason notin wd7qKnown:\n"
            "    result.reason = \"unavailable\"\n"
            "  result.status = if ok.getBool: asAllocated else: asRefused"),
        killer=C_INVENTED,
        why="A REFUSAL-REASON ALLOW-LIST. It satisfies every case written with "
            "the six real reasons and fails only the invented one — which is "
            "why the suite carries an invented one. The seventh reason a "
            "substrate three weeks newer learns to emit would read as a "
            "generic failure, which is how *\"the image was never published\" "
            "becomes an hour of debugging the substrate*.",
        control_name=CTRL_REORDER[0],
        control_find=CTRL_REORDER[1],
        control_replace=CTRL_REORDER[2],
    ),
    Mutation(
        id="A6",
        find=VERDICT,
        replace="  result.status = "
                "if httpStatus == 402: asRefused else: asAllocated",
        killer=C_OK_DECIDES,
        why="REFUSAL DECIDED BY THE STATUS NUMBER rather than by `ok`. The "
            "moment the substrate adds a second refusal status, a genuine "
            "refusal with a perfectly good reason in it reads as a success "
            "with an empty session id.",
        control_name=CTRL_REORDER[0],
        control_find=CTRL_REORDER[1],
        control_replace=CTRL_REORDER[2],
    ),
    Mutation(
        id="A7",
        find="    sameOriginCredentials: true))",
        replace="    sameOriginCredentials: false))",
        killer=C_PRINCIPAL,
        why="THE LOGIN COOKIE STOPS TRAVELLING. §3.1's tenancy tuple starts "
            "with `customer_id`, and on this path the cookie IS how the "
            "principal is named — `requireViewer` answers 401 without it, and "
            "the bundle has no principal id to send instead nor any business "
            "having one. A field that is always true is the kind a reader "
            "assumes rather than checks, which is why it is a field.",
        control_name=CTRL_RENAME[0],
        control_find=CTRL_RENAME[1],
        control_replace=CTRL_RENAME[2],
    ),
    Mutation(
        id="A8",
        find="  if d.session.projectId.len == 0:",
        replace="  if false:",
        killer=C_NO_PROJECT,
        why="A SESSION RUNTIME WITH NO PROJECT ID IS SENT ANYWAY, as "
            "`/api/v1/projects//sessions`. The substrate's router splits that "
            "to an empty `parts[4]` and answers about a project named \"\" — "
            "a descriptor its producer got wrong, presented as a working "
            "request, which is the expensive failure "
            "`decodeRuntime` already argues about for an empty image.",
        control_name=CTRL_RENAME[0],
        control_find=CTRL_RENAME[1],
        control_replace=CTRL_RENAME[2],
    ),
]

NIM_RESULT = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")

USAGE = (
    "usage: run-wd7-session-allocation-mutations.py "
    "[--only=A1,A2] [--explain ID] [--needle-scan] [--record-control-hashes]")
KNOWN_FLAGS = {"--only", "--explain", "--needle-scan",
               "--record-control-hashes", "--help", "-h"}


@dataclass
class RunResult:
    rc: int = 0
    ran: bool = True
    passed: list = field(default_factory=list)
    failed: list = field(default_factory=list)

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def acquire_lock():
    fh = open(LOCK_PATH, "a+")
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.seek(0)
        holder = fh.read().strip() or "(the holder recorded no details)"
        fh.close()
        print("ANOTHER MUTATION RUN HOLDS THE LOCK — nothing was mutated.")
        print(f"  lock: {LOCK_PATH}")
        print(f"  held by: {holder}")
        print("  Two instances in one worktree corrupt each other's restores.")
        return None
    fh.seek(0)
    fh.truncate()
    fh.write(f"pid {os.getpid()} on {os.uname().nodename}, cwd {ROOT}\n")
    fh.flush()
    return fh


def install_signal_restore() -> None:
    """Make SIGTERM/SIGHUP raise, so `finally: restore(...)` still runs."""
    def die(signum, _frame):
        raise SystemExit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, die)


def run_suite(label: str) -> RunResult:
    """Compile and run `test_session_allocation.nim`, as TWO steps.

    Two steps so "did not compile" is distinguishable from "ran and failed",
    and `-f` so a cached object file from an unmutated tree cannot be what gets
    graded.
    """
    res = RunResult()
    binary = f"/tmp/wd7-mut-{label}"
    compile_proc = subprocess.run(
        ["nim", "c", "-f", "--hints:off", "--warnings:off",
         "--path:src/frontend/viewmodel",
         f"--nimcache:/tmp/wd7-mut-cache-{label}",
         f"-o:{binary}", SUITE_PATH],
        cwd=ROOT, capture_output=True, text=True, timeout=3600,
    )
    if compile_proc.returncode != 0:
        res.rc = compile_proc.returncode
        res.ran = False
        print("      ---- did not compile; last 12 lines ----")
        for line in (compile_proc.stdout + compile_proc.stderr).splitlines()[-12:]:
            print("      " + line)
        return res
    proc = subprocess.run([binary], cwd=ROOT, capture_output=True,
                          text=True, timeout=3600)
    out = proc.stdout + proc.stderr
    res.rc = proc.returncode
    for line in out.splitlines():
        m = NIM_RESULT.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        res.ran = False
        print("      ---- no result lines; last 12 lines of output ----")
        for line in out.splitlines()[-12:]:
            print("      " + line)
    return res


def apply_once(path: str, find: str, replace: str):
    """Return (original, error). The needle must occur exactly once."""
    p = ROOT / path
    original = p.read_text()
    n = original.count(find)
    if n != 1:
        return original, f"pattern occurs {n} times in {path}, expected 1"
    write_atomically(p, original.replace(find, replace))
    return original, ""


def write_atomically(path: Path, text: str) -> None:
    """One rename, so a kill mid-write cannot leave a half-written file."""
    tmp = path.with_name(path.name + ".wd7-mut.tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def restore(path: str, original: str) -> None:
    write_atomically(ROOT / path, original)


def read_control_hashes() -> dict:
    if not CONTROL_HASHES.exists():
        return {}
    out = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        h, _, p = line.partition("  ")
        if h and p:
            out[p] = h
    return out


def write_control_hashes() -> None:
    body = [
        "# Control digests for run-wd7-session-allocation-mutations.py.",
        "#",
        "# ABSOLUTE, and that is the point. A baseline taken at start-up",
        "# cannot tell a clean tree from one a killed run left a mutation in:",
        "# it reads the mutation as the baseline, every restore then verifies",
        "# against the mutated bytes and agrees, and the only symptom is a red",
        "# control suite.",
        "#",
        "# Rewrite with --record-control-hashes, deliberately, when the",
        "# subject changes on purpose.",
        "",
    ]
    for p in TOUCHED:
        body.append(f"{digest(p)}  {p}")
    CONTROL_HASHES.write_text("\n".join(body) + "\n")


def check_control_hashes() -> int:
    recorded = read_control_hashes()
    if not recorded:
        print(f"NO CONTROL HASHES: {CONTROL_HASHES.name} is missing.")
        print("  Every restore below would verify against digests taken from")
        print("  THIS tree, so a mutation a killed run left behind would be")
        print("  adopted as the baseline. Record them from a tree you have")
        print("  checked, with --record-control-hashes.")
        return 2
    missing = [p for p in TOUCHED if p not in recorded]
    if missing:
        print(f"CONTROL HASHES INCOMPLETE: no entry for {missing}")
        return 2
    drifted = [p for p in TOUCHED if recorded[p] != digest(p)]
    if drifted:
        print("TREE IS NOT AT THE CONTROL BYTES — nothing was mutated.")
        for p in drifted:
            print(f"  {p}")
            print(f"      recorded {recorded[p]}")
            print(f"      on disk  {digest(p)}")
        print("  Either a previous run was killed mid-arm and left a mutation")
        print("  in the tree — restore it and re-run — or the file changed on")
        print("  purpose, in which case re-record with --record-control-hashes.")
        return 2
    return 0


def needle_scan() -> list:
    """Every arm whose `find` or `control_find` does not occur EXACTLY ONCE.

    An arm whose needle no longer occurs can never be applied and therefore
    never killed — it is a row in the table that LOOKS like coverage.
    """
    problems = []
    for mut in MUTATIONS:
        body = (ROOT / mut.path).read_text()
        for label, needle in (("find", mut.find),
                              ("control_find", mut.control_find)):
            n = body.count(needle)
            if n != 1:
                problems.append(
                    f"{mut.id}: {label} occurs {n} time(s) in {mut.path}, "
                    f"expected exactly 1")
    return problems


def report_needle_scan() -> int:
    problems = needle_scan()
    if not problems:
        print(f"  all {len(MUTATIONS)} arm(s) resolve to exactly one needle "
              f"and one control needle")
        return 0
    print("ARM NEEDLES DO NOT RESOLVE — nothing was mutated and nothing recorded.")
    for line in problems:
        print(f"  {line}")
    return 2


sys.path.insert(0, str(ROOT / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def selected(argv: list) -> list:
    wanted = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--only" and i + 1 < len(argv):
            wanted += [s.strip() for s in argv[i + 1].split(",") if s.strip()]
            i += 1
        elif a.startswith("--only="):
            wanted += [s.strip() for s in a[len("--only="):].split(",")
                       if s.strip()]
        elif not a.startswith("-"):
            wanted.append(a)
        i += 1
    if not wanted:
        return list(MUTATIONS)
    return [m for m in MUTATIONS if m.id in wanted]


def main() -> int:
    argv = sys.argv[1:]
    refused = refuse_undeclared_arms(argv, globals())
    if refused:
        return refused
    for arg in argv:
        if arg.startswith("-") and arg.split("=")[0] not in KNOWN_FLAGS:
            # "unknown argument", which is the wording
            # `ci/test/harness-argument-refusal.sh` greps for: that probe
            # requires a refusal to NAME what it refused, and a message it
            # cannot recognise is a refusal nobody can tell from a crash.
            print(f"unknown argument: {arg}")
            print(USAGE)
            return 2
    if "--help" in argv or "-h" in argv:
        print(USAGE)
        return 0

    if "--explain" in argv:
        ident = argv[argv.index("--explain") + 1]
        for mut in MUTATIONS:
            if mut.id == ident:
                print(f"{mut.id}  {mut.path}")
                print(f"  killer: {mut.killer}")
                print(f"  why:    {mut.why}")
                print(f"  control: {mut.control_name}")
                return 0
        return 2

    # THE NEEDLE SCAN RUNS FIRST AND GATES RE-RECORDING, because re-recording
    # is the moment the new bytes are blessed, and doing it first would certify
    # arms that have just stopped describing them.
    print("Needle scan")
    rc = report_needle_scan()
    if rc:
        return rc
    print()

    if "--record-control-hashes" in argv:
        write_control_hashes()
        print(f"recorded control digests for {len(TOUCHED)} file(s) in "
              f"{CONTROL_HASHES.name}")
        return 0

    if "--needle-scan" in argv:
        return 0

    lock = acquire_lock()
    if lock is None:
        return 2
    install_signal_restore()

    print("Control digests")
    rc = check_control_hashes()
    if rc:
        return rc
    print(f"  {len(TOUCHED)} file(s) at their recorded control bytes")
    print()

    print("Control run (unmutated tree)")
    base = run_suite("control")
    if not base.ran:
        print("CONTROL DID NOT RUN — nothing was mutated.")
        return 2
    if base.failed:
        print(f"CONTROL IS NOT GREEN: {len(base.failed)} failing case(s) — "
              f"nothing was mutated.")
        for name in base.failed:
            print(f"  [FAILED] {name}")
        return 2
    print(f"  {len(base.passed)} case(s) green")
    print()

    arms = selected(argv)
    # EVERY KILLER MUST BE A CASE THE CONTROL RAN. A killer that names no case
    # can never redden, so the arm would be unkillable and would look like
    # coverage.
    unknown = sorted({m.killer for m in arms if m.killer not in base.passed})
    if unknown:
        print("A KILLER NAMES NO CASE THE CONTROL RAN — nothing was mutated.")
        for name in unknown:
            print(f"  {name!r}")
        return 2

    print(f"Grading {len(arms)} arm(s)")
    killed = survived = harness = 0
    for mut in arms:
        original, err = apply_once(mut.path, mut.find, mut.replace)
        if err:
            print(f"{mut.id:<4} HARNESS-FAILURE   {err}")
            harness += 1
            continue
        try:
            res = run_suite(mut.id.lower())
        finally:
            restore(mut.path, original)
        drift = [p for p in TOUCHED if read_control_hashes()[p] != digest(p)]
        if drift:
            print(f"{mut.id:<4} HARNESS-FAILURE   {drift} did not restore to "
                  f"the control bytes")
            harness += 1
            continue
        if not res.ran:
            print(f"{mut.id:<4} HARNESS-FAILURE   the mutation never ran")
            harness += 1
        elif mut.killer in res.failed:
            others = [n for n in res.failed if n != mut.killer]
            note = f" (+{len(others)} other case(s))" if others else ""
            print(f"{mut.id:<4} killed            {mut.killer}{note}")
            killed += 1
        elif res.failed:
            print(f"{mut.id:<4} MISDIRECTED       reddened {res.failed} "
                  f"but not {mut.killer!r}")
            harness += 1
        else:
            print(f"{mut.id:<4} SURVIVED          {mut.killer} stayed green")
            survived += 1
    print()

    print("Behaviour-preserving controls (each alone; the suite must stay green)")
    controls_ok = 0
    seen = set()
    for mut in arms:
        key = (mut.path, mut.control_find)
        if key in seen:
            continue
        seen.add(key)
        original, err = apply_once(mut.path, mut.control_find,
                                   mut.control_replace)
        if err:
            print(f"     CONTROL-HARNESS-FAILURE  {err}")
            harness += 1
            continue
        try:
            res = run_suite("ctrl-" + mut.id.lower())
        finally:
            restore(mut.path, original)
        drift = [p for p in TOUCHED if read_control_hashes()[p] != digest(p)]
        if drift:
            print(f"     CONTROL-HARNESS-FAILURE  {drift} did not restore")
            harness += 1
            continue
        if res.ran and not res.failed:
            print(f"     green             {mut.control_name}")
            controls_ok += 1
        else:
            print(f"     NOT GREEN         {mut.control_name}: "
                  f"{res.failed or 'did not run'}")
            harness += 1
    print()

    print(f"{len(arms)} arm(s): {killed} killed, {survived} SURVIVED, "
          f"{harness} HARNESS-FAILURE; {controls_ok} control(s) green")
    return 0 if (survived == 0 and harness == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
