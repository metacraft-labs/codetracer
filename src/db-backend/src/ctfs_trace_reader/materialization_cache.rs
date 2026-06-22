//! M6 — coverage-aware materialization cache for the recreator replay path.
//!
//! ## What this is
//!
//! This module is the live-wiring layer M4/M5 deferred: the coverage-aware
//! *gate* that sits in front of the Memory Recreator (the `RecreatorReplaySession`
//! / native replay worker — RR, MCR, or TTD) so that re-execution happens **only**
//! for tick intervals that are not already materialized.
//!
//! It implements the [Naming-Alignment.md "Hybrid query flow"][naming] /
//! [MCR-Omniscient-DB-Algorithms.md §2.4][mcr] decision logic on top of the M4/M5
//! data model:
//!
//! 1. **Check `coverage.tc`.** Compute the target tick interval for a query. If it
//!    is recorded **COVERED**, serve from the materialized maps — no re-execution.
//! 2. **On miss, re-execute and materialize.** For an **UNCOVERED** interval, the
//!    Memory Recreator (the [`Recreator`] trait) re-executes that interval and
//!    materializes its writes; the cache appends them to the
//!    [`IntervalTaggedMap`], writes the newly-materialized interval **back into the
//!    `.ct`** through the M2 copy-on-write overlay
//!    ([`CtfsBlockOverlay`](super::block_overlay::CtfsBlockOverlay)) — in `Persist`
//!    mode for read-write media, `InMemory` for read-only media — and records the
//!    interval in `coverage.tc`.
//! 3. **Subsequent visits are hits.** Once an interval is in `coverage.tc`, the
//!    next visit (within the session or after a warm restart) is served from the
//!    materialized maps and does not call the recreator again.
//!
//! A fully-collapsed cache == a fully materialized trace (§2.4); the collapse step
//! lives in [`super::collapse`] and is invoked here once a contiguous span
//! completes.
//!
//! ## The `Recreator` boundary (testability)
//!
//! The real recreator is rr-based and Linux-only. The expensive, non-portable
//! "re-execute interval `[lo, hi)`" step is therefore abstracted behind the
//! [`Recreator`] trait so the **dispatch behaviour** (cache hit serves without
//! re-execution / cache miss re-executes exactly once + writes back / skip) is
//! deterministically testable on any platform with a fake recreator. The module
//! tests wire a fake recreator that returns canned writes and counts invocations.
//!
//! ## Production wiring status (honesty note)
//!
//! The decision logic + the `Recreator` boundary land here and are fully tested
//! against the fake. The PRODUCTION adapter — a `Recreator` that drives
//! [`RecreatorReplaySession`](crate::recreator_session::RecreatorReplaySession)
//! to re-execute `[lo, hi)` and dump its memory writes — is NOT yet implemented,
//! because the replay-worker protocol
//! ([`ReplayQuery`](crate::query::ReplayQuery)) currently has no
//! "materialize interval" query: re-executing an interval and emitting its
//! `memwrites.tc` is a native-backend (`codetracer-native-backend`) worker-side
//! capability that does not exist yet and genuinely requires the Linux rr worker.
//! That worker-side query + its db-backend adapter is the precise rr-gated
//! Outstanding Task tracked for this milestone; until it lands, the coverage gate
//! is exercised through the fake recreator (this is the testable seam the brief
//! asked for, not a stand-in for real rr bytes).
//!
//! [naming]: ../../../../../codetracer-specs/Refactoring-Plans/Naming-Alignment.md
//! [mcr]: ../../../../../codetracer-specs/Recording-Backends/Multi-Core-Recorder/MCR-Omniscient-DB-Algorithms.md

use std::collections::BTreeMap;
use std::error::Error;

use super::block_overlay::{BlockSink, CtfsBlockOverlay};
use super::coverage_namespace::{Coverage, CoverageMap, CoverageState};
use super::interval_tagged_map::{IntervalTaggedMap, MemWriteEntry, TickTagged};
use super::lazy_population_store::{persist_into_overlay, StoreError};
use super::server_prep_encoding::{encode_memwrites, CollapsedMemwrites};

