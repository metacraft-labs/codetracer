#!/usr/bin/env python3
"""Mutation harness for PLAT-17 — the WASM build of the ViewModel core.

WHAT THIS COVERS. codetracer-specs/Architecture/Uniform-WASM-Core.md §2.1.3
("run the EXISTING suites on a third backend and require the same results"),
§2.1.4 (what "the same" means: equal case counts and equal assertion counts,
per file, as an EQUALITY, with every excluded suite named for a platform
reason), §2.1.4's fake-timer speed signal, and PLAT-17's own deliverable 2
(`--mm:orc` under a linear-memory target, with the steady-state footprint
measured before any UI is attached) and deliverable 3 (the WASM arm of
`async_compat`).

WHY THIS FILE EXISTS AT ALL, which is worth stating because PLAT-17 shipped
without it and a landing pass put it back. Every milestone from PLAT-5 to
PLAT-16 ships a committed harness; PLAT-17's seventeen arms were documented in
prose and could not be re-run from the tree. Verification-Harness-Traps.md §14c
is the rule: *a measurement taken in a scratch directory is a claim, not
evidence*. Seventeen arms nobody can re-apply are seventeen sentences.

FIVE SUBJECT REPOS' WORTH OF ONE DIFF, WHICH IS UNUSUAL AND IS THE POINT.
PLAT-17's diff spans THREE git repositories — `codetracer`, `codetracer-specs`
and `nim-everywhere` — because the WASM arm of `drainPlatformCallbacks` lives
in `nim-everywhere/src/nim_everywhere/async_compat.nim`, a sibling checkout
that `config.nims` puts on the Nim path by the relative path `../nim-everywhere
/src`. Arms W1-W4 mutate it. `TOUCHED` therefore names a path OUTSIDE this
repository, `--enumerate-touched` runs `git status` in EACH repo a `TOUCHED`
entry lives in, and the digest file records a file this repository does not
version. All three are deliberate: a harness that could only restore files
inside its own repo would have had to leave the milestone's three most
important arms unarmed.


SEVEN VERDICTS, NOT TWO (Verification-Harness-Traps.md §1, §1a, §32a, §33).
An arm that never ran is not a kill; neither is one that died upstream of its
subject; neither is one whose case never reached a verdict at all:

  killed                 the named case (or contract) reported [FAILED] **and
                         its failure text carried the arm's own `because`**
  MIS-ATTRIBUTED         the named case died, but not for the arm's reason —
                         §17's fourth verdict. Sits beside HARNESS-FAILURE
                         rather than beside `killed`, because like it, it says
                         *the run told you nothing*
  MISDIRECTED            something else went red and the named case did not
  NO-VERDICT-FOR-KILLER  the run printed result lines, and the named case
                         reported NEITHER [OK] nor [FAILED] — the mutant died
                         INSIDE it, before its result line (§1a's mirror)
  SUITE-DIED             the mutation applied, the target BUILT, and the run
                         printed no result line at all. Distinct from
                         HARNESS-FAILURE on purpose, and PLAT-17 is the
                         milestone that makes the distinction load-bearing:
                         arm P1 restores the `getpwuid` defect, and what that
                         defect does is kill `common/paths.nim`'s MODULE
                         INITIALISER — before `unittest` prints anything. For
                         P1 that IS the kill (`expect="suite-dies"`); for
                         every other arm it is a problem
  SURVIVED               the run produced result lines and the named case was
                         [OK]. After a repair this means "a second mechanism
                         now covers this" at least as often as it means "the
                         code is fine" (§32a)
  HARNESS-FAILURE        the mutation did not apply, or the target did not
                         build/compile

Verdicts are parsed from RESULT LINES — `[OK]` / `[FAILED]` for a Nim suite,
`  ok: ` / `  ok — ` / `  FAIL: ` for the four bash contract scripts — and
NEVER from an exit status. `nim c -r` returns the same non-zero code for a
compile error, a failed assertion and an OOM, and `emcc`'s node loader returns
the same non-zero code for a trap and for a failing suite.


THREE GRADERS, BECAUSE PLAT-17'S DELIVERABLES ARE NOT ALL NIM.
A milestone whose subject is a BUILD is graded by scripts as well as by suites,
and pretending otherwise would have meant arming only the four Nim subjects:

  nim-wasm    compile a suite with the lane's own emscripten flags, run it
              under node. THE FLAGS ARE READ FROM `ci/lib/run-nim-test-lane.sh`
              RATHER THAN COPIED (§14: one predicate, one function) — so an arm
              that DELETES a flag from the runner changes what this harness
              compiles with, which is what makes L1/L2/L3/L5 gradeable at all
  nim-native  the same suite on `nim c`. Used for the negative controls that
              say an arm is about the WASM arm specifically
  script      run one of the four bash contract scripts and read its own
              markers

WHY THE THREE GRADERS SHARE ONE `RunResult`. Two verdict parsers would be
trap 14 in the place it does the most damage — a harness whose two halves
disagree about what a kill is. The parse differs (one regex per marker
vocabulary); everything downstream of `RunResult` is one code path.


EVERY KILL ARM CARRIES A NAMED BEHAVIOUR-PRESERVING CONTROL in the same file,
applied on its own, which must leave the grader GREEN. A renamed local, a
reordered disjunction, a swapped comparison, a flag written in its equivalent
spelling. Without the control an arm cannot distinguish "the mutation broke the
property" from "any edit to this file breaks the build" — which on a wasm lane,
where a link error and an assertion failure look identical from outside, is not
a theoretical distinction.

EVERY ARM'S `because` IS DERIVED FROM A TRANSCRIPT, NEVER TYPED (§17a, §17b).
`unittest.check` stringifies the AST it receives and a `template` body is
substituted before it gets there, so a `because` copied from a helper's source
can never occur — and §17b then shows the same string going stale under an
ordinary rename, with no scan that can see it. Run `--collect-because` to
re-derive every one of them from the failure text the arms actually produce,
and paste the block it prints. Two `because` strings in this file quote a
SCRIPT's `FAIL:` text rather than a `Check failed:` line; those are ordinary
text and are stable, which is §17a's "prefer a `because` that quotes the
EFFECT" arriving for free.

THE NEEDLE SCAN GATES `--record-control-hashes` (§16). An arm is a quotation of
the code; repairs move code; a quotation that stopped matching is a row in the
table that looks like coverage and can never be killed. The scan refuses to
re-record while any `find` or `control_find` fails to occur EXACTLY ONCE, and
it runs at the start of every ordinary run too — an unaimed arm is not a thing
to discover forty minutes in.

`TOUCHED` NAMES THE GRADED SUITES AND SCRIPTS, NOT ONLY THE MUTATION SUBJECTS,
and that is §16c being paid rather than inherited. Nine of the sixteen
harnesses before this one declare their subjects and not the suites their arms
are graded against, and the reason is mechanical: `TOUCHED` doubles as the
restore set, the digest set and the §16b enumeration set, so every path added
to it costs a re-record — and "keep it minimal" quietly came to mean "subjects
only". The cost of that is a change touching ONLY a suite producing no overlap
signal at all while invalidating every arm graded against it, with §16's needle
scan passing too because the subjects were never touched. The comment on
`TOUCHED` below states which entries are which.

RESTORATION IS CHECKED PER ARM, NOT ONCE AT THE END. An arm that leaves a file
dirty must be named at the arm that did it, because every verdict after it is
otherwise suspect — and on this harness the blast radius is a sibling repo.

Usage:
    run-plat17-wasm-mutations.py                    # the arms
    run-plat17-wasm-mutations.py --needle-scan      # quotations only, no build
    run-plat17-wasm-mutations.py --enumerate-touched
    run-plat17-wasm-mutations.py --collect-because  # re-derive every `because`
    run-plat17-wasm-mutations.py --record-control-hashes
    run-plat17-wasm-mutations.py --only W1,W3,P1
"""

from __future__ import annotations

import fcntl
import hashlib
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]            # .../codetracer
WORKSPACE = ROOT.parent           # .../codetracer-gui, the repro workspace root

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
#
# Every one of these is ROOT-relative and every one is a string, so
# `--enumerate-touched` can resolve `TOUCHED` statically with `ast.parse`
# without importing this module. Importing a harness is one keystroke from
# running it (§16c), and the auditor that reads these is not allowed to take
# that risk on our behalf.

