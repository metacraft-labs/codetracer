//! M26 — Reader for the prepopulated `step-map.ns` breakpoint index.
//!
//! ## What this is
//!
//! The CodeTracer trace spec
//! ([`codetracer-specs/Trace-Files/Seek-Based-CTFS-Reader.md` §4.1])
//! defines a dedicated **breakpoint namespace** — `step-map.ns` — that maps
//! `(path_id, line)` to the SORTED list of `step_id`s that executed on that
//! source line. It is the on-disk, computed-at-recording-time equivalent of the
//! in-memory `DistinctVec<PathId, HashMap<usize, Vec<DbStep>>>` the db-backend
//! otherwise reconstructs by replaying the whole step stream (the M24c lazy /
//! M25b parallel whole-table build).
//!
//! When a `.ct` carries this namespace, BREAKPOINT line→step resolution can be
//! answered with an O(unique-lines) index lookup and WITHOUT materializing the
//! whole step table — which is exactly the owner's "use the prepopulated tables
//! when available" guidance for breakpoint resolution.
//!
//! ## Production-emission status (honest)
//!
//! As of M26 NO production `.ct` bundle carries `step-map.ns`:
//!
//! * The spec's `step-map.ns` (magic `STMP`) is **not emitted by any writer** —
//!   it is a documented-but-unbuilt format.
//! * The Nim `MultiStreamTraceWriter` has a separate, OPT-IN `LinehitsBuilder`
//!   (`codetracer-trace-format-nim/.../linehits_builder.nim`) that records the
//!   SAME `line → [step_id]` mapping into a `linehits` CTFS namespace, but
//!   `enableLinehits` is only ever called from that repo's tests, and even then
//!   the finalized namespace is **never serialized into the container** in the
//!   writer's `close()` path. So `linehits.tc` is not consumable from a `.ct`
//!   either.
//!
//! Therefore M26 implements the CONSUMER against the spec's flat `STMP` layout
//! (which is self-contained and trivially seekable, unlike the B-tree namespace
//! format), and gates it on the namespace's actual PRESENCE. When a `.ct` ships
//! the table — whether as a container-internal file or as a sidecar — the
//! breakpoint resolver uses it; otherwise it falls back to the whole-table
//! build, byte-identically. Wiring a writer to emit `step-map.ns` in production
//! is a separate, writer-side toggle (see the M26 milestone note).
//!
//! ## Format (spec §4.1)
//!
//! ```text
//! Header:
//!   [magic: u32]            # 0x53544D50 ("STMP"), little-endian
//!   [version: u16]          # 1
//!   [path_count: u32]       # number of paths with step data
//!   [path_table_offset: u64]
//!
//! Path table (at path_table_offset), sorted by PathId:
//!   [path_id: u64]
//!   [line_count: u32]
//!   [lines_offset: u64]
//!
//! Line entries (at lines_offset for each path), sorted by line number:
//!   [line_number: u32]
//!   [step_count: u32]
//!   [first_step_id: i64]
//!   [last_step_id: i64]
//!   [steps_offset: u64]     # offset to the full step_id list
//!
//! Step ID lists (at steps_offset):
//!   [step_ids: step_count x i64]   # ascending
//! ```
//!
//! All integers are little-endian. The reader is defensive: any structural
//! inconsistency (bad magic, truncated section, out-of-bounds offset) is
//! reported as an error so the caller can cleanly fall back to the whole-table
//! build rather than serving wrong breakpoints.

use std::collections::HashMap;

use codetracer_trace_types::{PathId, StepId};

/// The spec magic for the step-map namespace: ASCII `"STMP"`, read as a
/// little-endian `u32` (`0x53544D50`).
pub const STEP_MAP_MAGIC: u32 = 0x5354_4D50;

/// The only format version this reader (and the test writer) understand.
pub const STEP_MAP_VERSION: u16 = 1;

/// The CTFS container-internal file name (and sidecar base name) for the
/// prepopulated step-map namespace, per the spec's container layout.
pub const STEP_MAP_FILE: &str = "step-map.ns";

