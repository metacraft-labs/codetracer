#!/usr/bin/env python3
"""Mutation harness for PLAT-16's terminal edit mode.

Every case in PLAT-16's five suites claims to detect something. This script
proves it, one case at a time: it patches a single line of the SUBJECT and
requires that the **named** case fails. A mutation killed only by some other
case is MISDIRECTED and is a failure of this harness, not a pass.

SIX SUITES, TWO TIERS. Each arm names the suite it is graded against:

  test_product_mode_dimensions.nim  Tier 1 — the two dimensions, and the
                                             keymap scoping between them
  test_mode_transition_oracle.nim   Tier 1 — Mode-Transitions.md §5 read at run
                                             time, and the mode register
  test_edit_mode_source.nim         Tier 1 — which source a mode shows, the
                                             stale-trace TELLING, and the route
                                             a replay session reaches it by
  test_edit_mode_build.nim          Tier 1 — the verdict states and the
                                             cancellation, with no process
  test_build_runner_process.nim     Tier 1 — the PROCESS: real children, one of
                                             them deliberately silent
  test_real_edit_mode.nim           Tier 2 — the shipped binary, a real pty,
                                             real key bytes, a real recording

SEVEN VERDICTS, NOT TWO (Verification-Harness-Traps §1, §1a and §17). An arm
that never ran is not a kill, and neither is one that died upstream of its
subject, and neither is one whose case never reached a verdict:

  killed                 the named case reported [FAILED] **and its failure
                         text carried the arm's own `because`**
  MIS-ATTRIBUTED         the named case died, but not for the arm's reason
  NO-VERDICT-FOR-KILLER  the named case reported NEITHER [OK] nor [FAILED] —
                         the mutant died inside it, before the result line
  SURVIVED               the run produced result lines and the named case
                         was [OK]
  MISDIRECTED            something else died and the named case did not
  SPARED-CASE-DIED       a case the arm declares must stay green did not
  HARNESS-FAILURE        the mutation did not apply, did not compile, or the
                         run produced NO result lines at all

`HARNESS-FAILURE` is the one this file was written to keep distinct. A run that
prints nothing looks exactly like a run in which every case passed if the only
signal read is an exit status, and reporting it as "killed" credits an arm that
was never executed. **Verdicts are parsed from `[OK]` / `[FAILED]` lines and
never from an exit status**, because a compile error also exits non-zero.

`MIS-ATTRIBUTED` is §17's fourth verdict and was ADDED BY PLAT-16'S LANDING
PASS, which found it missing: without a `because` field the harness could not
tell a case that died at the arm's own statement from one that died at a
refusal three hundred lines upstream, and several arms reported `(+N more)`
collateral with nothing distinguishing the two. Like `HARNESS-FAILURE` it says
*the run told you nothing*, not *the code is wrong*.

TWO RULES ABOUT `because` STRINGS, BOTH PAID FOR ELSEWHERE (§17a, §17b):

  * **Quote the expression AS SUBSTITUTED AT THE CALL SITE.** `unittest`
    stringifies the AST it receives, and a `template` body is substituted
    before it gets there — so `check cond` inside `template ck` prints the
    CALLER's expression, and a `because` copied from the template's source can
    never occur.
  * **DERIVE it from a transcript, never type it from the file.** Run the arm,
    read the `Check failed:` line, paste that. `--collect-because` below does
    exactly that and prints a ready-to-paste line per arm: a `because` typed
    from the source is a second copy of the code held in a file the compiler
    does not read, and this is the one place the copy and the original are not
    written in the same language.

`--needle-scan` cannot guard these. It answers *"does this arm still point at
code that exists"*; a `because` points at text no file contains until a run
produces it, so the only instrument is running the arm — which is the third
step of §16's own ordering (scan needles, re-record digests, **re-run arms**).

DECLARED SURVIVORS ARE A DELIVERABLE, AND EVERY KILL ARM NAMES ITS OWN. A
harness that kills everything says as little as one that kills nothing, so
`DECLARED_SURVIVORS` holds behaviour-preserving rewrites that MUST survive; an
arm that starts being killed is reported as a problem in its own right. The
pairing is written at both ends and is listed in `CONTROL_PAIRS` below, which
is checked for completeness before any arm runs: an arm with no control cannot
say whether the case it reddens reddens for the right reason.

THE LOCK COMES FIRST, BEFORE THE BASELINE DIGESTS. Two copies of this harness
in one checkout would interleave their mutations, and the second one's
"baseline" would be the first one's mutated tree — after which every
restoration check passes against the wrong bytes and every verdict is a
fabrication. `flock(LOCK_ONLY, LOCK_EX | LOCK_NB)` is taken as the FIRST thing
`main` does, and the digests are read after it.

THE NEEDLE SCAN GATES THE BASELINE. Before anything is mutated, every arm's
`find` pattern is required to occur EXACTLY ONCE in its file. If any does not,
the run aborts and **records nothing**: a needle that stopped resolving means
the subject moved, and the correct response is to re-point the arm and re-run
it, never to accept a digest taken over a tree whose arms no longer aim at
anything (Verification-Harness-Traps §32a — *"a repair that tightens can disarm
an arm whose needle still resolves — re-run arms, never only re-record
digests"*).

RESTORATION IS FROM AN IN-MEMORY SNAPSHOT, never from `git checkout --`: the
original bytes are read before the mutation and written back after it, and the
SHA-256 of every touched file is compared against the control hash AFTER EVERY
ARM. The run aborts on a mismatch rather than continuing on a dirty tree.

Usage (from the `codetracer` repository root):
  direnv exec . python3 src/frontend/tui/app/tests/run-plat16-mutations.py
  direnv exec . python3 src/frontend/tui/app/tests/run-plat16-mutations.py M3 S1
  direnv exec . python3 src/frontend/tui/app/tests/run-plat16-mutations.py \
      --collect-because            # derive every `because` from a real run
"""

import fcntl
import hashlib
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]

LOCK_PATH = ROOT / ".plat16-mutations.lock"

DIMS = "src/frontend/tui/app/tests/test_product_mode_dimensions.nim"
ORACLE = "src/frontend/tui/app/tests/test_mode_transition_oracle.nim"
SOURCE = "src/frontend/tui/app/tests/test_edit_mode_source.nim"
BUILDS = "src/frontend/tui/app/tests/test_edit_mode_build.nim"
PROCESS = "src/frontend/tui/tests/test_build_runner_process.nim"
REALPTY = "src/frontend/tui/tests/real_terminal/test_real_edit_mode.nim"

TIER2 = {REALPTY}
TIER2_PATHS = ["--path:../TermAssert/src", "--path:../TermAssertClient/src",
               "--path:../nim-libvterm/src"]

