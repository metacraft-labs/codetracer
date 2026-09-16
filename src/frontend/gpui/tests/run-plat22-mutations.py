#!/usr/bin/env python3
"""run-plat22-mutations.py — PLAT-22's mutation harness: the GPUI editing
surface.

## THE MACHINERY IS PLAT-20's, REUSED RATHER THAN RE-DERIVED

Everything below the arm table — the lock, the needle scan, the digest gate,
the `because` derivation, the seven verdicts, the behaviour-preserving control
per arm — is `run-plat20-mutations.py`'s, copied deliberately. A second harness
IMPLEMENTATION is Verification-Harness-Traps §14 one level up, and §14a is the
entry about what re-derivation costs: *"the problem was solved, in this
repository, in a file the second author had read."*

What is new here is TWO CHECKS the copied machinery gained, both from defects
measured on this milestone:

* **A `find` or `control_find` must END AT A LINE END** (PLAT-21's rule,
  adopted). Every control works by appending a comment marker to a matched
  fragment, so a needle that is a PREFIX of a longer line comments out the rest
  of that line and the "behaviour-preserving" control stops being
  behaviour-preserving. PLAT-21 scored 16 of 17 on exactly that.
* **`SUITE_CMD` reads the LANE's flags rather than repeating them.** PLAT-20's
  harness carried `--path:src/frontend/viewmodel` for a suite that links
  `isonim_tui`, and the link therefore failed with `ld: cannot find
  -ltree-sitter` outside the nix dev shell — two of its fourteen arms, INCLUDING
  ITS LOAD-BEARING ONE, scored `DID-NOT-COMPILE`. Measured 2026-09-16 and fixed
  in that harness; this one inherits the fixed shape.

## WHAT IT GRADES

PLAT-22's subject is an EDITOR wired to the shared ViewModels, so the arms fall
into four groups and the groups are the milestone's own four criteria:

  * the EXECUTION POINTER   — E2, U3
  * PER-LINE STATUS         — E1, E11
  * INLINE VALUES           — E3, E8
  * the FLOW OVERLAY        — E4

…plus the two things this milestone had to repair in the product to make any of
them reach a user (E9, E12), the escape's medium (E5), edit mode's contract
(E6, E10, U1) and the never-a-blank rule (E7, U2).

## THREE ARMS ARE UNDECLARED

U1, U2 and U3 are planted against this milestone's own evidence rather than
against its deliverable list. That is the only part of a harness that can find
something its author did not already know, and on the last seven milestones it
has.

## AND TWO MORE CAME FROM THE VERIFICATION PASS, 2026-09-16

E13 and E14 were planted as UNDECLARED arms by the verification pass and both
SURVIVED the 10-case, 307-assertion suite this harness had been recorded
against. They are declared here now, and both repairs are in the SUITE rather
than in the product — neither found a defect in the editor, both found a claim
the evidence could not tell from its opposite:

  * E13 — `provenanceOf(savUnverified)` answering `epVerified`, i.e. the editor
    certifying bytes nobody recorded. Verification-Harness-Traps §7a: the rule
    is quoted verbatim in `editor_rows.EditorProvenance`'s header and was
    asserted nowhere.
  * E14 — the pane no longer stating which mode's source it shows. §4d: the
    case DID assert it, with `contract.statement in textContent(root)`, and the
    read-only notice quotes the statement verbatim — so the containment was
    satisfied by prose ABOUT the thing while the thing was gone.

*Eight of seventeen arm-runs have now survived a first graded run on this
milestone, and every one of those repairs has been in the evidence.*

Usage:
    run-plat22-mutations.py                      # grade every arm
    run-plat22-mutations.py --only E5,U2
    run-plat22-mutations.py --needle-scan
    run-plat22-mutations.py --derive             # re-derive every `because`
    run-plat22-mutations.py --record-control-hashes
"""

import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HARNESS_DIR = Path(__file__).resolve().parent

# --- subjects ---------------------------------------------------------------
ROWS = "src/common/view_vocabulary/editor_rows.nim"
SURFACE = "src/frontend/view_vocabulary/editor_surface.nim"
LEAVES = "src/frontend/gpui/app/leaves.nim"
HAPP = "src/frontend/headless_app/headless_app.nim"
UISEL = "src/ct/ui_selection.nim"

