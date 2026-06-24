//! M5 — collapse-to-full (compaction) of a contiguous covered region.
//!
//! ## What this is
//!
//! MCR-Omniscient-DB-Algorithms.md §2.4 "Collapse-to-full": when a region's
//! covered intervals become **contiguous** and span a slice (or the whole trace),
//! the engine compacts that region:
//!
//! 1. Merge the per-`interval_id` sub-lists into **one flat tick-sorted array per
//!    key** ([`super::interval_tagged_map::IntervalTaggedMap::collapse_key`]).
//! 2. Drop the `interval_id` tags — the collapsed map is keyed by namespace key
//!    only, no per-interval binning.
//! 3. Drop the region's many `sparse` `coverage.tc` rows and replace them with a
//!    single `collapsed_complete` row for the spanned range.
//!
//! ## The byte-identity invariant (the crux)
//!
//! The collapsed output **must be byte-identical** to server-side per-slice prep
//! (Omniscient-DB-Server-Side-Prep.md §6.2 slice-summary → §6.3 coordinator
//! reduce). That is what makes a locally lazy-populated, collapsed slice and a
//! server-prepped slice **interchangeable** (§6.7.3). The flat per-key arrays are
//! therefore emitted through [`super::server_prep_encoding`], which ports the
//! authoritative `WLOG` (`memwrites.tc`) and `LHTS|v1` (`linehits.tc`) byte
//! layouts. The §6.3 reduce sorts `global_writes` by `(address, tick)`; this
//! collapse emits the same order by iterating namespace keys ascending (the
//! `IntervalTaggedMap` is a `BTreeMap`) and each key's collapsed list tick-sorted.

use super::coverage_namespace::{Coverage, CoverageError, CoverageMap, CoverageState};
use super::interval_tagged_map::{IntervalTaggedMap, LineHitEntry, MemWriteEntry};
use super::server_prep_encoding::{
    CollapsedLinehits, CollapsedMemwrites, collapsed_linehits_from_entries, encode_linehits, encode_memwrites,
};

/// Errors raised while collapsing a region.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CollapseError {
    /// The region `[tick_lo, tick_hi)` is not fully covered by `coverage.tc`, so
    /// it cannot be collapsed (collapse requires a contiguous covered span —
    /// §2.4). Carries the still-uncovered sub-ranges.
    NotContiguous {
        /// The maximal `[lo, hi)` sub-ranges of the region that are NOT covered.
        missing: Vec<(u64, u64)>,
    },
    /// An empty/inverted region (`tick_hi <= tick_lo`).
    EmptyRegion {
        /// The offending lower bound.
        tick_lo: u64,
        /// The offending upper bound.
        tick_hi: u64,
    },
    /// A coverage-map error while rewriting the rows for the collapsed range.
    Coverage(CoverageError),
}

impl std::fmt::Display for CollapseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CollapseError::NotContiguous { missing } => {
                write!(f, "region not contiguous; missing {missing:?}")
            }
            CollapseError::EmptyRegion { tick_lo, tick_hi } => {
                write!(f, "empty/inverted collapse region [{tick_lo}, {tick_hi})")
            }
            CollapseError::Coverage(e) => write!(f, "collapse coverage update: {e}"),
        }
    }
}

impl std::error::Error for CollapseError {}

impl From<CoverageError> for CollapseError {
    fn from(e: CoverageError) -> Self {
        CollapseError::Coverage(e)
    }
}

/// The byte-image output of collapsing a region: the flat `memwrites.tc` /
/// `linehits.tc` images, byte-identical to server-side per-slice prep.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollapsedRegion {
    /// The collapsed `memwrites.tc` image (`WLOG` bytes), or `None` if the
    /// memwrites map was empty for the region.
    pub memwrites: Option<Vec<u8>>,
    /// The collapsed `linehits.tc` image (`LHTS|v1` bytes), or `None` if the
    /// linehits map was empty for the region.
    pub linehits: Option<Vec<u8>>,
}

/// The set of `interval_id`s spanned by a contiguous covered region — the
/// granularity at which the tagged maps are binned. Derived from `K` (the
/// interval size) so the collapse knows which sub-lists to merge.
fn region_interval_ids(tick_lo: u64, tick_hi: u64, interval_size: u64) -> Vec<u32> {
    if interval_size == 0 || tick_hi <= tick_lo {
        return Vec::new();
    }
    let lo = tick_lo / interval_size;
    // The last interval that intersects [tick_lo, tick_hi): the interval owning
    // (tick_hi - 1).
    let hi = (tick_hi - 1) / interval_size;
    (lo..=hi).map(|i| i as u32).collect()
}

