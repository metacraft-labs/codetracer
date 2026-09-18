#!/usr/bin/env python3
"""Mutation harness for PLAT-8's plugin I/O SDK and its capability sandbox.

WHAT THIS COVERS. The part of Extensibility-Model.md §8 that is a security
boundary rather than a convenience: the capability policy
(`plugin_model/capabilities.nim`), the load-time validation that refuses a
grant nobody can inspect (`plugin_model/manifest.nim`), the SDK that takes the
decision on every spawn and every connect (`plugin_host/plugin_io.nim`), the
handle accounting deactivation sweeps (`plugin_host/handles.nim`,
`plugin_host/host.nim`), and the two boundary gates that hold both the plugin
and the SDK to "no synchronous form of any I/O call".

IT IS A SEPARATE FILE FROM `run-plat7-boundary-mutations.py` ON PURPOSE. That
harness grades PLAT-7's reactive boundary and its recorded control digests
cover PLAT-7's four files; this one grades PLAT-8's seven. Merging them would
mean one `--record-control-hashes` step re-blessing both campaigns' subjects at
once, which is exactly the "I changed the gate on purpose" / "a killed run left
debris" distinction the recorded digests exist to keep.

THREE VERDICTS, NOT TWO (Verification-Harness-Traps §1a). An arm that never ran
is not a kill:

  killed          the named case reported [FAILED] / FAIL
  SURVIVED        the run produced result lines and the named case was green
  HARNESS-FAILURE the mutation did not apply, did not compile, or the run
                  produced NO result lines at all

Verdicts are parsed out of `[OK]` / `[FAILED]` and `ok` / `FAIL` RESULT LINES,
never out of an exit status: `nim c -r` returns the same non-zero code for a
compile error, a failed assertion and an OOM.

EVERY KILL ARM CARRIES A NAMED BEHAVIOUR-PRESERVING CONTROL in the same file,
applied on its own, which must leave the suite GREEN. Without it a red arm
proves only that the file was touched.

DECLARED SURVIVORS ARE DECLARED, WITH THE REASON — AND THERE ARE NONE NOW.
This harness shipped with one, D1: the SECOND capability pass, removed at its
call site, on the reason that "a hermetic suite cannot make the resolver
disagree with the literal". A verification pass on 2026-09-08 killed it in one
line — `127.1` classifies `acRemote` and glibc resolves it to `127.0.0.1`, so
pass one permits and pass two refuses, with no /etc/hosts edit and no DNS. It
is arm V3 now. The empty `DECLARED_SURVIVORS` list carries the story, because
the general lesson is worth more than the arm: before declaring a survivor,
ask whether the case you cannot construct has a MIRROR you can.

THE V-ARMS ARE THAT PASS'S SIX FINDINGS, one repair each (F1 and F2 and F4 and
F5 take two arms apiece, at the policy level and end to end, or because the
repair itself has two halves). Each was pre-flighted by reverting its repair
and recording which cases went red, before being written down here.

ONLY ONE INSTANCE MAY RUN IN A WORKTREE, enforced with an exclusive `flock`
taken BEFORE the control-hash check. Two instances each restore from their own
in-memory snapshot, so the loser writes back bytes the winner had already
mutated and every verdict after that point grades a file nobody chose. The
recorded digests do not catch it: they are checked once, when both instances
are looking at a clean tree.

THE CONTROL HASHES ARE RECORDED ON DISK, NOT TAKEN AT START-UP. A baseline
taken at start-up cannot tell a clean tree from one a killed run left a
mutation in — it reads the mutation as the baseline, and every restore then
verifies against the mutated bytes.

Usage (from the repository root):
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat8-io-mutations.py

`-u` matters when the output is redirected: a full run is tens of minutes and
python otherwise block-buffers stdout, so a log stays EMPTY until the last arm.

Arms naming one case are run individually:
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat8-io-mutations.py P4 P12
"""

from __future__ import annotations

import fcntl
import hashlib
import os
import re
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]

# --- the files an arm may touch -------------------------------------------

CAPS = "src/common/plugin_model/capabilities.nim"
MANIFEST = "src/common/plugin_model/manifest.nim"
IO = "src/frontend/viewmodel/plugin_host/plugin_io.nim"
HANDLES = "src/frontend/viewmodel/plugin_host/handles.nim"
HOST = "src/frontend/viewmodel/plugin_host/host.nim"
GATE = "ci/test/plugin-reactive-boundary.sh"
SDK_GATE = "ci/test/sdk-facade-boundary.sh"

CAPS_SUITE = "src/common/plugin_capabilities_test.nim"
IO_SUITE = "src/frontend/viewmodel/tests/unit/test_plugin_io_sdk.nim"
GATE_SUITE = "ci/test/plugin-reactive-boundary-test.sh"
SDK_GATE_SUITE = "ci/test/sdk-facade-boundary-test.sh"

# PLAT-8's SOURCE-admission policy: the std import allow-list and the denied FFI
# pragmas. Added 2026-09-09 with the A-arms below.
ADMISSION = "src/common/plugin_model/source_admission.nim"
ADMISSION_SUITE = "src/frontend/viewmodel/tests/unit/test_plugin_source_admission.nim"
ALLOWLIST_SUITE = "src/common/plugin_source_admission_test.nim"

TOUCHED = [CAPS, MANIFEST, IO, HANDLES, HOST, GATE, SDK_GATE, ADMISSION]

CONTROL_HASHES = HERE / "plat8-io-mutation-control.sha256"
LOCK_PATH = HERE / ".plat8-io-mutation.lock"

NIM_RESULT = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*)$")
BASH_RESULT = re.compile(r"^\s*(ok|FAIL)\s+(.*)$")


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def acquire_lock():
    """Take the exclusive run lock, or explain who holds it and refuse."""
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


# --- the case names, spelled once ------------------------------------------
#
# A typo here shows up as "the killer resolves to 0 green cases" in the
# pre-flight rather than as a silently unkillable arm.

# `src/common/plugin_capabilities_test.nim`
C_LOOPBACK = "loopback literals are loopback, in both families"
C_LOCALHOST = "'localhost' is refused BY NAME rather than assumed to be loopback"
C_NAMED_NOT_PATHED = "an executable is named, not pathed"
C_UNDECLARED_EXE = "an undeclared program is refused and the declared set is printed"
C_NO_IMPLY = "the trace-egress grant is implied by no capability subset"
C_NEITHER_ALONE = "neither capability alone carries the weight"
C_STATEMENT = "an acknowledgement without a statement is not a grant"
C_PAIR_LOAD = ("the pair without the grant does not load, and the error is the "
               "disclosure")
C_MIRROR = "declared executables without 'process' is the mirror error"
C_SECOND_PASS = "a name that resolves off the machine is refused for socket:local"
C_NO_REDEMAND = "the second pass does NOT re-demand the declared host"
C_REMOTE_NOT_LOCAL = "socket:remote does not reach loopback"
C_LOCAL_NOT_REMOTE = "socket:local does not reach beyond loopback"
C_WITH_GRANT = "the pair with the grant is permitted, and it is the grant that did it"
C_DOTDOT_NAME = "a '..' inside a NAME is not a '..' segment"
I_REMOTE_UNDECLARED = "socket:remote without the host declared is still refused"

# `src/frontend/viewmodel/tests/unit/test_plugin_io_sdk.nim`
I_SHELL = "naming a shell is refused, and the attempt is what asserts it"
I_PATHY = "a path is refused even when the basename is declared"
I_NONLOOPBACK = "the attempt is refused, and no socket was opened to make it"
I_TEARDOWN = ("no surviving child and no leaked socket, after a mid-operation "
              "teardown")
I_DEACTIVATE_ALL = ("deactivateAll leaves nothing behind, for a plugin that "
                    "closed nothing")
I_RECLAIM = "reclaim releases the resources and leaves the plugin ALIVE"
I_TRACE_FS = "fs:read is not a way around 'trace'"
I_CHECKPOINT = "an I/O call inside an overrunning effect stops the run mid-flight"
I_CUT = "a length-prefixed frame survives being cut anywhere"
I_OVERLONG = "an overlong announced frame is refused rather than allocated"
I_PIPES = "delimiter framing round-trips through a real 'cat'"
I_ENV = "the environment is what the plugin declared, not what the host holds"
I_INJECT = "shell metacharacters in an argument are one literal argument"
I_PEER = "a python peer echoes length-prefixed frames back uppercased"

# `ci/test/plugin-reactive-boundary-test.sh`
G_REPO = "the guard passes on this repository"
G_SDK_BLOCKS = ("the SDK blocking on every plugin's behalf is caught, though "
                "every plugin is clean")
G_PLUGIN_SYNC = ("a plugin calling readFile is caught — system's readFile "
                 "cannot be filtered from any scope")
G_STRING = ("a plugin naming a sync-I/O primitive inside a STRING is clean — a "
            "literal calls nothing")
G_HOSTONLY = ("the hostOnly exemption is read from the TABLE, so clearing it "
              "reddens the gate")
G_EMPTY = "an empty denied-sync-io table is a finding rather than a vacuous pass"

# --- the 2026-09-09 verification arms. One per finding, on the repairs the
# --- verification pass's findings F1-F6 required.
C_F1_LOAD = ("F1: 'process' alone does not load, and the error is the "
             "disclosure")
C_F1_NEEDS = "'process' alone needs the trace-egress grant"
C_F4_CLASS = "F4: the UNSPECIFIED address is its own class, in every spelling"
C_F4_REFUSE = "F4: neither socket grant reaches the unspecified address"
I_F1_LOAD = ("the arm's own manifest is REFUSED AT LOAD, and the error is the "
             "reach")
I_F1_EXPLOIT = ("the exploit is REAL, and the only way to run it is with the "
                "disclosure")
I_F2_SYMLINK = ("a link into a recording is refused, and the bytes do not come "
                "back")
I_F2_ROOT = ("the declared root is canonicalised too, so a linked root still "
             "works")
I_F3_SECOND = "'127.1' passes the first pass and is refused by the second"
I_F4_CONNECT = ("0.0.0.0 no longer reaches the loopback daemon with "
                "socket:remote")
I_F5_GRANDCHILD = ("a child that forks is killed with its process group, "
                   "asserted at /proc")
I_F6_NAMES = "F6: the fourth way to block, and WHICH HALF refuses each name"
I_PARTITION = "the `system` surface is PARTITIONED by the two tables, not trimmed"

# `src/frontend/viewmodel/tests/unit/test_plugin_source_admission.nim`
S_SYSIO_GATE = "the gate refuses the sysio probe, naming the primitives"
S_SYSIO_REAL = ("the system exploit is REAL — no import, no pragma, any file "
                "read and written")

# `ci/test/plugin-reactive-boundary-test.sh`
S_UNACCOUNTED = ("a name the compiler puts in every plugin's scope, on neither "
                 "table, is a NAMED finding")