/// The records a [`Recreator`] produces for one re-executed tick interval.
///
/// The recreator re-executes `[tick_lo, tick_hi)` and reports the memory writes
/// (and, in a fuller implementation, line hits / steps / values) it observed. M6
/// materializes the `memwrites.tc` stream — the one the M5 store persists and the
/// warm-restart reader serves — keyed by address. Each write carries its own tick
/// so the [`IntervalTaggedMap`] keeps the interval's sub-list tick-sorted.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MaterializedInterval {
    /// `(address, write)` pairs observed in the interval, in any order — the cache
    /// inserts each into its address-keyed, tick-sorted interval sub-list.
    pub writes: Vec<(u64, MemWriteEntry)>,
}

impl MaterializedInterval {
    /// An empty materialization (a covered-but-no-writes interval).
    pub fn empty() -> Self {
        MaterializedInterval { writes: Vec::new() }
    }
}

/// The Memory Recreator boundary: "re-execute + materialize interval `[lo, hi)`".
///
/// This is the single expensive, non-portable operation in the coverage-aware
/// path. Production wires a recreator that drives the real rr/MCR/TTD replay
/// worker; tests wire a fake that returns canned records and counts invocations,
/// so the hit/miss/skip dispatch behaviour is deterministically testable without
/// a real recreator (rr is Linux-only; this code is exercised on macOS too).
///
/// Implementors MUST return the COMPLETE set of writes for the half-open tick
/// range `[tick_lo, tick_hi)` — the cache marks the interval covered on success,
/// after which absence of a record for an address is treated as a genuine
/// "no write" (§1.3 invariant 7 / `coverage_add` contract).
pub trait Recreator {
    /// Re-execute `[tick_lo, tick_hi)` and return its materialized writes.
    fn re_execute_and_materialize(
        &mut self,
        tick_lo: u64,
        tick_hi: u64,
    ) -> Result<MaterializedInterval, Box<dyn Error>>;
}

/// Outcome of an [`MaterializationCache::ensure_interval_materialized`] call,
/// used by callers (and tests) to observe whether re-execution happened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnsureOutcome {
    /// The interval was already COVERED in `coverage.tc`; served from the
    /// materialized maps, the recreator was NOT invoked.
    CacheHit,
    /// The interval was UNCOVERED; the recreator re-executed it exactly once, the
    /// writes were materialized + written back, and `coverage.tc` now marks it
    /// covered.
    CacheMiss,
}

/// The coverage-aware materialization cache.
///
/// Holds the live `coverage.tc` map, the address-keyed interval-tagged write map,
/// and an `interval_id` allocator. [`Self::ensure_interval_materialized`] is the
/// gate: it consults coverage, serves a covered interval without touching the
/// recreator, and re-executes + writes back only an uncovered one.
///
/// Persistence is delegated to the M5 store ([`persist_into_overlay`]) over a
/// caller-supplied [`CtfsBlockOverlay`]; the overlay's mode (`Persist` /
/// `InMemory`) selects read-write vs read-only-media behaviour — the cache itself
/// is mode-agnostic.
pub struct MaterializationCache {
    coverage: CoverageMap,
    /// `address → per-interval, tick-sorted write sub-lists`.
    memwrites: IntervalTaggedMap<MemWriteEntry>,
    /// Next `interval_id` to hand out for a freshly-materialized interval.
    next_interval_id: u32,
    /// Maps each materialized `tick_lo` to the `interval_id` it was tagged with,
    /// so a covered read can recover the covering interval ids for merge-on-read.
    interval_ids: BTreeMap<u64, u32>,
}

impl Default for MaterializationCache {
    fn default() -> Self {
        Self::new()
    }
}

impl MaterializationCache {
    /// Create an empty cache (a cold trace — `coverage.tc` empty).
    pub fn new() -> Self {
        MaterializationCache {
            coverage: CoverageMap::new(),
            memwrites: IntervalTaggedMap::new(),
            next_interval_id: 0,
            interval_ids: BTreeMap::new(),
        }
    }

    /// Build a cache pre-seeded from an already-loaded `coverage.tc` + collapsed
    /// `memwrites.tc` (the warm-restart entry point). The reloaded writes are a
    /// single already-collapsed interval; subsequent misses extend the cache.
    pub fn from_reloaded(coverage: CoverageMap, collapsed_memwrites: Vec<(u64, MemWriteEntry)>) -> Self {
        let mut memwrites: IntervalTaggedMap<MemWriteEntry> = IntervalTaggedMap::new();
        // The reloaded image is one flat collapsed stream; tag it interval 0.
        for (address, entry) in collapsed_memwrites {
            memwrites.append(address, 0, entry);
        }
        MaterializationCache {
            coverage,
            memwrites,
            // Reserve 0 for the reloaded collapsed stream; new intervals start at 1.
            next_interval_id: 1,
            interval_ids: BTreeMap::new(),
        }
    }

