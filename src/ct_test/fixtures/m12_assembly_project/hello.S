/*
 * Portable executable-level assembly fixture for the CodeTracer M12 fallback
 * provider.  The provider compiles this file with
 *   gcc -g -no-pie -x assembler-with-cpp
 * and runs the resulting binary, asserting that it prints
 * "assembly fixture passed".
 *
 * Raw syscall / ELF assembly is not portable across the targets CodeTracer is
 * developed and tested on (x86_64-linux on CI; arm64-darwin and x86_64-darwin
 * on developer machines).  To keep a single fixture that assembles and runs in
 * every dev shell, we select an architecture/ABI-specific body with the C
 * preprocessor (enabled by gcc's "assembler-with-cpp" input language) and call
 * libc's puts(), which gcc links by default.  This keeps the program a genuine
 * hand-written assembly translation unit while staying ABI-correct everywhere.
 *
 * References:
 *  - System V AMD64 ABI (arg0 in %rdi): https://gitlab.com/x86-psABIs/x86-64-ABI
 *  - AArch64 PCS (arg0 in x0):           https://github.com/ARM-software/abi-aa
 *  - Mach-O symbols are prefixed with an underscore on Apple platforms.
 */

#if defined(__APPLE__)
#  define CSYM(name) _##name
#else
#  define CSYM(name) name
#endif

/* ------------------------------------------------------------------ x86_64 */
#if defined(__x86_64__)

#  if defined(__APPLE__)
    .section __TEXT,__text
#  else
    .text
#  endif
    .globl CSYM(main)
    .p2align 4
CSYM(main):
    push %rbp
    mov %rsp, %rbp
    lea message(%rip), %rdi
    call CSYM(puts)@PLT
    xor %eax, %eax
    pop %rbp
    ret

/* ----------------------------------------------------------------- aarch64 */
#elif defined(__aarch64__) || defined(__arm64__)

#  if defined(__APPLE__)
    .section __TEXT,__text
#  else
    .text
#  endif
    .globl CSYM(main)
    .p2align 2
CSYM(main):
    stp x29, x30, [sp, #-16]!
    mov x29, sp
#  if defined(__APPLE__)
    adrp x0, message@PAGE
    add  x0, x0, message@PAGEOFF
#  else
    adrp x0, message
    add  x0, x0, :lo12:message
#  endif
    bl   CSYM(puts)
    mov  w0, #0
    ldp  x29, x30, [sp], #16
    ret

#else
#  error "unsupported architecture for the M12 assembly fixture"
#endif

/* ------------------------------------------------------------------- data */
#if defined(__APPLE__)
    .section __TEXT,__cstring
#else
    .section .rodata
#endif
message:
    .asciz "assembly fixture passed"
