// Cooperative-domain C flow program for MCR cooperative record/replay.
//
// WHY THIS EXISTS SEPARATELY FROM c_flow_test.c
// ---------------------------------------------
// Cooperative capture can only see syscalls issued from the TRACEE'S OWN
// IMAGE.  The hook is installed by rebinding the main executable's indirect
// symbol table (fishhook), and dyld strips the indirect symbol table from
// dyld-shared-cache images, so a call site that lives inside libsystem_c is
// permanently out of reach.  See
// codetracer-specs/Recording-Backends/Multi-Core-Recorder/MCR-Cooperative-Mobile.md
// ("Why cooperative mode exists" / "The capability boundary").
//
// `c_flow_test.c` reaches libc for its I/O: it calls `printf`, whose own
// `write(2)` is issued from inside libsystem_c.  That program is therefore
// NOT a valid cooperative target — measured, it records exactly two events
// (one `evThreadStart` plus its orphan `evVerifyArgHash` companion) no matter
// how much it prints.  That is the boundary working as designed, not a
// recorder defect, so it must not be "fixed" by hooking the stdio family.
//
// This program is the same computation with its I/O put back inside the
// cooperative domain: every byte of output is formatted in-image and handed to
// a single direct `write(2)` whose call site is in the main executable, which
// is exactly what the Rust flow fixture already does through Rust's std.  A
// fully statically-linked binary would have the same property, but macOS ships
// no static libc (no `libSystem.a`, no `crt0.o`; `clang -static` fails to
// link), so "issue the syscall from your own image" is the reachable form of
// that property on Darwin.
//
// The printed text and every local's value match `c_flow_test.c` line for
// line, so the two programs stay comparable.  `c_flow_test.c` is left alone:
// it is the fixture for the DAP/flow tests (breakpoint line 31, `printf` in
// the excluded-identifier set), and those tests want the libc call sites.
//
// Deliberately libc-free on the output path: no `snprintf`, no `malloc`, no
// stdio buffering.  Formatting is hand-rolled into a stack buffer so the
// recorded event stream is exactly one `evOsWrite` per printed line and
// nothing else.

#include <unistd.h>

#define MAX_SIZE 10

enum Color { RED, GREEN, BLUE };

struct Point {
    int x;
    int y;
};

// ---------------------------------------------------------------------------
// In-image formatted output.  Everything below runs in the main executable;
// the only libc symbol on this path is `write`, and its call site is here.
// ---------------------------------------------------------------------------

static int append_str(char *buf, int pos, const char *s) {
    while (*s) buf[pos++] = *s++;
    return pos;
}

static int append_int(char *buf, int pos, int v) {
    char tmp[16];
    int n = 0;
    unsigned int u;
    if (v < 0) {
        buf[pos++] = '-';
        u = (unsigned int)(-(long)v);
    } else {
        u = (unsigned int)v;
    }
    do {
        tmp[n++] = (char)('0' + (u % 10u));
        u /= 10u;
    } while (u != 0u);
    while (n > 0) buf[pos++] = tmp[--n];
    return pos;
}

// One line out, one `write(2)` in.  A short or failed write is a hole in both
// the program's output and the recorded stream, so it exits loudly rather than
// being dropped on the floor.
static void emit(const char *label, int value) {
    char buf[64];
    int n = append_str(buf, 0, label);
    n = append_int(buf, n, value);
    buf[n++] = '\n';
    ssize_t w = write(1, buf, (size_t)n);
    if (w != (ssize_t)n) _exit(70);
}

static void emit_point(const char *label, int x, int y) {
    char buf[64];
    int n = append_str(buf, 0, label);
    buf[n++] = '(';
    n = append_int(buf, n, x);
    n = append_str(buf, n, ", ");
    n = append_int(buf, n, y);
    buf[n++] = ')';
    buf[n++] = '\n';
    ssize_t w = write(1, buf, (size_t)n);
    if (w != (ssize_t)n) _exit(70);
}

int calculate_sum(int a, int b) {
    int sum = a + b;
    int doubled = sum * 2;
    int final_result = doubled + MAX_SIZE;
    emit("Sum: ", sum);
    emit("Doubled: ", doubled);
    emit("Final: ", final_result);
    return final_result;
}

void with_loops(int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        sum += i;
    }
    emit("for sum: ", sum);

    sum = 0;
    int j = 0;
    while (j < n) {
        sum += j;
        j++;
    }
    emit("while sum: ", sum);

    sum = 0;
    int k = 0;
    do {
        sum += k;
        k++;
    } while (k < n);
    emit("do-while sum: ", sum);
}

int main(void) {
    int x = 10;
    int y = 32;
    int result = calculate_sum(x, y);
    emit("Result: ", result);

    struct Point p;
    p.x = x;
    p.y = y;
    emit_point("Point: ", p.x, p.y);

    enum Color c = GREEN;
    emit("Color: ", c);

    with_loops(x);
    return 0;
}