/// Errors surfaced while parsing a `step-map.ns` blob. Every variant is a
/// recoverable "this table is unusable, fall back to the whole-table build"
/// signal — the caller never propagates these as hard failures.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StepMapError {
    /// The blob is shorter than the fixed 18-byte header.
    TooShort,
    /// The magic did not match [`STEP_MAP_MAGIC`].
    BadMagic(u32),
    /// The version field is not [`STEP_MAP_VERSION`].
    UnsupportedVersion(u16),
    /// A declared offset / length runs past the end of the blob.
    OutOfBounds {
        /// Human-readable name of the section that overran.
        section: &'static str,
        /// The byte offset the parser attempted to read at.
        offset: usize,
    },
}

impl std::fmt::Display for StepMapError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StepMapError::TooShort => write!(f, "step-map.ns shorter than header"),
            StepMapError::BadMagic(m) => write!(f, "step-map.ns bad magic 0x{m:08X}"),
            StepMapError::UnsupportedVersion(v) => write!(f, "step-map.ns unsupported version {v}"),
            StepMapError::OutOfBounds { section, offset } => {
                write!(f, "step-map.ns {section} out of bounds at offset {offset}")
            }
        }
    }
}

impl std::error::Error for StepMapError {}

/// A parsed, in-memory view of the prepopulated `step-map.ns` namespace.
///
/// The blob is parsed once at open into a `path_id → (line → sorted step_ids)`
/// map. This is intentionally the SAME shape the breakpoint resolver needs —
/// `step_ids_on_line` is a pure `HashMap` lookup with no step-stream access and
/// no whole-table build.
///
/// The map is small: O(unique source lines) `i64`s, typically well under the
/// spec's ~10MB ceiling even for large traces. Holding it resident keeps
/// breakpoint resolution O(1) per line without touching `steps.dat`.
#[derive(Debug, Default, Clone)]
pub struct StepMapNamespace {
    /// `path_id.0 → (line_number → ascending step_ids)`.
    by_path: HashMap<usize, HashMap<usize, Vec<StepId>>>,
}

/// Read a little-endian `u16` at `off`, bounds-checked.
fn read_u16(buf: &[u8], off: usize, section: &'static str) -> Result<u16, StepMapError> {
    buf.get(off..off + 2)
        .map(|b| u16::from_le_bytes([b[0], b[1]]))
        .ok_or(StepMapError::OutOfBounds { section, offset: off })
}

/// Read a little-endian `u32` at `off`, bounds-checked.
fn read_u32(buf: &[u8], off: usize, section: &'static str) -> Result<u32, StepMapError> {
    buf.get(off..off + 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .ok_or(StepMapError::OutOfBounds { section, offset: off })
}

/// Read a little-endian `u64` at `off`, bounds-checked.
fn read_u64(buf: &[u8], off: usize, section: &'static str) -> Result<u64, StepMapError> {
    buf.get(off..off + 8)
        .map(|b| u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]))
        .ok_or(StepMapError::OutOfBounds { section, offset: off })
}

/// Read a little-endian `i64` at `off`, bounds-checked.
fn read_i64(buf: &[u8], off: usize, section: &'static str) -> Result<i64, StepMapError> {
    read_u64(buf, off, section).map(|v| v as i64)
}

