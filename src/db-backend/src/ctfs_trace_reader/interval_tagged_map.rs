//! M4 — interval_id-tagged partial omniscient maps + merge-on-read.
//!
//! ## What this is
//!
//! While a region is `sparse` (MCR-Omniscient-DB-Algorithms.md §2.4 / §1.3
//! invariant 8), the `memwrites.tc` / `linehits.tc` records carry the producing
//! **`interval_id`**, and per key the value is a **set of per-interval,
//! internally tick-sorted sub-lists**. Population may arrive out of tick order
//! (the user searches at tick 5000 — populating interval 5 — then jumps back to
//! 1000–2000) without a global re-sort: each interval's sub-list stays
//! independently complete and tick-sorted over its own range.
//!
//! A read **merges** the sub-lists for the intervals intersecting the query's
//! tick range into one tick-sorted answer (a bounded k-way merge over the
//! covering intervals). This is the M4 deliverables 2 + 3.
//!
//! ## Relationship to the rest of M4
//!
//! * [`super::coverage_namespace::CoverageMap`] says WHICH intervals are
//!   populated and distinguishes "covered, no hits" from "not analyzed".
//! * This module holds the actual per-interval record sub-lists and merges them.
//!
//! A caller's read path is: ask the coverage map whether the query range is
//! covered (else trigger population); if covered, merge-read the sub-lists for
//! the covering intervals here.
//!
//! ## Record types
//!
//! Two concrete record shapes are supported, matching the namespace schemas in
//! MCR-Omniscient-DB-Algorithms.md §1.2:
//!
//! * `memwrites.tc`: key = memory address (u64), record =
//!   `(tick, pc, size, old_value, new_value)` ([`MemWriteEntry`]).
//! * `linehits.tc`: key = global line index (u64), record = `tick`
//!   ([`LineHitEntry`]).
//!
//! Both implement [`TickTagged`] (a record that knows its tick), so the
//! per-interval sub-list machinery + merge-on-read are shared generically and
//! stay DRY.

use std::collections::BTreeMap;

/// A record that carries a tick — the sort key for per-interval sub-lists and
/// the merge key for merge-on-read.
pub trait TickTagged: Clone {
    /// The instruction-counter tick this record was produced at.
    fn tick(&self) -> u64;
}

/// A `memwrites.tc` record (§1.2): one memory write, keyed in the namespace by
/// its target address. Mirrors [`crate::omniscient_db::WriteRecord`] minus the
/// address (which is the namespace key).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MemWriteEntry {
    /// Instruction-counter tick of the write.
    pub tick: u64,
    /// Program counter of the writing instruction.
    pub pc: u64,
    /// Bytes written (1, 2, 4, 8, 16).
    pub size: u32,
    /// Value before the write.
    pub old_value: u64,
    /// Value after the write.
    pub new_value: u64,
}

impl TickTagged for MemWriteEntry {
    fn tick(&self) -> u64 {
        self.tick
    }
}

/// A `linehits.tc` record (§1.2): one source-line execution, keyed in the
/// namespace by the global line index. The record IS the tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LineHitEntry {
    /// Instruction-counter tick at which the line executed.
    pub tick: u64,
}

impl TickTagged for LineHitEntry {
    fn tick(&self) -> u64 {
        self.tick
    }
}

/// The per-interval sub-lists for ONE namespace key (§1.3 invariant 8).
///
/// Each `interval_id` maps to that interval's complete, tick-sorted sub-list of
/// records for the key. The union over a tick range's covering intervals is the
/// complete, tick-ordered record set for that range.
#[derive(Debug, Clone)]
struct KeyValue<R: TickTagged> {
    /// `interval_id → tick-sorted records produced by that interval`.
    sublists: BTreeMap<u32, Vec<R>>,
}

// A hand-written `Default` (rather than `#[derive]`) so `KeyValue<R>` is
// `Default` without requiring `R: Default` — the derive would add that bound,
// but an empty sub-list map needs no record value.
impl<R: TickTagged> Default for KeyValue<R> {
    fn default() -> Self {
        KeyValue {
            sublists: BTreeMap::new(),
        }
    }
}

impl<R: TickTagged> KeyValue<R> {
    fn append(&mut self, interval_id: u32, record: R) {
        let sub = self.sublists.entry(interval_id).or_default();
        // Keep the sub-list tick-sorted. Records within one interval arrive in
        // execution (tick) order, so the common case is a cheap push; a binary
        // insert keeps correctness if a caller appends out of order.
        match sub.binary_search_by_key(&record.tick(), |r| r.tick()) {
            Ok(pos) => sub[pos] = record, // same tick → replace (idempotent re-append)
            Err(pos) => sub.insert(pos, record),
        }
    }
}

/// An interval_id-tagged partial omniscient map (`memwrites.tc` or
/// `linehits.tc` while sparse).
///
/// Generic over the record type `R: TickTagged`, so memory writes and line hits
/// share the per-interval sub-list machinery and the merge-on-read.
#[derive(Debug, Clone)]
pub struct IntervalTaggedMap<R: TickTagged> {
    /// `namespace key → per-interval sub-lists`.
    keys: BTreeMap<u64, KeyValue<R>>,
}

