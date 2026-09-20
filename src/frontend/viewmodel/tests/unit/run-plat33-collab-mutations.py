#!/usr/bin/env python3
"""PLAT-33's mutation harness: every published killer of `LAW-X1` … `LAW-X5`,
performed, plus the arms that grade the SUITE rather than the product.

    python3 src/frontend/viewmodel/tests/unit/run-plat33-collab-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --enumerate-touched
    python3 ... --only=M1,U2

=============================================================================
THE ORDER IS §16's AND IT IS ENFORCED RATHER THAN DOCUMENTED
=============================================================================

edit the tree -> `--needle-scan` -> review -> `--record-control-hashes`.

Re-recording is exactly the moment an arm's needle has just been moved, so a
full run REFUSES to start when a needle is lost or ambiguous, and REFUSES
again when a control digest has moved without a scan. Both refusals are acted
on rather than printed: a run started on an already-mutated file restores TO
the mutation and reports itself clean.

=============================================================================
ONE ARM AT A TIME, AND A SIGNAL HANDLER BECAUSE `finally` IS NOT ONE
=============================================================================

Exactly one mutation is on disk at any instant. `finally` restores it; a
SIGTERM skips `finally`, so SIGTERM/SIGINT/SIGHUP restore the active subject
on the way out (§32h). SIGKILL still cannot, which is the other reason the
digests are recorded and compared before every run.

Nothing else may run against this tree while this harness is live — a
concurrent reader grades a tree that still has a mutation on it.

=============================================================================
A HANG IS ITS OWN VERDICT
=============================================================================

§1: *a hang arm is one whose rc is 124 and nothing else*. `SUITE_TIMEOUT`
turns a suite that never finishes into a named HUNG rather than a long pass,
and the fix for a HUNG arm is the arm, not the timeout.

=============================================================================
§10.3 — NO ARM MAY QUOTE A COUNT
=============================================================================

A count changes on every commit that adds a test, so an arm whose needle
contains one is an arm that is silently unkillable by the next commit. The
scan rejects an arm quoting a count constant's NAME or its VALUE, and refuses
outright if it can find no count constants at all — a rule with nothing to
check is a rule that passes vacuously.
"""

import argparse
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

COLLAB_TEXT = "src/frontend/viewmodel/editor/collab_text.nim"
REDUCER = "src/frontend/viewmodel/collab/reducer.nim"
TEXT_OPS = "src/frontend/viewmodel/collab/text_ops.nim"
TRANSACTION = "src/frontend/viewmodel/editor/transaction.nim"
OPS = "src/frontend/viewmodel/editor/operations.nim"
GENERATOR = "src/frontend/viewmodel/tests/generators/schedule_generator.nim"
LAWS = "src/frontend/viewmodel/tests/unit/test_editor_collab_laws.nim"
EX = "src/frontend/viewmodel/tests/unit/test_editor_collab_examples.nim"

# **THE TWO MODULES THIS MILESTONE CHANGED BEHAVIOURALLY AND NO HARNESS
# WATCHED.** Added 2026-09-20, from a review verdict rather than from a
# failure — which is the rarer and better reason, and is recorded as such.
#
# PLAT-33 did two things to the collaboration layer that are not text-editing
# and were therefore invisible to every arm above:
#
# - `capabilities.nim` absorbed SIX predicates that `reducer.nim` had carried
#   its own copies of, and one of the six — `liveCapability` becoming
#   `hasLiveCapability` — does NOT agree with the copy it replaced on a
#   grant whose id is empty (old `true`, new `false`). That is a behaviour
#   change wearing a refactor's name, and the module's own header says so.
# - `codec.nim` gained an ADMISSION RULE: a capability grant whose `id` is
#   empty is refused at the decoder, because such a grant could never be
#   revoked once admitted.
#
# Both are reachable, both are security-relevant — one decides who may act,
# the other decides what gets into the state at all — and until this entry
# neither had a single mutation arm anywhere in the tree. Twenty-four
# harnesses and the two files that decide authority were covered by none of
# them.
CAPABILITIES = "src/frontend/viewmodel/collab/capabilities.nim"
CODEC = "src/frontend/viewmodel/collab/codec.nim"

# The suite that covers them. It is RUN (see `SUITES`) and DIGESTED (see
# `READ_ONLY_INPUTS`) but not ARMED: an arm on a test file that has no
# self-check of its own can only restate the test, and this harness's rule is
# that every member of `TOUCHED` carries a real killer. Its bytes are still
# controlled, so it cannot be weakened while this harness is live.
AUTHORITY = "src/frontend/viewmodel/tests/unit/test_collab_authority_m4.nim"

