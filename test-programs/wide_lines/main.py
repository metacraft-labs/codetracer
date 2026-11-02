#!/usr/bin/env python3
"""wide_lines: PLAT-70's horizontal-overflow fixture.

Horizontal-Overflow.md section 4: a text pane whose
lines are wider than the pane gets an overflow-only
horizontal bar. This program has ONE wide line of
each kind, far wider than any pane a suite lays out:

* a SOURCE line (WIDE_SOURCE below), the editor's
  widest line;
* an OUTPUT line, the same text written to stdout,
  the Terminal Output pane's widest line.

Every other line is at most 56 columns, so deleting
the wide line leaves nothing wider than the pane.
Both wide lines run from <<LEFT-EDGE>> to
<<RIGHT-EDGE>>. No loop: every stop is quick.
"""


def emit(text):
    print(text)


def main():
    WIDE_SOURCE = "<<LEFT-EDGE>> the quick brown fox jumps over the lazy dog, 0123456789 the quick brown fox jumps over the lazy dog, 0123456789 the quick brown fox jumps over the lazy dog, 0123456789 the quick brown fox jumps over the lazy dog, 0123456789 <<RIGHT-EDGE>>"
    emit(WIDE_SOURCE)
    short = "a short line"
    emit(short)
    return len(WIDE_SOURCE)


if __name__ == "__main__":
    main()
