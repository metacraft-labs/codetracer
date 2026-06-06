//! M22 — WASM emulator data-watch primitive (browser-replay parity).
//!
//! Implements the typed Rust wrapper around the Nim-side
//! `mcrDataWatch*` FFI surface. The browser-replay origin algorithm
//! (`TraceKind::Emulator` with no omniscient log) consumes this
//! through the [`ReplaySession::data_watch_*`] trait methods so the
//! M22 §6.6 hybrid path (undo-map last-mile + emulator data-breakpoint
//! pre-window) runs entirely inside the same WASM emulator instance —
//! no extra processes, no leaving the browser.
//!
//! See spec §6.6 of
//! `codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`.
//!
//! ## Surface
//!
//! * [`DataWatchHandle`] — opaque handle returned by
//!   [`install_data_watch`]. Cleared via [`clear_data_watch`].
//! * [`DataWatchFire`] — fire record (tick / pc / address / size /
//!   old_value / new_value) lifted out of the Nim-side staging area.
//! * [`install_data_watch`] / [`clear_data_watch`] / [`reset_data_watches`]
//!   / [`check_write`] — the typed entry points.
//! * [`DataWatchError`] — surfaces "watch slots exhausted" and
//!   "invalid argument" with precise reasons so the M22 acceptance
//!   test ``test_emulator_data_breakpoint_max_simultaneous_watches``
//!   can assert the error verbatim.
//!
//! ## V1 cap
//!
//! [`MAX_DATA_WATCHES`] = 32 mirrors the Nim shim's compile-time
//! constant. Installing a 33rd watch returns
//! [`DataWatchError::WatchSlotsExhausted`].
//!
//! ## Locking discipline
//!
//! All `mcrDataWatch*` FFI calls read/write Nim-global module-local
//! state shared across the process. Callers that share the surface
//! across threads MUST serialise via [`data_watch_ffi_lock()`] (a
//! `std::sync::Mutex`). Single-threaded callers — the origin
//! algorithm runs in the request-handling thread — don't need to take
//! the lock manually because the M22 origin path always acquires the
//! lock at the top of the chain-build.

use std::sync::{Mutex, OnceLock};

use crate::emulator_ffi;

/// V1 cap on simultaneous watches. Mirrors the Nim shim's
/// `MaxDataWatches` constant. See spec §12 / the M22 milestone
/// deliverables for the rationale.
pub const MAX_DATA_WATCHES: u32 = 32;

/// Opaque handle returned by [`install_data_watch`]. Wraps the C-int
/// handle the Nim shim mints so callers cannot accidentally pass a
/// raw int. Cloned freely; calling [`clear_data_watch`] on an already-
/// cleared handle returns
/// [`DataWatchError::UnknownHandle`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct DataWatchHandle(pub i32);

impl DataWatchHandle {
    /// Raw handle value (positive on success).
    pub fn raw(self) -> i32 {
        self.0
    }
}

/// Fire record staged by the Nim-side shim on the most-recent fire.
/// Lifted into a Rust struct via the per-field getters so callers
/// don't have to call ten FFI getters at the call site.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DataWatchFire {
    /// Handle of the watch that fired.
    pub handle: DataWatchHandle,
    /// Tick of the firing instruction (per spec §6.6 the
    /// "writing instruction").
    pub tick: u64,
    /// PC of the firing instruction.
    pub pc: u64,
    /// Address of the write.
    pub address: u64,
    /// Size in bytes of the write.
    pub size: u32,
    /// Value at `[address, address+size)` BEFORE the write.
    pub old_value: u64,
    /// Value at `[address, address+size)` AFTER the write.
    pub new_value: u64,
}

