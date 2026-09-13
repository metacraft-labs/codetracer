#!/usr/bin/env python3
"""Mutation harness for PLAT-13's executable tier of a project definition.

WHAT THIS COVERS. Project-Definitions.md §2.3 (the per-repository trust grant,
recorded by identity, revocable, visible, and not implied by any other trust
decision), §2's rule that cloning and opening must execute nothing, §6's
per-FILE gate, and §7's requirement that a project-supplied comparison be total
and bounded with the offender reported and the structural comparison used
instead. Five subject files, two suites.

WHY THE ARMS CAN BE AIMED AT "EXECUTING" HERE, WHERE PLAT-11'S COULD NOT.
PLAT-11's harness header says its arms are aimed at four PROPERTIES rather than
at the sentinel, because that milestone made executing INEXPRESSIBLE — there was
no `if` to mutate and an arm aimed at "the sentinel did not appear" could never
be killed. PLAT-13 is the milestone where executing becomes expressible, so the
gate is a real branch with a real failure mode: arm D1 removes it, the module
runs, and `ExecutionNeedle` comes back through a load that was given no grant.
That arm is the reason this harness exists.

FIVE VERDICTS, NOT TWO (Verification-Harness-Traps §1a and §17):

  killed           the named case reported [FAILED] **and** the failure output
                   carries the arm's own `because`
  MIS-ATTRIBUTED   the named case went red, but not for the arm's reason — it
                   died upstream of the mutated line (§17). This sits beside
                   HARNESS-FAILURE rather than beside `killed`, because like it
                   the run told you nothing
  SURVIVED         the run produced result lines and the named case was green
  SUITE-DIED       the run produced result lines and the named case is in
                   NEITHER list — the binary died before reaching it
  HARNESS-FAILURE  the mutation did not apply, did not compile, or the run
                   produced NO result lines at all

Verdicts are parsed out of `[OK]` / `[FAILED]` RESULT LINES, never out of an
exit status: `nim c -r` returns the same non-zero code for a compile error, a
failed assertion and an OOM.

EVERY KILL ARM CARRIES A NAMED BEHAVIOUR-PRESERVING CONTROL in the same file,
applied on its own, which must leave the suite GREEN. A renamed local, a hoisted
binding, a swapped disjunction, a bound written as arithmetic.

EVERY ARM'S `because` IS CHECKED AGAINST THE CONTROL RUN, BEFORE ANY MUTATION. A
`because` that already occurs in a passing run is true for free.

AND A `because` GOES STALE THE WAY §16'S NEEDLE DOES, WITH NO SCAN THAT SEES IT.
`--needle-scan` checks `find` and `control_find` — the quotations of the CODE. A `because`
is a quotation of the FAILURE TEXT, and `unittest` prints the assertion's AST as
SUBSTITUTED at the call site, so a repair that changes an argument at the call site moves
it. Measured on 2026-09-13: D4 and S4 both quoted `visualisedBy(pulled) == ""`, a
verification pass gave `visualisedBy` a second parameter, and both arms scored
MIS-ATTRIBUTED over mutations that killed their cases exactly as intended — §17a's false
negative in the mis-attribution detector, arriving through an ordinary rename. THE ONLY
INSTRUMENT FOR THIS IS RUNNING THE ARM, which is §16a's own conclusion.

A `because` IS A QUOTATION OF THE FAILURE TEXT, NOT OF THE SOURCE
(Verification-Harness-Traps §17a). `unittest.check` stringifies the AST it
receives and a template's body is substituted before it gets there, so a
`because` reaching through `ck`/`ckEq` quotes the expression AS SUBSTITUTED at
the call site, and no `because` in this file names a template-local `let` —
`sawWanted` and `leaked` print as ``sawWanted`gensymNNN``, whose NUMBER IS NOT
STABLE ACROSS COMPILATIONS. The arms that grade a `ckRefusedWith` or a
`ckNoNeedle` quote the CHECKPOINT text those helpers print instead, which is
ordinary text and is stable.

PREFER A `because` THAT QUOTES THE EFFECT (§17a). Where an arm can be attributed
either to a status or to the needle sweep, it is attributed to the needle.

AND FOUR `{.cursor.}` ANNOTATIONS WERE DELETED RATHER THAN ARMED, WHICH IS §16a APPLIED
TO THIS HARNESS'S OWN OUTPUT. Arm W20 removed the annotation from `enter`'s `let fn` and
SURVIVED. The reason is that Nim 2.2.8's ORC already infers a cursor there, so the explicit
one was a second mechanism with no arm that could kill it — a row that looks like coverage.
Measured on 2026-09-13 by removing each annotation in turn and then all four at once:
`enter`'s `fn` and `ft`, `ret`'s `rft` and `ft0` are all flat (7.4-9.0 ms at every body
length), while `runExportIn`'s `body` and `opCall`'s `callee` are the 7,819.8 ms and
3,390.8 ms ORC rows. The four redundant annotations are gone from the subject, W20 is gone from
this table, and W18/W19 grade the two that are load-bearing. **The PROPERTY is held by the
CASES, which measure cost per instruction and per call and do not care which mechanism
delivers it** — which is why deleting the redundant mechanism costs no coverage.

AND THE MEMORY MANAGER IS AN INPUT TO EVERY TIMING ABOVE. W18, W19 and W20 are about
`let x = someSeq`, which is a COPY under ORC and a REFCOUNT BUMP under refc — so every
millisecond in this file is an ORC number, and that is not incidental: this harness runs
`nim c` with no `--mm`, which is Nim 2.x's default ORC, and so does the `common-units` lane
that carries the two long-body cases W18/W19 are killed by. The `ct-cli-units` lane compiles
`--mm:refc`, and every SHIPPED binary is refc as well (`repro.nim`'s `ctNative` and
`ctNimJs` both pass `mm = "refc"`; `src/Tuprules.tup` passes `--mm:refc`). Measured on
2026-09-13, same host, same fixtures, best of seven, work bound 200,001, `spent` identical
at 200,002 in every row:

                             annotated (shipped)   annotations removed
    orc  paddedLoop 8,005          7.3 ms              7,819.8 ms
    refc paddedLoop 8,005         21.8 ms                 22.6 ms
    orc  paddedCallee 8,003       11.4 ms              3,390.8 ms
    refc paddedCallee 8,003       35.8 ms                 36.7 ms

So W18 and W19 grade a defect that was REAL in `common-units` and was never present in the
shipped `ct`. They are arms worth keeping — the annotations cost nothing, the lane that runs
the cases is ORC, and a future build that switches to ORC would meet the defect — but an arm
is only ever killed under the memory manager its case is compiled with, and a `because`
quoting a millisecond count is quoting one more input than it names.

TWO LINES IN THIS CAMPAIGN'S SUBJECTS CARRY NO ARM, DELIBERATELY, and they are
named here rather than left to be noticed: `O_NOFOLLOW` and the `(dev, ino)`
comparison in `project_executable_tier.readVerified`. The path opened is
`realpath(3)`'s own output, so it contains no symlink in any position by
construction and neither line can fire without a swap RACING the check — an arm
whose kill condition needs a winning race is Verification-Harness-Traps §10's
assertion that cannot fail, wearing a stopwatch. PLAT-11 measured the same pair
in the same shape; PLAT-13's status section carries this pass's own measurement
rather than citing it.

AND ONE MORE IS UNARMABLE FOR A DIFFERENT REASON, WHICH IS WORTH THE SENTENCE:
the work bound itself. An arm that removes `spend`'s comparison does not
terminate — the fixture it would be graded against is a `loop br 0` — so it
cannot be run at all. What IS graded is every charge site (W10, W11, W12) and
the bound's exact behaviour at the boundary (W9, which turns `>` into `>=` and
kills the equality `spent == MaxExecutableWork + 1`).

ONLY ONE INSTANCE MAY RUN IN A WORKTREE, enforced with an exclusive `flock`
taken BEFORE the control-hash check.

AND NEVER BESIDE A SIBLING HARNESS. PLAT-11's residue 12 and PLAT-12's residue 9
record the rule and the reason: a harness's SUITES compile files another harness
MUTATES, so a lock that serialises writers does nothing for readers. This
harness's suites compile `plugin_model/capabilities.nim` (PLAT-8's subject),
`project_definitions/*` (PLAT-11's) and `launch/grant_store.nim` (PLAT-10's).
Never two at once.

THE CONTROL HASHES ARE RECORDED ON DISK, NOT TAKEN AT START-UP. A baseline taken
at start-up reads a mutation a killed run left behind as the baseline.

THE NEEDLE SCAN GATES `--record-control-hashes` (Verification-Harness-Traps
§16): re-recording is exactly the moment an arm's needle has just been moved by
the repair that made the re-record necessary. And §16a: re-recording is not the
last step — a repair that TIGHTENS can disarm an arm whose needle still
resolves, so the arms are RE-RUN after every repair.

Usage (from the repository root):
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat13-executable-mutations.py

`-u` matters when the output is redirected: python otherwise block-buffers
stdout and a log stays empty until the last arm.

Arms naming one case are run individually:
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat13-executable-mutations.py D1 T2
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

TRUST = "src/common/project_trust.nim"
WASM = "src/common/project_wasm.nim"
EXEC = "src/common/project_executables.nim"
STORE = "src/ct/launch/project_trust_store.nim"
TIER = "src/ct/launch/project_executable_tier.nim"

TOUCHED = [TRUST, WASM, EXEC, STORE, TIER]

PURE_SUITE = "src/common/project_trust_test.nim"
CLI_SUITE = "src/ct/launch/project_executable_tier_test.nim"

CONTROL_HASHES = HERE / "plat13-executable-mutation-control.sha256"
LOCK_PATH = HERE / ".plat13-executable-mutation.lock"

NIM_RESULT = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*)$")


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

# `src/common/project_trust_test.nim`
P_REFUSED = "every I/O request an executable definition could make is refused"
P_FLOOR = "the floor is the empty set, and it is a PROPER subset of every grant"
P_DEFAULT = "the default is REFUSED, and it is the enum's zero value"
P_COPY = "a grant is for ONE checkout: another identity inherits nothing"
P_PERFILE = "a grant is for ONE file: the other executable file is undecided"
P_BYTES = "a grant is for THOSE BYTES: the file changing is a separate decision"
P_REVOKE = "revocation is recorded, survives a re-grant attempt, and is reversible"
P_PREREVOKE = "revoking a file nobody ever granted is RECORDED, not dropped"
P_DECLARATIVE = "a declarative file is not grantable, and asking is answered"
P_NOIDENT = "a checkout with no identity is refused, and never granted"
P_TWOPHASE = "the two phases of the decision read ONE predicate"
P_DISCLOSE = "the disclosure names the checkout, the file and the bytes"
P_LEDGERLINES = "an unusable line is a PROBLEM and the usable ones survive"
P_IMPORT = "a module that asks the host for a function is REFUSED, by name"
P_SECTIONS = "every section this build does not implement is refused BY ID"
P_SUBSET = "a value type, a block type and an opcode outside the subset are refused"
P_HOSTILE = "a hostile encoding is refused before it becomes an allocation"
P_CONTROLFLOW = "the subset's control flow does what WebAssembly says it does"
P_BOUNDED = "a non-terminating comparison is bounded rather than hanging a pane"
P_SPENT = "`spent` counts the WORK, and every unit of a small run is enumerable"
P_TRAPS = "a trap is a VALUE, and each kind is its own answer"
P_FALLBACK = "a §7 diff that does not answer falls back, and names the OFFENDER"
P_ANSWERS = "a §7 diff that DOES answer is the project's, and says so"
P_DOOR = "without an admission the bytes are not even DECODED"
P_ADMISSIONS = "every refusal the door can give is a distinct, reportable answer"
P_ENTRY = "a module missing the host's entry point is refused, not trapped"
P_OUTPUT = "an answer the host will not take is refused, and the value still shows"
P_UNITLOOP = "a body 1,600x longer spends the same AND takes the same time"
P_UNITCALL = "a CALL to a long-bodied function costs the same as a call to a short one"
P_FORGED = "a NEWLINE in the note is refused, and the forged row is a real one"
P_ANYFIELD = "every field is closed, not only the note"
P_ANNOTATION = "a path that cannot be a field loses its ANNOTATION, never its grant"
P_SIXFIELDS = "a row with more than six fields is a PROBLEM, not a rejoined note"
P_ZEROVALUE = "the ZERO VALUE of every decision type is the refusing one"
P_HELDPURE = "a revoke reaches a handle somebody is holding, asserted THROUGH it"
P_HELDDIFF = "a §7 comparison from a held handle falls back once the grant is gone"
P_NOPAGES = "a module that declares NO memory is refused, not indexed out of bounds"
P_RETEMPTY = "a function that declares a result and leaves nothing is a TRAP"
P_OUTERFRAME = "a callee cannot take an OUTER frame's operands"
P_DOUBLEELSE = "a second 'else' decodes, and falling out of the 'then' arm TRAPS"
P_LOCALSBOUND = "the locals bound is tested BEFORE the locals are allocated"
P_BODYCOUNT = "more code bodies than declared functions is refused, not indexed"
P_HUGEIMM = ("an immediate past 2^31-1 is refused, not narrowed into a "
             "RangeDefect")
P_STACKBOUND = ("an operand stack past its bound is a TRAP, not a seq that "
                "keeps growing")

# `src/ct/launch/project_executable_tier_test.nim`
C_NOGRANT = "an executable definition with no grant is not run — on the EFFECT"
C_NOOPEN = "with no grant the file is not OPENED — the syscall that did not happen"
C_RUNS = "a granted definition RUNS, which is what makes the refusals mean something"
C_COPY = "a COPY of a granted checkout is not granted"
C_MOVED = "MOVING a granted checkout keeps its grant and re-grants nothing"
C_REPLACED = "a DIFFERENT repository later at the same path inherits nothing"
C_IDENT = "a checkout that cannot be identified is refused, not guessed at"
C_REVOKED = "after a revoke the running path produces nothing, and no needle"
C_CHANGED = "the file changing after a grant is a separate decision, on the EFFECT"
C_SYMLINK = "a checked-in symlink cannot make the host run bytes from outside"
C_OVERSIZE = "an oversized module is refused by its SIZE, before it is read"
C_SCOPE = "a definition in a package scope outside the checkout is refused"
C_DIFF = "a real diff definition answers, and a non-terminating one falls back"
C_STORE = "it sits beside the plugin ledger and leaves no staging file behind"
C_HELD = "a HELD handle stops running, asserted through the handle itself"
C_INJECT = "a newline in a real directory name records ONE decision, not two"
C_UNRECORDED = ("a decision that could not be recorded is reported, and the "
                "code says so")
C_NOTACHECKOUT = ("and a SCAN of a root that is not a checkout says so, rather "
                  "than being silent")


@dataclass
class Suite:
    path: str
    binary: str


NIM_PURE = Suite(PURE_SUITE, "/tmp/plat13-mut-pure")
NIM_CLI = Suite(CLI_SUITE, "/tmp/plat13-mut-cli")


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    suite: Suite
    because: str
    why: str = ""
    control_name: str = ""
    control_find: str = ""
    control_replace: str = ""


MUTATIONS: list[Mutation] = [
    # -----------------------------------------------------------------------
    # D — the gate itself. §2: "Cloning a repository and opening it in
    # CodeTracer must not execute code from that repository."
    # -----------------------------------------------------------------------
    Mutation(
        "D1", TIER,
        "  if not permission.permitted:",
        "  if false:",
        C_NOOPEN, NIM_CLI, "Check failed: not sawUnreadable",
        "THE READ GATE. With it gone the executable definition of a repository "
        "nobody granted is OPENED — which the case sees as an `EACCES` reported "
        "about a file a no-grant load must not have touched. Attributed to that "
        "rather than to the needle (§17a's preference for the effect, and the "
        "effect here is a syscall that happened): the digest phase downstream "
        "still refuses the RUN, so removing this line alone leaks no bytes. "
        "That is defence in depth and §16a's own shape — the two phases have "
        "disjoint evidence precisely so neither can be removed silently",
        control_name="the permission is tested through a named boolean",
        control_find="  if not permission.permitted:",
        control_replace="  let mayOpen = permission.permitted\n  if not mayOpen:",
    ),
    # -- F2, 2026-09-13: the reader's own §5a --------------------------------
    Mutation(
        "V8", TIER,
        "  if not dirExists(resolvedRoot):",
        "  if false:",
        C_NOTACHECKOUT, NIM_CLI,
        "Check failed: describeScan(absent).contains(\"is not a directory this machine can\")",
        "THE READER GOES BACK TO SILENCE. `readExecutableDefinition` returned "
        "with no problem for two different events — 'this repository ships no "
        "executable definitions', which almost every repository is and which is "
        "correct to be silent about, and 'this is not a checkout I can read at "
        "all', which is a failure — and `describeScan` gave both the sentence a "
        "healthy checkout gets. Verification-Harness-Traps §5a on the READER's "
        "side. It fails CLOSED, so no refusal assertion in this campaign could "
        "ever have seen it, and the `because` therefore quotes the REPORT a "
        "scan gives rather than any status: nothing else in this suite "
        "produces that sentence",
        control_name="the root's directory-ness is read into a named binding",
        control_find="  if not dirExists(resolvedRoot):",
        control_replace="  let rootIsDir = dirExists(resolvedRoot)\n"
                        "  if not rootIsDir:",
    ),
    Mutation(
        "D2", TIER,
        "  if resolvedFile.len == 0 or resolvedFile != expected:",
        "  if false:",
        C_SYMLINK, NIM_CLI, "the needle came back:",
        "a checked-in symlink at `.codetracer/visualisers.wasm` makes the host "
        "read and run bytes from outside the repository — the escape PLAT-11 "
        "measured in the DECLARATIVE reader, where the consequence was a leaked "
        "read and here is an execution",
        control_name="the two halves of the placement rule are tested in the other order",
        control_find="  if resolvedFile.len == 0 or resolvedFile != expected:",
        control_replace="  if resolvedFile != expected or resolvedFile.len == 0:",
    ),
    Mutation(
        "D3", TIER,
        "  if size > MaxWasmBytes:",
        "  if false:",
        C_OVERSIZE, NIM_CLI,
        'Check failed: describeScan(scan).contains("costs a stat rather than a read")',
        "an oversized module is read into memory before anything refuses it — "
        "a denial of service with a polite error message, from a file a "
        "repository ships",
        control_name="the size bound is written as an inequality the other way round",
        control_find="  if size > MaxWasmBytes:",
        control_replace="  if not (size <= MaxWasmBytes):",
    ),
    Mutation(
        "D4", TIER,
        "  let admission = admit(ledger, identity, kind, digest)",
        "  let admission = etaAdmitted",
        C_CHANGED, NIM_CLI,
        "pulled.definitions.len was 1",
        "the digest stops binding the grant to the bytes at LOAD time, so a "
        "`git pull` that replaces the module produces a definition the user "
        "consented to nothing about. ATTRIBUTED TO THE DEFINITION EXISTING, "
        "not to what it renders, and that is §16a rather than a preference: "
        "the 2026-09-13 repair made `visualiseWith` re-ask the ledger before it "
        "runs, so the module is refused a SECOND time at run time and the "
        "needle never comes back — which disarmed this arm's original evidence "
        "while its needle still resolved. What only the LOAD-time admission "
        "gives is that the bytes are never decoded and the handle never exists",
        control_name="the admission's inputs are bound before it is asked",
        control_find="  let admission = admit(ledger, identity, kind, digest)",
        control_replace="  let subject = digest\n"
                        "  let admission = admit(ledger, identity, kind, subject)",
    ),
    Mutation(
        "D5", TIER,
        "  result.identity = checkoutIdentity(root)",
        '  result.identity = "fs1:one-identity-for-every-checkout"',
        C_RUNS, NIM_CLI, "Check failed: scan.problems.len == 0",
        "the SCAN stops asking which checkout it is in, so the identity a grant "
        "was recorded against and the identity a load is judged by are two "
        "different things and no grant ever matches. It fails in the SAFE "
        "direction, which is exactly why it needs an arm: nothing would go red "
        "except a user's own definitions silently never applying "
        "(Verification-Harness-Traps §15)",
        control_name="the identity is bound before it is stored",
        control_find="  result.identity = checkoutIdentity(root)",
        control_replace="  let here = checkoutIdentity(root)\n"
                        "  result.identity = here",
    ),
    Mutation(
        "D6", TIER,
        "    if pathProblem(scope) != ppOk:",
        "    if false:",
        C_SCOPE, NIM_CLI,
        "wanted etcNotContained for '../elsewhere/.codetracer'",
        "a package scope may leave the checkout, so §6's monorepo composition "
        "becomes the channel an executable definition outside the repository "
        "arrives through",
        control_name="the scope verdict is read into a named binding",
        control_find="    if pathProblem(scope) != ppOk:",
        control_replace="    let verdict = pathProblem(scope)\n"
                        "    if verdict != ppOk:",
    ),

    # -----------------------------------------------------------------------
    # T — the trust model. §2.3's three clauses.
    # -----------------------------------------------------------------------
    Mutation(
        "T1", TRUST,
        "  of tsUndecided: etaNoGrant",
        "  of tsUndecided: etaAdmitted",
        P_DEFAULT, NIM_PURE, "wanted etaNoGrant, got etaContentChanged",
        "THE DEFAULT BECOMES GRANTED. A repository nobody has decided about is "
        "admitted, which is `tasks.json`'s model and the one §2 exists to not "
        "repeat",
        control_name="the undecided answer is produced through a block",
        control_find="  of tsUndecided: etaNoGrant",
        control_replace="  of tsUndecided: (block: etaNoGrant)",
    ),
    Mutation(
        "T2", TRUST,
        "  of tsRevoked: etaRevoked",
        "  of tsRevoked: etaAdmitted",
        P_REVOKE, NIM_PURE, "wanted etaRevoked, got etaContentChanged",
        "a revocation stops meaning anything: the record says REVOKED and the "
        "decision says admitted, which is PLAT-10's own defect — `resolveAll()` "
        "handing a revoked capability back from an un-narrowed parse",
        control_name="the revoked answer is produced through a block",
        control_find="  of tsRevoked: etaRevoked",
        control_replace="  of tsRevoked: (block: etaRevoked)",
    ),
    Mutation(
        "T4", TRUST,
        "  if granted.len == 0 or digest.len == 0 or granted != digest:",
        "  if granted != digest:",
        P_BYTES, NIM_PURE, "wanted etaContentChanged, got etaAdmitted",
        "AN EMPTY DIGEST BECOMES A WILDCARD. A grant recorded with no digest, "
        "or a file whose digest could not be computed, admits — which is the "
        "one direction this decision may not fail in",
        control_name="the three refusing conditions are tested in another order",
        control_find="  if granted.len == 0 or digest.len == 0 or granted != digest:",
        control_replace="  if granted != digest or digest.len == 0 or granted.len == 0:",
    ),
    Mutation(
        "T5", TRUST,
        "  if tierOf(kind) != dtExecutable: return etaNotExecutableTier",
        "  if false: return etaNotExecutableTier",
        P_DECLARATIVE, NIM_PURE,
        "wanted etaNotExecutableTier, got etaNoGrant",
        "the tier stops being a property of the FILE (§6), so asking about "
        "`points.toml` is answered as though a declarative definition needed a "
        "trust decision — and a ledger could carry rows for files that need none",
        control_name="the tier is read into a named binding",
        control_find="  if tierOf(kind) != dtExecutable: return etaNotExecutableTier",
        control_replace="  let tier = tierOf(kind)\n"
                        "  if tier != dtExecutable: return etaNotExecutableTier",
    ),
    Mutation(
        "T6", TRUST,
        "  if identity.len == 0: return etaNoIdentity",
        "  if false: return etaNoIdentity",
        P_NOIDENT, NIM_PURE, "wanted etaNoIdentity, got etaNoGrant",
        "a checkout with no identity is decided about rather than refused — and "
        "with the ledger's own empty-identity guard removed too it would be "
        "every unidentifiable checkout sharing one row",
        control_name="the identity's emptiness is tested through a named binding",
        control_find="  if identity.len == 0: return etaNoIdentity",
        control_replace="  let anonymous = identity.len == 0\n"
                        "  if anonymous: return etaNoIdentity",
    ),
    Mutation(
        "T7", TRUST,
        "      return (if e.decision == tdGranted: e.digest else: \"\")",
        "      return e.digest",
        P_REVOKE, NIM_PURE,
        "handBuilt.grantedDigest(IdentityA, dfkVisualiserCode) was sha256:",
        "a revoked entry goes on reporting the digest it was granted over, so "
        "anything asking what is trusted after a revocation is told the old "
        "answer",
        control_name="the decision is compared the other way round",
        control_find="      return (if e.decision == tdGranted: e.digest else: \"\")",
        control_replace="      return (if e.decision != tdGranted: \"\" else: e.digest)",
    ),
    Mutation(
        "T8", TRUST,
        "  if ledger.stateOf(identity, kind) == tsRevoked: return troUnchanged",
        "  if false: return troUnchanged",
        P_REVOKE, NIM_PURE, "Check failed: led.entries.len == 2",
        "a revocation is appended on every call, so a session that revokes "
        "defensively at every launch grows the ledger without bound",
        control_name="the current state is read into a named binding",
        control_find="  if ledger.stateOf(identity, kind) == tsRevoked: "
                     "return troUnchanged",
        control_replace="  let current = ledger.stateOf(identity, kind)\n"
                        "  if current == tsRevoked: return troUnchanged",
    ),
    Mutation(
        "T9", TRUST,
        "  if tierOf(kind) != dtExecutable: return troNotExecutableTier\n"
        "  if identity.len == 0: return troNoIdentity\n"
        "  if digest.len == 0: return troNoDigest",
        "  if identity.len == 0: return troNoIdentity\n"
        "  if digest.len == 0: return troNoDigest",
        P_DECLARATIVE, NIM_PURE,
        "led.grant(IdentityA, dfkPoints, DigestOne, AtOne) was troRecorded",
        "a declarative file becomes grantable, so `describe` can tell a user "
        "they trusted something that never needed trusting — and the trust gate "
        "stops being a property of the file",
        control_name="the grant's tier test is written as a positive",
        control_find="  if tierOf(kind) != dtExecutable: return troNotExecutableTier\n"
                     "  if identity.len == 0: return troNoIdentity\n"
                     "  if digest.len == 0: return troNoDigest",
        control_replace="  if not (tierOf(kind) == dtExecutable):\n"
                        "    return troNotExecutableTier\n"
                        "  if identity.len == 0: return troNoIdentity\n"
                        "  if digest.len == 0: return troNoDigest",
    ),
    Mutation(
        "T10", TRUST,
        "      result.problems.add \"line \" & $lineNo & \": '\" & parts[2] &\n"
        "        \"' is a declarative definition. It loads without a decision, so a \" &\n"
        "        \"trust row for it would be a decision about nothing\"\n"
        "      continue",
        "      discard",
        P_LEDGERLINES, NIM_PURE, "Check failed: parsed.ledger.entries.len == 1",
        "a hand-edited ledger row naming `points.toml` is kept, so a file that "
        "needs no decision acquires one and a user reading `describe` is shown it",
        control_name="the declarative-row refusal is written through a named reason",
        control_find="    if tierOf(kind) != dtExecutable:",
        control_replace="    let rowTier = tierOf(kind)\n"
                        "    if rowTier != dtExecutable:",
    ),
    Mutation(
        "T11", TRUST,
        "    \"' from the checkout at \" & checkoutPath & \".\\n\" &",
        "    \"' from a checkout.\\n\" &",
        P_DISCLOSE, NIM_PURE, "Check failed: text.contains(\"/src/demo\")",
        "the disclosure stops naming the checkout it is about, so a user with "
        "two clones of one repository is asked a question they cannot answer",
        control_name="the disclosure's opening is built through a named binding",
        control_find="    \"' from the checkout at \" & checkoutPath & \".\\n\" &",
        control_replace="    \"' from the checkout at \" & (block: checkoutPath) & \".\\n\" &",
    ),
    Mutation(
        "T12", TRUST,
        "  ExecutableTierGrants* = GrantSet()",
        "  ExecutableTierGrants* = GrantSet(capabilities: {capFsRead},\n"
        "                                   readPaths: @[\"/\"])",
        P_REFUSED, NIM_PURE, "Check failed: not d.permitted",
        "§2.3's floor stops being the empty set: an executable definition — "
        "code from a repository the user may not have read — holds a capability "
        "a PLUGIN would have had to declare and a user would have had to grant",
        control_name="the empty grant set is written with its empty capability set",
        control_find="  ExecutableTierGrants* = GrantSet()",
        control_replace="  ExecutableTierGrants* = GrantSet(capabilities: {})",
    ),
    # -----------------------------------------------------------------------
    # E — the crossing. The only door, and what it does when the code misbehaves.
    # -----------------------------------------------------------------------
    Mutation(
        "E1", EXEC,
        "  if not admits(admission):",
        "  if false:",
        P_DOOR, NIM_PURE, "Check failed: refused.problem.code == etcNoGrant",
        "THE DOOR STOPS ASKING. Bytes from a repository with no grant reach "
        "`decodeModule` — a parser over hostile input — which is why the "
        "ordering is the deliverable and not tidiness: `we parsed it but did "
        "not run it` still exposes the parser",
        control_name="the admission is tested through a named boolean",
        control_find="  if not admits(admission):",
        control_replace="  let permitted = admits(admission)\n  if not permitted:",
    ),
    Mutation(
        "E2", TRUST,
        "  a == etaAdmitted",
        "  a != etaNotExecutableTier",
        P_ADMISSIONS, NIM_PURE,
        "Check failed: not refused.ok",
        "`admits` widens to everything except one value, so four of the five "
        "refusals admit — the shape a `case` with an `else` produces, arriving "
        "through a one-line predicate instead",
        control_name="the admitted value is compared through a named constant",
        control_find="  a == etaAdmitted",
        control_replace="  (block:\n    const Permitted = etaAdmitted\n    a == Permitted)",
    ),
    Mutation(
        "E3", EXEC,
        "  if a == b: dvEqual else: dvDifferent",
        "  dvEqual",
        P_FALLBACK, NIM_PURE,
        "Check failed: differing.verdict == dvDifferent",
        "§7's fallback stops being a comparison and becomes a constant, so a "
        "pane whose project definition looped reports every pair of values as "
        "equal — worse than the hang it replaced, because it is silent",
        control_name="the structural verdict is produced through named branches",
        control_find="  if a == b: dvEqual else: dvDifferent",
        control_replace="  (if a != b: dvDifferent else: dvEqual)",
    ),
    Mutation(
        "E4", EXEC,
        "    result.fromDefinition = false\n    return",
        "    result.fromDefinition = true\n    return",
        P_FALLBACK, NIM_PURE, "Check failed: not answer.fromDefinition",
        "a fallback is reported as the project's own answer, so §7's "
        "\"reports the offender\" becomes a fallback nobody can audit — and a "
        "definition that never answers looks like one that always does",
        control_name="the fallback flag is written through a named value",
        control_find="    result.fromDefinition = false\n    return",
        control_replace="    let answered = false\n"
                        "    result.fromDefinition = answered\n    return",
    ),
    Mutation(
        "E5", EXEC,
        "    result.offender = d.file & \"#\" & entry\n"
        "    result.fromDefinition = false",
        "    result.offender = \"\"\n"
        "    result.fromDefinition = false",
        P_FALLBACK, NIM_PURE,
        "Check failed: answer.offender == \".codetracer/diffs.wasm#\" & DiffExport",
        "§7 asks the host to \"report the offender by name\" and the name goes "
        "away, so a user is told a comparison failed and not which file to look at",
        control_name="the offender is composed through a named binding",
        control_find="    result.offender = d.file & \"#\" & entry\n"
                     "    result.fromDefinition = false",
        control_replace="    let named = d.file & \"#\" & entry\n"
                        "    result.offender = named\n"
                        "    result.fromDefinition = false",
    ),
    Mutation(
        "E6", EXEC,
        "  if at < 0 or at >= run.instance.memory.len:",
        "  if false:",
        P_OUTPUT, NIM_PURE, "Check failed: not seen.fromDefinition",
        "a module returning an address outside its own memory is believed, so "
        "the host reads whatever `readCString` makes of an out-of-range index — "
        "the one place a sandbox's answer crosses back into the host",
        control_name="the returned address is range-tested the other way round",
        control_find="  if at < 0 or at >= run.instance.memory.len:",
        control_replace="  if not (at >= 0 and at < run.instance.memory.len):",
    ),
    Mutation(
        "E7", EXEC,
        "  if text.len > MaxExecutableTextBytes:",
        "  if false:",
        P_OUTPUT, NIM_PURE, "Check failed: not cut.fromDefinition",
        "the module decides how long the host's answer is: a definition that "
        "never writes a terminator has its whole memory read back as a summary "
        "line, and the bound the declarative tier obeys is not applied to code",
        control_name="the text bound is written as an inequality the other way round",
        control_find="  if text.len > MaxExecutableTextBytes:",
        control_replace="  if not (text.len <= MaxExecutableTextBytes):",
    ),
    Mutation(
        "E8", EXEC,
        "  of dfkDiffCode: DiffExport",
        "  of dfkDiffCode: VisualiserExport",
        P_ENTRY, NIM_PURE,
        "Check failed: exportFor(dfkDiffCode) == DiffExport",
        "the ABI stops being a property of the file kind, so a diff definition "
        "is called through the visualiser's entry point — with the visualiser's "
        "arity, which is a refusal a user cannot act on",
        control_name="the diff export is named through its constant",
        control_find="  of dfkDiffCode: DiffExport",
        control_replace="  of dfkDiffCode: (block: DiffExport)",
    ),

    # -----------------------------------------------------------------------
    # W — the sandbox. The allow-list of nothing, and the bound.
    # -----------------------------------------------------------------------
    Mutation(
        "W1", WASM,
        "      let n = c.u32leb()\n      if c.failed: break\n      if n != 0:",
        "      c.pos = payloadEnd\n      let n = 0\n      if false:",
        P_IMPORT, NIM_PURE,
        "wanted wpcImportDeclared, got a DECODED module",
        "THE WHOLE SANDBOX. A module may declare imports, so a project ships "
        "one asking for `wasi_snapshot_preview1.fd_write` — which is what a "
        "real toolchain emits by default — and the boundary §2.3 rests on is "
        "gone. No denylist anywhere else in this file replaces it",
        control_name="the import count is read into a named binding",
        control_find="      let n = c.u32leb()\n      if c.failed: break\n      if n != 0:",
        control_replace="      let n = c.u32leb()\n      if c.failed: break\n"
                        "      let declaredImports = n\n"
                        "      if declaredImports != 0:",
    ),
    Mutation(
        "W3", WASM,
        "  else: (opNop, false)",
        "  else: (opNop, true)",
        P_SUBSET, NIM_PURE,
        "wanted wpcUnsupportedOpcode, got a DECODED module",
        "AN UNRECOGNISED-AND-IGNORED ARM, in a binary format. Every opcode "
        "outside the subset becomes a `nop`, so `memory.grow`, `call_indirect` "
        "and the float family are accepted and silently do nothing — a module "
        "that means one thing to its producer and another to this interpreter",
        control_name="the unknown-opcode answer is built through a named tuple",
        control_find="  else: (opNop, false)",
        control_replace="  else: (block:\n    let unknown = (opNop, false)\n    unknown)",
    ),
    Mutation(
        "W4", WASM,
        "      if bt != 0x40:",
        "      if false:",
        P_SUBSET, NIM_PURE,
        "wanted wpcUnsupportedBlockType, got a DECODED module",
        "a block may carry a result type, so a label carries values and every "
        "branch in the interpreter — which truncates the operand stack to the "
        "label's recorded height — silently discards them",
        control_name="the block type is read into a named binding",
        control_find="      if bt != 0x40:",
        control_replace="      let emptyBlock = bt == 0x40\n      if not emptyBlock:",
    ),
    Mutation(
        "W5", WASM,
        "  if b != 0x7F:",
        "  if false:",
        P_SUBSET, NIM_PURE, "wanted wpcUnsupportedType, got a DECODED module",
        "every value type is read as `i32`, so an `i64` or an `f64` parameter "
        "is accepted and the interpreter runs a module whose operands are not "
        "the operands it thinks they are",
        control_name="the value type byte is compared through a named constant",
        control_find="  if b != 0x7F:",
        control_replace="  const I32Byte = 0x7F\n  if b != I32Byte:",
    ),
    Mutation(
        "W6", WASM,
        "    if read >= 5:\n      c.fail(wpcMalformedInteger,\n"
        "             \"an unsigned integer longer than five bytes\")",
        "    if read >= 5000:\n      c.fail(wpcMalformedInteger,\n"
        "             \"an unsigned integer longer than five bytes\")",
        P_HOSTILE, NIM_PURE, "wanted wpcMalformedInteger, got",
        "the LEB128 bound stops bounding: a continuation bit set for ever reads "
        "the whole file as one integer, which is the cheapest denial of service "
        "a binary format has",
        control_name="the LEB128 byte bound is written as arithmetic",
        control_find="    if read >= 5:\n      c.fail(wpcMalformedInteger,\n"
                     "             \"an unsigned integer longer than five bytes\")",
        control_replace="    if read >= 4 + 1:\n      c.fail(wpcMalformedInteger,\n"
                        "             \"an unsigned integer longer than five bytes\")",
    ),
    Mutation(
        "W7", WASM,
        "      if id <= lastSection:",
        "      if false:",
        P_HOSTILE, NIM_PURE, "wanted wpcSectionOutOfOrder, got a DECODED module",
        "sections may repeat and may arrive in any order, so a module can carry "
        "two code sections and a producer and this decoder disagree about which "
        "one is the module",
        control_name="the section order is tested the other way round",
        control_find="      if id <= lastSection:",
        control_replace="      if not (id > lastSection):",
    ),
    Mutation(
        "W8", WASM,
        "        if minPages > MaxWasmPages:",
        "        if false:",
        P_HOSTILE, NIM_PURE, "wanted wpcTooLarge, got a DECODED module",
        "a module declares its own memory size, and the pages are ZEROED at "
        "instantiation — so a definition a repository ships chooses how much "
        "the host writes before a single instruction retires",
        control_name="the page bound is written as an inequality the other way round",
        control_find="        if minPages > MaxWasmPages:",
        control_replace="        if not (minPages <= MaxWasmPages):",
    ),
    Mutation(
        "W9", WASM,
        "    if result.spent > work:",
        "    if result.spent >= work:",
        P_BOUNDED, NIM_PURE,
        "Check failed: run.spent == MaxExecutableWork + 1",
        "the bound fires one unit early, so what `spent` REPORTS after the "
        "allowance is gone is no longer the allowance plus the one unit that "
        "crossed it. PLAT-12's lesson: what a bound says about itself after it "
        "is reached is a claim too, and it was overstating by ~77x",
        control_name="the bound is tested through a named comparison",
        control_find="    if result.spent > work:",
        control_replace="    let overspent = result.spent > work\n    if overspent:",
    ),
    Mutation(
        "W10", WASM,
        "  spend(ft0.params.len + m.functions[fi].localTypes.len)",
        "  spend(0)",
        P_SPENT, NIM_PURE, "run.spent was 65628",
        "a frame's locals stop being charged, so `newSeq[int32](n)` with `n` "
        "the MODULE's number is free — the exact shape PLAT-12 spent four "
        "rounds on, a quantity the input multiplies that the counter cannot see",
        control_name="the entry frame's local count is bound before it is charged",
        control_find="  spend(ft0.params.len + m.functions[fi].localTypes.len)",
        control_replace="  let entrySlots = ft0.params.len + m.functions[fi].localTypes.len\n"
                        "  spend(entrySlots)",
    ),
    Mutation(
        "W11", WASM,
        "  result.spent = spentAlready",
        "  result.spent = 0",
        P_SPENT, NIM_PURE, "run.spent was 94",
        "what the caller already spent — instantiating the module and writing "
        "the host's input into it — is thrown away, so the allowance a run "
        "starts with is not the allowance it has used",
        control_name="the carried charge is bound before it is stored",
        control_find="  result.spent = spentAlready",
        control_replace="  let carried = spentAlready\n  result.spent = carried",
    ),
    Mutation(
        "W12", WASM,
        "  m.memoryPages * WasmPageSize\n",
        "  0\n",
        P_SPENT, NIM_PURE,
        "Check failed: decoded.module.instantiationCost == 65536",
        "zeroing the module's pages is free, so a module declaring the maximum "
        "memory pays nothing for a quarter-megabyte of writes the host does "
        "before it runs",
        control_name="the instantiation cost is written as a named product",
        control_find="  m.memoryPages * WasmPageSize\n",
        control_replace="  let pages = m.memoryPages\n  pages * WasmPageSize\n",
    ),
    Mutation(
        "W13", WASM,
        "        result.trap = wtOutOfBounds",
        "        result.trap = wtUnreachable",
        P_TRAPS, NIM_PURE, "trap: wtOutOfBounds",
        "a load or store outside the module's own memory is reported as "
        "`unreachable`, so the one trap that says the sandbox's boundary was "
        "TESTED is indistinguishable from the module choosing to stop",
        control_name="the out-of-bounds trap is named through a constant",
        control_find="        result.trap = wtOutOfBounds",
        control_replace="        const OutOfRange = wtOutOfBounds\n"
                        "        result.trap = OutOfRange",
    ),
    Mutation(
        "W14", WASM,
        "      if a == low(int32) and b == -1'i32:\n"
        "        # WASM DEFINES THIS AS A TRAP",
        "      if false:\n"
        "        # WASM DEFINES THIS AS A TRAP",
        P_TRAPS, NIM_PURE, "trap: wtIntegerOverflow",
        "`INT32_MIN div -1` stops being the trap wasm defines and becomes Nim's "
        "own overflow Defect, which unwinds out of the interpreter and takes "
        "the host with it — a sandbox whose failure mode is a Defect is not one",
        control_name="the overflow operands are tested in the other order",
        control_find="      if a == low(int32) and b == -1'i32:\n"
                     "        # WASM DEFINES THIS AS A TRAP",
        control_replace="      if b == -1'i32 and a == low(int32):\n"
                        "        # WASM DEFINES THIS AS A TRAP",
    ),
    Mutation(
        "W15", WASM,
        "      nextPc = int(ins.target)\n    of opEnd:",
        "      nextPc = frames[^1].pc + 1\n    of opEnd:",
        P_CONTROLFLOW, NIM_PURE,
        "Check failed: equalArm.value == 1015",
        "falling out of a `then` arm runs the `else` arm as well, so every "
        "`if`/`else` in a project's code executes both branches and the last "
        "one wins",
        control_name="the else arm's destination is bound before it is taken",
        control_find="      nextPc = int(ins.target)\n    of opEnd:",
        control_replace="      let afterElse = int(ins.target)\n"
                        "      nextPc = afterElse\n    of opEnd:",
    ),
    Mutation(
        "W16", WASM,
        "      if frames.len == 0:\n"
        "        result.ok = true\n"
        "        result.value = (if rft.results.len == 1: rv else: 0)\n"
        "        return\n"
        "      continue",
        "      if frames.len == 0:\n"
        "        result.ok = true\n"
        "        result.value = (if rft.results.len == 1: rv else: 0)\n"
        "        return\n"
        "      discard",
        P_CONTROLFLOW, NIM_PURE, "Check failed: equalArm.ok",
        "a return from a called function writes the CALLEE's next instruction "
        "index over the CALLER's, so control resumes in the wrong function — "
        "the `continue` in `ret` is load-bearing and its absence compiles",
        control_name="the frame count is tested through a named binding",
        control_find="      if frames.len == 0:\n"
                     "        result.ok = true\n"
                     "        result.value = (if rft.results.len == 1: rv else: 0)\n"
                     "        return\n"
                     "      continue",
        control_replace="      let outermost = frames.len == 0\n"
                        "      if outermost:\n"
                        "        result.ok = true\n"
                        "        result.value = (if rft.results.len == 1: rv else: 0)\n"
                        "        return\n"
                        "      continue",
    ),
    Mutation(
        "W17", WASM,
        "        if lbl.isLoop:",
        "        if false:",
        P_ANSWERS, NIM_PURE,
        "Check failed: other.verdict == dvDifferent",
        "a branch to a loop label jumps PAST the loop instead of back to it, so "
        "every loop in a project's code runs one iteration — a comparison over "
        "two buffers then reports on their first byte",
        control_name="the label kind is read into a named binding",
        control_find="        if lbl.isLoop:",
        control_replace="        let backwards = lbl.isLoop\n        if backwards:",
    ),

    # -----------------------------------------------------------------------
    # S — the store. Identity, and the file PLAT-10's machinery writes.
    # -----------------------------------------------------------------------
    Mutation(
        "S1", STORE,
        "    result = \"fs1:\" & $info.id.device & \":\" & $info.id.file",
        "    result = \"fs1:\" & root",
        C_REPLACED, NIM_CLI,
        "Check failed: checkoutIdentity(w.root) != granted",
        "§2.3's \"recorded by identity rather than by path\", inverted in one "
        "line: a different repository later at the same path inherits the grant "
        "the user gave the one that used to be there",
        control_name="the identity's two components are bound before they are joined",
        control_find="    result = \"fs1:\" & $info.id.device & \":\" & $info.id.file",
        control_replace="    let dev = $info.id.device\n"
                        "    let file = $info.id.file\n"
                        "    result = \"fs1:\" & dev & \":\" & file",
    ),
    Mutation(
        "S2", STORE,
        "    if info.kind != pcDir: return \"\"",
        "    if false: return \"\"",
        C_IDENT, NIM_CLI,
        "Check failed: checkoutIdentity(w.root / definitionPath(\"\", dfkVisualiserCode)) == \"\"",
        "a FILE gets a checkout identity, so a grant can be recorded against "
        "something that is not a checkout and the ledger's key stops meaning "
        "what `describe` says it means",
        control_name="the directory test is written as a positive",
        control_find="    if info.kind != pcDir: return \"\"",
        control_replace="    if not (info.kind == pcDir): return \"\"",
    ),
    Mutation(
        "S3", STORE,
        "    let info = getFileInfo(root, followSymlink = true)",
        "    let info = getFileInfo(root, followSymlink = false)",
        C_IDENT, NIM_CLI,
        "Check failed: checkoutIdentity(alias) == checkoutIdentity(w.root)",
        "two names for one checkout become two checkouts, so a user who reaches "
        "their repository through a symlink one day and directly the next is "
        "asked to grant it twice — and learns to grant reflexively, which is "
        "the same as not having a gate. THIS ARM COULD NOT BE KILLED UNTIL THE "
        "REDUNDANT `expandFilename` WAS DELETED: two resolvers meant either one "
        "could go (§16a)",
        control_name="the checkout path is bound before it is stat'ed",
        control_find="    let info = getFileInfo(root, followSymlink = true)",
        control_replace="    let named = root\n"
                        "    let info = getFileInfo(named, followSymlink = true)",
    ),
    Mutation(
        "S4", STORE,
        "  \"sha256:\" & toLowerAscii($sha256.digest(bytes))",
        "  \"sha256:one-digest-for-every-file\"",
        C_CHANGED, NIM_CLI,
        "Check failed: visualisedBy(w, pulled) == \"\"",
        "the content digest stops depending on the content, so every file "
        "inherits every grant — the weakest possible binding, and one that "
        "looks exactly like the real thing in the ledger. FIRST WRITTEN AS "
        "`$bytes.len` AND IT SURVIVED: the two fixture modules differ in "
        "length, so a length-keyed digest still told them apart. An arm has to "
        "remove the dependence, not weaken it",
        control_name="the digest's hex is produced through a named binding",
        control_find="  \"sha256:\" & toLowerAscii($sha256.digest(bytes))",
        control_replace="  (block:\n"
                        "    let hex = toLowerAscii($sha256.digest(bytes))\n"
                        "    \"sha256:\" & hex)",
    ),
    Mutation(
        "S5", STORE,
        "    moveFile(staging, path)",
        "    copyFile(staging, path)",
        C_STORE, NIM_CLI,
        "Check failed: not name.contains(\".tmp.\")",
        "the write stops being atomic against a crash: the ledger is COPIED "
        "over rather than renamed, so a reader can see a prefix of it — and a "
        "truncated ledger loads as FEWER grants, which is safe, and as a lost "
        "revocation, which is not",
        control_name="the staging path is bound before it is renamed",
        control_find="    moveFile(staging, path)",
        control_replace="    let finished = staging\n    moveFile(finished, path)",
    ),
    Mutation(
        "S6", STORE,
        "  withGrantLedgerLock(path):\n"
        "    var current = loadProjectTrustFrom(path).ledger",
        "  block:\n"
        "    var current = loadProjectTrustFrom(path).ledger",
        C_STORE, NIM_CLI,
        "Check failed: \"projects.tsv.lock\" in listed",
        "the read-modify-write stops being serialised, so two processes that "
        "each load the same ledger both save and the file carries whichever was "
        "written last. No file is torn; one decision is simply gone — and if "
        "the lost one is a revoke, the code runs again at the next start",
        control_name="the ledger path is bound before the lock is taken",
        control_find="  withGrantLedgerLock(path):\n"
                     "    var current = loadProjectTrustFrom(path).ledger",
        control_replace="  let ledgerPath = path\n"
                        "  withGrantLedgerLock(ledgerPath):\n"
                        "    var current = loadProjectTrustFrom(ledgerPath).ledger",
    ),
    Mutation(
        "S7", STORE,
        "  sibling.parentDir / projectTrustFileName",
        "  sibling",
        C_STORE, NIM_CLI,
        "Check failed: path == w.userRoot / \"grants\" / \"v1\" / \"projects.tsv\"",
        "the project trust ledger becomes PLAT-10's plugin ledger: two records "
        "keyed on different things in one table, and each reader reporting the "
        "other's rows as unusable lines",
        control_name="the sibling's directory is bound before the name is joined",
        control_find="  sibling.parentDir / projectTrustFileName",
        control_replace="  let dir = sibling.parentDir\n  dir / projectTrustFileName",
    ),
]

# --- the arms whose needles span several lines -----------------------------
#
# T3, W2, S8, T1b and T2b are written here rather than in the table above, so
# that the table stays readable as a table. They are ordinary arms in every
# other respect, and `needle_scan` carries a duplicate-id check so that an arm
# written in both places — which would be applied twice — is refused before
# anything is mutated rather than discovered mid-run.

MUTATIONS.extend([
    Mutation(
        "T3", TRUST,
        "    if e.identity == identity and e.kind == kind:\n"
        "      return (if e.decision == tdGranted: tsGranted else: tsRevoked)",
        "    if e.kind == kind:\n"
        "      return (if e.decision == tdGranted: tsGranted else: tsRevoked)",
        P_COPY, NIM_PURE,
        "Check failed: led.stateOf(IdentityB, dfkVisualiserCode) == tsUndecided",
        "THE KEY STOPS BEING THE CHECKOUT. A grant for one repository answers "
        "for every repository, so a byte-identical copy of a checkout somebody "
        "trusted — or any other checkout at all — runs its code",
        control_name="the two halves of the key are tested in the other order",
        control_find="    if e.identity == identity and e.kind == kind:\n"
                     "      return (if e.decision == tdGranted: tsGranted else: tsRevoked)",
        control_replace="    if e.kind == kind and e.identity == identity:\n"
                        "      return (if e.decision == tdGranted: tsGranted else: tsRevoked)",
    ),
    Mutation(
        "W2", WASM,
        "    of 4:\n      c.fail(wpcUnsupportedSection,\n"
        "             \"a table section. This build implements no indirect calls, so a \" &\n"
        "             \"table has nothing to hold\")",
        "    of 4:\n      c.pos = payloadEnd",
        P_SECTIONS, NIM_PURE,
        "Check failed: decoded.problem.code == wpcUnsupportedSection",
        "a section this build does not implement is SKIPPED rather than "
        "refused, which is the \"unrecognised, ignored\" arm PLAT-11's parser "
        "deliberately has nowhere — arriving in a binary format, where the "
        "thing skipped is a function table",
        control_name="the table refusal's message is built through a named binding",
        control_find="    of 4:\n      c.fail(wpcUnsupportedSection,\n"
                     "             \"a table section. This build implements no indirect calls, so a \" &\n"
                     "             \"table has nothing to hold\")",
        control_replace="    of 4:\n"
                        "      let why = \"a table section. This build implements no indirect \" &\n"
                        "                \"calls, so a table has nothing to hold\"\n"
                        "      c.fail(wpcUnsupportedSection, why)",
    ),
    Mutation(
        "S8", STORE,
        "    result = \"fs1:\" & $info.id.device & \":\" & $info.id.file\n"
        "  except CatchableError, Defect:",
        "    result = \"fs1:one-identity-for-every-checkout\"\n"
        "  except CatchableError, Defect:",
        C_COPY, NIM_CLI, "the needle came back:",
        "EVERY CHECKOUT ON THE MACHINE SHARES ONE IDENTITY, so granting one "
        "repository grants them all and a byte-identical COPY of a checkout "
        "somebody trusted runs its code. This is the arm that falsifies the "
        "needle sweep for the copy case: `ExecutionNeedle` comes back out of a "
        "load of a checkout nobody granted. It mutates the STORE rather than "
        "the scan, which is why it leaks where D5 does not — the grant and the "
        "load then agree on the wrong answer instead of disagreeing",
        control_name="the identity's two components are joined through a named value",
        control_find="    result = \"fs1:\" & $info.id.device & \":\" & $info.id.file\n"
                     "  except CatchableError, Defect:",
        control_replace="    let composed = \"fs1:\" & $info.id.device & \":\" & $info.id.file\n"
                        "    result = composed\n"
                        "  except CatchableError, Defect:",
    ),
    Mutation(
        "T1b", TRUST,
        "  of tsUndecided: etaNoGrant",
        "  of tsUndecided: etaAdmitted",
        C_NOGRANT, NIM_CLI,
        "wanted etcNoGrant for '.codetracer/visualisers.wasm'",
        "T1's mutation, graded END TO END instead of at the policy level. "
        "PLAT-8 pairs its arms this way (P1/P1b, P2/P2b) for the reason it "
        "gives: a policy that says `refused` and a call site that proceeds "
        "anyway are indistinguishable from the policy suite alone. Here the "
        "load of an ungranted checkout opens the file and reaches the digest "
        "phase, which refuses it for the WRONG reason — a user is told their "
        "file changed when what happened is that they never granted it",
        control_name="the undecided answer is produced through a block (end to end)",
        control_find="  of tsUndecided: etaNoGrant",
        control_replace="  of tsUndecided: (block: etaNoGrant)",
    ),
    Mutation(
        "T2b", TRUST,
        "  of tsRevoked: etaRevoked",
        "  of tsRevoked: etaAdmitted",
        C_REVOKED, NIM_CLI,
        "wanted etcRevoked for '.codetracer/visualisers.wasm'",
        "T2's mutation, graded through the path that RUNS things rather than "
        "through the record — PLAT-10's own defect, where `resolveAll()` "
        "rebuilt from an un-narrowed parse and handed a revoked capability back "
        "while the record said REVOKED. A revoked checkout reaches the digest "
        "phase and is refused there, so a user who withdrew a grant is told "
        "their file changed",
        control_name="the revoked answer is produced through a block (end to end)",
        control_find="  of tsRevoked: etaRevoked",
        control_replace="  of tsRevoked: (block: etaRevoked)",
    ),
])

# --- the arms this verification pass's repairs brought with them -----------
#
# Verification-Harness-Traps §16a: a repair that TIGHTENS is a reason to write
# arms, not only to re-record digests. Every guard below either did not exist
# before 2026-09-13 or had no case that reached it, and five of them are the
# difference between a REFUSAL and a Defect raised out of the host.

MUTATIONS.extend([
    Mutation(
        "W18", WASM,
        "    let body {.cursor.} = m.functions[fnIdx].body",
        "    let body = m.functions[fnIdx].body",
        P_UNITLOOP, NIM_PURE, "the retired-instruction cost: 5 instruction(s) took",
        "THE BOUND'S UNIT STOPS BEING O(1), UNDER ORC. Copying the function "
        "body once per retired instruction makes a run cost "
        "O(instructions x body length) while `spent` reports O(instructions) — "
        "7.3 ms to 7,819.8 ms at a body of 8,005 (this harness's own build, "
        "`nim c`, ORC), with `spent` IDENTICAL at 200,002, and 66.9 s through "
        "`diffWith` on an 8 KB module reporting 1,000,001 of 1,000,000. Under "
        "refc — every shipped binary, and the `ct-cli-units` lane — the same "
        "line is a refcount bump and the same fixture moves 21.8 ms to 22.6 ms, "
        "so this arm grades a defect that was real in `common-units` and was "
        "never in a shipped `ct`. Nothing "
        "in W9-W12 can see it: `spent` is a correct count of a unit whose COST "
        "changed, and the §7 fixture's body is five instructions, so the suite "
        "that measured `spent` had an amplification factor of one",
        control_name="the body's function index is bound before it is aliased",
        control_find="    let body {.cursor.} = m.functions[fnIdx].body",
        control_replace="    let aliased = fnIdx\n"
                        "    let body {.cursor.} = m.functions[aliased].body",
    ),
    Mutation(
        "W19", WASM,
        "      let callee {.cursor.} = m.functions[int(ins.imm)]",
        "      let callee = m.functions[int(ins.imm)]",
        P_UNITCALL, NIM_PURE, "the call cost: 11 instruction(s) took",
        "W18's defect one level up, and ORC-only for the same reason: a CALL "
        "copies the callee's whole `WasmFunction`, so a call costs O(callee "
        "body length) against a charge of O(params + locals). 11.4 ms to "
        "3,390.8 ms at a callee body of 8,003 under ORC; 35.8 ms to 36.7 ms "
        "under refc, where the same binding is a refcount bump",
        control_name="the callee's index is bound before it is aliased",
        control_find="      let callee {.cursor.} = m.functions[int(ins.imm)]",
        control_replace="      let calleeIdx = int(ins.imm)\n"
                        "      let callee {.cursor.} = m.functions[calleeIdx]",
    ),
    Mutation(
        "W21", WASM,
        "    if stack.len - base < ft.params.len: return false",
        "    if stack.len < ft.params.len: return false",
        P_OUTERFRAME, NIM_PURE, "run.trap was wtStackUnderflow",
        "the operand test goes back to reading the WHOLE stack rather than the "
        "caller's own frame, so a callee can take an OUTER frame's operands — "
        "which wasm's validator forbids and this interpreter has no second "
        "check for. It is total either way, which is why it needs an arm: "
        "nothing crashes and nothing reports",
        control_name="the caller's base is compared through a named height",
        control_find="    if stack.len - base < ft.params.len: return false",
        control_replace="    let available = stack.len - base\n"
                        "    if available < ft.params.len: return false",
    ),
    Mutation(
        "W22", WASM,
        "  if at < 0 or at + data.len > inst.memory.len: return false",
        "  if false: return false",
        P_NOPAGES, NIM_PURE, 'Check failed: not inst.writeBytes(-1, "")',
        "THE HOST INDEXES OUT OF BOUNDS ON A GRANTED, WELL-FORMED MODULE. A "
        "definition declaring zero pages is admitted, exports what the host "
        "calls, and the host then writes its input at 1,024 into a memory of "
        "length zero — an `IndexDefect` unwound out of the interpreter. A "
        "sandbox whose failure mode is a Defect takes the host down with it",
        control_name="the write's range is tested the other way round",
        control_find="  if at < 0 or at + data.len > inst.memory.len: return false",
        control_replace="  if not (at >= 0 and at + data.len <= inst.memory.len): return false",
    ),
    Mutation(
        "W23", WASM,
        "        if stack.len <= frames[^1].stackBase:\n"
        "          result.trap = wtStackUnderflow\n"
        "          return",
        "        if false:\n"
        "          result.trap = wtStackUnderflow\n"
        "          return",
        P_RETEMPTY, NIM_PURE, "Unhandled exception: index out of bounds, the container is empty [IndexDefect]",
        "`ret` reads `stack[^1]` on an empty operand stack, so a function that "
        "declares a result and leaves nothing takes the host down. It is a "
        "DIFFERENT guard from the `pop()` template — that one refuses a pop "
        "below the frame's base, this one a RETURN with nothing to return — and "
        "each therefore needs a module only it refuses (§16a)",
        control_name="the frame's base is compared through a named height",
        control_find="        if stack.len <= frames[^1].stackBase:\n"
                     "          result.trap = wtStackUnderflow\n"
                     "          return",
        control_replace="        let above = stack.len - frames[^1].stackBase\n"
                        "        if above <= 0:\n"
                        "          result.trap = wtStackUnderflow\n"
                        "          return",
    ),
    Mutation(
        "W24", WASM,
        "          if localCount > MaxWasmLocals:",
        "          if false:",
        P_LOCALSBOUND, NIM_PURE, "wanted wpcTooLarge, got a DECODED module",
        "THE LOCALS BOUND STOPS BOUNDING, AND IT IS TESTED BEFORE AN APPEND. "
        "The declared count is a `u32`, so `2^31-1` is two billion `seq.add`s "
        "at DECODE time — before any work bound exists to stop them — and the "
        "host is gone. The case grades it at 257 and 100,000 so the arm is "
        "killed in milliseconds rather than hanging the harness, which is the "
        "same reason trap 1 asks a hang arm to be a hang on purpose",
        control_name="the running local count is compared through a named bound",
        control_find="          if localCount > MaxWasmLocals:",
        control_replace="          let overLocals = localCount > MaxWasmLocals\n"
                        "          if overLocals:",
    ),
    Mutation(
        "W25", WASM,
        "      if n != typeCounts.len:",
        "      if false:",
        P_BODYCOUNT, NIM_PURE, "Unhandled exception: index 1 not in 0 .. 0 [IndexDefect]",
        "`typeCounts[i]` is indexed once per code body, so a module declaring "
        "one function and shipping two bodies indexes past the end of a `seq` "
        "in the HOST — a decode-time Defect from a file a repository ships",
        control_name="the two counts are compared through a named equality",
        control_find="      if n != typeCounts.len:",
        control_replace="      let counted = n == typeCounts.len\n"
                        "      if not counted:",
    ),
    Mutation(
        "W26", WASM,
        "    if frames[^1].pc < 0 or frames[^1].pc >= body.len:",
        "    if false:",
        P_DOUBLEELSE, NIM_PURE, "Unhandled exception: index -1 not in 0 .. 12 [IndexDefect]",
        "THE GUARD THAT SAID IT WAS UNREACHABLE. `if / else / else / end` "
        "decodes, the FIRST `else` keeps `target = -1` because the matching "
        "`end` resolves the second one, and falling out of the `then` arm lands "
        "there with `pc = -1`. Without the guard that is `body[-1]` in the "
        "host. The comment claiming nothing could reach it was removed on "
        "2026-09-13; the guard stayed, and now has a module that reaches it",
        control_name="the program counter is range-tested through a named binding",
        control_find="    if frames[^1].pc < 0 or frames[^1].pc >= body.len:",
        control_replace="    let pc = frames[^1].pc\n"
                        "    if pc < 0 or pc >= body.len:",
    ),

    # --- the ledger's closed grammar --------------------------------------
    Mutation(
        "T13", TRUST,
        "    if c == TrustFieldSeparator or c == '\\n' or c == '\\r': return false",
        "    if false: return false",
        P_FORGED, NIM_PURE, "parseTrustLedger(led.render()).ledger.entries.len was 2",
        "ONE `grant` CALL RECORDS TWO DECISIONS. The ledger is one row per line "
        "with a tab between fields and the default note is the CHECKOUT PATH, "
        "so a directory name carrying a newline and five tab-separated fields "
        "appends a second, perfectly well-formed row — against a checkout the "
        "user decided nothing about. §2.3 and `grant`'s own doc both say ONE "
        "repository, ONE file, ONE digest",
        control_name="the forbidden characters are tested through a named set",
        control_find="    if c == TrustFieldSeparator or c == '\\n' or c == '\\r': return false",
        control_replace="    const Forbidden = {'\\n', '\\r'}\n"
                        "    if c == TrustFieldSeparator or c in Forbidden: return false",
    ),
    Mutation(
        "T13b", TRUST,
        "  if representableField(path): path else: UnrepresentablePathNote",
        "  path",
        C_INJECT, NIM_CLI, "hostileScan.definitions.len was 0",
        "`pathAnnotation`'S OWN EVIDENCE, WHICH IS NOT THE INJECTION (§16a). "
        "Two mechanisms stand between a hostile checkout path and a forged "
        "row, and `representableField` — graded by T13 — refuses the FIELD on "
        "its own. What only `pathAnnotation` does is keep the GRANT: without "
        "it, `record` refuses the whole row and the user's decision is "
        "silently lost, which is Verification-Harness-Traps §15 exactly — a "
        "repair failing in the safe direction, with every security assertion "
        "MORE satisfied and nothing anywhere going red. Measured: with this "
        "mutation the ledger holds ZERO entries, the hostile checkout's own "
        "definition never loads, and its code never runs",
        control_name="the annotation's verdict is read into a named binding",
        control_find="  if representableField(path): path else: UnrepresentablePathNote",
        control_replace="  let writable = representableField(path)\n"
                        "  if writable: path else: UnrepresentablePathNote",
    ),
    Mutation(
        "T14", TRUST,
        "    if parts.len < 5 or parts.len > 6:",
        "    if parts.len < 5:",
        P_SIXFIELDS, NIM_PURE, "parsed.ledger.entries.len was 1",
        "the reader goes back to rejoining `parts[5 .. ^1]`, which is a decoder "
        "for an encoding the writer can no longer emit — so a seven-field row "
        "becomes a note instead of a refusal, and the writer's grammar and the "
        "reader's stop being the same grammar",
        control_name="the field count is bounded through a named range test",
        control_find="    if parts.len < 5 or parts.len > 6:",
        control_replace="    let fields = parts.len\n"
                        "    if fields < 5 or fields > 6:",
    ),
    Mutation(
        "T15", TRUST,
        "    etaNoGrant\n"
        "      ## No decision has ever been recorded. THE DEFAULT, and the zero value.\n"
        "    etaAdmitted\n",
        "    etaAdmitted\n"
        "    etaNoGrant\n"
        "      ## No decision has ever been recorded. THE DEFAULT, and the zero value.\n",
        P_ZEROVALUE, NIM_PURE, "low(ExecutableTierAdmission) was etaAdmitted",
        "`default(ExecutableTierAdmission)` becomes PERMISSION — an "
        "uninitialised field, a `var` nobody assigned, a `seq` grown with "
        "`setLen`. This is PLAT-12's `Visualiser.tier` two types along, and it "
        "is latent by construction: no site default-constructs one today, which "
        "is exactly how PLAT-12's arrived",
        control_name="the admitted value keeps its ordinal through an explicit one",
        control_find="    etaNoGrant\n"
                     "      ## No decision has ever been recorded. THE DEFAULT, and the zero value.\n"
                     "    etaAdmitted\n",
        control_replace="    etaNoGrant = 0\n"
                        "      ## No decision has ever been recorded. THE DEFAULT, and the zero value.\n"
                        "    etaAdmitted = 1\n",
    ),
    Mutation(
        "T16", TRUST,
        "    tdRevoked = \"revoke\"\n    tdGranted = \"grant\"",
        "    tdGranted = \"grant\"\n    tdRevoked = \"revoke\"",
        P_ZEROVALUE, NIM_PURE, "low(TrustDecision) was grant",
        "`default(TrustDecision)` becomes a GRANT, so a `TrustEntry` nobody "
        "filled in is a decision to trust rather than a decision not to. The "
        "two enums are separate arms because they are separate declarations: "
        "fixing one and leaving the other is exactly what happened to "
        "`TrustState` and these two",
        control_name="the decisions keep their ordinals through explicit ones",
        control_find="    tdRevoked = \"revoke\"\n    tdGranted = \"grant\"",
        control_replace="    tdRevoked = (0, \"revoke\")\n    tdGranted = (1, \"grant\")",
    ),

    # --- a held handle -----------------------------------------------------
    Mutation(
        "E9", EXEC,
        "  let current = d.stillAdmitted(trust)\n"
        "  if not admits(current):\n"
        "    result.problems.add problem(d.file, codeFor(current),",
        "  let current = etaAdmitted\n"
        "  if not admits(current):\n"
        "    result.problems.add problem(d.file, codeFor(current),",
        P_HELDPURE, NIM_PURE, "after.text was EXECUTABLE-TIER-RAN-ct-plat13",
        "A HELD HANDLE OUTLIVES ITS GRANT. `ExecutableDefinition.module` IS the "
        "cached parse, so a definition already loaded goes on running after the "
        "user withdrew the decision — PLAT-10's `resolveAll()` one tier up, and "
        "the thing `trustDisclosure` promises does not happen in the words a "
        "user reads: \"withdrawing it stops the code running rather than only "
        "recording that you changed your mind\". NOTHING THAT RE-LOADS CAN SEE "
        "THIS, which is why the case asserts through the handle",
        control_name="the current admission is read through a named binding",
        control_find="  let current = d.stillAdmitted(trust)\n"
                     "  if not admits(current):\n"
                     "    result.problems.add problem(d.file, codeFor(current),",
        control_replace="  let live = d.stillAdmitted(trust)\n"
                        "  let current = live\n"
                        "  if not admits(current):\n"
                        "    result.problems.add problem(d.file, codeFor(current),",
    ),
    Mutation(
        "E10", EXEC,
        "  let current = d.stillAdmitted(trust)\n"
        "  if not admits(current):\n"
        "    fallBack(codeFor(current),",
        "  let current = etaAdmitted\n"
        "  if not admits(current):\n"
        "    fallBack(codeFor(current),",
        P_HELDDIFF, NIM_PURE, "Check failed: not answer.fromDefinition",
        "E9's defect on §7's comparison. Separate arm because it is a separate "
        "entry point: `visualiseWith` and `diffWith` both re-ask, and an arm on "
        "one says nothing about the other",
        control_name="the diff's current admission is read through a named binding",
        control_find="  let current = d.stillAdmitted(trust)\n"
                     "  if not admits(current):\n"
                     "    fallBack(codeFor(current),",
        control_replace="  let live = d.stillAdmitted(trust)\n"
                        "  let current = live\n"
                        "  if not admits(current):\n"
                        "    fallBack(codeFor(current),",
    ),
    Mutation(
        "E9b", EXEC,
        "  let current = d.stillAdmitted(trust)\n"
        "  if not admits(current):\n"
        "    result.problems.add problem(d.file, codeFor(current),",
        "  let current = etaAdmitted\n"
        "  if not admits(current):\n"
        "    result.problems.add problem(d.file, codeFor(current),",
        C_HELD, NIM_CLI, "after.text was EXECUTABLE-TIER-RAN-ct-plat13",
        "E9's mutation graded END TO END, against a real ledger on disk and a "
        "handle taken out of a real scan before the revoke — PLAT-8's P1/P1b "
        "pairing, and the reason it gives: a policy that says `refused` and a "
        "call site that runs anyway are indistinguishable from the policy suite "
        "alone",
        control_name="the current admission is read through a named binding (end to end)",
        control_find="  let current = d.stillAdmitted(trust)\n"
                     "  if not admits(current):\n"
                     "    result.problems.add problem(d.file, codeFor(current),",
        control_replace="  let live = d.stillAdmitted(trust)\n"
                        "  let current = live\n"
                        "  if not admits(current):\n"
                        "    result.problems.add problem(d.file, codeFor(current),",
    ),
])

# --- the landing pass's arms -----------------------------------------------
#
# THE VERIFIER'S OWN NUMBERING IS KEPT FOR TWO OF THESE (`U4`, `U14`). They are
# named that way in the verification report that found them, and an arm whose id
# does not match the report it answers is an arm nobody can look up. The rest of
# this table's ids are this harness's own series.

MUTATIONS.extend([
    Mutation(
        "U14", WASM,
        "  if value > uint64(high(int32)):",
        "  if false:",
        P_HUGEIMM, NIM_PURE,
        "Unhandled exception: value out of range: 34359738367 notin "
        "-2147483648 .. 2147483647 [RangeDefect]",
        "A `RangeDefect` UNWOUND OUT OF THE DECODER, from a file a repository "
        "ships. `u32leb`'s LENGTH bound accepts `FF FF FF FF 7F` — five bytes, "
        "which is what the spec's own grammar allows — and the VALUE it carries "
        "is 34,359,738,367. `decodeBody` narrows a `local.get` immediate with "
        "`int32(...)`, so without this test the refusal is "
        "`value out of range: 34359738367 notin -2147483648 .. 2147483647 "
        "[RangeDefect]` at project_wasm.nim's `decodeBody`. It is a DIFFERENT "
        "guard from the five-byte bound and needs a module only it refuses "
        "(§16a): the padded-LEB case asserts the length bound accepts exactly "
        "this length",
        control_name="the range test is written against the same bound as a constant",
        control_find="  if value > uint64(high(int32)):",
        control_replace="  const Int32Max = uint64(high(int32))\n"
                        "  if value > Int32Max:",
    ),
    Mutation(
        "U4", WASM,
        "    if stack.len >= MaxWasmStack:\n"
        "      result.trap = wtStackOverflow\n"
        "      return\n"
        "    stack.add v",
        "    stack.add v",
        P_STACKBOUND, NIM_PURE, "run.trap was wtNone",
        "THE OPERAND STACK STOPS BEING BOUNDED. Its absence is not a crash — "
        "`MaxWasmBodyInstr` caps how many pushes one body can contain — which "
        "is exactly why it needed an arm and why the verifier's hostile corpus "
        "saw nothing: what is lost is the BOUND, silently, and a module that "
        "should trap goes on to ANSWER. That is Verification-Harness-Traps §15 "
        "in the decoder — a guard whose removal makes everything greener — and "
        "the case takes the pair at the boundary in both directions so the arm "
        "cannot be killed by an off-by-one instead",
        control_name="the depth bound is compared through a named height",
        control_find="    if stack.len >= MaxWasmStack:\n"
                     "      result.trap = wtStackOverflow\n"
                     "      return\n"
                     "    stack.add v",
        control_replace="    let depth = stack.len\n"
                        "    if depth >= MaxWasmStack:\n"
                        "      result.trap = wtStackOverflow\n"
                        "      return\n"
                        "    stack.add v",
    ),

    # --- the ledger's answer, at both call sites -------------------------
    Mutation(
        "S9", STORE,
        "    outcome = l.grant(identity, kind, digest, at, annotation))",
        "    outcome = troRecorded\n"
        "    discard l.grant(identity, kind, digest, at, annotation))",
        C_UNRECORDED, NIM_CLI, "Check failed: refusedGrant.len > 0",
        "THE LEDGER'S ANSWER IS DROPPED AND SUCCESS IS ASSUMED — which is what "
        "this call site did until 2026-09-13, spelled `discard`. `at` and an "
        "explicit `note` are the caller's and do not go through "
        "`pathAnnotation`, so a decision can still be refused here; reporting "
        "\"\" for it tells a user they took a decision the machine did not keep",
        control_name="the grant's answer is carried through a named binding",
        control_find="    outcome = l.grant(identity, kind, digest, at, annotation))",
        control_replace="    let taken = l.grant(identity, kind, digest, at, annotation)\n"
                        "    outcome = taken)",
    ),
    Mutation(
        "S10", STORE,
        "    outcome = l.revoke(identity, kind, at, annotation))",
        "    outcome = troRecorded\n"
        "    discard l.revoke(identity, kind, at, annotation))",
        C_UNRECORDED, NIM_CLI, "Check failed: refusedRevoke.len > 0",
        "S9 ON THE SIDE THAT FAILS OPEN, and a separate arm because it is a "
        "separate call site: an arm on one says nothing about the other, which "
        "is E9/E10's own reason. A grant that is not recorded runs nothing "
        "extra; a REVOCATION that is not recorded leaves the code running after "
        "the user asked for it to stop, and answers \"\". That is the direction "
        "`updateProjectTrustAt`'s own comment names as the one this record must "
        "never fail in, reached with no race at all",
        control_name="the revocation's answer is carried through a named binding",
        control_find="    outcome = l.revoke(identity, kind, at, annotation))",
        control_replace="    let taken = l.revoke(identity, kind, at, annotation)\n"
                        "    outcome = taken)",
    ),
    Mutation(
        "S11", STORE,
        '  if decisionStands(outcome): return ""',
        '  if recorded(outcome): return ""',
        C_UNRECORDED, NIM_CLI,
        'Check failed: grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At) == ""',
        "THE TWO NON-RECORDS COLLAPSE AGAIN, in the other direction. `grant` "
        "and `revoke` answered a `bool` that meant BOTH \"nothing needed "
        "writing\" and \"nothing could be written\", and that is how the defect "
        "S9 and S10 grade arrived. This arm reports the benign one as a failure "
        "— re-granting a decision already in force — so the pair pins the "
        "distinction from both sides rather than only from the dangerous one",
        control_name="the success test is read through a named binding",
        control_find='  if decisionStands(outcome): return ""',
        control_replace="  let stands = decisionStands(outcome)\n"
                        '  if stands: return ""',
    ),
])

DECLARED_SURVIVORS: list[Mutation] = []

# --- MUTATIONS THAT ARE NOT ARMS, AND THE MEASUREMENT THAT SAYS SO ----------
#
# Verification-Harness-Traps §16a: "defence in depth silently halves mutation
# coverage unless each mechanism gets evidence of its own". The converse needs
# recording too, or every pass re-derives it: a guard whose every input is
# ALREADY refused by something else is not a coverage gap, and an arm on it
# would be a row that can never be killed.
#
# A second verification named seven guards whose mutations it did not supply.
# SIX are supplied here, with what running them produced, so the next pass reads
# a classification rather than re-deriving one. `U4` and `U14` became ARMS above
# — each had a module that reaches it, and each is now killed.
#
# The four below were APPLIED ONE AT A TIME AND BOTH SUITES RUN, 2026-09-13,
# and each left every case green:
#
#     U5   policy suite 59 OK / 0 FAILED    disk suite 22 OK / 0 FAILED
#     U6   policy suite 59 OK / 0 FAILED    disk suite 22 OK / 0 FAILED
#     U11  policy suite 59 OK / 0 FAILED    disk suite 22 OK / 0 FAILED
#     U12  policy suite 59 OK / 0 FAILED    disk suite 22 OK / 0 FAILED
#
# So an arm on any of them would be a row that can never be killed — §16's own
# definition of a row that looks like coverage. The reason is a second
# mechanism that answers first, named per guard:
#
#   | id  | find                                             | replace              | what answers instead |
#   |-----|--------------------------------------------------|----------------------|----------------------|
#   | U5  | `    if frames.len >= MaxWasmCallDepth: return false` | `    if false: return false` | the WORK BOUND: every call retires instructions, so unbounded recursion is stopped by `spend` before the frame stack is |
#   | U6  | `    if c.pos != payloadEnd and id != 0:`        | `    if false:`      | the CURSOR's own truncation: a section whose payload does not end where its length says runs the next read off the end and `wpcTruncated` answers |
#   | U11 | `    if instrs.len >= MaxWasmBodyInstr:`         | `    if false:`      | `MaxWasmBytes`: a body cannot carry more instructions than the module has bytes, and the module's size is bounded before it is decoded |
#   | U12 | `  if data.len > MaxWasmBytes:`                  | `  if false:`        | the DISK READER's `stat` bound: `project_executable_tier` refuses an oversized file by its size BEFORE it opens it (arm D3), so no oversized module reaches the decoder through the product |
#
# THEY ARE NOT IN `DECLARED_SURVIVORS`, and that is deliberate rather than an
# omission: a declared survivor is an arm the harness RUNS and expects to
# survive, and running these would assert that no other mechanism ever grows
# evidence for them — which is the opposite of what is wanted. They are a
# classification, kept with their mutations so re-deriving one is a paste.
#
# ONE OF THE SEVEN STILL HAS NO MUTATION: the verifier's `U9`, named in its
# report without one. It is the outstanding work this leaves open.


@dataclass
class RunResult:
    ran: bool = False
    rc: int = 0
    output: str = ""
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
    res = RunResult(ran=True)
    print(f"      [{label}] compiling {suite.path}")
    compile_proc = subprocess.run(
        ["nim", "c", "--hints:off", "--verbosity:0", "-o:" + suite.binary,
         suite.path],
        cwd=ROOT, capture_output=True, text=True, errors="replace",
        timeout=1800)
    if compile_proc.returncode != 0:
        res.ran = False
        res.output = compile_proc.stdout + compile_proc.stderr
        print("      ---- compile failed; last 12 lines ----")
        for line in res.output.splitlines()[-12:]:
            print("      " + line)
        return res
    # `errors="replace"` is load-bearing rather than defensive tidiness: these
    # suites print raw module bytes in a `checkpoint` when a decode refusal is
    # not the one a case expected, and a strict decode raises out of the harness
    # MID-ARM with a mutation applied.
    proc = subprocess.run([suite.binary], cwd=ROOT, capture_output=True,
                          text=True, errors="replace", timeout=3600)
    out = proc.stdout + proc.stderr
    res.output = out
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

    Verification-Harness-Traps §16. A mutation arm is a QUOTATION of the code,
    held somewhere the compiler does not look, and every repair to the quoted
    file is an opportunity for it to stop matching. When it does, the arm can
    never be applied, so it can never be killed, and what it leaves behind is a
    row in the table that LOOKS like coverage.

    It gates `--record-control-hashes` rather than sitting beside it: blessing
    new bytes as the baseline is exactly the moment an arm's needle has just
    been moved.
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
    ids = [m.id for m in MUTATIONS + DECLARED_SURVIVORS]
    for i in ids:
        if ids.count(i) != 1:
            problems.append(f"{i}: declared {ids.count(i)} times")
    return problems


def report_needle_scan() -> int:
    problems = needle_scan()
    if not problems:
        print(f"  all {len(MUTATIONS) + len(DECLARED_SURVIVORS)} arm(s) resolve "
              f"to exactly one needle and one control needle")
        return 0
    print("ARM NEEDLES DO NOT RESOLVE — nothing was mutated and nothing recorded.")
    for line in sorted(set(problems)):
        print(f"  {line}")
    print("  An arm whose needle no longer occurs can never be applied and can")
    print("  never be killed; it sits in the table looking like coverage.")
    print("  Re-aim it at the code as it is now, then re-run.")
    return 2


def write_control_hashes() -> None:
    body = ["# Control digests for run-plat13-executable-mutations.py.",
            "#",
            "# ABSOLUTE, and that is the point. A baseline taken at start-up",
            "# cannot tell a clean tree from one a killed run left a mutation",
            "# in: it reads the mutation as the baseline, every restore then",
            "# verifies against the mutated bytes, and the only symptom is",
            "# `CONTROL IS NOT GREEN` — which describes a red suite without",
            "# naming the cause.",
            "#",
            "# Rewrite with --record-control-hashes, deliberately, when one of",
            "# these files changes on purpose. The needle scan gates that step",
            "# (Verification-Harness-Traps §16), and §16a is why re-recording",
            "# is not the last step: RE-RUN THE ARMS afterwards.",
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
    if "--needle-scan" in sys.argv[1:]:
        return report_needle_scan()

    if "--record-control-hashes" in sys.argv[1:]:
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

    # BEFORE ANY MUTATION. An arm that cannot be applied is not a thing to
    # discover forty minutes in, next to nineteen results you now have to
    # decide whether to trust.
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
    survivors = [m for m in selected if m in DECLARED_SURVIVORS]

    baseline = {p: digest(p) for p in TOUCHED}

    # THE SUITE SET IS DERIVED FROM THE ARMS, not written out beside them — a
    # second registry of the same fact is where the two drift apart
    # (Verification-Harness-Traps §14), and PLAT-8's harness paid a `KeyError`
    # after a control phase to learn it.
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

    problems = 0

    # EVERY KILLER MUST RESOLVE TO EXACTLY ONE GREEN CASE IN ITS OWN SUITE,
    # checked BEFORE any mutation.
    for mut in selected:
        matches = [c for c in controls[mut.suite.path].passed if c == mut.killer]
        if len(matches) != 1:
            print(f"{mut.id}: killer {mut.killer!r} resolves to {len(matches)} "
                  f"green case(s) in {mut.suite.path}, expected exactly 1")
            problems += 1
    if problems:
        print(f"\n{problems} unusable arm(s); nothing was mutated")
        return 1
    print(f"  all {len(selected)} killers resolve to exactly one green case")

    # EVERY `because` MUST BE ABSENT FROM THE GREEN OUTPUT (§17's fix, and §5's
    # sentinel rule applied to it). A `because` that already occurs in a passing
    # run is true for free.
    for mut in selected:
        if not mut.because:
            print(f"{mut.id}: no `because`; a kill could not be attributed")
            problems += 1
            continue
        if mut.because in controls[mut.suite.path].output:
            print(f"{mut.id}: because {mut.because!r} already occurs in the "
                  f"GREEN output of {mut.suite.path}; it cannot be evidence "
                  f"that this arm is what reddened the case")
            problems += 1
    if problems:
        print(f"\n{problems} unusable arm(s); nothing was mutated")
        return 1
    print(f"  all {len(selected)} `because` needles are absent from the green "
          f"output\n")

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
        attributed = mut.because in res.output
        if not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif declared and newly_failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"now killed by {newly_failed}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", mut.why
        elif (mut.killer not in res.passed) and (mut.killer not in res.failed):
            verdict = "SUITE-DIED"
            note = (f"the suite produced {res.total} result line(s) and "
                    f"{mut.killer!r} was not among them")
            problems += 1
        elif not newly_failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif mut.killer not in newly_failed:
            verdict, note = "MISDIRECTED", f"died in {newly_failed}, not {mut.killer!r}"
            problems += 1
        elif not attributed:
            verdict = "MIS-ATTRIBUTED"
            note = f"the case died without {mut.because!r} in the failure output"
            problems += 1
        else:
            others = [f for f in newly_failed if f != mut.killer]
            killed += 1
            verdict = "killed"
            note = mut.killer + (f"  (+{len(others)} more)" if others else "")
        print(f"{mut.id:<5} {verdict:<20} {note}")
        if verdict != "killed" and not declared:
            # THE FAILURE TEXT, SO A `because` IS DERIVED RATHER THAN TYPED
            # (Verification-Harness-Traps §17a). A `because` written from the
            # SOURCE is a second copy of the code held in a file the compiler
            # does not read, and this is the one place where the copy and the
            # original are not even written in the same language. Printing the
            # transcript here is what makes re-deriving one a paste rather than
            # a guess.
            control_lines = set(controls[mut.suite.path].output.splitlines())
            shown = 0
            for line in res.output.splitlines():
                stripped = line.strip()
                if not stripped:
                    continue
                if not (stripped.startswith("Check failed:") or
                        stripped.startswith("wanted ") or
                        stripped.startswith("the needle came back") or
                        # AN ARM WHOSE MUTATION RAISES HAS NO `Check failed:`
                        # LINE AT ALL. `unittest` catches the exception, reports
                        # the case `[FAILED]`, and prints only the exception —
                        # so a transcript without this line sends the reader to
                        # guess a `because`, which is the §17a defect this
                        # transcript exists to remove. Found by U14 on
                        # 2026-09-13, which scored MIS-ATTRIBUTED with nothing
                        # in the transcript to re-derive from.
                        stripped.startswith("Unhandled exception:") or
                        " was " in stripped):
                    continue
                if line in control_lines:
                    continue
                print(f"{'':<5}   | {stripped[:160]}")
                shown += 1
                if shown >= 8:
                    break

        # --- the named behaviour-preserving control ------------------------
        if not mut.control_find:
            print(f"{'':<5} NO-CONTROL           this arm has no behaviour-preserving control")
            problems += 1
            continue
        original, err = apply_once(mut.path, mut.control_find,
                                   mut.control_replace)
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
