//! Follow-mode split-stream reader over a growing `.ct` (M1).
//!
//! This is the real-product live-tail path the
//! [`Seek-Based-CTFS-Reader`](../../../../../codetracer-specs/Trace-Files/Seek-Based-CTFS-Reader.md)
//! §5.6 design calls for: *one* decode pipeline reading the *same* split streams
//! (`steps.dat` + its companion `steps.idx`) as the final-file case, parameterised
//! by a [`BlockSource`] plus a follow flag, instead of the separate legacy
//! `events.log`-tailing `StreamingCtfsReader`.
//!
//! ## Why a focused follow reader (M1a) rather than `follow` on `CTFSTraceReader`
//!
//! The production new-format reader ([`super::CTFSTraceReader::open`]) and the
//! M22/M24c seekable split-stream readers (`StepStreamReader` / `ValueStreamReader`
//! / `SeekableCallStream`) all **snapshot the whole `dat` buffer and the whole
//! companion index at open** and assume the file has reached its final size.
//! Making *those* readers observe growth in place — extending the chunk-offset
//! table and decoding only the appended chunks as `FileEntry.Size` grows — is the
//! §7 "chunk-header table extension" work the design groups with the lazy/seekable
//! overlay milestone (M2+). It is deliberately **not** landed here, so we never
//! ship a half-working `CTFSTraceReader::follow` flag (see the M1 milestone's
//! Outstanding Tasks: M1b).
//!
//! What M1a lands is the cleanly-achievable, fully-honest piece: a follow reader
//! that drives the **real split-stream decode** (`decode_record` from
//! `codetracer_trace_writer::step_stream`, the exact wire format the seekable
//! readers use) over a [`FollowFileSource`], re-reading `steps.dat`'s
//! `FileEntry.Size` and re-parsing the grown `steps.idx` on [`Self::refresh`] so
//! that **split-stream step records appended after open become visible before the
//! recording is finalized**. This proves the unified follow-source approach
//! end-to-end against a real growing split-stream container.

use std::path::{Path, PathBuf};

use codetracer_trace_reader::step_stream_reader::decode_chunk_records;
use codetracer_trace_types::{Line, PathId};
use codetracer_trace_writer::meta_dat::meta_dat_has_step_stream;
use codetracer_trace_writer::step_stream::{unpack_global_line_index, StepStreamRecord};

use super::ctfs_container::{BlockSource, CtfsError, FollowFileSource};

/// The `(path_id, line)` source location of a single step, decoded from the
/// follow-tailed execution stream.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FollowStep {
    pub path_id: PathId,
    pub line: Line,
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
    /// The growing container, behind a follow source. `refresh()` re-reads
    /// Block 0 `FileEntry` sizes (the growth signal) and the finalization state.
    source: FollowFileSource,
    /// Records-per-chunk seek granularity, parsed once from the `steps.idx`
    /// header. `None` until the index header (4 bytes) has been committed.
    chunk_size: Option<usize>,
    /// Byte offsets into `steps.dat` for each chunk start, parsed from
    /// `steps.idx`. Grows as the writer appends offsets. The writer writes a
    /// chunk's index offset BEFORE the chunk data (see the Nim
    /// `chunked_compressed_table` / Rust `step_stream` writers), so an offset may
    /// momentarily reference a not-yet-fully-committed chunk; [`Self::refresh`]
    /// only decodes chunks whose end is backed by committed `steps.dat` bytes.
    chunk_offsets: Vec<u64>,
    /// Fully-decoded steps from every committed chunk, in order. Append-only.
    steps: Vec<FollowStep>,
    /// Number of `steps.dat` chunks already fully decoded into [`Self::steps`].
    decoded_chunks: usize,
    /// `path` of the container, retained for diagnostics.
    path: PathBuf,
}

impl FollowStepStreamSource {
    /// Open a growing `.ct` for follow-mode split-stream reads.
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
            chunk_size: None,
            chunk_offsets: Vec::new(),
            steps: Vec::new(),
            decoded_chunks: 0,
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
    /// non-empty). A follow poller stops once this is true and a final
    /// [`Self::refresh`] has drained the last committed chunks.
    pub fn is_finalized(&self) -> bool {
        self.source.is_finalized()
    }

