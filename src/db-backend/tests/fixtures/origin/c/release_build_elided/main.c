/* release_build_elided — C
 *
 * Release-build fixture where the optimiser elides the intermediate
 * `b = a` assignment entirely (constant-propagation / dead-store
 * elimination). The DWARF line table no longer carries the writing
 * PC, so the watchpoint loop falls through to OutOfBudget.
 *
 * The corresponding M11 test (`test_origin_rr_release_build_yields_out_of_budget`)
 * asserts that the chain terminates at TerminatorKind::OutOfBudget
 * with a documentation pointer back to spec §6.3.
 */
#include <stdio.h>

__attribute__((noinline)) static int compute(void) {
    int a = 10;
    int b = a;  /* Likely elided at -O2 + dead-store elimination. */
    return b;
}

int main(void) {
    int c = compute();
    printf("%d\n", c);
    return 0;
}
