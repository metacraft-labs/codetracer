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

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use once_cell::sync::OnceCell;

use codetracer_trace_types::{CallKey, FullValueRecord, Line, PathId, StepId, TypeId, ValueRecord, VariableId};

use crate::db::DbStep;

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
    /// The `.ct` container path this source was opened from. Retained so the
    /// M25b LOCAL parallel whole-table build can open INDEPENDENT per-thread
    /// reader handles over the SAME container (each with its own one-chunk
    /// decompression cache) — disjoint ranges then replay concurrently without
    /// contending on this source's `Mutex` or thrashing a single cached chunk.
    /// `None` for sources not opened from a path (currently always `Some`, since
    /// `open` is the only constructor, but kept optional for future in-memory
    /// sources that cannot be re-opened — those simply fall back to sequential).
    path: Option<PathBuf>,
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
                    path: Some(path.to_path_buf()),
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

    /// Open an INDEPENDENT sibling source over the SAME `.ct` container (M25b).
    ///
    /// The returned source has its OWN [`StepStreamReader`] and one-chunk
    /// decompression cache, so it can replay a disjoint step range on its own
    /// thread without touching this source's `Mutex` or cache. Returns `None`
    /// when this source has no retained path (an in-memory source that cannot be
    /// re-opened) or the re-open fails — the caller then falls back to driving
    /// the range through this (shared) source instead.
    pub fn open_sibling(&self) -> Option<SeekableStepStream> {
        let path = self.path.as_ref()?;
        match SeekableStepStream::open(path) {
            Ok(Some(sibling)) => Some(sibling),
            _ => None,
        }
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
/// Only the `StepValues` event contributes variable snapshots. The other
/// value-stream event shapes (`BindVariable`, `Cell*`, `Assign*`, …) would drive
/// a cell/compound history, but the PRODUCTION Nim `MultiStreamTraceWriter` does
/// not emit them — it records inline full values per step (`StepValues`), so a
/// production split bundle's cell history is legitimately empty and locals come
/// entirely from this snapshot (M23e-2; see the module docs and
/// `tests/ctfs_split_only_full_db_test.rs`). The cell/compound accessors
/// (`cell_changes_for` / `compound_at`) are only populated on the legacy
/// `events.log` path. The builder emits at most one `StepValues` per step, but
/// we iterate defensively to tolerate any future shape.
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

// ───────────────────────────────────────────────────────────────────────────
// M25a — UNIFIED, range-scoped CTFS-stream replay engine.
//
// Owner guidance (M25): "Most likely we can end up with the SAME code that
// builds the omniscient DB tables and populates the local in-memory tables
// during replay by processing the events in the other regular CTFS streams
// until a breakpoint is hit." So the M24c lazy on-demand population
// (`LazyStepCache`/`LazyValueCache` range fill), the on-first-demand whole-table
// build (`lazy_full_steps`), and — when wired — the omniscient line-hit build
// must all share ONE "replay the regular CTFS streams forward over a step
// RANGE, reconstruct each step, populate the target sinks" routine, not two (or
// three) parallel implementations.
//
// The engine here is the single event-processing core. It is RANGE-PARAMETERIZED
// (it walks an arbitrary `Range<usize>` of step indices, building on M24c's
// range awareness) so the later M25b (LOCAL parallel-over-disjoint-ranges) and
// M25c (NETWORK forward-from-search) access strategies can drive it over their
// own ranges WITHOUT changing the per-step processing — they only choose WHICH
// ranges to replay and on WHICH threads. That access-strategy seam is left for
// M25b/M25c; this milestone unifies the processing core only.
// ───────────────────────────────────────────────────────────────────────────

/// Reconstruct a single `DbStep` for step `index` from the seekable `steps.dat`
/// stream plus the resident per-step call-key arrays — the ONE place a `DbStep`
/// is built on the lazy/replay path.
///
/// This is the exact reconstruction the M24c `LazyStepCache::reconstruct` did
/// inline; it is hoisted to a free function so every replay sink and every
/// range-fill caller produces byte-identical steps. Steps whose stream record
/// carries no source line (a Raise/Catch/ThreadSwitch marker) — or an
/// out-of-range read — degrade to a `(PathId(0), Line(0))` location, the same
/// neutral slot the materialized path produced for a marker step. `column` is
/// always `None`: the lazy/replay path is only taken for NON-column-aware
/// traces (column-aware traces keep eager materialization), exactly as the M24c
/// routing documents.
pub fn reconstruct_db_step(
    stream: &SeekableStepStream,
    call_keys: &[CallKey],
    global_call_keys: &[CallKey],
    index: usize,
) -> DbStep {
    let (path_id, line) = stream.step_line(StepId(index as i64)).unwrap_or((PathId(0), Line(0)));
    DbStep {
        step_id: StepId(index as i64),
        path_id,
        line,
        column: None,
        call_key: call_keys.get(index).copied().unwrap_or(CallKey(-1)),
        global_call_key: global_call_keys.get(index).copied().unwrap_or(CallKey(-1)),
    }
}

/// A SINK the unified replay engine feeds each reconstructed step into.
///
/// The engine ([`replay_steps_into_sinks`]) owns the "walk a step RANGE, decode
/// each `steps.dat` record once, reconstruct the `DbStep`" loop; a sink decides
/// what to DO with each step. This is the M25a unification seam: the M24c
/// per-slot lazy cache, the whole-table line→step map build, and the omniscient
/// line-hit build are all just different sinks over the SAME engine, so the
/// event-processing logic exists exactly once.
pub trait StepReplaySink {
    /// Accept the reconstructed `DbStep` at `index`. Called once per step in the
    /// engine's range, in ascending index order.
    fn accept_step(&mut self, index: usize, step: &DbStep);
}

/// Sink that records every step's `(file_id, line, step_id)` as an omniscient
/// LINE-HIT (`linehits.tc`), keyed by source line — the same line→step/tick
/// mapping `FfiOmniscientDb::push_line_hit` builds recorder-side.
///
/// This is the concrete proof that the omniscient-DB build and the lazy
/// in-memory population now go through the SAME engine: the lazy step path runs
/// [`replay_steps_into_sinks`] with the in-memory step sinks; an omniscient build
/// runs the SAME engine with THIS sink to populate `linehits.tc`. The engine
/// processes each `steps.dat` event exactly once for either target.
///
/// We collect into a plain `Vec` (rather than calling the FFI directly) so the
/// engine stays free of FFI/locking concerns and the omniscient build path can
/// drive the actual `push_line_hit` from the collected hits under whatever
/// locking discipline it already holds (see `omniscient_db::omniscient_ffi_lock`).
/// A step's `tick` on the line-only materialized path is its step index — the
/// monotonic execution counter the line-hit index keys on.
#[derive(Debug, Default)]
pub struct LineHitSink {
    /// `(file_id, line, tick)` triples in step order, ready to feed
    /// `FfiOmniscientDb::push_line_hit`.
    hits: Vec<(u32, u32, u64)>,
}

impl LineHitSink {
    /// A fresh, empty line-hit sink.
    pub fn new() -> Self {
        LineHitSink { hits: Vec::new() }
    }

    /// The collected `(file_id, line, tick)` line-hit triples, in step order.
    pub fn hits(&self) -> &[(u32, u32, u64)] {
        &self.hits
    }

    /// Consume the sink, returning the collected line-hit triples.
    pub fn into_hits(self) -> Vec<(u32, u32, u64)> {
        self.hits
    }
}

impl StepReplaySink for LineHitSink {
    fn accept_step(&mut self, index: usize, step: &DbStep) {
        // Only steps with a real source line contribute a line hit — exactly the
        // `line.0 >= 0` guard the in-memory `step_map` build uses, so the two
        // sinks see a consistent line→step set for the same range.
        if step.line.0 >= 0 {
            self.hits.push((step.path_id.0 as u32, step.line.0 as u32, index as u64));
        }
    }
}

/// Sink that builds the WHOLE-TABLE step views the slice / line-map accessors
/// need: the contiguous `DbStep` array (backing `steps_from`) and the
/// path → line → `[DbStep]` map (backing `steps_on_line` / `step_map_for_path`).
///
/// This is the same per-step processing the M24c `lazy_full_steps` loop did
/// inline; hoisting it into a sink lets the on-first-demand whole-table build
/// run through the SAME unified engine as the lazy per-slot fill and the
/// omniscient build (M25a). Driving it over `[0, count)` reproduces the eager
/// `open_new_format_nim` step-loop's `db.steps` / `db.step_map` byte-for-byte.
pub struct WholeStepTableSink {
    /// Contiguous reconstructed steps, pushed in ascending index order.
    steps: Vec<DbStep>,
    /// Per-path `line → [DbStep]` map, pre-sized to the trace's path count.
    step_map: Vec<std::collections::HashMap<usize, Vec<DbStep>>>,
}

impl WholeStepTableSink {
    /// A whole-table sink pre-sized for `path_count` paths and `step_count`
    /// steps (capacity hints only — the map grows if a step references a
    /// higher path id, exactly as the eager loop's `while step_map.len() <= …`
    /// guard does).
    pub fn new(path_count: usize, step_count: usize) -> Self {
        let mut step_map = Vec::with_capacity(path_count);
        step_map.resize_with(path_count, std::collections::HashMap::new);
        WholeStepTableSink {
            steps: Vec::with_capacity(step_count),
            step_map,
        }
    }

    /// Consume the sink, returning `(steps, step_map)`.
    pub fn into_parts(self) -> (Vec<DbStep>, Vec<std::collections::HashMap<usize, Vec<DbStep>>>) {
        (self.steps, self.step_map)
    }
}

impl StepReplaySink for WholeStepTableSink {
    fn accept_step(&mut self, _index: usize, step: &DbStep) {
        self.steps.push(*step);
        let path_id = step.path_id.0;
        while self.step_map.len() <= path_id {
            self.step_map.push(std::collections::HashMap::new());
        }
        if step.line.0 >= 0 {
            self.step_map[path_id].entry(step.line.0 as usize).or_default().push(*step);
        }
    }
}

/// The UNIFIED replay engine (M25a).
///
/// Walks the step `range` over the seekable `steps.dat` stream, reconstructing
/// each `DbStep` ONCE (via [`reconstruct_db_step`]) and feeding it to every sink
/// in ascending index order. Range-scoped by construction: callers pass the
/// exact `[lo, hi)` they need (one chunk for a point lookup, `[0, count)` for a
/// whole-table build, or a disjoint shard for a future M25b parallel fill) and
/// the engine touches only that range — it never materializes the whole table
/// unless the caller asks for `[0, count)`.
///
/// Because `steps.dat` reads decompress a fixed-size chunk and the reader caches
/// the most-recent chunk, iterating a contiguous range ascending inflates each
/// chunk at most once (the M24c bounded-decompression property is preserved —
/// the engine does not change the read pattern, only consolidates the loop).
///
/// The range is clamped to `[0, call_keys.len())` so an out-of-range request is
/// a no-op rather than a panic.
pub fn replay_steps_into_sinks(
    stream: &SeekableStepStream,
    call_keys: &[CallKey],
    global_call_keys: &[CallKey],
    range: std::ops::Range<usize>,
    sinks: &mut [&mut dyn StepReplaySink],
) {
    let lo = range.start;
    let hi = std::cmp::min(range.end, call_keys.len());
    for index in lo..hi {
        let step = reconstruct_db_step(stream, call_keys, global_call_keys, index);
        for sink in sinks.iter_mut() {
            sink.accept_step(index, &step);
        }
    }
}

// ───────────────────────────────────────────────────────────────────────────
// M25b — ACCESS-STRATEGY SEAM + LOCAL parallel disjoint-range whole-table build.
//
// M25a unified the per-step PROCESSING into one engine. M25b chooses HOW the
// whole-table build (`[0, count)`) drives that engine. An audit found NO network
// `.ct` loader today — every trace is LOCAL (on the filesystem) — so the LOCAL
// strategy is the active path: when the trace is available locally we can launch
// MULTIPLE THREADS that examine DISJOINT RANGES of the step file in parallel and
// merge the per-thread partials deterministically. The NETWORK forward strategy
// (replay forward from a search hit over a streamed `.ct`) is M25c; it is left as
// an explicit placeholder so M25c can slot in without touching the engine.
// ───────────────────────────────────────────────────────────────────────────

/// How the on-demand WHOLE-TABLE step build populates the step views (M25b seam).
///
/// The build always reconstructs the same `db.steps` + line→step map through the
/// SAME M25a engine ([`replay_steps_into_sinks`]); the strategy only chooses
/// WHICH ranges run on WHICH threads. Results are byte-identical across
/// strategies (the merge is deterministic and range-ordered).
#[derive(Debug, Clone, Copy)]
pub enum StepBuildStrategy {
    /// LOCAL filesystem trace (the active path, M25b): split `[0, count)` into
    /// `threads` disjoint contiguous ranges and replay each on its own thread
    /// over an INDEPENDENT per-thread reader (its own one-chunk cache), then
    /// merge in range order. `threads == 1` (or a trace too small to split)
    /// degrades to the sequential single-stream build.
    Local {
        /// Upper bound on the number of worker threads (and therefore disjoint
        /// ranges). Clamped to `[1, count]` at build time.
        threads: usize,
    },
    /// NETWORK forward-from-search trace (M25c placeholder, NOT active in M25b).
    /// Reserved so the network access strategy can plug in later without
    /// changing the engine or the whole-table sinks. The build falls back to the
    /// sequential single-stream path until M25c implements it.
    NetworkForward,
}

impl Default for StepBuildStrategy {
    /// All traces are LOCAL today (no network loader exists yet — see the M25b
    /// audit), so the default is the LOCAL parallel strategy sized to the
    /// machine's available parallelism, bounded to a sane cap.
    fn default() -> Self {
        StepBuildStrategy::Local {
            threads: default_build_threads(),
        }
    }
}

/// Upper bound on whole-table build worker threads: the machine's available
/// parallelism, clamped to `[1, MAX_BUILD_THREADS]`. A defensive cap keeps the
/// build from oversubscribing on very large machines (the work is I/O- and
/// decompression-bound; past a handful of disjoint readers there is no further
/// win and each extra reader re-opens the container).
fn default_build_threads() -> usize {
    const MAX_BUILD_THREADS: usize = 8;
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
        .clamp(1, MAX_BUILD_THREADS)
}

/// Split `[0, count)` into at most `threads` DISJOINT, contiguous, ascending
/// ranges that exactly tile `[0, count)` (no gaps, no overlap). The first
/// `count % threads` ranges get one extra element so the union is always the
/// whole `[0, count)` regardless of divisibility. Empty ranges are omitted, so a
/// `count` smaller than `threads` yields exactly `count` singleton ranges.
fn split_disjoint_ranges(count: usize, threads: usize) -> Vec<std::ops::Range<usize>> {
    if count == 0 {
        return Vec::new();
    }
    let threads = threads.clamp(1, count);
    let base = count / threads;
    let remainder = count % threads;
    let mut ranges = Vec::with_capacity(threads);
    let mut lo = 0usize;
    for i in 0..threads {
        // The first `remainder` shards are one element larger so the shards tile
        // `[0, count)` exactly even when `count` is not a multiple of `threads`.
        let len = base + if i < remainder { 1 } else { 0 };
        let hi = lo + len;
        if hi > lo {
            ranges.push(lo..hi);
        }
        lo = hi;
    }
    ranges
}

/// Build the WHOLE-TABLE step views (`Vec<DbStep>` + per-path line→`[DbStep]`
/// map) over `[0, count)` according to `strategy`, returning a result
/// BYTE-IDENTICAL to the sequential single-stream build (M25b).
///
/// * `LOCAL { threads }` with `threads > 1` AND a multi-range split AND a
///   re-openable container: splits `[0, count)` into disjoint contiguous ranges,
///   replays each on its OWN thread through the SAME M25a engine over an
///   INDEPENDENT per-thread reader, then MERGES the per-thread partials in range
///   order. The merge is deterministic: the `DbStep` arrays concatenate by
///   ascending range (so `steps[i]` is step `i`), and each path's line→step
///   lists concatenate in range order (so a line's step list is in ascending
///   step order — IDENTICAL to the sequential build, where the single ascending
///   walk appends in step order).
/// * Otherwise (sequential fallback: `threads <= 1`, `count` too small to split,
///   no re-openable sibling reader, or `NetworkForward`): drives the engine once
///   over `[0, count)` on the shared `stream`.
///
/// Concurrency safety: each thread owns a DISJOINT range and writes only its OWN
/// `WholeStepTableSink` (no shared mutable state between threads — the threads
/// never touch each other's partials, and each reads through its own reader).
/// The MERGE runs single-threaded after all threads join. There is therefore no
/// data race by construction.
pub fn build_whole_step_table(
    stream: &SeekableStepStream,
    call_keys: &[CallKey],
    global_call_keys: &[CallKey],
    path_count: usize,
    strategy: StepBuildStrategy,
) -> (Vec<DbStep>, Vec<std::collections::HashMap<usize, Vec<DbStep>>>) {
    let count = call_keys.len();

    // Decide the disjoint-range split. Only the LOCAL strategy parallelizes;
    // NetworkForward is an M25c placeholder that uses the sequential path today.
    let threads = match strategy {
        StepBuildStrategy::Local { threads } => threads,
        StepBuildStrategy::NetworkForward => 1,
    };
    let ranges = if threads > 1 {
        split_disjoint_ranges(count, threads)
    } else {
        Vec::new()
    };

    // Parallel path requires (a) more than one shard and (b) the ability to open
    // independent per-thread readers so threads don't serialize on the shared
    // `stream`'s `Mutex`. If either is unavailable, fall back to sequential.
    if ranges.len() > 1
        && let Some(partials) = build_partials_parallel(stream, call_keys, global_call_keys, path_count, &ranges)
    {
        return merge_partials(path_count, count, partials);
    }

    // ── Sequential fallback (M25a behaviour, unchanged) ──
    let mut sink = WholeStepTableSink::new(path_count, count);
    replay_steps_into_sinks(stream, call_keys, global_call_keys, 0..count, &mut [&mut sink]);
    sink.into_parts()
}

/// Replay each disjoint `range` on its OWN thread into a per-thread
/// `WholeStepTableSink`, returning the partials in RANGE ORDER, or `None` if a
/// per-thread reader could not be opened (caller falls back to sequential).
///
/// Each thread opens an INDEPENDENT sibling reader over the same container, so
/// the threads neither contend on the shared source's `Mutex` nor thrash a
/// single one-chunk cache. The shared `stream` is used only to open siblings
/// (and as the fallback reader for the first shard, which can reuse it since the
/// build thread is otherwise idle while workers run). We use [`std::thread::scope`]
/// so the borrowed `call_keys` / `global_call_keys` slices can be shared by
/// reference without `'static` bounds or extra allocation.
fn build_partials_parallel(
    stream: &SeekableStepStream,
    call_keys: &[CallKey],
    global_call_keys: &[CallKey],
    path_count: usize,
    ranges: &[std::ops::Range<usize>],
) -> Option<Vec<WholeStepTableSink>> {
    // Pre-open one independent reader per shard BEFORE spawning, so a failure to
    // re-open the container aborts cleanly to the sequential path rather than
    // leaving some shards built and some not.
    let mut readers: Vec<SeekableStepStream> = Vec::with_capacity(ranges.len());
    for _ in ranges {
        readers.push(stream.open_sibling()?);
    }

    let results: Vec<WholeStepTableSink> = std::thread::scope(|scope| {
        let handles: Vec<_> = ranges
            .iter()
            .cloned()
            .zip(readers)
            .map(|(range, reader)| {
                scope.spawn(move || {
                    // Each worker owns its DISJOINT range, its OWN reader, and its
                    // OWN sink — no shared mutable state, so the replay is race-free.
                    let span = range.len();
                    let mut sink = WholeStepTableSink::new(path_count, span);
                    replay_steps_into_sinks(
                        &reader,
                        call_keys,
                        global_call_keys,
                        range,
                        &mut [&mut sink],
                    );
                    sink
                })
            })
            .collect();
        // Join in spawn (== range) order so the partials stay range-ordered for a
        // deterministic merge. Propagate a worker panic by resuming it on this thread
        // rather than `expect()` (the bin crate denies clippy::expect_used).
        handles
            .into_iter()
            .map(|h| match h.join() {
                Ok(sink) => sink,
                Err(panic_payload) => std::panic::resume_unwind(panic_payload),
            })
            .collect()
    });

    Some(results)
}

/// Merge per-thread (range-ordered) `WholeStepTableSink` partials into the final
/// whole-table views, BYTE-IDENTICAL to the sequential single-stream build.
///
/// * `steps`: concatenated in range order — since the ranges tile `[0, count)`
///   ascending and each partial holds its range's steps in index order,
///   `steps[i]` is exactly step `i`.
/// * `step_map`: for each path, each line's step list from each partial (already
///   in ascending step order within the partial) is appended in range order, so
///   the final per-line list is in global ascending step order — IDENTICAL to the
///   sequential build's single ascending append.
fn merge_partials(
    path_count: usize,
    count: usize,
    partials: Vec<WholeStepTableSink>,
) -> (Vec<DbStep>, Vec<std::collections::HashMap<usize, Vec<DbStep>>>) {
    let mut steps: Vec<DbStep> = Vec::with_capacity(count);
    let mut step_map: Vec<std::collections::HashMap<usize, Vec<DbStep>>> = Vec::with_capacity(path_count);
    step_map.resize_with(path_count, std::collections::HashMap::new);

    for partial in partials {
        let (part_steps, part_map) = partial.into_parts();
        steps.extend(part_steps);
        // Grow the merged map if a shard referenced a higher path id than the
        // pre-sized count (mirrors the eager loop's `while step_map.len() <= …`).
        while step_map.len() < part_map.len() {
            step_map.push(std::collections::HashMap::new());
        }
        for (path_id, by_line) in part_map.into_iter().enumerate() {
            for (line, mut shard_steps) in by_line {
                step_map[path_id].entry(line).or_default().append(&mut shard_steps);
            }
        }
    }

    (steps, step_map)
}

/// Sink that memoizes each reconstructed step into a `LazyStepCache`'s per-slot
/// `OnceCell` array (M25a). This is what `LazyStepCache::fill_range_for` feeds
/// the unified engine, so the lazy per-slot fill shares the engine with the
/// whole-table / omniscient sinks instead of looping the reconstruction inline.
///
/// `get_or_init` keeps the fill idempotent: an already-populated neighbour slot
/// is left as-is (the reconstructed step the engine hands us is simply dropped),
/// preserving the exact populated-set / bounded-decompression behaviour the M24c
/// range-aware fill had (a step already in the cache is never overwritten).
struct SlotFillSink<'a> {
    slots: &'a [OnceCell<DbStep>],
}

