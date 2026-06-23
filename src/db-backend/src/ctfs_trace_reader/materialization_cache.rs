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
//! The decision logic + the `Recreator` boundary are wired into the production
//! replay-worker protocol for the supported interval maps: memory writes and
//! source-line hits. The Linux rr worker still fails closed until it can collect
//! real records, so most tests use fake recreators or fake worker streams to
//! exercise the production cache/adapter path deterministically. Steps, calls,
//! and values are deliberately not modeled here yet: the existing stream codecs
//! encode complete `steps.dat`/`values.dat`/`calls.dat` images plus companion
//! indices, but this cache only has sparse interval-tagged map semantics. Writing
//! partial stream images would make seekable readers believe an incomplete stream
//! is authoritative.
//!
//! [naming]: ../../../../../codetracer-specs/Refactoring-Plans/Naming-Alignment.md
//! [mcr]: ../../../../../codetracer-specs/Recording-Backends/Multi-Core-Recorder/MCR-Omniscient-DB-Algorithms.md

use std::collections::BTreeMap;
use std::error::Error;

use super::block_overlay::{BlockSink, CtfsBlockOverlay};
use super::collapse::collapse_region;
use super::coverage_namespace::{Coverage, CoverageMap, CoverageState};
use super::interval_tagged_map::{IntervalTaggedMap, LineHitEntry, MemWriteEntry, TickTagged};
use super::lazy_population_store::{StoreError, persist_into_overlay};
use super::linehits_namespace::encode_linehits_cow_namespace;
use super::memwrites_namespace::encode_memwrites_cow_namespace;
use crate::omniscient_db::{OmniscientDb, Tick, WriteRecord};

/// The records a [`Recreator`] produces for one re-executed tick interval.
///
/// The recreator re-executes `[tick_lo, tick_hi)` and reports the memory writes
/// and source-line hits it observed. M6 materializes the `memwrites.tc` stream
/// and the supported M8 linehit subset; steps/calls/values remain future work.
/// Each record carries its own tick so the [`IntervalTaggedMap`] keeps the
/// interval's sub-list tick-sorted.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MaterializedInterval {
    /// `(address, write)` pairs observed in the interval, in any order — the cache
    /// inserts each into its address-keyed, tick-sorted interval sub-list.
    pub writes: Vec<(u64, MemWriteEntry)>,
    /// `(global_line_index, hit)` pairs observed in the interval, in any order.
    /// The cache inserts each into its line-keyed, tick-sorted interval sub-list.
    pub line_hits: Vec<(u64, LineHitEntry)>,
}

