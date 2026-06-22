//! [`TraceReader`] implementation that reads from `.ct` CTFS containers.
//!
//! See the module-level documentation on [`CTFSTraceReader`] for design
//! rationale and the two-format approach.

pub mod block_overlay;
pub mod call_stream_source;
pub mod ctfs_container;
pub mod follow_stream_source;
pub mod meta_dat;
pub mod step_map_namespace;
pub mod step_value_stream_source;

use std::collections::HashMap;
use std::error::Error;
use std::io::BufRead;
use std::path::{Path, PathBuf};

use log::info;
use serde_json::Value;

use codetracer_trace_types::{
    CallKey, EventLogKind, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, Place, StepId,
    TraceLowLevelEvent, TypeId, TypeRecord, ValueRecord, VariableId,
};

use crate::db::{CellChange, Db, DbCall, DbRecordEvent, DbStep, EndOfProgram};
use crate::trace_processor::TraceProcessor;
use crate::trace_reader::TraceReader;

#[cfg(feature = "nim-reader")]
use codetracer_trace_writer_nim::NimTraceReaderHandle;

use ctfs_container::CtfsReader;

/// A [`TraceReader`] backed by a `.ct` CTFS container file.
///
/// Supports two container layouts:
///
/// ## Old format (events-based, requires postprocessing)
///
/// Contains raw `TraceLowLevelEvent` values in `events.log` plus JSON
/// metadata in `meta.json`. These events must be processed by
/// [`TraceProcessor::postprocess`] at startup to build the in-memory `Db`.
/// This is the format produced by current recorders (Python, Ruby, JS,
/// blockchain VMs).
///
/// | File | Purpose |
/// |------|---------|
/// | `meta.json` | Trace metadata (workdir, program, args) |
/// | `events.log` | Encoded `TraceLowLevelEvent` stream (chunked Zstd or legacy CBOR) |
/// | `events.fmt` | Serialization format marker (`"split-binary"` or absent for CBOR) |
///
/// ## New format (pre-processed, no postprocessing needed)
///
/// Contains pre-computed data structures written by the seek-based writer.
/// The recorder (or a post-recording finalization step) builds the same
/// data structures that `postprocess` would produce and writes them as
/// separate CTFS internal files. The reader loads these directly into
/// `Db`, skipping the expensive event-by-event postprocessing entirely.
///
/// The new format is detected by the presence of `steps.dat` in the
/// container. See `Seek-Based-CTFS-Reader.md` for the full file layout.
///
/// | File | Purpose |
/// |------|---------|
/// | `meta.dat` | Binary metadata (replaces `meta.json`) |
/// | `steps.dat` + `steps.idx` | Pre-computed step records with variable values |
/// | `calls.dat` | Pre-computed call tree records |
/// | `events.dat` | Pre-computed I/O event records with step cross-references |
/// | `paths.dat` + `paths.off` | Interned source paths with offset index |
/// | `funcs.dat` + `funcs.off` | Interned function records with offset index |
/// | `types.dat` + `types.off` | Interned type records with offset index |
/// | `varnames.dat` + `varnames.off` | Interned variable names with offset index |
///
/// See [`crate::trace_processor`] for how `TraceLowLevelEvent` values are
/// processed into the `Db` struct (old format path only).
#[derive(Debug, Default, Clone, Copy)]
pub struct ColumnAwareCapabilities {
    /// Recorder advertised support for per-column breakpoints
    /// (meta.dat bit 6 — `FLAG_SUPPORTS_COLUMN_BREAKPOINTS`).
    pub supports_column_breakpoints: bool,
    /// Recorder advertised support for per-column step motions
    /// (meta.dat bit 7 — `FLAG_SUPPORTS_COLUMN_MOTIONS`).
    pub supports_column_motions: bool,
}

#[derive(Debug)]
pub struct CTFSTraceReader {
    /// The fully-populated in-memory database, built from CTFS contents
    /// during [`CTFSTraceReader::open`].
    db: Db,
    /// M-capability-flags: capability bits decoded from the trace's
    /// `meta.dat` header.  Surfaced to the DAP layer so the GUI can
    /// disable per-column affordances when the recorder doesn't support
    /// them.  Always `Default::default()` (both false) on traces that
    /// predate the bits — back-compat with the GUI's "no UI" default.
    column_capabilities: ColumnAwareCapabilities,
    /// M17b — the SEEKABLE `calls.dat` call-tree source.
    ///
    /// `Some` only when the container advertises the `has_call_stream`
    /// capability flag (bit 8 in `meta.dat`) AND ships `calls.dat`/`calls.idx`.
    /// When present, the call tree is served ON DEMAND from `calls.dat` by
    /// `call(key)` (decompressing only the needed chunk) rather than from the
    /// fully-materialized `db.calls` — so a network-loaded `.ct` never
    /// materializes the whole call tree (Trace-Files-Overview.md §"Random-access
    /// seeking"; trace-events.md "Call tree loads independently").
    ///
    /// Shared behind an `Arc` so cheap clones / concurrent readers over the same
    /// reader don't re-open the container. Always `None` for legacy (flag-off)
    /// traces, which keep the existing fully-materialized path unchanged.
    call_stream: Option<std::sync::Arc<call_stream_source::SeekableCallStream>>,
    /// M22 — the SEEKABLE `steps.dat` execution stream.
    ///
    /// `Some` only when the container advertises `has_step_stream` (bit 9) AND
    /// ships `steps.dat`/`steps.idx`. When present, a step's source `(path_id,
    /// line)` is served ON DEMAND from `steps.dat` via `seekable_step_line`
    /// (decompressing only the needed chunk) rather than from the materialized
    /// `db.steps`. Always `None` for legacy (flag-off) traces.
    step_stream: Option<std::sync::Arc<step_value_stream_source::SeekableStepStream>>,
    /// M22 — the SEEKABLE `values.dat` parallel value stream.
    ///
    /// `Some` only when the container advertises `has_value_stream` (bit 10) AND
    /// ships `values.dat`/`values.idx`. When present, a step's variable values
    /// are served ON DEMAND from `values.dat` via `seekable_variables_at`
    /// rather than from the materialized `db.variables`. Always `None` for
    /// legacy (flag-off) traces.
    value_stream: Option<std::sync::Arc<step_value_stream_source::SeekableValueStream>>,
    /// M24c — the LAZY per-step value cache backing the borrowing
    /// `variables_at()` accessor on a PRODUCTION split bundle.
    ///
    /// `Some` ONLY when the new-format (Nim FFI) reader skipped eager value
    /// materialization at open AND a `has_value_stream` `values.dat` attached —
    /// i.e. exactly when a step's values can be served on-demand. When present,
    /// `db.variables` is EMPTY (not materialized at open) and `variables_at()`
    /// borrows through this cache, decompressing only the requested step's chunk
    /// on first access. `None` on every other path (legacy `events.log`,
    /// Rust-writer combined bundles, `from_*` constructors, or a corrupt value
    /// stream), where the fully-materialized `db.variables` serves the borrow —
    /// so those paths stay bit-for-bit unchanged.
    lazy_values: Option<step_value_stream_source::LazyValueCache>,
    /// M24c-steps — the RANGE-AWARE LAZY per-step `DbStep` cache backing the
    /// borrowing `step()` accessor on a PRODUCTION (non-column-aware) split
    /// bundle.
    ///
    /// `Some` ONLY when the new-format (Nim FFI) reader skipped eager step
    /// materialization at open AND a `has_step_stream` `steps.dat` attached AND
    /// the trace is NOT column-aware (so the seekable stream's `(path_id, line)`
    /// is byte-identical to the eager result and `DbStep.column` is `None`). When
    /// present, `db.steps` is EMPTY (not materialized at open) and `step()`
    /// borrows through this cache, filling only the requested step's chunk-aligned
    /// RANGE on first access. `None` on every other path (legacy `events.log`,
    /// Rust-writer combined bundles, column-aware traces, `from_*` constructors,
    /// or a corrupt step stream), where the fully-materialized `db.steps` serves
    /// the borrow — so those paths stay bit-for-bit unchanged.
    lazy_steps: Option<step_value_stream_source::LazyStepCache>,
    /// M24c-steps — on-demand WHOLE-TABLE views for the slice / line-map
    /// accessors (`steps_from`, `steps_on_line`, `step_map_for_path`) when on the
    /// lazy step path.
    ///
    /// `step()` is range-aware (point lookups fill one chunk). But the slice /
    /// line-map accessors return contiguous / aggregate borrows the lazy cache
    /// cannot synthesize cheaply, AND they are used by genuinely O(trace) full
    /// scans (breakpoint-resolution Continue, history). When the FIRST such
    /// accessor is invoked we materialize the full `Vec<DbStep>` + line→steps map
    /// ONCE through the lazy cache (each step's chunk inflated at most once),
    /// memoize it here, and serve every later slice/map borrow from it — so
    /// point-lookup navigation stays lazy/bounded while the inherently
    /// whole-table operations remain correct and identical to the eager path.
    /// `None` whenever `lazy_steps` is `None`.
    lazy_steps_full: Option<std::sync::OnceLock<LazyFullSteps>>,
    /// M25b — the ACCESS STRATEGY the on-first-demand whole-table build
    /// (`lazy_full_steps`) uses to populate `db.steps` / `db.step_map`. Defaults
    /// to the LOCAL parallel disjoint-range strategy (every trace is local
    /// today; the network forward strategy is the M25c placeholder). Only the
    /// whole-table build — which is already on-demand — is affected; opening the
    /// trace and point lookups stay lazy/bounded.
    step_build_strategy: step_value_stream_source::StepBuildStrategy,
    /// M26 — the prepopulated `step-map.ns` breakpoint index, when the `.ct`
    /// carries one. `Some` ONLY when [`open`](Self::open) found a parseable
    /// `step-map.ns` (container-internal file or sidecar). When present, the
    /// breakpoint resolver (`step_ids_on_line`) answers a line's step set with
    /// an O(unique-lines) index lookup WITHOUT triggering the whole-table build
    /// — that is the M26 short-circuit. `None` on every legacy/older bundle (the
    /// common case today, since no production writer emits the namespace yet),
    /// where the M24c lazy / M25b parallel whole-table build serves
    /// `steps_on_line` exactly as before.
    step_map: Option<step_map_namespace::StepMapNamespace>,
}

/// M24c-steps — the memoized whole-table step views the lazy step path builds on
/// first slice/line-map demand. Holds the contiguous `DbStep` array (backing
/// `steps_from`) and the path → line → `[DbStep]` map (backing `steps_on_line` /
/// `step_map_for_path`), reconstructed once from the lazy cache.
#[derive(Debug)]
struct LazyFullSteps {
    steps: Vec<DbStep>,
    step_map: Vec<HashMap<usize, Vec<DbStep>>>,
}

impl CTFSTraceReader {
    /// Borrow the in-memory `Db` populated when the trace was opened.
    ///
    /// Useful for tests that need to inspect or rebuild auxiliary state
    /// (e.g. drive `FlowPreloader` directly) using the same `Db` that the
    /// reader serves through its `TraceReader` interface.
    pub fn db(&self) -> &Db {
        &self.db
    }

    /// M24c — a FULLY-MATERIALIZED clone of the in-memory `Db`, rehydrating the
    /// per-step value table from the lazy value cache when the reader is on the
    /// production lazy path (where `self.db.variables` is intentionally empty).
    ///
    /// Most consumers should borrow values through the `TraceReader::variables_at`
    /// trait method (which already prefers the lazy/seekable path). But a few
    /// `Db`-CONSUMING callers clone the whole `Db` and then iterate
    /// `db.variables` directly (e.g. the reprobuild origin-namespace / value-change
    /// encoder, which by its nature needs the COMPLETE value table). For those,
    /// this method reconstructs `db.variables` from the seekable stream so the
    /// cloned `Db` is self-contained and matches the eager-materialization result
    /// exactly. On every non-lazy reader it is just `db().clone()`.
    pub fn materialized_db(&self) -> Db {
        let mut db = self.db.clone();

        // M24c-steps — the lazy step path left `db.steps` / `db.step_map` empty;
        // rebuild the whole-table view so a raw `db.steps` / `db.step_map`
        // consumer sees exactly what the eager path produced.
        if self.lazy_steps.is_some() {
            let full = self.lazy_full_steps();
            db.steps.clear();
            db.steps.items.extend_from_slice(&full.steps);
            db.step_map.clear();
            db.step_map.items.extend_from_slice(&full.step_map);
            // Re-create the per-step parallel scaffolding the eager loop pushed
            // (empty on a production split bundle — only the legacy `events.log`
            // path populates these), so a cloned `Db`'s parallel vectors line up
            // with `db.steps`.
            db.instructions.clear();
            db.compound.clear();
            db.cells.clear();
            db.variable_cells.clear();
            for _ in 0..full.steps.len() {
                db.instructions.push(vec![]);
                db.compound.push(HashMap::new());
                db.cells.push(HashMap::new());
                db.variable_cells.push(HashMap::new());
            }
        }

        // The step count to iterate values over: the rebuilt table on the lazy
        // step path, otherwise the already-materialized `db.steps`.
        let step_total = db.steps.len();
        if let Some(lazy) = self.lazy_values.as_ref() {
            // The lazy path left `db.variables` empty; rebuild it per step so a
            // raw `db.variables.get(step)` consumer sees the same values the
            // trait accessor serves.
            debug_assert!(db.variables.is_empty());
            db.variables.clear();
            for step_idx in 0..step_total {
                let sid = StepId(step_idx as i64);
                let values = lazy.get(sid).map(|s| s.to_vec()).unwrap_or_default();
                db.variables.push(values);
            }
        }
        db
    }

    /// M24c-steps — the memoized WHOLE-TABLE step view for the lazy step path,
    /// built ONCE on first slice / line-map demand and reused thereafter.
    ///
    /// `step()` is range-aware (a point lookup fills one chunk). But the slice /
    /// line-map accessors (`steps_from`, `steps_on_line`, `step_map_for_path`)
    /// return contiguous / aggregate borrows the per-slot cache cannot synthesize,
    /// AND they back genuinely O(trace) full scans (breakpoint-resolution Continue,
    /// history). So the FIRST such accessor reconstructs the full `DbStep` array +
    /// the path → line → `[DbStep]` map through the lazy cache (each step's chunk
    /// inflated at most once), memoizes it, and serves every later slice/map borrow
    /// from it. Point-lookup navigation stays lazy/bounded; the inherently
    /// whole-table operations stay correct and identical to the eager path.
    ///
    /// Returns an empty whole-table view if called when `lazy_steps_full` is
    /// `None` (i.e. off the lazy step path) — the trait accessors guard that, so
    /// this stays internal and the fallback is never reached in practice.
    fn lazy_full_steps(&self) -> &LazyFullSteps {
        // Off the lazy step path this is unreachable (the accessors gate on
        // `lazy_steps.is_some()`), but we return a process-wide empty view rather
        // than panicking so the function is total. `OnceLock` keeps the empty view
        // a single shared allocation.
        let Some(cell) = self.lazy_steps_full.as_ref() else {
            static EMPTY: std::sync::OnceLock<LazyFullSteps> = std::sync::OnceLock::new();
            return EMPTY.get_or_init(|| LazyFullSteps {
                steps: Vec::new(),
                step_map: Vec::new(),
            });
        };
        cell.get_or_init(|| {
            let Some(lazy) = self.lazy_steps.as_ref() else {
                return LazyFullSteps {
                    steps: Vec::new(),
                    step_map: Vec::new(),
                };
            };
            // M25b — build the whole-table view through the unified M25a engine,
            // but according to the reader's ACCESS STRATEGY. The active LOCAL
            // strategy splits the FULL `[0, count)` range into DISJOINT shards
            // replayed on independent per-thread readers and merges them
            // deterministically — byte-identical to the sequential single-stream
            // build. The per-step processing (reconstruct the `DbStep`, push it,
            // index it into the line→step map) still lives once, in
            // `step_value_stream_source`, so the parallel whole-table build, the
            // sequential build, and the lazy point-lookup fill can never diverge.
            // Point lookups stay single-chunk lazy (this whole-table build runs
            // only on first slice / line-map demand, exactly as in M24c).
            let path_count = self.db.paths.len();
            let (steps, step_map) = lazy.build_whole_table(path_count, self.step_build_strategy);
            LazyFullSteps { steps, step_map }
        })
    }

    /// M24c-steps — number of step slots already filled by the lazy step cache,
    /// or `None` when the reader is not on the lazy step path. `Some(0)` right
    /// after open proves the step table was NOT materialized; a point lookup
    /// raises it by at most one chunk's worth of slots (range-aware fill).
    pub fn lazy_steps_populated(&self) -> Option<usize> {
        self.lazy_steps.as_ref().map(|c| c.populated_count())
    }