TOUCHED = [COLLAB_TEXT, REDUCER, TEXT_OPS, TRANSACTION, OPS, GENERATOR,
           LAWS, EX, CAPABILITIES, CODEC]

# **A HARNESS MUST DIGEST EVERYTHING ITS SUITES *READ*, NOT ONLY EVERYTHING IT
# MUTATES.** `test_editor_collab_examples.nim` `staticRead`s three files that
# are not subjects of any arm — the workflow that names the two collaboration
# lanes, the justfile that gives them recipes, and the lane-file script that
# declares them. Editing any of the three while this harness is live changes
# what a suite COMPILES TO, mid-arm, and `TOUCHED`'s digests cannot see it
# because none of them is in `TOUCHED`.
#
# They are not added to `TOUCHED` because that list is also the restore set
# and the "every subject carries an arm" rule; they are digested and compared
# here instead, and a move is a refusal rather than a warning.
#
# **THE RULE WAS UNDER-APPLIED WHEN IT WAS WRITTEN, AND THE MISSING ENTRY WAS
# THE IMPORTANT ONE.** The list below said three for a day while the examples
# suite `staticRead`s FOUR files outside its own subject set. The fourth is
# `codetracer-specs/Architecture/Editor-ViewModel.md` — §12.1a's published
# merge table, which is the ORACLE the suite grades `mergeFamilyOf` against.
# An undigested oracle is strictly worse than an undigested lane script: edit
# the spec while the harness is live and the expected value itself moves
# mid-arm, so an arm can be scored against a table that is not the one anybody
# reviewed. It lives in a SIBLING REPO, which is presumably why it was missed
# — `ROOT / rel` resolves the `..` fine, and being in another repo is a reason
# it can move without this repo's git status saying anything, not a reason to
# leave it out.
READ_ONLY_INPUTS = [
    ".github/workflows/codetracer.yml",
    "justfile",
    "ci/lib/test-lane-files.sh",
    "../codetracer-specs/Architecture/Editor-ViewModel.md",
    # Executed by this harness (it is in `SUITES`) but not mutated by it — see
    # `AUTHORITY` above for why it is digested here rather than in `TOUCHED`.
    AUTHORITY,
]

CONTROL_HASHES = HERE / "plat33-collab-mutation-control.sha256"

SUITE_TIMEOUT = int(os.environ.get("CT_P33_SUITE_TIMEOUT", "1800"))

SUITES = [LAWS, EX, AUTHORITY]

# **EVERY COMPILE NAMES ITS OUTPUT, AND THAT IS NOT TIDINESS.** Without `-o:`,
# `nim c -r` writes the executable NEXT TO THE SOURCE — so this harness built
# ELF binaries into `tests/unit/` and left them there, inside the very tree
# whose bytes it digests. A harness that writes into its own subject directory
# is one `git add -A` away from committing a 2 MB binary, and one `.gitignore`
# miss away from its own control-hash comparison reading files it created.
# `run-plat25-change-algebra-mutations.py` and `ci/test/editor-model-case-floor.sh`
# have always done this correctly (`-o:` into `$TMPDIR`); this harness simply
# omitted it, and the omission was for a while misattributed to the shell
# script — which writes to `${TMPDIR:-/tmp}/editor-model-floor-<suite>` at
# `editor-model-case-floor.sh:454` and never compiled into the tree at all.
#
# The paths are FIXED rather than per-arm temporaries on purpose: a stable
# output path lets Nim skip the rebuild when nothing changed, and every arm
# here CHANGES the content of a tracked source, which is what actually
# invalidates the cache (measured — an mtime touch does not, a content edit
# does).
BIN_DIR = os.environ.get("TMPDIR", "/tmp")


def suite_binary(rel: str) -> str:
    return os.path.join(BIN_DIR, "plat33-" + Path(rel).stem)

COUNT_NAMES = ["ExpectedAssertions", "ExpectedCases", "CHECKS:",
               "ScheduleClassCount", "PublishedMergeFamilyCount",
               "ForbiddenInOracleCount", "ScannedCollabModuleCount",
               "DivergenceTrials", "FuzzSchedulesPerPeerCount"]

# The killer for each arm is the NAME OF THE CASE that must die. A case name
# that does not exist in the suites is itself a harness failure — an arm
# aimed at a case nobody wrote is a row that can never be a kill.


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""


