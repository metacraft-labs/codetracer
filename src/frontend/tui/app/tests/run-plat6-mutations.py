#!/usr/bin/env python3
"""Mutation harness for PLAT-6's terminal layout binding.

Every case in PLAT-6's four suites claims to detect something. This script
proves it, one case at a time: it patches a single line of the SUBJECT
(`app/layout/binding.nim`, `app/layout/tab_strip.nim`, `app/input/mouse.nim`,
`app/runtime.nim`, or `headless_app/layout_model.nim` where the property is one
PLAT-4 owns and this binding depends on) and requires that the **named** case
fails. A mutation killed only by some other case is MISDIRECTED and is a
failure of this harness, not a pass.

EIGHT SUITES, TWO TIERS. Each arm names the suite it is graded against:

  test_layout_binding.nim          Tier 1 — the binding itself
  test_layout_command_routing.nim  Tier 1 — the opt-in, the `:` routing and
                                            the MOUSE routing
  test_layout_persistence.nim      Tier 1 — the layout DOCUMENT: its key, its
                                            failure arms and its persist plan
  test_layout_persistence_matrix.nim
                                   Tier 1 — the persistence DECISION,
                                            ENUMERATED: 96 session cells, 6
                                            plan cells, 13 failure kinds and
                                            the 2 arms that answer `lpoFailed`,
                                            every one of them asserted at the
                                            FILE rather than at the report
  test_real_layout_gestures.nim    Tier 2 — a KEYBOARD gesture through a pty
  test_real_layout_transients.nim  Tier 2 — cross-tier snapshot equivalence
  test_real_layout_mouse.nim       Tier 2 — a MOUSE gesture through a pty
  test_real_layout_persistence.nim Tier 2 — an arrangement surviving a RESTART:
                                            two processes, one recording

The Tier-2 arms are slow — a suite compile, a CHILD compile and a handful of
pty round trips apiece — and they are here anyway, because the two rows PLAT-6
landed unticked are exactly the two those suites close, and an arm that only
runs the Tier-1 suite cannot say whether either has teeth. M29 and M29B are the
SAME mutation graded at the two tiers, which is what makes the pty case
load-bearing rather than a slow restatement of the Tier-1 one.

AN ARM MAY ALSO NAME CASES THAT MUST STAY GREEN (`spares`). M31 is the reason:
it makes the painter use one glyph for every decoration, both tiers therefore
paint the same wrong screen, and the claim being demonstrated is that the
cell-for-cell equality CANNOT see that while the absolute check can. A spared
case that dies is reported as a problem, because the claim rather than the
subject would then be wrong.

THREE VERDICTS, NOT TWO (Verification-Harness-Traps §1). An arm that never ran
is not a kill:

  killed          the named case reported [FAILED]
  SURVIVED        the run produced result lines and the named case was [OK]
  HARNESS-FAILURE the mutation did not apply, did not compile, or the run
                  produced NO result lines at all

The last verdict is the one this file exists to keep distinct. A run that
prints nothing looks exactly like a run in which every case passed if the only
signal read is an exit status, and reporting it as "killed" credits an arm that
was never executed. **Verdicts are parsed from `[OK]` / `[FAILED]` lines and
never from an exit status**, because a compile error also exits non-zero.

DECLARED SURVIVORS ARE A DELIVERABLE, AND EVERY KILL ARM ADDED SINCE M30 NAMES
ITS OWN. A harness that kills everything says as little as one that kills
nothing, so the arms at the bottom are behaviour-preserving rewrites that MUST
survive; an arm that starts being killed is reported as a problem in its own
right. The pairing is written at both ends: M5/M26 ← S3, M30 ← S9, M33/M33B ← S5,
M34 ← S6, M35 and M31 ← S8, M36 ← S7, M37 ← S10, M38/M38B ← S11, M39 ← S12,
M40 ← S13, M41 ← S14, M42 ← S15, M43 ← S16, M44 ← S17, M45 ← S18,
M46/M47 ← S19, M48 ← S20, M49 ← S21, M51 ← S24, M52 ← S22, M55 ← S23,
M56 ← S25, M57 ← S26, M58 ← S27, M59 ← S28. Without the control, "the case
reddens when this line changes" is all an arm establishes.

S9 is here because M30 shipped WITHOUT a control and an independent pass had to
write one by hand, off the record. An arm that lives only in somebody's terminal
is not part of the harness, so it is spelled out below.

M45 ← S18 had the same provenance as M37 ← S10: a verification pass found a real
defect that SURVIVED the whole harness, because the property it breaks — "a
document that would not open is left alone" — was not named by any suite. Both
arms exist because the code was right and nothing measured it, which is the
failure mode this file is least able to report on its own: an arm nobody wrote
cannot be a survivor.

**M46 IS THE THIRD INSTANCE OF THAT SHAPE, AND IT IS WHY THE MATRIX SUITE
EXISTS.** Weakening `layoutPersistPlan`'s first branch to
`quarantined and (b.isNil or not b.userModified)` survived all 66 arms this file
carried, and its measured consequence is a `version: 99` document REPLACED on
disk by a `version: 2` one — permanent loss, because the user opened an older
build once and then moved a pane. Three findings in a row arriving the same way
is a class rather than three bugs, so the answer was not a fourth hand-picked
arm: `test_layout_persistence_matrix.nim` enumerates the decision's whole input
space as data and asserts every cell, and M46 … M57 are the arms that say the
enumeration has teeth. Each names ONE lane of that table, which is what the
table's lane column is for.

**M58 IS THE FOURTH INSTANCE, AND IT SURVIVED THE TABLE.** The table enumerates
the DECISION; the rename is not a decision, it is how the decision reaches the
disk, and `host/layout_store.nim`'s header had promised it since the module was
written with nothing asserting it. Collapsing the staged write to a direct one
left all four Tier-1 suites at 0 failed, and no arm among the 83 this file
carried touched `moveFile` — the suites' only mentions of `.new` were negative,
which is trap §4a exactly. M58 and M59 are the two `except` arms of
`persistLayoutForSession`, previously declared unreachable in three headers and
reached here on an ordinary `createTempDir()`.

`test_layout_binding.nim`'s last case asserts a RUNTIME ASSERTION COUNT, so an
arm that changes how many `ck`s run reddens that case as well as its own. That
is expected and is reported as `(+N more)`; what is not tolerated is an arm
whose named case stays green.

RESTORATION IS FROM AN IN-MEMORY SNAPSHOT, never from `git checkout --`: the
original bytes are read before the mutation and written back after it, and the
SHA-256 of every touched file is compared against the control hash before the
next arm starts. The run aborts on a mismatch rather than continuing on a dirty
tree.

Usage (from the `codetracer` repository root):
  direnv exec . python3 src/frontend/tui/app/tests/run-plat6-mutations.py
"""

import hashlib
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]

SUITE = "src/frontend/tui/app/tests/test_layout_binding.nim"
ROUTE = "src/frontend/tui/app/tests/test_layout_command_routing.nim"
PERSIST = "src/frontend/tui/tests/test_layout_persistence.nim"
MATRIX = "src/frontend/tui/tests/test_layout_persistence_matrix.nim"
GEST = "src/frontend/tui/tests/real_terminal/test_real_layout_gestures.nim"
TRANS = "src/frontend/tui/tests/real_terminal/test_real_layout_transients.nim"
MOUSE_SUITE = "src/frontend/tui/tests/real_terminal/test_real_layout_mouse.nim"
RELAUNCH = ("src/frontend/tui/tests/real_terminal/"
            "test_real_layout_persistence.nim")

BIND = "src/frontend/tui/app/layout/binding.nim"
TABS = "src/frontend/tui/app/layout/tab_strip.nim"
DOC = "src/frontend/tui/app/layout/persistence.nim"
MOUSE = "src/frontend/tui/app/input/mouse.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
STORE = "src/frontend/tui/host/layout_store.nim"
INTER = "src/frontend/headless_app/layout_interaction.nim"
MODEL = "src/frontend/headless_app/layout_model.nim"

# THE HARNESS'S OWN INSTRUMENTS, held to the same restoration check as the
# subject (Verification-Harness-Traps §7: an instrument is the last thing anyone
# re-reads, and a defect there is a wrong answer with a green tick next to it).
#
# `dual_snap.nim` is the one that made this necessary and it is not a
# hypothetical. It decides whether a Tier-2 arm is graded against a FRESHLY
# BUILT child: `newestSourceTime` stamps the app source, `test_app_runtime.nim`,
# `app/` and `host/`, and `compileChildApp` rebuilds only when the binary is
# older than that stamp. PLAT-6's verification reverted the stamp to its
# `app/`-only form and re-ran M38B — a real defect in `host/layout_store.nim`,
# graded at Tier 2 — and it **SURVIVED**, because the child was never rebuilt
# and a stale binary graded as a passing one. That is a false GREEN produced by
# an edit to a file the per-arm SHA-256 check did not cover, so the file that
# decides whether a grade is real is now covered by it.
#
# The same argument reaches three more files, and they are here for it rather
# than for tidiness — each is compiled INTO the child binary a Tier-2 arm is
# graded by, so an edit left behind in one of them mis-grades every arm after
# it exactly as a `dual_snap` edit would:
DUAL = "src/frontend/tui/testing/dual_snap.nim"
APPRT = "src/frontend/tui/testing/test_app_runtime.nim"
APP_GEST = "src/frontend/tui/tests/apps/app_layout_gestures.nim"
APP_MOUSE = "src/frontend/tui/tests/apps/app_layout_mouse.nim"
APP_PERSIST = "src/frontend/tui/tests/apps/app_layout_persist.nim"
APP_TRANS = "src/frontend/tui/tests/apps/app_layout_transients.nim"

