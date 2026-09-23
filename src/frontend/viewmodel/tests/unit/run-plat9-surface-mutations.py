#!/usr/bin/env python3
"""Mutation harness for PLAT-9's contributed surfaces, degradation and faults.

WHAT THIS COVERS. Extensibility-Model.md §6 (the contributed pane identity, the
per-surface view choice and the required/optional rule), §7 (fault containment
and `--no-extensions`) and §8.2 (the dependency probe and its degradation
through the EXISTING `PaneDegradation` model). Ten files, three suites.

IT IS A SEPARATE FILE FROM `run-plat7-boundary-mutations.py` AND
`run-plat8-io-mutations.py` ON PURPOSE, for the reason PLAT-8's own header
gives: each harness records control digests over its own campaign's subjects,
and merging them would mean one `--record-control-hashes` step re-blessing
several campaigns' files at once.

FOUR VERDICTS, NOT TWO (Verification-Harness-Traps §1a and §17):

  killed           the named case reported [FAILED] **and** the failure output
                   carries the arm's own `because`
  MIS-ATTRIBUTED   the named case went red, but not for the arm's reason — it
                   died upstream of the mutated line (§17). This sits beside
                   HARNESS-FAILURE rather than beside `killed`, because like it
                   the run told you nothing
  SURVIVED         the run produced result lines and the named case was green
  HARNESS-FAILURE  the mutation did not apply, did not compile, or the run
                   produced NO result lines at all

Verdicts are parsed out of `[OK]` / `[FAILED]` RESULT LINES, never out of an
exit status: `nim c -r` returns the same non-zero code for a compile error, a
failed assertion and an OOM.

EVERY KILL ARM CARRIES A NAMED BEHAVIOUR-PRESERVING CONTROL in the same file,
applied on its own, which must leave the suite GREEN. Without it a red arm
proves only that the file was touched.

EVERY ARM'S `because` IS CHECKED AGAINST THE CONTROL RUN, BEFORE ANY MUTATION.
A `because` that already occurs in the green output is not evidence of
anything — it is §5's sentinel-that-is-sometimes-true-for-free, moved into the
attribution field. The pre-flight refuses the whole run when one does.

ONLY ONE INSTANCE MAY RUN IN A WORKTREE, enforced with an exclusive `flock`
taken BEFORE the control-hash check. Two instances each restore from their own
in-memory snapshot, so the loser writes back bytes the winner had already
mutated and every verdict after that point grades a file nobody chose.

THE CONTROL HASHES ARE RECORDED ON DISK, NOT TAKEN AT START-UP. A baseline
taken at start-up cannot tell a clean tree from one a killed run left a
mutation in — it reads the mutation as the baseline, and every restore then
verifies against the mutated bytes.

THE NEEDLE SCAN GATES `--record-control-hashes` (Verification-Harness-Traps
§16). Re-recording digests is the moment a tree's new bytes are blessed as the
baseline, and it is exactly the moment an arm's needle may have been moved by
the repair that made the re-record necessary.

Usage (from the repository root):
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat9-surface-mutations.py

`-u` matters when the output is redirected: a full run is tens of minutes and
python otherwise block-buffers stdout, so a log stays EMPTY until the last arm.

Arms naming one case are run individually:
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat9-surface-mutations.py M1 M14
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

CPI = "src/common/contributed_pane_id.nim"
SURF = "src/common/plugin_model/surfaces.nim"
MANIFEST = "src/common/plugin_model/manifest.nim"
RESOLUTION = "src/common/plugin_model/resolution.nim"
DEG = "src/frontend/viewmodel/store/degraded_state.nim"
SHOST = "src/frontend/viewmodel/plugin_host/surface_host.nim"
HOST = "src/frontend/viewmodel/plugin_host/host.nim"
API = "src/frontend/viewmodel/plugin_host/plugin_api.nim"
LAYOUT = "src/frontend/headless_app/layout_model.nim"
EXTSEL = "src/ct/extension_selection.nim"
MAPPINGS = "src/common/view_vocabulary/mappings.nim"

TOUCHED = [CPI, SURF, MANIFEST, RESOLUTION, DEG, SHOST, HOST, API, LAYOUT,
           EXTSEL, MAPPINGS]

PURE_SUITE = "src/common/plugin_surfaces_test.nim"
VM_SUITE = "src/frontend/viewmodel/tests/unit/test_plugin_surfaces.nim"
CLI_SUITE = "src/ct/extension_selection_test.nim"

CONTROL_HASHES = HERE / "plat9-surface-mutation-control.sha256"
LOCK_PATH = HERE / ".plat9-surface-mutation.lock"

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

# `src/common/plugin_surfaces_test.nim`
P_BARE = ("a bare name is not a contributed pane id — which is what makes a "
          "builtin one impossible")
P_CHARSET = "the charset is closed, so an id survives a layout document unchanged"
P_EDGES = "the empty and edge cases each have their own answer"
P_NATIVE = "a native view is PREFERRED over the abstract one on its own front-end"
P_ABSENT = "'abstract is not automatically everywhere' is NO LONGER TRUE OF ANY SHIPPED ENTRY"
P_BOTH = "the refusal names both, and says what to do about it"
P_OPTIONAL = "an optional surface is simply not present, and is still NAMED"
P_COMMAND = "a COMMAND is invoked, not drawn, so §6.3 never refuses one"
P_FAILS = "on the terminal the plugin is not loadable and is not in the order"
P_BADID = "a malformed contributed pane id is refused at load time"
P_NOINSTALL = "a declared dependency without an install action is refused"
P_UNDECLARED = "a dependency outside the declared executables can never be met"
P_ABSENTSET = ("the GPUI absent set is read out of the table, and the prose is "
               "pinned to it")
P_DUPSURFACE = ("a pane and a marker sharing one local id are refused, naming "
                "both")

# `src/frontend/viewmodel/tests/unit/test_plugin_surfaces.nim`
V_REFUSED = ("the plugin fails activation, and the refusal names the "
             "front-end and the surface")
V_DEGRADED = "the degraded surface names the tool and the remedy; the sibling works"
V_REPROBE = "installing the tool and firing the declared trigger un-degrades it"
V_NOTRIGGER = "a surface that declared NO trigger is not re-probed by the same event"
V_FAULT1 = "the first fault is contained and attributed; the sibling surface renders"
V_DISABLED = "repeated faults disable the plugin, and the host STOPS calling the view"
V_NIL = "a view that returns nil is a fault too, not a blank region"
V_ACTIVATE = ("a plugin whose activate() raises is contained, and its "
              "neighbour still loads")
V_UNDECLARED_VIEW = ("a plugin contributing a view for a surface it never "
                     "declared is refused")
V_HOSTILE = "a hostile id spelled like a built-in pane cannot become one"
V_BADDOC = "a malformed contributed pane in a document is refused, with its kind"
V_BOTHKEYS = "a leaf claiming BOTH namespaces is refused"
V_INVISIBLE = "a contributed leaf is invisible to the PaneKind-typed algebra"
V_DEFECT = ("a view raising IndexDefect is contained, disabled, and the "
            "debugger survives")
V_DEFECTBOOT = ("a plugin whose activate() raises a Defect is contained and "
                "not retried")
V_NOEXT = "no plugin code runs, nothing is registered, and the report names the flag"
V_OPTIONAL = ("an OPTIONAL surface with no view is simply absent, and the "
              "plugin runs")

# `src/ct/extension_selection_test.nim`
C_PRESENT = "present, it is removed and nothing else is"
C_NOVALUE = "the flag takes no value, so it cannot be inverted by one"
C_DASHDASH = "everything after a bare -- belongs to the recorded program"


@dataclass
class Suite:
    path: str
    binary: str
    extra_path: bool = False


NIM_PURE = Suite(PURE_SUITE, "/tmp/plat9-mut-pure")
NIM_VM = Suite(VM_SUITE, "/tmp/plat9-mut-vm", extra_path=True)
NIM_CLI = Suite(CLI_SUITE, "/tmp/plat9-mut-cli")


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
    # -- §6.1, the contributed pane identity -------------------------------
    Mutation(
        "M1", CPI,
        "  if cuts == 0: return pipNoSeparator",
        "  if cuts == 0: return pipOk",
        P_BARE, NIM_PURE, "pipNoSeparator",
        "a BARE NAME becomes a valid contributed pane id, so an extension can "
        "spell an id exactly like a built-in pane and the two namespaces stop "
        "being disjoint — the collision PLAT-9's identity exists to prevent",
        control_name="the separator count is tested through a named binding",
        control_find="  if cuts == 0: return pipNoSeparator",
        control_replace="  let noSeparator = cuts == 0\n"
                        "  if noSeparator: return pipNoSeparator",
    ),
    Mutation(
        "M2", CPI,
        "    if not isPaneIdChar(c): return pipBadCharacter",
        "    if false: return pipBadCharacter",
        P_CHARSET, NIM_PURE, "pipBadCharacter",
        "the charset stops being closed: an id may carry a quote, a newline or "
        "a control character into a persisted layout document",
        control_name="the charset test is written through a named binding",
        control_find="    if not isPaneIdChar(c): return pipBadCharacter",
        control_replace="    let allowed = isPaneIdChar(c)\n"
                        "    if not allowed: return pipBadCharacter",
    ),
    Mutation(
        "M3", CPI,
        "  MaxPaneIdSegment* = 64",
        "  MaxPaneIdSegment* = 4096",
        P_EDGES, NIM_PURE, "pipTooLong",
        "the per-segment bound stops being the bound the suite measures; an id "
        "written into a tab and a document has no size anybody decided",
        control_name="the same bound written as an arithmetic expression",
        control_find="  MaxPaneIdSegment* = 64",
        control_replace="  MaxPaneIdSegment* = 32 + 32",
    ),
    # -- §6.2, which view runs here ----------------------------------------
    Mutation(
        "M4", SURF,
        "  if fe in c.nativeFrontEnds:\n    result.kind = vcNative",
        "  if false:\n    result.kind = vcNative",
        P_NATIVE, NIM_PURE, "vcNative",
        "§6.2's 'with the native one preferred where present' stops holding: a "
        "surface supplying both gets its abstract baseline on the front-end it "
        "wrote a native view for",
        control_name="the native-front-end test is written through a named binding",
        control_find="  if fe in c.nativeFrontEnds:\n    result.kind = vcNative",
        control_replace="  let hasNative = fe in c.nativeFrontEnds\n"
                        "  if hasNative:\n    result.kind = vcNative",
    ),
    # -- §6.3, required / optional -----------------------------------------
    Mutation(
        "M6", SURF,
        "    if c.requirement != srRequired: continue",
        "    if c.requirement == srRequired: continue",
        P_BOTH, NIM_PURE, "refusals.len == 1",
        "required and optional swap: a required surface with no view loads "
        "silently doing nothing, and an optional one fails the plugin",
        control_name="the requirement test is written with an explicit negation",
        control_find="    if c.requirement != srRequired: continue",
        control_replace="    if not (c.requirement == srRequired): continue",
    ),
    Mutation(
        "M7", SURF,
        "  for c in m.contributions:\n"
        "    if c.kind notin RenderingContributionKinds: continue\n"
        "    if c.requirement != srRequired: continue",
        "  for c in m.contributions:\n"
        "    if false: continue\n"
        "    if c.requirement != srRequired: continue",
        P_COMMAND, NIM_PURE, "surfaceRefusals(m.manifest, fe).len == 0",
        "a COMMAND is evaluated for 'no view on this front-end', a state it "
        "cannot be in — so a required command fails the plugin on every "
        "front-end and the palette loses it everywhere",
        control_name="the rendering-kind test is written through a named binding",
        control_find="  for c in m.contributions:\n"
                     "    if c.kind notin RenderingContributionKinds: continue\n"
                     "    if c.requirement != srRequired: continue",
        control_replace="  for c in m.contributions:\n"
                        "    let renders = c.kind in RenderingContributionKinds\n"
                        "    if not renders: continue\n"
                        "    if c.requirement != srRequired: continue",
    ),
    Mutation(
        "M8", RESOLUTION,
        "  if frontEnd.isSome:",
        "  if false:",
        P_FAILS, NIM_PURE, "r.isLoadable",
        "§6.3's refusal is computed and then not applied: the plugin resolves, "
        "activates, and does nothing where it has no view",
        control_name="the option test is written through a named binding",
        control_find="  if frontEnd.isSome:",
        control_replace="  let haveFrontEnd = frontEnd.isSome\n"
                        "  if haveFrontEnd:",
    ),
    Mutation(
        "M9", HOST,
        "  host.resolution = resolve(host.parsed, host.coreVersion,\n"
        "                            some(host.frontEnd))",
        "  host.resolution = resolve(host.parsed, host.coreVersion)",
        V_REFUSED, NIM_VM, "host.isLoadable",
        "THE WIRING, GRADED END TO END. `surfaceRefusals` still returns the "
        "right answer and `resolve` still applies it; the host simply stops "
        "telling either of them which front-end it is. A rule graded only "
        "where it is written is a rule nobody has shown is called.",
        control_name="the front-end option is built into a named binding first",
        control_find="  host.resolution = resolve(host.parsed, host.coreVersion,\n"
                     "                            some(host.frontEnd))",
        control_replace="  let here = some(host.frontEnd)\n"
                        "  host.resolution = resolve(host.parsed, "
                        "host.coreVersion, here)",
    ),
    # -- §6.1's manifest validation ----------------------------------------
    Mutation(
        "M10", MANIFEST,
        "            if idProblem != pipOk:",
        "            if false:",
        P_BADID, NIM_PURE, "pecBadContributedPaneId",
        "a malformed contributed pane id is accepted at load time, so it "
        "reaches a persisted layout and every consumer after it",
        control_name="the problem is compared through an explicit equality",
        control_find="            if idProblem != pipOk:",
        control_replace="            if not (idProblem == pipOk):",
    ),
    Mutation(
        "M11", MANIFEST,
        "          if c.needs.len > 0 and c.install.strip().len == 0:",
        "          if false:",
        P_NOINSTALL, NIM_PURE, "pecMissingInstallHint",
        "§8.2's 'a name and an install action, not \"unavailable\"' becomes "
        "optional: a surface may declare a dependency it can never tell a user "
        "how to install",
        control_name="the two conditions are swapped, which is the same conjunction",
        control_find="          if c.needs.len > 0 and c.install.strip().len == 0:",
        control_replace="          if c.install.strip().len == 0 and c.needs.len > 0:",
    ),
    Mutation(
        "M12", MANIFEST,
        "      if tool notin m.grants.executables:",
        "      if false:",
        P_UNDECLARED, NIM_PURE, "pecUndeclaredDependency",
        "a surface may need a tool the manifest never declared — §8.1.1 "
        "resolves against the declared set, so that surface is degraded "
        "forever for a reason the degradation cannot state",
        control_name="the membership test is written through a named binding",
        control_find="      if tool notin m.grants.executables:",
        control_replace="      let declared = tool in m.grants.executables\n"
                        "      if not declared:",
    ),
    # -- §8.2, the probe and its degradation -------------------------------
    Mutation(
        "M13", SHOST,
        "    of dpAbsent, dpUnprobed: return pdsAbsent",
        "    of dpAbsent, dpUnprobed: discard",
        V_DEGRADED, NIM_VM, "pdDependencyMissing",
        "a missing tool stops reaching the degradation model at all: the "
        "surface renders as though it were complete, which §8.2 calls 'the "
        "plugin-model version of a green suite that asserts nothing'",
        control_name="the two absent states are listed in the other order",
        control_find="    of dpAbsent, dpUnprobed: return pdsAbsent",
        control_replace="    of dpUnprobed, dpAbsent: return pdsAbsent",
    ),
    Mutation(
        # RE-AIMED 2026-09-11 (Verification-Harness-Traps §16). The arm quoted
        # a two-line conjunction; the redundant half — `surfaceDegradation(...)
        # != pdNone`, implied by the half that remains — was removed, and the
        # needle would otherwise have stopped matching and left this row
        # looking like coverage it could no longer provide.
        "M14", SHOST,
        "  if sh.dependencyState(qualifiedId) != pdsSatisfied:\n"
        "    return sh.degradedNode(qualifiedId)",
        "  if false:\n"
        "    return sh.degradedNode(qualifiedId)",
        V_DEGRADED, NIM_VM, "disassemblyRenders",
        "THE CALL SITE, as opposed to the decision. `surfaceDegradation` still "
        "answers `pdDependencyMissing` and the renderer ignores it, so the "
        "plugin's own view runs with its tool absent. A policy that says "
        "'degraded' and a call site that renders anyway are indistinguishable "
        "from the policy alone.",
        control_name="the dependency test is written through a named binding",
        control_find="  if sh.dependencyState(qualifiedId) != pdsSatisfied:\n"
                     "    return sh.degradedNode(qualifiedId)",
        control_replace="  let unmet = sh.dependencyState(qualifiedId) != "
                        "pdsSatisfied\n"
                        "  if unmet:\n"
                        "    return sh.degradedNode(qualifiedId)",
    ),
    Mutation(
        "M15", SHOST,
        "    if now != before:\n"
        "      rec.probes[tool] = now\n"
        "      result = true",
        "    if false:\n"
        "      rec.probes[tool] = now\n"
        "      result = true",
        V_REPROBE, NIM_VM, "reprobeDependencies",
        "a re-probe never reports a change, so the revision signal is never "
        "written and no contributed pane's memo re-runs: installing the tool "
        "DOES require restarting CodeTracer, which is exactly what §8.2 says "
        "it must not",
        control_name="the comparison is written through a named binding",
        control_find="    if now != before:\n"
                     "      rec.probes[tool] = now\n"
                     "      result = true",
        control_replace="    let changed = now != before\n"
                        "    if changed:\n"
                        "      rec.probes[tool] = now\n"
                        "      result = true",
    ),
    Mutation(
        "M16", SHOST,
        "    var declared = false\n    for t in rec.contribution.reprobe:",
        "    var declared = true\n    for t in rec.contribution.reprobe:",
        V_NOTRIGGER, NIM_VM, "reprobeDependencies(TraceOpened).len == 0",
        # THE DEFAULT, NOT THE MATCH. Aimed at `t.matches(occurred)` this arm
        # was MISDIRECTED: making every trigger match reddens the re-probe case
        # first, which is a different claim. A surface that declared NO trigger
        # has no `t` to match, so the only way to reach it is the default — and
        # that is the case `a surface that declared NO trigger` names.
        "a surface that declared NO trigger is re-probed by every event, so "
        "'re-probed on a DECLARED trigger' becomes 're-probed on anything' and "
        "the declaration means nothing",
        control_name="the flag is initialised through a named binding",
        control_find="    var declared = false\n    for t in rec.contribution.reprobe:",
        control_replace="    const notDeclared = false\n"
                        "    var declared = notDeclared\n"
                        "    for t in rec.contribution.reprobe:",
    ),
    Mutation(
        "M17", DEG,
        "    pdDependencyMissing,\n    pdDivergenceDetected,",
        "    pdEngineUnavailable,\n    pdDivergenceDetected,",
        V_DEGRADED, NIM_VM, "pdDependencyMissing",
        # THE ROW IS REPLACED RATHER THAN DELETED, and the reason is that a
        # deletion does not compile: `DegradationPrecedence` is an
        # `array[7, ...]` and a six-element literal is a type error, so the arm
        # scored HARNESS-FAILURE ("the mutation never ran") rather than
        # grading anything. Overwriting it with a row that is already in the
        # array keeps the length and removes the row from the walk, which is
        # the behaviour the arm is about.
        "the row leaves the shared precedence, so `resolveDegradation` never "
        "returns it and a contributed surface with a missing tool resolves to "
        "`pdNone` — the reuse becomes a value nobody resolves",
        control_name="the precedence array is written with the row on its own line",
        control_find="    pdDependencyMissing,\n    pdDivergenceDetected,",
        control_replace="    pdDependencyMissing,\n\n    pdDivergenceDetected,",
    ),
    Mutation(
        "M18", DEG,
        "    pdEngineUnavailable,\n    pdDependencyMissing,\n  }",
        "    pdEngineUnavailable,\n  }",
        V_DEGRADED, NIM_VM, "pdDependencyMissing",
        "the contributed pane stops being SENSITIVE to the row even though the "
        "row still exists — the other half of the reuse, and the half a "
        "precedence arm cannot reach",
        control_name="the sensitivity set is written in a different member order",
        control_find="  ContributedPaneDegradations*: set[PaneDegradation] = {\n"
                     "    pdPermanentlyUnreplayable,\n"
                     "    pdReplayWindowExpired,\n"
                     "    pdEngineUnavailable,\n"
                     "    pdDependencyMissing,\n"
                     "  }",
        control_replace="  ContributedPaneDegradations*: set[PaneDegradation] = {\n"
                        "    pdDependencyMissing,\n"
                        "    pdEngineUnavailable,\n"
                        "    pdReplayWindowExpired,\n"
                        "    pdPermanentlyUnreplayable,\n"
                        "  }",
    ),
    # -- §7, fault containment ---------------------------------------------
    Mutation(
        "M19", SHOST,
        "    if rec.faults >= sh.faultLimit:",
        "    if false:",
        V_DISABLED, NIM_VM, "isPluginDisabled",
        "'Repeated faults disable the extension for the session' stops "
        "happening: a view that throws on every frame throws on every frame "
        "forever, which §7 says is worse than one that is absent",
        control_name="the limit test is written through a named binding",
        control_find="    if rec.faults >= sh.faultLimit:",
        control_replace="    let overLimit = rec.faults >= sh.faultLimit\n"
                        "    if overLimit:",
    ),
    Mutation(
        "M20", SHOST,
        "  if sh.isSurfaceDisabled(qualifiedId):",
        "  if false:",
        V_DISABLED, NIM_VM, "explodeCalls",
        "the plugin is recorded as disabled and its views are called anyway. "
        "The disabling is only real if the host STOPS ENTERING the view, and a "
        "tally that keeps moving is what says it did not.",
        control_name="the disabled test is written through a named binding",
        control_find="  if sh.isSurfaceDisabled(qualifiedId):",
        control_replace="  let off = sh.isSurfaceDisabled(qualifiedId)\n"
                        "  if off:",
    ),
    Mutation(
        "M21", SHOST,
        "    if result.isNil:",
        "    if false:",
        V_NIL, NIM_VM, "node.isNil",
        "a view returning nil produces a blank region instead of a fault — "
        "§6.1's failure by the other route, and the one a `try` cannot catch",
        control_name="the nil test is written through a named binding",
        control_find="    if result.isNil:",
        control_replace="    let empty = result.isNil\n"
                        "    if empty:",
    ),
    Mutation(
        "M22", HOST,
        "  if faulted:",
        "  if false:",
        V_ACTIVATE, NIM_VM, "activationFaults",
        "a plugin whose `activate` raised is left marked ACTIVE with nothing "
        "released and nobody told — §7's containment applied to the plugin's "
        "first line, removed",
        control_name="the fault flag is read into a named binding",
        control_find="  if faulted:",
        control_replace="  let didFault = faulted\n"
                        "  if didFault:",
    ),
    Mutation(
        "M23", API,
        "  if not ctx.manifest.declaresSurface(surfaceId):",
        "  if false:",
        V_UNDECLARED_VIEW, NIM_VM, 'not host.isActive("acme.typo")',
        "a plugin may contribute a view for a surface its manifest never "
        "declared: the view is accepted, nothing renders it, and the plugin "
        "appears to load and silently does nothing",
        control_name="the declaration test is written through a named binding",
        control_find="  if not ctx.manifest.declaresSurface(surfaceId):",
        control_replace="  let declared = ctx.manifest.declaresSurface(surfaceId)\n"
                        "  if not declared:",
    ),
    # -- §7's flag ----------------------------------------------------------
    Mutation(
        "M24", HOST,
        "  if not host.extensionsEnabled: return false",
        "  if false: return false",
        V_NOEXT, NIM_VM, "flame.activations == 0",
        "`--no-extensions` stops stopping anything: every plugin's `activate` "
        "runs on the one code path that exists because an extension has made "
        "the product unusable",
        control_name="the flag is read into a named binding",
        control_find="  if not host.extensionsEnabled: return false",
        control_replace="  let extensionsOn = host.extensionsEnabled\n"
                        "  if not extensionsOn: return false",
    ),
    Mutation(
        "M25", SHOST,
        "  if not sh.extensionsEnabled:\n"
        "    return sh.noExtensionsNode(qualifiedId)",
        "  if false:\n"
        "    return sh.noExtensionsNode(qualifiedId)",
        V_NOEXT, NIM_VM, "No extension in this session contributes",
        # THE `because` IS NOT `--no-extensions`, AND THE PRE-FLIGHT IS WHY.
        # That string occurs in the GREEN output — it is in this suite's own
        # `suite` name — so an arm carrying it would be scored `killed` for a
        # case that died anywhere at all. The needle used instead is the text
        # of the arm that takes over when the flag arm is removed, and it is
        # printed only by a failed case's checkpoint.
        "a render under the flag no longer says WHY the surface is empty, so "
        "the recovery route is indistinguishable from a broken install",
        control_name="the flag is read into a named binding",
        control_find="  if not sh.extensionsEnabled:\n"
                     "    return sh.noExtensionsNode(qualifiedId)",
        control_replace="  let extensionsOn = sh.extensionsEnabled\n"
                        "  if not extensionsOn:\n"
                        "    return sh.noExtensionsNode(qualifiedId)",
    ),
    Mutation(
        "M26", EXTSEL,
        "    if arg == ExtensionsFlag:",
        "    if false:",
        C_PRESENT, NIM_CLI, "not plan.enabled",
        "the flag is neither honoured nor removed: confutils then sees an "
        "option it does not know, so the recovery route fails as a usage error",
        control_name="the comparison is written through a named binding",
        control_find="    if arg == ExtensionsFlag:",
        control_replace="    let isFlag = arg == ExtensionsFlag\n"
                        "    if isFlag:",
    ),
    Mutation(
        "M27", EXTSEL,
        "    if arg.startsWith(ExtensionsFlag & \"=\") or\n"
        "       arg.startsWith(ExtensionsFlag & \":\"):",
        "    if false:",
        C_NOVALUE, NIM_CLI, "epkUsageError",
        "`--no-extensions=false` stops being a usage error and starts being an "
        "unrecognised token, so a user guessing at the syntax of a recovery "
        "flag silently keeps their extensions",
        control_name="the two spellings are tested in the other order",
        control_find="    if arg.startsWith(ExtensionsFlag & \"=\") or\n"
                     "       arg.startsWith(ExtensionsFlag & \":\"):",
        control_replace="    if arg.startsWith(ExtensionsFlag & \":\") or\n"
                        "       arg.startsWith(ExtensionsFlag & \"=\"):",
    ),
    Mutation(
        "M28", EXTSEL,
        "    if arg == \"--\":\n      stopped = true",
        "    if false:\n      stopped = true",
        C_DASHDASH, NIM_CLI, "plan.enabled",
        "a recorded program's own `--no-extensions` is read as CodeTracer's, "
        "so recording a program that happens to take that flag turns the "
        "debugger's extensions off",
        control_name="the separator test is written through a named binding",
        control_find="    if arg == \"--\":\n      stopped = true",
        control_replace="    let isSeparator = arg == \"--\"\n"
                        "    if isSeparator:\n      stopped = true",
    ),
    # -- §6.1 in the layout -------------------------------------------------
    Mutation(
        "M29", LAYOUT,
        "  node.contributedPane = cp",
        "  discard cp",
        V_INVISIBLE, NIM_VM, "allContributedPanes",
        "a collapse converts a contributed leaf into a BUILT-IN one — `pane` "
        "carries the enum's zero value, so the extension's pane becomes the "
        "editor. The blank-region failure in its most expensive form: the "
        "region is not blank, it is somebody else's pane.",
        control_name="the field is assigned through a second named binding",
        control_find="  node.contributedPane = cp",
        control_replace="  let contributed = cp\n"
                        "  node.contributedPane = contributed",
    ),
    Mutation(
        "M30", LAYOUT,
        "    if not node.isContributed:\n      result.add(node.pane)\n"
        "    return\n  for c in node.children:\n    result.add(allPanes(c))",
        "    result.add(node.pane)\n"
        "    return\n  for c in node.children:\n    result.add(allPanes(c))",
        V_INVISIBLE, NIM_VM, "tree.allPanes()",
        "every contributed leaf is reported as `paneEditor`, because that is "
        "`PaneKind`'s zero value. `validate` then sees a duplicate editor, "
        "`lcRemovePane(editor)` deletes an extension's pane, and a pane the "
        "shell owns is reported as placed when it is not.",
        control_name="the contributed test is written through a named binding",
        control_find="    if not node.isContributed:\n"
                     "      result.add(node.pane)\n    return",
        control_replace="    let builtin = not node.isContributed\n"
                        "    if builtin:\n      result.add(node.pane)\n    return",
    ),
    Mutation(
        "M31", LAYOUT,
        "    if node.isContributed:\n"
        "      result[\"contributedPane\"] = %node.contributedPane\n"
        "    else:\n"
        "      result[\"pane\"] = %($node.pane)",
        "    if false:\n"
        "      result[\"contributedPane\"] = %node.contributedPane\n"
        "    else:\n"
        "      result[\"pane\"] = %($node.pane)",
        V_HOSTILE, NIM_VM, "containsContributed",
        "the two namespaces share one JSON key again: a contributed pane is "
        "written as `pane: \"editor\"` (the enum's zero value) and READ BACK "
        "as the built-in editor. The structural half of the collision defence, "
        "removed.",
        control_name="the branch is written as an explicit if/else on a binding",
        control_find="    if node.isContributed:\n"
                     "      result[\"contributedPane\"] = %node.contributedPane\n"
                     "    else:\n"
                     "      result[\"pane\"] = %($node.pane)",
        control_replace="    let contributed = node.isContributed\n"
                        "    if contributed:\n"
                        "      result[\"contributedPane\"] = %node.contributedPane\n"
                        "    else:\n"
                        "      result[\"pane\"] = %($node.pane)",
    ),
    Mutation(
        "M32", LAYOUT,
        "      if problem != pipOk:\n"
        "        raiseDecode(ldeBadContributedPane, describe(problem, id))",
        "      if false:\n"
        "        raiseDecode(ldeBadContributedPane, describe(problem, id))",
        V_BADDOC, NIM_VM, "ldeBadContributedPane",
        "a malformed id in a saved layout is accepted, so a slot nothing can "
        "resolve reaches the shell — and there is no extension to name in the "
        "report, because the id cannot be attributed to one",
        control_name="the problem is compared through an explicit equality",
        control_find="      if problem != pipOk:\n"
                     "        raiseDecode(ldeBadContributedPane, describe(problem, id))",
        control_replace="      if not (problem == pipOk):\n"
                        "        raiseDecode(ldeBadContributedPane, describe(problem, id))",
    ),
    Mutation(
        "M33", LAYOUT,
        "    if hasBuiltin and hasContributed:",
        "    if false:",
        V_BOTHKEYS, NIM_VM, "ldePaneAndContributedPane",
        "a leaf claiming BOTH namespaces is decoded as whichever the reader "
        "happens to check first, so a document written by something that does "
        "not understand the format silently places a pane nobody asked for",
        control_name="the two flags are tested in the other order",
        control_find="    if hasBuiltin and hasContributed:",
        control_replace="    if hasContributed and hasBuiltin:",
    ),
    Mutation(
        "M34", LAYOUT,
        "    if paneIdProblem(cmd.addedContributedPane) != pipOk:",
        "    if false:",
        V_HOSTILE, NIM_VM, "refused.kind == loRefused",
        "the COMMAND door stops validating the id. The decoder is not the only "
        "way a third party's id reaches a layout, and an id that is refused on "
        "the way in from disk and accepted on the way in from a manifest is "
        "refused nowhere that matters.",
        control_name="the problem is compared through a named binding",
        control_find="    if paneIdProblem(cmd.addedContributedPane) != pipOk:",
        control_replace="    let idProblem = paneIdProblem(cmd.addedContributedPane)\n"
                        "    if idProblem != pipOk:",
    ),
    Mutation(
        "M35", SHOST,
        "    if choice.kind == vcNone: continue",
        "    if false: continue",
        V_OPTIONAL, NIM_VM, "surfaceIds()",
        "§6.3's 'an optional surface is simply not present' stops being true: "
        "the surface is registered on a front-end that has no view for it, so "
        "a layout offers a pane that can only ever render nothing",
        control_name="the choice is compared through a named binding",
        control_find="    if choice.kind == vcNone: continue",
        control_replace="    let noView = choice.kind == vcNone\n"
                        "    if noView: continue",
    ),
    # -- §7, the fault class the boundary used to miss ----------------------
    Mutation(
        "M36", SHOST,
        "  except Defect as d:\n"
        "    return sh.containDefect(rec, qualifiedId, d)\n",
        "",
        V_DEFECT, NIM_VM, "Unhandled exception: index out of bounds",
        # THE ARM IS THE TREE AS IT WAS. Deleting this clause restores the
        # boundary that shipped — `except CatchableError` alone — so what it
        # grades is exactly the defect that was there: an ordinary out-of-range
        # read in a plugin view is not a `CatchableError`, so it went past the
        # boundary, past the host and out of whatever was drawing the frame.
        # §7's "must not take down the debugger" did not hold for the commonest
        # Nim runtime failure.
        "§7's containment stops covering `Defect` — `IndexDefect`, "
        "`FieldDefect`, `RangeDefect` and a nil dereference — so a plugin "
        "view's out-of-range read takes the debugger down",
        control_name="the caught value is bound under a different name",
        control_find="  except Defect as d:\n"
                     "    return sh.containDefect(rec, qualifiedId, d)",
        control_replace="  except Defect as raised:\n"
                        "    return sh.containDefect(rec, qualifiedId, raised)",
    ),
    Mutation(
        "M37", SHOST,
        "  rec.defected = true\n  rec.disabled = true",
        "  rec.defected = true\n  rec.disabled = false",
        V_DEFECT, NIM_VM, "p.calls == 1",
        "the surface is RE-ARMED after a `Defect`: the view is entered again "
        "on the next frame, which is a second run over state whose invariants "
        "the language has just said do not hold. The containment survives and "
        "the policy that makes it different from the `CatchableError` path "
        "does not.",
        control_name="the disable is written through the flag just set",
        control_find="  rec.defected = true\n  rec.disabled = true",
        control_replace="  rec.defected = true\n  rec.disabled = rec.defected",
    ),
    Mutation(
        "M38", HOST,
        "      except Defect as d:\n"
        "        faulted = true\n"
        "        faultedByDefect = true\n"
        "        faultMessage = \"the Defect \" & $d.name & \": \" & d.msg\n",
        "",
        V_DEFECTBOOT, NIM_VM, "Unhandled exception: index out of bounds",
        "the SAME hole one layer up: a plugin whose `activate` reads past the "
        "end of a sequence takes the application down before any view exists "
        "to mount inside a boundary. §7 applied to the plugin's first line, "
        "missing exactly the class that matters most.",
        control_name="the caught value is bound under a different name",
        control_find="      except Defect as d:\n"
                     "        faulted = true\n"
                     "        faultedByDefect = true\n"
                     "        faultMessage = \"the Defect \" & $d.name & \": \" "
                     "& d.msg",
        control_replace="      except Defect as raised:\n"
                        "        faulted = true\n"
                        "        faultedByDefect = true\n"
                        "        faultMessage = \"the Defect \" & $raised.name "
                        "& \": \" & raised.msg",
    ),
    Mutation(
        "M39", HOST,
        "      host.defectedPlugins.incl id",
        "      discard id",
        V_DEFECTBOOT, NIM_VM, "entered == 1",
        "a plugin whose `activate` broke an invariant is RETRIED on the next "
        "declared event. The fault is contained and then walked into again, "
        "which is the re-arm §7's 'repeated faults disable the extension' "
        "exists to stop — arriving through the activation path rather than "
        "through the render path.",
        control_name="the id is recorded through a named binding",
        control_find="      host.defectedPlugins.incl id",
        control_replace="      let defected = id\n"
                        "      host.defectedPlugins.incl defected",
    ),
    # -- the absent set, and the prose pinned to it (§3.4 / §6.4) ------------
    Mutation(
        "M40", MAPPINGS,
        "    if mappingFor(fe, k).status == msAbsent: result.add k",
        "    if false: result.add k",
        P_ABSENTSET, NIM_PURE, "derived.len == 3",
        "the absent set stops being READ OUT OF the table and becomes empty, "
        "so a sentence naming three entries — or, as both of this milestone's "
        "sentences did, naming the wrong three — is no longer contradicted by "
        "anything. This arm is what makes the new case evidence rather than a "
        "restatement.",
        control_name="the status is read into a named binding",
        control_find="    if mappingFor(fe, k).status == msAbsent: result.add k",
        control_replace="    let absentHere = mappingFor(fe, k).status == "
                        "msAbsent\n"
                        "    if absentHere: result.add k",
    ),
    # -- §6.1's one namespace for rendering surfaces ------------------------
    Mutation(
        "M41", MANIFEST,
        "    if surfaceKindById.hasKey(c.id):",
        "    if false:",
        P_DUPSURFACE, NIM_PURE, "pecDuplicateContribution",
        "a pane and a marker may share a local id again. Both compose one "
        "qualified id, the registry keeps the first and drops the second, and "
        "nothing anywhere says a contribution went missing — `lpUnknownPane`'s "
        "failure arriving at load time instead of at restore time.",
        control_name="the membership test is written through a named binding",
        control_find="    if surfaceKindById.hasKey(c.id):",
        control_replace="    let taken = surfaceKindById.hasKey(c.id)\n"
                        "    if taken:",
    ),
]


# DECLARED SURVIVORS. Each is a mutation this suite CANNOT kill, with the
# reason, so the gap is a line in the transcript rather than an absence.
DECLARED_SURVIVORS: list[Mutation] = [
    Mutation(
        "M5", SURF,
        "    if mappingFor(fe, v).status == msAbsent:",
        "    if false:",
        P_ABSENT, NIM_PURE, "vaVocabularyAbsentHere",
        "UNREACHABLE, measured: since PLAT-38 gave isonim-gpui element "
        "focus, NO front-end maps any vocabulary entry to `msAbsent` "
        "(`plugin_surfaces_test` asserts `absentAnywhere == 0`), so no "
        "shipped manifest reaches this branch and disabling it changes no "
        "reachable outcome. The mapping table is a constant a suite cannot "
        "plant into. Whether a refusal nothing can provoke keeps its code "
        "path is recorded as `Extensibility-Model.md` §3.4's decision; until "
        "it is taken this arm is an equivalent mutant, declared rather than "
        "hidden. (Until 2026-09-22 it killed: `Modal` mapped `msAbsent` on "
        "GPUI.)",
        control_name="the mapping status is read into a named binding",
        control_find="    if mappingFor(fe, v).status == msAbsent:",
        control_replace="    let status = mappingFor(fe, v).status\n"
                        "    if status == msAbsent:",
    ),
    # Until 2026-09-22 this list was EMPTY — every arm above killed — and the
    # two that looked like candidates while this harness was written were
    # both killable once the case was written the other way round:
    #
    #   * "an optional surface is left out of the registry" looked
    #     unobservable, because an absent surface and an unregistered one both
    #     render nothing. It is observable through `surfaceIds()`, which is
    #     the list a layout offers a user — arm M35 grades it.
    #   * "the host stops CALLING a disabled view" looked like the same
    #     assertion as "the render is contained". It is not: the first is a
    #     tally on the plugin's own side (M20), the second is the node the
    #     host returns (M19).
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
    compile_cmd += [f"--nimcache:/tmp/plat9-mut-cache-{Path(suite.path).stem}",
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
    body = ["# Control digests for run-plat9-surface-mutations.py.",
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
