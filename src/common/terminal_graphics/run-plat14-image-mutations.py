#!/usr/bin/env python3
"""Mutation harness for PLAT-14's terminal image rendering.

WHAT THIS COVERS. CodeTracer-TUI-Graphics.md §2 (the seven tiers, the per-cell
error minimisation, the aspect correction), §3 (multiplexers, SSH, the
placement identifiers and the rule that detection fails toward the safer tier)
and the PLAT-12 media path PLAT-14 widens. Eight subject files, four suites.

WHY THE ARMS ARE AIMED WHERE THEY ARE. This milestone's substance is a
DECISION and a BYTE STRING, and the two have different failure modes:

  * the decision (`app/theme/image_capability.nim`) fails by being OPTIMISTIC,
    and §3 says an optimistic failure is worse than the degradation it avoids —
    so every refusal arm below removes ONE refusal and asks whether anything
    notices (M1-M8);
  * the byte string (`terminal_graphics/emit.nim`) fails by carrying the wrong
    bytes or the wrong NUMBER of them, and the second is where a bound written
    against the wrong unit hides (M9-M13);
  * the tier model and the glyph tables fail by drawing a DIFFERENT picture
    rather than a coarser one, which §2.5 forbids and which no status can
    report (M14-M19);
  * the media widening fails by claiming a capability the terminal does not
    have, which puts PLAT-12's blank region back (M20-M22);
  * **the OVERRIDE fails by inventing evidence** (M27-M31). Every arm before
    M27 grades the automatic answer, and the one path allowed to beat it had
    no arm at all — so a guard written against the DA1 fence, and a chain
    ending `else: ipITerm2`, sat in a landed tree. Added 2026-09-14 from the
    landing pass's F1;
  * **the FLAG fails by not being read** (M33, M34). `--image-tier` is half of
    deliverable 4 and no test called `parseTuiCommand` with it, so deleting
    the branch and deleting its refusal both left two suites green. F2.

IT IS A SEPARATE FILE FROM THE PLAT-7 … PLAT-13 HARNESSES, for the reason
PLAT-8's header gives: each records control digests over its own campaign's
subjects, and merging them would mean one `--record-control-hashes` step
re-blessing several campaigns' files at once.

**AND IT MUST NOT RUN BESIDE THEM.** The locks are per harness and do not
serialise against each other, and PLAT-14's SUITES compile files other
harnesses own — `test_terminal_media_capability.nim` compiles
`value_presentation/surfaces.nim` and `value_visualisers.nim`, which are
PLAT-12's subjects, so a PLAT-12 arm reddens this harness's unmutated control.
Run one harness at a time.

FIVE VERDICTS, NOT TWO (Verification-Harness-Traps §1a and §17):

  killed           the named case reported [FAILED] **and** the failure output
                   carries the arm's own `because`
  MIS-ATTRIBUTED   the named case went red, but not for the arm's reason — it
                   died upstream of the mutated line (§17)
  SUITE-DIED       the binary produced result lines and the killer case was in
                   neither list, so it never ran
  SURVIVED         nothing noticed
  HARNESS-FAILURE  the arm could not be applied, or a restore did not restore

THE VERDICT IS PARSED FROM `[OK]`/`[FAILED]` LINES AND NEVER FROM AN EXIT
CODE. `std/unittest` exits non-zero for a compile-time abort, for a raised
exception and for a failed check alike, and three causes behind one number is
not a result.

THE `because` NEEDLES ARE DERIVED FROM TRANSCRIPTS, NOT TYPED FROM THE SOURCE
(§17a). Every string below was read out of a run in which the arm was applied;
`nim`'s `check` prints the failing expression AND each operand's value, and it
is the operand VALUE that says the mutation is what moved. A `because` typed
from the source would be a second copy of the code in a file the compiler does
not read.

THE NEEDLE SCAN GATES `--record-control-hashes` (§16). Blessing new bytes as
the baseline is exactly the moment an arm's needle has just been moved, and
recording first would certify the drift.

Usage:
    direnv exec . python3 -u src/common/terminal_graphics/run-plat14-image-mutations.py
    …                                      --needle-scan
    …                                      --record-control-hashes
    …                                      M4 M9        # individual arms
    …                                      --explain M4 # one arm, verbatim
"""

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
ROOT = HERE.parents[2]

# --- the files an arm may touch -------------------------------------------

TIERS = "src/common/terminal_graphics/tiers.nim"
RENDER = "src/common/terminal_graphics/cell_render.nim"
ASPECT = "src/common/terminal_graphics/aspect.nim"
OKLAB = "src/common/terminal_graphics/oklab.nim"
EMIT = "src/common/terminal_graphics/emit.nim"
CAP = "src/frontend/tui/app/theme/image_capability.nim"
MEDIA = "src/common/terminal_graphics/media.nim"
CLI = "src/frontend/tui/app/cli.nim"
# ADDED 2026-09-14, and the reason is the whole of finding F2. `--image-tier`
# was a ticked deliverable whose PARSER no arm and no case reached: deleting
# the entire branch from `cli.nim`, and deleting only its usage-error arm, both
# left every suite in this campaign green. A flag that is parsed into a value
# nothing asserts is a promise measured nowhere, so the parser is a subject of
# this harness now (M33, M34) and `test_image_capability.nim` calls
# `parseTuiCommand`.

