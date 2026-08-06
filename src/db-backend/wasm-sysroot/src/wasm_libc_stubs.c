/*
 * wasm_libc_stubs.c — minimal libc symbol definitions for the db-backend
 * wasm32-unknown-unknown build's trimmed sysroot.
 *
 * The wasm-sysroot headers under ../include declare the slice of libc the
 * Nim-generated ct_emulator C and its shims reference.  Most of those symbols
 * are satisfied elsewhere: memory/stdio routines come from the Rust VFS shim,
 * and math routines lower to native wasm instructions or compiler-rt's libm.
 * A few POSIX process primitives have no such provider on
 * wasm32-unknown-unknown and would otherwise be left as undefined symbols that
 * wasm-ld rejects.  We define minimal, deterministic stubs for them here and
 * compile this TU into libmcr_emulator.a via db-backend's build.rs.
 *
 * getpid: the emulator only calls getpid() to tag a merkle diagnostic log with
 * the recorder's PID (see @mlockstep_merkle.nim.c: emuMerklePid).  A wasm
 * module is a single sandboxed instance with no OS PID; returning a fixed
 * constant is both correct for that diagnostic use and deterministic, which is
 * exactly what MCR's exact-replay contract wants (a real, varying PID would be
 * a source of non-determinism, not a feature).
 */

#include <unistd.h>

pid_t getpid(void) {
  return 1;
}