# --- the suites the arms are graded against ---------------------------------
# §16c: these are NOT mutation subjects and they are in TOUCHED anyway, because
# a change that touches only a suite invalidates every arm graded against it
# while producing no overlap signal at all in a harness whose TOUCHED names
# subjects only.
SUITE_EDIT = "src/frontend/gpui/tests/test_gpui_editing_surface.nim"
SUITE_UISEL = "src/ct/ui_selection_test.nim"

TOUCHED = [ROWS, SURFACE, LEAVES, HAPP, UISEL, SUITE_EDIT, SUITE_UISEL]

CONTROL_HASHES = HARNESS_DIR / "plat22-mutation-control.sha256"
BECAUSE_FILE = HARNESS_DIR / "plat22-mutation-because.json"
LOCK_FILE = REPO / "build" / "plat22-mutations.lock"
NIMCACHE = REPO / "build" / "plat22mut"


def _tui_link_flags() -> list[str]:
    """The `--passL:` flags the lane gives a suite that links isonim-tui.

    Read from the file `scripts/build-tui-grammars.sh` writes and
    `ci/lib/test-lane-files.sh` reads, never copied — §14. No suite of THIS
    harness links isonim-tui today, and the function is here anyway so that the
    day one does, the flags arrive from the same place rather than from a
    literal somebody pastes. PLAT-20's harness learned that the expensive way.
    """
    path = REPO / "build" / "grammars" / "tui-link-flags.txt"
    if not path.exists():
        return []
    return [f"--passL:{flag}" for flag in path.read_text().split()]


SUITE_CMD = {
    # The `gpui-shell` lane's flags, from `ci/lib/test-lane-files.sh`: no
    # `isonim_tui` flags at all, which is the lane's whole point and which
    # `test_gpui_shell_split.nim` asserts from inside.
    SUITE_EDIT: ["--path:src/frontend/viewmodel"],
    SUITE_UISEL: ["--mm:refc"],
}


@dataclass
class Arm:
    name: str
    path: str
    find: str
    replace: str
    suite: str
    kills: str
    control_find: str
    control_replace: str
    note: str
    because: str = ""
    extra_kills: list = field(default_factory=list)


# The one control fragment per subject, appended to rather than invented per
# arm: a behaviour-preserving control is a second quotation of the same file,
# and one shared spelling per file is one thing to keep aimed instead of
# fifteen. Each ends AT A LINE END, which the needle scan now enforces.
CTL = {
    ROWS: ("func isWordChar(c: char): bool =",
           "func isWordChar(c: char): bool =  ## ctl"),
    SURFACE: ("func degradedMessageFor*(state: PaneDegradation): string =",
              "func degradedMessageFor*(state: PaneDegradation): string =  ## ctl"),
    LEAVES: ("proc slotPath(slot: DockPaneSlot): string =",
             "proc slotPath(slot: DockPaneSlot): string =  ## ctl"),
    HAPP: ("proc activatePane*(slot: HeadlessSessionSlot; kind: PaneKind): bool =",
           "proc activatePane*(slot: HeadlessSessionSlot; kind: PaneKind): bool =  ## ctl"),
    UISEL: ("func gapMessage(command: string; frontEnd: UiFrontEnd; gap: string): string =",
            "func gapMessage(command: string; frontEnd: UiFrontEnd; gap: string): string =  ## ctl"),
}