impl StepReplaySink for SlotFillSink<'_> {
    fn accept_step(&mut self, index: usize, step: &DbStep) {
        if let Some(slot) = self.slots.get(index) {
            let _ = slot.get_or_init(|| *step);
        }
    }
}

/// A LAZY, per-step value cache backing the borrowing `variables_at()` accessor
/// for a PRODUCTION split bundle (M24c).
///
/// The M22 `variables_at_owned` hot path already reads a step's values ON DEMAND
/// through [`SeekableValueStream`] (bounded decompression). But the borrowing
/// `TraceReader::variables_at(step) -> Option<&[FullValueRecord]>` API — used by
/// the full-trace value-history scans in `db.rs` — needs STABLE storage to hand
/// out a `&[…]`. Previously the new-format reader (`open_new_format_nim`)
/// satisfied that by EAGERLY decoding every step's values into `db.variables` at
/// open time (O(trace size) materialization — the exact thing M24's acceptance
/// forbids).
///
/// This cache removes that eager cost: at open it allocates one EMPTY
/// [`OnceCell`] slot per step (cheap — no decode, no decompression). The first
/// borrow of step `N`'s values decompresses ONLY that step's `values.dat` chunk
/// (through the same seekable reader the owned path uses) and memoizes the
/// decoded records in the slot. Subsequent borrows of the same step return the
/// cached slice with no further work. So opening a production `.ct` no longer
/// decodes the whole value stream up front, while the borrowing API keeps
/// returning a stable, byte-identical slice.
///
/// The outer `Vec<OnceCell<…>>` is allocated once at the trace's step count and
/// never resized, so a `&` into a populated slot stays valid for the reader's
/// lifetime (the `Vec` never reallocates). `OnceCell` gives safe interior
/// mutability behind `&self`, matching the `variables_at(&self, …)` signature.
pub struct LazyValueCache {
    stream: Arc<SeekableValueStream>,
    /// One slot per step; `OnceCell` is empty until the step's values are first
    /// borrowed, then holds the boxed decoded records for the reader's lifetime.
    slots: Vec<OnceCell<Box<[FullValueRecord]>>>,
}