/// Typed errors returned by the data-watch primitive. Each variant
/// carries a precise reason so the origin-error mapper can surface
/// the failure to the user verbatim.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DataWatchError {
    /// V1 cap of 32 simultaneous watches has been reached. The M22
    /// acceptance test asserts this is surfaced verbatim — do not
    /// rewrite the error string without updating the test.
    WatchSlotsExhausted,
    /// Size is out of the V1 `1..=8` byte range.
    InvalidSize(u32),
    /// `clear_data_watch` was called with a handle the shim doesn't
    /// recognise (already cleared, or never installed).
    UnknownHandle(i32),
}

impl std::fmt::Display for DataWatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DataWatchError::WatchSlotsExhausted => write!(
                f,
                "watch slots exhausted (V1 cap of {} simultaneous watches reached)",
                MAX_DATA_WATCHES
            ),
            DataWatchError::InvalidSize(size) => write!(f, "invalid watch size {size} bytes (V1 supports 1..=8)"),
            DataWatchError::UnknownHandle(h) => {
                write!(f, "data-watch handle {h} is not installed (already cleared?)")
            }
        }
    }
}

impl std::error::Error for DataWatchError {}

/// Global lock around the data-watch FFI surface. Every
/// `mcrDataWatch*` symbol touches Nim-global module state, so
/// concurrent callers MUST take this lock for the full duration of
/// a "reset + install + probe + clear" sequence. Single-threaded
/// callers (the origin algorithm) take the lock once at the top of
/// the chain build.
pub fn data_watch_ffi_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// Reset every armed watch + diagnostic counter. Mirrors the M17 /
/// M18 reset discipline so tests that share the per-process Nim
/// state never observe each other's seeded watches.
pub fn reset_data_watches() {
    // SAFETY: idempotent admin call against module-local Nim state.
    unsafe { emulator_ffi::mcrDataWatchReset() };
}

/// Arm a new watch on `[address, address + size)`. Returns the
/// fresh handle on success, or [`DataWatchError`] when the install
/// is refused.
pub fn install_data_watch(address: u64, size: u32) -> Result<DataWatchHandle, DataWatchError> {
    if size == 0 || size > 8 {
        return Err(DataWatchError::InvalidSize(size));
    }
    // SAFETY: scalar-only arguments; the Nim shim handles every
    // failure mode through its return-code surface.
    let rc = unsafe { emulator_ffi::mcrDataWatchInstall(address, size as i32) };
    if rc == emulator_ffi::MCR_DATA_WATCH_SLOTS_EXHAUSTED {
        Err(DataWatchError::WatchSlotsExhausted)
    } else if rc == emulator_ffi::MCR_DATA_WATCH_INVALID_ARG {
        Err(DataWatchError::InvalidSize(size))
    } else if rc <= 0 {
        // Defensive: any other non-positive rc means the shim refused
        // the install for an unmodelled reason. Map to InvalidSize so
        // the caller surfaces a typed error instead of crashing.
        Err(DataWatchError::InvalidSize(size))
    } else {
        Ok(DataWatchHandle(rc))
    }
}

/// Tear down the watch with `handle`. Returns `Ok(())` on success or
/// [`DataWatchError::UnknownHandle`] when the handle is already
/// cleared or was never installed.
pub fn clear_data_watch(handle: DataWatchHandle) -> Result<(), DataWatchError> {
    // SAFETY: scalar-only argument.
    let rc = unsafe { emulator_ffi::mcrDataWatchClear(handle.raw()) };
    if rc == 0 {
        Ok(())
    } else {
        Err(DataWatchError::UnknownHandle(handle.raw()))
    }
}

/// Number of slots currently armed.
pub fn installed_count() -> u32 {
    // SAFETY: scalar diagnostic probe.
    unsafe { emulator_ffi::mcrDataWatchInstalledCount() as u32 }
}

