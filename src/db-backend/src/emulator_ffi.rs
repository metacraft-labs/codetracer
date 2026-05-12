//! Raw FFI bindings to the Nim MCR emulator (F5c-1).
//!
//! The implementation lives at
//! `codetracer-native-recorder/ct_emulator/src/ct_emulator/emulator_wasm_api.nim`
//! and is compiled to C by `build_native_api.sh`, then linked into this
//! crate by `build.rs` via `cc::Build`.
//!
//! Callers MUST invoke `NimMain()` exactly once before using any `mcr*`
//! function. The higher-level [`crate::emulator_session::EmulatorReplaySession`]
//! wrapper handles this through a `std::sync::Once`.
//!
//! Scope for F5c-1: only the symbols exercised by the bring-up unit test
//! and the session stub. F5c-3 will expand this to cover memory regions,
//! syscall events, and the full register file once the trait impl needs
//! them.

#![cfg(not(target_arch = "wasm32"))]
#![allow(non_snake_case)]

use std::os::raw::c_int;

unsafe extern "C" {
    /// Initialise the Nim runtime. Required once per process before any
    /// other exported Nim function is called.
    pub fn NimMain();

    /// Reset emulator state. Safe to call multiple times.
    pub fn mcrInit();

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