impl std::fmt::Debug for LazyValueCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let populated = self.slots.iter().filter(|c| c.get().is_some()).count();
        f.debug_struct("LazyValueCache")
            .field("steps", &self.slots.len())
            .field("populated", &populated)
            .finish()
    }
}

impl LazyValueCache {
    /// Build a lazy value cache over `step_count` steps, served from the seekable
    /// `values.dat` stream. No values are decoded here — every slot starts empty.
    pub fn new(stream: Arc<SeekableValueStream>, step_count: usize) -> LazyValueCache {
        let mut slots = Vec::with_capacity(step_count);
        slots.resize_with(step_count, OnceCell::new);
        LazyValueCache { stream, slots }
    }

    /// Number of steps this cache spans.
    pub fn len(&self) -> usize {
        self.slots.len()
    }

    /// `true` when the cache spans no steps.
    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }

    /// Number of step slots that have actually been decoded so far. Lets a test
    /// prove that opening the trace populated NOTHING (the whole value stream is
    /// not materialized at open) and that one borrow populated exactly one slot.
    pub fn populated_count(&self) -> usize {
        self.slots.iter().filter(|c| c.get().is_some()).count()
    }

    /// Number of distinct `values.dat` Zstd chunks the backing stream has
    /// inflated so far (bounded-decompression probe for the borrowing
    /// `variables_at` path, which reads through this cache's own stream).
    pub fn chunk_decompressions(&self) -> u64 {
        self.stream.chunk_decompressions()
    }

    /// Borrow step `step_id`'s values, decoding (and memoizing) them from the
    /// seekable stream on first access. Returns `None` for an out-of-range id so
    /// the caller can fall through to whatever fallback it has.
    ///
    /// The returned slice is byte-identical to the records the eager
    /// materialization used to push into `db.variables[step]` (both decode the
    /// same `StepValues` CBOR through [`step_values_to_full_records`]).
    pub fn get(&self, step_id: StepId) -> Option<&[FullValueRecord]> {
        if step_id.0 < 0 {
            return None;
        }
        let slot = self.slots.get(step_id.0 as usize)?;
        let boxed = slot.get_or_init(|| {
            // A step with no recorded values, or an out-of-range read the stream
            // declines, both yield an empty record list — the same answer the
            // eager path produced (`db.variables.push(vec![])`).
            self.stream
                .variables_at(step_id)
                .unwrap_or_default()
                .into_boxed_slice()
        });
        Some(boxed)
    }
}