TOUCHED = [TIERS, RENDER, ASPECT, OKLAB, EMIT, CAP, MEDIA, CLI]

RENDER_SUITE = "src/common/terminal_graphics/cell_render_test.nim"
EMIT_SUITE = "src/common/terminal_graphics/emit_test.nim"
CAP_SUITE = "src/frontend/tui/app/tests/test_image_capability.nim"
MEDIA_SUITE = ("src/frontend/viewmodel/tests/unit/"
               "test_terminal_media_capability.nim")

CONTROL_HASHES = HERE / "plat14-image-mutation-control.sha256"
LOCK_PATH = HERE / ".plat14-image-mutation.lock"

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

# `cell_render_test.nim`
R_ORDINAL = "the ordinal IS the specification's tier number"
R_WEAKER = "weakerOf picks the tier that asks LESS of the terminal"
R_GEOMETRY = "§2.1's geometry column, and the candidate bound derived from it"
R_AUTOMATIC = "the three tiers that are not automatically selectable, named"
R_NAMES = "the tier names round-trip, and an unknown name fails to the WEAKEST"
R_GAMMA = "the sRGB transfer function is applied, by its number"
R_WEIGHTS = "green is weighted above blue, which is why sRGB error is wrong"
R_QUADRANT = "every quadrant mask has a distinct glyph in the block-elements range"
R_SEXTANT = "every sextant mask has a distinct glyph, and the four legacy ones"
R_BRAILLE = "every braille mask has a distinct glyph inside U+2800..U+28FF"
R_OCTANT = "octants REFUSE rather than drawing an unverified table"
R_RAMP = "the ascii ramp is monotone and stays inside ASCII"
R_ASPECT = "a square source fits twice as many columns as rows at a 1:2 cell"
R_SQUARE = "a square cell needs no correction, and the model says so"
R_TIERFIT = "the fit is the SAME at every drawable cell tier"
R_EXACT = "a half block over two bands is EXACT, and the two colours are the two"
R_FLIP = "the same two bands the other way up pick the other glyph"
R_CANDIDATES = "the search evaluates EXACTLY the bounded candidate set, per cell"
R_BOX = "the box filter is the mean, computed independently"

# `emit_test.nim`
E_KITTY = "a Kitty transmission is the documented APC, written out"
E_CHUNKS = "a payload over one chunk is split at exactly the documented size"
E_PLACE = "a placement re-displays without the payload, in under 64 bytes"
E_ITERM = "an iTerm2 inline image is the documented OSC, written out"
E_TMUX = "tmux passthrough doubles every ESC, and only ESC"
E_CELL = "one half-block cell is one SGR pair and one glyph"
E_SGR = "SGR is emitted on change only, so a flat region costs one glyph each"
E_SCRUB = "the second emission of one image carries no payload at all"
E_BUDGET = "a payload under the budget whose EMISSION is over it is refused"
E_SCAN = "containsGraphicsEscape finds a graphics escape, and only one"
E_ASCII = "an ASCII cell carries a foreground and NO background at all"

# `test_image_capability.nim`
C_TABLE = "every environment resolves to the documented tier AND reason"
C_FLOOR = "the refusals are not all one value, and tier 0 is really reached"
C_AUTO = "automatic selection never leaves AutomaticTiers"
C_SWEEP = "the whole cross product, each compared with its more certain twin"
C_PROBE = "an unanswered probe is never better than no probe at all"
C_PINNED = "--image-tier reaches the three tiers detection never picks"
C_OVERRIDE = "a pinned tier 0 wins over a refusal, and the refusal is still SAID"
C_NOPROTO = "a pinned tier 0 with NO protocol anywhere is the one case it loses"
C_LINK = "an SSH session carries a budget and a local one does not"
C_DEMOTE = "an oversized tier-0 emission demotes, measured in EMITTED bytes"
C_WIRE = "a refused environment emits NO graphics escape, and a permitted one does"
C_PINTABLE = "a pinned tier 0 over EVERY advertisement and EVERY probe outcome"
C_CLI = ("the CLI parses --image-tier into the flag, and refuses an unknown "
         "name")

# `test_terminal_media_capability.nim`
M_TABLE = "tier 0 widens the set; every cell tier does not"
M_FLOOR = "the seven declared surface budgets are UNCHANGED by this milestone"
M_DRAWN = "a PNG declaration DRAWS on a Kitty terminal's tree budget"
M_DESKTOP = "the SAME value on the desktop's state panel degrades, and says why"
M_CELLS = "the SAME value on a terminal with no graphics protocol degrades too"
M_JPEG = "a JPEG draws on iTerm2 and degrades on Kitty, same value, same rule"


@dataclass
class Suite:
    path: str
    binary: str
    extra_path: bool = False