ARMS = [
    # ------------------------------------------------------------------
    # PER-LINE STATUS
    # ------------------------------------------------------------------
    Arm("E1", ROWS,
        "      if p.enabled:\n        return emBreakpoint",
        "      if p.enabled:\n        sawTracepoint = true",
        SUITE_EDIT,
        "PER-LINE STATUS comes from the points, and a breakpoint beats a tracepoint",
        CTL[ROWS][0], CTL[ROWS][1],
        "A BREAKPOINT STOPS RUNNING THE PROGRAM AND A TRACEPOINT DOES NOT, so "
        "a line carrying both must show the one that stops. The two existing "
        "front-ends resolved this two different ways — the terminal by an "
        "emission ORDER that `markFor`'s last-wins consumed, the web by "
        "writing both divs and letting CSS decide — and a third front-end was "
        "about to pick a third. The precedence is a ranking here so a medium "
        "cannot get it wrong by drawing in a different order."),

    Arm("E11", SURFACE,
        "  if points.len == 0:\n    result.support[ecLineStatus] = esDegraded\n\n  let values = inlineValuesOf(state, budget)",
        "  let values = inlineValuesOf(state, budget)",
        SUITE_EDIT,
        "PER-LINE STATUS comes from the points, and a breakpoint beats a tracepoint",
        CTL[SURFACE][0], CTL[SURFACE][1],
        "THE UNFILED DEGRADATION. `PointListVM.points` has no backend "
        "producer, so a surface handed none draws a CLEAN GUTTER — and a clean "
        "gutter is indistinguishable from a file with no breakpoints in it. "
        "Reporting `esRendered` because the MECHANISM works is precisely the "
        "claim `FiledEditorGaps[pgMarksHaveNoProducer]` exists to stop being "
        "made, and this arm is what makes the register's `taken == filed` "
        "assertion carry weight rather than describe itself."),

    # ------------------------------------------------------------------
    # THE EXECUTION POINTER
    # ------------------------------------------------------------------
    Arm("E2", ROWS,
        "  elif executionLine > 0 and line == executionLine: eptExecution",
        "  elif executionLine > 0: eptExecution",
        SUITE_EDIT,
        "the EXECUTION POINTER comes from the ViewModel and the rendering follows it",
        CTL[ROWS][0], CTL[ROWS][1],
        "EVERY ROW BECOMES THE EXECUTION LINE. The positive half of the case "
        "— 'the pointer is on line N' — stays GREEN under this, because line N "
        "really does carry it. Only the NEGATIVE twin (`pointing == 1`) sees "
        "it. That is §4a's emptied subject in its usual costume: nothing is "
        "empty, the count never moves, and what was emptied is the VARIETY "
        "inside the set."),

    # ------------------------------------------------------------------
    # INLINE VALUES
    # ------------------------------------------------------------------
    Arm("E3", ROWS,
        "    if beforeOk and afterOk:\n      return true",
        "    return true",
        SUITE_EDIT,
        "INLINE VALUES are presented at the GPUI ROW budget, on the execution line only",
        CTL[ROWS][0], CTL[ROWS][1],
        "WHOLE-WORD BECOMES SUBSTRING, so `sum` matches `summary` and a value "
        "is attached to the wrong identifier. A value on the wrong name is a "
        "STALE value by another route, and stale is worse than absent because "
        "it is indistinguishable from correct."),

    Arm("E8", SURFACE,
        "      else: presentText(v.presented, budget).strip()",
        "      else: v.value.strip()",
        SUITE_EDIT,
        "INLINE VALUES are presented at the GPUI ROW budget, on the execution line only",
        CTL[SURFACE][0], CTL[SURFACE][1],
        "THE PLAT-2 ARM. `Variable.value` is ONE rendering at ONE budget — "
        "`tuiValueBudget`, somebody else's — and using it is exactly the 'two "
        "spellings of one value in one pane' PLAT-2's own risk names. The "
        "budget this front-end declares is `gpuiRowBudget()`, and until this "
        "milestone that function had no production caller at all."),

    # ------------------------------------------------------------------
    # THE FLOW OVERLAY
    # ------------------------------------------------------------------
    Arm("E4", SURFACE,
        "  if line >= loop.first and line <= loop.last:\n    efsTaken",
        "  if true:\n    efsTaken",
        SUITE_EDIT,
        "PLAT-22's four concerns are four, and the filed register agrees with a RUN",
        CTL[SURFACE][0], CTL[SURFACE][1],
        "THE OVERCLAIM. `efsTaken` here means 'inside the focused loop' and "
        "NOT 'this line ran' — `FlowVM` carries no per-line taken/not-taken "
        "fact at all, which is `FiledEditorGaps[pgFlowHasNoPerLineFact]`. An "
        "overlay that answered `efsTaken` for every line would be telling a "
        "user the program executed lines it never reached, which is the "
        "strongest form of a debugger lying."),

    # ------------------------------------------------------------------
    # THE ESCAPE'S MEDIUM
    # ------------------------------------------------------------------
    Arm("E5", LEAVES,
        "  if escape.isNil or escape.nativeMedium != GpuiMedium or\n     surface.medium != GpuiMedium:",
        "  if escape.isNil:",
        SUITE_EDIT,
        "an escape naming ANOTHER front-end is refused, and the refusal names both",
        CTL[LEAVES][0], CTL[LEAVES][1],
        "`vocabulary.nativeEscape`'s own doc comment says it is built "
        "deliberately so that a caller writing one HAS SAID which front-end it "
        "is for — and until PLAT-22 nothing anywhere read the answer. PLAT-21's "
        "verification planted an arm that hardcoded the node's medium to "
        "'terminal' while the `PaneView` still said 'gpui', and it SURVIVED "
        "three suites: `grep -rn nativeMedium` over all of them returned "
        "nothing. This is that field given a production reader."),

    # ------------------------------------------------------------------
    # EDIT MODE — a PRODUCT mode, not a front-end feature
    # ------------------------------------------------------------------
    Arm("E6", SURFACE,
        "  result.mutable = contract.mutable and mutableHere",
        "  result.mutable = contract.mutable",
        SUITE_EDIT,
        "EDIT mode reaches this front-end, reads the CORE's contract, and says what it cannot do",
        CTL[SURFACE][0], CTL[SURFACE][1],
        "THE FRONT-END CLAIMS A CAPABILITY IT DOES NOT HAVE. The core's "
        "contract says edit mode is mutable and this medium has no text "
        "buffer; answering the contract's value alone is a surface telling "
        "every caller the user may type into it. The opposite failure — "
        "rewriting the contract to `false` — is the two-dimensions-into-one "
        "collapse PLAT-16 is written against, which is why the surface carries "
        "BOTH and reports the disagreement."),

    Arm("E10", UISEL,
        "      var gpuiEditHandoff = @[\"--edit\"]",
        "      var gpuiEditHandoff: seq[string] = @[]",
        SUITE_UISEL,
        "`--ui=gpui` inherits every refusal `--ui=tui` has, and names ITSELF",
        CTL[UISEL][0], CTL[UISEL][1],
        "THE FLAG BECOMES DECORATION. Without `--edit` the positional reaches "
        "`codetracer-gpui` as a RECORDING, and the front-end refuses it for "
        "having no `trace.json` — a true diagnosis of the wrong question, "
        "which is the failure `ui-selection.md` §4.1 draws its per-front-end "
        "messages against."),

    # ------------------------------------------------------------------
    # NEVER A BLANK
    # ------------------------------------------------------------------
    Arm("E7", LEAVES,
        "    r.createTextNode(if row.held: row.text else: EditorLoadingText))",
        "    r.createTextNode(row.text))",
        SUITE_EDIT,
        "a line the window does not hold renders a PLACEHOLDER, never a blank",
        CTL[LEAVES][0], CTL[LEAVES][1],
        "`SourceVM`'s SECOND CONTRACT, thrown away at the last step. Its own "
        "header: *'an empty-string default is exactly how a source pane "
        "silently renders blank, and a blank pane over a working debugger is "
        "indistinguishable from a file of blank lines.'* The VM answers "
        "`srkRequest` correctly, the surface carries `held = false` correctly, "
        "and the renderer discards both."),

    # ------------------------------------------------------------------
    # THE TWO PRODUCT REPAIRS THIS MILESTONE HAD TO MAKE
    # ------------------------------------------------------------------
    Arm("E9", HAPP,
        "    if not adopt.isNil: adopt",
        "    if false: adopt",
        SUITE_EDIT,
        "THE SHIPPED BINARY draws the editor — Tier 2, through --report-plan",
        CTL[HAPP][0], CTL[HAPP][1],
        "RESTORES THE DEFECT THIS MILESTONE FOUND IN THE SHIPPED BINARY. "
        "Without `adopt`, `openSession` builds a SECOND `DebuggerSession` over "
        "the same transport — `dspCreated`, panel VMs nil, a store nothing "
        "writes to — so `codetracer-gpui` drew '— waiting for the session to "
        "launch' on all five panes of a real `calc` recording while the "
        "process held a live debugger.\n\n"
        "IT IS GRADED BY THE TIER-2 CASE AND BY NOTHING ELSE, which is the "
        "point: every Tier-1 case in this file stays green under it, because "
        "each builds its own surface from ViewModels it took straight from the "
        "session. `main.nim` is compiled by no suite (§7b), so only a case "
        "that runs the BINARY can see this."),

    Arm("E12", LEAVES,
        "      let drewData = renderPaneView(r, node, leaf, GpuiPanelBudget)",
        "      let drewData = true",
        SUITE_EDIT,
        "THE SHIPPED BINARY draws the editor — Tier 2, through --report-plan",
        CTL[LEAVES][0], CTL[LEAVES][1],
        "RESTORES PLAT-21's STATE: the binary draws a pane's NAME instead of "
        "its view. PLAT-21 wrote every debugger pane once in the vocabulary "
        "and a third binding to render them, measured both through three "
        "renderers on a real recording — and nothing in the shipped binary "
        "called either. That is the fifth recording of 'has no production "
        "caller' in this campaign, and this arm is what keeps it from being a "
        "sixth."),

    # ------------------------------------------------------------------
    # UNDECLARED — planted against this milestone's own evidence
    # ------------------------------------------------------------------
    Arm("U1", SURFACE,
        "  if lines.len > 1 and lines[^1].len == 0 and text.len > 0 and\n     text[^1] in {'\\n', '\\r'}:\n    lines.setLen(lines.len - 1)",
        "  if false:\n    lines.setLen(lines.len - 1)",
        SUITE_EDIT,
        "EDIT mode reaches this front-end, reads the CORE's contract, and says what it cannot do",
        CTL[SURFACE][0], CTL[SURFACE][1],
        "UNDECLARED. Every text file ends in a newline, so `splitLines` yields "
        "a final empty element and a four-line file reports five. It is a "
        "one-off that no assertion about the POINTER or the MARKS would ever "
        "see, and it is the number a user counts. Three editors disagreeing "
        "about how long a file is would be found by a user rather than by a "
        "suite, which is why the trim is in the shared derivation and not in a "
        "medium."),

    Arm("U2", LEAVES,
        "    if leaf.kind == glkBuiltin and leaf.builtin == paneEditor:",
        "    if leaf.kind == glkBuiltin and leaf.builtin == paneFlow:",
        SUITE_EDIT,
        "THE SHIPPED BINARY draws the editor — Tier 2, through --report-plan",
        CTL[LEAVES][0], CTL[LEAVES][1],
        "UNDECLARED, AND IT RESTORES A DEFECT THIS MILESTONE MEASURED ON THE "
        "BINARY. Deciding the editor by `leaf.live` rather than by the surface "
        "made `ct edit --ui=gpui <project>` draw 'Editor — waiting for the "
        "session to launch' over a project it had already read off the disk: "
        "`live` asks whether a REPLAY SESSION built a ViewModel, and edit mode "
        "deliberately has no replay session. Pointing the branch at a "
        "different pane is the same loss with the arm aimed at the ORDER "
        "rather than at the predicate."),

    Arm("U3", SURFACE,
        "    if row.held and row.pointer == eptExecution:\n      row.values = valuesForLine(row.text, values)",
        "    if row.held:\n      row.values = valuesForLine(row.text, values)",
        SUITE_EDIT,
        "INLINE VALUES are presented at the GPUI ROW budget, on the execution line only",
        CTL[SURFACE][0], CTL[SURFACE][1],
        "UNDECLARED. The values a ViewModel reports are the values in scope AT "
        "THE STOP. Attaching them to every line that mentions the name puts "
        "the value of `x` at the stop beside a line thirty above it that has "
        "not run yet — a stale value with extra steps, and one that looks "
        "more helpful than the correct rendering, which is why nobody would "
        "report it as a bug."),

    # ------------------------------------------------------------------
    # ADDED BY THE VERIFICATION PASS, 2026-09-16 — two undeclared arms
    # SURVIVED the 10-case, 307-assertion suite, and these are them.
    # ------------------------------------------------------------------
    Arm("E13", SURFACE,
        "  of savVerified: epVerified\n  of savUnverified: epUnverified\n  of savAbsent: epAbsent",
        "  of savVerified: epVerified\n  of savUnverified: epVerified\n  of savAbsent: epAbsent",
        SUITE_EDIT,
        "PROVENANCE reaches the rendered tree, and the three availabilities are three",
        CTL[SURFACE][0], CTL[SURFACE][1],
        "THE EDITOR CERTIFIES BYTES NOBODY RECORDED. CTUI-5's rule is quoted "
        "verbatim in `editor_rows.EditorProvenance`'s own header — *'a file "
        "served savUnverified must not look identical to one served "
        "savVerified. CTUI-4 fought hard for this distinction; do not render "
        "it away'* — and until 2026-09-16 NOTHING in this suite could tell it "
        "from its opposite: this mutation left all ten cases and all 307 "
        "assertions green. Verification-Harness-Traps §7a, in its exact shape. "
        "The case that kills it asserts the three availabilities reach the "
        "RENDERED tree as three different answers, which is the only form an "
        "equality against `provenanceOf` could not have satisfied for free."),

    Arm("E14", LEAVES,
        "  if surface.sourceStatement.len > 0:",
        "  if false and surface.sourceStatement.len > 0:",
        SUITE_EDIT,
        "EDIT mode reaches this front-end, reads the CORE's contract, and says what it cannot do",
        CTL[LEAVES][0], CTL[LEAVES][1],
        "THE PANE STOPS SAYING WHICH MODE'S SOURCE IT IS SHOWING — §2's "
        "Requirement, *'always, not only when they differ'* — and it SURVIVED "
        "on 2026-09-16, over a case that already asserted the statement on the "
        "rendered tree. The check was `contract.statement in "
        "textContent(root)`, and the read-only NOTICE quotes the statement "
        "verbatim, so the containment was satisfied by prose ABOUT the thing "
        "while the thing was gone: Verification-Harness-Traps §4d, arriving "
        "through a suite rather than through a gate. `exactTextNodes` is the "
        "repair — an element whose text IS the statement, which only the "
        "statement's own div can be."),
]
# ---------------------------------------------------------------------------
# plumbing
# ---------------------------------------------------------------------------