/// A RANGE-AWARE, LAZY per-step `DbStep` cache backing the borrowing `step()`
/// accessor for a PRODUCTION split bundle (M24c-steps).
///
/// ## Why this exists
///
/// `open_new_format_nim` used to EAGERLY materialize the WHOLE `db.steps` array
/// at open: a chunked FFI loop decoded every step's `(path_id, line)` and pushed
/// a `DbStep` per step (O(trace size) — the exact cost M24's acceptance forbids
/// for production open). This cache removes that eager cost for the common
/// (non-column-aware) production bundle, mirroring the proven [`LazyValueCache`]
/// pattern but RANGE-AWARE: a point `step(id)` lookup fills only the RANGE
/// (one `steps.dat` chunk) that contains `id`, NOT the whole array.
///
/// ## What it stores
///
/// * `stream` — the seekable `steps.dat` source (M24a-1 spec format). A step's
///   `(path_id, line)` is decoded on demand, decompressing only its chunk.
/// * `call_keys` / `global_call_keys` — the per-step innermost / last-started
///   call keys. These are CHEAP O(steps) integer fills computed at open from the
///   call entry/exit ranges (the same arrays the eager loop built), kept resident
///   so a `DbStep` can be reconstructed without re-deriving the call mapping.
/// * `slots` — one [`OnceCell`] per step; empty until that step's chunk is first
///   filled, then holds the reconstructed `DbStep` for the reader's lifetime.
///
/// ## Range awareness
///
/// A `steps.dat` read decompresses a fixed-size chunk. To make the cache "aware
/// of which RANGES are populated", a first touch of step `N` fills EVERY slot in
/// `N`'s chunk `[chunk_lo, chunk_hi)` from that single decompression — so a
/// subsequent touch of a neighbour in the same range is a pure cache hit (no new
/// decompression), and the populated set is exactly the set of touched chunks.
/// The whole array is never filled by a point lookup.
///
/// ## Column-aware traces
///
/// This cache is built ONLY for NON-column-aware traces, where the seekable
/// stream's `(path_id, line)` is byte-identical to the eager materialization and
/// `DbStep.column` is always `None` (see the parity test and the routing in
/// `open_new_format_nim`). Column-aware traces keep eager materialization so the
/// `GlobalPositionDecoder` column / line override stays bit-for-bit correct.
///
/// The outer `Vec<OnceCell<…>>` is sized once to the step count and never
/// resized, so a `&DbStep` into a populated slot stays valid for the cache's
/// lifetime.
pub struct LazyStepCache {
    stream: Arc<SeekableStepStream>,
    /// Innermost (deepest) enclosing call key per step, computed at open.
    call_keys: Vec<CallKey>,
    /// Last-started call key at-or-before each step, computed at open.
    global_call_keys: Vec<CallKey>,
    /// One slot per step; empty until the step's chunk is first filled.
    slots: Vec<OnceCell<DbStep>>,
    /// Records-per-chunk granularity of the backing `steps.dat` stream — the size
    /// of the RANGE a single point lookup populates.
    chunk_size: usize,
}