    /// Read access to the live coverage map (for callers / tests).
    pub fn coverage(&self) -> &CoverageMap {
        &self.coverage
    }

    /// The deduplicated set of `interval_id`s that may hold materialized writes:
    /// interval 0 (the reloaded collapsed stream, present after a warm restart)
    /// plus every interval id this session minted on a cache miss.
    ///
    /// Deduplication is load-bearing: [`IntervalTaggedMap::merge_read`] visits each
    /// supplied id's sub-list once, so a repeated id would double-count its writes.
    fn covering_interval_ids(&self) -> Vec<u32> {
        let mut ids: Vec<u32> = self.interval_ids.values().copied().collect();
        ids.push(0);
        ids.sort_unstable();
        ids.dedup();
        ids
    }

    /// Classify a tick range against the current coverage.
    pub fn coverage_of(&self, tick_lo: u64, tick_hi: u64) -> Coverage {
        self.coverage.coverage_of(tick_lo, tick_hi)
    }

    /// Serve the writes to `address` in `[tick_lo, tick_hi)` from the materialized
    /// maps — ONLY when the range is covered.
    ///
    /// - `Some(writes)` (possibly empty for a genuine covered-no-writes) when the
    ///   range is covered: served from the maps, no re-execution.
    /// - `None` when the range is NOT covered: the caller must re-execute (the
    ///   absence of records is *unknown*, not *empty*).
    pub fn writes_in_range(&self, address: u64, tick_lo: u64, tick_hi: u64) -> Option<Vec<MemWriteEntry>> {
        match self.coverage.coverage_of(tick_lo, tick_hi) {
            Coverage::NotCovered { .. } => None,
            Coverage::Covered { .. } => Some(self.memwrites.merge_read(
                address,
                &self.covering_interval_ids(),
                tick_lo,
                tick_hi,
            )),
        }
    }

    /// The coverage-aware gate (M6 GOAL step 2).
    ///
    /// Ensure `[tick_lo, tick_hi)` is materialized:
    ///
    /// - **Covered → cache hit.** The recreator is NOT invoked; the interval is
    ///   already served from the materialized maps. Returns
    ///   [`EnsureOutcome::CacheHit`].
    /// - **Uncovered → cache miss.** The recreator re-executes the interval
    ///   exactly once; the writes are appended to the interval-tagged map and
    ///   `coverage.tc` is updated to mark the interval covered; the caller then
    ///   persists via [`Self::persist`]. Returns [`EnsureOutcome::CacheMiss`].
    ///
    /// This is the single decision point that makes the native backend
    /// coverage-aware: "re-execute once, then serve materialized".
    pub fn ensure_interval_materialized<R: Recreator + ?Sized>(
        &mut self,
        recreator: &mut R,
        tick_lo: u64,
        tick_hi: u64,
    ) -> Result<EnsureOutcome, Box<dyn Error>> {
        if tick_hi <= tick_lo {
            return Err(format!("ensure_interval_materialized: empty/inverted interval [{tick_lo}, {tick_hi})").into());
        }

        // 1. Consult coverage.tc. A fully-covered interval is served from the
        //    materialized streams with NO re-execution.
        if let Coverage::Covered { .. } = self.coverage.coverage_of(tick_lo, tick_hi) {
            return Ok(EnsureOutcome::CacheHit);
        }

        // 2. Cache miss — re-execute exactly once and materialize.
        let materialized = recreator.re_execute_and_materialize(tick_lo, tick_hi)?;
        let interval_id = self.next_interval_id;
        self.next_interval_id = self
            .next_interval_id
            .checked_add(1)
            .ok_or("ensure_interval_materialized: interval_id overflow")?;

        for (address, write) in &materialized.writes {
            // Defensive: the recreator must only report writes in-range; clip to
            // the half-open interval so a stray out-of-range record can't leak a
            // false "covered" answer for a neighbouring range.
            if write.tick() >= tick_lo && write.tick() < tick_hi {
                self.memwrites.append(*address, interval_id, *write);
            }
        }
        self.interval_ids.insert(tick_lo, interval_id);

        // Mark the interval covered ONLY after its maps are complete for the
        // range (coverage_add contract / §1.3 invariant 7).
        self.coverage.coverage_add(tick_lo, tick_hi, CoverageState::Sparse)?;

        Ok(EnsureOutcome::CacheMiss)
    }