PMODE = "src/frontend/viewmodel/viewmodels/product_mode.nim"
KEYMAP = "src/frontend/tui/app/input/keymap.nim"
STATUS = "src/frontend/tui/app/views/status_bar.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
EDITPANE = "src/frontend/tui/app/views/edit_pane.nim"
EDITBIND = "src/frontend/tui/app/edit_binding.nim"
BUILDSESS = "src/frontend/tui/app/build_session.nim"
BUILDPANE = "src/frontend/tui/app/views/build_output.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
PROFILE = "src/frontend/tui/app/layout/profile.nim"
CLI = "src/frontend/tui/app/cli.nim"
BUILDRUNNER = "src/frontend/tui/host/build_runner.nim"
MAIN = "src/frontend/tui/main.nim"

# WHAT THE PER-ARM DIGEST CHECK COVERS: every source file of this repository
# that an arm's verdict depends on — the five suites and the ten subjects.
#
# THE TIER-2 ARM DEPENDS ON A BUILT BINARY (`build/bin/codetracer-tui`) THAT
# THIS LIST CANNOT COVER, and that is stated rather than left to be found. A
# hash over a build output would move whenever the binary is rebuilt and would
# report nothing; what makes the Tier-2 arms honest instead is that
# `run_suite` REBUILDS the binary for every Tier-2 arm before running the
# suite, so a stale binary cannot grade a mutation. PLAT-6's harness recorded
# the same hazard from the other end — an edit to `dual_snap.nim` left a child
# un-rebuilt and a real defect graded as SURVIVED — and the answer here is to
# rebuild unconditionally rather than to trust a staleness stamp.
# MAIN IS IN THE LIST AND IS COMPILED BY NO SUITE, which is exactly why it is
# here. `main.nim` is the entrypoint: the two loops, and the wiring that decides
# what each of them can do. PLAT-16's landing pass found a defect that lived
# only there — the replay loop wired no `EditServices`, so §2.1's notice had no
# route in the product — and no Tier-1 arm could ever have seen it, because no
# Tier-1 suite has this module in its graph. The arm that grades it is a TIER-2
# arm, killed through a rebuilt binary.
TOUCHED = [DIMS, ORACLE, SOURCE, BUILDS, PROCESS, REALPTY,
           PMODE, KEYMAP, STATUS, SHELL, EDITPANE, EDITBIND, BUILDSESS,
           BUILDPANE, RUNTIME, PROFILE, CLI, BUILDRUNNER, MAIN]


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    suite: str
    killer: str
    why: str = ""
    spares: list = field(default_factory=list)


# ---------------------------------------------------------------------------
# The kill arms
# ---------------------------------------------------------------------------

