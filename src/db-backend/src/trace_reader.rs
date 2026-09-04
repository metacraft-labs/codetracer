use std::collections::HashMap;
use std::path::{Path, PathBuf};

use log::{info, warn};
use num_bigint::BigInt;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, Line, NO_KEY, PathId, Place, StepId, TypeId, TypeKind,
    TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
};

use crate::db::{
    CellChange, DbCall, DbRecordEvent, DbStep, EndOfProgram, NEXT_INTERNAL_STEP_OVERS_LIMIT, OUTERMOST_CALL_DEPTH,
};
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
use crate::task::{Call, CallArg, Location, RRTicks};
use crate::value::{Type, Value};

/// Facade for reading trace data.
///
/// Implementations may load data from in-memory arrays (current `Db`),
/// memory-mapped CTFS files (future), or any other backing store.
///
/// The trait is intentionally read-only — it never mutates the underlying
/// data. Methods that return `Option` signal "no such id" rather than
/// panicking, so callers can decide how to handle missing data.
///
/// # Design notes
///
/// * **Interning tables** (paths, functions, types, variable names) are
///   small enough to always live in memory, even in a file-backed
///   implementation.
/// * **Per-step data** (steps, variables, compound values, cells) may be
///   large. In a CTFS-backed implementation these would be seek-addressed
///   from a memory-mapped file.
/// * **Secondary indices** (path_map, step_map) accelerate lookups that
///   the handler performs frequently.
pub trait TraceReader: std::fmt::Debug + Send {
    // ── Interning tables ────────────────────────────────────────────

    /// Resolve a path id to its string representation (relative to workdir).
    fn path(&self, id: PathId) -> Option<&str>;

    /// Look up a function record by id.
    fn function(&self, id: FunctionId) -> Option<&FunctionRecord>;

    /// Look up a type record by id.
    fn type_record(&self, id: TypeId) -> Option<&TypeRecord>;

    /// Resolve a variable id to its human-readable name.
    fn variable_name(&self, id: VariableId) -> Option<&str>;

    /// Reverse-lookup: return the `VariableId` for a given variable
    /// name, scanning the interning table. Used by the per-session
    /// origin-summary cache (spec §3.2.3 / M2 deliverable) where the
    /// cache key is `(VariableId, StepId)`. Default impl is O(n) over
    /// the variable name table; concrete implementations may override
    /// with a hash index when scanning becomes a hot path.
    fn variable_id_for(&self, name: &str) -> Option<VariableId> {
        // The fully generic fall-back: scan the name table. Concrete
        // backends with their own interning maps override this for O(1).
        let mut idx: usize = 0;
        loop {
            let id = VariableId(idx);
            match self.variable_name(id) {
                Some(n) if n == name => return Some(id),
                Some(_) => idx += 1,
                None => return None,
            }
        }
    }

    /// Total number of recorded paths.
    fn path_count(&self) -> usize;

    /// Total number of recorded functions.
    fn function_count(&self) -> usize;

    /// Total number of recorded types.
    fn type_count(&self) -> usize;

    // ── Per-step data ───────────────────────────────────────────────

    /// Look up a single step by id.
    fn step(&self, id: StepId) -> Option<&DbStep>;

    /// Total number of recorded steps.
    fn step_count(&self) -> usize;

    /// Local variable values captured at a particular step.
    fn variables_at(&self, step_id: StepId) -> Option<&[FullValueRecord]>;

    /// Compound (aggregate) values captured at a particular step,
    /// keyed by `Place`.
    fn compound_at(&self, step_id: StepId) -> Option<&HashMap<Place, ValueRecord>>;

    /// Cell values captured at a particular step, keyed by `Place`.
    fn cells_at(&self, step_id: StepId) -> Option<&HashMap<Place, ValueRecord>>;

    /// The full cell-change history for a given `Place`.
    fn cell_changes_for(&self, place: &Place) -> Option<&Vec<CellChange>>;

    /// Variable-to-cell mapping at a particular step.
    fn variable_cells_at(&self, step_id: StepId) -> Option<&HashMap<VariableId, Place>>;

    // ── Call tree ───────────────────────────────────────────────────

    /// Look up a call by its key.
    fn call(&self, key: CallKey) -> Option<&DbCall>;

    /// Total number of recorded calls.
    fn call_count(&self) -> usize;

    // ── Seekable call tree (M17b) ────────────────────────────────────
    //
    // The default `call`/`call_count` above serve the call tree from a
    // fully-materialized `Db`. A SEEKABLE reader (the db-backend's
    // `CTFSTraceReader` over a `has_call_stream` `.ct`) can instead serve the
    // call tree ON DEMAND from the dedicated `calls.dat` stream, decompressing
    // only the chunk a request needs — so a network-loaded `.ct` never
    // materializes the whole call tree (Trace-Files-Overview.md §"Random-access
    // seeking"; trace-events.md "Call tree loads independently … no step
    // scanning needed").
    //
    // These are additive, default-`None` hooks so every existing reader keeps
    // its current behaviour; consumers that want the seekable path (e.g.
    // `Calltrace::new`) check `seekable_call_count()` first and fall back to the
    // materialized `call`/`call_count` when it is `None`.

    /// `Some(n)` when this reader serves the call tree from a SEEKABLE
    /// `calls.dat` stream (on-demand, not from a materialized `Db`), where `n`
    /// is the call count; `None` for fully-materialized readers.
    fn seekable_call_count(&self) -> Option<usize> {
        None
    }

    /// Fetch one call by key from the SEEKABLE `calls.dat` stream, decompressing
    /// only the chunk that holds it. Returns an OWNED [`DbCall`] (the seekable
    /// path does not keep calls resident, unlike the borrowing `call`). Returns
    /// `None` when this reader has no seekable stream or the key is out of range.
    fn seekable_call(&self, _key: CallKey) -> Option<DbCall> {
        None
    }

    // ── Seekable step + value streams (M22) ──────────────────────────
    //
    // M17b made the CALL tree seekable; the per-step source LINE and the
    // per-step VARIABLE VALUES still came from a fully-materialized `Db`. These
    // additive, default-`None` hooks let a SEEKABLE reader (the db-backend's
    // `CTFSTraceReader` over a `has_step_stream` + `has_value_stream` `.ct`)
    // serve a step's line and a step's variable values ON DEMAND from
    // `steps.dat`/`values.dat`, decompressing only the chunk a request needs —
    // so a network-loaded `.ct` never materializes the whole step/value stream
    // (Trace-Files-Overview.md §"Random-access seeking").
    //
    // As with the call hooks, these are default-`None` so every existing reader
    // keeps its current behaviour; consumers that want the seekable path check
    // the count hook first and fall back to the materialized
    // `step`/`variables_at` when it is `None`.

