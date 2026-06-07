//! M18 — Omniscient DB trait + default FFI-backed implementation.
//!
//! See:
//!
//! * `codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`
//!   §6.5 (omniscient algorithm) and §6.8.2 (FFI surface).
//! * `codetracer-specs/Recording-Backends/Multi-Core-Recorder/MCR-Omniscient-DB-Algorithms.md`
//!   §1 (`memwrites.tc` + `linehits.tc` namespace schemas).
//!
//! The Nim side already implements the persistent write log
//! ([`codetracer-native-recorder/ct_emulator/src/ct_emulator/write_log.nim`])
//! and the binary-search omniscient query layer
//! ([`codetracer-native-recorder/ct_emulator/src/ct_emulator/omniscient_query.nim`]).
//! M18's role is the *Rust integration surface* — exposing those
//! algorithms through the [`OmniscientDb`] trait, wiring the CTFS
//! `memwrites.tc` / `linehits.tc` namespaces into the trace-reader
//! detection path, and providing an on-demand interval-analysis
//! trigger.
//!
//! ## Trait surface
//!
//! [`OmniscientDb`] is the read-only query surface that origin queries
//! (M20) and `db.rs::load_history` consume. Default implementations
//! delegate every method to the FFI shim
//! ([`crate::emulator_ffi::mcrOmniscient*`]), so production callers
//! that hold a live `ReplaySession` simply get an
//! `Option<&dyn OmniscientDb>` whose presence already implies the
//! `memwrites.tc` namespace has been loaded.
//!
//! ## Lazy interval analysis
//!
//! [`OmniscientDb::ensure_interval_analyzed`] is a thin synchronous
//! stub on top of the FFI's
//! [`crate::emulator_ffi::mcrOmniscientIntervalSchedule`] +
//! [`crate::emulator_ffi::mcrOmniscientIntervalIsAnalyzed`] surface.
//! M18's deliverable is the trigger contract, not a self-driving
//! scheduler — true asynchrony lands in M19+. The implementation here
//! schedules the request, marks it analysed via
//! [`crate::emulator_ffi::mcrOmniscientIntervalMarkAnalyzed`] (the
//! recorder pipeline would do this from a worker thread in
//! production), and returns immediately so queries can re-poll.
//!
//! ## FFI thread-safety
//!
//! Every `mcrOmniscient*` symbol reads / writes the same Nim-global
//! module state — see the discipline notes in
//! [`crate::emulator_ffi::tests`]. Callers MUST hold the
//! [`omniscient_ffi_lock()`] mutex across any sequence of admin +
//! query calls to keep concurrent tests serialised.

use std::ffi::CString;
use std::sync::{Mutex, OnceLock};

use crate::emulator_ffi;

/// Tick type alias — the omniscient log keys writes by the MCR
/// conditional-branch counter. We reuse `u64` to stay binary-compatible
/// with `write_log.nim::WriteRecord` and the M17 hop algorithm in
/// [`crate::emulator_origin`].
pub type Tick = u64;

/// CTFS namespace names per
/// `Recording-Backends/Multi-Core-Recorder/MCR-Omniscient-DB-Algorithms.md`
/// §1. The Nim recorder writes both files into the CTFS container;
/// the Rust trace-reader detects them through
/// [`ctfs_has_omniscient_namespaces`].
pub const CTFS_MEMWRITES_FILE: &str = "memwrites.tc";
pub const CTFS_LINEHITS_FILE: &str = "linehits.tc";

/// P0.6 — recording-wide M32 namespace names. Present in sharded
/// recordings whose server-side coordinator emitted the cross-slice
/// reduce artefacts. Detected via
/// [`ctfs_has_global_omniscient_namespaces`].
pub const CTFS_GLOBAL_MEMWRITES_FILE: &str = "global-memwrites.tc";
pub const CTFS_GLOBAL_LINEHITS_FILE: &str = "global-linehits.tc";

/// P0.6 — recording-wide partial-with-gaps namespace. Present when one
/// or more per-slice preps failed permanently; carries a gap list the
/// trait surfaces as `TerminatorKind::UnknownSource`.
pub const CTFS_PARTIAL_GLOBAL_MEMWRITES_FILE: &str = "partial-global-memwrites.tc";

