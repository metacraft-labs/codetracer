//! Test-only INCREMENTAL CTFS streaming writer (M1 fixtures).
//!
//! Mirrors the production Nim streaming protocol just enough to exercise the
//! db-backend follow reader against a *growing* split-stream `.ct`:
//!
//!  1. [`IncrementalCtfsStreamWriter::create`] uses the selected shipping
//!     CtfsWriter to declare all nine members at size zero and publishes the
//!     current-layout directory. Each subsequent flush uses the same writer.
//!  2. [`IncrementalCtfsStreamWriter::flush_chunk`] encodes a chunk of steps via
//!     the PRODUCTION `encode_step_stream` encoder, appends the compressed chunk
//!     bytes to `steps.dat` and the chunk's 8-byte offset to `steps.idx`,
//!     GROWS both files' `FileEntry.Size` in Block 0, and flushes the touched
//!     blocks — exactly the "FileEntry.Size grows as a chunk is flushed" growth
//!     signal the follow source watches.
//!  3. [`IncrementalCtfsStreamWriter::finalize`] writes a real `meta.dat`
//!     (via `encode_meta_dat` with the `has_step_stream` flag) LAST — the
//!     finalization signal.
//!
//! Container storage uses the genuine shipping CtfsWriter. Each fixture flush
//! writes every pending member block before publishing the directory entries;
//! the existing stream encoders and refresh assertions remain unchanged.

use codetracer_ctfs::writer::{CtfsWriter, FileHandle};
use std::path::Path;

use codetracer_trace_types::{Line, PathId};
use codetracer_trace_types::{StepRecord, TraceLowLevelEvent};
use codetracer_trace_writer::call_stream::{CallStreamRecord, encode_call_stream};
use codetracer_trace_writer::meta_dat::{
    FLAG_HAS_CALL_STREAM, FLAG_HAS_STEP_STREAM, FLAG_HAS_VALUE_STREAM, encode_meta_dat,
};
use codetracer_trace_writer::step_stream::{StepStreamBuilder, encode_step_stream};
use codetracer_trace_writer::value_stream::{ValueRecordEntry, ValueStreamEvent, encode_value_stream};

const BLOCK_SIZE: usize = 4096;
const MAX_ROOT_ENTRIES: u32 = 31;

/// The fixed root-directory order of the files this writer manages. The
/// value/call streams are declared up front (size 0) so the multi-stream follow
/// reader can open the container before any chunk of any stream exists, exactly
/// as a live recorder creates the directory up front. A stream the test never
/// flushes simply stays at size 0 (its FileEntry advertises an empty file).
const FILES: [&str; 9] = [
    "steps.dat",
    "steps.idx",
    "values.dat",
    "values.idx",
    "calls.dat",
    "calls.idx",
    "paths.dat",
    "paths.off",
    "meta.dat",
];

/// How many source paths this writer's containers register.
///
/// A step's `global_line_index` is a position in the space the path table
/// defines, so a container with steps and no path table has no space to place
/// them in and a reader cannot say where any of its steps are. A real recorder
/// always writes the table; this writer declares a fixed synthetic one so its
/// containers are containers, and tests may use any path id below this.
pub const DECLARED_PATH_COUNT: usize = 8;

/// An incremental CTFS streaming writer for the follow-reader tests.
pub struct IncrementalCtfsStreamWriter {
    container: CtfsWriter,
    chunk_size: usize,
    files: Vec<(String, FileHandle)>,
    /// Accumulated step events, re-encoded whole on each flush so the chunk
    /// boundaries the encoder produces stay consistent. We append only the
    /// NEWLY-produced chunk's bytes to `steps.dat` / `steps.idx`.
    all_steps: Vec<TraceLowLevelEvent>,
    /// Number of chunks already flushed to `steps.dat` / `steps.idx`.
    chunks_flushed: usize,
    /// Accumulated value records, re-encoded whole on each value-chunk flush.
    all_values: Vec<ValueRecordEntry>,
    /// Number of chunks already flushed to `values.dat` / `values.idx`.
    value_chunks_flushed: usize,
    /// Accumulated call records, re-encoded whole on each call-chunk flush.
    all_calls: Vec<CallStreamRecord>,
    /// Number of chunks already flushed to `calls.dat` / `calls.idx`.
    call_chunks_flushed: usize,
}