MUTATIONS = [
    # ---- §2: which source a mode shows -----------------------------------
    Mutation(
        "M1", PMODE,
        "ModeSourceContract(origin: soWorkingTree, mutable: true, "
        "windowed: false,",
        "ModeSourceContract(origin: soTracePayload, mutable: true, "
        "windowed: false,",
        SOURCE, "the two modes read two origins, and the answer is the core's",
        "Edit mode reads the recording's copy — §2's table inverted."),
    Mutation(
        "M2", PMODE,
        'statement: "the working tree")',
        'statement: "")',
        SOURCE,
        "the Source pane states which mode's source it shows, ALWAYS",
        "The pane stops saying which source it shows."),
    Mutation(
        "M3", PMODE,
        "  if assessment.verdict != stvStale:\n    return \"\"",
        "  if true:\n    return \"\"",
        SOURCE,
        "edit, toggle to Debug on an existing trace, and the user is told",
        "The stale-trace sentence is never produced: the user is misled."),
    Mutation(
        "M4", PMODE,
        "    elif result.editedPaths.len == 0: stvFresh\n"
        "    else: stvStale",
        "    else: stvFresh",
        SOURCE,
        "the notice names the files, and caps the list rather than the count",
        "A recording is never stale, whatever was edited."),

    # ---- §5's preservation table, read at run time ------------------------
    Mutation(
        "M5", PMODE,
        "  for ch in text.toLowerAscii:",
        "  for ch in text:",
        ORACLE,
        "a mutated cell is DETECTED — the oracle is read, not assumed",
        "The normaliser stops lower-casing, so an upper-case initial is "
        "dropped rather than folded and no document row can match.\n"
        "\n"
        "        THE FIRST VERSION OF THIS ARM SURVIVED AND WAS WRONG, and "
        "the finding is kept here rather than edited away: it replaced\n"
        "        `cell.replace(\"**\", \"\").strip()` with `cell`, which is "
        "BEHAVIOUR-PRESERVING for every row §5 publishes — the slugifier "
        "already reduces `*` and surrounding whitespace to nothing, because "
        "they are not alphanumeric. An arm that changes no behaviour cannot "
        "kill anything, and `SURVIVED` was the correct verdict about it. The "
        "lower-casing is the one step of that function whose removal is "
        "observable."),
    Mutation(
        "M6", PMODE,
        'pcFoldState = "fold-state"',
        'pcFoldState = "folds"',
        ORACLE,
        "every row the document names is a concern this build carries",
        "One concern's slug drifts from the row the document publishes."),

    # ---- the mode register ------------------------------------------------
    Mutation(
        "M7", SHELL,
        "  if target == reg.product:\n    return false\n"
        "  reg.layouts[reg.product] = leaving",
        "  if false:\n    return false\n"
        "  reg.layouts[reg.product] = leaving",
        ORACLE,
        "an idempotent switch changes nothing and overwrites no cell",
        "§6's idempotence guard goes: switching to the current mode "
        "overwrites the other mode's cell."),
    Mutation(
        "M8", SHELL,
        "  reg.layouts[reg.product] = leaving\n  reg.product = target",
        "  reg.product = target",
        ORACLE,
        "the register is keyed by MODE, so Edit does not disturb Debug",
        "§4 requirement 2 goes: the leaving mode's arrangement is not kept."),
    Mutation(
        "M9", SHELL,
        "  if reg.layouts[target].isNil:\n"
        "    reg.layouts[target] = layoutForMode(target, profile)",
        "  reg.layouts[target] = layoutForMode(target, profile)",
        ORACLE,
        "three round trips leave every parsed concern byte-identical",
        "§4 requirement 1 goes: every entry rebuilds from the mode default, "
        "which is the 'works once' failure §6 is written against."),

    # ---- the two dimensions, and the scoping between them -----------------
    Mutation(
        "M10", KEYMAP,
        "     kaToggleHexDec, kaViewMemoryDump, kaEnterInspect:\n"
        "    asDebugOnly",
        "     kaToggleHexDec, kaViewMemoryDump, kaEnterInspect:\n"
        "    asBoth",
        DIMS,
        "every action's scope is declared, and the three arms are exactly these",
        "The debug-only arm empties: scoping exists and decides nothing."),
    Mutation(
        "M11", KEYMAP,
        "    if not appliesIn(bnd.action, product):",
        "    if false:",
        DIMS,
        "one physical key, two product modes, two answers — and a control",
        "§8.1's inert-and-says-so goes: Step Over fires in Edit mode."),
    Mutation(
        "M12", KEYMAP,
        '  r.add b(mmNormal, "Ctrl+F5", kaToggleProductMode)',
        "  discard",
        DIMS,
        "Ctrl+F5 is one command, reachable from both product modes",
        "§8.4 goes: the transition is one-way from the keyboard."),
    Mutation(
        "M13", KEYMAP,
        "  of kaToggleProductMode: ssModeTransitions",
        "  of kaToggleProductMode: ssSpec41",
        DIMS,
        "the toggle comes from a third published document, and exactly one does",
        "The toggle is filed under a document that does not publish it."),
    Mutation(
        "M14", STATUS,
        '  "[" & $product & "]"',
        '  ""',
        DIMS,
        "the state space is the PRODUCT of the two, not their sum",
        "The product indicator disappears: one dimension is on screen."),
    Mutation(
        "M15", STATUS,
        "  if mode == umNormal and product == pmEdit:",
        "  if false:",
        DIMS,
        "the product mode changes the hint strip without changing the input mode",
        "The hint strip stops being a function of the product mode."),

    # ---- the editing surface ----------------------------------------------
    Mutation(
        "M16", EDITPANE,
        "      isExecutionLine = false, numberStyle = EditLineNumberStyle)",
        "      isExecutionLine = true, numberStyle = EditLineNumberStyle)",
        SOURCE,
        "the gutter is Debug's minus the execution pointer, and the code "
        "column does not move",
        "§3's 'minus the execution pointer' goes: `-->` on every line."),
    Mutation(
        # RE-POINTED BY PLAT-34 (§32a): `buf.widget.text` is `buf.doc.text`.
        "M17", EDITBIND,
        "buf.doc.text != buf.loadedText",
        'buf.doc.text != ""',
        SOURCE,
        "an edit that was undone is not a staleness",
        "`isDirty` stops comparing against WHAT WAS LOADED, so every non-empty "
        "buffer is dirty forever and an undone edit still announces a stale "
        "recording.\n"
        "\n"
        "        THE FIRST VERSION OF THIS ARM SURVIVED AND WAS WRONG: it "
        "compared `undoStack.len > 0`, and `isonim-tui`'s `undo` POPS from "
        "that stack, so after a `Ctrl+z` the mutated predicate answered false "
        "exactly as the real one does. A second spelling of the same answer is "
        "not a mutation."),
    Mutation(
        "M18", SHELL,
        "  if region.pane == paneEditor and model.product == pmEdit and",
        "  if region.pane == paneEditor and not model.edit.isEmpty and",
        SOURCE,
        "the editor rectangle is painted from the PRODUCT mode and nothing else",
        "The pane branches on the DATA rather than on the mode, so Debug mode "
        "shows the working tree for any session that ever opened a file."),

    # ---- the verdicts -----------------------------------------------------
    Mutation(
        "M19", BUILDSESS,
        "    if s.cancelRequested: bvCancelled\n"
        "    elif exitCode == 0: bvSucceeded",
        "    if exitCode == 0: bvSucceeded",
        BUILDS,
        "cancellation is a verdict of its own, and the exit code does not "
        "decide it",
        "A cancelled build is reported as a FAILED one: §5a's merged events."),
    Mutation(
        "M20", BUILDSESS,
        "  of bvIdle, bvCancelled: bsIdle",
        "  of bvIdle: bsIdle\n  of bvCancelled: bsFailed",
        BUILDS,
        "the core's four states are reachable and the fifth maps onto idle",
        "The lossy direction loses the distinction it exists to keep."),
    Mutation(
        "M21", BUILDSESS,
        "    s.lines.delete(0)\n    s.truncated = true",
        "    s.lines.delete(0)",
        BUILDS,
        "output is capped and the cap is REPORTED",
        "The pane silently loses the first error."),
    Mutation(
        "M22", BUILDPANE,
        '  of bvCancelled: CellStyle(fg: "yellow", bold: true)',
        '  of bvCancelled: CellStyle(fg: "red", bold: true)',
        BUILDS,
        "each verdict has its own colour, and no two share one",
        "Two verdicts become indistinguishable to a colour read."),
    Mutation(
        "M23", RUNTIME,
        "      elif not rt.app.build.isNil and rt.app.build.verdict == "
        "bvRunning:",
        "      elif false:",
        BUILDS,
        "the verbs reach the host seam, and only in Edit mode",
        "Two builds run at once and write into one pane."),
    Mutation(
        "M24", RUNTIME,
        "  if rt.app.modes.product == pmEdit:\n    var text = line.strip()",
        "  if true:\n    var text = line.strip()",
        BUILDS,
        "the verbs reach the host seam, and only in Edit mode",
        "The five edit verbs stop being an Edit-mode prefix and shadow §4.3's "
        "published surface in Debug mode too."),

    # ---- the per-mode layout ----------------------------------------------
    Mutation(
        "M25", PROFILE,
        "  of pmEdit: editProfileLayout(profile)",
        "  of pmEdit: profileLayout(profile)",
        ORACLE,
        "the register is keyed by MODE, so Edit does not disturb Debug",
        "§4a goes: Edit mode inherits Debug's furniture."),

    # ---- Tier 2: the shipped binary on a real pty -------------------------
    Mutation(
        "M26", CLI,
        '      editRequested = true\n    of "--no-flow-overlay":',
        '      editRequested = false\n    of "--no-flow-overlay":',
        REALPTY,
        "`--edit <project>` opens the project in EDIT mode, with the file on "
        "screen",
        "`--edit` PARSES AND SILENTLY DOES NOTHING — the exact failure "
        "`cli.PlannedOptions`' header is written against. The positional then "
        "reaches the front-end as a trace folder and the binary refuses it for "
        "having no `trace.json`: a true diagnosis of the wrong question.\n"
        "\n"
        "        THE FIRST VERSION OF THIS ARM DID NOT COMPILE (it changed the "
        "object variant's branch and left a field of the other branch behind), "
        "and the harness reported HARNESS-FAILURE rather than a kill — which "
        "is the third verdict working. An arm that does not build grades "
        "nothing."),
    Mutation(
        "M27", RUNTIME,
        "  if rt.app.modes.product != pmEdit or rt.modal.mode != mmNormal:\n"
        "    return false",
        "  if true:\n    return false",
        REALPTY,
        "a typed byte reaches the buffer, and the dirty marker appears",
        "The editor stops owning its keys: a typed character is a command "
        "again. Only a real pty can see this — a Tier-1 suite that called "
        "`applyEditKey` directly would still pass."),

    # ---- F2: `:w` must not silence the staleness notice -------------------
    #
    # The defect these three grade was LIVE and green: `refreshEditedPaths`
    # read `isDirty` ("differs from disk") as "differs from what was recorded",
    # and `markSaved` answers the first one `false`. Measured before the
    # repair: edit + toggle told the user; edit + `:w` + toggle said "switched
    # to DEBUG mode" with `editedPaths: @[]`.
    Mutation(
        "M28", EDITBIND,
        "    if idx >= 0 and s.buffers[idx].outrunsRecording:",
        "    if idx >= 0 and s.buffers[idx].isDirty:",
        SOURCE,
        "a saved edit is still an edit the recording predates",
        "THE DEFECT ITSELF, RESTORED. `refreshEditedPaths` goes back to asking "
        "`isDirty`, so saving silences the notice — §5a's two questions merged "
        "back into one `bool`, with the dangerous one read as the benign one."),
    Mutation(
        # RE-POINTED BY PLAT-34 (§32a): `buf.widget.text` is `buf.doc.text`.
        "M29", EDITBIND,
        "    buf.loadedText = buf.doc.text",
        "    buf.loadedText = buf.doc.text\n"
        "    buf.recordedText = buf.doc.text",
        SOURCE,
        "a saved edit is still an edit the recording predates",
        "THE SAME DEFECT THROUGH THE OTHER END, and it is a separate arm "
        "because it is a separate mechanism (§32a: two mechanisms guarding one "
        "property each need evidence only they can produce). `markSaved` moves "
        "the BASELINE instead of the disk copy, so a save makes the recording "
        "retroactively fresh — a repair to `refreshEditedPaths` alone would "
        "leave this route open."),
    Mutation(
        # RE-POINTED BY PLAT-34 (§32a). `buf.widget` is gone — the terminal's
        # buffer is `EditingDocument` now and `buf.doc.text` is the same
        # question asked of the model. The DEFECT is unchanged; only the
        # spelling of the left-hand operand moved, and this harness refused to
        # run until it was re-pointed, which is the guard working.
        "M30", EDITBIND,
        "  buf.doc.text != buf.recordedText or "
        "buf.loadedText != buf.recordedText",
        "  buf.doc.text != buf.recordedText",
        SOURCE,
        "a save that restores the recorded bytes IS fresh again",
        "The DISK half of the disjunction goes. edit + `:w` + undo then reads "
        "as fresh, because the buffer is back — while the file on disk still "
        "holds the edit. This is the arm that makes the second half of "
        "`outrunsRecording` load-bearing rather than decorative."),
    Mutation(
        # RE-POINTED BY PLAT-34 (§32a), same reason as M30.
        "M31", EDITBIND,
        "  buf.doc.text != buf.recordedText or ",
        "  ",
        SOURCE,
        "edit, toggle to Debug on an existing trace, and the user is told",
        "The BUFFER half goes, so an UNSAVED edit stops being a staleness and "
        "the milestone's own named case dies. Paired with M30 in the other "
        "direction: between them neither half of the disjunction can be "
        "removed silently."),

    # ---- F1: the route the notice needs, and the once-per-session rule ----
    Mutation(
        "M32", RUNTIME,
        "  if rt.app.editSession.furnished or rt.editServices.listFiles.isNil:\n"
        "    return \"\"",
        "  if true:\n    return \"\"",
        SOURCE,
        "the toggle furnishes the workspace through the host seam, exactly once",
        "THE PRE-REPAIR STATE, RESTORED. `ensureEditWorkspace` does nothing, so "
        "`Ctrl+F5` out of a replay session reaches an editor with no file tree, "
        "no buffer and no reader — which is the state in which §2.1's notice "
        "cannot be produced by any shipped route at all."),
    Mutation(
        "M33", RUNTIME,
        "  if rt.app.editSession.furnished or rt.editServices.listFiles.isNil:",
        "  if rt.editServices.listFiles.isNil:",
        SOURCE,
        "the toggle furnishes the workspace through the host seam, exactly once",
        "The once-per-session guard goes: every `Ctrl+F5` re-walks the project. "
        "Not merely wasteful — it is a second chance to replace an unsaved "
        "buffer, which Mode-Transitions.md §5 calls data loss by name."),
    Mutation(
        "M34", MAIN,
        "  let edit = wireEditServices(rt, projectRoot, proc(): EditListResult =\n"
        "    let listing = listProjectFiles(projectRoot)\n"
        "    EditListResult(files: listing.files, truncated: listing.truncated))",
        "  let edit = EditHostState()",
        REALPTY,
        "a recording, an edit, a save, and the switch back TELLS the user",
        "THE DEFECT F1 NAMED, IN THE ONE FILE NO TIER-1 SUITE COMPILES. The "
        "replay loop stops wiring the host seam, so the toggle into Edit mode "
        "arrives at an empty session exactly as it did before the landing "
        "pass. Only a Tier-2 arm can reach this: `main.nim` is in no suite's "
        "module graph, which is precisely why the defect survived a green "
        "Tier-1 suite whose fixture supplied the missing state by hand."),

    # ---- F3: the drain that claimed not to block ---------------------------
    Mutation(
        "M35", BUILDRUNNER,
        "  if flags == -1 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) == -1:",
        "  if flags == -1 or fcntl(fd, F_SETFL, flags) == -1:",
        PROCESS,
        "a child that is SILENT for three seconds does not hold the loop",
        "THE DEFECT ITSELF, RESTORED: the descriptor stays blocking, so "
        "`read` sleeps on a silent child and the byte bound never fires. "
        "Measured in that state — one poll, 3005 ms, and zero returns to the "
        "loop in three seconds — which in the product is the whole TUI frozen "
        "with `:cancel` unreachable."),
    Mutation(
        "M36", BUILDRUNNER,
        "    discard rb.drain(MaxBytesAtExit)",
        "    discard 0",
        PROCESS,
        "output written just before the child exits is not lost",
        "The post-exit drain goes, so everything past one poll's byte bound is "
        "thrown away when the descriptor is dropped — for a compiler, exactly "
        "the errors the user ran `:build` to read. A SEPARATE MECHANISM from "
        "M35 and therefore a separate arm."),
    Mutation(
        "M37", BUILDRUNNER,
        "    if err == EAGAIN or err == EWOULDBLOCK:\n      return",
        "    if err == EAGAIN or err == EWOULDBLOCK:\n"
        "      rb.sawEof = true\n      return",
        PROCESS,
        "a child that is SILENT for three seconds does not hold the loop",
        "\"Nothing to read RIGHT NOW\" is read as \"there will never be another "
        "byte\" — the two facts `sawEof` exists to keep apart, and the ordinary "
        "state of a silent build merged into the terminal one. The loop stays "
        "responsive and the output never arrives, which is the failure mode a "
        "naive non-blocking fix has and the reason this arm is not M35's "
        "twin."),
]


