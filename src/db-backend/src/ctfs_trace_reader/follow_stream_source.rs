//! Follow-mode split-stream readers over a growing `.ct` (M1a + M1b).
//!
//! This is the real-product live-tail path the
//! [`Seek-Based-CTFS-Reader`](../../../../../codetracer-specs/Trace-Files/Seek-Based-CTFS-Reader.md)
//! §5.6 design calls for: *one* decode pipeline reading the *same* split streams
//! (`steps.dat` / `values.dat` / `calls.dat` plus their companion `.idx` files)
//! as the final-file case, parameterised by a [`BlockSource`] plus a follow flag,
//! instead of the separate legacy `events.log`-tailing `StreamingCtfsReader`.
//!
//! ## Generalised chunk-table-extension core (M1b, §7)
//!
//! The M1a milestone landed [`FollowStepStreamSource`]: a follow reader over a
//! growing `steps.dat` / `steps.idx` that re-reads `steps.dat`'s committed
//! `FileEntry.Size`, re-parses the grown index, and decodes only the
//! newly-bounded chunks on [`refresh`](FollowStepStreamSource::refresh). M1b
//! generalises that "re-read the companion `.idx`, extend the chunk-offset table,
//! and decode only the appended chunks as `FileEntry.Size` grows" mechanism —
//! the design's §7 *chunk-header table extension* — into a reusable
//! [`ChunkFollowState`] core, and reuses it for the VALUE (`values.dat`) and CALL
//! (`calls.dat`) streams via [`FollowValueStreamSource`] and
//! [`FollowCallStreamSource`]. [`FollowReader`] ties the three together so an
//! open follow reader picks up steps, values, and calls appended after open.
//!
//! Each per-stream follow source drives the EXACT production seekable decode
//! (`decode_chunk_records` from `codetracer_trace_reader::{step,value,call}_stream_reader`,
//! all now `pub`) so the follow path and the final-file seekable path can never
//! diverge.
//!
//! ## Why a focused follow reader rather than `follow` on `CTFSTraceReader::open`
//!
//! The PRODUCTION new-format reader ([`super::CTFSTraceReader::open`]) routes
//! split-only bundles through the Nim FFI reader
//! ([`super::CTFSTraceReader::open_new_format_nim`]), which opens an opaque Nim
//! `NewTraceReader` handle that snapshots the whole stream at open and exposes no
//! growth/refresh API. Threading `follow` through that FFI handle is a large,
//! separate piece of work (it needs a Nim-side reader-protocol refresh). Rather
//! than ship a half-working `CTFSTraceReader::follow` flag over the FFI handle,
//! M1b lands the follow capability over the SPLIT STREAMS THE RUST SIDE CONTROLS:
//! the unified [`FollowReader`] over a [`FollowFileSource`], driving the same
//! Rust seekable decode the final-file path uses. See the M1 milestone's
//! Outstanding Tasks for the remaining Nim-FFI follow wiring.

use std::path::{Path, PathBuf};

use codetracer_trace_reader::call_stream_reader::decode_chunk_records as decode_call_chunk_records;
use codetracer_trace_reader::step_stream_reader::decode_chunk_records as decode_step_chunk_records;
use codetracer_trace_reader::value_stream_reader::decode_chunk_records as decode_value_chunk_records;
use codetracer_trace_types::{Line, PathId};
use codetracer_trace_writer::call_stream::CallStreamRecord;
use codetracer_trace_writer::meta_dat::{
    meta_dat_has_call_stream, meta_dat_has_step_stream, meta_dat_has_value_stream,
};
use codetracer_trace_writer::step_stream::{unpack_global_line_index, StepStreamRecord};
use codetracer_trace_writer::value_stream::ValueRecordEntry;

use super::call_stream_source::call_stream_record_to_db_call;
use super::ctfs_container::{BlockSource, CtfsError, FollowFileSource};
use super::step_value_stream_source::step_values_to_full_records;
use crate::db::DbCall;
use codetracer_trace_types::FullValueRecord;

/// The `(path_id, line)` source location of a single step, decoded from the
/// follow-tailed execution stream.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FollowStep {
    pub path_id: PathId,
    pub line: Line,
}

