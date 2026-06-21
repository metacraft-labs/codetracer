//! Seekable, on-demand `calls.dat` call-tree source for the db-backend (M17b).
//!
//! The db-backend is the production reader for materialized `.ct` traces and is
//! SEEKABLE by design: a `.ct` loaded over the network must NOT be fully
//! materialized into memory (see `Trace-Files-Overview.md` §"Random-access
//! seeking" — CTFS block seeking + Seekable-Zstd seek table + the companion
//! event-offset index, on-demand decompression with an LRU, multiple concurrent
//! readers). The dedicated `calls.dat` stream (M17a) exists precisely so the
//! call tree can "load independently … no step scanning needed"
//! (`trace-events.md` §"Call Stream (`calls.dat`)").
//!
//! This module wires the db-backend onto the M17a format-level
//! [`codetracer_trace_reader::call_stream_reader::CallStreamReader`]: it fetches
//! a single call record by `call_key`, decompressing ONLY the one Zstd chunk
//! that holds it (bounded decompression — never the whole stream, never a fully
//! materialized `Db`). It does NOT reimplement the wire format.
//!
//! ## Concurrency
//!
//! The underlying [`CallStreamReader`] keeps a one-chunk decompression cache, so
//! reads take `&mut self`. We wrap it in a [`Mutex`] so a single
//! [`SeekableCallStream`] is `Send + Sync` and can be shared behind an
//! `Arc<dyn TraceReader>`. For the spec's "multiple concurrent readers" property
//! each reader simply opens its own [`SeekableCallStream`] over the same `.ct`
//! (the CTFS container is opened read-only), so independent readers never
//! contend — see the concurrent-readers test.

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use codetracer_trace_types::{CallKey, FullValueRecord, FunctionId, StepId, TypeId, ValueRecord};

use codetracer_trace_reader::call_stream_reader::{open_call_stream, CallStreamReader};
use codetracer_trace_writer::call_stream::{CallStreamRecord, VOID_RETURN_MARKER};

use crate::db::DbCall;

/// A seekable, on-demand view over a container's `calls.dat` call stream.
///
/// Holds the M17a [`CallStreamReader`] behind a [`Mutex`] (interior mutability:
/// each read may decompress a chunk and update the reader's one-chunk cache).
/// Reading a call by `call_key` decompresses ONLY that call's chunk — the whole
/// trace is never materialized.
pub struct SeekableCallStream {
    reader: Mutex<CallStreamReader>,
    record_count: u64,
    chunk_size: usize,
    /// Number of *distinct* Zstd chunks this source has had to decompress since
    /// it was opened.
    ///
    /// This is the *observable* bounded-decompression property the M17b spec
    /// requires: fetching a single call by key must decompress at most one chunk
    /// (and clustered reads within the same chunk decompress it at most once),
    /// NOT the whole stream. The db-backend test reads calls from a multi-chunk
    /// stream and asserts this counter stays bounded.
    chunk_decompressions: AtomicU64,
}

impl std::fmt::Debug for SeekableCallStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SeekableCallStream")
            .field("record_count", &self.record_count)
            .field("chunk_size", &self.chunk_size)
            .field("chunk_decompressions", &self.chunk_decompressions.load(Ordering::Relaxed))
            .finish()
    }
}

impl SeekableCallStream {
    /// Open the seekable call stream for a `.ct` path. Returns `Ok(None)` when
    /// the container carries no dedicated `calls.dat` stream (the
    /// `has_call_stream` capability flag is unset, or the file is absent) — the
    /// caller then falls back to the legacy fully-materialized call tree, so
    /// backward compatibility is preserved.
    pub fn open(path: &Path) -> Result<Option<SeekableCallStream>, String> {
        match open_call_stream(path)? {
            Some(reader) => {
                let record_count = reader.count();
                let chunk_size = reader.chunk_size();
                Ok(Some(SeekableCallStream {
                    reader: Mutex::new(reader),
                    record_count,
                    chunk_size,
                    chunk_decompressions: AtomicU64::new(0),
                }))
            }
            None => Ok(None),
        }
    }

    /// Total number of call records in the stream.
    pub fn call_count(&self) -> usize {
        self.record_count as usize
    }

    /// The fixed records-per-chunk seek granularity.
    pub fn chunk_size(&self) -> usize {
        self.chunk_size
    }

    /// Number of *distinct* Zstd chunks decompressed so far
    /// (bounded-decompression probe; see [`Self::chunk_decompressions`] field).
    pub fn chunk_decompressions(&self) -> u64 {
        self.chunk_decompressions.load(Ordering::Relaxed)
    }

    /// Fetch one call record by `call_key`, decompressing only its chunk, and
    /// convert it to an owned [`DbCall`]. Returns `None` for an out-of-range key.
    ///
    /// The conversion is structural — `function_id`, `parent_key`, `children`,
    /// `depth`, and the entry `step_id` come straight from the `calls.dat`
    /// record (the same fields the fully-materialized `Db` call tree carries).
    /// Argument and return values are best-effort decoded from the record's CBOR
    /// payloads (byte-identical to the `events.log` `Call`/`Return` payloads); a
    /// decode failure degrades to an empty/`None` value rather than failing the
    /// whole call, because the call-tree STRUCTURE is what the seekable path
    /// must serve.
    pub fn call(&self, key: CallKey) -> Option<DbCall> {
        if key.0 < 0 || key.0 as u64 >= self.record_count {
            return None;
        }
        let mut reader = self.reader.lock().ok()?;

        // Account for *distinct* chunk decompressions exactly: the reader caches
        // the most-recently-inflated chunk, so a read only inflates a new chunk
        // when the target chunk differs from the cached one. We observe the
        // reader's cache state directly (via the M17a `cached_chunk` probe).
        let cached_before = reader.cached_chunk();
        let record = reader.read(key.0 as u64).ok()?;
        let cached_after = reader.cached_chunk();
        if cached_before != cached_after {
            self.chunk_decompressions.fetch_add(1, Ordering::Relaxed);
        }

        Some(call_stream_record_to_db_call(&record))
    }
}

