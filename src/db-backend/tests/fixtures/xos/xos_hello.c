/* M-XOS-Fixture test program.
 *
 * A tiny dynamically-linked C program exercising a real call chain
 * (`main -> compute -> add`) plus a libc call (`printf`) so that:
 *
 *   1.  `libct_interpose.so` actually loads via `LD_PRELOAD`
 *       (statically-linked binaries skip LD_PRELOAD entirely, so a
 *       dynamic link is required to trigger the `__libc_start_main`
 *       wrapper that captures `cp0.{mem,regs,maps,fsbase}`).
 *   2.  The recorded binary has DWARF function/line info the
 *       `EmulatorReplaySession` can resolve.
 *   3.  Several frames sit on the stack at the moment of the cp0
 *       capture so the CFI walker has something non-trivial to walk
 *       through.
 *
 * Build:
 *     gcc -O0 -g -o xos_hello.elf xos_hello.c
 *
 * The build is intentionally PIC/PIE; the recorder's
 * M-Replay-PC-Rebase logic computes a runtime → static delta from
 * `cp0.maps` so DWARF lookups still hit.
 */

#include <stdio.h>

int add(int a, int b) {
    int sum = a + b;
    return sum;
}

int compute(int x) {
    int doubled = add(x, x);
    return doubled;
}

int main(void) {
    int result = compute(21);
    printf("xos_hello result=%d\n", result);
    return 0;
}
