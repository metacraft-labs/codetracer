#!/usr/bin/env python3
"""multi_root — a recording whose sources live in two SIBLING folders.

The runner is here, in ``app/``; the modules it imports are in ``shared/``
(one of them a package with its own sub-folder). A recording of it therefore
has more than one source root, which is the shape a front-end's FILES pane
must list in full — the terminal and GPUI used to show an empty tree for it
(``src/frontend/tui/tests/test_recording_file_tree.nim``).

Small and deterministic, like ``calc``: no clock, no randomness, no I/O other
than ``print``.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "shared"))

import helpers  # noqa: E402  (after the path it lives on)
from pkg import extra  # noqa: E402


def main():
    total = helpers.add(2, 3)
    scaled = extra.scale(total, 4)
    print("total", total, "scaled", scaled)
    return scaled


if __name__ == "__main__":
    main()