/// Convert a `calls.dat` [`CallStreamRecord`] into the db-backend's [`DbCall`].
///
/// This mirrors the mapping the fully-materialized new-format reader performs
/// when it pulls calls out of the Nim seek-based reader (see
/// `open_new_format_nim`): the structural fields map 1:1, args are decoded from
/// the record's single synthetic CBOR blob (the `Vec<FullValueRecord>` the
/// `Call` event carried), and the return value from the `Return` payload.
pub fn call_stream_record_to_db_call(record: &CallStreamRecord) -> DbCall {
    let args = decode_args(&record.args);
    let return_value = decode_return_value(&record.return_value);
    DbCall {
        key: CallKey(record.call_key as i64),
        function_id: FunctionId(record.function_id as usize),
        args,
        return_value,
        step_id: StepId(record.first_step_id as i64),
        depth: record.depth as usize,
        parent_key: CallKey(record.parent_key),
        children_keys: record.children.iter().map(|&c| CallKey(c as i64)).collect(),
    }
}

/// Decode the record's args blob (the whole-`Vec<FullValueRecord>` CBOR the
/// `Call` event carried) back into `FullValueRecord`s. An empty blob means "no
/// args"; a decode error degrades to an empty arg list (the structure is what
/// matters here, never a crash).
fn decode_args(blob: &[u8]) -> Vec<FullValueRecord> {
    if blob.is_empty() {
        return Vec::new();
    }
    match cbor4ii::serde::from_reader::<Vec<FullValueRecord>, _>(blob) {
        Ok(v) => v,
        Err(e) => {
            log::warn!("calls.dat: failed to decode call args CBOR ({e}); using empty args");
            Vec::new()
        }
    }
}

/// Decode the record's return-value blob. The void-return marker and an empty
/// blob both map to `ValueRecord::None`. A decode error degrades to `None`.
fn decode_return_value(blob: &[u8]) -> ValueRecord {
    if blob.is_empty() || blob == [VOID_RETURN_MARKER] {
        return ValueRecord::None { type_id: TypeId(0) };
    }
    match cbor4ii::serde::from_reader::<ValueRecord, _>(blob) {
        Ok(v) => v,
        Err(e) => {
            log::warn!("calls.dat: failed to decode call return-value CBOR ({e}); using None");
            ValueRecord::None { type_id: TypeId(0) }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The structural `CallStreamRecord` → `DbCall` mapping is faithful: keys,
    /// function id, parent, children, depth, and entry step map 1:1; empty
    /// args/return degrade to no args / `None`.
    #[test]
    fn record_to_db_call_maps_structural_fields() {
        let record = CallStreamRecord {
            call_key: 3,
            function_id: 7,
            parent_key: 1,
            first_step_id: 42,
            last_step_id: 99,
            depth: 2,
            args: Vec::new(),
            return_value: Vec::new(),
            raised_exception: Vec::new(),
            children: vec![4, 5],
        };
        let call = call_stream_record_to_db_call(&record);
        assert_eq!(call.key, CallKey(3));
        assert_eq!(call.function_id, FunctionId(7));
        assert_eq!(call.parent_key, CallKey(1));
        assert_eq!(call.depth, 2);
        assert_eq!(call.step_id, StepId(42));
        assert_eq!(call.children_keys, vec![CallKey(4), CallKey(5)]);
        assert!(call.args.is_empty());
        assert!(matches!(call.return_value, ValueRecord::None { .. }));
    }

    /// A root call's `-1` parent key round-trips as `CallKey(-1)`.
    #[test]
    fn record_to_db_call_preserves_root_parent() {
        let record = CallStreamRecord {
            call_key: 0,
            function_id: 0,
            parent_key: -1,
            first_step_id: 0,
            last_step_id: 0,
            depth: 0,
            args: Vec::new(),
            return_value: vec![VOID_RETURN_MARKER],
            raised_exception: Vec::new(),
            children: Vec::new(),
        };
        let call = call_stream_record_to_db_call(&record);
        assert_eq!(call.parent_key, CallKey(-1));
        assert!(matches!(call.return_value, ValueRecord::None { .. }));
    }

    /// A corrupt args blob degrades to empty args, never a panic (the call-tree
    /// STRUCTURE is what the seekable path must serve).
    #[test]
    fn corrupt_args_blob_degrades_to_empty() {
        let record = CallStreamRecord {
            call_key: 1,
            function_id: 2,
            parent_key: 0,
            first_step_id: 1,
            last_step_id: 1,
            depth: 1,
            args: vec![0xff, 0xfe, 0xfd], // not valid CBOR for Vec<FullValueRecord>
            return_value: Vec::new(),
            raised_exception: Vec::new(),
            children: Vec::new(),
        };
        let call = call_stream_record_to_db_call(&record);
        assert!(call.args.is_empty(), "corrupt args degrade to empty, not a crash");
    }
}