impl std::fmt::Debug for LazyStepCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let populated = self.slots.iter().filter(|c| c.get().is_some()).count();
        f.debug_struct("LazyStepCache")
            .field("steps", &self.slots.len())
            .field("populated", &populated)
            .field("chunk_size", &self.chunk_size)
            .finish()
    }
}

impl LazyStepCache {
    /// Build a lazy step cache over `step_count` steps served from the seekable
    /// `steps.dat` stream. The two call-key arrays MUST be `step_count` long (the
    /// caller computes them from the call entry/exit ranges, exactly as the eager
    /// loop did). No step lines are decoded here — every slot starts empty.
    pub fn new(
        stream: Arc<SeekableStepStream>,
        call_keys: Vec<CallKey>,
        global_call_keys: Vec<CallKey>,
    ) -> LazyStepCache {
        let step_count = call_keys.len();
        debug_assert_eq!(
            global_call_keys.len(),
            step_count,
            "call-key arrays must agree on the step count"
        );
        let chunk_size = stream.chunk_size().max(1);
        let mut slots = Vec::with_capacity(step_count);
        slots.resize_with(step_count, OnceCell::new);
        LazyStepCache {
            stream,
            call_keys,
            global_call_keys,
            slots,
            chunk_size,
        }
    }

    /// Number of steps this cache spans.
    pub fn len(&self) -> usize {
        self.slots.len()
    }