    /// `Some(n)` when this reader serves the step timeline from a SEEKABLE
    /// `steps.dat` stream (on-demand, not from a materialized `Db`), where `n`
    /// is the step-record count; `None` for fully-materialized readers.
    fn seekable_step_count(&self) -> Option<usize> {
        None
    }

    /// Fetch the `(path_id, line)` of a step from the SEEKABLE `steps.dat`
    /// stream, decompressing only the chunk that holds it. Returns `None` when
    /// this reader has no seekable stream, the id is out of range, or the record
    /// at that index carries no source line (a Raise/Catch/ThreadSwitch marker).
    fn seekable_step_line(&self, _step_id: StepId) -> Option<(PathId, Line)> {
        None
    }

    /// `Some(n)` when this reader serves per-step variable values from a SEEKABLE
    /// `values.dat` stream (on-demand), where `n` is the value-record count
    /// (== step count by the parallel-index invariant); `None` otherwise.
    fn seekable_value_count(&self) -> Option<usize> {
        None
    }

    /// Fetch the variable values visible at a step from the SEEKABLE
    /// `values.dat` stream, decompressing only the chunk that holds it. Returns
    /// OWNED [`FullValueRecord`]s (an empty vec for a step with no variable
    /// activity). Returns `None` when this reader has no seekable stream or the
    /// id is out of range.
    fn seekable_variables_at(&self, _step_id: StepId) -> Option<Vec<FullValueRecord>> {
        None
    }

    /// Per-step variable values as an OWNED vec, PREFERRING the seekable
    /// `values.dat` stream when present and falling back to the materialized
    /// `variables_at` otherwise.
    ///
    /// This is the M22 production read path for step variables: the DAP
    /// variable handlers (`load_locals`, `load_value`) call it so a
    /// `has_value_stream` `.ct` reads a step's values ON DEMAND from
    /// `values.dat` (bounded decompression) instead of from a fully-materialized
    /// `Db`. The fallback keeps legacy (flag-off) bundles bit-for-bit unchanged.
    ///
    /// Returns `None` only when the step id is out of range on BOTH paths.
    fn variables_at_owned(&self, step_id: StepId) -> Option<Vec<FullValueRecord>> {
        if self.seekable_value_count().is_some()
            && let Some(values) = self.seekable_variables_at(step_id)
        {
            return Some(values);
        }
        self.variables_at(step_id).map(|v| v.to_vec())
    }

    // ── Events ──────────────────────────────────────────────────────

    /// All recorded events, in order.
    ///
    /// This is the MATERIALIZING accessor: it hands out a borrowed slice, so a
    /// reader backed by a seekable `events.dat` stream has to decode the whole
    /// stream to answer it. Prefer [`event_count`](Self::event_count) when only
    /// the total is wanted, and
    /// [`seekable_event_page`](Self::seekable_event_page) when only a window is.
    fn events(&self) -> &[DbRecordEvent];

    /// Total number of recorded events.
    ///
    /// Readers backed by a seekable `events.dat` answer this from the stream's
    /// chunk index without decoding any event.
    fn event_count(&self) -> usize;

    /// M0/4 — the number of events available through the SEEKABLE `events.dat`
    /// stream, or `None` when this reader has no such stream.
    ///
    /// `Some(_)` is the caller's signal that
    /// [`seekable_event_page`](Self::seekable_event_page) is worth using
    /// instead of [`events`](Self::events) — the same shape as
    /// [`seekable_call_count`](Self::seekable_call_count) and
    /// [`seekable_step_count`](Self::seekable_step_count).
    fn seekable_event_count(&self) -> Option<usize> {
        None
    }

    /// M0/4 — read a contiguous page of `len` events starting at `start` from
    /// the seekable `events.dat` stream, decompressing only the chunks the page
    /// spans. `None` when this reader has no seekable event stream; an empty
    /// vector when `start` is past the end.
    ///
    /// This is what lets an event-log pane paginate a trace whose event stream
    /// does not fit in a browser tab's memory budget.
    fn seekable_event_page(&self, start: usize, len: usize) -> Option<Vec<DbRecordEvent>> {
        let _ = (start, len);
        None
    }

    // ── Secondary indices ───────────────────────────────────────────

    /// Reverse-lookup: find the `PathId` for a given path string.
    fn path_id_for(&self, path: &str) -> Option<PathId>;

    /// Return the step records on a given `line` within a given path.
    /// Returns `None` when the path or line has no recorded steps.
    fn steps_on_line(&self, path_id: PathId, line: usize) -> Option<&Vec<DbStep>>;

    /// Return the full line→steps map for a given path.
    fn step_map_for_path(&self, path_id: PathId) -> Option<&HashMap<usize, Vec<DbStep>>>;

    /// M26 — the ascending `step_id`s recorded on `(path_id, line)` — the
    /// BREAKPOINT-resolution primitive.
    ///
    /// This is `steps_on_line` reduced to just the step ids a breakpoint
    /// resolver needs (it never inspects the rest of a `DbStep`). Splitting it
    /// out lets a reader answer breakpoint queries from a PREPOPULATED line→step
    /// index — the spec's `step-map.ns` (M26) — with an O(unique-lines) lookup
    /// that does NOT trigger the whole step-table build, while readers without
    /// such an index keep the existing whole-table behaviour.
    ///
    /// The default derives the ids from [`steps_on_line`](Self::steps_on_line),
    /// so every reader is correct out of the box and the result is identical to
    /// the whole-table path. The CTFS reader OVERRIDES it to prefer the
    /// prepopulated `step-map.ns` when the `.ct` carries one (falling back to
    /// this same whole-table derivation when it does not).
    ///
    /// Returns `None` when the path/line has no recorded steps.
    fn step_ids_on_line(&self, path_id: PathId, line: usize) -> Option<Vec<StepId>> {
        self.steps_on_line(path_id, line)
            .map(|records| records.iter().map(|s| s.step_id).collect())
    }

    /// M0/3 — the exclusive END of the maximal run of steps that begins at
    /// `start` and carries `call_key`: the first step at-or-after `start` whose
    /// own `call_key` differs, or the step count when the run reaches the end of
    /// the trace. `start` itself when the step at `start` does not carry
    /// `call_key` (an empty run).
    ///
    /// `None` means "this reader has no call-key index and would have to walk
    /// the step stream to answer" — the caller then walks it itself, exactly as
    /// it always did. The default is `None` for every reader; the CTFS reader
    /// overrides it against the RESIDENT per-step call-key array its lazy step
    /// cache already builds at open.
    fn call_run_end(&self, start: StepId, call_key: CallKey) -> Option<StepId> {
        let _ = (start, call_key);
        None
    }

