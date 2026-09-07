#!/usr/bin/env python3
"""Mutation harness for PLAT-6's terminal layout binding.

Every case in PLAT-6's four suites claims to detect something. This script
proves it, one case at a time: it patches a single line of the SUBJECT
(`app/layout/binding.nim`, `app/layout/tab_strip.nim`, `app/input/mouse.nim`,
`app/runtime.nim`, or `headless_app/layout_model.nim` where the property is one
PLAT-4 owns and this binding depends on) and requires that the **named** case
fails. A mutation killed only by some other case is MISDIRECTED and is a
failure of this harness, not a pass.

FIVE SUITES, TWO TIERS. Each arm names the suite it is graded against:

  test_layout_binding.nim          Tier 1 — the binding itself
  test_layout_command_routing.nim  Tier 1 — the opt-in, the `:` routing and
                                            the MOUSE routing
  test_real_layout_gestures.nim    Tier 2 — a KEYBOARD gesture through a pty
  test_real_layout_transients.nim  Tier 2 — cross-tier snapshot equivalence
  test_real_layout_mouse.nim       Tier 2 — a MOUSE gesture through a pty

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
M34 ← S6, M35 and M31 ← S8, M36 ← S7. Without the control, "the case reddens
when this line changes" is all an arm establishes.

S9 is here because M30 shipped WITHOUT a control and an independent pass had to
write one by hand, off the record. An arm that lives only in somebody's terminal
is not part of the harness, so it is spelled out below.

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
GEST = "src/frontend/tui/tests/real_terminal/test_real_layout_gestures.nim"
TRANS = "src/frontend/tui/tests/real_terminal/test_real_layout_transients.nim"
MOUSE_SUITE = "src/frontend/tui/tests/real_terminal/test_real_layout_mouse.nim"

BIND = "src/frontend/tui/app/layout/binding.nim"
TABS = "src/frontend/tui/app/layout/tab_strip.nim"
MOUSE = "src/frontend/tui/app/input/mouse.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
INTER = "src/frontend/headless_app/layout_interaction.nim"
MODEL = "src/frontend/headless_app/layout_model.nim"

TOUCHED = [SUITE, ROUTE, GEST, TRANS, MOUSE_SUITE, BIND, TABS, MOUSE, RUNTIME,
           INTER, MODEL]

# THE TWO TIER-2 SUITES NEED THREE MORE `--path`s and they spawn a child in a
# real pty, so an arm against one costs a compile, a CHILD compile and a
# handful of pty round trips. They are here anyway, and for the reason the
# milestone gives: the rows PLAT-6 left open were "a gesture through a real
# pty" and "cross-tier snapshot equivalence", and an arm that only ever runs
# the Tier-1 suite cannot say whether either of those checks has teeth.
TIER2 = {GEST, TRANS, MOUSE_SUITE}
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

ROUTE_CASES = [R_OFF, R_SAME, R_DOCK, R_FOCUS, R_SPEC43, R_VERBS, R_RESIZE,
               R_MOUSEOFF, R_MOUSEDRAG, R_MOUSEFOCUS, R_CLICKWHEEL, R_PROMPT,
               R_EDGES, C_COUNT]

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
    GEST: GEST_CASES,
    TRANS: TRANS_CASES,
    MOUSE_SUITE: MOUSE_CASES,
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
    # compile rather than twenty-seven. The control still runs: an arm graded
    # against a suite nobody checked is not graded.
    only = set(sys.argv[1:])
    baseline = {p: digest(p) for p in TOUCHED}

    arms = [m for m in MUTATIONS + DECLARED_SURVIVORS
            if not only or m.id in only]
    if not arms:
        print(f"no arm matches {sorted(only)}")
        return 1
    # ONLY THE SUITES THE SELECTED ARMS USE. A filtered re-run of one Tier-1
    # arm must not pay for two pty controls; a run with no filter pays for all
    # four, which is the honest price of grading four suites.
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
