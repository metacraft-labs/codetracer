//! M4 — the `coverage.tc` namespace: persisted partial-coverage data model.
//!
//! ## What this is
//!
//! When the omniscient maps (`memwrites.tc` / `linehits.tc`) are built **lazily**
//! at replay time (MCR-Omniscient-DB-Algorithms.md §2.4), the database is at any
//! moment only *partially* populated. The set of populated regions is itself
//! persisted as a CTFS namespace, `coverage.tc`: a sorted set of disjoint
//! `[tick_lo, tick_hi)` intervals, each tagged with its state.
//!
//! `coverage.tc` is the durable successor of the previously in-memory-only
//! `analyzed_set` bitset: a new session reads it and **reuses already-analyzed
//! intervals** instead of re-replaying (warm restart, M5). It is the
//! positive-space dual of `partial-global-memwrites.tc` (which lists what is
//! *known missing*): `coverage.tc` says what *is* analyzed.
//!
//! ## The coverage distinction (M4 deliverable 4)
//!
//! The whole point of `coverage.tc` is to distinguish two cases a bare empty map
//! cannot tell apart (§1.3 invariant 7):
//!
//! * **covered, no hits** — the interval's maps are complete for this tick range
//!   and there simply are no records (a real, trustable "no writes here").
//! * **not analyzed** — the tick range is absent from `coverage.tc`; absence of
//!   records means *unknown*, not *empty*, and a reader must trigger population
//!   (M5/M6) before treating it as empty.
//!
//! [`CoverageMap::coverage_of`] returns exactly this trichotomy.
//!
//! ## Persistence (CoW-backed)
//!
//! Coverage rows are persisted through the M3/M4 copy-on-write namespace B-tree
//! ([`super::cow_namespace_writer::CowNamespaceWriter`] /
//! [`super::cow_namespace_reader::CowNamespaceReader`]): the row for an interval
//! is keyed by its `tick_lo` (u64) with a 16-byte (Type B) descriptor carrying
//! `tick_hi` + `state`. Each `coverage_add` is one CoW commit that atomically
//! advances the namespace root, so an interrupted persist-mode flush leaves the
//! last committed coverage tree intact (CTFS-Binary-Format.md §10). This is the
//! mechanism the M5 warm-restart + persist path consumes.
//!
//! ## Invariant (M4 deliverable 5)
//!
//! An interval is added to `coverage.tc` **only once** its maps are complete for
//! that tick range. This module does not itself analyze maps; it is the caller's
//! contract (the lazy-population loop, M5/M6) to call [`CoverageMap::coverage_add`]
//! only after `append_tagged_records` has made the maps complete for the range.
//! The type documents and centralises that invariant.

use std::collections::BTreeMap;

use super::cow_namespace_reader::{CowLeafType, CowNamespaceReader, CowNsError};
use super::cow_namespace_writer::{CowNamespaceWriter, CowWriteError};

/// The CTFS namespace file name for the coverage dual (§1.2).
pub const CTFS_COVERAGE_FILE: &str = "coverage.tc";

/// State of one populated `[tick_lo, tick_hi)` interval (§2.4 `CoverageRow`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoverageState {
    /// The interval's maps are complete for this tick range, but the underlying
    /// `memwrites.tc` / `linehits.tc` values for this region are still stored as
    /// per-`interval_id` sub-lists (not yet merged with neighbours).
    Sparse,
    /// The region has been compacted into one flat tick-sorted array per key
    /// (the M5 collapse-to-full output).
    CollapsedComplete,
}

impl CoverageState {
    /// On-disk byte tag for the state, stored in the coverage descriptor.
    fn to_byte(self) -> u8 {
        match self {
            CoverageState::Sparse => 0,
            CoverageState::CollapsedComplete => 1,
        }
    }

    /// Parse the on-disk byte tag, rejecting unknown values.
    fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(CoverageState::Sparse),
            1 => Some(CoverageState::CollapsedComplete),
            _ => None,
        }
    }
}

/// One populated coverage interval (§2.4 `CoverageRow`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoverageRow {
    /// Inclusive lower tick bound.
    pub tick_lo: u64,
    /// Exclusive upper tick bound.
    pub tick_hi: u64,
    /// The interval's state.
    pub state: CoverageState,
}