# -- mutation subjects ------------------------------------------------------
# `async_compat.nim` is in the SIBLING REPO `nim-everywhere`. See the header.
ASYNC_COMPAT = "../nim-everywhere/src/nim_everywhere/async_compat.nim"
PATHS = "src/common/paths.nim"
RUNNER = "ci/lib/run-nim-test-lane.sh"
LANE_FILES = "ci/lib/test-lane-files.sh"
JUSTFILE = "justfile"
FT_PROBE = "src/frontend/viewmodel/tests/manual/wasm_fake_timer_probe.nim"
FP_PROBE = "src/frontend/viewmodel/tests/manual/wasm_footprint_probe.nim"
SUITE_ASYNC = "src/frontend/viewmodel/tests/unit/test_async_compat_wasm_arm.nim"

# -- graded suites and scripts that NO arm mutates --------------------------
# In `TOUCHED` anyway; see the header's §16c paragraph.
SUITE_FACADE = "src/frontend/viewmodel/tests/unit/test_sdk_facade.nim"
SUITE_PANEL = "src/frontend/viewmodel/tests/unit/test_verification_panel_registration.nim"
PARITY_SH = "ci/test/vm-unit-wasm-parity.sh"
LANE_TEST_SH = "ci/test/vm-unit-wasm-lane-test.sh"
FOOTPRINT_SH = "ci/test/wasm-footprint.sh"
FAKETIMER_SH = "ci/test/wasm-fake-timer-speed.sh"

TOUCHED = [
    # Every source file of this workspace that an arm's verdict depends on:
    # the eight mutation subjects and the six suites/scripts the arms are
    # GRADED BY. Both halves, deliberately — see the header.
    #
    # Mutated by at least one arm:
    ASYNC_COMPAT,     # W1 W2 W3 W4      (sibling repo nim-everywhere)
    PATHS,            # P1
    RUNNER,           # L1 L2 L3 L4 L5
    LANE_FILES,       # G1 G2
    JUSTFILE,         # J1
    FT_PROBE,         # T1 T2
    FP_PROBE,         # F1 F2
    SUITE_ASYNC,      # G3 — and the grader for W1-W4
    #
    # Graded against, never mutated. A change to any of these invalidates the
    # arms above it exactly as a change to a subject would, and §16c is the
    # entry recording that nine earlier harnesses do not say so:
    SUITE_FACADE,     # W3's spared case: 43/0 on wasm with platformIsWasm false
    SUITE_PANEL,      # P1's grader — the cheapest wasm suite linking common/paths
    PARITY_SH,        # grades G1 G2 G3
    LANE_TEST_SH,     # grades L1 L2 L3 L4 L5 J1
    FOOTPRINT_SH,     # grades F1 F2
    FAKETIMER_SH,     # grades T1 T2
]

CONTROL_HASHES = HERE / "plat17-wasm-mutation-control.sha256"
LOCK = HERE / ".plat17-wasm-mutation.lock"

# `CT_NIM_CACHE_ROOT` is honoured so a run inherits the warm cache the lane
# and the parity gate already built; without it every arm pays a cold
# emscripten link (~90 s) for a file the previous arm compiled.
CACHE_ROOT = Path(os.environ.get("CT_NIM_CACHE_ROOT", "/tmp/ct-nim-cache")) / "plat17-mutations"


# ---------------------------------------------------------------------------
# The wasm compile flags, READ FROM THE RUNNER rather than copied
# ---------------------------------------------------------------------------

def wasm_flags() -> list[str]:
    """The `nim c` flags `ci/lib/run-nim-test-lane.sh` uses for the wasm lane.

    ONE PREDICATE, ONE FUNCTION (§14). A copied flag list would let arms L1,
    L2, L3 and L5 — each of which DELETES a flag from the runner — pass while
    this harness went on compiling with the flag the runner no longer has. The
    arm would then be graded by a build the mutation did not describe, which is
    the worst of the shapes on that page: a row in the table that looks like
    coverage and whose subject is not the thing under test.

    Parsed rather than sourced because the runner is not a library: it runs a
    lane when you source it. The region is the `compile_cmd=( … )` array in the
    `wasm` branch, which is the same text contract 4-7 of
    `ci/test/vm-unit-wasm-lane-test.sh` already grep against.
    """
    text = (ROOT / RUNNER).read_text()
    m = re.search(
        r'elif \[ "\$\{backend\}" = "wasm" \]; then.*?'
        r'compile_cmd=\(nim c(.*?)\)\n',
        text, re.S)
    if not m:
        raise SystemExit(
            "PRE-FLIGHT: could not find the wasm `compile_cmd=(nim c …)` array "
            f"in {RUNNER}. The harness reads the lane's flags from the runner "
            "rather than copying them (§14); if the runner was restructured, "
            "this reader must be re-aimed, NOT replaced by a literal list.")
    raw = m.group(1)
    # Drop the shell comments, the `${extra_flags[@]}` expansion and the two
    # flags this harness supplies itself (`--nimcache`, `-o`).
    raw = re.sub(r"#[^\n]*", " ", raw)
    out = []
    for tok in shlex.split(raw):
        if tok.startswith(("--nimcache", "-o:", "${", '"${')):
            continue
        out.append(tok)
    return out


# ---------------------------------------------------------------------------
# Arms
# ---------------------------------------------------------------------------

@dataclass
class Grader:
    """How an arm's verdict is taken."""
    kind: str                 # "nim-wasm" | "nim-native" | "script"
    target: str               # a .nim suite, or a bash script
    env: dict = field(default_factory=dict)
    argv: list = field(default_factory=list)

    @property
    def label(self) -> str:
        stem = Path(self.target).stem
        return {"nim-wasm": f"{stem}@wasm",
                "nim-native": f"{stem}@native"}.get(self.kind, stem)


@dataclass
class Arm:
    id: str
    path: str                 # ROOT-relative; may leave this repository
    find: str
    replace: str
    grader: Grader
    killer: str               # the case / contract that must go red
    why: str                  # what property the arm removes
    control_name: str
    control_find: str
    control_replace: str
    expect: str = "case"      # "case" | "suite-dies"
    spares: list = field(default_factory=list)
    spare_grader: Grader | None = None


# The three graders used most often, named once.
G_ASYNC_WASM = Grader("nim-wasm", SUITE_ASYNC)
G_ASYNC_NATIVE = Grader("nim-native", SUITE_ASYNC)
G_PANEL_WASM = Grader("nim-wasm", SUITE_PANEL)
G_FACADE_WASM = Grader("nim-wasm", SUITE_FACADE)
G_LANE_TEST = Grader("script", LANE_TEST_SH)
G_FOOTPRINT = Grader("script", FOOTPRINT_SH)
G_FAKETIMER = Grader("script", FAKETIMER_SH,
                     env={"CT_FAKE_TIMER_ITERATIONS": "2000"})
# Contract 1 of the parity gate reads the two lanes' FILE LISTS and compiles
# nothing, so restricting contract 2 to one file with `CT_PARITY_ONLY` leaves
# G1/G2 graded at full fidelity while costing one compile instead of 142.
# A restricted run exits 2 and says `NOT A VERDICT`, which is exactly right
# here: the arms read its `ok:`/`FAIL:` lines, never its status.
G_PARITY_ONE = Grader("script", PARITY_SH,
                      env={"CT_PARITY_ONLY": "test_async_compat_wasm_arm"})