/// A single recorded memory-write event. Mirrors `WriteRecord` in
/// `write_log.nim`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WriteRecord {
    pub tick: Tick,
    pub pc: u64,
    pub address: u64,
    pub size: u32,
    pub old_value: u64,
    pub new_value: u64,
}

/// Read-only query surface for the MCR omniscient DB. M20's origin
/// queries and the materialized DB's `load_history` path both consume
/// this trait so they can transparently use the Nim-side omniscient
/// log when a trace ships one and fall back to per-backend
/// alternatives when it does not.
pub trait OmniscientDb {
    /// Find the most recent write whose target range overlaps
    /// `[addr, addr+size)` STRICTLY before `tick`. Returns `None` when
    /// no qualifying write exists in the recorded log.
    fn last_write_before(&self, addr: u64, size: u32, tick: Tick) -> Option<WriteRecord>;

    /// Resolve the value at `[addr, addr+size)` at the given tick.
    /// Returns `None` when no write at-or-before `tick` was recorded.
    fn value_at(&self, addr: u64, size: u32, tick: Tick) -> Option<Vec<u8>>;

    /// Collect every write whose target range overlaps
    /// `[addr, addr+size)` with `tick_min <= tick <= tick_max`, sorted
    /// by ascending `tick`. Empty `Vec` means no writes in range.
    fn writes_in_range(&self, addr: u64, size: u32, tick_min: Tick, tick_max: Tick) -> Vec<WriteRecord>;

    /// Surface the per-line tick list for `(file_id, line)` from the
    /// `linehits.tc` namespace. Empty `Vec` means no recorded hits.
    fn source_line_hits(&self, file_id: u32, line: u32) -> Vec<Tick>;

    /// Reports whether the omniscient DB has any recorded data. A
    /// freshly-constructed [`FfiOmniscientDb`] returns `false` until
    /// the recorder pipeline finalises `memwrites.tc` / `linehits.tc`
    /// (or the test-only admin surface seeds the in-shim store via
    /// [`FfiOmniscientDb::push_write`] /
    /// [`FfiOmniscientDb::push_line_hit`]).
    fn is_present(&self) -> bool;

    /// Schedule interval analysis for `tick`'s owning interval and
    /// block until the analyser reports completion. M18 ships a
    /// synchronous stub — the FFI's
    /// `mcrOmniscientIntervalMarkAnalyzed` is invoked inline so the
    /// trigger contract is exercisable without a real analyser
    /// thread. M19+ adds true async + placeholder summaries per spec
    /// §3.2.3.
    ///
    /// Returns `true` when the interval ended up analysed (either
    /// because it was already analysed or because the synchronous
    /// stub completed). Returns `false` only when the underlying
    /// scheduler refused the request.
    ///
    /// **Locking discipline:** this method does NOT take the
    /// [`omniscient_ffi_lock()`] mutex. Callers are expected to hold
    /// the lock for the full read-after-write sequence — that lets
    /// the synchronous stub interleave correctly with neighbouring
    /// `last_write_before` / `value_at` / `writes_in_range` calls,
    /// and avoids a reentrancy deadlock with the per-method locking
    /// in those query methods. `std::sync::Mutex` is non-reentrant,
    /// so taking the lock twice from the same thread would block
    /// forever. The FFI itself is single-threaded by construction
    /// (the Nim shim's globals are not thread-safe).
    fn ensure_interval_analyzed(&self, interval_id: u64) -> bool {
        // SAFETY: The omniscient FFI is safe against an uninitialised
        // Nim runtime (returns 0). The caller holds the global lock
        // (see method-level docs); we don't re-acquire it here
        // because `std::sync::Mutex` would deadlock on a nested
        // lock attempt from the same thread.
        unsafe {
            if emulator_ffi::mcrOmniscientIntervalIsAnalyzed(interval_id) == 1 {
                return true;
            }
            let sched = emulator_ffi::mcrOmniscientIntervalSchedule(interval_id);
            if sched != 0 {
                return false;
            }
            // M18 stub: in lieu of a real analyser thread, mark the
            // interval analysed immediately. The recorder pipeline
            // replaces this with a worker-thread call to
            // `mcrOmniscientIntervalMarkAnalyzed` from M19+.
            emulator_ffi::mcrOmniscientIntervalMarkAnalyzed(interval_id);
            emulator_ffi::mcrOmniscientIntervalIsAnalyzed(interval_id) == 1
        }
    }
}