ARMS = [
    # -------------------------------------------------------------------
    # THE FIVE PUBLISHED KILLERS — §3.7's own column, performed
    # -------------------------------------------------------------------
    Arm(
        "M1", COLLAB_TEXT,
        "    let carried = running\n    changes = some(carried)\n",
        "    let carried = changes.get\n    changes = some(carried)\n",
        "LAW-X1 under scDelayedPastLocalEdit",
        "**`LAW-X1`'s PUBLISHED KILLER: APPLY AN INCOMING UPDATE WITHOUT "
        "FIRST REBASING IT OVER THE PEER'S UNCONFIRMED LOCAL WORK.** The "
        "composed remote change arrives expressed against the peer's "
        "CONFIRMED document; the peer's real document has its unconfirmed "
        "work on top. Returning the unrebased composition converges on every "
        "schedule in which nothing is unconfirmed, which is most of an "
        "in-order one — so the arm is expected to die in the classes where "
        "a delivery lands on a peer holding local work, and that is exactly "
        "what the population's `interleaved` equality guarantees exists.",
    ),
    Arm(
        "M2", REDUCER,
        "  if document.hasApplied(op.opId):\n    return duplicate()\n",
        "  if false and document.hasApplied(op.opId):\n    return duplicate()\n",
        "LAW-X2 under scDuplicated",
        "**`LAW-X2`'s PUBLISHED KILLER: DISABLE `opId` DEDUP.** Note what "
        "this arm does NOT break: the document still converges, because "
        "`applyAcceptTextUpdate` refuses a second claim on a version slot. "
        "The law had to be strengthened to see it — idempotence over the "
        "WHOLE replica, including `revision` and `appliedOpIds` — and that "
        "repair is recorded in the case's own comment and in §3.7a.",
    ),
    Arm(
        "M3", COLLAB_TEXT,
        "  ordered.sort(proc (x, y: Submission): int =\n"
        "    let kx = submissionOrderKey(x)\n"
        "    let ky = submissionOrderKey(y)\n"
        "    if kx[0] != ky[0]: cmp(kx[0], ky[0]) else: cmp(kx[1], ky[1]))\n",
        "  ordered.sort(proc (x, y: Submission): int = 0)\n",
        "LAW-X3 under scInOrder",
        "**`LAW-X3`'s PUBLISHED KILLER: TIE-BREAK ON ARRIVAL ORDER.** Which "
        "is the REFERENCE'S behaviour — `@codemirror/collab` states no "
        "tie-break at all — so this arm is also the measurement of what the "
        "divergence from it buys. Two inserts at one offset fold to `AB` one "
        "way and `BA` the other.",
    ),
    Arm(
        "M4a", COLLAB_TEXT,
        "  result.selection = mapSelection(selBefore, cs)\n",
        "  result.selection = caretSelection(0)\n",
        "LAW-X4's three arms under scInOrder",
        "**`LAW-X4`, THIRD PROPERTY: THE RECEIVED TRANSACTION SETS THE "
        "SELECTION.** §12.2 requires it NOT to, so that §7's ordinary "
        "mapping rule applies for free and selection mapping is decided in "
        "one place.",
    ),
    Arm(
        "M4b", COLLAB_TEXT,
        "                @[Annotation(kind: anRemote, peer: peer),\n"
        "                  Annotation(kind: anAddToHistory, addToHistory: false)]),\n",
        "                @[Annotation(kind: anUserEvent, userEvent: ueInput)]),\n",
        "LAW-X4's three arms under scReordered",
        "**`LAW-X4`, FIRST PROPERTY: THE RECEIVED TRANSACTION ENTERS THE "
        "UNDO HISTORY.** This is the defect PLAT-32 exists to prevent and "
        "the one this milestone is most capable of re-introducing: a "
        "collaboration layer that converges perfectly while undo pulls "
        "somebody else's typing out from under them.",
    ),
    Arm(
        "M4c", OPS,
        "  if st.filters.refusedBy(cs):\n"
        "    if newSelection.isSome:\n"
        "      result.selection = newSelection.get\n"
        "    return\n",
        "  if false:\n"
        "    return\n",
        "the filters are bypassed — remote edit BEFORE the caret",
        "**`LAW-X4`, SECOND PROPERTY, FROM THE OTHER SIDE.** The published "
        "killer is *route a remote transaction through the local filters*; "
        "this arm removes the filter from the LOCAL path instead, which "
        "makes the two paths identical and destroys the two-sidedness. An "
        "arm that only added the filter to the remote path would leave the "
        "case green whenever the filter never fires.",
    ),
    Arm(
        "M4d", TRANSACTION,
        "    of tfReadOnly:\n      return true\n",
        "    of tfReadOnly:\n      return false\n",
        "LAW-X4's three arms under scInOrder",
        "The filter predicate itself, made inert. **RE-AIMED after it came "
        "back MISDIRECTED**: it was pointed at the examples suite's filter "
        "case, which installs a PROTECTED RANGE, and this arm makes the "
        "READ-ONLY guard inert. §36's second rule — an arm aimed at the wrong "
        "half reports a verdict about the wrong assertion. `LAW-X4`'s second arm "
        "asserts that a LOCAL edit under a read-only guard is refused and a "
        "remote one is not; a guard that never fires satisfies half of that "
        "for the wrong reason.",
    ),
    Arm(
        "M5", REDUCER,
        "    if op.targetPath.startsWith(\"editor.documents\") or\n"
        "        op.targetPath.startsWith(\"editor.remoteSelections\"):\n"
        "      return rejected(\n",
        "    if false:\n"
        "      return rejected(\n",
        "LAW-X5 under scInOrder",
        "**`LAW-X5`'s PUBLISHED KILLER: LET IT FALL THROUGH TO THE REGISTER "
        "PATH.** `applyScalarRegister`'s `case op.targetPath` has an `else: "
        "false`, so a register op aimed at the text state becomes an "
        "`ignored` — *recorded but did not change shared state* — which is "
        "indistinguishable from a stale stamp losing a race. QUIET is the "
        "failure mode, which is why the law demands an explicit refusal.",
    ),
    Arm(
        "M6", REDUCER,
        "    (true, capEditSharedText, op.opTargetPath(\"editor.documents\"))\n",
        "    (false, capObserve, \"\")\n",
        "a peer WITHOUT the text capability is refused",
        "**THE PLANTED OMISSION THE VERIFICATION GATE ASKS FOR.** "
        "`Editor-ViewModel.md` §12.1 records `requiredCapability`'s `else: "
        "(false, capObserve, \"\")` as the half the compiler does not cover: "
        "a text kind added to the enum and to the exhaustive reducer but not "
        "to this table compiles, runs, and is UNGATED. This arm performs "
        "exactly that omission. The compiler cannot see it — the `case` is "
        "still exhaustive — which is the whole point.",
    ),

    # -------------------------------------------------------------------
    # THE SUITE AND THE GENERATOR, ARMED AS SUBJECTS
    # -------------------------------------------------------------------
    Arm(
        "U1", LAWS,
        "const ForbiddenInOracle = [\"rebase\", \"receiveUpdates\", \"PeerSession\",\n",
        "const ForbiddenInOracle = [\n",
        "§30a — THE ORACLE IS NOT A SECOND CALL TO THE MERGE FUNCTION",
        "An EMPTY forbidden list iterates nothing and satisfies every \"must "
        "not contain\" written over it (§4). The cardinality assertion beside "
        "it is what makes that a red rather than a silence.",
    ),
    Arm(
        "U2", LAWS,
        "    if path.kind == pcFile and path.path.endsWith(\".nim\"):\n",
        "    if path.kind == pcFile and path.path.endsWith(\".nimX\"):\n",
        "§35 — THE SCANNED MODULES ARE THE DIRECTORY, NOT A LIST",
        "A lister that matches nothing satisfies *\"the set is exactly these "
        "eighteen\"* by leaving nothing to disagree with it — §4, one level "
        "up from the scan it guards. The arm is one character in the "
        "extension it filters on.",
    ),
    Arm(
        "G1", GENERATOR,
        "  for step in s.steps:\n    if step.kind == stPartition:\n"
        "      return scPartitionedAndHealed\n",
        "  return s.intended\n",
        "§30a — THE CLASSIFIER IS NOT THE CONSTRUCTOR, ASSERTED ON ITS BODY",
        "**THE CLASSIFIER BECOMES THE CONSTRUCTOR** (§34's third rule). If "
        "the histogram is built from the label the generator applied to its "
        "own output, the whole check is the generator agreeing with itself "
        "and a smeared population is invisible in principle. This arm must "
        "NOT be killed by the equality alone — the equality holds perfectly "
        "under it — so the case that dies is the one asserting the "
        "classifier reads the STEP LIST.\n\n"
        "**THAT CASE DID NOT EXIST UNTIL THIS ARM SURVIVED.** The first run "
        "reported SURVIVED against every realised-count equality in the "
        "suite, which reads as \"the mutation is harmless\" and is in fact "
        "\"nothing here can see it\" — §36's first rule. The repair is the "
        "source scan over the classifier's own body, and the arm is aimed at "
        "it now.",
    ),
    Arm(
        "G2", GENERATOR,
        "        if sendable.atVersion < authorityVersionBefore:\n"
        "          inc result.rebasedSubmissions\n",
        "        if false:\n"
        "          inc result.rebasedSubmissions\n",
        "§34 — THE AUTHORITY REALLY REBASED, AND THE REBASE REALLY MOVED SOMETHING",
        "**THE POPULATION COUNTER, ARMED.** §34's rule is that a population "
        "assertion must itself be able to fail; a realised count nothing can "
        "falsify is a number in a print statement.\n\n"
        "**RE-AIMED after it came back MISDIRECTED.** The first spelling "
        "changed the SCHEDULE — delivering to each peer immediately after it "
        "submits, so no submission is ever behind the authority — which is a "
        "better description of the defect but also changes what "
        "`classifySchedule` says about every draw, so it died in the class "
        "equality and in `FUZZ-9` rather than in the case it was written "
        "for. A mutation whose blast radius is wider than its subject "
        "reports a verdict about the wrong assertion (§36).",
    ),
    Arm(
        "G4", TEXT_OPS,
        "  result = base\n  for entry in doc.committedLog:\n"
        "    result = decodeChangeSet(entry.changes).apply(result)\n",
        "  result = base\n  var session = initPeerSession(\"oracle\")\n"
        "  var updates: seq[TextUpdate] = @[]\n"
        "  for entry in doc.committedLog: updates.add entry.toTextUpdate\n"
        "  let received = session.receiveUpdates(updates)\n"
        "  if received.hasChanges: result = received.changes.apply(result)\n",
        "§30a — THE ORACLE IS NOT A SECOND CALL TO THE MERGE FUNCTION",
        "**THE ORACLE BECOMES A SECOND CALL TO THE MERGE FUNCTION.** This is "
        "the §30a arm and it is the one that matters most here, because it "
        "is a CORRECT re-derivation: every convergence assertion stays green "
        "under it, on every class, at every peer count. No assertion about "
        "what either side ANSWERS can see it. The source scan over "
        "`foldDocument`'s own body is the only thing that can, which is why "
        "the claim checked is about the PRODUCER rather than the answer.",
    ),
    Arm(
        "U3", EX,
        "    if not (first.startsWith(\"`MF-\") or first.startsWith(\"**`MF-\")): continue\n",
        "    if not first.startsWith(\"`ZZ-\"): continue\n",
        "the section was found and parsed",
        "**A PARSER THAT FINDS NOTHING SATISFIES BOTH SET DIFFERENCES.** "
        "§7.1's last line — *the cardinality, asserted* — is the one usually "
        "omitted, and without it `names(T) - names(I) == {}` and "
        "`names(I) - names(T) == {}` are both true of two empty sets. This "
        "arm empties the published side and the cardinality is the only "
        "thing that can say so.",
    ),

    # -------------------------------------------------------------------
    # THE AUTHORITY LAYER — added 2026-09-20, from a review verdict
    # -------------------------------------------------------------------
    Arm(
        "M7", CAPABILITIES,
        "    if grant.subject == principalId and grant.revokedByOpId.len == 0 and\n",
        "    if grant.subject == principalId and\n",
        "test_collab_revoked_capability_rejects_later_ops",
        "**A REVOKED CAPABILITY GOES ON WORKING.** `liveCapabilityGrant` "
        "walks the grant table and the `revokedByOpId.len == 0` term is the "
        "ONLY thing that distinguishes a live grant from a retracted one — "
        "revocation is a tombstone on the row, not a deletion of it, so "
        "dropping the term does not remove a grant, it resurrects every "
        "grant that was ever revoked. `hasLiveCapability`, "
        "`canGrantCapabilities` and `canDelegateCapabilities` all reach the "
        "table through this one walk and all three inherit the defect, which "
        "is the §30 argument for the extraction stated as a mutation: ONE "
        "function to arm, and every caller goes red together.\n\n"
        "This is the predicate `reducer.nim` used to carry its own copy of. "
        "Under the duplication this arm would have been HALF a defect — the "
        "reducer's copy would still refuse, the capabilities copy would "
        "admit, and which one answered would depend on the call path. That "
        "is precisely the failure mode §30 describes, and it is why the "
        "extraction is a deliverable rather than tidying.",
    ),
    Arm(
        "M8", CODEC,
        "  grant.id = node{\"id\"}.getStr(\"\")\n"
        "  if grant.id.len == 0:\n"
        "    return false\n",
        "  grant.id = node{\"id\"}.getStr(\"\")\n"
        "  if false:\n"
        "    return false\n",
        "test_collab_capability_grant_without_id_is_refused_at_decode",
        "**THE DECODER ADMITS A GRANT NOBODY CAN EVER REVOKE.** The guard is "
        "removed while the `bool` return, the `var` out-parameter and the "
        "caller's `if` all stay exactly as they are — so this arm does not "
        "test whether the plumbing compiles, it tests whether the RULE is "
        "enforced. Everything downstream still type-checks and the suite "
        "still runs; only the admission decision changes.\n\n"
        "The defect it restores is not cosmetic. `applyGrantCapabilities` "
        "and `applyRevokeCapabilities` both refuse `id.len == 0`, so an "
        "empty-id grant is not a value the reducer can create OR retract: "
        "admitting one at the decoder writes a row into `capabilityGrants` "
        "that no authority has any operation to remove. Any snapshot that "
        "merely OMITS the `\"id\"` key produced one, which makes the reachable "
        "input a missing field rather than a crafted one.\n\n"
        "The killer case tests both directions — the omitted key and a "
        "present-but-empty one are both refused, and an untouched round trip "
        "still keeps the grant and still confers the capability. A decoder "
        "that refused every grant would pass the refusal half and fail the "
        "control, which is §7b's rule met rather than cited.",
    ),
]

