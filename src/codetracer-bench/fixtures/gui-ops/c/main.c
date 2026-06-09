/* P4 GUI-ops latency fixture (C).  Mirrors fixtures/gui-ops/python/main.py:
 * a small assignment chain so the headless DAP harness can issue
 * threads, stackTrace, ct/load-locals, ct/load-history, ct/load-flow,
 * ct/originChain, and ct/originSummary requests against the recorded
 * trace and measure their wall-clock latency.
 */
#include <stdio.h>

static int fold(int x, int y) {
    return x * 31 + y;
}

int main(void) {
    int a = 1;
    int b = a + 2;
    int c = b * 3;
    int d = c + 10;
    int e = fold(d, 7);
    printf("%d\n", e);
    return 0;
}