    /// Re-observe the growing container: re-read `steps.dat`'s committed
    /// `FileEntry.Size`, re-parse newly-appended `steps.idx` offsets, and decode
    /// every chunk that is now fully backed by committed `steps.dat` bytes.
    ///
    /// Returns the number of NEWLY-decoded steps this refresh produced (0 when no
    /// new fully-committed chunk has appeared yet).
    pub fn refresh(&mut self) -> Result<usize, CtfsError> {
        // Re-read Block 0 FileEntry sizes + finalization. After this, the
        // follow source knows the committed sizes of `steps.dat` / `steps.idx`.
        self.source.refresh()?;

        // Gate on the step stream's READABILITY, not on `meta.dat`. During live
        // recording `meta.dat` is committed LAST (it is the finalization signal),
        // so requiring it would make follow mode see nothing until the very end —
        // defeating the purpose. The presence of a `steps.idx` with a committed
        // header is the in-progress signal that a step stream is being written.
        //
        // Once `meta.dat` HAS landed (finalized container), we additionally honor
        // its `has_step_stream` flag: a finalized container that explicitly does
        // NOT advertise the step stream must read nothing, preserving the
        // capability-flag contract for sealed traces.
        if self.source.file_size("meta.dat").unwrap_or(0) > 0 && !self.has_step_stream_flag() {
            return Ok(0);
        }

        // Re-read the (possibly grown) index file. Parsing is cheap and the index
        // is small relative to the data, so we re-read it whole each refresh.
        let idx_size = self.source.file_size("steps.idx").unwrap_or(0);
        if idx_size < 4 {
            // Header not committed yet.
            return Ok(0);
        }
        let idx_bytes = self.read_internal_file("steps.idx", idx_size)?;
        self.parse_index(&idx_bytes);

        let before = self.steps.len();
        self.decode_committed_chunks()?;
        Ok(self.steps.len() - before)
    }

    /// Whether `meta.dat` is committed AND advertises `has_step_stream`.
    fn has_step_stream_flag(&self) -> bool {
        let meta_size = self.source.file_size("meta.dat").unwrap_or(0);
        if meta_size == 0 {
            return false;
        }
        match self.read_internal_file("meta.dat", meta_size) {
            Ok(meta) => meta_dat_has_step_stream(&meta),
            Err(_) => false,
        }
    }

    /// Parse `steps.idx` (`[chunk_size: u32 LE][offset_0: u64 LE]...`) into the
    /// chunk-size + offset table. Only ever extends the table — a shrinking index
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
    /// fully backed by committed `steps.dat` bytes.
    ///
    /// A chunk `c` spans `[chunk_offsets[c], chunk_offsets[c+1])` — or
    /// `[chunk_offsets[last], steps.dat.size)` for the final chunk. A chunk is
    /// "committed" once `steps.dat`'s `FileEntry.Size` covers its end. The writer
    /// records a chunk's index offset BEFORE the chunk bytes, so we must not
    /// decode the LAST indexed chunk until either a later offset bounds it or the
    /// recording is finalized (so its end is the final `steps.dat` size).
    fn decode_committed_chunks(&mut self) -> Result<usize, CtfsError> {
        let dat_size = self.source.file_size("steps.dat").unwrap_or(0);
        let finalized = self.source.is_finalized();
        let mut newly = 0usize;

        while self.decoded_chunks < self.chunk_offsets.len() {
            let c = self.decoded_chunks;
            let start = self.chunk_offsets[c];
            // The chunk's end is the next offset, or — for the last indexed
            // chunk — the committed `steps.dat` size (only safe to use once the
            // file is finalized, since mid-recording the last chunk's bytes may
            // still be landing).
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

            let chunk = self.read_internal_file_range("steps.dat", start, (end - start) as usize)?;
            let decoded = decode_chunk_steps(&chunk)
                .map_err(|e| CtfsError::Corrupt(format!("follow steps.dat chunk {c} ({}): {e}", self.path.display())))?;
            for step in &decoded {
                self.steps.push(*step);
            }
            newly += decoded.len();
            self.decoded_chunks += 1;
        }
        Ok(newly)
    }

    /// Read the whole of a named internal file (of known committed `size`)
    /// through the follow source's block mapping.
    fn read_internal_file(&self, name: &str, size: u64) -> Result<Vec<u8>, CtfsError> {
        self.read_internal_file_range(name, 0, size as usize)
    }

    /// Read `len` bytes at logical `offset` within a named internal file through
    /// the follow source, walking the container's block mapping via a
    /// short-lived [`super::ctfs_container::CtfsReader`] over the SAME growing
    /// file.
    ///
    /// We re-open a `CtfsReader` per call (cheap: it parses only Block 0 via
    /// positional reads, never the whole container) so the mapping walk always
    /// reflects the latest committed Block 0 — the directory and mapping blocks a
    /// live writer has flushed. The reader's bounds checks run against the follow
    /// source's freshly-refreshed `current_size`, so a read into a
    /// not-yet-committed region surfaces as a `Corrupt` error rather than reading
    /// stale bytes.
    fn read_internal_file_range(&self, name: &str, offset: u64, len: usize) -> Result<Vec<u8>, CtfsError> {
        let mut reader = super::ctfs_container::CtfsReader::open_follow(&self.path)?;
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
}

/// Decode every step record in one committed `steps.dat` chunk into
/// `(path_id, line)` locations, dropping non-`Step` records (markers carry no
/// line). Delegates the wire-format decode to the seekable reader's
/// [`decode_chunk_records`] so the follow path and the final-file path can never
/// diverge: the first `Step` of a chunk is AbsoluteStep, deltas resolve against
/// the running absolute carried forward within the chunk only.
fn decode_chunk_steps(compressed: &[u8]) -> Result<Vec<FollowStep>, String> {
    let records = decode_chunk_records(compressed)?;
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