// ───────────────────────────────────────────────────────────────────────────
// Generalised chunk-follow core (§7 "chunk-header table extension").
//
// Every split stream (`steps.dat` / `values.dat` / `calls.dat`) shares the same
// streaming layout: a `<name>.dat` of length-prefixed records grouped into
// compressed chunks, and a companion `<name>.idx` of
// `[chunk_size: u32 LE][offset_0: u64 LE]...`. The writer commits a chunk's
// index offset BEFORE the chunk data (CTFS-Binary-Format.md §7), so the LAST
// indexed chunk's data may still be landing; a follow reader must defer it until
// either a successor offset bounds it or the trace is finalized.
//
// `ChunkFollowState` owns exactly that protocol — index re-parse, chunk-table
// extension, and the trailing-chunk deferral — independent of WHAT a chunk
// decodes into. A per-stream source supplies the index/data file names and a
// chunk-decode closure; the core decides WHICH chunk ranges are now committed.
// ───────────────────────────────────────────────────────────────────────────

/// The growth-tracking state shared by every follow-mode split stream.
///
/// Tracks the parsed `<name>.idx` chunk-offset table (extended, never shrunk, on
/// each refresh) and how many of those chunks have already been decoded, applying
/// the index-offset-before-chunk-data deferral protocol so a poller sees early
/// chunks mid-recording and the trailing chunk on finalize.
#[derive(Debug)]
struct ChunkFollowState {
    /// The `.dat` file name within the container (e.g. `steps.dat`).
    dat_name: String,
    /// The companion `.idx` file name within the container (e.g. `steps.idx`).
    idx_name: String,
    /// Records-per-chunk seek granularity, parsed once from the `.idx` header.
    /// `None` until the 4-byte header has been committed.
    chunk_size: Option<usize>,
    /// Byte offsets into `<name>.dat` for each chunk start, parsed from
    /// `<name>.idx`. Grows as the writer appends offsets.
    chunk_offsets: Vec<u64>,
    /// Number of `<name>.dat` chunks already fully decoded.
    decoded_chunks: usize,
}

impl ChunkFollowState {
    fn new(dat_name: &str, idx_name: &str) -> Self {
        ChunkFollowState {
            dat_name: dat_name.to_string(),
            idx_name: idx_name.to_string(),
            chunk_size: None,
            chunk_offsets: Vec::new(),
            decoded_chunks: 0,
        }
    }

    /// Parse the `<name>.idx` (`[chunk_size: u32 LE][offset: u64 LE]...`) into the
    /// chunk-size + offset table. Only ever EXTENDS the table — a shrinking index
    /// would be a writer bug, so we keep the longest table we have seen.
    fn parse_index(&mut self, idx: &[u8]) {
        if idx.len() < 4 {
            return;
        }
        if self.chunk_size.is_none() {
            let cs = u32::from_le_bytes([idx[0], idx[1], idx[2], idx[3]]) as usize;
            if cs > 0 {
                self.chunk_size = Some(cs);
            }
        }
        let mut offsets = Vec::new();
        let mut pos = 4usize;
        while pos + 8 <= idx.len() {
            offsets.push(u64::from_le_bytes([
                idx[pos],
                idx[pos + 1],
                idx[pos + 2],
                idx[pos + 3],
                idx[pos + 4],
                idx[pos + 5],
                idx[pos + 6],
                idx[pos + 7],
            ]));
            pos += 8;
        }
        if offsets.len() > self.chunk_offsets.len() {
            self.chunk_offsets = offsets;
        }
    }

    /// Decode every chunk that has not yet been decoded AND whose data range is
    /// fully backed by committed `<name>.dat` bytes, feeding each decoded chunk's
    /// records to `decode_chunk` and counting how many leaf records were produced.
    ///
    /// A chunk `c` spans `[chunk_offsets[c], chunk_offsets[c+1])` — or
    /// `[chunk_offsets[last], dat_size)` for the final chunk, but only once
    /// finalized (mid-recording the last chunk's bytes may still be landing). The
    /// writer records a chunk's index offset BEFORE the chunk bytes, so the LAST
    /// indexed chunk is deferred until a successor offset bounds it or the
    /// recording is finalized.
    ///
    /// `read_range(start, len)` reads `len` bytes at logical `start` within the
    /// `.dat` file. `apply(chunk_index, &chunk_bytes) -> count` decodes the
    /// chunk and records its records into the owning source, returning the number
    /// of leaf records produced. Returns the total newly-produced record count.
    fn decode_committed_chunks(
        &mut self,
        dat_size: u64,
        finalized: bool,
        mut read_range: impl FnMut(&str, u64, usize) -> Result<Vec<u8>, CtfsError>,
        mut apply: impl FnMut(usize, &[u8]) -> Result<usize, CtfsError>,
    ) -> Result<usize, CtfsError> {
        let mut newly = 0usize;
        while self.decoded_chunks < self.chunk_offsets.len() {
            let c = self.decoded_chunks;
            let start = self.chunk_offsets[c];
            let end = if c + 1 < self.chunk_offsets.len() {
                self.chunk_offsets[c + 1]
            } else if finalized {
                dat_size
            } else {
                // Last indexed chunk on an in-progress recording: its end is not
                // yet bounded by a successor offset, so leave it for a later
                // refresh (when either a new offset or finalization arrives).
                break;
            };

            if end > dat_size || start > end {
                // The chunk's data isn't fully committed yet — wait.
                break;
            }

            let chunk = read_range(&self.dat_name, start, (end - start) as usize)?;
            newly += apply(c, &chunk)?;
            self.decoded_chunks += 1;
        }
        Ok(newly)
    }
}