impl MaterializedInterval {
    /// An empty materialization (a covered-but-no-writes interval).
    pub fn empty() -> Self {
        MaterializedInterval {
            writes: Vec::new(),
            line_hits: Vec::new(),
        }
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
/// Implementors MUST return the COMPLETE set of supported records for the
/// half-open tick range `[tick_lo, tick_hi)` — the cache marks the interval
/// covered on success, after which absence of a record for an address or line is
/// treated as genuine negative knowledge for that covered interval (§1.3
/// invariant 7 / `coverage_add` contract).
pub trait Recreator {
    /// Re-execute `[tick_lo, tick_hi)` and return its materialized records.
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
    /// `global_line_index → per-interval, tick-sorted source-line hit sub-lists`.
    linehits: IntervalTaggedMap<LineHitEntry>,
    /// Next `interval_id` to hand out for a freshly-materialized interval.
    next_interval_id: u32,
    /// Maps each materialized `tick_lo` to the `interval_id` it was tagged with,
    /// so a covered read can recover the covering interval ids for merge-on-read.
    interval_ids: BTreeMap<u64, u32>,
    /// Last collapsed `memwrites.tc` image produced by the gate. Kept only while
    /// every coverage row is collapsed; any later sparse miss invalidates it.
    collapsed_memwrites_image: Option<Vec<u8>>,
    /// Last live `linehits.tc` image produced by the gate.
    collapsed_linehits_image: Option<Vec<u8>>,
}

impl std::fmt::Debug for MaterializationCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MaterializationCache")
            .field("coverage_rows", &self.coverage.rows())
            .field("memwrite_keys", &self.memwrites.keys())
            .field("linehit_keys", &self.linehits.keys())
            .field("next_interval_id", &self.next_interval_id)
            .field("interval_ids", &self.interval_ids)
            .field(
                "has_collapsed_memwrites_image",
                &self.collapsed_memwrites_image.is_some(),
            )
            .field("has_collapsed_linehits_image", &self.collapsed_linehits_image.is_some())
            .finish()
    }
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
            linehits: IntervalTaggedMap::new(),
            next_interval_id: 0,
            interval_ids: BTreeMap::new(),
            collapsed_memwrites_image: None,
            collapsed_linehits_image: None,
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
            linehits: IntervalTaggedMap::new(),
            // Reserve 0 for the reloaded collapsed stream; new intervals start at 1.
            next_interval_id: 1,
            interval_ids: BTreeMap::new(),
            collapsed_memwrites_image: None,
            collapsed_linehits_image: None,
        }
    }

    /// Read access to the live coverage map (for callers / tests).
    pub fn coverage(&self) -> &CoverageMap {
        &self.coverage
    }

    /// Whether this cache has any materialized coverage or write records.
    pub fn is_present(&self) -> bool {
        !self.coverage.rows().is_empty() || !self.memwrites.is_empty() || !self.linehits.is_empty()
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
            Coverage::Covered { .. } => {
                Some(
                    self.memwrites
                        .merge_read(address, &self.covering_interval_ids(), tick_lo, tick_hi),
                )
            }
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
        for (global_line_index, hit) in &materialized.line_hits {
            if hit.tick() >= tick_lo && hit.tick() < tick_hi {
                self.linehits.append(*global_line_index, interval_id, *hit);
            }
        }
        self.interval_ids.insert(tick_lo, interval_id);

        // Mark the interval covered ONLY after its maps are complete for the
        // range (coverage_add contract / §1.3 invariant 7).
        self.coverage.coverage_add(tick_lo, tick_hi, CoverageState::Sparse)?;
        self.collapsed_memwrites_image = None;
        self.collapsed_linehits_image = None;
        let _collapsed = self.try_collapse_completed_region(tick_lo, tick_hi)?;

        Ok(EnsureOutcome::CacheMiss)
    }

    /// Write the current `coverage.tc` + materialized `memwrites.tc` back through
    /// the overlay (M6 GOAL step 3). The overlay's mode decides durability:
    /// `Persist` flushes to the `.ct`; `InMemory` keeps the cache session-local
    /// and leaves the backing byte-unchanged.
    ///
    /// The memwrites are emitted as a CoW namespace keyed by address, with each
    /// value payload retaining the producing interval id. The warm-restart reader
    /// can still flatten the image for today's query surface, while the persisted
    /// bytes preserve sparse sub-list structure for future live omniscient map
    /// wiring.
    pub fn persist(&self, overlay: &mut CtfsBlockOverlay) -> Result<(), StoreError> {
        let image = self.encode_memwrites_image()?;
        let linehits_image = self.encode_linehits_image()?;
        persist_into_overlay(overlay, &self.coverage, image.as_deref(), linehits_image.as_deref())
    }

    /// Flush a `Persist`-mode overlay through `sink`, publishing the persisted
    /// namespaces durably. A no-op for an `InMemory` overlay.
    pub fn flush(&self, overlay: &mut CtfsBlockOverlay, sink: &mut dyn BlockSink) -> Result<(), StoreError> {
        super::lazy_population_store::flush_overlay(overlay, sink)
    }

    /// Encode the materialized writes across ALL covered intervals into a CoW
    /// `memwrites.tc` namespace image, or `None` when empty.
    fn encode_memwrites_image(&self) -> Result<Option<Vec<u8>>, StoreError> {
        if self
            .coverage
            .rows()
            .iter()
            .all(|row| row.state == CoverageState::CollapsedComplete)
            && let Some(image) = &self.collapsed_memwrites_image
        {
            return Ok(Some(image.clone()));
        }
        encode_memwrites_cow_namespace(&self.memwrites).map_err(|e| StoreError::Decode(e.to_string()))
    }

    /// Encode live materialized line hits into the production CoW
    /// `linehits.tc` namespace image, or `None` when no line hits have been
    /// materialized in this cache.
    fn encode_linehits_image(&self) -> Result<Option<Vec<u8>>, StoreError> {
        if self
            .coverage
            .rows()
            .iter()
            .all(|row| row.state == CoverageState::CollapsedComplete)
            && let Some(image) = &self.collapsed_linehits_image
        {
            return Ok(Some(image.clone()));
        }
        encode_linehits_cow_namespace(&self.linehits).map_err(|e| StoreError::Decode(e.to_string()))
    }

    fn try_collapse_completed_region(&mut self, tick_lo: u64, tick_hi: u64) -> Result<bool, Box<dyn Error>> {
        if tick_hi <= tick_lo {
            return Ok(false);
        }
        let interval_size = tick_hi - tick_lo;
        if interval_size == 0 {
            return Ok(false);
        }

        let rows = self.coverage.rows();
        let Some(row_index) = rows
            .iter()
            .position(|row| row.tick_lo == tick_lo && row.tick_hi == tick_hi)
        else {
            return Ok(false);
        };

        let mut start = row_index;
        while start > 0 {
            let prev = &rows[start - 1];
            let cur = &rows[start];
            if prev.tick_hi != cur.tick_lo || prev.tick_hi - prev.tick_lo != interval_size {
                break;
            }
            start -= 1;
        }

        let mut end = row_index + 1;
        while end < rows.len() {
            let prev = &rows[end - 1];
            let cur = &rows[end];
            if prev.tick_hi != cur.tick_lo || cur.tick_hi - cur.tick_lo != interval_size {
                break;
            }
            end += 1;
        }

        if end - start < 2 {
            return Ok(false);
        }

        let region_lo = rows[start].tick_lo;
        let region_hi = rows[end - 1].tick_hi;
        for row in &rows[start..end] {
            let expected = row.tick_lo / interval_size;
            if row.tick_lo % interval_size != 0 || self.interval_ids.get(&row.tick_lo) != Some(&(expected as u32)) {
                return Ok(false);
            }
        }

        let collapsed = collapse_region(
            &mut self.coverage,
            &self.memwrites,
            &self.linehits,
            region_lo,
            region_hi,
            interval_size,
            |key| {
                let (file_id, line) = codetracer_trace_writer::step_stream::unpack_global_line_index(key);
                (file_id as u32, line as u32)
            },
        )?;
        self.collapsed_memwrites_image = collapsed.memwrites;
        if collapsed.linehits.is_some() {
            self.collapsed_linehits_image = encode_linehits_cow_namespace(&self.linehits)
                .map_err(|e| format!("collapse linehits CoW encode failed: {e}"))?;
        }
        Ok(true)
    }

    /// Serve line hits for one packed global line key in `[tick_lo, tick_hi)` —
    /// ONLY when that tick range is covered.
    pub fn line_hits_for_key_in_range(&self, global_line_index: u64, tick_lo: u64, tick_hi: u64) -> Option<Vec<Tick>> {
        match self.coverage.coverage_of(tick_lo, tick_hi) {
            Coverage::NotCovered { .. } => None,
            Coverage::Covered { .. } => Some(
                self.linehits
                    .merge_read(global_line_index, &self.covering_interval_ids(), tick_lo, tick_hi)
                    .into_iter()
                    .map(|hit| hit.tick)
                    .collect(),
            ),
        }
    }

    fn writes_overlapping_range(
        &self,
        address: u64,
        size: u32,
        tick_lo: u64,
        tick_hi: u64,
    ) -> Option<Vec<WriteRecord>> {
        if size == 0 {
            return Some(Vec::new());
        }
        match self.coverage.coverage_of(tick_lo, tick_hi) {
            Coverage::NotCovered { .. } => None,
            Coverage::Covered { .. } => {
                let query_hi = address.saturating_add(size as u64);
                let mut out = Vec::new();
                for key in self.memwrites.keys() {
                    let records = self
                        .memwrites
                        .merge_read(key, &self.covering_interval_ids(), tick_lo, tick_hi);
                    for write in records {
                        let write_hi = key.saturating_add(write.size as u64);
                        if key < query_hi && address < write_hi {
                            out.push(WriteRecord {
                                tick: write.tick,
                                pc: write.pc,
                                address: key,
                                size: write.size,
                                old_value: write.old_value,
                                new_value: write.new_value,
                            });
                        }
                    }
                }
                out.sort_by_key(|write| write.tick);
                Some(out)
            }
        }
    }
}