impl StepMapNamespace {
    /// Parse a `step-map.ns` blob per the spec §4.1 layout.
    ///
    /// Returns a fully-resident [`StepMapNamespace`] on success, or a
    /// [`StepMapError`] when the blob is malformed. Callers treat any error as
    /// "no usable prepopulated table" and fall back to the whole-table build.
    pub fn parse(buf: &[u8]) -> Result<Self, StepMapError> {
        // ── Header ──────────────────────────────────────────────────────
        // [magic:u32][version:u16][path_count:u32][path_table_offset:u64] = 18 bytes.
        if buf.len() < 18 {
            return Err(StepMapError::TooShort);
        }
        let magic = read_u32(buf, 0, "header.magic")?;
        if magic != STEP_MAP_MAGIC {
            return Err(StepMapError::BadMagic(magic));
        }
        let version = read_u16(buf, 4, "header.version")?;
        if version != STEP_MAP_VERSION {
            return Err(StepMapError::UnsupportedVersion(version));
        }
        let path_count = read_u32(buf, 6, "header.path_count")? as usize;
        let path_table_offset = read_u64(buf, 10, "header.path_table_offset")? as usize;

        // ── Path table ──────────────────────────────────────────────────
        // Each entry: [path_id:u64][line_count:u32][lines_offset:u64] = 20 bytes.
        let mut by_path: HashMap<usize, HashMap<usize, Vec<StepId>>> = HashMap::with_capacity(path_count);
        for p in 0..path_count {
            let base = path_table_offset + p * 20;
            let path_id = read_u64(buf, base, "path_table.path_id")? as usize;
            let line_count = read_u32(buf, base + 8, "path_table.line_count")? as usize;
            let lines_offset = read_u64(buf, base + 12, "path_table.lines_offset")? as usize;

            let mut by_line: HashMap<usize, Vec<StepId>> = HashMap::with_capacity(line_count);
            for l in 0..line_count {
                // Each line entry: [line:u32][step_count:u32][first:i64][last:i64][steps_offset:u64]
                // = 4 + 4 + 8 + 8 + 8 = 32 bytes. (The spec's prose "~28 bytes"
                // is a rough SIZE ESTIMATE, not the on-disk record stride.)
                let lbase = lines_offset + l * 32;
                let line = read_u32(buf, lbase, "line_entry.line")? as usize;
                let step_count = read_u32(buf, lbase + 4, "line_entry.step_count")? as usize;
                // first_step_id / last_step_id are range-check hints; the
                // authoritative data is the explicit step-id list, so we read
                // them only to validate the bounds match the list ends.
                let first_hint = read_i64(buf, lbase + 8, "line_entry.first_step_id")?;
                let last_hint = read_i64(buf, lbase + 16, "line_entry.last_step_id")?;
                let steps_offset = read_u64(buf, lbase + 24, "line_entry.steps_offset")? as usize;

                let mut step_ids = Vec::with_capacity(step_count);
                for s in 0..step_count {
                    let sbase = steps_offset + s * 8;
                    step_ids.push(StepId(read_i64(buf, sbase, "step_id_list")?));
                }
                // Defensive consistency check: the hints must bracket the list.
                // A mismatch means a corrupt/foreign table — bail to fallback.
                if step_count > 0 {
                    let actual_first = step_ids[0].0;
                    let actual_last = step_ids[step_count - 1].0;
                    if actual_first != first_hint || actual_last != last_hint {
                        return Err(StepMapError::OutOfBounds {
                            section: "line_entry.step_bounds_mismatch",
                            offset: lbase,
                        });
                    }
                }
                by_line.insert(line, step_ids);
            }
            by_path.insert(path_id, by_line);
        }

        Ok(StepMapNamespace { by_path })
    }

    /// The ascending `step_id`s recorded on `(path_id, line)`, or `None` when
    /// the path/line carries no steps in the prepopulated table.
    ///
    /// This is the O(1) breakpoint-resolution primitive: a pure two-level
    /// `HashMap` lookup with NO step-stream access and NO whole-table build.
    pub fn step_ids_on_line(&self, path_id: PathId, line: usize) -> Option<&Vec<StepId>> {
        self.by_path.get(&(path_id.0)).and_then(|by_line| by_line.get(&line))
    }

    /// Total number of `(path_id, line)` keys in the table — used by tests to
    /// confirm the namespace round-tripped the expected unique-line count.
    pub fn entry_count(&self) -> usize {
        self.by_path.values().map(|by_line| by_line.len()).sum()
    }

    /// Whether the table carries any line entry for `path_id`. The DAP
    /// "closest line" fallback uses this to decide whether the prepopulated
    /// table can answer for a path at all before scanning lines.
    pub fn has_path(&self, path_id: PathId) -> bool {
        self.by_path.get(&(path_id.0)).is_some_and(|by_line| !by_line.is_empty())
    }
}

