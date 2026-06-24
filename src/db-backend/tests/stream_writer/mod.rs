//! Test-only INCREMENTAL CTFS streaming writer (M1 fixtures).
//!
//! Mirrors the production Nim streaming protocol just enough to exercise the
//! db-backend follow reader against a *growing* split-stream `.ct`:
//!
//!  1. [`IncrementalCtfsStreamWriter::create`] lays down Block 0 (CTFS v4
//!     header + extended header + a `FileEntry` for `steps.dat`, `steps.idx`,
//!     `meta.dat`, each starting at size 0 with a pre-allocated root mapping
//!     block) and flushes it. After this the container is a VALID (if empty)
//!     CTFS file the reader can open.
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
//! To keep block mapping trivial the writer uses ONLY direct (level-1) mapping:
//! each file's root map block holds up to `entries_per_block - 1` direct data
//! block pointers, so fixtures must stay under that bound (511 blocks/file for
//! the default 4096-byte block — far beyond any test's needs).
//!
//! It is NOT a general CTFS writer; it deliberately models the minimal subset
//! the follow-reader tests need.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
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
const HEADER_SIZE: usize = 8;
const EXTENDED_HEADER_SIZE: usize = 8;
const FILE_ENTRY_SIZE: usize = 24;
const MAX_ROOT_ENTRIES: u32 = 31;
const CTFS_MAGIC: [u8; 5] = [0xC0, 0xDE, 0x72, 0xAC, 0xE2];
const CTFS_VERSION_V4: u8 = 4;
const BASE40_CHARS: &[u8; 40] = b"\x000123456789abcdefghijklmnopqrstuvwxyz./-";

/// The fixed root-directory order of the files this writer manages. The
/// value/call streams are declared up front (size 0) so the multi-stream follow
/// reader can open the container before any chunk of any stream exists, exactly
/// as a live recorder creates the directory up front. A stream the test never
/// flushes simply stays at size 0 (its FileEntry advertises an empty file).
const FILES: [&str; 7] = [
    "steps.dat",
    "steps.idx",
    "values.dat",
    "values.idx",
    "calls.dat",
    "calls.idx",
    "meta.dat",
];

fn base40_encode(name: &str) -> u64 {
    let mut encoded: u64 = 0;
    let mut mult: u64 = 1;
    for ch in name.bytes() {
        let idx = BASE40_CHARS.iter().position(|&c| c == ch).expect("base40 char") as u64;
        encoded += idx * mult;
        mult *= 40;
    }
    encoded
}

/// Per-file bookkeeping: current logical size and root map block.
struct FileState {
    name: String,
    size: u64,
    map_block: u64,
    /// Number of data blocks already mapped (= next direct map index to fill).
    data_blocks: u64,
}

