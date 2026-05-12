// Tiny `_start` entry-point so the M-DWARF-1 fixture links without libc.
// We don't actually run this binary — `dwarf_index` parses the ELF for
// DWARF info — so the entry-point only needs to be a valid symbol the
// linker can resolve. On x86_64 it invokes `main` then `exit(0)` via the
// raw `SYS_exit_group` syscall (#231) so the binary is still
// theoretically executable for manual smoke-testing.

    .text
    .globl _start
    .type _start, @function
_start:
    call main
    mov $231, %rax    // SYS_exit_group
    xor %rdi, %rdi    // exit code 0
    syscall
    .size _start, .-_start