NIM_RENDER = Suite(RENDER_SUITE, "/tmp/plat14-mut-render")
NIM_EMIT = Suite(EMIT_SUITE, "/tmp/plat14-mut-emit")
NIM_CAP = Suite(CAP_SUITE, "/tmp/plat14-mut-cap", extra_path=True)
NIM_MEDIA = Suite(MEDIA_SUITE, "/tmp/plat14-mut-media", extra_path=True)


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


DECLARED_SURVIVORS: list[Mutation] = []


MUTATIONS: list[Mutation] = [
    # -- §3's refusals: each one removed, and asked whether anything notices --
    Mutation(
        "M1", CAP,
        "  elif mux == muxScreen:\n    refusal = prScreenNeverPasses",
        "  elif false:\n    refusal = prScreenNeverPasses",
        C_TABLE, NIM_CAP,
        "kitty under screen [§3 screen generally will not pass graphics protocols "
        "at all] -> image-tier=protocol(environment) protocol=ipKitty "
        "advertised=ipKitty mux=screen",
        control_name="the screen arm, spelled with the enum compared the other way",
        control_find="  elif mux == muxScreen:\n    refusal = prScreenNeverPasses",
        control_replace="  elif muxScreen == mux:\n    refusal = prScreenNeverPasses"),
    Mutation(
        "M2", CAP,
        "  elif mux == muxUnknown:\n    refusal = prMultiplexerUnproven",
        "  elif mux == muxNone:\n    refusal = prMultiplexerUnproven",
        C_TABLE, NIM_CAP,
        "cap.tier was itProtocol",
        why="TERM=screen-256color with no $TMUX and no $STY is the ambiguous "
            "path; treating it as 'no multiplexer' is the optimistic reading.",
        control_name="the ambiguous-multiplexer arm, with the comparison reversed",
        control_find="  elif mux == muxUnknown:\n    refusal = prMultiplexerUnproven",
        control_replace="  elif muxUnknown == mux:\n    refusal = prMultiplexerUnproven"),
    Mutation(
        "M3", CAP,
        "  elif probe.attempted and not probe.answered:",
        "  elif probe.attempted and probe.answered and false:",
        C_TABLE, NIM_CAP,
        "a probe was sent down a live path and NOTHING came back [§3 a failed "
        "graphics probe must fall back silently] -> "
        "image-tier=protocol(environment) protocol=ipKitty",
        why="§3's 'a failed graphics probe must fall back silently'. Removing "
            "this arm makes a measured negative lose to an advertisement.",
        control_name="the unanswered-probe arm, with the conjunction reordered",
        control_find="  elif probe.attempted and not probe.answered:",
        control_replace="  elif (not probe.answered) and probe.attempted:"),
    Mutation(
        "M4", CAP,
        "  elif mux == muxTmux and not (measuredProtocol(probe) and\n"
        "                               ienv.passthrough == ptOn):",
        "  elif mux == muxTmux and not (probe.answered and\n"
        "                               ienv.passthrough == ptOn):",
        C_TABLE, NIM_CAP,
        "cap.wrapForMultiplexer was true",
        why="THE DEFECT §3 NAMES BY HAND: tmux answers the DA1 fence ITSELF "
            "whether or not it forwards APC, so a rule written against "
            "`probe.answered` is satisfied by exactly the configuration that "
            "accepts the escape and shows nothing.",
        control_name="the tmux arm, with the conjunction's operands swapped",
        control_find="  elif mux == muxTmux and not (measuredProtocol(probe) and\n"
                     "                               ienv.passthrough == ptOn):",
        control_replace="  elif mux == muxTmux and not (ienv.passthrough == ptOn and\n"
                        "                               measuredProtocol(probe)):"),
    Mutation(
        "M5", CAP,
        "  probe.attempted and probe.answered and (probe.kitty or probe.iterm2)",
        "  probe.attempted and probe.answered",
        C_TABLE, NIM_CAP,
        "cap.wrapForMultiplexer was true",
        why="`measuredProtocol` widened to 'the path is alive' is M4 by a "
            "different door — the predicate, rather than its call site.",
        control_name="measuredProtocol, with the disjunction's operands swapped",
        control_find="  probe.attempted and probe.answered and (probe.kitty or probe.iterm2)",
        control_replace="  probe.attempted and probe.answered and (probe.iterm2 or probe.kitty)"),
    Mutation(
        "M6", CAP,
        "  if ienv.tmux.len > 0: return muxTmux\n  if ienv.sty.len > 0: return muxScreen",
        "  if ienv.tmux.len > 0: return muxTmux\n  if false: return muxScreen",
        C_TABLE, NIM_CAP,
        "kitty under screen [§3 screen generally will not pass graphics protocols "
        "at all] -> image-tier=protocol(environment) protocol=ipKitty "
        "advertised=ipKitty mux=none",
        control_name="the $STY test, written as an emptiness comparison",
        control_find="  if ienv.sty.len > 0: return muxScreen",
        control_replace='  if ienv.sty != "": return muxScreen'),
    Mutation(
        "M7", CAP,
        '  if term.startsWith("screen") or term.startsWith("tmux"):\n'
        "    return muxUnknown",
        '  if term.startsWith("screen") and term.startsWith("tmux"):\n'
        "    return muxUnknown",
        C_TABLE, NIM_CAP,
        "TERM says screen but no multiplexer variable is set [§3 the ambiguous "
        "path resolves to the treatment that asks least] -> "
        "image-tier=protocol(environment) protocol=ipKitty "
        "advertised=ipKitty mux=none",
        control_name="the TERM test, with the disjunction's operands swapped",
        control_find='  if term.startsWith("screen") or term.startsWith("tmux"):',
        control_replace='  if term.startsWith("tmux") or term.startsWith("screen"):'),
    Mutation(
        "M8", CAP,
        "  if refusal == prNone and protocol == ipSixel:",
        "  if false and protocol == ipSixel:",
        C_TABLE, NIM_CAP,
        "cap.protocol was ipSixel",
        why="Selecting a protocol this build cannot emit turns a picture into "
            "an exception (`emit.emitProtocolImage` raises for `ipSixel`).",
        control_name="the sixel refusal, with the conjunction's operands swapped",
        control_find="  if refusal == prNone and protocol == ipSixel:",
        control_replace="  if protocol == ipSixel and refusal == prNone:"),

    # -- the bytes, and the unit the budget is written in --------------------
    Mutation(
        "M9", EMIT,
        "func emittedBytes*(e: EmittedImage): int {.inline.} = e.bytes.len",
        "func emittedBytes*(e: EmittedImage): int {.inline.} = e.imageId.int",
        E_BUDGET, NIM_EMIT,
        "emission.emittedBytes == emission.bytes.len",
        why="THE UNIT HAZARD, as an arm: a measurement that is not the length "
            "of the string that was written.",
        control_name="emittedBytes, spelled with an explicit len call",
        control_find="func emittedBytes*(e: EmittedImage): int {.inline.} = e.bytes.len",
        control_replace="func emittedBytes*(e: EmittedImage): int {.inline.} = len(e.bytes)"),
    Mutation(
        "M10", EMIT,
        "  e.linkBudget == 0 or e.emittedBytes <= budget",
        "  e.linkBudget == 0 or e.emittedBytes <= budget",
        E_BUDGET, NIM_EMIT,
        "",
        why="placeholder — replaced below"),
    Mutation(
        "M11", EMIT,
        "    if alreadyUploaded:\n      body = kittyPlace(imageId, placementId, cols, rows)\n"
        "      reused = true",
        "    if alreadyUploaded:\n      body = kittyTransmit(payload, imageId, cols, rows)\n"
        "      reused = true",
        E_SCRUB, NIM_EMIT,
        "second.bytes.contains(AbcBase64)",
        why="§3's placement rule removed: the scrub re-uploads while still "
            "REPORTING that it re-placed, which is the report-versus-effect "
            "shape this campaign keeps meeting.",
        control_name="the placement branch, with the two statements' order preserved "
                     "and the flag set first",
        control_find="    if alreadyUploaded:\n      body = kittyPlace(imageId, placementId, cols, rows)\n"
                     "      reused = true",
        control_replace="    if alreadyUploaded:\n      reused = true\n"
                        "      body = kittyPlace(imageId, placementId, cols, rows)"),
    Mutation(
        "M12", EMIT,
        "      inner.add \"\\x1b\\x1b\"",
        "      inner.add \"\\x1b\"",
        E_TMUX, NIM_EMIT,
        r'Check failed: wrapped == "\ePtmux;"',
        why="A tmux passthrough that wraps but does not double is delivered to "
            "the outer terminal truncated at the first `ESC \\`.",
        control_name="the ESC doubling, written as two adds",
        control_find="      inner.add \"\\x1b\\x1b\"",
        control_replace="      inner.add \"\\x1b\"\n      inner.add \"\\x1b\""),
    Mutation(
        "M13", EMIT,
        "    let chunkEnd = min(pos + KittyChunkBytes, b64.len)",
        "    let chunkEnd = min(pos + KittyChunkBytes + 1, b64.len)",
        E_CHUNKS, NIM_EMIT,
        "Check failed: stop - semi - 1 <= KittyChunkBytes",
        control_name="the chunk boundary, with the min's operands swapped",
        control_find="    let chunkEnd = min(pos + KittyChunkBytes, b64.len)",
        control_replace="    let chunkEnd = min(b64.len, pos + KittyChunkBytes)"),

    # -- the tier model and the glyph tables ---------------------------------
    Mutation(
        "M14", TIERS,
        "  if ord(a) >= ord(b): a else: b",
        "  if ord(a) <= ord(b): a else: b",
        R_WEAKER, NIM_RENDER,
        "weakerOf(itProtocol, itAscii) == itAscii",
        why="The lattice inverted. Every 'fail toward the safer tier' rule in "
            "the product is a call to this one function.",
        control_name="weakerOf, with the comparison written the other way round",
        control_find="  if ord(a) >= ord(b): a else: b",
        control_replace="  if ord(b) <= ord(a): a else: b"),
    Mutation(
        "M15", TIERS,
        "  (false, itAscii)",
        "  (false, itProtocol)",
        R_NAMES, NIM_RENDER,
        "fallback == itAscii",
        why="`ImageTier`'s ZERO VALUE is tier 0, so a parse failure that "
            "defaulted would hand a caller the tier that can put escape bytes "
            "on a screen — PLAT-12's `Visualiser.tier` defect in a new place.",
        control_name="the failure value, spelled as the enum's high member",
        control_find="  (false, itAscii)",
        control_replace="  (false, high(ImageTier))"),
    Mutation(
        "M16", TIERS,
        "  AutomaticTiers* = {itProtocol, itHalfBlock, itBraille, itAscii}",
        "  AutomaticTiers* = {itProtocol, itHalfBlock, itSextant, itBraille, itAscii}",
        R_AUTOMATIC, NIM_RENDER,
        "itSextant notin AutomaticTiers",
        control_name="the automatic set, with its members reordered",
        control_find="  AutomaticTiers* = {itProtocol, itHalfBlock, itBraille, itAscii}",
        control_replace="  AutomaticTiers* = {itAscii, itBraille, itHalfBlock, itProtocol}"),
    Mutation(
        "M17", RENDER,
        "  if mask > 0b101010: dec index\n  if mask > 0b010101: dec index",
        "  if mask > 0b010101: dec index",
        R_SEXTANT, NIM_RENDER,
        "Check failed: glyphFor(itSextant, "
        "0b00000000000000000000000000111110) ==",
        why="The U+1FB00 run skips four masks that already have legacy "
            "spellings; one decrement dropped shifts sixty glyphs by one, "
            "which draws a DIFFERENT picture rather than a coarser one.",
        control_name="the two decrements, with the tests written as >= on the "
                     "next value",
        control_find="  if mask > 0b101010: dec index\n  if mask > 0b010101: dec index",
        control_replace="  if mask >= 0b101011: dec index\n  if mask >= 0b010110: dec index"),
    Mutation(
        "M18", RENDER,
        "  BrailleDotBits: array[8, int] = [0x01, 0x08, 0x02, 0x10,\n"
        "                                   0x04, 0x20, 0x40, 0x80]",
        "  BrailleDotBits: array[8, int] = [0x01, 0x02, 0x04, 0x08,\n"
        "                                   0x10, 0x20, 0x40, 0x80]",
        R_BRAILLE, NIM_RENDER,
        "Check failed: glyphFor(itBraille, "
        "0b00000000000000000000000000000010) ==",
        why="Braille numbers its dots DOWN the left column and then down the "
            "right, which is not row-major. A row-major table is a transposed "
            "picture that still has 256 distinct glyphs.",
        control_name="the dot table, with the same eight values written in hex "
                     "with leading zeroes",
        control_find="  BrailleDotBits: array[8, int] = [0x01, 0x08, 0x02, 0x10,\n"
                     "                                   0x04, 0x20, 0x40, 0x80]",
        control_replace="  BrailleDotBits: array[8, int] = [0x001, 0x008, 0x002, 0x010,\n"
                        "                                   0x004, 0x020, 0x040, 0x080]"),
    Mutation(
        "M19", ASPECT,
        "  var rows = int(round(float(cols) * float(aspect.widthPx) *\n"
        "                       float(sourceHeight) /\n"
        "                       (float(aspect.heightPx) * float(sourceWidth))))",
        "  var rows = int(round(float(cols) * float(sourceHeight) /\n"
        "                       float(sourceWidth)))",
        R_ASPECT, NIM_RENDER,
        "fit.rows == 10",
        why="§2.4's correction removed: the picture is stretched vertically by "
            "two, which is the defect the section exists for and which no "
            "status reports.",
        control_name="the correction, with the two products written in the "
                     "other order",
        control_find="  var rows = int(round(float(cols) * float(aspect.widthPx) *\n"
                     "                       float(sourceHeight) /\n"
                     "                       (float(aspect.heightPx) * float(sourceWidth))))",
        control_replace="  var rows = int(round(float(sourceHeight) * float(aspect.widthPx) *\n"
                        "                       float(cols) /\n"
                        "                       (float(sourceWidth) * float(aspect.heightPx))))"),
    Mutation(
        "M20", OKLAB,
        "  if c <= 0.04045: c / 12.92\n  else: pow((c + 0.055) / 1.055, 2.4)",
        "  if c <= 0.04045: c\n  else: c",
        R_GAMMA, NIM_RENDER,
        "abs(mid.l - 0.6) was 0.1947",
        why="§2.3's whole reason for the space. Without the transfer function "
            "the metric is a linear-in-bytes distance wearing Oklab's name, "
            "and the banding it produces is exactly what the section warns of.",
        control_name="the transfer function, with the threshold written as a "
                     "strict comparison on the other side",
        control_find="  if c <= 0.04045: c / 12.92\n  else: pow((c + 0.055) / 1.055, 2.4)",
        control_replace="  if not (c > 0.04045): c / 12.92\n  else: pow((c + 0.055) / 1.055, 2.4)"),

    # -- the media widening, which must follow the EMITTER -------------------
    Mutation(
        "M21", MEDIA,
        "  if tier != itProtocol:\n    return",
        "  if false:\n    return",
        M_TABLE, NIM_MEDIA,
        "terminalMediaCapability(tier, ipKitty) == MediaCapabilityNote",
        why="PLAT-12's blank region, put back: a cell tier claiming `image/png` "
            "declares a capability nothing implements, and the value degrades "
            "into nothing instead of degrading honestly.",
        control_name="the tier test, written as a positive membership test",
        control_find="  if tier != itProtocol:\n    return",
        control_replace="  if not (tier == itProtocol):\n    return"),
    Mutation(
        "M22", MEDIA,
        "  of ipKitty: result.incl mcImagePng",
        "  of ipKitty:\n    result.incl mcImagePng\n    result.incl mcImageJpeg",
        M_JPEG, NIM_MEDIA,
        "onKitty.mediaGaps.len == 1",
        why="Kitty's `f=100` is PNG. A JPEG handed to it is transmitted and "
            "rejected, which is a blank region with extra steps.",
        control_name="the Kitty arm, written as a set union",
        control_find="  of ipKitty: result.incl mcImagePng",
        control_replace="  of ipKitty: result = result + {mcImagePng}"),
    Mutation(
        "M23", CAP,
        "  if cap.tier != itProtocol: return cap",
        "  if cap.tier == itProtocol: return cap",
        C_DEMOTE, NIM_CAP,
        "demoted.tier == itHalfBlock",
        why="§3's link rule removed: a megabyte frame goes down a constrained "
            "link on every distinct image.",
        control_name="the early return, written as a positive test",
        control_find="  if cap.tier != itProtocol: return cap",
        control_replace="  if not (cap.tier == itProtocol): return cap"),
    Mutation(
        "M24", CAP,
        "  linkBudget: (if ssh: MaxLinkImageBytes else: 0))",
        "  linkBudget: (if ssh: 0 else: 0))",
        C_LINK, NIM_CAP,
        "remote.linkBudget == MaxLinkImageBytes",
        control_name="the link budget, with the condition negated and the arms "
                     "swapped",
        control_find="  linkBudget: (if ssh: MaxLinkImageBytes else: 0))",
        control_replace="  linkBudget: (if not ssh: 0 else: MaxLinkImageBytes))"),
    Mutation(
        "M25", CAP,
        "  if flags.imageTierPinned:",
        "  if false:",
        C_PINNED, NIM_CAP,
        "cap.tier == tier",
        why="§2.2: 'an explicit flag always beats a probe'. A flag that is "
            "parsed and then not read is the shape `app/cli.nim`'s own header "
            "refuses.",
        control_name="the pin test, written as an inequality against false",
        control_find="  if flags.imageTierPinned:",
        control_replace="  if flags.imageTierPinned != false:"),
    Mutation(
        "M26", CAP,
        "  if isDumbTerminal(env): return urAscii\n  if caps.borders == bmAscii: return urAscii\n"
        "  urWide3_2",
        "  if isDumbTerminal(env): return urAscii\n  if caps.borders == bmAscii: return urAscii\n"
        "  urOctants16",
        C_AUTO, NIM_CAP,
        "cap.repertoire was urOctants16",
        why="The repertoire raised to a rung no probe can establish. Sextants "
            "and octants need a FONT, and a terminal that lacks the glyph "
            "draws a grid of tofu — a DIFFERENT picture, not a coarser one.",
        control_name="the repertoire, with the two guards' order preserved and "
                     "the locale test written positively",
        control_find="  if caps.borders == bmAscii: return urAscii",
        control_replace="  if not (caps.borders != bmAscii): return urAscii"),

    # -- THE OVERRIDE PATH (landing-pass finding F1) -------------------------
    #
    # Everything above M27 grades the AUTOMATIC answer. Nothing graded the one
    # path that is allowed to beat it, and the three arms here are the three
    # undeclared mutations that SURVIVED the 14-case suite the landing pass
    # shipped — U6, U7 and the sixel admission. They are arms now because the
    # guard they attack was written against `probe.answered`, the DA1 fence,
    # which `GraphicsProbe.answered`'s own doc says every terminal and every
    # multiplexer answers: it fired only when NOTHING replied, so a terminal
    # that advertised no protocol and merely answered DA1 was handed `ipITerm2`
    # by the last arm of an `if` chain.
    Mutation(
        "M27", CAP,
        "    if flags.imageTier == itProtocol and pinnable == ipNone:",
        "    if flags.imageTier == itProtocol and advertised == ipNone:",
        C_PINTABLE, NIM_CAP,
        "cap.protocol was ipNone",
        why="U6: the guard tests the ADVERTISEMENT rather than the protocol an "
            "emission would actually use. Wrong in BOTH directions at once — a "
            "measured Kitty reply with no advertisement is refused, and a "
            "Sixel advertisement this build cannot emit is honoured into a "
            "tier-0 capability with no protocol in it.",
        control_name="the pin guard, with the conjunction's operands swapped",
        control_find="    if flags.imageTier == itProtocol and pinnable == ipNone:",
        control_replace="    if pinnable == ipNone and flags.imageTier == itProtocol:"),
    Mutation(
        "M28", CAP,
        "    if probe.iterm2: return ipITerm2\n  ipNone",
        "    if probe.iterm2: return ipITerm2\n  ipITerm2",
        C_PINTABLE, NIM_CAP,
        "cap.tier was itProtocol",
        why="U7: the SYNTHESIS, restored. `emittableProtocol`'s last line is "
            "the whole of 'a protocol nothing named is never invented' — the "
            "shipped code used to end `else: ipITerm2`, and `probe.iterm2` is "
            "documented always-false, so that arm was an unconditional guess "
            "at a terminal that had claimed nothing.",
        control_name="the no-protocol answer, written through result",
        control_find="    if probe.iterm2: return ipITerm2\n  ipNone",
        control_replace="    if probe.iterm2: return ipITerm2\n  result = ipNone"),
    Mutation(
        "M29", CAP,
        "  if advertised in EmittableProtocols: return advertised",
        "  if advertised != ipNone: return advertised",
        C_PINTABLE, NIM_CAP,
        "cap.protocol was ipSixel",
        why="The admission widened to every advertisement. `ipSixel` reaches "
            "`emit.emitProtocolImage`, which RAISES for it — the pin turns a "
            "picture into an exception, which is the exact outcome "
            "`prSixelHasNoEncoder` exists to prevent on the automatic path.",
        control_name="the emittable test, written as a double negative",
        control_find="  if advertised in EmittableProtocols: return advertised",
        control_replace="  if not (advertised notin EmittableProtocols): return advertised"),
    Mutation(
        "M30", CAP,
        "  elif advertised == ipKitty and probe.attempted and probe.answered and\n"
        "       not probe.kitty:",
        "  elif advertised == ipKitty and probe.attempted and probe.answered and\n"
        "       probe.kitty and false:",
        C_TABLE, NIM_CAP,
        # DERIVED FROM THE TRANSCRIPT (§17a), and the first spelling —
        # `cap.refusal was prNone` — was MIS-ATTRIBUTED over a mutation that
        # killed its case exactly as intended: `ProtocolRefusal`'s members carry
        # string values, so `unittest` prints `none`, not `prNone`.
        "cap.refusal was none",
        why="THE THIRD SITE, and the same root cause as M4 one arm further "
            "down the chain: a probe that reached the far end and came back "
            "WITHOUT the Kitty reply is a measured negative about the one "
            "protocol that can be measured. Removing this arm makes that "
            "measurement decisive under tmux and ignored locally — the same "
            "bytes meaning two different things depending on whether $TMUX "
            "happens to be set.",
        control_name="the graphics-silence arm, with the conjunction reordered",
        control_find="  elif advertised == ipKitty and probe.attempted and probe.answered and\n"
                     "       not probe.kitty:",
        control_replace="  elif probe.attempted and probe.answered and (not probe.kitty) and\n"
                        "       advertised == ipKitty:"),
    Mutation(
        "M31", CAP,
        "  if cap.tierFrom == csFlag: return cap",
        "  if false: return cap",
        C_DEMOTE, NIM_CAP,
        "notDemoted.tier was itHalfBlock",
        why="U5: §2.2's 'always wins' applied to the rule that runs AFTER the "
            "decision. An argued asymmetry with no case — the landing pass's "
            "suite was green over its opposite, which is §7a's deliberate "
            "asymmetry in a doc comment.",
        control_name="the pin exemption, written as a double negative",
        control_find="  if cap.tierFrom == csFlag: return cap",
        control_replace="  if not (cap.tierFrom != csFlag): return cap"),
    Mutation(
        "M32", EMIT,
        "        if grid.tier != itAscii and (not haveBg or cell.bg != lastBg):",
        "        if (not haveBg or cell.bg != lastBg):",
        E_ASCII, NIM_EMIT,
        # DERIVED FROM THE TRANSCRIPT (§17a), and it quotes the EFFECT rather
        # than the report: the background escape is IN the bytes. The first
        # spelling quoted the source (`\x1b`) and `unittest` renders the
        # substituted AST with `\e`, so a correct arm scored MIS-ATTRIBUTED.
        'asciiBytes.contains("\\e[48;2;") was true',
        why="U4: the ASCII tier's background suppression, which had no comment "
            "and no case. `renderCells` leaves an ASCII cell's `bg` at the "
            "zero `Rgb` — 'no opinion', not 'black' — so emitting it paints a "
            "black rectangle over the user's own terminal background at every "
            "cell. A DIFFERENT picture, which §2.5 forbids for the tier that "
            "exists for TERM=dumb and CI logs.",
        control_name="the tier test, written as a negated equality",
        control_find="        if grid.tier != itAscii and (not haveBg or cell.bg != lastBg):",
        control_replace="        if not (grid.tier == itAscii) and (not haveBg or cell.bg != lastBg):"),

    # -- THE PARSER (landing-pass finding F2) --------------------------------
    #
    # `--image-tier` is deliverable 4's second half and NO test called
    # `parseTuiCommand` with it. Both of these survived the landing pass's two
    # suites, green.
    Mutation(
        "M33", CLI,
        '          let (isImageTier, tierText) = optionValue(arg, "--image-tier")\n'
        "          if isImageTier:\n"
        "            let (okTier, tier) = parseTierName(tierText)\n"
        "            if not okTier:\n"
        "              return TuiCommand(\n"
        "                kind: tckUsageError,\n"
        "                message: \"unknown image tier '\" & tierText &\n"
        "                         \"'; pick one of \" & tierNames())\n"
        "            flags.imageTier = tier\n"
        "            flags.imageTierPinned = true\n"
        "            break options\n",
        "          discard\n",
        C_CLI, NIM_CAP,
        "cmd.kind was tckUsageError",
        why="U1: the ENTIRE branch deleted. `--image-tier=half-block` then "
            "falls through to 'unknown option', and the flag §2.2 calls the "
            "one thing that always wins cannot be typed at all.",
        control_name="the flag test, written as an inequality against false",
        control_find="          if isImageTier:",
        control_replace="          if isImageTier != false:"),
    Mutation(
        "M34", CLI,
        "            if not okTier:",
        "            if false:",
        C_CLI, NIM_CAP,
        "bad.kind was tckOpenTrace",
        why="U2: the usage-error arm deleted. `parseTierName` fails to "
            "`itAscii` on purpose — a parse failure must not hand a caller "
            "tier 0, which is `ImageTier`'s zero value — so without the "
            "refusal an unknown name silently pins the WEAKEST tier on a user "
            "who asked for the strongest, and nothing is printed.",
        control_name="the parse-failure test, written as an equality against false",
        control_find="            if not okTier:",
        control_replace="            if okTier == false:"),
]