    /// M0/3 — the LINE-MAP accessor: the greatest source line carrying a step in
    /// the half-open range `[start, end)`, or `0` when the range holds no steps
    /// (`0` is the neutral element for a maximum over recorded lines, which are
    /// never negative).
    ///
    /// `None` means "this reader has no line index that covers every step and
    /// would have to walk the step stream to answer" — the caller then walks it
    /// itself. The CTFS reader overrides it against the prepopulated
    /// `step-map.ns`, and only when that table is a COMPLETE index over the
    /// trace's steps, which is what makes the answer identical to the walk.
    ///
    /// Together with [`call_run_end`](Self::call_run_end) this is what lets
    /// `load_location` obtain a function's last line from the container's own
    /// index instead of scanning from the current step to the end of the call.
    fn max_line_over_steps(&self, start: StepId, end: StepId) -> Option<i64> {
        let _ = (start, end);
        None
    }

    // ── Iteration helpers ────────────────────────────────────────────

    /// Iterate over all functions with their ids.
    ///
    /// Returns `(FunctionId, &FunctionRecord)` pairs in id order.
    fn functions_iter(&self) -> Box<dyn Iterator<Item = (FunctionId, &FunctionRecord)> + '_>;

    /// Iterate over all calls in order.
    fn calls_iter(&self) -> Box<dyn Iterator<Item = &DbCall> + '_>;

    /// Return a slice of steps starting from `start_id` to the end.
    ///
    /// Returns an empty slice when `start_id` is out of bounds.
    ///
    /// # This is the MATERIALIZING accessor
    ///
    /// A borrowed contiguous slice cannot be synthesized from a chunked
    /// stream, so a reader backed by a seekable `steps.dat` has to build the
    /// WHOLE step table to answer it — which is exactly what M0's gate is
    /// about. Every caller that only walks forward (or backward) until some
    /// condition holds should use [`scan_steps_from`](Self::scan_steps_from)
    /// instead, which is bounded by how far it actually walks.
    fn steps_from(&self, start_id: StepId) -> &[DbStep];

    /// Visit steps in trace order starting from the one adjacent to `start_id`,
    /// stopping as soon as `visit` returns `false`.
    ///
    /// `forward == true` visits `start_id + 1, start_id + 2, …`;
    /// `forward == false` visits `start_id - 1, start_id - 2, …, 0`.
    /// The step at `start_id` itself is never visited, matching what every
    /// caller of [`steps_from`](Self::steps_from) did by hand with `.skip(1)`
    /// or `[..end]`.
    ///
    /// # Why this exists (M0 deliverable 3, `steps_from` half)
    ///
    /// Ordinary step-over, step-out, continue and run-to-entry are all
    /// "walk until a predicate holds, then stop", and they typically stop
    /// within a handful of steps. Expressed over `steps_from` they nonetheless
    /// force the whole-table build, because the slice they ask for runs to the
    /// end of the trace. Expressed here, a reader with a seekable step stream
    /// serves each visited step from its chunk-aligned lazy cache, so the cost
    /// is proportional to the distance walked rather than to the trace length —
    /// which is what lets a trace larger than a tab's memory budget navigate.
    ///
    /// The default implementation walks `steps_from`, so a reader with a fully
    /// materialized step table behaves exactly as it did before.
    fn scan_steps_from(&self, start_id: StepId, forward: bool, visit: &mut dyn FnMut(&DbStep) -> bool) {
        if start_id.0 < 0 {
            return;
        }
        if forward {
            let tail = self.steps_from(start_id);
            for step in tail.iter().skip(1) {
                if !visit(step) {
                    return;
                }
            }
        } else {
            let all_steps = self.steps_from(StepId(0));
            let end = start_id.0 as usize;
            if end <= all_steps.len() {
                for step in all_steps[..end].iter().rev() {
                    if !visit(step) {
                        return;
                    }
                }
            }
        }
    }

    /// Iterate over all `(path_string, PathId)` entries in the path map.
    ///
    /// This is needed for fuzzy path matching (suffix match, filename match,
    /// etc.) where exact-match `path_id_for` is insufficient.
    fn path_entries_iter(&self) -> Box<dyn Iterator<Item = (&str, PathId)> + '_>;

    // ── Instructions ────────────────────────────────────────────────

    /// Assembly instructions recorded at a particular step.
    fn instructions_at(&self, step_id: StepId) -> Option<&Vec<String>>;

    // ── Derived queries ─────────────────────────────────────────────

    /// Convenience: look up the `CallKey` for the call containing `step_id`.
    ///
    /// Equivalent to `self.step(step_id).map(|s| s.call_key)`.
    fn call_key_for_step(&self, step_id: StepId) -> Option<CallKey> {
        self.step(step_id).map(|s| s.call_key)
    }

    /// Return events associated with a step.
    ///
    /// When `exact` is `true`, only events at exactly `step_id` are returned.
    /// When `false`, events across the entire "line visit" (a contiguous run
    /// of steps on the same source line) are returned.
    fn load_step_events(&self, step_id: StepId, exact: bool) -> Vec<DbRecordEvent>;

    // ── Metadata ────────────────────────────────────────────────────

    /// The working directory the trace was recorded in.
    fn workdir(&self) -> &Path;

    /// How the traced program ended (normal exit vs. error).
    fn end_of_program(&self) -> &EndOfProgram;

    /// Surface an omniscient DB owned by this trace reader, when the underlying
    /// trace carries production omniscient namespaces. The default keeps legacy
    /// in-memory readers unchanged; CTFS readers override this for CoW-backed
    /// `linehits.tc` and future non-memwrite namespaces.
    fn omniscient_db(&self) -> Option<&dyn crate::omniscient_db::OmniscientDb> {
        None
    }

    // ── Value / call conversion helpers ─────────────────────────────
    //
    // These default methods replace `Db::to_ct_value`, `Db::to_call`,
    // `Db::to_call_arg`, and `Db::load_location`.  They depend only on
    // other `TraceReader` methods (interning tables, steps, calls) so
    // any implementation of the trait gets them for free.

