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
//! * The Nim `MultiStreamTraceWriter` also has an OPT-IN `LinehitsBuilder`
//!   (`codetracer-trace-format-nim/.../linehits_builder.nim`) that records a
//!   related `line → [step_id]` mapping and, as of the M8 CoW namespace slice,
//!   serializes it as `linehits.tc` through an `NSB1` CoW namespace. That
//!   namespace serves omniscient line-hit consumers; breakpoint resolution still
//!   uses this `STMP` table when present because its shape is purpose-built for
//!   `(path_id, line) → sorted step_ids`.
//!
//! Therefore M26 implements the CONSUMER against the spec's flat `STMP` layout
//! (which is self-contained and trivially seekable, unlike the B-tree namespace
//! format), and gates it on the namespace's actual PRESENCE. When a `.ct` ships
//! the table — whether as a container-internal file or as a sidecar — the
//! breakpoint resolver uses it; otherwise it falls back to the whole-table
//! build, byte-identically. Wiring a writer to emit `step-map.ns` in production
//! is a separate, writer-side toggle (see the M26 milestone note).
//!
//! ## Format (version 2, `codetracer-trace-format-spec/internal-files.md` §"`step-map.ns`")
//!
//! ```text
//! Header (26 bytes):
//!   magic: u32 = 0x53544D50 ("STMP")   version: u16 = 2
//!   chunk_count: u32   path_count: u32   line_count: u32   step_count: u64
//! Chunk table, chunk_count x 20 bytes, in key order:
//!   frame_offset: u64 (from the end of the table)   first_path_id: u64   first_line: u32
//! Frames: one zstd frame per chunk, back to back; the last ends at the end of the member.
//! Chunk content: line records in ascending (path_id, line) order:
//!   path_delta: varint   line: varint (absolute after a path change or at a chunk's
//!   start, else the line minus the previous one)   count: varint
//!   runs until their repeats add up to count: gap: varint, repeat: varint
//!   (the id before a list's first is -1)
//! ```
//!
//! All fixed-width integers are little-endian. The reader refuses, by name,
//! every malformation the specification lists -- counts that disagree with
//! the header, a chunk whose first key is not its table key, keys that do not
//! ascend, a `count`, `gap` or `repeat` of 0, runs that overshoot their count,
//! a frame that does not decode to its declared size -- because each is a map
//! that would answer some breakpoint with the wrong steps. The caller treats a
//! refusal as "no usable index" and falls back to the whole-table build.

use std::collections::HashMap;

use codetracer_trace_types::{PathId, StepId};

/// The spec magic for the step-map namespace: ASCII `"STMP"`, read as a
/// little-endian `u32` (`0x53544D50`).
pub const STEP_MAP_MAGIC: u32 = 0x5354_4D50;

/// The only format version this reader (and the serializer) understand.
pub const STEP_MAP_VERSION: u16 = 2;

/// The CTFS container-internal file name (and sidecar base name) for the
/// prepopulated step-map namespace, per the spec's container layout.
pub const STEP_MAP_FILE: &str = "step-map.ns";

/// The decompressed size at or past which a chunk is closed (after the record
/// that reaches it). Normative, so that two writers produce the same bytes.
pub const STEP_MAP_CHUNK_TARGET: usize = 65_536;

/// The zstd level every chunk is compressed at.
pub const STEP_MAP_ZSTD_LEVEL: i32 = 3;

const HEADER_SIZE: usize = 26;
const CHUNK_ENTRY_SIZE: usize = 20;

/// Errors surfaced while parsing a `step-map.ns` blob. Every variant is a
/// recoverable "this table is unusable, fall back to the whole-table build"
/// signal — the caller never propagates these as hard failures.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StepMapError {
    /// The blob is shorter than the fixed 26-byte header.
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
    /// The member is well-framed but says something a step map cannot: the
    /// message names what.
    Invalid(String),
}