# ---------------------------------------------------------------------------
# The declared survivors — every kill arm's named control
# ---------------------------------------------------------------------------

DECLARED_SURVIVORS = [
    Mutation(
        "S1", PMODE,
        "  var slug = \"\"\n  var pendingDash = false",
        "  var slug = \"\"\n  var pendingDash: bool = false",
        ORACLE, "",
        "An explicit type on a local that was already `bool`. Pairs M5/M6: "
        "those arms redden the oracle cases because the NORMALISATION changed, "
        "not because `product_mode.nim` was edited."),
    Mutation(
        "S2", KEYMAP,
        "  of asBoth: true\n  of asDebugOnly: product == pmDebug\n"
        "  of asEditOnly: product == pmEdit",
        "  of asDebugOnly: product == pmDebug\n  of asEditOnly: "
        "product == pmEdit\n  of asBoth: true",
        DIMS, "",
        "The three arms of `appliesIn` in a different order — a `case` over an "
        "enum, so the order is not behaviour. Pairs M10/M11/M12/M13."),
    Mutation(
        "S3", SHELL,
        "  if target == reg.product:\n    return false",
        "  if reg.product == target:\n    return false",
        ORACLE, "",
        "`==` with its operands swapped. Pairs M7/M8/M9/M18/M25: those arms "
        "redden because the REGISTER's behaviour changed."),
    Mutation(
        "S4", EDITPANE,
        "    spec.isInspectionLine = false",
        "    spec.isInspectionLine = (1 == 2)",
        SOURCE, "",
        "`false` spelled as a constant-folded comparison. Pairs M16/M17: the "
        "gutter case reddens for the POINTER, not for an edit to this file."),
    Mutation(
        "S5", BUILDSESS,
        "  BuildSession(kind: kind, command: command, verdict: bvIdle, "
        "exitCode: 0,\n               lines: @[], truncated: false, "
        "cancelRequested: false,\n               deadlineMs: deadlineMs, "
        "startedMs: nowMs)",
        "  BuildSession(command: command, kind: kind, exitCode: 0, "
        "verdict: bvIdle,\n               truncated: false, lines: @[], "
        "cancelRequested: false,\n               startedMs: nowMs, "
        "deadlineMs: deadlineMs)",
        BUILDS, "",
        "The constructor's named fields in a different order — named "
        "arguments, so the order is not behaviour. Pairs M19/M20/M21/M22."),
    Mutation(
        "S6", STATUS,
        "  let mode = $m.mode & \" \" & productIndicator(m.product)",
        "  let mode = ($m.mode) & \" \" & productIndicator(m.product)",
        DIMS, "",
        "Redundant parentheses around `$m.mode`. Pairs M14/M15: the dimension "
        "cases redden because an INDICATOR went, not because this line moved."),
    Mutation(
        "S7", RUNTIME,
        "    of \"cancel\":\n      if rt.app.build.isNil or "
        "rt.app.build.verdict != bvRunning:",
        "    of \"cancel\":\n      if rt.app.build.isNil or "
        "not (rt.app.build.verdict == bvRunning):",
        BUILDS, "",
        "`!=` spelled as `not (… == …)`. Pairs M23/M24."),
    Mutation(
        "S8", CLI,
        "            if editPath.len > 0:",
        "            if editPath.len != 0:",
        REALPTY, "",
        "`> 0` spelled as `!= 0` on a `len`, in the attached-value arm of "
        "`--edit`. Pairs M26/M27: the Tier-2 "
        "cases redden because the front-end stopped working, not because "
        "`cli.nim` was touched — which is the control a pty arm most needs, "
        "since a child that will not start looks the same as one that starts "
        "and misbehaves."),
    Mutation(
        # RE-POINTED BY PLAT-34 (§32a). The nil guard lost its second
        # conjunct with the widget — there is no second object to be nil — and
        # the operands are `buf.doc.text` now. This is a NEVER-MUTATED
        # CONTROL: it must still survive, and re-pointing it is what keeps it
        # able to.
        "S9", EDITBIND,
        "  if buf.isNil:\n    return false\n"
        "  buf.doc.text != buf.recordedText or "
        "buf.loadedText != buf.recordedText",
        "  if buf.isNil:\n    return false\n"
        "  (buf.doc.text != buf.recordedText) or "
        "(buf.loadedText != buf.recordedText)",
        SOURCE, "",
        "Redundant parentheses around the two operands of an `or`. Pairs "
        "M28/M29/M30/M31: those arms redden because the STALENESS PREDICATE "
        "changed meaning, not because `edit_binding.nim` was edited."),
    Mutation(
        "S10", BUILDRUNNER,
        "  if rb.isNil or rb.fd < 0 or rb.sawEof:",
        "  if rb.isNil or rb.sawEof or rb.fd < 0:",
        PROCESS, "",
        "Two pure predicates in an `or` chain swapped. Neither can raise and "
        "neither has an effect, so the order is not behaviour. Pairs "
        "M35/M36/M37: the process cases redden because the PIPE stopped being "
        "read correctly, not because this file was touched."),
    Mutation(
        "S12", RUNTIME,
        '  let where = if rt.app.projectRoot.len > 0: rt.app.projectRoot else: "."',
        '  let where = if rt.app.projectRoot.len != 0: rt.app.projectRoot else: "."',
        SOURCE, "",
        "`> 0` spelled as `!= 0` on a `len`, inside `ensureEditWorkspace`. "
        "Pairs M32/M33: the route cases redden because the WORKSPACE stopped "
        "being furnished, not because `runtime.nim` was edited — and it is a "
        "RUNTIME control graded against SOURCE rather than borrowing S7, which "
        "is graded against a suite these arms do not name."),
    Mutation(
        "S11", MAIN,
        "  let projectRoot = getCurrentDir()",
        "  let projectRoot: string = getCurrentDir()",
        REALPTY, "",
        "An explicit type on a local that was already `string`. Pairs M34, and "
        "it is the control a Tier-2 arm over the ENTRYPOINT most needs: a "
        "`main.nim` that stopped compiling would fail the same cases M34 "
        "fails, and this is what tells 'the wiring went' from 'the binary "
        "went'."),
]