HARNESS = [DUAL, APPRT, APP_GEST, APP_MOUSE, APP_PERSIST, APP_TRANS]

# WHAT IS STILL OUTSIDE THIS LIST, said rather than left to be found — the
# subject of a check is a claim (Verification-Harness-Traps §6), and this one's
# claim is "every SOURCE FILE OF THIS REPOSITORY that an arm's verdict depends
# on". Three things are outside it, each for a different reason:
#
#   * THE BUILT ARTEFACTS. `build/nimcache/plat6-mutations-*`,
#     `/tmp/plat6-mutation-*`, and the Tier-2 child binaries `dual_snap` builds.
#     A hash over a build output would move on every arm by construction and
#     would report nothing. What makes them safe is `dual_snap`'s own staleness
#     stamp — which is exactly why that file had to come inside this list first,
#     and the one place a defect here has already produced a false GREEN.
#   * `build/grammars/`, read by `link_flags()` and by the archive path below.
#     Also a build output, and produced by `scripts/build-tui-grammars.sh`
#     rather than by anything an arm touches.
#   * THE SIBLING REPOSITORIES. The four Tier-2 suites import `term_assert`,
#     which `TIER2_PATHS` resolves into `../TermAssert/`, `../TermAssertClient/`
#     and `../nim-libvterm/`. Those are separate checkouts with their own
#     history, and a per-arm hash here could notice a change but could not
#     restore one, so this file does not claim them. A harness's bug report
#     arrives disguised as your own code failing (§9-11); if a Tier-2 arm starts
#     behaving oddly with no local edit to explain it, those three are where to
#     look.
TOUCHED = [SUITE, ROUTE, PERSIST, MATRIX, GEST, TRANS, MOUSE_SUITE, RELAUNCH,
           BIND, TABS, DOC, MOUSE, RUNTIME, STORE, INTER, MODEL] + HARNESS

# THE TWO TIER-2 SUITES NEED THREE MORE `--path`s and they spawn a child in a
# real pty, so an arm against one costs a compile, a CHILD compile and a
# handful of pty round trips. They are here anyway, and for the reason the
# milestone gives: the rows PLAT-6 left open were "a gesture through a real
# pty" and "cross-tier snapshot equivalence", and an arm that only ever runs
# the Tier-1 suite cannot say whether either of those checks has teeth.
TIER2 = {GEST, TRANS, MOUSE_SUITE, RELAUNCH}
TIER2_PATHS = ["--path:../TermAssert/src", "--path:../TermAssertClient/src",
               "--path:../nim-libvterm/src"]

# The case names, spelled once. A typo here shows up as "the control did not
# run this case" rather than as a silently unkillable arm.
C_ZONES = ("the hit-test partitions the body: every cell resolves to exactly "
           "one zone")
C_ROUND = "cells -> pointer -> region -> cells is a round trip"
C_STRIP = "the painted tab strip and the hit-test agree, column by column"
C_KINDS = "every drop-target kind is reachable THROUGH the binding"
C_COLLAPSE = "the collapse rules fire through the binding, not only through apply"
C_DOCK = "a docked pane round-trips: dock, render, save, restore, undock"
C_GATE = "PLAT-4's handed-forward gate: a command sweep, then a PROJECTION"
C_DRAW = "the drag ghost, the drop target and the resize guide are on the screen"
C_CANCEL = "a cancelled gesture leaves the committed layout byte-identical"
C_KEYS = "every keyboard gesture has a spelling, and none of them is silent"
C_SGR = "SGR-1006 bytes drive a layout gesture end to end"
C_PROFILE = "a user-modified layout survives a resize; an untouched one re-flows"
C_NOREF = "the binding holds no LayoutNode reference, structurally"
C_COUNT = "assertion count"

PLAT6_CASES = [
    C_ZONES, C_ROUND, C_STRIP, C_KINDS, C_COLLAPSE, C_DOCK, C_GATE, C_DRAW,
    C_CANCEL, C_KEYS, C_SGR, C_PROFILE, C_NOREF, C_COUNT,
]

# The routing suite (Tier 1) — the opt-in and the `:` prompt's layout verbs.
R_OFF = ("OFF BY DEFAULT: a layout verb is the unknown \u00a74.3 command it "
         "always was")
R_SAME = "enabling it changes NOTHING on screen, compared as rendered rows"
R_DOCK = "`:dock bottom` typed at the prompt docks the FOCUSED pane, and shows it"
R_FOCUS = "the pane a verb acts on is the one Tab moved to"
R_SPEC43 = "\u00a74.3 is untouched: its own commands still reach the interpreter"
R_VERBS = "every verb is reachable from the prompt, and none of them is silent"
R_RESIZE = "a resize re-flows an untouched arrangement and leaves a gestured one"

# The MOUSE half of the routing suite, added when `handleToken` started routing
# mouse reports into the binding — the row PLAT-6 stayed `partial` for a second
# time.
R_MOUSEOFF = "OFF BY DEFAULT: a mouse report is the inert token it always was"
R_MOUSEDRAG = "a mouse DRAG docks the pane it picked up, through handleToken"
R_MOUSEFOCUS = "a mouse press moves the focus RING, not only the binding's focus"
R_CLICKWHEEL = ("a click activates a tab and a wheel scrolls the strip, "
                "through handleToken")
R_PROMPT = "a mouse report does not disturb an open prompt"
R_EDGES = "which dock edges a real drag can reach, measured rather than argued"

# THE PROPERTY THE MOUSE PATH HAD AND NOBODY MEASURED. PLAT-6's verification of
# the mouse pass found by mutation that deleting `rt.rebuildFocus()` from
# `routeMouseReport` SURVIVED — the ring was left holding a pane a drop had just
# docked away, so `Tab` would offer a pane that is not on screen. M34 deletes
# the return leg on the line below it and nothing covered the rebuild. M37 is
# the arm; this is the case that kills it.
R_MOUSERING = ("a mouse DROP rebuilds the focus ring, so Tab cannot offer a "
               "docked pane")

ROUTE_CASES = [R_OFF, R_SAME, R_DOCK, R_FOCUS, R_SPEC43, R_VERBS, R_RESIZE,
               R_MOUSEOFF, R_MOUSEDRAG, R_MOUSEFOCUS, R_MOUSERING,
               R_CLICKWHEEL, R_PROMPT, R_EDGES, C_COUNT]

# The persistence suite (Tier 1) — the layout DOCUMENT.
P_KEY = ("the document is keyed by the recording, so two recordings never "
         "share one")
P_TRIP = "a docked pane survives a restart, through the product's own `:` prompt"
P_FREEZE = "a restored arrangement freezes the responsive profile"
P_BAD = "an unreadable document is reported BY KIND and is never overwritten"
P_RESET = "no gesture, no document — and `:reset-layout` deletes a stale one"
P_OFF = ("OFF BY DEFAULT: with no binding nothing is read and nothing is "
         "written")

# THE PROPERTY GUARDING THE USER'S FILE ON THE ONE PATH `adoptLayoutDocument`
# CANNOT REACH. Every other unreadable arm sets the quarantine flag inside
# `adoptLayoutDocument`; a file that will not OPEN never gets there, so
# `host/layout_store.nim` calls `runtime.markLayoutDocumentUnreadable` by hand
# and NOTHING else in the product calls it. PLAT-6's verification neutered that
# call and measured the consequence on a real file with its permissions
# removed: the user is still told, `quarantined` is false, the plan is `remove`
# and the exit DELETES the document. A transient `EACCES` therefore costs a
# user their arrangement permanently. M45 is the arm; this is the case that
# kills it.
P_EACCES = ("a document that will not OPEN is quarantined and survives "
            "byte-identical")

PERSIST_CASES = [P_KEY, P_TRIP, P_FREEZE, P_BAD, P_EACCES, P_RESET, P_OFF,
                 C_COUNT]

# THE MATRIX SUITE (Tier 1) — the persistence decision, ENUMERATED.
#
# Each case owns one LANE of `SessionMatrix`, plus the two side tables. The
# lanes are carried as a column of the table rather than derived from the row
# key precisely so an arm can name exactly one of them: a partition that drifted
# would move a kill into a case that does not name it, and this harness reports
# that as MISDIRECTED rather than as a pass.
X_SPACE = ("the input space: three dimensions, 96 cells, every triple exactly "
           "once")
X_OFF = "OFF: with no layout binding, all 32 cells are inert and no file moves"
X_UNNAMED = ("BOUND BUT UNNAMED: a rearrangeable session with no document "
             "writes nowhere")
X_ABSENT = "ABSENT: a first run restores nothing and leaves nothing behind"
X_READABLE = ("READABLE: a document this build understands is rewritten, or "
              "deleted by a reset")

# **THE TWO CELLS THE PRECEDENCE RESTS ON.** `quarantined` and `userModified`
# disagree in both of them, and each is broken by a different edit:
#
#   X_PRECMOD    quarantined AND userModified — broken by WEAKENING the first
#                branch (M46). The document is REPLACED.
#   X_PRECUNMOD  quarantined and NOT userModified — broken by REORDERING the
#                two branches (M47). The document is DELETED.
#
# One of them alone establishes the precedence for one half of the
# disagreement, which is how the weakening survived 66 arms.
X_PRECMOD = ("PRECEDENCE: a session that REARRANGED over an unreadable "
             "document leaves it alone")
X_PRECUNMOD = ("PRECEDENCE: a session that did NOT rearrange over an "
               "unreadable document leaves it alone")
