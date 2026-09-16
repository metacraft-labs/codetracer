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
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use codetracer_trace_types::{CallKey, FullValueRecord, FunctionId, StepId, TypeId, ValueRecord, VariableId};

use codetracer_trace_reader::call_stream_reader::{CallStreamReader, open_call_stream};
use codetracer_trace_writer::call_stream::{CallArg, CallStreamRecord, VOID_RETURN_MARKER};

use crate::db::DbCall;

use super::ctfs_container::CtfsReader;

/// A seekable, on-demand view over a container's `calls.dat` call stream.
///
/// Holds the M17a [`CallStreamReader`] behind a [`Mutex`] (interior mutability:
/// each read may decompress a chunk and update the reader's one-chunk cache).
/// Reading a call by `call_key` decompresses ONLY that call's chunk — the whole
/// trace is never materialized.
pub struct SeekableCallStream {
    reader: Mutex<CallStreamReader>,
    record_count: AtomicU64,
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
            .field("record_count", &self.record_count.load(Ordering::Relaxed))
            .field("chunk_size", &self.chunk_size)
            .field(
                "chunk_decompressions",
                &self.chunk_decompressions.load(Ordering::Relaxed),
            )
            .finish()
    }
}

impl SeekableCallStream {
    /// Open the seekable call stream for a `.ct` path. Returns `Ok(None)` when
    /// the container carries no dedicated `calls.dat` stream (the file is
    /// structurally absent) — the caller then falls back to the legacy
    /// fully-materialized call tree, so backward compatibility is preserved.
    /// Existence is decided by structural presence, not the `has_call_stream`
    /// hint bit.
    pub fn open(path: &Path) -> Result<Option<SeekableCallStream>, String> {
        match open_call_stream(path)? {
            Some(reader) => {
                let record_count = reader.count();
                let chunk_size = reader.chunk_size();
                Ok(Some(SeekableCallStream {
                    reader: Mutex::new(reader),
                    record_count: AtomicU64::new(record_count),
                    chunk_size,
                    chunk_decompressions: AtomicU64::new(0),
                }))
            }
            None => Ok(None),
        }
    }

    /// Open the seekable call stream through the already-open db-backend CTFS
    /// reader. `calls.dat` and `calls.idx` are read through the caller's current
    /// `BlockSource`/overlay instead of re-opening the `.ct` by filesystem path.
    pub fn open_from_ctfs(ctfs: &mut CtfsReader) -> Result<Option<SeekableCallStream>, String> {
        // Existence is answered by STRUCTURAL PRESENCE of `calls.dat`, never by
        // `meta.dat`'s `has_call_stream` hint bit — a writer may stamp that bit
        // only at close, so gating on it (or on `meta.dat` being present at all,
        // which the writer also emits only at close) would refuse a call stream
        // that structurally exists in a still-recording trace (trace-format spec:
        // "Stream-presence flags are a hint, not a gate"). The container's own
        // `meta.dat` is therefore never read here: `from_files` is handed
        // `structural_presence_meta()`, which states the presence THIS call has
        // already established structurally. See that helper for why passing an
        // empty slice instead silently refused every split-stream container.
        let dat = match ctfs.read_file("calls.dat") {
            Ok(dat) => dat,
            Err(_) => return Ok(None),
        };
        let idx = ctfs
            .read_file("calls.idx")
            .map_err(|e| format!("calls.idx missing despite calls.dat presence: {e}"))?;

        match CallStreamReader::from_files(&super::structural_presence_meta(), dat, idx)? {
            Some(reader) => {
                let record_count = reader.count();
                let chunk_size = reader.chunk_size();
                Ok(Some(SeekableCallStream {
                    reader: Mutex::new(reader),
                    record_count: AtomicU64::new(record_count),
                    chunk_size,
                    chunk_decompressions: AtomicU64::new(0),
                }))
            }
            None => Ok(None),
        }
    }