# EVERY KILL ARM NAMES ITS CONTROL, and the map is checked for completeness
# before any arm runs. An arm with no control establishes only "the case
# reddens when this line changes", which is not the claim the harness makes.
CONTROL_PAIRS = {
    "M1": "S1", "M2": "S1", "M3": "S1", "M4": "S1", "M5": "S1", "M6": "S1",
    "M7": "S3", "M8": "S3", "M9": "S3", "M18": "S3", "M25": "S3",
    "M10": "S2", "M11": "S2", "M12": "S2", "M13": "S2",
    "M14": "S6", "M15": "S6",
    "M16": "S4", "M17": "S4",
    "M19": "S5", "M20": "S5", "M21": "S5", "M22": "S5",
    "M23": "S7", "M24": "S7",
    "M26": "S8", "M27": "S8",
    "M28": "S9", "M29": "S9", "M30": "S9", "M31": "S9",
    "M32": "S12", "M33": "S12",
    "M34": "S11",
    "M35": "S10", "M36": "S10", "M37": "S10",
}

# The cases each suite MUST have run for a control to count as green. A control
# that skipped the case an arm is graded against grades nothing.
SUITE_CASES = {
    DIMS: [
        "the two enums have their own cardinalities, and neither names the other",
        "the state space is the PRODUCT of the two, not their sum",
        "the product mode changes the hint strip without changing the input mode",
        "every action's scope is declared, and the three arms are exactly these",
        "one physical key, two product modes, two answers — and a control",
        "Ctrl+F5 is one command, reachable from both product modes",
        "the toggle comes from a third published document, and exactly one does",
    ],
    ORACLE: [
        "the specification is present, and §5's table parses",
        "every row the document names is a concern this build carries",
        "a mutated cell is DETECTED — the oracle is read, not assumed",
        "three round trips leave every parsed concern byte-identical",
        "the register is keyed by MODE, so Edit does not disturb Debug",
        "an idempotent switch changes nothing and overwrites no cell",
    ],
    SOURCE: [
        "the two modes read two origins, and the answer is the core's",
        "the Source pane states which mode's source it shows, ALWAYS",
        "the gutter is Debug's minus the execution pointer, and the code "
        "column does not move",
        "the editor rectangle is painted from the PRODUCT mode and nothing else",
        "edit, toggle to Debug on an existing trace, and the user is told",
        "told ONCE, and the negative control says the notice can be absent",
        "an edit that was undone is not a staleness",
        "a saved edit is still an edit the recording predates",
        "a save that restores the recorded bytes IS fresh again",
        "the notice names the files, and caps the list rather than the count",
        "the toggle furnishes the workspace through the host seam, exactly once",
        "no seam, no workspace — and the toggle still says what it did",
        "an empty project is furnished once and reported honestly",
        "a reader that refuses wins the status line over the file count",
    ],
    PROCESS: [
        "a child that is SILENT for three seconds does not hold the loop",
        "a HUNG child is cancelled from the same loop, and the user gets the "
        "verdict",
        "output written just before the child exits is not lost",
        "the deadline bounds a session nobody is watching, and is NOT a "
        "cancellation",
        "a failing child reports its exit code and its diagnostics",
        "a line split across two reads is ONE line in the pane",
        "a command the shell cannot run is a verdict, not an exception",
    ],
    BUILDS: [
        "cancellation is a verdict of its own, and the exit code does not "
        "decide it",
        "the core's four states are reachable and the fifth maps onto idle",
        "the deadline is a bound and is NOT reported as a cancellation",
        "output is capped and the cap is REPORTED",
        "each verdict has its own colour, and no two share one",
        "the pane says the verdict in words, and paints the output",
        "an idle pane is a statement rather than a blank",
        "the error heuristic offers lines and hides none",
        "the verbs reach the host seam, and only in Edit mode",
        "a missing runner is reported, not a crash",
        "`:w` writes through the host seam and clears the dirty marker",
    ],
    REALPTY: [
        "the binary this lane tests exists and can be executed",
        "`--edit <project>` opens the project in EDIT mode, with the file on "
        "screen",
        "a typed byte reaches the buffer, and the dirty marker appears",
        "Ctrl+z undoes, written as the byte 0x1a",
        "`sendKey(\"ctrl+f5\")` loses the modifier; the raw bytes do not",
        "Ctrl+F5 switches the product mode, as bytes, and the indicator moves",
        "a recording, an edit, a save, and the switch back TELLS the user",
        "with NO edit, the same route says nothing — the notice is not a "
        "constant",
        "`--edit` with `--headless` is refused on the ordinary screen",
    ],
}

