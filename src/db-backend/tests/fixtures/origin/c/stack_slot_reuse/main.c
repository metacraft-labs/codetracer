/* stack_slot_reuse — C
 *
 * Stack-slot reuse / aliasing guard fixture (M11 test #2):
 *
 * The compiler is free to reuse the stack slot of the now-dead `tmp`
 * variable inside `inner()` for `outer`'s local `x` after the inner
 * call returns. Without the guard, the M11 algorithm would walk back
 * to `inner`'s `tmp = 7` write and emit a spurious hop.
 *
 * With the guard (spec §6.3 "stack-slot reuse"), the algorithm:
 *
 *   1. Catches the watchpoint on the writing PC inside `inner`.
 *   2. Resolves the PC's source line — `int tmp = 7;`.
 *   3. Parses the line as an assignment.
 *   4. Sees the LHS targets `tmp`, NOT `x` — so the guard re-issues
 *      reverse-continue without emitting a hop.
 *
 * Expected chain for `x` queried at the printf line:
 *
 *   hop 0: target=x   rhs=42     OriginKind=Literal   terminator=Literal(int, value=42)
 *
 * The test specifically asserts that NO hop carries `target=tmp` or
 * `source_text="int tmp = 7;"`.
 */
#include <stdio.h>

__attribute__((noinline)) static int inner(void) {
    int tmp = 7;  /* stack slot deliberately reusable by `outer`. */
    return tmp + 1;
}

__attribute__((noinline)) static int outer(void) {
    int discard = inner();
    (void)discard;
    /* The compiler is free to reuse `inner`'s tmp slot here. */
    int x = 42;
    return x;
}

int main(void) {
    int x = outer();
    printf("%d\n", x);
    return 0;
}