S_SWEEP_EMPTY = "a sweep that derives nothing is a FAILURE, not a clean surface"

# --- the 2026-09-09 SOURCE-ADMISSION arms. The allow-list over a plugin's
# --- imports, and the FFI-pragma denial that closes the route around it.
G_PROBE = ("THE PROBE: a declared plugin importing std/posix is refused, "
           "naming the module and the import")
G_TABLE_IS_READ = ("the SAME module becomes clean once the TABLE names it — "
                   "the gate reads it, it does not hold it")
G_ADMITTED_CLEAN = ("a plugin importing only allow-listed modules is clean — "
                    "the rule permits as well as refuses")
G_FFI_WORDS = ("the same WORDS outside a pragma are clean — the finding is a "
               "pragma, not a vocabulary")
G_FFI_MULTILINE = ("a pragma split ACROSS LINES is read too — the scan "
                   "accumulates the span, it does not match a line")
A_EFFECT = "under admission the file is not read and the shell is not reached"
A_FFI_EFFECT = "under admission the FFI probe does not reach system(3) either"
A_COVERAGE = "the probe covers every admitted module, and nothing else"
A_NO_DANGEROUS = "no admitted module hands out a dangerous name"

# `ci/test/sdk-facade-boundary-test.sh`
S_REPO = "the guard passes on this repository"


@dataclass
class Suite:
    path: str
    kind: str  # "nim" or "bash"
    binary: str = ""


NIM_CAPS = Suite(CAPS_SUITE, "nim", "/tmp/plat8-mut-caps")
NIM_IO = Suite(IO_SUITE, "nim", "/tmp/plat8-mut-io")
BASH_GATE = Suite(GATE_SUITE, "bash")
BASH_SDK_GATE = Suite(SDK_GATE_SUITE, "bash")
# The two suites the A-arms grade. `NIM_ADMISSION` COMPILES AND RUNS a real
# exploit and then runs the boundary gate twice, so it is the slowest suite
# here by a wide margin; it is used only where the end-to-end grading is the
# point, exactly as `NIM_IO` is for P1b/P2b/P3b.
NIM_ADMISSION = Suite(ADMISSION_SUITE, "nim", "/tmp/plat8-mut-admission")
NIM_ALLOWLIST = Suite(ALLOWLIST_SUITE, "nim", "/tmp/plat8-mut-allowlist")


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    suite: Suite
    why: str = ""
    control_name: str = ""
    control_find: str = ""
    control_replace: str = ""