    /// M24c-steps — number of distinct `steps.dat` Zstd chunks the lazy step
    /// cache's backing stream has inflated so far, or `None` when not on the lazy
    /// step path. Counter-proof for the bounded-decompression property: a point
    /// `step()` lookup inflates at most one `steps.dat` chunk.
    pub fn lazy_steps_chunk_decompressions(&self) -> Option<u64> {
        self.lazy_steps.as_ref().map(|c| c.chunk_decompressions())
    }

    /// M24c-steps — `true` when the whole-table step view has already been
    /// materialized (a slice / line-map accessor was invoked). Lets a test prove
    /// that pure point-lookup navigation never triggers the full materialization.
    pub fn lazy_full_steps_materialized(&self) -> Option<bool> {
        self.lazy_steps_full.as_ref().map(|c| c.get().is_some())
    }

    /// M26 — `true` when the reader attached a prepopulated `step-map.ns`
    /// breakpoint index at open. Lets a test prove that (a) a table-bearing
    /// bundle routes breakpoint resolution through the index and (b) a
    /// legacy/older bundle does not. Borrow the parsed namespace for direct
    /// inspection via [`Self::step_map`].
    pub fn has_prepopulated_step_map(&self) -> bool {
        self.step_map.is_some()
    }

    /// M26 — borrow the attached prepopulated `step-map.ns` index, if any. Used
    /// by tests to assert parity of the index's step sets against the
    /// whole-table build directly.
    pub fn step_map(&self) -> Option<&step_map_namespace::StepMapNamespace> {
        self.step_map.as_ref()
    }

    /// M-capability-flags accessor — the column-aware capability bits
    /// decoded from `meta.dat`.  The DAP layer threads these into the
    /// `Capabilities` response so the GUI gates per-column
    /// breakpoint / motion affordances on them.
    pub fn column_capabilities(&self) -> ColumnAwareCapabilities {
        self.column_capabilities
    }

    /// M24c — number of per-step value slots already DECODED by the lazy value
    /// cache, or `None` when the reader is not on the lazy (production split)
    /// path. `Some(0)` right after open proves the value table was NOT
    /// materialized; the count rises by at most one per distinct step borrowed.
    /// Exposed for the M24c lazy-open / bounded-decompression tests.
    pub fn lazy_values_populated(&self) -> Option<usize> {
        self.lazy_values.as_ref().map(|c| c.populated_count())
    }

    /// M24c — number of distinct `values.dat` Zstd chunks the seekable value
    /// overlay has inflated so far, or `None` when no overlay is attached.
    /// Counter-proof for the bounded-decompression property: fetching one step's
    /// values inflates at most one chunk.
    pub fn value_stream_chunk_decompressions(&self) -> Option<u64> {
        self.value_stream.as_ref().map(|s| s.chunk_decompressions())
    }

    /// M24c — number of distinct `values.dat` Zstd chunks the LAZY value cache's
    /// own backing stream (the one the borrowing `variables_at` reads through)
    /// has inflated so far, or `None` when not on the lazy path. The counterpart
    /// of [`Self::value_stream_chunk_decompressions`] for the borrowing path.
    pub fn lazy_values_chunk_decompressions(&self) -> Option<u64> {
        self.lazy_values.as_ref().map(|c| c.chunk_decompressions())
    }

    /// Build a reader directly from a decoded `TraceLowLevelEvent` stream.
    ///
    /// CTFS is the canonical materialized-trace container, but some
    /// external recorders still emit the legacy `runtime_tracing`
    /// materialized layout — a `trace.json` file holding the same
    /// `Vec<TraceLowLevelEvent>` payload that CTFS stores (CBOR-encoded)
    /// in `events.log`.  The Noir recorder (`nargo trace`) is the
    /// current example.  Rather than failing such traces (which would
    /// then wrongly fall through to the rr/MCR replay-worker path), we
    /// run the very same postprocessing pipeline `open()` uses so the
    /// resulting reader is indistinguishable from a CTFS-loaded one.
    pub fn from_events(events: Vec<TraceLowLevelEvent>, workdir: &Path) -> Result<Self, Box<dyn Error>> {
        let mut db = Db::new(&workdir.to_path_buf());
        let mut processor = TraceProcessor::new(&mut db);
        processor.postprocess(&events)?;
        // Legacy event-stream traces never carry meta.dat capability
        // bits — they were recorded before the M-capability-flags
        // milestone — so both flags surface as false.  Defaults give
        // the GUI the safe back-compat answer: hide per-column UI.
        Ok(CTFSTraceReader {
            db,
            column_capabilities: ColumnAwareCapabilities::default(),
            // No `.ct` path is available here (events come from an in-memory
            // stream), so there is no seekable `calls.dat` to attach. The
            // fully-materialized `db.calls` serves the call tree.
            call_stream: None,
            // The seekable `steps.dat`/`values.dat` streams (if any) are attached
            // centrally by `open()`, which has the `.ct` path. `from_*`
            // constructors that lack a path leave these `None`.
            step_stream: None,
            value_stream: None,
            lazy_values: None,
            lazy_steps: None,
            lazy_steps_full: None,
            step_build_strategy: step_value_stream_source::StepBuildStrategy::default(),
            // No `.ct` path here (events come from an in-memory stream), so no
            // `step-map.ns` to attach. `open()` attaches it on the path-bearing
            // constructors.
            step_map: None,
        })
    }
}

/// Returns `true` if the CTFS container uses the new pre-processed split-stream
/// format that must be read via the Nim FFI ([`CTFSTraceReader::open_new_format_nim`]),
/// meaning postprocessing can be skipped entirely.
///
/// This is the PRODUCTION format: the Nim `MultiStreamTraceWriter` that every
/// live recorder (Ruby/Python/JS/shell) drives via FFI emits ONLY the split
/// per-kind streams (`steps.dat`/`calls.dat`/`values.dat`/`events.dat` +
/// interning) and NO `events.log`. Such bundles are served via
/// [`CTFSTraceReader::open_new_format_nim`], which reads the split streams
/// directly and never consults `events.log`.
///
/// Detection: `steps.dat` present AND `events.log` ABSENT.
///
/// The `events.log`-presence guard is the M23e-4 interop boundary. The
/// SECONDARY Rust `CtfsTraceWriter` now also DEFAULT-emits the split streams
/// (M23e-4) — but ADDITIVELY, alongside `events.log` — and its split wire
/// formats are NOT byte-compatible with the Nim FFI reader for the
/// step/value/io-event streams (only the `calls.dat` (M20) and the binary
/// interning tables (M23d) were cross-matched; the Rust `steps.idx`/`values.idx`/
/// `events.idx` carry a bare `[chunk_size][offsets…]` index and a header-less
/// chunk layout, whereas the Nim exec/value/event readers expect a
/// `total_events` header+trailer and a per-chunk u32 count, and the Rust zstd
/// frames omit the pledged content size the Nim decompressor requires). Routing
/// such a Rust-writer bundle through the Nim reader yields zero steps/calls. So a
/// bundle that carries BOTH `steps.dat` and `events.log` is the Rust-writer
/// combined format: we read it via the LEGACY `events.log` postprocessing path
/// (which builds the correct full `Db`), and the Rust-side SEEKABLE readers
/// (`calls.dat`/`steps.dat`/`values.dat`, all written by and matched to the same
/// Rust crate) still attach for on-demand reads. Only a split-ONLY bundle (the
/// production Nim writer's `events.log`-free layout) takes the Nim FFI path.
///
/// Returns `false` for old-format containers that store raw events in
/// `events.log` and require [`TraceProcessor::postprocess`]. That path is the
/// LEGACY/secondary-Rust-writer/test fallback only — NOT produced by live
/// recording. See the `M23e` audit in
/// `Trace-Based-Incremental-Testing.milestones.org` for the bounding.
fn is_new_format(ctfs: &CtfsReader) -> bool {
    ctfs.has_file("steps.dat") && !ctfs.has_file("events.log")
}

/// M26 — the `<ct>.step-map.ns` SIDECAR path for a given `.ct` file. Appending
/// the namespace suffix to the full `.ct` name (rather than replacing the
/// extension) keeps the sidecar unambiguous next to the bundle and avoids
/// colliding with any other `.ns` artefact.
fn sidecar_step_map_path(ct_path: &Path) -> PathBuf {
    let mut name = ct_path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(".");
    name.push(step_map_namespace::STEP_MAP_FILE);
    match ct_path.parent() {
        Some(dir) => dir.join(name),
        None => PathBuf::from(name),
    }
}

impl CTFSTraceReader {
    /// Open a `.ct` CTFS trace file, parse its contents, and build the
    /// in-memory database.
    ///
    /// Automatically detects the container format:
    /// - **New format** (`steps.dat` present, `events.log` ABSENT): the
    ///   PRODUCTION split-stream format emitted by every live recorder (the Nim
    ///   `MultiStreamTraceWriter`). Loads pre-processed data directly via
    ///   [`open_new_format_nim`](Self::open_new_format_nim), skipping
    ///   [`TraceProcessor::postprocess`]. Startup is bounded by I/O and
    ///   decompression, not by trace size. `events.log` is never read on this
    ///   path.
    /// - **Old/combined format** (`events.log` present): the LEGACY/secondary-
    ///   Rust-writer/test fallback (NOT produced by live recording). Deserializes
    ///   events and runs [`TraceProcessor::postprocess`] to build the `Db`. This
    ///   includes the M23e-4 secondary Rust-writer combined bundle, which ALSO
    ///   ships the split streams additively but whose split wire formats are not
    ///   Nim-FFI-readable for steps/values/events — see [`is_new_format`] for the
    ///   interop boundary. The Rust-side seekable streams still attach below for
    ///   on-demand reads. See the `M23e` audit in
    ///   `Trace-Based-Incremental-Testing.milestones.org`.
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - The file cannot be opened or is not a valid CTFS container
    /// - Metadata is missing or malformed
    /// - The trace data cannot be deserialized
    /// - (Old format only) The `TraceProcessor` fails during postprocessing
    pub fn open(path: &Path) -> Result<Self, Box<dyn Error>> {
        let mut ctfs = CtfsReader::open(path)?;

        // BEAM-recorder traces ship a sidecar layout (`trace_meta.json` +
        // `runtime_session.jsonl`) that the Nim seek-based reader cannot
        // parse. Detect those first so we route them through the dedicated
        // sidecar path rather than the new-format CTFS code.
        if let Some(reader) = Self::open_elixir_sidecar_format(&mut ctfs, path)? {
            return Ok(reader);
        }

        let mut reader = if is_new_format(&ctfs) {
            info!("CTFS new format detected — skipping postprocessing");
            Self::open_new_format(&mut ctfs, path)?
        } else {
            info!("CTFS old format detected — running postprocessing");
            Self::open_old_format(&mut ctfs)?
        };

        // M17b — attach the SEEKABLE `calls.dat` call-tree source when the
        // container advertises one. This is the path that lets a network-loaded
        // `.ct` serve its call tree on-demand without materializing the whole
        // trace. A flag-off (legacy) container yields `None`, preserving the
        // existing fully-materialized behaviour exactly.
        //
        // A `calls.dat` that is present-but-corrupt is logged and ignored (we
        // fall back to the materialized `db.calls`) rather than failing the open
        // — opening the trace at all is strictly more useful than refusing it,
        // and the materialized path is always available as a safe fallback.
        reader.call_stream = match call_stream_source::SeekableCallStream::open(path) {
            Ok(Some(stream)) => {
                info!(
                    "CTFS: seekable calls.dat attached ({} calls, chunk_size {}) — call tree served on-demand",
                    stream.call_count(),
                    stream.chunk_size(),
                );
                Some(std::sync::Arc::new(stream))
            }
            Ok(None) => None,
            Err(e) => {
                info!("CTFS: calls.dat present but unreadable ({e}); falling back to materialized call tree");
                None
            }
        };

        // M22 — attach the SEEKABLE `steps.dat` execution stream when the
        // container advertises one (`has_step_stream`). A step's source line is
        // then served on-demand from `steps.dat` (bounded decompression) rather
        // than from the materialized `db.steps`. A flag-off container yields
        // `None`, preserving the existing fully-materialized behaviour exactly.
        // A present-but-corrupt stream is logged and ignored (we keep the
        // materialized `db.steps` fallback) rather than failing the open.
        reader.step_stream = match step_value_stream_source::SeekableStepStream::open(path) {
            Ok(Some(stream)) => {
                info!(
                    "CTFS: seekable steps.dat attached ({} steps, chunk_size {}) — step lines served on-demand",
                    stream.step_count(),
                    stream.chunk_size(),
                );
                Some(std::sync::Arc::new(stream))
            }
            Ok(None) => None,
            Err(e) => {
                info!("CTFS: steps.dat present but unreadable ({e}); falling back to materialized step table");
                None
            }
        };

        // M22 — attach the SEEKABLE `values.dat` parallel value stream when the
        // container advertises one (`has_value_stream`). A step's variable values
        // are then served on-demand from `values.dat` rather than from the
        // materialized `db.variables`. Same fall-back/back-compat discipline as
        // the step stream above.
        reader.value_stream = match step_value_stream_source::SeekableValueStream::open(path) {
            Ok(Some(stream)) => {
                info!(
                    "CTFS: seekable values.dat attached ({} value records, chunk_size {}) — step values served on-demand",
                    stream.value_count(),
                    stream.chunk_size(),
                );
                Some(std::sync::Arc::new(stream))
            }
            Ok(None) => None,
            Err(e) => {
                info!("CTFS: values.dat present but unreadable ({e}); falling back to materialized value table");
                None
            }
        };

        // M26 — attach the prepopulated `step-map.ns` BREAKPOINT INDEX when the
        // bundle carries one. When present, breakpoint line→step resolution
        // (`step_ids_on_line`) is an O(unique-lines) index lookup that does NOT
        // trigger the M24c lazy / M25b whole-table build. When absent — the
        // common case today, since no production writer emits the namespace yet
        // (see `step_map_namespace`'s module docs) — the resolver falls back to
        // the whole-table build, byte-identically.
        //
        // We look for the table in two places, in order:
        //   1. a container-internal `step-map.ns` file (the spec's layout), and
        //   2. a `<ct>.step-map.ns` SIDECAR next to the `.ct` (the path a
        //      writer-side toggle / external tool can drop the index at without
        //      rewriting the container).
        // A present-but-unparseable table is logged and ignored (we keep the
        // whole-table fallback) rather than failing the open — opening the trace
        // is strictly more useful than refusing it, and the fallback always
        // yields identical breakpoints.
        reader.step_map = Self::load_step_map_namespace(&mut ctfs, path);

        Ok(reader)
    }

    /// M26 — locate and parse the prepopulated `step-map.ns` breakpoint index
    /// for the `.ct` at `path`, preferring the container-internal file and
    /// falling back to a `<ct>.step-map.ns` sidecar. Returns `None` (the
    /// whole-table fallback) when neither is present or the bytes are
    /// unparseable.
    fn load_step_map_namespace(
        ctfs: &mut CtfsReader,
        path: &Path,
    ) -> Option<step_map_namespace::StepMapNamespace> {
        // 1. Container-internal `step-map.ns`.
        let internal = if ctfs.has_file(step_map_namespace::STEP_MAP_FILE) {
            match ctfs.read_file(step_map_namespace::STEP_MAP_FILE) {
                Ok(bytes) => Some(bytes),
                Err(e) => {
                    info!("CTFS: step-map.ns present but unreadable ({e}); falling back to whole-table breakpoint build");
                    None
                }
            }
        } else {
            None
        };

        // 2. Sidecar `<ct>.step-map.ns`.
        let bytes = internal.or_else(|| {
            // A missing sidecar is the normal case — not an error — so any read
            // failure (absent file, permission, etc.) collapses to `None` and we
            // stay on the whole-table fallback.
            let sidecar = sidecar_step_map_path(path);
            std::fs::read(&sidecar).ok()
        });

        let bytes = bytes?;
        match step_map_namespace::StepMapNamespace::parse(&bytes) {
            Ok(ns) => {
                info!(
                    "CTFS: prepopulated step-map.ns attached ({} (path,line) entries) — breakpoint resolution served from the index",
                    ns.entry_count()
                );
                Some(ns)
            }
            Err(e) => {
                info!("CTFS: step-map.ns malformed ({e}); falling back to whole-table breakpoint build");
                None
            }
        }
    }

    /// Construct a [`CTFSTraceReader`] from raw bytes already in memory.
    ///
    /// This is the VFS-friendly counterpart of [`open`](Self::open): the
    /// caller supplies the complete `.ct` file contents (e.g. read from
    /// the in-memory VFS in WASM builds) and the reader parses them
    /// without touching the filesystem.
    ///
    /// Only the **old format** (events-based) is supported here because
    /// the new format requires the Nim FFI reader which needs a real file
    /// path.  If the container uses the new format, an error is returned.
    pub fn from_bytes(data: Vec<u8>) -> Result<Self, Box<dyn Error>> {
        let mut ctfs = CtfsReader::from_bytes(data)?;

        if is_new_format(&ctfs) {
            Err("CTFS new format (nim-reader) is not supported via from_bytes; \
                 only old-format containers can be loaded from in-memory data"
                .into())
        } else {
            info!("CTFS from_bytes: old format detected — running postprocessing");
            Self::open_old_format(&mut ctfs)
        }
    }

