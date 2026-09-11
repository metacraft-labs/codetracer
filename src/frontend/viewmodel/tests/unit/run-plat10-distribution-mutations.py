#!/usr/bin/env python3
"""Mutation harness for PLAT-10's plugin distribution and capability grants.

WHAT THIS COVERS. Extensibility-Model.md §8.3 (distribution through the
launcher's own mechanism: the `<name>@<version>` layout, `.ctrc` pins, the
version-eligibility rules, and the plugin/capability-file separation) and
PLAT-10's third deliverable (the per-plugin capability grant, its persistence
and its revocation). Five subject files, four suites.

IT IS A SEPARATE FILE FROM THE PLAT-7, PLAT-8 AND PLAT-9 HARNESSES, for the
reason PLAT-8's header gives: each records control digests over its own
campaign's subjects, and merging them would mean one `--record-control-hashes`
re-blessing several campaigns' files at once.

FOUR VERDICTS, NOT TWO (Verification-Harness-Traps §1a and §17):

  killed           the named case reported [FAILED] **and** the failure output
                   carries the arm's own `because`
  MIS-ATTRIBUTED   the named case went red, but not for the arm's reason — it
                   died upstream of the mutated line (§17)
  SURVIVED         the run produced result lines and the named case was green
  HARNESS-FAILURE  the mutation did not apply, did not compile, or the run
                   produced NO result lines at all

Verdicts are parsed out of `[OK]` / `[FAILED]` RESULT LINES, never out of an
exit status.

EVERY KILL ARM CARRIES A NAMED BEHAVIOUR-PRESERVING CONTROL in the same file,
applied on its own, which must leave the suite GREEN.

EVERY ARM'S `because` IS CHECKED AGAINST THE CONTROL RUN, BEFORE ANY MUTATION.

ONLY ONE INSTANCE MAY RUN IN A WORKTREE, enforced with an exclusive `flock`
taken BEFORE the control-hash check.

THE NEEDLE SCAN GATES `--record-control-hashes` (Verification-Harness-Traps
§16).

A `because` IS A QUOTATION OF THE FAILURE TEXT, AND `unittest` PRINTS THE AST
**AFTER** TEMPLATE SUBSTITUTION. Found on this harness's first full run, by its
own §17 verdict: H1 and H2 were written with `because` = the source text of an
assertion inside the `ckRefusedSpawn` TEMPLATE — `not fileExists(sentinel)` —
and `sentinel` is a template parameter. What `check` actually prints is the
SUBSTITUTED expression, `not fileExists(tmp / "after-revoke-same-session")`, so
the needle could never occur and both arms scored MIS-ATTRIBUTED over a
mutation that had killed their case exactly as intended. Two rules follow:

  * a `because` quoting an assertion inside a template must quote the
    expression as it is SUBSTITUTED at the call site, which also makes it
    unique per arm rather than shared by every caller of the template;
  * it must not name a `let` the template declares — those are gensym'd, and
    print as ``outcome`gensym94``.

Both `because` strings are derived from a real failure transcript rather than
typed from the source (§17's second cheaper approximation).

ONE ARM RUNS AGAINST THE END-TO-END SUITE ON PURPOSE (E1). That suite drives
the REAL `ct` binary, and an arm that reddens one of its cases is the evidence
that its assertions grade this repository's code rather than only the
launcher's — a suite whose every assertion is about somebody else's binary
would be green over any change made here.

Usage (from the repository root):
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat10-distribution-mutations.py

`-u` matters when the output is redirected: a full run is tens of minutes and
python otherwise block-buffers stdout.

Arms naming one case are run individually:
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat10-distribution-mutations.py D1 H4
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

DIST = "src/common/plugin_model/distribution.nim"
LEDGER = "src/common/plugin_model/grant_ledger.nim"
HOST = "src/frontend/viewmodel/plugin_host/host.nim"
PCOMP = "src/ct/launch/plugin_components.nim"
GSTORE = "src/ct/launch/grant_store.nim"

TOUCHED = [DIST, LEDGER, HOST, PCOMP, GSTORE]

PURE_SUITE = "src/common/plugin_distribution_test.nim"
CLI_SUITE = "src/ct/launch/plugin_components_test.nim"
E2E_SUITE = "src/ct/launch/plugin_distribution_e2e_test.nim"
VM_SUITE = "src/frontend/viewmodel/tests/unit/test_plugin_grant_lifecycle.nim"

CONTROL_HASHES = HERE / "plat10-distribution-mutation-control.sha256"
LOCK_PATH = HERE / ".plat10-distribution-mutation.lock"

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

# `src/common/plugin_distribution_test.nim`
P_FAILURES = "every way a directory name can fail has its own answer"
P_BOUNDS = "the length bounds are the launcher's, and are asserted as numbers"
P_ROLE = "the role is decided by which files are present, all four ways"
P_LEX = "the comparison is LEXICOGRAPHIC, which is what the launcher does"
P_PINWINS = "a pin beats the active symlink AND the highest version"
P_PINMISSING = "a pin to a version that is not installed selects NOTHING"
P_HISTORY = "grant, then revoke: the last entry in force, the history kept"
P_NARROW = "the narrowing removes exactly the revoked capability"
P_UNDECIDED = "revoking an UNDECIDED capability is recorded, and that matters later"
P_FORGET = "forgetting a plugin removes its entries and nobody else's"
P_BADLINE = "an unusable line is reported by number and the rest is kept"
P_SPELLINGS = "every capability spelling survives the round trip"

# `src/ct/launch/plugin_components_test.nim`
C_BOTHFILES = "a component carrying BOTH files is refused as a plugin, naming both"
C_SHADOW = "a user install shadows a system one of the same name, at any version"
C_ACTIVE = "a REAL `active` symlink beats the highest version"
C_CTRCENV = ("CODETRACER_CTRC_PATH short-circuits the walk, as the launcher "
             "exports it")
C_SILENT = "a misnamed directory with NO plugin manifest is silent"
C_NOTOURS = "a pin on an ordinary command component is not this substrate's business"
C_LEDGERPATH = "the ledger lives beside the launcher's own installs"
C_NOTMP = "the write leaves no temporary behind"
C_STAGING = ("the staging path carries the writer's pid, so two writers cannot "
             "share it")
C_CONCURRENT = "concurrent writers do not lose each other's decisions"

# `src/ct/launch/plugin_distribution_e2e_test.nim`
E_PIN = "a .ctrc pin decides which installed version CodeTracer loads"

# `src/frontend/viewmodel/tests/unit/test_plugin_grant_lifecycle.nim`
V_ACCEPT = "accepting the manifest grants it, and THEN the child runs"
V_LIVE = "a LIVE plugin loses the capability the moment it is revoked"
V_RESTART = "and it is still refused after a restart"
V_POLICY = "the refusal comes from PLAT-8's own policy, not from a second gate"
V_REDISCOVER = "re-running discovery does not hand the capability back"
V_INSPECT = "the inspection API reads the store the SDK reads, for a LIVE plugin"


@dataclass
class Suite:
    path: str
    binary: str
    extra_path: bool = False


NIM_PURE = Suite(PURE_SUITE, "/tmp/plat10-mut-pure")
NIM_CLI = Suite(CLI_SUITE, "/tmp/plat10-mut-cli")
NIM_E2E = Suite(E2E_SUITE, "/tmp/plat10-mut-e2e")
NIM_VM = Suite(VM_SUITE, "/tmp/plat10-mut-vm", extra_path=True)


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
    # -- §8.3, the `<name>@<version>` layout the launcher creates ----------
    Mutation(
        "D1", DIST,
        "  if seps == 0: return crpNoSeparator",
        "  if seps == 0: return crpOk",
        P_FAILURES, NIM_PURE, "crpNoSeparator",
        "any directory under a components root becomes a component reference "
        "with an empty version, so `active`, `.tmp` and a stray `README` all "
        "parse — and a plugin's identity stops being the thing `ct uninstall` "
        "takes",
        control_name="the separator count is tested through a named binding",
        control_find="  if seps == 0: return crpNoSeparator",
        control_replace="  let none = seps == 0\n"
                        "  if none: return crpNoSeparator",
    ),
    Mutation(
        "D2", DIST,
        "  if seps > 1: return crpMultipleSeparators",
        "  if false: return crpMultipleSeparators",
        P_FAILURES, NIM_PURE, "crpMultipleSeparators",
        "a directory name with two separators is accepted, and the launcher "
        "reads its separator position with two different rules that disagree "
        "on exactly that input — so CodeTracer and `ct` would name different "
        "components from one directory",
        control_name="the separator count is compared the other way round",
        control_find="  if seps > 1: return crpMultipleSeparators",
        control_replace="  if not (seps <= 1): return crpMultipleSeparators",
    ),
    Mutation(
        "D3", DIST,
        "  MaxCtrcPins* = 16",
        "  MaxCtrcPins* = 4096",
        P_BOUNDS, NIM_PURE, "MaxCtrcPins == 16",
        "the pin limit stops being the launcher's. A `.ctrc` with twenty pins "
        "would be read here and REFUSED by `ct`, which exits 1 on it — so "
        "CodeTracer would honour pins from a file no component could start "
        "under",
        control_name="the same bound written as an arithmetic expression",
        control_find="  MaxCtrcPins* = 16",
        control_replace="  MaxCtrcPins* = 8 + 8",
    ),
    Mutation(
        "D4", DIST,
        "    if not isComponentVersionChar(c) or c == ComponentSeparator or c == '/':",
        "    if false:",
        P_FAILURES, NIM_PURE, "crpBadVersionChar",
        "a version may carry a path separator or a second `@`, so a component "
        "directory name can name a path outside its own level",
        control_name="the three refusals are tested in the other order",
        control_find="    if not isComponentVersionChar(c) or c == ComponentSeparator or c == '/':",
        control_replace="    if c == '/' or c == ComponentSeparator or not isComponentVersionChar(c):",
    ),
    Mutation(
        "D5", DIST,
        "    if x != y: return x > y",
        "    if x != y: return x < y",
        P_LEX, NIM_PURE, "lexGreater(\"1.9.0\", \"1.10.0\")",
        "the highest-version rule inverts, so CodeTracer loads the OLDEST "
        "installed version of a plugin while `ct` execs the newest",
        control_name="the byte comparison is written as a negated <=",
        control_find="    if x != y: return x > y",
        control_replace="    if x != y: return not (x <= y)",
    ),
    Mutation(
        "D6", DIST,
        "  if pin.len > 0:\n    for v in installed:",
        "  if false:\n    for v in installed:",
        P_PINWINS, NIM_PURE, "vsrPinned",
        "a `.ctrc` pin stops deciding anything: a project that checked a pin "
        "in beside its code gets whichever version happens to be highest, "
        "which is the whole reason the pin was written",
        control_name="the pin presence is tested through a named binding",
        control_find="  if pin.len > 0:\n    for v in installed:",
        control_replace="  let pinned = pin.len > 0\n  if pinned:\n"
                        "    for v in installed:",
    ),
    Mutation(
        "D7", DIST,
        "    return VersionSelection(rule: vsrPinnedMissing, version: \"\")",
        "    discard \"the pin is ignored when it names nothing installed\"",
        P_PINMISSING, NIM_PURE, "vsrPinnedMissing",
        "a pin to an absent version silently falls back to the highest "
        "installed one. `scanLevelForCommand` `continue`s past every "
        "non-matching version, so `ct` would run NOTHING while CodeTracer ran "
        "a version the project pinned away from",
        control_name="the same value written with its fields in the other order",
        control_find="    return VersionSelection(rule: vsrPinnedMissing, version: \"\")",
        control_replace="    return VersionSelection(version: \"\", rule: vsrPinnedMissing)",
    ),
    Mutation(
        "D8", DIST,
        "  if hasPluginManifest and hasCapabilityFile: crAmbiguous",
        "  if false: crAmbiguous",
        P_ROLE, NIM_PURE, "crAmbiguous",
        "a component carrying BOTH files is read as a plugin, so sharing the "
        "distribution format starts implying the exec-by-command-word "
        "dispatch — §8.3's first distinction, deleted",
        control_name="the two file tests are written in the other order",
        control_find="  if hasPluginManifest and hasCapabilityFile: crAmbiguous",
        control_replace="  if hasCapabilityFile and hasPluginManifest: crAmbiguous",
    ),
    # -- the grant ledger --------------------------------------------------
    Mutation(
        "L1", LEDGER,
        "  for i in countdown(ledger.entries.high, 0):\n"
        "    let e = ledger.entries[i]\n"
        "    if e.plugin == plugin and e.capability == cap:\n"
        "      return (if e.decision == gdGranted: gsGranted else: gsRevoked)",
        "  for i in 0 .. ledger.entries.high:\n"
        "    let e = ledger.entries[i]\n"
        "    if e.plugin == plugin and e.capability == cap:\n"
        "      return (if e.decision == gdGranted: gsGranted else: gsRevoked)",
        P_HISTORY, NIM_PURE, "gsRevoked",
        "the FIRST entry wins instead of the last, so a revocation never takes "
        "effect on a capability that was granted before it — the ledger is "
        "append-only, so that is every revocation there will ever be",
        control_name="the countdown is written with an explicit length",
        control_find="  for i in countdown(ledger.entries.high, 0):\n"
                     "    let e = ledger.entries[i]\n"
                     "    if e.plugin == plugin and e.capability == cap:\n"
                     "      return (if e.decision == gdGranted: gsGranted else: gsRevoked)",
        control_replace="  for i in countdown(ledger.entries.len - 1, 0):\n"
                        "    let e = ledger.entries[i]\n"
                        "    if e.plugin == plugin and e.capability == cap:\n"
                        "      return (if e.decision == gdGranted: gsGranted else: gsRevoked)",
    ),
    Mutation(
        "L2", LEDGER,
        "    if ledger.stateOf(plugin, c) == gsGranted:\n      result.incl c",
        "    if true:\n      result.incl c",
        P_NARROW, NIM_PURE, "after.capabilities",
        "the ledger stops narrowing anything: every declared capability is "
        "effective whatever the record says, which is the exact shape "
        "PLAT-10's brief calls theatre",
        control_name="the state is read into a named binding",
        control_find="    if ledger.stateOf(plugin, c) == gsGranted:\n      result.incl c",
        control_replace="    let state = ledger.stateOf(plugin, c)\n"
                        "    if state == gsGranted:\n      result.incl c",
    ),
    Mutation(
        "L3", LEDGER,
        "    if ledger.stateOf(plugin, c) != gsUndecided: continue",
        "    if false: continue",
        P_UNDECIDED, NIM_PURE, "gsRevoked",
        "the acceptance step overwrites a revocation, so a revoked capability "
        "comes back on the next `ct install` or the next start-up that "
        "re-accepts the manifest",
        control_name="the state is compared with an explicit negation",
        control_find="    if ledger.stateOf(plugin, c) != gsUndecided: continue",
        control_replace="    if not (ledger.stateOf(plugin, c) == gsUndecided): continue",
    ),
    Mutation(
        "L4", LEDGER,
        "    if e.plugin == plugin: inc result\n    else: kept.add e",
        "    if e.plugin == plugin: inc result\n    kept.add e",
        P_FORGET, NIM_PURE, "gsUndecided",
        "uninstalling a plugin leaves its grants behind, so reinstalling it "
        "inherits a consent the user gave to a different version of a "
        "different manifest",
        control_name="the plugin test is written with an explicit negation",
        control_find="    if e.plugin == plugin: inc result\n    else: kept.add e",
        control_replace="    if not (e.plugin != plugin): inc result\n"
                        "    else: kept.add e",
    ),
    Mutation(
        "L5", LEDGER,
        "    if not capOk:",
        "    if false:",
        P_BADLINE, NIM_PURE, "parsed.problems.len == 4",
        "a line naming a capability that does not exist becomes an entry for "
        "the enum's ZERO VALUE — so a typo, or a ledger written by a newer "
        "build, grants `process` silently",
        control_name="the capability lookup is tested through a named binding",
        control_find="    if not capOk:",
        control_replace="    let unknownCapability = not capOk\n"
                        "    if unknownCapability:",
    ),
    Mutation(
        "L6", LEDGER,
        "  LedgerFieldSeparator* = '\\t'",
        "  LedgerFieldSeparator* = ':'",
        P_SPELLINGS, NIM_PURE, "parsed.problems.len == 0",
        "the field separator collides with §8.1.2's own spellings: "
        "`socket:local` splits into two fields, so the two socket grants stop "
        "round-tripping and a saved ledger loses them",
        control_name="the same byte written as an escape",
        control_find="  LedgerFieldSeparator* = '\\t'",
        control_replace="  LedgerFieldSeparator* = '\\x09'",
    ),
    # -- discovery, over the tree the launcher wrote ------------------------
    Mutation(
        "P1", PCOMP,
        "      let role = componentRole(fileExists(manifestPath),\n"
        "                               fileExists(dir / CapabilityFile))",
        "      let role = componentRole(fileExists(manifestPath), false)",
        C_BOTHFILES, NIM_CLI, "d.codes() == @[pecPluginAlsoDispatchable]",
        "discovery stops looking for the capability file, so a component that "
        "is exec'd by the launcher on a command word is ALSO loaded as a "
        "plugin — the two roles stop being disjoint",
        control_name="the two file probes are read into named bindings",
        control_find="      let role = componentRole(fileExists(manifestPath),\n"
                     "                               fileExists(dir / CapabilityFile))",
        control_replace="      let hasManifest = fileExists(manifestPath)\n"
                        "      let hasCaps = fileExists(dir / CapabilityFile)\n"
                        "      let role = componentRole(hasManifest, hasCaps)",
    ),
    Mutation(
        "P2", PCOMP,
        "      if entry.name in claimed: continue",
        "      if false: continue",
        C_SHADOW, NIM_CLI, "d.names() == @[\"demo-plugin@1.0.0\"]",
        "a system-level install stops being shadowed by the user's own, so a "
        "machine with both loads two copies of one plugin id — which "
        "`resolve` then refuses as a duplicate, taking the user's install "
        "down with it",
        control_name="the claim test is written through a named binding",
        control_find="      if entry.name in claimed: continue",
        control_replace="      let alreadyClaimed = entry.name in claimed\n"
                        "      if alreadyClaimed: continue",
    ),
    Mutation(
        "P3", PCOMP,
        "  if not symlinkExists(link): return \"\"",
        "  if true: return \"\"",
        C_ACTIVE, NIM_CLI, "vsrActiveSymlink",
        "the `active/<name>` symlink stops being read, so rule 2 of the "
        "launcher's own eligibility order never fires and a level that pins "
        "its active version through a link is decided by the highest instead",
        control_name="the symlink probe is read into a named binding",
        control_find="  if not symlinkExists(link): return \"\"",
        control_replace="  let present = symlinkExists(link)\n"
                        "  if not present: return \"\"",
    ),
    Mutation(
        "P4", PCOMP,
        "  if exported.len > 0:\n"
        "    return (if fileExists(exported): exported else: \"\")",
        "  if false:\n"
        "    return (if fileExists(exported): exported else: \"\")",
        C_CTRCENV, NIM_CLI, "found.path == tmp",
        "the launcher's exported `.ctrc` path is ignored and the walk is "
        "repeated from this process's working directory — which is not "
        "guaranteed to be the launcher's, so the two can read different files",
        control_name="the exported path length is compared the other way",
        control_find="  if exported.len > 0:\n"
                     "    return (if fileExists(exported): exported else: \"\")",
        control_replace="  if exported.len != 0:\n"
                        "    return (if fileExists(exported): exported else: \"\")",
    ),
    Mutation(
        "P5", PCOMP,
        "      if fileExists(child / PluginManifestFile):\n"
        "        result.badDirs.add base",
        "      if true:\n"
        "        result.badDirs.add base",
        C_SILENT, NIM_CLI, "d.problems.len == 0",
        "every directory under a components root that is not `<name>@<version>` "
        "is reported as a broken plugin, so a user's real components root "
        "produces a column of errors about things that were never plugins",
        control_name="the manifest probe is read into a named binding",
        control_find="      if fileExists(child / PluginManifestFile):\n"
                     "        result.badDirs.add base",
        control_replace="      let claimsPlugin = fileExists(child / PluginManifestFile)\n"
                        "      if claimsPlugin:\n"
                        "        result.badDirs.add base",
    ),
    Mutation(
        "P6", PCOMP,
        "        if anyPlugin:\n          claimed.add entry.name",
        "        if true:\n          claimed.add entry.name",
        C_NOTOURS, NIM_CLI, "d.problems.len == 0",
        "a `.ctrc` pin on an ordinary command component is reported as a "
        "plugin problem, attributing the launcher's business to the plugin "
        "substrate — and claiming the name, so a plugin of the same name at a "
        "lower level is then invisible",
        control_name="the flag is compared explicitly",
        control_find="        if anyPlugin:\n          claimed.add entry.name",
        control_replace="        if anyPlugin == true:\n"
                        "          claimed.add entry.name",
    ),
    # -- the grant store on disk --------------------------------------------
    # RE-AIMED on 2026-09-11, Verification-Harness-Traps §16. F3 moved the write
    # into `writeLedgerLocked` and made the staging path pid-unique, so the
    # arm's old quotation (`let tmp = path & ".tmp"` …) no longer occurred and
    # the arm had become unkillable — a row that looks like coverage. The needle
    # scan caught it before the digests were re-recorded, which is the ordering
    # §16 exists to impose.
    Mutation(
        "G1", GSTORE,
        "    let staging = grantLedgerStagingPath(path)\n"
        "    writeFile(staging, ledger.render())\n"
        "    moveFile(staging, path)",
        "    writeFile(grantLedgerStagingPath(path), ledger.render())",
        C_NOTMP, NIM_CLI,
        "not fileExists(grantLedgerStagingPath(grantLedgerPath()))",
        "the ledger is written to a staging file that is never renamed, so "
        "every grant and every revocation is lost at the next start-up — and "
        "the failure is invisible, because `saveGrantLedger` still returns "
        "success",
        control_name="the staging path is held in a differently named binding",
        control_find="    let staging = grantLedgerStagingPath(path)\n"
                     "    writeFile(staging, ledger.render())\n"
                     "    moveFile(staging, path)",
        control_replace="    let tmpPath = grantLedgerStagingPath(path)\n"
                        "    writeFile(tmpPath, ledger.render())\n"
                        "    moveFile(tmpPath, path)",
    ),
    # -- F3: the two halves of "atomic against a concurrent writer" ----------
    Mutation(
        "G4", GSTORE,
        "  if path.len == 0: \"\" else: path & \".tmp.\" & $getCurrentProcessId()",
        "  if path.len == 0: \"\" else: path & \".tmp\"",
        C_STAGING, NIM_CLI, "mine != path & \".tmp\"",
        "the staging path goes back to a FIXED name, so two savers share one "
        "staging inode and each can rename the other's half-written bytes over "
        "the ledger. `parseLedger` is total, so a truncation at a line boundary "
        "loads as FEWER grants — and a lost `revoke` line restores a capability "
        "the user took back, which is the one direction this record must never "
        "fail in",
        control_name="the pid is read into a named binding first",
        control_find="  if path.len == 0: \"\" else: path & \".tmp.\" & $getCurrentProcessId()",
        control_replace="  let pid = getCurrentProcessId()\n"
                        "  if path.len == 0: \"\" else: path & \".tmp.\" & $pid",
    ),
    Mutation(
        "G5", GSTORE,
        "        if lockFd >= 0:\n          discard flockEx(lockFd)",
        "        if lockFd >= 0:\n          discard lockFd",
        C_CONCURRENT, NIM_CLI,
        "back.ledger.entries.len == ConcurrentWriters * GrantsPerWriter",
        "the descriptor is opened and never locked, so a read-modify-write is "
        "no longer serialised: two processes that each load the same starting "
        "ledger, each append and each save both succeed, and the file carries "
        "whichever was written last. No file is torn; one decision is simply "
        "gone. "
        "THIS ARM GRADES A RACE, and the margin is the evidence that it is not "
        "a coin flip (Verification-Harness-Traps §12): across 15 runs of the "
        "same four children with the lock removed, 8 to 26 of the 32 entries "
        "survived and 32 was never reached, while every locked run was 32",
        control_name="the lock result is held in a named binding",
        control_find="        if lockFd >= 0:\n          discard flockEx(lockFd)",
        control_replace="        if lockFd >= 0:\n"
                        "          let locked = flockEx(lockFd)\n"
                        "          discard locked",
    ),
    Mutation(
        "G2", GSTORE,
        "  r / grantStoreSubdir / grantStoreVersion / grantStoreFileName",
        "  r / grantStoreFileName",
        C_LEDGERPATH, NIM_CLI, "grantLedgerPath() == tmp /",
        "the ledger moves out of its versioned directory and into the root "
        "the launcher owns, beside `components/`, `active/` and `registry/` — "
        "a state file with no version in its path, in a directory a package "
        "manager writes to",
        control_name="the same path written with explicit grouping",
        control_find="  r / grantStoreSubdir / grantStoreVersion / grantStoreFileName",
        control_replace="  (r / grantStoreSubdir) / (grantStoreVersion / grantStoreFileName)",
    ),
    Mutation(
        "G3", GSTORE,
        "  if override.len > 0: return override.strip(leading = false, chars = {'/'})",
        "  if false: return override.strip(leading = false, chars = {'/'})",
        C_LEDGERPATH, NIM_CLI, "launcherUserRoot() == tmp",
        "`CODETRACER_USER_ROOT` stops selecting the root, so a second profile "
        "gets the FIRST profile's grants — and every suite that isolates "
        "itself with that variable silently writes into the developer's real "
        "`~/.codetracer`",
        control_name="the override length is compared the other way",
        control_find="  if override.len > 0: return override.strip(leading = false, chars = {'/'})",
        control_replace="  if override.len != 0: return override.strip(leading = false, chars = {'/'})",
    ),
    # -- the end-to-end suite grades THIS repository, not only the launcher --
    Mutation(
        "E1", DIST,
        "    for v in installed:\n      if v == pin:\n"
        "        return VersionSelection(rule: vsrPinned, version: v)",
        "    for v in installed:\n      if false:\n"
        "        return VersionSelection(rule: vsrPinned, version: v)",
        E_PIN, NIM_E2E, "pinned.plugins.len == 1",
        "the pin never matches an installed version, so a project's checked-in "
        "`.ctrc` selects nothing at all. THE POINT OF PUTTING THIS ARM IN THE "
        "END-TO-END SUITE is that the suite's tree is built by the real `ct`: "
        "if every assertion there were about the launcher's behaviour, this "
        "arm would leave it green",
        control_name="the pin comparison is written the other way round",
        control_find="    for v in installed:\n      if v == pin:\n"
                     "        return VersionSelection(rule: vsrPinned, version: v)",
        control_replace="    for v in installed:\n      if pin == v:\n"
                        "        return VersionSelection(rule: vsrPinned, version: v)",
    ),
    # -- the host: where a narrowing becomes a refusal -----------------------
    Mutation(
        "H1", HOST,
        "  if host.records.hasKey(id):\n"
        "    let rec = host.records[id]\n"
        "    if not rec.ctx.isNil:",
        "  if false:\n"
        "    let rec = host.records[id]\n"
        "    if not rec.ctx.isNil:",
        V_LIVE, NIM_VM, 'not fileExists(tmp / "after-revoke-same-session")',
        "a LIVE plugin keeps the grants it was activated with. `PluginManifest` "
        "is a value type, so revoking would edit a copy the running plugin "
        "does not read — the user is told the capability is gone and the "
        "plugin goes on spawning",
        control_name="the record lookup is read into a named binding",
        control_find="  if host.records.hasKey(id):\n"
                     "    let rec = host.records[id]\n"
                     "    if not rec.ctx.isNil:",
        control_replace="  let live = host.records.hasKey(id)\n"
                        "  if live:\n"
                        "    let rec = host.records[id]\n"
                        "    if not rec.ctx.isNil:",
    ),
    Mutation(
        "H2", HOST,
        "  if host.resolution.manifests.hasKey(id):\n"
        "    host.resolution.manifests[id].grants = narrowed",
        "  if false:\n"
        "    host.resolution.manifests[id].grants = narrowed",
        V_RESTART, NIM_VM, 'not fileExists(tmp / "after-restart")',
        "the stored manifest is never narrowed, so a plugin activated AFTER a "
        "revocation — which is every plugin after a restart — is handed the "
        "capability the user took back",
        control_name="the manifest lookup is read into a named binding",
        control_find="  if host.resolution.manifests.hasKey(id):\n"
                     "    host.resolution.manifests[id].grants = narrowed",
        control_replace="  let known = host.resolution.manifests.hasKey(id)\n"
                        "  if known:\n"
                        "    host.resolution.manifests[id].grants = narrowed",
    ),
    Mutation(
        "H3", HOST,
        "    host.declaredGrants[result.manifest.id] = result.manifest.grants",
        "    host.declaredGrants[result.manifest.id] = GrantSet()",
        V_ACCEPT, NIM_VM, "capProcess in w.host.effectiveCapabilitiesOf(ProbeId)",
        "the declared set a grant is intersected with is empty, so no grant "
        "the user gives can ever take effect. It fails CLOSED, which is why it "
        "needs an arm: every refusal assertion in the campaign is MORE "
        "satisfied by it and only a positive case notices "
        "(Verification-Harness-Traps §15)",
        control_name="the declared grants are captured through a named binding",
        control_find="    host.declaredGrants[result.manifest.id] = result.manifest.grants",
        control_replace="    let declared = result.manifest.grants\n"
                        "    host.declaredGrants[result.manifest.id] = declared",
    ),
    Mutation(
        "H4", HOST,
        "  result = host.ledger.revoke(id, cap, at, note)\n"
        "  host.applyLedgerTo(id)",
        "  result = host.ledger.revoke(id, cap, at, note)",
        V_LIVE, NIM_VM, "capProcess notin w.host.effectiveCapabilitiesOf(ProbeId)",
        "THE THEATRE ARM. The revocation is recorded, the report says REVOKED, "
        "the history shows the date — and nothing narrows a `GrantSet`, so the "
        "plugin keeps the capability. This is the state PLAT-10's brief names "
        "as the thing to prove does not happen",
        control_name="the revocation result is held before the narrowing",
        control_find="  result = host.ledger.revoke(id, cap, at, note)\n"
                     "  host.applyLedgerTo(id)",
        control_replace="  let changed = host.ledger.revoke(id, cap, at, note)\n"
                        "  host.applyLedgerTo(id)\n"
                        "  result = changed",
    ),
    Mutation(
        "H6", HOST,
        "  if host.ledgerAttached: host.applyLedger()",
        "  discard host.ledgerAttached",
        V_REDISCOVER, NIM_VM, 'not fileExists(tmp / "after-rediscovery")',
        "THE SECOND THEATRE ARM, and the one that needed no fault to reach: "
        "`resolveAll` rebuilds `resolution.manifests` from `host.parsed` — the "
        "UN-narrowed parse — so a second discovery pass hands every plugin its "
        "DECLARED set back, and `activateOne` copies the widened manifest into "
        "the next `ctx`. The ledger still says `revoke` and `report()` still "
        "prints REVOKED with the date. `resolveAll` and `deactivate` are both "
        "public and neither is privileged, so nothing but this line stood "
        "between a recorded revocation and a running child",
        control_name="the ledger flag is read into a named binding",
        control_find="  if host.ledgerAttached: host.applyLedger()",
        control_replace="  let governed = host.ledgerAttached\n"
                        "  if governed: host.applyLedger()",
    ),
    Mutation(
        "H5", HOST,
        "    host.resolution.manifests[id].capabilities = narrowed.capabilities",
        "    discard narrowed.capabilities",
        V_POLICY, NIM_VM, "grants.capabilities",
        "the manifest's two spellings of one capability set diverge: "
        "`capabilities` keeps the declared set while `grants.capabilities` "
        "carries the narrowed one, so any future reader that picks the first "
        "reads a revoked capability as held",
        control_name="the narrowed set is assigned through a named binding",
        control_find="    host.resolution.manifests[id].capabilities = narrowed.capabilities",
        control_replace="    let effective = narrowed.capabilities\n"
                        "    host.resolution.manifests[id].capabilities = effective",
    ),
]


# DECLARED SURVIVORS. Each is a mutation this campaign's suites CANNOT kill,
# with the reason, so the gap is a line in the transcript rather than an
# absence.
DECLARED_SURVIVORS: list[Mutation] = [
    # Two candidates were considered while this harness was written and both
    # turned out to be killable once the case was written the other way round:
    #
    #   * "the `.capabilities` shorthand stops being narrowed" looked
    #     unobservable, because nothing on the runtime path reads it —
    #     `grantsOf` reads `.grants`. It is observable as an INVARIANT between
    #     two fields the manifest documents as one set, and arm H5 grades it
    #     against an assertion written for exactly that.
    #   * "`revokeCapability` records but does not narrow" looked like the same
    #     assertion as "the ledger says revoked". It is not: the first is a
    #     sentinel file that does not appear (H4), the second is a string.
    #
    # The one below is genuinely unkillable BY CONSTRUCTION, and saying why is
    # the point of this list.
    Mutation(
        "S1", HOST,
        "  if host.isActive(id):\n"
        "    let rec = host.records[id]\n"
        "    if not rec.ctx.isNil:\n"
        "      return grantsOf(rec.ctx).capabilities",
        "  if false:\n"
        "    let rec = host.records[id]\n"
        "    if not rec.ctx.isNil:\n"
        "      return grantsOf(rec.ctx).capabilities",
        V_INSPECT, NIM_VM,
        "w.host.effectiveCapabilitiesOf(ProbeId) == grantsOf(w.probe.ctx)",
        "F2's repair: `effectiveCapabilitiesOf` reads the LIVE context when "
        "there is one, rather than `resolution.manifests` unconditionally. "
        "NO CASE IN THIS CAMPAIGN CAN KILL IT, and the reason is the reason the "
        "repair is defence rather than a behaviour change: in a HEALTHY host "
        "`applyLedgerTo` writes both stores together and `activateOne` copies "
        "one from the other, so the two never disagree and reading either gives "
        "the same answer. The branch is observable only under a fault. "
        "IT IS GRADED ALL THE SAME, BY ARM H1 — measured on 2026-09-11 with H1 "
        "applied (the arm that stops the live context being narrowed): reading "
        "`resolution.manifests` reported `{fs:read}` and left assertion (2) of "
        "V_LIVE GREEN over a host that spawned the child, so only the sentinel "
        "file caught it; reading the live context reports "
        "`{process, fs:read}` and reddens it. So the value of this line is a "
        "second assertion that stops being vacuous under fault, which is "
        "exactly what a mutation of the line itself cannot show",
        control_name="the active test is read into a named binding",
        control_find="  if host.isActive(id):\n"
                     "    let rec = host.records[id]\n"
                     "    if not rec.ctx.isNil:\n"
                     "      return grantsOf(rec.ctx).capabilities",
        control_replace="  let live = host.isActive(id)\n"
                        "  if live:\n"
                        "    let rec = host.records[id]\n"
                        "    if not rec.ctx.isNil:\n"
                        "      return grantsOf(rec.ctx).capabilities",
    ),
]
@dataclass
class RunResult:
    rc: int = 0
    ran: bool = True
    passed: list[str] = None
    failed: list[str] = None
    output: str = ""

    def __post_init__(self):
        if self.passed is None:
            self.passed = []
        if self.failed is None:
            self.failed = []

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def run_suite(suite: Suite, label: str) -> RunResult:
    """Compile and run one suite; parse its verdict out of its RESULT LINES."""
    res = RunResult()
    compile_cmd = ["nim", "c", "-f", "--hints:off", "--warnings:off"]
    if suite.extra_path:
        compile_cmd.append("--path:src/frontend/viewmodel")
    compile_cmd += [f"--nimcache:/tmp/plat10-mut-cache-{Path(suite.path).stem}",
                    f"-o:{suite.binary}", suite.path]
    compile_proc = subprocess.run(compile_cmd, cwd=ROOT, capture_output=True,
                                  text=True, timeout=3600)
    if compile_proc.returncode != 0:
        res.rc = compile_proc.returncode
        res.ran = False
        res.output = compile_proc.stdout + compile_proc.stderr
        print("      ---- did not compile; last 12 lines ----")
        for line in res.output.splitlines()[-12:]:
            print("      " + line)
        return res
    proc = subprocess.run([suite.binary], cwd=ROOT, capture_output=True,
                          text=True, timeout=3600)
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
    been moved, and recording first would certify the drift.
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
    body = ["# Control digests for run-plat10-distribution-mutations.py.",
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
            "# (Verification-Harness-Traps §16).",
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

    # THE SUITE SET IS DERIVED FROM THE ARMS, not written out beside them —
    # a second registry of the same fact is where the two drift apart
    # (Verification-Harness-Traps §14).
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
    # checked BEFORE any mutation. An arm whose killer does not is an arm that
    # can never legitimately be killed, and it would sit in the table looking
    # like coverage.
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
    # sentinel rule applied to it). A `because` that already occurs in a
    # passing run is true for free, so an arm carrying one could be scored
    # `killed` for a case that died three hundred lines upstream — which is
    # exactly the mis-attribution the fourth verdict exists to catch.
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
        elif not newly_failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif mut.killer not in newly_failed:
            verdict, note = "MISDIRECTED", f"died in {newly_failed}, not {mut.killer!r}"
            problems += 1
        elif not attributed:
            # Verification-Harness-Traps §17: the case went red, and not for
            # this arm's reason. `the run told you nothing` — so this belongs
            # beside HARNESS-FAILURE, not beside `killed`.
            verdict = "MIS-ATTRIBUTED"
            note = f"the case died without {mut.because!r} in the failure output"
            problems += 1
        else:
            others = [f for f in newly_failed if f != mut.killer]
            killed += 1
            verdict = "killed"
            note = mut.killer + (f"  (+{len(others)} more)" if others else "")
        print(f"{mut.id:<5} {verdict:<20} {note}")

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