MUTATIONS: list[Mutation] = [
    # -- the capability policy ---------------------------------------------
    Mutation(
        "P1", CAPS,
        "    if not g.declaresExecutable(req.target):",
        "    if false:",
        C_UNDECLARED_EXE, NIM_CAPS,
        "the declared executable set stops being consulted: `process` becomes "
        "a grant to spawn ANYTHING on the host's PATH, which is the hole §8.4 "
        "says does not exist",
        control_name="the declared-set test is written through a named binding",
        control_find="    if not g.declaresExecutable(req.target):",
        control_replace="    let isDeclared = g.declaresExecutable(req.target)\n"
                        "    if not isDeclared:",
    ),
    Mutation(
        "P1b", CAPS,
        "    if not g.declaresExecutable(req.target):",
        "    if false:",
        I_SHELL, NIM_IO,
        "THE SAME MUTATION, GRADED END TO END. The policy case above proves the "
        "decision changed; this proves a real plugin can then really spawn a "
        "real shell. A rule graded only where it is written is a rule nobody "
        "has shown is called.",
        control_name="the declared-set test is written through a named binding",
        control_find="    if not g.declaresExecutable(req.target):",
        control_replace="    let isDeclared = g.declaresExecutable(req.target)\n"
                        "    if not isDeclared:",
    ),
    Mutation(
        "P2", CAPS,
        "  if '/' in name or '\\\\' in name: return false",
        "  if false: return false",
        C_NAMED_NOT_PATHED, NIM_CAPS,
        "an executable name may carry a path separator again: §8.1.1's 'a "
        "plugin does not hand over an absolute path of its choosing' is gone",
        control_name="the two separator tests are split into two statements",
        control_find="  if '/' in name or '\\\\' in name: return false",
        control_replace="  if '/' in name: return false\n"
                        "  if '\\\\' in name: return false",
    ),
    Mutation(
        "P2b", CAPS,
        "  if '/' in name or '\\\\' in name: return false",
        "  if false: return false",
        I_PATHY, NIM_IO,
        "THE SAME MUTATION, GRADED END TO END: a plugin declaring `sh` may then "
        "spawn `/bin/sh`.",
        control_name="the two separator tests are split into two statements",
        control_find="  if '/' in name or '\\\\' in name: return false",
        control_replace="  if '/' in name: return false\n"
                        "  if '\\\\' in name: return false",
    ),
    Mutation(
        "P3", CAPS,
        "  if isLoopbackLiteral(h): return acLoopback\n",
        "  if not isLoopbackLiteral(h): return acLoopback\n",
        C_LOOPBACK, NIM_CAPS,
        "the classification is inverted: every non-loopback address is treated "
        "as loopback and `socket:local` becomes a network grant",
        control_name="the classification test is written through a named binding",
        control_find="  if isLoopbackLiteral(h): return acLoopback\n",
        control_replace="  let loopback = isLoopbackLiteral(h)\n"
                        "  if loopback: return acLoopback\n",
    ),
    Mutation(
        "P3b", CAPS,
        "  if isLoopbackLiteral(h): return acLoopback\n",
        "  if not isLoopbackLiteral(h): return acLoopback\n",
        I_NONLOOPBACK, NIM_IO,
        "THE SAME MUTATION, GRADED END TO END: a plugin holding only "
        "`socket:local` may then open a socket to a non-loopback address. This "
        "is the milestone's own third test, phrased as an attempt.",
        control_name="the classification test is written through a named binding",
        control_find="  if isLoopbackLiteral(h): return acLoopback\n",
        control_replace="  let loopback = isLoopbackLiteral(h)\n"
                        "  if loopback: return acLoopback\n",
    ),
    Mutation(
        "P4", CAPS,
        "  if h.toLowerAscii() == \"localhost\" or",
        "  if false and h.toLowerAscii() == \"localhost\" or",
        C_LOCALHOST, NIM_CAPS,
        "'localhost' stops being refused by name. A name the machine resolves "
        "is not an address, and a loopback-only grant that follows one is a "
        "network grant nobody wrote down.",
        control_name="the three localhost spellings are reordered",
        control_find="  if h.toLowerAscii() == \"localhost\" or\n"
                     "     h.toLowerAscii() == \"localhost.\" or\n"
                     "     h.toLowerAscii().endsWith(\".localhost\"):",
        control_replace="  if h.toLowerAscii().endsWith(\".localhost\") or\n"
                        "     h.toLowerAscii() == \"localhost.\" or\n"
                        "     h.toLowerAscii() == \"localhost\":",
    ),
    Mutation(
        "P5", CAPS,
        "  if not needsTraceEgressGrant(g.capabilities): return true\n"
        "  g.traceEgress.acknowledged and\n"
        "    g.traceEgress.statement.strip().len >= MinTraceEgressStatement",
        "  if not needsTraceEgressGrant(g.capabilities): return true\n"
        "  true",
        C_NO_IMPLY, NIM_CAPS,
        "THE VERIFICATION GATE ITSELF. The pair no longer needs the explicit "
        "grant, so `trace` + `socket:remote` is implied by holding both — which "
        "is exactly what PLAT-8's gate says must not be true.",
        control_name="the two conditions are written as nested ifs",
        control_find="  if not needsTraceEgressGrant(g.capabilities): return true\n"
                     "  g.traceEgress.acknowledged and\n"
                     "    g.traceEgress.statement.strip().len >= MinTraceEgressStatement",
        control_replace="  if not needsTraceEgressGrant(g.capabilities): return true\n"
                        "  if not g.traceEgress.acknowledged: return false\n"
                        "  g.traceEgress.statement.strip().len >= MinTraceEgressStatement",
    ),
    Mutation(
        "P6", CAPS,
        "  capTrace in eff and capSocketRemote in eff",
        "  capTrace in eff or capSocketRemote in eff",
        C_NEITHER_ALONE, NIM_CAPS,
        "the PAIR becomes EITHER: a trace-only plugin is asked to acknowledge "
        "an exfiltration path it cannot take, which §8.1.2's 'neither alone "
        "carries the same weight' rules out in the other direction",
        control_name="the two membership tests are swapped, which is the same conjunction",
        control_find="  capTrace in eff and capSocketRemote in eff",
        control_replace="  capSocketRemote in eff and capTrace in eff",
    ),
    Mutation(
        "P7", CAPS,
        "  MinTraceEgressStatement* = 16",
        "  MinTraceEgressStatement* = 0",
        C_STATEMENT, NIM_CAPS,
        "an empty statement becomes a statement: the grant is acknowledged and "
        "says nothing, which is the acknowledgement nobody read",
        control_name="the same length written as an arithmetic expression",
        control_find="  MinTraceEgressStatement* = 16",
        control_replace="  MinTraceEgressStatement* = 8 + 8",
    ),
    Mutation(
        "P8", CAPS,
        "      if not traceEgressPermitted(g):",
        "      if false:",
        C_WITH_GRANT, NIM_CAPS,
        "the SDK-side half of the gate: the decision stops consulting the "
        "egress grant, so a plugin holding the pair connects to a declared "
        "host with no acknowledgement at all. The killer is the case that "
        "asserts the grant is what made the difference — the enumeration case "
        "grades `traceEgressPermitted` itself and does not reach `decide`, so "
        "naming it here would have been an arm that could never be killed for "
        "the reason it claims.",
        control_name="the egress test is written through a named binding",
        control_find="      if not traceEgressPermitted(g):",
        control_replace="      let egressOk = traceEgressPermitted(g)\n"
                        "      if not egressOk:",
    ),
    Mutation(
        "P9", CAPS,
        "      if capSocketRemote notin g.capabilities:\n"
        "        return refuse(id, capSocketRemote, what, target,",
        "      if false:\n"
        "        return refuse(id, capSocketRemote, what, target,",
        C_LOCAL_NOT_REMOTE, NIM_CAPS,
        "a remote address stops requiring `socket:remote`, so a plugin holding "
        "only `socket:local` reaches beyond loopback. §8.4's 'grants are "
        "per-kind and separate' is a claim in BOTH directions and each "
        "direction has its own case; this arm is the one that breaks the "
        "local-only plugin, and P3 breaks the other.",
        control_name="the membership test is written the other way round",
        control_find="      if capSocketRemote notin g.capabilities:\n"
                     "        return refuse(id, capSocketRemote, what, target,",
        control_replace="      if not (capSocketRemote in g.capabilities):\n"
                        "        return refuse(id, capSocketRemote, what, target,",
    ),
    Mutation(
        "P10", CAPS,
        "  of acRemote:\n"
        "    if capSocketRemote in g.capabilities:\n"
        "      return permit(capSocketRemote)",
        "  of acRemote:\n"
        "    if true:\n"
        "      return permit(capSocketRemote)",
        C_SECOND_PASS, NIM_CAPS,
        "THE SECOND CAPABILITY PASS. A name that resolves off the machine stops "
        "being refused for a `socket:local` plugin, which is the DNS-shaped way "
        "a loopback grant becomes a network grant.",
        control_name="the membership test is written through a named binding",
        control_find="  of acRemote:\n"
                     "    if capSocketRemote in g.capabilities:\n"
                     "      return permit(capSocketRemote)",
        control_replace="  of acRemote:\n"
                        "    let remoteGranted = capSocketRemote in g.capabilities\n"
                        "    if remoteGranted:\n"
                        "      return permit(capSocketRemote)",
    ),
    Mutation(
        "P11", CAPS,
        "  case classifyHost(resolved)\n"
        "  of acLoopback:",
        "  case classifyHost(wrote)\n"
        "  of acLoopback:",
        C_SECOND_PASS, NIM_CAPS,
        "the second pass judges the STRING THE PLUGIN WROTE rather than the "
        "address it resolved to — which makes it a restatement of the first "
        "pass and no second pass at all",
        control_name="the resolved literal is hoisted into a named binding",
        control_find="  case classifyHost(resolved)\n"
                     "  of acLoopback:",
        control_replace="  let resolvedClass = classifyHost(resolved)\n"
                        "  case resolvedClass\n"
                        "  of acLoopback:",
    ),
    Mutation(
        "P11b", CAPS,
        "  of acRemote:\n"
        "    if capSocketRemote in g.capabilities:\n"
        "      return permit(capSocketRemote)",
        "  of acRemote:\n"
        "    if capSocketRemote in g.capabilities:\n"
        "      return decide(g, id, IoRequest(kind: irConnectTcp,\n"
        "                                     target: resolved, port: port))",
        C_NO_REDEMAND, NIM_CAPS,
        "THE SIMPLIFICATION THE CASE EXISTS TO REFUSE. The second pass goes "
        "back to re-running the WHOLE of `decide` on the resolved literal, "
        "which re-demands that the ADDRESS be declared as well as the name — so "
        "every legitimate connection to a declared hostname is refused. It is "
        "the obvious tidy-up (`one predicate, one function`, applied one level "
        "too far) and it is why the second pass asks a different question of "
        "the same policy rather than the same one.\n"
        "\n"
        "        This arm replaced one that swapped the two `of` branches and "
        "did not compile — a HARNESS-FAILURE rather than a kill, which is "
        "exactly the distinction the three verdicts exist to keep.",
        control_name="the resolved literal is hoisted into a named binding",
        control_find="  case classifyHost(resolved)\n"
                     "  of acLoopback:",
        control_replace="  let resolvedClass = classifyHost(resolved)\n"
                        "  case resolvedClass\n"
                        "  of acLoopback:",
    ),
    # -- the manifest's load-time validation --------------------------------
    Mutation(
        "P12", MANIFEST,
        "  if needsTraceEgressGrant(m.capabilities):\n"
        "    if not traceEgressPermitted(m.grants):",
        "  if needsTraceEgressGrant(m.capabilities):\n"
        "    if false:",
        C_PAIR_LOAD, NIM_CAPS,
        "the pair loads without the grant. The runtime refusal in `decide` "
        "would still fire, which is the point of having both: this arm shows "
        "the LOAD-TIME half is graded on its own rather than covered by the "
        "runtime one.",
        control_name="the pair test is hoisted into a named binding",
        control_find="  if needsTraceEgressGrant(m.capabilities):\n"
                     "    if not traceEgressPermitted(m.grants):",
        control_replace="  let holdsThePair = needsTraceEgressGrant(m.capabilities)\n"
                        "  if holdsThePair:\n"
                        "    if not traceEgressPermitted(m.grants):",
    ),
    Mutation(
        "P13", MANIFEST,
        "  if capProcess notin m.capabilities and m.grants.executables.len > 0:",
        "  if false:",
        C_MIRROR, NIM_CAPS,
        "a manifest may declare executables it was not granted `process` for. "
        "§8.4 makes the declaration what a user reads before granting, and a "
        "declaration the grant does not back reads as a power the plugin has.",
        control_name="the two conditions are reordered, which is the same conjunction",
        control_find="  if capProcess notin m.capabilities and m.grants.executables.len > 0:",
        control_replace="  if m.grants.executables.len > 0 and capProcess notin m.capabilities:",
    ),
    # -- the SDK takes the decision -----------------------------------------
    Mutation(
        "P14", IO,
        "    let d = decide(grantsOf(ctx), ctx.state.id,\n"
        "                   IoRequest(kind: irSpawnProcess, target: name))\n"
        "    if not d.permitted:",
        "    let d = decide(grantsOf(ctx), ctx.state.id,\n"
        "                   IoRequest(kind: irSpawnProcess, target: name))\n"
        "    if false:",
        I_SHELL, NIM_IO,
        "the SDK stops consulting the policy on a spawn. THE POLICY IS "
        "UNCHANGED and every case in the capability suite is still green — "
        "which is why the end-to-end suite exists.",
        control_name="the decision is hoisted into a named permission flag",
        control_find="    let d = decide(grantsOf(ctx), ctx.state.id,\n"
                     "                   IoRequest(kind: irSpawnProcess, target: name))\n"
                     "    if not d.permitted:",
        control_replace="    let d = decide(grantsOf(ctx), ctx.state.id,\n"
                        "                   IoRequest(kind: irSpawnProcess, target: name))\n"
                        "    let spawnPermitted = d.permitted\n"
                        "    if not spawnPermitted:",
    ),
    Mutation(
        "P15", IO,
        "    let d = decide(grantsOf(ctx), ctx.state.id,\n"
        "                   IoRequest(kind: irConnectTcp, target: host, port: port))\n"
        "    if not d.permitted:",
        "    let d = decide(grantsOf(ctx), ctx.state.id,\n"
        "                   IoRequest(kind: irConnectTcp, target: host, port: port))\n"
        "    if false:",
        I_REMOTE_UNDECLARED, NIM_IO,
        "the SDK stops consulting the policy on a TCP connect. MEASURED: the "
        "milestone's third test stays GREEN, because the SECOND pass — on the "
        "resolved address — still refuses a `socket:local` plugin reaching "
        "203.0.113.9. What the second pass cannot save is the declared-HOST "
        "set, which only the first pass consults, and `localhost`, which the "
        "second pass sees as a resolved 127.0.0.1 and permits. So this arm is "
        "evidence that the two passes are not redundant: each catches "
        "something the other does not.",
        control_name="the decision is hoisted into a named permission flag",
        control_find="    let d = decide(grantsOf(ctx), ctx.state.id,\n"
                     "                   IoRequest(kind: irConnectTcp, target: host, port: port))\n"
                     "    if not d.permitted:",
        control_replace="    let d = decide(grantsOf(ctx), ctx.state.id,\n"
                        "                   IoRequest(kind: irConnectTcp, target: host, port: port))\n"
                        "    let connectPermitted = d.permitted\n"
                        "    if not connectPermitted:",
    ),
    Mutation(
        "P16", IO,
        "      let dt = decide(grantsOf(ctx), ctx.state.id,\n"
        "                      IoRequest(kind: irReadTrace, target: full))\n"
        "      if not dt.permitted:",
        "      let dt = decide(grantsOf(ctx), ctx.state.id,\n"
        "                      IoRequest(kind: irReadTrace, target: full))\n"
        "      if false:",
        I_TRACE_FS, NIM_IO,
        "`fs:read` becomes a way around `trace`: a plugin granted a directory "
        "that happens to contain a recording reads the recorded program's "
        "memory with a grant that says nothing about recordings",
        control_name="the trace decision is hoisted into a named permission flag",
        control_find="      let dt = decide(grantsOf(ctx), ctx.state.id,\n"
                     "                      IoRequest(kind: irReadTrace, target: full))\n"
                     "      if not dt.permitted:",
        control_replace="      let dt = decide(grantsOf(ctx), ctx.state.id,\n"
                        "                      IoRequest(kind: irReadTrace, target: full))\n"
                        "      let tracePermitted = dt.permitted\n"
                        "      if not tracePermitted:",
    ),
    Mutation(
        "P17", IO,
        "    ctx.checkBudget()\n"
        "    let d = decide(grantsOf(ctx), ctx.state.id,\n"
        "                   IoRequest(kind: irSpawnProcess, target: name))",
        "    let d = decide(grantsOf(ctx), ctx.state.id,\n"
        "                   IoRequest(kind: irSpawnProcess, target: name))",
        I_CHECKPOINT, NIM_IO,
        "the I/O entry point stops being a deadline checkpoint. PLAT-7's "
        "`plugin_api.nim` states in as many words that 'PLAT-8's I/O primitives "
        "are required to be checkpoints for the same reason', and until this arm "
        "existed that was three documents and no test.",
        control_name="the checkpoint is called through the context binding",
        control_find="    ctx.checkBudget()\n"
                     "    let d = decide(grantsOf(ctx), ctx.state.id,\n"
                     "                   IoRequest(kind: irSpawnProcess, target: name))",
        control_replace="    let c = ctx\n"
                        "    c.checkBudget()\n"
                        "    let d = decide(grantsOf(ctx), ctx.state.id,\n"
                        "                   IoRequest(kind: irSpawnProcess, target: name))",
    ),
    Mutation(
        "P18", IO,
        "    findExe(name, followSymlinks = false)",
        "    findExe(name)",
        I_INJECT, NIM_IO,
        "RESOLUTION FOLLOWS THE SYMLINK AGAIN. This is not a hypothetical: on "
        "this workspace's nixpkgs coreutils, `findExe(\"printf\")` resolves to "
        "`…/bin/coreutils`, a multi-call binary that dispatches on its own "
        "argv[0] and exits 1 having printed nothing. §8.1.1 gives the host "
        "resolution so the plugin's declaration reaches the program it named.",
        control_name="the resolution flag is hoisted into a named binding",
        control_find="    findExe(name, followSymlinks = false)",
        control_replace="    let keepLinks = false\n"
                        "    findExe(name, followSymlinks = keepLinks)",
    ),
    Mutation(
        "P19", IO,
        "      var envTable = newStringTable(modeCaseSensitive)\n"
        "      for (k, v) in env:\n"
        "        envTable[k] = v",
        "      var envTable: StringTableRef = nil\n"
        "      for (k, v) in env:\n"
        "        discard v",
        I_ENV, NIM_IO,
        "the child inherits the HOST's environment instead of the plugin's. "
        "`startProcess` inherits when `env` is nil, and the host's environment "
        "is where a token would be.",
        control_name="the environment pairs are copied through a named local",
        control_find="      var envTable = newStringTable(modeCaseSensitive)\n"
                     "      for (k, v) in env:\n"
                     "        envTable[k] = v",
        control_replace="      var envTable = newStringTable(modeCaseSensitive)\n"
                        "      for pair in env:\n"
                        "        envTable[pair[0]] = pair[1]",
    ),
    Mutation(
        "P20", IO,
        "    if buffer.len < 4 + n: return tsIncomplete",
        "    if false: return tsIncomplete",
        I_CUT, NIM_IO,
        "the length-prefixed decoder stops waiting for the whole payload — the "
        "exact loop §8.1's codec row exists so that every plugin does not "
        "rewrite it",
        control_name="the length comparison is written the other way round",
        control_find="    if buffer.len < 4 + n: return tsIncomplete",
        control_replace="    if 4 + n > buffer.len: return tsIncomplete",
    ),
    Mutation(
        "P21", IO,
        "    if n > MaxFrameBytes: return tsOverlong",
        "    if false: return tsOverlong",
        I_OVERLONG, NIM_IO,
        "a peer's announced length is trusted: 'the plugin's peer sent a large "
        "number' becomes a way to exhaust the host process",
        control_name="the bound comparison is written the other way round",
        control_find="    if n > MaxFrameBytes: return tsOverlong",
        control_replace="    if MaxFrameBytes < n: return tsOverlong",
    ),
    Mutation(
        "P22", IO,
        "    if delim in payload: return \"\"",
        "    if false: return \"\"",
        I_OVERLONG, NIM_IO,
        "a delimited frame may contain its own delimiter, so one message "
        "silently becomes two on the wire",
        control_name="the containment test is written through a named binding",
        control_find="    if delim in payload: return \"\"",
        control_replace="    let carriesDelim = delim in payload\n"
                        "    if carriesDelim: return \"\"",
    ),
    # -- handles, deactivation and reclaim ----------------------------------
    Mutation(
        "P23", HANDLES,
        "      if t.close(h): result = result + 1",
        "      result = result + 1",
        I_TEARDOWN, NIM_IO,
        "THE REPORT IS UNCHANGED WHILE THE STATE MOVES — the shape every "
        "data-loss defect in this campaign had. `closeAll` still returns the "
        "right count and `liveCount` still drops, because the table is emptied; "
        "nothing is actually released. Only the OS notices.",
        control_name="the released handle is bound before it is closed",
        control_find="      if t.close(h): result = result + 1",
        control_replace="      let released = t.close(h)\n"
                        "      if released: result = result + 1",
    ),
    Mutation(
        "P24", HANDLES,
        "  if not c.isNil:\n    c()",
        "  if false:\n    c()",
        I_DEACTIVATE_ALL, NIM_IO,
        "`close` stops running the closer. Same shape as P23 one level down, "
        "and graded by a different case so neither stands in for the other.",
        control_name="the nil test is written the other way round",
        control_find="  if not c.isNil:\n    c()",
        control_replace="  if c != nil:\n    c()",
    ),
    Mutation(
        "P25", HOST,
        "  host.reclaim(id)\n",
        "  discard 0\n",
        I_TEARDOWN, NIM_IO,
        "deactivation stops sweeping the handle table. §8.1.1: 'Deactivation "
        "closes them — the reason a plugin cannot leak a daemon past its own "
        "lifetime.' The reactive release still happens, so every PLAT-7 case is "
        "green and the child is still running.",
        control_name="the swept plugin id is hoisted into a named binding",
        control_find="  host.reclaim(id)\n",
        control_replace="  let sweeping = id\n  host.reclaim(sweeping)\n",
    ),
    Mutation(
        "P26", IO,
        "      if p.pid > 0:\n"
        "        let pgid = getpgid(Pid(p.pid))",
        "      if false:\n"
        "        let pgid = getpgid(Pid(p.pid))",
        I_TEARDOWN, NIM_IO,
        "the child is never signalled: the handle is forgotten and `sleep 300` "
        "outlives the plugin, the host and — in the product — the trace the "
        "user closed.\n"
        "\n"
        "        RE-AIMED 2026-09-09. This arm's needle was the bare "
        "`discard posix.kill(...)` that `rawKill` used to hold, and F5's repair "
        "moved it — the guard now wraps a process-group kill. **The needle scan "
        "found that, not review**: an arm whose needle no longer occurs is an "
        "arm that scores HARNESS-FAILURE at best and is silently unkillable at "
        "worst, and a repair that moves a line moves every arm aimed at it.",
        control_name="the pid test is written through a named binding",
        control_find="      if p.pid > 0:\n"
                     "        let pgid = getpgid(Pid(p.pid))",
        control_replace="      let alive = p.pid > 0\n"
                        "      if alive:\n"
                        "        let pgid = getpgid(Pid(p.pid))",
    ),
    Mutation(
        "P27", IO,
        "    var spins = 0\n"
        "    while spins < 20000:",
        "    var spins = 0\n"
        "    while false:",
        I_TEARDOWN, NIM_IO,
        "the killed child is never REAPED, so it becomes a zombie — a process "
        "the OS still lists. A liveness probe that asked only `kill(pid, 0)` "
        "would call that dead; `/proc/<pid>` does not, which is why the suite "
        "asks both.",
        control_name="the spin bound is hoisted into a named constant",
        control_find="    var spins = 0\n"
                     "    while spins < 20000:",
        control_replace="    let spinLimit = 20000\n"
                        "    var spins = 0\n"
                        "    while spins < spinLimit:",
    ),
    Mutation(
        "P28", HOST,
        "  if rec.ctx.isNil or rec.ctx.state.isNil or rec.ctx.state.handles.isNil:\n"
        "    return 0\n"
        "  var failures: seq[HandleCloseFailure] = @[]\n"
        "  result = rec.ctx.state.handles.closeAll(failures)",
        "  if rec.ctx.isNil or rec.ctx.state.isNil or rec.ctx.state.handles.isNil:\n"
        "    return 0\n"
        "  var failures: seq[HandleCloseFailure] = @[]\n"
        "  result = 0",
        I_RECLAIM, NIM_IO,
        "`reclaim` reports a sweep it did not do. The plugin stays alive, which "
        "is correct, and its forty sockets stay open, which is the whole of what "
        "'reclaimable without restarting CodeTracer' was supposed to mean.",
        control_name="the handle table is hoisted into a named binding",
        control_find="  var failures: seq[HandleCloseFailure] = @[]\n"
                     "  result = rec.ctx.state.handles.closeAll(failures)",
        control_replace="  var failures: seq[HandleCloseFailure] = @[]\n"
                        "  let table = rec.ctx.state.handles\n"
                        "  result = table.closeAll(failures)",
    ),
    # -- the gates ----------------------------------------------------------
    Mutation(
        "P29", GATE,
        '\t\tbody="$(blank_strings <<<"${body}" | strip_export_except)"',
        '\t\tbody="$(cat <<<"${body}")"',
        G_REPO, BASH_GATE,
        "the declaration-aware filters are removed, so the denied table's own "
        "string literals and the surface's `export … except` clause are read as "
        "calls and the gate reddens on a clean tree. A gate that cannot be "
        "green is a gate somebody removes from the lane.",
        control_name="the two filters are applied in two statements",
        control_find='\t\tbody="$(blank_strings <<<"${body}" | strip_export_except)"',
        control_replace='\t\tbody="$(blank_strings <<<"${body}")"\n'
                        '\t\tbody="$(strip_export_except <<<"${body}")"',
    ),
    Mutation(
        "P30", GATE,
        '\t\tif grep -qxF "${name}" <<<"${sync_host_only}"; then continue; fi',
        "\t\t:",
        G_REPO, BASH_GATE,
        "the hostOnly exemption stops being read, so the SDK's own legitimate "
        "`startProcess` is reported and the gate is permanently red",
        control_name="the exemption test is written as an if/then without the one-liner",
        control_find='\t\tif grep -qxF "${name}" <<<"${sync_host_only}"; then continue; fi',
        control_replace='\t\tif grep -qxF "${name}" <<<"${sync_host_only}"; then\n'
                        "\t\t\tcontinue\n"
                        "\t\tfi",
    ),
    Mutation(
        "P31", GATE,
        '\t\t\tif ($0 ~ /,[[:space:]]*true\\)[[:space:]]*,?[[:space:]]*$/) print s',
        "\t\t\tprint s",
        G_SDK_BLOCKS, BASH_GATE,
        "every entry is treated as hostOnly, so `sdk-does-not-block` exempts "
        "the whole denied set and an SDK that blocks on every plugin's behalf "
        "passes",
        control_name="the flag pattern is anchored with an equivalent alternation",
        control_find='\t\t\tif ($0 ~ /,[[:space:]]*true\\)[[:space:]]*,?[[:space:]]*$/) print s',
        control_replace='\t\t\tif ($0 ~ /,[ \\t]*true\\)[ \\t]*,?[ \\t]*$/) print s',
    ),
    Mutation(
        "P32", GATE,
        "sync_io_count=\"$(grep -c . <<<\"${sync_io}\" || true)\"",
        "sync_io_count=1",
        G_EMPTY, BASH_GATE,
        "the emptiness check is bypassed, so a tree whose denied table parsed "
        "to nothing reports OK and checks 15 and 16 scan for nothing — "
        "Verification-Harness-Traps §6a's vacuous universal",
        control_name="the count is taken through an intermediate variable",
        control_find="sync_io_count=\"$(grep -c . <<<\"${sync_io}\" || true)\"",
        control_replace="sync_io_lines=\"${sync_io}\"\n"
                        "sync_io_count=\"$(grep -c . <<<\"${sync_io_lines}\" || true)\"",
    ),
    Mutation(
        "P33", GATE,
        "\t\t\tsync_findings=\"${sync_findings}${f}:${hit}\"$'\\n'",
        "\t\t\t:",
        G_PLUGIN_SYNC, BASH_GATE,
        "the sync-I/O findings are collected into nothing, so a plugin calling "
        "`readFile` is reported by nobody. `readFile` lives in `system` and "
        "cannot be filtered out of any scope, so this gate is the ONLY thing "
        "that refuses it — measured: with PLAT-7's surface alone, "
        "`compiles(readFile(\"x\"))` inside a plugin is true.",
        control_name="the finding is accumulated through a named local",
        control_find="\t\t\tsync_findings=\"${sync_findings}${f}:${hit}\"$'\\n'",
        control_replace="\t\t\tsync_line=\"${f}:${hit}\"\n"
                        "\t\t\tsync_findings=\"${sync_findings}${sync_line}\"$'\\n'",
    ),
    Mutation(
        "P34", GATE,
        "blank_strings() {\n\tsed -e 's/\"[^\"]*\"/\"\"/g'\n}",
        "blank_strings() {\n\tcat\n}",
        G_STRING, BASH_GATE,
        "the string blanker is a no-op, so a plugin that merely QUOTES the name "
        "of a routine it must not call is reported — Verification-Harness-Traps "
        "§4d's 'reword the prose until the regex is happy', one quote mark over",
        control_name="the sed expression is written without -e",
        control_find="blank_strings() {\n\tsed -e 's/\"[^\"]*\"/\"\"/g'\n}",
        control_replace="blank_strings() {\n\tsed 's/\"[^\"]*\"/\"\"/g'\n}",
    ),
    Mutation(
        "P35", SDK_GATE,
        "\t\t\tplugin_io_edge_seen=1\n",
        "\t\t\tplugin_io_edge_seen=0\n",
        S_REPO, BASH_SDK_GATE,
        "the admitted edge stops being witnessed, so `plugin-io-edge-is-real` "
        "reddens on this repository. That check exists because an admission for "
        "an import nobody makes is an admission nobody can see is wrong.",
        control_name="the witness flag is set through an arithmetic assignment",
        control_find="\t\t\tplugin_io_edge_seen=1\n",
        control_replace="\t\t\tplugin_io_edge_seen=$((0 + 1))\n",
    ),

    # -- THE 2026-09-09 VERIFICATION ARMS --------------------------------
    #
    # Six findings, six repairs, one arm per repair — and F1 and F4 get two
    # each, at the policy level and end to end, for the same reason P1/P1b
    # and P2/P2b do: a rule graded only where it is written is a rule nobody
    # has shown is called.
    #
    # EVERY ONE OF THESE WAS PRE-FLIGHTED BY REVERTING THE REPAIR AND
    # OBSERVING WHICH CASES WENT RED, before it was written down here. The
    # F4 pre-flight is the one worth knowing about: with `acUnspecified`
    # removed, the arm's own suite HUNG rather than failing, because the
    # exploit's connection consumed the accept the control then waited on.
    # That is Verification-Harness-Traps §1a arriving in a new arm — a test
    # that hangs on the defect it detects reports the defect as its absence
    # — and the read in that case is bounded now, with the measurement in
    # its comment.
    Mutation(
        "V1", CAPS,
        "  let eff = effectiveCapabilities(caps)\n"
        "  capTrace in eff and capSocketRemote in eff",
        "  capTrace in caps and capSocketRemote in caps",
        C_F1_LOAD, NIM_CAPS,
        "F1. THE EGRESS GATE STOPS BINDING `process` and goes back to asking "
        "the DECLARED set for §8.1.2's pair. That is the state PLAT-8 shipped "
        "in, and in it a plugin declaring `trace`, `fs:read` and `process` "
        "with `env` as its one declared executable — no socket capability, no "
        "declared host — loads clean, reads a recording, ships it over TCP, "
        "and the user is shown no exfiltration disclosure at all.",
        control_name="the effective-set test is written through result",
        control_find="  let eff = effectiveCapabilities(caps)\n"
                     "  capTrace in eff and capSocketRemote in eff",
        control_replace="  let eff = effectiveCapabilities(caps)\n"
                        "  result = capTrace in eff and capSocketRemote in eff",
    ),
    Mutation(
        "V1b", CAPS,
        "  let eff = effectiveCapabilities(caps)\n"
        "  capTrace in eff and capSocketRemote in eff",
        "  capTrace in caps and capSocketRemote in caps",
        I_F1_LOAD, NIM_IO,
        "THE SAME MUTATION, GRADED END TO END, against the verification "
        "pass's own arm-C manifest registered with the real host. The policy "
        "case proves the predicate changed; this proves the manifest a real "
        "attacker writes then LOADS.",
        control_name="the effective-set test is written through result",
        control_find="  let eff = effectiveCapabilities(caps)\n"
                     "  capTrace in eff and capSocketRemote in eff",
        control_replace="  let eff = effectiveCapabilities(caps)\n"
                        "  result = capTrace in eff and capSocketRemote in eff",
    ),
    Mutation(
        "V2", IO,
        "    try:\n"
        "      return expandFilename(absolute)\n"
        "    except CatchableError, Defect:\n"
        "      discard",
        "    if true:\n"
        "      return normalizedPath(absolute)",
        I_F2_SYMLINK, NIM_IO,
        "F2. THE CANONICALISER STOPS RESOLVING SYMLINKS and goes back to "
        "`absolutePath` + `normalizedPath`, which is what shipped. "
        "`pathIsUnder` is textual, so an ordinary symlink inside a declared "
        "readable root then reads the recording — measured at "
        "`ioOk data=RECORDED-SECRETS` — and a second symlink reads outside "
        "the declared root entirely. This falsified §8.1.4's bullet calling "
        "that containment 'the part that matters'.",
        control_name="the resolved path is returned through a named binding",
        control_find="    try:\n"
                     "      return expandFilename(absolute)\n"
                     "    except CatchableError, Defect:\n"
                     "      discard",
        control_replace="    try:\n"
                        "      let resolved = expandFilename(absolute)\n"
                        "      return resolved\n"
                        "    except CatchableError, Defect:\n"
                        "      discard",
    ),
    Mutation(
        "V2b", IO,
        "    result = grantsOf(ctx)\n"
        "    var rs: seq[string] = @[]\n"
        "    for r in result.readPaths: rs.add canonicalPath(r)\n"
        "    result.readPaths = rs",
        "    result = grantsOf(ctx)\n"
        "    var rs: seq[string] = @[]\n"
        "    for r in result.readPaths: rs.add r\n"
        "    result.readPaths = rs",
        I_F2_ROOT, NIM_IO,
        "F2's SECOND HALF, and it is the one a hurried repair skips: the "
        "declared fs ROOTS stop going through the same canonicaliser as the "
        "subject. Nothing becomes readable that was not — the failure is in "
        "the SAFE direction, a plugin whose declared root is itself reached "
        "through a symlink simply stops being able to read its own files — "
        "which is exactly why it would ship. This arm exists because the "
        "defect was found by its own new case rather than by review.",
        control_name="the roots are collected with an explicit index loop",
        control_find="    for r in result.readPaths: rs.add canonicalPath(r)",
        control_replace="    for i in 0 ..< result.readPaths.len:\n"
                        "      rs.add canonicalPath(result.readPaths[i])",
    ),
    Mutation(
        "V3", IO,
        "      let d2 = decideResolvedAddress(grantsOf(ctx), ctx.state.id, host, a, port)\n"
        "      if not d2.permitted:",
        "      let d2 = decideResolvedAddress(grantsOf(ctx), ctx.state.id, host, a, port)\n"
        "      if false:",
        I_F3_SECOND, NIM_IO,
        "F3. THE SECOND CAPABILITY PASS, AT ITS CALL SITE — and this arm is "
        "the reason D1 is no longer a declared survivor. PLAT-8 recorded that "
        "this mutation could not be killed because 'a hermetic suite cannot "
        "make the resolver disagree with the literal' and that killing it "
        "'needs a target that classifies as loopback and resolves elsewhere'. "
        "Both clauses are wrong, and the MIRROR is the easy one: `127.1` is "
        "not four octets so `classifyHost` calls it `acRemote`, and glibc "
        "resolves it to `127.0.0.1`. Pass one permits, pass two refuses. No "
        "/etc/hosts edit, no DNS, no resolver the suite does not already "
        "have. `2130706433` and `0x7f000001` do the same.",
        control_name="the second decision is hoisted into a named permission flag",
        control_find="      let d2 = decideResolvedAddress(grantsOf(ctx), ctx.state.id, host, a, port)\n"
                     "      if not d2.permitted:",
        control_replace="      let d2 = decideResolvedAddress(grantsOf(ctx), ctx.state.id, host, a, port)\n"
                        "      let resolvedPermitted = d2.permitted\n"
                        "      if not resolvedPermitted:",
    ),
    Mutation(
        "V4", CAPS,
        "  if isUnspecifiedLiteral(h): return acUnspecified\n",
        "",
        C_F4_CLASS, NIM_CAPS,
        "F4. `0.0.0.0` GOES BACK TO CLASSIFYING AS `acRemote`, which is what "
        "shipped, and it falsified 'neither grant implies the other, in both "
        "directions': it resolves to `0.0.0.0` so the second pass agrees with "
        "the first, and `connect(0.0.0.0)` reaches 127.0.0.1 on Linux.",
        control_name="the unspecified test is compared against true explicitly",
        control_find="  if isUnspecifiedLiteral(h): return acUnspecified\n",
        control_replace="  if isUnspecifiedLiteral(h) == true: return acUnspecified\n",
    ),
    Mutation(
        "V4b", CAPS,
        "  if isUnspecifiedLiteral(h): return acUnspecified\n",
        "",
        I_F4_CONNECT, NIM_IO,
        "THE SAME MUTATION, GRADED END TO END, and the effect is the whole "
        "point: with it, a plugin holding ONLY `socket:remote` connects to a "
        "REAL loopback daemon and the daemon RECEIVES a frame. The outcome "
        "alone would not distinguish that from a refusal; what the case "
        "asserts is that the accept never completes.",
        control_name="the unspecified test is compared against true explicitly",
        control_find="  if isUnspecifiedLiteral(h): return acUnspecified\n",
        control_replace="  if isUnspecifiedLiteral(h) == true: return acUnspecified\n",
    ),
    Mutation(
        "V5", IO,
        "        let pgid = getpgid(Pid(p.pid))\n"
        "        if pgid == Pid(p.pid):\n"
        "          discard posix.killpg(pgid, SIGKILL)\n"
        "        else:\n"
        "          discard posix.kill(Pid(p.pid), SIGKILL)",
        "        discard posix.kill(Pid(p.pid), SIGKILL)",
        I_F5_GRANDCHILD, NIM_IO,
        "F5. THE TEARDOWN GOES BACK TO SIGKILLING ONE PID, which is what "
        "shipped: no process group, no PR_SET_PDEATHSIG. For exactly the "
        "shape `startLongRunning`'s own comment names — a language server or "
        "an analyser daemon — the measurement is `child alive=false "
        "grandchild alive=true`, so 'no surviving child' was true of one "
        "process. The pre-flight run reproduced it: the grandchild's /proc "
        "state after the teardown was `S`, running.",
        control_name="the group-leader test is hoisted into a named flag",
        control_find="        let pgid = getpgid(Pid(p.pid))\n"
                     "        if pgid == Pid(p.pid):",
        control_replace="        let pgid = getpgid(Pid(p.pid))\n"
                        "        let isGroupLeader = pgid == Pid(p.pid)\n"
                        "        if isGroupLeader:",
    ),
    Mutation(
        "V5b", IO,
        "env = envTable, options = {poDaemon})",
        "env = envTable, options = {})",
        I_F5_GRANDCHILD, NIM_IO,
        "F5's OTHER HALF. `killpg` is only worth anything if the child is its "
        "own process-group leader, and `poDaemon` is what makes it one — "
        "`POSIX_SPAWN_SETPGROUP` with a pgroup of 0, applied by the kernel at "
        "spawn so no parent-side `setpgid` can lose a race with `execve`. "
        "Without it the child shares CodeTracer's group, `rawKill`'s guard "
        "correctly REFUSES to killpg (it would kill the editor), and the "
        "grandchild survives. Two arms because either half alone restores the "
        "defect, and a repair with two halves needs two arms.",
        control_name="the spawn options are built as a named set",
        control_find="                         env = envTable, options = {poDaemon})",
        control_replace="                         env = envTable,\n"
                        "                         options = {poDaemon} + {})",
    ),
    Mutation(
        "V6", IO,
        '    ("staticExec",     "await ctx.spawnProcess (there is no shell, and " &',
        '    ("staticExecXX",   "await ctx.spawnProcess (there is no shell, and " &',
        I_F6_NAMES, NIM_IO,
        "F6. ONE OF THE FIVE NEWLY-DENIED NAMES LEAVES THE TABLE, by being "
        "misspelled rather than deleted so the array length and the gate's "
        "own count do not move — which is the interesting version of the "
        "arm. `staticExec` runs a SHELL at compile time, entirely outside "
        "every runtime gate in this milestone, and it compiles in a plugin's "
        "scope today. The gate parses this table rather than hardcoding it, "
        "so a name that quietly leaves it leaves the gate too, silently.",
        # RE-AIMED 2026-09-09: the table grew 20 -> 41 when the `system`
        # surface was swept off the compiler, and this control quoted the
        # bound. Verification-Harness-Traps §16, caught by `--needle-scan`
        # before anything was recorded, which is what the scan is for.
        control_name="the array bound is written as a range",
        control_find="  PluginDeniedSyncIo*: array[41,",
        control_replace="  PluginDeniedSyncIo*: array[0 .. 40,",
    ),

    # -- the segment/substring repair (2026-09-12) -------------------------
    #
    # `pathIsUnder` tested for `..` as a SUBSTRING, in BOTH arguments, and the
    # second argument is the resolved ROOT. A declared root — or, through
    # PLAT-11's `readSourceFile`, a whole checkout — whose own path contained
    # those two characters had every file in it refused, with a message saying
    # the file was not inside it.
    #
    # THE ARM MUTATES THE SEGMENT WALK BACK INTO THE SUBSTRING TEST rather than
    # deleting the check. Deleting it would be graded by the OTHER case ("a
    # path containing '..' is refused rather than resolved"), which both
    # spellings satisfy; the thing worth grading is the DISTINCTION, so the
    # mutation is the old code and the killer is the case only the new code
    # passes. Verification-Harness-Traps §32a's rule, applied forwards: two
    # mechanisms — here two readings of one rule — need disjoint evidence.
    Mutation(
        "V7", CAPS,
        "  if hasParentSegment(path) or hasParentSegment(root): return false",
        '  if ".." in path or ".." in root: return false',
        C_DOTDOT_NAME, NIM_CAPS,
        "THE SUBSTRING TEST COMES BACK, which is what shipped until "
        "2026-09-12. A checkout or a declared root named `my..project` or "
        "`v1..v2` has EVERY file in it refused — not one file in it — and the "
        "row PLAT-11 shows the user says \"'src/a.nim' is not in this "
        "checkout\", which is false. It fails in the SAFE direction and every "
        "security assertion in both campaigns is MORE satisfied by it "
        "(Verification-Harness-Traps §15), which is why it survived review in "
        "two campaigns and was found by a third.",
        control_name="the two segment tests are hoisted into one named binding",
        control_find="  if hasParentSegment(path) or hasParentSegment(root): return false",
        control_replace="  let escapes = hasParentSegment(path) or hasParentSegment(root)\n"
                        "  if escapes: return false",
    ),

    # -- the SOURCE-ADMISSION arms (2026-09-09) ----------------------------
    #
    # PLAT-8 landed naming, as the worst entry on its own residual list, that
    # a plugin may import any `std` module and call it directly with the
    # capability model nowhere in that path. The A-arms grade the repair: an
    # ALLOW-LIST over the imports of a plugin's reachable closure, and the
    # FFI-pragma denial that closes the route AROUND the allow-list.
    #
    # A1/A7 are the P1/P1b pairing again — the same edit, graded once where the
    # rule is written and once by COMPILING AND RUNNING the exploit. A rule
    # graded only where it is written is a rule nobody has shown is called.
    Mutation(
        "A1", GATE,
        '\t\t[ "${allowed}" = "$1" ] && return 0',
        '\t\t[ "${allowed}" != "$1" ] && return 0',
        G_PROBE, BASH_GATE,
        "the allow-list membership test is inverted, so every std module "
        "except the first entry is admitted: `std/posix` is back, and with it "
        "`open`, `read`, `write`, `socket`, `connect`, `fork` and `execv` "
        "under identifiers no denied list can name.",
        control_name="the membership test is written as an if-statement",
        control_find='\t\t[ "${allowed}" = "$1" ] && return 0',
        control_replace='\t\tif [ "${allowed}" = "$1" ]; then return 0; fi',
    ),
    Mutation(
        "A7", GATE,
        '\t\t[ "${allowed}" = "$1" ] && return 0',
        '\t\t[ "${allowed}" != "$1" ] && return 0',
        A_EFFECT, NIM_ADMISSION,
        "THE SAME MUTATION, GRADED ON THE EFFECT. The case above proves the "
        "gate stopped saying no; this one COMPILES AND RUNS the probe and "
        "measures that `/etc/hostname` was read and `/bin/sh` was reached — "
        "against sentinel files, not against anything either instrument "
        "printed.",
        control_name="the membership test is written as an if-statement",
        control_find='\t\t[ "${allowed}" = "$1" ] && return 0',
        control_replace='\t\tif [ "${allowed}" = "$1" ]; then return 0; fi',
    ),
    Mutation(
        "A2", GATE,
        '\ttable_names "${ALLOWLIST_REL}" "${ALLOWLIST_CONST}"\n}',
        "\tprintf '%s\\n' std/strutils std/tables std/times\n}",
        G_TABLE_IS_READ, BASH_GATE,
        "the allow-list is HARDCODED in the gate instead of read out of the "
        "table. Everything stays green except the one case that adds a module "
        "to the table and expects the gate to follow — which is the whole "
        "argument for the list living in nim beside the code it binds.",
        control_name="the table's default mode is passed explicitly",
        control_find='\ttable_names "${ALLOWLIST_REL}" "${ALLOWLIST_CONST}"\n}',
        control_replace='\ttable_names "${ALLOWLIST_REL}" "${ALLOWLIST_CONST}" all\n}',
    ),
    Mutation(
        "A3", GATE,
        '\tif [ "${mode}" = "pragma-only" ]; then',
        "\tif false; then",
        G_FFI_WORDS, BASH_GATE,
        "the FFI scan loses its `{. \u2026 .}` span bound and matches bare "
        "identifiers, so a plugin with a variable called `header` or a proc "
        "called `compile` is refused. That is the direction that makes a check "
        "unusable rather than blind, and the remedy a reader would reach for "
        "is to rename the variable \u2014 Verification-Harness-Traps \u00a74d's "
        "smell pointed at code instead of at prose.",
        control_name="the mode test is written with its operands the other way round",
        control_find='\tif [ "${mode}" = "pragma-only" ]; then',
        control_replace='\tif [ "pragma-only" = "${mode}" ]; then',
    ),
    Mutation(
        "A4", GATE,
        '\t\t\t\tspan = span " " line',
        '\t\t\t\tspan = ""',
        G_FFI_MULTILINE, BASH_GATE,
        "the pragma-span accumulator stops carrying text across lines, so a "
        "pragma written over three lines loses everything before its closing "
        "`.}` \u2014 `importc` on the second line is gone and the scan sees only "
        "`header` on the third. The single-line spelling still reports, so the "
        "gate's own control stays green and the loss is SILENT, which is the "
        "failure mode this file's import extractor was repaired for seven "
        "times.\n\n"
        "        THIS ARM SURVIVED ITS FIRST RUN, AND THE SURVIVOR WAS A DEFECT "
        "IN THE CASE RATHER THAN IN THE RULE. The case's needle was the bare "
        "word `importc`, and check 22's own OK line prints "
        "`2 pragma(s) in .../plugin_io.nim (header importc )` in the SAME "
        "output — so the assertion was satisfied by the gate's CONTROL rather "
        "than by the finding, while the finding said `header` alone. "
        "Verification-Harness-Traps 5's sentinel collision, in an assertion's "
        "haystack instead of in a return value. The needle is anchored to the "
        "finding's own sentence now, which no other line in the gate produces.",
        control_name="the accumulation is written with an explicit empty suffix",
        control_find='\t\t\t\tspan = span " " line',
        control_replace='\t\t\t\tspan = span " " line ""',
    ),
    Mutation(
        "A5", ADMISSION,
        '    ("std/times", "wall clock,',
        '    ("std/timesXX", "wall clock,',
        G_REPO, BASH_GATE,
        "ONE ENTRY QUIETLY LEAVES THE ALLOW-LIST, by being misspelled rather "
        "than deleted so the array length does not move. Three of this "
        "repository's five declared plugins import `std/times`, so the gate "
        "refuses them \u2014 which is the allow-list failing in the SAFE "
        "direction, and the arm exists to show that the direction is a "
        "property of the design rather than a hope.",
        control_name="the entry is written across two lines",
        control_find='    ("std/times", "wall clock,',
        control_replace='    ("std/times",\n     "wall clock,',
    ),
    Mutation(
        "A6", ADMISSION,
        '    ("std/unicode", "rune-level',
        '    ("std/os", "rune-level',
        A_COVERAGE, NIM_ALLOWLIST,
        "AN OPERATING-SYSTEM MODULE IS ADDED TO THE ALLOW-LIST and no probe "
        "arm is added with it. The conformance suite's twenty-one imports are "
        "a second copy of the table \u2014 nim cannot import from a `const` \u2014 "
        "so the coverage case is the only thing standing between a widened "
        "boundary and a green run.",
        control_name="the entry is written across two lines",
        control_find='    ("std/unicode", "rune-level',
        control_replace='    ("std/unicode",\n     "rune-level',
    ),
    Mutation(
        "A8", GATE,
        '\tnames_in "$1" "$(denied_ffi_pragmas)" pragma-only',
        "\treturn 0",
        A_FFI_EFFECT, NIM_ADMISSION,
        "THE FFI SCAN STOPS SCANNING, graded on the EFFECT: the probe whose "
        "entire content is `import codetracer_plugin` and one "
        "`{.importc: \"system\".}` declaration is then ADMITTED, and its "
        "sentinel appears \u2014 which is `system(3)` with no grant, no declared "
        "executable and no disclosure.\n\n"
        "        FIRST WRITTEN AS A MISSPELLING IN THE TABLE (`importc` -> "
        "`importcXX`) AND THAT ARM COULD NOT BE KILLED, which is worth "
        "recording rather than quietly replacing: the probe's pragma is "
        "`{.importc: \"system\", header: \"<stdlib.h>\".}`, so `header` alone "
        "still refuses it and the effect never changes. A denied list with "
        "two entries covering one construct absorbs the loss of either \u2014 "
        "which is the list being ROBUST, and is exactly why an arm aimed at "
        "one entry proves nothing about the rule.",
        control_name="the pragma set is passed through a named binding",
        control_find='\tnames_in "$1" "$(denied_ffi_pragmas)" pragma-only',
        control_replace='\tlocal pragmas\n'
                        '\tpragmas="$(denied_ffi_pragmas)"\n'
                        '\tnames_in "$1" "${pragmas}" pragma-only',
    ),

    # -- the DERIVED `system` surface (2026-09-09) -------------------------
    #
    # The fifth list is the only one not written down in this repository: it is
    # swept off the pinned compiler by `ci/lib/system-io-surface.sh`, because
    # `system.nim` ends with `export syncio` and what a plugin can name with no
    # import is therefore a property of the toolchain. These seven arms grade
    # the two tables that must PARTITION that set, the sweep that produces it,
    # and the one exemption the SDK holds.
    Mutation(
        "S1", IO,
        '    ("open",             "await ctx.readPath / ctx.writePath (the host opens)", true),',
        '    ("open",             "await ctx.readPath / ctx.writePath (the host opens)", false),',
        G_REPO, BASH_GATE,
        "THE `open` EXEMPTION IS WITHDRAWN. `open` is denied like any other "
        "name now — the blocker was that `handles.open` was the SDK's own "
        "registration proc, and that proc is called `registerHandle`. What is "
        "left is ONE genuinely mediated occurrence, `posix.open` inside "
        "`openVerified`, taken after `decide`; it is exempt because the table "
        "SAYS SO, exactly as `startProcess` is. Flip the flag and "
        "`sdk-does-not-block` fires on that one line — which is the arm that "
        "shows the sanctioned path is preserved BY DECLARATION and not by the "
        "name having been left off the list.",
        # THE CONTROL IS A REWORDING AND NOT THE "written across two lines"
        # rendering every other table arm here uses. `hostOnly` is read off the
        # SAME line as the name, so splitting this record would take the flag
        # with it and the control would go red for a real reason — which is the
        # defect this arm exists to catch, arriving inside its own control.
        control_name="the hostOnly entry's advice text is reworded",
        control_find='    ("open",             "await ctx.readPath / ctx.writePath (the host opens)", true),',
        control_replace='    ("open",             "await ctx.readPath / ctx.writePath - the host opens, after decide", true),',
    ),
    Mutation(
        "S2", IO,
        '    ("open",             "await ctx.readPath',
        '    ("openXX",           "await ctx.readPath',
        S_SYSIO_GATE, NIM_ADMISSION,
        "`open` FALLS OFF THE DENIED LIST, graded END TO END: the probe whose "
        "entire import list is `import codetracer_plugin` is then not refused "
        "BY NAME for the routine that binds a path to a File. It is a "
        "MISSPELLING rather than a deletion because the array length is "
        "declared forty lines away and a deletion would not compile — and "
        "because check 23 then reports `open` as UNACCOUNTED, which is the "
        "second half of the same repair: a name that leaves one table without "
        "arriving on the other is a finding, not a silence.",
        control_name="the hostOnly entry is re-indented",
        control_find='    ("open",             "await ctx.readPath / ctx.writePath (the host opens)", true),',
        control_replace='    ("open",   "await ctx.readPath / ctx.writePath (the host opens)",   true),',
    ),
    Mutation(
        "S3", IO,
        '    ("readBuffer",       "await stream.read(n)",                        false),',
        '    ("readBufferXX",     "await stream.read(n)",                        false),',
        S_SYSIO_GATE, NIM_ADMISSION,
        "THE BUFFER FAMILY, which is the half nobody's enumeration had. The "
        "residual named ten routines and `readBuffer` was not among them; with "
        "`open` it is a complete file read. Graded on the gate's own finding "
        "line for the probe rather than on the table's length.",
        control_name="the denied entry is written across two lines",
        control_find='    ("readBuffer",       "await stream.read(n)",                        false),',
        control_replace='    ("readBuffer",\n'
                        '     "await stream.read(n)",                             false),',
    ),
    Mutation(
        "S4", IO,
        '    ("reopen",           "await ctx.readPath — `reopen` re-binds an ALREADY " &',
        '    ("reopenXX",         "await ctx.readPath — `reopen` re-binds an ALREADY " &',
        G_REPO, BASH_GATE,
        "`reopen` IS THE NAME THAT MAKES THE DERIVATION WORTH HAVING. "
        "`reopen(stdin, \"/etc/hostname\", fmRead)` reads any file with NO "
        "`open` at all, so denying only the name that had been written down "
        "would have left the hole exactly where it was. It is on the list "
        "because the SWEEP found it, and this arm asserts the sweep still "
        "notices when it leaves.",
        control_name="the denied entry is written across two lines",
        control_find='    ("reopen",           "await ctx.readPath — `reopen` re-binds an ALREADY " &',
        control_replace='    ("reopen",\n'
                        '     "await ctx.readPath — `reopen` re-binds an ALREADY " &',
    ),
    Mutation(
        "S5", IO,
        '    ("stdin",            "the host\'s own standard input, already open. It is " &',
        '    ("stdinXX",          "the host\'s own standard input, already open. It is " &',
        G_REPO, BASH_GATE,
        "AN EXEMPTION GOES MISSING AND THAT IS A FINDING TOO. The repair is "
        "that the two tables PARTITION the derived surface, so a name falling "
        "off the EXEMPT table is caught by the same check as a name falling "
        "off the denied one. Before 2026-09-09 an exemption was an absence, "
        "and an absence is indistinguishable from the oversight that left "
        "`open` and `readBuffer` unmediated.",
        control_name="the exempt entry is written across two lines",
        control_find='    ("stdin",            "the host\'s own standard input, already open. It is " &',
        control_replace='    ("stdin",\n'
                        '     "the host\'s own standard input, already open. It is " &',
    ),
    Mutation(
        "S6", GATE,
        '\tif [ "${system_unaccounted_n}" -gt 0 ]; then',
        "\tif false; then",
        S_UNACCOUNTED, BASH_GATE,
        "CHECK 23 STOPS REPORTING. The sweep still runs and the tables are "
        "still parsed; only the verdict is dropped, which is the shape a "
        "check acquires when somebody silences it rather than removes it.",
        control_name="the emptiness test is written as an inequality",
        control_find='\tif [ "${system_unaccounted_n}" -gt 0 ]; then',
        control_replace='\tif [ "${system_unaccounted_n}" -ne 0 ]; then',
    ),
    Mutation(
        "S7", GATE,
        'if [ "${system_surface_n}" -eq 0 ]; then',
        "if false; then",
        S_SWEEP_EMPTY, BASH_GATE,
        "THE SWEEP STOPS FAILING CLOSED. With the empty-surface guard gone, a "
        "run with no nim on PATH derives nothing, matches nothing against the "
        "tables and reports OK — Verification-Harness-Traps §4 exactly, "
        "inside the check written to escape it. This is the arm that makes "
        "'it fails closed' evidence rather than a sentence in a comment.",
        control_name="the emptiness test is written against the derived list",
        control_find='if [ "${system_surface_n}" -eq 0 ]; then',
        control_replace='if [ -z "$(grep -v \'^$\' <<<"${system_surface}")" ]; then',
    ),
]