DECLARED_SURVIVORS = [
    Arm(
        "G3", LAWS,
        "        if i mod 3 == 0: changeSet(doc.len, at, bs[k + 2], corpusClusters(r, 1))\n"
        "        else: changeSet(doc.len, at, at, corpusClusters(r, 1))\n",
        "        changeSet(doc.len, at, at, corpusClusters(r, 1))\n",
        "",
        "**A DECLARED SURVIVOR, AND IT REFUTED THE COMMENT IT WAS WRITTEN "
        "TO DEFEND.** The offline stream rewrites every third edit, under a "
        "comment claiming an insert-only stream *\"cannot move the metric at "
        "all\"*. This arm removes the rewrites; the curve barely moves — "
        "0.98 / 0.77 / 0.58 against 0.98 / 0.79 / 0.50 over the same twelve "
        "trials per level — so the monotonicity case stays green and "
        "SURVIVED is the correct verdict.\n\n"
        "A rebase never DROPS an insertion, which is what the comment was "
        "reasoning from, but it does ORDER one: a remote insert at the same "
        "offset is placed before the peer's, breaking the context the peer "
        "was aiming after exactly as a rewrite does. The comment is corrected "
        "and carries both curves; the rewrites are kept because they "
        "strengthen the effect at the densest level and cost nothing.\n\n"
        "It is a DECLARED survivor rather than a deleted arm so that a "
        "future change which makes the rewrites load-bearing turns it into a "
        "NO-LONGER-A-SURVIVOR rather than into a silent extra kill.",
    ),
    Arm(
        "S1", COLLAB_TEXT,
        "  if baseLen < 0:\n",
        "  if baseLen < -1:\n",
        "",
        "A DECLARED SURVIVOR, recorded rather than deleted. "
        "`initTextAuthority`'s negative-length guard is unreachable from any "
        "suite here — nothing constructs an authority over a negative "
        "document — so widening it changes nothing and SURVIVED is the "
        "correct verdict. It is listed so that a future case which DOES "
        "drive the guard turns it into a NO-LONGER-A-SURVIVOR rather than "
        "into a silent extra kill.",
    ),
]