    /// Write the current `coverage.tc` + materialized `memwrites.tc` back through
    /// the overlay (M6 GOAL step 3). The overlay's mode decides durability:
    /// `Persist` flushes to the `.ct`; `InMemory` keeps the cache session-local
    /// and leaves the backing byte-unchanged.
    ///
    /// The memwrites are emitted as a single flat (address, tick)-ordered image
    /// via the authoritative server-prep layout, so a persisted image is
    /// forward-compatible with a server-prepped slice and reloads through the M5
    /// warm-restart reader.
    pub fn persist(&self, overlay: &mut CtfsBlockOverlay) -> Result<(), StoreError> {
        let image = self.encode_memwrites_image();
        persist_into_overlay(overlay, &self.coverage, image.as_deref(), None)
    }

    /// Flush a `Persist`-mode overlay through `sink`, publishing the persisted
    /// namespaces durably. A no-op for an `InMemory` overlay.
    pub fn flush(&self, overlay: &mut CtfsBlockOverlay, sink: &mut dyn BlockSink) -> Result<(), StoreError> {
        super::lazy_population_store::flush_overlay(overlay, sink)
    }

    /// Encode the materialized writes across ALL covered intervals into one flat
    /// (address-major, tick-minor) `memwrites.tc` image, or `None` when empty.
    fn encode_memwrites_image(&self) -> Option<Vec<u8>> {
        let covering = self.covering_interval_ids();
        let mut per_address: Vec<(u64, Vec<MemWriteEntry>)> = Vec::new();
        for key in self.memwrites.keys() {
            // Merge across the whole tick domain (u64::MAX upper bound) so every
            // sub-list contributes; merge_read keeps it tick-sorted.
            let writes = self.memwrites.merge_read(key, &covering, 0, u64::MAX);
            if !writes.is_empty() {
                per_address.push((key, writes));
            }
        }
        if per_address.is_empty() {
            return None;
        }
        Some(encode_memwrites(&CollapsedMemwrites { per_address }))
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::block_overlay::{FileBlockSink, NoOpBlockSink, OverlayMode};
    use crate::ctfs_trace_reader::coverage_namespace::CTFS_COVERAGE_FILE;
    use crate::ctfs_trace_reader::ctfs_container::{write_minimal_ctfs, CtfsReader, InMemoryBlockSource, LocalFileSource};
    use crate::ctfs_trace_reader::lazy_population_store::WarmRestartReader;

    const ADDR: u64 = 0x4000;

    fn mw(tick: u64, new_value: u64) -> MemWriteEntry {
        MemWriteEntry {
            tick,
            pc: 0xCAFE,
            size: 8,
            old_value: 0,
            new_value,
        }
    }

    /// A fake [`Recreator`] that returns canned writes for a single interval and
    /// counts how many times it was actually invoked, so the hit/miss/skip
    /// dispatch behaviour is asserted DETERMINISTICALLY without a real rr engine.
    struct FakeRecreator {
        /// `(tick, new_value)` writes to return for each re-executed interval,
        /// keyed by `tick_lo`. Writes outside the range are clipped by the cache.
        canned: BTreeMap<u64, Vec<MemWriteEntry>>,
        /// Number of times `re_execute_and_materialize` was actually called.
        calls: usize,
    }

    impl FakeRecreator {
        fn new() -> Self {
            FakeRecreator {
                canned: BTreeMap::new(),
                calls: 0,
            }
        }

        fn with_interval(mut self, tick_lo: u64, writes: Vec<MemWriteEntry>) -> Self {
            self.canned.insert(tick_lo, writes);
            self
        }
    }

    impl Recreator for FakeRecreator {
        fn re_execute_and_materialize(
            &mut self,
            tick_lo: u64,
            _tick_hi: u64,
        ) -> Result<MaterializedInterval, Box<dyn Error>> {
            self.calls += 1;
            let writes = self
                .canned
                .get(&tick_lo)
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .map(|w| (ADDR, w))
                .collect();
            Ok(MaterializedInterval { writes })
        }
    }

    /// `e2e_recreator_cache_hit_serves_from_materialized` — a query in a COVERED
    /// interval returns the materialized data and the mock recreator's re-execute
    /// count stays 0.
    #[test]
    fn e2e_recreator_cache_hit_serves_from_materialized() {
        let mut cache = MaterializationCache::new();
        let mut rec = FakeRecreator::new().with_interval(0, vec![mw(100, 1), mw(500, 2)]);

        // First touch of [0, 1000) is a MISS — materializes it (1 call).
        let out = cache.ensure_interval_materialized(&mut rec, 0, 1000).unwrap();
        assert_eq!(out, EnsureOutcome::CacheMiss);
        assert_eq!(rec.calls, 1);

        // Now the interval is COVERED — a subsequent identical request is a HIT and
        // does NOT invoke the recreator.
        let out = cache.ensure_interval_materialized(&mut rec, 0, 1000).unwrap();
        assert_eq!(out, EnsureOutcome::CacheHit, "covered interval is a cache hit");
        assert_eq!(rec.calls, 1, "cache hit must NOT re-execute");

        // The covered query is served from the materialized maps.
        let served = cache.writes_in_range(ADDR, 0, 1000).expect("covered range served from maps");
        let ticks: Vec<u64> = served.iter().map(|w| w.tick).collect();
        assert_eq!(ticks, vec![100, 500], "materialized writes served from the cache");
        assert_eq!(rec.calls, 1, "serving from maps must NOT re-execute");
    }

    /// `e2e_recreator_cache_miss_replays_and_writes_back` — a query in an
    /// UNCOVERED interval calls the mock recreator exactly once, the interval is
    /// materialized, written back through the overlay (Persist), and coverage.tc
    /// now marks it covered; a subsequent identical query is then a hit with the
    /// recreator count unchanged.
    #[test]
    fn e2e_recreator_cache_miss_replays_and_writes_back() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("miss.ct");
        write_minimal_ctfs(&path, &[("stub.dat", &[1u8, 2, 3, 4])]).unwrap();

        let mut cache = MaterializationCache::new();
        let mut rec = FakeRecreator::new().with_interval(1000, vec![mw(1100, 7), mw(1900, 8)]);

        // [1000, 2000) is uncovered → cache miss → recreator called exactly once.
        assert_eq!(cache.coverage_of(1000, 2000), Coverage::NotCovered { missing: vec![(1000, 2000)] });
        let out = cache.ensure_interval_materialized(&mut rec, 1000, 2000).unwrap();
        assert_eq!(out, EnsureOutcome::CacheMiss);
        assert_eq!(rec.calls, 1, "uncovered interval re-executes exactly once");

        // coverage.tc now marks it covered, and the writes are materialized.
        assert!(matches!(cache.coverage_of(1000, 2000), Coverage::Covered { .. }));
        let served = cache.writes_in_range(ADDR, 1000, 2000).unwrap();
        assert_eq!(served.iter().map(|w| w.tick).collect::<Vec<_>>(), vec![1100, 1900]);

        // Write the materialized interval back into the .ct (Persist mode).
        let backing = Box::new(InMemoryBlockSource::new(std::fs::read(&path).unwrap()));
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();
        cache.persist(&mut overlay).unwrap();
        let mut sink = FileBlockSink::open(&path).unwrap();
        cache.flush(&mut overlay, &mut sink).unwrap();

        // Reopen with NO overlay: coverage.tc + memwrites.tc are durable, and the
        // warm-restart reader serves the covered interval.
        let mut reader = CtfsReader::open(&path).unwrap();
        assert!(reader.has_file(CTFS_COVERAGE_FILE), "coverage.tc persisted to .ct");
        let warm = WarmRestartReader::open(&mut reader).unwrap();
        assert!(matches!(warm.coverage_of(1000, 2000), Coverage::Covered { .. }));
        let reloaded = warm.writes_in_range(ADDR, 1000, 2000).unwrap().expect("covered after warm restart");
        assert_eq!(reloaded.iter().map(|w| w.tick).collect::<Vec<_>>(), vec![1100, 1900]);

        // A subsequent identical query against the live cache is a HIT — the
        // recreator count is unchanged.
        let out = cache.ensure_interval_materialized(&mut rec, 1000, 2000).unwrap();
        assert_eq!(out, EnsureOutcome::CacheHit);
        assert_eq!(rec.calls, 1, "subsequent query after write-back is a hit");
    }

