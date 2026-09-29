#!/usr/bin/env python3
"""call_pages — a recording whose call trace is longer than any one page.

The terminal's and the GUI front-ends' calltrace panes read the trace a
section at a time (``ct/load-calltrace-section``) and load more as the
reader scrolls, as the desktop's calltrace pane does. A test of that needs a
recording with more calls than one section holds, and ``calc`` has 29.

``ROUNDS`` rounds of two nested calls: ``1 + 2 * ROUNDS`` calls below the
module, 601 with the value below — more than the desktop's own whole-trace
window (500 rows), so no reader can hold it in one request by accident.

Deterministic: no clock, no randomness, no environment. The checksum it
prints is the whole observable output.
"""

ROUNDS = 300


def leaf(i):
    return i * 2


def step(i):
    return leaf(i) + 1


def main():
    total = 0
    for i in range(ROUNDS):
        total += step(i)
    print("checksum =", total)


if __name__ == "__main__":
    main()