/// Read `len` bytes at logical `offset` within a named internal file through a
/// follow source, walking the container's block mapping via a short-lived
/// [`super::ctfs_container::CtfsReader`] over the SAME growing file.
///
/// We re-open a `CtfsReader` per call (cheap: it parses only Block 0 via
/// positional reads, never the whole container) so the mapping walk always
/// reflects the latest committed Block 0 — the directory and mapping blocks a
/// live writer has flushed. A read into a not-yet-committed region surfaces as a
/// `Corrupt` error rather than reading stale bytes.
///
/// Shared by all three per-stream follow sources (the read primitive is
/// identical regardless of which `.dat` file is being tailed).
fn read_internal_file_range(path: &Path, name: &str, offset: u64, len: usize) -> Result<Vec<u8>, CtfsError> {
    let mut reader = super::ctfs_container::CtfsReader::open_follow(path)?;
    let whole = reader.read_file(name)?;
    let start = offset as usize;
    let end = start
        .checked_add(len)
        .ok_or_else(|| CtfsError::Corrupt("follow read range overflow".to_string()))?;
    if end > whole.len() {
        return Err(CtfsError::Corrupt(format!(
            "follow read of '{name}' [{start}..{end}) extends beyond committed size ({})",
            whole.len()
        )));
    }
    Ok(whole[start..end].to_vec())
}

/// Whether a follow source's `meta.dat` is committed AND a capability-flag
/// predicate holds. Used to honor a finalized container's capability flags (a
/// sealed container that does not advertise a given stream must read nothing).
fn meta_flag_set(source: &FollowFileSource, path: &Path, predicate: impl Fn(&[u8]) -> bool) -> bool {
    let meta_size = source.file_size("meta.dat").unwrap_or(0);
    if meta_size == 0 {
        return false;
    }
    match read_internal_file_range(path, "meta.dat", 0, meta_size as usize) {
        Ok(meta) => predicate(&meta),
        Err(_) => false,
    }
}

/// A follow-mode reader over a growing container's `steps.dat` / `steps.idx`
/// split execution stream.
///
/// Holds a [`FollowFileSource`] (its own positional read + Block 0 re-read) and
/// the latest-known `steps.idx` chunk table. [`Self::refresh`] re-reads
/// `steps.dat`'s committed `FileEntry.Size`, re-parses any newly-appended index
/// offsets, and decodes the chunks that have become fully committed — so the
/// step count grows monotonically as the recorder flushes chunks, and the reader
/// surfaces appended steps **before** finalization.
#[derive(Debug)]
pub struct FollowStepStreamSource {
    source: FollowFileSource,
    follow: ChunkFollowState,
    /// Fully-decoded steps from every committed chunk, in order. Append-only.
    steps: Vec<FollowStep>,
    /// `path` of the container, retained for diagnostics / per-call re-open.
    path: PathBuf,
}

impl FollowStepStreamSource {
    /// Open a growing `.ct` for follow-mode split-stream STEP reads.
    ///
    /// Requires the container to advertise the `has_step_stream` capability bit
    /// in `meta.dat` — but tolerates `meta.dat` being absent at open (a live
    /// recorder commits it last), in which case the gate is re-checked on each
    /// [`Self::refresh`]. An initial refresh decodes whatever chunks are already
    /// committed.
    pub fn open(path: &Path) -> Result<Self, CtfsError> {
        let source = FollowFileSource::open(path)?;
        let mut reader = FollowStepStreamSource {
            source,
            follow: ChunkFollowState::new("steps.dat", "steps.idx"),
            steps: Vec::new(),
            path: path.to_path_buf(),
        };
        reader.refresh()?;
        Ok(reader)
    }