impl OmniscientDb for MaterializationCache {
    fn last_write_before(&self, addr: u64, size: u32, tick: Tick) -> Option<WriteRecord> {
        if tick == 0 {
            return None;
        }
        self.writes_overlapping_range(addr, size, 0, tick)
            .and_then(|writes| writes.into_iter().next_back())
    }

    fn value_at(&self, addr: u64, size: u32, tick: Tick) -> Option<Vec<u8>> {
        if size == 0 || size > 8 {
            return None;
        }
        let write = self.last_write_before(addr, size, tick)?;
        let offset = addr.checked_sub(write.address)?;
        let query_hi = addr.checked_add(size as u64)?;
        let write_hi = write.address.checked_add(write.size as u64)?;
        if query_hi > write_hi || offset.checked_add(size as u64)? > 8 {
            return None;
        }
        let bytes = write.new_value.to_le_bytes();
        let start = offset as usize;
        let end = start + size as usize;
        Some(bytes[start..end].to_vec())
    }

    fn writes_in_range(&self, addr: u64, size: u32, tick_min: Tick, tick_max: Tick) -> Vec<WriteRecord> {
        let tick_hi = tick_max.saturating_add(1);
        self.writes_overlapping_range(addr, size, tick_min, tick_hi)
            .unwrap_or_default()
    }