    /// Convert a `TypeId` to the frontend `Type` representation.
    ///
    /// A `TypeId` that is not present in the trace's interning type table
    /// MUST NOT panic the server: it degrades to a `<unknown>` placeholder
    /// type so the request that triggered the lookup still produces a
    /// response and the per-request channel is never dropped mid-flight.
    ///
    /// Why this matters on the new (seek-based / Nim-FFI) reader path: the
    /// reactive `ct/load-locals` auto-loader that fires after a navigation
    /// renders every local in the current frame. JS (and similar dynamic)
    /// recorders can emit value records whose `TypeId` is not represented
    /// in the trace's type table — typically function-bearing locals. An
    /// unchecked `expect("invalid TypeId")` here panicked the stable
    /// thread, dropped its response channel, and left the DAP client
    /// blocked forever waiting for a `stopped`/response that the panicked
    /// thread had committed to producing (e.g. the depth-changing
    /// `stepIn`/`stepOut` ViewModel acceptance tests would hang). This is
    /// the same defensive policy already applied to the materialized
    /// `MaterializedReplaySession::type_record` path
    /// (`db.rs::default_type_record`); applying it uniformly here keeps the
    /// server alive across malformed/absent type ids on the new-format
    /// reader too.
    fn to_ct_type(&self, type_id: &TypeId) -> Type {
        if self.type_count() == 0 {
            // Probably an rr trace case — no type information available.
            warn!("to_ct_type: returning placeholder type (assuming rr trace)");
            return Type::new(TypeKind::None, "<None>");
        }
        let Some(type_record) = self.type_record(*type_id) else {
            warn!("to_ct_type: TypeId {type_id:?} not in type table; using <unknown> placeholder");
            return Type::new(TypeKind::None, "<unknown>");
        };
        match type_record.kind {
            TypeKind::Struct => {
                let mut t = Type::new(type_record.kind, &type_record.lang_type);
                t.labels = self.get_field_names(type_id);
                t
            }
            _ => Type::new(type_record.kind, &type_record.lang_type),
        }
    }

    /// Return the field names for a struct type, or an empty vec for
    /// non-struct types.
    ///
    /// An absent `TypeId` degrades to an empty field list rather than
    /// panicking — same rationale as [`to_ct_type`](Self::to_ct_type):
    /// a missing type record must never bring down the stable thread and
    /// hang the DAP client.
    fn get_field_names(&self, type_id: &TypeId) -> Vec<String> {
        let Some(type_record) = self.type_record(*type_id) else {
            warn!("get_field_names: TypeId {type_id:?} not in type table; returning no field names");
            return Vec::new();
        };
        match &type_record.specific_info {
            TypeSpecificInfo::Struct { fields } => fields.iter().map(|field| field.name.clone()).collect(),
            _ => Vec::new(),
        }
    }

    /// Convert a `ValueRecord` to the frontend `Value` representation.
    ///
    /// This is recursive: compound value records (sequences, structs,
    /// tuples, variants, references) recurse into their children.
    ///
    /// Type lookups go through [`to_ct_type`](Self::to_ct_type) /
    /// [`type_record`](Self::type_record) and degrade to a `<unknown>`
    /// placeholder on an absent `TypeId` rather than panicking, so a
    /// malformed/absent type id can never drop the request channel.
    fn to_ct_value(&self, record: &ValueRecord) -> Value {
        match record {
            ValueRecord::Int { i, type_id } => {
                let mut res = Value::new(TypeKind::Int, self.to_ct_type(type_id));
                res.i = i.to_string();
                res
            }
            ValueRecord::Float { f, type_id } => {
                let mut res = Value::new(TypeKind::Float, self.to_ct_type(type_id));
                res.f = f.to_string();
                res
            }
            ValueRecord::String { text, type_id } => {
                let mut res = Value::new(TypeKind::String, self.to_ct_type(type_id));
                res.text = text.clone();
                res
            }
            ValueRecord::Bool { b, type_id } => {
                let mut res = Value::new(TypeKind::Bool, self.to_ct_type(type_id));
                res.b = *b;
                res
            }
            ValueRecord::Sequence {
                elements,
                type_id,
                is_slice,
            } => {
                let typ = if !is_slice {
                    self.to_ct_type(type_id)
                } else {
                    // An absent slice TypeId degrades to a `<unknown>`
                    // slice type rather than panicking — same defensive
                    // policy as `to_ct_type` (keeps the stable thread
                    // alive so the request still produces a response).
                    match self.type_record(*type_id) {
                        Some(type_record) => Type::new(TypeKind::Slice, &type_record.lang_type),
                        None => {
                            warn!(
                                "to_ct_value: slice TypeId {type_id:?} not in type table; using <unknown> placeholder"
                            );
                            Type::new(TypeKind::Slice, "<unknown>")
                        }
                    }
                };
                let mut res = Value::new(TypeKind::Seq, typ);
                res.elements = elements.iter().map(|e| self.to_ct_value(e)).collect();
                res
            }
            ValueRecord::Struct { field_values, type_id } => {
                let mut res = Value::new(TypeKind::Struct, self.to_ct_type(type_id));
                res.elements = field_values.iter().map(|value| self.to_ct_value(value)).collect();
                res
            }
            ValueRecord::Tuple { elements, type_id } => {
                let mut res = Value::new(TypeKind::Tuple, self.to_ct_type(type_id));
                res.elements = elements.iter().map(|value| self.to_ct_value(value)).collect();
                res.typ.labels = elements
                    .iter()
                    .enumerate()
                    .map(|(index, _)| format!("{index}"))
                    .collect();
                res.typ.member_types = res.elements.iter().map(|value| value.typ.clone()).collect();
                res
            }
            ValueRecord::Variant {
                discriminator,
                contents,
                type_id,
            } => {
                let mut res = Value::new(TypeKind::Variant, self.to_ct_type(type_id));
                res.active_variant = discriminator.to_string();
                res.active_variant_value = Some(Box::new(self.to_ct_value(contents)));
                res
            }
            ValueRecord::Reference {
                dereferenced,
                address,
                mutable,
                type_id,
            } => {
                let mut res = Value::new(TypeKind::Pointer, self.to_ct_type(type_id));
                let dereferenced_value = self.to_ct_value(dereferenced);
                res.typ.element_type = Some(Box::new(dereferenced_value.typ.clone()));
                res.address = (*address).to_string();
                res.ref_value = Some(Box::new(dereferenced_value));
                res.is_mutable = *mutable;
                res
            }
            ValueRecord::Raw { r, type_id } => {
                let mut res = Value::new(TypeKind::Raw, self.to_ct_type(type_id));
                res.r = r.clone();
                res
            }
            ValueRecord::Error { msg, type_id } => {
                let mut res = Value::new(TypeKind::Error, self.to_ct_type(type_id));
                res.msg = msg.clone();
                res
            }
            ValueRecord::None { type_id } => Value::new(TypeKind::None, self.to_ct_type(type_id)),
            ValueRecord::Cell { .. } => {
                // Supposed to map to place in value graph — not yet implemented.
                unimplemented!()
            }
            ValueRecord::BigInt { b, negative, type_id } => {
                let sign = if *negative {
                    num_bigint::Sign::Minus
                } else {
                    num_bigint::Sign::Plus
                };
                let num = BigInt::from_bytes_be(sign, b);
                let mut res = Value::new(TypeKind::Int, self.to_ct_type(type_id));
                res.i = num.to_string();
                res
            }
            ValueRecord::Char { c, type_id } => {
                let mut res = Value::new(TypeKind::Char, self.to_ct_type(type_id));
                res.c = c.to_string();
                res
            }
        }
    }