    /// Number of fully-decoded steps observed so far. Grows monotonically across
    /// [`Self::refresh`] calls as the recorder flushes chunks.
    pub fn step_count(&self) -> usize {
        self.steps.len()
    }

    /// The decoded source location of step `index`, or `None` if not yet observed
    /// (or if that record carries no source line — a `Raise`/`Catch`/`ThreadSwitch`
    /// marker).
    pub fn step(&self, index: usize) -> Option<FollowStep> {
        self.steps.get(index).copied()
    }

    /// All steps decoded so far, in order.
    pub fn steps(&self) -> &[FollowStep] {
        &self.steps
    }

    /// `true` once the container is sealed (`meta.dat` / `meta.json` committed
    /// non-empty).
    pub fn is_finalized(&self) -> bool {
        self.source.is_finalized()
    }

    /// Re-observe the growing container and decode any newly-committed `steps.dat`
    /// chunks. Returns the number of NEWLY-decoded steps this refresh produced.
    pub fn refresh(&mut self) -> Result<usize, CtfsError> {
        self.source.refresh()?;

        // Gate on the step stream's READABILITY (a `steps.idx` with a committed
        // header), not on `meta.dat` (committed LAST). Once `meta.dat` HAS landed
        // we additionally honor its `has_step_stream` flag: a finalized container
        // that explicitly does NOT advertise the step stream must read nothing.
        if self.source.file_size("meta.dat").unwrap_or(0) > 0
            && !meta_flag_set(&self.source, &self.path, meta_dat_has_step_stream)
        {
            return Ok(0);
        }

        let idx_size = self.source.file_size("steps.idx").unwrap_or(0);
        if idx_size < 4 {
            return Ok(0);
        }
        let idx_bytes = read_internal_file_range(&self.path, "steps.idx", 0, idx_size as usize)?;
        self.follow.parse_index(&idx_bytes);

        let before = self.steps.len();
        let dat_size = self.source.file_size("steps.dat").unwrap_or(0);
        let finalized = self.source.is_finalized();
        let path = self.path.clone();
        let steps = &mut self.steps;
        self.follow.decode_committed_chunks(
            dat_size,
            finalized,
            |name, start, len| read_internal_file_range(&path, name, start, len),
            |c, chunk| {
                let decoded = decode_step_chunk(chunk)
                    .map_err(|e| CtfsError::Corrupt(format!("follow steps.dat chunk {c} ({}): {e}", path.display())))?;
                let n = decoded.len();
                steps.extend(decoded);
                Ok(n)
            },
        )?;
        Ok(self.steps.len() - before)
    }
}

/// A follow-mode reader over a growing container's `values.dat` / `values.idx`
/// parallel value stream (M1b).
///
/// Mirrors [`FollowStepStreamSource`] but for the per-step VALUE records: value
/// record `N` ↔ step `N`. [`Self::refresh`] surfaces appended value records
/// before finalization, decoding each committed chunk through the production
/// `values.dat` decode path.
#[derive(Debug)]
pub struct FollowValueStreamSource {
    source: FollowFileSource,
    follow: ChunkFollowState,
    /// Fully-decoded per-step value records, in order. Append-only.
    records: Vec<ValueRecordEntry>,
    path: PathBuf,
}

impl FollowValueStreamSource {
    /// Open a growing `.ct` for follow-mode split-stream VALUE reads. Tolerates a
    /// not-yet-committed `meta.dat`; re-checks the `has_value_stream` flag on each
    /// refresh once `meta.dat` lands.
    pub fn open(path: &Path) -> Result<Self, CtfsError> {
        let source = FollowFileSource::open(path)?;
        let mut reader = FollowValueStreamSource {
            source,
            follow: ChunkFollowState::new("values.dat", "values.idx"),
            records: Vec::new(),
            path: path.to_path_buf(),
        };
        reader.refresh()?;
        Ok(reader)
    }

    /// Number of per-step value records observed so far.
    pub fn value_count(&self) -> usize {
        self.records.len()
    }

    /// The reconstructed `FullValueRecord`s visible at step `index`, byte-identical
    /// to the materialized `db.variables[index]`, or `None` if not yet observed.
    pub fn variables_at(&self, index: usize) -> Option<Vec<FullValueRecord>> {
        self.records.get(index).map(|r| step_values_to_full_records(&r.events))
    }