/// The result of a coverage query over a tick range — the trichotomy the whole
/// `coverage.tc` mechanism exists to express (§1.3 invariant 7).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Coverage {
    /// Every tick in the queried range falls inside a populated interval. The
    /// reader may trust map results for this range without re-checking.
    Covered {
        /// `true` once every covering interval is `CollapsedComplete`.
        all_collapsed: bool,
    },
    /// Some (or all) of the queried range is absent from `coverage.tc`. The
    /// reader must trigger population for `missing` before treating absence of
    /// records as absence of writes. Carries the still-uncovered sub-ranges.
    NotCovered {
        /// The maximal `[lo, hi)` sub-ranges of the query that are NOT covered.
        missing: Vec<(u64, u64)>,
    },
}

/// Errors surfaced while persisting / loading the coverage namespace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoverageError {
    /// A row with `tick_hi <= tick_lo` (an empty / inverted interval).
    EmptyInterval {
        /// The offending lower bound.
        tick_lo: u64,
        /// The offending upper bound.
        tick_hi: u64,
    },
    /// A new row overlaps an already-present row (coverage rows must be disjoint,
    /// §2.4 "sorted set of disjoint intervals").
    Overlap {
        /// The new row's lower bound.
        tick_lo: u64,
        /// The new row's upper bound.
        tick_hi: u64,
        /// The existing row it overlapped.
        existing_lo: u64,
    },
    /// Underlying CoW writer error.
    Write(CowWriteError),
    /// Underlying CoW reader error while reloading a persisted image.
    Read(CowNsError),
    /// A persisted descriptor carried an unknown state byte.
    BadStateByte(u8),
}

impl std::fmt::Display for CoverageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CoverageError::EmptyInterval { tick_lo, tick_hi } => {
                write!(f, "coverage interval [{tick_lo}, {tick_hi}) is empty/inverted")
            }
            CoverageError::Overlap {
                tick_lo,
                tick_hi,
                existing_lo,
            } => write!(
                f,
                "coverage interval [{tick_lo}, {tick_hi}) overlaps existing row at {existing_lo}"
            ),
            CoverageError::Write(e) => write!(f, "coverage write: {e}"),
            CoverageError::Read(e) => write!(f, "coverage read: {e}"),
            CoverageError::BadStateByte(b) => write!(f, "coverage bad state byte {b}"),
        }
    }
}

impl std::error::Error for CoverageError {}

impl From<CowWriteError> for CoverageError {
    fn from(e: CowWriteError) -> Self {
        CoverageError::Write(e)
    }
}

impl From<CowNsError> for CoverageError {
    fn from(e: CowNsError) -> Self {
        CoverageError::Read(e)
    }
}

/// Encode a coverage row's descriptor: `[tick_hi: u64][state: u8][pad: 7]` = 16
/// bytes (Type B). The key (`tick_lo`) lives in the B-tree key, not the
/// descriptor.
fn encode_descriptor(tick_hi: u64, state: CoverageState) -> [u8; 16] {
    let mut d = [0u8; 16];
    d[0..8].copy_from_slice(&tick_hi.to_le_bytes());
    d[8] = state.to_byte();
    d
}

/// Decode a coverage row's descriptor. Returns the `(tick_hi, state)` pair, or a
/// [`CoverageError::BadStateByte`] for an unknown state tag.
fn decode_descriptor(desc: &[u8]) -> Result<(u64, CoverageState), CoverageError> {
    let mut hi = [0u8; 8];
    hi.copy_from_slice(&desc[0..8]);
    let tick_hi = u64::from_le_bytes(hi);
    let state = CoverageState::from_byte(desc[8]).ok_or(CoverageError::BadStateByte(desc[8]))?;
    Ok((tick_hi, state))
}

/// The in-memory + CoW-persisted coverage set.
///
/// Holds the sorted set of disjoint coverage rows (keyed by `tick_lo`) both in a
/// `BTreeMap` for O(log n) range queries AND in a CoW namespace B-tree
/// ([`CowNamespaceWriter`]) for crash-safe incremental persistence. The two are
/// kept in sync: every [`Self::coverage_add`] mutates the `BTreeMap` and commits
/// one CoW root.
pub struct CoverageMap {
    /// `tick_lo → (tick_hi, state)`. Disjoint, sorted by `tick_lo`.
    rows: BTreeMap<u64, (u64, CoverageState)>,
    /// CoW namespace writer backing the on-disk `coverage.tc` image.
    writer: CowNamespaceWriter,
}

