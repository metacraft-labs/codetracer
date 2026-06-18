/* c_recreator — benchmark workload for the native indexer.
 *
 * Drives the spec §6.8.6 native-mode benchmark — the workload is a
 * fixed-iteration accumulator loop so the recorded omniscient log
 * has a stable per-iteration write footprint the benchmark suite
 * can pin per-mode against.
 *
 * The volatile qualifier on `accum` defeats the DCE pass that would
 * otherwise collapse the entire loop on `-O2`; the benchmark targets
 * the "release build, partial DWARF coverage" shape the native
 * recorder commonly ingests.
 */

#include <stdint.h>
#include <stdio.h>

#define ITERATIONS 1024

static int64_t chain_step(int64_t accum, int64_t idx) {
    int64_t forwarded = accum;
    int64_t bumped = forwarded + idx;
    return bumped;
}

int main(void) {
    volatile int64_t accum = 0;
    for (int64_t i = 0; i < ITERATIONS; ++i) {
        accum = chain_step(accum, i);
    }
    printf("%lld\n", (long long)accum);
    return 0;
}