    /// Convert a `FullValueRecord` (variable name + value) to a `CallArg`.
    #[allow(clippy::expect_used)]
    fn to_call_arg(&self, arg_record: &FullValueRecord) -> CallArg {
        CallArg {
            name: self
                .variable_name(arg_record.variable_id)
                .unwrap_or("<unknown>")
                .to_string(),
            text: "".to_string(),
            value: self.to_ct_value(&arg_record.value),
        }
    }

    /// Convert a `DbCall` to the frontend `Call` representation.
    ///
    /// Uses `load_location` for the call's source location and
    /// `to_ct_value` / `to_call_arg` for arguments and return value.
    #[allow(clippy::expect_used)]
    fn to_call(&self, call_record: &DbCall, expr_loader: &mut ExprLoader) -> Call {
        Call {
            key: format!("{}", call_record.key.0),
            children: vec![],
            depth: call_record.depth,
            location: self.load_location(call_record.step_id, call_record.key, expr_loader),
            parent: None,
            raw_name: self
                .function(call_record.function_id)
                .expect("to_call: invalid function_id")
                .name
                .clone(),
            args: call_record.args.iter().map(|arg| self.to_call_arg(arg)).collect(),
            return_value: self.to_ct_value(&call_record.return_value),
            with_args_and_return: true,
        }
    }

    /// Build a `Location` for the given step and call key.
    ///
    /// If `call_key_arg` has a negative value, the step's own call key is
    /// used instead.  The returned location includes function boundary
    /// lines when tree-sitter data is available via `expr_loader`.
    #[allow(clippy::expect_used)]
    fn load_location(&self, step_id: StepId, call_key_arg: CallKey, expr_loader: &mut ExprLoader) -> Location {
        let step_id_int = step_id.0;
        let Some(step_record) = self.step(step_id) else {
            // Some recorders (notably the EVM recorder against
            // multi-function contracts like FlowTest.sol) emit Call
            // records whose ``step_id`` points outside the steps table
            // -- the source-map walk attributes the call to a step
            // index that the step stream never produces.  Older
            // versions of this helper would ``.expect("load_location:
            // invalid step_id")`` and panic in the stable worker
            // thread, which left every ``ct/load-calltrace-section``
            // request hanging until the WDIO client timed out
            // ("``DAP request timeout``").  Surface a sentinel
            // location instead so the calltrace-section response can
            // still be assembled -- the GUI shows ``<unknown>`` in
            // that row, which is strictly more useful than the
            // request never completing.
            warn!(
                "load_location: step_id {step_id_int} out of range (step_count={}) -- \
                 returning sentinel Location to keep the DAP response stream alive",
                self.step_count(),
            );
            return Location {
                rr_ticks: RRTicks(step_id_int),
                key: format!("{}", call_key_arg.0),
                ..Location::default()
            };
        };
        let path = format!(
            "{}",
            self.workdir()
                .join(self.path(step_record.path_id).unwrap_or(""))
                .display()
        );
        let line = step_record.line.0;
        let call_key = if call_key_arg.0 >= 0 {
            call_key_arg
        } else {
            step_record.call_key
        };
        let call_key_int = call_key.0;

        // Allow NO_KEY (-1): some traces (e.g. MCR portable traces) have
        // steps that are not inside any call.  The branch below already
        // handles NO_KEY by returning "<unknown>" function name.
        assert!(
            call_key_int >= 0 || call_key == NO_KEY,
            "load_location: unexpected negative call_key {call_key_int} (not NO_KEY)"
        );

        let (function_name, callstack_depth) = if call_key != NO_KEY {
            let call = self.call(call_key).expect("load_location: invalid call_key");
            let function = self
                .function(call.function_id)
                .expect("load_location: invalid function_id");
            (function.name.clone(), call.depth)
        } else {
            ("<unknown>".to_string(), 0)
        };
        let call_key_text = format!("{call_key_int}");
        let global_call_key_text = format!("{}", step_record.global_call_key.0);

        let mut location = Location::new(
            &path,
            line,
            RRTicks(step_id_int),
            &function_name,
            &call_key_text,
            &global_call_key_text,
            callstack_depth,
        );
        // M1 — surface the recorded column on the DAP wire when the
        // trace carries it (Python + JavaScript column-aware recorders).
        // `Location::new` initializes `column = None` for the legacy
        // line-only path; we overwrite here so the `ct/complete-move`
        // event and the breakpoint stop-check downstream both see the
        // recorded column.
        location.column = step_record.column.map(|c| c.0);
        if function_name != "<top-level>" {
            let raw_path = self.path(step_record.path_id).unwrap_or("");
            let use_trace_function_boundaries = |location: &mut Location| {
                if call_key != NO_KEY {
                    let call = self
                        .call(CallKey(call_key_int))
                        .expect("load_location: invalid call_key (fallback)");
                    let function_record = self
                        .function(call.function_id)
                        .expect("load_location: invalid function_id (fallback)");
                    location.function_first = function_record.line.0;

                    let mut last_line = function_record.line.0;
                    // M0/3 — the function's last line is the greatest line over
                    // the SUFFIX of this call's step run that begins at the
                    // current step. Ask the reader's indices for it first: the
                    // run's end from the resident call-key array, and the run's
                    // greatest line from the prepopulated `step-map.ns`. Both
                    // answers are exact — `max_line_over_steps` only answers at
                    // all when its table covers every step — so this is the same
                    // number the walk below produces.
                    //
                    // This is the browser path's whole cost. The walk is O(run
                    // length) point lookups into `steps.dat`, and on the browser
                    // there is no filesystem, so `expr_loader.load_file` always
                    // fails and EVERY `load_location` reached it; a trace that is
                    // one long call therefore walked to the end of the trace
                    // every time. Readers with neither index return `None` and
                    // keep the walk, unchanged.
                    let indexed = self
                        .call_run_end(StepId(step_id_int), CallKey(call_key_int))
                        .and_then(|run_end| self.max_line_over_steps(StepId(step_id_int), run_end));
                    match indexed {
                        Some(indexed_last) => {
                            if indexed_last > last_line {
                                last_line = indexed_last;
                            }
                        }
                        None => {
                            let steps_len = self.step_count() as i64;
                            for i in step_id_int..steps_len {
                                let step = self.step(StepId(i)).expect("load_location: invalid step in range");
                                if step.call_key == CallKey(call_key_int) {
                                    if step.line.0 > last_line {
                                        last_line = step.line.0;
                                    }
                                } else {
                                    break;
                                }
                            }
                        }
                    }
                    location.function_last = last_line;
                }
            };
            match expr_loader.load_file(&PathBuf::from(raw_path)) {
                Ok(_) => {
                    let (fn_start, fn_last) = expr_loader.get_first_last_fn_lines(&location);
                    let lang = expr_loader.get_current_language(&PathBuf::from(raw_path));
                    // BEAM languages (Elixir + Erlang) ship their function ranges
                    // in manifests, not tree-sitter — defer to the trace's own
                    // function boundaries for both.
                    if lang != Lang::Elixir && lang != Lang::Erlang && fn_start > 0 && fn_last >= fn_start {
                        location.function_first = fn_start;
                        location.function_last = fn_last;
                    } else {
                        use_trace_function_boundaries(&mut location);
                    }
                }
                Err(e) => {
                    // No tree-sitter grammar for this language (Cairo, Circom, etc.).
                    // Fall back to the trace's own function line data.
                    warn!("expr loader load file error: {e:?} — using trace function boundaries");
                    use_trace_function_boundaries(&mut location);
                }
            }
        }
        location
    }

