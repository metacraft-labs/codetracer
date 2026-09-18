#!/usr/bin/env python3
"""PLAT-24 deliverable 6 — the Unicode and grapheme corpus, generated.

Editor-Model-Conformance-Suite.md §5: **nine classes, two documents each,
eighteen documents.** A SHORT document per class (<= 20 lines, hand-audited,
with each line's expected cluster count and display width recorded beside it in
the manifest) and a LONG one "taken from real text, so the line-length and
cluster-density distributions are not the author's guess".

WHAT "REAL TEXT" MEANS HERE, STATED RATHER THAN IMPLIED
======================================================
This workspace is a software monorepo. A census of every committed text file in
`codetracer`, `codetracer-specs`, `isonim`, `isonim-tui`, `nim-termctl`,
`TermAssert`, `codetracer-design-system` and `isonim-docs` (5,784 files) found
NO prose in a combining-mark script, NO CJK paragraph and NO ZWJ-family text of
any length: the densest non-ASCII file in the workspace is a box-drawing TUI
snapshot. So "a long document taken from real text" cannot mean "a paragraph of
Hindi somebody wrote here", and pretending otherwise would put the author's
guess into the corpus under a label that says it is not.

Each long document therefore names EXACTLY what it is made of, and there are
three kinds, all pinned:

  ucd:      material taken from the Unicode Character Database itself — the very
            files `isonim-tui`'s width tables are generated from, so the corpus
            and the segmenter are the same Unicode version (16.0.0). The
            cluster material is real upstream data, not invented.
  workspace: a real committed file of this workspace, verbatim.
  workspace+rule: a real committed file with a deterministic, stated
            transformation — used only where the class is ABOUT a malformation
            (mixed terminators, ill-formed bytes, control characters) that no
            healthy source file contains.

The line-length distribution of every `ucd:` document is taken from a real
workspace file (`src/frontend/ui/editor.nim`), so line lengths are a real
file's and not a round number.

THE INDEPENDENT ORACLE
======================
`GraphemeBreakTest.txt` encodes, for 1,093 sequences, where Unicode says the
cluster boundaries are (`÷` = break, `×` = no break). A document built by
concatenating those sequences therefore carries an expected cluster count that
does NOT come from the segmenter under test. The concatenation is only sound if
the separator always breaks on both sides, so sequences whose first code point
is Extend / ZWJ / SpacingMark, or whose last is Prepend, are excluded from the
packing (they would join across the separator and the arithmetic would be
wrong). That exclusion is counted and printed.

Measured 2026-09-18 before the corpus was designed: `width.nim`'s
`graphemeClusters` agrees with **all 1,093** GraphemeBreakTest sequences, 0
divergences. That is why the oracle column is an equality rather than a pinned
divergence count.

DETERMINISM
===========
No randomness, no clock, no environment. Re-running this script on the same
inputs rewrites the same bytes; `manifest.tsv` records an FNV-1a fingerprint of
every document and the suite asserts it, so a corpus file rewritten by an editor
that normalises line endings reddens the suite (§5.2) instead of quietly
changing what every law downstream is quantified over.

`.gitattributes` beside the corpus marks every document `-text`, because a
corpus whose class 6 document is about CR and LF and whose VCS is allowed to
rewrite CR and LF is a corpus with a scheduled death.

Usage (from the repository root):
  python3 src/frontend/viewmodel/tests/corpus/unicode/generate-corpus.py
  python3 .../generate-corpus.py --check    # regenerate into memory and diff
"""

from __future__ import annotations

import io
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]                       # .../codetracer
WORKSPACE = ROOT.parent

TUI_FIXTURES = WORKSPACE / "isonim-tui" / "tests" / "fixtures" / "unicode"
GBT_PATH = TUI_FIXTURES / "GraphemeBreakTest.txt"
GBP_PATH = TUI_FIXTURES / "GraphemeBreakProperty.txt"
EAW_PATH = TUI_FIXTURES / "EastAsianWidth.txt"

# The real file whose line-length distribution the `ucd:` documents borrow.
LINE_LENGTH_DONOR = "src/frontend/ui/editor.nim"

# Real workspace files used verbatim or under a stated rule.
TAB_SOURCE = "ci/lib/run-nim-test-lane.sh"          # genuinely tab-indented
ASCII_SOURCE = "src/ct_test/contracts.nim"          # genuinely pure ASCII
TERMINATOR_SOURCE = "src/ct_test/run_store.nim"     # real source, LF today
ILLFORMED_SOURCE = "src/frontend/viewmodel/editor/rope.nim"   # real UTF-8 in it