// Hand-written `Default` so the map is constructible without `R: Default`.
impl<R: TickTagged> Default for IntervalTaggedMap<R> {
    fn default() -> Self {
        IntervalTaggedMap { keys: BTreeMap::new() }
    }
}

impl<R: TickTagged> IntervalTaggedMap<R> {
    /// An empty map.
    pub fn new() -> Self {
        IntervalTaggedMap { keys: BTreeMap::new() }
    }

    /// Append one record for `key`, tagged with the producing `interval_id`.
    ///
    /// The record joins that interval's sub-list for the key, kept tick-sorted.
    /// This is what the lazy-population loop calls for each analyzed record
    /// (§2.4 `append_tagged_records`).
    pub fn append(&mut self, key: u64, interval_id: u32, record: R) {
        self.keys.entry(key).or_default().append(interval_id, record);
    }

    /// The `interval_id`s that produced any record for `key` (for diagnostics /
    /// collapse).
    pub fn interval_ids_for(&self, key: u64) -> Vec<u32> {
        self.keys
            .get(&key)
            .map(|kv| kv.sublists.keys().copied().collect())
            .unwrap_or_default()
    }

    /// Merge-on-read (M4 deliverable 3): return the tick-sorted records for `key`
    /// drawn from the sub-lists of the intervals in `covering_intervals`, clipped
    /// to `[tick_lo, tick_hi)`.
    ///
    /// `covering_intervals` is the set of `interval_id`s the caller determined
    /// (via [`super::coverage_namespace::CoverageMap::intervals_intersecting`])
    /// intersect the query tick range. Only those sub-lists are merged, so an
    /// uncovered/unrelated interval's records never leak into the answer.
    ///
    /// The result is a single tick-sorted list — a bounded k-way merge over the
    /// covering sub-lists, each already tick-sorted (§1.3 invariant 8: their
    /// union is exactly the complete tick-ordered set for the range).
    pub fn merge_read(&self, key: u64, covering_intervals: &[u32], tick_lo: u64, tick_hi: u64) -> Vec<R> {
        let Some(kv) = self.keys.get(&key) else {
            return Vec::new();
        };
        // Gather the relevant sub-lists (each tick-sorted) and k-way merge.
        let mut cursors: Vec<(&[R], usize)> = Vec::new();
        for &iid in covering_intervals {
            if let Some(sub) = kv.sublists.get(&iid) {
                cursors.push((sub.as_slice(), 0));
            }
        }
        let mut out: Vec<R> = Vec::new();
        loop {
            // Pick the cursor whose next record has the smallest tick.
            let mut best: Option<usize> = None;
            let mut best_tick = u64::MAX;
            for (ci, (slice, pos)) in cursors.iter().enumerate() {
                if *pos < slice.len() {
                    let t = slice[*pos].tick();
                    if t < best_tick {
                        best_tick = t;
                        best = Some(ci);
                    }
                }
            }
            let Some(ci) = best else { break };
            let (slice, pos) = &mut cursors[ci];
            let rec = slice[*pos].clone();
            *pos += 1;
            // Clip to the query range [tick_lo, tick_hi).
            if rec.tick() >= tick_lo && rec.tick() < tick_hi {
                out.push(rec);
            }
        }
        out
    }

    /// Collapse (M5 building block): merge ALL the per-interval sub-lists for
    /// `key` into one flat tick-sorted array, dropping the `interval_id` tags.
    ///
    /// This is the per-key half of §2.4 "collapse-to-full": the caller drives it
    /// over every key once a region's intervals are contiguous, then drops the
    /// region's coverage rows in favour of one `collapsed_complete` row.
    pub fn collapse_key(&self, key: u64) -> Vec<R> {
        let Some(kv) = self.keys.get(&key) else {
            return Vec::new();
        };
        let all: Vec<u32> = kv.sublists.keys().copied().collect();
        self.merge_read(key, &all, u64::MIN, u64::MAX)
    }

    /// Every namespace key present in the map, ascending.
    pub fn keys(&self) -> Vec<u64> {
        self.keys.keys().copied().collect()
    }

    /// Whether the map has any records.
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::coverage_namespace::{CoverageMap, CoverageState};

    fn mw(tick: u64, new_value: u64) -> MemWriteEntry {
        MemWriteEntry {
            tick,
            pc: 0xDEAD,
            size: 8,
            old_value: 0,
            new_value,
        }
    }

