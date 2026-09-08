#!/usr/bin/env python3
"""Mutation harness for PLAT-7's plugin reactive boundary.

WHAT THIS COVERS. The boundary that makes Extensibility-Model.md §5.3's
synchronous-effect budget enforcement rather than advice: the narrowed plugin
surface (`codetracer_plugin.nim`), the wrapped reactive primitives and the
accounting guard on `plugin_api.nim`, and the import lint
(`ci/test/plugin-reactive-boundary.sh`) that refuses the module-qualified
spelling `export … except` cannot filter.

It does NOT re-run PLAT-7's original sixteen arms. That harness was never
committed to the tree, so there is nothing here to re-run; saying so is more
useful than a table that implies otherwise.

THREE VERDICTS, NOT TWO (Verification-Harness-Traps §1a). An arm that never ran
is not a kill:

  killed          the named case reported [FAILED] / FAIL
  SURVIVED        the run produced result lines and the named case was green
  HARNESS-FAILURE the mutation did not apply, did not compile, or the run
                  produced NO result lines at all

The last is the one this file exists to keep distinct: `nim c -r` exits
non-zero identically for a compile error, a failed assertion and an OOM, so an
rc-based verdict scores a mutation that never executed as a kill.

EVERY KILL ARM CARRIES A NAMED BEHAVIOUR-PRESERVING CONTROL in the same file —
a renamed local, a hoisted binding, a reordered but equivalent expression —
which is applied on its own and must leave the suite GREEN. Without it a red
arm proves only that the file was touched: a mutation that broke compilation,
or one that reddened everything because the file no longer parsed, would score
identically to a mutation that defeated exactly the rule under test.

RESTORATION IS FROM A VERIFIED SNAPSHOT, never from `git checkout --`: the
original bytes are read into memory before each edit and written back after it,
and the SHA-256 of every touched file is compared against the control hash
before the next arm starts. This repository installs a post-checkout hook that
repairs worktree hooks as a side effect, so a test run must not go through git
to restore a file.

THE CONTROL HASH IS RECORDED ON DISK, NOT TAKEN AT START-UP. That difference is
a finding rather than a refinement. A verification run was killed mid-arm, so
python never reached `finally: restore(...)` and a mutation was left in the
tree. The next run took its baseline digests FROM THAT TREE, so every restore
verified against the mutated bytes and agreed; the only symptom was the control
suite reporting `CONTROL IS NOT GREEN`, which describes a red suite and does not
name the cause. With ${CONTROL_HASHES} committed beside this file the same
condition is reported by name, before anything is mutated, pointing at the file
and offering the two ways out.

ONLY ONE INSTANCE MAY RUN IN A WORKTREE, and that is enforced with an exclusive
`flock` rather than asked for. Two ran concurrently here during the sixth
verification pass: each restores a mutated file from its OWN in-memory snapshot,
so the loser's restore writes back bytes the winner had already mutated, and
every verdict after that point grades a file nobody chose. The recorded control
digests below do not catch it — they are checked once, before the first
mutation, when both instances are looking at a clean tree. See `acquire_lock`.

`--record-control-hashes` rewrites it, and is the deliberate step that
distinguishes "I changed the gate on purpose" from "a killed run left debris".
Signals are also handled: SIGTERM and SIGHUP raise, so `finally` runs and the
file is restored, which turns most mid-flight kills into a clean exit rather
than into debris the next run has to name.

ARMS NAMING ONE CASE ARE RUN INDIVIDUALLY, so a tally cannot hide which died:
each arm's verdict names the case that reddened, and an arm that reddened a
DIFFERENT case than the one it claims is reported as MISDIRECTED rather than as
a kill.

Usage (from the repository root):
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat7-boundary-mutations.py

`-u` matters when the output is redirected: a full run is tens of minutes, and
without it python block-buffers stdout, so a log file stays EMPTY until the last
arm and there is no way to tell a slow run from a wedged one.
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

# --- the files an arm may touch -------------------------------------------

API = "src/frontend/viewmodel/plugin_host/plugin_api.nim"
SURFACE = "src/frontend/viewmodel/codetracer_plugin.nim"
GATE = "ci/test/plugin-reactive-boundary.sh"
# THE SHARED IMPORT EXTRACTOR. Both boundary gates call it, which is why arms
# G13 and G13b are the same mutation graded by two different contract suites:
# a defect in a shared predicate is a defect in every consumer of it, and a
# control on one consumer only is half a control.
LIB = "ci/lib/nim-imports.sh"

LIFECYCLE = "src/frontend/viewmodel/tests/unit/test_plugin_lifecycle.nim"
BUDGET = "src/frontend/viewmodel/tests/unit/test_plugin_effect_budget.nim"
GATE_SUITE = "ci/test/plugin-reactive-boundary-test.sh"
SDK_GATE_SUITE = "ci/test/sdk-facade-boundary-test.sh"

TOUCHED = [API, SURFACE, GATE, LIB]

# WHERE THE ABSOLUTE CONTROL HASHES LIVE. See the module docstring: a baseline
# taken at start-up cannot tell a clean tree from one a killed run left a
# mutation in, because it reads the mutation as the baseline.
CONTROL_HASHES = HERE / "plat7-boundary-mutation-control.sha256"

# WHY THERE IS A LOCK, AND WHY THE RECORDED HASHES DO NOT COVER THIS.
#
# Two instances of this harness ran concurrently in one worktree during the
# sixth verification pass. Nothing detected it, and the failure mode is worse
# than a confusing transcript: each instance snapshots a file's bytes IN MEMORY
# before it mutates, and restores from its own snapshot afterwards. So the
# loser's restore WRITES BACK BYTES THE WINNER HAD ALREADY MUTATED — the
# extractor is silently reverted to another arm's mutation mid-run, and every
# verdict after that point grades a file nobody chose.
#
# The recorded control digests do not catch this. They are checked ONCE, before
# the first mutation, and both instances pass that check because both start on a
# clean tree; the collision happens later, between two writes, where the only
# comparison is each instance's own baseline dict — which the other instance's
# write invalidated. Even the post-restore digest assertion agrees, because it
# compares against the same stale baseline.
#
# So the lock is the mechanism and the hashes are the backstop, not the other
# way round. It is an exclusive `flock` held for the whole run: an advisory lock
# on an open descriptor, released by the kernel when the process exits however it
# exits — including SIGKILL, which is the one signal `install_signal_restore`
# cannot help with. That property is why this is a `flock` and not a pid file: a
# pid file left by a killed run is indistinguishable from a live one.
LOCK_PATH = HERE / ".plat7-boundary-mutation.lock"


def acquire_lock():
    """Take the exclusive run lock, or explain who holds it and refuse.

    Returns the open file object, which must stay referenced for the lifetime
    of the run: closing it releases the lock.
    """
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
        print("  Two instances in one worktree corrupt each other's restores:")
        print("  each snapshots a file's bytes in memory before mutating and")
        print("  writes its own snapshot back afterwards, so the second one to")
        print("  finish reverts the tree to bytes the first had mutated. Wait")
        print("  for that run to finish, or kill it and re-check the tree")
        print("  against the recorded control digests before starting again.")
        return None
    fh.seek(0)
    fh.truncate()
    fh.write(f"pid {os.getpid()} on {os.uname().nodename}, cwd {ROOT}\n")
    fh.flush()
    return fh

# --- the case names, spelled once ------------------------------------------
#
# A typo here shows up as "the control did not run this case" rather than as a
# silently unkillable arm.

C_SURFACE = "a plugin cannot NAME createEffect, and can name ctx.pluginEffect"
C_ROOT_ESCAPE = "a raw createRoot detaches the root — the escape, measured"
C_ROOT_FIX = "ctx.pluginRoot releases with the scope, over the same plugin"
C_ROOT_BUDGET = "the body inside a plugin root is budgeted like any other"
C_MEMO_BUDGET = "the body inside a plugin MEMO is budgeted like any other"
C_REENTRANT = "a checkpoint still fires in an OUTER run after a nested one returns"
C_RECORDED = "pluginComputed, pluginRenderEffect and pluginOnMount are recorded"
C_ENTERED = "every wrapped body enters through the budget wrapper"
C_BATCH = "deactivation inside a batch also stops an already-queued effect"
C_RELEASE = "a deactivated plugin's effects no longer run, and its edges are gone"

G_QUALIFIED = "the MODULE-QUALIFIED call the surface cannot filter is caught"
G_IMPORT = "a plugin importing isonim/core/computation is caught"
G_PROSE = "a denied primitive named only in a DOC COMMENT is not a finding (prose has no ABI)"
G_AGREES = "a primitive in the table but NOT filtered by the surface is caught"
G_BASELINE = "the clean baseline passes every check"
G_IMPORT_CONTROL = "the import control reddens when its subject stops importing the denied modules"
G_COMPILES_CLEAN = "a plugin that only ASKS whether a primitive resolves is not a finding"
G_COMPILES_SHARED = ("a real call AFTER a compiles() on the same line is still caught "
                     "— the strip is balanced, not to end-of-line")
G_HELPER = "a plugin reaching the primitive through ONE undeclared helper module is caught"
G_TERMINAL = ("the sanctioned surface is reached and NOT walked, so its own facade "
              "import is not a finding")
G_READABLE = ("a spec that resolves to no repository file is a finding: the gate "
              "cannot bind what it cannot read")
G_HEADER_MARKER = ("a '## CT-PLUGIN:' HEADER declares a plugin outside any "
                   ".ct-plugin tree, and the rules bind it")
G_NEWLINE_HELPER = ("the helper-module exploit REACHED THROUGH a newline-continued "
                    "import is caught — the spelling the gate could not see")
G_LATER_PIECE = ("a conditional in a LATER ;-piece is examined too — the self-check "
                 "is not keyed on the first token of the line")
G_COUNTED = ("a line carrying ONE readable import and ONE lost import is refused — "
             "the self-check counts, it does not test existence")
S_NEWLINE = ("a newline-continued import does not evade the rule (138 files in "
             "this repo are written that way)")
S_LATER_PIECE = ("a conditional in a LATER ;-piece is refused too — the self-check "
                 "is not keyed on the first token of the line")
G_BLOCK_GATE = ("a BLOCK COMMENT between the ';' and the 'when' does not switch the "
                "self-check off — the gate reads the stripped line too")
G_RAW_GATE = ("a leading character literal that truncates the comment strip is "
              "still refused — the gate reads the RAW line too")
S_THREE_RENDERINGS = ("a block comment between ';' and 'when', and a leading literal "
                      "that truncates the strip, are BOTH refused — the gate reads "
                      "three renderings")
G_CONTINUATION = ("a desynchronised conditional on the CONTINUATION LINE of a "
                  "multi-line import is refused — the self-check is asked of every "
                  "line, not only of a line that starts a statement")
S_CONTINUATION = ("a desynchronised conditional on the CONTINUATION LINE of a "
                  "multi-line import is refused — the self-check is asked of every "
                  "line")
S_CRLF = ("a newline-continued import in a CRLF-terminated file is still read — a "
          "carriage return is a line terminator, not part of the keyword")


@dataclass
class Suite:
    """One runnable suite, and how to read a verdict out of it."""

    path: str
    kind: str  # "nim" or "bash"
    binary: str = ""


NIM_LIFECYCLE = Suite(LIFECYCLE, "nim", "/tmp/plat7-mut-lifecycle")
NIM_BUDGET = Suite(BUDGET, "nim", "/tmp/plat7-mut-budget")
BASH_GATE = Suite(GATE_SUITE, "bash")
BASH_SDK_GATE = Suite(SDK_GATE_SUITE, "bash")


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    suite: Suite
    why: str = ""
    # THE NAMED BEHAVIOUR-PRESERVING CONTROL, in the same file. Applied on its
    # own; the suite must stay green.
    control_name: str = ""
    control_find: str = ""
    control_replace: str = ""


MUTATIONS: list[Mutation] = [
    # -- the narrowed surface ---------------------------------------------
    Mutation(
        "N1", SURFACE,
        "export codetracer_embed except\n"
        "  createEffect, createRenderEffect, createComputed, createMemo, onMount,\n"
        "  createRoot, onCleanup, runWithOwner, getOwner, updateComputation",
        "export codetracer_embed",
        C_SURFACE, NIM_LIFECYCLE,
        "the surface stops filtering: every raw primitive is back in a plugin's scope",
        control_name="the except list is reordered, which is the same set",
        control_find="  createEffect, createRenderEffect, createComputed, createMemo, onMount,\n"
                     "  createRoot, onCleanup, runWithOwner, getOwner, updateComputation",
        control_replace="  createRoot, onCleanup, runWithOwner, getOwner, updateComputation,\n"
                        "  createEffect, createRenderEffect, createComputed, createMemo, onMount",
    ),
    # -- the createRoot escape --------------------------------------------
    Mutation(
        "N2", API,
        "    scope.cleanups.add dispose\n",
        "    (if false: scope.cleanups.add dispose)\n",
        C_ROOT_FIX, NIM_LIFECYCLE,
        "pluginRoot stops registering the root's dispose: the escape reopens",
        control_name="the dispose is hoisted into a named binding first",
        control_find="    scope.cleanups.add dispose\n",
        control_replace="    let rootDispose = dispose\n    scope.cleanups.add rootDispose\n",
    ),
    Mutation(
        "N3", API,
        "    runBudgeted(c, name, proc() = body(dispose)))",
        "    body(dispose))",
        C_ROOT_BUDGET, NIM_LIFECYCLE,
        "the root's body stops being budgeted",
        control_name="the effect name is hoisted into a named binding",
        control_find="  isonim_owner.createRoot(proc(dispose: proc()) =\n"
                     "    scope.cleanups.add dispose\n"
                     "    runBudgeted(c, name, proc() = body(dispose)))",
        control_replace="  let rootName = name\n"
                        "  isonim_owner.createRoot(proc(dispose: proc()) =\n"
                        "    scope.cleanups.add dispose\n"
                        "    runBudgeted(c, rootName, proc() = body(dispose)))",
    ),
    Mutation(
        "N6", API,
        "    runBudgeted(c, name, inner)",
        "    inner()",
        C_MEMO_BUDGET, NIM_LIFECYCLE,
        "the MEMO's body stops being budgeted. This arm is why the case beside "
        "it exists: `pluginMemo`'s docstring, §5.4's layer table and "
        "deliverable 6 all promise the memo's body is budgeted exactly as an "
        "effect's is, and until 2026-09-08 this mutation SURVIVED all 23 "
        "lifecycle cases, all 6 budget cases and the budget suite run alone. "
        "The property was true in the shipped code and nothing graded it.",
        control_name="the memo's effect name is hoisted into a named binding",
        control_find="  var latest: T\n"
                     "  let inner = proc() =\n"
                     "    latest = body()\n"
                     "  let compute = proc(): T =\n"
                     "    runBudgeted(c, name, inner)\n"
                     "    latest",
        control_replace="  var latest: T\n"
                        "  let memoName = name\n"
                        "  let inner = proc() =\n"
                        "    latest = body()\n"
                        "  let compute = proc(): T =\n"
                        "    runBudgeted(c, memoName, inner)\n"
                        "    latest",
    ),
    # -- the re-entrant wrapper -------------------------------------------
    Mutation(
        "N4", API,
        "    st.inRun = prevInRun\n    st.runStarted = prevStarted\n"
        "    st.runEffect = prevEffect",
        "    st.inRun = false\n    st.runStarted = prevStarted\n"
        "    st.runEffect = prevEffect",
        C_REENTRANT, NIM_LIFECYCLE,
        "the pre-fix non-re-entrant wrapper: a nested run silently disarms the "
        "outer run's checkpoints",
        control_name="the three restores are reordered, which is the same assignment set",
        control_find="    st.inRun = prevInRun\n    st.runStarted = prevStarted\n"
                     "    st.runEffect = prevEffect",
        control_replace="    st.runEffect = prevEffect\n    st.runStarted = prevStarted\n"
                        "    st.inRun = prevInRun",
    ),
    # -- the accounting guard (the silent skip) ----------------------------
    Mutation(
        "N5", API,
        "  ctx.state.effects.add owner.owned[^1]\n",
        "  discard owner.owned[^1]\n",
        C_RECORDED, NIM_LIFECYCLE,
        "the record is dropped entirely — this is what the pre-fix `if` did "
        "SILENTLY whenever its condition was false",
        control_name="the recorded computation is hoisted into a named binding",
        control_find="  ctx.state.effects.add owner.owned[^1]\n",
        control_replace="  let created = owner.owned[^1]\n  ctx.state.effects.add created\n",
    ),
    Mutation(
        "N5b", API,
        "  ctx.state.effects.add owner.owned[^1]\n",
        "  discard owner.owned[^1]\n",
        C_BATCH, NIM_LIFECYCLE,
        "THE SAME MUTATION, NAMING THE OTHER CASE. A dropped record cannot "
        "break the release — that is cleanNode(scope) — but it drops the "
        "csClean sweep, so an already-queued effect survives its plugin's "
        "deactivation. That is what the silent skip cost, and it is why the "
        "else is now a raise.",
        control_name="the recorded computation is hoisted into a named binding",
        control_find="  ctx.state.effects.add owner.owned[^1]\n",
        control_replace="  let created = owner.owned[^1]\n  ctx.state.effects.add created\n",
    ),
    Mutation(
        "N7", API,
        "  isonim_computation.createEffect(proc() = runBudgeted(c, name, body))\n"
        "  recordCreated(ctx, owner, before, \"an effect\", name)",
        "  isonim_computation.createEffect(proc() = runBudgeted(c, name, body))\n"
        "  isonim_computation.createEffect(proc() = discard)\n"
        "  recordCreated(ctx, owner, before, \"an effect\", name)",
        C_RELEASE, NIM_LIFECYCLE,
        "two computations where the host expected one. THE GUARD FIRES: a "
        "PluginAccountingError is raised and named. Under the pre-fix silent "
        "skip the same mutation recorded nothing and said nothing.",
        control_name="the effect body is hoisted into a named closure",
        control_find="  isonim_computation.createEffect(proc() = runBudgeted(c, name, body))\n"
                     "  recordCreated(ctx, owner, before, \"an effect\", name)",
        control_replace="  let wrapped = proc() = runBudgeted(c, name, body)\n"
                        "  isonim_computation.createEffect(wrapped)\n"
                        "  recordCreated(ctx, owner, before, \"an effect\", name)",
    ),
    # -- the budget wrapper still refuses a suspended plugin ---------------
    Mutation(
        "N8", API,
        "  if ctx.state.suspended:\n    inc ctx.state.refusedRuns\n    return",
        "  if false:\n    inc ctx.state.refusedRuns\n    return",
        "after the trip the body is refused, and a quiet plugin keeps observing",
        NIM_BUDGET,
        "the wrapper stops refusing a suspended plugin (PLAT-7's A8, re-run "
        "here because the wrapper was edited)",
        control_name="the suspension test is written through a named binding",
        control_find="  if ctx.state.suspended:\n    inc ctx.state.refusedRuns\n    return",
        control_replace="  let isSuspended = ctx.state.suspended\n"
                        "  if isSuspended:\n    inc ctx.state.refusedRuns\n    return",
    ),
    Mutation(
        "N9", API,
        "  if ctx.isNil or ctx.state.isNil or not ctx.state.inRun: return\n"
        "  inc ctx.state.checkpoints\n"
        "  let elapsed = getMonoTime() - ctx.state.runStarted\n"
        "  if elapsed > ctx.state.budget:",
        "  if ctx.isNil or ctx.state.isNil or not ctx.state.inRun: return\n"
        "  inc ctx.state.checkpoints\n"
        "  let elapsed = getMonoTime() - ctx.state.runStarted\n"
        "  if false:",
        "a plugin that observes is stopped INSIDE its first overrun",
        NIM_BUDGET,
        "the deadline checkpoint never raises (PLAT-7's A9)",
        control_name="the elapsed comparison is written the other way round",
        control_find="  if elapsed > ctx.state.budget:",
        control_replace="  if ctx.state.budget < elapsed:",
    ),
    # -- the gate ----------------------------------------------------------
    Mutation(
        "G1", GATE,
        '\t\tif [ "${norm}" = "${denied}" ] || [ "${norm%/"${denied}"}" != "${norm}" ]; then',
        '\t\tif false; then',
        G_IMPORT, BASH_GATE,
        "the import predicate matches nothing — and it reddens its OWN control "
        "too, which is the property that makes check 1's clean result mean "
        "something",
        control_name="the two match arms are swapped, which is the same disjunction",
        control_find='\t\tif [ "${norm}" = "${denied}" ] || [ "${norm%/"${denied}"}" != "${norm}" ]; then',
        control_replace='\t\tif [ "${norm%/"${denied}"}" != "${norm}" ] || [ "${norm}" = "${denied}" ]; then',
    ),
    Mutation(
        "G2", GATE,
        "\tprintf '(^|[^[:alnum:]_])%s([^[:alnum:]_]|$)' \"$1\"",
        "\tprintf '^%s([^[:alnum:]_]|$)' \"$1\"",
        G_QUALIFIED, BASH_GATE,
        "the leading boundary is anchored, so `computation.createEffect(` no "
        "longer matches — exactly the spelling `export … except` cannot filter "
        "and this gate is the sole defence against. "
        "RETARGETED 2026-09-08: this pattern used to be written out FIVE times "
        "— once in `denied_names_in` and four more inline in checks 8 and 10 — "
        "so an arm quoting one copy left the other four agreeing with each "
        "other while the rule was broken. It is now `identifier_pattern`, one "
        "function, and this single edit reddens the rule AND every control "
        "over it at once, which is what makes each of them evidence about the "
        "other (Verification-Harness-Traps §14).",
        control_name="the alternation's branches are swapped, which is the same class",
        control_find="\tprintf '(^|[^[:alnum:]_])%s([^[:alnum:]_]|$)' \"$1\"",
        control_replace="\tprintf '([^[:alnum:]_]|^)%s($|[^[:alnum:]_])' \"$1\"",
    ),
    Mutation(
        "G3", GATE,
        "\tsed -e 's/#\\[.*\\]#//g' -e 's/[[:space:]]*##\\?.*$//' \"$1\" 2>/dev/null",
        "\tcat \"$1\" 2>/dev/null",
        G_PROSE, BASH_GATE,
        "the comment stripper stops stripping: every plugin whose header "
        "explains the rule becomes a finding",
        control_name="the two sed expressions are given as one -e",
        control_find="\tsed -e 's/#\\[.*\\]#//g' -e 's/[[:space:]]*##\\?.*$//' \"$1\" 2>/dev/null",
        control_replace="\tsed -e 's/#\\[.*\\]#//g; s/[[:space:]]*##\\?.*$//' \"$1\" 2>/dev/null",
    ),
    Mutation(
        "G4", GATE,
        '\t\t\t\tgrep -E "^${d}/" "${list}" || true',
        '\t\t\t\ttrue',
        G_BASELINE, BASH_GATE,
        "the `.ct-plugin` directory marker stops enrolling its tree; the "
        "vacuity floor is what notices, which is why check 0 exists",
        control_name="the prefix match is written with an explicit anchor variable",
        control_find='\t\t\t\tgrep -E "^${d}/" "${list}" || true',
        control_replace='\t\t\t\tgrep -E "^$(printf %s "${d}")/" "${list}" || true',
    ),
    Mutation(
        "G5", GATE,
        '\tif [ -n "${only_const}" ] || [ -n "${only_surface}" ]; then',
        '\tif false; then',
        G_AGREES, BASH_GATE,
        "the drift check between the primitives table and the surface's except "
        "clause always passes",
        control_name="the two emptiness tests are swapped",
        control_find='\tif [ -n "${only_const}" ] || [ -n "${only_surface}" ]; then',
        control_replace='\tif [ -n "${only_surface}" ] || [ -n "${only_const}" ]; then',
    ),
    Mutation(
        "G6", GATE,
        '\tif [ "${control_import_n}" -eq "${CONTROL_IMPORT_EXPECTED}" ]; then',
        '\tif [ "${control_import_n}" -ge 0 ]; then',
        G_IMPORT_CONTROL, BASH_GATE,
        "the gate's OWN control is weakened from an exact count to a "
        "tautology — Verification-Harness-Traps §4b, where 'at least one' is "
        "satisfied by one member of two",
        control_name="the count comparison is written with the operands swapped",
        control_find='\tif [ "${control_import_n}" -eq "${CONTROL_IMPORT_EXPECTED}" ]; then',
        control_replace='\tif [ "${CONTROL_IMPORT_EXPECTED}" -eq "${control_import_n}" ]; then',
    ),
    Mutation(
        "G7", GATE,
        '\tbody="$(code_lines "${file}" | strip_compiles)"',
        '\tbody="$(code_lines "${file}")"',
        G_COMPILES_CLEAN, BASH_GATE,
        "the compiles() exemption is removed: the fixture that ASSERTS the "
        "denial becomes a finding, and the gate reddens on its own evidence",
        control_name="the pipeline is written with an explicit intermediate",
        control_find='\tbody="$(code_lines "${file}" | strip_compiles)"',
        control_replace='\tlocal raw\n\traw="$(code_lines "${file}")"\n'
                        '\tbody="$(strip_compiles <<<"${raw}")"',
    ),
    Mutation(
        "G8", GATE,
        "\t\t\tif (substr(line, i, 9) == \"compiles(\") {\n"
        "\t\t\t\tdepth = 1\n"
        "\t\t\t\ti += 9\n"
        "\t\t\t\twhile (i <= n && depth > 0) {\n"
        "\t\t\t\t\tc = substr(line, i, 1)\n"
        "\t\t\t\t\tif (c == \"(\") depth++\n"
        "\t\t\t\t\telse if (c == \")\") depth--\n"
        "\t\t\t\t\ti++\n"
        "\t\t\t\t}\n"
        "\t\t\t\tcontinue\n"
        "\t\t\t}",
        "\t\t\tif (substr(line, i, 9) == \"compiles(\") {\n"
        "\t\t\t\ti = n + 1\n"
        "\t\t\t\tcontinue\n"
        "\t\t\t}",
        G_COMPILES_SHARED, BASH_GATE,
        "the compiles() strip cuts to end-of-line instead of matching parens, "
        "so a real call sharing a line with a compiles() goes with it — a "
        "silent MISS, which is the one outcome a boundary lint may not produce",
        control_name="the depth test is written as an if/else-if chain in the other order",
        control_find="\t\t\t\t\tif (c == \"(\") depth++\n"
                     "\t\t\t\t\telse if (c == \")\") depth--",
        control_replace="\t\t\t\t\tif (c == \")\") depth--\n"
                        "\t\t\t\t\telse if (c == \"(\") depth++",
    ),
    # -- the closure walk --------------------------------------------------
    Mutation(
        "G9", GATE,
        "\t\t\tif [ -z \"${seen[${resolved}]+x}\" ]; then\n"
        "\t\t\t\tseen[\"${resolved}\"]=1\n"
        "\t\t\t\tqueue+=(\"${resolved}\")\n"
        "\t\t\tfi",
        "\t\t\tif false; then\n"
        "\t\t\t\tseen[\"${resolved}\"]=1\n"
        "\t\t\t\tqueue+=(\"${resolved}\")\n"
        "\t\t\tfi",
        G_HELPER, BASH_GATE,
        "the closure walk never enqueues anything, so it returns its seeds and "
        "checks 1 and 2 collapse back to the FILE-SCOPED rules one undeclared "
        "helper module defeated — measured at rawRuns=4, budgeted runs=0, with "
        "the gate reporting 12 checks and 0 failing",
        control_name="the seen-mark and the enqueue are written in the other order",
        control_find="\t\t\t\tseen[\"${resolved}\"]=1\n"
                     "\t\t\t\tqueue+=(\"${resolved}\")",
        control_replace="\t\t\t\tqueue+=(\"${resolved}\")\n"
                        "\t\t\t\tseen[\"${resolved}\"]=1",
    ),
    Mutation(
        "G10", GATE,
        "\t\t[ \"${resolved}\" = \"${terminal}\" ] && continue",
        "\t\t[ \"${resolved}\" = \"\" ] && continue",
        G_TERMINAL, BASH_GATE,
        "the sanctioned surface stops being a terminal, so the walk enters it, "
        "finds its `import codetracer_embed` — a DENIED import — and reports "
        "every plugin in the tree for consuming the surface correctly. The "
        "terminal is load-bearing in the other direction too, which is why it "
        "is a parameter of the walk rather than a filter applied afterwards.",
        control_name="the terminal comparison is written with the operands swapped",
        control_find="\t\t[ \"${resolved}\" = \"${terminal}\" ] && continue",
        control_replace="\t\t[ \"${terminal}\" = \"${resolved}\" ] && continue",
    ),
    Mutation(
        "G11", GATE,
        "\tcase \"$1\" in\n\tstd/* | system) return 0 ;;\n\tesac\n\treturn 1",
        "\tcase \"$1\" in\n\t*) return 0 ;;\n\tesac\n\treturn 1",
        G_READABLE, BASH_GATE,
        "every unresolvable spec is admitted as standard library, so the "
        "closure's boundary stops being stated: a module the gate never read "
        "is scored identically to one it read and found clean",
        control_name="the two admitted patterns are written in the other order",
        control_find="\tstd/* | system) return 0 ;;",
        control_replace="\tsystem | std/*) return 0 ;;",
    ),
    # -- how a plugin is DECLARED -----------------------------------------
    Mutation(
        "G12", GATE,
        '\t\t\t\tif head -n "${MARKER_SCAN_LINES}" "${f}" 2>/dev/null |',
        '\t\t\t\tif head -n 0 "${f}" 2>/dev/null |',
        G_HEADER_MARKER, BASH_GATE,
        "the `## CT-PLUGIN:` HEADER declaration path is disabled outright. "
        "Until 2026-09-08 this exact edit left the gate at 15/0 and its "
        "contract suite at 48/0: the spelling appeared zero times in the suite, "
        "no file in the tree used it, and no arm targeted it — a declaration "
        "mechanism that was documented, implemented, and measured by nothing. "
        "It was kept rather than deleted because the sibling gate's identical "
        "`## SDK-CONSUMER:` carries 11 real files and the argument for two "
        "spellings here is that they are the SAME two.",
        control_name="the line bound is written as an arithmetic expansion of the same constant",
        control_find='\t\t\t\tif head -n "${MARKER_SCAN_LINES}" "${f}" 2>/dev/null |',
        control_replace='\t\t\t\tif head -n "$((MARKER_SCAN_LINES))" "${f}" 2>/dev/null |',
    ),
    # -- the SHARED import extractor ---------------------------------------
    #
    # THE DEFECT THIS CAMPAIGN ACTUALLY SHIPPED, as an arm. The plugin gate had
    # its own `import_specs`, re-derived from the same examples, whose keyword
    # test required whitespace after the keyword. Measured on the real
    # repository, the helper-module exploit twice, everything else identical:
    #
    #     import ../../../raw_helper_probe       -> 15 check(s), 3 failing
    #     import <newline>   ../../../raw_helper -> 15 check(s), 0 failing
    #
    # with `rawRuns=6 runs=0 violations=0 suspended=false` in both. The two
    # arms below are ONE edit to ONE function, graded by TWO contract suites,
    # because that is the property being claimed: the extractor is shared, so
    # breaking it breaks both gates rather than only the one whose suite is
    # nearest to hand.
    Mutation(
        "G13", LIB,
        "\t\tif (frag == \"import\" || frag == \"include\" || frag == \"from\") return 1\n",
        "",
        G_NEWLINE_HELPER, BASH_GATE,
        "the continuation branch is removed, so a bare `import` on its own line "
        "starts nothing and nim's newline-continued form is invisible again — "
        "the exact shape the re-derived extractor had, and the exploit walks "
        "straight through. "
        "RETARGETED 2026-09-08 onto `opens_import`: the test used to be written "
        "inline in `handle_stmt`, and the self-check `imports_unread` beside it "
        "needed to ask the same question about the same piece. Two spellings "
        "would have been a second copy of a predicate — the shape "
        "Verification-Harness-Traps §14 is about — so it is one function, and "
        "this single edit now moves BOTH the extraction and the self-check over "
        "it.",
        control_name="the exact-keyword arm is tested before the prefix arm, which is the same set",
        control_find="\t\tif (frag ~ /^(import|from|include)[ \\t]/) return 1\n"
                     "\t\tif (frag == \"import\" || frag == \"include\" || frag == \"from\") return 1\n",
        control_replace="\t\tif (frag == \"import\" || frag == \"include\" || frag == \"from\") return 1\n"
                        "\t\tif (frag ~ /^(import|from|include)[ \\t]/) return 1\n",
    ),
    Mutation(
        "G13b", LIB,
        "\t\tif (frag == \"import\" || frag == \"include\" || frag == \"from\") return 1\n",
        "",
        S_NEWLINE, BASH_SDK_GATE,
        "THE SAME MUTATION, GRADED BY THE OTHER CONSUMER. `sdk-facade-boundary."
        "sh` reads this function too, and until 2026-09-08 its contract suite "
        "had no case for the form — so the extractor handled it and nothing "
        "distinguished that from nobody having tried. A shared predicate with a "
        "control on one consumer only is half a control.",
        control_name="the exact-keyword arm is tested before the prefix arm, which is the same set",
        control_find="\t\tif (frag ~ /^(import|from|include)[ \\t]/) return 1\n"
                     "\t\tif (frag == \"import\" || frag == \"include\" || frag == \"from\") return 1\n",
        control_replace="\t\tif (frag == \"import\" || frag == \"include\" || frag == \"from\") return 1\n"
                        "\t\tif (frag ~ /^(import|from|include)[ \\t]/) return 1\n",
    ),
    # -- the extractor's SELF-CHECK, which had two routes past it -----------
    #
    # `imports_unread` is what turns "this scan read nothing out of a line that
    # plainly has an import on it" into a refusal, and on 2026-09-08 a fourth
    # verification pass measured two ways around it on the real gate, the real
    # fixture and a real helper module:
    #
    #   discard 1; when <hash> == <hash>: import <helper>          15 checks, 0 failing
    #   import <surface>; when <hash> == <hash>: import <helper>   15 checks, 0 failing
    #   control: import <helper>                                   15 checks, 2 failing
    #
    # Both compile on nim 2.2.8 and both import usably; both printed
    # `0 reached by import` with `closure-is-readable` reporting OK, which is
    # the fingerprint of a gate that did not report having failed to read
    # something. The two arms below put the two weaknesses back one at a time,
    # so neither is evidence for the other.
    #
    # G14 AND G14b WERE RETARGETED ON 2026-09-08, onto `conditional_here`. The
    # later-piece test used to be written inline in the gate; the fifth
    # verification pass had to ask it of THREE renderings of the line, and
    # writing it out three times would have been three copies of one predicate
    # — the shape Verification-Harness-Traps §14 is about, in the file whose
    # header is about it. It is one function now, so this single edit moves the
    # test over all three renderings at once.
    Mutation(
        "G14", LIB,
        "\t\treturn (s ~ /;[ \\t]*(when|elif)[ \\t(]/ || s ~ /;[ \\t]*else[ \\t]*:/)\n",
        "\t\treturn 0\n",
        G_LATER_PIECE, BASH_GATE,
        "the self-check is keyed on the FIRST TOKEN of the line again, so a "
        "conditional in a later `;`-piece is never examined — gap 1 of the two "
        "the fourth verification pass measured",
        control_name="the two later-piece tests are written in the other order",
        control_find="\t\treturn (s ~ /;[ \\t]*(when|elif)[ \\t(]/ || s ~ /;[ \\t]*else[ \\t]*:/)\n",
        control_replace="\t\treturn (s ~ /;[ \\t]*else[ \\t]*:/ || s ~ /;[ \\t]*(when|elif)[ \\t(]/)\n",
    ),
    Mutation(
        "G14b", LIB,
        "\t\treturn (s ~ /;[ \\t]*(when|elif)[ \\t(]/ || s ~ /;[ \\t]*else[ \\t]*:/)\n",
        "\t\treturn 0\n",
        S_LATER_PIECE, BASH_SDK_GATE,
        "THE SAME MUTATION, GRADED BY THE OTHER CONSUMER, for the reason G13b "
        "exists: the self-check lives in the shared extractor, so a control on "
        "one gate only is half a control.",
        control_name="the two later-piece tests are written in the other order",
        control_find="\t\treturn (s ~ /;[ \\t]*(when|elif)[ \\t(]/ || s ~ /;[ \\t]*else[ \\t]*:/)\n",
        control_replace="\t\treturn (s ~ /;[ \\t]*else[ \\t]*:/ || s ~ /;[ \\t]*(when|elif)[ \\t(]/)\n",
    ),
    Mutation(
        "G15", LIB,
        "\t\treturn read < wanted",
        "\t\treturn read == 0",
        G_COUNTED, BASH_GATE,
        "the self-check goes back to testing EXISTENCE instead of comparing "
        "counts, so a line carrying one readable import beside one lost import "
        "clears on the strength of the readable one — gap 2. It is a separate "
        "arm from G14 because gap 2 was only ever reachable THROUGH gap 1 (a "
        "`when`-first spelling of it does not compile), so one arm covering "
        "both would have proved neither.",
        control_name="the count comparison is written with the operands swapped",
        control_find="\t\treturn read < wanted",
        control_replace="\t\treturn wanted > read",
    ),
    # -- the GATE on that self-check, which had a route of its own ----------
    #
    # G14 and G15 put back the two weaknesses IN the self-check. Neither
    # touched the gate that decides whether the self-check runs at all, and on
    # 2026-09-08 a fifth verification pass measured a sixth route past this
    # boundary through exactly that gate. It was a plain regex over the RAW
    # line requiring only whitespace between the `;` and the `when`, and a
    # BLOCK COMMENT is legal there:
    #
    #   discard 1; when <hash> == <hash>: import <helper>          REFUSED
    #   discard 1; #[c]# when <hash> == <hash>: import <helper>    read, ZERO specs
    #   discard 1; #[c]# when <dquote> != <x>: import <helper>     read, ZERO specs
    #
    # All three compile on nim 2.2.8 and import usably. `strip_comment` removes
    # the block comment, so the shape is present in the STRIPPED text and
    # absent from the RAW text — and the character-literal desync then hid the
    # import, leaving `15 checks, 0 failing` with `closure-is-readable` OK.
    #
    # G16 IS THAT DEFECT AND G17 IS THE OBVIOUS REPAIR FOR IT, because the
    # obvious repair is a TRADE: reading the stripped line INSTEAD of the raw
    # one catches those two and reopens
    # `discard <hash-literal>; when <hash> == <hash>: import <helper>`, where
    # the comment strip cuts at the `#` inside the leading literal and the
    # stripped line carries neither a `;` nor a `when`. The two renderings
    # resolve a `#` in OPPOSITE directions, so the gate asks both — plus a
    # third, quote-blind and block-comments-only. Each arm removes exactly one
    # rendering, so neither is evidence for the other.
    Mutation(
        "G16", LIB,
        "\t\tif (!conditional_here(raw) && !conditional_here(line) &&\n"
        "\t\t    !conditional_here(strip_block_comments_blind(raw)))\n"
        "\t\t\treturn 0",
        "\t\tif (!conditional_here(raw))\n"
        "\t\t\treturn 0",
        G_BLOCK_GATE, BASH_GATE,
        "the gate reads the RAW line only — the shipped defect. A block comment "
        "between the `;` and the `when` is invisible to it, so the self-check "
        "never runs and the import is lost in silence.",
        control_name="the three renderings are tested in a different order, which is the same conjunction",
        control_find="\t\tif (!conditional_here(raw) && !conditional_here(line) &&\n"
                     "\t\t    !conditional_here(strip_block_comments_blind(raw)))\n",
        control_replace="\t\tif (!conditional_here(line) && !conditional_here(strip_block_comments_blind(raw)) &&\n"
                        "\t\t    !conditional_here(raw))\n",
    ),
    Mutation(
        "G16b", LIB,
        "\t\tif (!conditional_here(raw) && !conditional_here(line) &&\n"
        "\t\t    !conditional_here(strip_block_comments_blind(raw)))\n"
        "\t\t\treturn 0",
        "\t\tif (!conditional_here(raw))\n"
        "\t\t\treturn 0",
        S_THREE_RENDERINGS, BASH_SDK_GATE,
        "THE SAME MUTATION, GRADED BY THE OTHER CONSUMER, for the reason G13b "
        "and G14b exist: the gate lives in the shared extractor.",
        control_name="the three renderings are tested in a different order, which is the same conjunction",
        control_find="\t\tif (!conditional_here(raw) && !conditional_here(line) &&\n"
                     "\t\t    !conditional_here(strip_block_comments_blind(raw)))\n",
        control_replace="\t\tif (!conditional_here(line) && !conditional_here(strip_block_comments_blind(raw)) &&\n"
                        "\t\t    !conditional_here(raw))\n",
    ),
    Mutation(
        "G17", LIB,
        "\t\tif (!conditional_here(raw) && !conditional_here(line) &&\n"
        "\t\t    !conditional_here(strip_block_comments_blind(raw)))\n"
        "\t\t\treturn 0",
        "\t\tif (!conditional_here(line))\n"
        "\t\t\treturn 0",
        G_RAW_GATE, BASH_GATE,
        "the gate reads the COMMENT-STRIPPED line only — the one-line repair "
        "that looks right and is a trade. It closes the block-comment route "
        "G16 opens and reopens the leading-character-literal one, which the "
        "raw gate had caught since the self-check was written. This arm is why "
        "the gate is a disjunction rather than a substitution: without it, "
        "nothing in the tree would have said that the cheaper fix costs "
        "something.",
        control_name="the three renderings are tested in a different order, which is the same conjunction",
        control_find="\t\tif (!conditional_here(raw) && !conditional_here(line) &&\n"
                     "\t\t    !conditional_here(strip_block_comments_blind(raw)))\n",
        control_replace="\t\tif (!conditional_here(line) && !conditional_here(strip_block_comments_blind(raw)) &&\n"
                        "\t\t    !conditional_here(raw))\n",
    ),
    # -- the CALL SITE of that self-check, which had a route of its own ------
    #
    # G14/G15 put back the weaknesses IN the self-check; G16/G17 put back the
    # weaknesses in its GATE. NONE of the five passes that wrote them touched
    # how `imports_unread` is INVOKED, and on 2026-09-08 a sixth verification
    # pass measured a seventh route past this boundary through exactly that.
    # The call site read `collecting == 0 && imports_unread($0, line)`, so on a
    # CONTINUATION LINE of a multi-line import the self-check did not run:
    #
    #   import <surface>; when <hash> == <hash>: import <helper>     REFUSED
    #   import ⏎ <surface>; when <hash> == <hash>: import <helper>   read, ZERO specs
    #   from   ⏎ <surface> import h; when <hash> == <hash>: import … read, ZERO specs
    #
    # All three compile on nim 2.2.8 and import usably. THE DISTINGUISHING FACT
    # is that no rendering is desynchronised — all three see the conditional —
    # so this is outside both documented residual shapes rather than an instance
    # of either, and it is cheaper than the survivor they name: one ordinary
    # multi-line import plus one character literal.
    Mutation(
        "G18", LIB,
        "\t\tif (imports_unread($0, line)) {\n",
        "\t\tif (collecting == 0 && imports_unread($0, line)) {\n",
        G_CONTINUATION, BASH_GATE,
        "the call site is gated on `collecting == 0` again — the shipped "
        "defect. A multi-line import leaves `collecting == 1`, so a "
        "desynchronised conditional riding on its continuation line is never "
        "gated, never counted and never refused.",
        control_name="the verdict is compared to zero explicitly and the two state resets are written in the other order",
        control_find="\t\tif (imports_unread($0, line)) {\n"
                     "\t\t\tprint FILENAME \"\\t\" trim($0) >> unan\n"
                     "\t\t\tcollecting = 0; buf = \"\"\n",
        control_replace="\t\tif (imports_unread($0, line) != 0) {\n"
                        "\t\t\tprint FILENAME \"\\t\" trim($0) >> unan\n"
                        "\t\t\tbuf = \"\"; collecting = 0\n",
    ),
    Mutation(
        "G18b", LIB,
        "\t\tif (imports_unread($0, line)) {\n",
        "\t\tif (collecting == 0 && imports_unread($0, line)) {\n",
        S_CONTINUATION, BASH_SDK_GATE,
        "THE SAME MUTATION, GRADED BY THE OTHER CONSUMER, for the reason G13b, "
        "G14b and G16b exist: the call site lives in the shared extractor, so a "
        "control on one gate only is half a control.",
        control_name="the verdict is compared to zero explicitly and the two state resets are written in the other order",
        control_find="\t\tif (imports_unread($0, line)) {\n"
                     "\t\t\tprint FILENAME \"\\t\" trim($0) >> unan\n"
                     "\t\t\tcollecting = 0; buf = \"\"\n",
        control_replace="\t\tif (imports_unread($0, line) != 0) {\n"
                        "\t\t\tprint FILENAME \"\\t\" trim($0) >> unan\n"
                        "\t\t\tbuf = \"\"; collecting = 0\n",
    ),
    # -- the OTHER call-site defect the same attack found --------------------
    #
    # `trim` removes spaces and tabs and not a carriage return, so on a
    # CRLF-terminated file a bare `import` line is the string `import\r`:
    # `opens_import` does not recognise it and `imports_unread`'s `wanted` does
    # not count it, so the module list beneath it is lost in SILENCE. It is
    # stripped rather than refused because a CR is a line terminator, and the
    # fix is free — zero of the 1180 tracked and untracked `.nim` files in this
    # repository carry CR line endings.
    Mutation(
        "G19", LIB,
        "\t\tsub(/\\r$/, \"\", $0)\n",
        "",
        S_CRLF, BASH_SDK_GATE,
        "the carriage return survives into the keyword test, so a CRLF file's "
        "newline-continued import opens no statement and is neither read nor "
        "refused",
        control_name="the strip is guarded by a redundant test for the CR it removes",
        control_find="\t\tsub(/\\r$/, \"\", $0)\n",
        control_replace="\t\tif ($0 ~ /\\r$/) sub(/\\r$/, \"\", $0)\n",
    ),
]

# Arms expected NOT to be killed. Empty, and stated so rather than omitted: a
# survivor list that quietly grows is how an arm stops meaning anything.
DECLARED_SURVIVORS: list[Mutation] = []


NIM_RESULT = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")
BASH_RESULT = re.compile(r"^\s{2}(ok|FAIL)\s+(.*?)\s*$")


@dataclass
class RunResult:
    rc: int = 0
    ran: bool = True
    passed: list[str] = field(default_factory=list)
    failed: list[str] = field(default_factory=list)

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def run_suite(suite: Suite, label: str) -> RunResult:
    """Run one suite and parse its verdict out of its RESULT LINES.

    Never out of the exit status: `nim c -r` returns the same non-zero code for
    a compile error, a failed assertion and an OOM, and the gate's contract
    suite exits 1 for a finding and 2 for "could not run".
    """
    res = RunResult()
    if suite.kind == "nim":
        # Compile and run as TWO steps, so "did not compile" is distinguishable
        # from "ran and failed" — and `-f` so a cached object file from an
        # unmutated tree cannot be what gets graded.
        compile_proc = subprocess.run(
            ["nim", "c", "-f", "--hints:off", "--warnings:off",
             "--path:src/frontend/viewmodel",
             f"--nimcache:/tmp/plat7-mut-cache-{label}",
             f"-o:{suite.binary}", suite.path],
            cwd=ROOT, capture_output=True, text=True, timeout=3600,
        )
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
        proc = subprocess.run(["bash", suite.path], cwd=ROOT,
                              capture_output=True, text=True, timeout=3600)
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
    """The recorded control digests, keyed by repo-relative path."""
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


def write_control_hashes() -> None:
    body = ["# Control digests for run-plat7-boundary-mutations.py.",
            "#",
            "# ABSOLUTE, and that is the point. A baseline taken at start-up",
            "# cannot tell a clean tree from one a killed run left a mutation",
            "# in: it reads the mutation as the baseline, every restore then",
            "# verifies against the mutated bytes, and the only symptom is",
            "# `CONTROL IS NOT GREEN` — which describes a red suite without",
            "# naming the cause.",
            "#",
            "# Rewrite with --record-control-hashes, deliberately, when a gate",
            "# or the API changes on purpose.",
            ""]
    for p in TOUCHED:
        body.append(f"{digest(p)}  {p}")
    CONTROL_HASHES.write_text("\n".join(body) + "\n")


def check_control_hashes() -> int:
    """0 when the tree is at its recorded control bytes; 2 otherwise."""
    recorded = read_control_hashes()
    if not recorded:
        print(f"NO CONTROL HASHES: {CONTROL_HASHES.relative_to(ROOT)} is missing.")
        print("  Every restore below would verify against digests taken from")
        print("  THIS tree, so a mutation a killed run left behind would be")
        print("  adopted as the baseline. Record them from a tree you have")
        print("  checked, with --record-control-hashes.")
        return 2
    drifted = [p for p in TOUCHED if recorded.get(p) != digest(p)]
    missing = [p for p in TOUCHED if p not in recorded]
    if missing:
        print(f"CONTROL HASHES INCOMPLETE: no entry for {missing}")
        print("  Re-record with --record-control-hashes.")
        return 2
    if drifted:
        print("TREE IS NOT AT THE CONTROL BYTES — nothing was mutated.")
        for p in drifted:
            print(f"  {p}")
            print(f"      recorded {recorded[p]}")
            print(f"      on disk  {digest(p)}")
        print("  Either a previous run was killed mid-arm and left a mutation")
        print("  in the tree — restore it and re-run — or the file changed on")
        print("  purpose, in which case re-record with --record-control-hashes.")
        print("  This is the condition that previously surfaced only as")
        print("  'CONTROL IS NOT GREEN', which names a red suite rather than")
        print("  the debris that reddened it.")
        return 2
    return 0


def install_signal_restore() -> None:
    """Make SIGTERM/SIGHUP raise, so `finally: restore(...)` still runs.

    A killed run is how a mutation gets left in the tree in the first place.
    SIGINT already raises; these two do not, and the default disposition ends
    the process between the write and the restore. SIGKILL cannot be caught,
    which is why the recorded control hash above exists as well as this.
    """
    def die(signum, _frame):
        raise SystemExit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, die)


def main() -> int:
    # ARMS NAMING ONE CASE ARE RUN INDIVIDUALLY. Passing arm ids on the command
    # line runs exactly those, with the same control run and the same verified
    # restore, so a re-run after fixing one arm does not have to re-grade the
    # other sixteen and a tally cannot stand in for a named verdict.
    global MUTATIONS
    if "--record-control-hashes" in sys.argv[1:]:
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

    # THE TREE IS AT ITS CONTROL BYTES — asserted before anything is mutated,
    # against a RECORDED digest rather than against this run's own reading.
    rc = check_control_hashes()
    if rc:
        return rc

    wanted = [a for a in sys.argv[1:] if not a.startswith("-")]
    if wanted:
        MUTATIONS = [m for m in MUTATIONS if m.id in wanted]
        missing = set(wanted) - {m.id for m in MUTATIONS}
        if missing:
            print(f"no such arm(s): {sorted(missing)}")
            return 2

    baseline = {p: digest(p) for p in TOUCHED}

    # Only the suites the selected arms actually need, so running one arm by id
    # does not pay for a control run of every suite in the file.
    all_suites = [NIM_LIFECYCLE, NIM_BUDGET, BASH_GATE, BASH_SDK_GATE]
    needed = {m.suite.path for m in MUTATIONS + DECLARED_SURVIVORS}
    suites = [s for s in all_suites if s.path in needed]
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
    for mut in MUTATIONS:
        matches = [c for c in controls[mut.suite.path].passed if c == mut.killer]
        if len(matches) != 1:
            print(f"{mut.id}: killer {mut.killer!r} resolves to {len(matches)} "
                  f"green case(s) in {mut.suite.path}, expected exactly 1")
            problems += 1
    if problems:
        print(f"\n{problems} unusable arm(s); nothing was mutated")
        return 1
    print(f"  all {len(MUTATIONS)} killers resolve to exactly one green case\n")

    killed = 0
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        # --- the kill arm -------------------------------------------------
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

        declared = mut in DECLARED_SURVIVORS
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

    print(f"\n{killed} killed, {len(DECLARED_SURVIVORS)} declared survivor(s), "
          f"{problems} problems")
    # THE LOCK IS NAMED HERE ON PURPOSE. It is held by an open descriptor and
    # nothing else reads the variable, so a tidying pass — or a linter reporting
    # an unused binding — would delete it and silently re-open the concurrency
    # hole it exists to close. Printing it makes the hold visible in every
    # transcript and makes the binding load-bearing to a reader.
    print(f"run lock held for the whole run: {LOCK_PATH.name} (fd {lock.fileno()})")
    lock.close()
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