/// Global lock around the omniscient FFI surface. Every
/// `mcrOmniscient*` symbol reads / writes Nim-global module state;
/// callers MUST hold this mutex across any read-after-write sequence
/// (e.g. push + finalize + query). Both the trait's default methods
/// and the integration tests obey this contract.
pub fn omniscient_ffi_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// Default FFI-backed implementation of [`OmniscientDb`]. Holds no
/// state — the Nim shim owns the omniscient store.
///
/// `FfiOmniscientDb` is the trait impl that
/// [`crate::emulator_session::EmulatorReplaySession`] hands out via
/// its `omniscient_db()` accessor. The admin helpers
/// (`push_write` / `push_line_hit` / `finalize` / `reset` /
/// `load_from_path`) are also exposed here so the M18 integration
/// tests and the production replay-worker bridge can drive the FFI
/// through a single typed surface.
#[derive(Debug, Default, Clone, Copy)]
pub struct FfiOmniscientDb;

impl FfiOmniscientDb {
    /// Construct a new FFI-backed handle. No FFI work is performed —
    /// the handle is zero-cost and clones freely.
    ///
    /// **Locking discipline:** the FFI surface this handle exposes
    /// shares one process-wide Nim-global module state across every
    /// `FfiOmniscientDb` instance. Callers that share the handle
    /// across threads MUST hold [`omniscient_ffi_lock()`] for the
    /// full duration of an admin + query sequence; the per-method
    /// bodies in this impl deliberately do NOT take the lock so the
    /// trait's [`OmniscientDb::ensure_interval_analyzed`] default
    /// can compose with `last_write_before` / `value_at` /
    /// `writes_in_range` without deadlocking on the non-reentrant
    /// `std::sync::Mutex`. The integration tests acquire the lock
    /// once at the top of each test; the recorder bridge does the
    /// same.
    pub fn new() -> Self {
        FfiOmniscientDb
    }

    /// Reset the in-shim store. Idempotent.
    pub fn reset(&self) {
        // SAFETY: idempotent reset of Nim-global state. The caller
        // holds `omniscient_ffi_lock()` for serialisation when
        // sharing the handle across threads.
        unsafe { emulator_ffi::mcrOmniscientReset() };
    }

    /// Push a synthetic [`WriteRecord`] into the in-shim store.
    /// Returns `true` on success, `false` if the record is malformed
    /// (out-of-range size). Used by integration tests and by the
    /// production loader before `finalize`.
    pub fn push_write(&self, record: WriteRecord) -> bool {
        // SAFETY: scalar-only arguments; Nim shim validates `size`.
        let rc = unsafe {
            emulator_ffi::mcrOmniscientPushWrite(
                record.tick,
                record.pc,
                record.address,
                record.size as i32,
                record.old_value,
                record.new_value,
            )
        };
        rc == 0
    }

    /// Append a `(file_id, line, tick)` triple to the in-shim
    /// `linehits.tc` index. Returns `true` on success.
    pub fn push_line_hit(&self, file_id: u32, line: u32, tick: Tick) -> bool {
        // SAFETY: scalar-only arguments.
        let rc = unsafe { emulator_ffi::mcrOmniscientPushLineHit(file_id, line, tick) };
        rc == 0
    }

    /// Force index construction. Subsequent queries reuse the built
    /// indexes; pushing more records after finalize invalidates them
    /// (the next query rebuilds automatically).
    pub fn finalize(&self) -> bool {
        // SAFETY: triggers the Nim shim's index build from accumulated state.
        unsafe { emulator_ffi::mcrOmniscientFinalize() == 0 }
    }

    /// Load an on-disk `memwrites.tc`-formatted file into the in-shim
    /// store. Returns `true` on success, `false` on I/O or parse
    /// failure. Production callers point this at the CTFS namespace
    /// after extracting it from the container.
    pub fn load_from_path(&self, path: &std::path::Path) -> bool {
        let c_path = match CString::new(path.to_string_lossy().as_bytes()) {
            Ok(c) => c,
            Err(_) => return false,
        };
        // SAFETY: the C string outlives the call and the Nim shim
        // copies it before returning.
        unsafe { emulator_ffi::mcrOmniscientLoadFromPath(c_path.as_ptr()) == 0 }
    }