def digest(rel: str) -> str:
    return hashlib.sha256((REPO / rel).read_bytes()).hexdigest()


def take_lock():
    """`flock` BEFORE any digest (§14d's corollary).

    A second run in the same worktree legitimately takes the lock; while it
    holds it the tree on disk carries one arm's mutation, and any digest taken
    in that window blesses a mutated file. `rm -f` of the lock file is not
    cleanup — `flock` is on the inode — so the handle is held for the whole
    run and never unlinked.
    """
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    LOCK_FILE.touch(exist_ok=True)
    fh = open(LOCK_FILE, "r+")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("REFUSED: another run holds the lock. Nothing was mutated.")
        sys.exit(3)
    return fh


def _ends_at_line_end(text: str, needle: str) -> tuple[bool, str]:
    """Does `needle` end where its line ends in `text`?

    PLAT-21's second needle check, adopted. Every control here works by
    APPENDING a comment marker to a matched fragment, so a needle that is a
    PREFIX of a longer line comments out the rest of that line: the subject
    stops compiling, the killer case prints no verdict, and the harness reports
    a fourth verdict that reads like a flake. PLAT-21's first graded run scored
    16 of 17 on exactly that, and the defect is STATIC, so it is checked
    statically.

    Applied to `find` as well as to `control_find`, which PLAT-21's own note
    does not spell out and which costs nothing: a mutation whose needle is a
    prefix silently rewrites a line's tail too, so the arm is not the mutation
    its author wrote.
    """
    at = text.find(needle)
    if at < 0:
        return True, ""          # occurrence count reports this separately
    end = at + len(needle)
    if end >= len(text) or text[end] == "\n":
        return True, ""
    rest = text[end:text.find("\n", end) if "\n" in text[end:] else len(text)]
    return False, rest