ARMS = [
    # -------------------------------------------------------------------
    # The WASM arm of the dispatcher pump — nim-everywhere/async_compat.nim
    #
    # These four are the arms PLAT-17's verification singled out as having no
    # runner at all, and they are the reason this file exists rather than a
    # justification for it: the milestone claims `drainWasmDispatcher` is
    # `runOnce` minus `selectInto`, and nothing in the tree could demonstrate
    # that either loop was load-bearing.
    # -------------------------------------------------------------------
    Arm(
        id="W1",
        path=ASYNC_COMPAT,
        find=("        while p.callbacks.len > 0:\n"
              "          let cb = p.callbacks.popFirst()\n"
              "          cb()\n"),
        replace=("        while false:\n"
                 "          let cb = p.callbacks.popFirst()\n"
                 "          cb()\n"),
        grader=G_ASYNC_WASM,
        killer="it runs after exactly one drain",
        why="the drain's callSoon queue loop — `processPendingCallbacks` "
            "without which a completed future's callback is never delivered",
        control_name="the queue-drain local is renamed",
        control_find="          let cb = p.callbacks.popFirst()\n          cb()\n",
        control_replace="          let pending = p.callbacks.popFirst()\n          pending()\n",
    ),
    Arm(
        id="W2",
        path=ASYNC_COMPAT,
        find="        while p.timers.len > 0 and now >= p.timers[0].finishAt:\n",
        replace="        while false and p.timers.len > 0 and now >= p.timers[0].finishAt:\n",
        grader=G_ASYNC_WASM,
        killer="a due timer fires on a drain and a future one does not",
        why="the drain's due-timer loop — `processTimers` without which a "
            "`sleepFor` that the fake clock has already passed never completes",
        control_name="the due-timer comparison is written the other way round",
        control_find="while p.timers.len > 0 and now >= p.timers[0].finishAt:",
        control_replace="while p.timers.len > 0 and p.timers[0].finishAt <= now:",
    ),
    Arm(
        id="W3",
        path=ASYNC_COMPAT,
        find="const platformIsWasm* = defined(wasm32) or defined(emscripten) or defined(wasi)\n",
        replace="const platformIsWasm* = false\n",
        grader=G_ASYNC_WASM,
        killer="platformIsWasm agrees with the backend this binary was built for",
        why="the TARGET-selected third axis. With it false the wasm build "
            "silently takes the NATIVE `poll(0)` branch — which works here "
            "only because emscripten emulates epoll through "
            "`__syscall_prlimit64`, the accident the arm exists to stop "
            "depending on",
        # THE SPARED SUITE IS THE POINT OF THIS ARM. `test_sdk_facade` is the
        # EXISTING test PLAT-17's deliverable 3 names as covering the WASM arm
        # ("the one whose absence produced a silent zero-valued success in
        # CTUI-4"), and under W3 it stays 43 of 43 green on wasm. That is the
        # measurement that says the new suite is NECESSARY rather than
        # additive: the facade-level suite cannot see which arm of the pump it
        # is running on, and an arm that reddens only the new suite is an arm
        # nothing in the tree could have graded before this milestone.
        spares=["the facade's whole surface is present on every arm"],
        spare_grader=G_FACADE_WASM,
        control_name="the disjunction is reordered",
        control_find="defined(wasm32) or defined(emscripten) or defined(wasi)",
        control_replace="defined(emscripten) or defined(wasm32) or defined(wasi)",
    ),
    Arm(
        id="W4",
        path=ASYNC_COMPAT,
        find="        while p.callbacks.len > 0:\n",
        replace="        for _ in 0 ..< p.callbacks.len:\n",
        grader=G_ASYNC_WASM,
        killer="a cascade settles inside ONE drain",
        why="re-reading `.len` each turn. A snapshot length drains exactly "
            "the callbacks that were queued when the drain began, so a "
            "callback that queues another leaves it for a drain that a "
            "browser has no reason to perform",
        control_name="the loop bound is written as an explicit emptiness test",
        control_find="        while p.callbacks.len > 0:\n",
        control_replace="        while not (p.callbacks.len == 0):\n",
    ),

    # -------------------------------------------------------------------
    # The portability defect the WASM build found — src/common/paths.nim
    # -------------------------------------------------------------------
    Arm(
        id="P1",
        path=PATHS,
        find=("    let username =\n"
              "      if not pwd.isNil and not pwd.pw_name.isNil: $pwd.pw_name\n"
              "      else: env.get(\"USER\", \"unknown\")\n"),
        replace="    let username = pwd.pw_name\n",
        grader=G_PANEL_WASM,
        # `expect="suite-dies"` — AND THAT IS THE WHOLE FINDING. `getpwuid`
        # returns NULL when the effective uid has no passwd entry (POSIX says
        # so; emscripten's `geteuid()` is 0 and `getpwuid(0)` is NULL), and
        # `pwd.pw_name` then dereferences it inside this module's INITIALISER
        # — before `unittest` has printed a single line. A line parser folds
        # that into "no case failed", which is §1a's mirror, and it is why
        # SUITE-DIED is a verdict here rather than a note.
        killer="(the module initialiser — no case reaches a verdict)",
        expect="suite-dies",
        why="the nil guard on `getpwuid(geteuid())`. Reproduced on ORDINARY "
            "LINUX as well as on wasm32; see this harness's header note and "
            "the milestone's recipe",
        # A HOISTED BINDING, not a rename. The first version of this control
        # renamed `pwd` on its own `let` and left the three references to it
        # three lines down — so the control DID NOT COMPILE and scored
        # CONTROL-DID-NOT-RUN, which reads like a flake and is really a
        # control that was never behaviour-preserving.
        control_name="the nil guard is hoisted into a named binding",
        control_find="    let username =\n      if not pwd.isNil and not pwd.pw_name.isNil: $pwd.pw_name\n",
        control_replace="    let havePwName = not pwd.isNil and not pwd.pw_name.isNil\n    let username =\n      if havePwName: $pwd.pw_name\n",
    ),

    # -------------------------------------------------------------------
    # The lane's flags — ci/lib/run-nim-test-lane.sh, graded by the contract
    # suite. Each of these four flags is silent when absent: the lane goes on
    # building and going green while measuring something else.
    # -------------------------------------------------------------------
    Arm(
        id="L1",
        path=RUNNER,
        find="\t\t\t--mm:orc --threads:off\n",
        replace="\t\t\t--threads:off\n",
        grader=G_LANE_TEST,
        killer="the wasm compile passes --mm:orc explicitly",
        why="PLAT-17's deliverable 2 stated as a flag. Nim 2.x DEFAULTS to "
            "orc, so this arm's mutant builds and passes — the lane simply "
            "stops being able to name the memory manager its footprint and "
            "timing numbers were taken under (§12b)",
        control_name="the two flags are written in the other order",
        control_find="\t\t\t--mm:orc --threads:off\n",
        control_replace="\t\t\t--threads:off --mm:orc\n",
    ),
    Arm(
        id="L2",
        path=RUNNER,
        find="\t\t\t--passL:-sEXIT_RUNTIME=1\n",
        replace="",
        grader=G_LANE_TEST,
        killer="the wasm compile passes -sEXIT_RUNTIME=1",
        why="the `-d:nodejs` of a wasm lane: without it emscripten need not "
            "propagate main's status and a FAILING suite can exit 0",
        # THE TWO `--passL` LINES SWAPPED. The first version of this control
        # rewrote `--passL:` as `--passL=`, which nim accepts and contract 5
        # — a grep for the literal `passL:-sEXIT_RUNTIME=1` — does not. It
        # scored CONTROL-RED, correctly: an edit that reddens the grader is
        # not behaviour-preserving with respect to that grader, whatever the
        # compiler thinks.
        control_name="the last two link flags are swapped",
        control_find="\t\t\t--passL:-sALLOW_MEMORY_GROWTH=1\n\t\t\t--passL:-sEXIT_RUNTIME=1\n",
        control_replace="\t\t\t--passL:-sEXIT_RUNTIME=1\n\t\t\t--passL:-sALLOW_MEMORY_GROWTH=1\n",
    ),
    Arm(
        id="L3",
        path=RUNNER,
        find="\t\t\t--passL:-sNODERAWFS=1\n",
        replace="",
        grader=G_LANE_TEST,
        killer="the wasm compile uses node's real filesystem (-sNODERAWFS=1)",
        why="the flag that decides the FILE SET. Without it emscripten's "
            "in-memory MEMFS replaces node's filesystem and every suite that "
            "reads a fixture would have to be excluded — for a reason about "
            "the harness rather than about the platform",
        control_name="the first two link flags are swapped",
        control_find="\t\t\t--passL:-sSTACK_SIZE=8388608\n\t\t\t--passL:-sNODERAWFS=1\n",
        control_replace="\t\t\t--passL:-sNODERAWFS=1\n\t\t\t--passL:-sSTACK_SIZE=8388608\n",
    ),
    Arm(
        id="L5",
        path=RUNNER,
        find="\t\t\t--passL:-sSTACK_SIZE=8388608\n",
        replace="",
        grader=G_LANE_TEST,
        killer="the wasm compile raises the stack above emscripten's 64 KB default",
        why="emscripten's default stack is 64 KB against a native thread's "
            "8 MiB, and `test_verification_payload` sits between the two — "
            "dying after 42 of 56 cases with `memory access out of bounds` "
            "and no Nim frame, which reads as a miscompile",
        control_name="the size is written as its arithmetic",
        control_find="--passL:-sSTACK_SIZE=8388608",
        control_replace="--passL:-sSTACK_SIZE=$((8 * 1024 * 1024))",
    ),
    Arm(
        id="L4",
        path=RUNNER,
        find="\t\techo \"ERROR: lane '${lane}' needs the Emscripten toolchain and 'emcc' is not on PATH.\" >&2\n",
        replace="\t\techo \"note: skipping lane '${lane}' (no emcc)\" >&2\n",
        grader=G_LANE_TEST,
        killer="a missing emcc fails the lane by name rather than skipping it",
        why="the refusal that keeps a missing toolchain from reading as a "
            "pass. A lane answering '0 files, nothing to do, exit 0' "
            "satisfies every aggregate above it while measuring nothing — "
            "`vm-js`'s defect wearing a toolchain check",
        control_name="the refusal message is reflowed without changing what it says",
        control_find="needs the Emscripten toolchain and 'emcc' is not on PATH.",
        control_replace="needs the Emscripten toolchain; 'emcc' is not on PATH.",
    ),
    Arm(
        id="J1",
        path=JUSTFILE,
        find="test-vm-unit-wasm-parity: vm-test-prereqs\n",
        replace="test-vm-unit-wasm-parity-DISABLED: vm-test-prereqs\n",
        grader=G_LANE_TEST,
        killer="the count-equality gate exists as its own recipe and script",
        why="the parity RECIPE. `test-vm-unit-wasm` on its own only says the "
            "lane is green, and §2.1.4 is explicit that green is the weaker "
            "claim",
        control_name="the recipe gains a second, redundant prerequisite listing",
        control_find="test-vm-unit-wasm-parity: vm-test-prereqs\n",
        control_replace="test-vm-unit-wasm-parity:  vm-test-prereqs\n",
    ),

    # -------------------------------------------------------------------
    # The exclusion list — ci/lib/test-lane-files.sh, graded by the parity
    # gate's contract 1 in BOTH directions. This is the milestone's own
    # risk section made mechanical: "the build is declared working on a
    # subset of suites, and the subset is never named".
    # -------------------------------------------------------------------
    Arm(
        id="G1",
        path=LANE_FILES,
        find="\t\t\t\t'/test_project_action_runner\\.nim$'\n",
        replace="\t\t\t\t'/test_project_action_runner\\.nim$' \\\n\t\t\t\t'/test_sync\\.nim$'\n",
        grader=G_PARITY_ONE,
        killer="(contract 1 — the documented exclusion set)",
        expect="script-fails",
        why="an UNDOCUMENTED seventh exclusion — a suite leaving the wasm "
            "lane with nobody writing down why, which is the exact shape "
            "PLAT-17's risk section names",
        control_name="the six rejections are reordered",
        control_find="\t\t\t\t'/test_sdk_facade_boundary\\.nim$' \\\n\t\t\t\t'/test_plugin_io_sdk\\.nim$' \\\n",
        control_replace="\t\t\t\t'/test_plugin_io_sdk\\.nim$' \\\n\t\t\t\t'/test_sdk_facade_boundary\\.nim$' \\\n",
    ),
    Arm(
        id="G2",
        path=LANE_FILES,
        # Two lines, not one: the single-line spelling occurs TWICE in this
        # file — the `vm-unit-js` lane rejects the same suite — and an arm
        # whose needle has two targets hits neither (§16's "exactly once, not
        # at least once"). The needle scan caught it on the first run.
        find=("\t\t\t\t'/test_platform_desktop_native\\.nim$' \\\n"
              "\t\t\t\t'/test_project_action_runner\\.nim$'\n"),
        replace="\t\t\t\t'/test_project_action_runner\\.nim$'\n",
        grader=G_PARITY_ONE,
        killer="(contract 1 — the documented exclusion set)",
        expect="script-fails",
        why="a STALE exclusion — a file still on the documented list that "
            "the lane no longer excludes. The other direction of contract 1, "
            "and the one that keeps an exclusion from outliving its reason",
        control_name="the six rejections are reordered",
        control_find="\t\t\t\t'/test_plugin_grant_lifecycle\\.nim$' \\\n\t\t\t\t'/test_plugin_source_admission\\.nim$' \\\n",
        control_replace="\t\t\t\t'/test_plugin_source_admission\\.nim$' \\\n\t\t\t\t'/test_plugin_grant_lifecycle\\.nim$' \\\n",
    ),
    Arm(
        id="G3",
        path=SUITE_ASYNC,
        find="  test \"a void future settles the same way\":\n",
        replace="  when not defined(emscripten):\n   test \"a void future settles the same way\":\n",
        grader=G_PARITY_ONE,
        killer="(contract 2 — the per-file case/assertion equality)",
        expect="script-fails",
        why="a case ELIDED ON WASM ONLY — the milestone's characteristic "
            "defect, a lane whose file set is the same and whose CASE count "
            "quietly is not. Contract 2 is an equality per file precisely so "
            "this cannot be absorbed by a total",
        control_name="the case's body is re-indented without changing it",
        control_find="  test \"a void future settles the same way\":\n",
        control_replace="  test \"a void future  settles the same way\":\n",
    ),

    # -------------------------------------------------------------------
    # The footprint probe — the assertion PLAT-17 had to re-aim twice
    # -------------------------------------------------------------------
    Arm(
        id="F1",
        path=FP_PROBE,
        find="  for s in live:\n    s.dispose()\n  live.setLen(0)\n",
        replace="  for s in live:\n    s.dispose()\n",
        grader=G_FOOTPRINT,
        killer="(the footprint verdict)",
        expect="script-fails",
        why="RETENTION. Every session stays referenced, so ORC's cycle "
            "collector has nothing to reclaim. This is the arm that the "
            "first draft's `steady < peak` SURVIVED — 775,408 steady against "
            "810,864 peak, 95.6%, and still 'below' — and that the FRACTION "
            "(25% of peak) kills. An inequality both mechanisms satisfy is "
            "§10 wearing a comparison operator",
        # `live = @[]`, not `live.delete(0 ..< live.len)`: the slice overload
        # does not compile on Nim 2.2.8, and a control that does not build
        # scores CONTROL-RED over a build failure — a line about the harness
        # where a line about the code belongs.
        control_name="the release is written as a fresh empty sequence",
        control_find="  live.setLen(0)\n",
        control_replace="  live = @[]\n",
    ),
    Arm(
        id="F2",
        path=FP_PROBE,
        find="  for _ in 0 ..< sessionCount:\n    live.add buildOneSession()\n",
        replace="  for _ in 0 ..< 0:\n    live.add buildOneSession()\n",
        grader=G_FOOTPRINT,
        killer="(the peak-delta negative control)",
        expect="script-fails",
        why="A RUN THAT BUILDS NOTHING. Eight sessions allocate nothing, so "
            "the peak delta is zero and the fraction above it grades no "
            "measurement — the negative control on contract 1, without which "
            "a probe that constructed no graph would report a perfect 0% "
            "steady and pass",
        control_name="the session loop counts up from an explicit zero",
        control_find="  for _ in 0 ..< sessionCount:\n",
        control_replace="  for _ in 0 ..< max(sessionCount, 0):\n",
    ),

    # -------------------------------------------------------------------
    # The fake-timer probe — the speed signal, and the guard on it
    # -------------------------------------------------------------------
    Arm(
        id="T1",
        path=FT_PROBE,
        find="      (proc() = inc completed),\n",
        replace="      (proc() = discard),\n",
        grader=G_FAKETIMER,
        killer="(contract 3 — every continuation arrived)",
        expect="script-fails",
        why="CONTINUATIONS THAT NEVER ATTACH. The chain still runs and the "
            "wall time is still a number; nothing arrived. This is the arm "
            "that the ratio alone could not catch, and the reason the probe "
            "refuses to print a ratio unless every continuation arrived",
        control_name="the completion counter is incremented through a named proc",
        control_find="      (proc() = inc completed),\n",
        control_replace="      (proc() = completed = completed + 1),\n",
    ),
    Arm(
        id="T2",
        path=FT_PROBE,
        find="  const MinRatio = 100.0\n",
        replace="  const MinRatio = 1_000_000.0\n",
        grader=G_FAKETIMER,
        killer="(contract 1 — each probe's own verdict)",
        expect="script-fails",
        why="THE MECHANISM THRESHOLD RAISED ABOVE THE MEASUREMENT. 100 sits "
            "between the ~1 a host-timer chain scores and the ~11,000 this "
            "one does; above the measurement the probe reports FAILED over a "
            "chain that is entirely inside the runtime, which is the arm that "
            "says the threshold is a separator rather than a tuning",
        control_name="the threshold is written as a float literal with an exponent",
        control_find="  const MinRatio = 100.0\n",
        control_replace="  const MinRatio = 1.0e2\n",
    ),
]


