use std::collections::HashMap;
use std::path::{Path, PathBuf};

use log::{info, warn};
use num_bigint::BigInt;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, PathId, Place, StepId, TypeId, TypeKind, TypeRecord,
    TypeSpecificInfo, ValueRecord, VariableId, NO_KEY,
};

use crate::db::{CellChange, DbCall, DbRecordEvent, DbStep, EndOfProgram, NEXT_INTERNAL_STEP_OVERS_LIMIT};
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

    // ── Events ──────────────────────────────────────────────────────

    /// All recorded events, in order.
    fn events(&self) -> &[DbRecordEvent];

    /// Total number of recorded events.
    fn event_count(&self) -> usize;

    // ── Secondary indices ───────────────────────────────────────────

    /// Reverse-lookup: find the `PathId` for a given path string.
    fn path_id_for(&self, path: &str) -> Option<PathId>;

    /// Return the step records on a given `line` within a given path.
    /// Returns `None` when the path or line has no recorded steps.
    fn steps_on_line(&self, path_id: PathId, line: usize) -> Option<&Vec<DbStep>>;

    /// Return the full line→steps map for a given path.
    fn step_map_for_path(&self, path_id: PathId) -> Option<&HashMap<usize, Vec<DbStep>>>;

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
    fn steps_from(&self, start_id: StepId) -> &[DbStep];

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

    // ── Value / call conversion helpers ─────────────────────────────
    //
    // These default methods replace `Db::to_ct_value`, `Db::to_call`,
    // `Db::to_call_arg`, and `Db::load_location`.  They depend only on
    // other `TraceReader` methods (interning tables, steps, calls) so
    // any implementation of the trait gets them for free.

    /// Convert a `TypeId` to the frontend `Type` representation.
    #[allow(clippy::expect_used)]
    fn to_ct_type(&self, type_id: &TypeId) -> Type {
        if self.type_count() == 0 {
            // Probably an rr trace case — no type information available.
            warn!("to_ct_type: returning placeholder type (assuming rr trace)");
            return Type::new(TypeKind::None, "<None>");
        }
        let type_record = self.type_record(*type_id).expect("to_ct_type: invalid TypeId");
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
    #[allow(clippy::expect_used)]
    fn get_field_names(&self, type_id: &TypeId) -> Vec<String> {
        match &self
            .type_record(*type_id)
            .expect("get_field_names: invalid TypeId")
            .specific_info
        {
            TypeSpecificInfo::Struct { fields } => fields.iter().map(|field| field.name.clone()).collect(),
            _ => Vec::new(),
        }
    }

    /// Convert a `ValueRecord` to the frontend `Value` representation.
    ///
    /// This is recursive: compound value records (sequences, structs,
    /// tuples, variants, references) recurse into their children.
    #[allow(clippy::expect_used)]
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
                    let type_record = self
                        .type_record(*type_id)
                        .expect("to_ct_value: invalid TypeId for slice");
                    Type::new(TypeKind::Slice, &type_record.lang_type)
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
        let step_record = self.step(step_id).expect("load_location: invalid step_id");
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
        let Some(initial_call) = self.call(initial_step.call_key) else {
            warn!(
                "step_over_depths_step_id: call_key {:?} for step {:?} is out of bounds (calls len {})",
                initial_step.call_key,
                start_step_id,
                self.call_count()
            );
            return start_step_id;
        };
        let initial_call_depth = initial_call.depth;
        let mut current_step_id = start_step_id;

        // Iterate using steps_from slice, skipping the first element (the start step itself).
        let steps_slice = self.steps_from(start_step_id);
        let iter: Box<dyn Iterator<Item = &DbStep>> = if forward {
            // Skip the first element (the start step itself).
            Box::new(steps_slice.iter().skip(1))
        } else {
            // For backward iteration, we need all steps before start_step_id.
            // steps_from gives us [start_step_id..end], but we need [0..start_step_id) reversed.
            let all_steps = self.steps_from(StepId(0));
            let end = start_step_id.0 as usize;
            if end <= all_steps.len() {
                Box::new(all_steps[..end].iter().rev())
            } else {
                Box::new(std::iter::empty())
            }
        };

        for new_step in iter {
            let new_call_key = new_step.call_key;
            current_step_id = new_step.step_id;
            let Some(new_call) = self.call(new_call_key) else {
                warn!(
                    "step_over_depths_step_id: call_key {:?} for step {:?} is out of bounds (calls len {})",
                    new_call_key,
                    current_step_id,
                    self.call_count()
                );
                break;
            };

            info!("for returned: {:?} with depth: {:?}", new_step, new_call.depth);

            // depth - delta can be < 0: compare as i64 to avoid underflow.
            if (new_call.depth as i64) <= (initial_call_depth as i64) - (delta as i64) {
                break;
            }
        }

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
        let (original_path_id, original_line, original_call_key) =
            (original_step.path_id, original_step.line, original_step.call_key);
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
            if !step_to_different_line {
                break;
            } else if let Some(current_step) = self.step(current_step_id) {
                if original_path_id != current_step.path_id
                    || original_line != current_step.line
                    || original_call_key != current_step.call_key
                {
                    break;
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
                    if let Some(change_index) = cell_change.index {
                        if change_index == index {
                            if let Some(item_place) = cell_change.item_place {
                                return self.load_value_for_place(item_place, step_id);
                            }
                        }
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
        if normalized != path {
            if let Some(id) = self.path_id_for(&normalized) {
                return Some(id);
            }
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
        if let Ok(relative) = abs_path.strip_prefix(workdir) {
            if let Some(rel_str) = relative.to_str() {
                if let Some(id) = self.path_id_for(rel_str) {
                    return Some(id);
                }
                #[cfg(windows)]
                {
                    let norm_rel = rel_str.replace('\\', "/");
                    if norm_rel != rel_str {
                        if let Some(id) = self.path_id_for(&norm_rel) {
                            return Some(id);
                        }
                    }
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
        if let Ok(canonical) = abs_path.canonicalize() {
            if canonical != abs_path {
                if let Some(canonical_str) = canonical.to_str() {
                    if let Some(id) = self.path_id_for(canonical_str) {
                        return Some(id);
                    }
                }
                for (stored_path, id) in self.path_entries_iter() {
                    if !stored_path.is_empty() && canonical.ends_with(stored_path) {
                        return Some(id);
                    }
                }
            }
        }

        // 5. Reverse canonicalize: stored paths may be symlink-resolved.
        for (stored_path, id) in self.path_entries_iter() {
            if stored_path.is_empty() {
                continue;
            }
            let sp = std::path::Path::new(stored_path);
            if sp.is_absolute() {
                if let Ok(canonical_stored) = sp.canonicalize() {
                    if canonical_stored == abs_path {
                        return Some(id);
                    }
                }
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