def needle_scan() -> list[str]:
    """Every arm whose `find` or `control_find` is unaimed.

    TWO CHECKS, not one:

      1. it occurs EXACTLY ONCE — not at least once. An arm whose needle occurs
         twice has two targets and hits neither (§16).
      2. it ENDS AT A LINE END (see `_ends_at_line_end`).
    """
    bad = []
    for arm in ARMS:
        text = (REPO / arm.path).read_text()
        for label, needle in (("find", arm.find),
                              ("control_find", arm.control_find)):
            n = text.count(needle)
            if n != 1:
                bad.append(f"{arm.name}: `{label}` occurs {n} times in "
                           f"{arm.path}, expected exactly 1")
                continue
            ok, rest = _ends_at_line_end(text, needle)
            if not ok:
                bad.append(f"{arm.name}: `{label}` is a PREFIX of a longer "
                           f"line in {arm.path} — the rest is {rest!r}. "
                           f"Appending a comment marker would comment it out.")
    return bad


def report_needle_scan() -> int:
    bad = needle_scan()
    if bad:
        print("NEEDLE SCAN FAILED — these arms are unaimed and cannot be "
              "killed:")
        for b in bad:
            print("  " + b)
        return 1
    print(f"needle scan: {len(ARMS)} arm(s), every `find` and `control_find` "
          f"occurs exactly once")
    return 0