    /// Persist the in-shim store to disk per the M18 recorder-finalize
    /// hook. Writes `memwrites.tc` via the Nim `WriteLogWriter` and the
    /// line-hits sidecar via the `LHTS|v1` binary format. Either path
    /// may be `None` to skip that artefact.
    ///
    /// Returns `true` on success. This is the round-trip sibling of
    /// [`Self::load_from_path`] + [`Self::load_line_hits_from_path`]
    /// and is the M18-completion entry point: the recorder calls this
    /// at trace-finalize time, the db-backend calls
    /// `load_from_path` at replay time, and the FFI's
    /// `mcrOmniscient*` query surface serves the chain.
    pub fn write_to_path(
        &self,
        memwrites_path: Option<&std::path::Path>,
        linehits_path: Option<&std::path::Path>,
    ) -> bool {
        let mem_c = match memwrites_path {
            Some(p) => match CString::new(p.to_string_lossy().as_bytes()) {
                Ok(c) => Some(c),
                Err(_) => return false,
            },
            None => None,
        };
        let line_c = match linehits_path {
            Some(p) => match CString::new(p.to_string_lossy().as_bytes()) {
                Ok(c) => Some(c),
                Err(_) => return false,
            },
            None => None,
        };
        let mem_ptr = mem_c.as_ref().map_or(std::ptr::null(), |c| c.as_ptr());
        let line_ptr = line_c.as_ref().map_or(std::ptr::null(), |c| c.as_ptr());
        // SAFETY: both C strings (when present) outlive the call.
        unsafe { emulator_ffi::mcrOmniscientWriteToPath(mem_ptr, line_ptr) == 0 }
    }

    /// Load a previously-written `linehits.tc` sidecar into the
    /// in-shim store. Sibling of [`Self::load_from_path`] for the
    /// line-hits artefact.
    pub fn load_line_hits_from_path(&self, path: &std::path::Path) -> bool {
        let c_path = match CString::new(path.to_string_lossy().as_bytes()) {
            Ok(c) => c,
            Err(_) => return false,
        };
        // SAFETY: the C string outlives the call.
        unsafe { emulator_ffi::mcrOmniscientLoadLineHitsFromPath(c_path.as_ptr()) == 0 }
    }

    /// P0.5 — emit a `slice-summary.tc` per the SSUM|v1 layout the
    /// .NET `SliceSummaryCodec` decodes. Used by the recorder-side
    /// per-slice prep to ship the side-car the M32 coordinator
    /// consumes. Returns `true` on success.
    pub fn write_slice_summary_to_path(
        &self,
        path: &std::path::Path,
        slice_index: u32,
        tick_lo: u64,
        tick_hi: u64,
    ) -> bool {
        let c_path = match CString::new(path.to_string_lossy().as_bytes()) {
            Ok(c) => c,
            Err(_) => return false,
        };
        // SAFETY: the C string outlives the call.
        unsafe {
            emulator_ffi::mcrOmniscientWriteSliceSummaryToPath(c_path.as_ptr(), slice_index as i32, tick_lo, tick_hi)
                == 0
        }
    }

    /// P0.6 — load a server-emitted `global-memwrites.tc` blob into
    /// the in-shim store. Used by the db-backend's sharded trace open
    /// path so [`OmniscientDb::last_write_before`] consults the
    /// recording-wide write log before the per-slice fallback.
    pub fn load_global_memwrites_from_path(&self, path: &std::path::Path) -> bool {
        let c_path = match CString::new(path.to_string_lossy().as_bytes()) {
            Ok(c) => c,
            Err(_) => return false,
        };
        // SAFETY: the C string outlives the call.
        unsafe { emulator_ffi::mcrOmniscientLoadGlobalMemwritesFromPath(c_path.as_ptr()) == 0 }
    }