/// Serialize a `path_id → (line → step_ids)` map into the spec §4.1 `STMP`
/// wire format. This is the inverse of [`StepMapNamespace::parse`].
///
/// It lives in the production crate (not behind `#[cfg(test)]`) for two
/// reasons: (1) it is the natural place to keep the write↔read round-trip
/// honest and audited against the spec, and (2) it is the building block a
/// future writer-side emission toggle would reuse. Tests drive it to produce a
/// genuine prepopulated table from real recorded steps — the table is DERIVED
/// from the trace, never faked.
///
/// `entries` is consumed as `(path_id, line, ascending_step_ids)` triples. The
/// function sorts paths by id and lines by number to honor the spec's
/// binary-searchable ordering.
pub fn serialize_step_map(entries: &[(PathId, usize, Vec<StepId>)]) -> Vec<u8> {
    // Group by path, then by line, sorting both keys to match the spec ordering.
    let mut by_path: std::collections::BTreeMap<u64, std::collections::BTreeMap<u32, Vec<i64>>> =
        std::collections::BTreeMap::new();
    for (path_id, line, step_ids) in entries {
        let mut ids: Vec<i64> = step_ids.iter().map(|s| s.0).collect();
        ids.sort_unstable();
        by_path
            .entry(path_id.0 as u64)
            .or_default()
            .insert(*line as u32, ids);
    }

    let path_count = by_path.len();

    // Layout plan (so every offset is known before we write any bytes):
    //   [header: 18 bytes]
    //   [path table: path_count * 20 bytes]
    //   [for each path: its line entries: line_count * 28 bytes]
    //   [for each line: its step-id list: step_count * 8 bytes]
    const HEADER_SIZE: usize = 18;
    const PATH_ENTRY_SIZE: usize = 20;
    // [line:u32][step_count:u32][first:i64][last:i64][steps_offset:u64] = 32 bytes.
    const LINE_ENTRY_SIZE: usize = 32;

    let path_table_offset = HEADER_SIZE;
    let mut cursor = path_table_offset + path_count * PATH_ENTRY_SIZE;

    // Reserve each path's line-entry block, recording where it starts.
    let mut line_block_offsets: Vec<usize> = Vec::with_capacity(path_count);
    for by_line in by_path.values() {
        line_block_offsets.push(cursor);
        cursor += by_line.len() * LINE_ENTRY_SIZE;
    }

    // Reserve each line's step-id list, recording where it starts. We flatten in
    // the same (path, line) iteration order used above.
    let mut step_list_offsets: Vec<usize> = Vec::new();
    for by_line in by_path.values() {
        for ids in by_line.values() {
            step_list_offsets.push(cursor);
            cursor += ids.len() * 8;
        }
    }

    let total = cursor;
    let mut buf = vec![0u8; total];

    // ── Header ──────────────────────────────────────────────────────────
    buf[0..4].copy_from_slice(&STEP_MAP_MAGIC.to_le_bytes());
    buf[4..6].copy_from_slice(&STEP_MAP_VERSION.to_le_bytes());
    buf[6..10].copy_from_slice(&(path_count as u32).to_le_bytes());
    buf[10..18].copy_from_slice(&(path_table_offset as u64).to_le_bytes());

    // ── Path table + line entries + step lists ──────────────────────────
    let mut step_list_idx = 0usize;
    for (p, (path_id, by_line)) in by_path.iter().enumerate() {
        let pbase = path_table_offset + p * PATH_ENTRY_SIZE;
        let lines_offset = line_block_offsets[p];
        buf[pbase..pbase + 8].copy_from_slice(&path_id.to_le_bytes());
        buf[pbase + 8..pbase + 12].copy_from_slice(&(by_line.len() as u32).to_le_bytes());
        buf[pbase + 12..pbase + 20].copy_from_slice(&(lines_offset as u64).to_le_bytes());

        for (l, (line, ids)) in by_line.iter().enumerate() {
            let lbase = lines_offset + l * LINE_ENTRY_SIZE;
            let steps_offset = step_list_offsets[step_list_idx];
            step_list_idx += 1;
            let first = ids.first().copied().unwrap_or(0);
            let last = ids.last().copied().unwrap_or(0);
            buf[lbase..lbase + 4].copy_from_slice(&line.to_le_bytes());
            buf[lbase + 4..lbase + 8].copy_from_slice(&(ids.len() as u32).to_le_bytes());
            buf[lbase + 8..lbase + 16].copy_from_slice(&first.to_le_bytes());
            buf[lbase + 16..lbase + 24].copy_from_slice(&last.to_le_bytes());
            buf[lbase + 24..lbase + 32].copy_from_slice(&(steps_offset as u64).to_le_bytes());

            for (s, id) in ids.iter().enumerate() {
                let sbase = steps_offset + s * 8;
                buf[sbase..sbase + 8].copy_from_slice(&id.to_le_bytes());
            }
        }
    }

    buf
}