def check_control_hashes() -> bool:
    if not CONTROL_HASHES.exists():
        print("NO CONTROL DIGESTS — run --record-control-hashes first.")
        return False
    ok = True
    for line in CONTROL_HASHES.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        want, rel = line.split(None, 1)
        rel = rel.strip()
        have = digest(rel)
        if have != want:
            print(f"TREE IS NOT AT THE CONTROL BYTES — nothing was mutated.")
            print(f"  {rel}\n      recorded {want[:8]}…   on disk {have[:8]}…")
            ok = False
    return ok


CONTROL_HEADER = """\
# Control digests for run-plat22-mutations.py.
#
# The bytes every arm restores to, and the bytes every arm's verdict was taken
# against. BOTH HALVES OF `TOUCHED` are here — the six mutation subjects AND
# the four suites the arms are graded by — which is Verification-Harness-Traps
# §16c's gap paid rather than inherited: a change that touches only a suite
# invalidates every arm graded against it while producing no overlap signal at
# all in a harness whose TOUCHED names subjects only.
#
# Recorded AFTER running the pre-commit hooks over every file (§16e). `shfmt`,
# `shellcheck`, `end-of-file-fixer`, `trim-trailing-whitespace`,
# `markdownlint-fix` and `cspell` all report Passed with the bytes unchanged,
# so the digests below are the digests the commit carries. Reading the files
# proves nothing here; running the hooks does.
#
# Refreshed with --record-control-hashes, which the needle scan GATES (§16):
# re-recording from a tree whose arms have stopped matching certifies the arms
# along with the bytes.
"""