# DECLARED SURVIVORS. Each is a mutation that this suite CANNOT kill, with the
# reason, so the gap is a line in the transcript rather than an absence.
DECLARED_SURVIVORS: list[Mutation] = [
    # EMPTY, AND THAT IS THE RESULT OF THE 2026-09-09 VERIFICATION PASS.
    #
    # This list held D1 — the second capability pass, removed at its call site
    # in `plugin_io` — with the reason "a hermetic suite cannot make the
    # resolver disagree with the literal", and the further claim that killing
    # it "needs a target that classifies as loopback and RESOLVES elsewhere".
    #
    # Both clauses were false, and the second is the instructive one: the
    # MIRROR is the easy direction. `127.1` classifies `acRemote` (it is not
    # four octets) and glibc resolves it to `127.0.0.1` (`acLoopback`), so
    # pass one PERMITS and pass two REFUSES — with no /etc/hosts edit, no DNS
    # and no resolver the suite did not already have. `::ffff:127.0.0.1`,
    # `2130706433` and `0x7f000001` are three more of the same shape.
    #
    # The arm is V3 now, and it kills. **A declared survivor is a claim about
    # the design, and this one turned out to be a claim about the test that
    # had not been written** — which is the general warning worth leaving
    # here: before declaring a survivor, ask whether the case you cannot
    # construct has a mirror you can.
]