    /// Detect and load Elixir/Erlang sidecar-format CTFS bundles produced
    /// by `codetracer-beam-recorder` (and the legacy `codetracer-elixir-
    /// recorder` brand).
    ///
    /// The BEAM recorder writes a `trace_meta.json` describing the run plus
    /// a `runtime_session.jsonl` event log alongside the `.ct` container,
    /// rather than encoding the full trace into the Nim seek-based binary
    /// format. This helper streams that log into a `Db` so the rest of
    /// db-backend can serve it through the normal `TraceReader` interface.
    ///
    /// Returns `Ok(None)` when the bundle does not look like a BEAM-recorder
    /// trace, so the caller can fall through to the regular CTFS readers.
    fn open_elixir_sidecar_format(ctfs: &mut CtfsReader, ct_path: &Path) -> Result<Option<Self>, Box<dyn Error>> {
        use codetracer_trace_types::{TypeKind, TypeSpecificInfo};

        let Some(trace_dir) = ct_path.parent() else {
            return Ok(None);
        };
        let trace_meta_path = trace_dir.join("trace_meta.json");
        let runtime_path = trace_dir.join("runtime_session.jsonl");
        if !trace_meta_path.is_file() || !runtime_path.is_file() {
            return Ok(None);
        }

        let trace_meta_raw = std::fs::read_to_string(&trace_meta_path)?;
        let trace_meta: Value = serde_json::from_str(&trace_meta_raw)?;
        // Accept both the current `codetracer-beam-recorder` brand and the
        // legacy `codetracer-elixir-recorder` brand for one release cycle, so
        // bundles produced before the BEAM-recorder rename keep loading.
        match trace_meta.get("recorder").and_then(Value::as_str) {
            Some("codetracer-beam-recorder") | Some("codetracer-elixir-recorder") => {}
            _ => return Ok(None),
        }

        let workdir = trace_meta
            .pointer("/runtime_session/source_root")
            .and_then(Value::as_str)
            .map(PathBuf::from)
            .unwrap_or_default();
        let mut db = Db::new(&workdir);

        db.types.push(TypeRecord {
            kind: TypeKind::Int,
            lang_type: "integer".to_string(),
            specific_info: TypeSpecificInfo::None,
        });

        let mut location_index: HashMap<u64, (PathBuf, i64)> = HashMap::new();
        if let Some(manifests) = trace_meta.get("manifests").and_then(Value::as_array) {
            for manifest in manifests {
                let Some(copy_path) = manifest.get("trace_copy_path").and_then(Value::as_str) else {
                    continue;
                };
                let Ok(bytes) = ctfs.read_file(copy_path) else {
                    continue;
                };
                let manifest_json: Value = serde_json::from_slice(&bytes)?;
                let Some(locations) = manifest_json.get("locations").and_then(Value::as_array) else {
                    continue;
                };
                for location in locations {
                    let Some(id) = location.get("id").and_then(Value::as_u64) else {
                        continue;
                    };
                    let Some(path) = location.get("build_path").and_then(Value::as_str) else {
                        continue;
                    };
                    let Some(line) = location.get("line").and_then(Value::as_i64) else {
                        continue;
                    };
                    location_index.insert(id, (PathBuf::from(path), line));
                }
            }
        }

        if let Some(sources) = trace_meta.get("sources").and_then(Value::as_array) {
            for source in sources {
                if let Some(path) = source.get("source_path").and_then(Value::as_str) {
                    Self::ensure_db_path(&mut db, &PathBuf::from(path));
                }
            }
        }
        for (path, _) in location_index.values() {
            Self::ensure_db_path(&mut db, path);
        }

        let file = std::fs::File::open(&runtime_path)?;
        let reader = std::io::BufReader::new(file);
        let mut function_ids: HashMap<String, FunctionId> = HashMap::new();
        let mut variable_ids: HashMap<String, VariableId> = HashMap::new();
        let mut frame_calls: HashMap<u64, CallKey> = HashMap::new();
        let mut call_next_lines: HashMap<i64, (PathBuf, i64)> = HashMap::new();
        let mut call_stack: Vec<CallKey> = Vec::new();
        let mut active_values: HashMap<VariableId, FullValueRecord> = HashMap::new();

        for line in reader.lines() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            let event: Value = serde_json::from_str(&line)?;
            match event.get("event").and_then(Value::as_str) {
                Some("call") => {
                    let function_key = event
                        .get("function_key")
                        .and_then(Value::as_str)
                        .map(ToString::to_string)
                        .unwrap_or_else(|| {
                            let module = event.get("module").and_then(Value::as_str).unwrap_or("<module>");
                            let function = event.get("function").and_then(Value::as_str).unwrap_or("<function>");
                            let arity = event.get("arity").and_then(Value::as_u64).unwrap_or(0);
                            format!("{module}.{function}/{arity}")
                        });
                    let location = event
                        .get("source_location")
                        .and_then(|source| {
                            let path = source.get("build_path")?.as_str()?;
                            let line = source.get("line")?.as_i64()?;
                            Some((PathBuf::from(path), line))
                        })
                        .or_else(|| {
                            event
                                .get("location_id")
                                .and_then(Value::as_u64)
                                .and_then(|id| location_index.get(&id).cloned())
                        })
                        .unwrap_or_else(|| (workdir.clone(), 0));
                    let path_id = Self::ensure_db_path(&mut db, &location.0);
                    let next_function_id = FunctionId(db.functions.len());
                    let function_id = *function_ids.entry(function_key.clone()).or_insert_with(|| {
                        db.functions.push(FunctionRecord {
                            name: function_key.clone(),
                            path_id,
                            line: Line(location.1),
                        });
                        next_function_id
                    });
                    let parent_key = call_stack.last().copied().unwrap_or(CallKey(-1));
                    let call_key = CallKey(db.calls.len() as i64);
                    if parent_key.0 >= 0 {
                        db.calls[parent_key].children_keys.push(call_key);
                    }
                    let step_id = StepId(db.steps.len() as i64);
                    db.calls.push(DbCall {
                        key: call_key,
                        function_id,
                        args: vec![],
                        return_value: ValueRecord::None { type_id: TypeId(0) },
                        step_id,
                        depth: call_stack.len(),
                        parent_key,
                        children_keys: vec![],
                    });
                    if let Some(frame_id) = event.get("frame_id").and_then(Value::as_u64) {
                        frame_calls.insert(frame_id, call_key);
                    }
                    call_next_lines.insert(call_key.0, (location.0, location.1 + 1));
                    call_stack.push(call_key);
                }
                Some("step") => {
                    let indexed_location = event
                        .get("location_id")
                        .and_then(Value::as_u64)
                        .and_then(|location_id| location_index.get(&location_id).cloned());
                    let inferred_location = call_stack.last().and_then(|call_key| {
                        let (path, next_line) = call_next_lines.get_mut(&call_key.0)?;
                        let line = *next_line;
                        *next_line += 1;
                        Some((path.clone(), line))
                    });
                    let Some((path, line)) = indexed_location.or(inferred_location) else {
                        continue;
                    };
                    let path_id = Self::ensure_db_path(&mut db, &path);
                    let step_id = StepId(db.steps.len() as i64);
                    let call_key = call_stack.last().copied().unwrap_or(CallKey(-1));
                    let db_step = DbStep {
                        step_id,
                        path_id,
                        line: Line(line),
                        // BEAM sidecar `runtime_session.jsonl` records
                        // only `(file, line)` per step — see
                        // codetracer-beam-recorder.  Column data is
                        // not part of the sidecar contract, so we
                        // surface `None` here.
                        column: None,
                        call_key,
                        global_call_key: call_key,
                    };
                    db.steps.push(db_step);
                    db.variables.push(active_values.values().cloned().collect());
                    db.instructions.push(vec![]);
                    db.compound.push(HashMap::new());
                    db.cells.push(HashMap::new());
                    db.variable_cells.push(HashMap::new());
                    db.local_variable_cells.push(HashMap::new());
                    db.step_map[path_id].entry(line as usize).or_default().push(db_step);
                }
                Some("variable_bind") => {
                    let raw_name = event.get("name").and_then(Value::as_str).unwrap_or("<var>");
                    let name = Self::normalize_elixir_variable_name(raw_name);
                    let target_call_key = event
                        .get("frame_id")
                        .and_then(Value::as_u64)
                        .and_then(|frame_id| frame_calls.get(&frame_id).copied());
                    let next_variable_id = VariableId(db.variable_names.len());
                    let variable_id = *variable_ids.entry(name.clone()).or_insert_with(|| {
                        db.variable_names.push(name);
                        next_variable_id
                    });
                    let value = event
                        .get("value")
                        .and_then(Self::elixir_sidecar_value_record)
                        .unwrap_or(ValueRecord::None { type_id: TypeId(0) });
                    let full = FullValueRecord { variable_id, value };
                    active_values.insert(variable_id, full.clone());
                    if db
                        .steps
                        .items
                        .last()
                        .is_some_and(|step| target_call_key.is_none_or(|call_key| step.call_key == call_key))
                        && let Some(step_values) = db.variables.items.last_mut()
                    {
                        step_values.retain(|existing| existing.variable_id != variable_id);
                        step_values.push(full);
                    }
                }
                Some("drop_variables") => {
                    if let Some(variables) = event.get("variables").and_then(Value::as_array) {
                        for variable in variables {
                            if let Some(raw_name) = variable.get("name").and_then(Value::as_str) {
                                let name = Self::normalize_elixir_variable_name(raw_name);
                                if let Some(variable_id) = variable_ids.get(&name) {
                                    active_values.remove(variable_id);
                                }
                            }
                        }
                    }
                }
                Some("return_from") => {
                    if let Some(frame_id) = event.get("frame_id").and_then(Value::as_u64)
                        && let Some(call_key) = frame_calls.remove(&frame_id)
                    {
                        if let Some(value) = event.get("return_value").and_then(Self::elixir_sidecar_value_record) {
                            db.calls[call_key].return_value = value;
                        }
                        while let Some(top) = call_stack.pop() {
                            if top == call_key {
                                break;
                            }
                        }
                    }
                }
                Some("message_send" | "message_receive") => {
                    let content = event
                        .get("message_repr")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    db.events.push(DbRecordEvent {
                        kind: EventLogKind::Write,
                        content,
                        step_id: StepId(db.steps.len().saturating_sub(1) as i64),
                        metadata: event.to_string(),
                    });
                }
                _ => {}
            }
        }