    /// Total number of call records in the stream.
    pub fn call_count(&self) -> usize {
        self.record_count.load(Ordering::Relaxed) as usize
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
        if key.0 < 0 || key.0 as u64 >= self.record_count.load(Ordering::Relaxed) {
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

    /// Materialize the call stream into db-backend calls plus their step ranges.
    ///
    /// Follow-mode production readers keep the seekable stream as the canonical
    /// refreshed source, but some `TraceReader` consumers still use the
    /// borrowing materialized call APIs. This gives the owner a consistent
    /// snapshot after a follow refresh.
    pub fn calls_and_ranges(&self) -> Result<Vec<(DbCall, u64, u64)>, String> {
        let mut reader = self
            .reader
            .lock()
            .map_err(|_| "calls.dat reader mutex poisoned".to_string())?;
        let count = self.record_count.load(Ordering::Relaxed);
        let mut calls = Vec::with_capacity(count as usize);
        for key in 0..count {
            let record = reader
                .read(key)
                .map_err(|e| format!("calls.dat[{key}] read failed: {e}"))?;
            let call = call_stream_record_to_db_call(&record);
            calls.push((call, record.first_step_id, record.last_step_id));
        }
        Ok(calls)
    }

    /// Refresh this stream in place from an already-refreshed CTFS reader.
    pub fn refresh_from_ctfs(&self, ctfs: &mut CtfsReader) -> Result<(), String> {
        let Some(reader) = open_call_reader_from_ctfs(ctfs)? else {
            return Ok(());
        };
        let record_count = reader.count();
        let mut guard = self
            .reader
            .lock()
            .map_err(|_| "calls.dat reader mutex poisoned".to_string())?;
        *guard = reader;
        self.record_count.store(record_count, Ordering::Relaxed);
        Ok(())
    }
}

fn open_call_reader_from_ctfs(ctfs: &mut CtfsReader) -> Result<Option<CallStreamReader>, String> {
    // Structural presence of `calls.dat` decides existence, not the
    // `has_call_stream` hint bit or `meta.dat` presence — the LIVE refresh path
    // must serve a still-recording trace whose `meta.dat` is not yet written
    // (see `SeekableCallStream::open_from_ctfs`). `from_files` is handed
    // `structural_presence_meta()` rather than the container's `meta.dat`.
    let dat = match ctfs.read_file("calls.dat") {
        Ok(dat) => dat,
        Err(_) => return Ok(None),
    };
    let idx = ctfs
        .read_file("calls.idx")
        .map_err(|e| format!("calls.idx missing despite calls.dat presence: {e}"))?;
    CallStreamReader::from_files(&super::structural_presence_meta(), dat, idx)
}

/// Convert a `calls.dat` [`CallStreamRecord`] into the db-backend's [`DbCall`].
///
/// This mirrors the mapping the fully-materialized new-format reader performs
/// when it pulls calls out of the Nim seek-based reader (see
/// `open_new_format_nim`): the structural fields map 1:1, each `calls.dat`
/// argument becomes one [`FullValueRecord`] carrying the argument's interned
/// `varnames.dat` id and its decoded CBOR value, and the return value comes from
/// the `Return` payload.
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

/// Adapt a `calls.dat` record's arguments into the db-backend's
/// [`FullValueRecord`]s: ONE output per [`CallArg`], in the record's declaration
/// order, each keeping its name.
///
/// The name is carried by `varname_id`, an index into the container's
/// `varnames.dat` interning table, and `FullValueRecord::variable_id` is an
/// index into that SAME table — the db-backend resolves it to text later, via
/// `Db::variable_name`. So the adaptation is the id, not a string lookup, and it
/// is the identical construction the fully-materialized readers already perform
/// on `reader.call_arg(key, i)` (`mod.rs`, `open_new_format_rust` /
/// `open_new_format_nim`). There is deliberately no second mechanism here.
///
/// Every argument survives. `codetracer-trace-format` commit a797cb8 changed
/// this record precisely because the previous shape — one synthetic blob under a
/// `varname_id` of 0 — kept only the first argument and threw away every name,
/// so a consumer that collapses the entries or drops them on a decode failure
/// reintroduces exactly the data loss that change exists to end. A value that
/// does not decode becomes a `ValueRecord::Raw` placeholder under its real name
/// (see [`super::decode_interned_cbor_value`]) rather than vanishing.
fn decode_args(args: &[CallArg]) -> Vec<FullValueRecord> {
    args.iter()
        .map(|arg| FullValueRecord {
            variable_id: VariableId(arg.varname_id as usize),
            value: super::decode_interned_cbor_value("calls.dat", &arg.value),
        })
        .collect()
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
// Same test-module convention as the sibling stream sources in this directory
// (`span_stream.rs`, `collapse.rs`, …): a fixture that cannot encode its own
// CBOR should abort the test loudly, and that is what `unwrap` does here.
// Nothing outside `mod tests` is exempted.
#[allow(clippy::unwrap_used, clippy::expect_used)]
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

    /// Encode a `ValueRecord` the way `calls.dat` stores an argument value.
    fn cbor(value: &ValueRecord) -> Vec<u8> {
        cbor4ii::serde::to_vec(Vec::new(), value).unwrap()
    }

    /// Build a record whose only interesting content is its argument list.
    fn record_with_args(args: Vec<CallArg>) -> CallStreamRecord {
        CallStreamRecord {
            call_key: 1,
            function_id: 2,
            parent_key: 0,
            first_step_id: 1,
            last_step_id: 1,
            depth: 1,
            args,
            return_value: Vec::new(),
            raised_exception: Vec::new(),
            children: Vec::new(),
        }
    }

    /// **The contract `codetracer-trace-format` a797cb8 exists to establish:
    /// EVERY argument survives the `calls.dat` → `DbCall` adaptation, in
    /// declaration order, each still carrying its own name.**
    ///
    /// The name is the interned `varnames.dat` id — the db-backend resolves it
    /// to text downstream (`Db::variable_name`), so preserving the id per
    /// argument IS preserving the name, and the assertions below are on the ids
    /// rather than on strings for that reason.
    ///
    /// This test is written to FAIL under the three ways the adaptation can
    /// lose or scramble data while still compiling. Each defect was planted
    /// separately and measured on its own run (2026-09-17,
    /// `cargo test --lib ctfs_trace_reader::call_stream_source`, 5 cases in
    /// this module). The cell names the FIRST assertion to panic in each case,
    /// because that is what attributes the kill to this arm rather than to an
    /// unrelated earlier failure:
    ///
    /// | planted defect in `decode_args` | cases red | first assertion to panic |
    /// | --- | --- | --- |
    /// | collapse: `args.iter().take(1)` (keep only the first, the pre-a797cb8 behaviour) | 2 of 5 | `3 args survive, one per CallArg` (left 1, right 3); `a bad value costs no argument its slot` (left 1, right 3) |
    /// | drop names: `variable_id: VariableId(0)` for every arg | 3 of 5 | `arg 0 keeps ITS OWN name` (left VariableId(0), right VariableId(7)); `the bad arg keeps its name` (left VariableId(0), right VariableId(11)); (left VariableId(0), right VariableId(5)) |
    /// | scramble: `args.iter().rev()` (right count, wrong pairing) | 2 of 5 | `arg 0 keeps ITS OWN name` (left VariableId(3), right VariableId(7)) |
    /// | unmodified | 0 of 5 | — |
    ///
    /// The ids are asserted per index by EXACT equality rather than by "the ids
    /// differ", which is what makes the scramble row above redden: a check that
    /// only required the ids to differ would pass on any permutation. Three
    /// distinct ids rather than two so that a defect reusing one id for every
    /// argument is caught at every index, not just where it happens to collide.
    #[test]
    fn every_call_arg_survives_with_its_own_name() {
        let record = record_with_args(vec![
            CallArg {
                varname_id: 7,
                value: cbor(&ValueRecord::Int {
                    i: 42,
                    type_id: TypeId(1),
                }),
            },
            CallArg {
                varname_id: 11,
                value: cbor(&ValueRecord::String {
                    text: "board".to_string(),
                    type_id: TypeId(2),
                }),
            },
            CallArg {
                varname_id: 3,
                value: cbor(&ValueRecord::Bool {
                    b: true,
                    type_id: TypeId(3),
                }),
            },
        ]);

        let call = call_stream_record_to_db_call(&record);

        assert_eq!(call.args.len(), 3, "3 args survive, one per CallArg");

        // Names: each argument keeps ITS OWN interning id, in declaration order.
        assert_eq!(call.args[0].variable_id, VariableId(7), "arg 0 keeps ITS OWN name");
        assert_eq!(call.args[1].variable_id, VariableId(11), "arg 1 keeps ITS OWN name");
        assert_eq!(call.args[2].variable_id, VariableId(3), "arg 2 keeps ITS OWN name");

        // Values: paired with the right name, not shuffled or shared.
        assert!(matches!(call.args[0].value, ValueRecord::Int { i: 42, .. }));
        assert!(matches!(&call.args[1].value, ValueRecord::String { text, .. } if text == "board"));
        assert!(matches!(call.args[2].value, ValueRecord::Bool { b: true, .. }));
    }

    /// An argument whose CBOR value does not decode is surfaced LOUDLY, under
    /// its real name, and its siblings are untouched.
    ///
    /// The pre-a797cb8 consumer answered a decode failure with an EMPTY arg
    /// list, which in the Variables view is indistinguishable from a call that
    /// captured nothing. A `Raw` placeholder is a visible defect instead, and
    /// losing one argument's value must not cost the other two theirs.
    #[test]
    fn undecodable_arg_keeps_its_name_and_spares_its_siblings() {
        let record = record_with_args(vec![
            CallArg {
                varname_id: 7,
                value: cbor(&ValueRecord::Int {
                    i: 1,
                    type_id: TypeId(1),
                }),
            },
            CallArg {
                varname_id: 11,
                value: vec![0xff, 0xfe, 0xfd], // not valid CBOR for a ValueRecord
            },
            CallArg {
                varname_id: 3,
                value: cbor(&ValueRecord::Int {
                    i: 2,
                    type_id: TypeId(1),
                }),
            },
        ]);

        let call = call_stream_record_to_db_call(&record);

        assert_eq!(call.args.len(), 3, "a bad value costs no argument its slot");
        assert_eq!(call.args[1].variable_id, VariableId(11), "the bad arg keeps its name");
        assert!(
            matches!(&call.args[1].value, ValueRecord::Raw { r, .. } if r.contains("cbor decode error")),
            "a bad value is a VISIBLE placeholder, never a silently absent argument: {:?}",
            call.args[1].value
        );
        assert!(matches!(call.args[0].value, ValueRecord::Int { i: 1, .. }));
        assert!(matches!(call.args[2].value, ValueRecord::Int { i: 2, .. }));
    }

    /// An argument carrying an EMPTY value payload still occupies its slot under
    /// its own name — an absent value is not an absent argument.
    #[test]
    fn empty_arg_value_still_yields_a_named_argument() {
        let record = record_with_args(vec![CallArg {
            varname_id: 5,
            value: Vec::new(),
        }]);
        let call = call_stream_record_to_db_call(&record);
        assert_eq!(call.args.len(), 1);
        assert_eq!(call.args[0].variable_id, VariableId(5));
        assert!(matches!(call.args[0].value, ValueRecord::None { .. }));
    }
}