# M10 is deliberately absent from the table above: `fitsLinkBudget`'s body is
# `emit.fitsLinkBudget`'s, which M9 already grades at the measurement, and an
# arm that mutated the comparison into itself would be a row that cannot fail.
# Removed rather than left as a no-op, because a no-op arm reads as coverage.
MUTATIONS = [m for m in MUTATIONS if m.id != "M10"]


@dataclass
class RunResult:
    rc: int = 0
    ran: bool = True
    passed: list = None
    failed: list = None
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
    compile_cmd += [f"--nimcache:/tmp/plat14-mut-cache-{Path(suite.path).stem}",
                    f"-o:{suite.binary}", suite.path]
    compile_proc = subprocess.run(compile_cmd, cwd=ROOT, capture_output=True,
                                  text=True, errors="replace", timeout=3600)
    if compile_proc.returncode != 0:
        res.rc = compile_proc.returncode
        res.ran = False
        res.output = compile_proc.stdout + compile_proc.stderr
        print("      ---- did not compile; last 12 lines ----")
        for line in res.output.splitlines()[-12:]:
            print("      " + line)
        return res
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


def apply_once(path: str, find: str, replace: str):
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


def read_control_hashes() -> dict:
    if not CONTROL_HASHES.exists():
        return {}
    out = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        h, _, p = line.partition("  ")
        if h and p:
            out[p] = h
    return out