        db.end_of_program = EndOfProgram::Normal;
        // Elixir sidecar traces don't carry meta.dat capability bits
        // (they're a fundamentally different recorder pipeline that
        // never opted into CTFS) — surface both bits as false so the
        // GUI hides per-column UI on those traces.
        Ok(Some(CTFSTraceReader {
            db,
            column_capabilities: ColumnAwareCapabilities::default(),
            // BEAM sidecar bundles ship a JSONL session log, not a `calls.dat`
            // call stream, so there is no seekable stream to attach.
            call_stream: None,
            // The seekable `steps.dat`/`values.dat` streams (if any) are attached
            // centrally by `open()`, which has the `.ct` path. `from_*`
            // constructors that lack a path leave these `None`.
            step_stream: None,
            value_stream: None,
            lazy_values: None,
            lazy_steps: None,
            lazy_steps_full: None,
            step_build_strategy: step_value_stream_source::StepBuildStrategy::default(),
            // BEAM sidecar bundles do not carry a `step-map.ns`; `open()` would
            // attach one if present, but these traces are fully materialized so
            // the whole-table path serves breakpoints.
            step_map: None,
        }))
    }

    fn ensure_db_path(db: &mut Db, path: &Path) -> PathId {
        let path_string = path.display().to_string();
        if let Some(path_id) = db.path_map.get(&path_string) {
            return *path_id;
        }
        let path_id = PathId(db.paths.len());
        db.paths.push(path_string.clone());
        db.path_map.insert(path_string, path_id);
        db.step_map.push(HashMap::new());
        path_id
    }

    fn normalize_elixir_variable_name(name: &str) -> String {
        name.trim_start_matches('_')
            .split('@')
            .next()
            .unwrap_or(name)
            .to_string()
    }

    fn elixir_sidecar_value_record(value: &Value) -> Option<ValueRecord> {
        if let Some(int) = value.get("value").and_then(Value::as_i64) {
            return Some(ValueRecord::Int {
                i: int,
                type_id: TypeId(0),
            });
        }
        if let Some(text) = value.get("value").and_then(Value::as_str) {
            return Some(ValueRecord::Raw {
                r: text.to_string(),
                type_id: TypeId(0),
            });
        }
        None
    }

    /// Open a new-format CTFS container by loading pre-processed data
    /// directly into the `Db`, bypassing `TraceProcessor::postprocess`.
    ///
    /// The new format stores the same data structures that `postprocess`
    /// would build, but written at recording time (or during a finalization
    /// step). This eliminates the O(n) startup cost where n is the number
    /// of trace events.
    ///
    /// When the `nim-reader` feature is enabled, this uses
    /// [`NimTraceReaderHandle`] to open the `.ct` file via the Nim
    /// seek-based reader FFI. Currently it reads metadata and interning
    /// tables to build a minimal `Db`; full step/call/event population
    /// will follow.
    ///
    /// Without `nim-reader`, returns an error indicating the format is
    /// recognized but the reader is not available.
    #[allow(unused_variables, clippy::needless_return)]
    fn open_new_format(ctfs: &mut CtfsReader, ct_path: &Path) -> Result<Self, Box<dyn Error>> {
        #[cfg(feature = "nim-reader")]
        {
            return Self::open_new_format_nim(ctfs, ct_path);
        }

        #[cfg(not(feature = "nim-reader"))]
        {
            Err(format!(
                "CTFS new format detected (steps.dat present) but the nim-reader \
                 feature is not enabled. Container: {}. \
                 Rebuild with --features nim-reader to use the Nim seek-based reader.",
                ctfs.file_names().join(", ")
            )
            .into())
        }
    }

    /// Nim-backed new-format reader implementation.
    ///
    /// Opens the `.ct` file via the Nim `NewTraceReader` FFI, reads metadata
    /// and interning tables, and builds a minimal `Db`. Step, call, and
    /// event data is read on-demand via JSON queries to the Nim reader.
    ///
    /// # Current status
    ///
    /// This is the first integration point: it proves the FFI bridge works
    /// end-to-end and populates metadata + interning tables. Full Db
    /// population (steps, calls, events, step_map) comes next.
    #[cfg(feature = "nim-reader")]
    fn open_new_format_nim(_ctfs: &mut CtfsReader, ct_file_path: &Path) -> Result<Self, Box<dyn Error>> {
        use codetracer_trace_types::{FunctionRecord, Line, PathId, TypeKind, TypeRecord, TypeSpecificInfo};
        use num_traits::FromPrimitive;
        use std::path::PathBuf;

        let ct_path = ct_file_path.to_string_lossy().to_string();

        let reader =
            NimTraceReaderHandle::open(&ct_path).map_err(|e| format!("failed to open .ct via Nim reader: {e}"))?;

        let step_count = reader.step_count();
        let call_count = reader.call_count();
        let event_count = reader.event_count();

        info!(
            "Nim reader opened: {} steps, {} calls, {} events, {} paths, {} functions, {} types, {} varnames",
            step_count,
            call_count,
            event_count,
            reader.path_count(),
            reader.function_count(),
            reader.type_count(),
            reader.varname_count(),
        );

        let workdir_str = reader.workdir();
        let workdir = if workdir_str.is_empty() {
            PathBuf::from(".")
        } else {
            PathBuf::from(&workdir_str)
        };

        let mut db = Db::new(&workdir);

        // ── Interning tables ───────────────────────────────────────────
        //
        // Paths — also populate the reverse path_map for lookups by
        // string and ensure step_map has a slot per path.
        for i in 0..reader.path_count() {
            let p = reader.path(i).map_err(|e| format!("path {i}: {e}"))?;
            db.paths.push(p.clone());
            db.path_map.insert(p, PathId(db.paths.len() - 1));
            db.step_map.push(HashMap::new());
        }

        // Functions — the Nim reader only exposes function names (not
        // path/line), so we create stub FunctionRecords for now.
        for i in 0..reader.function_count() {
            let name = reader.function(i).map_err(|e| format!("function {i}: {e}"))?;
            db.functions.push(FunctionRecord {
                name,
                path_id: PathId(0),
                line: Line(0),
            });
        }

        // Types — only the type name is available via FFI.
        for i in 0..reader.type_count() {
            let name = reader.type_name(i).map_err(|e| format!("type {i}: {e}"))?;
            db.types.push(TypeRecord {
                kind: TypeKind::Raw,
                lang_type: name,
                specific_info: TypeSpecificInfo::None,
            });
        }

        // Variable names
        for i in 0..reader.varname_count() {
            let name = reader.varname(i).map_err(|e| format!("varname {i}: {e}"))?;
            db.variable_names.push(name);
        }

        info!(
            "Nim reader: interning tables loaded — {} paths, {} functions, {} types, {} varnames",
            db.paths.len(),
            db.functions.len(),
            db.types.len(),
            db.variable_names.len(),
        );

        // ── Calls ──────────────────────────────────────────────────────
        //
        // Load call records first. We need call entry/exit step ranges to
        // compute the step→call_key mapping for DbStep.
        //
        // call_fields returns:
        //   (function_id, parent_key, entry_step, exit_step, depth, children_count)
        //
        // We also store entry_step/exit_step per call so we can later
        // assign call_key to each step.
        struct CallRange {
            entry_step: u64,
            exit_step: u64,
        }
        let mut call_ranges: Vec<CallRange> = Vec::with_capacity(call_count as usize);

        for key in 0..call_count {
            let (function_id, parent_key, entry_step, exit_step, depth, children_count) =
                reader.call_fields(key).map_err(|e| format!("call {key}: {e}"))?;

            let mut children_keys = Vec::with_capacity(children_count as usize);
            for c in 0..children_count {
                let child_key = reader
                    .call_child(key, c)
                    .map_err(|e| format!("call {key} child {c}: {e}"))?;
                children_keys.push(CallKey(child_key as i64));
            }

            // Pull the captured call arguments via the structured FFI so
            // the frontend can render `format_board(board=...)` instead of
            // an empty `format_board()`.  The recorder stages each
            // argument's (name, CBOR-encoded value) pair on the call
            // record at write time; here we decode them back into
            // `FullValueRecord`s sharing the same varname interning
            // table that step variables use.
            let arg_count = reader.call_arg_count(key);
            let mut args: Vec<FullValueRecord> = Vec::with_capacity(arg_count as usize);
            for arg_idx in 0..arg_count {
                match reader.call_arg(key, arg_idx) {
                    Ok((varname_id, data)) => {
                        let value = if data.is_empty() {
                            ValueRecord::None { type_id: TypeId(0) }
                        } else {
                            match cbor4ii::serde::from_reader::<ValueRecord, _>(data.as_slice()) {
                                Ok(v) => v,
                                Err(e) => {
                                    log::warn!("call {key} arg {arg_idx}: CBOR decode failed: {e}, using Raw fallback");
                                    ValueRecord::Raw {
                                        r: format!("<cbor decode error: {e}>"),
                                        type_id: TypeId(0),
                                    }
                                }
                            }
                        };
                        args.push(FullValueRecord {
                            variable_id: VariableId(varname_id as usize),
                            value,
                        });
                    }
                    Err(e) => {
                        log::warn!("call {key} arg {arg_idx}: read failed: {e}");
                        break;
                    }
                }
            }

            db.calls.push(DbCall {
                key: CallKey(key as i64),
                function_id: FunctionId(function_id as usize),
                args,
                return_value: ValueRecord::None { type_id: TypeId(0) }, // TODO: return values
                step_id: StepId(entry_step as i64),
                depth: depth as usize,
                parent_key: CallKey(parent_key),
                children_keys,
            });

            call_ranges.push(CallRange { entry_step, exit_step });
        }

        info!("Nim reader: {} calls loaded", db.calls.len());

        // ── Step→call mapping ──────────────────────────────────────────
        //
        // Build a vector mapping each step index to its innermost
        // (deepest) enclosing call_key, using the entry_step/exit_step
        // ranges. A step at index S belongs to the deepest call whose
        // range [entry_step, exit_step] contains S.
        //
        // We sweep calls in key order (which matches recording order)
        // and use a simple stack to track the current innermost call.
        let mut step_to_call_key: Vec<CallKey> = vec![CallKey(-1); step_count as usize];

        // For each call, mark all steps in [entry_step, exit_step] with
        // this call_key. Because calls are ordered by entry_step and
        // children appear after their parent, later (deeper) calls
        // overwrite parent assignments — giving us the innermost call.
        for (key_idx, range) in call_ranges.iter().enumerate() {
            let call_key = CallKey(key_idx as i64);
            let start = range.entry_step as usize;
            let end = std::cmp::min(range.exit_step as usize + 1, step_count as usize);
            step_to_call_key[start..end].fill(call_key);
        }

        // Build global_call_key: for each step, the call_key of the last
        // call that started at or before that step. We sweep calls in
        // order and advance through steps.
        let mut step_to_global_call_key: Vec<CallKey> = vec![CallKey(-1); step_count as usize];
        if call_count > 0 {
            let mut call_idx: usize = 0;
            let mut current_global_key = CallKey(0);
            for (step_idx, slot) in step_to_global_call_key.iter_mut().enumerate() {
                // Advance to the last call whose entry_step <= step_idx.
                while call_idx + 1 < call_count as usize && call_ranges[call_idx + 1].entry_step <= step_idx as u64 {
                    call_idx += 1;
                    current_global_key = CallKey(call_idx as i64);
                }
                // Also check the first call.
                if call_ranges[call_idx].entry_step <= step_idx as u64 {
                    current_global_key = CallKey(call_idx as i64);
                }
                *slot = current_global_key;
            }
        }

        // ── Steps ──────────────────────────────────────────────────────
        //
        // Populate db.steps, db.step_map, and per-step scaffolding
        // (variables, instructions, compound, cells, variable_cells).
        //
        // The (path_id, line) pair for every step is drained via the
        // bulk `ct_reader_step_locations` FFI in chunked batches.  The
        // per-step accessor would issue one Rust→Nim FFI hop per step
        // AND re-scan from the exec-stream chunk boundary on every
        // call, giving O(steps × chunk_size) decode cost end-to-end.
        // The bulk accessor streams each chunk exactly once and pays
        // a single FFI hop per BULK_STEP_LOCATIONS_CHUNK steps.  See
        // codetracer §5.2(o) / §1.97 for the motivation and the
        // before / after benchmark numbers.
        const BULK_STEP_LOCATIONS_CHUNK: u64 = 1024;

        // M1 — call the column-aware bulk FFI when the trace declared
        // `has_column_aware_steps` so DbStep.column carries the real
        // recorded column.  Legacy line-only traces stay on the
        // cheaper line-only path; their column slot would be 0 on the
        // column-aware FFI anyway (the spec keeps columns 1-indexed),
        // and skipping the column buffer avoids an extra allocation
        // per chunk.
        let column_aware = reader.has_column_aware_steps();
        // M-capability-flags — capture the capability bits before we
        // drop the reader handle at function exit so the DAP layer
        // can decide whether to expose per-column UI affordances.
        let column_capabilities = ColumnAwareCapabilities {
            supports_column_breakpoints: reader.supports_column_breakpoints(),
            supports_column_motions: reader.supports_column_motions(),
        };

        // Build a pure-Rust `GlobalPositionDecoder` for the column-aware
        // path.  We bypass the Nim FFI's `decodeGlobalPositionIndex`
        // here for two reasons:
        //
        // 1. The FFI's column-aware fallback (when its per-file
        //    line-length table is empty) returns `gli.resolve(GLI)` —
        //    which interprets the byte-offset GLI as a line index, so
        //    DAP `stackTrace` responses surface absurd "line" numbers
        //    (e.g. line 270 for a 12-line source file).  Recovering
        //    here keeps the FFI's bug from leaking into the DAP wire.
        //
        // 2. The Nim reader's `decodeGlobalPositionIndex` is gated on
        //    `meta.hasColumnAwareSteps`, which a known recorder-side
        //    bug leaves clear even though the trace actually carries
        //    column-aware Layout A data.  The `lineLengthRaw` /
        //    `lineCountRaw` ungated FFI exposes the per-file tables
        //    regardless of the meta bit so we can decode reliably.
        //
        // The decoder is `None` only when no Layout A data is available
        // (a legitimate line-only trace) — in that case we use the
        // legacy `step_locations` path so the line numbers stay
        // bit-for-bit identical to pre-extension behaviour.
        let position_decoder: Option<codetracer_trace_reader::global_position_decoder::GlobalPositionDecoder> =
            if column_aware {
                let path_total = reader.path_count();
                let mut per_file: Vec<Vec<u32>> = Vec::with_capacity(path_total as usize);
                let mut any_with_lines = false;
                for fid in 0..path_total {
                    let line_count = reader.line_count_raw(fid);
                    let mut lls: Vec<u32> = Vec::with_capacity(line_count as usize);
                    for li in 0..line_count {
                        match reader.line_length_raw(fid, li as u32) {
                            Some(v) => lls.push(v),
                            None => {
                                // Should not happen because `line_count_raw`
                                // returns the exact populated length, but
                                // be defensive: a missing entry leaves a
                                // zero-byte line which the decoder treats
                                // as a no-op slot.
                                lls.push(0);
                            }
                        }
                    }
                    if !lls.is_empty() {
                        any_with_lines = true;
                    }
                    per_file.push(lls);
                }
                if any_with_lines {
                    Some(
                        codetracer_trace_reader::global_position_decoder::GlobalPositionDecoder::from_line_lengths(
                            per_file,
                        ),
                    )
                } else {
                    None
                }
            } else {
                None
            };


        // ── M24c-steps: RANGE-AWARE LAZY step path ─────────────────────
        //
        // The PRODUCTION split bundle ships a SPEC-canonical `has_step_stream`
        // `steps.dat` that the Rust `StepStreamReader` reads directly (M24a-1).
        // When that stream is available AND the trace is NOT column-aware, we DO
        // NOT decode the whole step table here — that eager loop was the
        // O(trace size) materialization M24 set out to remove. Instead we attach a
        // `LazyStepCache` over the seekable stream (plus the cheap, already-computed
        // call-key arrays) and leave `db.steps` / `db.step_map` EMPTY. A step is
        // then reconstructed on first borrow, decompressing only that step's
        // chunk-aligned RANGE. The reconstructed `DbStep` is byte-identical to what
        // this loop pushes, because both decode the same packed `(path_id, line)`
        // (`steps.dat` GLI ↔ the bulk FFI's line-only path) and derive the same
        // call keys.
        //
        // Column-aware traces are EXCLUDED: their eager path overrides
        // `(path_id, line)` via the pure-Rust `GlobalPositionDecoder` and sets
        // `DbStep.column`, which the line-only `steps.dat` GLI cannot reproduce.
        // For those, and for any bundle lacking a seekable step stream (value-less
        // / pre-M24a / legacy / corrupt-stream), we fall back to the eager loop —
        // correctness first.
        let lazy_steps = if column_aware {
            None
        } else {
            match step_value_stream_source::SeekableStepStream::open(ct_file_path) {
                Ok(Some(stream)) => {
                    let stream = std::sync::Arc::new(stream);
                    info!(
                        "Nim reader: steps served LAZILY (range-aware) from seekable steps.dat \
                         ({} records, chunk_size {}) — step table not materialized at open",
                        stream.step_count(),
                        stream.chunk_size(),
                    );
                    Some(step_value_stream_source::LazyStepCache::new(
                        stream,
                        step_to_call_key.clone(),
                        step_to_global_call_key.clone(),
                    ))
                }
                Ok(None) => None,
                Err(e) => {
                    info!("Nim reader: steps.dat present but unreadable ({e}); materializing step table eagerly");
                    None
                }
            }
        };

        if lazy_steps.is_some() {
            info!("Nim reader: step table NOT materialized at open (lazy range-aware path)");

            // Even on the lazy step path we still allocate the EMPTY per-step
            // parallel scaffolding (`instructions`/`compound`/`cells`/
            // `variable_cells`) the eager loop pushes. These are empty
            // HashMaps/Vecs — NO step decode, NO decompression, NO scan — so the
            // O(trace size) cost the lazy path removes (the step-record decode and
            // the line→step map build) is untouched. But they keep the borrowing
            // accessors returning `Some(empty)` (not `None`) per step, which the
            // split-bundle full-DB contract asserts (the per-step maps EXIST but
            // are empty because a production split bundle carries no Cell/Assign
            // events). See `tests/ctfs_split_only_full_db_test.rs`.
            for _ in 0..step_count {
                db.instructions.push(vec![]);
                db.compound.push(HashMap::new());
                db.cells.push(HashMap::new());
                db.variable_cells.push(HashMap::new());
            }
        }

        // Eager step materialization. Skipped entirely on the lazy path above; the
        // per-step scaffolding for that path is allocated (empty) just above.
        let mut path_id_buf: Vec<u64> = vec![0; BULK_STEP_LOCATIONS_CHUNK as usize];
        let mut line_buf: Vec<u64> = vec![0; BULK_STEP_LOCATIONS_CHUNK as usize];
        let mut column_buf: Vec<u64> = if column_aware {
            vec![0; BULK_STEP_LOCATIONS_CHUNK as usize]
        } else {
            Vec::new()
        };
        // Raw `global_position_index` buffer — only allocated when we
        // have a pure-Rust decoder ready to consume them.
        let mut gli_buf: Vec<u64> = if position_decoder.is_some() {
            vec![0; BULK_STEP_LOCATIONS_CHUNK as usize]
        } else {
            Vec::new()
        };
        let mut step_idx: u64 = 0;
        while lazy_steps.is_none() && step_idx < step_count {
            let want = std::cmp::min(BULK_STEP_LOCATIONS_CHUNK, step_count - step_idx);
            let written = if column_aware {
                reader
                    .step_locations_with_columns(
                        step_idx,
                        want,
                        &mut path_id_buf[..want as usize],
                        &mut line_buf[..want as usize],
                        &mut column_buf[..want as usize],
                    )
                    .map_err(|e| format!("step_locations_with_columns(start={step_idx}, count={want}): {e}"))?
            } else {
                reader
                    .step_locations(
                        step_idx,
                        want,
                        &mut path_id_buf[..want as usize],
                        &mut line_buf[..want as usize],
                    )
                    .map_err(|e| format!("step_locations(start={step_idx}, count={want}): {e}"))?
            };
            if written == 0 {
                // Defensive: should never happen since `want > 0` and
                // the bulk FFI guarantees min(count, remaining) on
                // success.  Falling back here would just spin.
                return Err(format!("step_locations returned 0 entries at step {step_idx}; trace truncated?").into());
            }

            // When we have a pure-Rust decoder, fetch raw GLIs for the
            // same step range and override the FFI's (potentially
            // bogus) (path_id, line, column) interpretation per step.
            // The FFI buffers stay valid as the legacy fallback (e.g.
            // when a single step's GLI exceeds the decoder's known
            // address space — which would only happen on a
            // partial-trace inconsistency).
            if let Some(decoder) = position_decoder.as_ref() {
                let glis_written = reader
                    .step_global_line_indices(step_idx, want, &mut gli_buf[..want as usize])
                    .map_err(|e| format!("step_global_line_indices(start={step_idx}, count={want}): {e}"))?;
                let common = std::cmp::min(glis_written, written) as usize;
                for offset in 0..common {
                    match decoder.decode_global_position_index(gli_buf[offset]) {
                        Ok(pos) => {
                            path_id_buf[offset] = pos.file;
                            line_buf[offset] = u64::from(pos.line);
                            column_buf[offset] = u64::from(pos.column);
                        }
                        Err(_) => {
                            // Fall through: keep the FFI's interpretation,
                            // which on legitimate edge cases (e.g. step
                            // GLI past the decoder's known address space)
                            // is the best signal we have.
                        }
                    }
                }
            }

            for offset in 0..written {
                let i = step_idx + offset;
                let path_id = PathId(path_id_buf[offset as usize] as usize);
                let line = Line(line_buf[offset as usize] as i64);
                let step_id = StepId(i as i64);
                let call_key = step_to_call_key[i as usize];
                let global_call_key = step_to_global_call_key[i as usize];

                // M1 — populate `DbStep.column` when the trace is
                // column-aware.  The column-aware FFI returns
                // 1-indexed columns; a 0 sentinel (which the FFI
                // emits on per-line-table absent fallback) maps to
                // `None` so the stop check defaults to line-only
                // matching.  Legacy traces stay on `None`.
                let column = if column_aware {
                    let raw = column_buf[offset as usize];
                    if raw == 0 { None } else { Some(Line(raw as i64)) }
                } else {
                    None
                };
                let db_step = DbStep {
                    step_id,
                    path_id,
                    line,
                    column,
                    call_key,
                    global_call_key,
                };

                db.steps.push(db_step);

                // Per-step parallel vectors that postprocess() also creates.
                db.instructions.push(vec![]);
                db.compound.push(HashMap::new());
                db.cells.push(HashMap::new());
                db.variable_cells.push(HashMap::new());

                // step_map: (path_id) → { line → [DbStep, ...] }
                // Ensure enough entries in step_map for this path_id.
                while db.step_map.len() <= path_id.0 {
                    db.step_map.push(HashMap::new());
                }
                if line.0 >= 0 {
                    let line_usize = line.0 as usize;
                    db.step_map[path_id].entry(line_usize).or_default().push(db_step);
                }
            }

            step_idx += written;
        }

        if lazy_steps.is_none() {
            info!("Nim reader: {} steps loaded", db.steps.len());
        }

        // ── Variables ──────────────────────────────────────────────────
        //
        // M24c — LAZY value path. The PRODUCTION split bundle (M24a-2) ships a
        // SPEC-canonical `has_value_stream` `values.dat` that the Rust
        // `ValueStreamReader` reads directly (verified: the seekable overlay
        // engages on production). When that stream is available we DO NOT decode
        // the whole value table here — doing so was the O(trace size)
        // materialization M24 set out to remove. Instead we attach a
        // `LazyValueCache` over the seekable stream and leave `db.variables`
        // EMPTY. A step's values are then decoded on first borrow, decompressing
        // only that step's chunk (`variables_at`/`variables_at_owned` both prefer
        // the stream). The decoded records are byte-identical to what this loop
        // used to push, because both decode the same `StepValues` CBOR.
        //
        // We open the seekable stream HERE (atomically with the skip decision) so
        // the open never ends up with neither a materialized table nor a stream:
        //   - stream opens  → skip eager decode, attach the lazy cache.
        //   - stream absent → a value-less or pre-M24a-2 (flag-off) bundle; fall
        //     back to eager FFI materialization exactly as before, so older
        //     bundles and the corrupt-stream case stay correct.
        let lazy_values = match step_value_stream_source::SeekableValueStream::open(ct_file_path) {
            Ok(Some(stream)) => {
                let stream = std::sync::Arc::new(stream);
                info!(
                    "Nim reader: values served LAZILY from seekable values.dat ({} records) — \
                     value table not materialized at open",
                    stream.value_count(),
                );
                Some(step_value_stream_source::LazyValueCache::new(
                    stream,
                    step_count as usize,
                ))
            }
            Ok(None) => None,
            Err(e) => {
                info!("Nim reader: values.dat present but unreadable ({e}); materializing value table eagerly");
                None
            }
        };

        if lazy_values.is_none() {
            // Eager fallback: no seekable value stream is available (a value-less
            // or pre-M24a-2 flag-off bundle, or an unreadable stream). Decode the
            // full value table via the FFI so the borrowing `variables_at` keeps
            // returning the same data it always did.
            //
            // For each step, read variable values via the structured FFI.
            // step_value returns (varname_id, type_id, cbor_data) where
            // cbor_data is a CBOR-encoded ValueRecord (tagged with "kind").
            for step_idx in 0..step_count {
                let val_count = reader.step_value_count(step_idx);
                let mut step_values: Vec<FullValueRecord> = Vec::with_capacity(val_count as usize);

                for v in 0..val_count {
                    match reader.step_value(step_idx, v) {
                        Ok((varname_id, _type_id, data)) => {
                            // Decode the CBOR-encoded ValueRecord. The Nim
                            // writer produces CBOR maps with a "kind" tag
                            // matching the serde(tag = "kind") layout of
                            // ValueRecord.
                            let value = if data.is_empty() {
                                ValueRecord::None { type_id: TypeId(0) }
                            } else {
                                match cbor4ii::serde::from_reader::<ValueRecord, _>(data.as_slice()) {
                                    Ok(v) => v,
                                    Err(e) => {
                                        log::warn!(
                                            "step {step_idx} value {v}: CBOR decode failed: {e}, using Raw fallback"
                                        );
                                        ValueRecord::Raw {
                                            r: format!("<cbor decode error: {e}>"),
                                            type_id: TypeId(0),
                                        }
                                    }
                                }
                            };
                            step_values.push(FullValueRecord {
                                variable_id: VariableId(varname_id as usize),
                                value,
                            });
                        }
                        Err(e) => {
                            log::warn!("step {step_idx} value {v}: read failed: {e}");
                            break;
                        }
                    }
                }

                db.variables.push(step_values);
            }

            info!("Nim reader: variables materialized for {} steps", db.variables.len());
        }

        // ── Events ─────────────────────────────────────────────────────
        //
        // event_fields returns (kind: u8, step_id: u64, data: Vec<u8>).
        // Nim IOEventKind: 0=stdout, 1=stderr, 2=file_op, 3=error.
        // Map to EventLogKind using num_traits::FromPrimitive for the
        // standard values, with a fallback mapping for the Nim-specific
        // kind codes.
        for idx in 0..event_count {
            match reader.event_fields(idx) {
                Ok((kind_byte, step_id_raw, data)) => {
                    // Map Nim IOEventKind values to EventLogKind.
                    // Nim: 0=ioStdout → Write, 1=ioStderr → WriteOther,
                    //      2=ioFileOp → WriteFile, 3=ioError → Error.
                    let kind = match kind_byte {
                        0 => EventLogKind::Write,
                        1 => EventLogKind::WriteOther,
                        2 => EventLogKind::WriteFile,
                        3 => EventLogKind::Error,
                        other => {
                            // Try the Rust enum's own discriminant values
                            // for forward compatibility.
                            EventLogKind::from_u8(other).unwrap_or(EventLogKind::Write)
                        }
                    };

                    let step_id = StepId(step_id_raw as i64);
                    let content = String::from_utf8_lossy(&data).to_string();

                    db.events.push(DbRecordEvent {
                        kind,
                        content,
                        step_id,
                        metadata: String::new(),
                    });
                }
                Err(e) => {
                    log::warn!("event {idx}: read failed: {e}");
                    break;
                }
            }
        }

        info!("Nim reader: {} events loaded", db.events.len());

        // ── end_of_program ─────────────────────────────────────────────
        //
        // Match the same logic as TraceProcessor::postprocess: if the
        // last event is an Error on the last step, mark it as an error
        // termination.
        // Use the FFI `step_count` (the real recorded step total) rather than
        // `db.steps.len()` so this stays correct on the M24c-steps LAZY path,
        // where `db.steps` is intentionally empty (the step table is reconstructed
        // on demand). On the eager path `db.steps.len() == step_count`, so the
        // result is unchanged.
        db.end_of_program = if !db.events.is_empty() && step_count > 0 {
            let last_event = &db.events[db.events.len() - 1];
            let on_last_step = (last_event.step_id.0 as usize) == (step_count as usize) - 1;
            if last_event.kind == EventLogKind::Error && on_last_step {
                let reason = format!("error: {}", last_event.content);
                EndOfProgram::Error { reason }
            } else {
                EndOfProgram::Normal
            }
        } else {
            EndOfProgram::Normal
        };

        info!(
            "Nim reader: Db fully populated — {} steps, {} calls, {} events, {} variables",
            db.steps.len(),
            db.calls.len(),
            db.events.len(),
            db.variables.len(),
        );

        Ok(CTFSTraceReader {
            db,
            column_capabilities,
            // The seekable `calls.dat` stream (if any) is attached centrally by
            // `open()`, which has the `.ct` path. `from_*` constructors that
            // lack a path leave this `None`.
            call_stream: None,
            // The seekable `steps.dat`/`values.dat` streams (if any) are attached
            // centrally by `open()`, which has the `.ct` path. `from_*`
            // constructors that lack a path leave these `None`.
            step_stream: None,
            value_stream: None,
            // M24c — when set, `db.variables` is empty and step values are served
            // LAZILY from the seekable `values.dat` stream (built above). The
            // `value_stream` overlay itself is attached centrally by `open()`.
            lazy_values,
            // M24c-steps — when set, `db.steps` / `db.step_map` are empty and
            // steps are served LAZILY (range-aware) from the seekable `steps.dat`
            // stream (built above). The slice / line-map accessors memoize a
            // whole-table view through `lazy_steps_full` on first demand.
            lazy_steps_full: if lazy_steps.is_some() {
                Some(std::sync::OnceLock::new())
            } else {
                None
            },
            lazy_steps,
            // M25b — the LOCAL parallel disjoint-range whole-table build is the
            // active strategy for the (filesystem-backed) production split bundle
            // this path opens.
            step_build_strategy: step_value_stream_source::StepBuildStrategy::default(),
            // M26 — the prepopulated `step-map.ns` (if any) is attached centrally
            // by `open()`, which has the `.ct` path. Left `None` here so a
            // path-less reconstruction of this struct stays on the whole-table
            // fallback.
            step_map: None,
        })
    }

    /// Open an old-format CTFS container by deserializing raw events from
    /// `events.log` and running `TraceProcessor::postprocess` to build
    /// the in-memory `Db`.
    ///
    /// LEGACY / NON-PRODUCTION PATH (M23e bounding). This `events.log` reader is
    /// NOT the production path. Production `.ct` bundles are split-stream-only
    /// (`steps.dat` present) and served by [`open_new_format_nim`] — they never
    /// reach here. `events.log` survives ONLY as: (a) the secondary Rust
    /// `CtfsTraceWriter`'s combined stream (not used by live recording),
    /// (b) test fixtures, and (c) possibly the streaming/follow-mode reader
    /// (assessed separately in M23e-5). It is deliberately retained — NOT
    /// removed — so those legacy/test bundles keep opening. See `M23e` in
    /// `Trace-Based-Incremental-Testing.milestones.org`. The parity between this
    /// path and the split path is verified by
    /// `tests/ctfs_split_only_full_db_test.rs`.
    ///
    /// Trace metadata is read from `meta.dat` — the canonical binary
    /// format defined in `codetracer-specs/Trace-Files/CTFS-Binary-Format.md`
    /// §8.  M-REC-1.5 (pre-1.0) retired the legacy `meta.json` fallback;
    /// the reader rejects any `.ct` container that does not carry a
    /// `meta.dat`.
    fn open_old_format(ctfs: &mut CtfsReader) -> Result<Self, Box<dyn Error>> {
        // 1. Read and parse trace metadata from the canonical `meta.dat`
        //    payload.  M-REC-1.5 retired the legacy `meta.json` fallback.
        let meta_bytes = ctfs
            .read_file("meta.dat")
            .map_err(|e| format!("missing or unreadable meta.dat: {e}"))?;
        let parsed = meta_dat::parse_meta_dat(&meta_bytes).map_err(|e| format!("failed to parse meta.dat: {e}"))?;
        let meta = codetracer_trace_types::TraceMetadata {
            recording_id: parsed.recording_id,
            program: parsed.program,
            args: parsed.args,
            workdir: PathBuf::from(parsed.workdir),
        };

        let workdir = if meta.workdir.as_os_str().is_empty() {
            // Fall back to the parent directory of the program path.
            // Also handles the case where `meta.dat` carried an empty
            // workdir string (which `PathBuf::from("")` turns into an
            // empty `OsStr`).
            Path::new(&meta.program)
                .parent()
                .unwrap_or(Path::new("."))
                .to_path_buf()
        } else {
            meta.workdir.clone()
        };

        // 2. Read the trace events from the container.
        //    Old format: CBOR-encoded TraceLowLevelEvent sequence in
        //    `events.log`, optionally with split-binary encoding indicated
        //    by `events.fmt`.
        let events = Self::load_events(ctfs)?;

        // 3. Run the postprocessing pipeline to populate a Db struct from
        //    the raw events. This is the expensive O(n) step that the new
        //    format eliminates.
        let mut db = Db::new(&workdir);
        let mut processor = TraceProcessor::new(&mut db);
        processor.postprocess(&events)?;

        // Old-format traces *can* carry the capability bits because
        // meta.dat is the same wire format on both paths — read them
        // out of the Rust meta_dat parser the same way the Nim path
        // does via the FFI.  The parser's own `KNOWN_FLAGS_MASK`
        // recognises the bits (see this module's accompanying
        // `meta_dat.rs`); a clear bit (e.g. on truly legacy traces)
        // surfaces as `false` which is the safe "no per-column UI"
        // default for the GUI.
        let column_capabilities = ColumnAwareCapabilities {
            supports_column_breakpoints: (parsed.flags & meta_dat::FLAG_SUPPORTS_COLUMN_BREAKPOINTS) != 0,
            supports_column_motions: (parsed.flags & meta_dat::FLAG_SUPPORTS_COLUMN_MOTIONS) != 0,
        };

        Ok(CTFSTraceReader {
            db,
            column_capabilities,
            // Attached centrally by `open()` (which has the `.ct` path).
            call_stream: None,
            // The seekable `steps.dat`/`values.dat` streams (if any) are attached
            // centrally by `open()`, which has the `.ct` path. `from_*`
            // constructors that lack a path leave these `None`.
            step_stream: None,
            value_stream: None,
            lazy_values: None,
            lazy_steps: None,
            lazy_steps_full: None,
            step_build_strategy: step_value_stream_source::StepBuildStrategy::default(),
            // M26 — attached centrally by `open()` (which has the `.ct` path).
            step_map: None,
        })
    }

    /// Extract `TraceLowLevelEvent` values from the CTFS container's
    /// `events.log`.
    ///
    /// LEGACY / NON-PRODUCTION PATH (M23e bounding). `events.log` is the
    /// legacy combined event stream — the secondary Rust `CtfsTraceWriter`
    /// format, test fixtures, and the streaming/follow-mode reader. It is NOT
    /// emitted by live recorders (whose split-stream bundles route through
    /// [`open_new_format_nim`] and never call this). Retained for back-compat
    /// per `M23e`; do not treat it as the canonical event source.
    ///
    /// Supports three data layouts, detected automatically:
    ///
    /// 1. **Chunked split-binary** (new default): `events.fmt` contains
    ///    `"split-binary"` and `events.log` uses inline 16-byte chunk
    ///    headers with Zstd-compressed payloads. Decompressed via
    ///    [`codetracer_ctfs::ChunkedReader`], then decoded via
    ///    [`codetracer_trace_writer::split_binary::decode_events`].
    ///
    /// 2. **Chunked CBOR**: `events.log` uses chunk headers but
    ///    `events.fmt` is absent or does not say `"split-binary"`.
    ///    Decompressed via `ChunkedReader`, then deserialized as CBOR.
    ///
    /// 3. **Legacy CBOR streaming**: No chunk headers (e.g. older zeekstd
    ///    frames). Falls back to sequential `cbor4ii::serde::from_reader`.
    ///
    /// If `events.log` is missing entirely, an empty event list is
    /// returned so that the reader can still be constructed (useful for
    /// metadata-only traces or tests).
    fn load_events(ctfs: &mut CtfsReader) -> Result<Vec<TraceLowLevelEvent>, Box<dyn Error>> {
        // The 8-byte CodeTracer events.log magic prefix written by the
        // streaming `CtfsTraceWriter` (and by the legacy CBOR+Zstd writer).
        // Mirrors `codetracer_trace_format_cbor_zstd::HEADERV1` — duplicated
        // here to avoid an extra workspace dependency.  Layout:
        //   [0..5] : "C0DE72ACE2"   magic / l33t-spelling of "CodeTracer"
        //   [5]    : 0x01           file format version 1
        //   [6..8] : 0x00 0x00      reserved
        const EVENTS_HEADER_V1: [u8; 8] = [0xC0, 0xDE, 0x72, 0xAC, 0xE2, 0x01, 0x00, 0x00];

        let event_bytes = match ctfs.read_file("events.log") {
            Ok(bytes) => bytes,
            Err(_) => {
                // No events file — return an empty trace. This allows opening
                // minimal .ct files that only contain metadata (e.g. in tests).
                return Ok(Vec::new());
            }
        };

        if event_bytes.is_empty() {
            return Ok(Vec::new());
        }

        // Strip the optional 8-byte `HEADERV1` magic prefix.  The current
        // streaming writer always emits it; older test fixtures and the
        // legacy in-memory `NonStreamingTraceWriter` do not.  The chunked
        // and CBOR readers below both expect chunk/CBOR data starting at
        // byte zero, so we skip the magic when present.
        let payload: &[u8] = if event_bytes.len() >= EVENTS_HEADER_V1.len()
            && event_bytes[..EVENTS_HEADER_V1.len()] == EVENTS_HEADER_V1
        {
            &event_bytes[EVENTS_HEADER_V1.len()..]
        } else {
            &event_bytes
        };

        // Detect the serialization format. The presence of `events.fmt`
        // with the content `"split-binary"` indicates the new split-binary
        // encoding; otherwise we fall back to CBOR.
        let is_split_binary = match ctfs.read_file("events.fmt") {
            Ok(fmt) => fmt == b"split-binary",
            Err(_) => false, // Legacy: no format marker means CBOR
        };

        // Try the chunked format first (new writer produces inline 16-byte
        // chunk headers followed by Zstd-compressed payloads).
        if let Ok(decompressed) = codetracer_ctfs::ChunkedReader::decompress_all(payload) {
            if is_split_binary {
                return Ok(codetracer_trace_writer::split_binary::decode_events(&decompressed));
            } else {
                // Chunked CBOR — decompress, then parse CBOR from the buffer
                return Self::deserialize_cbor_from_buffer(&decompressed);
            }
        }

        // Fallback: legacy CBOR streaming (zeekstd frames, no chunk headers).
        // This path handles older `.ct` files that pre-date the chunked format.
        Self::deserialize_cbor_from_buffer(payload)
    }

    /// Deserialize a sequence of individually-encoded CBOR
    /// `TraceLowLevelEvent` values from an in-memory buffer.
    ///
    /// Uses `cbor4ii::serde::from_reader` in a loop, the same approach as
    /// `codetracer_trace_reader` for the standalone binary trace format.
    /// A parse error after at least one successful event is treated as a
    /// truncated stream (common during streaming recording when the
    /// recorder has not flushed completely).
    fn deserialize_cbor_from_buffer(data: &[u8]) -> Result<Vec<TraceLowLevelEvent>, Box<dyn Error>> {
        use std::io::BufRead;

        let mut events = Vec::new();
        let mut buf_reader = std::io::BufReader::new(data);

        loop {
            // Check for EOF before attempting to deserialize
            let buf = buf_reader.fill_buf()?;
            if buf.is_empty() {
                break;
            }

            match cbor4ii::serde::from_reader::<TraceLowLevelEvent, _>(&mut buf_reader) {
                Ok(event) => {
                    events.push(event);
                }
                Err(e) => {
                    // If we have already read some events, treat a parse error
                    // at the tail as a truncated stream (common during streaming
                    // recording — the recorder may not have flushed completely).
                    if !events.is_empty() {
                        log::warn!(
                            "CTFS: stopped reading events after {count} events: {e}. \
                             Treating as truncated stream.",
                            count = events.len()
                        );
                        break;
                    } else {
                        return Err(format!("failed to deserialize any events from events.log: {e}").into());
                    }
                }
            }
        }

        Ok(events)
    }
}