    /// P0.6 — load a server-emitted `partial-global-memwrites.tc`
    /// blob into the in-shim store and accumulate the gap list.
    /// Returns `true` on success.
    pub fn load_partial_global_memwrites_from_path(&self, path: &std::path::Path) -> bool {
        let c_path = match CString::new(path.to_string_lossy().as_bytes()) {
            Ok(c) => c,
            Err(_) => return false,
        };
        // SAFETY: the C string outlives the call.
        unsafe { emulator_ffi::mcrOmniscientLoadPartialGlobalMemwritesFromPath(c_path.as_ptr()) == 0 }
    }

    /// P0.6 — number of gap entries from the most recent
    /// [`Self::load_partial_global_memwrites_from_path`] call. The
    /// db-backend's origin dispatcher consults this when classifying a
    /// query whose tick range crosses a known gap.
    pub fn partial_gap_count(&self) -> i32 {
        // SAFETY: scalar accessor.
        unsafe { emulator_ffi::mcrOmniscientPartialGapCount() }
    }

    /// P0.6 — read the (tick_lo, tick_hi, slice_index) tuple of the
    /// gap at `index`. Returns `None` when `index` is out of bounds.
    pub fn partial_gap_at(&self, index: i32) -> Option<PartialGap> {
        if index < 0 || index >= self.partial_gap_count() {
            return None;
        }
        // SAFETY: scalar accessors; valid index range checked above.
        unsafe {
            let slice = emulator_ffi::mcrOmniscientPartialGapSliceIndex(index);
            if slice < 0 {
                return None;
            }
            Some(PartialGap {
                slice_index: slice as u32,
                tick_lo: emulator_ffi::mcrOmniscientPartialGapTickLo(index),
                tick_hi: emulator_ffi::mcrOmniscientPartialGapTickHi(index),
            })
        }
    }

    /// P0.6 — return `true` when the supplied tick falls inside one of
    /// the partial-failure gap ranges. The db-backend's origin
    /// dispatcher uses this to surface
    /// `TerminatorKind::UnknownSource` per spec §6.6.
    pub fn tick_falls_in_partial_gap(&self, tick: u64) -> bool {
        let count = self.partial_gap_count();
        for i in 0..count {
            if let Some(gap) = self.partial_gap_at(i)
                && tick >= gap.tick_lo
                && tick <= gap.tick_hi
            {
                return true;
            }
        }
        false
    }
}

/// P0.6 — descriptor of one PartialGlobalMemwrites gap entry surfaced by
/// [`FfiOmniscientDb::partial_gap_at`]. The omniscient origin path
/// classifies queries whose tick range overlaps a gap as
/// `TerminatorKind::UnknownSource`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PartialGap {
    /// Index of the failed slice whose gap this describes.
    pub slice_index: u32,
    /// Inclusive lower bound of the gap's tick range.
    pub tick_lo: u64,
    /// Inclusive upper bound of the gap's tick range.
    pub tick_hi: u64,
}

impl OmniscientDb for FfiOmniscientDb {
    fn last_write_before(&self, addr: u64, size: u32, tick: Tick) -> Option<WriteRecord> {
        // SAFETY: the shim returns 1/0 and stages the hit in
        // module-local state; the per-field getters are scalar reads.
        // The caller is expected to hold `omniscient_ffi_lock()`
        // across the call when sharing the FFI surface concurrently.
        unsafe {
            let hit = emulator_ffi::mcrOmniscientLastWriteBefore(addr, size as i32, tick);
            if hit != 1 {
                return None;
            }
            Some(WriteRecord {
                tick: emulator_ffi::mcrOmniscientLastWriteResultTick(),
                pc: emulator_ffi::mcrOmniscientLastWriteResultPc(),
                address: emulator_ffi::mcrOmniscientLastWriteResultAddress(),
                size: emulator_ffi::mcrOmniscientLastWriteResultSize() as u32,
                old_value: emulator_ffi::mcrOmniscientLastWriteResultOldValue(),
                new_value: emulator_ffi::mcrOmniscientLastWriteResultNewValue(),
            })
        }
    }

    fn value_at(&self, addr: u64, size: u32, tick: Tick) -> Option<Vec<u8>> {
        if size == 0 {
            return None;
        }
        let mut buf = vec![0u8; size as usize];
        // SAFETY: `buf` is a writable slice of `size` bytes; the shim
        // copies up to `buf_len` little-endian bytes from the resolved
        // value and returns 1 on hit.
        let hit =
            unsafe { emulator_ffi::mcrOmniscientValueAt(addr, size as i32, tick, buf.as_mut_ptr(), buf.len() as i32) };
        if hit == 1 { Some(buf) } else { None }
    }