_ACTIVE = None


def read_source(rel):
    return (ROOT / rel).read_text()


def write_source(rel, text):
    (ROOT / rel).write_text(text)


def digest(rel):
    return hashlib.sha256((ROOT / rel).read_bytes()).hexdigest()


def declared_counts():
    """value -> constant name, over every subject."""
    out = {}
    pat = re.compile(r"\b(" + "|".join(re.escape(n) for n in COUNT_NAMES) +
                     r")\s*[:=]?\s*=?\s*(\d+)")
    for rel in TOUCHED:
        for name, value in pat.findall(read_source(rel)):
            out[value] = name
    return out


def declared_case_names():
    names = set()
    for rel in SUITES:
        for m in re.finditer(r'^\s*test "([^"]+)"', read_source(rel),
                             re.MULTILINE):
            names.add(m.group(1))
        # `test "a " & $x & " b"` forms: keep the literal prefix so a killer
        # written against a generated name can still be matched by prefix.
        for m in re.finditer(r'^\s*test "([^"]+)" & ', read_source(rel),
                             re.MULTILINE):
            names.add(m.group(1))
    return names


def check_killer_names(problems):
    declared = declared_case_names()
    for arm in ARMS:
        if not arm.killer:
            print(f"{arm.id}: NO KILLER NAMED — an arm with no stated killer "
                  f"is not admitted")
            problems += 1
            continue
        if arm.killer in declared:
            continue
        if any(arm.killer.startswith(d) or d.startswith(arm.killer)
               for d in declared):
            continue
        print(f"{arm.id}: KILLER NAMES NO DECLARED CASE: {arm.killer!r}")
        problems += 1
    return problems


