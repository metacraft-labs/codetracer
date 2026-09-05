#!/usr/bin/env python3
"""wide_state — the program behind CTUI-1's ``wide_state`` fixture.

WHAT CTUI-1 ASKS FOR, LITERALLY
-------------------------------
"a trace with a >500-property structure and a >50-frame recursion, for CTUI-6
and CTUI-7's performance gates".

Those two numbers are the whole specification, and both are *lower bounds a
later milestone measures against*, so they are declared here as named
constants rather than written into the code twice:

* ``WIDE_PROPERTY_COUNT`` — the number of members of the wide structures.  A
  variables pane that renders 600 rows without virtualising them is the defect
  CTUI-7's gate exists to find, and it cannot be found against a struct with
  eight fields.
* ``RECURSION_DEPTH`` — the depth of the recursion.  At the innermost call the
  call stack carries more frames than any terminal can show at once, which is
  what makes a calltrace pane's scrolling and its depth budget testable.

Both are exceeded rather than met exactly (600 > 500, 64 > 50) so that an
off-by-one in how anything downstream counts — the recorder's own frame, a
pane's header row, a 1- versus 0-based depth — cannot put the fixture *under*
the bound the gate asserts.

TWO wide shapes, not one, and what measuring them showed
--------------------------------------------------------
``wide_mapping`` is a ``dict`` and ``wide_object`` is an instance with 600
attributes.  A recorder may represent those very differently — one as a
sequence of key/value pairs, the other as a struct with labels — and a pane
that renders one well may collapse on the other, so both are recorded.

Measured on this corpus (2026-09-05, Python recorder, `ct/load-locals` at the
last recorded step): the dict comes back as a compound value with **600**
members, and the instance comes back with **0** — the value layer does not
currently expand an object's attributes into children.  So the >500 bound
CTUI-1 sets is met by ``wide_mapping``, and ``wide_object`` is kept because
that asymmetry is exactly the kind of thing CTUI-7's inspector has to know
about, and a fixture that carried only the shape that works would hide it.

Deterministic throughout: every value is a pure function of its index.
"""

WIDE_PROPERTY_COUNT = 600
"""Member count of both wide structures.  CTUI-1 requires > 500."""

RECURSION_DEPTH = 64
"""Depth of the recursion below ``main``.  CTUI-1 requires > 50."""


class WideState(object):
    """An object carrying ``WIDE_PROPERTY_COUNT`` distinct attributes.

    Built with ``setattr`` in a loop rather than written out 600 times: the
    attribute NAMES are what a variables pane renders, and generating them
    keeps them uniform (``field_000`` … ``field_599``) so a test can assert on
    an ordering without depending on a hand-written list staying sorted.
    """

    def __init__(self, width):
        self.width = width
        for index in range(width):
            setattr(self, "field_%03d" % index, index * 3 + 1)

    def total(self):
        """Sum every generated attribute.  A single number the test can pin."""
        running = 0
        for index in range(self.width):
            running += getattr(self, "field_%03d" % index)
        return running


def build_wide_mapping(width):
    """Return a dict with ``width`` entries, keyed ``key_000`` … ``key_<n>``."""
    mapping = {}
    for index in range(width):
        mapping["key_%03d" % index] = index * 2
    return mapping


def descend(depth, accumulator):
    """Recurse ``depth`` frames deep, carrying a live local into each one.

    ``accumulator`` is threaded through on purpose: a recursion whose frames
    all carry the same locals is indistinguishable from a loop once the
    debugger renders it, and the point of this arm is that the frames are
    genuinely distinct.
    """
    if depth <= 0:
        return accumulator
    step = depth * 2
    return descend(depth - 1, accumulator + step)


def main():
    wide_object = WideState(WIDE_PROPERTY_COUNT)
    wide_mapping = build_wide_mapping(WIDE_PROPERTY_COUNT)
    deep_total = descend(RECURSION_DEPTH, 0)

    print("attributes = %d" % wide_object.width)
    print("mapping entries = %d" % len(wide_mapping))
    print("attribute total = %d" % wide_object.total())
    print("mapping total = %d" % sum(wide_mapping.values()))
    print("recursion depth = %d" % RECURSION_DEPTH)
    print("recursion total = %d" % deep_total)
    return wide_object, wide_mapping, deep_total


main()
