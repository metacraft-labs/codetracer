//! Seekable, on-demand `steps.dat` + `values.dat` sources for the db-backend (M22).
//!
//! These mirror the M17b `call_stream_source::SeekableCallStream` exactly, but
//! for the EXECUTION stream (`steps.dat`, M23a) and the PARALLEL VALUE stream
//! (`values.dat`, M23b). They complete the M17b spec-violation fix: M17b made
//! the CALL tree seekable; the step line lookups and per-step variable values
//! still came from a fully-materialized `Db`. With these two sources, a
//! `has_step_stream` + `has_value_stream` `.ct` serves a step's source line and
//! a step's variable values ON DEMAND, decompressing ONLY the one Zstd chunk a
//! request needs — never the whole stream, never a fully-materialized `Db`
//! (see `Trace-Files-Overview.md` §"Random-access seeking").
//!
//! This module wires the db-backend onto the format-level M23a/M23b readers:
//!   - [`codetracer_trace_reader::step_stream_reader::StepStreamReader`]
//!     (`steps.dat`/`steps.idx`): decodes AbsoluteStep/DeltaStep records, each
//!     carrying an absolute `global_line_index` that
//!     [`unpack_global_line_index`] turns back into the exact `(path_id, line)`
//!     the step had.
//!   - [`codetracer_trace_reader::value_stream_reader::ValueStreamReader`]
//!     (`values.dat`/`values.idx`): value record `N` ↔ step `N`; its
//!     `StepValues` event carries the same `(name_id, CBOR ValueRecord)` pairs
//!     the `Value` events carried, so a step's `FullValueRecord`s reconstruct
//!     byte-identically to the materialized `db.variables[step]`.
//!
//! It does NOT reimplement either wire format.
//!
//! ## Concurrency
//!
//! Each format reader keeps a one-chunk decompression cache, so reads take
//! `&mut self`. We wrap each in a [`Mutex`] so a single source is `Send + Sync`
//! behind an `Arc<dyn TraceReader>`. For the spec's "multiple concurrent
//! readers" property each reader simply opens its own source over the same `.ct`
//! (the CTFS container is opened read-only), so independent readers never
//! contend — see the concurrent-readers test.

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use codetracer_trace_types::{FullValueRecord, Line, PathId, StepId, TypeId, ValueRecord, VariableId};

use codetracer_trace_reader::step_stream_reader::{open_step_stream, StepStreamReader};
use codetracer_trace_reader::value_stream_reader::{open_value_stream, ValueStreamReader};
use codetracer_trace_writer::step_stream::{unpack_global_line_index, StepStreamRecord};
use codetracer_trace_writer::value_stream::ValueStreamEvent;

/// A seekable, on-demand view over a container's `steps.dat` execution stream.
///
/// Holds the M23a [`StepStreamReader`] behind a [`Mutex`] (interior mutability:
/// each read may decompress a chunk and update the reader's one-chunk cache).
/// Reading a step's line by `step_id` decompresses ONLY that step's chunk — the
/// whole trace is never materialized.
pub struct SeekableStepStream {
    reader: Mutex<StepStreamReader>,
    record_count: u64,
    chunk_size: usize,
    /// Number of *distinct* Zstd chunks this source has had to decompress since
    /// it was opened.
    ///
    /// This is the *observable* bounded-decompression property the M22 spec
    /// requires (exactly as M17b/M23a/M23b proved it for calls/steps/values):
    /// fetching a single step's line must decompress at most one chunk — NOT the
    /// whole stream. The db-backend test reads a step from a multi-chunk stream
    /// and asserts this counter stays bounded.
    chunk_decompressions: AtomicU64,
}

impl std::fmt::Debug for SeekableStepStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SeekableStepStream")
            .field("record_count", &self.record_count)
            .field("chunk_size", &self.chunk_size)
            .field("chunk_decompressions", &self.chunk_decompressions.load(Ordering::Relaxed))
            .finish()
    }
}

impl SeekableStepStream {
    /// Open the seekable step stream for a `.ct` path. Returns `Ok(None)` when
    /// the container carries no dedicated `steps.dat` stream (the
    /// `has_step_stream` capability flag is unset, or the file is absent) — the
    /// caller then falls back to the fully-materialized `Db` step table, so
    /// backward compatibility is preserved.
    pub fn open(path: &Path) -> Result<Option<SeekableStepStream>, String> {
        match open_step_stream(path)? {
            Some(reader) => {
                let record_count = reader.count();
                let chunk_size = reader.chunk_size();
                Ok(Some(SeekableStepStream {
                    reader: Mutex::new(reader),
                    record_count,
                    chunk_size,
                    chunk_decompressions: AtomicU64::new(0),
                }))
            }
            None => Ok(None),
        }
    }