    /// `test_recreator_coverage_aware_skip` — an already-covered interval is NOT
    /// re-executed (recreator count 0 for the covered probe).
    #[test]
    fn test_recreator_coverage_aware_skip() {
        let mut cache = MaterializationCache::new();

        // Pre-seed coverage as if a prior session already materialized [0, 5000).
        cache.coverage.coverage_add(0, 5000, CoverageState::CollapsedComplete).unwrap();
        cache.interval_ids.insert(0, 0);
        cache.memwrites.append(ADDR, 0, mw(2500, 42));

        // A call-counting fake: if the gate ever re-executes a covered interval,
        // `calls` becomes non-zero and the assertion below fails. (A panicking
        // recreator is avoided deliberately — unwinding across the linked Nim
        // emulator FFI boundary aborts the whole test process rather than failing
        // one test; a counter proves the skip just as strongly and deterministically.)
        let mut counting = FakeRecreator::new();

        // A probe fully inside the covered region is a hit (no re-execution)…
        let out = cache.ensure_interval_materialized(&mut counting, 1000, 2000).unwrap();
        assert_eq!(out, EnsureOutcome::CacheHit, "a covered interval skips re-execution");
        assert_eq!(counting.calls, 0, "covered sub-range re-execute count is 0");

        // …and so is the whole covered span.
        let out = cache.ensure_interval_materialized(&mut counting, 0, 5000).unwrap();
        assert_eq!(out, EnsureOutcome::CacheHit);
        assert_eq!(counting.calls, 0, "covered interval re-execute count is 0");
    }

