// Cooperative-domain C++ flow program for MCR cooperative record/replay.
//
// WHY THIS EXISTS SEPARATELY FROM cpp_flow_test.cpp
// -------------------------------------------------
// Cooperative capture can only see syscalls issued from the TRACEE'S OWN
// IMAGE.  The hook is installed by rebinding the main executable's indirect
// symbol table (fishhook), and dyld strips the indirect symbol table from
// dyld-shared-cache images, so a call site inside libc++ or libsystem_c is
// permanently out of reach.  See
// codetracer-specs/Recording-Backends/Multi-Core-Recorder/MCR-Cooperative-Mobile.md
// ("Why cooperative mode exists" / "The capability boundary").
//
// `cpp_flow_test.cpp` reaches the C++ runtime for its I/O: `std::cout` lives in
// `/usr/lib/libc++.1.dylib` and its `write(2)` is issued from there.  That
// program is therefore NOT a valid cooperative target — measured, it records
// exactly two events (one `evThreadStart` plus its orphan `evVerifyArgHash`
// companion) no matter how much it prints.  That is the boundary working as
// designed, not a recorder defect, so it must not be "fixed" by hooking the
// stdio/iostream family.
//
// This program is the same computation with its I/O put back inside the
// cooperative domain: every byte of output is formatted in-image and handed to
// a single direct `write(2)` whose call site is in the main executable.  The
// binary is still dynamically linked — macOS ships no static libc (no
// `libSystem.a`, no `crt0.o`; `clang -static` fails to link), and clang++
// always links libc++ — but nothing on the I/O path calls into either.
//
// The printed text and every local's value match `cpp_flow_test.cpp`, so the
// two programs stay comparable.  `cpp_flow_test.cpp` is left alone: it is the
// fixture for the DAP/flow tests (breakpoint line 19, `std`/`cout`/`endl` in
// the excluded-identifier set), and those tests want the libc++ call sites.
//
// Deliberately runtime-free on the output path: no iostream, no `snprintf`, no
// allocation.  Formatting is hand-rolled into a stack buffer so the recorded
// event stream is exactly one `evOsWrite` per printed line and nothing else.

#include <unistd.h>

namespace {

int append_str(char *buf, int pos, const char *s) {
    while (*s) buf[pos++] = *s++;
    return pos;
}

int append_int(char *buf, int pos, int v) {
    char tmp[16];
    int n = 0;
    unsigned int u;
    if (v < 0) {
        buf[pos++] = '-';
        u = static_cast<unsigned int>(-static_cast<long>(v));
    } else {
        u = static_cast<unsigned int>(v);
    }
    do {
        tmp[n++] = static_cast<char>('0' + (u % 10u));
        u /= 10u;
    } while (u != 0u);
    while (n > 0) buf[pos++] = tmp[--n];
    return pos;
}

// One line out, one `write(2)` in.  A short or failed write is a hole in both
// the program's output and the recorded stream, so it exits loudly rather than
// being dropped on the floor.
void emit(const char *label, int value) {
    char buf[64];
    int n = append_str(buf, 0, label);
    n = append_int(buf, n, value);
    buf[n++] = '\n';
    ssize_t w = ::write(1, buf, static_cast<size_t>(n));
    if (w != static_cast<ssize_t>(n)) ::_exit(70);
}

}  // namespace

int calculate_sum(int a, int b) {
    int sum = a + b;
    int doubled = sum * 2;
    int final_result = doubled + 10;
    emit("Sum: ", sum);
    emit("Doubled: ", doubled);
    emit("Final: ", final_result);
    return final_result;
}

int main() {
    int x = 10;
    int y = 32;
    int result = calculate_sum(x, y);
    emit("Result: ", result);
    return 0;
}