impl IncrementalCtfsStreamWriter {
    /// Create a new growing container at `path` with all nine managed files
    /// pre-declared at size 0, and
    /// flush Block 0 so the file is immediately a valid CTFS container.
    pub fn create(path: &Path, chunk_size: usize) -> std::io::Result<Self> {
        let mut container =
            CtfsWriter::create(path, BLOCK_SIZE as u32, MAX_ROOT_ENTRIES).map_err(std::io::Error::other)?;
        let mut files = Vec::new();
        for name in FILES {
            let handle = container.add_file(name).map_err(std::io::Error::other)?;
            files.push((name.to_string(), handle));
        }
        let mut writer = IncrementalCtfsStreamWriter {
            container,
            chunk_size,
            files,
            all_steps: Vec::new(),
            chunks_flushed: 0,
            all_values: Vec::new(),
            value_chunks_flushed: 0,
            all_calls: Vec::new(),
            call_chunks_flushed: 0,
        };

        writer.flush_block_zero()?;
        writer.write_path_table()?;
        Ok(writer)
    }

    /// Write the container's path interning table: `paths.dat` is the
    /// concatenated raw path bytes and `paths.off` the `count + 1` cumulative
    /// end-offsets, exactly as the production writers emit a line-only table.
    fn write_path_table(&mut self) -> std::io::Result<()> {
        let mut dat = Vec::new();
        let mut off = Vec::new();
        off.extend_from_slice(&0u64.to_le_bytes());
        for id in 0..DECLARED_PATH_COUNT {
            dat.extend_from_slice(format!("/tmp/stream_writer_src{id}.rs").as_bytes());
            off.extend_from_slice(&(dat.len() as u64).to_le_bytes());
        }
        self.append_to_file("paths.dat", &dat)?;
        self.append_to_file("paths.off", &off)?;
        self.flush_block_zero()?;
        self.container.flush().map_err(std::io::Error::other)
    }

    /// Encode `new_steps` as the next chunk and append it to `steps.dat` /
    /// `steps.idx`, growing both files' `FileEntry.Size`.
    ///
    /// `new_steps` must be exactly one chunk's worth (`chunk_size` steps) for the
    /// tests' chunk-by-chunk growth assertions, but any non-empty slice works.
    pub fn flush_chunk(&mut self, new_steps: &[(PathId, Line)]) -> std::io::Result<()> {
        // Re-encode the WHOLE stream so the encoder's chunking is consistent,
        // then extract only the new chunk's `.dat` bytes and its `.idx` offset.
        for (pid, line) in new_steps {
            self.all_steps.push(TraceLowLevelEvent::Step(StepRecord {
                path_id: *pid,
                line: *line,
            }));
        }
        let mut builder = StepStreamBuilder::new();
        for ev in &self.all_steps {
            builder.observe(ev);
        }
        let stream = builder.finish();
        let encoded = encode_step_stream(&stream, self.chunk_size, 3).expect("encode_step_stream");

        let c = self.chunks_flushed;
        self.append_stream_chunk("steps.dat", "steps.idx", &encoded.dat, &encoded.idx, c)?;
        self.chunks_flushed += 1;
        self.flush_block_zero()?;
        self.container.flush().map_err(std::io::Error::other)?;
        Ok(())
    }

    /// Encode the accumulated value records and append the next chunk to
    /// `values.dat` / `values.idx`, growing both files' `FileEntry.Size`.
    ///
    /// `new_values` is appended to the running value record list (one record per
    /// step, parallel-indexed). Like [`Self::flush_chunk`], the whole value
    /// stream is re-encoded and only the new chunk's bytes/offset are appended.
    pub fn flush_value_chunk(&mut self, new_values: &[ValueRecordEntry]) -> std::io::Result<()> {
        self.all_values.extend_from_slice(new_values);
        let encoded = encode_value_stream(&self.all_values, self.chunk_size, 3).expect("encode_value_stream");
        let c = self.value_chunks_flushed;
        self.append_stream_chunk("values.dat", "values.idx", &encoded.dat, &encoded.idx, c)?;
        self.value_chunks_flushed += 1;
        self.flush_block_zero()?;
        self.container.flush().map_err(std::io::Error::other)?;
        Ok(())
    }

    /// Encode the accumulated call records and append the next chunk to
    /// `calls.dat` / `calls.idx`, growing both files' `FileEntry.Size`.
    pub fn flush_call_chunk(&mut self, new_calls: &[CallStreamRecord]) -> std::io::Result<()> {
        self.all_calls.extend_from_slice(new_calls);
        let encoded = encode_call_stream(&self.all_calls, self.chunk_size, 3).expect("encode_call_stream");
        let c = self.call_chunks_flushed;
        self.append_stream_chunk("calls.dat", "calls.idx", &encoded.dat, &encoded.idx, c)?;
        self.call_chunks_flushed += 1;
        self.flush_block_zero()?;
        self.container.flush().map_err(std::io::Error::other)?;
        Ok(())
    }

