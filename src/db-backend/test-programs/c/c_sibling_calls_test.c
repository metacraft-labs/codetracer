// Two calls of one function, at the same depth, with nothing recorded
// between them: no system call, and no conditional branch either.
//
// `tests/native_calltrace_jump_test.rs` keeps the call-trace row of the SECOND
// call to `scale` and activates it later; the session must land in that call
// (`value` == 20), not in the first one (`value` == 10). Both calls run
// between the same two recorded events (the output is written once, at
// exit), so an MCR position (a geid) is shared by both, and both run with
// the same count of retired conditional branches, so an rr tick count is
// shared too. Keep `scale` and the code between the two calls branch-free.

#include <stdio.h>

static volatile int sink;

static int scale(int value) {
    int scaled = value * 3;
    sink = scaled;
    return scaled;
}

int main(void) {
    int first = scale(10);
    int second = scale(20);
    printf("first %d second %d\n", first, second);
    return 0;
}