def needle_scan() -> list:
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
    problems = []
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
    body = ["# Control digests for run-plat14-image-mutations.py.",
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
            "#",
            "# `surfaces.nim` is ALSO a PLAT-12 subject. When it changes, both",
            "# harnesses' digests have to be re-recorded and both harnesses'",
            "# arms aimed at it re-run — §16a: a repair that tightens can",
            "# disarm an arm whose needle still resolves.",
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


def explain(arm_id: str) -> int:
    """Apply ONE arm, run its suite, and print the failure lines verbatim.

    Verification-Harness-Traps §17a: "derive it rather than type it". A
    `because` typed from the source is a second copy of the code held in a file
    the compiler does not read, so this is how the strings above were obtained.
    """
    chosen = [m for m in MUTATIONS + DECLARED_SURVIVORS if m.id == arm_id]
    if not chosen:
        print(f"no such arm: {arm_id}")
        return 2
    mut = chosen[0]
    lock = acquire_lock()
    if lock is None:
        return 2
    install_signal_restore()
    original, err = apply_once(mut.path, mut.find, mut.replace)
    if err:
        print(f"{mut.id}: {err}")
        return 2
    try:
        res = run_suite(mut.suite, f"{mut.id}-explain")
    finally:
        restore(mut.path, original)
    print(f"---- {mut.id}: failure lines with the arm applied ----")
    for line in res.output.splitlines():
        if ("Check failed" in line or " was " in line
                or line.strip().startswith("[FAILED]")):
            print("  " + line)
    lock.close()
    return 0


def main() -> int:
    if "--needle-scan" in sys.argv[1:]:
        return report_needle_scan()

    if "--explain" in sys.argv[1:]:
        idx = sys.argv.index("--explain")
        if idx + 1 >= len(sys.argv):
            print("--explain needs an arm id")
            return 2
        return explain(sys.argv[idx + 1])

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
    controls = {}

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
    # sentinel rule applied to it).
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
            print("      ---- the failure lines this arm actually produced ----")
            for line in res.output.splitlines():
                if ("Check failed" in line or " was " in line
                        or line.strip().startswith("[FAILED]")):
                    print("      " + line)
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