impl std::fmt::Display for StepMapError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StepMapError::TooShort => write!(f, "step-map.ns shorter than its 26-byte header"),
            StepMapError::BadMagic(m) => write!(f, "step-map.ns bad magic 0x{m:08X}"),
            StepMapError::UnsupportedVersion(v) => write!(
                f,
                "step-map.ns version {v} is not readable: this reader reads version {STEP_MAP_VERSION} only"
            ),
            StepMapError::OutOfBounds { section, offset } => {
                write!(f, "step-map.ns {section} out of bounds at offset {offset}")
            }
            StepMapError::Invalid(what) => write!(f, "step-map.ns refused: {what}"),
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
    /// M0/3 — `path_id.0 → line numbers in DESCENDING order`. The line-map
    /// accessor [`Self::max_line_in_step_range`] walks lines from the highest
    /// down and stops at the first one with a step in range, so it needs the
    /// keys ordered; the `by_path` `HashMap` cannot supply that. Derived once at
    /// parse — O(unique lines), no step-stream access.
    lines_desc: HashMap<usize, Vec<usize>>,
    /// M0/3 — total number of step ids across every `(path, line)` list, plus
    /// the smallest and largest id seen. Together with the reader's step count
    /// these are what [`Self::covers_all_steps`] checks before the line-map
    /// accessor is allowed to answer.
    total_step_ids: usize,
    /// Smallest step id in the table (`i64::MAX` for an empty table).
    min_step_id: i64,
    /// Largest step id in the table (`i64::MIN` for an empty table).
    max_step_id: i64,
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

fn invalid<T>(what: impl Into<String>) -> Result<T, StepMapError> {
    Err(StepMapError::Invalid(what.into()))
}

/// Read an unsigned LEB128 varint of at most ten bytes.
fn read_varint(buf: &[u8], pos: &mut usize, chunk: usize) -> Result<u64, StepMapError> {
    let mut value = 0u64;
    let mut shift = 0u32;
    loop {
        let Some(&byte) = buf.get(*pos) else {
            return invalid(format!("chunk {chunk} ends inside a record"));
        };
        *pos += 1;
        if shift == 63 && byte > 1 {
            return invalid(format!("chunk {chunk}: a varint overflows 64 bits"));
        }
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(value);
        }
        shift += 7;
        if shift > 63 {
            return invalid(format!("chunk {chunk}: a varint is longer than ten bytes"));
        }
    }
}

/// The content size a zstd frame header declares, or `None` when the frame
/// declares none (RFC 8878 §3.1.1.1).
fn declared_content_size(frame: &[u8]) -> Option<u64> {
    if frame.len() < 5 || frame[0..4] != [0x28, 0xB5, 0x2F, 0xFD] {
        return None;
    }
    let fhd = frame[4];
    let fcs_flag = fhd >> 6;
    let single_segment = fhd & 0x20 != 0;
    let dict_id_bytes = [0usize, 1, 2, 4][(fhd & 0x03) as usize];
    let fcs_bytes = match fcs_flag {
        0 if single_segment => 1,
        0 => return None,
        1 => 2,
        2 => 4,
        _ => 8,
    };
    let start = 5 + usize::from(!single_segment) + dict_id_bytes;
    let field = frame.get(start..start + fcs_bytes)?;
    let mut raw = [0u8; 8];
    raw[..fcs_bytes].copy_from_slice(field);
    let value = u64::from_le_bytes(raw);
    Some(if fcs_bytes == 2 { value + 256 } else { value })
}

#[cfg(not(target_arch = "wasm32"))]
fn inflate(frame: &[u8]) -> Result<Vec<u8>, String> {
    zstd::decode_all(std::io::Cursor::new(frame)).map_err(|e| e.to_string())
}

#[cfg(target_arch = "wasm32")]
fn inflate(frame: &[u8]) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let mut decoder =
        ruzstd::decoding::StreamingDecoder::new(std::io::Cursor::new(frame)).map_err(|e| e.to_string())?;
    let mut raw = Vec::new();
    decoder.read_to_end(&mut raw).map_err(|e| e.to_string())?;
    Ok(raw)
}

