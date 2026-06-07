# P4 GUI-ops latency fixture (Python).
#
# A small assignment chain that drives a recordable trace with enough
# state (1 thread, ~10 frames, a few locals) so the headless DAP harness
# can issue `threads`, `stackTrace`, `ct/load-locals`, `ct/load-history`,
# `ct/load-flow`, `ct/originChain`, and `ct/originSummary` requests
# against the recorded trace and measure their wall-clock latency.
#
# The shape is intentionally minimal: the GUI-ops bench is about request
# latency per operation, not about the depth of the surface that a single
# request walks.  Operators looking at multi-thousand-step latencies
# should look at the M30 / M31 cluster bench, not this one.


def fold(x: int, y: int) -> int:
    return x * 31 + y


def main() -> None:
    a = 1
    b = a + 2
    c = b * 3
    d = c + 10
    e = fold(d, 7)
    print(e)


if __name__ == "__main__":
    main()
