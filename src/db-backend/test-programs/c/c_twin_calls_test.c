// Two calls of one function, at the same depth, with nothing recorded and no
// conditional branch between them, that also agree on every register at the
// stop `tests/native_calltrace_jump_test.rs` keeps (`sink = scaled;`): both are
// `scale(10)`, and they differ only in memory, in `calls` and the local `nth`
// (1 in the first call, 2 in the second).
//
// An MCR replay tells the two stops apart by the served thread's retired
// instruction count, so activating the second call's row must land in it
// (`nth` == 2). An rr replay identifies a stop by its event, tick count and
// registers, which these two stops share, so it must refuse the jump and
// leave the session where it was. Keep `scale` and the code between the two
// calls branch-free and keep the stop's registers equal in both calls.

#include <stdio.h>

static volatile int calls;
static volatile int sink;

static int scale(int value) {
    int nth = calls + 1;
    calls = nth;
    int scaled = value * 3;
    sink = scaled;
    return scaled;
}

int main(void) {
    int first = scale(10);
    int second = scale(10);
    printf("first %d second %d calls %d\n", first, second, calls);
    return 0;
}