#[cfg(test)]
// The bin crate (`replay-server`) denies `expect_used` / `unwrap_used` even in
// unit tests; `.expect()` on an obviously-`Ok` parse is the clearest way to
// surface a regression here, so allow it for the test module only (the same
// concession the integration tests get via their crate-level attribute).
#[allow(clippy::expect_used, clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_a_simple_table() {
        let entries = vec![
            (PathId(0), 10, vec![StepId(2), StepId(52), StepId(102)]),
            (PathId(0), 11, vec![StepId(3)]),
            (PathId(2), 7, vec![StepId(8), StepId(9)]),
        ];
        let blob = serialize_step_map(&entries);
        let ns = StepMapNamespace::parse(&blob).expect("parse round-trips");

        assert_eq!(ns.entry_count(), 3);
        assert_eq!(
            ns.step_ids_on_line(PathId(0), 10),
            Some(&vec![StepId(2), StepId(52), StepId(102)])
        );
        assert_eq!(ns.step_ids_on_line(PathId(0), 11), Some(&vec![StepId(3)]));
        assert_eq!(ns.step_ids_on_line(PathId(2), 7), Some(&vec![StepId(8), StepId(9)]));
        // Missing path / line resolve to None.
        assert!(ns.step_ids_on_line(PathId(0), 999).is_none());
        assert!(ns.step_ids_on_line(PathId(5), 10).is_none());
        assert!(ns.has_path(PathId(0)));
        assert!(!ns.has_path(PathId(5)));
    }

    #[test]
    fn unsorted_step_ids_are_sorted_on_serialize() {
        let entries = vec![(PathId(1), 4, vec![StepId(30), StepId(10), StepId(20)])];
        let blob = serialize_step_map(&entries);
        let ns = StepMapNamespace::parse(&blob).expect("parse");
        assert_eq!(
            ns.step_ids_on_line(PathId(1), 4),
            Some(&vec![StepId(10), StepId(20), StepId(30)])
        );
    }

    #[test]
    fn rejects_bad_magic() {
        let mut blob = serialize_step_map(&[(PathId(0), 1, vec![StepId(0)])]);
        blob[0] = 0xFF;
        assert!(matches!(StepMapNamespace::parse(&blob), Err(StepMapError::BadMagic(_))));
    }

    #[test]
    fn rejects_bad_version() {
        let mut blob = serialize_step_map(&[(PathId(0), 1, vec![StepId(0)])]);
        blob[4] = 9;
        blob[5] = 0;
        assert!(matches!(
            StepMapNamespace::parse(&blob),
            Err(StepMapError::UnsupportedVersion(9))
        ));
    }

    #[test]
    fn rejects_truncated_header() {
        assert!(matches!(
            StepMapNamespace::parse(&[0u8; 4]),
            Err(StepMapError::TooShort)
        ));
    }

    #[test]
    fn rejects_truncated_body() {
        let mut blob = serialize_step_map(&[(PathId(0), 1, vec![StepId(7)])]);
        // Lop off the final step-id list bytes — the parser must bail, not panic.
        blob.truncate(blob.len() - 4);
        assert!(matches!(
            StepMapNamespace::parse(&blob),
            Err(StepMapError::OutOfBounds { .. })
        ));
    }

    #[test]
    fn empty_table_round_trips() {
        let blob = serialize_step_map(&[]);
        let ns = StepMapNamespace::parse(&blob).expect("empty table parses");
        assert_eq!(ns.entry_count(), 0);
        assert!(ns.step_ids_on_line(PathId(0), 1).is_none());
    }
}
