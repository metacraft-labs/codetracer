// A program whose `main` is slow to flow under an MCR replay and whose
// `quick` is cheap: `tests/running_load_flow_superseded_test.rs` starts the
// flow of `main`, sends the flow of `quick` while it runs, and checks that the
// first is stopped and answered as superseded at once.
//
// `quick` runs BEFORE the long call, so a replay reaches its entry without
// executing `spin`. The flow of `main` steps over `spin(...)`, which retires
// tens of millions of instructions: a replay that steps over it emulates every
// one of them (about 1.4 million per second with a `-d:release` ct-mcr, fewer
// with a debug one), so that step takes far longer than the flow worker's 10 s
// read timeout. `volatile` and the -O0 build keep the loop from being folded.

#include <stdio.h>

static int quick(int a) {
    int doubled = a * 2; // BREAKPOINT quick
    int sum = doubled + 1;
    return sum;
}

static unsigned long spin(unsigned long n) {
    volatile unsigned long acc = 0;
    for (unsigned long i = 0; i < n; i++) {
        acc += i;
    }
    return acc;
}

int main(void) {
    int q = quick(20); // BREAKPOINT main
    unsigned long s = spin(8000000UL);
    printf("%d %lu\n", q, s);
    return 0;
}