/// An incremental CTFS streaming writer for the follow-reader tests.
pub struct IncrementalCtfsStreamWriter {
    file: File,
    chunk_size: usize,
    /// Next free physical block number (block 0 is the directory).
    next_block: u64,
    files: Vec<FileState>,
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
    /// Create a new growing container at `path` with the three managed files
    /// pre-declared at size 0 (each with a reserved root mapping block), and
    /// flush Block 0 so the file is immediately a valid CTFS container.
    pub fn create(path: &Path, chunk_size: usize) -> std::io::Result<Self> {
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(true)
            .open(path)?;

        // Block 0 (directory) is block 0; reserve a root mapping block per file.
        let mut next_block = 1u64;
        let mut files = Vec::new();
        for name in FILES {
            let map_block = next_block;
            next_block += 1;
            files.push(FileState {
                name: name.to_string(),
                size: 0,
                map_block,
                data_blocks: 0,
            });
        }

        let mut writer = IncrementalCtfsStreamWriter {
            file,
            chunk_size,
            next_block,
            files,
            all_steps: Vec::new(),
            chunks_flushed: 0,
            all_values: Vec::new(),
            value_chunks_flushed: 0,
            all_calls: Vec::new(),
            call_chunks_flushed: 0,
        };

        // Grow the backing file to cover the reserved blocks (block 0 + the
        // per-file root map blocks), zero-filled.
        writer.ensure_len(writer.next_block * BLOCK_SIZE as u64)?;
        writer.flush_block_zero()?;
        Ok(writer)
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
        self.file.flush()?;
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
        self.file.flush()?;
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
        self.file.flush()?;
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
        let meta = encode_meta_dat("rec", "prog", &[], "/wd", "test-recorder", &[], flags);
        self.append_to_file("meta.dat", &meta)?;
        self.flush_block_zero()?;
        self.file.flush()?;
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

    fn file_index(&self, name: &str) -> usize {
        self.files.iter().position(|f| f.name == name).expect("managed file")
    }

    /// Append `bytes` to the logical end of a managed file, allocating data
    /// blocks and writing their direct map pointers as needed, then grow the
    /// file's `FileEntry.Size`.
    fn append_to_file(&mut self, name: &str, bytes: &[u8]) -> std::io::Result<()> {
        let fi = self.file_index(name);
        let mut written = 0usize;
        while written < bytes.len() {
            let (map_block, data_blocks, size) = {
                let f = &self.files[fi];
                (f.map_block, f.data_blocks, f.size)
            };
            let offset_in_file = size + written as u64;
            let block_index = offset_in_file / BLOCK_SIZE as u64;
            let offset_in_block = (offset_in_file % BLOCK_SIZE as u64) as usize;

            // Allocate a new data block when we are at a fresh block boundary.
            let data_block = if block_index >= data_blocks {
                let blk = self.alloc_block()?;
                // Direct mapping only: write the pointer at `block_index` in the
                // root map block.
                assert!(
                    block_index < (BLOCK_SIZE / 8 - 1) as u64,
                    "fixture exceeds direct mapping"
                );
                self.write_ptr(map_block, block_index as usize, blk)?;
                self.flush_block(map_block)?;
                self.files[fi].data_blocks = block_index + 1;
                blk
            } else {
                self.read_ptr(map_block, block_index as usize)?
            };

            let space = BLOCK_SIZE - offset_in_block;
            let to_write = space.min(bytes.len() - written);
            let phys_off = data_block * BLOCK_SIZE as u64 + offset_in_block as u64;
            self.ensure_len(phys_off + to_write as u64)?;
            self.file.seek(SeekFrom::Start(phys_off))?;
            self.file.write_all(&bytes[written..written + to_write])?;
            written += to_write;
        }
        self.files[fi].size += bytes.len() as u64;
        Ok(())
    }

    fn alloc_block(&mut self) -> std::io::Result<u64> {
        let blk = self.next_block;
        self.next_block += 1;
        self.ensure_len(self.next_block * BLOCK_SIZE as u64)?;
        Ok(blk)
    }

    /// Grow the backing file to at least `len` bytes (zero-filled).
    fn ensure_len(&mut self, len: u64) -> std::io::Result<()> {
        let cur = self.file.metadata()?.len();
        if len > cur {
            self.file.set_len(len)?;
        }
        Ok(())
    }

    fn write_ptr(&mut self, block: u64, index: usize, value: u64) -> std::io::Result<()> {
        let off = block * BLOCK_SIZE as u64 + (index * 8) as u64;
        self.ensure_len(off + 8)?;
        self.file.seek(SeekFrom::Start(off))?;
        self.file.write_all(&value.to_le_bytes())?;
        Ok(())
    }

    fn read_ptr(&mut self, block: u64, index: usize) -> std::io::Result<u64> {
        let off = block * BLOCK_SIZE as u64 + (index * 8) as u64;
        self.file.seek(SeekFrom::Start(off))?;
        let mut buf = [0u8; 8];
        self.file.read_exact(&mut buf)?;
        Ok(u64::from_le_bytes(buf))
    }

    /// Ensure the touched block's bytes are durable. `set_len` + buffered writes
    /// are flushed by the OS lazily; an explicit flush keeps a concurrent reader
    /// honest. (Here block flushing is a no-op beyond the final `file.flush()`,
    /// retained as a structural mirror of the Nim writer's per-block flush.)
    fn flush_block(&mut self, _block: u64) -> std::io::Result<()> {
        Ok(())
    }

    /// Rewrite Block 0: header + extended header + the three file entries with
    /// their current sizes / map blocks. This is the growth commit point — a
    /// follow reader's `refresh()` re-reads exactly these `FileEntry.Size`s.
    fn flush_block_zero(&mut self) -> std::io::Result<()> {
        let mut block0 = vec![0u8; BLOCK_SIZE];
        block0[0..5].copy_from_slice(&CTFS_MAGIC);
        block0[5] = CTFS_VERSION_V4;
        block0[8..12].copy_from_slice(&(BLOCK_SIZE as u32).to_le_bytes());
        block0[12..16].copy_from_slice(&MAX_ROOT_ENTRIES.to_le_bytes());

        let entry_start = HEADER_SIZE + EXTENDED_HEADER_SIZE;
        for (i, f) in self.files.iter().enumerate() {
            let off = entry_start + i * FILE_ENTRY_SIZE;
            let name_encoded = base40_encode(&f.name);
            // A size-0 file keeps map_block 0 (the reader treats it as empty);
            // once it has data, expose its real root map block.
            let map_block = if f.size == 0 { 0 } else { f.map_block };
            block0[off..off + 8].copy_from_slice(&f.size.to_le_bytes());
            block0[off + 8..off + 16].copy_from_slice(&map_block.to_le_bytes());
            block0[off + 16..off + 24].copy_from_slice(&name_encoded.to_le_bytes());
        }

        self.ensure_len(BLOCK_SIZE as u64)?;
        self.file.seek(SeekFrom::Start(0))?;
        self.file.write_all(&block0)?;
        Ok(())
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
