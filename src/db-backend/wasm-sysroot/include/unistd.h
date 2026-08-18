#pragma once

int dup(int);

/*
 * pid_t / getpid — declared so the Nim-generated ct_emulator C
 * (@mlockstep_merkle.nim.c calls getpid()) compiles under clang 21's strict
 * -Wimplicit-function-declaration=error on wasm32-unknown-unknown.  POSIX
 * defines pid_t as a signed integer type; a plain `int` matches the generated
 * code, which assigns the result into an `int`.  No wasm-native definition
 * exists, so getpid resolves as a module import at link time (the emulator
 * only uses it to tag a merkle log; a fixed host value is acceptable there).
 */
typedef int pid_t;
pid_t getpid(void);
