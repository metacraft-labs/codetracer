/*
 * M8 native fixture for the Trace-Based-Incremental-Testing campaign.
 *
 * End-to-end native incremental decision: skip a native test when none of the
 * native functions it EXECUTED changed at the instruction-byte level, re-run
 * when an executed one did.
 *
 * Functions and roles:
 *   - used_a   : EXECUTED by the test. A pure, position-independent LEAF (no
 *                calls, no pc-relative branches). Edited by
 *                native_changing_an_executed_function_reruns.
 *   - used_b   : EXECUTED by the test. Also a pure leaf.
 *   - unused_c : NOT executed by the test (the "function the test did not
 *                execute"). Edited by native_changing_an_unexecuted_function_skips.
 *   - main     : entry point; calls used_a + used_b. NOTE: main is NOT in the
 *                test's executed set (see README) so that the executed set is
 *                exactly the two pure leaves {used_a, used_b}.
 *
 * # CRUCIAL LAYOUT CHOICE — why the unexecuted-edit case genuinely SKIPS
 *
 * The M7 relocation limitation is real: a function that RELOCATES and contains a
 * call re-hashes (a SAFE re-run, but it would break the "skip" expectation). To
 * make native_changing_an_unexecuted_function_skips genuinely skip, editing
 * `unused_c` must NOT change the instruction bytes of the EXECUTED functions
 * (used_a, used_b).
 *
 * Two properties guarantee this:
 *   1. The executed functions used_a/used_b are pure POSITION-INDEPENDENT leaves
 *      — their machine code is byte-identical wherever the linker places them,
 *      so even if they relocate their hashes are stable.
 *   2. `unused_c` is placed AFTER used_a and used_b in source order (and before
 *      main). On this host the linker lays functions out in source order, so
 *      growing `unused_c` shifts the addresses of functions placed AFTER it
 *      (here `main`), NOT the earlier used_a/used_b. main is not in the executed
 *      set, so its relocation is irrelevant.
 *
 * Both properties are belt-and-suspenders: (1) alone already makes the leaves'
 * hashes relocation-invariant; (2) additionally keeps the leaves from moving at
 * all. The test empirically asserts the executed-function hashes are unchanged
 * after the unused_c edit, so a regression here fails loudly rather than
 * silently producing a coincidental re-run.
 *
 * All non-main functions are __attribute__((noinline)) so each keeps a distinct
 * symbol with its own block of machine code (locatable by nativeFunctionTable).
 */

__attribute__((noinline)) int used_a(void) {
  return 1;
}

__attribute__((noinline)) int used_b(int x) {
  return x * 2 + 7;
}

__attribute__((noinline)) int unused_c(void) {
  return 99;
}

int main(void) {
  return used_a() + used_b(3);
}