/// Inflate chunk `chunk`'s frame, refusing one that declares no content size
/// or does not decode to the size it declares.
fn inflate_chunk(frame: &[u8], chunk: usize) -> Result<Vec<u8>, StepMapError> {
    let Some(declared) = declared_content_size(frame) else {
        return invalid(format!("chunk {chunk}'s frame does not declare its content size"));
    };
    let content = match inflate(frame) {
        Ok(content) => content,
        Err(e) => return invalid(format!("chunk {chunk}'s frame does not decode: {e}")),
    };
    if content.len() as u64 != declared {
        return invalid(format!(
            "chunk {chunk}'s frame decodes to {} bytes, not the {declared} it declares",
            content.len()
        ));
    }
    Ok(content)
}

impl StepMapNamespace {
    /// Parse a version 2 `step-map.ns` member.
    ///
    /// Returns a fully-resident [`StepMapNamespace`] on success, or a
    /// [`StepMapError`] naming what is wrong. Callers treat any error as "no
    /// usable prepopulated table" and fall back to the whole-table build.
    pub fn parse(buf: &[u8]) -> Result<Self, StepMapError> {
        if buf.len() < 6 {
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
        if buf.len() < HEADER_SIZE {
            return Err(StepMapError::TooShort);
        }
        let chunk_count = read_u32(buf, 6, "header.chunk_count")? as usize;
        let path_count = read_u32(buf, 10, "header.path_count")? as u64;
        let line_count = read_u32(buf, 14, "header.line_count")? as u64;
        let step_count = read_u64(buf, 18, "header.step_count")?;

        let table_end = chunk_count
            .checked_mul(CHUNK_ENTRY_SIZE)
            .and_then(|t| t.checked_add(HEADER_SIZE))
            .filter(|&end| end <= buf.len())
            .ok_or(StepMapError::OutOfBounds {
                section: "chunk_table",
                offset: HEADER_SIZE,
            })?;
        let mut chunks: Vec<(usize, u64, u32)> = Vec::with_capacity(chunk_count);
        for c in 0..chunk_count {
            let base = HEADER_SIZE + c * CHUNK_ENTRY_SIZE;
            let offset = read_u64(buf, base, "chunk_table.frame_offset")?;
            let start = usize::try_from(offset)
                .ok()
                .and_then(|o| o.checked_add(table_end))
                .filter(|&start| start <= buf.len())
                .ok_or(StepMapError::OutOfBounds {
                    section: "chunk_table.frame_offset",
                    offset: base,
                })?;
            chunks.push((
                start,
                read_u64(buf, base + 8, "chunk_table.first_path_id")?,
                read_u32(buf, base + 16, "chunk_table.first_line")?,
            ));
        }
        if let Some(&(first, _, _)) = chunks.first()
            && first != table_end
        {
            return invalid("the first frame does not start at the end of the chunk table");
        }

        let mut by_path: HashMap<usize, HashMap<usize, Vec<StepId>>> = HashMap::new();
        let mut lines_desc: HashMap<usize, Vec<usize>> = HashMap::new();
        let mut total_step_ids = 0u64;
        let mut total_lines = 0u64;
        let mut min_step_id = i64::MAX;
        let mut max_step_id = i64::MIN;
        let mut previous_key: Option<(u64, u64)> = None;
        for (c, &(start, first_path, first_line)) in chunks.iter().enumerate() {
            let end = chunks.get(c + 1).map_or(buf.len(), |next| next.0);
            if end < start {
                return invalid(format!("chunk {c}'s frame ends before it starts"));
            }
            let content = inflate_chunk(&buf[start..end], c)?;
            let mut pos = 0usize;
            let (mut path, mut line) = (first_path, 0u64);
            let mut first_record = true;
            while pos < content.len() {
                let path_delta = read_varint(&content, &mut pos, c)?;
                let line_field = read_varint(&content, &mut pos, c)?;
                if first_record {
                    if path_delta != 0 || line_field != u64::from(first_line) {
                        return invalid(format!(
                            "chunk {c}'s first record is not its table key ({first_path}, {first_line})"
                        ));
                    }
                    line = line_field;
                } else if path_delta > 0 {
                    path = path
                        .checked_add(path_delta)
                        .ok_or_else(|| StepMapError::Invalid(format!("chunk {c}: a path id overflows")))?;
                    line = line_field;
                } else {
                    if line_field == 0 {
                        return invalid(format!("chunk {c}: keys do not ascend strictly (a line delta of 0)"));
                    }
                    line = line
                        .checked_add(line_field)
                        .ok_or_else(|| StepMapError::Invalid(format!("chunk {c}: a line overflows")))?;
                }
                if line > u64::from(u32::MAX) {
                    return invalid(format!("chunk {c}: line {line} does not fit 32 bits"));
                }
                if previous_key.is_some_and(|previous| (path, line) <= previous) {
                    return invalid(format!("chunk {c}: keys do not ascend strictly at ({path}, {line})"));
                }
                previous_key = Some((path, line));
                first_record = false;

                let count = read_varint(&content, &mut pos, c)?;
                if count == 0 {
                    return invalid(format!("chunk {c}: line ({path}, {line}) has a count of 0"));
                }
                let mut ids: Vec<StepId> = Vec::with_capacity(count.min(1 << 20) as usize);
                let mut previous_id = -1i64;
                let mut decoded = 0u64;
                while decoded < count {
                    let gap = read_varint(&content, &mut pos, c)?;
                    let repeat = read_varint(&content, &mut pos, c)?;
                    if gap == 0 || repeat == 0 {
                        return invalid(format!("chunk {c}: line ({path}, {line}) has a gap or repeat of 0"));
                    }
                    if repeat > count - decoded {
                        return invalid(format!(
                            "chunk {c}: the runs of line ({path}, {line}) overshoot its count {count}"
                        ));
                    }
                    let gap =
                        i64::try_from(gap).map_err(|_| StepMapError::Invalid(format!("chunk {c}: a gap overflows")))?;
                    for _ in 0..repeat {
                        previous_id = previous_id
                            .checked_add(gap)
                            .ok_or_else(|| StepMapError::Invalid(format!("chunk {c}: a step id overflows")))?;
                        ids.push(StepId(previous_id));
                    }
                    decoded += repeat;
                }
                total_step_ids += count;
                total_lines += 1;
                if let (Some(first), Some(last)) = (ids.first(), ids.last()) {
                    min_step_id = min_step_id.min(first.0);
                    max_step_id = max_step_id.max(last.0);
                }
                by_path.entry(path as usize).or_default().insert(line as usize, ids);
            }
            if first_record {
                return invalid(format!("chunk {c} holds no record"));
            }
        }
        let paths_seen = by_path.len() as u64;
        if (paths_seen, total_lines, total_step_ids) != (path_count, line_count, step_count) {
            return invalid(format!(
                "the decoded counts ({paths_seen} paths, {total_lines} lines, {total_step_ids} steps) \
                 disagree with the header ({path_count}, {line_count}, {step_count})"
            ));
        }
        for (path_id, by_line) in &by_path {
            let mut desc: Vec<usize> = by_line.keys().copied().collect();
            desc.sort_unstable_by(|a, b| b.cmp(a));
            lines_desc.insert(*path_id, desc);
        }

        Ok(StepMapNamespace {
            by_path,
            lines_desc,
            total_step_ids: total_step_ids as usize,
            min_step_id,
            max_step_id,
        })
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

    /// M0/3 — total number of step ids the table records, across every
    /// `(path, line)` entry.
    pub fn total_step_ids(&self) -> usize {
        self.total_step_ids
    }

    /// M0/3 — whether this table is a COMPLETE line index over `step_count`
    /// steps: it records exactly `step_count` ids, the smallest is `0` and the
    /// largest is `step_count - 1`.
    ///
    /// This is the precondition that makes [`Self::max_line_in_step_range`]
    /// EXACTLY equivalent to walking `steps.dat` and taking the maximum of
    /// `step.line` — every step is represented, so no step's line can be
    /// missing from the maximum. A table that fails this check (a partial
    /// index, a foreign table, a trace with marker steps the writer left out)
    /// is refused for range queries and the caller keeps its step-by-step scan,
    /// which is always correct.
    ///
    /// An empty table only "covers" an empty trace.
    pub fn covers_all_steps(&self, step_count: usize) -> bool {
        if self.total_step_ids == 0 {
            return step_count == 0;
        }
        self.total_step_ids == step_count && self.min_step_id == 0 && self.max_step_id == step_count as i64 - 1
    }

    /// M0/3 — the LINE-MAP accessor: the greatest source line carrying a step in
    /// the half-open step range `[start, end)`, across every path in the table.
    ///
    /// Returns `0` when the range holds no steps — `0` is the neutral element
    /// for a maximum over recorded lines, which are never negative (a step with
    /// no source line reconstructs to `Line(0)`).
    ///
    /// ## Why this replaces a scan
    ///
    /// `TraceReader::load_location` needs the greatest line over the SUFFIX of a
    /// call's step run. It used to get it by walking the run one step at a time,
    /// which is O(run length) point lookups into `steps.dat` — and on the
    /// browser path, where the tree-sitter arm is never taken, that walk ran on
    /// EVERY `load_location`.
    ///
    /// This answers the same question from the index instead. Lines are visited
    /// from the highest down and each is tested with a binary search over its
    /// ascending step-id list, so the walk stops at the first line that has a
    /// step in range: the cost is O(lines above the answer x log steps-per-line)
    /// per path, independent of the run's length.
    pub fn max_line_in_step_range(&self, start: StepId, end: StepId) -> usize {
        let mut best = 0usize;
        if end.0 <= start.0 {
            return best;
        }
        for (path_id, lines) in &self.lines_desc {
            let Some(by_line) = self.by_path.get(path_id) else {
                continue;
            };
            for &line in lines {
                // `lines` is descending, so once we reach a line that cannot beat
                // the running maximum no later line in this path can either.
                if line <= best {
                    break;
                }
                let Some(ids) = by_line.get(&line) else {
                    continue;
                };
                // The first id at-or-after `start`; the line is in range when
                // that id also falls before `end`.
                let at = ids.partition_point(|id| id.0 < start.0);
                if ids.get(at).is_some_and(|id| id.0 < end.0) {
                    best = line;
                    break;
                }
            }
        }
        best
    }

    /// Whether the table carries any line entry for `path_id`. The DAP
    /// "closest line" fallback uses this to decide whether the prepopulated
    /// table can answer for a path at all before scanning lines.
    pub fn has_path(&self, path_id: PathId) -> bool {
        self.by_path
            .get(&(path_id.0))
            .is_some_and(|by_line| !by_line.is_empty())
    }
}

fn write_varint(out: &mut Vec<u8>, mut value: u64) {
    while value >= 0x80 {
        out.push((value as u8) | 0x80);
        value >>= 7;
    }
    out.push(value as u8);
}

/// Serialize a `path_id → (line → step_ids)` map as a version 2 `step-map.ns`
/// member, byte for byte as `internal-files.md` §"`step-map.ns`" specifies.
/// This is the inverse of [`StepMapNamespace::parse`].
///
/// `entries` is consumed as `(path_id, line, step_ids)` triples; ids are
/// sorted, and lines and paths are written in ascending key order. Not
/// available on wasm32, which has a zstd decoder but no encoder.
#[cfg(not(target_arch = "wasm32"))]
pub fn serialize_step_map(entries: &[(PathId, usize, Vec<StepId>)]) -> Vec<u8> {
    let mut by_key: std::collections::BTreeMap<(u64, u32), Vec<i64>> = std::collections::BTreeMap::new();
    for (path_id, line, step_ids) in entries {
        let mut ids: Vec<i64> = step_ids.iter().map(|s| s.0).collect();
        ids.sort_unstable();
        by_key.insert((path_id.0 as u64, *line as u32), ids);
    }
    let path_count = by_key
        .keys()
        .map(|k| k.0)
        .collect::<std::collections::BTreeSet<_>>()
        .len();
    let step_count: usize = by_key.values().map(Vec::len).sum();

    let mut chunks: Vec<(u64, u32, Vec<u8>)> = Vec::new();
    let mut current: Option<(u64, u32, Vec<u8>)> = None;
    let mut previous = (0u64, 0u32);
    for (&(path, line), ids) in &by_key {
        let content = match current.as_mut() {
            Some((_, _, content)) => {
                let path_delta = path - previous.0;
                write_varint(content, path_delta);
                write_varint(
                    content,
                    if path_delta > 0 {
                        u64::from(line)
                    } else {
                        u64::from(line - previous.1)
                    },
                );
                content
            }
            None => {
                let (_, _, content) = current.insert((path, line, Vec::new()));
                write_varint(content, 0);
                write_varint(content, u64::from(line));
                content
            }
        };
        write_varint(content, ids.len() as u64);
        let mut previous_id = -1i64;
        let mut run: Option<(u64, u64)> = None;
        for &id in ids {
            let gap = (id - previous_id) as u64;
            previous_id = id;
            run = match run {
                Some((g, n)) if g == gap => Some((g, n + 1)),
                Some((g, n)) => {
                    write_varint(content, g);
                    write_varint(content, n);
                    Some((gap, 1))
                }
                None => Some((gap, 1)),
            };
        }
        if let Some((g, n)) = run {
            write_varint(content, g);
            write_varint(content, n);
        }
        previous = (path, line);
        if content.len() >= STEP_MAP_CHUNK_TARGET
            && let Some(done) = current.take()
        {
            chunks.push(done);
        }
    }
    if let Some(done) = current {
        chunks.push(done);
    }

    let frames: Vec<Vec<u8>> = chunks
        .iter()
        .map(
            |(_, _, content)| match zstd::bulk::compress(content, STEP_MAP_ZSTD_LEVEL) {
                Ok(frame) => frame,
                Err(e) => unreachable!("in-memory zstd compression cannot fail: {e}"),
            },
        )
        .collect();
    let mut out =
        Vec::with_capacity(HEADER_SIZE + chunks.len() * CHUNK_ENTRY_SIZE + frames.iter().map(Vec::len).sum::<usize>());
    out.extend_from_slice(&STEP_MAP_MAGIC.to_le_bytes());
    out.extend_from_slice(&STEP_MAP_VERSION.to_le_bytes());
    out.extend_from_slice(&(chunks.len() as u32).to_le_bytes());
    out.extend_from_slice(&(path_count as u32).to_le_bytes());
    out.extend_from_slice(&(by_key.len() as u32).to_le_bytes());
    out.extend_from_slice(&(step_count as u64).to_le_bytes());
    let mut offset = 0u64;
    for ((path, line, _), frame) in chunks.iter().zip(&frames) {
        out.extend_from_slice(&offset.to_le_bytes());
        out.extend_from_slice(&path.to_le_bytes());
        out.extend_from_slice(&line.to_le_bytes());
        offset += frame.len() as u64;
    }
    for frame in frames {
        out.extend_from_slice(&frame);
    }
    out
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
        // Lop off the end of the last frame — the parser must bail, not panic.
        blob.truncate(blob.len() - 4);
        assert!(StepMapNamespace::parse(&blob).is_err());
    }

    #[test]
    fn empty_table_round_trips() {
        let blob = serialize_step_map(&[]);
        let ns = StepMapNamespace::parse(&blob).expect("empty table parses");
        assert_eq!(ns.entry_count(), 0);
        assert!(ns.step_ids_on_line(PathId(0), 1).is_none());
    }

    // ── Version 2 (internal-files.md §"`step-map.ns`") ───────────────────

    fn varint(out: &mut Vec<u8>, mut v: u64) {
        while v >= 0x80 {
            out.push((v as u8) | 0x80);
            v >>= 7;
        }
        out.push(v as u8);
    }

    /// A version 2 member assembled from the specification: the header
    /// counts, one chunk-table entry per `(first_path, first_line, content)`,
    /// and each content compressed as one zstd frame.
    fn v2_member(counts: (u32, u32, u64), chunks: &[(u64, u32, Vec<u8>)]) -> Vec<u8> {
        let frames: Vec<Vec<u8>> = chunks.iter().map(|c| zstd::bulk::compress(&c.2, 3).unwrap()).collect();
        let mut out = Vec::new();
        out.extend_from_slice(&0x5354_4D50u32.to_le_bytes());
        out.extend_from_slice(&2u16.to_le_bytes());
        out.extend_from_slice(&(chunks.len() as u32).to_le_bytes());
        out.extend_from_slice(&counts.0.to_le_bytes());
        out.extend_from_slice(&counts.1.to_le_bytes());
        out.extend_from_slice(&counts.2.to_le_bytes());
        let mut off = 0u64;
        for (c, f) in chunks.iter().zip(&frames) {
            out.extend_from_slice(&off.to_le_bytes());
            out.extend_from_slice(&c.0.to_le_bytes());
            out.extend_from_slice(&c.1.to_le_bytes());
            off += f.len() as u64;
        }
        for f in frames {
            out.extend_from_slice(&f);
        }
        out
    }

    /// The specification's own example: one line, ids 0, 2, 4, 6, 7 -- the
    /// first gap counts from -1, and runs are maximal.
    const EXAMPLE_RECORD: [u8; 9] = [0, 3, 5, 1, 1, 2, 3, 1, 1];

    #[test]
    fn a_version_2_member_from_the_specification_is_read() {
        let blob = v2_member((1, 1, 5), &[(0, 3, EXAMPLE_RECORD.to_vec())]);
        let ns = StepMapNamespace::parse(&blob).expect("a version 2 member must parse");
        assert_eq!(
            ns.step_ids_on_line(PathId(0), 3),
            Some(&vec![StepId(0), StepId(2), StepId(4), StepId(6), StepId(7)])
        );
        assert_eq!(ns.entry_count(), 1);
        assert_eq!(ns.total_step_ids(), 5);
    }

    /// Keys are delta-coded within a chunk: a path delta restates the line, a
    /// zero path delta adds to it; and a chunk's first record restates its key.
    #[test]
    fn keys_are_delta_coded_within_a_chunk_and_restated_at_its_start() {
        let mut c0 = Vec::new();
        // (2, 10): ids 5   then (2, 12): ids 1, 3   then (5, 4): id 9
        c0.extend_from_slice(&[0, 10, 1, 6, 1]);
        c0.extend_from_slice(&[0, 2, 2, 2, 1, 2, 1]);
        c0.extend_from_slice(&[3, 4, 1, 10, 1]);
        let mut c1 = Vec::new();
        // (5, 7): ids 100..=102
        c1.extend_from_slice(&[0, 7, 3]);
        varint(&mut c1, 101);
        c1.extend_from_slice(&[1, 1, 2]);
        let blob = v2_member((2, 4, 7), &[(2, 10, c0), (5, 7, c1)]);
        let ns = StepMapNamespace::parse(&blob).expect("parse");
        assert_eq!(ns.step_ids_on_line(PathId(2), 10), Some(&vec![StepId(5)]));
        assert_eq!(ns.step_ids_on_line(PathId(2), 12), Some(&vec![StepId(1), StepId(3)]));
        assert_eq!(ns.step_ids_on_line(PathId(5), 4), Some(&vec![StepId(9)]));
        assert_eq!(
            ns.step_ids_on_line(PathId(5), 7),
            Some(&vec![StepId(100), StepId(101), StepId(102)])
        );
    }

    #[test]
    fn an_empty_map_is_the_26_byte_header() {
        let blob = serialize_step_map(&[]);
        assert_eq!(blob.len(), 26);
        assert_eq!(&blob[4..6], &2u16.to_le_bytes());
        assert!(blob[6..].iter().all(|&b| b == 0), "every count of an empty map is 0");
        let ns = StepMapNamespace::parse(&blob).expect("empty map parses");
        assert_eq!(ns.entry_count(), 0);
    }

    /// The serializer writes the specified bytes: the example record above is
    /// the content of its one chunk.
    #[test]
    fn the_serializer_writes_version_2() {
        let blob = serialize_step_map(&[(
            PathId(0),
            3,
            vec![StepId(0), StepId(2), StepId(4), StepId(6), StepId(7)],
        )]);
        assert_eq!(blob, v2_member((1, 1, 5), &[(0, 3, EXAMPLE_RECORD.to_vec())]));
    }

    /// A chunk closes after the record that brings its content to 65,536
    /// bytes or more, and the next record restates its key in a new chunk.
    #[test]
    fn the_serializer_closes_a_chunk_at_the_target() {
        // Each line holds 20,000 ids spaced 3 then 4 apart alternately: no two
        // adjacent runs share a gap, so its content is about 40 KB.
        let lines: Vec<(PathId, usize, Vec<StepId>)> = (0..4)
            .map(|l| {
                let mut id = l as i64;
                let ids = (0..20_000)
                    .map(|k| {
                        let here = id;
                        id += if k % 2 == 0 { 30 } else { 40 };
                        StepId(here)
                    })
                    .collect();
                (PathId(1), 10 + l, ids)
            })
            .collect();
        let blob = serialize_step_map(&lines);
        let chunk_count = u32::from_le_bytes(blob[6..10].try_into().unwrap());
        assert_eq!(
            chunk_count, 2,
            "two ~40 KB records reach the target, so four make two chunks"
        );
        let second_first_line = u32::from_le_bytes(blob[26 + 20 + 16..26 + 20 + 20].try_into().unwrap());
        assert_eq!(second_first_line, 12, "the second chunk opens at the third line");
        let ns = StepMapNamespace::parse(&blob).expect("parse");
        for (path, line, ids) in &lines {
            assert_eq!(ns.step_ids_on_line(*path, *line), Some(ids));
        }
    }

    fn refused(blob: &[u8], what: &str) -> String {
        let err = StepMapNamespace::parse(blob).expect_err(what).to_string();
        assert!(
            err.contains("step-map.ns"),
            "{what}: the refusal does not name the member: {err}"
        );
        err
    }

    /// Each malformation `internal-files.md` names is refused: every one is a
    /// map that would answer some breakpoint with the wrong steps.
    #[test]
    fn a_malformed_version_2_member_is_refused() {
        let good = || vec![(0u64, 3u32, EXAMPLE_RECORD.to_vec())];
        refused(&v2_member((1, 1, 6), &good()), "a step count that disagrees");
        refused(&v2_member((1, 2, 5), &good()), "a line count that disagrees");
        refused(&v2_member((2, 1, 5), &good()), "a path count that disagrees");
        refused(
            &v2_member((1, 1, 5), &[(0, 4, EXAMPLE_RECORD.to_vec())]),
            "a table key that is not the first record's",
        );
        refused(
            &v2_member((1, 1, 5), &[(0, 3, vec![1, 3, 5, 1, 1, 2, 3, 1, 1])]),
            "a chunk's first record with a path delta",
        );
        refused(
            &v2_member((1, 2, 2), &[(0, 3, vec![0, 3, 1, 1, 1, 0, 0, 1, 1, 1])]),
            "a repeated key",
        );
        refused(&v2_member((1, 1, 0), &[(0, 3, vec![0, 3, 0])]), "a count of 0");
        refused(&v2_member((1, 1, 1), &[(0, 3, vec![0, 3, 1, 0, 1])]), "a gap of 0");
        refused(&v2_member((1, 1, 1), &[(0, 3, vec![0, 3, 1, 1, 0])]), "a repeat of 0");
        refused(
            &v2_member((1, 1, 2), &[(0, 3, vec![0, 3, 2, 1, 3])]),
            "runs that overshoot the count",
        );
        refused(
            &v2_member((1, 1, 5), &[(0, 3, EXAMPLE_RECORD[..7].to_vec())]),
            "a record cut short",
        );
        refused(
            &v2_member((1, 2, 2), &[(0, 9, vec![0, 9, 1, 1, 1]), (0, 3, vec![0, 3, 1, 3, 1])]),
            "chunks out of key order",
        );

        // A frame whose declared content size is not what it decodes to.
        let mut blob = v2_member((1, 1, 5), &good());
        let frame_start = 26 + 20;
        let fhd = blob[frame_start + 4];
        assert_eq!(fhd >> 6, 0, "the fixture's frame declares its size in one byte");
        assert_ne!(fhd & 0x20, 0, "the fixture's frame is single-segment");
        blob[frame_start + 5] += 1;
        refused(&blob, "a frame that does not decode to its declared size");
    }

    /// Version 1 is refused by its version, naming it.
    #[test]
    fn a_version_1_member_is_refused_by_version() {
        let mut blob = serialize_step_map(&[(PathId(0), 1, vec![StepId(0)])]);
        blob[4..6].copy_from_slice(&1u16.to_le_bytes());
        let err = StepMapNamespace::parse(&blob).unwrap_err();
        assert_eq!(err, StepMapError::UnsupportedVersion(1));
        assert!(err.to_string().contains("version 1"), "{err}");
    }
}