/// Inner-loop per-write probe. Returns the fire record on hit, or
/// `None` if no watch overlaps the write.
///
/// **This is the primitive the §6.6 hybrid algorithm consumes to
/// resolve a pre-window origin query.** The Rust origin driver
/// arms a watch on the queried `(address, size)`, replays from the
/// nearest checkpoint, calls [`check_write`] per emulated write,
/// and surfaces the resulting `(tick, pc, old, new)` tuple as an
/// origin hop.
pub fn check_write(
    tick: u64,
    pc: u64,
    address: u64,
    size: u32,
    old_value: u64,
    new_value: u64,
) -> Option<DataWatchFire> {
    // SAFETY: scalar arguments; the shim short-circuits when no
    // watches are armed and stages the fire record in module-local
    // state on a hit.
    let rc = unsafe { emulator_ffi::mcrDataWatchCheckWrite(tick, pc, address, size as i32, old_value, new_value) };
    if rc <= 0 {
        return None;
    }
    // SAFETY: per-field getters read from the same module-local
    // staging area populated by `mcrDataWatchCheckWrite`.
    let fire = unsafe {
        DataWatchFire {
            handle: DataWatchHandle(emulator_ffi::mcrDataWatchLastFireHandle()),
            tick: emulator_ffi::mcrDataWatchLastFireTick(),
            pc: emulator_ffi::mcrDataWatchLastFirePc(),
            address: emulator_ffi::mcrDataWatchLastFireAddress(),
            size: emulator_ffi::mcrDataWatchLastFireSize() as u32,
            old_value: emulator_ffi::mcrDataWatchLastFireOldValue(),
            new_value: emulator_ffi::mcrDataWatchLastFireNewValue(),
        }
    };
    Some(fire)
}

/// Diagnostic: total writes probed since the last reset. Used by the
/// M22 perf-overhead test to compute per-write inner-loop cost.
pub fn write_check_count() -> u64 {
    // SAFETY: scalar diagnostic probe.
    unsafe { emulator_ffi::mcrDataWatchWriteCheckCount() }
}

/// Diagnostic: total fires since the last reset.
pub fn fire_count() -> u64 {
    // SAFETY: scalar diagnostic probe.
    unsafe { emulator_ffi::mcrDataWatchFireCount() }
}

/// Number of fires currently held in the ring buffer.
pub fn history_len() -> u32 {
    // SAFETY: scalar diagnostic probe.
    unsafe { emulator_ffi::mcrDataWatchHistoryLen() as u32 }
}