/// Flatten the `memwrites.tc` tagged map over the region's covering intervals
/// into per-address tick-sorted arrays (ascending by address, the namespace key /
/// §6.3 reduce sort key), then encode to the authoritative `WLOG` layout.
///
/// Returns `None` when the map has no records for the region.
pub fn collapse_memwrites(
    map: &IntervalTaggedMap<MemWriteEntry>,
    tick_lo: u64,
    tick_hi: u64,
    interval_size: u64,
) -> Option<Vec<u8>> {
    let covering = region_interval_ids(tick_lo, tick_hi, interval_size);
    let mut per_address: Vec<(u64, Vec<MemWriteEntry>)> = Vec::new();
    // `keys()` is ascending (BTreeMap), giving address-major order.
    for key in map.keys() {
        // Merge only this region's covering intervals' sub-lists, clipped to the
        // region — an interval outside the region never leaks in.
        let writes = map.merge_read(key, &covering, tick_lo, tick_hi);
        if !writes.is_empty() {
            per_address.push((key, writes));
        }
    }
    if per_address.is_empty() {
        return None;
    }
    Some(encode_memwrites(&CollapsedMemwrites { per_address }))
}

/// Flatten the `linehits.tc` tagged map over the region into per-line tick-sorted
/// arrays (ascending by namespace key) and encode to the authoritative `LHTS|v1`
/// layout.
///
/// The `linehits.tc` namespace key is the **global line index**; `key_to_line`
/// maps it back to the `(file_id, line)` pair the on-disk format stores. (The
/// global line index is `file_id`-major in the recorder's interning, so the
/// ascending key order already yields ascending `(file_id, line)`.)
///
/// Returns `None` when the map has no records for the region.
pub fn collapse_linehits<F>(
    map: &IntervalTaggedMap<LineHitEntry>,
    tick_lo: u64,
    tick_hi: u64,
    interval_size: u64,
    key_to_line: F,
) -> Option<Vec<u8>>
where
    F: Fn(u64) -> (u32, u32),
{
    let covering = region_interval_ids(tick_lo, tick_hi, interval_size);
    let mut per_line: Vec<(u32, u32, Vec<LineHitEntry>)> = Vec::new();
    for key in map.keys() {
        let hits = map.merge_read(key, &covering, tick_lo, tick_hi);
        if !hits.is_empty() {
            let (file_id, line) = key_to_line(key);
            per_line.push((file_id, line, hits));
        }
    }
    if per_line.is_empty() {
        return None;
    }
    let collapsed: CollapsedLinehits = collapsed_linehits_from_entries(per_line);
    Some(encode_linehits(&collapsed))
}