@dataclass
class RunResult:
    rc: int = 0
    ran: bool = True
    passed: list[str] = None
    failed: list[str] = None

    def __post_init__(self):
        if self.passed is None:
            self.passed = []
        if self.failed is None:
            self.failed = []

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def run_suite(suite: Suite, label: str) -> RunResult:
    """Run one suite and parse its verdict out of its RESULT LINES."""
    res = RunResult()
    if suite.kind == "nim":
        compile_cmd = ["nim", "c", "-f", "--hints:off", "--warnings:off"]
        if suite.path.startswith("src/frontend/viewmodel/"):
            compile_cmd.append("--path:src/frontend/viewmodel")
        compile_cmd += [f"--nimcache:/tmp/plat8-mut-cache-{label}",
                        f"-o:{suite.binary}", suite.path]
        compile_proc = subprocess.run(compile_cmd, cwd=ROOT, capture_output=True,
                                      text=True, timeout=3600)
        if compile_proc.returncode != 0:
            res.rc = compile_proc.returncode
            res.ran = False
            print("      ---- did not compile; last 12 lines ----")
            for line in (compile_proc.stdout + compile_proc.stderr).splitlines()[-12:]:
                print("      " + line)
            return res
        proc = subprocess.run([suite.binary], cwd=ROOT, capture_output=True,
                              text=True, timeout=3600)
        pattern = NIM_RESULT
        good = "OK"
    else:
        proc = subprocess.run(["bash", suite.path], cwd=ROOT, capture_output=True,
                              text=True, timeout=3600)
        pattern = BASH_RESULT
        good = "ok"

    out = proc.stdout + proc.stderr
    res.rc = proc.returncode
    for line in out.splitlines():
        m = pattern.match(line)
        if m:
            (res.passed if m.group(1) == good else res.failed).append(m.group(2))
    if res.total == 0:
        res.ran = False
        print("      ---- no result lines; last 12 lines of output ----")
        for line in out.splitlines()[-12:]:
            print("      " + line)
    return res