    fn writes_in_range(&self, addr: u64, size: u32, tick_min: Tick, tick_max: Tick) -> Vec<WriteRecord> {
        // SAFETY: each scalar getter reads from the same module-local
        // staging area populated by `mcrOmniscientWritesInRange`.
        unsafe {
            let count = emulator_ffi::mcrOmniscientWritesInRange(addr, size as i32, tick_min, tick_max);
            if count <= 0 {
                return Vec::new();
            }
            let mut out = Vec::with_capacity(count as usize);
            for i in 0..count {
                out.push(WriteRecord {
                    tick: emulator_ffi::mcrOmniscientRangeRecordTick(i),
                    pc: emulator_ffi::mcrOmniscientRangeRecordPc(i),
                    address: emulator_ffi::mcrOmniscientRangeRecordAddress(i),
                    size: emulator_ffi::mcrOmniscientRangeRecordSize(i) as u32,
                    old_value: emulator_ffi::mcrOmniscientRangeRecordOldValue(i),
                    new_value: emulator_ffi::mcrOmniscientRangeRecordNewValue(i),
                });
            }
            out
        }
    }

    fn source_line_hits(&self, file_id: u32, line: u32) -> Vec<Tick> {
        // SAFETY: scalar count + index reads against module-local state.
        unsafe {
            let count = emulator_ffi::mcrOmniscientSourceLineHits(file_id, line);
            if count <= 0 {
                return Vec::new();
            }
            let mut out = Vec::with_capacity(count as usize);
            for i in 0..count {
                out.push(emulator_ffi::mcrOmniscientSourceLineHitAt(i));
            }
            out
        }
    }

    fn is_present(&self) -> bool {
        // SAFETY: scalar diagnostic accessors.
        unsafe { emulator_ffi::mcrOmniscientWriteCount() > 0 || emulator_ffi::mcrOmniscientLineHitCount() > 0 }
    }
}

/// CTFS namespace probe. Returns `true` when a CTFS container declares
/// at least one of `memwrites.tc` / `linehits.tc`, signalling that the
/// trace ships an omniscient DB the [`OmniscientDb`] trait can attach
/// to. The Rust trace reader uses this to surface the presence flag
/// to `ReplaySession::omniscient_db()` callers without forcing the
/// payload to be parsed up-front.
pub fn ctfs_has_omniscient_namespaces<F>(file_exists: F) -> bool
where
    F: Fn(&str) -> bool,
{
    file_exists(CTFS_MEMWRITES_FILE) || file_exists(CTFS_LINEHITS_FILE)
}