def needle_scan():
    """Every arm's needle occurs exactly once. No toolchain, about a second."""
    problems = 0

    counts = declared_counts()
    print("declared count constants in the subjects: " +
          (", ".join(f"{v}={k}" for k, v in sorted(counts.items())) or "none"))
    if not counts:
        print("REFUSING: no declared count constant was found in any subject, "
              "so §10.3's rule would pass vacuously")
        problems += 1
    for arm in ARMS + DECLARED_SURVIVORS:
        blob = arm.find + arm.replace
        for name in COUNT_NAMES:
            if name in blob:
                print(f"{arm.id}: NEEDLE QUOTES A COUNT NAME ({name}) — §10.3")
                problems += 1
        for digits in re.findall(r"\d+", blob):
            if digits in counts:
                print(f"{arm.id}: NEEDLE QUOTES THE VALUE OF "
                      f"{counts[digits]} ({digits}) — §10.3")
                problems += 1

    armed = {arm.path for arm in ARMS}
    unarmed = [p for p in TOUCHED if p not in armed]
    if unarmed:
        print(f"SUBJECTS WITH NO ARM: {unarmed}")
        problems += 1
    else:
        print(f"all {len(TOUCHED)} subjects carry at least one arm")

    for arm in ARMS + DECLARED_SURVIVORS:
        text = read_source(arm.path)
        n = text.count(arm.find)
        status = "ok" if n == 1 else "LOST" if n == 0 else "AMBIGUOUS"
        if n != 1:
            problems += 1
        print(f"{arm.id:<5} {status:<10} {n} occurrence(s) in {arm.path}")

    problems = check_killer_names(problems)
    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