    /// M4 — `test_interval_id_merge_on_read`: records from multiple intervals for
    /// one key merge into a single tick-sorted answer on read.
    #[test]
    fn test_interval_id_merge_on_read() {
        let mut map: IntervalTaggedMap<MemWriteEntry> = IntervalTaggedMap::new();
        const ADDR: u64 = 0x1000;

        // Interval 1 produced writes at ticks 1100, 1300 (in-order).
        map.append(ADDR, 1, mw(1100, 11));
        map.append(ADDR, 1, mw(1300, 13));
        // Interval 2 produced writes at ticks 2100, 2200.
        map.append(ADDR, 2, mw(2200, 22));
        map.append(ADDR, 2, mw(2100, 21)); // appended OUT of tick order on purpose
        // Interval 5 produced a write at tick 5500.
        map.append(ADDR, 5, mw(5500, 55));

        // Merge intervals 1 + 2 over [1000, 3000): ticks 1100,1300,2100,2200,
        // sorted, interval 5 excluded.
        let merged = map.merge_read(ADDR, &[1, 2], 1000, 3000);
        let ticks: Vec<u64> = merged.iter().map(|r| r.tick).collect();
        assert_eq!(ticks, vec![1100, 1300, 2100, 2200]);
        let values: Vec<u64> = merged.iter().map(|r| r.new_value).collect();
        assert_eq!(values, vec![11, 13, 21, 22]);

        // A narrower clip picks only the in-range records, still sorted.
        let clipped = map.merge_read(ADDR, &[1, 2, 5], 1300, 5501);
        let ticks: Vec<u64> = clipped.iter().map(|r| r.tick).collect();
        assert_eq!(ticks, vec![1300, 2100, 2200, 5500]);

        // Collapse merges every interval's sub-list into one flat sorted array.
        let flat = map.collapse_key(ADDR);
        let ticks: Vec<u64> = flat.iter().map(|r| r.tick).collect();
        assert_eq!(ticks, vec![1100, 1300, 2100, 2200, 5500]);
    }

    /// M4 — `test_out_of_order_interval_population`: populating interval
    /// [5000,6000) BEFORE [1000,2000) yields correct merged results and coverage.
    ///
    /// Exercises the full M4 surface together: the coverage map records the
    /// out-of-order intervals, the tagged map holds their sub-lists, and a query
    /// spanning both merges correctly while an uncovered gap is reported.
    #[test]
    fn test_out_of_order_interval_population() {
        let mut cov = CoverageMap::new();
        let mut map: IntervalTaggedMap<LineHitEntry> = IntervalTaggedMap::new();
        const LINE: u64 = 42;

        // Interval 5 ([5000,6000)) is populated FIRST.
        map.append(LINE, 5, LineHitEntry { tick: 5100 });
        map.append(LINE, 5, LineHitEntry { tick: 5900 });
        cov.coverage_add(5000, 6000, CoverageState::Sparse).expect("cover 5");

        // THEN interval 1 ([1000,2000)).
        map.append(LINE, 1, LineHitEntry { tick: 1900 });
        map.append(LINE, 1, LineHitEntry { tick: 1100 }); // out-of-order append
        cov.coverage_add(1000, 2000, CoverageState::Sparse).expect("cover 1");

        // Coverage rows are stored in sorted (tick_lo) order regardless of the
        // population order.
        let los: Vec<u64> = cov.rows().iter().map(|r| r.tick_lo).collect();
        assert_eq!(los, vec![1000, 5000]);

        // A query spanning BOTH populated intervals: the covering intervals are
        // determined from coverage, then merge-read yields one tick-sorted answer
        // across the out-of-order populations.
        let covering: Vec<u32> = cov
            .intervals_intersecting(1000, 6000)
            .iter()
            .map(|r| (r.tick_lo / 1000) as u32)
            .collect();
        assert_eq!(covering, vec![1, 5]);
        let merged = map.merge_read(LINE, &covering, 1000, 6000);
        let ticks: Vec<u64> = merged.iter().map(|r| r.tick).collect();
        assert_eq!(ticks, vec![1100, 1900, 5100, 5900]);

        // The gap between the two populated intervals is correctly reported as
        // NOT covered — distinguishing "unknown" from "covered, empty".
        use super::super::coverage_namespace::Coverage;
        assert_eq!(
            cov.coverage_of(1000, 6000),
            Coverage::NotCovered {
                missing: vec![(2000, 5000)]
            }
        );

        // But each populated interval, queried alone, is covered.
        assert!(matches!(
            cov.coverage_of(1000, 2000),
            super::super::coverage_namespace::Coverage::Covered { .. }
        ));
        assert!(matches!(
            cov.coverage_of(5000, 6000),
            super::super::coverage_namespace::Coverage::Covered { .. }
        ));
    }

    #[test]
    fn merge_excludes_unrelated_intervals() {
        let mut map: IntervalTaggedMap<MemWriteEntry> = IntervalTaggedMap::new();
        map.append(0x10, 1, mw(100, 1));
        map.append(0x10, 9, mw(9000, 9)); // far-away interval

        // Merging only interval 1 must NOT include interval 9's record, even
        // though the tick clip would otherwise admit it.
        let merged = map.merge_read(0x10, &[1], 0, u64::MAX);
        let ticks: Vec<u64> = merged.iter().map(|r| r.tick).collect();
        assert_eq!(ticks, vec![100]);
    }

    #[test]
    fn missing_key_merges_to_empty() {
        let map: IntervalTaggedMap<LineHitEntry> = IntervalTaggedMap::new();
        assert!(map.merge_read(999, &[1, 2, 3], 0, u64::MAX).is_empty());
    }
}