# ---------------------------------------------------------------------------
# `because` — DERIVED FROM TRANSCRIPTS, NEVER TYPED (§17a, §17b)
# ---------------------------------------------------------------------------
#
# Regenerate with `--collect-because`, which applies each arm, reads the
# failure text its killer actually produced, and prints this block. A string
# typed from the source is a second copy of the code held in a file the
# compiler does not read (§14), and for a `unittest` assertion reached through
# a template the copy and the original are not even in the same language.
BECAUSE = {
    # Every one of these came out of `--collect-because`, which applies the arm
    # and reads the line its killer actually produced. None was typed from a
    # source file. Re-derive after any repair to a subject, a suite or a
    # script: a `because` goes stale exactly as §16's needle does and NO SCAN
    # CAN SEE IT (§17b) — the only instrument is running the arm.
    #
    # THE FOUR NIM ARMS quote `Check failed:` WITH its prefix. The bare
    # rendered expression is not enough: W3's is `platformIsWasm`, which is
    # also a substring of its own case NAME, so the bare form occurs in the
    # GREEN transcript and would be satisfied for free (§17).
    'W1': 'Check failed: seen == 42',
    'W2': 'Check failed: due.finished',
    'W3': 'Check failed: platformIsWasm',
    'W4': 'Check failed: order == @[1, 2]',
    #
    # P1 HAS NO `Check failed:` AT ALL, and that is the arm. The mutant dies in
    # `common/paths.nim`'s module initialiser before `unittest` prints a line,
    # so its only evidence is the trap — taken WITHOUT the `wasm://wasm/…`
    # module address printed beneath it, which changes on every compilation and
    # is §17a's gensym number in a different runtime.
    'P1': 'RuntimeError: memory access out of bounds',
    #
    # THE SIX SCRIPT-CONTRACT ARMS quote the whole `FAIL:` line. The contract
    # NAME alone appears in a green run too, as `ok — <name>`.
    'L1': 'vm-unit-wasm-lane-test: FAIL: the wasm compile passes --mm:orc explicitly',
    'L2': 'vm-unit-wasm-lane-test: FAIL: the wasm compile passes -sEXIT_RUNTIME=1',
    'L3': "vm-unit-wasm-lane-test: FAIL: the wasm compile uses node's real filesystem (-sNODERAWFS=1)",
    'L4': 'vm-unit-wasm-lane-test: FAIL: a missing emcc fails the lane by name rather than skipping it',
    'L5': "vm-unit-wasm-lane-test: FAIL: the wasm compile raises the stack above emscripten's 64 KB default",
    'J1': 'vm-unit-wasm-lane-test: FAIL: the count-equality gate exists as its own recipe and script',
    #
    # G1 AND G2 ARE THE TWO DIRECTIONS OF ONE CONTRACT and print the SAME
    # `FAIL:` text. Only the file listed under `undocumented:` or under
    # `stale:` says which direction fired, which is why these two carry the
    # indented path block and the others do not.
    'G1': 'FAIL: vm-unit \\ vm-unit-wasm is not the documented set\n      undocumented (in the difference, not in the list):\n        src/frontend/viewmodel/tests/unit/test_sync.nim\n      stale (in the list, not in the difference):',
    'G2': 'FAIL: vm-unit \\ vm-unit-wasm is not the documented set\n      undocumented (in the difference, not in the list):\n      stale (in the list, not in the difference):\n        src/frontend/viewmodel/tests/unit/test_platform_desktop_native.nim',
    #
    # G3 is the milestone's own sentence, mechanically produced: `contract 2
    # reports 12/23/0 against 10/23/1`.
    'G3': 'FAIL: src/frontend/viewmodel/tests/unit/test_async_compat_wasm_arm.nim: native 12 case(s)/23 assertion(s)/0 failed, wasm 10/23/1',
    #
    # THE FOUR PROBE ARMS quote the probe's own `*-VERDICT FAILED` statement of
    # the EFFECT, with the MEASUREMENT that led to it dropped: the full lines
    # read `steady is 95% of peak (limit 25%): …` and `ratio 17695.2 is below
    # 1000000.0: …`, and both numbers move on every run. A `because` carrying
    # one is wrong INTERMITTENTLY, which §17a names as worse than either wrong
    # or right.
    'F1': 'releasing every session reclaimed almost nothing',
    'F2': 'nothing was allocated, so there is no reclamation to measure',
    'T1': 'the elapsed time above measures a chain that did not run',
    'T2': 'the fake clock is not driving the whole chain — something in it is waiting on a real timer',
}