def apply_once(path: str, find: str, replace: str) -> tuple[str, str]:
    """Return (original, error). The needle must occur exactly once."""
    p = ROOT / path
    original = p.read_text()
    n = original.count(find)
    if n != 1:
        return original, f"pattern occurs {n} times in {path}, expected 1"
    p.write_text(original.replace(find, replace))
    return original, ""


def restore(path: str, original: str) -> None:
    (ROOT / path).write_text(original)


def read_control_hashes() -> dict[str, str]:
    if not CONTROL_HASHES.exists():
        return {}
    out: dict[str, str] = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        h, _, p = line.partition("  ")
        if h and p:
            out[p] = h
    return out


def needle_scan() -> list[str]:
    """Every arm whose `find` or `control_find` does not occur EXACTLY ONCE.

    THE TRAP THIS EXISTS FOR, AND IT COST THIS HARNESS TWO ARMS. A mutation arm
    is a needle plus a replacement, and a LATER REPAIR can move the code the
    needle quotes. When it does, the arm stops describing anything: it can
    never be applied, so it can never be killed, and what it leaves behind is a
    row in the table that LOOKS like coverage. P6 and P26 both had this after
    the 2026-09-09 repairs rewrote the blocks they quoted; both were found by
    running this scan, not by review, and re-aimed.

    IT RUNS BEFORE `--record-control-hashes`, WHICH IS THE POINT. Re-recording
    digests is the moment a tree's new bytes are blessed as the baseline, and
    it is exactly the moment an arm's needle has just been moved. Recording
    first and scanning later is Verification-Harness-Traps trap 7 inside the
    verification step: the "correct" example is taken from the subject under
    suspicion. So the scan is a GATE on recording rather than a report beside
    it.
    """
    problems: list[str] = []
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        body = (ROOT / mut.path).read_text()
        for label, needle in (("find", mut.find),
                              ("control_find", mut.control_find)):
            if not needle:
                continue
            n = body.count(needle)
            if n != 1:
                problems.append(
                    f"{mut.id}: {label} occurs {n} time(s) in {mut.path}, "
                    f"expected exactly 1")
    return problems