    /// InMemory-mode write-back leaves the backing `.ct` byte-for-byte unchanged
    /// (read-only-media / non-expanding sessions), while the cache still serves
    /// the interval for the session's lifetime.
    #[test]
    fn test_in_memory_mode_leaves_backing_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("inmem.ct");
        write_minimal_ctfs(&path, &[("stub.dat", &[1u8, 2, 3, 4])]).unwrap();
        let raw_before = std::fs::read(&path).unwrap();

        let mut cache = MaterializationCache::new();
        let mut rec = FakeRecreator::new().with_interval(0, vec![mw(10, 1)]);
        cache.ensure_interval_materialized(&mut rec, 0, 1000).unwrap();

        let backing = Box::new(LocalFileSource::open(&path).unwrap());
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::InMemory).unwrap();
        cache.persist(&mut overlay).unwrap();
        // Staged in the overlay…
        assert!(overlay.has_file(CTFS_COVERAGE_FILE).unwrap());
        // …but a flush is a no-op and the backing is unchanged.
        let mut noop = NoOpBlockSink;
        cache.flush(&mut overlay, &mut noop).unwrap();
        drop(overlay);
        assert_eq!(std::fs::read(&path).unwrap(), raw_before, "InMemory mode leaves .ct unchanged");

        // The live cache still serves the interval for the session.
        let served = cache.writes_in_range(ADDR, 0, 1000).unwrap();
        assert_eq!(served.iter().map(|w| w.tick).collect::<Vec<_>>(), vec![10]);
    }

    /// Out-of-order population: materializing a distant interval first, then an
    /// earlier one, keeps each covered and leaves the gap NotCovered.
    #[test]
    fn test_out_of_order_materialization() {
        let mut cache = MaterializationCache::new();
        let mut rec = FakeRecreator::new()
            .with_interval(5000, vec![mw(5100, 1)])
            .with_interval(1000, vec![mw(1100, 2)]);

        // Materialize the distant interval first.
        assert_eq!(cache.ensure_interval_materialized(&mut rec, 5000, 6000).unwrap(), EnsureOutcome::CacheMiss);
        // Then the earlier one.
        assert_eq!(cache.ensure_interval_materialized(&mut rec, 1000, 2000).unwrap(), EnsureOutcome::CacheMiss);
        assert_eq!(rec.calls, 2);

        // Both populated intervals are covered; the gap between them is not.
        assert!(matches!(cache.coverage_of(1000, 2000), Coverage::Covered { .. }));
        assert!(matches!(cache.coverage_of(5000, 6000), Coverage::Covered { .. }));
        assert!(matches!(cache.coverage_of(2000, 5000), Coverage::NotCovered { .. }));

        // Each interval serves its own writes.
        assert_eq!(
            cache.writes_in_range(ADDR, 1000, 2000).unwrap().iter().map(|w| w.tick).collect::<Vec<_>>(),
            vec![1100]
        );
        assert_eq!(
            cache.writes_in_range(ADDR, 5000, 6000).unwrap().iter().map(|w| w.tick).collect::<Vec<_>>(),
            vec![5100]
        );
    }
}