# ---------------------------------------------------------------------------
# Result parsing
# ---------------------------------------------------------------------------

# EVERY TRANSCRIPT IS STRIPPED OF ANSI BEFORE ANYTHING READS IT, and this is
# trap 4 rather than a formatting nicety. `std/unittest` colourises its result
# lines whenever the build has not been told otherwise, so the bytes are
#
#     ESC[1mESC[32m  [OK] ESC[0mplatformIsWasm agrees with …ESC[0m
#
# — and `^\s*\[(OK|FAILED)\]` matches NONE of them. The first version of this
# harness reported `CONTROL IS NOT GREEN: … produced no result lines at all`
# over a suite that had just printed twelve green ones: a scanner that finds
# nothing, passing every "must not contain" check and failing every "must".
# Caught on the first smoke run only because the pre-flight prints the
# transcript it refused on.
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_ansi(s: str) -> str:
    return ANSI.sub("", s)


NIM_RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")

# The four bash contract scripts. Two marker vocabularies, both one line:
#   ci/test/vm-unit-wasm-lane-test.sh   `  ok — <text>`   `…: FAIL: <text>`
#   the other three                     `  ok: <text>`    `  FAIL: <text>`
SH_OK_LINE = re.compile(r"^\s*ok(?:\s+—|:)\s+(.*?)\s*$")
SH_FAIL_LINE = re.compile(r"^(?:\s*|.*?: )FAIL:\s+(.*?)\s*$")

CHECK_FAILED = re.compile(r"Check failed:\s*(.*?)\s*$")
# A Nim traceback frame carries an absolute path, so it is host-specific and
# must never become a `because`.
TRACEBACK_FRAME = re.compile(r"^\S*\.nim\(\d+\)\s+\S+\s*$")


@dataclass
class RunResult:
    rc: int
    passed: list = field(default_factory=list)
    failed: list = field(default_factory=list)
    ran: bool = True
    built: bool = True
    failure_text: dict = field(default_factory=dict)
    transcript: str = ""

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


# THE PROBE'S OWN VERDICT LINE, which is the strongest evidence either probe
# produces: `FOOTPRINT-VERDICT\tFAILED\tsteady is 95% of peak (limit 25%)…`
# and `FAKETIMER-VERDICT\tFAILED\tratio 0.9 is below 100.0…`. §17a's closing
# rule — prefer a `because` that quotes the EFFECT over one that quotes a
# report — and here it is also what keeps two arms apart: F1 and F2 both make
# the probe `quit(1)`, so the SCRIPT's first `FAIL:` is the same generic
# "the native probe exited 1" line for both. One `because` shared by two arms
# is §5a in the evidence rather than in the code: two events with different
# remedies behind one string, and either arm would then be attributed to the
# other's mutation.
# The leading `\s*` is not decoration: `ci/test/wasm-footprint.sh` re-prints
# the probe's rows INDENTED under its own `FAIL:` line, so an anchored
# pattern matched none of them and F1 and F2 both fell through to the
# script's generic "the native probe exited 1" line — one `because` for two
# arms, which the duplicate refusal below exists to catch and which this
# character is what stops happening in the first place.
PROBE_VERDICT = re.compile(r"^\s*[A-Z-]+-VERDICT\tFAILED\t(.*?)\s*$")