def report_needle_scan() -> int:
    problems = needle_scan()
    if not problems:
        print(f"  all {len(MUTATIONS) + len(DECLARED_SURVIVORS)} arm(s) resolve "
              f"to exactly one needle and one control needle")
        return 0
    print("ARM NEEDLES DO NOT RESOLVE — nothing was mutated and nothing recorded.")
    for line in problems:
        print(f"  {line}")
    print("  An arm whose needle no longer occurs can never be applied and can")
    print("  never be killed; it sits in the table looking like coverage.")
    print("  Re-aim it at the code as it is now, then re-run.")
    return 2


def write_control_hashes() -> None:
    body = ["# Control digests for run-plat8-io-mutations.py.",
            "#",
            "# ABSOLUTE, and that is the point. A baseline taken at start-up",
            "# cannot tell a clean tree from one a killed run left a mutation",
            "# in: it reads the mutation as the baseline, every restore then",
            "# verifies against the mutated bytes, and the only symptom is",
            "# `CONTROL IS NOT GREEN` — which describes a red suite without",
            "# naming the cause.",
            "#",
            "# Rewrite with --record-control-hashes, deliberately, when the",
            "# SDK, the policy or a gate changes on purpose.",
            ""]
    for p in TOUCHED:
        body.append(f"{digest(p)}  {p}")
    CONTROL_HASHES.write_text("\n".join(body) + "\n")


