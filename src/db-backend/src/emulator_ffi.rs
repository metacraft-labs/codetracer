//! Raw FFI bindings to the Nim MCR emulator (F5c-1 native, F5c-2 wasm32).
//!
//! The implementation lives at
//! `codetracer-native-recorder/ct_emulator/src/ct_emulator/emulator_wasm_api.nim`
//! and is compiled to C either by `build_native_api.sh` (host target) or
//! `build_wasm_api.sh` (wasm32 target). `build.rs` then links the right
//! artifact into this crate:
//!   * native build → `libmcr_emulator.so` / `.dylib` (visibility-scoped
//!     shared library, to avoid clashing with the `codetracer_trace_writer_nim`
//!     Nim runtime).
//!   * wasm32 build → plain static archive `libmcr_emulator.a`, because
//!     the wasm build excludes `codetracer_trace_writer_nim` entirely
//!     (see `Cargo.toml`'s `browser-transport` feature set).
//!
//! Callers MUST invoke `NimMain()` exactly once before using any `mcr*`
//! function. The higher-level [`crate::emulator_session::EmulatorReplaySession`]
//! wrapper handles this through a `std::sync::Once`.
//!
//! Scope for F5c-3: in addition to the bring-up symbols (`NimMain`,
//! `mcrInit`, plus the register getters used by F5c-1's smoke test), we
//! now bind the full state-loading and stepping surface required for the
//! `EmulatorReplaySession` trait methods to return real data:
//!
//! * `mcrLoadMemoryRegion` — install memory regions from a CTFS
//!   checkpoint.
//! * `mcrSetRegisters` — install the initial x86_64 register file.
//! * `mcrAddSyscallEvent` — append entries to the syscall replay log.
//! * `mcrStep` / `mcrRun` — drive the emulator forward.
//! * `mcrReadMemory` — sample emulator memory for variable evaluation.
//!
//! The Nim implementations are documented at
//! `codetracer-native-recorder/ct_emulator/src/ct_emulator/emulator_wasm_api.nim`.

#![allow(non_snake_case)]

use std::os::raw::c_int;

unsafe extern "C" {
    /// Initialise the Nim runtime. Required once per process before any
    /// other exported Nim function is called.
    pub fn NimMain();

    /// Reset emulator state. Safe to call multiple times.
    pub fn mcrInit();

    /// Install a memory region at `address` with `data_len` bytes from
    /// `data`. Returns 0 on success, -1 on failure (null pointer or
    /// non-positive length).
    pub fn mcrLoadMemoryRegion(address: u64, data: *const u8, data_len: c_int) -> c_int;

    /// Install the full x86_64 register file in argument order
    /// (rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp, r8..=r15, rip, rflags).
    /// Marks the emulator as initialised, allowing `mcrStep`/`mcrRun` to
    /// proceed.
    #[allow(clippy::too_many_arguments)]
    pub fn mcrSetRegisters(
        rax: u64,
        rbx: u64,
        rcx: u64,
        rdx: u64,
        rsi: u64,
        rdi: u64,
        rbp: u64,
        rsp: u64,
        r8: u64,
        r9: u64,
        r10: u64,
        r11: u64,
        r12: u64,
        r13: u64,
        r14: u64,
        r15: u64,
        rip: u64,
        rflags: u64,
    );

    /// Append a recorded syscall (number + return value) to the replay
    /// log. Returns 0 on success.
    pub fn mcrAddSyscallEvent(number: u64, return_value: i64) -> c_int;

    /// Single-step the emulator. Returns 0 on continuation, 1 on exit,
    /// -1 on error (or if registers have not been set).
    pub fn mcrStep() -> c_int;

    /// Run up to `max_instructions` instructions. Returns 0 on a normal
    /// stop, 1 on exit, -1 on error.
    pub fn mcrRun(max_instructions: c_int) -> c_int;

    /// Read `length` bytes of emulator memory at `address` into `buf`.
    /// Returns 0 on success, -1 on failure (null pointer, non-positive
    /// length, or address not covered by any loaded region).
    pub fn mcrReadMemory(address: u64, buf: *mut u8, length: c_int) -> c_int;

    /// Current emulator program counter, or 0 if no registers are set.
    pub fn mcrGetPC() -> u64;

    /// Current emulator stack pointer, or 0 if no registers are set.
    pub fn mcrGetSP() -> u64;

    /// Generic register accessor — see `mcr_emulator.h` for the index
    /// table (0..15 = GPRs, 16 = rip, 17 = rflags).
    pub fn mcrGetRegister(index: c_int) -> u64;

    /// Monotonic instruction counter incremented by `mcrStep`/`mcrRun`.
    pub fn mcrGetStepCounter() -> u64;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Once;

    static NIM_MAIN: Once = Once::new();

    fn init_nim_runtime() {
        // SAFETY: NimMain is idempotent at the C level but our Once guard
        // ensures it is only invoked once even if multiple tests race.
        NIM_MAIN.call_once(|| unsafe {
            NimMain();
        });
    }

    /// F5c-1 acceptance smoke test: prove that the static library is
    /// linked, the Nim runtime can be initialised, and a representative
    /// `mcr*` symbol round-trips a sensible value.
    #[test]
    fn ffi_round_trip_returns_zero_before_init() {
        init_nim_runtime();
        // SAFETY: mcrInit and the getters are safe to call against the
        // freshly-initialised Nim runtime; mcrInit resets gInitialized=false
        // so every getter must return 0.
        unsafe {
            mcrInit();
            assert_eq!(mcrGetPC(), 0, "PC must be 0 before registers are set");
            assert_eq!(mcrGetSP(), 0, "SP must be 0 before registers are set");
            assert_eq!(mcrGetRegister(0), 0, "rax must be 0 before registers are set");
            assert_eq!(mcrGetRegister(17), 0, "rflags must be 0 before registers are set");
            assert_eq!(mcrGetStepCounter(), 0, "step counter resets to 0");
        }
    }
}