def git_rev(repo: Path) -> str:
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "--short=9", "HEAD"],
                          capture_output=True, text=True, check=True).stdout.strip()


def fnv1a(data: bytes) -> int:
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


# ---------------------------------------------------------------------------
# The Unicode Character Database, parsed
# ---------------------------------------------------------------------------

def parse_gbt(path: Path):
    """[(codepoints, expected_cluster_count)] from GraphemeBreakTest.txt."""
    out = []
    for raw in io.open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        cps, breaks = [], 0
        for tok in line.split():
            if tok == "÷":
                breaks += 1
            elif tok == "×":
                pass
            else:
                cps.append(int(tok, 16))
        if cps:
            # `÷ a × b ÷ c ÷` — one ÷ per boundary, including the trailing one.
            out.append((cps, breaks - 1))
    return out


def parse_ranged_property(path: Path):
    """{codepoint: value} from a UCD file of `start..end ; Value` lines."""
    table = {}
    for raw in io.open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip()
        if not line or ";" not in line:
            continue
        rng, value = (p.strip() for p in line.split(";")[:2])
        if ".." in rng:
            lo, hi = (int(p, 16) for p in rng.split(".."))
        else:
            lo = hi = int(rng, 16)
        if hi - lo > 0x20000:          # a default range, not an assignment
            continue
        for cp in range(lo, hi + 1):
            table[cp] = value
    return table


# ---------------------------------------------------------------------------
# Line-length distribution, taken from a real file
# ---------------------------------------------------------------------------

def donor_line_lengths() -> list[int]:
    text = io.open(ROOT / LINE_LENGTH_DONOR, encoding="utf-8",
                   errors="surrogateescape").read()
    lens = [len(l) for l in text.split("\n")]
    # Keep the shape of a real source file: blank lines and very long ones both
    # exist and both matter, but a target of 0 clusters would emit nothing and a
    # target of 400 would make one line the whole document.
    return [n for n in lens if 1 <= n <= 110] or [40]


class LinePacker:
    """Emit lines whose CLUSTER counts follow a real file's line lengths."""

    def __init__(self, targets: list[int]):
        self.targets = targets
        self.i = 0

    def next_target(self) -> int:
        t = self.targets[self.i % len(self.targets)]
        self.i += 1
        return t


# ---------------------------------------------------------------------------
# The nine SHORT documents — hand-authored and hand-audited
# ---------------------------------------------------------------------------
#
# Every line is `(text, clusters, width_narrow, width_wide)`. The three numbers
# are the AUTHOR's, worked out from the line's composition, and they are what
# the suite compares the segmenter against. They are deliberately not read back
# out of the segmenter: a manifest produced by the thing it grades is a
# self-comparison (Verification-Harness-Traps.md §30), and the whole reason §5.1
# says "hand-audited" is that one of the two sides has to be independent.
#
# The width rule being audited against, from `width.nim`:
#   * a cluster's width is its FIRST rune's East-Asian width, except that a
#     regional-indicator cluster is 2, an Extended_Pictographic cluster with
#     more than one rune (ZWJ join, skin tone, VS16) is 2, and VS16 on a
#     narrow pictographic base promotes to 2;
#   * every C0/C1 control, every Extend, ZWJ, SpacingMark and Prepend rune is
#     width 0 — so a TAB contributes 0 and tab EXPANSION is a wrap-layer
#     question this column does not answer (class 8's own case does);
#   * `awWide` changes exactly the East-Asian `Ambiguous` class and nothing
#     else, which is the whole of `LAW-C5`.

ZWJ = "‍"
VS16 = "️"


def _ascii(n: int) -> tuple[int, int, int]:
    return (n, n, n)


SHORT_DOCS: dict[str, list[tuple[str, int, int, int]]] = {}