    /// `true` when the cache spans no steps.
    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }

    /// Number of step slots actually filled so far. Lets a test prove that
    /// opening the trace populated NOTHING (the whole step array is not built at
    /// open) and that a point lookup filled only its RANGE (one chunk's worth of
    /// slots), not the whole array.
    pub fn populated_count(&self) -> usize {
        self.slots.iter().filter(|c| c.get().is_some()).count()
    }

    /// Number of distinct `steps.dat` Zstd chunks the backing stream has inflated
    /// so far (bounded-decompression probe for the borrowing `step` path).
    pub fn chunk_decompressions(&self) -> u64 {
        self.stream.chunk_decompressions()
    }

    /// Reconstruct a single `DbStep` from the seekable stream + the resident
    /// call-key arrays. Delegates to the UNIFIED [`reconstruct_db_step`] so the
    /// lazy path, the whole-table build, and the omniscient build all produce
    /// byte-identical steps (M25a).
    fn reconstruct(&self, index: usize) -> DbStep {
        reconstruct_db_step(&self.stream, &self.call_keys, &self.global_call_keys, index)
    }

    /// Fill every still-empty slot in the chunk-aligned RANGE that contains
    /// `index`, driving the UNIFIED [`replay_steps_into_sinks`] engine over that
    /// range with a slot-filling sink (M25a). Reading the FIRST slot in the range
    /// decompresses that chunk once; the remaining reads in the same range are
    /// cache hits on the stream's one-chunk cache, so the whole range is populated
    /// for a single decompression. Range awareness: a point lookup populates
    /// exactly its chunk's slots, never the whole array.
    fn fill_range_for(&self, index: usize) {
        let lo = (index / self.chunk_size) * self.chunk_size;
        let hi = std::cmp::min(lo + self.chunk_size, self.slots.len());
        let mut sink = SlotFillSink { slots: &self.slots };
        replay_steps_into_sinks(
            &self.stream,
            &self.call_keys,
            &self.global_call_keys,
            lo..hi,
            &mut [&mut sink],
        );
    }

    /// Replay a step `range` into a set of EXTERNAL sinks (M25a) through the
    /// SAME unified engine the per-slot fill uses, reusing this cache's seekable
    /// `steps.dat` stream and resident call-key arrays. This is the shared entry
    /// the on-first-demand whole-table build (`lazy_full_steps`) and the
    /// omniscient line-hit build drive, so no caller re-implements the
    /// "decode each step, reconstruct it, populate the target" logic.
    ///
    /// The lazy per-slot cache is NOT touched here — the external sinks own their
    /// own storage. Iterating `[0, len())` ascending inflates each `steps.dat`
    /// chunk at most once (the engine preserves the read pattern).
    pub fn replay_range(&self, range: std::ops::Range<usize>, sinks: &mut [&mut dyn StepReplaySink]) {
        replay_steps_into_sinks(&self.stream, &self.call_keys, &self.global_call_keys, range, sinks);
    }

    /// Build the WHOLE-TABLE step views (`Vec<DbStep>` + per-path line→`[DbStep]`
    /// map) for this cache's full `[0, len())` range according to `strategy`
    /// (M25b). On the LOCAL strategy with parallelism, `[0, len())` is split into
    /// disjoint ranges replayed on independent per-thread readers and merged
    /// deterministically — byte-identical to the sequential single-stream build.
    ///
    /// This is the parallel counterpart of driving [`Self::replay_range`] over
    /// `[0, len())` with a single [`WholeStepTableSink`]; the on-first-demand
    /// `lazy_full_steps` whole-table build calls THIS so the local parallel
    /// strategy is used while the per-slot point-lookup fill stays single-chunk
    /// lazy. Point lookups never go through here.
    pub fn build_whole_table(
        &self,
        path_count: usize,
        strategy: StepBuildStrategy,
    ) -> (Vec<DbStep>, Vec<std::collections::HashMap<usize, Vec<DbStep>>>) {
        build_whole_step_table(&self.stream, &self.call_keys, &self.global_call_keys, path_count, strategy)
    }

    /// Borrow step `step_id`, filling its RANGE from the seekable stream on first
    /// access. Returns `None` for an out-of-range id so the caller can fall
    /// through. The returned `&DbStep` is byte-identical to the record the eager
    /// materialization used to push into `db.steps[step_id]` for a non-column-aware
    /// trace (both decode the same packed `(path_id, line)` and derive the same
    /// call keys).
    pub fn get(&self, step_id: StepId) -> Option<&DbStep> {
        if step_id.0 < 0 {
            return None;
        }
        let index = step_id.0 as usize;
        if index >= self.slots.len() {
            return None;
        }
        // Fill the whole range so neighbours are free; then borrow this slot.
        self.fill_range_for(index);
        self.slots[index].get()
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::panic)]
mod tests {
    use super::*;