    /// Total number of execution-stream records in the stream.
    pub fn step_count(&self) -> usize {
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

    /// Fetch the `(path_id, line)` of step `step_id` from the SEEKABLE
    /// `steps.dat` stream, decompressing only its chunk. Returns `None` for an
    /// out-of-range id, or when the record at that index is not a `Step` (e.g. a
    /// `Raise`/`Catch`/`ThreadSwitch` marker carries no source line).
    ///
    /// The decoded record's `global_line_index` is the exact value M23a packed
    /// from the original `(path_id, line)`; [`unpack_global_line_index`] is its
    /// inverse, so the returned location is byte-identical to the materialized
    /// `DbStep`'s `(path_id, line)`.
    pub fn step_line(&self, step_id: StepId) -> Option<(PathId, Line)> {
        if step_id.0 < 0 || step_id.0 as u64 >= self.record_count {
            return None;
        }
        let mut reader = self.reader.lock().ok()?;

        // Account for *distinct* chunk decompressions exactly: the reader caches
        // the most-recently-inflated chunk, so a read only inflates a new chunk
        // when the target chunk differs from the cached one. We observe the
        // reader's cache state directly (via the M23a `cached_chunk` probe).
        let cached_before = reader.cached_chunk();
        let record = reader.read(step_id.0 as u64).ok()?;
        let cached_after = reader.cached_chunk();
        if cached_before != cached_after {
            self.chunk_decompressions.fetch_add(1, Ordering::Relaxed);
        }

        match record {
            StepStreamRecord::Step { global_line_index } => {
                let (path_id, line) = unpack_global_line_index(global_line_index);
                Some((PathId(path_id), Line(line)))
            }
            // Raise/Catch/ThreadSwitch records carry no source line; the
            // execution stream interleaves them with `Step` records but only
            // `Step` records have a `(path_id, line)`.
            _ => None,
        }
    }
}

/// A seekable, on-demand view over a container's `values.dat` parallel value
/// stream.
///
/// Holds the M23b [`ValueStreamReader`] behind a [`Mutex`]. Reading a step's
/// variable values by `step_id` decompresses ONLY that step's chunk — the whole
/// trace is never materialized. By the parallel-index invariant (value record
/// `N` ↔ step `N`) the integer step index IS the value-record index.
pub struct SeekableValueStream {
    reader: Mutex<ValueStreamReader>,
    record_count: u64,
    chunk_size: usize,
    /// Distinct-chunk decompression counter (bounded-decompression probe), as on
    /// [`SeekableStepStream`].
    chunk_decompressions: AtomicU64,
}

impl std::fmt::Debug for SeekableValueStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SeekableValueStream")
            .field("record_count", &self.record_count)
            .field("chunk_size", &self.chunk_size)
            .field("chunk_decompressions", &self.chunk_decompressions.load(Ordering::Relaxed))
            .finish()
    }
}

impl SeekableValueStream {
    /// Open the seekable value stream for a `.ct` path. Returns `Ok(None)` when
    /// the container carries no dedicated `values.dat` stream — the caller falls
    /// back to the fully-materialized `db.variables`, preserving backward compat.
    pub fn open(path: &Path) -> Result<Option<SeekableValueStream>, String> {
        match open_value_stream(path)? {
            Some(reader) => {
                let record_count = reader.count();
                let chunk_size = reader.chunk_size();
                Ok(Some(SeekableValueStream {
                    reader: Mutex::new(reader),
                    record_count,
                    chunk_size,
                    chunk_decompressions: AtomicU64::new(0),
                }))
            }
            None => Ok(None),
        }
    }

    /// Total number of value records in the stream (equals the step count).
    pub fn value_count(&self) -> usize {
        self.record_count as usize
    }

    /// The fixed records-per-chunk seek granularity.
    pub fn chunk_size(&self) -> usize {
        self.chunk_size
    }

    /// Number of *distinct* Zstd chunks decompressed so far.
    pub fn chunk_decompressions(&self) -> u64 {
        self.chunk_decompressions.load(Ordering::Relaxed)
    }