    fn source_line_hits(&self, file_id: u32, line: u32) -> Vec<Tick> {
        let key = codetracer_trace_writer::step_stream::pack_global_line_index(file_id as usize, i64::from(line));
        let mut hits: Vec<Tick> = self
            .linehits
            .merge_read(key, &self.covering_interval_ids(), u64::MIN, u64::MAX)
            .into_iter()
            .map(|hit| hit.tick)
            .collect();
        hits.sort_unstable();
        hits.dedup();
        hits
    }

    fn is_present(&self) -> bool {
        MaterializationCache::is_present(self)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::block_overlay::{FileBlockSink, NoOpBlockSink, OverlayMode};
    use crate::ctfs_trace_reader::coverage_namespace::CTFS_COVERAGE_FILE;
    use crate::ctfs_trace_reader::ctfs_container::{
        CtfsReader, InMemoryBlockSource, LocalFileSource, write_minimal_ctfs,
    };
    use crate::ctfs_trace_reader::lazy_population_store::{CTFS_LINEHITS_FILE, CTFS_MEMWRITES_FILE, WarmRestartReader};
    use crate::ctfs_trace_reader::memwrites_namespace::MemwritesNamespace;
    use crate::ctfs_trace_reader::server_prep_encoding::WLOG_MAGIC;

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
        /// `(global_line_index, hit_tick)` records to return for each interval.
        canned_linehits: BTreeMap<u64, Vec<(u64, LineHitEntry)>>,
        /// Number of times `re_execute_and_materialize` was actually called.
        calls: usize,
    }