# --- class 1: ZWJ sequences -------------------------------------------------
SHORT_DOCS["c1-zwj"] = [
    # "family: " is 8 ASCII clusters of width 1; the sequence is ONE cluster of
    # width 2 (Extended_Pictographic with ZWJ joins).
    ("family: \U0001F468" + ZWJ + "\U0001F469" + ZWJ + "\U0001F467", 9, 10, 10),
    ("four:   \U0001F468" + ZWJ + "\U0001F469" + ZWJ + "\U0001F467" + ZWJ +
     "\U0001F466", 9, 10, 10),
    ("astro:  \U0001F469" + ZWJ + "\U0001F680", 9, 10, 10),
    ("dev:    \U0001F468\U0001F3FD" + ZWJ + "\U0001F4BB", 9, 10, 10),
    ("rainbow:\U0001F3F3" + VS16 + ZWJ + "\U0001F308", 9, 10, 10),
    ("hands:  \U0001F9D1" + ZWJ + "\U0001F91D" + ZWJ + "\U0001F9D1", 9, 10, 10),
    ("eye:    \U0001F441" + VS16 + ZWJ + "\U0001F5E8" + VS16, 9, 10, 10),
    ("judge:  \U0001F469" + ZWJ + "⚖" + VS16, 9, 10, 10),
    ("kiss:   \U0001F469" + ZWJ + "❤" + VS16 + ZWJ + "\U0001F48B" + ZWJ +
     "\U0001F468", 9, 10, 10),
    # A ZWJ between two NON-pictographic characters: GB9 keeps it with what
    # precedes it, GB11 does not apply, so "a<ZWJ>" is one cluster and "b" is
    # another. 11 ASCII clusters + 2 = 13; the ZWJ itself is width 0.
    ("plain ZWJ: a" + ZWJ + "b", 13, 13, 13),
    # A ZWJ at the very end of a line has nothing to join to.
    ("tail ZWJ: ab" + ZWJ, 12, 12, 12),
    # A ZWJ at the very start has nothing before it; it is its own cluster.
    (ZWJ + "leading ZWJ", 12, 11, 11),
]

# --- class 2: combining marks ----------------------------------------------
SHORT_DOCS["c2-combining"] = [
    ("NFD e: é", 8, 8, 8),
    ("stack:  à́̂̃", 9, 9, 9),
    # GB9c: Consonant, Linker, Consonant is one cluster.
    ("deva:   क्ष", 9, 9, 9),
    # हिन्दी = ह + ि(SpacingMark) | न + ्(Linker) + द + ी(SpacingMark)
    ("deva2:  हिन्दी", 10, 10, 10),
    # שָׁלוֹם — Hebrew points are Extend; four clusters.
    ("hebrew: שָׁלוֹם", 12, 12, 12),
    # بِسْمِ — Arabic marks are Extend; three clusters.
    ("arabic: بِسْمِ", 11, 11, 11),
    ("viet:   Việt", 12, 12, 12),
    # Marks with no base at all: one cluster, width 0.
    ("́̂", 1, 0, 0),
    ("zalgo:  x" + "̴" * 20, 9, 9, 9),
    # A SpacingMark that follows a space still joins to it (GB9a).
    ("spacing:  ਃ", 10, 10, 10),
]