    // ── Navigation helpers ────────────────────────────────────────

    /// Step forward or backward through the trace, skipping steps that
    /// are deeper than the starting depth minus `delta`.
    ///
    /// * `delta == 0` → "next" (same level or shallower)
    /// * `delta == 1` → "step out" (shallower level only)
    ///
    /// Returns the new `StepId` (unchanged if no suitable step was found).
    #[allow(clippy::expect_used)]
    fn step_over_depths_step_id(&self, start_step_id: StepId, forward: bool, delta: usize) -> StepId {
        let Some(initial_step) = self.step(start_step_id) else {
            warn!(
                "step_over_depths_step_id: start_step_id {:?} is out of bounds (steps len {})",
                start_step_id,
                self.step_count()
            );
            return start_step_id;
        };
        // A step whose `call_key` does not resolve to a recorded call is a
        // FRAMELESS step, not an error and not a dead end.  Event-driven
        // runtimes record them routinely: the JavaScript recorder emits
        // steps at the event-loop level — the bootstrap steps before the
        // module frame opens, and the steps between one callback returning
        // and the next being entered — and those carry `CallKey(NO_KEY)`
        // because no recorded call encloses them.
        //
        // Frameless steps sit at the trace's OUTERMOST level, which is the
        // same level as the frames the event loop drives (the `<module>`
        // call and every callback invoked from the loop are recorded with
        // `depth = 0` and `parent = NO_KEY`).  Their effective depth is
        // therefore 0, and a step-over from one behaves exactly like a
        // step-over at the outermost level: advance to the next step that
        // is not deeper.
        //
        // Bailing out with `start_step_id` here — as this code used to —
        // meant step-over reported "no successor" for every frameless
        // step, so pressing F10 at the last statement of a Node module
        // body held the cursor forever even though step-into and continue
        // both advanced from the identical position.
        let initial_call_depth: i64 = match self.call(initial_step.call_key) {
            Some(call) => call.depth as i64,
            None => OUTERMOST_CALL_DEPTH,
        };
        let mut current_step_id = start_step_id;

        // M0/3 — a BOUNDED walk, not a slice.
        //
        // This loop stops at the first step shallow enough to be the
        // destination, which for ordinary step-over is a handful of steps
        // away. It used to express that over `steps_from`, whose borrowed
        // slice runs to the end of the trace and therefore forced the whole
        // step table to be materialized on a seekable reader — on the very
        // first navigation command, which is BlockTracer's exact use case.
        // `scan_steps_from` walks the same steps in the same order and lets
        // the reader serve them from wherever it can afford to.
        //
        // The backward direction was the worse of the two: it asked for
        // `steps_from(StepId(0))` — the entire trace — purely to walk a few
        // steps back from the current position.
        self.scan_steps_from(start_step_id, forward, &mut |new_step| {
            let new_call_key = new_step.call_key;
            current_step_id = new_step.step_id;
            let Some(new_call) = self.call(new_call_key) else {
                warn!(
                    "step_over_depths_step_id: call_key {:?} for step {:?} is out of bounds (calls len {})",
                    new_call_key,
                    current_step_id,
                    self.call_count()
                );
                return false;
            };

            info!("for returned: {:?} with depth: {:?}", new_step, new_call.depth);

            // depth - delta can be < 0: compare as i64 to avoid underflow.
            // Stop here when the step is at or above the target depth.
            (new_call.depth as i64) > initial_call_depth - (delta as i64)
        });

        current_step_id
    }

    /// Find the step id after stepping out of the current call (one level shallower).
    ///
    /// Returns `(new_step_id, moved)` where `moved` is `true` when
    /// the position actually changed.
    fn step_out_step_id_relative_to(&self, step_id: StepId, forward: bool) -> (StepId, bool) {
        let new_step_id = self.step_over_depths_step_id(step_id, forward, 1);
        (new_step_id, step_id != new_step_id)
    }

    /// Find the next step id at the same call depth (stepping over deeper calls),
    /// optionally requiring a different source line.
    ///
    /// Returns `(new_step_id, moved)`.
    fn next_step_id_relative_to(&self, step_id: StepId, forward: bool, step_to_different_line: bool) -> (StepId, bool) {
        // M2 — delegate to the granularity-aware driver with the
        // column-check disabled.  The line-only path stays
        // bit-for-bit identical to the pre-M2 implementation; the
        // statement-granularity path goes through
        // `next_step_id_relative_to_with_granularity` directly.
        self.next_step_id_relative_to_with_granularity(step_id, forward, step_to_different_line, false)
    }