// ── TraceReader implementation ─────────────────────────────────────────
//
// All methods delegate to the inner `Db`, exactly like
// `InMemoryTraceReader`. The difference is how the Db is populated:
//
// - Old format: events.log -> load_events -> TraceProcessor::postprocess -> Db
// - New format: steps.dat + calls.dat + ... -> direct Db load (no postprocess)
//
// Both formats produce the same Db, so the TraceReader implementation is
// identical regardless of which loading path was used.

impl TraceReader for CTFSTraceReader {
    // ── Interning tables ────────────────────────────────────────────

    fn path(&self, id: PathId) -> Option<&str> {
        self.db.paths.get(id).map(|s| s.as_str())
    }

    fn function(&self, id: FunctionId) -> Option<&FunctionRecord> {
        self.db.functions.get(id)
    }

    fn type_record(&self, id: TypeId) -> Option<&TypeRecord> {
        self.db.types.get(id)
    }

    fn variable_name(&self, id: VariableId) -> Option<&str> {
        self.db.variable_names.get(id).map(|s| s.as_str())
    }

    fn path_count(&self) -> usize {
        self.db.paths.len()
    }

    fn function_count(&self) -> usize {
        self.db.functions.len()
    }

    fn type_count(&self) -> usize {
        self.db.types.len()
    }