def check_control_hashes() -> int:
    recorded = read_control_hashes()
    if not recorded:
        print(f"NO CONTROL HASHES: {CONTROL_HASHES.relative_to(ROOT)} is missing.")
        print("  Every restore below would verify against digests taken from")
        print("  THIS tree, so a mutation a killed run left behind would be")
        print("  adopted as the baseline. Record them from a tree you have")
        print("  checked, with --record-control-hashes.")
        return 2
    missing = [p for p in TOUCHED if p not in recorded]
    if missing:
        print(f"CONTROL HASHES INCOMPLETE: no entry for {missing}")
        print("  Re-record with --record-control-hashes.")
        return 2
    drifted = [p for p in TOUCHED if recorded.get(p) != digest(p)]
    if drifted:
        print("TREE IS NOT AT THE CONTROL BYTES — nothing was mutated.")
        for p in drifted:
            print(f"  {p}")
            print(f"      recorded {recorded[p]}")
            print(f"      on disk  {digest(p)}")
        print("  Either a previous run was killed before it restored, or one")
        print("  of these files changed on purpose. Check the diff, then")
        print("  re-record with --record-control-hashes.")
        return 2
    return 0


def install_signal_restore() -> None:
    """Turn SIGTERM/SIGHUP into an exception so `finally: restore(...)` runs."""

    def raise_on(signum, _frame):
        raise KeyboardInterrupt(f"signal {signum}")

    for sig in (signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, raise_on)
        except (ValueError, OSError):
            pass


def main() -> int:
    global MUTATIONS
    if "--needle-scan" in sys.argv[1:]:
        return report_needle_scan()

    if "--record-control-hashes" in sys.argv[1:]:
        # THE SCAN IS A GATE ON RECORDING, not a report beside it. See
        # `needle_scan`.
        rc = report_needle_scan()
        if rc:
            return rc
        write_control_hashes()
        print(f"recorded {len(TOUCHED)} control digest(s) in "
              f"{CONTROL_HASHES.relative_to(ROOT)}")
        return 0

    install_signal_restore()

    # THE LOCK IS TAKEN BEFORE THE HASH CHECK, and is held in a local for the
    # whole run: a garbage-collected file object closes its descriptor, and a
    # closed descriptor releases the flock.
    lock = acquire_lock()
    if lock is None:
        return 2

    rc = check_control_hashes()
    if rc:
        return rc

    # BEFORE ANY MUTATION, and for the same reason the killer pre-flight below
    # runs before any mutation: an arm that cannot be applied is not a failure
    # to discover half way through a forty-minute run.
    rc = report_needle_scan()
    if rc:
        return rc

    wanted = [a for a in sys.argv[1:] if not a.startswith("-")]
    selected = MUTATIONS + DECLARED_SURVIVORS
    if wanted:
        selected = [m for m in selected if m.id in wanted]
        missing = set(wanted) - {m.id for m in selected}
        if missing:
            print(f"no such arm(s): {sorted(missing)}")
            return 2
    kill_arms = [m for m in selected if m not in DECLARED_SURVIVORS]
    survivors = [m for m in selected if m in DECLARED_SURVIVORS]

    baseline = {p: digest(p) for p in TOUCHED}

    # THE SUITE SET IS DERIVED FROM THE ARMS, not written out beside them.
    # It was a literal list — `[NIM_CAPS, NIM_IO, BASH_GATE, BASH_SDK_GATE]` —
    # intersected with the arms' own suites, which is a second registry of the
    # same fact (Verification-Harness-Traps §14). Adding the A-arms' two suites
    # to `Suite` and forgetting this line produced a `KeyError` on the FIRST run
    # of the new arms, after the control phase had already spent the compile
    # time. Derived, a new suite cannot be forgotten and the failure mode does
    # not exist.
    suites = []
    seen_suite_paths = set()
    for m in selected:
        if m.suite.path not in seen_suite_paths:
            seen_suite_paths.add(m.suite.path)
            suites.append(m.suite)
    controls: dict[str, RunResult] = {}

    print("== control ==")
    for s in suites:
        r = run_suite(s, "control-" + Path(s.path).stem)
        if not r.ran or r.failed:
            print(f"CONTROL IS NOT GREEN for {s.path}: rc={r.rc} failed={r.failed}")
            return 1
        controls[s.path] = r
        print(f"  {s.path}: {r.total} cases, 0 failures")

    # EVERY KILLER MUST RESOLVE TO EXACTLY ONE GREEN CASE IN ITS OWN SUITE,
    # checked BEFORE any mutation. An arm whose killer does not is an arm that
    # can never legitimately be killed, and it would sit in the table looking
    # like coverage.
    problems = 0
    for mut in selected:
        matches = [c for c in controls[mut.suite.path].passed if c == mut.killer]
        if len(matches) != 1:
            print(f"{mut.id}: killer {mut.killer!r} resolves to {len(matches)} "
                  f"green case(s) in {mut.suite.path}, expected exactly 1")
            problems += 1
    if problems:
        print(f"\n{problems} unusable arm(s); nothing was mutated")
        return 1
    print(f"  all {len(selected)} killers resolve to exactly one green case\n")

    killed = 0
    for mut in selected:
        original, err = apply_once(mut.path, mut.find, mut.replace)
        if err:
            print(f"{mut.id:<5} HARNESS-FAILURE      {err}")
            problems += 1
            continue
        try:
            res = run_suite(mut.suite, f"{mut.id}-kill")
        finally:
            restore(mut.path, original)
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{mut.id:<5} HARNESS-FAILURE      {p} did not restore "
                          f"to its control bytes")
                    return 2

        declared = mut in survivors
        newly_failed = [f for f in res.failed
                        if f not in controls[mut.suite.path].failed]
        if not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif declared and newly_failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"now killed by {newly_failed}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", mut.why
        elif not newly_failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif mut.killer in newly_failed:
            others = [f for f in newly_failed if f != mut.killer]
            killed += 1
            verdict = "killed"
            note = mut.killer + (f"  (+{len(others)} more)" if others else "")
        else:
            verdict, note = "MISDIRECTED", f"died in {newly_failed}, not {mut.killer!r}"
            problems += 1
        print(f"{mut.id:<5} {verdict:<20} {note}")

        # --- the named behaviour-preserving control ------------------------
        if not mut.control_find:
            print(f"{'':<5} NO-CONTROL           this arm has no behaviour-preserving control")
            problems += 1
            continue
        original, err = apply_once(mut.path, mut.control_find, mut.control_replace)
        if err:
            print(f"{'':<5} CONTROL-HARNESS-FAILURE  {err}")
            problems += 1
            continue
        try:
            cres = run_suite(mut.suite, f"{mut.id}-control")
        finally:
            restore(mut.path, original)
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{mut.id:<5} HARNESS-FAILURE      {p} did not restore "
                          f"after the control")
                    return 2
        c_newly_failed = [f for f in cres.failed
                          if f not in controls[mut.suite.path].failed]
        if not cres.ran:
            print(f"{'':<5} CONTROL-DID-NOT-RUN  {mut.control_name}")
            problems += 1
        elif c_newly_failed:
            print(f"{'':<5} CONTROL-RED          {mut.control_name} -> {c_newly_failed}")
            problems += 1
        else:
            print(f"{'':<5} control green        {mut.control_name}")

    print(f"\n{killed} killed, {len(survivors)} declared survivor(s), "
          f"{problems} problems")
    # THE LOCK IS NAMED HERE ON PURPOSE. It is held by an open descriptor and
    # nothing else reads the variable, so a tidying pass would delete the
    # binding and silently re-open the concurrency hole it exists to close.
    print(f"run lock held for the whole run: {LOCK_PATH.name} (fd {lock.fileno()})")
    lock.close()
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
