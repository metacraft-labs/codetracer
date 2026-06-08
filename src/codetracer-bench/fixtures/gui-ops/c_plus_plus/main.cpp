// P4 GUI-ops latency fixture (C++).
//
// Mirrors fixtures/gui-ops/python/main.py: a small assignment chain
// that drives a recordable trace with enough state (1 thread, ~10
// frames, a few locals) so the headless DAP harness can issue
// `threads`, `stackTrace`, `ct/load-locals`, `ct/load-history`,
// `ct/load-flow`, `ct/originChain`, and `ct/originSummary` requests
// against the recorded trace and measure their wall-clock latency.
//
// The shape is intentionally minimal: the GUI-ops bench is about
// request latency per operation, not depth of the surface that a
// single request walks.  Operators looking at multi-thousand-step
// latencies should look at the M30 / M31 cluster bench, not this one.

#include <cstdio>

static int fold(int x, int y) {
    return x * 31 + y;
}

int main() {
    int a = 1;
    int b = a + 2;
    int c = b * 3;
    int d = c + 10;
    int e = fold(d, 7);
    std::printf("%d\n", e);
    return 0;
}