    /// `true` once the container is sealed.
    pub fn is_finalized(&self) -> bool {
        self.source.is_finalized()
    }

    /// Re-observe the growing container and decode any newly-committed
    /// `values.dat` chunks. Returns the number of NEWLY-decoded value records.
    pub fn refresh(&mut self) -> Result<usize, CtfsError> {
        self.source.refresh()?;

        if self.source.file_size("meta.dat").unwrap_or(0) > 0
            && !meta_flag_set(&self.source, &self.path, meta_dat_has_value_stream)
        {
            return Ok(0);
        }

        let idx_size = self.source.file_size("values.idx").unwrap_or(0);
        if idx_size < 4 {
            return Ok(0);
        }
        let idx_bytes = read_internal_file_range(&self.path, "values.idx", 0, idx_size as usize)?;
        self.follow.parse_index(&idx_bytes);

        let before = self.records.len();
        let dat_size = self.source.file_size("values.dat").unwrap_or(0);
        let finalized = self.source.is_finalized();
        let path = self.path.clone();
        let records = &mut self.records;
        self.follow.decode_committed_chunks(
            dat_size,
            finalized,
            |name, start, len| read_internal_file_range(&path, name, start, len),
            |c, chunk| {
                let decoded = decode_value_chunk_records(chunk)
                    .map_err(|e| CtfsError::Corrupt(format!("follow values.dat chunk {c} ({}): {e}", path.display())))?;
                let n = decoded.len();
                records.extend(decoded);
                Ok(n)
            },
        )?;
        Ok(self.records.len() - before)
    }
}

/// A follow-mode reader over a growing container's `calls.dat` / `calls.idx`
/// call-tree stream (M1b).
///
/// Mirrors [`FollowStepStreamSource`] but for CALL records. [`Self::refresh`]
/// surfaces appended call records before finalization, decoding each committed
/// chunk through the production `calls.dat` decode path and converting to
/// [`DbCall`] via the shared [`call_stream_record_to_db_call`] mapping (so the
/// follow path and the final-file seekable path build identical calls).
#[derive(Debug)]
pub struct FollowCallStreamSource {
    source: FollowFileSource,
    follow: ChunkFollowState,
    /// Fully-decoded call records, in `call_key` order. Append-only.
    calls: Vec<DbCall>,
    path: PathBuf,
}

impl FollowCallStreamSource {
    /// Open a growing `.ct` for follow-mode split-stream CALL reads. Tolerates a
    /// not-yet-committed `meta.dat`; re-checks the `has_call_stream` flag on each
    /// refresh once `meta.dat` lands.
    pub fn open(path: &Path) -> Result<Self, CtfsError> {
        let source = FollowFileSource::open(path)?;
        let mut reader = FollowCallStreamSource {
            source,
            follow: ChunkFollowState::new("calls.dat", "calls.idx"),
            calls: Vec::new(),
            path: path.to_path_buf(),
        };
        reader.refresh()?;
        Ok(reader)
    }

    /// Number of call records observed so far.
    pub fn call_count(&self) -> usize {
        self.calls.len()
    }

    /// The decoded call with `call_key == index`, or `None` if not yet observed.
    pub fn call(&self, index: usize) -> Option<&DbCall> {
        self.calls.get(index)
    }

    /// All calls decoded so far, in `call_key` order.
    pub fn calls(&self) -> &[DbCall] {
        &self.calls
    }

    /// `true` once the container is sealed.
    pub fn is_finalized(&self) -> bool {
        self.source.is_finalized()
    }