def write_control_hashes():
    lines = [f"{digest(rel)}  {rel}" for rel in TOUCHED]
    CONTROL_HASHES.write_text(CONTROL_HEADER + "\n".join(lines) + "\n")
    print(f"recorded {len(lines)} control digest(s) to "
          f"{CONTROL_HASHES.relative_to(REPO)}")


def run_suite(suite: str) -> tuple[int, str]:
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    cmd = ["nim", "c", "-r", "--hints:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + SUITE_CMD[suite] + [suite]
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                       timeout=2400)
    return p.returncode, p.stdout + p.stderr


def failure_lines_for(out: str, case: str) -> list[str]:
    """The `Check failed:` lines printed for `case`, in order.

    `unittest` prints the failure lines BEFORE the `[FAILED] <name>` line, so
    the block for a case is everything since the previous verdict line.
    """
    block: list[str] = []
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("[OK]") or s.startswith("[FAILED]"):
            name = s.split("] ", 1)[-1]
            if name == case:
                return block
            block = []
            continue
        block.append(s)
    return []


def verdict_for(out: str, case: str) -> str | None:
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("[OK] ") and s[5:] == case:
            return "OK"
        if s.startswith("[FAILED] ") and s[9:] == case:
            return "FAILED"
    return None


def apply_patch(rel: str, find: str, replace: str):
    path = REPO / rel
    text = path.read_text()
    assert text.count(find) == 1, f"needle not unique in {rel}"
    path.write_text(text.replace(find, replace, 1))


def restore(rel: str, original: str):
    (REPO / rel).write_text(original)


# ---------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------

def load_because() -> dict:
    if BECAUSE_FILE.exists():
        return json.loads(BECAUSE_FILE.read_text())
    return {}


def derive(selected: list[Arm]) -> int:
    derived = {}
    for arm in selected:
        original = (REPO / arm.path).read_text()
        try:
            apply_patch(arm.path, arm.find, arm.replace)
            rc, out = run_suite(arm.suite)
        finally:
            restore(arm.path, original)
        lines = failure_lines_for(out, arm.kills)
        # `unittest` prefixes the line with the FILE AND POSITION, so the
        # marker is not at the start. Taking the substring from the marker is
        # also what makes the derived string position-independent: a line added
        # above the assertion would otherwise change every `because` in the
        # file (§17b's staleness, self-inflicted).
        checks = [l[l.index("Check failed:"):] for l in lines
                  if "Check failed:" in l]
        if not checks:
            print(f"{arm.name}: NO `Check failed:` line for '{arm.kills}' — "
                  f"cannot derive a `because`.")
            print("   verdict was:", verdict_for(out, arm.kills))
            continue
        # The FIRST one: the assertion the mutation reached first.
        text = re.sub(r"\s+", " ", checks[0]).strip()
        derived[arm.name] = text
        print(f"{arm.name}: because = {text}")
    # §17a's closing rule: two arms may not share a `because`.
    seen: dict[str, str] = {}
    clash = False
    for name, text in derived.items():
        if text in seen:
            print(f"REFUSED: {name} and {seen[text]} derived the same "
                  f"`because`; an arm must not be attributable to a case it "
                  f"did not break.")
            clash = True
        seen[text] = name
    if clash:
        return 2
    existing = load_because()
    existing.update(derived)
    BECAUSE_FILE.write_text(json.dumps(existing, indent=2, sort_keys=True)
                            + "\n")
    print(f"wrote {len(derived)} derived `because` string(s) to "
          f"{BECAUSE_FILE.relative_to(REPO)}")
    return 0


