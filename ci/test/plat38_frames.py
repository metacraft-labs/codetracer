"""PLAT-38 — reading a binary PPM, and comparing two of them.

NOT-A-CI-GATE: a shared measurement module, not a check on one. It is imported
by `ci/test/plat38-keystroke.sh` and by `just plat38-threshold-probe`; it
asserts nothing and has no exit status of its own.

**ONE MODULE, TWO CALLERS, AND THAT IS THE POINT.**
`ci/test/plat38-keystroke.sh` measures the change fraction that the gate
asserts, and `just plat38-threshold-probe` re-takes the same measurement at
the thresholds that were REJECTED. If each spelled the comparison itself, the
probe would be measuring its own arithmetic rather than the lane's, and the
published figures would be about two functions —
`codetracer-specs/Testing/Verification-Harness-Traps.md` §30, two copies of
one predicate, rule and control each calling their own.

§36b is why the probe exists at all: *"the winner is gated, the losers are
prose"*. A parameter search is a measurement, so it is written down as a
PROGRAM rather than as a table; re-taking it costs a minute instead of a
reconstruction.
"""

import os


def read_ppm(path):
    """Return (width, height, pixel bytes) for a binary P6 PPM, or None.

    `None` rather than an exception for a missing or malformed file, so a
    caller can distinguish "there is no frame" from "the frame says nothing" —
    two states that a zero would conflate.
    """
    if not os.path.exists(path):
        return None
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(b"P6"):
        return None
    # The header is `P6 <w> <h> <max>`, whitespace-separated, with `#` comments
    # permitted between any two fields. Parsed rather than assumed: `grim -t
    # ppm` writes no comment today and a reader that depended on that would
    # break on the first tool that did.
    fields, i = [], 2
    while len(fields) < 3 and i < len(data):
        while i < len(data) and data[i : i + 1].isspace():
            i += 1
        if data[i : i + 1] == b"#":
            while i < len(data) and data[i : i + 1] != b"\n":
                i += 1
            continue
        j = i
        while j < len(data) and not data[j : j + 1].isspace():
            j += 1
        fields.append(int(data[i:j]))
        i = j
    if len(fields) < 3:
        return None
    i += 1  # exactly one whitespace byte separates the header from the raster
    width, height, _maxval = fields
    return width, height, data[i : i + width * height * 3]


def nonblank_fraction(pixels):
    """The fraction of BYTES that are not NUL.

    The same reading `isonim-gpui/scripts/wayland-capture-frame.sh` takes, and
    for the same reason: a blank compositor output is NUL bytes, and a painted
    one is not. It is a coarse instrument and it is used for a coarse claim —
    *there is a window and its pixels are not the pixels of a blank screen* —
    which is the ONE claim PLAT-37's instrument contract puts on the vision
    tier.
    """
    if not pixels:
        return 0.0
    return sum(1 for b in pixels) and sum(1 for b in pixels if b) / len(pixels)


def changed_fraction(before, after):
    """The fraction of PIXELS that differ between two rasters.

    Pixel-wise rather than byte-wise, so a single channel moving by one is one
    changed pixel rather than one changed byte — the quantity the threshold is
    stated in.
    """
    n = min(len(before), len(after))
    if n < 3:
        return 0.0
    differing = sum(
        1 for i in range(0, n - 2, 3) if before[i : i + 3] != after[i : i + 3]
    )
    return differing / (n / 3)