    /// Append the chunk at index `c` from a freshly-encoded `dat`/`idx` pair to
    /// the on-disk `<name>.dat` / `<name>.idx`, growing both files'
    /// `FileEntry.Size`. Shared by every per-stream flush so the
    /// "extract chunk `c`'s bytes + its offset and append them" logic lives once.
    ///
    /// The on-disk `<name>.idx` is `[chunk_size u32]` followed by one u64 offset
    /// per flushed chunk; on the FIRST flush we write the 4-byte header too.
    fn append_stream_chunk(
        &mut self,
        dat_name: &str,
        idx_name: &str,
        dat: &[u8],
        idx: &[u8],
        c: usize,
    ) -> std::io::Result<()> {
        let offsets = parse_idx_offsets(idx);
        assert!(c < offsets.len(), "encoder produced fewer chunks than flushed");
        let dat_start = offsets[c] as usize;
        let dat_end = if c + 1 < offsets.len() {
            offsets[c + 1] as usize
        } else {
            dat.len()
        };
        self.append_to_file(dat_name, &dat[dat_start..dat_end])?;

        if c == 0 {
            let mut idx_init = Vec::new();
            idx_init.extend_from_slice(&(self.chunk_size as u32).to_le_bytes());
            idx_init.extend_from_slice(&offsets[0].to_le_bytes());
            self.append_to_file(idx_name, &idx_init)?;
        } else {
            self.append_to_file(idx_name, &offsets[c].to_le_bytes())?;
        }
        Ok(())
    }

    /// Commit `meta.dat` (with the `has_step_stream` flag) as the finalization
    /// signal, growing its `FileEntry.Size`.
    pub fn finalize(&mut self) -> std::io::Result<()> {
        self.finalize_with_flags(FLAG_HAS_STEP_STREAM)
    }

    /// Commit `meta.dat` advertising every split stream this writer flushed
    /// (steps always; values/calls when at least one chunk of each was flushed),
    /// as the finalization signal. Used by the multi-stream follow test so the
    /// finalized container's capability flags match what was written.
    pub fn finalize_all_streams(&mut self) -> std::io::Result<()> {
        let mut flags = FLAG_HAS_STEP_STREAM;
        if self.value_chunks_flushed > 0 {
            flags |= FLAG_HAS_VALUE_STREAM;
        }
        if self.call_chunks_flushed > 0 {
            flags |= FLAG_HAS_CALL_STREAM;
        }
        self.finalize_with_flags(flags)
    }

    /// Commit `meta.dat` with an explicit capability-flag set.
    fn finalize_with_flags(&mut self, flags: u16) -> std::io::Result<()> {
        // `meta.dat` has required a canonical UUIDv7 `recording_id` since v3,
        // and the readers validate it. A placeholder here produces a container
        // the production Nim reader refuses at open, which is what a test using
        // this writer to stand in for a recorder must not do.
        let meta = encode_meta_dat(
            "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb",
            "prog",
            &[],
            "/wd",
            "test-recorder",
            flags,
        );
        self.append_to_file("meta.dat", &meta)?;
        self.flush_block_zero()?;
        self.container.flush().map_err(std::io::Error::other)?;
        Ok(())
    }

    /// A `ValueRecordEntry` carrying one `StepValues` event with the given
    /// `(name_id, CBOR ValueRecord)` pairs — a convenience for building value
    /// fixtures in the multi-stream follow test.
    pub fn step_values_record(values: Vec<(u64, Vec<u8>)>) -> ValueRecordEntry {
        ValueRecordEntry {
            events: vec![ValueStreamEvent::StepValues { values }],
        }
    }

    // ── internals ─────────────────────────────────────────────────────────

    /// Append actual encoded bytes through the shipping current-layout writer.
    fn append_to_file(&mut self, name: &str, bytes: &[u8]) -> std::io::Result<()> {
        let handle = self.files.iter().find(|(n, _)| n == name).expect("managed file").1;
        self.container.append(handle, bytes).map_err(std::io::Error::other)?;
        Ok(())
    }

    /// Publish all pending member data before any directory entry exposes it.
    fn flush_block_zero(&mut self) -> std::io::Result<()> {
        for (_, handle) in &self.files {
            self.container.write_pending(*handle).map_err(std::io::Error::other)?;
        }
        for (_, handle) in &self.files {
            self.container.publish_entry(*handle).map_err(std::io::Error::other)?;
        }
        self.container.flush().map_err(std::io::Error::other)
    }
}

/// Parse the `[chunk_size u32][offset u64]...` index into its offset list.
fn parse_idx_offsets(idx: &[u8]) -> Vec<u64> {
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
    offsets
}