impl CoverageMap {
    /// Create an empty coverage map with a fresh CoW namespace backing it.
    pub fn new() -> Self {
        CoverageMap {
            rows: BTreeMap::new(),
            // Type B: 16-byte descriptors; skip sub-blocks (coverage rows are
            // fixed-size, full-block-allocated like `threads.ns`).
            writer: CowNamespaceWriter::new(CowLeafType::TypeB, true),
        }
    }

    /// Reload a coverage map from a persisted `coverage.tc` page image (e.g. one
    /// read back from the `.ct` at session start — the warm-restart path, M5).
    ///
    /// Rebuilds the `BTreeMap` by walking every committed key/descriptor and
    /// resumes incremental commits from the published root.
    pub fn load(image: &[u8]) -> Result<Self, CoverageError> {
        let reader = match CowNamespaceReader::open(image, CowLeafType::TypeB) {
            Ok(r) => r,
            // An empty namespace (never committed) reloads as an empty map.
            Err(CowNsError::Empty) => return Ok(Self::new()),
            Err(e) => return Err(CoverageError::Read(e)),
        };
        let mut rows = BTreeMap::new();
        for tick_lo in reader.keys()? {
            let desc = reader.lookup(tick_lo)?;
            let (tick_hi, state) = decode_descriptor(desc)?;
            rows.insert(tick_lo, (tick_hi, state));
        }
        let writer = CowNamespaceWriter::load(image, CowLeafType::TypeB)?;
        Ok(CoverageMap { rows, writer })
    }

    /// Record a populated interval `[tick_lo, tick_hi)` with the given state and
    /// commit it (CoW). This is the §2.4 `coverage_add`.
    ///
    /// **Invariant (M4 deliverable 5 / §1.3 invariant 7):** the caller must only
    /// call this once the underlying maps are complete for `[tick_lo, tick_hi)`.
    /// Returns the new commit id on success.
    ///
    /// Rejects an empty/inverted interval and an interval that overlaps an
    /// existing row (coverage rows are a sorted set of *disjoint* intervals).
    pub fn coverage_add(&mut self, tick_lo: u64, tick_hi: u64, state: CoverageState) -> Result<u64, CoverageError> {
        if tick_hi <= tick_lo {
            return Err(CoverageError::EmptyInterval { tick_lo, tick_hi });
        }
        // Reject overlap with any existing row. The row at-or-before tick_lo may
        // extend past tick_lo; the row at-or-after tick_lo may start before
        // tick_hi. Rows are disjoint, so at most one of each can exist.
        let left = self.rows.range(..=tick_lo).next_back();
        if let Some((&elo, &(ehi, _))) = left
            && ehi > tick_lo
        {
            return Err(CoverageError::Overlap {
                tick_lo,
                tick_hi,
                existing_lo: elo,
            });
        }
        let right = self.rows.range(tick_lo..).next();
        if let Some((&elo, _)) = right
            && elo < tick_hi
        {
            return Err(CoverageError::Overlap {
                tick_lo,
                tick_hi,
                existing_lo: elo,
            });
        }

        let commit = self
            .writer
            .insert_and_commit(tick_lo, &encode_descriptor(tick_hi, state))?;
        self.rows.insert(tick_lo, (tick_hi, state));
        Ok(commit)
    }

    /// Replace the state of an already-present interval (e.g. `Sparse` →
    /// `CollapsedComplete` after a collapse, M5). The interval bounds must match
    /// an existing row's `tick_lo` exactly. Returns the new commit id.
    pub fn coverage_set_state(&mut self, tick_lo: u64, state: CoverageState) -> Result<u64, CoverageError> {
        let &(tick_hi, _) = self.rows.get(&tick_lo).ok_or(CoverageError::EmptyInterval {
            tick_lo,
            tick_hi: tick_lo,
        })?;
        let commit = self
            .writer
            .insert_and_commit(tick_lo, &encode_descriptor(tick_hi, state))?;
        self.rows.insert(tick_lo, (tick_hi, state));
        Ok(commit)
    }

    /// The serialised on-disk `coverage.tc` page image (what a persist-mode
    /// overlay flush writes into the `.ct`).
    pub fn serialize(&self) -> Vec<u8> {
        self.writer.serialize()
    }