# --- class 3: regional indicators -------------------------------------------
RI = {c: chr(0x1F1E6 + ord(c) - ord("A")) for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"}
SHORT_DOCS["c3-regional"] = [
    ("bg: " + RI["B"] + RI["G"], 5, 6, 6),
    ("jp: " + RI["J"] + RI["P"], 5, 6, 6),
    # TWO flags and ONE ODD TRAILING indicator — §5.1's named case, the one a
    # naive pair-chunker gets wrong.
    ("pair+odd: " + RI["B"] + RI["G"] + RI["J"] + RI["P"] + RI["U"], 13, 16, 16),
    # The odd one FIRST: pairing is left-to-right, so (U,B) pair and G is alone.
    ("odd first: " + RI["U"] + RI["B"] + RI["G"], 13, 15, 15),
    ("lone: " + RI["Z"], 7, 8, 8),
    ("six: " + RI["A"] + RI["B"] + RI["C"] + RI["D"] + RI["E"] + RI["F"],
     8, 11, 11),
    ("seven:" + RI["A"] + RI["B"] + RI["C"] + RI["D"] + RI["E"] + RI["F"] +
     RI["G"], 10, 14, 14),
    ("after text " + RI["B"] + RI["G"] + " more", 17, 18, 18),
    (RI["X"], 1, 2, 2),
]

# --- class 4: ambiguous width ----------------------------------------------
# Every line carries at least one East-Asian `Ambiguous` code point, so every
# line's width MUST differ between the two policies. The generator asserts each
# of these code points really is `A` in EastAsianWidth.txt rather than trusting
# this comment.
SHORT_DOCS["c4-ambiguous"] = [
    ("pm: ±", 5, 5, 6),
    ("box: ┌──┐", 9, 9, 13),
    ("greek: αβγ", 10, 10, 13),
    ("cyr: Привет", 11, 11, 17),
    ("quotes: “hi”", 12, 12, 14),
    ("math: × ÷ ±", 11, 11, 14),
    ("arrows: ←→↑↓", 12, 12, 16),
    ("dots: …", 7, 7, 8),
    ("accent: é", 9, 9, 10),
    ("blocks: ■●", 10, 10, 12),
]

# --- class 5: CJK wide ------------------------------------------------------
SHORT_DOCS["c5-cjk"] = [
    ("han: 漢字", 7, 9, 9),
    ("hira: ひらがな", 10, 14, 14),
    ("kata: カタカナ", 10, 14, 14),
    ("hangul: 한글", 10, 12, 12),
    # Decomposed Hangul: L + V + T is ONE cluster (GB6/GB7/GB8), width 2.
    ("jamo: 한", 7, 8, 8),
    ("fw: ＡＢＣ", 7, 10, 10),
    ("mixed: 日本語text", 14, 17, 17),
    ("punct: 。、「」", 11, 15, 15),
    ("emojiwide: \U0001F600", 12, 13, 13),
]

# --- class 6: line terminators ----------------------------------------------
# This document's LINES are what `split('\n')` yields, so a CR that is not
# followed by LF stays INSIDE a line and is its own cluster of width 0. That is
# the property the class exists to pin: `lines` and `terminators + 1` agree
# only if a lone CR is not counted as a terminator.
SHORT_DOCS["c6-terminators"] = [
    ("lf line one", 11, 11, 11),
    ("crlf line two\r", 14, 13, 13),
    ("lone cr: A\rB", 12, 11, 11),
    ("mixed: X\rY\r", 11, 9, 9),
    ("tab\tand\ttabs", 12, 10, 10),
    ("no final newline", 16, 16, 16),
]
# The one document that does NOT end in a newline — §5.1's "no final newline".
NO_FINAL_NEWLINE = {"c6-terminators-short"}

# --- class 7: ill-formed input ----------------------------------------------
# Authored as BYTES, because the point is bytes that are not text. The cluster
# and width columns for this class are measured rather than audited and the
# manifest says so by name — see ILLFORMED_AUDIT below.
ILLFORMED_SHORT_LINES: list[bytes] = [
    b"bare continuation: \x80\xbf",
    b"truncated 3-byte: \xe2\x82",
    b"truncated 4-byte: \xf0\x9f\x98",
    b"overlong NUL: \xc0\x80",
    b"invalid lead: \xf5\xff\xfe",
    b"WTF-8 high surrogate: \xed\xa0\x80",
    b"WTF-8 low surrogate: \xed\xb0\x80",
    b"CESU-8 pair: \xed\xa0\xbd\xed\xb8\x80",
    b"embedded NUL: A\x00B",
    b"valid after invalid: \x80 ok",
    b"lead at end of line: ok\xe2",
    b"truncated mid-word: caf\xc3 au lait",
]

# --- class 8: tabs at wrap boundaries ---------------------------------------
SHORT_DOCS["c8-tabs"] = [
    ("\tindented once", 14, 13, 13),
    ("\t\tindented twice", 16, 14, 14),
    ("a\tb\tc", 5, 3, 3),
    ("12345678\tX", 10, 9, 9),
    ("1234567\tX", 9, 8, 8),
    ("\t\t\t\t", 4, 0, 0),
    ("mid\ttab\twith 日本", 15, 15, 15),
    ("trailing tab\t", 13, 12, 12),
    ("\tleading tab then forty chars: " + "x" * 40, 71, 70, 70),
    ("\t日\t本\t", 5, 4, 4),
    # A tab whose EXPANSION CROSSES a wrap column — §5.1's named case. It only
    # exists when the wrap column is not a multiple of the tab size: at tab
    # size 8 a tab at column 19 advances to 24 and straddles column 20, where
    # at column 39 it would merely land on 40. Both wrap columns are in
    # §6's declared matrix {20, 40, 80, 120} and both tab sizes are in {2, 4,
    # 8}, so the corpus has to carry the straddling case or every law PLAT-27
    # writes over class 8 is quantified over a corpus without it.
    ("x" * 19 + "\tcrosses col 20 at tab size 8", 48, 47, 47),
    ("y" * 17 + "\t|", 19, 18, 18),
]

# --- class 9: ASCII control — THE CLASS THAT MUST NOT MOVE -------------------
# `LAW-C5`'s negative half. Every line is pure ASCII, so `awNarrow` and
# `awWide` MUST agree on every one of them; a model that ignored the policy
# would satisfy class 4's arm and this one would still hold, which is exactly
# why both halves exist (Verification-Harness-Traps §7b).
SHORT_DOCS["c9-ascii-control"] = [
    ("plain ascii line", 16, 16, 16),
    ("bel:\x07 backspace:\x08", 17, 15, 15),
    ("vt:\x0b ff:\x0c", 9, 7, 7),
    ("esc:\x1b[31m red \x1b[0m", 18, 16, 16),
    ("del:\x7f", 5, 4, 4),
    ("nul:\x00 after", 11, 10, 10),
    ("all C0: \x01\x02\x03\x04\x05\x06", 14, 8, 8),
    ("tab is C0 too:\t|", 16, 15, 15),
    ("printable: !\"#$%&'()*+,-./0123456789:;<=>?@", 43, 43, 43),
    ("sixteen ascii...", 16, 16, 16),
]


# ---------------------------------------------------------------------------
# The nine LONG documents
# ---------------------------------------------------------------------------

def pack_gbt(seqs, packer: LinePacker, gbp, target_lines: int,
             tail=None) -> tuple[str, int, int]:
    """Concatenate GBT sequences into lines of realistic length.

    Returns (text, expected_clusters, skipped). The separator is U+0020, which
    breaks on both sides for every sequence that survives the filter below, so
    the expected count is exact arithmetic over Unicode's own break data.
    """
    joinable = []
    skipped = 0
    for cps, exp in seqs:
        first, last = gbp.get(cps[0], ""), gbp.get(cps[-1], "")
        if first in ("Extend", "ZWJ", "SpacingMark"):
            skipped += 1
            continue
        if last == "Prepend":
            skipped += 1
            continue
        joinable.append(("".join(chr(c) for c in cps), exp))
    if not joinable:
        raise SystemExit("pack_gbt: no sequence survived the filter")

    lines, total, i = [], 0, 0
    while len(lines) < target_lines:
        want = packer.next_target()
        parts, got = [], 0
        while got < want:
            text, exp = joinable[i % len(joinable)]
            i += 1
            if parts:
                got += 1                       # the separating space
            parts.append(text)
            got += exp
        line = " ".join(parts)
        if tail is not None:
            line += tail[0]
            got += tail[1]
        lines.append(line)
        total += got
    return "\n".join(lines) + "\n", total, skipped


def pack_codepoints(cps: list[int], packer: LinePacker, target_lines: int) -> str:
    """Lines of real code points, lengths from the donor's distribution."""
    out, i = [], 0
    while len(out) < target_lines:
        want = packer.next_target()
        chunk = []
        for _ in range(want):
            chunk.append(chr(cps[i % len(cps)]))
            i += 1
        # Break the run with real ASCII so the lines are text and not a wall.
        out.append("".join(chunk))
    return "\n".join(out) + "\n"


def read_workspace(rel: str) -> bytes:
    return (ROOT / rel).read_bytes()


def rewrite_terminators(data: bytes) -> bytes:
    """LF / CRLF / lone-CR in a fixed 3-cycle, and NO final newline."""
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    out = []
    for n, line in enumerate(lines):
        line = line.rstrip(b"\r")
        if n % 3 == 0:
            out.append(line + b"\n")
        elif n % 3 == 1:
            out.append(line + b"\r\n")
        else:
            # A LONE CR: not a terminator for a store that splits on '\n', so
            # this line and the next are ONE line with a CR inside it.
            out.append(line + b"\r")
    blob = b"".join(out)
    while blob.endswith(b"\n") or blob.endswith(b"\r"):
        blob = blob[:-1]
    return blob


def corrupt_utf8(data: bytes) -> bytes:
    """A stated, deterministic malformation of a real file.

    Every 7th multi-byte sequence loses its continuation bytes, every 23rd
    space becomes a bare continuation byte, and one WTF-8 surrogate pair is
    planted every 40 lines. Newlines are never touched, so the line structure
    stays the real file's.
    """
    out = bytearray()
    i, seq_n, sp_n = 0, 0, 0
    while i < len(data):
        b = data[i]
        if b < 0x80:
            if b == 0x20:
                sp_n += 1
                out.append(0x80 + (sp_n % 0x40) if sp_n % 23 == 0 else b)
            else:
                out.append(b)
            i += 1
            continue
        # a multi-byte lead
        n = 2 if b < 0xE0 else 3 if b < 0xF0 else 4
        seq_n += 1
        if seq_n % 7 == 0:
            out.append(b)                       # lead only — truncated
        else:
            out.extend(data[i:i + n])
        i += n
    blob = bytes(out)
    lines = blob.split(b"\n")
    for n in range(0, len(lines), 40):
        lines[n] = lines[n] + b" \xed\xa0\xbd\xed\xb8\x80"
    return b"\n".join(lines)


def inject_controls(data: bytes) -> bytes:
    """Real ASCII source, with real ASCII control characters put back in.

    A pure source file has none beyond LF, and the class is about the ones a
    terminal capture or a paginated listing really carries: an ANSI colour
    escape around every 13th line, a form feed as a page break every 50 lines,
    and a vertical tab and a DEL in the positions a stray keystroke leaves them.
    """
    lines = data.split(b"\n")
    out = []
    for n, line in enumerate(lines):
        if n and n % 50 == 0:
            out.append(b"\x0c")
        if n % 13 == 0 and line:
            line = b"\x1b[36m" + line + b"\x1b[0m"
        if n % 31 == 0 and line:
            line = line + b"\x0b\x7f"
        if n % 71 == 0 and line:
            line = line + b"\x07"
        out.append(line)
    return b"\n".join(out)


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------

CLASSES = [
    ("c1-zwj", 1, "ZWJ sequences"),
    ("c2-combining", 2, "combining marks"),
    ("c3-regional", 3, "regional indicators"),
    ("c4-ambiguous", 4, "ambiguous width"),
    ("c5-cjk", 5, "CJK wide"),
    ("c6-terminators", 6, "line terminators"),
    ("c7-illformed", 7, "ill-formed input"),
    ("c8-tabs", 8, "tabs at wrap boundaries"),
    ("c9-ascii-control", 9, "ASCII control"),
]


def build() -> tuple[dict[str, bytes], list[dict]]:
    if not GBT_PATH.exists():
        raise SystemExit(
            f"MISSING PREREQUISITE: {GBT_PATH}\n"
            "The corpus is generated from the same Unicode 16.0.0 data that\n"
            "isonim-tui's width tables are generated from. A missing checkout\n"
            "fails BY NAME here rather than producing a smaller corpus.")
    tui_rev = git_rev(WORKSPACE / "isonim-tui")
    ct_rev = git_rev(ROOT)

    gbt = parse_gbt(GBT_PATH)
    gbp = parse_ranged_property(GBP_PATH)
    eaw = parse_ranged_property(EAW_PATH)
    donor = donor_line_lengths()

    ucd = f"ucd:isonim-tui@{tui_rev} tests/fixtures/unicode"
    ws = f"workspace:codetracer@{ct_rev}"

    # The short documents' ambiguous class really is ambiguous — asserted here
    # rather than asserted in a comment.
    for text, _, wn, ww in SHORT_DOCS["c4-ambiguous"]:
        if not any(eaw.get(ord(ch)) == "A" for ch in text):
            raise SystemExit(f"class 4 line carries no EAW=A code point: {text!r}")
        if wn == ww:
            raise SystemExit(f"class 4 line does not move with the policy: {text!r}")
    for text, _, wn, ww in SHORT_DOCS["c9-ascii-control"]:
        if any(ord(ch) > 0x7F for ch in text):
            raise SystemExit(f"class 9 line is not ASCII: {text!r}")
        if wn != ww:
            raise SystemExit(f"class 9 line moves with the policy: {text!r}")

    docs: dict[str, bytes] = {}
    rows: list[dict] = []

    def add(doc_id: str, cls: int, kind: str, data: bytes, provenance: str,
            oracle: int | str, audit: str):
        docs[doc_id] = data
        rows.append(dict(id=doc_id, cls=cls, kind=kind, provenance=provenance,
                         oracle=oracle, audit=audit))

    # ---- the nine short documents -----------------------------------------
    for key, cls, _name in CLASSES:
        doc_id = f"{key}-short"
        if key == "c7-illformed":
            blob = b"\n".join(ILLFORMED_SHORT_LINES) + b"\n"
            add(doc_id, cls, "short", blob,
                "hand-authored (bytes, for PLAT-24 deliverable 6)",
                "-", "bytes-audited")
            continue
        lines = SHORT_DOCS[key]
        if len(lines) > 20:
            raise SystemExit(f"{doc_id}: {len(lines)} lines, §5.1 says <= 20")
        text = "\n".join(l[0] for l in lines)
        if doc_id not in NO_FINAL_NEWLINE:
            text += "\n"
        add(doc_id, cls, "short", text.encode("utf-8"),
            "hand-authored (for PLAT-24 deliverable 6)",
            sum(l[1] for l in lines), "hand-audited")

    # ---- the nine long documents ------------------------------------------
    packer = LinePacker(donor)

    zwj_seqs = [(c, e) for c, e in gbt if 0x200D in c and not
                any(x in (0x0A, 0x0D) for x in c)]
    text, exp, skipped = pack_gbt(zwj_seqs, packer, gbp, 320)
    add("c1-zwj-long", 1, "long", text.encode("utf-8"),
        f"{ucd}/GraphemeBreakTest.txt (Unicode 16.0.0), sequences containing "
        f"U+200D, packed to the line lengths of {LINE_LENGTH_DONOR}; "
        f"{skipped} sequences excluded as unjoinable",
        exp, "ucd-oracle")

    mark_seqs = [(c, e) for c, e in gbt
                 if any(gbp.get(x) in ("Extend", "SpacingMark") for x in c)
                 and 0x200D not in c
                 and not any(0x1F1E6 <= x <= 0x1F1FF for x in c)
                 and not any(x in (0x0A, 0x0D) for x in c)]
    text, exp, skipped = pack_gbt(mark_seqs, packer, gbp, 400)
    add("c2-combining-long", 2, "long", text.encode("utf-8"),
        f"{ucd}/GraphemeBreakTest.txt (Unicode 16.0.0), sequences carrying an "
        f"Extend or SpacingMark and no ZWJ or regional indicator, packed to the "
        f"line lengths of {LINE_LENGTH_DONOR}; {skipped} excluded as unjoinable",
        exp, "ucd-oracle")

    ri_seqs = [(c, e) for c, e in gbt
               if any(0x1F1E6 <= x <= 0x1F1FF for x in c)
               and not any(x in (0x0A, 0x0D) for x in c)]
    # Every line ends in ONE more regional indicator than pairs up — §5.1's
    # "odd trailing" case, on every line of the document rather than once.
    text, exp, skipped = pack_gbt(ri_seqs, packer, gbp, 300,
                                  tail=(" " + RI["Q"], 2))
    add("c3-regional-long", 3, "long", text.encode("utf-8"),
        f"{ucd}/GraphemeBreakTest.txt (Unicode 16.0.0), sequences containing a "
        f"regional indicator, packed to the line lengths of "
        f"{LINE_LENGTH_DONOR}, each line given an ODD TRAILING indicator; "
        f"{skipped} excluded as unjoinable",
        exp, "ucd-oracle")

    ambiguous = sorted(cp for cp, v in eaw.items() if v == "A"
                       and (0x00A1 <= cp <= 0x2BFF or 0xFFE0 <= cp <= 0xFFE6)
                       and gbp.get(cp) not in ("Control", "CR", "LF", "Extend",
                                               "ZWJ", "SpacingMark", "Prepend"))
    if len(ambiguous) < 200:
        raise SystemExit(f"only {len(ambiguous)} ambiguous code points found")
    add("c4-ambiguous-long", 4, "long",
        pack_codepoints(ambiguous, packer, 320).encode("utf-8"),
        f"{ucd}/EastAsianWidth.txt (Unicode 16.0.0), every `A` code point in "
        f"U+00A1..U+2BFF and U+FFE0..U+FFE6 ({len(ambiguous)} of them), packed "
        f"to the line lengths of {LINE_LENGTH_DONOR}",
        "-", "generated")

    wide = sorted(cp for cp, v in eaw.items() if v in ("W", "F")
                  and (0x3000 <= cp <= 0x9FFF or 0xAC00 <= cp <= 0xD7A3
                       or 0xFF01 <= cp <= 0xFF60))
    if len(wide) < 1000:
        raise SystemExit(f"only {len(wide)} wide code points found")
    add("c5-cjk-long", 5, "long",
        pack_codepoints(wide, packer, 320).encode("utf-8"),
        f"{ucd}/EastAsianWidth.txt (Unicode 16.0.0), every `W`/`F` code point "
        f"in the CJK, Hangul-syllable and fullwidth ranges ({len(wide)} of "
        f"them), packed to the line lengths of {LINE_LENGTH_DONOR}",
        "-", "generated")

    add("c6-terminators-long", 6, "long",
        rewrite_terminators(read_workspace(TERMINATOR_SOURCE)),
        f"{ws} {TERMINATOR_SOURCE}, terminators rewritten LF / CRLF / lone-CR "
        f"in a fixed 3-cycle, with NO final newline",
        "-", "generated")

    add("c7-illformed-long", 7, "long",
        corrupt_utf8(read_workspace(ILLFORMED_SOURCE)),
        f"{ws} {ILLFORMED_SOURCE}, every 7th multi-byte sequence truncated to "
        f"its lead byte, every 23rd space replaced by a bare continuation byte, "
        f"a WTF-8 surrogate pair planted every 40 lines",
        "-", "generated")

    add("c8-tabs-long", 8, "long", read_workspace(TAB_SOURCE),
        f"{ws} {TAB_SOURCE}, VERBATIM — a genuinely tab-indented real file",
        "-", "verbatim")

    ascii_src = read_workspace(ASCII_SOURCE)
    if any(b > 0x7F for b in ascii_src):
        raise SystemExit(f"{ASCII_SOURCE} is not pure ASCII any more")
    add("c9-ascii-control-long", 9, "long", inject_controls(ascii_src),
        f"{ws} {ASCII_SOURCE} (pure ASCII), with an ANSI colour escape around "
        f"every 13th line, a form feed every 50 lines, VT+DEL every 31st and "
        f"BEL every 71st",
        "-", "generated")

    return docs, rows


def write_provenance(rows: list[dict]) -> str:
    out = ["# PLAT-24 corpus — the hand-maintained half of the manifest.",
           "#",
           "# `manifest.tsv` is EMITTED from these rows plus the documents'",
           "# bytes by `emit_manifest.nim`. This file is what a human writes;",
           "# that one is what a machine computes and the suite asserts.",
           "#",
           "# oracle: the expected cluster count from an INDEPENDENT source —",
           "#         hand audit for a short document, Unicode's own",
           "#         GraphemeBreakTest break data for a `ucd-oracle` one, and",
           "#         `-` where there is none, which is a fact the manifest",
           "#         states rather than hides.",
           "#",
           "# id\tclass\tkind\toracle\taudit\tprovenance"]
    for r in rows:
        out.append("\t".join([r["id"], str(r["cls"]), r["kind"],
                              str(r["oracle"]), r["audit"], r["provenance"]]))
    return "\n".join(out) + "\n"


def write_short_lines() -> str:
    out = ["# PLAT-24 corpus — the HAND AUDIT of the nine short documents.",
           "#",
           "# Editor-Model-Conformance-Suite.md §5.1: a short document carries",
           "# `each line's expected cluster count and display width recorded",
           "# beside it in the corpus manifest`. These three numbers per line",
           "# are the AUTHOR's, worked out from the line's composition. They",
           "# are not read back out of the segmenter, because a manifest",
           "# produced by the thing it grades is a self-comparison (§30).",
           "#",
           "# The one class with no audit column is class 7: what Nim's",
           "# `fastRuneAt` yields for a byte that is not text is an",
           "# implementation's answer and not a fact about Unicode, so it is",
           "# recorded as MEASURED, by name, rather than audited — and the",
           "# BYTE length of each of its lines is audited instead.",
           "#",
           "# id\tline\tclusters\twidthNarrow\twidthWide"]
    for key, _cls, _name in CLASSES:
        if key == "c7-illformed":
            for n, blob in enumerate(ILLFORMED_SHORT_LINES):
                out.append(f"{key}-short\t{n}\tMEASURED\tMEASURED\tMEASURED"
                           f"\t{len(blob)}")
            continue
        for n, (_text, c, wn, ww) in enumerate(SHORT_DOCS[key]):
            out.append(f"{key}-short\t{n}\t{c}\t{wn}\t{ww}")
    return "\n".join(out) + "\n"


GITATTRIBUTES = """\
# PLAT-24's Unicode corpus. Editor-Model-Conformance-Suite.md §5.2: a corpus
# file silently rewritten by something that normalises line endings is how a
# corpus dies. One of these documents is ABOUT CR and LF and another is about
# bytes that are not text at all, so nothing may touch them.
*.txt -text -diff
*.bin -text -diff
# The manifest and the audit too: they are the corpus's identity, and a
# checkout that rewrote their line endings would change the bytes the suite
# fingerprints them by even though the parser would still read them.
*.tsv -text
"""


def main() -> int:
    check = "--check" in sys.argv[1:]
    docs, rows = build()
    outputs: dict[str, bytes] = dict(docs)
    outputs["provenance.tsv"] = write_provenance(rows).encode("utf-8")
    outputs["short-lines.tsv"] = write_short_lines().encode("utf-8")
    outputs[".gitattributes"] = GITATTRIBUTES.encode("utf-8")

    changed = 0
    for name, blob in sorted(outputs.items()):
        path = HERE / (name if name.endswith((".tsv", ".gitattributes"))
                       else name + ".txt")
        old = path.read_bytes() if path.exists() else None
        if old == blob:
            continue
        changed += 1
        if check:
            print(f"DIFFERS: {path.name} "
                  f"({0 if old is None else len(old)} -> {len(blob)} bytes)")
        else:
            path.write_bytes(blob)
    for name, blob in sorted(outputs.items()):
        if name.endswith((".tsv", ".gitattributes")):
            continue
        print(f"{name + '.txt':<28} {len(blob):>8} bytes  "
              f"fnv1a=0x{fnv1a(blob):016x}")
    print(f"\n{len(docs)} documents, {changed} rewritten"
          f"{' (check only)' if check else ''}")
    if len(docs) != 18:
        print(f"REFUSING: §5 says eighteen documents, this made {len(docs)}")
        return 1
    return 1 if (check and changed) else 0


if __name__ == "__main__":
    sys.exit(main())