    impl FakeRecreator {
        fn new() -> Self {
            FakeRecreator {
                canned: BTreeMap::new(),
                canned_linehits: BTreeMap::new(),
                calls: 0,
            }
        }

        fn with_interval(mut self, tick_lo: u64, writes: Vec<MemWriteEntry>) -> Self {
            self.canned.insert(tick_lo, writes);
            self
        }

        fn with_line_hits(mut self, tick_lo: u64, line_hits: Vec<(u64, LineHitEntry)>) -> Self {
            self.canned_linehits.insert(tick_lo, line_hits);
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
            let line_hits = self.canned_linehits.get(&tick_lo).cloned().unwrap_or_default();
            Ok(MaterializedInterval { writes, line_hits })
        }
    }

    struct FailingRecreator {
        calls: usize,
        message: &'static str,
    }

    impl Recreator for FailingRecreator {
        fn re_execute_and_materialize(
            &mut self,
            _tick_lo: u64,
            _tick_hi: u64,
        ) -> Result<MaterializedInterval, Box<dyn Error>> {
            self.calls += 1;
            Err(self.message.into())
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
        let served = cache
            .writes_in_range(ADDR, 0, 1000)
            .expect("covered range served from maps");
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
        assert_eq!(
            cache.coverage_of(1000, 2000),
            Coverage::NotCovered {
                missing: vec![(1000, 2000)]
            }
        );
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
        let memwrites_image = reader.read_file(CTFS_MEMWRITES_FILE).unwrap();
        assert_eq!(
            &memwrites_image[0..4],
            b"NSB1",
            "live write-back persists memwrites.tc as CoW"
        );
        let mem_ns = MemwritesNamespace::open(&memwrites_image).unwrap();
        assert_eq!(
            mem_ns
                .writes_for_address(ADDR)
                .unwrap()
                .iter()
                .map(|(interval_id, write)| (*interval_id, write.tick))
                .collect::<Vec<_>>(),
            vec![(0, 1100), (0, 1900)],
            "CoW memwrites payload preserves sparse interval ids"
        );
        let warm = WarmRestartReader::open(&mut reader).unwrap();
        assert!(matches!(warm.coverage_of(1000, 2000), Coverage::Covered { .. }));
        let reloaded = warm
            .writes_in_range(ADDR, 1000, 2000)
            .unwrap()
            .expect("covered after warm restart");
        assert_eq!(reloaded, vec![mw(1100, 7), mw(1900, 8)]);
        assert_eq!(reloaded.iter().map(|w| w.tick).collect::<Vec<_>>(), vec![1100, 1900]);

        // A subsequent identical query against the live cache is a HIT — the
        // recreator count is unchanged.
        let out = cache.ensure_interval_materialized(&mut rec, 1000, 2000).unwrap();
        assert_eq!(out, EnsureOutcome::CacheHit);
        assert_eq!(rec.calls, 1, "subsequent query after write-back is a hit");
    }

    #[test]
    fn test_recreator_boundary_error_does_not_mark_coverage_complete() {
        let mut cache = MaterializationCache::new();
        let mut rec = FailingRecreator {
            calls: 0,
            message: "rr frozen emulator boundary: syscall_or_replay_event_needed",
        };

        let err = cache
            .ensure_interval_materialized(&mut rec, 1000, 2000)
            .expect_err("boundary failure must propagate instead of marking coverage");
        assert!(
            err.to_string().contains("syscall_or_replay_event_needed"),
            "structured boundary reason should remain visible in the cache error path: {err}"
        );
        assert_eq!(rec.calls, 1, "uncovered interval should invoke recreator once");
        assert_eq!(
            cache.coverage_of(1000, 2000),
            Coverage::NotCovered {
                missing: vec![(1000, 2000)]
            },
            "failed materialization must leave coverage incomplete"
        );
        assert!(
            cache.writes_in_range(ADDR, 1000, 2000).is_none(),
            "failed materialization must not create a covered-empty memwrites answer"
        );
        let line_key = codetracer_trace_writer::step_stream::pack_global_line_index(1, 10);
        assert!(
            cache.line_hits_for_key_in_range(line_key, 1000, 2000).is_none(),
            "failed materialization must not create a covered-empty linehits answer"
        );
    }