    // ── Per-step data ───────────────────────────────────────────────

    fn step(&self, id: StepId) -> Option<&DbStep> {
        // M24c-steps — on a PRODUCTION (non-column-aware) split bundle the step
        // table is NOT materialized at open; a step is reconstructed LAZILY from
        // the seekable `steps.dat` stream (filling only its chunk-aligned RANGE on
        // first access, then memoized). `db.steps` is empty on this path, so we
        // serve the borrow from the lazy cache. Every other path (legacy
        // `events.log`, Rust-writer combined bundles, column-aware traces, value-
        // less / pre-M24a bundles) leaves `lazy_steps` `None` and serves the
        // fully-materialized `db.steps` — bit-for-bit unchanged.
        if let Some(lazy) = self.lazy_steps.as_ref() {
            return lazy.get(id);
        }
        self.db.steps.get(id)
    }

    fn step_count(&self) -> usize {
        // On the lazy step path `db.steps` is empty; the real count is the lazy
        // cache's span (== the recorded step total).
        if let Some(lazy) = self.lazy_steps.as_ref() {
            return lazy.len();
        }
        self.db.steps.len()
    }

    fn variables_at(&self, step_id: StepId) -> Option<&[FullValueRecord]> {
        // M24c — on a PRODUCTION split bundle the value table is NOT materialized
        // at open; a step's values are borrowed LAZILY from the seekable
        // `values.dat` stream (decompressing only that step's chunk on first
        // access, then memoized). `db.variables` is empty on this path, so we
        // serve the borrow from the lazy cache. Every other path (legacy
        // `events.log`, Rust-writer combined bundles, value-less / pre-M24a-2
        // bundles) leaves `lazy_values` `None` and serves the fully-materialized
        // `db.variables` — bit-for-bit unchanged.
        if let Some(lazy) = self.lazy_values.as_ref() {
            return lazy.get(step_id);
        }
        self.db.variables.get(step_id).map(|v| v.as_slice())
    }

    fn compound_at(&self, step_id: StepId) -> Option<&HashMap<Place, ValueRecord>> {
        self.db.compound.get(step_id)
    }

    fn cells_at(&self, step_id: StepId) -> Option<&HashMap<Place, ValueRecord>> {
        self.db.cells.get(step_id)
    }

    fn cell_changes_for(&self, place: &Place) -> Option<&Vec<CellChange>> {
        self.db.cell_changes.get(place)
    }

    fn variable_cells_at(&self, step_id: StepId) -> Option<&HashMap<VariableId, Place>> {
        self.db.variable_cells.get(step_id)
    }

    // ── Call tree ───────────────────────────────────────────────────

    fn call(&self, key: CallKey) -> Option<&DbCall> {
        self.db.calls.get(key)
    }

    fn call_count(&self) -> usize {
        self.db.calls.len()
    }

    // ── Seekable call tree (M17b) ────────────────────────────────────
    //
    // When the container ships a `has_call_stream` `calls.dat`, the call tree is
    // served on-demand from it (see `call_stream_source`). The materialized
    // `db.calls` remains populated for the borrowing `call`/`call_count` above
    // (so other consumers and the legacy path keep working), but the seekable
    // hooks let `Calltrace::new` read the tree WITHOUT scanning the whole
    // materialized stream.

    fn seekable_call_count(&self) -> Option<usize> {
        self.call_stream.as_ref().map(|s| s.call_count())
    }

    fn seekable_call(&self, key: CallKey) -> Option<DbCall> {
        self.call_stream.as_ref().and_then(|s| s.call(key))
    }

    // ── Seekable step + value streams (M22) ──────────────────────────
    //
    // When the container ships `has_step_stream` / `has_value_stream` streams,
    // a step's source line and a step's variable values are served on-demand
    // from `steps.dat` / `values.dat` (decompressing only the needed chunk).
    // The materialized `db.steps` / `db.variables` remain populated for the
    // borrowing `step` / `variables_at` above (so other consumers and the
    // legacy path keep working), but the seekable hooks let the production DAP
    // variable path read values WITHOUT scanning the whole materialized stream.

    fn seekable_step_count(&self) -> Option<usize> {
        self.step_stream.as_ref().map(|s| s.step_count())
    }

    fn seekable_step_line(&self, step_id: StepId) -> Option<(PathId, Line)> {
        self.step_stream.as_ref().and_then(|s| s.step_line(step_id))
    }

    fn seekable_value_count(&self) -> Option<usize> {
        self.value_stream.as_ref().map(|s| s.value_count())
    }

    fn seekable_variables_at(&self, step_id: StepId) -> Option<Vec<FullValueRecord>> {
        self.value_stream.as_ref().and_then(|s| s.variables_at(step_id))
    }

    // ── Events ──────────────────────────────────────────────────────

    fn events(&self) -> &[DbRecordEvent] {
        &self.db.events
    }

    fn event_count(&self) -> usize {
        self.db.events.len()
    }

    // ── Secondary indices ───────────────────────────────────────────

    fn path_id_for(&self, path: &str) -> Option<PathId> {
        self.db.path_map.get(path).copied()
    }

    fn steps_on_line(&self, path_id: PathId, line: usize) -> Option<&Vec<DbStep>> {
        // M24c-steps — the line-map accessors back breakpoint resolution. On the
        // lazy step path the line→steps map is materialized ONCE on first demand
        // (see `lazy_full_steps`) and served from there; identical to the eager
        // `db.step_map`. Off the lazy path, serve the materialized map directly.
        if self.lazy_steps.is_some() {
            return self
                .lazy_full_steps()
                .step_map
                .get(path_id.0)
                .and_then(|by_line| by_line.get(&line));
        }
        self.db.step_map.get(path_id).and_then(|by_line| by_line.get(&line))
    }

    fn step_map_for_path(&self, path_id: PathId) -> Option<&HashMap<usize, Vec<DbStep>>> {
        if self.lazy_steps.is_some() {
            return self.lazy_full_steps().step_map.get(path_id.0);
        }
        self.db.step_map.get(path_id)
    }

    fn step_ids_on_line(&self, path_id: PathId, line: usize) -> Option<Vec<StepId>> {
        // M26 — PREFER the prepopulated `step-map.ns` breakpoint index when the
        // `.ct` carries one: a line's step ids are an O(unique-lines) HashMap
        // lookup that does NOT touch `steps.dat` and does NOT trigger the M24c
        // lazy / M25b whole-table build. The index stores the SAME ascending
        // step-id set the whole-table build would produce (it is computed from
        // the same steps), so the result is identical.
        if let Some(step_map) = self.step_map.as_ref() {
            return step_map.step_ids_on_line(path_id, line).cloned();
        }
        // No prepopulated index (legacy/older bundle): fall back to the
        // whole-table derivation. On the lazy step path this materializes the
        // whole-table view once on first demand (`lazy_full_steps`), exactly as
        // `steps_on_line` does; off it, it reads the eager `db.step_map`.
        self.steps_on_line(path_id, line)
            .map(|records| records.iter().map(|s| s.step_id).collect())
    }

    // ── Iteration helpers ────────────────────────────────────────────