# ---------------------------------------------------------------------------
# §17's `because`: a substring the KILLER CASE'S OWN FAILURE TEXT must contain
# ---------------------------------------------------------------------------
#
# **EVERY LINE BELOW WAS PRODUCED BY A RUN, NOT TYPED FROM A SUITE.**
# `--collect-because` applies each arm, runs its suite, reads the killer case's
# `Check failed:` line out of the transcript and prints exactly this table. That
# is §17's own "cheaper approximation" taken literally, and §17a's rule about
# where a typed one goes wrong: `unittest` renders a `check` by stringifying the
# AST it was handed, and `template ck(condition)` is substituted before that, so
# what comes out is the CALLER's expression with the CALLER's own arguments in
# it — a string that cannot be copied out of `edit_binding.nim` or out of the
# `ck` template, only observed.
#
# A TABLE RATHER THAN A FIELD ON EACH ARM, for one reason: it is GENERATED, and
# generated text mixed into hand-written arms invites hand-editing. Regenerate
# it after any repair that moves an assertion — §17b is a `because` going stale
# through an ordinary rename, and nothing static can see that happen.
#
# TWO ARMS MAY SHARE A STRING and two do (M23/M24): both break the same
# assertion of the same case through different lines of `runtime.nim`. That is
# not §17a's shared-`because` hazard, which is about one TEMPLATE's callers
# being indistinguishable; here the case is the same case, and `killer` already
# names it.
BECAUSE = {
    'M1': 'sourceOriginFor(pmEdit) == soWorkingTree',
    'M2': 'sourceStatementFor(mode).len > 0',
    'M3': 'row.contains("predates")',
    'M4': 'notice.contains("5 files")',
    'M5': 'real == $pcCaretAndSelection',
    'M6': 'fromSpec == fromCode',
    'M7': 'not reg.switchTo(intruder, pmDebug, lpStandard)',
    'M8': 'reg.activeLayout() == debugTree',
    'M9': 'onScreen == editTree',
    'M10': 'debugOnly.len > 0',
    'M11': 'inEdit.kind == krInertInMode',
    'M12': 'r.kind == krAction',
    'M13': 'fromModeTransitions == @["toggle-product-mode"]',
    'M14': 'bar.find("[EDIT]") > bar.find("SEARCH")',
    'M15': 'debugHints != editHints',
    'M16': 'not text.contains(ExecutionPointerGlyph)',
    'M17': 'not buf.isDirty',
    'M18': 'not inDebug.contains(EditPaneTitle)',
    'M19': 'cancelled.verdict == bvCancelled',
    'M20': 'statusOf(bvCancelled) == bsIdle',
    'M21': 's.truncated',
    'M22': 'style.fg notin colours',
    'M23': 'asked.len == 1',
    'M24': 'asked.len == 1',
    'M25': 'firstEdit.contains(paneFileTree)',
    'M26': "Unhandled exception: the binary exited before 'EDIT ' appeared; screen was:",
    'M27': "Unhandled exception: 'Zproc alpha() =' never appeared within 20000 ms; screen:",
    'M32': 'walks == 1',
    'M28': 'switched.detail.contains("predates")',
    'M29': 'buf.outrunsRecording',
    'M30': 'buf.outrunsRecording',
    'M31': 'rt.app.editSession.editedPaths == @[FileA]',
    'M33': 'walks == 1',
    'M34': 'editing.contains("editing ")',
    'M35': 'o.pollsWhileRunning >= MinPollsWhileSilent',
    'M36': 'rb.session.lines[^1] == "20000"',
    'M37': 'rb.session.lines == @["done"]',
}


RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")


@dataclass
class RunResult:
    rc: int
    passed: list = field(default_factory=list)
    failed: list = field(default_factory=list)
    ran: bool = True
    failure_text: dict = field(default_factory=dict)
    """Case name -> everything `unittest` printed before its `[FAILED]` line.

    That is where the `Check failed:` line lives, and it is the only place an
    arm's `because` can be matched against — §17's whole point being that
    *which* assertion died is the difference between a kill and a run that told
    you nothing.
    """

    @property
    def total(self):
        return len(self.passed) + len(self.failed)


CHECK_FAILED = re.compile(r"Check failed:\s*(.*?)\s*$")

# A Nim traceback frame: `<path>(<line>) <symbol>`, with an absolute path in
# it on every host. See `derived_because` for why these must not become a
# `because`.
TRACEBACK_FRAME = re.compile(r"^\S*\.nim\(\d+\)\s+\S+\s*$")


def derived_because(text: str) -> str:
    """The FIRST `Check failed:` line of a case's failure text, as printed.

    "As printed" is the rule, not a convenience: `unittest` renders a `check`
    by stringifying the AST it was handed, and a `template ck(condition)` is
    substituted before that — so what comes out is the CALLER's expression,
    with the caller's own arguments in it. That is both why a `because` typed
    from the source can never occur (§17a) and why the derived one is specific
    to a single call site rather than shared by every caller of the helper.

    The first line and not all of them, because the operands printed under it
    (`x was 3`) carry run-dependent values, and a `because` that quoted one
    would go stale on a host where the value differs — §17b's staleness
    arriving from a third direction.
    """
    for line in text.splitlines():
        m = CHECK_FAILED.search(line)
        if m:
            return m.group(1)
    # NO `Check failed:` AT ALL IS A REAL SHAPE, NOT A GAP, and the Tier-2
    # suite is where it lives: a pty case that waits for the screen to say
    # something fails by RAISING (`'predates' never appeared within 20000 ms`)
    # rather than by a `check`, because "the screen never said it" is a
    # different fact from "the comparison was false" and only the raise can
    # carry the screen that was there instead.
    #
    # THE TRACEBACK FRAMES ARE SKIPPED, AND THAT IS NOT TIDINESS. `unittest`
    # prints the stack trace before the message, and every frame carries an
    # ABSOLUTE PATH and a LINE NUMBER — so a `because` taken from one would be
    # specific to this checkout's directory (it would never match on a CI
    # runner) and would go stale on any edit above it in the file. §17b is a
    # `because` rotting through a rename; this would be one rotting through a
    # newline. The message is the first line that is not a frame.
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if TRACEBACK_FRAME.match(stripped):
            continue
        return stripped
    return ""


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def link_flags():
    """The `--passL:` flags the lane adds, read from the same file."""
    path = ROOT / "build" / "grammars" / "tui-link-flags.txt"
    if not path.is_file():
        return []
    return ["--passL:" + f for f in path.read_text().split()]


def rebuild_product() -> bool:
    """Rebuild `build/bin/codetracer-tui`, which the Tier-2 arm grades.

    UNCONDITIONALLY, before every Tier-2 arm. See `TOUCHED`'s note: a staleness
    stamp is what let PLAT-6's harness grade a real defect as SURVIVED, and
    this is the same hazard with the cheaper answer.
    """
    archive = ROOT / "build" / "grammars" / "libcodetracer_tui_grammars.a"
    cmd = ["nim", "c", "--hints:off", "--path:src/frontend/viewmodel",
           f"-d:isonimTuiGrammarArchive={archive}",
           *link_flags(),
           "--nimcache:build/nimcache/codetracer-tui",
           "-o:build/bin/codetracer-tui",
           "src/frontend/tui/main.nim"]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                          errors="replace", timeout=3600)
    if proc.returncode != 0:
        print("      ---- the product did not build ----")
        for line in (proc.stdout + proc.stderr).splitlines()[-20:]:
            print("      " + line)
    return proc.returncode == 0