    /// M2 — granularity-aware next-step driver.  Same depth-handling
    /// shape as [`next_step_id_relative_to`] but with a column-aware
    /// loop-termination predicate so the statement-granularity runner
    /// can stop at a column change within the same line.
    ///
    /// * `step_to_different_line = false`, `step_to_different_column = false`
    ///   → single hop at same-or-shallower depth.
    /// * `step_to_different_line = true`, `step_to_different_column = false`
    ///   → legacy line-granularity (`Action::Next`).
    /// * `step_to_different_column = true` → statement-granularity (M2).
    ///   Steps with `column = None` collapse — the column check
    ///   reduces to equality of `None`s and never breaks the loop —
    ///   so legacy line-only traces degrade gracefully to
    ///   line-granularity behaviour without the caller needing a
    ///   capability check.
    ///
    /// Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M2.
    fn next_step_id_relative_to_with_granularity(
        &self,
        step_id: StepId,
        forward: bool,
        step_to_different_line: bool,
        step_to_different_column: bool,
    ) -> (StepId, bool) {
        let mut last_step_id = step_id;
        let Some(original_step) = self.step(step_id) else {
            warn!(
                "next_step_id_relative_to: step_id {:?} is out of bounds (steps len {})",
                step_id,
                self.step_count()
            );
            return (step_id, false);
        };
        let original_step = *original_step;
        let (original_path_id, original_line, original_column, original_call_key) = (
            original_step.path_id,
            original_step.line,
            original_step.column,
            original_step.call_key,
        );
        let mut count = 0;
        loop {
            let current_step_id = self.step_over_depths_step_id(last_step_id, forward, 0);
            if current_step_id == last_step_id {
                return (current_step_id, false);
            }
            last_step_id = current_step_id;
            count += 1;
            if count >= NEXT_INTERNAL_STEP_OVERS_LIMIT {
                break;
            }
            if !step_to_different_line && !step_to_different_column {
                break;
            } else if let Some(current_step) = self.step(current_step_id) {
                let path_or_line_changed = original_path_id != current_step.path_id
                    || original_line != current_step.line
                    || original_call_key != current_step.call_key;
                if path_or_line_changed {
                    // line / path / call frame changed — both
                    // granularities stop here.
                    break;
                }
                if step_to_different_column {
                    // M2 / M7 — statement-boundary detection.  Under
                    // the column-aware recorder contract the recorder
                    // may emit multiple steps per statement on the
                    // same source line: the user-facing
                    // `__ct.step(siteId)` injection point plus
                    // assignment-write / bookkeeping hooks anchored
                    // at-or-before the statement's start column.
                    //
                    // Forward direction (M2 — `next`/F10-style):
                    // we define the unambiguous user-visible "next
                    // statement" as the next step on the same line
                    // whose column is STRICTLY GREATER than the entry
                    // column — that is, the start of the NEXT
                    // statement under the recorder's left-to-right
                    // code-emit model.  Same-line steps with column ≤
                    // entry are either intra-statement bookkeeping or
                    // repeated landings at the entry's own column;
                    // both are skipped.
                    //
                    // Backward direction (M7 — `stepBack`-style): we
                    // mirror the predicate.  The "previous statement"
                    // is the previous step on the same line whose
                    // column is STRICTLY LESS than the entry column —
                    // the start of the PRIOR statement under the
                    // recorder's left-to-right code-emit model.
                    // Same-line steps with column ≥ entry are
                    // intra-statement bookkeeping the runner skips
                    // past to reach the real prior-statement boundary.
                    // This is the exact mirror of the forward
                    // predicate; the JS recorder's same-line
                    // bookkeeping-anchor behaviour applies
                    // symmetrically in the reverse direction.
                    //
                    // `column = None` (legacy line-only traces) maps
                    // every comparison to "not strictly past", so the
                    // boundary never fires and statement granularity
                    // degrades to line granularity — the documented
                    // fallback for traces without column data, in
                    // both directions.
                    //
                    // Spec:
                    //   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M2 (forward) and §M7 (backward).
                    let strictly_advanced = match (original_column, current_step.column) {
                        (Some(prev), Some(cur)) => {
                            if forward {
                                cur.0 > prev.0
                            } else {
                                cur.0 < prev.0
                            }
                        }
                        _ => false,
                    };
                    if strictly_advanced {
                        break;
                    }
                }
            } else {
                warn!(
                    "next_step_id_relative_to: current_step_id {:?} out of bounds during line check",
                    current_step_id
                );
                break;
            }
        }
        if let Some(last_step) = self.step(last_step_id) {
            info!("next step id: {:?}", last_step);
        }
        (last_step_id, step_id != last_step_id)
    }

    // ── Value loading ──────────────────────────────────────────────

    /// Look up the value for a given `Place` at the given step, walking
    /// the cell-change history to find the most recent change.
    #[allow(clippy::comparison_chain)]
    fn load_value_for_place(&self, place: Place, step_id: StepId) -> ValueRecord {
        info!("load_value_for_place {place:?} for #{step_id:?}");
        if let Some(changes) = self.cell_changes_for(&place) {
            let mut i: usize = 0;
            let mut last_change_index: Option<usize> = None;
            while i < changes.len() {
                let change = changes[i];
                info!("cell change {i} for {place:?} for {step_id:?}: {change:?}");
                if changes[i].step_id == step_id {
                    last_change_index = Some(i);
                    break;
                } else if changes[i].step_id > step_id {
                    break;
                } else {
                    last_change_index = Some(i);
                    i += 1;
                    continue;
                }
            }
            if let Some(index) = last_change_index {
                let cell_change = changes[index];
                info!("last cell change for {place:?} for {step_id:?}: {cell_change:?}");
                info!("==============");
                if let Some(cells_for_step_id) = self.cells_at(cell_change.step_id) {
                    if cells_for_step_id.contains_key(&place) {
                        cells_for_step_id[&place].clone()
                    } else {
                        self.load_compound_value_for_place(place, cell_change)
                    }
                } else {
                    self.load_compound_value_for_place(place, cell_change)
                }
            } else {
                ValueRecord::Error {
                    msg: format!("internal error: no cell change for place {place:?} up to step_id {place:?}"),
                    type_id: TypeId(0),
                }
            }
        } else {
            ValueRecord::Error {
                msg: "internal error: no change found for this place".to_string(),
                type_id: TypeId(0),
            }
        }
    }