    /// Fetch the variable values visible at step `step_id` from the SEEKABLE
    /// `values.dat` stream, decompressing only its chunk, as owned
    /// [`FullValueRecord`]s. Returns `None` for an out-of-range id (so the caller
    /// can fall back); returns an empty `Vec` for a step that has no variable
    /// activity.
    ///
    /// The reconstruction reads the record's single `StepValues` event and
    /// decodes each `(name_id, CBOR ValueRecord)` pair back into a
    /// `FullValueRecord` — byte-identical to the materialized
    /// `db.variables[step]` for a trace whose step variables came from `Value`
    /// events (the value-stream builder projects exactly those). A per-value
    /// CBOR decode failure degrades that single value to a `Raw` placeholder
    /// rather than failing the whole step, mirroring the materialized
    /// new-format reader (`open_new_format_nim`).
    pub fn variables_at(&self, step_id: StepId) -> Option<Vec<FullValueRecord>> {
        if step_id.0 < 0 || step_id.0 as u64 >= self.record_count {
            return None;
        }
        let mut reader = self.reader.lock().ok()?;

        let cached_before = reader.cached_chunk();
        let record = reader.read(step_id.0 as u64).ok()?;
        let cached_after = reader.cached_chunk();
        if cached_before != cached_after {
            self.chunk_decompressions.fetch_add(1, Ordering::Relaxed);
        }

        Some(step_values_to_full_records(&record.events))
    }
}

/// Reconstruct the per-step `Vec<FullValueRecord>` (the materialized
/// `db.variables[step]` shape) from a value record's stream events.
///
/// Only the `StepValues` event contributes variable snapshots; the other
/// value-stream events (`BindVariable`, `Cell*`, `Assign*`, …) drive the
/// cell/compound history the db-backend serves through `cell_changes_for` /
/// `compound_at`, which M22 keeps on the materialized path (see the module
/// docs). The builder emits at most one `StepValues` per step, but we iterate
/// defensively to tolerate any future shape.
pub fn step_values_to_full_records(events: &[ValueStreamEvent]) -> Vec<FullValueRecord> {
    let mut out = Vec::new();
    for event in events {
        if let ValueStreamEvent::StepValues { values } = event {
            for (name_id, cbor) in values {
                out.push(FullValueRecord {
                    variable_id: VariableId(*name_id as usize),
                    value: decode_value(cbor),
                });
            }
        }
    }
    out
}

/// Decode a value-stream `StepValues` CBOR payload back into a [`ValueRecord`].
/// An empty blob maps to `ValueRecord::None`; a decode error degrades to a
/// `Raw` placeholder (mirroring `open_new_format_nim`) so one bad value never
/// fails the whole step.
fn decode_value(blob: &[u8]) -> ValueRecord {
    if blob.is_empty() {
        return ValueRecord::None { type_id: TypeId(0) };
    }
    match cbor4ii::serde::from_reader::<ValueRecord, _>(blob) {
        Ok(v) => v,
        Err(e) => {
            log::warn!("values.dat: failed to decode StepValues CBOR ({e}); using Raw placeholder");
            ValueRecord::Raw {
                r: format!("<cbor decode error: {e}>"),
                type_id: TypeId(0),
            }
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::panic)]
mod tests {
    use super::*;

    /// A `StepValues` event with two values reconstructs two `FullValueRecord`s
    /// with the right ids and decoded values.
    #[test]
    fn step_values_reconstructs_full_records() {
        let v0 = cbor4ii::serde::to_vec(Vec::new(), &ValueRecord::Int { i: 7, type_id: TypeId(0) }).unwrap();
        let v1 = cbor4ii::serde::to_vec(
            Vec::new(),
            &ValueRecord::String {
                text: "hi".to_string(),
                type_id: TypeId(1),
            },
        )
        .unwrap();
        let events = vec![ValueStreamEvent::StepValues {
            values: vec![(3, v0), (5, v1)],
        }];
        let records = step_values_to_full_records(&events);
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].variable_id, VariableId(3));
        assert!(matches!(records[0].value, ValueRecord::Int { i: 7, .. }));
        assert_eq!(records[1].variable_id, VariableId(5));
        assert!(matches!(&records[1].value, ValueRecord::String { text, .. } if text == "hi"));
    }

    /// A record with no `StepValues` event (only bind/cell events) reconstructs
    /// an empty variable list — those events feed the cell history, not the
    /// per-step variable snapshot.
    #[test]
    fn non_stepvalues_events_yield_no_variables() {
        let events = vec![
            ValueStreamEvent::BindVariable { variable_id: 1, place: 9 },
            ValueStreamEvent::DropVariable { variable_id: 1 },
        ];
        assert!(step_values_to_full_records(&events).is_empty());
    }

    /// A corrupt value blob degrades to a `Raw` placeholder, never a panic.
    #[test]
    fn corrupt_value_blob_degrades_to_raw() {
        let events = vec![ValueStreamEvent::StepValues {
            values: vec![(0, vec![0xff, 0xfe, 0xfd])],
        }];
        let records = step_values_to_full_records(&events);
        assert_eq!(records.len(), 1);
        assert!(matches!(&records[0].value, ValueRecord::Raw { r, .. } if r.contains("cbor decode error")));
    }
}