/// P0.6 — CTFS namespace probe for the recording-wide M32 artefacts.
/// Returns `true` when a CTFS container declares at least one of
/// [`CTFS_GLOBAL_MEMWRITES_FILE`], [`CTFS_GLOBAL_LINEHITS_FILE`], or
/// [`CTFS_PARTIAL_GLOBAL_MEMWRITES_FILE`], signalling that the trace
/// is sharded and the coordinator emitted the cross-slice reduce
/// artefacts.
///
/// The sharded-trace open path consults this before falling back to
/// the per-slice [`ctfs_has_omniscient_namespaces`] probe. When this
/// returns `true`, [`FfiOmniscientDb::load_global_memwrites_from_path`]
/// (or its partial sibling) is the right loader to drive.
pub fn ctfs_has_global_omniscient_namespaces<F>(file_exists: F) -> bool
where
    F: Fn(&str) -> bool,
{
    file_exists(CTFS_GLOBAL_MEMWRITES_FILE)
        || file_exists(CTFS_GLOBAL_LINEHITS_FILE)
        || file_exists(CTFS_PARTIAL_GLOBAL_MEMWRITES_FILE)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Once;

    static NIM_MAIN: Once = Once::new();

    fn init_nim_runtime() {
        // SAFETY: idempotent guarded init of the Nim runtime.
        NIM_MAIN.call_once(|| unsafe {
            emulator_ffi::NimMain();
        });
    }

    /// Helper — fully reset BOTH the M17 undo-map state and the M18
    /// omniscient store so neighbouring tests in the same `cargo test`
    /// process never observe leftover writes.
    fn reset_all() {
        init_nim_runtime();
        // SAFETY: idempotent module-level resets.
        unsafe {
            emulator_ffi::mcrOmniscientReset();
            emulator_ffi::mcrUndoMapReset();
        }
    }

    #[test]
    fn ffi_omniscient_db_round_trip_finds_synthetic_write() {
        let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset_all();
        let db = FfiOmniscientDb::new();
        assert!(
            !db.is_present(),
            "freshly-reset shim store must report no omniscient presence"
        );

        let rec = WriteRecord {
            tick: 42,
            pc: 0xDEAD_BEEF,
            address: 0x4000,
            size: 4,
            old_value: 0x1111,
            new_value: 0x2222,
        };
        assert!(db.push_write(rec));
        assert!(db.finalize());
        assert!(db.is_present(), "shim store must report presence after push + finalize");

        let hit = db.last_write_before(0x4000, 4, 100).expect("hit expected");
        assert_eq!(hit.tick, 42);
        assert_eq!(hit.pc, 0xDEAD_BEEF);
        assert_eq!(hit.address, 0x4000);
        assert_eq!(hit.size, 4);
        assert_eq!(hit.new_value, 0x2222);
    }

    #[test]
    fn ffi_omniscient_db_writes_in_range_yields_ascending_tick() {
        let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset_all();
        let db = FfiOmniscientDb::new();
        for i in 0..8u64 {
            assert!(db.push_write(WriteRecord {
                tick: 10 + i,
                pc: 0x1000 + i,
                address: 0x4000,
                size: 4,
                old_value: i,
                new_value: i + 1,
            }));
        }
        assert!(db.finalize());

        let writes = db.writes_in_range(0x4000, 4, 12, 16);
        assert_eq!(writes.len(), 5);
        let ticks: Vec<Tick> = writes.iter().map(|w| w.tick).collect();
        assert_eq!(ticks, vec![12, 13, 14, 15, 16]);
        // All records distinct, ordered ascending.
        for window in writes.windows(2) {
            assert!(window[0].tick < window[1].tick);
        }
    }

    #[test]
    fn ffi_omniscient_db_source_line_hits_round_trips() {
        let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset_all();
        let db = FfiOmniscientDb::new();
        db.push_line_hit(7, 100, 1234);
        db.push_line_hit(7, 100, 1235);
        db.push_line_hit(7, 101, 9999);

        let ticks = db.source_line_hits(7, 100);
        assert_eq!(ticks, vec![1234, 1235]);
        let other = db.source_line_hits(7, 101);
        assert_eq!(other, vec![9999]);
        let missing = db.source_line_hits(7, 999);
        assert!(missing.is_empty());
    }

    #[test]
    fn ffi_omniscient_db_lazy_interval_marks_analyzed_on_demand() {
        let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset_all();
        let db = FfiOmniscientDb::new();
        // SAFETY: scalar probe.
        let pre = unsafe { emulator_ffi::mcrOmniscientIntervalIsAnalyzed(7) };
        assert_eq!(pre, 0, "unscheduled intervals must report unanalysed");

        assert!(db.ensure_interval_analyzed(7));
        // SAFETY: scalar probe.
        let post = unsafe { emulator_ffi::mcrOmniscientIntervalIsAnalyzed(7) };
        assert_eq!(post, 1, "trigger contract must mark the interval analysed");
        // A second call short-circuits to true without re-scheduling.
        assert!(db.ensure_interval_analyzed(7));
    }

    #[test]
    fn ctfs_namespace_probe_detects_memwrites_or_linehits() {
        let with_memwrites = |name: &str| name == CTFS_MEMWRITES_FILE;
        let with_linehits = |name: &str| name == CTFS_LINEHITS_FILE;
        let with_both = |name: &str| name == CTFS_MEMWRITES_FILE || name == CTFS_LINEHITS_FILE;
        let with_neither = |_: &str| false;

        assert!(ctfs_has_omniscient_namespaces(with_memwrites));
        assert!(ctfs_has_omniscient_namespaces(with_linehits));
        assert!(ctfs_has_omniscient_namespaces(with_both));
        assert!(!ctfs_has_omniscient_namespaces(with_neither));
    }
}