# A wasm trap. `RuntimeError: memory access out of bounds` is P1's whole
# evidence, and the line BELOW it — `wasm://wasm/0012f3a2:1` — is a module
# address that changes with every recompilation, which is §17a's gensym number
# in a different runtime. The first `--collect-because` run derived exactly
# that address for P1; this pattern is why it no longer can.
WASM_TRAP = re.compile(r"^\s*(RuntimeError: .*?)\s*$")


def derived_because(text: str) -> str:
    """The most specific stable evidence in a failure transcript.

    Derived, never typed (§17a's second rule applied to itself): revert the
    repair, run the killer, and read the line out of the transcript. A
    `because` typed from the source is a second copy of the code held in a file
    the compiler does not read (§14), and for a `unittest` assertion reached
    through a template the copy and the original are not even written in the
    same language.

    The ORDER is the whole content of this function, and each rung was put
    there by an arm that would otherwise have been mis-attributed:

      1. the probe's own `*-VERDICT FAILED` line — the EFFECT (§17a), and what
         separates F1 from F2 and T1 from T2;
      2. a wasm trap — P1's only evidence, taken WITHOUT the module address
         printed beneath it, which is not stable across compilations;
      3. a `unittest` `Check failed:` line, prefix included so the string is a
         quotation of a FAILURE rather than of a word (W3's bare
         `platformIsWasm` is a substring of its own case NAME and therefore
         occurs in the GREEN transcript);
      4. a script's `FAIL:` line TOGETHER WITH its indented detail lines —
         G1 and G2 are the two directions of ONE contract and print the same
         `FAIL:` text, and only the indented block below it says which
         direction fired;
      5. last resort, the first informative line, with module addresses and
         absolute paths excluded.
    """
    lines = text.splitlines()
    for line in lines:
        m = PROBE_VERDICT.match(line)
        if m:
            # THE TAIL, AFTER THE FIRST COLON — the probe's statement of the
            # EFFECT, with the MEASUREMENT that led to it dropped. The full
            # line reads `ratio 17695.2 is below 1000000.0: the fake clock is
            # not driving the whole chain`, and `17695.2` is a wall-clock
            # measurement that is different on every run: a `because` carrying
            # it is not merely wrong, it is wrong INTERMITTENTLY, which §17a
            # names as worse than either wrong or right. `steady is 95% of
            # peak` is the same hazard one arm along.
            #
            # The residual, named rather than papered over: T2's tail is the
            # text a GENUINE mechanism regression would also print, so that
            # arm's discrimination rests on its needle and its control rather
            # than on its `because` alone. The alternative — quoting the
            # threshold the arm itself installed — would be a `because`
            # derived from the harness instead of from the transcript.
            body = m.group(1)
            head, sep, tail = body.partition(": ")
            return tail.strip() if sep and tail.strip() else body
    for line in lines:
        m = WASM_TRAP.match(line)
        if m:
            return m.group(1)
    for line in lines:
        m = CHECK_FAILED.search(line)
        if m and not TRACEBACK_FRAME.match(line):
            return f"Check failed: {m.group(1)}"
    for i, line in enumerate(lines):
        m = SH_FAIL_LINE.match(line)
        if not m:
            continue
        # THE WHOLE `FAIL:` LINE, not the contract name inside it. Every one of
        # the four scripts prints a passing contract as `ok — <name>` and a
        # failing one as `FAIL: <name>`, so the NAME alone occurs in a GREEN
        # run — and the pre-flight's "this `because` is true for free" guard
        # rejected all six lane-test arms on exactly that ground. The marker is
        # the evidence; the name is the subject.
        block = [line.strip()]
        base = len(line) - len(line.lstrip())
        # …plus the PATHS the failure names beneath it, and nothing else. G1
        # and G2 are the two DIRECTIONS of one contract and print identical
        # `FAIL:` text; only the file listed under `undocumented:` or under
        # `stale:` says which fired. Prose continuation lines are excluded
        # deliberately — a `because` that quotes a script's explanatory text
        # goes stale on a reword, which is §17b with nothing gained.
        for nxt in lines[i + 1:i + 8]:
            if not nxt.strip():
                break
            if len(nxt) - len(nxt.lstrip()) <= base:
                break
            t = nxt.strip()
            if t.endswith(".nim") and "/" in t:
                block.append(nxt.rstrip())
            elif t.endswith(":"):
                block.append(nxt.rstrip())
        return "\n".join(block)
    for line in lines:
        s = line.strip()
        if (s and not TRACEBACK_FRAME.match(line) and not s.startswith("/")
                and not s.startswith("wasm://")):
            return s[:160]
    return ""


def parse_nim(out: str, rc: int, built: bool) -> RunResult:
    out = strip_ansi(out)
    res = RunResult(rc=rc, built=built, transcript=out)
    if not built:
        res.ran = False
        return res
    # EVERYTHING SINCE THE LAST RESULT LINE BELONGS TO THE NEXT ONE.
    # `unittest` prints a failing check's location, its rendered condition and
    # its operands BEFORE the `[FAILED] <name>` line that closes the case.
    pending: list[str] = []
    for line in out.splitlines():
        m = NIM_RESULT_LINE.match(line)
        if not m:
            pending.append(line)
            continue
        name = m.group(2)
        if m.group(1) == "OK":
            res.passed.append(name)
        else:
            res.failed.append(name)
            res.failure_text[name] = "\n".join(pending)
        pending = []
    res.ran = bool(res.passed or res.failed)
    return res


# A SCRIPT'S GREEN PATH NEED NOT PRINT A MARKER PER CONTRACT, and one of the
# four does not: `ci/test/wasm-footprint.sh` prints its table, one terminal
# verdict line, and no `ok:` at all. Reading `ran` off the markers alone
# reported `CONTROL IS NOT GREEN: wasm-footprint produced no result lines` over
# a run that had just measured both targets and passed — the harness calling a
# green instrument dead, which is exactly the mislabel `ran` exists to prevent
# in the other direction. So a script also "ran" if it reached its own terminal
# summary line, and each of the four is named here rather than matched by a
# loose pattern: an over-broad terminal regex would make a crashed script read
# as a run with nothing to say.
SCRIPT_TERMINAL = re.compile(
    r"^(?:wasm-footprint|wasm-fake-timer-speed|vm-unit-wasm parity"
    r"|vm-unit-wasm-lane-test|contracts|test-vm-unit-wasm lane)\b", re.M)


def parse_script(out: str, rc: int) -> RunResult:
    out = strip_ansi(out)
    res = RunResult(rc=rc, transcript=out)
    for line in out.splitlines():
        m = SH_OK_LINE.match(line)
        if m:
            res.passed.append(m.group(1))
            continue
        m = SH_FAIL_LINE.match(line)
        if m:
            res.failed.append(m.group(1))
            res.failure_text[m.group(1)] = out
    res.ran = bool(res.passed or res.failed
                   or SCRIPT_TERMINAL.search(out))
    return res


# ---------------------------------------------------------------------------
# Graders
# ---------------------------------------------------------------------------

def _env(extra: dict) -> dict:
    e = dict(os.environ)
    e.update(extra)
    return e