    /// Re-observe the growing container and decode any newly-committed
    /// `calls.dat` chunks. Returns the number of NEWLY-decoded call records.
    pub fn refresh(&mut self) -> Result<usize, CtfsError> {
        self.source.refresh()?;

        if self.source.file_size("meta.dat").unwrap_or(0) > 0
            && !meta_flag_set(&self.source, &self.path, meta_dat_has_call_stream)
        {
            return Ok(0);
        }

        let idx_size = self.source.file_size("calls.idx").unwrap_or(0);
        if idx_size < 4 {
            return Ok(0);
        }
        let idx_bytes = read_internal_file_range(&self.path, "calls.idx", 0, idx_size as usize)?;
        self.follow.parse_index(&idx_bytes);

        let before = self.calls.len();
        let dat_size = self.source.file_size("calls.dat").unwrap_or(0);
        let finalized = self.source.is_finalized();
        let chunk_size = self.follow.chunk_size.unwrap_or(0).max(1);
        let path = self.path.clone();
        let calls = &mut self.calls;
        self.follow.decode_committed_chunks(
            dat_size,
            finalized,
            |name, start, len| read_internal_file_range(&path, name, start, len),
            |c, chunk| {
                // A call record's `call_key` is its global position, which the
                // chunk decode does not carry inline: chunk `c` holds records
                // `[c * chunk_size, c * chunk_size + within]`. (`c` is the GLOBAL
                // chunk index, so the base is `c * chunk_size` regardless of how
                // many chunks were already decoded on a prior refresh.)
                let raw_records = decode_call_chunk_records(chunk)
                    .map_err(|e| CtfsError::Corrupt(format!("follow calls.dat chunk {c} ({}): {e}", path.display())))?;
                let n = raw_records.len();
                let base_key = c * chunk_size;
                for (within, raw) in raw_records.iter().enumerate() {
                    let call_key = (base_key + within) as u64;
                    let record = CallStreamRecord::decode(call_key, raw).map_err(|e| {
                        CtfsError::Corrupt(format!("follow calls.dat record {call_key} ({}): {e}", path.display()))
                    })?;
                    calls.push(call_stream_record_to_db_call(&record));
                }
                Ok(n)
            },
        )?;
        Ok(self.calls.len() - before)
    }
}

/// The UNIFIED follow-mode reader over the split streams the Rust side controls
/// (M1b).
///
/// Bundles a [`FollowStepStreamSource`], [`FollowValueStreamSource`], and
/// [`FollowCallStreamSource`] over the SAME growing `.ct` so that a single
/// [`Self::refresh`] picks up steps, values, AND calls appended after open. This
/// is the follow-capable Rust open path the §5.6 design calls for: live/streaming
/// replay over a [`FollowFileSource`] driving the same Rust seekable decode the
/// final-file path uses, for the split streams the Rust reader owns.
///
/// A stream that the container does not (yet) carry simply stays empty — its
/// gate (the companion `.idx` header, plus a finalized container's capability
/// flag) keeps it at zero records — so a steps-only bundle still works.
#[derive(Debug)]
pub struct FollowReader {
    steps: FollowStepStreamSource,
    values: FollowValueStreamSource,
    calls: FollowCallStreamSource,
}

impl FollowReader {
    /// Open a growing `.ct` for unified follow-mode reads across the steps,
    /// values, and calls split streams.
    pub fn open(path: &Path) -> Result<Self, CtfsError> {
        Ok(FollowReader {
            steps: FollowStepStreamSource::open(path)?,
            values: FollowValueStreamSource::open(path)?,
            calls: FollowCallStreamSource::open(path)?,
        })
    }

    /// Re-observe the growing container across all three streams. Returns the
    /// per-stream count of NEWLY-decoded records as `(steps, values, calls)`.
    pub fn refresh(&mut self) -> Result<(usize, usize, usize), CtfsError> {
        let s = self.steps.refresh()?;
        let v = self.values.refresh()?;
        let c = self.calls.refresh()?;
        Ok((s, v, c))
    }

    /// `true` once the container is sealed (any of the per-stream sources observe
    /// the finalization meta; they share the same backing file so all agree).
    pub fn is_finalized(&self) -> bool {
        self.steps.is_finalized()
    }

    /// Borrow the follow STEP source.
    pub fn steps(&self) -> &FollowStepStreamSource {
        &self.steps
    }

    /// Borrow the follow VALUE source.
    pub fn values(&self) -> &FollowValueStreamSource {
        &self.values
    }

    /// Borrow the follow CALL source.
    pub fn calls(&self) -> &FollowCallStreamSource {
        &self.calls
    }
}

/// Decode every step record in one committed `steps.dat` chunk into
/// `(path_id, line)` locations, dropping non-`Step` records (markers carry no
/// line). Delegates the wire-format decode to the seekable reader's
/// [`decode_step_chunk_records`] so the follow path and the final-file path can
/// never diverge.
fn decode_step_chunk(compressed: &[u8]) -> Result<Vec<FollowStep>, String> {
    let records = decode_step_chunk_records(compressed)?;
    let mut out = Vec::new();
    for rec in records {
        if let StepStreamRecord::Step { global_line_index } = rec {
            let (path_id, line) = unpack_global_line_index(global_line_index);
            out.push(FollowStep {
                path_id: PathId(path_id),
                line: Line(line),
            });
        }
    }
    Ok(out)
}