def grade(selected: list[Arm]) -> int:
    because = load_because()
    missing = [a.name for a in selected if a.name not in because]
    if missing:
        print(f"REFUSED: no derived `because` for {', '.join(missing)}. "
              f"Run --derive first; a typed one is a second copy of the code "
              f"(§17a).")
        return 2

    results = []
    for arm in selected:
        original = (REPO / arm.path).read_text()
        before = hashlib.sha256(original.encode()).hexdigest()

        # 1. the arm
        try:
            apply_patch(arm.path, arm.find, arm.replace)
            rc, out = run_suite(arm.suite)
        finally:
            restore(arm.path, original)
        after = hashlib.sha256((REPO / arm.path).read_bytes()).hexdigest()
        if after != before:
            results.append((arm, "HARNESS-FAILURE",
                            "the revert did not restore the bytes"))
            continue

        if "Error: " in out and "[OK]" not in out and "[FAILED]" not in out:
            results.append((arm, "DID-NOT-COMPILE", ""))
            continue

        v = verdict_for(out, arm.kills)
        if v is None:
            # §1a's mirror: a mutant that crashed the case prints no verdict
            # line for it, and a line parser folds that into SURVIVED.
            results.append((arm, "NO-VERDICT-FOR-KILLER",
                            "the run told you nothing"))
            continue
        if v == "OK":
            results.append((arm, "SURVIVED", ""))
            continue

        raw = failure_lines_for(out, arm.kills)
        lines = " ".join(l[l.index("Check failed:"):] if "Check failed:" in l
                         else l for l in raw)
        lines = re.sub(r"\s+", " ", lines)
        if because[arm.name] not in lines:
            results.append((arm, "MIS-ATTRIBUTED",
                            f"expected: {because[arm.name]}"))
            continue

        # 2. the behaviour-preserving control
        try:
            apply_patch(arm.path, arm.control_find, arm.control_replace)
            crc, cout = run_suite(arm.suite)
        finally:
            restore(arm.path, original)
        cafter = hashlib.sha256((REPO / arm.path).read_bytes()).hexdigest()
        if cafter != before:
            results.append((arm, "HARNESS-FAILURE",
                            "the control revert did not restore the bytes"))
            continue
        if verdict_for(cout, arm.kills) != "OK":
            results.append((arm, "CONTROL-HARNESS-FAILURE",
                            "the behaviour-preserving control reddened the "
                            "killer case"))
            continue

        results.append((arm, "KILLED", ""))

    print()
    print("| arm | subject | verdict | note |")
    print("|-----|---------|---------|------|")
    for arm, verdict, note in results:
        print(f"| {arm.name} | {Path(arm.path).name} | **{verdict}** | "
              f"{note} |")
    killed = sum(1 for _, v, _ in results if v == "KILLED")
    print()
    print(f"{killed} of {len(results)} KILLED")
    return 0 if killed == len(results) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    ap.add_argument("--derive", action="store_true")
    ap.add_argument("--only", default="")
    args = ap.parse_args()

    fh = take_lock()  # BEFORE any digest.

    if args.needle_scan:
        return report_needle_scan()

    if args.record_control_hashes:
        # §16: the scan GATES the recording. Recording first would certify a
        # tree in which an arm describes nothing.
        rc = report_needle_scan()
        if rc:
            return rc
        write_control_hashes()
        return 0

    rc = report_needle_scan()
    if rc:
        return rc
    if not check_control_hashes():
        return 3

    selected = ARMS
    if args.only:
        want = {s.strip() for s in args.only.split(",")}
        selected = [a for a in ARMS if a.name in want]
        if not selected:
            print(f"no arm matches {args.only}")
            return 2

    if args.derive:
        return derive(selected)
    return grade(selected)


if __name__ == "__main__":
    sys.exit(main())