def run_grader(g: Grader) -> RunResult:
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    if g.kind == "script":
        proc = subprocess.run(["bash", g.target, *g.argv], cwd=ROOT,
                              capture_output=True, text=True,
                              errors="replace", env=_env(g.env), timeout=5400)
        return parse_script(proc.stdout + proc.stderr, proc.returncode)

    stem = Path(g.target).stem
    cache = CACHE_ROOT / f"{g.kind}-{stem}"
    if g.kind == "nim-wasm":
        artifact = cache.with_suffix(".js")
        cmd = ["nim", "c", "--hints:off", "--warnings:off", *wasm_flags(),
               "--path:src/frontend/viewmodel",
               f"--nimcache:{cache}", f"-o:{artifact}", g.target]
        run_cmd = ["node", str(artifact)]
    else:
        artifact = cache.with_suffix(".bin")
        cmd = ["nim", "c", "--hints:off", "--warnings:off", "--mm:orc",
               "--path:src/frontend/viewmodel",
               f"--nimcache:{cache}", f"-o:{artifact}", g.target]
        run_cmd = [str(artifact)]

    build = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                           errors="replace", env=_env(g.env), timeout=5400)
    if build.returncode != 0:
        return parse_nim(build.stdout + build.stderr, build.returncode, built=False)
    # `2>&1` matters here more than usual: emscripten writes its
    # `warning: unsupported syscall` diagnostics to stderr, and a trap prints
    # its `RuntimeError: memory access out of bounds` there too — which is the
    # ONLY evidence arm P1 produces.
    proc = subprocess.run(run_cmd, cwd=ROOT, capture_output=True, text=True,
                          errors="replace", env=_env(g.env), timeout=5400)
    return parse_nim(proc.stdout + proc.stderr, proc.returncode, built=True)


# ---------------------------------------------------------------------------
# Digests, the lock, and the needle scan
# ---------------------------------------------------------------------------

def digest(rel: str) -> str:
    return hashlib.sha256((ROOT / rel).read_bytes()).hexdigest()


def repo_of(rel: str) -> Path:
    """The git repo a `TOUCHED` entry lives in.

    `TOUCHED` names a path in the SIBLING repo `nim-everywhere` (see the
    header), so neither the digest sweep nor the §16b enumeration may assume
    one repository.
    """
    p = (ROOT / rel).resolve()
    d = p.parent
    while d != d.parent:
        if (d / ".git").exists():
            return d
        d = d.parent
    return ROOT


def read_control_hashes() -> dict:
    if not CONTROL_HASHES.exists():
        return {}
    out = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        h, _, p = line.partition("  ")
        out[p] = h
    return out


def write_control_hashes() -> None:
    lines = [
        "# Control digests for run-plat17-wasm-mutations.py.",
        "#",
        "# The bytes every arm restores to, and the bytes every arm's verdict",
        "# was taken against. Both halves of TOUCHED are here — the eight",
        "# mutation subjects AND the six suites/scripts the arms are graded by",
        "# — which is §16c's gap paid rather than inherited.",
        "#",
        "# One entry is OUTSIDE THIS REPOSITORY:",
        "# ../nim-everywhere/src/nim_everywhere/async_compat.nim, the sibling",
        "# checkout config.nims puts on the Nim path. PLAT-17's diff spans",
        "# three repos and the arms that matter most are in the other one.",
        "#",
        "# Refreshed with --record-control-hashes, which the needle scan GATES",
        "# (§16): re-recording from a tree whose arms have stopped matching",
        "# certifies the arms along with the bytes.",
    ]
    for p in TOUCHED:
        lines.append(f"{digest(p)}  {p}")
    CONTROL_HASHES.write_text("\n".join(lines) + "\n")


def needle_scan() -> list[str]:
    """Every arm whose `find` or `control_find` does not occur EXACTLY ONCE.

    Exactly once, not at least once: an arm whose needle occurs twice has two
    targets and hits neither (§16).
    """
    bad = []
    for a in ARMS:
        text = (ROOT / a.path).read_text()
        n = text.count(a.find)
        if n != 1:
            bad.append(f"{a.id:<4} find occurs {n}x in {a.path}")
        n = text.count(a.control_find)
        if n != 1:
            bad.append(f"{a.id:<4} control_find occurs {n}x in {a.path}")
    return bad


def report_needle_scan() -> int:
    bad = needle_scan()
    if bad:
        print("NEEDLE SCAN: an arm has stopped quoting code that exists.")
        print("  A quotation that no longer matches is a row in the table that")
        print("  looks like coverage and can never be killed (§16).")
        for b in bad:
            print("   ", b)
        return 2
    print(f"needle scan: all {len(ARMS)} arms' find and control_find resolve "
          "to exactly one site")
    return 0