    /// Load a compound (aggregate) value for a place from the compound table.
    fn load_compound_value_for_place(&self, place: Place, cell_change: CellChange) -> ValueRecord {
        info!("load_compound_value_for_place {place:?} {cell_change:?}");
        if let Some(compound_for_step_id) = self.compound_at(cell_change.step_id) {
            if compound_for_step_id.contains_key(&place) {
                let compound_value = &compound_for_step_id[&place];
                if let ValueRecord::Sequence {
                    elements,
                    type_id,
                    is_slice: _,
                } = compound_value
                {
                    let loaded_elements = elements
                        .iter()
                        .map(|element| {
                            if let ValueRecord::Cell { place } = element {
                                self.load_value_for_place(*place, cell_change.step_id)
                            } else {
                                element.clone()
                            }
                        })
                        .collect();
                    ValueRecord::Sequence {
                        elements: loaded_elements,
                        type_id: *type_id,
                        is_slice: false,
                    }
                } else {
                    compound_value.clone()
                }
            } else if let Some(_index) = cell_change.index {
                if let Some(type_id) = cell_change.type_id {
                    let elements: Vec<ValueRecord> = (0..cell_change.item_count)
                        .map(|i| self.load_value_item_by_index(place, i, cell_change.step_id))
                        .collect();
                    ValueRecord::Sequence {
                        elements,
                        type_id,
                        is_slice: false,
                    }
                } else {
                    ValueRecord::Error {
                        msg: "internal error: no type_id for this compound cell change".to_string(),
                        type_id: TypeId(0),
                    }
                }
            } else {
                ValueRecord::Error {
                    msg: "internal error: no cell/compound for this place and step_id".to_string(),
                    type_id: TypeId(0),
                }
            }
        } else if let Some(_index) = cell_change.index {
            if let Some(type_id) = cell_change.type_id {
                let elements: Vec<ValueRecord> = (0..cell_change.item_count)
                    .map(|i| self.load_value_item_by_index(place, i, cell_change.step_id))
                    .collect();
                ValueRecord::Sequence {
                    elements,
                    type_id,
                    is_slice: false,
                }
            } else {
                ValueRecord::Error {
                    msg: "internal error: no type_id for this compound cell change".to_string(),
                    type_id: TypeId(0),
                }
            }
        } else {
            ValueRecord::Error {
                msg: "internal error: no cell/compound for this place and step_id".to_string(),
                type_id: TypeId(0),
            }
        }
    }

    /// Load a single element of a compound value by its index within the compound.
    fn load_value_item_by_index(&self, place: Place, index: usize, step_id: StepId) -> ValueRecord {
        info!("load_value_by_index {place:?} index {index} #{step_id:?}");
        if let Some(changes) = self.cell_changes_for(&place) {
            for cell_change in changes.iter().rev() {
                if cell_change.step_id <= step_id {
                    info!("  cell change for index {index}: {cell_change:?}");
                    if let Some(change_index) = cell_change.index
                        && change_index == index
                        && let Some(item_place) = cell_change.item_place
                    {
                        return self.load_value_for_place(item_place, step_id);
                    }
                }
            }
        }
        ValueRecord::Error {
            msg: "internal error: no relevant cell change for this index".to_string(),
            type_id: TypeId(0),
        }
    }

    // ── Fuzzy path resolution ──────────────────────────────────────

    /// Resolve a source path to its `PathId`, trying multiple matching
    /// strategies beyond exact match.
    ///
    /// Strategies tried in order:
    /// 1. Exact match via `path_id_for`
    /// 2. Workdir-stripped relative path match
    /// 3. Suffix match (component-wise)
    /// 4. Canonicalized path match (resolves symlinks)
    /// 5. Reverse canonicalize (stored paths may be symlink-resolved)
    /// 6. Filename-only match (when unambiguous)
    ///
    /// On Windows, path separators are normalized at each stage.
    fn fuzzy_path_id_for(&self, path: &str) -> Option<PathId> {
        // 1. Exact match (fast path).
        if let Some(id) = self.path_id_for(path) {
            return Some(id);
        }

        // On Windows, normalize separators.
        #[cfg(windows)]
        let normalized = path.replace('\\', "/");

        #[cfg(windows)]
        if normalized != path
            && let Some(id) = self.path_id_for(&normalized)
        {
            return Some(id);
        }

        // On Windows, paths are case-insensitive and the drive letter is
        // commonly cased differently by different toolchains — e.g. Rust's
        // `canonicalize` yields `D:\...` while the Erlang/Elixir BEAM
        // `filename` module emits `d:/...`. Compare the query against every
        // stored path with both separators and case folded so a breakpoint
        // set via one casing still resolves against the trace's other.
        #[cfg(windows)]
        {
            let folded = normalized.to_lowercase();
            for (stored_path, id) in self.path_entries_iter() {
                if !stored_path.is_empty() && stored_path.replace('\\', "/").to_lowercase() == folded {
                    return Some(id);
                }
            }
        }

        let abs_path = std::path::Path::new(path);
        let workdir = self.workdir();

        // 2. Try stripping the workdir prefix to obtain a relative path.
        let relative_str = abs_path
            .strip_prefix(workdir)
            .ok()
            .and_then(|relative| relative.to_str());
        if let Some(id) = relative_str.and_then(|rel_str| self.path_id_for(rel_str)) {
            return Some(id);
        }
        #[cfg(windows)]
        {
            if let Some(rel_str) = relative_str {
                let norm_rel = rel_str.replace('\\', "/");
                if norm_rel != rel_str
                    && let Some(id) = self.path_id_for(&norm_rel)
                {
                    return Some(id);
                }
            }
        }

        // On Windows, also try stripping the workdir with normalized separators.
        #[cfg(windows)]
        {
            let norm_workdir = workdir.to_string_lossy().replace('\\', "/");
            if normalized.starts_with(&norm_workdir) {
                let relative = &normalized[norm_workdir.len()..].trim_start_matches('/');
                if let Some(id) = self.path_id_for(relative) {
                    return Some(id);
                }
            }
        }

        // 3. Suffix match: check if the absolute path ends with any stored
        //    relative path (compared component-wise).
        for (stored_path, id) in self.path_entries_iter() {
            if !stored_path.is_empty() && abs_path.ends_with(stored_path) {
                return Some(id);
            }
        }

        // 4. Canonicalize and retry.
        if let Ok(canonical) = abs_path.canonicalize()
            && canonical != abs_path
        {
            if let Some(canonical_str) = canonical.to_str()
                && let Some(id) = self.path_id_for(canonical_str)
            {
                return Some(id);
            }
            for (stored_path, id) in self.path_entries_iter() {
                if !stored_path.is_empty() && canonical.ends_with(stored_path) {
                    return Some(id);
                }
            }
        }

        // 5. Reverse canonicalize: stored paths may be symlink-resolved.
        for (stored_path, id) in self.path_entries_iter() {
            if stored_path.is_empty() {
                continue;
            }
            let sp = std::path::Path::new(stored_path);
            if sp.is_absolute()
                && let Ok(canonical_stored) = sp.canonicalize()
                && canonical_stored == abs_path
            {
                return Some(id);
            }
        }

        // 6. Filename-only match (unambiguous).
        if let Some(lookup_filename) = abs_path.file_name() {
            let matches: Vec<PathId> = self
                .path_entries_iter()
                .filter_map(|(stored, id)| {
                    let sp = std::path::Path::new(stored);
                    if sp.file_name() == Some(lookup_filename) {
                        Some(id)
                    } else {
                        None
                    }
                })
                .collect();
            if matches.len() == 1 {
                return Some(matches[0]);
            }
        }

        None
    }
}