def record_control_hashes():
    lines = [f"{digest(p)}  {p}" for p in TOUCHED + READ_ONLY_INPUTS]
    CONTROL_HASHES.write_text("\n".join(lines) + "\n")
    print(f"recorded {len(lines)} digests in {CONTROL_HASHES.name}")
    return 0


def check_control_hashes():
    if not CONTROL_HASHES.exists():
        print(f"NOTE: {CONTROL_HASHES.name} is absent — run "
              f"--record-control-hashes after reviewing the tree")
        return True
    recorded = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        if not line.strip():
            continue
        h, _, rel = line.partition("  ")
        recorded[rel] = h
    ok = True
    for p in TOUCHED + READ_ONLY_INPUTS:
        # **A PATH THAT IS NOT IN THE FILE AT ALL IS A REFUSAL, NOT A SKIP.**
        # `if p in recorded and …` let a newly added subject or read-only
        # input pass silently until somebody happened to re-record, which is
        # the same one-sided-check shape as the `rebase(` count in
        # `test_editor_change_algebra.nim`: absence and agreement were
        # indistinguishable. Adding the spec oracle to READ_ONLY_INPUTS is
        # exactly the case that would have been swallowed.
        if p not in recorded:
            print(f"CONTROL DIGEST ABSENT: {p} is compared by this harness "
                  f"but has no recorded digest — run --needle-scan, review, "
                  f"then --record-control-hashes (§32)")
            ok = False
        elif recorded[p] != digest(p):
            print(f"CONTROL DIGEST MOVED: {p} — re-run --needle-scan BEFORE "
                  f"--record-control-hashes (§32)")
            ok = False
    return ok


@dataclass
class RunResult:
    ran: bool = True
    hung: bool = False
    failed: list = field(default_factory=list)
    cases: int = 0