X_EACCES = ("EACCES: a document that will not OPEN is left alone, whatever "
            "the session did")

# THE TWO ARMS THAT ANSWER `lpoFailed`, AND THE DURABILITY PROMISE.
#
# `X_DURABILITY` does two jobs with one probe, which is why the arm that breaks
# the staging is killed by a case about a FAILURE. `host/layout_store.nim`
# promises the document is written to `<path>.new` and MOVED onto `<path>`;
# nothing asserted it, and collapsing the two lines to a bare
# `writeFile(path, plan.text)` left all four suites at 0 failed while no arm in
# this file touched `moveFile`. The only `.new` mentions in either suite were
# NEGATIVE — "a stray `.new` would mean the rename did not happen" — which is
# Verification-Harness-Traps §4a: a lone negative with no positive twin has
# nothing to fail. The case puts a DIRECTORY where the staging file must go, so
# the write cannot happen at all and the report names `<path>.new`; with the
# collapse planted the same probe SUCCEEDS and the case reddens. M58 is the
# arm, S27 its control.
X_DURABILITY = ("DURABILITY: the write is STAGED at `<path>.new` and renamed "
                "onto the document")
X_FAILREMOVE = ("FAILED: a remove the filesystem refuses is reported, and the "
                "document stays")
X_PLAN = ("the plan table: six cells, four reachable and two a session cannot "
          "present")
X_KINDS = ("the failure-kind table: thirteen kinds, eleven produced and two "
           "unreachable")
X_CELLS = "cell count"

MATRIX_CASES = [X_SPACE, X_OFF, X_UNNAMED, X_ABSENT, X_READABLE, X_PRECMOD,
                X_PRECUNMOD, X_EACCES, X_DURABILITY, X_FAILREMOVE, X_PLAN,
                X_KINDS, X_CELLS, C_COUNT]

# The relaunch suite (Tier 2) — two processes, one recording.
L_RELAUNCH = "a pane docked on a real pty is still docked in the NEXT process"
L_BAD = "an unreadable document is NAMED on the status row and left alone"
L_OFF = "OFF: with no binding the child neither reads nor writes a document"

RELAUNCH_CASES = [L_RELAUNCH, L_BAD, L_OFF, C_COUNT]

# The gesture suite (Tier 2) — a real pty.
G_DOCK = "`:dock bottom` typed as real bytes rearranges a real terminal"
G_SPEC43 = ("a word that is not a layout verb still reaches \u00a74.3, on the "
            "terminal")

GEST_CASES = [G_DOCK, G_SPEC43, C_COUNT]

# The transient-state suite (Tier 2) — the cross-tier comparison and, beside
# it, the absolute check that survives both tiers being wrong together.
T_EQUAL = "every transient state is the same screen in both tiers, cell for cell"
T_MODEL = "the decorations are what the MODEL says, on the real terminal"
T_ARM = "MUTATION ARM: a changed cell fails the comparison and names it"

TRANS_CASES = [T_EQUAL, T_MODEL, T_ARM, C_COUNT]

# The mouse suite (Tier 2) — a real drag on a real pty, and beside it the
# absolute probe that survives both tiers being wrong together.
M_DRAG = "a mouse DRAG typed as real bytes docks a pane on a real terminal"
M_MODEL = "the decorations a mouse gesture draws are what the MODEL says"
M_BYTES = "the bytes this file writes are the bytes the harness writes"

MOUSE_CASES = [M_DRAG, M_MODEL, M_BYTES, C_COUNT]

SUITE_CASES = {
    SUITE: PLAT6_CASES,
    ROUTE: ROUTE_CASES,
    PERSIST: PERSIST_CASES,
    MATRIX: MATRIX_CASES,
    GEST: GEST_CASES,
    TRANS: TRANS_CASES,
    MOUSE_SUITE: MOUSE_CASES,
    RELAUNCH: RELAUNCH_CASES,
}


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""
    suite: str = SUITE
    # Cases that must stay GREEN under this arm. An arm whose whole point is
    # that one check sees a defect another cannot has to say so mechanically,
    # or the claim is a sentence in a comment — see M31.
    spares: tuple = ()