def enumerate_touched() -> int:
    """§16b: intersect `TOUCHED` with the diff BEING COMMITTED, per repo.

    The subject set is the COMMIT's, not the session's — and `-uall`, because
    untracked files are in the diff being committed and a porcelain call
    without it reports a DIRECTORY for a new tree and misses every file under
    it.
    """
    repos: dict[Path, list] = {}
    for p in TOUCHED:
        repos.setdefault(repo_of(p), []).append(p)
    total = 0
    for repo, paths in sorted(repos.items()):
        proc = subprocess.run(["git", "status", "--porcelain", "-uall"],
                              cwd=repo, capture_output=True, text=True)
        diff = {line[3:] for line in proc.stdout.splitlines() if line[3:]}
        print(f"{repo.name}: {len(diff)} path(s) in the diff being committed")
        for p in sorted(paths):
            rel = os.path.relpath((ROOT / p).resolve(), repo)
            mark = "OVERLAPS" if rel in diff else "clean   "
            if rel in diff:
                total += 1
            print(f"  {mark}  {rel}")
    print(f"\n{total} of {len(TOUCHED)} TOUCHED entries are in the diff.")
    print("An overlapping harness has two dispositions — re-run, or")
    print("deliberately deferred with a reason — and neither is absence "
          "from a list.")
    return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    only = None
    for a in argv:
        if a.startswith("--only="):
            only = {s.strip() for s in a[len("--only="):].split(",")}
    arms = [a for a in ARMS if only is None or a.id in only]

    if "--needle-scan" in argv:
        return report_needle_scan()
    if "--enumerate-touched" in argv:
        return enumerate_touched()

    # THE LOCK IS TAKEN BEFORE THE BASELINE DIGESTS ARE READ. A second run
    # starting between the read and the first mutation would record a mutated
    # file as the control bytes. `flock` rather than a pidfile, and never
    # `pgrep -f`: a `pgrep` pattern matches the auditor reading this file.
    lock_fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"another run holds {LOCK}. Never two harnesses at once.")
        return 2

    try:
        collecting = "--collect-because" in argv

        rc = report_needle_scan()
        if rc:
            return rc

        if "--record-control-hashes" in argv:
            # GATED BY THE SCAN ABOVE (§16). The natural next step after a
            # repair is to re-bless the baseline; doing that first leaves the
            # harness perfectly consistent with a tree in which some of its
            # arms describe nothing.
            write_control_hashes()
            print(f"recorded {len(TOUCHED)} control digest(s) to "
                  f"{CONTROL_HASHES.name}")
            return 0

        recorded = read_control_hashes()
        if not recorded:
            print(f"no {CONTROL_HASHES.name}; run --record-control-hashes "
                  "first (the needle scan gates it).")
            return 2
        drift = [(p, recorded.get(p), digest(p))
                 for p in TOUCHED if recorded.get(p) != digest(p)]
        if drift:
            print("TREE IS NOT AT THE CONTROL BYTES — nothing was mutated.")
            for p, want, got in drift:
                print(f"  {p}\n      recorded {want}   on disk {got}")
            return 2
        baseline = {p: recorded[p] for p in TOUCHED}

        # PRE-FLIGHT, over the UNMUTATED tree: every grader green, every
        # killer resolving to exactly one case that is currently passing, and
        # every `because` ABSENT from the passing run. A `because` that already
        # occurs in a green run is true for free.
        graders = []
        for a in arms:
            if a.grader not in graders:
                graders.append(a.grader)
            if a.spare_grader is not None and a.spare_grader not in graders:
                graders.append(a.spare_grader)
        control_runs = {}
        print("\n--- control pre-flight (the unmutated tree) ---", flush=True)
        for g in graders:
            res = run_grader(g)
            control_runs[id(g)] = res
            if not res.ran:
                print(f"CONTROL IS NOT GREEN: {g.label} produced no result "
                      "lines at all. Nothing below would mean anything.")
                print(res.transcript[-3000:])
                return 2
            if res.failed:
                print(f"CONTROL IS NOT GREEN: {g.label} -> {res.failed}")
                return 2
            print(f"  {g.label:<42} {res.total} result line(s), 0 failed",
                  flush=True)

        for a in arms:
            ctl = control_runs[id(a.grader)]
            if a.expect == "case" and a.killer not in ctl.passed:
                near = [c for c in ctl.passed if a.killer.lower() in c.lower()]
                print(f"{a.id}: killer {a.killer!r} is not a passing case of "
                      f"{a.grader.label}. Near: {near[:3]}")
                return 2
            b = BECAUSE.get(a.id, "")
            if b and b in ctl.transcript:
                print(f"{a.id}: its `because` already occurs in the GREEN run "
                      "— it would be satisfied for free (§17).")
                return 2

        print(f"\n--- {len(arms)} arm(s) ---", flush=True)
        problems = 0
        collected = {}
        for a in arms:
            path = ROOT / a.path
            original = path.read_text()
            if original.count(a.find) != 1:
                print(f"{a.id:<5} HARNESS-FAILURE  the needle stopped "
                      f"resolving mid-run in {a.path}")
                return 2
            path.write_text(original.replace(a.find, a.replace))
            try:
                res = run_grader(a.grader)
                spare = (run_grader(a.spare_grader)
                         if a.spare_grader is not None else None)
            finally:
                path.write_text(original)
                # PER ARM, not once at the end. An arm that left a file dirty
                # must be named where it happened, because every verdict after
                # it is otherwise suspect — and one of these files is in a
                # sibling repository.
                for p in TOUCHED:
                    if digest(p) != baseline[p]:
                        print(f"{a.id:<5} HARNESS-FAILURE  {p} did not restore "
                              "to its control bytes")
                        return 2

            note = ""
            if not res.built:
                verdict, note = "HARNESS-FAILURE", "the target did not build"
                problems += 1
            elif a.expect == "script-fails":
                # THE KILL IS THAT THE INSTRUMENT REFUSED, and the arm is
                # attributed by the refusal's own text. Used where a script's
                # green path prints no marker the arm could name as a "case"
                # that must go red — the parity gate's contract 1, and the
                # footprint and fake-timer probes, whose contracts are `FAIL:`
                # lines rather than a green roll-call.
                if not res.failed:
                    verdict, note = "SURVIVED", "the script reported no failure"
                    problems += 1
                elif collecting:
                    verdict = "collected"
                    note = derived_because(res.transcript) or "(nothing)"
                    if note != "(nothing)":
                        collected[a.id] = note
                elif not BECAUSE.get(a.id, ""):
                    verdict = "killed (UNATTRIBUTED)"
                    note = "no `because`; run --collect-because"
                    problems += 1
                elif BECAUSE[a.id] not in res.transcript:
                    verdict = "MIS-ATTRIBUTED"
                    note = (f"{BECAUSE[a.id]!r} not in the transcript; it "
                            f"said: {derived_because(res.transcript)}")
                    problems += 1
                else:
                    verdict = "killed"
                    # The ATTRIBUTED evidence, not the script's first `FAIL:`
                    # line. For the four probe arms those are different
                    # strings, and printing the first one would put F1's and
                    # F2's identical generic line in the transcript that is
                    # supposed to show they were told apart.
                    note = BECAUSE[a.id].splitlines()[0][:76]
            elif a.expect == "suite-dies":
                # The kill IS the absence of result lines. See P1.
                if res.ran:
                    verdict = "SURVIVED"
                    note = (f"the run still printed {res.total} result line(s); "
                            "the initialiser did not die")
                    problems += 1
                elif collecting:
                    verdict = "collected"
                    note = derived_because(res.transcript) or "(nothing)"
                    if note != "(nothing)":
                        collected[a.id] = note
                else:
                    b = BECAUSE.get(a.id, "")
                    if not b:
                        verdict = "killed (UNATTRIBUTED)"
                        note = "no `because`; run --collect-because"
                        problems += 1
                    elif b not in res.transcript:
                        verdict = "MIS-ATTRIBUTED"
                        note = (f"{b!r} not in the transcript; it said: "
                                + derived_because(res.transcript))
                        problems += 1
                    else:
                        verdict = "killed"
                        note = "no result line at all — the module initialiser died"
            elif not res.ran:
                verdict, note = "SUITE-DIED", ("the target built and printed no "
                                               "result line at all")
                problems += 1
            elif a.killer not in res.passed and a.killer not in res.failed:
                # §1a's mirror: the mutant died INSIDE the named case, before
                # its result line. Not a survival — the run told you nothing.
                verdict = "NO-VERDICT-FOR-KILLER"
                note = (f"{a.killer[:44]!r} reported neither [OK] nor [FAILED]; "
                        f"{len(res.failed)} other case(s) failed")
                problems += 1
            elif not res.failed:
                verdict, note = "SURVIVED", "no case noticed"
                problems += 1
            elif a.killer in res.failed:
                text = res.failure_text.get(a.killer, "")
                broke = [c for c in a.spares if spare and c in spare.failed]
                if collecting:
                    verdict = "collected"
                    note = derived_because(text) or "(no failure text)"
                    if note != "(no failure text)":
                        collected[a.id] = note
                elif broke:
                    verdict = "SPARED-CASE-DIED"
                    note = f"{broke} should have stayed green under {a.id}"
                    problems += 1
                elif not BECAUSE.get(a.id, ""):
                    verdict = "killed (UNATTRIBUTED)"
                    note = a.killer[:44] + "  — no `because`; run --collect-because"
                    problems += 1
                elif BECAUSE[a.id] not in text:
                    verdict = "MIS-ATTRIBUTED"
                    note = (f"{BECAUSE[a.id]!r} not in the failure text; it "
                            f"said: {derived_because(text)}")
                    problems += 1
                else:
                    others = [f for f in res.failed if f != a.killer]
                    verdict = "killed"
                    note = (a.killer[:44] +
                            (f"  (+{len(others)} more)" if others else "") +
                            (f"  [spared {len(a.spares)} green]" if a.spares else ""))
            else:
                verdict = "MISDIRECTED"
                note = f"died in {res.failed[:2]}, not {a.killer!r}"
                problems += 1

            print(f"{a.id:<5} {a.grader.label[:34]:<34} {verdict:<22} {note}",
                  flush=True)

        if collecting:
            # TWO ARMS MAY NOT SHARE ONE `because`. A string that two
            # mutations both produce cannot attribute either of them, and the
            # harness would report `killed` for an arm whose case died for the
            # other arm's reason — §17's mis-attribution with the detector
            # disarmed. §5a is the same shape one layer down: two events with
            # different remedies behind one value.
            dupes = {}
            for k, v in collected.items():
                dupes.setdefault(v, []).append(k)
            shared = {v: ks for v, ks in dupes.items() if len(ks) > 1}
            print("\n# paste into BECAUSE:")
            for k, v in collected.items():
                print(f"    {k!r}: {v!r},")
            if shared:
                print("\nREFUSING: these arms derived the SAME `because`, so "
                      "neither can be attributed:")
                for v, ks in shared.items():
                    print(f"  {ks} -> {v!r}")
                print("  Aim `derived_because` at evidence only one of them "
                      "produces; do not type one in.")
                return 2
            return 0

        # THE CONTROLS. Each is behaviour-preserving and must leave its grader
        # green. Without them an arm cannot distinguish "the mutation broke the
        # property" from "any edit to this file breaks the build".
        print(f"\n--- {len(arms)} behaviour-preserving control(s) ---", flush=True)
        for a in arms:
            path = ROOT / a.path
            original = path.read_text()
            if original.count(a.control_find) != 1:
                print(f"{'':<5} CONTROL-HARNESS-FAILURE  {a.id}'s control "
                      f"needle stopped resolving in {a.path}")
                problems += 1
                continue
            path.write_text(original.replace(a.control_find, a.control_replace))
            try:
                res = run_grader(a.grader)
            finally:
                path.write_text(original)
                for p in TOUCHED:
                    if digest(p) != baseline[p]:
                        print(f"{a.id:<5} CONTROL-HARNESS-FAILURE  {p} did not "
                              "restore to its control bytes")
                        return 2
            if not res.ran:
                print(f"{a.id:<5} CONTROL-DID-NOT-RUN      {a.control_name}")
                problems += 1
            elif res.failed:
                print(f"{a.id:<5} CONTROL-RED              {a.control_name} "
                      f"-> {res.failed[:2]}")
                problems += 1
            else:
                print(f"{a.id:<5} control green            {a.control_name}",
                      flush=True)

        print(f"\n{len(arms)} arms, {problems} problems")
        return 1 if problems else 0
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