    /// `test_recreator_coverage_aware_skip` — an already-covered interval is NOT
    /// re-executed (recreator count 0 for the covered probe).
    #[test]
    fn test_recreator_coverage_aware_skip() {
        let mut cache = MaterializationCache::new();

        // Pre-seed coverage as if a prior session already materialized [0, 5000).
        cache
            .coverage
            .coverage_add(0, 5000, CoverageState::CollapsedComplete)
            .unwrap();
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
        assert_eq!(
            std::fs::read(&path).unwrap(),
            raw_before,
            "InMemory mode leaves .ct unchanged"
        );

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
        assert_eq!(
            cache.ensure_interval_materialized(&mut rec, 5000, 6000).unwrap(),
            EnsureOutcome::CacheMiss
        );
        // Then the earlier one.
        assert_eq!(
            cache.ensure_interval_materialized(&mut rec, 1000, 2000).unwrap(),
            EnsureOutcome::CacheMiss
        );
        assert_eq!(rec.calls, 2);

        // Both populated intervals are covered; the gap between them is not.
        assert!(matches!(cache.coverage_of(1000, 2000), Coverage::Covered { .. }));
        assert!(matches!(cache.coverage_of(5000, 6000), Coverage::Covered { .. }));
        assert!(matches!(cache.coverage_of(2000, 5000), Coverage::NotCovered { .. }));

        // Each interval serves its own writes.
        assert_eq!(
            cache
                .writes_in_range(ADDR, 1000, 2000)
                .unwrap()
                .iter()
                .map(|w| w.tick)
                .collect::<Vec<_>>(),
            vec![1100]
        );
        assert_eq!(
            cache
                .writes_in_range(ADDR, 5000, 6000)
                .unwrap()
                .iter()
                .map(|w| w.tick)
                .collect::<Vec<_>>(),
            vec![5100]
        );
    }

    #[test]
    fn gate_collapses_aligned_contiguous_span() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("collapsed.ct");
        write_minimal_ctfs(&path, &[("stub.dat", &[1u8])]).unwrap();

        let mut cache = MaterializationCache::new();
        let mut rec = FakeRecreator::new()
            .with_interval(0, vec![mw(100, 1)])
            .with_interval(1000, vec![mw(1100, 2)]);

        assert_eq!(
            cache.ensure_interval_materialized(&mut rec, 0, 1000).unwrap(),
            EnsureOutcome::CacheMiss
        );
        assert_eq!(cache.coverage_of(0, 1000), Coverage::Covered { all_collapsed: false });

        assert_eq!(
            cache.ensure_interval_materialized(&mut rec, 1000, 2000).unwrap(),
            EnsureOutcome::CacheMiss
        );
        assert_eq!(cache.coverage_of(0, 2000), Coverage::Covered { all_collapsed: true });

        let backing = Box::new(InMemoryBlockSource::new(std::fs::read(&path).unwrap()));
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();
        cache.persist(&mut overlay).unwrap();
        let mut sink = FileBlockSink::open(&path).unwrap();
        cache.flush(&mut overlay, &mut sink).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        let memwrites_image = reader.read_file(CTFS_MEMWRITES_FILE).unwrap();
        assert_eq!(
            &memwrites_image[..WLOG_MAGIC.len()],
            WLOG_MAGIC,
            "collapsed gate persist emits server-prep WLOG bytes"
        );
        let warm = WarmRestartReader::open(&mut reader).unwrap();
        assert_eq!(warm.coverage_of(0, 2000), Coverage::Covered { all_collapsed: true });
        assert_eq!(
            warm.writes_in_range(ADDR, 0, 2000).unwrap().unwrap(),
            vec![mw(100, 1), mw(1100, 2)]
        );
    }