    /// Every coverage row in `tick_lo` order.
    pub fn rows(&self) -> Vec<CoverageRow> {
        self.rows
            .iter()
            .map(|(&tick_lo, &(tick_hi, state))| CoverageRow {
                tick_lo,
                tick_hi,
                state,
            })
            .collect()
    }

    /// Number of coverage rows.
    pub fn len(&self) -> usize {
        self.rows.len()
    }

    /// Whether the coverage set is empty.
    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    /// Classify a query's tick range `[tick_lo, tick_hi)` as covered or not.
    ///
    /// This is the M4 deliverable-4 coverage distinction: a fully-covered range
    /// returns [`Coverage::Covered`] (and whether every covering interval is
    /// collapsed); any gap returns [`Coverage::NotCovered`] with the precise
    /// uncovered sub-ranges so the caller knows exactly what to populate.
    pub fn coverage_of(&self, tick_lo: u64, tick_hi: u64) -> Coverage {
        if tick_hi <= tick_lo {
            // Degenerate empty query: nothing to cover, vacuously covered.
            return Coverage::Covered { all_collapsed: true };
        }
        let mut cursor = tick_lo;
        let mut missing: Vec<(u64, u64)> = Vec::new();
        let mut all_collapsed = true;

        // Walk the rows whose `tick_lo` could intersect the query. Start from the
        // row at-or-before the query start (it may extend into the query).
        let start_key = self
            .rows
            .range(..=tick_lo)
            .next_back()
            .map(|(&k, _)| k)
            .unwrap_or(tick_lo);
        for (&row_lo, &(row_hi, state)) in self.rows.range(start_key..) {
            if row_lo >= tick_hi {
                break; // past the query range
            }
            if row_hi <= cursor {
                continue; // entirely before the cursor
            }
            if row_lo > cursor {
                // Gap between the cursor and this row's start.
                missing.push((cursor, row_lo.min(tick_hi)));
                if row_lo >= tick_hi {
                    cursor = tick_hi;
                    break;
                }
            }
            // This row covers [max(cursor,row_lo), min(row_hi,tick_hi)).
            let covered_to = row_hi.min(tick_hi);
            if covered_to > cursor {
                if state != CoverageState::CollapsedComplete {
                    all_collapsed = false;
                }
                cursor = covered_to;
            }
            if cursor >= tick_hi {
                break;
            }
        }
        if cursor < tick_hi {
            missing.push((cursor, tick_hi));
        }

        if missing.is_empty() {
            Coverage::Covered { all_collapsed }
        } else {
            Coverage::NotCovered { missing }
        }
    }

    /// The coverage rows that intersect `[tick_lo, tick_hi)`, in `tick_lo` order.
    /// Used by merge-on-read to know which interval sub-lists to merge.
    pub fn intervals_intersecting(&self, tick_lo: u64, tick_hi: u64) -> Vec<CoverageRow> {
        let mut out = Vec::new();
        if tick_hi <= tick_lo {
            return out;
        }
        // Start from the row at-or-before the query start: it is the only row
        // with `tick_lo < query_lo` that can still extend into the query (rows
        // are disjoint, so at most one such row exists). Earlier rows end before
        // `query_lo` and cannot intersect.
        let start_key = self
            .rows
            .range(..=tick_lo)
            .next_back()
            .map(|(&k, _)| k)
            .unwrap_or(tick_lo);
        for (&row_lo, &(row_hi, state)) in self.rows.range(start_key..) {
            if row_lo >= tick_hi {
                break;
            }
            if row_hi > tick_lo {
                out.push(CoverageRow {
                    tick_lo: row_lo,
                    tick_hi: row_hi,
                    state,
                });
            }
        }
        out
    }
}

impl Default for CoverageMap {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used)]
mod tests {
    use super::*;