/// Find the most-recent fire in the history ring whose target range
/// overlaps `[address, address + size)` STRICTLY before `tick`.
/// Returns `Some(fire)` on hit, `None` on miss.
///
/// This is the primitive the M22 §6.6 hybrid origin algorithm
/// consumes to walk fires backwards across multiple hops without
/// re-running the WASM emulator for each hop — the buffer is filled
/// once per replay window and the algorithm walks it backwards using
/// the previous hop's `tick_before` as the next `tick`.
pub fn history_find_before(address: u64, size: u32, tick: u64) -> Option<DataWatchFire> {
    if size == 0 {
        return None;
    }
    // SAFETY: scalar arguments; the shim stages the hit into module-
    // local state.
    let rc = unsafe { emulator_ffi::mcrDataWatchHistoryFindBefore(address, size as i32, tick) };
    if rc != 1 {
        return None;
    }
    let fire = unsafe {
        DataWatchFire {
            handle: DataWatchHandle(emulator_ffi::mcrDataWatchLastFireHandle()),
            tick: emulator_ffi::mcrDataWatchLastFireTick(),
            pc: emulator_ffi::mcrDataWatchLastFirePc(),
            address: emulator_ffi::mcrDataWatchLastFireAddress(),
            size: emulator_ffi::mcrDataWatchLastFireSize() as u32,
            old_value: emulator_ffi::mcrDataWatchLastFireOldValue(),
            new_value: emulator_ffi::mcrDataWatchLastFireNewValue(),
        }
    };
    Some(fire)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use std::sync::Once;

    static NIM_MAIN: Once = Once::new();

    fn ensure_nim() {
        NIM_MAIN.call_once(|| unsafe {
            emulator_ffi::NimMain();
        });
    }

    fn reset() {
        ensure_nim();
        reset_data_watches();
    }

    #[test]
    fn install_then_clear_round_trip() {
        let _guard = data_watch_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset();
        let handle = install_data_watch(0x4000, 4).expect("install ok");
        assert_eq!(installed_count(), 1);
        clear_data_watch(handle).expect("clear ok");
        assert_eq!(installed_count(), 0);
    }

    #[test]
    fn install_rejects_invalid_size() {
        let _guard = data_watch_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset();
        assert!(matches!(
            install_data_watch(0x4000, 0),
            Err(DataWatchError::InvalidSize(0))
        ));
        assert!(matches!(
            install_data_watch(0x4000, 9),
            Err(DataWatchError::InvalidSize(9))
        ));
    }

    #[test]
    fn install_caps_at_max() {
        let _guard = data_watch_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset();
        let mut handles = Vec::new();
        for i in 0..MAX_DATA_WATCHES {
            let h = install_data_watch(0x4000 + i as u64 * 8, 4).expect("install ok");
            handles.push(h);
        }
        // The (cap+1)th install must surface the precise
        // WatchSlotsExhausted error so the user can act on it.
        let err = install_data_watch(0xDEAD, 4).unwrap_err();
        assert_eq!(err, DataWatchError::WatchSlotsExhausted);
        // Tear down every handle to leave the global state clean.
        for h in handles {
            clear_data_watch(h).expect("clear ok");
        }
        assert_eq!(installed_count(), 0);
    }

    #[test]
    fn check_write_short_circuits_when_no_watches() {
        let _guard = data_watch_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset();
        let before = write_check_count();
        let fire = check_write(100, 0x500, 0x4000, 4, 0x11, 0x22);
        assert!(fire.is_none(), "no watches armed -> no fire");
        // The counter still increments so the perf-overhead test can
        // observe the inner-loop probe cost.
        assert_eq!(write_check_count(), before + 1);
    }

    #[test]
    fn check_write_fires_on_matching_address() {
        let _guard = data_watch_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset();
        let handle = install_data_watch(0x4000, 4).expect("install ok");
        // A write that overlaps the watch range fires the watch.
        let fire = check_write(100, 0xC0DE, 0x4000, 4, 0x11, 0x22).expect("fire expected");
        assert_eq!(fire.handle, handle);
        assert_eq!(fire.tick, 100);
        assert_eq!(fire.pc, 0xC0DE);
        assert_eq!(fire.address, 0x4000);
        assert_eq!(fire.size, 4);
        assert_eq!(fire.old_value, 0x11);
        assert_eq!(fire.new_value, 0x22);
        // A non-overlapping write at the same tick does NOT fire.
        let miss = check_write(101, 0xC0DE, 0x5000, 4, 0, 0);
        assert!(miss.is_none(), "non-overlapping write must not fire");
        clear_data_watch(handle).expect("clear ok");
    }

    #[test]
    fn history_find_before_walks_fires_backwards() {
        let _guard = data_watch_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset();
        let handle = install_data_watch(0x4000, 4).expect("install ok");
        // Seed three fires at ticks 100/200/300.
        for (tick, pc, old, new) in [(100u64, 0xAAu64, 0u64, 1u64), (200, 0xBB, 1, 2), (300, 0xCC, 2, 3)] {
            assert!(check_write(tick, pc, 0x4000, 4, old, new).is_some());
        }
        assert_eq!(history_len(), 3);
        // Walking backwards from tick 1000 returns the most-recent
        // fire (tick=300).
        let f = history_find_before(0x4000, 4, 1000).expect("hit at 300");
        assert_eq!(f.tick, 300);
        // Then 200, then 100, then None.
        let f = history_find_before(0x4000, 4, 300).expect("hit at 200");
        assert_eq!(f.tick, 200);
        let f = history_find_before(0x4000, 4, 200).expect("hit at 100");
        assert_eq!(f.tick, 100);
        assert!(history_find_before(0x4000, 4, 100).is_none(), "no fire before tick 100");
        clear_data_watch(handle).expect("clear ok");
    }
}