MUTATIONS = [
    # --- the hit-test is total, and every zone is reachable ----------------
    Mutation(
        "M1", BIND,
        '    return some(LayoutPointer(path: "", zone: zone))',
        "    return none(LayoutPointer)",
        C_ZONES,
        "a cell on a dock strip resolves to nothing",
    ),
    Mutation(
        "M2", BIND,
        "  if dt < bandV and dt < best:\n"
        "    best = dt\n"
        "    zone = dzTopEdge",
        "  if false:\n"
        "    best = dt\n"
        "    zone = dzTopEdge",
        C_ZONES,
        "the top edge band is unreachable, so dzTopEdge is never produced",
    ),
    # --- the two directions of the hit-test are one table ------------------
    Mutation(
        "M3", BIND,
        "  of drNodeStrip:\n"
        "    stripOf(geom.dropAreaOfPath(region.path), region.side)",
        "  of drNodeStrip:\n"
        "    stripOf(geom.boundsOfPath(region.path), region.side)",
        C_ROUND,
        "the inverse direction stops excluding the tab strip; the forward one "
        "still does",
    ),
    Mutation(
        "M4", BIND,
        "  of leRight:\n"
        "    let w = edgeBandCells(area.width)\n"
        "    CellArea(col: area.col + area.width - w, row: area.row, width: w,\n"
        "             height: area.height)",
        "  of leRight:\n"
        "    let w = edgeBandCells(area.width)\n"
        "    CellArea(col: area.col, row: area.row, width: w,\n"
        "             height: area.height)",
        C_ROUND,
        "the right-hand strip is drawn on the left",
    ),
    # --- the painter and the hit-test read one tab-strip answer ------------
    #
    # `tabRow` NOW ASSEMBLES THE ROW FROM `tabSpans`, so these two arms are not
    # the two the milestone landed with. The differential check — every column
    # of a painted strip against the hit-test — can only see a painter that has
    # STOPPED following the table (M5); a defect in the table itself moves both
    # readers together and is invisible to it, which is what M26 demonstrates
    # and what the case's absolute oracle is for.
    Mutation(
        "M5", TABS,
        "  for span in tabSpans(tabs, active):\n"
        "    while cursor < span.startCol:\n"
        "      line.add ' '\n"
        "      inc cursor\n"
        "    line.add tabLabel(tabs[span.index], span.index == active)\n"
        "    cursor = span.startCol + span.width",
        "  for span in tabSpans(tabs, active):\n"
        "    if span.index > 0:\n"
        "      line.add \"  \"\n"
        "    line.add tabLabel(tabs[span.index], span.index == active)\n"
        "    cursor = span.startCol + span.width",
        C_STRIP,
        "the painter stops reading the span table and gives itself a gap "
        "again — the exact defect making the assembly structural removes",
    ),
    Mutation(
        "M6", TABS,
        "    line.add tabLabel(tabs[span.index], span.index == active)",
        "    line.add tabLabel(tabs[span.index], false)",
        C_STRIP,
        "the active tab is painted without its brackets",
    ),
    Mutation(
        "M26", TABS,
        "  TabGapCells* = 1",
        "  TabGapCells* = 2",
        C_STRIP,
        "THE SHARED TABLE IS WRONG. Painter and hit-test move together, so the "
        "column-by-column agreement stays green; only the absolute oracle "
        "(\u00a73.1's rule, restated in the suite) sees it",
    ),
    # --- the strips tile the body, with a control of their own -------------
    Mutation(
        "M27", BIND,
        "  of leTop:\n"
        "    CellArea(col: body.col + left, row: body.row,\n"
        "             width: body.width - left - right, height: DockStripThickness)",
        "  of leTop:\n"
        "    CellArea(col: body.col, row: body.row,\n"
        "             width: body.width, height: DockStripThickness)",
        C_ZONES,
        "the top strip claims the columns the left and right strips already "
        "have, so the body is double-claimed",
    ),
    # --- the caret lands inside the tab it names ---------------------------
    Mutation(
        "M28", BIND,
        "    let caret = tabSlotCaret(strip.tabs, strip.active, region.slot)",
        "    let caret = tabSlotCaret(strip.tabs, strip.active, region.slot + 1)",
        C_ROUND,
        "the drop caret is drawn one slot to the right. THE CHECK PLAT-6 "
        "LANDED COULD NOT SEE THIS: a caret one tab over is still on the "
        "strip's row and inside its columns, which is all that arm asserted",
    ),
    # --- every drop-target kind, through the binding -----------------------
    Mutation(
        "M7", BIND,
        "    let sameCell = event.row == b.pressRow and event.col == b.pressCol",
        "    let sameCell = true",
        C_KINDS,
        "every release is treated as a click, so no drop ever commits",
    ),
    Mutation(
        "M8", BIND,
        "      if region.activeTab < 0 and event.row == region.area.row:",
        "      if false and event.row == region.area.row:",
        C_KINDS,
        "a pane with no tab strip can no longer be picked up at all",
    ),
    # --- the collapse rules, reached BY A GESTURE --------------------------
    Mutation(
        "M9", MODEL,
        "  if node.kind == lnStack:\n"
        "    # A stack with one tab is an ordinary arrangement, not a hole: rule 1 does\n"
        "    # not apply to it. Collapsing it would delete the tab strip the user is\n"
        "    # about to drop a second tab onto.\n"
        "    if node.activeIndex < 0:",
        "  if node.kind == lnStack and kept.len > 1:\n"
        "    if node.activeIndex < 0:",
        C_COLLAPSE,
        "§2.4 rule 1's STACK EXEMPTION is removed, so a one-tab stack collapses",
    ),
    Mutation(
        "M10", MODEL,
        "  if kept.len == 0:\n"
        "    return false                                  # rule 2: emptied, drop me",
        "  if kept.len == 0:\n"
        "    return true",
        C_COLLAPSE,
        "rule 2 stops removing an emptied container",
    ),
    # --- the docked round trip ---------------------------------------------
    Mutation(
        "M11", BIND,
        "    let restored = restoreLayoutDocument(doc)\n"
        "    b.history = newLayoutHistory(restored)",
        "    let restored = restoreLayoutDocument(doc)\n"
        "    discard restored",
        C_DOCK,
        "a restore reports success without adopting anything",
    ),
    Mutation(
        "M12", BIND,
        "  saveLayout(b.layout)",
        "  saveLayout(b.layout.tree)",
        C_DOCK,
        "the save drops the docked panes, keeping only the tree",
    ),
    # --- PLAT-4's handed-forward projection-composition gate ---------------
    Mutation(
        "M13", BIND,
        "  result.projection = projectLayout(layout.tree, result.inner, policy)",
        "  result.projection = projectLayout(layout.tree, body, policy)",
        C_GATE,
        "the tree is projected over the whole body, so it overlaps the strips",
    ),
    Mutation(
        "M14", BIND,
        "  result.inner = CellArea(col: body.col + left, row: body.row + top,\n"
        "                          width: max(0, body.width - left - rightW),\n"
        "                          height: max(0, body.height - top - bottom))",
        "  result.inner = CellArea(col: body.col + left, row: body.row + top,\n"
        "                          width: max(0, body.width - left - rightW),\n"
        "                          height: max(0, body.height - top - bottom + 1))",
        C_GATE,
        "the inner area claims one row the bottom strip also claims",
    ),
    # --- drawing the transient state ---------------------------------------
    Mutation(
        "M15", BIND,
        "    if not ghost.isEmptyArea:\n"
        "      result.add LayoutDecoration(kind: ldDragGhost, area: ghost,",
        "    if false:\n"
        "      result.add LayoutDecoration(kind: ldDragGhost, area: ghost,",
        C_DRAW,
        "the drag ghost is never drawn",
    ),
    Mutation(
        "M16", BIND,
        "  if now.width != before.width:",
        "  if false:",
        C_DRAW,
        "a horizontal resize draws no guide",
    ),
    # --- a cancelled gesture cannot have changed the layout ----------------
    Mutation(
        "M17", BIND,
        "  b.interaction = b.interaction.cancel()\n"
        "  action(lasCancelled, \"gesture cancelled\")",
        "  discard b.dropDrag()\n"
        "  b.interaction = b.interaction.cancel()\n"
        "  action(lasCancelled, \"gesture cancelled\")",
        C_CANCEL,
        "cancelling commits the drag first",
    ),
    # --- the keyboard surface ----------------------------------------------
    Mutation(
        # THE FIRST SPELLING OF THIS ARM SURVIVED, AND IT WAS A NO-OP, NOT A
        # SURVIVING PROPERTY (Verification-Harness-Traps §1's sibling problem;
        # PLAT-5's audit hit the same shape). It changed only the `toEnd`
        # expression to `count`, and the very next line —
        # `if slot > count - 1: slot = count - 1` — clamped it straight back.
        # Re-run as a mutation that reaches the observable behaviour, it kills
        # its named case. An arm that cannot change the output is not evidence
        # about the suite.
        "M18", BIND,
        "  var slot =\n"
        "    if toEnd: (if delta < 0: 0 else: count - 1)\n"
        "    else: index + delta\n"
        "  if slot < 0: slot = 0\n"
        "  if slot > count - 1: slot = count - 1",
        "  var slot =\n"
        "    if toEnd: (if delta < 0: 0 else: count)\n"
        "    else: index + delta\n"
        "  if slot < 0: slot = 0\n"
        "  if slot > count: slot = count",
        C_KEYS,
        "the same-stack slot bound goes back to `count`, which lcMoveTab "
        "refuses — the real defect this arm was written from",
    ),
    Mutation(
        "M19", BIND,
        "    return action(lasUnknownCommand,\n"
        "                  \"'\" & words[0] & \"' is not a layout command\")",
        "    return action(lasUnknownCommand, \"\")",
        C_KEYS,
        "an unknown command reports nothing at all",
    ),
    # --- the mouse ----------------------------------------------------------
    Mutation(
        "M20", BIND,
        "    let delta = if event.button == mbWheelDown: 1 else: -1",
        "    let delta = if event.button == mbWheelDown: -1 else: 1",
        C_SGR,
        "the wheel scrolls the tab strip the wrong way",
    ),
    Mutation(
        "M21", MOUSE,
        "  event.row = row - 1\n"
        "  event.col = col - 1",
        "  event.row = row\n"
        "  event.col = col",
        C_SGR,
        "SGR's one-based wire coordinates are read as zero-based",
    ),
    # --- the responsive-profile decision -----------------------------------
    Mutation(
        "M22", BIND,
        "  if b.userModified:\n"
        "    return false\n"
        "  b.history = newLayoutHistory(initLayout(profileLayout(selected)))",
        "  b.history = newLayoutHistory(initLayout(profileLayout(selected)))",
        C_PROFILE,
        "a resize re-flows a layout the user has modified",
    ),
    Mutation(
        "M23", BIND,
        "  b.userModified = false\n"
        "  action(lasApplied, \"layout reset to the \" & $b.profile & \" profile\")",
        "  action(lasApplied, \"layout reset to the \" & $b.profile & \" profile\")",
        C_PROFILE,
        "`:reset-layout` does not un-freeze the profile",
    ),
    # --- the binding holds no node reference -------------------------------
    Mutation(
        "M24", BIND,
        "  let outcome = b.history.dispatch(cmd)",
        "  let outcome = b.history.dispatch(cmd)\n"
        "  discard nodeAtPath(b.history.value.tree, \"\")",
        C_NOREF,
        "the binding reaches for the ref-returning door",
    ),
    Mutation(
        "M25", INTER,
        "    activeIndex*: int\n"
        "      ## The stack's active child, or -1 for every other kind.",
        "    activeIndex*: int\n"
        "      ## The stack's active child, or -1 for every other kind.\n"
        "    node*: LayoutNode",
        C_NOREF,
        "NodeInfo grows a way back to the tree",
    ),
    # --- the opt-in and the routing (PLAT-6's follow-up) --------------------
    #
    # These are the arms for the two rows the milestone landed unticked. M29
    # and M29B are THE SAME MUTATION run against the two tiers, which is the
    # only way to say that the pty case is load-bearing rather than decorative:
    # if the Tier-1 routing case were the only killer, the Tier-2 one would be
    # a slow re-statement of it.
    Mutation(
        "M29", RUNTIME,
        "    if words.len > 0 and parseLayoutVerb(words[0])[0]:",
        "    if false and parseLayoutVerb(words[0])[0]:",
        R_DOCK,
        "the `:` prompt stops routing layout verbs into the binding",
        suite=ROUTE,
    ),
    Mutation(
        "M29B", RUNTIME,
        "    if words.len > 0 and parseLayoutVerb(words[0])[0]:",
        "    if false and parseLayoutVerb(words[0])[0]:",
        G_DOCK,
        "the same defect, seen from a REAL PTY: `:dock bottom` typed as bytes "
        "no longer rearranges the terminal",
        suite=GEST,
    ),
    Mutation(
        "M30", RUNTIME,
        "      let (had, focused) = rt.focus.focusedPane()\n"
        "      if had:\n"
        "        rt.app.layoutBinding.focus = focused",
        "      let (had, focused) = rt.focus.focusedPane()\n"
        "      if false and had:\n"
        "        rt.app.layoutBinding.focus = focused",
        R_FOCUS,
        "the binding's focus stops following `Tab`, so a verb acts on whatever "
        "pane the binding was constructed with",
        suite=ROUTE,
    ),
    Mutation(
        "M31", BIND,
        "    let glyph = glyphFor(d.kind)",
        "    let glyph = DockStripGlyph",
        T_MODEL,
        "THE ARM THE CROSS-TIER PAIR EXISTS FOR. Every decoration is painted "
        "with one glyph. Both tiers paint the same wrong screen, so the "
        "cell-for-cell equality is GREEN and only the absolute check — the "
        "model's own `decorationsFor` probed on the real terminal — dies",
        suite=TRANS,
        spares=(T_EQUAL,),
    ),
    Mutation(
        "M32", RUNTIME,
        "  if rt.layoutBindingEnabled():\n"
        "    discard rt.app.layoutBinding.resize(width, height)",
        "  if false:\n"
        "    discard rt.app.layoutBinding.resize(width, height)",
        R_RESIZE,
        "a real resize never reaches the binding, so the profile and the tree "
        "stay at the size the session started on",
        suite=ROUTE,
    ),
    # --- the MOUSE half of the routing (PLAT-6's second follow-up) ---------
    #
    # `binding.onMouse`, `beginDrag`, `hoverAt` and `dropDrag` had no caller
    # outside their own module and `test_layout_binding.nim`; `handleToken`
    # routed the twelve `:` verbs and no mouse report. These four arms grade
    # the wiring that closes that, and EVERY ONE OF THEM HAS A NAMED
    # BEHAVIOUR-PRESERVING CONTROL below — M33/M33B ← S5, M34 ← S6, M35 ← S8,
    # M36 ← S7 — so that "the case reddens when this neighbourhood is edited"
    # is excluded rather than assumed. M30 shipped without one and a verifier
    # had to add it.
    Mutation(
        "M33", RUNTIME,
        "    if isMouse:",
        "    if false:",
        R_MOUSEDRAG,
        "`handleToken` stops offering a decoded mouse report to the binding, "
        "which is the state PLAT-6 landed in",
        suite=ROUTE,
    ),
    Mutation(
        "M33B", RUNTIME,
        "    if isMouse:",
        "    if false:",
        M_DRAG,
        "the same defect, seen from a REAL PTY: a press and a release written "
        "as SGR-1006 bytes no longer rearrange the terminal. THE SAME "
        "MUTATION AS M33 AT THE OTHER TIER, which is what says the pty case "
        "is load-bearing rather than a slow restatement of the in-process one",
        suite=MOUSE_SUITE,
    ),
    Mutation(
        "M34", RUNTIME,
        "  discard rt.focus.focusPaneKind(binding.focus)",
        "  discard binding.focus",
        R_MOUSEFOCUS,
        "the RETURN LEG of the focus synchronisation goes. A mouse press moves "
        "the binding's focus and the ring never hears about it, so `Tab` "
        "continues from where the keyboard left off and a verb typed after a "
        "click acts on the wrong pane",
        suite=ROUTE,
    ),
    Mutation(
        "M35", BIND,
        "    let glyph = glyphFor(d.kind)",
        "    let glyph = DockStripGlyph",
        M_MODEL,
        "M31's defect, graded against the MOUSE suite: every decoration is "
        "painted with one glyph. Both tiers paint the same wrong screen, so "
        "the cell-for-cell comparison is DECLARED SPARED and stays green; only "
        "the absolute probe — each decoration's rectangle from "
        "`decorationsFor`, required to carry THAT KIND's glyph on the real "
        "terminal — dies. The drag reaches two kinds with two glyphs, which is "
        "what makes that possible at all",
        suite=MOUSE_SUITE,
        spares=(M_DRAG,),
    ),
    Mutation(
        "M36", BIND,
        "  var best = dl\n"
        "  var zone = dzOutsideLeft\n"
        "  if dr < best:\n"
        "    best = dr\n"
        "    zone = dzOutsideRight\n"
        "  if dt < best:\n"
        "    best = dt\n"
        "    zone = dzOutsideTop\n"
        "  if db < best:\n"
        "    zone = dzOutsideBottom\n"
        "  zone",
        "  var best = dl\n"
        "  var zone = dzOutsideLeft\n"
        "  discard best\n"
        "  discard dr\n"
        "  discard dt\n"
        "  discard db\n"
        "  zone",
        R_EDGES,
        "every cell outside the tree area resolves to the LEFT dock edge. The "
        "arm for the medium claim PLAT-6 recorded and this pass re-measured: "
        "a sweep that reported the wrong set of reachable edges would be "
        "indistinguishable from one that reported the right one without it",
        suite=ROUTE,
    ),
    # --- the property the MOUSE path had and nobody measured ---------------
    #
    # PLAT-6's verification of the mouse pass recorded this as a FINDING rather
    # than a defect: deleting `rt.rebuildFocus()` from `routeMouseReport`
    # SURVIVED the whole harness. The code was right and the property was
    # unmeasured — M34 deletes the return leg on the line below it, and nothing
    # deleted the rebuild. The `:` path has had the assertion since it landed;
    # the mouse path now has its own, and this is the arm that says so.
    Mutation(
        "M37", RUNTIME,
        "  rt.rebuildFocus()\n"
        "  discard rt.focus.focusPaneKind(binding.focus)",
        "  discard rt.focus.focusPaneKind(binding.focus)",
        R_MOUSERING,
        "the focus ring is NOT rebuilt after a mouse gesture, so it goes on "
        "holding the pane a drop just docked away and `Tab` offers a pane that "
        "is not on the screen",
        suite=ROUTE,
    ),
    # --- PLAT-6's persistence: the arrangement survives a restart ----------
    #
    # M38 and M38B are THE SAME MUTATION at the two tiers, on the M29/M29B and
    # M33/M33B pattern, and it is the only way to say that the RELAUNCH suite is
    # load-bearing rather than a slow restatement of the in-process one: if the
    # Tier-1 round trip were the only killer, spawning two real processes would
    # be buying nothing.
    Mutation(
        "M38", STORE,
        "  rt.adoptLayoutDocument(path, text)",
        '  LayoutRestoreReport(status: lrsNoDocument, path: path, message: "")',
        P_TRIP,
        "the document is read and then NOT adopted — the session reports "
        "'nothing saved' and opens on the profile default, which is the state "
        "PLAT-6 landed in",
        suite=PERSIST,
    ),
    Mutation(
        "M38B", STORE,
        "  rt.adoptLayoutDocument(path, text)",
        '  LayoutRestoreReport(status: lrsNoDocument, path: path, message: "")',
        L_RELAUNCH,
        "the same defect seen from TWO REAL PROCESSES: the first docks a pane "
        "and writes the document, and the second opens on the default "
        "arrangement. THE SAME MUTATION AS M38 AT THE OTHER TIER",
        suite=RELAUNCH,
    ),
    Mutation(
        "M39", DOC,
        "  if quarantined:\n"
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")',
        "  if false:\n"
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")',
        P_BAD,
        "a session that started from a document it could not read no longer "
        "leaves it alone. THE EXPENSIVE CASE: a document written by a NEWER "
        "build is `UnknownVersion` here, and this arm deletes it because the "
        "user opened an older binary once",
        suite=PERSIST,
    ),
    Mutation(
        "M40", DOC,
        '  layoutDocumentSlug(canonicalTraceFolder) & "-" &\n'
        "    digest[0 ..< min(LayoutKeyDigestChars, digest.len)] & "
        "LayoutDocumentExt",
        "  layoutDocumentSlug(canonicalTraceFolder) & LayoutDocumentExt",
        P_KEY,
        "the key loses its digest and becomes the recording's BASENAME, so "
        "`/a/calc.ct` and `/b/calc.ct` share one document and one recording's "
        "arrangement silently applies to another",
        suite=PERSIST,
    ),
    Mutation(
        "M41", DOC,
        "  if b.isNil or not b.userModified:\n"
        '    return LayoutPersistPlan(intent: lpiRemove, text: "")',
        "  if b.isNil:\n"
        '    return LayoutPersistPlan(intent: lpiRemove, text: "")',
        P_RESET,
        "an UNTOUCHED session writes its profile default, which freezes the "
        "profile on the next launch — open a recording once at 80x24 and the "
        "Compact tree is pinned on a 200x60 terminal for ever. It also stops "
        "`:reset-layout` from deleting the stale document",
        suite=PERSIST,
    ),
    Mutation(
        "M42", STORE,
        "  if not rt.layoutBindingEnabled():\n"
        "    # WITH THE FLAG OFF NOTHING IS READ, and no path is even computed "
        "— so the\n"
        "    # state directory is not touched, not even by a `stat`.\n"
        '    return LayoutRestoreReport(status: lrsNoDocument, path: "", '
        'message: "")',
        "  if false:\n"
        '    return LayoutRestoreReport(status: lrsNoDocument, path: "", '
        'message: "")',
        P_OFF,
        "the flag-off guard goes, so a session with no `--layout-binding` "
        "opens the state directory and reads a document it has nowhere to put",
        suite=PERSIST,
    ),
    Mutation(
        "M43", BIND,
        "    b.interaction = noInteraction()\n"
        "    b.userModified = true",
        "    b.interaction = noInteraction()",
        P_FREEZE,
        "a RESTORED document stops counting as a user modification, so the "
        "next resize re-flows the arrangement a previous session built and the "
        "profile freeze PLAT-6 decided on stops at the session boundary",
        suite=PERSIST,
    ),
    Mutation(
        "M44", DOC,
        '    message: "saved layout ignored (" & kind & "): " & why & '
        '" — this session " &',
        '    message: "the layout was not restored: " & why & '
        '" — this session " &',
        L_BAD,
        "the failure message loses the KIND it leads with. Graded at TIER 2 "
        "because 'the user is told' is a claim about a real screen: "
        "`status_bar.statusBarText` fits the notification to the columns that "
        "are left and truncates the tail, so a diagnosis that moved behind a "
        "90-character path is a warning nobody can see",
        suite=RELAUNCH,
    ),
    # --- the one call that stands between an EACCES and a deleted file ------
    #
    # PLAT-6's verification of the persistence pass recorded this as Y2: a real
    # defect that SURVIVED THE WHOLE HARNESS, because no suite named
    # `UnreadableFile` and no arm touched the call. The code was right and the
    # property was unmeasured — which is the same shape as M37's, one milestone
    # later, and with a worse consequence: not a stale focus ring but a user's
    # arrangement deleted by a transient `EACCES`.
    #
    # It is graded at TIER 1 and NOT at Tier 2, deliberately. The condition has
    # to be a REAL permission removal — injecting a `readFile` failure would
    # grade this module against a fake — and a Tier-1 case owns a temporary
    # directory it created, whereas the pty child's state root is handed to it
    # through an environment variable and a `chmod` between the two processes
    # would be racing the child's own startup.
    #
    # AND THIS HARNESS REFUSES TO GRADE THE ARM ON A HOST WHERE THE PROPERTY
    # CANNOT BE MEASURED, without anything being added for it. The case makes a
    # real permission removal and checks that it actually denied reading; where
    # it did not — root, or a filesystem that does not enforce permissions — it
    # reports `[SKIPPED]`, which `RESULT_LINE` matches as neither `[OK]` nor
    # `[FAILED]`. So the case is absent from `control.passed`, the control step
    # prints `CONTROL DID NOT RUN 1 NAMED CASES` and the run stops before a
    # single arm is applied. A killed verdict from an unmeasurable arm is
    # exactly the "reporting a state it did not reach" failure
    # Verification-Harness-Traps calls the common thread.
    Mutation(
        "M45", RUNTIME,
        "  ## out.\n"
        "  rt.layoutDocumentQuarantined = true",
        "  ## out.\n"
        "  discard rt",
        P_EACCES,
        "the quarantine is NOT recorded for a file that would not open, so the "
        "session's plan is `remove` and exiting DELETES a document it never "
        "managed to read. The report is unchanged — the user is still told the "
        "file was left alone — which is why the case that kills this asserts "
        "the FILE rather than the message",
        suite=PERSIST,
    ),
    # --- the persistence DECISION, enumerated: one arm per branch ------------
    #
    # M39, M41, M42, M45 above grade the branches that a hand-written case
    # happened to name. These grade THE WHOLE DECISION, one arm per branch and
    # per branch ORDERING, each against one lane of `SessionMatrix`. M46 is the
    # reason the table exists: it is the defect that survived all 66 arms.
    Mutation(
        "M46", DOC,
        "  if quarantined:\n"
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")',
        "  if quarantined and (b.isNil or not b.userModified):\n"
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")',
        X_PRECMOD,
        "**THE ARM THIS WHOLE SUITE WAS BUILT FOR.** The quarantine branch is "
        "weakened so it fires only when the session ALSO left the arrangement "
        "alone. A session that could not read its document and then moved a "
        "pane therefore falls through to `lpiWrite`: open a recording with an "
        "older build (its document is `version: 99`), rearrange a pane, quit — "
        "and the exit REPLACES the newer document with a `version: 2` one. "
        "Permanent loss, not a session's. THIS SURVIVED THE ENTIRE 66-ARM "
        "HARNESS, because no case ever constructed `quarantined` and "
        "`userModified` together",
        suite=MATRIX,
    ),
    Mutation(
        "M47", DOC,
        "  if quarantined:\n"
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")\n'
        "  if b.isNil or not b.userModified:\n"
        '    return LayoutPersistPlan(intent: lpiRemove, text: "")',
        "  if b.isNil or not b.userModified:\n"
        '    return LayoutPersistPlan(intent: lpiRemove, text: "")\n'
        "  if quarantined:\n"
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")',
        X_PRECUNMOD,
        "THE PRECEDENCE REVERSED — the OTHER half of the same disagreement, "
        "and the one M46 cannot see. A session that could not read its "
        "document and did NOT touch the arrangement now answers `lpiRemove`, "
        "so the exit DELETES a document this build merely failed to "
        "understand. Two arms rather than one because a precedence has two "
        "sides and a case that only builds one of them establishes the rule "
        "for half the inputs",
        suite=MATRIX,
    ),
    Mutation(
        "M48", DOC,
        '    return LayoutPersistPlan(intent: lpiRemove, text: "")',
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")',
        X_READABLE,
        "the second branch's ANSWER changes: a stale document is left in place "
        "rather than deleted, so `:reset-layout` no longer reaches the disk "
        "and the next launch restores an arrangement the user explicitly "
        "abandoned",
        suite=MATRIX,
    ),
    Mutation(
        "M49", STORE,
        "  if not fileExists(path):\n"
        '    return LayoutRestoreReport(status: lrsNoDocument, path: path, '
        'message: "")',
        "  if false:\n"
        '    return LayoutRestoreReport(status: lrsNoDocument, path: path, '
        'message: "")',
        X_ABSENT,
        "the ABSENT arm goes, so an ordinary first run falls into the "
        "`readFile` failure and reports `UnreadableFile` at a path where "
        "nothing was ever saved. The user is warned about a document that does "
        "not exist, and the session quarantines instead of writing what they "
        "then arrange",
        suite=MATRIX,
    ),
    Mutation(
        "M51", RUNTIME,
        "  rt.layoutDocumentQuarantined = result.status == lrsUnreadable",
        "  rt.layoutDocumentQuarantined = false",
        X_PRECMOD,
        "M45's twin on the OTHER path into the quarantine. `M45` covers the "
        "flag `host/layout_store.nim` sets by hand; this is the flag "
        "`adoptLayoutDocument` sets for every failure the DECODER sees — "
        "corrupt bytes, an empty file, a newer schema, an unknown pane. "
        "Without it a session that could not read its document and then "
        "rearranged a pane WRITES over it",
        suite=MATRIX,
    ),
    Mutation(
        "M52", RUNTIME,
        "  if not rt.layoutPersistenceEnabled():\n"
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")',
        "  if false:\n"
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")',
        X_UNNAMED,
        "the guard in front of the whole decision goes, so a session that was "
        "never bound to a document — a binding with no `restoreLayoutForSession` "
        "call, which is the dimension a summary of this decision drops — starts "
        "planning writes and removes against an EMPTY path",
        suite=MATRIX,
    ),
    Mutation(
        "M55", STORE,
        "      outcome: (if rt.layoutPersistenceEnabled(): lpoQuarantined\n"
        "                else: lpoDisabled),",
        "      outcome: lpoQuarantined,",
        X_OFF,
        "`disabled` and `quarantined` stop being different facts. A session "
        "with no `--layout-binding` reports that it left a document alone, "
        "which is a claim about a file it never named — and the two outcomes "
        "are the only thing distinguishing 'this feature is off' from 'this "
        "feature refused to save'",
        suite=MATRIX,
    ),
    Mutation(
        "M56", DOC,
        "  if b.isNil:\n"
        "    return unreadableLayoutDocument(path, UnreadableFileKind,\n"
        '                                   "there is no layout binding")',
        "  if b.isNil:\n"
        "    return unreadableLayoutDocument(path, NotJsonKind,\n"
        '                                   "there is no layout binding")',
        X_KINDS,
        "the nil-binding refusal is reported as `NotJson` — a kind that names "
        "the user's bytes for a failure that is entirely this process's. The "
        "arm exists to say the kind TABLE reads kinds rather than counting "
        "them: eleven producers, each required to answer with its own name",
        suite=MATRIX,
    ),
    Mutation(
        "M57", DOC,
        "  if b.isNil or not b.userModified:",
        "  if b.isNil or b.userModified:",
        X_PLAN,
        "the second branch's CONDITION is inverted, so an untouched session "
        "writes and a rearranged one deletes. The arm for the plan table "
        "itself: six cells over the routine's own two inputs, which is the "
        "only place `b.isNil` — a value no session can present — is graded at "
        "all",
        suite=MATRIX,
    ),
    # --- the write is a RENAME, and a refused delete is not a delete ---------
    #
    # M58 IS THE FOURTH INSTANCE OF THE SHAPE M37, M45 AND M46 SHARE, and it is
    # the one that survived the table itself. `host/layout_store.nim`'s header
    # has promised since the module was written that the document is staged at
    # `<path>.new` and MOVED onto `<path>`, so a process killed mid-write
    # leaves the previous arrangement intact. Nothing asserted it: with the two
    # lines collapsed to a bare `writeFile`, `test_layout_persistence_matrix`,
    # `test_layout_persistence`, `test_layout_command_routing` and
    # `test_layout_binding` were ALL at 0 failed, and no arm among the 83 this
    # file carried touched `moveFile`. The suites' only mentions of `.new` were
    # negative — trap §4a's lone negative assertion, which nothing can fail.
    Mutation(
        "M58", STORE,
        "      writeFile(temp, plan.text)\n"
        "      moveFile(temp, path)",
        "      writeFile(path, plan.text)",
        X_DURABILITY,
        "THE ATOMIC WRITE COLLAPSED TO A DIRECT ONE. The bytes go straight to "
        "the document, so a process killed between the first byte and the last "
        "leaves a half-written file where the arrangement was — and the next "
        "launch reports it as `NotJson` and offers the profile default. The "
        "case that kills this obstructs `<path>.new` with a DIRECTORY: under "
        "the real module the write cannot open its file and the report names "
        "the staging path, and under this arm the write succeeds and the "
        "planted document is replaced",
        suite=MATRIX,
    ),
    Mutation(
        "M59", STORE,
        "    except CatchableError as e:\n"
        "      LayoutPersistReport(\n"
        "        outcome: lpoFailed, path: path,\n"
        '        message: "the saved layout could not be removed: " & path & '
        '": " & e.msg)',
        "    except CatchableError:\n"
        '      LayoutPersistReport(outcome: lpoRemoved, path: path, message: "")',
        X_FAILREMOVE,
        "a delete the filesystem REFUSED is reported as done. "
        "`:reset-layout` promises the stale document is gone; this session "
        "says `removed` over a file still on disk, so the user believes the "
        "arrangement they abandoned will not come back and the next launch "
        "restores it. The second of the two `lpoFailed` arms, and the one a "
        "privileged host cannot measure — which is why its case probes and "
        "skips LOUDLY rather than weakening",
        suite=MATRIX,
    ),
]