def run_suite(suites):
    result = RunResult()
    for rel in suites:
        cmd = ["nim", "c", "-r", "--path:src/frontend/viewmodel", "--hints:off",
               "-o:" + suite_binary(rel), rel]
        try:
            proc = subprocess.run(cmd, cwd=ROOT, capture_output=True,
                                  timeout=SUITE_TIMEOUT)
        except subprocess.TimeoutExpired:
            result.hung = True
            return result
        # **BYTES, THEN DECODE WITH `errors="replace"`, AND IT IS NOT
        # DEFENSIVENESS.** The corpus these suites run over contains
        # ILL-FORMED UTF-8 by design — class 7 is bare continuation bytes,
        # overlong encodings and unpaired surrogates — and a failing `check`
        # prints the document. With `text=True` Python decodes the child's
        # output strictly and raises `UnicodeDecodeError` *in the harness*,
        # mid-arm, which is a harness that dies on the arms that are working.
        # It happened: `M3` killed its case, the case printed the document,
        # and the run ended in a traceback with nine arms unexamined. The
        # `finally` restored the subject, which is the only reason this was a
        # lost run rather than a mutated tree.
        out = (proc.stdout + proc.stderr).decode("utf-8", errors="replace")
        oks = out.count("[OK]")
        fails = re.findall(r"\[FAILED\] (.+)", out)
        # **A SUITE THAT PRINTED NO RESULT LINE AT ALL DID NOT RUN**, and a
        # mutation that stops ONE of the two suites compiling while the other
        # still prints its cases would otherwise read as a clean survival.
        if oks == 0 and not fails:
            result.ran = False
            return result
        result.cases += oks
        result.failed.extend(f.strip() for f in fails)
    return result


def restore_active(signum, frame):
    global _ACTIVE
    if _ACTIVE is not None:
        rel, original = _ACTIVE
        write_source(rel, original)
        print(f"\nsignal {signum}: restored {rel}")
    sys.exit(128 + signum)


def install_restore_on_signal():
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, restore_active)


def main():
    global _ACTIVE
    ap = argparse.ArgumentParser()
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    ap.add_argument("--enumerate-touched", action="store_true")
    ap.add_argument("--only", default="")
    args = ap.parse_args()

    if args.enumerate_touched:
        for p in TOUCHED:
            print(p)
        return 0
    if args.needle_scan:
        return needle_scan()
    if args.record_control_hashes:
        if needle_scan() != 0:
            print("REFUSING TO RECORD: a needle is lost or ambiguous (§32). "
                  "The scan runs BEFORE the digests precisely because "
                  "re-recording is when a needle has just moved.")
            return 1
        return record_control_hashes()

    install_restore_on_signal()
    only = {s.strip() for s in args.only.split(",") if s.strip()}

    if needle_scan() != 0:
        print("REFUSING TO RUN: a needle is lost or ambiguous (§32)")
        return 1
    if not check_control_hashes():
        print("REFUSING TO RUN: a control digest moved (§32). Re-run "
              "--needle-scan, review the tree, then --record-control-hashes.")
        return 1

    baseline = {p: digest(p) for p in TOUCHED}

    print("\n=== control ===")
    control = run_suite(SUITES)
    if control.hung or not control.ran or control.failed:
        print(f"CONTROL IS NOT GREEN: hung={control.hung} ran={control.ran} "
              f"failed={control.failed}")
        return 1
    print(f"control: {control.cases} cases, 0 failed")

    print("\n=== arms ===")
    problems = 0
    kills = 0
    for arm in ARMS + DECLARED_SURVIVORS:
        if only and arm.id not in only:
            continue
        original = read_source(arm.path)
        occurrences = original.count(arm.find)
        if occurrences != 1:
            print(f"{arm.id:<5} HARNESS-FAILURE      needle occurs "
                  f"{occurrences} times in {arm.path}, expected 1")
            problems += 1
            continue
        _ACTIVE = (arm.path, original)
        write_source(arm.path, original.replace(arm.find, arm.replace))
        try:
            res = run_suite(SUITES)
        finally:
            write_source(arm.path, original)
            _ACTIVE = None
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{arm.id:<5} HARNESS-FAILURE      {p} did not "
                          f"restore to its control bytes")
                    return 2

        declared = arm in DECLARED_SURVIVORS
        if res.hung:
            verdict, note = "HUNG", (f"no result in {SUITE_TIMEOUT}s — repair "
                                     f"the arm, not the timeout")
            problems += 1
        elif not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif declared and res.failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"died in {res.failed[:2]}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", ""
        elif not res.failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif any(f == arm.killer or f.startswith(arm.killer)
                 for f in res.failed):
            verdict, note = "killed", f"{len(res.failed)} case(s) red"
            kills += 1
        else:
            verdict, note = "MISDIRECTED", f"died in {res.failed[:2]}"
            problems += 1
        print(f"{arm.id:<5} {verdict:<20} {note}")

    print(f"\n{len(ARMS)} arms, {kills} killed, "
          f"{len(DECLARED_SURVIVORS)} declared survivors, {problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