    /// `split_disjoint_ranges` must TILE `[0, count)` exactly: no gaps, no
    /// overlaps, ascending, and the union is the whole range — the invariant the
    /// M25b parallel build relies on for `steps[i] == step i` after the merge.
    fn assert_tiles(count: usize, threads: usize) {
        let ranges = split_disjoint_ranges(count, threads);
        // Union covers [0, count) exactly, ascending, contiguous.
        let mut expected = 0usize;
        for r in &ranges {
            assert_eq!(r.start, expected, "range {r:?} must start where the previous ended");
            assert!(r.end > r.start, "no empty ranges (got {r:?})");
            expected = r.end;
        }
        assert_eq!(expected, count, "ranges must cover all of [0, {count})");
        // At most `threads` shards, and exactly `min(threads, count)` when count>0.
        if count > 0 {
            assert_eq!(ranges.len(), threads.clamp(1, count), "shard count for count={count}, threads={threads}");
        } else {
            assert!(ranges.is_empty());
        }
    }

    /// The disjoint-range split tiles `[0, count)` exactly across a spread of
    /// divisible and indivisible cases, including count < threads.
    #[test]
    fn disjoint_ranges_tile_exactly() {
        for &(count, threads) in &[
            (0usize, 4usize),
            (1, 4),
            (3, 4),   // fewer steps than threads → singleton shards
            (8, 4),   // evenly divisible
            (10, 4),  // remainder 2 → first two shards larger
            (5000, 7),
            (5002, 8),
            (100, 1), // single thread → one shard
        ] {
            assert_tiles(count, threads);
        }
    }

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