    #[test]
    fn materialization_cache_omniscient_db_reads_covered_memwrites() {
        let mut cache = MaterializationCache::new();
        let mut rec = FakeRecreator::new().with_interval(0, vec![mw(100, 0x1122), mw(500, 0x3344)]);
        cache.ensure_interval_materialized(&mut rec, 0, 1000).unwrap();

        let db: &dyn OmniscientDb = &cache;
        assert!(db.is_present());
        assert_eq!(
            db.last_write_before(ADDR, 8, 501).unwrap(),
            WriteRecord {
                tick: 500,
                pc: 0xCAFE,
                address: ADDR,
                size: 8,
                old_value: 0,
                new_value: 0x3344,
            }
        );
        assert_eq!(db.value_at(ADDR, 2, 501).unwrap(), vec![0x44, 0x33]);
        assert_eq!(
            db.value_at(ADDR + 1, 2, 501).unwrap(),
            vec![0x33, 0x00],
            "partial-address reads slice at the requested byte offset"
        );
        assert_eq!(
            db.value_at(ADDR + 7, 2, 501),
            None,
            "a single write cannot prove bytes beyond its covered range"
        );
        assert_eq!(
            db.writes_in_range(ADDR, 8, 0, 999)
                .into_iter()
                .map(|write| write.tick)
                .collect::<Vec<_>>(),
            vec![100, 500]
        );
        assert_eq!(
            db.writes_in_range(ADDR, 8, 2000, 3000),
            Vec::<WriteRecord>::new(),
            "uncovered ranges do not claim negative knowledge"
        );
    }

    #[test]
    fn materialization_cache_serves_and_persists_live_linehits() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("linehits-live.ct");
        write_minimal_ctfs(&path, &[("stub.dat", &[1u8])]).unwrap();

        let key = codetracer_trace_writer::step_stream::pack_global_line_index(3, 42);
        let mut cache = MaterializationCache::new();
        let mut rec = FakeRecreator::new().with_line_hits(
            0,
            vec![
                (key, LineHitEntry { tick: 10 }),
                (key, LineHitEntry { tick: 25 }),
                (key, LineHitEntry { tick: 1000 }),
            ],
        );

        assert_eq!(
            cache.ensure_interval_materialized(&mut rec, 0, 100).unwrap(),
            EnsureOutcome::CacheMiss
        );
        assert_eq!(rec.calls, 1);
        assert_eq!(
            cache.line_hits_for_key_in_range(key, 0, 100).unwrap(),
            vec![10, 25],
            "line hits are clipped to the materialized interval"
        );
        assert_eq!(
            cache.line_hits_for_key_in_range(key, 100, 200),
            None,
            "uncovered ranges do not claim complete linehit knowledge"
        );

        let db: &dyn OmniscientDb = &cache;
        assert_eq!(db.source_line_hits(3, 42), vec![10, 25]);
        assert_eq!(db.source_line_hits(3, 43), Vec::<u64>::new());

        assert_eq!(
            cache.ensure_interval_materialized(&mut rec, 0, 100).unwrap(),
            EnsureOutcome::CacheHit
        );
        assert_eq!(rec.calls, 1, "covered linehit interval is not replayed again");

        let backing = Box::new(InMemoryBlockSource::new(std::fs::read(&path).unwrap()));
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();
        cache.persist(&mut overlay).unwrap();
        let mut sink = FileBlockSink::open(&path).unwrap();
        cache.flush(&mut overlay, &mut sink).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        let linehits_image = reader.read_file(CTFS_LINEHITS_FILE).unwrap();
        assert_eq!(&linehits_image[0..4], b"NSB1");
        let linehits = crate::ctfs_trace_reader::linehits_namespace::LinehitsNamespace::open(&linehits_image).unwrap();
        assert_eq!(linehits.hits(key).unwrap(), vec![10, 25]);
    }
}