/// Collapse a contiguous covered region into flat, byte-identical-to-server-prep
/// maps and rewrite `coverage.tc` for the range.
///
/// Preconditions (§2.4): `[tick_lo, tick_hi)` must be **fully covered** by
/// `coverage.tc` (else [`CollapseError::NotContiguous`]). On success:
///
/// - Returns the flat `memwrites.tc` / `linehits.tc` byte images.
/// - **Drops** every coverage row strictly inside `[tick_lo, tick_hi)` and
///   replaces the whole span with a single `collapsed_complete` row, so the
///   region's `coverage.tc` rows carry the post-collapse state (deliverable 1 /
///   `test_collapse_drops_interval_tags`).
///
/// The caller then persists the returned images + the rewritten `coverage.tc`
/// through the M2 overlay (persist mode) — see
/// [`super::lazy_population_store::LazyPopulationStore`].
#[allow(clippy::too_many_arguments)]
pub fn collapse_region<F>(
    coverage: &mut CoverageMap,
    memwrites: &IntervalTaggedMap<MemWriteEntry>,
    linehits: &IntervalTaggedMap<LineHitEntry>,
    tick_lo: u64,
    tick_hi: u64,
    interval_size: u64,
    key_to_line: F,
) -> Result<CollapsedRegion, CollapseError>
where
    F: Fn(u64) -> (u32, u32),
{
    if tick_hi <= tick_lo {
        return Err(CollapseError::EmptyRegion { tick_lo, tick_hi });
    }
    // The region must be fully covered — collapse is only legal over a contiguous
    // covered span (§2.4).
    match coverage.coverage_of(tick_lo, tick_hi) {
        Coverage::Covered { .. } => {}
        Coverage::NotCovered { missing } => return Err(CollapseError::NotContiguous { missing }),
    }

    let mem_image = collapse_memwrites(memwrites, tick_lo, tick_hi, interval_size);
    let line_image = collapse_linehits(linehits, tick_lo, tick_hi, interval_size, key_to_line);

    // Rewrite coverage: drop every row inside the span, then add one collapsed
    // row. The rows are disjoint and (given full coverage) tile [tick_lo,
    // tick_hi) exactly, so every row with tick_lo <= row_lo < tick_hi lies inside
    // the span and is removed; the gap is then filled by the single collapsed row.
    coverage.coverage_remove_range(tick_lo, tick_hi)?;
    debug_assert!(
        coverage
            .rows()
            .iter()
            .all(|r| r.tick_lo < tick_lo || r.tick_lo >= tick_hi),
        "collapse must have dropped all in-span rows"
    );
    coverage.coverage_add(tick_lo, tick_hi, CoverageState::CollapsedComplete)?;

    Ok(CollapsedRegion {
        memwrites: mem_image,
        linehits: line_image,
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::server_prep_encoding::{decode_linehits, decode_memwrites};

    const K: u64 = 1000;

    fn mw(tick: u64, new_value: u64) -> MemWriteEntry {
        MemWriteEntry {
            tick,
            pc: 0xDEAD,
            size: 8,
            old_value: 0,
            new_value,
        }
    }

    /// Build a two-interval, fully-covered region whose collapse output we assert.
    fn populate_two_intervals() -> (CoverageMap, IntervalTaggedMap<MemWriteEntry>) {
        let mut cov = CoverageMap::new();
        let mut map: IntervalTaggedMap<MemWriteEntry> = IntervalTaggedMap::new();
        const ADDR: u64 = 0x4000;

        // Interval 0 [0,1000): writes at 100, 300.
        map.append(ADDR, 0, mw(100, 1));
        map.append(ADDR, 0, mw(300, 2));
        cov.coverage_add(0, 1000, CoverageState::Sparse).unwrap();
        // Interval 1 [1000,2000): writes at 1100, 1900 (appended out of order).
        map.append(ADDR, 1, mw(1900, 4));
        map.append(ADDR, 1, mw(1100, 3));
        cov.coverage_add(1000, 2000, CoverageState::Sparse).unwrap();
        (cov, map)
    }

    /// `test_collapse_byte_identical_to_server_prep` — a fully-populated region
    /// collapses to bytes IDENTICAL to the server-side per-slice prep output for
    /// the same range. The "server-prep output" reference is built by sorting the
    /// region's writes by `(address, tick)` and running the authoritative
    /// `encode_memwrites` (Omniscient-DB-Server-Side-Prep.md §6.3) — NOT by a
    /// second call of the collapse path. Byte equality of the two is the §6.7.3
    /// interchangeability invariant.
    #[test]
    fn test_collapse_byte_identical_to_server_prep() {
        let (mut cov, map) = populate_two_intervals();
        let empty_lines: IntervalTaggedMap<LineHitEntry> = IntervalTaggedMap::new();

        let collapsed = collapse_region(&mut cov, &map, &empty_lines, 0, 2000, K, |k| (k as u32, 0)).unwrap();
        let got = collapsed.memwrites.expect("memwrites image");

        // Independent server-prep reference: emulate §6.3 reduce — gather ALL the
        // region's writes, sort by (address, tick), encode. (Single address here,
        // so the (address, tick) order is just tick order across both intervals.)
        const ADDR: u64 = 0x4000;
        let mut all = vec![mw(100, 1), mw(300, 2), mw(1100, 3), mw(1900, 4)];
        all.sort_by_key(|w| (ADDR, w.tick));
        let reference = encode_memwrites(&CollapsedMemwrites {
            per_address: vec![(ADDR, all)],
        });

        assert_eq!(
            got, reference,
            "collapsed memwrites must be byte-identical to server prep"
        );

        // And it decodes back to the merged, tick-sorted writes (no interval tags).
        let decoded = decode_memwrites(&got).unwrap();
        let ticks: Vec<u64> = decoded.iter().map(|(_, w)| w.tick).collect();
        assert_eq!(ticks, vec![100, 300, 1100, 1900]);
    }

    /// Multi-address collapse emits records in (address, tick) order — the §6.3
    /// reduce sort — across several namespace keys.
    #[test]
    fn collapse_multi_address_orders_by_address_then_tick() {
        let mut cov = CoverageMap::new();
        let mut map: IntervalTaggedMap<MemWriteEntry> = IntervalTaggedMap::new();
        // Two addresses, populated across two intervals, appended scrambled.
        map.append(0x9000, 1, mw(1500, 0));
        map.append(0x1000, 0, mw(200, 0));
        map.append(0x9000, 0, mw(50, 0));
        map.append(0x1000, 1, mw(1700, 0));
        cov.coverage_add(0, 1000, CoverageState::Sparse).unwrap();
        cov.coverage_add(1000, 2000, CoverageState::Sparse).unwrap();
        let empty_lines: IntervalTaggedMap<LineHitEntry> = IntervalTaggedMap::new();

        let collapsed = collapse_region(&mut cov, &map, &empty_lines, 0, 2000, K, |k| (k as u32, 0)).unwrap();
        let decoded = decode_memwrites(&collapsed.memwrites.unwrap()).unwrap();
        let keyed: Vec<(u64, u64)> = decoded.iter().map(|(a, w)| (*a, w.tick)).collect();
        // 0x1000 (ascending) before 0x9000, each tick-sorted.
        assert_eq!(keyed, vec![(0x1000, 200), (0x1000, 1700), (0x9000, 50), (0x9000, 1500)]);
    }

    /// `test_collapse_drops_interval_tags` — after collapse, the region's coverage
    /// rows are replaced by a single `collapsed_complete` row (interval-granular
    /// sparse rows removed), and the flat image carries no per-interval binning.
    #[test]
    fn test_collapse_drops_interval_tags() {
        let (mut cov, map) = populate_two_intervals();
        let empty_lines: IntervalTaggedMap<LineHitEntry> = IntervalTaggedMap::new();

        // Before: two sparse rows.
        let rows_before = cov.rows();
        assert_eq!(rows_before.len(), 2);
        assert!(rows_before.iter().all(|r| r.state == CoverageState::Sparse));

        collapse_region(&mut cov, &map, &empty_lines, 0, 2000, K, |k| (k as u32, 0)).unwrap();

        // After: one collapsed_complete row spanning the whole region.
        let rows_after = cov.rows();
        assert_eq!(rows_after.len(), 1, "the two sparse rows collapse to one");
        assert_eq!(rows_after[0].tick_lo, 0);
        assert_eq!(rows_after[0].tick_hi, 2000);
        assert_eq!(rows_after[0].state, CoverageState::CollapsedComplete);

        // The region now reports as fully collapsed.
        assert_eq!(cov.coverage_of(0, 2000), Coverage::Covered { all_collapsed: true });
    }

    /// Collapsing a region that is not fully covered is rejected (it isn't a
    /// contiguous covered span yet).
    #[test]
    fn collapse_rejects_non_contiguous_region() {
        let mut cov = CoverageMap::new();
        let map: IntervalTaggedMap<MemWriteEntry> = IntervalTaggedMap::new();
        let lines: IntervalTaggedMap<LineHitEntry> = IntervalTaggedMap::new();
        cov.coverage_add(0, 1000, CoverageState::Sparse).unwrap();
        // [1000, 2000) is NOT covered — there's a hole.
        let err = collapse_region(&mut cov, &map, &lines, 0, 2000, K, |k| (k as u32, 0)).unwrap_err();
        assert!(matches!(err, CollapseError::NotContiguous { .. }));
    }

    /// Linehits collapse produces the authoritative LHTS layout over the region.
    #[test]
    fn collapse_linehits_round_trips() {
        let mut cov = CoverageMap::new();
        let mem: IntervalTaggedMap<MemWriteEntry> = IntervalTaggedMap::new();
        let mut lines: IntervalTaggedMap<LineHitEntry> = IntervalTaggedMap::new();
        // global line index 42 hit in both intervals.
        lines.append(42, 0, LineHitEntry { tick: 300 });
        lines.append(42, 1, LineHitEntry { tick: 1300 });
        cov.coverage_add(0, 1000, CoverageState::Sparse).unwrap();
        cov.coverage_add(1000, 2000, CoverageState::Sparse).unwrap();

        let collapsed = collapse_region(&mut cov, &mem, &lines, 0, 2000, K, |k| ((k >> 16) as u32, k as u32)).unwrap();
        let image = collapsed.linehits.expect("linehits image");
        let decoded = decode_linehits(&image).unwrap();
        assert_eq!(decoded.len(), 1);
        let (file_id, line, ticks) = &decoded[0];
        assert_eq!((*file_id, *line), (0, 42));
        assert_eq!(ticks, &vec![300, 1300]);
    }
}