DECLARED_SURVIVORS = [
    Mutation(
        "S1", BIND,
        "proc isEmptyArea*(a: CellArea): bool =\n"
        "  a.width <= 0 or a.height <= 0",
        "proc isEmptyArea*(a: CellArea): bool =\n"
        "  not (a.width > 0 and a.height > 0)",
        "",
        "De Morgan on the emptiness test — the same predicate, spelled the "
        "other way. It MUST survive: a suite that reddens on any edit is as "
        "useless as one that reddens on none.",
    ),
    Mutation(
        "S2", BIND,
        "  if slot < 0: slot = 0\n"
        "  if slot > count - 1: slot = count - 1",
        "  slot = max(0, min(slot, count - 1))",
        "",
        "The same clamp as one expression. Behaviour-preserving for every "
        "`count >= 1`, and `tabPositionOf` cannot answer with a smaller one.",
    ),
    Mutation(
        "S3", TABS,
        "    while cursor < span.startCol:\n"
        "      line.add ' '\n"
        "      inc cursor",
        "    for _ in cursor ..< span.startCol:\n"
        "      line.add ' '\n"
        "    cursor = span.startCol",
        "",
        "The gap fill as a `for` rather than a `while` — the same cells, the "
        "same cursor. It MUST survive, and it is the control for M5 and M26: "
        "both of those edit this loop's neighbourhood, so an arm that reddened "
        "on any edit to `tabRow` would make neither of them evidence.",
    ),
    Mutation(
        "S4", RUNTIME,
        "  not rt.isNil and not rt.app.isNil and not rt.app.layoutBinding.isNil",
        "  not (rt.isNil or rt.app.isNil or rt.app.layoutBinding.isNil)",
        "",
        "De Morgan on the opt-in test. It MUST survive: the routing suite "
        "asserts the OFF arm at three geometries and the ON arm at twenty, so "
        "a suite that reddened here would be reporting the spelling rather "
        "than the behaviour.",
        suite=ROUTE,
    ),
    # --- the controls for the four mouse arms ------------------------------
    Mutation(
        "S5", RUNTIME,
        "    let (isMouse, event) = decodeMouse(token)\n"
        "    if isMouse:\n"
        "      rt.routeMouseReport(event, result)\n"
        "      return",
        "    let decoded = decodeMouse(token)\n"
        "    if decoded[0]:\n"
        "      rt.routeMouseReport(decoded[1], result)\n"
        "      return",
        "",
        "The decoder's answer destructured by index rather than by name — the "
        "same two values, the same call. IT MUST SURVIVE, and it is THE "
        "CONTROL FOR M33 AND M33B: both edit this branch, so a suite that "
        "reddened on any edit to it would make neither of them evidence about "
        "the routing rather than about the spelling.",
        suite=ROUTE,
    ),
    Mutation(
        "S6", RUNTIME,
        "  rt.rebuildFocus()\n"
        "  discard rt.focus.focusPaneKind(binding.focus)",
        "  rt.rebuildFocus()\n"
        "  let carried = rt.focus.focusPaneKind(binding.focus)\n"
        "  discard carried",
        "",
        "The return leg's result named before it is discarded. IT MUST "
        "SURVIVE, and it is THE CONTROL FOR M34, which deletes the call on "
        "this very line.",
        suite=ROUTE,
    ),
    Mutation(
        "S7", BIND,
        "  let db = body.row + body.height - 1 - row",
        "  let db = (body.row + body.height) - (row + 1)",
        "",
        "The bottom distance re-associated — the same integer for every input. "
        "IT MUST SURVIVE, and it is THE CONTROL FOR M36, which rewrites the "
        "comparison chain these four distances feed.",
        suite=ROUTE,
    ),
    Mutation(
        "S8", BIND,
        "    let right = d.area.col + d.area.width",
        "    let right = d.area.width + d.area.col",
        "",
        "The decoration's right edge with the addition commuted. IT MUST "
        "SURVIVE, and it is THE CONTROL FOR M35 (and, retrospectively, for "
        "M31): both edit `paintDecorations`' per-decoration preamble, so an "
        "absolute probe that reddened on any edit there would be reporting the "
        "neighbourhood rather than the glyph table.",
        suite=MOUSE_SUITE,
    ),
    Mutation(
        "S9", RUNTIME,
        "      let (had, focused) = rt.focus.focusedPane()\n"
        "      if had:\n"
        "        rt.app.layoutBinding.focus = focused",
        "      let picked = rt.focus.focusedPane()\n"
        "      if picked[0]:\n"
        "        rt.app.layoutBinding.focus = picked[1]",
        "",
        "The `:` prompt's focus copy destructured by index rather than by name. "
        "IT MUST SURVIVE, and it is THE CONTROL FOR M30, which deletes the "
        "copy on these very lines. M30 shipped without one; an independent "
        "pass wrote this arm by hand and it was never added, so a re-run of "
        "the harness could not reproduce the finding that M30 measures "
        "behaviour rather than an edit to its neighbourhood.",
        suite=ROUTE,
    ),
    # --- the controls for M37 and for the seven persistence arms -----------
    Mutation(
        "S10", RUNTIME,
        "  rt.rebuildFocus()\n"
        "  discard rt.focus.focusPaneKind(binding.focus)",
        "  rebuildFocus(rt)\n"
        "  discard rt.focus.focusPaneKind(binding.focus)",
        "",
        "The focus-ring rebuild spelled as a plain call rather than with "
        "method-call syntax — the same call, the same argument. IT MUST "
        "SURVIVE, and it is THE CONTROL FOR M37, which deletes that very line: "
        "without it, 'the case reddens when this line is edited' is all M37 "
        "would establish.",
        suite=ROUTE,
    ),
    Mutation(
        "S11", STORE,
        "  rt.adoptLayoutDocument(path, text)",
        "  adoptLayoutDocument(rt, path, text)",
        "",
        "The adoption spelled as a plain call. IT MUST SURVIVE, and it is THE "
        "CONTROL FOR M38 AND M38B, which replace that same expression.",
        suite=PERSIST,
    ),
    Mutation(
        "S12", DOC,
        "  if quarantined:\n"
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")',
        "  if quarantined:\n"
        '    result = LayoutPersistPlan(intent: lpiQuarantine, text: "")\n'
        "    return result",
        "",
        "The quarantine answer named before it is returned — the same value on "
        "the same condition. IT MUST SURVIVE, and it is THE CONTROL FOR M39, "
        "which replaces that condition.",
        suite=PERSIST,
    ),
    Mutation(
        "S13", DOC,
        "    digest[0 ..< min(LayoutKeyDigestChars, digest.len)] & "
        "LayoutDocumentExt",
        "    digest[0 ..< min(digest.len, LayoutKeyDigestChars)] & "
        "LayoutDocumentExt",
        "",
        "`min`'s arguments commuted — the same integer for every input. IT "
        "MUST SURVIVE, and it is THE CONTROL FOR M40, which rewrites the "
        "expression this slice is part of.",
        suite=PERSIST,
    ),
    Mutation(
        "S14", DOC,
        "  if b.isNil or not b.userModified:",
        "  if not (not b.isNil and b.userModified):",
        "",
        "De Morgan on the persist plan's guard, short-circuit and all: `not "
        "b.isNil` is still evaluated first, so a nil binding is still never "
        "dereferenced. IT MUST SURVIVE, and it is THE CONTROL FOR M41, which "
        "drops one of these two conditions.",
        suite=PERSIST,
    ),
    Mutation(
        "S15", STORE,
        '    return LayoutRestoreReport(status: lrsNoDocument, path: "", '
        'message: "")',
        '    return LayoutRestoreReport(path: "", message: "", '
        "status: lrsNoDocument)",
        "",
        "The flag-off answer with its named fields in a different order — the "
        "same object. IT MUST SURVIVE, and it is THE CONTROL FOR M42, which "
        "removes the guard in front of this very statement.",
        suite=PERSIST,
    ),
    Mutation(
        "S16", BIND,
        "    b.interaction = noInteraction()\n"
        "    b.userModified = true",
        "    b.userModified = true\n"
        "    b.interaction = noInteraction()",
        "",
        "The two independent assignments swapped. IT MUST SURVIVE, and it is "
        "THE CONTROL FOR M43, which deletes the second of them.",
        suite=PERSIST,
    ),
    Mutation(
        "S17", DOC,
        '    message: "saved layout ignored (" & kind & "): " & why & '
        '" — this session " &',
        '    message: "saved layout ignored (" & kind & ")" & ": " & why & '
        '" — this session " &',
        "",
        "The same message with one concatenation split in two. IT MUST "
        "SURVIVE, and it is THE CONTROL FOR M44 — graded at TIER 2 like the "
        "arm it controls, because a control run against a different suite says "
        "nothing about the case that has to redden.",
        suite=RELAUNCH,
    ),
    Mutation(
        "S18", RUNTIME,
        "  ## out.\n"
        "  rt.layoutDocumentQuarantined = true",
        "  ## out.\n"
        "  let unreadable = true\n"
        "  rt.layoutDocumentQuarantined = unreadable",
        "",
        "The quarantine named before it is assigned — the same field, the same "
        "value, the same one-statement body. IT MUST SURVIVE, and it is THE "
        "CONTROL FOR M45, which deletes that very assignment: without it, 'the "
        "case reddens when this line is edited' is all M45 would establish, "
        "and the property M45 exists to grade is precisely a property nothing "
        "had graded before.",
        suite=PERSIST,
    ),
    # --- the controls for the nine matrix arms ------------------------------
    #
    # EVERY ONE OF THEM IS GRADED AGAINST THE MATRIX SUITE, deliberately. S17's
    # rule: a control run against a different suite says nothing about the case
    # that has to redden. S14 already De Morgans the same guard M57 inverts, but
    # it is graded against `test_layout_persistence.nim`, so it cannot say
    # whether the MATRIX cases redden on any edit to that line — S26 is that
    # statement, and it is why a near-duplicate arm is worth its compile.
    Mutation(
        "S19", DOC,
        "  if quarantined:\n"
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")\n'
        "  if b.isNil or not b.userModified:\n"
        '    return LayoutPersistPlan(intent: lpiRemove, text: "")',
        "  if quarantined:\n"
        '    return LayoutPersistPlan(intent: lpiQuarantine, text: "")\n'
        "  elif b.isNil or not b.userModified:\n"
        '    return LayoutPersistPlan(intent: lpiRemove, text: "")',
        "",
        "The second branch as an `elif` rather than a second `if` — identical, "
        "because the first branch returns. IT MUST SURVIVE, and it is THE "
        "CONTROL FOR M46 AND M47: both rewrite exactly these four lines, one "
        "by weakening the first condition and one by swapping the two "
        "branches, so a pair of cases that reddened on any edit to this "
        "neighbourhood would make neither of them evidence about the "
        "PRECEDENCE. It touches the ordering structure itself and changes "
        "nothing, which is the only kind of control a precedence arm can have.",
        suite=MATRIX,
    ),
    Mutation(
        "S20", DOC,
        '    return LayoutPersistPlan(intent: lpiRemove, text: "")',
        '    result = LayoutPersistPlan(intent: lpiRemove, text: "")\n'
        "    return result",
        "",
        "The remove answer named before it is returned — the same value on the "
        "same condition, and the shape S12 already uses for the quarantine "
        "arm. IT MUST SURVIVE, and it is THE CONTROL FOR M48, which replaces "
        "that very expression.",
        suite=MATRIX,
    ),
    Mutation(
        "S21", STORE,
        "  if not fileExists(path):",
        "  if not path.fileExists():",
        "",
        "The existence test in method-call syntax — the same call on the same "
        "argument. IT MUST SURVIVE, and it is THE CONTROL FOR M49, which "
        "removes the guard on that line.",
        suite=MATRIX,
    ),
    Mutation(
        "S22", RUNTIME,
        "  if not rt.layoutPersistenceEnabled():",
        "  if not layoutPersistenceEnabled(rt):",
        "",
        "The persistence guard spelled as a plain call. IT MUST SURVIVE, and "
        "it is THE CONTROL FOR M52, which removes that guard.",
        suite=MATRIX,
    ),
    Mutation(
        "S23", STORE,
        "      outcome: (if rt.layoutPersistenceEnabled(): lpoQuarantined\n"
        "                else: lpoDisabled),",
        "      outcome: (if not rt.layoutPersistenceEnabled(): lpoDisabled\n"
        "                else: lpoQuarantined),",
        "",
        "The same two-armed choice with the condition negated and the arms "
        "swapped — the same outcome for every session. IT MUST SURVIVE, and it "
        "is THE CONTROL FOR M55, which collapses that choice to one arm.",
        suite=MATRIX,
    ),
    Mutation(
        "S24", RUNTIME,
        "  rt.layoutDocumentQuarantined = result.status == lrsUnreadable",
        "  rt.layoutDocumentQuarantined = (result.status == lrsUnreadable)",
        "",
        "The quarantine predicate parenthesised — the same comparison, the "
        "same assignment. IT MUST SURVIVE, and it is THE CONTROL FOR M51, "
        "which replaces that predicate with `false`.",
        suite=MATRIX,
    ),
    Mutation(
        "S25", DOC,
        '                                   "there is no layout binding")',
        '                                   "there is no " & "layout binding")',
        "",
        "The nil-binding message as two literals joined — the same string. IT "
        "MUST SURVIVE, and it is THE CONTROL FOR M56, which edits the KIND "
        "argument two lines above it: without this, 'the kind table reddens "
        "when this call is edited' is all M56 would establish.",
        suite=MATRIX,
    ),
    Mutation(
        "S26", DOC,
        "  if b.isNil or not b.userModified:",
        "  if b.isNil or (not b.userModified):",
        "",
        "The second branch's guard parenthesised, short-circuit and all. IT "
        "MUST SURVIVE, and it is THE CONTROL FOR M57 — S14 makes the same "
        "point against `test_layout_persistence.nim`, and a control graded "
        "against a different suite says nothing about the case that has to "
        "redden.",
        suite=MATRIX,
    ),
    Mutation(
        "S27", STORE,
        "      writeFile(temp, plan.text)\n"
        "      moveFile(temp, path)",
        "      let staged = temp\n"
        "      writeFile(staged, plan.text)\n"
        "      moveFile(staged, path)",
        "",
        "The staging path named before it is used — the same two calls on the "
        "same path, in the same order. IT MUST SURVIVE, and it is THE CONTROL "
        "FOR M58, which rewrites exactly these two lines into one: without it, "
        "'the DURABILITY case reddens when this line is edited' is all M58 "
        "would establish, and the property M58 exists to grade is precisely a "
        "property that nothing measured until now.",
        suite=MATRIX,
    ),
    Mutation(
        "S28", STORE,
        "      LayoutPersistReport(\n"
        "        outcome: lpoFailed, path: path,\n"
        '        message: "the saved layout could not be removed: " & path & '
        '": " & e.msg)',
        "      let why =\n"
        '        "the saved layout could not be removed: " & path & ": " & '
        "e.msg\n"
        "      LayoutPersistReport(outcome: lpoFailed, path: path, "
        "message: why)",
        "",
        "The remove failure's message named before it is reported — the same "
        "outcome, the same path, the same string, and the shape S12 and S20 "
        "already use. IT MUST SURVIVE, and it is THE CONTROL FOR M59, which "
        "replaces that very expression with a `removed` report.",
        suite=MATRIX,
    ),
]

RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")


@dataclass
class RunResult:
    rc: int
    passed: list = field(default_factory=list)
    failed: list = field(default_factory=list)
    ran: bool = True

    @property
    def total(self):
        return len(self.passed) + len(self.failed)


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def link_flags():
    """The `--passL:` flags the Tier-1 lane adds, read from the same file."""
    path = ROOT / "build" / "grammars" / "tui-link-flags.txt"
    if not path.is_file():
        return []
    return ["--passL:" + f for f in path.read_text().split()]


def run_suite(suite: str = SUITE) -> RunResult:
    archive = ROOT / "build" / "grammars" / "libcodetracer_tui_grammars.a"
    extra = TIER2_PATHS if suite in TIER2 else []
    stem = Path(suite).stem
    cmd = ["nim", "c", "-r", "--hints:off", "--path:src/frontend/viewmodel",
           f"-d:isonimTuiGrammarArchive={archive}",
           *link_flags(),
           *extra,
           # ONE NIMCACHE PER SUITE. Sharing it across the four made every arm
           # a full rebuild of whichever suite ran last, which is minutes on
           # the Tier-2 pair.
           f"--nimcache:build/nimcache/plat6-mutations-{stem}",
           f"-o:/tmp/plat6-mutation-{stem}", suite]
    # `errors="replace"`, NOT the default strict decode. A mutated suite is a
    # suite printing diagnostics about bytes it did not expect, and this one
    # slices painted rows — which contain U+2500 — at cell offsets, so a
    # mismatch message can carry a PARTIAL RUNE. With the default,
    # `subprocess.run` raises `UnicodeDecodeError` and the arm ends in a Python
    # traceback instead of in one of this file's three verdicts, which is
    # exactly the "no verdict at all" failure the three-verdict rule exists to
    # keep visible (Verification-Harness-Traps §1). Found by an arm that
    # widened `tabSpans`' gap.
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                          errors="replace", timeout=3600)
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode)
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        # NOT A KILL. A binary that produced no result lines did not run the
        # suite: it failed to compile, or died before the first case.
        res.ran = False
        print("      ---- no result lines; last 20 lines of output ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)
    return res


def main() -> int:
    # An optional arm filter, so a re-run after fixing ONE arm costs one
    # compile rather than all of them. The control still runs: an arm graded
    # against a suite nobody checked is not graded.
    only = set(sys.argv[1:])
    baseline = {p: digest(p) for p in TOUCHED}

    arms = [m for m in MUTATIONS + DECLARED_SURVIVORS
            if not only or m.id in only]
    if not arms:
        print(f"no arm matches {sorted(only)}")
        return 1
    # ONLY THE SUITES THE SELECTED ARMS USE. A filtered re-run of one Tier-1
    # arm must not pay for four pty controls; a run with no filter pays for all
    # eight, which is the honest price of grading eight suites.
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
    for mut in arms:
        path = ROOT / mut.path
        original = path.read_text()
        occurrences = original.count(mut.find)
        if occurrences != 1:
            print(f"{mut.id:<5} HARNESS-FAILURE      pattern occurs "
                  f"{occurrences} times in {mut.path}, expected 1")
            problems += 1
            continue
        path.write_text(original.replace(mut.find, mut.replace))
        try:
            res = run_suite(mut.suite)
        finally:
            path.write_text(original)
            # Restoration is verified, not assumed.
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
        elif not res.failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif mut.killer in res.failed:
            others = [f for f in res.failed if f != mut.killer]
            # A SPARED CASE THAT DIED IS A FAILURE OF THE ARM'S CLAIM, not a
            # bonus kill. M31 exists to show that the cross-tier equality
            # CANNOT see a defect both tiers share; if it saw one, the pairing
            # this milestone argues for would be unnecessary and the comment
            # would be wrong.
            broke = [c for c in mut.spares if c in res.failed]
            if broke:
                verdict = "SPARED-CASE-DIED"
                note = f"{broke} should have stayed green under {mut.id}"
                problems += 1
            else:
                verdict = "killed"
                note = mut.killer + (f"  (+{len(others)} more)" if others else "")
                if mut.spares:
                    note += f"  [spared: {len(mut.spares)}]"
        else:
            verdict, note = "MISDIRECTED", f"died in {res.failed}, not {mut.killer!r}"
            problems += 1
        print(f"{mut.id:<6} {Path(mut.suite).stem[:34]:<34} {verdict:<20} "
              f"{note}", flush=True)

    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