def run_suite(suite: str) -> RunResult:
    archive = ROOT / "build" / "grammars" / "libcodetracer_tui_grammars.a"
    tier2 = suite in TIER2
    if tier2 and not rebuild_product():
        # A child that did not build is NOT a kill. It is the third verdict.
        return RunResult(rc=1, ran=False)
    stem = Path(suite).stem
    cmd = ["nim", "c", "-r", "--hints:off", "--path:src/frontend/viewmodel",
           f"-d:isonimTuiGrammarArchive={archive}",
           *link_flags(),
           *(TIER2_PATHS if tier2 else []),
           f"--nimcache:build/nimcache/plat16-mutations-{stem}",
           f"-o:/tmp/plat16-mutation-{stem}", suite]
    # `errors="replace"`, NOT the default strict decode: a mutated suite prints
    # painted rows, which carry U+2500 and can be sliced mid-rune, and a
    # `UnicodeDecodeError` would end the arm in a Python traceback rather than
    # in one of this file's five verdicts.
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                          errors="replace", timeout=3600)
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode)
    # EVERYTHING SINCE THE LAST RESULT LINE BELONGS TO THE NEXT ONE.
    # `unittest` prints a failing `check`'s location, its rendered condition and
    # its operands BEFORE the `[FAILED] <name>` line that closes the case, so a
    # case's failure text is the run of lines preceding its verdict.
    pending = []
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
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
    if res.total == 0:
        res.ran = False
        print("      ---- no result lines; last 20 lines of output ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)
    return res


def main() -> int:
    # ---- THE LOCK, FIRST, BEFORE ANY DIGEST IS READ --------------------
    lock = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(f"another run holds {LOCK_PATH}; refusing to interleave "
              "mutations with it")
        return 3

    argv = sys.argv[1:]
    # `--collect-because` DERIVES what would otherwise be typed. It runs every
    # selected kill arm and prints the `Check failed:` line its killer case
    # actually produced, ready to paste into the arm's `because`. §17a's second
    # rule, applied to itself: the harness that needs the string is the one
    # that can produce it.
    collecting = "--collect-because" in argv
    only = {a for a in argv if not a.startswith("--")}
    arms = [m for m in MUTATIONS + DECLARED_SURVIVORS
            if not only or m.id in only]
    if collecting:
        arms = [m for m in arms if m in MUTATIONS]
    if not arms:
        print(f"no arm matches {sorted(only)}")
        return 1

    # ---- EVERY KILL ARM HAS A NAMED CONTROL ----------------------------
    uncontrolled = [m.id for m in MUTATIONS if m.id not in CONTROL_PAIRS]
    if uncontrolled:
        print(f"KILL ARMS WITH NO NAMED CONTROL: {uncontrolled}")
        return 1
    survivor_ids = {m.id for m in DECLARED_SURVIVORS}
    dangling = sorted(set(CONTROL_PAIRS.values()) - survivor_ids)
    if dangling:
        print(f"CONTROL_PAIRS names survivors that do not exist: {dangling}")
        return 1

    # ---- THE NEEDLE SCAN GATES THE BASELINE ----------------------------
    # Over EVERY arm, not only the selected ones: a needle that stopped
    # resolving in an arm this run happens not to have selected is still a
    # subject that moved, and recording a baseline over it would make the next
    # unfiltered run compare against a tree whose arms aim at nothing.
    bad = []
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        text = (ROOT / mut.path).read_text()
        n = text.count(mut.find)
        if n != 1:
            bad.append(f"{mut.id}: pattern occurs {n} times in {mut.path}")
    if bad:
        print("NEEDLE SCAN FAILED — nothing was recorded and nothing was run:")
        for line in bad:
            print("  " + line)
        print("Re-point the arm at the moved subject and re-run it. Do NOT "
              "re-record digests over a tree whose arms no longer aim at "
              "anything (Verification-Harness-Traps §32a).")
        return 1

    baseline = {p: digest(p) for p in TOUCHED}

    suites = []
    for m in arms:
        if m.suite not in suites:
            suites.append(m.suite)

    print("== control ==")
    for suite in suites:
        control = run_suite(suite)
        if control.failed or not control.ran:
            print(f"CONTROL IS NOT GREEN for {suite}: rc={control.rc} "
                  f"failed={control.failed}")
            return 1
        named = SUITE_CASES[suite]
        missing = [c for c in named if c not in control.passed]
        if missing:
            print(f"CONTROL DID NOT RUN {len(missing)} NAMED CASES in "
                  f"{suite}: {missing}")
            return 1
        print(f"control {Path(suite).stem}: {control.total} cases, all "
              f"{len(named)} named ones ran, 0 failures", flush=True)
    print(flush=True)

    problems = 0
    collected = {}
    for mut in arms:
        path = ROOT / mut.path
        original = path.read_text()
        if original.count(mut.find) != 1:
            print(f"{mut.id:<5} HARNESS-FAILURE      the needle stopped "
                  f"resolving mid-run in {mut.path}")
            return 2
        path.write_text(original.replace(mut.find, mut.replace))
        try:
            res = run_suite(mut.suite)
        finally:
            path.write_text(original)
            # PER ARM, not once at the end: an arm that left a file dirty must
            # be named, and every verdict after it is otherwise suspect.
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{mut.id:<5} HARNESS-FAILURE      {p} did not "
                          f"restore to its control bytes")
                    return 2
        declared = mut in DECLARED_SURVIVORS
        if not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif declared and res.failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"now killed by {res.failed}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", mut.why
        elif mut.killer not in res.passed and mut.killer not in res.failed:
            # THE KILLER CASE PRODUCED NO VERDICT AT ALL, which is neither a
            # survival nor a kill: the mutant DIED INSIDE IT, before `unittest`
            # printed its result line. Added by PLAT-16's landing pass after
            # M32 was scored `SURVIVED` over a mutation that had actually taken
            # the process down — `ck not buf.isNil` reported correctly and the
            # next line dereferenced the nil.
            #
            # This is trap §1a arriving from the other side: that entry is
            # about a mutant that hangs and prints no summary, and this is one
            # that crashes and prints no summary. Both are states an
            # `[OK]`/`[FAILED]` parser silently folds into "nothing noticed",
            # which is the most expensive possible mislabel — it reads as a gap
            # in the SUITE when it is a gap in the HARNESS's evidence.
            #
            # **The remedy is in the CASE, not here**: an assertion sequence
            # must not be able to crash the binary, so a `ck` that could
            # dereference a value a mutation can null needs a nil-safe accessor
            # (see `test_edit_mode_source.pathOf`). This verdict exists to make
            # that visible the first time rather than after an afternoon spent
            # asking why a correct arm reports a survival.
            verdict = "NO-VERDICT-FOR-KILLER"
            note = (f"{mut.killer[:40]!r} reported neither [OK] nor [FAILED]: "
                    f"the mutant died inside it. {len(res.failed)} other "
                    "case(s) failed")
            problems += 1
        elif not res.failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif mut.killer in res.failed:
            broke = [c for c in mut.spares if c in res.failed]
            text = res.failure_text.get(mut.killer, "")
            if collecting:
                verdict = "collected"
                note = derived_because(text) or "(no failure text at all)"
                if mut.id not in ("",) and note != "(no failure text at all)":
                    collected[mut.id] = note
            elif broke:
                verdict = "SPARED-CASE-DIED"
                note = f"{broke} should have stayed green under {mut.id}"
                problems += 1
            elif not BECAUSE.get(mut.id, ""):
                # NOT A KILL, and not a problem either: it is an arm that has
                # not been attributed yet. Named so it cannot be read as one.
                verdict = "killed (UNATTRIBUTED)"
                note = (mut.killer[:40] +
                        "  — no `because`; run --collect-because")
                problems += 1
            elif BECAUSE[mut.id] not in text:
                # §17's fourth verdict. The case died; it did not die here.
                verdict = "MIS-ATTRIBUTED"
                note = (f"{BECAUSE[mut.id]!r} not in the failure text; it said: " +
                        derived_because(text))
                problems += 1
            else:
                others = [f for f in res.failed if f != mut.killer]
                verdict = "killed"
                note = (mut.killer[:52] +
                        (f"  (+{len(others)} more)" if others else "") +
                        f"  [control {CONTROL_PAIRS.get(mut.id, '-')}]")
        else:
            verdict = "MISDIRECTED"
            note = f"died in {res.failed}, not {mut.killer!r}"
            problems += 1
        print(f"{mut.id:<5} {Path(mut.suite).stem[:32]:<32} {verdict:<20} "
              f"{note}", flush=True)

    if collecting:
        print("\n# paste into BECAUSE, above RESULT_LINE:")
        for mid, text in collected.items():
            print(f"    {mid!r}: {text!r},")
    print(f"\n{len(arms)} arms, {problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
