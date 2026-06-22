//! M5 — persisted lazy population + warm restart, over the M2 overlay.
//!
//! ## What this is
//!
//! The lazy-population engine (MCR-Omniscient-DB-Algorithms.md §2.4) builds the
//! omniscient maps (`memwrites.tc` / `linehits.tc`) one interval at a time and
//! tracks which intervals are populated in `coverage.tc`. This module is the
//! **persistence + warm-restart** layer for that state, sitting on the M4 data
//! model ([`CoverageMap`], [`IntervalTaggedMap`]) and the M2 copy-on-write block
//! overlay ([`CtfsBlockOverlay`]):
//!
//! - **Persist via overlay** (deliverable 2): [`LazyPopulationStore::persist`]
//!   writes `coverage.tc` (+ the sparse or collapsed maps) into a
//!   [`CtfsBlockOverlay`]. In `Persist` mode a [`flush`](CtfsBlockOverlay::flush)
//!   makes them durable in the `.ct`; in `InMemory` mode the backing is left
//!   byte-unchanged (read-only-media / non-expanding sessions, §2.4
//!   "Persistence + crash safety").
//! - **Warm restart** (deliverable 3 / `e2e_warm_restart_reuses_coverage`):
//!   [`LazyPopulationStore::load_coverage_from_container`] reopens a `.ct` that
//!   already carries a persisted `coverage.tc` and reloads it as covered, so a
//!   reader recognises covered intervals and serves them from the maps WITHOUT
//!   re-deriving them. (Re-derivation of *uncovered* intervals — replay-driven
//!   population — is M6's concern; M5 demonstrates warm restart at the data
//!   level: persisted coverage + maps reload as covered and queryable.)
//!
//! ## Scope (honesty note)
//!
//! This module persists and reloads the coverage + map **state** through the
//! overlay and proves a covered interval is served from the reloaded maps while
//! an uncovered one is reported `NotCovered`. Wiring this into the live
//! production replay loop (the recreator that *fills* uncovered intervals by
//! replaying) is M6 — see the milestone Outstanding Tasks. The pieces here are
//! complete and tested in isolation on the M2/M4 structures.

use super::block_overlay::{BlockSink, CtfsBlockOverlay};
use super::coverage_namespace::{Coverage, CoverageError, CoverageMap};
use super::ctfs_container::{CtfsError, CtfsReader};
use super::interval_tagged_map::{IntervalTaggedMap, MemWriteEntry};
use super::server_prep_encoding::{decode_linehits, decode_memwrites};

/// The CTFS internal-file name for a collapsed/sparse memory-write map image.
pub const CTFS_MEMWRITES_FILE: &str = "memwrites.tc";
/// The CTFS internal-file name for a collapsed/sparse line-hit map image.
pub const CTFS_LINEHITS_FILE: &str = "linehits.tc";

