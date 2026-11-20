#!/usr/bin/env python3
"""Check cell_render.nim's octant table against the Unicode 16 character data.

`cell_render.octantGlyph` draws a 2x4 sub-cell mask as one character. Unicode
16.0 encodes 230 of the 256 masks as `BLOCK OCTANT-<cells>` in U+1CD00-U+1CDE5
and skips the 26 masks that already had a spelling. This script derives the
whole table from the character NAMES in Python's `unicodedata` (Python 3.14
carries UCD 16.0.0) and compares it with the table the Nim code carries:

  * every name in U+1CD00-U+1CDE5 is `BLOCK OCTANT-<digits>`, the digits name
    distinct masks, and the run is in increasing mask order — which is what
    `octantGlyph`'s "U+1CD00 plus the non-legacy masks below it" relies on;
  * the 26 masks absent from the run are exactly `OctantLegacyGlyphs`' masks;
  * each legacy character's name describes the cells its mask sets, read from
    the name (quadrants, halves, quarter rows, the middle quarters).

Run with a Python whose `unicodedata.unidata_version` is 16.x:

    python3.14 -I src/common/terminal_graphics/octant_table_unicode16.py

Exit status 0 means the Nim table and the Unicode data agree.
"""

import re
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent


def cells(mask):
    return {i + 1 for i in range(8) if mask >> i & 1}


def mask_of(cell_set):
    return sum(1 << (c - 1) for c in cell_set)


# Octant cells: 1 2 / 3 4 / 5 6 / 7 8 (row-major, two columns, four rows).
ROWS = [{1, 2}, {3, 4}, {5, 6}, {7, 8}]
LEFT = {1, 3, 5, 7}
RIGHT = {2, 4, 6, 8}
QUADRANT = {
    "UPPER LEFT": {1, 3},
    "UPPER RIGHT": {2, 4},
    "LOWER LEFT": {5, 7},
    "LOWER RIGHT": {6, 8},
}


def cells_named(name):
    """The octant cells a legacy block character's NAME says it covers."""
    if name == "SPACE":
        return set()
    if name == "FULL BLOCK":
        return LEFT | RIGHT
    if name.startswith("QUADRANT "):
        out = set()
        for part in name[len("QUADRANT "):].split(" AND "):
            out |= QUADRANT[part]
        return out
    fixed = {
        "UPPER HALF BLOCK": ROWS[0] | ROWS[1],
        "LOWER HALF BLOCK": ROWS[2] | ROWS[3],
        "LEFT HALF BLOCK": LEFT,
        "RIGHT HALF BLOCK": RIGHT,
        "UPPER ONE QUARTER BLOCK": ROWS[0],
        "LOWER ONE QUARTER BLOCK": ROWS[3],
        "UPPER THREE QUARTERS BLOCK": ROWS[0] | ROWS[1] | ROWS[2],
        "LOWER THREE QUARTERS BLOCK": ROWS[1] | ROWS[2] | ROWS[3],
        "MIDDLE LEFT ONE QUARTER BLOCK": {3, 5},
        "MIDDLE RIGHT ONE QUARTER BLOCK": {4, 6},
        "LEFT HALF UPPER ONE QUARTER BLOCK": ROWS[0] & LEFT,
        "RIGHT HALF UPPER ONE QUARTER BLOCK": ROWS[0] & RIGHT,
        "LEFT HALF LOWER ONE QUARTER BLOCK": ROWS[3] & LEFT,
        "RIGHT HALF LOWER ONE QUARTER BLOCK": ROWS[3] & RIGHT,
    }
    if name not in fixed:
        raise SystemExit("no cell reading for legacy character name " + repr(name))
    return fixed[name]


def nim_legacy_table():
    """(mask, code point) pairs from cell_render.nim's OctantLegacyGlyphs."""
    source = (HERE / "cell_render.nim").read_text(encoding="utf-8")
    start = source.index("= [", source.index("OctantLegacyGlyphs:"))
    body = source[start:source.index("]\n", start)]
    pairs = []
    for m in re.finditer(r'\(0b([01]{8}), "([^"]+)"\)', body):
        literal = m.group(2)
        u = re.fullmatch(r"\\u\{([0-9A-Fa-f]+)\}", literal)
        cp = int(u.group(1), 16) if u else ord(literal)
        pairs.append((int(m.group(1), 2), cp))
    return pairs


def main():
    version = unicodedata.unidata_version
    if not version.startswith("16."):
        print("needs Unicode 16 data; this Python has " + version, file=sys.stderr)
        return 2
    run = {}
    for cp in range(0x1CD00, 0x1CDE6):
        name = unicodedata.name(chr(cp))
        if not name.startswith("BLOCK OCTANT-"):
            print("U+%04X is %s, not a BLOCK OCTANT" % (cp, name))
            return 1
        mask = mask_of(int(d) for d in name[len("BLOCK OCTANT-"):])
        if mask in run:
            print("U+%04X repeats mask %d" % (cp, mask))
            return 1
        run[mask] = cp
    failures = 0
    if [run[m] for m in sorted(run)] != list(range(0x1CD00, 0x1CDE6)):
        print("the BLOCK OCTANT run is not in increasing mask order")
        failures += 1
    absent = sorted(set(range(256)) - set(run))
    legacy = nim_legacy_table()
    if [m for m, _ in legacy] != absent:
        print("legacy masks differ: nim %s, unicode %s" % ([m for m, _ in legacy], absent))
        failures += 1
    for mask, cp in legacy:
        name = unicodedata.name(chr(cp))
        if cells_named(name) != cells(mask):
            print("mask %d: U+%04X %s covers %s, the mask sets %s" % (
                mask, cp, name, sorted(cells_named(name)), sorted(cells(mask))))
            failures += 1
    print("unicode %s: %d octant characters, %d legacy masks checked, %d failures" % (
        version, len(run), len(legacy), failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