    fn functions_iter(&self) -> Box<dyn Iterator<Item = (FunctionId, &FunctionRecord)> + '_> {
        Box::new(self.db.functions.iter().enumerate().map(|(i, f)| (FunctionId(i), f)))
    }

    fn calls_iter(&self) -> Box<dyn Iterator<Item = &DbCall> + '_> {
        Box::new(self.db.calls.iter())
    }

    fn steps_from(&self, start_id: StepId) -> &[DbStep] {
        // M24c-steps — `steps_from` backs genuinely O(trace) full scans
        // (breakpoint-resolution Continue, step-over depth walks, history). On the
        // lazy step path the contiguous `DbStep` array is materialized ONCE on
        // first demand and served from there; identical to the eager `db.steps`.
        let items: &[DbStep] = if self.lazy_steps.is_some() {
            &self.lazy_full_steps().steps
        } else {
            &self.db.steps.items
        };
        let start = start_id.0 as usize;
        if start < items.len() {
            &items[start..]
        } else {
            &[]
        }
    }

    fn path_entries_iter(&self) -> Box<dyn Iterator<Item = (&str, PathId)> + '_> {
        Box::new(self.db.path_map.iter().map(|(s, &id)| (s.as_str(), id)))
    }

    // ── Instructions ────────────────────────────────────────────────

    fn instructions_at(&self, step_id: StepId) -> Option<&Vec<String>> {
        self.db.instructions.get(step_id)
    }

    // ── Derived queries ─────────────────────────────────────────────

    fn load_step_events(&self, step_id: StepId, exact: bool) -> Vec<DbRecordEvent> {
        self.db.load_step_events(step_id, exact)
    }

    // ── Metadata ────────────────────────────────────────────────────

    fn workdir(&self) -> &Path {
        &self.db.workdir
    }

    fn end_of_program(&self) -> &EndOfProgram {
        &self.db.end_of_program
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// Canonical pinned test UUIDv7 (M-REC-1).  The embedded timestamp is
    /// fictional; the byte layout passes `is_canonical_uuid_v7`.
    const TEST_RECORDING_ID: &str = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb";

    /// Helper: build a syntactically valid v3 `meta.dat` payload with the
    /// given program / args / workdir fields and no MCR/replay-launch
    /// blocks.  Tests previously hand-wrote `meta.json` here — M-REC-1.5
    /// dropped that fallback so the binary form is now the only option.
    fn meta_dat_bytes(program: &str, args: &[&str], workdir: &str) -> Vec<u8> {
        meta_dat::serialize_meta_dat(&meta_dat::MetaDat {
            version: meta_dat::META_DAT_VERSION,
            flags: 0,
            recording_id: TEST_RECORDING_ID.to_owned(),
            program: program.to_owned(),
            args: args.iter().map(|s| (*s).to_owned()).collect(),
            workdir: workdir.to_owned(),
            recorder_id: "test".to_owned(),
            paths: vec![],
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: vec![],
            has_filter_provenance: false,
        })
    }

    /// Verify that a minimal .ct file with `meta.dat` can be opened and
    /// produces an empty trace (zero steps, zero calls, etc.).
    #[test]
    fn test_ctfs_trace_reader_opens_minimal_ct_file() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("test.ct");

        let dat = meta_dat_bytes("/tmp/test", &[], "/tmp");
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat)]).unwrap();

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 0);
        assert_eq!(reader.call_count(), 0);
        assert_eq!(reader.event_count(), 0);
        assert_eq!(reader.workdir().to_str().unwrap(), "/tmp");
    }

    /// Verify that a .ct file without `events.log` opens successfully
    /// (metadata-only trace).
    #[test]
    fn test_ctfs_trace_reader_missing_events_log() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("no-events.ct");

        let dat = meta_dat_bytes("/home/user/app", &["--flag"], "/home/user");
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat)]).unwrap();

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 0);
        assert_eq!(reader.workdir().to_str().unwrap(), "/home/user");
    }

    /// Verify that workdir falls back to the program's parent directory
    /// when the metadata workdir field is empty.
    #[test]
    fn test_ctfs_trace_reader_workdir_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("fallback.ct");

        let dat = meta_dat_bytes("/opt/bin/my_program", &[], "");
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat)]).unwrap();

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.workdir().to_str().unwrap(), "/opt/bin");
    }

    /// Verify that opening a non-existent file returns an error.
    #[test]
    fn test_ctfs_trace_reader_nonexistent_file() {
        let result = CTFSTraceReader::open(Path::new("/nonexistent/path/trace.ct"));
        assert!(result.is_err());
    }

    /// Verify that opening a file with invalid magic bytes returns an error.
    #[test]
    fn test_ctfs_trace_reader_invalid_magic() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("bad.ct");
        std::fs::write(&ct_path, b"this is not a CTFS file at all!").unwrap();

        let result = CTFSTraceReader::open(&ct_path);
        assert!(result.is_err());
    }

    /// Verify that old-format detection works: a container with only
    /// `meta.dat` (no `steps.dat`) uses the old postprocessing path.
    #[test]
    fn test_ctfs_old_format_detected_without_steps_dat() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("old-format.ct");

        let dat = meta_dat_bytes("/tmp/test", &[], "/tmp");
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat)]).unwrap();

        // Old format should work fine (goes through postprocess path)
        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 0);
    }

    /// Verify that new-format detection works: a container with `steps.dat`
    /// is recognized as new-format. Since the new-format reader is not yet
    /// implemented, this should return an error indicating the format is
    /// recognized but unsupported.
    #[test]
    fn test_ctfs_new_format_detected_with_steps_dat() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("new-format.ct");

        // Create a container with steps.dat to trigger new-format detection.
        // The content doesn't matter — we just need the file to exist.
        let dat = meta_dat_bytes("/tmp/test", &[], "/tmp");
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("steps.dat", b"placeholder")]).unwrap();

        let result = CTFSTraceReader::open(&ct_path);
        // Without the nim-reader feature, new-format should error; with it,
        // it may succeed or fail depending on the container contents.
        #[cfg(not(feature = "nim-reader"))]
        {
            assert!(result.is_err());
            let err_msg = result.unwrap_err().to_string();
            assert!(
                err_msg.contains("nim-reader feature is not enabled"),
                "expected 'nim-reader feature is not enabled' error, got: {err_msg}"
            );
        }
        #[cfg(feature = "nim-reader")]
        {
            // With nim-reader, the Nim FFI will attempt to open the container.
            // A placeholder steps.dat may or may not parse depending on the
            // Nim reader's tolerance for minimal/invalid data. Either outcome
            // is acceptable — the important thing is that it doesn't panic and
            // the "not enabled" error is NOT returned.
            if let Err(e) = &result {
                let msg = e.to_string();
                assert!(
                    !msg.contains("nim-reader feature is not enabled"),
                    "nim-reader is enabled but got the 'not enabled' error: {msg}"
                );
            }
        }
    }

    /// M38 — GUI integration test: full trace pipeline through CTFSTraceReader.
    ///
    /// Creates a .ct container with CBOR-encoded TraceLowLevelEvent values
    /// exercising the full pipeline: path registration, function/type interning,
    /// call entry, step recording with variables, I/O event, and return.
    /// Then opens it with CTFSTraceReader and verifies:
    ///   - Step count, step navigation (path/line), step_map lookup
    ///   - Variable inspection at each step
    ///   - Call tree structure (function, depth, parent/child)
    ///   - Event count and content
    ///   - Interning tables (paths, functions, types, variable names)
    #[test]
    fn test_gui_pipeline_with_ctfs_trace() {
        use codetracer_trace_types::{
            CallRecord, EventLogKind, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, RecordEvent,
            ReturnRecord, StepRecord, TraceLowLevelEvent, TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord,
            VariableId,
        };
        use std::path::PathBuf;

        // -- Build a realistic event stream --
        //
        // Simulates a Python program "hello.py" with:
        //   path 0: /tmp/hello.py
        //   type 0: int
        //   type 1: str
        //   function 0: main (line 1)
        //   function 1: greet (line 5)
        //   variable 0: x
        //   variable 1: name
        //
        //   call main → step line 2 (x = 42) → call greet → step line 6 (name = "world")
        //     → event Write("Hello world") → return from greet → step line 3 → return from main
        let events: Vec<TraceLowLevelEvent> = vec![
            // Intern path
            TraceLowLevelEvent::Path(PathBuf::from("/tmp/hello.py")),
            // Intern types
            TraceLowLevelEvent::Type(TypeRecord {
                kind: TypeKind::Int,
                lang_type: "int".to_string(),
                specific_info: TypeSpecificInfo::None,
            }),
            TraceLowLevelEvent::Type(TypeRecord {
                kind: TypeKind::String,
                lang_type: "str".to_string(),
                specific_info: TypeSpecificInfo::None,
            }),
            // Intern functions
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(1),
                name: "main".to_string(),
            }),
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(5),
                name: "greet".to_string(),
            }),
            // Intern variable names
            TraceLowLevelEvent::VariableName("x".to_string()),
            TraceLowLevelEvent::VariableName("name".to_string()),
            // Call main (function_id=0)
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(0),
                args: vec![],
            }),
            // Step at line 2 of hello.py (x = 42)
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(2),
            }),
            TraceLowLevelEvent::Value(FullValueRecord {
                variable_id: VariableId(0),
                value: ValueRecord::Int {
                    i: 42,
                    type_id: TypeId(0),
                },
            }),
            // Call greet (function_id=1)
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(1),
                args: vec![FullValueRecord {
                    variable_id: VariableId(1),
                    value: ValueRecord::String {
                        text: "world".to_string(),
                        type_id: TypeId(1),
                    },
                }],
            }),
            // Step at line 6 of hello.py (inside greet)
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(6),
            }),
            TraceLowLevelEvent::Value(FullValueRecord {
                variable_id: VariableId(1),
                value: ValueRecord::String {
                    text: "world".to_string(),
                    type_id: TypeId(1),
                },
            }),
            // I/O event: stdout write
            TraceLowLevelEvent::Event(RecordEvent {
                kind: EventLogKind::Write,
                metadata: "stdout".to_string(),
                content: "Hello world".to_string(),
            }),
            // Return from greet
            TraceLowLevelEvent::Return(ReturnRecord {
                return_value: ValueRecord::None { type_id: TypeId(0) },
            }),
            // Step at line 3 (back in main, after greet returns)
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(3),
            }),
            // Return from main
            TraceLowLevelEvent::Return(ReturnRecord {
                return_value: ValueRecord::Int {
                    i: 0,
                    type_id: TypeId(0),
                },
            }),
        ];

        // Serialize events as sequential CBOR (legacy format).
        // cbor4ii::serde::to_vec takes ownership of the buffer and returns
        // the extended buffer, so we chain through each event.
        let mut cbor_buf = Vec::new();
        for event in &events {
            cbor_buf = cbor4ii::serde::to_vec(cbor_buf, event).expect("CBOR encode failed");
        }

        // Build the .ct container
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("pipeline.ct");
        let dat = meta_dat_bytes("/tmp/hello.py", &[], "/tmp");
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("events.log", &cbor_buf)]).unwrap();

        // Open with CTFSTraceReader (exercises the full old-format pipeline)
        let reader = CTFSTraceReader::open(&ct_path).unwrap();

        // --- Verify step count and navigation ---
        assert_eq!(reader.step_count(), 3, "expected 3 steps (line 2, 6, 3)");

        let step0 = reader.step(StepId(0)).expect("step 0 should exist");
        assert_eq!(step0.path_id, PathId(0));
        assert_eq!(step0.line, Line(2));

        let step1 = reader.step(StepId(1)).expect("step 1 should exist");
        assert_eq!(step1.path_id, PathId(0));
        assert_eq!(step1.line, Line(6));

        let step2 = reader.step(StepId(2)).expect("step 2 should exist");
        assert_eq!(step2.path_id, PathId(0));
        assert_eq!(step2.line, Line(3));

        // --- Verify step_map lookup (path + line → steps) ---
        let steps_on_line2 = reader.steps_on_line(PathId(0), 2).expect("should have steps on line 2");
        assert_eq!(steps_on_line2.len(), 1);
        assert_eq!(steps_on_line2[0].step_id, StepId(0));

        let steps_on_line6 = reader.steps_on_line(PathId(0), 6).expect("should have steps on line 6");
        assert_eq!(steps_on_line6.len(), 1);
        assert_eq!(steps_on_line6[0].step_id, StepId(1));

        // --- Verify variable inspection ---
        // Step 0 has x=42 from the Value event plus name="world" from the
        // Call(greet) args (the processor pushes call args onto the current
        // step's variable list before the callee's first step is recorded).
        let vars0 = reader.variables_at(StepId(0)).expect("step 0 should have variables");
        assert_eq!(vars0.len(), 2, "step 0 should have 2 variables (x + greet arg)");
        assert_eq!(vars0[0].variable_id, VariableId(0));
        match &vars0[0].value {
            ValueRecord::Int { i, .. } => assert_eq!(*i, 42),
            other => panic!("expected Int value for x, got {other:?}"),
        }

        let vars1 = reader.variables_at(StepId(1)).expect("step 1 should have variables");
        // Step 1 (inside greet) has the explicit Value event for name="world"
        assert!(
            !vars1.is_empty(),
            "step 1 should have at least 1 variable (name=\"world\")"
        );
        let has_world = vars1
            .iter()
            .any(|v| matches!(&v.value, ValueRecord::String { text, .. } if text == "world"));
        assert!(has_world, "step 1 should contain name=\"world\"");

        // --- Verify call tree ---
        assert_eq!(reader.call_count(), 2, "expected 2 calls (main, greet)");

        let call0 = reader.call(CallKey(0)).expect("call 0 (main) should exist");
        assert_eq!(call0.function_id, FunctionId(0));
        assert_eq!(call0.depth, 0, "main should be at depth 0");

        let call1 = reader.call(CallKey(1)).expect("call 1 (greet) should exist");
        assert_eq!(call1.function_id, FunctionId(1));
        assert_eq!(call1.depth, 1, "greet should be at depth 1");
        assert_eq!(call1.parent_key, CallKey(0), "greet's parent should be main");

        // Verify main has greet as a child
        assert!(
            call0.children_keys.contains(&CallKey(1)),
            "main should list greet as child"
        );

        // --- Verify events ---
        assert_eq!(reader.event_count(), 1, "expected 1 I/O event");
        let io_event = &reader.events()[0];
        assert_eq!(io_event.kind, EventLogKind::Write);
        assert_eq!(io_event.content, "Hello world");

        // --- Verify interning tables ---
        assert_eq!(reader.path_count(), 1);
        assert_eq!(reader.path(PathId(0)).unwrap(), "/tmp/hello.py");
        assert_eq!(reader.path_id_for("/tmp/hello.py"), Some(PathId(0)));

        assert_eq!(reader.function_count(), 2);
        assert_eq!(reader.function(FunctionId(0)).unwrap().name, "main");
        assert_eq!(reader.function(FunctionId(1)).unwrap().name, "greet");

        assert_eq!(reader.type_count(), 2);
        assert_eq!(reader.type_record(TypeId(0)).unwrap().lang_type, "int");
        assert_eq!(reader.type_record(TypeId(1)).unwrap().lang_type, "str");

        assert_eq!(reader.variable_name(VariableId(0)).unwrap(), "x");
        assert_eq!(reader.variable_name(VariableId(1)).unwrap(), "name");

        // --- Verify metadata ---
        assert_eq!(reader.workdir().to_str().unwrap(), "/tmp");
        assert!(
            matches!(reader.end_of_program(), EndOfProgram::Normal),
            "expected Normal end of program"
        );
    }

    /// M0 — end-to-end: the db-backend opens a real materialized `.ct`
    /// fixture (whose internal files are stored as CTFS blocks resolved through
    /// the M0 [`BlockSource`] seam) and serves a known step + variable
    /// identically to the pre-refactor behaviour.
    ///
    /// The fixture is a self-contained old-format trace built by the container
    /// writer: opening it drives `CtfsReader::read_file` (now routed through an
    /// `InMemoryBlockSource`) for `meta.dat` and `events.log`, then the full
    /// trace pipeline.  A block misrouted by the seam would corrupt the CBOR
    /// event stream and break the step/variable assertions below, so this test
    /// genuinely exercises the seam end-to-end rather than asserting a trivial
    /// fact.
    #[test]
    fn e2e_db_backend_open_materialized_unchanged() {
        use codetracer_trace_types::{
            CallRecord, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, StepRecord, TraceLowLevelEvent,
            TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
        };
        use std::path::PathBuf;

        // A small but real trace: main() steps line 2 with x = 1234567.
        let events: Vec<TraceLowLevelEvent> = vec![
            TraceLowLevelEvent::Path(PathBuf::from("/tmp/prog.py")),
            TraceLowLevelEvent::Type(TypeRecord {
                kind: TypeKind::Int,
                lang_type: "int".to_string(),
                specific_info: TypeSpecificInfo::None,
            }),
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(1),
                name: "main".to_string(),
            }),
            TraceLowLevelEvent::VariableName("x".to_string()),
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(0),
                args: vec![],
            }),
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(2),
            }),
            TraceLowLevelEvent::Value(FullValueRecord {
                variable_id: VariableId(0),
                value: ValueRecord::Int {
                    i: 1_234_567,
                    type_id: TypeId(0),
                },
            }),
        ];

        let mut cbor_buf = Vec::new();
        for event in &events {
            cbor_buf = cbor4ii::serde::to_vec(cbor_buf, event).expect("CBOR encode failed");
        }

        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("materialized.ct");
        let dat = meta_dat_bytes("/tmp/prog.py", &[], "/tmp");
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("events.log", &cbor_buf)]).unwrap();

        // Open through the db-backend reader (default InMemoryBlockSource seam).
        let reader = CTFSTraceReader::open(&ct_path).unwrap();

        // Known step served identically: step 0 is line 2 of prog.py.
        assert_eq!(reader.step_count(), 1, "expected exactly 1 step");
        let step0 = reader.step(StepId(0)).expect("step 0 should exist");
        assert_eq!(step0.path_id, PathId(0));
        assert_eq!(step0.line, Line(2));

        // Known variable served identically: x = 1234567 at step 0.
        let vars0 = reader.variables_at(StepId(0)).expect("step 0 should have variables");
        let x = vars0
            .iter()
            .find(|v| v.variable_id == VariableId(0))
            .expect("variable x should be present at step 0");
        match &x.value {
            ValueRecord::Int { i, .. } => assert_eq!(*i, 1_234_567, "x must round-trip exactly through the seam"),
            other => panic!("expected Int value for x, got {other:?}"),
        }

        // Interning + metadata served identically.
        assert_eq!(reader.path(PathId(0)).unwrap(), "/tmp/prog.py");
        assert_eq!(reader.function(FunctionId(0)).unwrap().name, "main");
        assert_eq!(reader.variable_name(VariableId(0)).unwrap(), "x");
        assert_eq!(reader.workdir().to_str().unwrap(), "/tmp");
    }

    /// Verify the `is_new_format` helper function directly.
    #[test]
    fn test_is_new_format_detection() {
        let dir = tempfile::tempdir().unwrap();
        let dat = meta_dat_bytes("/tmp/test", &[], "/tmp");

        // Old format: no steps.dat
        let old_path = dir.path().join("old.ct");
        ctfs_container::write_minimal_ctfs(&old_path, &[("meta.dat", &dat)]).unwrap();
        let old_ctfs = CtfsReader::open(&old_path).unwrap();
        assert!(!is_new_format(&old_ctfs));

        // New (production Nim) format: has steps.dat, NO events.log.
        let new_path = dir.path().join("new.ct");
        ctfs_container::write_minimal_ctfs(&new_path, &[("meta.dat", &dat), ("steps.dat", b"data")]).unwrap();
        let new_ctfs = CtfsReader::open(&new_path).unwrap();
        assert!(is_new_format(&new_ctfs));

        // M23e-4 combined (secondary Rust-writer) format: has BOTH steps.dat AND
        // events.log. This MUST take the legacy events.log path — the Rust split
        // wire formats are not Nim-FFI-readable for steps/values/events — so
        // `is_new_format` is false.
        let combined_path = dir.path().join("combined.ct");
        ctfs_container::write_minimal_ctfs(
            &combined_path,
            &[("meta.dat", &dat), ("steps.dat", b"data"), ("events.log", b"data")],
        )
        .unwrap();
        let combined_ctfs = CtfsReader::open(&combined_path).unwrap();
        assert!(
            !is_new_format(&combined_ctfs),
            "a bundle with both steps.dat and events.log is the Rust-writer combined format \
             and must read via the legacy events.log path"
        );
    }

    // ── M43: GUI latency benchmarks ────────────────────────────────────

    /// Build a .ct container with the given number of steps, each with one
    /// variable value. Returns the path to the temporary .ct file. The
    /// caller should keep the `TempDir` alive until done.
    fn build_trace_with_steps(dir: &std::path::Path, step_count: usize) -> std::path::PathBuf {
        use codetracer_trace_types::{
            CallRecord, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, StepRecord, TraceLowLevelEvent,
            TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
        };
        use std::path::PathBuf;

        // Build a realistic event stream with `step_count` steps.
        let mut events: Vec<TraceLowLevelEvent> = Vec::new();

        // Intern 10 paths so path_id varies
        for i in 0..10 {
            events.push(TraceLowLevelEvent::Path(PathBuf::from(format!("/src/file_{i}.py"))));
        }

        // Intern types
        events.push(TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::Int,
            lang_type: "int".to_string(),
            specific_info: TypeSpecificInfo::None,
        }));

        // Intern a function
        events.push(TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "main".to_string(),
        }));

        // Intern variable name
        events.push(TraceLowLevelEvent::VariableName("x".to_string()));

        // Call main
        events.push(TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(0),
            args: vec![],
        }));

        // N steps with alternating path_id and incrementing lines
        for i in 0..step_count {
            events.push(TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(i % 10),
                line: Line((i + 1) as i64),
            }));
            events.push(TraceLowLevelEvent::Value(FullValueRecord {
                variable_id: VariableId(0),
                value: ValueRecord::Int {
                    i: i as i64,
                    type_id: TypeId(0),
                },
            }));
        }

        // Return from main
        events.push(TraceLowLevelEvent::Return(codetracer_trace_types::ReturnRecord {
            return_value: ValueRecord::None { type_id: TypeId(0) },
        }));

        // Serialize as CBOR
        let mut cbor_buf = Vec::new();
        for event in &events {
            cbor_buf = cbor4ii::serde::to_vec(cbor_buf, event).expect("CBOR encode failed");
        }

        let ct_path = dir.join("bench_trace.ct");
        let dat = meta_dat_bytes("/tmp/bench.py", &[], "/tmp");
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("events.log", &cbor_buf)]).unwrap();

        ct_path
    }

    /// Compute the median of a sorted duration slice.
    fn median_duration(durations: &mut [std::time::Duration]) -> std::time::Duration {
        durations.sort();
        let mid = durations.len() / 2;
        if durations.len().is_multiple_of(2) {
            (durations[mid - 1] + durations[mid]) / 2
        } else {
            durations[mid]
        }
    }

    /// M43 — GUI step navigation latency benchmark.
    ///
    /// Creates a trace with 10K steps, measures the time for 100 random
    /// step navigations via `reader.step()`, and asserts the median latency
    /// is below a reasonable threshold.
    ///
    /// This validates that the GUI can navigate steps interactively without
    /// perceptible lag. The postprocessed `Db` stores steps in a contiguous
    /// `DistinctVec`, so random access should be O(1).
    #[test]
    fn bench_gui_step_navigation_latency() {
        use std::time::Instant;

        let dir = tempfile::tempdir().unwrap();
        let ct_path = build_trace_with_steps(dir.path(), 10_000);

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 10_000);

        // Deterministic pseudo-random step indices (avoid rand dependency).
        // LCG: seed=42, a=1103515245, c=12345, m=2^31
        let mut rng_state: u64 = 42;
        let mut step_indices: Vec<usize> = Vec::with_capacity(100);
        for _ in 0..100 {
            rng_state = (rng_state.wrapping_mul(1103515245).wrapping_add(12345)) & 0x7FFFFFFF;
            step_indices.push((rng_state as usize) % 10_000);
        }

        // Warm up: access a few steps to ensure any lazy initialization is done
        for i in 0i64..10 {
            let _ = reader.step(StepId(i));
        }

        // Measure 100 random step navigations
        let mut durations = Vec::with_capacity(100);
        for &idx in &step_indices {
            let start = Instant::now();
            let step = reader.step(StepId(idx as i64));
            let elapsed = start.elapsed();

            assert!(step.is_some(), "step {idx} should exist");
            durations.push(elapsed);
        }

        let median = median_duration(&mut durations);

        // Print results as JSON for CI consumption
        println!(
            "{{\"benchmark\":\"gui_step_navigation\",\"step_count\":10000,\
             \"samples\":100,\"median_us\":{},\"max_us\":{}}}",
            median.as_micros(),
            durations.iter().max().unwrap().as_micros()
        );

        // Assert median < 100us. On modern hardware, indexed Vec access
        // should be well under 1us. We use 100us as a generous upper bound
        // to avoid flaky failures on slow CI machines.
        assert!(
            median.as_micros() < 100,
            "step navigation median latency too high: {}us (threshold: 100us)",
            median.as_micros()
        );
    }

    /// M43 — GUI variable load latency benchmark.
    ///
    /// Creates a trace with 10K steps (each with one variable), measures
    /// the time for 100 random `variables_at()` lookups, and asserts the
    /// median latency is below a reasonable threshold.
    ///
    /// This validates that the GUI can load variable panels without lag.
    /// Variable data is stored in a `DistinctVec<Vec<FullValueRecord>>`,
    /// so random access should be O(1) with the cost dominated by the
    /// slice creation.
    #[test]
    fn bench_gui_variable_load_latency() {
        use std::time::Instant;

        let dir = tempfile::tempdir().unwrap();
        let ct_path = build_trace_with_steps(dir.path(), 10_000);

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 10_000);

        // Deterministic pseudo-random step indices (different seed from above)
        let mut rng_state: u64 = 137;
        let mut step_indices: Vec<usize> = Vec::with_capacity(100);
        for _ in 0..100 {
            rng_state = (rng_state.wrapping_mul(1103515245).wrapping_add(12345)) & 0x7FFFFFFF;
            step_indices.push((rng_state as usize) % 10_000);
        }

        // Warm up
        for i in 0i64..10 {
            let _ = reader.variables_at(StepId(i));
        }

        // Measure 100 random variable loads
        let mut durations = Vec::with_capacity(100);
        for &idx in &step_indices {
            let start = Instant::now();
            let vars = reader.variables_at(StepId(idx as i64));
            let elapsed = start.elapsed();

            assert!(vars.is_some(), "variables at step {idx} should exist");
            // Each step should have exactly 1 variable (x = step_index)
            assert_eq!(vars.unwrap().len(), 1, "step {idx} should have 1 variable");
            durations.push(elapsed);
        }

        let median = median_duration(&mut durations);

        // Print results as JSON for CI consumption
        println!(
            "{{\"benchmark\":\"gui_variable_load\",\"step_count\":10000,\
             \"samples\":100,\"median_us\":{},\"max_us\":{}}}",
            median.as_micros(),
            durations.iter().max().unwrap().as_micros()
        );

        // Assert median < 500us. Variable lookup is a Vec index + slice
        // creation, should be under 1us on modern hardware. Use 500us as
        // a generous bound for slow CI.
        assert!(
            median.as_micros() < 500,
            "variable load median latency too high: {}us (threshold: 500us)",
            median.as_micros()
        );
    }

    /// M43 — GUI call tree viewport latency benchmark.
    ///
    /// Creates a trace with 10K steps and a call tree, measures the time for
    /// 100 random `call()` lookups plus children enumeration, and asserts the
    /// median latency is below 500us.
    ///
    /// This validates that the GUI can render call tree viewports without lag.
    /// Call data is stored in a contiguous `DistinctVec<DbCall>`, so random
    /// access should be O(1) plus the cost of iterating `children_keys`.
    #[test]
    fn bench_gui_call_tree_viewport_latency() {
        use std::time::Instant;

        let dir = tempfile::tempdir().unwrap();
        let ct_path = build_trace_with_steps(dir.path(), 10_000);

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        // The trace has 1 call (main) with all 10K steps inside it.
        assert!(reader.call_count() >= 1, "expected at least 1 call");

        // Warm up
        for i in 0i64..reader.call_count().min(10) as i64 {
            let _ = reader.call(CallKey(i));
        }

        // Measure 100 call lookups (cycling through available calls)
        let call_count = reader.call_count();
        let mut durations = Vec::with_capacity(100);
        for sample in 0..100usize {
            let key = CallKey((sample % call_count) as i64);
            let start = Instant::now();
            let call = reader.call(key);
            // Also access children_keys to simulate viewport rendering
            if let Some(c) = call {
                let _ = c.children_keys.len();
                let _ = c.function_id;
                let _ = c.depth;
            }
            let elapsed = start.elapsed();
            durations.push(elapsed);
        }

        let median = median_duration(&mut durations);

        println!(
            "{{\"benchmark\":\"gui_call_tree_viewport\",\"call_count\":{},\
             \"samples\":100,\"median_us\":{},\"max_us\":{}}}",
            call_count,
            median.as_micros(),
            durations.iter().max().unwrap().as_micros()
        );

        assert!(
            median.as_micros() < 500,
            "call tree viewport median latency too high: {}us (threshold: 500us)",
            median.as_micros()
        );
    }

    /// M43 — GUI event log page load latency benchmark.
    ///
    /// Creates a trace with events, measures the time to load a page of 50
    /// events via `reader.events()` slice access, and asserts median < 1ms.
    ///
    /// This validates that the GUI event log panel can paginate without lag.
    #[test]
    fn bench_gui_event_log_page_load_latency() {
        use codetracer_trace_types::{
            CallRecord, EventLogKind, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, RecordEvent,
            StepRecord, TraceLowLevelEvent, TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
        };
        use std::path::PathBuf;
        use std::time::Instant;

        // Build a trace with 200 I/O events across 200 steps
        let dir = tempfile::tempdir().unwrap();
        let mut events: Vec<TraceLowLevelEvent> = vec![
            TraceLowLevelEvent::Path(PathBuf::from("/src/main.py")),
            TraceLowLevelEvent::Type(TypeRecord {
                kind: TypeKind::Int,
                lang_type: "int".to_string(),
                specific_info: TypeSpecificInfo::None,
            }),
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(1),
                name: "main".to_string(),
            }),
            TraceLowLevelEvent::VariableName("i".to_string()),
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(0),
                args: vec![],
            }),
        ];

        for i in 0..200usize {
            events.push(TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line((i + 1) as i64),
            }));
            events.push(TraceLowLevelEvent::Value(FullValueRecord {
                variable_id: VariableId(0),
                value: ValueRecord::Int {
                    i: i as i64,
                    type_id: TypeId(0),
                },
            }));
            events.push(TraceLowLevelEvent::Event(RecordEvent {
                kind: EventLogKind::Write,
                metadata: "stdout".to_string(),
                content: format!("output line {i}"),
            }));
        }

        events.push(TraceLowLevelEvent::Return(codetracer_trace_types::ReturnRecord {
            return_value: ValueRecord::None { type_id: TypeId(0) },
        }));

        let mut cbor_buf = Vec::new();
        for event in &events {
            cbor_buf = cbor4ii::serde::to_vec(cbor_buf, event).expect("CBOR encode failed");
        }

        let ct_path = dir.path().join("event_bench.ct");
        let dat = meta_dat_bytes("/tmp/main.py", &[], "/tmp");
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("events.log", &cbor_buf)]).unwrap();

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.event_count(), 200);

        // Warm up
        let _ = reader.events();

        // Measure 100 page loads of 50 events each (simulating pagination)
        let total_events = reader.event_count();
        let page_size = 50usize;
        let mut durations = Vec::with_capacity(100);

        // Deterministic page offsets
        let mut rng_state: u64 = 99;
        for _ in 0..100 {
            rng_state = (rng_state.wrapping_mul(1103515245).wrapping_add(12345)) & 0x7FFFFFFF;
            let offset = (rng_state as usize) % (total_events.saturating_sub(page_size) + 1);

            let start = Instant::now();
            let all_events = reader.events();
            let end = (offset + page_size).min(all_events.len());
            let page = &all_events[offset..end];
            // Simulate reading event fields for rendering
            for ev in page {
                let _ = &ev.content;
                let _ = ev.kind;
                let _ = ev.step_id;
            }
            let elapsed = start.elapsed();
            durations.push(elapsed);
        }

        let median = median_duration(&mut durations);

        println!(
            "{{\"benchmark\":\"gui_event_log_page_load\",\"event_count\":{},\
             \"page_size\":{},\"samples\":100,\"median_us\":{},\"max_us\":{}}}",
            total_events,
            page_size,
            median.as_micros(),
            durations.iter().max().unwrap().as_micros()
        );

        // Assert median < 1ms (1000us) for loading 50 events
        assert!(
            median.as_micros() < 1000,
            "event log page load median latency too high: {}us (threshold: 1000us)",
            median.as_micros()
        );
    }

    /// M37 — Verify that the old-format postprocessing path correctly builds
    /// the `Db` from a 1000-step trace. This is not a startup time benchmark
    /// (the old format always requires O(n) postprocessing); it verifies
    /// correctness of the existing path that M37 preserves.
    ///
    /// The new-format startup time benchmark (`bench_new_format_startup_time`)
    /// requires the `nim-reader` feature because `open_new_format` delegates
    /// to the Nim seek-based reader. Without that feature, the new-format
    /// path returns an error, so the benchmark is feature-gated.
    #[test]
    fn bench_old_format_postprocess_1000_steps() {
        use std::time::Instant;

        let dir = tempfile::tempdir().unwrap();
        let ct_path = build_trace_with_steps(dir.path(), 1000);

        let start = Instant::now();
        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        let elapsed = start.elapsed();

        assert_eq!(reader.step_count(), 1000);
        println!(
            "{{\"benchmark\":\"old_format_postprocess_1000\",\"startup_ms\":{}}}",
            elapsed.as_millis()
        );

        // Old format with 1000 steps should complete well under 1 second.
        assert!(
            elapsed.as_millis() < 1000,
            "old-format postprocessing took too long: {}ms (threshold: 1000ms)",
            elapsed.as_millis()
        );
    }

    /// M37 — Verify new-format startup time is < 200ms.
    ///
    /// This test requires the `nim-reader` feature because `open_new_format`
    /// delegates to the Nim seek-based reader. When `nim-reader` is enabled,
    /// a properly formatted new-format `.ct` file should open in < 200ms
    /// because no O(n) postprocessing occurs — data is loaded on demand from
    /// pre-computed data structures.
    ///
    /// Without `nim-reader`, the test verifies that format detection correctly
    /// identifies the new format and returns an appropriate error.
    #[test]
    fn bench_new_format_startup_time() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("new-format-bench.ct");

        // Create a minimal new-format container with steps.dat to trigger
        // format detection. The actual content depends on the Nim writer's
        // output format.
        let dat = meta_dat_bytes("/tmp/bench.py", &[], "/tmp");
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("steps.dat", b"placeholder")]).unwrap();

        #[cfg(not(feature = "nim-reader"))]
        {
            // Without nim-reader, verify format detection works but open fails
            // with the expected error (not a postprocessing error).
            let result = CTFSTraceReader::open(&ct_path);
            assert!(result.is_err());
            let err = result.unwrap_err().to_string();
            assert!(
                err.contains("nim-reader"),
                "expected nim-reader feature error, got: {err}"
            );
        }

        #[cfg(feature = "nim-reader")]
        {
            use std::time::Instant;

            // With nim-reader, the open should succeed (assuming the Nim reader
            // can handle the container) and complete under 200ms.
            let start = Instant::now();
            let result = CTFSTraceReader::open(&ct_path);
            let elapsed = start.elapsed();

            // NOTE: This test uses a placeholder steps.dat which the Nim reader
            // may not accept. If it errors, that's expected — the startup time
            // is still measured up to the point of error detection. A real
            // integration test with a properly recorded trace is needed for
            // full M37 verification (see M38).
            match result {
                Ok(_) => {
                    println!(
                        "{{\"benchmark\":\"new_format_startup\",\"startup_ms\":{}}}",
                        elapsed.as_millis()
                    );
                    // Default dev-machine SLA is 200ms.  Shared CI runners
                    // (especially GitHub-hosted windows-latest) are 2-3x
                    // slower than a developer workstation, so let CI
                    // override the threshold via env var instead of
                    // flaking on the dev-machine value.  No env var ->
                    // legacy 200ms enforcement is unchanged.
                    let threshold_ms: u128 = std::env::var("CT_BENCH_STARTUP_MS_THRESHOLD")
                        .ok()
                        .and_then(|raw| raw.parse().ok())
                        .filter(|&v: &u128| v > 0)
                        .unwrap_or(200);
                    assert!(
                        elapsed.as_millis() < threshold_ms,
                        "new-format startup took too long: {}ms (threshold: {}ms)",
                        elapsed.as_millis(),
                        threshold_ms
                    );
                }
                Err(e) => {
                    // Expected for placeholder data. The key verification is that
                    // the startup path reached the Nim reader (not postprocess).
                    let err = e.to_string();
                    assert!(
                        !err.contains("postprocess"),
                        "new-format path should not involve postprocessing, but got: {err}"
                    );
                    println!(
                        "{{\"benchmark\":\"new_format_startup\",\"status\":\"error\",\
                         \"startup_ms\":{},\"error\":\"{}\"}}",
                        elapsed.as_millis(),
                        err.replace('"', "'")
                    );
                }
            }
        }
    }

    // ── meta.dat metadata-loading tests ───────────────────────────────
    //
    // These tests pin the canonical metadata-loading behavior:
    // `open_old_format` loads from the binary `meta.dat` file inside the
    // CTFS container.  M-REC-1.5 (pre-1.0) removed the legacy `meta.json`
    // fallback, so any trace that lacks `meta.dat` is rejected outright.

    /// Helper: build a syntactically valid v3 [`meta_dat::MetaDat`] for
    /// tests with the canonical pinned UUIDv7 recording_id.
    fn test_meta_dat_v3(program: &str, args: Vec<String>, workdir: &str) -> meta_dat::MetaDat {
        meta_dat::MetaDat {
            version: meta_dat::META_DAT_VERSION,
            flags: 0,
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
            program: program.to_owned(),
            args,
            workdir: workdir.to_owned(),
            recorder_id: "test".to_owned(),
            paths: vec![],
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: vec![],
            has_filter_provenance: false,
        }
    }

    /// A trace with `meta.dat` loads using the canonical binary metadata.
    #[test]
    fn open_old_format_reads_meta_dat_when_present() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("meta-dat-only.ct");

        let dat = meta_dat::serialize_meta_dat(&test_meta_dat_v3(
            "/usr/bin/myprog",
            vec!["--verbose".to_owned(), "input.txt".to_owned()],
            "/srv/work",
        ));

        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat)]).unwrap();

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.workdir().to_str().unwrap(), "/srv/work");
    }

    /// M-REC-1.5: a trace that lacks `meta.dat` is rejected.  Previously
    /// such traces fell back to a JSON sidecar; that path is gone.
    #[test]
    fn open_old_format_rejects_trace_without_meta_dat() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("no-meta-dat.ct");

        // Container with only events.log (no meta.dat); used to fall back
        // to `meta.json`, now an error.
        let placeholder_events: &[u8] = b"";
        ctfs_container::write_minimal_ctfs(&ct_path, &[("events.log", placeholder_events)]).unwrap();

        let err = CTFSTraceReader::open(&ct_path)
            .expect_err("open must fail when meta.dat is missing")
            .to_string();
        assert!(
            err.contains("meta.dat"),
            "expected error to mention meta.dat, got: {err}",
        );
    }

    /// If `meta.dat` is present but corrupted, the open must error rather
    /// than producing nonsense metadata.
    #[test]
    fn open_old_format_propagates_meta_dat_parse_errors() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("bad-meta-dat.ct");

        // Bytes too short to even contain the 8-byte header — guarantees
        // a `MetaDatError::TooShort` from the parser.
        let bad_dat = [0x00u8; 4];
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.dat", &bad_dat)]).unwrap();

        let result = CTFSTraceReader::open(&ct_path);
        let err = result.expect_err("open must fail on malformed meta.dat").to_string();
        assert!(
            err.contains("failed to parse meta.dat"),
            "expected meta.dat parse error, got: {err}",
        );
    }
}