/// Errors surfaced while persisting / reloading lazy-population state.
#[derive(Debug)]
pub enum StoreError {
    /// A coverage-namespace error.
    Coverage(CoverageError),
    /// A container/overlay I/O error.
    Container(CtfsError),
    /// A map image failed to decode on reload.
    Decode(String),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StoreError::Coverage(e) => write!(f, "lazy store coverage: {e}"),
            StoreError::Container(e) => write!(f, "lazy store container: {e}"),
            StoreError::Decode(e) => write!(f, "lazy store decode: {e}"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<CoverageError> for StoreError {
    fn from(e: CoverageError) -> Self {
        StoreError::Coverage(e)
    }
}
impl From<CtfsError> for StoreError {
    fn from(e: CtfsError) -> Self {
        StoreError::Container(e)
    }
}

/// Persist `coverage.tc` and the supplied map images into `overlay`.
///
/// Writes the `coverage.tc` namespace image (always), and the `memwrites.tc` /
/// `linehits.tc` images when present, as internal CTFS files through the
/// copy-on-write overlay. Nothing is written to the backing file here — the
/// caller flushes the overlay (in `Persist` mode) to make the writes durable, or
/// drops it (in `InMemory` mode) to discard them.
///
/// `memwrites_image` / `linehits_image` are the byte images the caller produced —
/// either the sparse per-interval encoding or the M5 collapsed (server-prep
/// byte-identical) encoding; this layer is agnostic to which.
pub fn persist_into_overlay(
    overlay: &mut CtfsBlockOverlay,
    coverage: &CoverageMap,
    memwrites_image: Option<&[u8]>,
    linehits_image: Option<&[u8]>,
) -> Result<(), StoreError> {
    overlay.write_internal_file(super::coverage_namespace::CTFS_COVERAGE_FILE, &coverage.serialize())?;
    if let Some(image) = memwrites_image {
        overlay.write_internal_file(CTFS_MEMWRITES_FILE, image)?;
    }
    if let Some(image) = linehits_image {
        overlay.write_internal_file(CTFS_LINEHITS_FILE, image)?;
    }
    Ok(())
}

/// Flush a `Persist`-mode overlay's staged blocks through `sink` (durably
/// publishing the persisted namespaces). A thin pass-through kept here so callers
/// of this module do not need to reach into the overlay's flush directly.
pub fn flush_overlay(overlay: &mut CtfsBlockOverlay, sink: &mut dyn BlockSink) -> Result<(), StoreError> {
    overlay.flush(sink)?;
    Ok(())
}

/// Reload the `coverage.tc` namespace from a container (the warm-restart entry
/// point). Returns an empty [`CoverageMap`] when the container has no
/// `coverage.tc` (a cold trace).
pub fn load_coverage_from_container(reader: &mut CtfsReader) -> Result<CoverageMap, StoreError> {
    if !reader.has_file(super::coverage_namespace::CTFS_COVERAGE_FILE) {
        return Ok(CoverageMap::new());
    }
    let image = reader.read_file(super::coverage_namespace::CTFS_COVERAGE_FILE)?;
    Ok(CoverageMap::load(&image)?)
}

/// Reload the collapsed `memwrites.tc` image from a container into per-address
/// write lists. Returns an empty vector when the file is absent.
pub fn load_memwrites_from_container(reader: &mut CtfsReader) -> Result<Vec<(u64, MemWriteEntry)>, StoreError> {
    if !reader.has_file(CTFS_MEMWRITES_FILE) {
        return Ok(Vec::new());
    }
    let image = reader.read_file(CTFS_MEMWRITES_FILE)?;
    decode_memwrites(&image).map_err(StoreError::Decode)
}

/// Reload the collapsed `linehits.tc` image from a container into per-line tick
/// lists. Returns an empty vector when the file is absent.
pub fn load_linehits_from_container(reader: &mut CtfsReader) -> Result<Vec<(u32, u32, Vec<u64>)>, StoreError> {
    if !reader.has_file(CTFS_LINEHITS_FILE) {
        return Ok(Vec::new());
    }
    let image = reader.read_file(CTFS_LINEHITS_FILE)?;
    decode_linehits(&image).map_err(StoreError::Decode)
}

/// A warm-restart query surface over reloaded coverage + collapsed maps.
///
/// After a warm restart, a query for a tick range first consults `coverage.tc`:
/// a covered interval is served from the reloaded maps (no re-derivation); an
/// uncovered interval is reported [`Coverage::NotCovered`] so the caller knows it
/// must trigger population (M6). This is the data-level warm-restart behaviour the
/// `e2e_warm_restart_reuses_coverage` test asserts.
pub struct WarmRestartReader {
    coverage: CoverageMap,
    /// Reloaded `memwrites.tc`: `address → tick-sorted writes` (collapsed image).
    memwrites: std::collections::BTreeMap<u64, Vec<MemWriteEntry>>,
}

impl WarmRestartReader {
    /// Build a warm-restart reader by reloading `coverage.tc` + `memwrites.tc`
    /// from a freshly-opened container.
    pub fn open(reader: &mut CtfsReader) -> Result<Self, StoreError> {
        let coverage = load_coverage_from_container(reader)?;
        let mut memwrites: std::collections::BTreeMap<u64, Vec<MemWriteEntry>> = std::collections::BTreeMap::new();
        for (address, entry) in load_memwrites_from_container(reader)? {
            memwrites.entry(address).or_default().push(entry);
        }
        // The collapsed image is already (address, tick)-ordered, so each
        // per-address list is tick-sorted; keep that guarantee defensively.
        for list in memwrites.values_mut() {
            list.sort_by_key(|w| w.tick);
        }
        Ok(WarmRestartReader { coverage, memwrites })
    }

    /// The reloaded coverage map.
    pub fn coverage(&self) -> &CoverageMap {
        &self.coverage
    }

    /// Classify a query tick range against the reloaded coverage.
    pub fn coverage_of(&self, tick_lo: u64, tick_hi: u64) -> Coverage {
        self.coverage.coverage_of(tick_lo, tick_hi)
    }

    /// Serve writes to `address` in `[tick_lo, tick_hi)` from the reloaded maps —
    /// but ONLY when the range is covered. Returns:
    ///
    /// - `Ok(Some(writes))` when the range is covered (the writes, possibly empty
    ///   for a genuine "covered, no writes"); served from the maps with no
    ///   re-derivation.
    /// - `Ok(None)` when the range is NOT covered (the caller must trigger
    ///   population — M6); the absence of records is *unknown*, not *empty*.
    pub fn writes_in_range(
        &self,
        address: u64,
        tick_lo: u64,
        tick_hi: u64,
    ) -> Result<Option<Vec<MemWriteEntry>>, StoreError> {
        match self.coverage.coverage_of(tick_lo, tick_hi) {
            Coverage::NotCovered { .. } => Ok(None),
            Coverage::Covered { .. } => {
                let writes = self
                    .memwrites
                    .get(&address)
                    .map(|list| {
                        list.iter()
                            .filter(|w| w.tick >= tick_lo && w.tick < tick_hi)
                            .cloned()
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                Ok(Some(writes))
            }
        }
    }
}

/// Convenience: a fresh sparse `memwrites.tc` map encoded for one interval, used
/// by the persist tests. The interval's per-key writes are flattened (a single
/// interval is already its own complete tick-sorted sub-list) and encoded through
/// the authoritative server-prep layout — so even a sparse single-interval
/// persist is forward-compatible with a server-prepped slice for that range.
pub fn encode_single_interval_memwrites(
    map: &IntervalTaggedMap<MemWriteEntry>,
    interval_id: u32,
    tick_lo: u64,
    tick_hi: u64,
) -> Option<Vec<u8>> {
    use super::server_prep_encoding::{encode_memwrites, CollapsedMemwrites};
    let mut per_address: Vec<(u64, Vec<MemWriteEntry>)> = Vec::new();
    for key in map.keys() {
        let writes = map.merge_read(key, &[interval_id], tick_lo, tick_hi);
        if !writes.is_empty() {
            per_address.push((key, writes));
        }
    }
    if per_address.is_empty() {
        return None;
    }
    Some(encode_memwrites(&CollapsedMemwrites { per_address }))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::block_overlay::{FileBlockSink, NoOpBlockSink, OverlayMode};
    use crate::ctfs_trace_reader::collapse::collapse_region;
    use crate::ctfs_trace_reader::coverage_namespace::CoverageState;
    use crate::ctfs_trace_reader::ctfs_container::{write_minimal_ctfs, InMemoryBlockSource, LocalFileSource};
    use crate::ctfs_trace_reader::interval_tagged_map::LineHitEntry;

    const K: u64 = 1000;
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

    /// Build a minimal `.ct` with a single tiny stub file so the overlay has a
    /// valid container to layer over (the namespaces are added through the
    /// overlay, not the initial writer).
    fn make_base_ct(path: &std::path::Path) {
        write_minimal_ctfs(path, &[("stub.dat", &[1u8, 2, 3, 4])]).unwrap();
    }

    /// Populate one fully-covered, collapsed region and persist it through an
    /// overlay over `path`'s backing, returning the collapsed memwrites image.
    fn populate_and_collapse() -> (CoverageMap, Vec<u8>) {
        let mut cov = CoverageMap::new();
        let mut map: IntervalTaggedMap<MemWriteEntry> = IntervalTaggedMap::new();
        let lines: IntervalTaggedMap<LineHitEntry> = IntervalTaggedMap::new();
        map.append(ADDR, 0, mw(100, 1));
        map.append(ADDR, 1, mw(1100, 2));
        cov.coverage_add(0, 1000, CoverageState::Sparse).unwrap();
        cov.coverage_add(1000, 2000, CoverageState::Sparse).unwrap();
        let collapsed = collapse_region(&mut cov, &map, &lines, 0, 2000, K, |k| (k as u32, 0)).unwrap();
        (cov, collapsed.memwrites.unwrap())
    }

    /// `test_lazy_population_persisted_via_overlay` — maps + coverage written
    /// through the overlay in Persist mode reload (reopen backing, no overlay) as
    /// covered; in InMemory mode the backing is byte-unchanged.
    #[test]
    fn test_lazy_population_persisted_via_overlay() {
        // ── Persist mode: durable, reloads as covered ────────────────────────
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("persist.ct");
        make_base_ct(&path);

        let (cov, mem_image) = populate_and_collapse();

        let backing = Box::new(InMemoryBlockSource::new(std::fs::read(&path).unwrap()));
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();
        persist_into_overlay(&mut overlay, &cov, Some(&mem_image), None).unwrap();
        let mut sink = FileBlockSink::open(&path).unwrap();
        flush_overlay(&mut overlay, &mut sink).unwrap();

        // Reopen the backing with NO overlay; the namespaces are durable.
        let mut reader = CtfsReader::open(&path).unwrap();
        assert!(reader.has_file("coverage.tc"), "coverage.tc persisted");
        assert!(reader.has_file("memwrites.tc"), "memwrites.tc persisted");
        let reloaded_cov = load_coverage_from_container(&mut reader).unwrap();
        // The collapsed region reloads as covered + collapsed.
        assert_eq!(reloaded_cov.coverage_of(0, 2000), Coverage::Covered { all_collapsed: true });
        let reloaded_writes = load_memwrites_from_container(&mut reader).unwrap();
        let ticks: Vec<u64> = reloaded_writes.iter().map(|(_, w)| w.tick).collect();
        assert_eq!(ticks, vec![100, 1100]);

        // ── InMemory mode: backing byte-unchanged ────────────────────────────
        let dir2 = tempfile::tempdir().unwrap();
        let path2 = dir2.path().join("inmem.ct");
        make_base_ct(&path2);
        let raw_before = std::fs::read(&path2).unwrap();

        let backing2 = Box::new(LocalFileSource::open(&path2).unwrap());
        let mut overlay2 = CtfsBlockOverlay::new(backing2, OverlayMode::InMemory).unwrap();
        persist_into_overlay(&mut overlay2, &cov, Some(&mem_image), None).unwrap();
        // Staged in the overlay, readable there…
        assert!(overlay2.has_file("coverage.tc").unwrap(), "staged in overlay");
        // …but a flush is a no-op and the backing is byte-for-byte unchanged.
        let mut noop = NoOpBlockSink;
        flush_overlay(&mut overlay2, &mut noop).unwrap();
        drop(overlay2);
        let raw_after = std::fs::read(&path2).unwrap();
        assert_eq!(raw_after, raw_before, "InMemory mode leaves backing unchanged");
        // A reader over the unchanged backing sees NO coverage namespace.
        let reader2 = CtfsReader::open(&path2).unwrap();
        assert!(!reader2.has_file("coverage.tc"), "InMemory persist did not touch backing");
    }

    /// `e2e_warm_restart_reuses_coverage` — a second open over the same persisted
    /// `.ct` serves a previously-covered interval from the maps (coverage.tc
    /// recognised; no re-derivation), and an uncovered interval is NotCovered.
    #[test]
    fn e2e_warm_restart_reuses_coverage() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("warm.ct");
        make_base_ct(&path);

        // ── Session 1: populate [0,2000), collapse, persist + flush ──────────
        let (cov, mem_image) = populate_and_collapse();
        {
            let backing = Box::new(InMemoryBlockSource::new(std::fs::read(&path).unwrap()));
            let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();
            persist_into_overlay(&mut overlay, &cov, Some(&mem_image), None).unwrap();
            let mut sink = FileBlockSink::open(&path).unwrap();
            flush_overlay(&mut overlay, &mut sink).unwrap();
        }

        // ── Session 2 (warm restart): reopen the .ct fresh, reuse coverage ───
        let mut reader = CtfsReader::open(&path).unwrap();
        let warm = WarmRestartReader::open(&mut reader).unwrap();

        // A previously-covered interval is served from the maps (no re-derivation).
        let served = warm.writes_in_range(ADDR, 0, 2000).unwrap();
        let writes = served.expect("covered interval served from maps, not re-derived");
        let ticks: Vec<u64> = writes.iter().map(|w| w.tick).collect();
        assert_eq!(ticks, vec![100, 1100], "warm-restart serves the persisted writes");

        // A covered range with no writes for an address is a real "no writes".
        let empty_addr = warm.writes_in_range(0xBEEF, 0, 2000).unwrap();
        assert_eq!(empty_addr, Some(vec![]), "covered + no record = genuine empty");

        // An UNCOVERED interval is reported NotCovered — the warm cache does not
        // serve it; M6's replay-driven population must fill it.
        assert_eq!(
            warm.coverage_of(5000, 6000),
            Coverage::NotCovered {
                missing: vec![(5000, 6000)]
            }
        );
        let uncovered = warm.writes_in_range(ADDR, 5000, 6000).unwrap();
        assert_eq!(uncovered, None, "uncovered interval not served from the warm cache");
    }

    /// A sparse (un-collapsed) single-interval persist also reloads as covered
    /// (state preserved as Sparse), demonstrating the persist path is not
    /// collapse-specific.
    #[test]
    fn sparse_interval_persists_and_reloads() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sparse.ct");
        make_base_ct(&path);

        let mut cov = CoverageMap::new();
        let mut map: IntervalTaggedMap<MemWriteEntry> = IntervalTaggedMap::new();
        map.append(ADDR, 3, mw(3100, 9));
        map.append(ADDR, 3, mw(3500, 10));
        cov.coverage_add(3000, 4000, CoverageState::Sparse).unwrap();
        let mem_image = encode_single_interval_memwrites(&map, 3, 3000, 4000).unwrap();

        let backing = Box::new(InMemoryBlockSource::new(std::fs::read(&path).unwrap()));
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();
        persist_into_overlay(&mut overlay, &cov, Some(&mem_image), None).unwrap();
        let mut sink = FileBlockSink::open(&path).unwrap();
        flush_overlay(&mut overlay, &mut sink).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        let reloaded = load_coverage_from_container(&mut reader).unwrap();
        let rows = reloaded.rows();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].state, CoverageState::Sparse);
        // The query is covered (sparse), and the maps serve the writes.
        assert_eq!(reloaded.coverage_of(3000, 4000), Coverage::Covered { all_collapsed: false });
    }
}