    /// M4 — `test_coverage_tc_roundtrip`: coverage.tc intervals + states persist
    /// and reload identically through the CoW namespace image.
    #[test]
    fn test_coverage_tc_roundtrip() {
        let mut cov = CoverageMap::new();
        cov.coverage_add(1000, 2000, CoverageState::Sparse).expect("add");
        cov.coverage_add(2000, 3000, CoverageState::CollapsedComplete)
            .expect("add");
        cov.coverage_add(5000, 6000, CoverageState::Sparse).expect("add");

        let image = cov.serialize();
        let reloaded = CoverageMap::load(&image).expect("reload");

        let rows = reloaded.rows();
        assert_eq!(
            rows,
            vec![
                CoverageRow {
                    tick_lo: 1000,
                    tick_hi: 2000,
                    state: CoverageState::Sparse
                },
                CoverageRow {
                    tick_lo: 2000,
                    tick_hi: 3000,
                    state: CoverageState::CollapsedComplete
                },
                CoverageRow {
                    tick_lo: 5000,
                    tick_hi: 6000,
                    state: CoverageState::Sparse
                },
            ]
        );
        // The reloaded map is still fully functional (queries match the original).
        assert_eq!(
            reloaded.coverage_of(1000, 3000),
            Coverage::Covered { all_collapsed: false }
        );
        assert_eq!(
            reloaded.coverage_of(2000, 3000),
            Coverage::Covered { all_collapsed: true }
        );
    }

    /// M4 — `test_partial_coverage_query_distinguishes_uncovered`: a query into
    /// an unanalyzed interval reports NOT-covered (vs covered-but-empty).
    #[test]
    fn test_partial_coverage_query_distinguishes_uncovered() {
        let mut cov = CoverageMap::new();
        // Only [1000, 2000) is analyzed.
        cov.coverage_add(1000, 2000, CoverageState::Sparse).expect("add");

        // A query fully inside the analyzed interval is COVERED — absence of
        // records there is a real "no writes", not "unknown".
        assert_eq!(cov.coverage_of(1200, 1800), Coverage::Covered { all_collapsed: false });

        // A query into an UNANALYZED interval is NOT-covered (unknown), and names
        // the exact missing sub-range — never reported as empty.
        assert_eq!(
            cov.coverage_of(3000, 4000),
            Coverage::NotCovered {
                missing: vec![(3000, 4000)]
            }
        );

        // A query straddling the analyzed/unanalyzed boundary reports only the
        // uncovered tail as missing.
        assert_eq!(
            cov.coverage_of(1500, 2500),
            Coverage::NotCovered {
                missing: vec![(2000, 2500)]
            }
        );

        // A query before the analyzed interval reports the uncovered head.
        assert_eq!(
            cov.coverage_of(500, 1500),
            Coverage::NotCovered {
                missing: vec![(500, 1000)]
            }
        );
    }

    #[test]
    fn rejects_empty_and_overlapping_intervals() {
        let mut cov = CoverageMap::new();
        assert!(matches!(
            cov.coverage_add(2000, 1000, CoverageState::Sparse),
            Err(CoverageError::EmptyInterval { .. })
        ));
        cov.coverage_add(1000, 2000, CoverageState::Sparse).expect("add");
        // Overlap on the left edge.
        assert!(matches!(
            cov.coverage_add(1500, 2500, CoverageState::Sparse),
            Err(CoverageError::Overlap { .. })
        ));
        // Overlap fully containing.
        assert!(matches!(
            cov.coverage_add(900, 2100, CoverageState::Sparse),
            Err(CoverageError::Overlap { .. })
        ));
        // Adjacent (touching but disjoint) is fine.
        cov.coverage_add(2000, 3000, CoverageState::Sparse)
            .expect("adjacent ok");
    }

    #[test]
    fn collapse_state_transition_persists() {
        let mut cov = CoverageMap::new();
        cov.coverage_add(0, 1000, CoverageState::Sparse).expect("add");
        cov.coverage_set_state(0, CoverageState::CollapsedComplete)
            .expect("collapse");
        let reloaded = CoverageMap::load(&cov.serialize()).expect("reload");
        assert_eq!(
            reloaded.rows(),
            vec![CoverageRow {
                tick_lo: 0,
                tick_hi: 1000,
                state: CoverageState::CollapsedComplete
            }]
        );
    }

    #[test]
    fn intervals_intersecting_is_precise() {
        let mut cov = CoverageMap::new();
        cov.coverage_add(0, 1000, CoverageState::Sparse).expect("add");
        cov.coverage_add(1000, 2000, CoverageState::Sparse).expect("add");
        cov.coverage_add(5000, 6000, CoverageState::Sparse).expect("add");

        let hit = cov.intervals_intersecting(500, 5500);
        let los: Vec<u64> = hit.iter().map(|r| r.tick_lo).collect();
        assert_eq!(los, vec![0, 1000, 5000]);

        // A query strictly between intervals hits nothing.
        assert!(cov.intervals_intersecting(2000, 5000).is_empty());
    }
}
