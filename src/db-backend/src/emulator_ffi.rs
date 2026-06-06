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

    // -----------------------------------------------------------------
    // M17 — value-origin hybrid origin tier (undo-map last-mile +
    // breakpoint fallback). See spec §6.4 of
    // `codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`.
    //
    // The Nim shim lives at
    // `codetracer-native-recorder/ct_emulator/src/ct_emulator/origin_undo_ffi.nim`.
    //
    // These entry points are split into:
    //
    //   * an admin surface (`mcrUndoMapReset`, `mcrUndoMapSetWindow`,
    //     `mcrUndoMapPushWrite`) that the M17 algorithm uses to seed the
    //     Nim-side state from Rust fixtures so the Tier 1 path can be
    //     exercised without a live emulator pipeline;
    //   * a query surface (`mcrUndoMapWriteCoverage`,
    //     `mcrUndoMapLastWriteBefore` + the per-field
    //     `mcrUndoMapLastWriteResult*` getters) that the Tier 1 hop
    //     algorithm calls on each iteration; and
    //   * the Tier 2 reverse-step driver
    //     (`mcrLastMileReverseStepReset`, `mcrLastMileReverseStep`, plus
    //     the cursor getters) used when Tier 1 reports
    //     "out-of-window".
    //
    // All entry points are SAFE to call against an uninitialised Nim
    // runtime in the sense that they will return 0 (false) rather than
    // crash; the caller is still responsible for invoking `NimMain`
    // once via the `EmulatorReplaySession` bring-up before any of these
    // are exercised.
    // -----------------------------------------------------------------

    /// Reset the Nim-side undo map state used by the M17 hybrid
    /// algorithm. Idempotent — safe to call multiple times.
    pub fn mcrUndoMapReset();

    /// Pin the active undo window. Tier 1 coverage queries consult this
    /// range; ticks outside `[start, end]` fall through to Tier 2.
    pub fn mcrUndoMapSetWindow(start_tick: u64, end_tick: u64);

    /// Append a synthetic write record to the undo log. Used by tests
    /// and by the Rust-side window-extension helper to repopulate Tier
    /// 1 after a window flip. Returns 0 on success, -1 if `size` is out
    /// of the 1..=8 byte range.
    pub fn mcrUndoMapPushWrite(
        pc: u64,
        tick_before: u64,
        address: u64,
        size: c_int,
        old_value: u64,
        new_value: u64,
    ) -> c_int;

    /// Returns 1 iff `(address, tick)` is inside the active undo window.
    /// `address` is reserved for future per-address windowing schemes
    /// and is ignored today.
    pub fn mcrUndoMapWriteCoverage(address: u64, tick: u64) -> c_int;

    /// Scan the live undo log backwards for the most recent write whose
    /// target range overlaps `[address, address+size)` with
    /// `tick_before < tick`. Returns 1 on hit, 0 on miss. The hit's
    /// fields are read via the `mcrUndoMapLastWriteResult*` getters
    /// (one call per scalar field — keeps the FFI struct-free).
    pub fn mcrUndoMapLastWriteBefore(address: u64, size: c_int, tick: u64) -> c_int;

    /// PC of the last-write hit returned by `mcrUndoMapLastWriteBefore`.
    pub fn mcrUndoMapLastWriteResultPc() -> u64;

    /// Tick of the last-write hit (i.e. `tickBefore`).
    pub fn mcrUndoMapLastWriteResultTick() -> u64;

    /// Address of the last-write hit (the base of the write, not the
    /// query base).
    pub fn mcrUndoMapLastWriteResultAddress() -> u64;

    /// Size of the last-write hit in bytes.
    pub fn mcrUndoMapLastWriteResultSize() -> c_int;

    /// Pre-write value at the hit, zero-extended to 64 bits little-endian.
    pub fn mcrUndoMapLastWriteResultValue() -> u64;

    /// Seed the Tier-2 reverse-step driver with a budget + initial
    /// `(pc, tick)` cursor.
    pub fn mcrLastMileReverseStepReset(budget: c_int, pc: u64, tick: u64);

    /// Take one reverse-step on the Tier-2 controller. Returns:
    /// - 0 on success (cursor advanced backwards by one tick),
    /// - 1 if the budget has been exhausted,
    /// - 2 if the recording start has been reached.
    pub fn mcrLastMileReverseStep() -> c_int;

    /// Current tick of the Tier-2 cursor (post-`mcrLastMileReverseStep`).
    pub fn mcrLastMileReverseStepCurrentTick() -> u64;

    /// Current PC of the Tier-2 cursor.
    pub fn mcrLastMileReverseStepCurrentPc() -> u64;

    /// Number of reverse-steps taken since the last
    /// `mcrLastMileReverseStepReset` call.
    pub fn mcrLastMileReverseStepCount() -> c_int;

    // -----------------------------------------------------------------
    // M18 — Omniscient DB FFI surface. See spec §6.5 / §6.8.2 of
    // `codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`
    // and §1 of
    // `codetracer-specs/Recording-Backends/Multi-Core-Recorder/MCR-Omniscient-DB-Algorithms.md`.
    //
    // The Nim shim lives at
    // `codetracer-native-recorder/ct_emulator/src/ct_emulator/omniscient_db_ffi.nim`.
    //
    // Entry points are split into:
    //
    //   * an admin surface (`mcrOmniscientReset`,
    //     `mcrOmniscientPushWrite`, `mcrOmniscientPushLineHit`,
    //     `mcrOmniscientFinalize`, `mcrOmniscientLoadFromPath`) that the
    //     M18 trait + tests use to seed the omniscient store from Rust
    //     fixtures (and that the production replay path uses to load an
    //     on-disk `memwrites.tc` namespace);
    //   * a query surface (`mcrOmniscientLastWriteBefore` +
    //     per-field getters, `mcrOmniscientValueAt`,
    //     `mcrOmniscientWritesInRange` + per-record getters,
    //     `mcrOmniscientSourceLineHits` + per-entry getter) backing
    //     `OmniscientDb::{last_write_before, value_at, writes_in_range,
    //     source_line_hits}`;
    //   * the lazy interval-analysis trigger
    //     (`mcrOmniscientIntervalSchedule`,
    //     `mcrOmniscientIntervalMarkAnalyzed`,
    //     `mcrOmniscientIntervalIsAnalyzed`,
    //     `mcrOmniscientIntervalScheduledCount`) that lets the trait
    //     defer work for unanalysed intervals to a follow-on milestone
    //     without changing the trait's surface;
    //   * diagnostic accessors (`mcrOmniscientWriteCount`,
    //     `mcrOmniscientLineHitCount`) that the trait's `is_present`
    //     probe consults to detect a loaded `memwrites.tc` /
    //     `linehits.tc` namespace.
    //
    // All entry points are safe against an uninitialised Nim runtime:
    // they return zero rather than crash. The caller is still
    // responsible for invoking `NimMain` once via the
    // `EmulatorReplaySession` bring-up before any of these are
    // exercised.
    // -----------------------------------------------------------------

    /// Reset the Nim-side omniscient DB state. Idempotent.
    pub fn mcrOmniscientReset();

    /// Append a synthetic write record to the in-shim store. The Rust
    /// driver / production loader uses this to seed the store before
    /// finalisation.
    pub fn mcrOmniscientPushWrite(
        tick: u64,
        pc: u64,
        address: u64,
        size: c_int,
        old_value: u64,
        new_value: u64,
    ) -> c_int;

    /// Append a `(file_id, line, tick)` triple to the in-shim
    /// source-line hits index.
    pub fn mcrOmniscientPushLineHit(file_id: u32, line: u32, tick: u64) -> c_int;

    /// Build the binary-search indexes from the accumulated writes /
    /// hits. Idempotent — calling it after a no-op `Push` reuses the
    /// existing indexes.
    pub fn mcrOmniscientFinalize() -> c_int;

    /// Load an on-disk `write_log.nim`-formatted file into the in-shim
    /// store (production path: the recorder finalises a `memwrites.tc`
    /// namespace and the replay-worker bridge points the FFI at it).
    /// Returns 0 on success, -1 on I/O or parse failure.
    pub fn mcrOmniscientLoadFromPath(path: *const std::os::raw::c_char) -> c_int;

    /// Scan the in-shim store for the most recent write whose target
    /// range overlaps `[address, address+size)` STRICTLY before `tick`.
    /// Returns 1 on hit, 0 on miss. The hit's fields are read via the
    /// `mcrOmniscientLastWriteResult*` getters.
    pub fn mcrOmniscientLastWriteBefore(address: u64, size: c_int, tick: u64) -> c_int;

    pub fn mcrOmniscientLastWriteResultTick() -> u64;
    pub fn mcrOmniscientLastWriteResultPc() -> u64;
    pub fn mcrOmniscientLastWriteResultAddress() -> u64;
    pub fn mcrOmniscientLastWriteResultSize() -> c_int;
    pub fn mcrOmniscientLastWriteResultOldValue() -> u64;
    pub fn mcrOmniscientLastWriteResultNewValue() -> u64;

    /// Resolve the value at `[address, address+size)` at `tick` and copy
    /// up to `buf_len` bytes into `buf` little-endian. Returns 1 on hit
    /// (a recorded write at-or-before `tick` was found), 0 on miss.
    pub fn mcrOmniscientValueAt(address: u64, size: c_int, tick: u64, buf: *mut u8, buf_len: c_int) -> c_int;

    /// Convenience accessor: the most recent `mcrOmniscientValueAt`
    /// hit's value as a zero-extended `u64`.
    pub fn mcrOmniscientValueResultLow64() -> u64;

    /// Collect every write whose target range overlaps
    /// `[address, address+size)` with `tick_min <= tick <= tick_max`,
    /// sorted by ascending `tick`. Returns the number of records; each
    /// record is read via `mcrOmniscientRangeRecord*Get` with an index
    /// in `0..count`.
    pub fn mcrOmniscientWritesInRange(address: u64, size: c_int, tick_min: u64, tick_max: u64) -> c_int;

    pub fn mcrOmniscientRangeRecordTick(index: c_int) -> u64;
    pub fn mcrOmniscientRangeRecordPc(index: c_int) -> u64;
    pub fn mcrOmniscientRangeRecordAddress(index: c_int) -> u64;
    pub fn mcrOmniscientRangeRecordSize(index: c_int) -> c_int;
    pub fn mcrOmniscientRangeRecordOldValue(index: c_int) -> u64;
    pub fn mcrOmniscientRangeRecordNewValue(index: c_int) -> u64;

    /// Surface the per-line tick list for `(file_id, line)`. Returns
    /// the number of recorded hits; individual ticks are read via
    /// `mcrOmniscientSourceLineHitAt(index)`.
    pub fn mcrOmniscientSourceLineHits(file_id: u32, line: u32) -> c_int;
    pub fn mcrOmniscientSourceLineHitAt(index: c_int) -> u64;

    /// Schedule interval analysis for the given interval id. Used by
    /// the lazy-mode trigger when a query targets an unanalysed
    /// interval.
    pub fn mcrOmniscientIntervalSchedule(interval_id: u64) -> c_int;

    /// Mark an interval as analysed. Called by the analyser stub
    /// (synchronous fallback for M18) after the interval's writes have
    /// been pushed.
    pub fn mcrOmniscientIntervalMarkAnalyzed(interval_id: u64) -> c_int;

    /// Returns 1 iff the given interval has been marked as analysed.
    pub fn mcrOmniscientIntervalIsAnalyzed(interval_id: u64) -> c_int;

    /// Diagnostic: number of intervals scheduled since the last reset.
    pub fn mcrOmniscientIntervalScheduledCount() -> c_int;

    /// Diagnostic: total number of writes currently held by the
    /// in-shim store. The trait's `is_present` probe consults this to
    /// decide whether a `memwrites.tc` namespace is loaded.
    pub fn mcrOmniscientWriteCount() -> c_int;

    /// Diagnostic: number of distinct `(file_id, line)` keys currently
    /// held in the source-line hits index.
    pub fn mcrOmniscientLineHitCount() -> c_int;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, Once};

    static NIM_MAIN: Once = Once::new();
    /// All `mcr*` FFI symbols read/write Nim-global module-local state.
    /// Cargo runs tests in parallel by default, so without a single
    /// shared lock the M17 tests race on `gOriginUndoLog` and the
    /// existing F5c-1 smoke would race on `gInitialized`. The mutex
    /// is global to every test in this module so the FFI surface
    /// stays serially exclusive.
    pub(crate) static FFI_LOCK: Mutex<()> = Mutex::new(());

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
        let _guard = FFI_LOCK.lock().unwrap_or_else(|p| p.into_inner());
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

    /// M17 — coverage returns 0 against an empty undo map (no records,
    /// no window).
    #[test]
    fn m17_coverage_is_zero_on_empty_undo_log() {
        init_nim_runtime();
        let _guard = FFI_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // SAFETY: reset is idempotent and the coverage query is
        // side-effect-free apart from reading the module-local state
        // the reset just cleared.
        unsafe {
            mcrUndoMapReset();
            assert_eq!(mcrUndoMapWriteCoverage(0x1000, 42), 0);
        }
    }

    /// M17 — Tier-1 round-trip: push a synthetic write into the undo
    /// log, query for it via `mcrUndoMapLastWriteBefore`, and confirm
    /// the per-field getters surface the same values.
    #[test]
    fn m17_tier_one_round_trip_finds_synthetic_write() {
        init_nim_runtime();
        let _guard = FFI_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // SAFETY: every entry point is guarded by the module-local
        // state machine; the reset/push/query order matches the
        // documented contract.
        unsafe {
            mcrUndoMapReset();
            mcrUndoMapSetWindow(0, 1000);
            let rc = mcrUndoMapPushWrite(0xDEAD_BEEF, 100, 0x4000, 4, 0x1111, 0x2222);
            assert_eq!(rc, 0, "pushing a 4-byte write should succeed");

            assert_eq!(
                mcrUndoMapWriteCoverage(0x4000, 500),
                1,
                "(addr, tick=500) is within [0, 1000]"
            );
            assert_eq!(
                mcrUndoMapWriteCoverage(0x4000, 2000),
                0,
                "(addr, tick=2000) is OUTSIDE the active undo window"
            );

            let hit = mcrUndoMapLastWriteBefore(0x4000, 4, 200);
            assert_eq!(hit, 1, "the synthetic write must be discoverable");
            assert_eq!(mcrUndoMapLastWriteResultPc(), 0xDEAD_BEEF);
            assert_eq!(mcrUndoMapLastWriteResultTick(), 100);
            assert_eq!(mcrUndoMapLastWriteResultAddress(), 0x4000);
            assert_eq!(mcrUndoMapLastWriteResultSize(), 4);
            assert_eq!(mcrUndoMapLastWriteResultValue(), 0x1111);

            // A query strictly older than the write's `tickBefore`
            // must NOT surface it — the algorithm needs the strict-`<`
            // contract so the same query can drive successive hops
            // without re-finding the same record.
            let earlier = mcrUndoMapLastWriteBefore(0x4000, 4, 100);
            assert_eq!(earlier, 0, "queries at tick == tickBefore must miss");
        }
    }

    /// M17 — Tier-2 reverse-step driver advances the cursor and reports
    /// budget exhaustion / recording-start sentinels distinctly.
    #[test]
    fn m17_tier_two_reverse_step_reports_sentinels() {
        init_nim_runtime();
        let _guard = FFI_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // SAFETY: per the module contract `mcrLastMileReverseStepReset`
        // is the only legal way to (re-)seed the cursor; subsequent
        // step calls are scalar and side-effect-bounded to the
        // module-local cursor fields.
        unsafe {
            mcrLastMileReverseStepReset(3, 0x4000_0000, 5);
            assert_eq!(mcrLastMileReverseStep(), 0, "step 1 ok");
            assert_eq!(mcrLastMileReverseStepCurrentTick(), 4);
            assert_eq!(mcrLastMileReverseStep(), 0, "step 2 ok");
            assert_eq!(mcrLastMileReverseStep(), 0, "step 3 ok");
            assert_eq!(mcrLastMileReverseStep(), 1, "budget exhausted on step 4");
            assert_eq!(mcrLastMileReverseStepCount(), 3);

            mcrLastMileReverseStepReset(10, 0x4000_0000, 1);
            assert_eq!(mcrLastMileReverseStep(), 0, "step 1 ok");
            assert_eq!(mcrLastMileReverseStepCurrentTick(), 0);
            assert_eq!(mcrLastMileReverseStep(), 2, "recording-start at tick 0");
        }
    }
}
